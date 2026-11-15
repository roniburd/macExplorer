import Foundation

public struct ReadOptions: Sendable, Hashable {
    public var directoriesOnly: Bool = false       // tree children
    public var noMaterialization: Bool = false     // background/tree re-reads (§4.2 list)
    public var permissionPending: Bool = false     // → StallPolicy.awaitingPermission
    public var forceFallback: Bool = false         // tests: readdir + fstatat path
    public var batchSize: Int = 2_000
    public var batchInterval: Duration = .milliseconds(8)
    public init() {}
}

public enum ReadEvent: Sendable {
    case batch(Batch)
    case stalled                  // watchdog: no progress for stallTimeout (lane poisoned)
    case waitingForPermission     // stalled while permissionPending
    case resumed                  // a stalled read made progress again
    case completed(ReadSummary)
    case failed(ReadFailure)      // open/read error of the directory itself
}

public struct ReadSummary: Sendable, Equatable {
    public var entryCount: Int
    public var degradedCount: Int
    public var usedFallback: Bool
    public var elapsed: Duration
    public init(entryCount: Int, degradedCount: Int, usedFallback: Bool, elapsed: Duration) {
        self.entryCount = entryCount
        self.degradedCount = degradedCount
        self.usedFallback = usedFallback
        self.elapsed = elapsed
    }
}

public struct ReadFailure: Error, Sendable, Equatable {
    /// `.truncatedRecords`: getattrlistbulk returned a malformed record after batches were already delivered, so the
    /// listing is incomplete (code EIO). Re-read the directory with `ReadOptions.forceFallback`.
    public enum Stage: Sendable, Equatable { case open, read, unresponsiveVolume, truncatedRecords }
    public var code: Int32        // errno (ENOENT, ENOTDIR, EACCES, EPERM, ENXIO, ...)
    public var stage: Stage
    /// Remote rate limits (EAGAIN): when the provider accepts requests again, if it said.
    public var resetAt: Date?
    public init(code: Int32, stage: Stage, resetAt: Date? = nil) { self.code = code; self.stage = stage; self.resetAt = resetAt }
}

/// Batching policy: flush at `batchSize` entries or when `interval` has passed since the last flush.
struct BatchAccumulator {
    let batchSize: Int
    let intervalNanos: UInt64
    let now: () -> UInt64
    private var lastFlush: UInt64

    init(batchSize: Int, interval: Duration, now: @escaping () -> UInt64 = { LaneJob.now() }) {
        self.batchSize = max(1, batchSize)
        let c = interval.components
        self.intervalNanos = UInt64(c.seconds) * 1_000_000_000 + UInt64(c.attoseconds / 1_000_000_000)
        self.now = now
        self.lastFlush = now()
    }

    mutating func shouldFlush(count: Int) -> Bool {
        guard count > 0 else { return false }
        if count >= batchSize || now() &- lastFlush >= intervalNanos {
            lastFlush = now()
            return true
        }
        return false
    }
}
