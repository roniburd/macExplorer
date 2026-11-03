import Foundation
import MacxFS

public struct FileOpTuning: Sendable {
    public var progressInterval: Duration
    public var copyChunkBytes: Int
    public var faultHook: (@Sendable (FaultPoint, JobID) -> Void)?
    /// Test knobs (`@testable import Core`).
    var allowClone = true
    var forceCrossVolume = false
    var bodyOverride: (@Sendable (JobContext) async -> Void)? = nil
    public init(progressInterval: Duration = .milliseconds(100), copyChunkBytes: Int = 1 << 20,
                faultHook: (@Sendable (FaultPoint, JobID) -> Void)? = nil) {
        self.progressInterval = progressInterval; self.copyChunkBytes = copyChunkBytes; self.faultHook = faultHook
    }
}

public enum JobEvent: Sendable {
    case added(JobSnapshot)
    case updated(JobSnapshot)
    case finished(JobSnapshot, JobOutcome)
}

public actor FileOpQueue {
    private struct Entry {
        let ctx: JobContext
        var devices: Set<UInt64>?
        var started = false
        var suspended = false
        var finished = false
    }

    private let lanes: LanePool
    private let trash: any TrashService
    private let journal: Journal
    private let interaction: any FileOpInteraction
    private let tuning: FileOpTuning
    private var order: [JobID] = []
    private var entries: [JobID: Entry] = [:]
    private var outcomes: [JobID: JobOutcome] = [:]
    private var undoFlags: [JobID: Bool] = [:]
    private var outcomeWaiters: [JobID: [CheckedContinuation<JobOutcome, Never>]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private nonisolated let eventStream: AsyncStream<JobEvent>
    private nonisolated let continuation: AsyncStream<JobEvent>.Continuation

    public init(lanes: LanePool, trash: any TrashService, journal: Journal, interaction: any FileOpInteraction,
                tuning: FileOpTuning = FileOpTuning()) {
        self.lanes = lanes; self.trash = trash; self.journal = journal; self.interaction = interaction; self.tuning = tuning
        (eventStream, continuation) = AsyncStream.makeStream(of: JobEvent.self, bufferingPolicy: .unbounded)
    }

    public nonisolated var events: AsyncStream<JobEvent> { eventStream }

    @discardableResult
    public func enqueue(_ request: JobRequest) -> JobID {
        let id = JobID()
        let ctx = JobContext(id: id, request: request, lanes: lanes, trash: trash, journal: journal,
                             interaction: interaction, tuning: tuning)
        order.append(id)
        entries[id] = Entry(ctx: ctx)
        undoFlags[id] = request.registersUndo
        continuation.yield(.added(ctx.snapshot()))
        let urls = request.kind.allURLs
        let lanes = self.lanes
        Task {
            let probe = (try? await lanes.perform(on: .unknown, .fileOp) { _ in VolumeIdentity.probe(urls) })
                ?? VolumeIdentity.Probe(devices: [], laneVolume: .unknown)
            self.didProbe(id, probe)
        }
        return id
    }

    private func didProbe(_ id: JobID, _ probe: VolumeIdentity.Probe) {
        guard entries[id] != nil, !(entries[id]!.finished) else { return }
        entries[id]!.devices = probe.devices
        entries[id]!.ctx.setLaneVolume(probe.laneVolume)
        schedule()
    }

    /// A job starts when no earlier unfinished job has an unknown or overlapping device set (FIFO per volume set).
    private func schedule() {
        var earlier: [Set<UInt64>?] = []
        for id in order {
            guard let e = entries[id], !e.finished else { continue }
            let blocked = e.devices == nil || earlier.contains { d in
                guard let d, let mine = e.devices else { return true }
                return !d.isDisjoint(with: mine)
            }
            if !e.started && !e.suspended && !blocked { start(id) }
            earlier.append(e.devices)
        }
    }

    private func start(_ id: JobID) {
        entries[id]!.started = true
        let ctx = entries[id]!.ctx
        let ticker = startTicker(ctx)
        let body = tuning.bodyOverride
        Task {
            let outcome: JobOutcome
            if let body {
                ctx.setState(.running)
                await body(ctx)
                outcome = ctx.outcome()
            } else {
                outcome = await JobRunner.run(ctx)
            }
            ticker.cancel()
            self.didFinish(id, outcome)
        }
    }

    private func startTicker(_ ctx: JobContext) -> Task<Void, Never> {
        let interval = tuning.progressInterval
        let continuation = self.continuation
        return Task.detached {
            var last: JobSnapshot?
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                ctx.tickThroughput(now: .now)
                let s = ctx.snapshot()
                if s != last { continuation.yield(.updated(s)); last = s }
            }
        }
    }

    private func didFinish(_ id: JobID, _ outcome: JobOutcome) {
        guard let e = entries[id], !e.finished else { return }
        e.ctx.setState(.finished)
        entries[id] = nil
        order.removeAll { $0 == id }
        outcomes[id] = outcome
        continuation.yield(.finished(e.ctx.snapshot(), outcome))
        for w in outcomeWaiters.removeValue(forKey: id) ?? [] { w.resume(returning: outcome) }
        schedule()
        if !hasActiveJobs {
            let waiters = idleWaiters
            idleWaiters = []
            for w in waiters { w.resume() }
        }
    }

    public func pause(_ id: JobID) {
        guard let e = entries[id] else { return }
        e.ctx.control.pause()
        e.ctx.setState(.paused)
        if !e.started { entries[id]!.suspended = true }
    }

    public func resume(_ id: JobID) {
        guard let e = entries[id] else { return }
        e.ctx.control.resume()
        e.ctx.setState(e.started ? .running : .queued)
        entries[id]!.suspended = false
        schedule()
    }

    public func cancel(_ id: JobID) {
        guard let e = entries[id] else { return }
        e.ctx.cancelJob()
        if !e.started { didFinish(id, e.ctx.outcome()) }
    }

    public func cancelAll() async {
        for id in order { cancel(id) }
        await waitUntilIdle()
    }

    public func snapshots() -> [JobSnapshot] { order.compactMap { entries[$0]?.ctx.snapshot() } }

    public func outcome(of id: JobID) async -> JobOutcome {
        if let o = outcomes[id] { return o }
        guard entries[id] != nil else {
            return JobOutcome(record: JobRecord(id: id, verb: .copying, actions: []), skipped: [], wasCancelled: false, created: [], localChanges: [])
        }
        return await withCheckedContinuation { outcomeWaiters[id, default: []].append($0) }
    }

    public func waitUntilIdle() async {
        guard hasActiveJobs else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public var hasActiveJobs: Bool { !entries.isEmpty }

    public func suspendJobs(touching mountPoint: URL) -> [JobID] {
        let prefix = mountPoint.standardizedFileURL.path
        func touches(_ e: Entry) -> Bool {
            e.ctx.kind.allURLs.contains { u in let p = u.standardizedFileURL.path; return p == prefix || p.hasPrefix(prefix + "/") }
        }
        var running: [JobID] = []
        for id in order {
            guard let e = entries[id], touches(e) else { continue }
            if e.started { running.append(id) } else { pause(id) }
        }
        return running
    }

    /// Whether the request asked for an undo entry (OperationsCenter checks it on .finished).
    public func registersUndo(_ id: JobID) -> Bool { undoFlags[id] ?? false }
}
