import Core
import Darwin
import Foundation

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

extension FileOpTuning {
    /// 256 KiB chunks with a 3 ms pause each: a 64 MiB copy takes about 0.8 s, so pause/cancel land mid-file.
    static var slowChunks: FileOpTuning {
        FileOpTuning(copyChunkBytes: 256 << 10, faultHook: { point, _ in
            if point == .midCopyChunk { usleep(3_000) }
        })
    }
}
