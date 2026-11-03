import Foundation
import Darwin
import Synchronization
import MacxFS

enum StepResult: Sendable, Equatable { case done, skipped, cancelled }

/// Pause/cancel flags shared by async job code and lane work.
final class JobControl: Sendable {
    private let flags = Mutex((paused: false, cancelled: false))
    var isPaused: Bool { flags.withLock { $0.paused } }
    var isCancelled: Bool { flags.withLock { $0.cancelled } }
    func pause() { flags.withLock { $0.paused = true } }
    func resume() { flags.withLock { $0.paused = false } }
    func cancel() { flags.withLock { $0.cancelled = true; $0.paused = false } }

    /// Lane side (between copy chunks): waits while paused, heartbeating so the watchdog never poisons
    /// a paused lane. Returns false when cancelled.
    func laneCheckpoint(_ lane: LaneContext) -> Bool {
        while true {
            let f = flags.withLock { $0 }
            if f.cancelled || lane.isCancelled { return false }
            if !f.paused { return true }
            lane.heartbeat()
            usleep(20_000)
        }
    }

    /// Async side (between items).
    func checkpoint() async -> Bool {
        while isPaused && !isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
        return !isCancelled
    }
}

final class JobContext: Sendable {
    let id: JobID
    let request: JobRequest
    var kind: JobKind { request.kind }
    let lanes: LanePool
    let trash: any TrashService
    let journal: Journal
    let interaction: any FileOpInteraction
    let tuning: FileOpTuning
    let control = JobControl()

    private struct State {
        var snapshot: JobSnapshot
        var laneVolume: VolumeID = .unknown
        var actions: [ItemAction] = []
        var skipped: [SkippedItem] = []
        var created: [URL] = []
        var changes: [URL: LocalChange] = [:]
        var changeOrder: [URL] = []
        var skipAll: Set<String> = []
        var journaledStart = false
        var meter = ThroughputMeter()
        var fileConflictAction: ConflictAction?
        var folderConflictAction: ConflictAction?
        var perItemConflicts: [URL: ConflictAction]?
    }
    private let state: Mutex<State>

    init(id: JobID, request: JobRequest, lanes: LanePool, trash: any TrashService, journal: Journal,
         interaction: any FileOpInteraction, tuning: FileOpTuning) {
        self.id = id; self.request = request; self.lanes = lanes; self.trash = trash
        self.journal = journal; self.interaction = interaction; self.tuning = tuning
        state = Mutex(State(snapshot: JobSnapshot(id: id, description: request.kind.jobDescription, state: .queued,
                                                  progress: .zero, origin: request.origin, startedAt: .now)))
    }

    // MARK: snapshot and progress
    func snapshot() -> JobSnapshot { state.withLock { $0.snapshot } }
    func setState(_ s: JobState) { state.withLock { $0.snapshot.state = s } }
    var laneVolume: VolumeID {
        get { state.withLock { $0.laneVolume } }
    }
    func setLaneVolume(_ v: VolumeID) { state.withLock { $0.laneVolume = v } }
    func setTotals(items: Int, bytes: Int64?) {
        state.withLock { $0.snapshot.progress.itemsTotal = items; $0.snapshot.progress.bytesTotal = bytes }
    }
    func addProgress(items: Int = 0, bytes: Int64 = 0, current: String? = nil) {
        state.withLock { s in
            s.snapshot.progress.itemsDone += items
            s.snapshot.progress.bytesDone += bytes
            if let current { s.snapshot.progress.currentItem = current }
        }
    }
    /// Called by the queue's ticker every progressInterval.
    func tickThroughput(now: ContinuousClock.Instant) {
        state.withLock { s in
            s.meter.sample(bytesDone: s.snapshot.progress.bytesDone, at: now)
            s.snapshot.progress.throughput = s.meter.samples
            s.snapshot.progress.estimatedRemaining = s.meter.estimatedRemaining(bytesDone: s.snapshot.progress.bytesDone,
                                                                                bytesTotal: s.snapshot.progress.bytesTotal)
        }
    }

    // MARK: lanes
    func onLane<T: Sendable>(_ work: @escaping @Sendable (LaneContext) throws -> T) async throws -> T {
        try await lanes.perform(on: laneVolume, .fileOp, work)
    }

    // MARK: record
    func record(_ action: ItemAction) { state.withLock { $0.actions.append(action) } }
    func removeLastAction(where match: (ItemAction) -> Bool) {
        state.withLock { s in if let i = s.actions.lastIndex(where: match) { s.actions.remove(at: i) } }
    }
    func skip(_ url: URL, reason: FileOpErrorKind?) { state.withLock { $0.skipped.append(SkippedItem(url: url, reason: reason)) } }

    private func mutateChange(_ dir: URL, _ body: (inout LocalChange) -> Void) {
        let key = URL(filePath: dir.standardizedFileURL.path, directoryHint: .isDirectory)   // one key per folder
        state.withLock { s in
            if s.changes[key] == nil { s.changes[key] = LocalChange(directory: key); s.changeOrder.append(key) }
            body(&s.changes[key]!)
        }
    }
    func landed(_ url: URL, select: Bool = true, beginRename: Bool = false) {
        state.withLock { $0.created.append(url) }
        let name = url.lastPathComponent
        mutateChange(url.deletingLastPathComponent()) { c in
            c.added.append(name)
            if select { c.select.append(name) }
            if beginRename { c.beginRename = name }
        }
    }
    func noteRemoved(_ url: URL) { mutateChange(url.deletingLastPathComponent()) { $0.removed.append(url.lastPathComponent) } }
    func noteModified(_ url: URL) { mutateChange(url.deletingLastPathComponent()) { $0.modified.append(url.lastPathComponent) } }
    func noteRenamed(from: URL, to: URL) {
        if from.deletingLastPathComponent().standardizedFileURL.path == to.deletingLastPathComponent().standardizedFileURL.path {
            mutateChange(to.deletingLastPathComponent()) { c in
                c.renamed.append(LocalChange.Rename(from: from.lastPathComponent, to: to.lastPathComponent))
                c.select.append(to.lastPathComponent)
            }
        } else {
            noteRemoved(from)
            landed(to)
        }
    }

    // MARK: faults, journal
    func fault(_ point: FaultPoint) { tuning.faultHook?(point, id) }

    /// Records `jobStarted` before the job's first journal entry.
    func journalRecord(_ entry: JournalEntry) async throws {
        let first = state.withLock { s -> Bool in defer { s.journaledStart = true }; return !s.journaledStart }
        if first { try await journal.record(.jobStarted(job: id, description: snapshot().description)) }
        try await journal.record(entry)
    }
    func journalClear(_ entry: JournalEntry) async { try? await journal.clear(entry) }

    // MARK: control and questions
    func checkpoint() async -> Bool { await control.checkpoint() }
    func cancelJob() { control.cancel(); setState(.cancelling) }

    private func waitingForUser<T>(_ body: () async -> T) async -> T {
        let previous = snapshot().state
        setState(.waitingForUser)
        let r = await body()
        if snapshot().state == .waitingForUser { setState(previous) }
        return r
    }

    /// Honors an earlier "Skip All" for the same error class.
    func askError(_ error: FileOpError) async -> ErrorResolution {
        let key = error.kind.categoryKey
        if state.withLock({ $0.skipAll.contains(key) }) { return .skip }
        let answer = await waitingForUser { await interaction.resolveError(error, job: snapshot()) }
        if answer == .skipAll { state.withLock { _ = $0.skipAll.insert(key) } }
        return answer
    }

    func askSpace(_ shortfall: SpaceShortfall) async -> Bool {
        await waitingForUser { await interaction.confirmInsufficientSpace(shortfall, job: snapshot()) }
    }

    /// Runs a lane step (returns 0 or an errno) until it succeeds or the user skips or cancels.
    func attempt(_ url: URL, destination: URL? = nil, _ step: @escaping @Sendable (LaneContext) -> Int32) async -> StepResult {
        while true {
            let code: Int32 = (try? await onLane(step)) ?? EIO
            if code == 0 { return .done }
            let locked = code == EPERM ? ((try? await onLane { _ in
                (PosixFS.info(url.path)?.isLocked ?? false) || (PosixFS.info(url.deletingLastPathComponent().path)?.isLocked ?? false)
            }) ?? false) : false
            let kind = FileOpErrorKind(errno: code, isLockedItem: locked)
            switch await askError(FileOpError(kind: kind, url: url, destination: destination)) {
            case .retry, .continueAnyway: continue
            case .skip, .skipAll: skip(url, reason: kind); return .skipped
            case .cancel: cancelJob(); return .cancelled
            case .unlockAndContinue:
                _ = try? await onLane { _ in PosixFS.clearImmutable(url.path, recursive: false) }
                continue
            }
        }
    }

    // MARK: conflicts memory (used by ConflictExecutor, P1-22)
    /// nil = nothing remembered for this class; ask the user.
    func rememberedConflictAction(folder: Bool, source: URL) -> ConflictAction? {
        state.withLock { s in
            if let map = s.perItemConflicts { return map[source] ?? .skip }
            return folder ? s.folderConflictAction : s.fileConflictAction
        }
    }
    func rememberConflict(_ resolution: ConflictResolution, folder: Bool) {
        state.withLock { s in
            switch resolution {
            case .all(let a): if folder { s.folderConflictAction = a } else { s.fileConflictAction = a }
            case .perItem(let m): s.perItemConflicts = m
            case .one, .cancelJob: break
            }
        }
    }
    func askConflict(_ info: ConflictInfo) async -> ConflictResolution {
        await waitingForUser { await interaction.resolveConflict(info, job: snapshot()) }
    }

    // MARK: outcome
    func outcome() -> JobOutcome {
        state.withLock { s in
            JobOutcome(record: JobRecord(id: id, verb: kind.verb, actions: s.actions), skipped: s.skipped,
                       wasCancelled: control.isCancelled, created: s.created,
                       localChanges: s.changeOrder.compactMap { s.changes[$0] })
        }
    }
}

extension FileOpErrorKind {
    /// Groups errors for "Skip All" (associated values ignored).
    var categoryKey: String {
        switch self {
        case .permissionDenied: "permissionDenied"
        case .blockedByMacOS: "blockedByMacOS"
        case .locked: "locked"
        case .readOnlyVolume: "readOnlyVolume"
        case .noSpace: "noSpace"
        case .inUse: "inUse"
        case .nameTooLong: "nameTooLong"
        case .sourceGone: "sourceGone"
        case .intoItself: "intoItself"
        case .changedDuringMove: "changedDuringMove"
        case .noTrash: "noTrash"
        case .other(let code, _): "other\(code)"
        }
    }
}

extension JobContext {
    /// Plan phase shared by copy/move/trash/delete/chmod: lane plan, per-item refusals (Skip/Cancel),
    /// free-space prompt, totals. nil = the job was cancelled.
    func plan(sources: [URL], destination: URL?, mode: PlanMode) async -> JobPlan? {
        setState(.planning)
        let force = tuning.forceCrossVolume
        let planned = try? await onLane { lane in
            Planner.plan(sources: sources, destination: destination, mode: mode, forceCrossVolume: force, lane: lane)
        }
        guard let plan = planned else {
            for s in sources { skip(s, reason: .other(code: EIO, message: String(cString: strerror(EIO)))) }
            return nil
        }
        for r in plan.refused {
            if await askError(FileOpError(kind: r.kind, url: r.url, destination: destination)) == .cancel {
                cancelJob(); return nil
            }
            skip(r.url, reason: r.kind)
        }
        if plan.neededBytes > 0, let available = plan.availableBytes, plan.neededBytes > available {
            let go = await askSpace(SpaceShortfall(needed: plan.neededBytes, available: available, volumeName: plan.destinationVolumeName))
            if !go { cancelJob(); return nil }
        }
        setTotals(items: plan.totalItems, bytes: plan.totalBytes)
        setState(.running)
        return plan
    }
}

enum JobRunner {
    static func run(_ ctx: JobContext) async -> JobOutcome {
        ctx.setState(.planning)
        switch ctx.kind {
        case .newItem(let kind, let directory):
            await CreateOps.newItem(ctx, kind: kind, in: directory)
        case .rename(let url, let newName):
            await CreateOps.rename(ctx, url, to: newName)
        case .copy(let sources, let destination):
            await CopyJob.run(ctx, sources: sources, destination: destination, duplicate: false)
        case .duplicate(let urls):
            let groups = Dictionary(grouping: urls) { $0.deletingLastPathComponent().standardizedFileURL.path }
            for parent in groups.keys.sorted() where !ctx.control.isCancelled {
                await CopyJob.run(ctx, sources: groups[parent]!, destination: URL(filePath: parent, directoryHint: .isDirectory), duplicate: true)
            }
        case .move(let sources, let destination):
            await MoveJob.run(ctx, sources: sources, destination: destination)
        case .trash(let urls):
            await TrashDeleteJobs.trash(ctx, urls)
        case .delete(let urls):
            await TrashDeleteJobs.delete(ctx, urls)
        case .alias(let sources, let destination):
            await LinkJobs.alias(ctx, sources: sources, destination: destination)
        case .symlink(let sources, let destination):
            await LinkJobs.symlink(ctx, sources: sources, destination: destination)
        case .chmodRecursive(let url, let change):
            await AttributeJobs.chmodRecursive(ctx, url, change)
        case .setAttributes(let urls, let edit):
            await AttributeJobs.setAttributes(ctx, urls, edit)
        case .undo(let record), .redo(let record):
            await UndoPlanner.run(ctx, record)
        }
        try? await ctx.journal.finish(job: ctx.id)
        return ctx.outcome()
    }
}

enum FailureResolution: Sendable, Equatable { case retry, skipped, cancelled }

extension JobContext {
    /// Asks about one failed step (errno). Skip records the item; Unlock and Continue clears uchg first.
    func resolveFailure(_ code: Int32, url: URL, destination: URL? = nil) async -> FailureResolution {
        let locked = code == EPERM ? ((try? await onLane { _ in
            (PosixFS.info(url.path)?.isLocked ?? false) || (PosixFS.info(url.deletingLastPathComponent().path)?.isLocked ?? false)
        }) ?? false) : false
        let kind = FileOpErrorKind(errno: code, isLockedItem: locked)
        switch await askError(FileOpError(kind: kind, url: url, destination: destination)) {
        case .retry, .continueAnyway: return .retry
        case .unlockAndContinue:
            _ = try? await onLane { _ in PosixFS.clearImmutable(url.path, recursive: false) }
            return .retry
        case .skip, .skipAll: skip(url, reason: kind); return .skipped
        case .cancel: cancelJob(); return .cancelled
        }
    }
}

extension JobContext {
    /// "Delete permanently?" for items on volumes without a Trash.
    func askNoTrash(_ urls: [URL]) async -> Bool {
        let previous = snapshot().state
        setState(.waitingForUser)
        let answer = await interaction.confirmPermanentDeleteWithoutTrash(urls, job: snapshot())
        setState(previous)
        return answer
    }
}

extension JobContext {
    /// Undo/redo count one item per step, whatever the reused helpers added (they add their own item counts).
    func setItemsDone(_ n: Int) { state.withLock { $0.snapshot.progress.itemsDone = n } }

    /// A folder appeared without becoming part of the selection or `JobOutcome.created` (undo re-creating a parent).
    func noteAdded(_ url: URL) { mutateChange(url.deletingLastPathComponent()) { $0.added.append(url.lastPathComponent) } }
}
