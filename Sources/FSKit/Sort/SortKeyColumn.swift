/// Byte keys, one per storage index, in a single arena (no per-key allocation).
public struct SortKeyColumn: Sendable {
    private(set) var bytes: [UInt8] = []
    private(set) var starts: [UInt32] = []
    private(set) var lengths: [UInt32] = []

    public init() {}
    public var count: Int { starts.count }
    /// Byte length of key `index`.
    public func length(_ index: Int) -> Int { Int(lengths[index]) }

    public mutating func append(_ key: UnsafeRawBufferPointer) {
        starts.append(UInt32(bytes.count))
        lengths.append(UInt32(key.count))
        bytes.append(contentsOf: key)
    }

    mutating func append(_ key: [UInt8]) { key.withUnsafeBytes { append($0) } }

    mutating func reserve(keys: Int, bytes byteCount: Int) {
        starts.reserveCapacity(keys)
        lengths.reserveCapacity(keys)
        bytes.reserveCapacity(byteCount)
    }

    public mutating func append(contentsOf other: SortKeyColumn) {
        let base = UInt32(bytes.count)
        bytes.append(contentsOf: other.bytes)
        starts.append(contentsOf: other.starts.map { $0 + base })
        lengths.append(contentsOf: other.lengths)
    }

    public func withKey<R>(_ index: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes { raw in
            try body(UnsafeRawBufferPointer(rebasing: raw[Int(starts[index])..<Int(starts[index]) + Int(lengths[index])]))
        }
    }

    /// Mirrors EntryStore.remove compaction (indices are storage indices before removal).
    public mutating func remove(_ indices: Set<UInt32>) {
        guard !indices.isEmpty else { return }
        var fresh = SortKeyColumn()
        bytes.withUnsafeBytes { raw in
            for i in 0..<count where !indices.contains(UInt32(i)) {
                fresh.append(UnsafeRawBufferPointer(rebasing: raw[Int(starts[i])..<Int(starts[i]) + Int(lengths[i])]))
            }
        }
        self = fresh
    }

    /// Replaces key `index` (old bytes stay in the arena until the next remove).
    public mutating func replace(_ index: Int, with key: [UInt8]) {
        starts[index] = UInt32(bytes.count)
        lengths[index] = UInt32(key.count)
        bytes.append(contentsOf: key)
    }

    /// Unsafe fast access for Sorter: calls body with (arena, starts, lengths).
    func withStorage<R>(_ body: (UnsafeRawBufferPointer, UnsafeBufferPointer<UInt32>, UnsafeBufferPointer<UInt32>) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes { b in
            try starts.withUnsafeBufferPointer { s in try lengths.withUnsafeBufferPointer { l in try body(b, s, l) } }
        }
    }
}
