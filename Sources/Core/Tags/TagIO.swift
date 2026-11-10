import Foundation
import Darwin
import MacxFS

public struct TagIOError: Error, Sendable, Equatable {
    public var code: Int32
    public init(code: Int32) { self.code = code }
}

/// Finder-compatible tag storage: the `com.apple.metadata:_kMDItemUserTags` xattr, a binary plist array of
/// `"<name>\n<colour digit>"` (or just `"<name>"` for no colour). Never touches `com.apple.FinderInfo`.
/// Every xattr call uses XATTR_NOFOLLOW, so a symlink's own tags are read and written (as Finder does).
public enum TagIO {
    public static let xattrName = FinderMetadata.tagsXattr

    /// Pure. Non-string elements are dropped; an unknown colour digit decodes as `.none`.
    public static func decode(_ data: Data) -> [FileTag] {
        guard let array = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any] else { return [] }
        return array.compactMap { element -> FileTag? in
            guard let s = element as? String else { return nil }
            guard let nl = s.lastIndex(of: "\n") else { return s.isEmpty ? nil : FileTag(name: s) }
            let name = String(s[..<nl])
            guard !name.isEmpty else { return nil }
            let digit = Int(s[s.index(after: nl)...]) ?? 0
            return FileTag(name: name, color: TagColor(rawValue: digit) ?? .none)
        }
    }

    public static func encode(_ tags: [FileTag]) throws -> Data {
        let strings = tags.map { $0.color == .none ? $0.name : "\($0.name)\n\($0.color.rawValue)" }
        return try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
    }

    /// Trims whitespace and newlines, drops empty names and case-insensitive duplicates (the first wins).
    public static func normalize(_ tags: [FileTag]) -> [FileTag] {
        var seen = Set<String>()
        var out: [FileTag] = []
        for t in tags {
            let name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(FileTag(name: name, color: t.color))
        }
        return out
    }

    /// Lane only. No xattr (ENOATTR) → []; any other failure (ENOENT, EACCES, …) throws.
    public static func read(_ url: URL) throws(TagIOError) -> [FileTag] {
        assertOffMain()
        let path = url.path(percentEncoded: false)
        while true {
            let size = getxattr(path, xattrName, nil, 0, 0, XATTR_NOFOLLOW)
            if size < 0 {
                if errno == ENOATTR { return [] }
                throw TagIOError(code: errno)
            }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, xattrName, &buffer, size, 0, XATTR_NOFOLLOW)
            if read < 0 {
                if errno == ERANGE { continue }               // grew between the two calls
                if errno == ENOATTR { return [] }             // removed between the two calls
                throw TagIOError(code: errno)
            }
            return decode(Data(buffer.prefix(read)))
        }
    }

    /// Lane only. Writes `normalize(tags)`; an empty list removes the xattr (removing twice is fine).
    public static func write(_ tags: [FileTag], to url: URL) throws(TagIOError) {
        assertOffMain()
        let path = url.path(percentEncoded: false)
        let normalized = normalize(tags)
        if normalized.isEmpty {
            if removexattr(path, xattrName, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw TagIOError(code: errno) }
            return
        }
        guard let data = try? encode(normalized) else { throw TagIOError(code: EINVAL) }
        let rc = data.withUnsafeBytes { setxattr(path, xattrName, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if rc != 0 { throw TagIOError(code: errno) }
    }
}
