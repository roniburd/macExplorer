import Foundation
import MacxFS

/// Persisted per-folder view state (spec §11 Phase 2). Lookup: object key, then the path index (each record's last
/// known path), then `defaults()`. Records are created only by `save`, so untouched folders follow the defaults
/// ("Apply to All Folders" changes the defaults and calls `removeAll`). At most `capacity` records; the least
/// recently used are evicted. Writes are debounced by `flushDelay`; `flush()` writes now. No file-system calls:
/// `storage` holds the bytes (`FileSettingsStorage` does its own I/O off main).
@MainActor
public final class FolderViewStore {
    public static let storageKey = "folderViews.v1"
    public static let capacity = 5_000

    struct Record: Codable, Equatable {
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

    public init(storage: any SettingsStorage, defaults: @escaping @MainActor () -> FolderViewState,
                now: @escaping @MainActor () -> Date = { Date() }, flushDelay: Duration = .seconds(1)) {
        self.storage = storage
        self.defaults = defaults
        self.now = now
        self.flushDelay = flushDelay
        if let data = storage.data(forKey: Self.storageKey),
           let list = try? JSONDecoder().decode([Record].self, from: data) {
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

    /// Writes now (also called from `applicationWillTerminate`).
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        let list = records.values.sorted { $0.lastUsed > $1.lastUsed }
        storage.set(try? JSONEncoder().encode(list), forKey: Self.storageKey)
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

    private func scheduleFlush() {
        flushTask?.cancel()
        let delay = flushDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
