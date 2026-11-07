import Foundation
import MacxFS

public struct CrawlOptions: Sendable, Hashable {
    public var includePackages: Bool = false
    public var includeHidden: Bool = false
    public var maxResults: Int = 100_000
    public var maxConcurrentReads: Int = 2
    public var progressInterval: Duration = .milliseconds(100)
    public init() {}
}

/// Folders the crawler must not open (TCC-protected without a recorded grant). Paths are standardized, no trailing "/".
public struct CrawlPermissions: Sendable, Hashable {
    public var blockedPrefixes: [String]
    public init(blockedPrefixes: [String]) { self.blockedPrefixes = blockedPrefixes.map(Self.trim) }
    public static let none = CrawlPermissions(blockedPrefixes: [])

    /// Prefixes strictly below `root` (the user is already looking inside the root). Comparisons use
    /// `MountTable.standardize`, so "/private/var/…" and "/var/…" spellings match; the kept prefixes are unchanged.
    public func relevant(forRoot root: String) -> CrawlPermissions {
        let r = MountTable.standardize(root)
        let below = r == "/" ? "/" : r + "/"
        return CrawlPermissions(blockedPrefixes: blockedPrefixes.filter {
            let p = MountTable.standardize($0)
            return p != r && p.hasPrefix(below)
        })
    }

    public func isBlocked(_ path: String) -> Bool {
        let p = MountTable.standardize(path)
        return blockedPrefixes.contains {
            let b = MountTable.standardize($0)
            return p == b || p.hasPrefix(b == "/" ? "/" : b + "/")
        }
    }

    static func trim(_ s: String) -> String { s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s }
}
