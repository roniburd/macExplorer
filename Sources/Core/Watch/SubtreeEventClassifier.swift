import CoreServices
import Foundation

/// What a recursive (directory-granularity) FSEvents delivery means for the folder sizes of one folder's children.
public enum SubtreeChange: Sendable, Equatable {
    case children(Set<String>)     // names directly inside the folder whose subtree changed
    case all                       // events were lost or the folder itself moved: every child is suspect
}

/// Pure classification for `SubtreeWatcher` (§11 Phase 2 folder sizes). Paths compare by component, without
/// trailing slashes and with /private/{var,tmp,etc} ≡ /{var,tmp,etc} (EventClassifier's rule).
public enum SubtreeEventClassifier {
    private static let rescanAnywhere = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagEventIdsWrapped)
    private static let mustScan = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
    private static let rootChanged = UInt32(kFSEventStreamEventFlagRootChanged)
    private static let historyDone = UInt32(kFSEventStreamEventFlagHistoryDone)

    /// nil = nothing below the folder changed (only the folder's own listing, or unrelated paths).
    public static func classify(_ events: [RawFSEvent], folder: String) -> SubtreeChange? {
        let base = EventClassifier.components(folder)
        var names = Set<String>()
        for event in events {
            let flags = event.flags
            if flags & historyDone != 0 { continue }
            if flags & (rescanAnywhere | rootChanged) != 0 { return .all }
            let parts = EventClassifier.components(event.path)
            if parts.count <= base.count {
                // The folder itself or an ancestor: a MustScanSubDirs there covers every child.
                if flags & mustScan != 0, Array(base.prefix(parts.count)) == parts { return .all }
                continue
            }
            guard Array(parts.prefix(base.count)) == base else { continue }
            names.insert(parts[base.count])
        }
        return names.isEmpty ? nil : .children(names)
    }
}
