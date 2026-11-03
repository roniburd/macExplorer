import Foundation
import Darwin
import MacxFS

public struct RecoveryReport: Sendable, Equatable {
    public var removedPartials: [URL] = []
    public var restoredDestinations: [URL] = []
    public var restoredRenames: [URL] = []
    public var incompleteJobs: [JobDescription] = []
    public init() {}
    public var isEmpty: Bool { removedPartials.isEmpty && restoredDestinations.isEmpty && restoredRenames.isEmpty && incompleteJobs.isEmpty }
}

public enum LaunchRecovery {
    /// Order: interrupted two-step renames, then journaled partials (only names matching PartialName), then
    /// trashed destinations whose original path is free. Every job in the journal is then finished.
    public static func run(journal: Journal, lanes: LanePool) async -> RecoveryReport {
        let entries = await journal.entries()
        guard !entries.isEmpty else { return RecoveryReport() }
        var report = (try? await lanes.perform(on: .unknown, .fileOp) { lane in recover(entries, lane) }) ?? RecoveryReport()
        report.incompleteJobs = entries.compactMap { if case .jobStarted(_, let d) = $0 { d } else { nil } }
        var seen = Set<JobID>()
        for e in entries where seen.insert(e.job).inserted { try? await journal.finish(job: e.job) }
        return report
    }

    static func recover(_ entries: [JournalEntry], _ lane: LaneContext) -> RecoveryReport {
        assertOffMain()
        var report = RecoveryReport()
        for case .twoStepRename(_, let temp, let original, _) in entries {
            lane.heartbeat()
            if PosixFS.exists(temp.path), !PosixFS.exists(original.path), PosixFS.rename(temp.path, original.path) == 0 {
                report.restoredRenames.append(original)
            }
        }
        for case .partial(_, let url) in entries {
            lane.heartbeat()
            guard PartialName.isPartial(url.lastPathComponent), PosixFS.exists(url.path) else { continue }
            if PosixFS.removeTree(url.path, unlock: true) == 0 { report.removedPartials.append(url) }
        }
        for case .trashedDestination(_, let original, let trashURL) in entries {
            lane.heartbeat()
            if !PosixFS.exists(original.path), PosixFS.exists(trashURL.path),
               PosixFS.rename(trashURL.path, original.path) == 0 {
                report.restoredDestinations.append(original)
            }
        }
        return report
    }
}
