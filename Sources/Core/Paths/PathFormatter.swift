import Foundation

/// The "Copy Path As ▸" variants (spec §11 Phase 2). Copy as Path (⇧⌘C) is `.posix`.
public enum PathStyle: String, Sendable, Codable, CaseIterable { case posix, tilde, fileURL, name, shellQuoted }

/// One item to format: its URL and whether it is a folder (or package), which only the file URL style shows (trailing "/").
public struct PathItem: Sendable, Equatable {
    public var url: URL
    public var isDirectory: Bool
    public init(url: URL, isDirectory: Bool) { self.url = url; self.isDirectory = isDirectory }
}

/// Pure path text for the pasteboard. Names are kept exactly as the file system gave them (no Unicode normalization).
public enum PathFormatter {
    /// One line per item; shell-quoted items are joined with spaces so the result pastes as one argument list.
    public static func format(_ items: [PathItem], style: PathStyle, home: URL) -> String {
        items.map { one($0, style: style, home: home) }.joined(separator: style == .shellQuoted ? " " : "\n")
    }

    public static func one(_ item: PathItem, style: PathStyle, home: URL) -> String {
        let path = posixPath(item.url)
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
    /// precomposed "é" again. Space, "#", "?" and "%" are encoded; "'" and the other RFC 3986 path characters stay.
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
    /// the user's spelling of the folder (/private/var vs /var) is kept.
    static func posixPath(_ url: URL) -> String {
        let path = url.absoluteURL.path(percentEncoded: false)
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
