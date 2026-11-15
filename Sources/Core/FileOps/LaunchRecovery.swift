import Foundation
import Darwin
import MacxFS

public struct RecoveryReport: Sendable, Equatable {
    public var removedPartials: [URL] = []
    public var restoredDestinations: [URL] = []
    public var restoredRenames: [URL] = []
    public var incompleteJobs: [JobDescription] = []
    /// Items recovery could not act on this time (their volume is not mounted, or a rename or removal failed): their
    /// journal entries are kept and tried again at the next launch.
    public var pendingRecoveries: [URL] = []
    public init() {}
    public var isEmpty: Bool {
        removedPartials.isEmpty && restoredDestinations.isEmpty && restoredRenames.isEmpty && incompleteJobs.isEmpty
            && pendingRecoveries.isEmpty
    }
}

public enum LaunchRecovery {
    /// Launches a job's unrecoverable entries are kept for; after that they are dropped (the volume is never coming back).
    static let maxAttempts = 10

    /// Order: interrupted batch renames (every item back at its original name, P4-11), interrupted two-step renames, then journaled partials (only names matching PartialName), then
    /// trashed destinations whose original path is free. A job whose entries were all resolved (or can never be) is
    /// finished; entries that could not be acted on yet are kept for the next launch (at most `maxAttempts` launches).
    public static func run(journal: Journal, lanes: LanePool) async -> RecoveryReport {
        let entries = await journal.entries()
        guard !entries.isEmpty else { return RecoveryReport() }
        let result = (try? await lanes.perform(on: .unknown, .fileOp) { lane in recover(entries, lane) })
        var report = result?.report ?? RecoveryReport()
        let pending = result?.pending ?? entries.filter { if case .jobStarted = $0 { false } else { true } }
        report.incompleteJobs = entries.compactMap { if case .jobStarted(_, let d) = $0 { d } else { nil } }
        var seen = Set<JobID>()
        for e in entries where seen.insert(e.job).inserted {
            let kept = pending.filter { $0.job == e.job }
            guard !kept.isEmpty, let n = try? await journal.retainForNextLaunch(job: e.job, keeping: kept), n < maxAttempts else {
                try? await journal.finish(job: e.job)
                continue
            }
            report.pendingRecoveries += kept.flatMap(\.recoveryURLs)
        }
        return report
    }

    /// Lane only. `pending`: entries that could not be acted on (kept for the next launch).
    static func recover(_ entries: [JournalEntry], _ lane: LaneContext) -> (report: RecoveryReport, pending: [JournalEntry]) {
        assertOffMain()
        var report = RecoveryReport()
        var pending: [JournalEntry] = []
        /// A missing parent folder: the volume is not mounted (or the folder is gone); nothing can be decided yet.
        func reachable(_ u: URL) -> Bool { PosixFS.exists(u.deletingLastPathComponent().path) }
        for case .batchRename(let job, let steps) in entries {
            lane.heartbeat()
            if steps.contains(where: { !reachable($0.original) }) { pending.append(.batchRename(job: job, steps: steps)); continue }
            report.restoredRenames += BatchRenameJob.recover(steps, heartbeat: lane.heartbeat)
        }
        for case .twoStepRename(let job, let temp, let original, let target) in entries {
            lane.heartbeat()
            if PosixFS.exists(temp.path) {
                // An occupied original can't be restored automatically, now or later: dropped.
                guard !PosixFS.exists(original.path) else { continue }
                if PosixFS.rename(temp.path, original.path) == 0 {
                    report.restoredRenames.append(original)
                } else {
                    pending.append(.twoStepRename(job: job, temporary: temp, original: original, target: target))
                }
            } else if !reachable(temp) {
                pending.append(.twoStepRename(job: job, temporary: temp, original: original, target: target))
            }
        }
        for case .partial(let job, let url) in entries {
            lane.heartbeat()
            guard PartialName.isPartial(url.lastPathComponent) else { continue }
            if PosixFS.exists(url.path) {
                if PosixFS.removeTree(url.path, unlock: true) == 0 {
                    report.removedPartials.append(url)
                } else {
                    pending.append(.partial(job: job, url: url))
                }
            } else if !reachable(url) {
                pending.append(.partial(job: job, url: url))
            }
        }
        for case .trashedDestination(let job, let original, let trashURL) in entries {
            lane.heartbeat()
            let entry = JournalEntry.trashedDestination(job: job, original: original, trashURL: trashURL)
            guard reachable(original), reachable(trashURL) else { pending.append(entry); continue }
            let occupied = PosixFS.exists(original.path), held = PosixFS.exists(trashURL.path)
            if !occupied, held {
                if PosixFS.rename(trashURL.path, original.path) == 0 {
                    report.restoredDestinations.append(original)
                } else {
                    pending.append(entry)
                }
            } else if occupied, held, PartialName.isPartial(trashURL.lastPathComponent) {
                // Set aside on a volume without a Trash (the user chose to delete it permanently) and the new item is
                // in place: the Replace completed, so the old item goes as agreed.
                if PosixFS.removeTree(trashURL.path, unlock: true) == 0 {
                    report.removedPartials.append(trashURL)
                } else {
                    pending.append(entry)
                }
            }
            // Otherwise resolved (put back already, or the Trash emptied) or never restorable (both taken): dropped.
        }
        return (report, pending)
    }
}

extension JournalEntry {
    /// The user-facing items of a kept entry (RecoveryReport.pendingRecoveries).
    var recoveryURLs: [URL] {
        switch self {
        case .partial(_, let u): [u]
        case .trashedDestination(_, let original, _), .twoStepRename(_, _, let original, _): [original]
        case .batchRename(_, let steps): steps.map(\.original)
        case .jobStarted: []
        }
    }
}
