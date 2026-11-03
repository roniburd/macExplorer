/// Concatenated UTF-8 names. Strings are made only for visible cells and operations (§4.2).
public struct NameArena: Sendable {
    public init() {}
    public private(set) var bytes: [UInt8] = []

    public mutating func append(_ bytes: some Collection<UInt8>) -> UInt32 {
        let offset = UInt32(self.bytes.count)
        self.bytes.append(contentsOf: bytes)
        return offset
    }

    public func string(offset: UInt32, length: UInt16) -> String {
        withBytes(offset: offset, length: length) { String(decoding: $0, as: UTF8.self) }
    }

    public func withBytes<R>(offset: UInt32, length: UInt16, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { all in
            try body(UnsafeBufferPointer(rebasing: all[Int(offset)..<Int(offset) + Int(length)]))
        }
    }

    mutating func removeAll(keepingCapacity: Bool) { bytes.removeAll(keepingCapacity: keepingCapacity) }
}

/// Byte range of the file extension in a UTF-8 name: after the last ".", which is neither the first nor
/// the last byte (".bashrc" and "name." have no extension).
func fileExtensionRange(_ name: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
    guard name.count > 2, let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < name.count - 1 else { return nil }
    return (dot + 1)..<name.count
}
