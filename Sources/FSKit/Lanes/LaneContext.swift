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
    let stalled = Atomic<Bool>(false)         // a .stalled/.waitingForPermission notice is outstanding
    let everStalled = Atomic<Bool>(false)     // .poison jobs report .stalled at most once
    let laneID = Atomic<UInt64>(0)

    init(id: UInt64, volume: VolumeID, laneClass: LaneClass, policy: StallPolicy,
         onStall: (@Sendable (StallNotice) -> Void)?) {
        self.id = id
        self.volume = volume
        self.laneClass = laneClass
        self.policy = policy
        self.onStall = onStall
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func beat() {
        lastBeat.store(LaneJob.now(), ordering: .relaxed)
        if stalled.exchange(false, ordering: .acquiringAndReleasing) {
            onStall?(.resumed)
        }
    }
}

public struct LaneContext: Sendable {
    let job: LaneJob

    /// Call at least every 250 ms while making progress (after each syscall batch, per emitted batch).
    public func heartbeat() { job.beat() }
    /// True once the awaiting Task was cancelled. Work should return promptly (partial results are fine).
    public var isCancelled: Bool { job.cancelled.load(ordering: .relaxed) }
    public var laneID: LaneID { LaneID(raw: job.laneID.load(ordering: .relaxed)) }
}
