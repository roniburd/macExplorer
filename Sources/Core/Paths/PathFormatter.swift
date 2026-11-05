import Foundation

/// The "Copy Path As ▸" variants (spec §11 Phase 2). Copy as Path (⇧⌘C) is `.posix`.
public enum PathStyle: String, Sendable, Codable, CaseIterable { case posix, tilde, fileURL, name, shellQuoted }

/// One item to format: its POSIX path text and whether it is a folder (or package), which only the file URL style
/// shows (trailing "/"). Build items for folder rows with `init(directory:name:isDirectory:)` from the row's raw name
/// (FolderModel.name(atRow:)): `init(url:)` goes through URL.path, which on Darwin decomposes precomposed characters
/// ("é" -> "e" + U+0301), so it is only for targets that exist as URLs alone (the folder itself, favorites, volumes).
public struct PathItem: Sendable, Equatable {
    /// POSIX path (no trailing slash, "/" stays "/"), "." and ".." resolved lexically.
    public var path: String
    public var isDirectory: Bool
    public init(path: String, isDirectory: Bool) {
        self.path = PathFormatter.lexicalPOSIX(path)
        self.isDirectory = isDirectory
    }
    public init(url: URL, isDirectory: Bool) {
        self.init(path: url.absoluteURL.path(percentEncoded: false), isDirectory: isDirectory)
    }
    /// `name` exactly as the file system returned it (no normalization); only `directory` goes through URL.path.
    public init(directory: URL, name: String, isDirectory: Bool) {
        let parent = PathFormatter.lexicalPOSIX(directory.absoluteURL.path(percentEncoded: false))
        self.path = (parent == "/" ? "" : parent) + "/" + name
        self.isDirectory = isDirectory
    }
}

/// Pure path text for the pasteboard. No Unicode normalization of its own: an item's path text is kept as given
/// (see PathItem for which initializer keeps on-disk names verbatim).
public enum PathFormatter {
    /// One line per item; shell-quoted items are joined with spaces so the result pastes as one argument list.
    public static func format(_ items: [PathItem], style: PathStyle, home: URL) -> String {
        items.map { one($0, style: style, home: home) }.joined(separator: style == .shellQuoted ? " " : "\n")
    }

    public static func one(_ item: PathItem, style: PathStyle, home: URL) -> String {
        let path = item.path
        switch style {
        case .posix: return path
        case .tilde: return tilde(path, home: posixPath(home))
        case .fileURL: return fileURL(path, isDirectory: item.isDirectory)
        case .name: return path == "/" ? "/" : String(path.split(separator: "/").last ?? "/")
        case .shellQuoted: return shellQuote(path)
        }
    }

    /// "file://" + the percent-encoded path (+ "/" for a folder). Built by hand so the path string's own UTF-8 bytes
    /// are encoded: URL(filePath:).absoluteString re-derives the file-system representation, which would decompose a
    /// precomposed "é" in a raw-name item. Space, "#", "?" and "%" are encoded; "'" and the other RFC 3986 path characters stay.
    public static func fileURL(_ path: String, isDirectory: Bool) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? path
        return "file://" + encoded + (isDirectory && path != "/" ? "/" : "")
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~!$&'()*+,;=:@/")
        return set
    }()

    /// "~" replaces Home only on a whole-component match ("/Users/roni2" is not inside "/Users/roni").
    public static func tilde(_ path: String, home: String) -> String {
        guard home != "/", !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// POSIX single quotes; an embedded ' becomes '\'' . Nothing inside single quotes is expanded by sh/zsh/bash.
    public static func shellQuote(_ path: String) -> String {
        "'" + path.replacing("'", with: #"'\''"#) + "'"
    }

    /// POSIX path without a trailing slash ("/" stays "/"), with "." and ".." resolved lexically. Purely lexical:
    /// URL.standardizedFileURL may stat the path (to drop "/private"), which must not run on the main thread, and
    /// the user's spelling of the folder (/private/var vs /var) is kept. Note: URL.path decomposes (NFD) on Darwin.
    static func posixPath(_ url: URL) -> String { lexicalPOSIX(url.absoluteURL.path(percentEncoded: false)) }

    /// `posixPath` for a path string, without going through URL (so its characters are kept as they are).
    static func lexicalPOSIX(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { _ = parts.popLast(); continue }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }
}
