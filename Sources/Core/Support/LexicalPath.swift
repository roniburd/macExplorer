import Foundation

/// Pure string path normalization for in-memory comparisons (§5.6 clipboard and drop validation). No file-system calls.
enum LexicalPath {
    /// Removes "." / ".." / duplicate and trailing slashes, and drops a leading "/private" before var, tmp or etc,
    /// so /private/var/… and /var/… compare equal (the same rule as MountTable).
    static func standardize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast(); continue }
            parts.append(c)
        }
        if parts.count >= 2, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        return "/" + parts.joined(separator: "/")
    }

    static func standardize(_ url: URL) -> String { standardize(url.path(percentEncoded: false)) }

    /// Parent of a standardized path ("/" for top-level items and for "/" itself).
    static func parent(of standardized: String) -> String {
        guard let slash = standardized.utf8.lastIndex(of: UInt8(ascii: "/")), slash != standardized.utf8.startIndex else {
            return "/"
        }
        return String(standardized[..<slash])
    }

    /// Byte-wise equality. Swift's String == folds canonically equivalent (NFC/NFD) spellings, which are distinct names on disk.
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// True when `path` is `ancestor` or lies inside it, comparing bytes component-wise. Both must be standardized.
    static func isSelfOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        let p = path.utf8, a = ancestor.utf8
        guard p.starts(with: a) else { return false }
        let rest = p.dropFirst(a.count)
        return rest.isEmpty || rest.first == UInt8(ascii: "/")
    }
}
