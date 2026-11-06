import Foundation

/// A value stored in a `.DS_Store` record.
public enum DSValue: Equatable, Sendable {
    case bool(Bool)
    case long(UInt32)
    case short(UInt16)
    case type(String)          // four-character code
    case blob(Data)
    case ustr(String)
    case comp(UInt64)
    case dutc(UInt64)
}

/// Read-only parser of Finder's `.DS_Store` files (design 2026-11-05 §3): the reverse-engineered "Bud1" buddy-allocator
/// file holding a B-tree ("DSDB") of (filename, structure code) → value records. Every read is bounds-checked and
/// the tree walk is depth-limited and cycle-checked; any inconsistency yields nil ("no Finder data"). Never writes.
public enum DSStore {
    public static let maxFileSize = 1 << 20
    static let maxDepth = 32
    static let maxRecords = 100_000

    /// filename → structure code → value. Nil for anything that is not a well-formed `.DS_Store`.
    public static func parse(_ data: Data) -> [String: [String: DSValue]]? {
        guard data.count <= maxFileSize else { return nil }
        var parser = Parser(bytes: [UInt8](data))
        return parser.parse()
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos: Int
        let end: Int

        init(_ bytes: [UInt8], start: Int, end: Int) {
            self.bytes = bytes
            self.pos = start
            self.end = min(end, bytes.count)
        }

        mutating func u8() -> UInt8? {
            guard pos >= 0, pos + 1 <= end else { return nil }
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func u16() -> UInt16? {
            guard pos >= 0, pos + 2 <= end else { return nil }
            defer { pos += 2 }
            return UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])
        }

        mutating func u32() -> UInt32? {
            guard pos >= 0, pos + 4 <= end else { return nil }
            defer { pos += 4 }
            return UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16 | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3])
        }

        mutating func u64() -> UInt64? {
            guard let hi = u32(), let lo = u32() else { return nil }
            return UInt64(hi) << 32 | UInt64(lo)
        }

        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, pos >= 0, pos + count <= end else { return nil }
            defer { pos += count }
            return bytes[pos..<(pos + count)]
        }

        mutating func fourCC() -> String? {
            guard let raw = take(4) else { return nil }
            return String(bytes: raw, encoding: .macOSRoman)
        }

        mutating func utf16(units: Int) -> String? {
            guard units >= 0, units <= 0x10000, let raw = take(units * 2) else { return nil }
            var chars: [UInt16] = []
            chars.reserveCapacity(units)
            var i = raw.startIndex
            while i < raw.endIndex { chars.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1])); i += 2 }
            return String(utf16CodeUnits: chars, count: chars.count)
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var blocks: [UInt32] = []
        var records: [String: [String: DSValue]] = [:]
        var recordCount = 0
        var visited = Set<UInt32>()

        init(bytes: [UInt8]) { self.bytes = bytes }

        /// Byte range of block `id` (offsets are relative to byte 4 of the file).
        func block(_ id: UInt32) -> Range<Int>? {
            guard Int(id) < blocks.count else { return nil }
            let addr = blocks[Int(id)]
            let shift = Int(addr & 0x1F)
            guard shift >= 5, shift < 31 else { return nil }
            let start = Int(addr & ~UInt32(0x1F)) + 4
            let size = 1 << shift
            guard start >= 4, start < bytes.count else { return nil }
            return start..<min(start + size, bytes.count)
        }

        mutating func parse() -> [String: [String: DSValue]]? {
            var header = Reader(bytes, start: 0, end: 36)
            guard header.u32() == 1, header.fourCC() == "Bud1",
                  let rootOffset = header.u32(), let rootSize = header.u32(), let rootCopy = header.u32(),
                  rootOffset == rootCopy, rootSize >= 8 else { return nil }
            let rootStart = Int(rootOffset) + 4
            var root = Reader(bytes, start: rootStart, end: rootStart + Int(rootSize))
            guard let count = root.u32(), count <= 0x10000, root.u32() != nil else { return nil }
            for _ in 0..<count {
                guard let addr = root.u32() else { return nil }
                blocks.append(addr)
            }
            let padded = (Int(count) + 255) / 256 * 256
            guard root.take((padded - Int(count)) * 4) != nil else { return nil }
            guard let tocCount = root.u32(), tocCount <= 256 else { return nil }
            var dsdb: UInt32?
            for _ in 0..<tocCount {
                guard let length = root.u8(), let name = root.take(Int(length)), let id = root.u32() else { return nil }
                if String(bytes: name, encoding: .macOSRoman) == "DSDB" { dsdb = id }
            }
            guard let dsdb, let master = block(dsdb) else { return nil }
            var m = Reader(bytes, start: master.lowerBound, end: master.upperBound)
            guard let rootNode = m.u32(), let levels = m.u32(), m.u32() != nil, m.u32() != nil,
                  levels <= UInt32(DSStore.maxDepth) else { return nil }
            guard walk(rootNode, depth: 0) else { return nil }
            return records
        }

        mutating func walk(_ node: UInt32, depth: Int) -> Bool {
            guard depth <= DSStore.maxDepth, !visited.contains(node), let range = block(node) else { return false }
            visited.insert(node)
            var r = Reader(bytes, start: range.lowerBound, end: range.upperBound)
            guard let rightmost = r.u32(), let count = r.u32(), count <= UInt32(DSStore.maxRecords) else { return false }
            for _ in 0..<count {
                if rightmost != 0 {
                    guard let child = r.u32(), walk(child, depth: depth + 1) else { return false }
                }
                guard readRecord(&r) else { return false }
            }
            if rightmost != 0 { return walk(rightmost, depth: depth + 1) }
            return true
        }

        mutating func readRecord(_ r: inout Reader) -> Bool {
            recordCount += 1
            guard recordCount <= DSStore.maxRecords,
                  let nameLength = r.u32(), let name = r.utf16(units: Int(nameLength)),
                  let code = r.fourCC(), let type = r.fourCC() else { return false }
            let value: DSValue
            switch type {
            case "bool": guard let v = r.u8() else { return false }; value = .bool(v != 0)
            case "long": guard let v = r.u32() else { return false }; value = .long(v)
            case "shor": guard let v = r.u32() else { return false }; value = .short(UInt16(truncatingIfNeeded: v))
            case "type": guard let v = r.fourCC() else { return false }; value = .type(v)
            case "blob":
                guard let length = r.u32(), let raw = r.take(Int(length)) else { return false }
                value = .blob(Data(raw))
            case "ustr":
                guard let length = r.u32(), let text = r.utf16(units: Int(length)) else { return false }
                value = .ustr(text)
            case "comp": guard let v = r.u64() else { return false }; value = .comp(v)
            case "dutc": guard let v = r.u64() else { return false }; value = .dutc(v)
            default: return false     // unknown types have unknown sizes: the rest of the node can't be read
            }
            records[name, default: [:]][code] = value
            return true
        }
    }
}
