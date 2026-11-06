/// Struct-of-arrays folder snapshot (§4.2, §4.3 ownership). Value type with copy-on-write arrays: the
/// main-actor FolderModel owns and mutates it; sorting/diffing work on immutable copies off main.
public struct EntryStore: Sendable {
    public let identityMode: IdentityMode
    public private(set) var entries: [Entry] = []      // storage order (append order)
    public private(set) var names = NameArena()
    public private(set) var order: [UInt32] = []       // display permutation: storage indices of visible rows
    public private(set) var version: UInt64 = 0        // incremented by every mutation

    private var rowOfIndex: [Int32] = []               // inverse permutation; -1 = not displayed
    private var identities: [RowID: UInt32] = [:]      // first storage index per identity
    private var errors: [UInt32: Int32] = [:]          // per-entry errno side table
    private var garbageBytes = 0                       // arena bytes no entry references any more

    public init(identityMode: IdentityMode) { self.identityMode = identityMode }

    public var count: Int { entries.count }
    public var visibleCount: Int { order.count }

    // MARK: Storage-index access

    public func entry(_ index: UInt32) -> Entry { entries[Int(index)] }

    public func name(_ index: UInt32) -> String {
        let e = entries[Int(index)]
        return names.string(offset: e.nameOffset, length: e.nameLen)
    }

    public func withNameBytes<R>(_ index: UInt32, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        let e = entries[Int(index)]
        return try names.withBytes(offset: e.nameOffset, length: e.nameLen, body)
    }

    public func identity(_ index: UInt32) -> RowID {
        identity(of: entries[Int(index)], name: name(index))
    }

    public func firstIndex(of id: RowID) -> UInt32? { identities[id] }

    /// O(n). NameNormalizer.sameName semantics; hidden rows (not in `order`) included.
    public func firstIndex(named name: String, caseSensitive: Bool) -> UInt32? {
        let wanted = NameNormalizer.identityName(name, caseSensitive: caseSensitive)
        for i in entries.indices where NameNormalizer.identityName(self.name(UInt32(i)), caseSensitive: caseSensitive) == wanted {
            return UInt32(i)
        }
        return nil
    }

    /// One pass for many names (QA round 1: 10k pasted items must not cost names × entries normalizations):
    /// each given name that is present maps to its first storage index (firstIndex(named:) semantics, hidden rows
    /// included). Stops scanning once every name was found. O(n + names).
    public func firstIndices(named wantedNames: [String], caseSensitive: Bool) -> [String: UInt32] {
        guard !wantedNames.isEmpty else { return [:] }
        var wanted: [String: [String]] = [:]
        for name in wantedNames { wanted[NameNormalizer.identityName(name, caseSensitive: caseSensitive), default: []].append(name) }
        var found: [String: UInt32] = [:]
        for i in entries.indices {
            let key = NameNormalizer.identityName(self.name(UInt32(i)), caseSensitive: caseSensitive)
            guard let originals = wanted.removeValue(forKey: key) else { continue }
            for original in originals { found[original] = UInt32(i) }
            if wanted.isEmpty { break }
        }
        return found
    }

    public func errno(_ index: UInt32) -> Int32? { errors[index] }

    // MARK: Display-row access

    public func storageIndex(forRow row: Int) -> UInt32 { order[row] }

    public func row(ofStorageIndex index: UInt32) -> Int? {
        guard Int(index) < rowOfIndex.count else { return nil }
        let row = rowOfIndex[Int(index)]
        return row < 0 ? nil : Int(row)
    }

    public func row(of id: RowID) -> Int? { firstIndex(of: id).flatMap { row(ofStorageIndex: $0) } }

    // MARK: Mutation

    /// O(batch); leaves `order` unchanged.
    public mutating func append(_ batch: Batch) {
        let base = UInt32(entries.count)
        let arenaBase = UInt32(names.bytes.count)
        _ = names.append(batch.names)
        entries.reserveCapacity(entries.count + batch.count)
        for var e in batch.entries {
            e.nameOffset += arenaBase
            entries.append(e)
            let index = UInt32(entries.count - 1)
            let id = identity(index)
            if identities[id] == nil { identities[id] = index }
        }
        rowOfIndex.append(contentsOf: repeatElement(-1, count: batch.count))
        for error in batch.errors { errors[base + error.index] = error.code }
        version &+= 1
    }

    public mutating func setOrder(_ order: [UInt32]) {
        self.order = order
        rowOfIndex = [Int32](repeating: -1, count: entries.count)
        for (row, index) in order.enumerated() { rowOfIndex[Int(index)] = Int32(row) }
        version &+= 1
    }

    /// Replaces the entry with the same identity (keeping its storage index and row) or appends a new one
    /// (not displayed until the next setOrder). Returns the storage index. The entry comes from a successful
    /// stat, so a replaced entry's errno side-table value is cleared.
    @discardableResult
    public mutating func upsert(_ entry: Entry, name: String) -> UInt32 {
        var e = entry
        let bytes = Array(name.utf8)
        e.nameLen = UInt16(clamping: bytes.count)
        e.nameOffset = names.append(bytes.prefix(Int(e.nameLen)))
        let id = identity(of: e, name: name)
        if let index = identities[id] {
            let old = entries[Int(index)]
            garbageBytes += Int(old.nameLen)
            if identity(of: old, name: self.name(index)) != id { identities[identity(index)] = nil }
            entries[Int(index)] = e
            identities[id] = index
            errors[index] = nil
            version &+= 1
            return index
        }
        entries.append(e)
        rowOfIndex.append(-1)
        let index = UInt32(entries.count - 1)
        identities[id] = index
        version &+= 1
        return index
    }

    /// Compacts storage, remaps `order`, identities and errors. O(n).
    public mutating func remove(_ indices: Set<UInt32>) {
        guard !indices.isEmpty else { return }
        var remap = [Int32](repeating: -1, count: entries.count)
        var kept: [Entry] = []
        kept.reserveCapacity(entries.count - indices.count)
        for (i, e) in entries.enumerated() {
            if indices.contains(UInt32(i)) { garbageBytes += Int(e.nameLen); continue }
            remap[i] = Int32(kept.count)
            kept.append(e)
        }
        entries = kept
        order = order.compactMap { remap[Int($0)] >= 0 ? UInt32(remap[Int($0)]) : nil }
        var newErrors: [UInt32: Int32] = [:]
        for (i, code) in errors where remap[Int(i)] >= 0 { newErrors[UInt32(remap[Int(i)])] = code }
        errors = newErrors
        if garbageBytes > 64 * 1024 && garbageBytes * 2 > names.bytes.count { compactArena() }
        rebuildIdentities()
        setOrder(order)   // rebuilds the inverse permutation; bumps version
    }

    public mutating func setError(_ code: Int32?, at index: UInt32) {
        errors[index] = code
        if code == nil { errors.removeValue(forKey: index) }
        version &+= 1
    }

    /// The identity `entry` named `name` has (or would have) in this store, without looking it up.
    public func identity(of entry: Entry, named name: String) -> RowID { identity(of: entry, name: name) }

    // MARK: Private

    private func identity(of entry: Entry, name: @autoclosure () -> String) -> RowID {
        switch identityMode {
        case .objectID:
            // No file ID (degraded record whose error omitted FILEID): the exact name keeps rows apart.
            if entry.rowID == 0 { return .name(NameNormalizer.identityName(name(), caseSensitive: true)) }
            return .object(entry.rowID)
        case .name(let caseSensitive): return .name(NameNormalizer.identityName(name(), caseSensitive: caseSensitive))
        }
    }

    private mutating func rebuildIdentities() {
        identities.removeAll(keepingCapacity: true)
        for i in entries.indices {
            let id = identity(UInt32(i))
            if identities[id] == nil { identities[id] = UInt32(i) }
        }
    }

    private mutating func compactArena() {
        var fresh = NameArena()
        for i in entries.indices {
            let e = entries[i]
            entries[i].nameOffset = names.withBytes(offset: e.nameOffset, length: e.nameLen) { fresh.append($0) }
        }
        names = fresh
        garbageBytes = 0
    }
}
