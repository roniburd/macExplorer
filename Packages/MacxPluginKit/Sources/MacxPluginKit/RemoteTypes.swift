import Foundation

public enum RemoteItemKind: Sendable, Codable, Hashable { case file, directory, symlink, submodule }

public struct RemoteItem: Sendable, Codable, Hashable {
    public var name: String
    public var kind: RemoteItemKind
    public var size: Int64?          // files only
    public var executable: Bool
    public var contentID: String?    // blob SHA or equivalent; the cache key
    public var modified: Date?
    public init(name: String, kind: RemoteItemKind, size: Int64? = nil, executable: Bool = false,
                contentID: String? = nil, modified: Date? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.executable = executable
        self.contentID = contentID
        self.modified = modified
    }

    /// The trust boundary for provider names: one local path component (non-empty, not "." or "..", no "/" or NUL).
    /// The app skips items whose name fails this before listing them or writing them to disk.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

public struct RemoteRef: Sendable, Codable, Hashable {
    public enum Kind: Sendable, Codable, Hashable { case branch, tag, commit }
    public var name: String
    public var kind: Kind
    public var commit: String?
    public init(name: String, kind: Kind, commit: String? = nil) { self.name = name; self.kind = kind; self.commit = commit }
}

public enum RemoteError: Error, Sendable, Equatable {
    case notFound, noAccess, rateLimited(resetAt: Date?), network(String), unsupported
}
