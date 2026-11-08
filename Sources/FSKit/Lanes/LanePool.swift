import Foundation
import Synchronization

public enum VolumeHealth: Sendable, Equatable { case healthy, unresponsive }

public enum LaneError: Error, Sendable, Equatable {
    case volumeUnresponsive(VolumeID)      // poisonCap reached; no reads issued until resetVolume
    case cancelled
}

/// Resumes a continuation exactly once, from whichever path gets there first (lane, cancel, poison cap).
final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>
    init(_ c: CheckedContinuation<T, any Error>) { continuation = Mutex(c) }
    func resume(_ result: Result<T, any Error>) {
        let c = continuation.withLock { value -> CheckedContinuation<T, any Error>? in
            defer { value = nil }
            return value
        }
        c?.resume(with: result)
    }
}

/// Broadcasts health changes to any number of AsyncStream subscribers.
final class HealthHub: Sendable {
    typealias Element = (VolumeID, VolumeHealth)
    private let subscribers = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in _ = self?.subscribers.withLock { $0.removeValue(forKey: id) } }
        return stream
    }

    func send(_ element: Element) {
        for c in subscribers.withLock({ Array($0.values) }) { c.yield(element) }
    }
}

/// Per-volume I/O lanes with a stall watchdog (§4.2). See the contract in the overview §3.2.
public actor LanePool {
    public static let shared = LanePool()

    private struct Key: Hashable { var volume: VolumeID; var laneClass: LaneClass }
    private struct Active { var job: LaneJob; var lane: IOLane }

    private let config: WatchdogConfig
    private var lanes: [Key: [IOLane]] = [:]
    private var poisoned: [VolumeID: Int] = [:]
    private var unresponsive: Set<VolumeID> = []
    private var active: [UInt64: Active] = [:]
    private var nextJobID: UInt64 = 0
    private var nextLaneID: UInt64 = 0
    private var watchdog: Task<Void, Never>?
    private nonisolated let hub = HealthHub()
    /// Uptime nanoseconds for heartbeats and watchdog passes.
    private let clock: @Sendable () -> UInt64
    /// Test seam (`init(config:manualClock:)`): no watchdog task; the test runs each pass with `runWatchdogPass()`.
    private let manualWatchdog: Bool

    public init(config: WatchdogConfig = .default) {
        self.config = config
        self.clock = { LaneJob.now() }
        self.manualWatchdog = false
    }

    /// Test seam: a pool whose watchdog never runs on its own. Heartbeats and watchdog passes read `clock` (uptime
    /// nanoseconds, never 0) instead of the system clock, so a test decides when time passes and when the watchdog
    /// looks (`runWatchdogPass()`), and lane-thread scheduling on a slow machine cannot cause or hide a stall.
    init(config: WatchdogConfig, manualClock clock: @escaping @Sendable () -> UInt64) {
        self.config = config
        self.clock = clock
        self.manualWatchdog = true
    }

    deinit {
        for lane in lanes.values.joined() { lane.stop() }
    }

    @discardableResult
    public func perform<T: Sendable>(
        on volume: VolumeID,
        _ laneClass: LaneClass = .read,
        stallPolicy: StallPolicy = .poison,
        onStall: (@Sendable (StallNotice) -> Void)? = nil,
        _ work: @escaping @Sendable (LaneContext) throws -> T
    ) async throws -> T {
        if unresponsive.contains(volume) { throw LaneError.volumeUnresponsive(volume) }
        nextJobID += 1
        let job = LaneJob(id: nextJobID, volume: volume, laneClass: laneClass, policy: stallPolicy, onStall: onStall, clock: clock)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let once = ResumeOnce(continuation)
                let item = IOLane.Item(
                    job: job,
                    run: { [self] in
                        defer { Task { await self.finished(job.id) } }
                        if job.cancelled.load(ordering: .relaxed) {
                            once.resume(.failure(LaneError.cancelled))
                            return
                        }
                        let result = Result<T, any Error> { try work(LaneContext(job: job)) }
                        job.markFinished()
                        once.resume(result)
                    },
                    fail: { error in once.resume(.failure(error)) }
                )
                dispatch(item)
            }
        } onCancel: {
            job.cancelled.store(true, ordering: .relaxed)
            Task { await self.withdraw(job) }
        }
    }

    public func health(of volume: VolumeID) -> VolumeHealth {
        unresponsive.contains(volume) ? .unresponsive : .healthy
    }

    public func poisonedCount(of volume: VolumeID) -> Int { poisoned[volume, default: 0] }

    public func liveLaneCount(of volume: VolumeID, _ laneClass: LaneClass) -> Int {
        lanes[Key(volume: volume, laneClass: laneClass)]?.count ?? 0
    }

    /// Called on remount/reappearance: forget the unresponsive mark and poisoned count.
    public func resetVolume(_ volume: VolumeID) {
        poisoned[volume] = nil
        if unresponsive.remove(volume) != nil { hub.send((volume, .healthy)) }
    }

    /// Test seam (@testable): marks `volume` unresponsive as reaching the poison cap does, so tests of what callers
    /// do with an unresponsive volume need neither a hung lane call nor a short watchdog for their healthy work.
    func markUnresponsive(_ volume: VolumeID) {
        if unresponsive.insert(volume).inserted { hub.send((volume, .unresponsive)) }
    }

    public nonisolated var healthChanges: AsyncStream<(VolumeID, VolumeHealth)> { hub.stream() }

    /// Test seam: jobs dispatched and not yet finished (queued on a lane or running).
    var inFlightJobCount: Int { active.count }

    /// Test seam for `init(config:manualClock:)`: one watchdog pass at the clock's current time.
    func runWatchdogPass() { _ = tickWatchdog() }

    // MARK: Internals

    private func dispatch(_ item: IOLane.Item) {
        let job = item.job
        if unresponsive.contains(job.volume) {
            item.fail(LaneError.volumeUnresponsive(job.volume))
            return
        }
        let key = Key(volume: job.volume, laneClass: job.laneClass)
        var pool = lanes[key, default: []]
        let lane: IOLane
        if pool.count < config.lanesPerClass {
            nextLaneID += 1
            lane = IOLane(id: LaneID(raw: nextLaneID), volume: job.volume, laneClass: job.laneClass)
            pool.append(lane)
            lanes[key] = pool
        } else {
            lane = pool.min { $0.load < $1.load }!
        }
        // Only this actor poisons or stops lanes, so a lane taken from the pool accepts work.
        let accepted = lane.submit(item)
        precondition(accepted, "LanePool: pooled lane refused work")
        active[job.id] = Active(job: job, lane: lane)
        startWatchdogIfNeeded()
    }

    private func finished(_ id: UInt64) {
        active[id] = nil
    }

    /// Cancellation before the job started: take it off its lane and fail it now.
    private func withdraw(_ job: LaneJob) {
        guard let entry = active[job.id], let item = entry.lane.withdraw(job) else { return }
        active[job.id] = nil
        item.fail(LaneError.cancelled)
    }

    private func startWatchdogIfNeeded() {
        guard watchdog == nil, !manualWatchdog else { return }
        let tick = config.tick
        watchdog = Task { [weak self] in
            while true {
                try? await Task.sleep(for: tick)
                guard let self, await self.tickWatchdog() else { return }
            }
        }
    }

    /// One watchdog pass. Returns false (and clears `watchdog`) when nothing is in flight.
    private func tickWatchdog() -> Bool {
        let now = clock()
        let limit = config.stallNanoseconds
        for entry in active.values {
            let job = entry.job
            let beat = job.lastBeat.load(ordering: .relaxed)
            guard WatchdogConfig.isOverdue(lastBeat: beat, now: now, limit: limit), entry.lane.runningJob === job else { continue }
            switch job.policy {
            case .poison:
                guard !job.everStalled.load(ordering: .relaxed) else { continue }
                job.markStalled(.stalled) {
                    job.everStalled.store(true, ordering: .relaxed)
                    poison(entry.lane)
                }
            case .awaitingPermission:
                job.markStalled(.waitingForPermission)
            }
        }
        if active.isEmpty {
            watchdog = nil
            return false
        }
        return true
    }

    private func poison(_ lane: IOLane) {
        let key = Key(volume: lane.volume, laneClass: lane.laneClass)
        lanes[key]?.removeAll { $0 === lane }
        let count = poisoned[lane.volume, default: 0] + 1
        poisoned[lane.volume] = count
        let drained = lane.poison()
        if count >= config.poisonCap, unresponsive.insert(lane.volume).inserted {
            hub.send((lane.volume, .unresponsive))
        }
        for item in drained {
            active[item.job.id] = nil
            dispatch(item)   // fails with volumeUnresponsive past the cap
        }
    }
}
