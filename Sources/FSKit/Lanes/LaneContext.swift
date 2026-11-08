import Dispatch
import Synchronization

/// Per-job state shared by the lane thread (heartbeats), the awaiting task (cancellation) and the watchdog.
final class LaneJob: Sendable {
    let id: UInt64
    let volume: VolumeID
    let laneClass: LaneClass
    let policy: StallPolicy
    let onStall: (@Sendable (StallNotice) -> Void)?
    let lastBeat = Atomic<UInt64>(0)          // DispatchTime uptime nanoseconds; 0 = not started
    let cancelled = Atomic<Bool>(false)
    private let stall = Mutex<StallState>(.running)
    let everStalled = Atomic<Bool>(false)     // .poison jobs report .stalled at most once
    let laneID = Atomic<UInt64>(0)
    /// Heartbeat clock (uptime nanoseconds): `LaneJob.now` in the app, a manual clock in watchdog tests.
    private let clock: @Sendable () -> UInt64

    init(id: UInt64, volume: VolumeID, laneClass: LaneClass, policy: StallPolicy,
         onStall: (@Sendable (StallNotice) -> Void)?, clock: @escaping @Sendable () -> UInt64 = { LaneJob.now() }) {
        self.id = id
        self.volume = volume
        self.laneClass = laneClass
        self.policy = policy
        self.onStall = onStall
        self.clock = clock
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func beat() {
        lastBeat.store(clock(), ordering: .relaxed)
        stall.withLock { state in
            guard state == .stalled else { return }
            state = .running
            onStall?(.resumed)
        }
    }

    /// Watchdog: a running job without a recent heartbeat. Runs `action` (e.g. poisoning the lane) and then
    /// reports `notice`, both under the stall lock, so a job that already finished (or whose stall is still
    /// outstanding) reports nothing. Returns whether the notice was sent.
    @discardableResult
    func markStalled(_ notice: StallNotice, action: () -> Void = {}) -> Bool {
        stall.withLock { state in
            guard state == .running else { return false }
            state = .stalled
            action()
            onStall?(notice)
            return true
        }
    }

    /// Lane thread: the work returned. Reports .resumed if a stall notice is outstanding; no stall after this.
    func markFinished() {
        stall.withLock { state in
            if state == .stalled { onStall?(.resumed) }
            state = .finished
        }
    }
}

enum StallState: Sendable { case running, stalled, finished }

public struct LaneContext: Sendable {
    let job: LaneJob

    /// Call at least every 250 ms while making progress (after each syscall batch, per emitted batch).
    public func heartbeat() { job.beat() }
    /// True once the awaiting Task was cancelled. Work should return promptly (partial results are fine).
    public var isCancelled: Bool { job.cancelled.load(ordering: .relaxed) }
    public var laneID: LaneID { LaneID(raw: job.laneID.load(ordering: .relaxed)) }
}
