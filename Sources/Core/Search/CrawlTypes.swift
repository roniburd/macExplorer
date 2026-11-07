import Foundation
import MacxFS

public struct CrawlOptions: Sendable, Hashable {
    public var includePackages: Bool = false
    public var includeHidden: Bool = false
    public var maxResults: Int = 100_000
    public var maxConcurrentReads: Int = 2
    public var progressInterval: Duration = .milliseconds(100)
    /// Finder "Show all filename extensions": when false, name terms also see the display name of items whose
    /// extension Finder hides (per-file flag, ".app"), like the in-folder filter (`Sorter.matches`).
    public var showAllExtensions: Bool = false
    public init() {}
}

/// Folders the crawler must not open (TCC-protected without a recorded grant). Paths are standardized, no trailing "/".
///
/// Comparisons are case- and normalization-insensitive (and fold "/private/var|tmp|etc" to "/var|tmp|etc"): the
/// boot volume is case-insensitive APFS, so a root typed as "/users/me" still reaches "/Users/me/Desktop" on disk
/// and must hit that prefix. On a case-sensitive volume this can only over-block (skip a look-alike folder), never
/// open a protected one, which is the safe direction (Review Focus 4).
public struct CrawlPermissions: Sendable, Hashable {
    public let blockedPrefixes: [String]
    private let folded: [String]                    // Self.fold of each prefix, parallel to blockedPrefixes
    public init(blockedPrefixes: [String]) {
        self.blockedPrefixes = blockedPrefixes.map(Self.trim)
        self.folded = self.blockedPrefixes.map(Self.fold)
    }
    public static let none = CrawlPermissions(blockedPrefixes: [])

    /// Prefixes strictly below `root` (the user is already looking inside the root). The kept prefixes are unchanged.
    public func relevant(forRoot root: String) -> CrawlPermissions {
        let r = Self.fold(root)
        let below = r == "/" ? "/" : r + "/"
        return CrawlPermissions(blockedPrefixes: zip(blockedPrefixes, folded).filter { $0.1 != r && $0.1.hasPrefix(below) }.map(\.0))
    }

    public func isBlocked(_ path: String) -> Bool {
        guard !folded.isEmpty else { return false }
        let p = Self.fold(path)
        return folded.contains { b in p == b || p.hasPrefix(b == "/" ? "/" : b + "/") }
    }

    static func trim(_ s: String) -> String { s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s }

    /// Comparison key: NFC, lowercased, then lexical standardize (after lowercasing, so "/PRIVATE/VAR" folds too).
    static func fold(_ path: String) -> String { MountTable.standardize(path.precomposedStringWithCanonicalMapping.lowercased()) }
}
