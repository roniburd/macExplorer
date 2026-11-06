import Foundation
import MacxFS

/// MacExplorer's own per-folder view choices: the first level of the resolution chain (design 2026-11-05 §2; the
/// rest is Finder's `.DS_Store`, the built-in rule and the global defaults, see `FolderViewResolver`). Each record
/// holds only the fields the user changed in that folder (`FolderViewSettings`), so the other fields keep following
/// Finder and the defaults.
///
/// Keys (spec §11 Phase 2, P2-07): volume UUID + fileID on `idStable` volumes (a renamed or moved folder keeps its
/// view), the normalized path elsewhere and while the identity probe is pending. Lookup: object key, then the path
/// index (each record's last known path). Records are created only by `update`/`save`. At most `capacity` records;
/// the least recently used are evicted. Writes are debounced by `flushDelay`; `flush()` writes now. No file-system
/// calls: `storage` holds the bytes (`FileSettingsStorage` does its own I/O off main); the one-time import of the
/// previous path-keyed JSON file (`legacyJSON`) reads through the closure the caller passes.
///
/// §4.4 (review fix): the debounced write snapshots `records` on main, sorts and encodes on a background task, and
/// only hands the bytes to `storage` on main; a newer write supersedes an encode still in flight. The persisted form
/// (`encode`/`decode`) is compact line-based text with each distinct column list stored once and referenced by
/// index: a full store is under 1.4 MB even with a distinct column list per record, and loads at launch in about
/// 15 ms in release. Budgets: `macx-bench --metrics folderViews`.
///
/// Finder's `.DS_Store` views are cached here too (`finderView`/`setFinderView`): in memory, read once per launch
/// per folder, never persisted.
@MainActor
public final class FolderViewStore {
    public static let storageKey = "folderViews.v3"
    /// Earlier formats, read once and removed: v2 (full records, Phase 2 development builds) is imported; v1 (the
    /// verbose P2-07 format) was never released and is dropped.
    static let v2StorageKey = "folderViews.v2"
    static let legacyStorageKey = "folderViews.v1"
    public static let capacity = 5_000

    struct Record: Sendable, Equatable {
        var key: FolderViewKey
        var pathKey: FolderViewKey
        var settings: FolderViewSettings
        var lastUsed: Date
    }

    private let storage: any SettingsStorage
    private let now: @MainActor () -> Date
    private let flushDelay: Duration
    private let limit: Int
    private var records: [FolderViewKey: Record] = [:]
    /// Path key → the key of the record last seen at that path.
    private var byPath: [FolderViewKey: FolderViewKey] = [:]
    /// Finder's view per standardized path, read this launch (empty settings = read, nothing found). Not persisted.
    private var finderViews: [String: FolderViewSettings] = [:]
    private var flushTask: Task<Void, Never>?
    /// Bumped by every write; an encode started for an older generation is dropped.
    private var writeGeneration = 0
    /// Test inspection.
    private(set) var backgroundEncodeCount = 0
    private(set) var lastEncodeWasOnMain = false

    /// `legacyJSON` returns the bytes of the earlier path-keyed `folder-views.json` (design 2026-11-05 §2); it is
    /// called only while `storage` holds no store yet, and the file itself is left in place.
    public init(storage: any SettingsStorage, legacyJSON: () -> Data? = { nil },
                now: @escaping @MainActor () -> Date = { Date() }, flushDelay: Duration = .seconds(1),
                capacity: Int = FolderViewStore.capacity) {
        self.storage = storage
        self.now = now
        self.flushDelay = flushDelay
        self.limit = capacity
        if storage.data(forKey: Self.legacyStorageKey) != nil { storage.set(nil, forKey: Self.legacyStorageKey) }
        var imported = false
        if let data = storage.data(forKey: Self.storageKey) {
            load(Self.decode(data) ?? [])
        } else if let data = storage.data(forKey: Self.v2StorageKey) {
            load(Self.decode(data) ?? [])
            storage.set(nil, forKey: Self.v2StorageKey)
            imported = true
        } else if let data = legacyJSON(), let list = Self.decodeLegacyJSON(data) {
            load(list)
            imported = !list.isEmpty
        }
        if imported { scheduleFlush() }
    }

    deinit { flushTask?.cancel() }

    public var count: Int { records.count }

    /// The folder's own settings (nil when it has none). Never creates a record. A hit refreshes its LRU time and,
    /// for an object-keyed record seen under a new path (renamed or moved), moves the path index to the new path.
    public func settings(for locator: FolderViewLocator) -> FolderViewSettings? {
        guard var record = lookup(locator) else { return nil }
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
        return record.settings
    }

    public func hasOverride(for locator: FolderViewLocator) -> Bool { lookup(locator) != nil }

    /// Applies `change` to the folder's own settings (creating the record); an empty result removes it.
    ///
    /// Without a fileID (identity probe pending) this is a path record, even when the path index points at an
    /// object record: that record may be a folder renamed away from this path (review fix), and it must keep its
    /// own view. With an object key, a path record at the same path (an edit made while the probe was pending) is
    /// merged into the object record, newest fields winning, and removed (no duplicate).
    public func update(_ locator: FolderViewLocator, _ change: (inout FolderViewSettings) -> Void) {
        let key = locator.primaryKey
        var settings = records[key]?.settings ?? FolderViewSettings()
        if case .object = key, let old = byPath[locator.pathKey], old != key, case .path = old, let pending = records[old] {
            settings = pending.settings.over(settings)
        }
        change(&settings)
        dropPathRecord(at: locator.pathKey, keeping: key)   // path → object migration
        if let existing = records[key], existing.pathKey != locator.pathKey, byPath[existing.pathKey] == key {
            byPath[existing.pathKey] = nil
        }
        if settings.isEmpty {
            records[key] = nil
            if byPath[locator.pathKey] == key { byPath[locator.pathKey] = nil }
        } else {
            records[key] = Record(key: key, pathKey: locator.pathKey, settings: settings, lastUsed: now())
            byPath[locator.pathKey] = key
            evictIfNeeded()
        }
        scheduleFlush()
    }

    /// Every field of `state` becomes the folder's own (a full record).
    public func save(_ state: FolderViewState, for locator: FolderViewLocator) {
        update(locator) { $0 = state.settings }
    }

    /// The identity probe returned: a pending path record at the folder's path moves to its object key. No-op
    /// when there is none (or the locator has no object key).
    public func adopt(_ locator: FolderViewLocator) {
        guard case .object = locator.primaryKey, let old = byPath[locator.pathKey], case .path = old,
              records[old] != nil else { return }
        update(locator) { _ in }
    }

    /// "Reset View for This Folder": the folder's own record goes (and a pending path record at its path).
    public func remove(_ locator: FolderViewLocator) {
        var removed = false
        if let r = lookup(locator) { drop(r); removed = true }
        if let k = byPath[locator.pathKey], case .path = k, let r = records[k] { drop(r); removed = true }
        if removed { scheduleFlush() }
    }

    /// "Apply to All Folders": every folder follows the chain (Finder, built-in rule, defaults) again. Writes now.
    public func removeAll() {
        records.removeAll()
        byPath.removeAll()
        flush()
    }

    /// Finder's view of `folder` if it was read this launch (empty settings = read, nothing found).
    public func finderView(for folder: URL) -> FolderViewSettings? { finderViews[FolderViewLocator.standardPath(folder)] }

    public func setFinderView(_ view: FolderViewSettings, for folder: URL) {
        if finderViews.count >= limit { finderViews.removeAll(keepingCapacity: true) }
        finderViews[FolderViewLocator.standardPath(folder)] = view
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
    ///     macx-folder-views<TAB>3
    ///     C<TAB><id>:<width>:<0|1>,…                       one per distinct column list, referenced by order
    ///     R<TAB><uuid><TAB><fileID><TAB><mode><TAB><sortField><TAB><0|1 ascending><TAB><iconSize><TAB><density>
    ///      <TAB><groupBy><TAB><0|1 sizes><TAB><column list index><TAB><lastUsed seconds since 2001><TAB><path key>
    ///
    /// A field the folder doesn't set is empty (sort: field and direction both empty). uuid and fileID are empty for
    /// a path record (its key is its path key). In the path, `\`, tab, newline and carriage return are escaped as
    /// `\\`, `\t`, `\n`, `\r`. Version 2 (Phase 2 development builds) has no density field and every other field set.
    /// Pure; debounced writes run it off main.
    nonisolated static let formatHeader = "macx-folder-views\t3"
    nonisolated static let v2FormatHeader = "macx-folder-views\t2"

    nonisolated static func encode(_ records: [Record]) -> Data? {
        var columnIndex: [[ColumnSetting]: Int] = [:]
        var columnLines = ""
        var recordLines = ""
        recordLines.reserveCapacity(records.count * 120)
        for r in records.sorted(by: { $0.lastUsed > $1.lastUsed }) {
            var c = ""
            if let columns = r.settings.columns {
                if let i = columnIndex[columns] { c = String(i) } else {
                    c = String(columnIndex.count)
                    columnIndex[columns] = columnIndex.count
                    columnLines += "C\t" + columns.map { "\($0.id.rawValue):\($0.width):\($0.visible ? 1 : 0)" }
                        .joined(separator: ",") + "\n"
                }
            }
            var uuid = "", fileID = ""
            if case .object(let u, let f) = r.key { uuid = u; fileID = String(f) }
            guard case .path(let path) = r.pathKey else { continue }
            let s = r.settings
            let sortField = s.sort?.field.rawValue ?? "", ascending = s.sort.map { $0.ascending ? "1" : "0" } ?? ""
            let sizes = s.calculateFolderSizes.map { $0 ? "1" : "0" } ?? ""
            recordLines += "R\t\(uuid)\t\(fileID)\t\(s.viewMode?.rawValue ?? "")\t\(sortField)\t\(ascending)"
            recordLines += "\t\(s.iconSize?.rawValue ?? "")\t\(s.density?.rawValue ?? "")\t\(s.groupBy?.rawValue ?? "")"
            recordLines += "\t\(sizes)\t\(c)\t\(r.lastUsed.timeIntervalSinceReferenceDate)\t\(escape(path))\n"
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
            let header = p.text(until: .newline)
            guard header == formatHeader || header == v2FormatHeader, p.end(.newline) else { return nil }
            let v2 = header == v2FormatHeader
            var columns: [[ColumnSetting]] = []
            var out: [Record] = []
            /// An optional field: nil = invalid, .some(nil) = not set.
            func field<T>(_ make: (String) -> T?) -> T?? {
                guard let text = p.text(until: .tab), p.end(.tab) else { return nil }
                if text.isEmpty { return v2 ? nil : .some(nil) }
                guard let value = make(text) else { return nil }
                return .some(value)
            }
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
                          let mode = field(ViewMode.init(rawValue:)),
                          let sortField = field(SortField.init(rawValue:)),
                          let ascending = field(flag),
                          let icon = field(IconSize.init(rawValue:)),
                          let density = v2 ? .some(nil) : field(Density.init(rawValue:)),
                          let group = field(GroupBy.init(rawValue:)),
                          let sizes = field(flag),
                          let c = field({ Int($0) }), c.map(columns.indices.contains) ?? true,
                          (sortField == nil) == (ascending == nil),
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
                    let sort = sortField.flatMap { f in ascending.map { MacxFS.SortDescriptor(field: f, ascending: $0) } }
                    let settings = FolderViewSettings(viewMode: mode, iconSize: icon, density: density, sort: sort,
                                                      columns: c.map { columns[$0] }, groupBy: group,
                                                      calculateFolderSizes: sizes)
                    out.append(Record(key: key, pathKey: .path(path), settings: settings,
                                      lastUsed: Date(timeIntervalSinceReferenceDate: t)))
                default:
                    return nil
                }
            }
            return out
        }
    }

    nonisolated private static func flag(_ text: String) -> Bool? {
        switch text {
        case "0": false
        case "1": true
        default: nil
        }
    }

    /// The earlier path-keyed JSON store (`folder-views.json`, design 2026-11-05 §2): `{"version": 1, "folders":
    /// {"<standardized path>": {"settings": {…}, "lastUsed": <seconds since 1970>}}}`. Paths become path records,
    /// lowercased as on a case-insensitive volume (the volume is unknown at launch); the identity probe moves each to
    /// its object key the first time the folder is opened. nil when the bytes are not that format.
    nonisolated static func decodeLegacyJSON(_ data: Data) -> [Record]? {
        struct Entry: Decodable { var settings: FolderViewSettings; var lastUsed: Double }
        struct File: Decodable { var folders: [String: Entry] }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return file.folders.compactMap { path, entry -> Record? in
            guard path.hasPrefix("/"), !entry.settings.isEmpty else { return nil }
            let key = FolderViewKey.path(NameNormalizer.identityName(path, caseSensitive: false))
            return Record(key: key, pathKey: key, settings: entry.settings,
                          lastUsed: Date(timeIntervalSince1970: entry.lastUsed))
        }.sorted { $0.lastUsed > $1.lastUsed }
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

    /// Stored most recent first: keep the most recent claim on a path, and at most `limit` records.
    private func load(_ list: [Record]) {
        for r in list where records[r.key] == nil {
            guard records.count < limit else { break }
            records[r.key] = r
            if byPath[r.pathKey] == nil { byPath[r.pathKey] = r.key }
        }
    }

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

    private func drop(_ r: Record) {
        records[r.key] = nil
        if byPath[r.pathKey] == r.key { byPath[r.pathKey] = nil }
    }

    /// A path-keyed record at `pathKey` other than `key` is superseded (the folder there now has its own record).
    private func dropPathRecord(at pathKey: FolderViewKey, keeping key: FolderViewKey) {
        guard let old = byPath[pathKey], old != key, case .path = old else { return }
        records[old] = nil
        byPath[pathKey] = nil
    }

    private func evictIfNeeded() {
        let excess = records.count - limit
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
