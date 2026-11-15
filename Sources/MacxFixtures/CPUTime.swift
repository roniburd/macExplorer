import Darwin

/// CPU time consumed by the calling thread. Unit tests that bound a cost use it instead of wall time: under
/// `swift test --parallel` a thread waiting for a core accrues wall time but no CPU time. (Real budgets are
/// macx-bench's, on a release build.)
public enum CPUTime {
    public static func thread() -> Duration {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return .seconds(Int64(ts.tv_sec)) + .nanoseconds(Int64(ts.tv_nsec))
    }

    /// The calling thread's CPU time spent in `body` (synchronous, single-threaded work only).
    public static func measure(_ body: () throws -> Void) rethrows -> Duration {
        let start = thread()
        try body()
        return thread() - start
    }
}
