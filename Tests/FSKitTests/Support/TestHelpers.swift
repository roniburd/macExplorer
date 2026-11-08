import Foundation
import Synchronization

/// Thread-safe recorder for values produced on lane threads.
final class Recorder<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    func append(_ value: T) { items.withLock { $0.append(value) } }
    var values: [T] { items.withLock { $0 } }
}

/// A gate a lane job blocks on (no heartbeats) to simulate a hung syscall. Always open it in teardown.
final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open(count: Int = 1) { for _ in 0..<count { semaphore.signal() } }
}

/// Polls `condition` every 10 ms until true or `timeout`.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Uptime nanoseconds for `LanePool(config:manualClock:)`: time passes only when the test calls `advance(by:)`,
/// so a slow or descheduled lane thread can neither cause nor hide a stall. Starts above 0 (a 0 heartbeat means
/// "not started").
final class ManualClock: Sendable {
    private let nanoseconds = Mutex<UInt64>(1_000_000_000)
    var now: UInt64 { nanoseconds.withLock { $0 } }
    func advance(by duration: Duration) {
        let c = duration.components
        let delta = UInt64(c.seconds) * 1_000_000_000 + UInt64(c.attoseconds / 1_000_000_000)
        nanoseconds.withLock { $0 += delta }
    }
}

/// An async wait the test ends: `wait()` suspends (without blocking a thread) until `release()`.
actor TimeoutLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
