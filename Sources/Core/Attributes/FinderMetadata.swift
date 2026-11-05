import Foundation

/// Finder's metadata xattrs: names, parsers and (for fixtures and tests) encoders. Pure.
public enum FinderMetadata {
    public static let tagsXattr = "com.apple.metadata:_kMDItemUserTags"
    public static let commentXattr = "com.apple.metadata:kMDItemFinderComment"
    public static let lastUsedXattr = "com.apple.lastuseddate#PS"

    /// Binary plist `[String]`, each "Name\n<colour index>" or "Name". Anything else → [].
    public static func parseTags(_ data: Data) -> [String] {
        guard let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return [] }
        return list.compactMap { raw in
            let name = raw.firstIndex(of: "\n").map { String(raw[..<$0]) } ?? raw
            return name.isEmpty ? nil : name
        }
    }

    /// Binary plist string, else the raw bytes as UTF-8; nil when neither.
    public static func parseComment(_ data: Data) -> String? {
        if let s = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? String { return s }
        return String(data: data, encoding: .utf8)
    }

    /// 16 bytes: tv_sec, tv_nsec (Int64, little endian). Short data, sec ≤ 0 or nsec out of range → nil.
    public static func parseLastUsed(_ data: Data) -> Date? {
        guard data.count >= 16 else { return nil }
        let (sec, nsec) = data.withUnsafeBytes { raw in
            (Int64(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: Int64.self)),
             Int64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: Int64.self)))
        }
        guard sec > 0, (0..<1_000_000_000).contains(nsec) else { return nil }
        return Date(timeIntervalSince1970: Double(sec) + Double(nsec) / 1e9)
    }

    public static func encodeTags(_ tags: [String]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)) ?? Data()
    }

    public static func encodeComment(_ comment: String) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: comment, format: .binary, options: 0)) ?? Data()
    }

    public static func encodeLastUsed(_ date: Date) -> Data {
        let sec = Int64(date.timeIntervalSince1970.rounded(.down))
        let nsec = Int64(((date.timeIntervalSince1970 - Double(sec)) * 1e9).rounded())
        var d = Data()
        withUnsafeBytes(of: sec.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: min(nsec, 999_999_999).littleEndian) { d.append(contentsOf: $0) }
        return d
    }
}
