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
func eventually(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
