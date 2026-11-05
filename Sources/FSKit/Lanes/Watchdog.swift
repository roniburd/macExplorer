public enum StallPolicy: Sendable, Hashable {
    case poison               // default: no heartbeat for stallTimeout → lane poisoned, notice .stalled
    case awaitingPermission   // TCC location without recorded outcome: notice .waitingForPermission, never poison
}

public enum StallNotice: Sendable, Equatable { case stalled, waitingForPermission, resumed }

public struct WatchdogConfig: Sendable, Equatable {
    public var stallTimeout: Duration      // default .seconds(2)
    public var tick: Duration              // default .milliseconds(250)
    public var lanesPerClass: Int          // default 2 (per volume, per LaneClass)
    public var poisonCap: Int              // default 4 (per volume, all classes)
    public static let `default` = WatchdogConfig()
    public init(stallTimeout: Duration = .seconds(2), tick: Duration = .milliseconds(250), lanesPerClass: Int = 2, poisonCap: Int = 4) {
        self.stallTimeout = stallTimeout
        self.tick = tick
        self.lanesPerClass = lanesPerClass
        self.poisonCap = poisonCap
    }

    var stallNanoseconds: UInt64 {
        let c = stallTimeout.components
        return UInt64(c.seconds) * 1_000_000_000 + UInt64(c.attoseconds / 1_000_000_000)
    }

    /// No heartbeat for `limit` ns. A beat newer than `now` (the lane beat after the watchdog read the clock)
    /// is fresh, not a wrapped-around stall.
    static func isOverdue(lastBeat: UInt64, now: UInt64, limit: UInt64) -> Bool {
        lastBeat != 0 && now > lastBeat && now - lastBeat >= limit
    }
}
