import CoreServices
import Foundation

/// Pure classification of one coalesced FSEvents delivery for the visible folder (§4.3 Watcher).
public enum EventClassifier {
    /// More distinct item names than this in one delivery → full re-read.
    public static let incrementalLimit = 256

    private static let rescanAnywhere = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagEventIdsWrapped)
    private static let mustScan = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
    private static let rootChangedFlag = UInt32(kFSEventStreamEventFlagRootChanged)
    private static let goneFlags = UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
    private static let historyDone = UInt32(kFSEventStreamEventFlagHistoryDone)

    /// Keeps events on `folder`'s children and grandchildren (as the child's name); drops the rest (except
    /// rescan/root flags). nil = nothing to do.
    /// Paths compare lexically, without trailing slashes and with /private/{var,tmp,etc} ≡ /{var,tmp,etc}.
    public static func classify(_ events: [RawFSEvent], folder: String) -> WatchEvent? {
        let folderParts = components(folder)
        var names: [String] = []
        var seen = Set<String>()
        var rescan = false
        for event in events {
            let flags = event.flags
            if flags & historyDone != 0 { continue }
            if flags & rescanAnywhere != 0 { rescan = true; continue }
            let parts = components(event.path)
            if flags & rootChangedFlag != 0 { return .rootChanged }
            if parts == folderParts {
                if flags & goneFlags != 0 { return .rootChanged }
                if flags & mustScan != 0 { rescan = true }
                continue                                    // the folder's own metadata
            }
            if flags & mustScan != 0 {
                if parts.count < folderParts.count && Array(folderParts.prefix(parts.count)) == parts { rescan = true }
                // A descendant's contents changed in bulk: re-read the child that holds it (its own mtime).
                if parts.count > folderParts.count, Array(parts.prefix(folderParts.count)) == folderParts,
                   seen.insert(parts[folderParts.count]).inserted { names.append(parts[folderParts.count]) }
                continue
            }
            // A direct child, or an entry directly inside a child folder: creating, removing or renaming that
            // entry changes the child's own mtime, which FSEvents reports only as the grandchild's path. Deeper
            // paths change a grandchild's mtime, not the child's (QA round 1: stale Date Modified, size-cache misses).
            guard parts.count == folderParts.count + 1 || parts.count == folderParts.count + 2,
                  Array(parts.prefix(folderParts.count)) == folderParts else { continue }
            let name = parts[folderParts.count]
            if seen.insert(name).inserted { names.append(name) }
        }
        if rescan || names.count > incrementalLimit { return .fullRescan }
        return names.isEmpty ? nil : .items(names)
    }

    /// Path components with the firmlinked "/private" prefix dropped (same rule as ChangeBus.key).
    static func components(_ path: String) -> [String] {
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 2, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        return parts
    }
}
