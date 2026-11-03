public struct EntryError: Sendable, Equatable {
    public var index: UInt32
    public var code: Int32
    public init(index: UInt32, code: Int32) { self.index = index; self.code = code }
}

/// A Sendable chunk of directory entries with its own name arena (§4.2 streaming).
public struct Batch: Sendable {
    public var generation: Generation
    public var entries: [Entry] = []      // nameOffset relative to `names`
    public var names: [UInt8] = []        // concatenated UTF-8 names
    public var errors: [EntryError] = []  // index into `entries`
    public init(generation: Generation) { self.generation = generation }
    public var count: Int { entries.count }

    public func name(at index: Int) -> String {
        let e = entries[index]
        return names.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[Int(e.nameOffset)..<Int(e.nameOffset) + Int(e.nameLen)]), as: UTF8.self)
        }
    }

    public mutating func append(_ entry: Entry, nameBytes: UnsafeBufferPointer<UInt8>) {
        var e = entry
        e.nameOffset = UInt32(names.count)
        e.nameLen = UInt16(clamping: nameBytes.count)
        names.append(contentsOf: nameBytes.prefix(Int(e.nameLen)))
        entries.append(e)
    }
}
