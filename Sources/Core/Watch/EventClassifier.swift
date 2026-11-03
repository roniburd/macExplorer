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

    /// Drops events whose parent is not exactly `folder` (except rescan/root flags). nil = nothing to do.
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
                continue
            }
            guard parts.count == folderParts.count + 1, Array(parts.dropLast()) == folderParts, let name = parts.last else { continue }
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
