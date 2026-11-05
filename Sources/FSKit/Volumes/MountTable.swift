import Foundation
import Synchronization

/// In-memory mount table (§4.2, §5.6 drag validation). Pure; no file-system calls.
public struct MountTable: Sendable, Equatable {
    private let byLength: [VolumeInfo]   // longest mount path first
    private let paths: [String]          // standardized mount paths, parallel to byLength

    public init(_ volumes: [VolumeInfo]) {
        let pairs = volumes.map { (MountTable.standardize($0.mountPoint.path(percentEncoded: false)), $0) }
            .sorted { $0.0.utf8.count > $1.0.utf8.count }
        byLength = pairs.map(\.1)
        paths = pairs.map(\.0)
    }

    public static let empty = MountTable([])
    public var volumes: [VolumeInfo] { byLength }

    /// Longest-prefix match of the standardized path against mount points (pure, in-memory).
    public func volume(containing path: String) -> VolumeInfo? {
        let p = MountTable.standardize(path)
        for (i, mount) in paths.enumerated() where mount == "/" || p == mount || p.hasPrefix(mount + "/") {
            return byLength[i]
        }
        return nil
    }

    public func isSameVolume(_ a: String, _ b: String) -> Bool {
        guard let x = volume(containing: a), let y = volume(containing: b) else { return false }
        return x.id == y.id
    }

    /// Lexical: removes "." / ".." / duplicate and trailing slashes, then drops a leading "/private" before
    /// var, tmp or etc. mountedVolumeURLs reports images mounted in $TMPDIR as /private/var/folders/…, while
    /// URL.standardizedFileURL (LaunchOptions, the overview's "standardized URL") yields /var/folders/…; both
    /// mount points and queries go through this, so either spelling finds the image's volume.
    public static func standardize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast(); continue }
            parts.append(c)
        }
        if parts.count >= 2, parts[0] == "private", firmlinked.contains(parts[1]) { parts.removeFirst() }
        return "/" + parts.joined(separator: "/")
    }

    private static let firmlinked: Set<Substring> = ["var", "tmp", "etc"]
}

/// Mutex-protected mirror of the main-actor table for off-main readers (DirectoryReaders, FileOps planning).
public final class MountTableStore: Sendable {
    private let table: Mutex<MountTable>
    public init(_ table: MountTable = .empty) { self.table = Mutex(table) }
    public func current() -> MountTable { table.withLock { $0 } }
    public func update(_ table: MountTable) { self.table.withLock { $0 = table } }
}
