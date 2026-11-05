import Foundation
import MacxFS

/// Group by (spec §11, P2-09). While grouped, every display order the worker returns (loading frames, re-sorts,
/// watcher and LocalChange patches, re-reads) is partitioned off main with the current grouping, and main
/// publishes `.groups(runs)` followed by one `.changes(.reset)`, so a new item always lands in its group.
/// A patch that leaves the order and the groups as they were (reloads only) is still published as reloads.
/// Every result carries the grouping revision it was computed for; one computed for an older grouping is
/// published consistently (its own order and runs) and followed by a regroup with the current one.
/// The stored state lives in FolderModel.swift (extensions cannot hold stored properties).
extension FolderModel {
    /// Groups this model's display order (`.none` turns grouping off). The view decides: Details only.
    public func setGrouping(_ groupBy: GroupBy) {
        guard !closed, groupBy != grouping else { return }
        grouping = groupBy
        groupingRevision += 1
        cancelDayTimer()
        if groupBy == .dateModified {
            dateBuckets = DateBuckets(now: context.now(), calendar: context.calendar)
            scheduleDayTimer()
        }
        regroup()
    }

    /// The day changed: Date Modified groups are recomputed ("Today" becomes "Yesterday"). No-op otherwise.
    public func regroupForNewDay() {
        guard !closed, grouping == .dateModified else { return }
        dateBuckets = DateBuckets(now: context.now(), calendar: context.calendar)
        groupingRevision += 1
        scheduleDayTimer()
        regroup()
    }

    /// The day timer is armed (tests).
    var hasDayTimer: Bool { dayTask != nil }

    /// The grouping the next worker call partitions with. A date grouping whose day ended meanwhile (the timer
    /// was late, the Mac slept) gets fresh buckets first.
    func currentGroupSpec() -> FolderWorker.GroupSpec {
        guard grouping != .none else { return FolderWorker.GroupSpec(groupBy: .none, buckets: FolderWorker.GroupSpec.none.buckets,
                                                                     revision: groupingRevision) }
        if grouping == .dateModified, context.now() >= dateBuckets.nextBoundary {
            dateBuckets = DateBuckets(now: context.now(), calendar: context.calendar)
            groupingRevision += 1
            scheduleDayTimer()
        }
        return FolderWorker.GroupSpec(groupBy: grouping, buckets: dateBuckets, revision: groupingRevision)
    }

    /// Re-publishes the current folder with the current grouping. A complete folder re-sorts on the store queue;
    /// a listing in progress picks the new revision up on its next frame and when it finishes.
    func regroup() {
        guard started, !closed else { return }
        switch state {
        case .complete: enqueue { [weak self] in await self?.resortNow() }
        case .loading, .partial, .unresponsive, .waitingForPermission, .error: break
        }
    }

    /// Adopts the groups of an order that is about to be published with a reset; `.groups` is sent while grouped
    /// and once when grouping turned off (Phase 1 ungrouped folders never see it).
    func setGroups(_ runs: [GroupRun]) {
        let had = !groups.isEmpty
        groups = runs
        if grouping != .none || had || !runs.isEmpty { emit(.groups(runs)) }
    }

    /// Publishes a patch or re-read result whose store (and order) was just adopted.
    func publishPatch(_ changes: ChangeSet, runs: [GroupRun]) {
        guard !runs.isEmpty || !groups.isEmpty else {
            if !changes.isEmpty { emit(.changes(changes)) }      // ungrouped: Phase 1 incremental changes
            return
        }
        let onlyReloads = changes.changes.allSatisfy { if case .reload = $0 { true } else { false } }
        if onlyReloads && runs == groups {
            if !changes.isEmpty { emit(.changes(changes)) }      // same order, same groups
            return
        }
        groups = runs
        emit(.groups(runs))
        emit(.changes(.reset))
    }

    func scheduleDayTimer() {
        dayTask?.cancel()
        let delay = max(1, dateBuckets.nextBoundary.timeIntervalSince(context.now()) + 1)
        dayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.regroupForNewDay()
        }
    }

    func cancelDayTimer() {
        dayTask?.cancel()
        dayTask = nil
    }
}
