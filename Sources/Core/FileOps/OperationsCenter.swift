import Foundation
import Observation
import MacxFS

/// Main-actor mirror of the FileOpQueue (§6.2) and the router of finished jobs: LocalChange posts (§4.3),
/// undo registration (§6.6), onFinished observers, `perform` callers. The single consumer of `queue.events`.
@MainActor @Observable
public final class OperationsCenter {
    public private(set) var jobs: [JobSnapshot] = []
    private var revealed: Set<JobID> = []
    @ObservationIgnored private var externalCancels: [JobID: @MainActor () -> Void] = [:]

    private let queue: FileOpQueue
    private let undo: FileOpUndoStack
    private let changeBus: ChangeBus
    private let actionName: @MainActor (JobDescription) -> String
    private let finishedObservers = Observers<(JobSnapshot, JobOutcome)>()
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var waiters: [JobID: [CheckedContinuation<JobOutcome, Never>]] = [:]
    @ObservationIgnored private var unclaimed: [JobID: JobOutcome] = [:]
    @ObservationIgnored private var performsInFlight = 0
    /// §6.2: jobs that finish sooner show nothing.
    @ObservationIgnored var revealDelay: Duration = .seconds(1)
    /// Waits out `revealDelay` before a job is revealed. Test hook: a test swaps in a gate it opens by hand, so the
    /// "hidden until the delay passes" window does not depend on how quickly a loaded runner polls.
    @ObservationIgnored var revealSleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// How often the row of a file being written is re-read (its size grows in the list).
    @ObservationIgnored var writeRefreshInterval: Duration = .seconds(1)
    @ObservationIgnored private var lastWriteRefresh: [JobID: (url: URL, at: ContinuousClock.Instant)] = [:]

    public init(queue: FileOpQueue, undo: FileOpUndoStack, changeBus: ChangeBus,
                actionName: @escaping @MainActor (JobDescription) -> String) {
        self.queue = queue; self.undo = undo; self.changeBus = changeBus; self.actionName = actionName
    }

    public var visibleJobs: [JobSnapshot] { jobs.filter { $0.state == .waitingForUser || revealed.contains($0.id) } }
    public var overallFraction: Double? { Self.overallFraction(of: jobs) }
    /// The Dock badge's %: over the visible jobs only (jobs under 1 s don't count, §6.2/§6.7).
    public var visibleFraction: Double? { Self.overallFraction(of: visibleJobs) }
    public var hasActiveJobs: Bool { !jobs.isEmpty }

    /// Work-weighted (JobProgress.workDone / workTotal: items and written bytes) over jobs that know their totals;
    /// otherwise the mean of the known fractions.
    nonisolated static func overallFraction(of jobs: [JobSnapshot]) -> Double? {
        let known = jobs.filter { ($0.progress.workTotal ?? 0) > 0 }
        if !known.isEmpty {
            let done = known.reduce(Int64(0)) { $0 + min($1.progress.workDone, $1.progress.workTotal ?? 0) }
            let total = known.reduce(Int64(0)) { $0 + ($1.progress.workTotal ?? 0) }
            return min(1, Double(done) / Double(total))
        }
        let fractions = jobs.compactMap(\.progress.fraction)
        return fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
    }

    /// Idempotent.
    public func start() {
        guard consumer == nil else { return }
        let events = queue.events
        consumer = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    func handle(_ event: JobEvent) async {
        switch event {
        case .added(let s):
            guard !jobs.contains(where: { $0.id == s.id }) else { return }
            jobs.append(s)
            scheduleReveal(s.id)
        case .updated(let s):
            // A ticker update can race the finish; one for a job we no longer list is stale.
            guard let i = jobs.firstIndex(where: { $0.id == s.id }) else { return }
            jobs[i] = s
            refreshWrittenFile(s)
        case .finished(let s, let outcome):
            jobs.removeAll { $0.id == s.id }
            revealed.remove(s.id)
            lastWriteRefresh[s.id] = nil
            changeBus.post(outcome.localChanges)
            if await queue.registersUndo(s.id) {
                undo.register(outcome, actionName: actionName(s.description))
            }
            finishedObservers.send((s, outcome))
            if let ws = waiters.removeValue(forKey: s.id) {
                for w in ws { w.resume(returning: outcome) }
            } else if performsInFlight > 0 {
                unclaimed[s.id] = outcome                 // finished before its perform caller started waiting
            }
        }
    }

    /// FSEvents reports a file's data writes only when it closes, so a large file being copied would keep the size
    /// it had when it was created. While a job writes a file, its row is re-read once per `writeRefreshInterval`
    /// (and at once when the job moves on to another file).
    private func refreshWrittenFile(_ s: JobSnapshot) {
        guard let url = s.progress.writingNow else {
            lastWriteRefresh[s.id] = nil
            return
        }
        let now = ContinuousClock.now
        if let last = lastWriteRefresh[s.id], last.url == url, now - last.at < writeRefreshInterval { return }
        lastWriteRefresh[s.id] = (url, now)
        changeBus.post([LocalChange(directory: url.deletingLastPathComponent(), modified: [url.lastPathComponent])])
    }

    private func scheduleReveal(_ id: JobID) {
        let delay = revealDelay, waitOut = revealSleep
        Task { [weak self] in
            await waitOut(delay)
            guard let self, self.jobs.contains(where: { $0.id == id }) else { return }
            self.revealed.insert(id)
        }
    }

    // MARK: external activities (remote downloads, spec §4.5)

    /// A row for work that does not run in the FileOpQueue (downloads from a repository). Revealed after the same
    /// delay as jobs; the panel's cancel button calls `cancel`.
    public func beginExternal(_ description: JobDescription, cancel: @escaping @MainActor () -> Void) -> JobID {
        let id = JobID()
        externalCancels[id] = cancel
        jobs.append(JobSnapshot(id: id, description: description, state: .running, progress: JobProgress(),
                                origin: nil, startedAt: .now))
        scheduleReveal(id)
        return id
    }

    public func updateExternal(_ id: JobID, _ progress: JobProgress) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].progress = progress
    }

    public func endExternal(_ id: JobID) {
        externalCancels[id] = nil
        jobs.removeAll { $0.id == id }
        revealed.remove(id)
    }

    /// true when `id` is an external activity (its cancel handler ran); false for queue jobs.
    @discardableResult
    public func cancelExternal(_ id: JobID) -> Bool {
        guard let cancel = externalCancels[id] else { return false }
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = .cancelling }
        cancel()
        return true
    }

    /// Returns after the finished job's changes were posted and its undo entry registered.
    public func perform(_ request: JobRequest) async -> JobOutcome {
        start()
        performsInFlight += 1
        defer {
            performsInFlight -= 1
            if performsInFlight == 0 { unclaimed.removeAll() }
        }
        let id = await queue.enqueue(request)
        if let outcome = unclaimed.removeValue(forKey: id) { return outcome }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    public func onFinished(_ handler: @escaping @MainActor (JobSnapshot, JobOutcome) -> Void) -> ObserverToken {
        finishedObservers.add { handler($0.0, $0.1) }
    }
}
