import CoreServices
import Darwin
import Foundation

/// Extended attributes, quarantine and "Where from" (§4.3 Properties). Synchronous; lane only, under
/// `withNoMaterialization`. Never follows a symlink (`XATTR_NOFOLLOW`).
public enum Xattrs {
    public static let quarantineName = "com.apple.quarantine"
    public static let whereFromsName = "com.apple.metadata:kMDItemWhereFroms"

    /// Names and sizes, sorted by name. Empty when the item has none or cannot be read.
    public static func list(_ path: String) -> [XattrInfo] {
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        let read = listxattr(path, &buffer, length, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        let names = buffer[..<read].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return names.sorted().map { name in
            XattrInfo(name: name, size: max(0, getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)))
        }
    }

    /// The value of one attribute, or nil when it is absent or unreadable.
    public static func read(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        guard size > 0 else { return Data() }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read >= 0 else { return nil }
        return data.prefix(read)
    }

    public static func quarantine(_ path: String) -> QuarantineInfo? {
        read(path, quarantineName).map(parseQuarantine)
    }

    /// "flags;hex date;agent;uuid". Unparseable parts become nil; `raw` is always the bytes on disk.
    public static func parseQuarantine(_ raw: Data) -> QuarantineInfo {
        let fields = String(decoding: raw, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        let date = fields.count > 1 ? UInt64(fields[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        let agent = fields.count > 2 && !fields[2].isEmpty ? String(fields[2]) : nil
        return QuarantineInfo(raw: raw, agentName: agent, date: date)
    }

    /// `kMDItemWhereFroms`: the metadata xattr first (present even where Spotlight does not index), then `MDItem`.
    public static func whereFroms(_ path: String) -> [String] {
        if let data = read(path, whereFromsName) {
            let decoded = decodeWhereFroms(data)
            if !decoded.isEmpty { return decoded }
        }
        return (spotlightValue(path, kMDItemWhereFroms) as? [String]) ?? []
    }

    static func decodeWhereFroms(_ data: Data) -> [String] {
        let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
        if let strings = value as? [String] { return strings }
        if let string = value as? String { return [string] }
        return []
    }

    /// `kMDItemLastUsedDate` (Finder's "Last opened"), nil when Spotlight does not know it.
    static func lastUsedDate(_ path: String) -> Date? {
        spotlightValue(path, kMDItemLastUsedDate) as? Date
    }

    private static func spotlightValue(_ path: String, _ key: CFString) -> Any? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, key)
    }
}
