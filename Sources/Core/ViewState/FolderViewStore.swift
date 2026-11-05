import Foundation
import MacxFS

/// Persisted per-folder view state (spec §11 Phase 2). Lookup: object key, then the path index (each record's last
/// known path), then `defaults()`. Records are created only by `save`, so untouched folders follow the defaults
/// ("Apply to All Folders" changes the defaults and calls `removeAll`). At most `capacity` records; the least
/// recently used are evicted. Writes are debounced by `flushDelay`; `flush()` writes now. No file-system calls:
/// `storage` holds the bytes (`FileSettingsStorage` does its own I/O off main).
///
/// §4.4 (review fix): the debounced write snapshots `records` on main, sorts and encodes on a background task, and
/// only hands the bytes to `storage` on main; a newer write supersedes an encode still in flight. The persisted form
/// (`encode`/`decode`) is compact line-based text with each distinct column list stored once and referenced by
/// index: a full store is under 1.4 MB even with a distinct column list per record (was ~4.4 MB of JSON), and loads
/// at launch in about 15 ms in release (was about 120 ms). Budgets: `macx-bench --metrics folderViews`.
@MainActor
public final class FolderViewStore {
    public static let storageKey = "folderViews.v2"
    /// The verbose P2-07 format; removed on load (it was never released).
    static let legacyStorageKey = "folderViews.v1"
    public static let capacity = 5_000

    struct Record: Sendable, Equatable {
        var key: FolderViewKey
        var pathKey: FolderViewKey
        var state: FolderViewState
        var lastUsed: Date
    }

    private let storage: any SettingsStorage
    private let defaults: @MainActor () -> FolderViewState
    private let now: @MainActor () -> Date
    private let flushDelay: Duration
    private var records: [FolderViewKey: Record] = [:]
    /// Path key → the key of the record last seen at that path.
    private var byPath: [FolderViewKey: FolderViewKey] = [:]
    private var flushTask: Task<Void, Never>?
    /// Bumped by every write; an encode started for an older generation is dropped.
    private var writeGeneration = 0
    /// Test inspection.
    private(set) var backgroundEncodeCount = 0
    private(set) var lastEncodeWasOnMain = false

    public init(storage: any SettingsStorage, defaults: @escaping @MainActor () -> FolderViewState,
                now: @escaping @MainActor () -> Date = { Date() }, flushDelay: Duration = .seconds(1)) {
        self.storage = storage
        self.defaults = defaults
        self.now = now
        self.flushDelay = flushDelay
        if storage.data(forKey: Self.legacyStorageKey) != nil { storage.set(nil, forKey: Self.legacyStorageKey) }
        if let data = storage.data(forKey: Self.storageKey), let list = Self.decode(data) {
            // Stored most recent first: keep the most recent claim on a path, and at most `capacity` records.
            for r in list.prefix(Self.capacity) where records[r.key] == nil {
                records[r.key] = r
                if byPath[r.pathKey] == nil { byPath[r.pathKey] = r.key }
            }
        }
    }

    deinit { flushTask?.cancel() }

    public var count: Int { records.count }

    /// The folder's own state, or `defaults()`. Never creates a record. A hit refreshes its LRU time and, for an
    /// object-keyed record seen under a new path (renamed or moved), moves the path index to the new path.
    public func state(for locator: FolderViewLocator) -> FolderViewState {
        guard var record = lookup(locator) else { return defaults() }
        record.lastUsed = now()
        if case .object = record.key, record.pathKey != locator.pathKey {
            if byPath[record.pathKey] == record.key { byPath[record.pathKey] = nil }
            dropPathRecord(at: locator.pathKey, keeping: record.key)
            record.pathKey = locator.pathKey
            byPath[locator.pathKey] = record.key
            records[record.key] = record
            scheduleFlush()
        } else {
            records[record.key] = record
        }
        return record.state
    }

    public func hasOverride(for locator: FolderViewLocator) -> Bool { lookup(locator) != nil }

    public func save(_ state: FolderViewState, for locator: FolderViewLocator) {
        // Without a fileID (identity probe pending), update the object record already indexed at this path rather
        // than adding a duplicate path record next to it.
        var key = locator.primaryKey
        if locator.objectKey == nil, let existing = lookup(locator), case .object = existing.key { key = existing.key }
        dropPathRecord(at: locator.pathKey, keeping: key)   // path → object migration
        if let existing = records[key], existing.pathKey != locator.pathKey, byPath[existing.pathKey] == key {
            byPath[existing.pathKey] = nil
        }
        records[key] = Record(key: key, pathKey: locator.pathKey, state: state, lastUsed: now())
        byPath[locator.pathKey] = key
        evictIfNeeded()
        scheduleFlush()
    }

    /// "Apply to All Folders": every folder follows the defaults again. Writes now.
    public func removeAll() {
        records.removeAll()
        byPath.removeAll()
        flush()
    }

    /// Writes now, synchronously (`applicationWillTerminate`, `removeAll`). Supersedes any encode in flight.
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        writeGeneration += 1
        storage.set(Self.encode(Array(records.values)), forKey: Self.storageKey)
    }

    // MARK: persisted form

    /// Line-based UTF-8 text, most recently used record first (JSONDecoder took ~65 ms for a full store):
    ///
    ///     macx-folder-views<TAB>2
    ///     C<TAB><id>:<width>:<0|1>,…                       one per distinct column list, referenced by order
    ///     R<TAB><uuid><TAB><fileID><TAB><mode><TAB><sortField><TAB><0|1 ascending><TAB><iconSize><TAB><groupBy>
    ///      <TAB><0|1 sizes><TAB><column list index><TAB><lastUsed seconds since 2001><TAB><path key, escaped>
    ///
    /// uuid and fileID are empty for a path record (its key is its path key). In the path, `\`, tab, newline and
    /// carriage return are escaped as `\\`, `\t`, `\n`, `\r`. Pure; debounced writes run it off main.
    nonisolated static let formatHeader = "macx-folder-views\t2"

    nonisolated static func encode(_ records: [Record]) -> Data? {
        var columnIndex: [[ColumnSetting]: Int] = [:]
        var columnLines = ""
        var recordLines = ""
        recordLines.reserveCapacity(records.count * 120)
        for r in records.sorted(by: { $0.lastUsed > $1.lastUsed }) {
            let c: Int
            if let i = columnIndex[r.state.columns] { c = i } else {
                c = columnIndex.count
                columnIndex[r.state.columns] = c
                columnLines += "C\t" + r.state.columns.map { "\($0.id.rawValue):\($0.width):\($0.visible ? 1 : 0)" }
                    .joined(separator: ",") + "\n"
            }
            var uuid = "", fileID = ""
            if case .object(let u, let f) = r.key { uuid = u; fileID = String(f) }
            guard case .path(let path) = r.pathKey else { continue }
            let s = r.state
            recordLines += "R\t\(uuid)\t\(fileID)\t\(s.mode.rawValue)\t\(s.sort.field.rawValue)\t\(s.sort.ascending ? 1 : 0)"
            recordLines += "\t\(s.iconSize.rawValue)\t\(s.groupBy.rawValue)\t\(s.calculateFolderSizes ? 1 : 0)\t\(c)"
            recordLines += "\t\(r.lastUsed.timeIntervalSinceReferenceDate)\t\(escape(path))\n"
        }
        return Data((formatHeader + "\n" + columnLines + recordLines).utf8)
    }

    nonisolated private static func encodeReportingThread(_ records: [Record]) -> (Data?, Bool) {
        (encode(records), Thread.isMainThread)
    }

    /// nil when the bytes are not a valid store (treated as empty). Parses the bytes in place (no per-line or
    /// per-field arrays): a full store with a distinct column list per record decodes in a few ms (release).
    nonisolated static func decode(_ data: Data) -> [Record]? {
        data.withUnsafeBytes { raw -> [Record]? in
            var p = Parser(bytes: raw.bindMemory(to: UInt8.self))
            guard p.text(until: .newline) == formatHeader, p.end(.newline) else { return nil }
            var columns: [[ColumnSetting]] = []
            var out: [Record] = []
            while !p.atEnd {
                guard let tag = p.byte(), p.end(.tab) else { return nil }
                switch tag {
                case UInt8(ascii: "C"):
                    var list: [ColumnSetting] = []
                    list.reserveCapacity(ColumnID.allCases.count)
                    if !p.end(.newline) {           // an empty list is "C<TAB>"
                        repeat {
                            guard let id = p.text(until: .colon).flatMap(ColumnID.init(rawValue:)), p.end(.colon),
                                  let width = p.text(until: .colon).flatMap(Double.init), p.end(.colon),
                                  let visible = p.flag() else { return nil }
                            list.append(ColumnSetting(id: id, width: width, visible: visible))
                        } while p.end(.comma)
                        guard p.end(.newline) else { return nil }
                    }
                    columns.append(list)
                case UInt8(ascii: "R"):
                    guard let uuid = p.text(until: .tab), p.end(.tab),
                          let fileID = p.text(until: .tab), p.end(.tab),
                          let mode = p.text(until: .tab).flatMap(ViewMode.init(rawValue:)), p.end(.tab),
                          let field = p.text(until: .tab).flatMap(SortField.init(rawValue:)), p.end(.tab),
                          let ascending = p.flag(), p.end(.tab),
                          let icon = p.text(until: .tab).flatMap(IconSize.init(rawValue:)), p.end(.tab),
                          let group = p.text(until: .tab).flatMap(GroupBy.init(rawValue:)), p.end(.tab),
                          let sizes = p.flag(), p.end(.tab),
                          let c = p.text(until: .tab).flatMap({ Int($0) }), columns.indices.contains(c), p.end(.tab),
                          let t = p.text(until: .tab).flatMap(Double.init), p.end(.tab),
                          let path = p.text(until: .newline).flatMap(unescape), p.end(.newline) else { return nil }
                    let key: FolderViewKey
                    switch (uuid.isEmpty, fileID.isEmpty) {
                    case (true, true): key = .path(path)
                    case (false, false):
                        guard let id = UInt64(fileID) else { return nil }
                        key = .object(volumeUUID: uuid, fileID: id)
                    default: return nil
                    }
                    let state = FolderViewState(mode: mode, columns: columns[c],
                                                sort: MacxFS.SortDescriptor(field: field, ascending: ascending),
                                                iconSize: icon, groupBy: group, calculateFolderSizes: sizes)
                    out.append(Record(key: key, pathKey: .path(path), state: state,
                                      lastUsed: Date(timeIntervalSinceReferenceDate: t)))
                default:
                    return nil
                }
            }
            return out
        }
    }

    /// Byte cursor for `decode`.
    private struct Parser {
        enum Delimiter: UInt8 {
            case newline = 0x0A, tab = 0x09, colon = 0x3A, comma = 0x2C
        }
        let bytes: UnsafeBufferPointer<UInt8>
        var i = 0
        var atEnd: Bool { i >= bytes.count }

        mutating func byte() -> UInt8? {
            guard i < bytes.count else { return nil }
            defer { i += 1 }
            return bytes[i]
        }

        /// Consumes `d` if it is next (or, for newline, at the end of the data).
        mutating func end(_ d: Delimiter) -> Bool {
            if i < bytes.count, bytes[i] == d.rawValue { i += 1; return true }
            return d == .newline && i >= bytes.count
        }

        /// The text up to (not including) `d`, a newline, or the end; nil if it is not valid UTF-8.
        mutating func text(until d: Delimiter) -> String? {
            let start = i
            while i < bytes.count, bytes[i] != d.rawValue, bytes[i] != Delimiter.newline.rawValue { i += 1 }
            return String(validating: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
        }

        mutating func flag() -> Bool? {
            switch byte() {
            case UInt8(ascii: "0"): false
            case UInt8(ascii: "1"): true
            default: nil
            }
        }
    }

    /// By Unicode scalar: "\r\n" is one Character, so a Character-level scan would miss it.
    nonisolated private static func escape(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u {
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            default: out.append(u)
            }
        }
        return String(out)
    }

    nonisolated private static func unescape(_ s: String) -> String? {
        guard s.unicodeScalars.contains("\\") else { return s }
        var out = String.UnicodeScalarView()
        var pending = false
        for u in s.unicodeScalars {
            if pending {
                switch u {
                case "\\": out.append("\\")
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                default: return nil
                }
                pending = false
            } else if u == "\\" {
                pending = true
            } else {
                out.append(u)
            }
        }
        return pending ? nil : String(out)
    }

    // MARK: private

    private func lookup(_ l: FolderViewLocator) -> Record? {
        if let k = l.objectKey, let r = records[k] { return r }
        guard let k = byPath[l.pathKey], let r = records[k] else { return nil }
        if case .object(_, let id) = r.key {
            // A different folder now lives at the record's last known path.
            if let fileID = l.fileID, fileID != id { return nil }
            if let mine = l.objectKey, mine != r.key { return nil }
        }
        return r
    }

    /// A path-keyed record at `pathKey` other than `key` is superseded (the folder there now has its own record).
    private func dropPathRecord(at pathKey: FolderViewKey, keeping key: FolderViewKey) {
        guard let old = byPath[pathKey], old != key, case .path = old else { return }
        records[old] = nil
        byPath[pathKey] = nil
    }

    private func evictIfNeeded() {
        let excess = records.count - Self.capacity
        guard excess > 0 else { return }
        let victims: [Record]
        if excess == 1 {
            victims = records.values.min { $0.lastUsed < $1.lastUsed }.map { [$0] } ?? []
        } else {
            victims = Array(records.values.sorted { $0.lastUsed < $1.lastUsed }.prefix(excess))
        }
        for v in victims {
            records[v.key] = nil
            if byPath[v.pathKey] == v.key { byPath[v.pathKey] = nil }
        }
    }

    /// Debounced write: snapshot on main, sort + encode off main, `storage.set` on main unless superseded.
    private func scheduleFlush() {
        flushTask?.cancel()
        let delay = flushDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.writeGeneration += 1
            let generation = self.writeGeneration
            let snapshot = Array(self.records.values)
            let (data, onMain) = await Task.detached(priority: .utility) { Self.encodeReportingThread(snapshot) }.value
            guard !Task.isCancelled, generation == self.writeGeneration else { return }
            self.flushTask = nil
            self.backgroundEncodeCount += 1
            self.lastEncodeWasOnMain = onMain
            self.storage.set(data, forKey: Self.storageKey)
        }
    }
}
