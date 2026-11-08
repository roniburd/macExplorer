import Core
import Darwin
import Foundation
import Synchronization

struct ScenarioFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ScenarioSkip: Error, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { "skipped: \(reason)" }
}

struct CoreScenario: Sendable {
    enum Requirement: Sendable, Equatable { case none, diskImages, helperProcess }
    let name: String
    let requires: Requirement
    let timeout: Duration
    let body: @MainActor @Sendable (ScenarioContext) async throws -> Void

    init(_ name: String, requires: Requirement = .none, timeout: Duration = .seconds(60),
         _ body: @escaping @MainActor @Sendable (ScenarioContext) async throws -> Void) {
        self.name = name
        self.requires = requires
        self.timeout = timeout
        self.body = body
    }
}

enum Deadline {
    /// Waits for `task` up to `timeout`. nil on timeout (the task keeps running; the caller decides).
    static func wait<T: Sendable>(for task: Task<T, Never>, timeout: Duration) async -> T? {
        let (stream, continuation) = AsyncStream<T?>.makeStream()
        let waiter = Task { continuation.yield(await task.value) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(nil)
        }
        defer {
            waiter.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await value in stream { return value }
        return nil
    }

    static func run<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await wait(for: Task { await operation() }, timeout: timeout)
    }
}

/// Holds a copy at its first copied chunk until the scenario has paused or cancelled the job, so "mid-copy" does not
/// depend on how fast the runner copies. The hook runs on the copy's lane (`FaultPoint.midCopyChunk`); the copy's
/// pause/cancel checkpoint runs right after it, so a pause or cancel issued while held takes effect before another
/// byte is copied. The hold is bounded (`limit`) so a scenario that fails early never wedges the lane.
final class ChunkGate: Sendable {
    private let state = Mutex((reached: false, opened: false))
    private let released = DispatchSemaphore(value: 0)
    private let limit: Duration

    init(limit: Duration = .seconds(60)) { self.limit = limit }

    var isHeld: Bool { state.withLock { $0.reached && !$0.opened } }

    /// 256 KiB chunks: a 64 MiB file reaches the first chunk long before its end.
    var tuning: FileOpTuning {
        FileOpTuning(copyChunkBytes: 256 << 10, faultHook: { [self] point, _ in
            guard point == .midCopyChunk else { return }
            let hold = state.withLock { s -> Bool in
                guard !s.reached else { return false }
                s.reached = true
                return true
            }
            guard hold else { return }
            let seconds = Double(limit.components.seconds)
            _ = released.wait(timeout: .now() + seconds)
        })
    }

    /// Lets the held copy go on (idempotent).
    func open() {
        let first = state.withLock { s -> Bool in
            guard !s.opened else { return false }
            s.opened = true
            return true
        }
        if first { released.signal() }
    }
}
