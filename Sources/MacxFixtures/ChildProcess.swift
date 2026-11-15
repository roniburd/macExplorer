import Darwin
import Foundation
import Synchronization

/// Runs a configured Process with stdout+stderr on one pipe that is drained while the child runs (a child writing more
/// than the pipe buffer, 64 KB, never blocks waiting for a reader that only starts after exit). On timeout the child
/// gets SIGTERM, then SIGKILL if it hasn't exited 5 s later, and is always reaped before this returns.
enum ChildProcess {
    struct Outcome: Sendable {
        var status: Int32
        var output: String
        var timedOut: Bool
    }

    /// Thread-safe sink the drain thread appends to.
    private final class Collected: Sendable {
        let data = Mutex(Data())
        let done = DispatchSemaphore(value: 0)
    }

    static func run(_ process: Process, timeout: Duration) throws -> Outcome {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let collected = Collected()
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            while true {
                let chunk = reader.availableData       // empty at EOF (every writer closed)
                if chunk.isEmpty { break }
                collected.data.withLock { $0.append(chunk) }
            }
            collected.done.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + seconds(timeout)) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // A grandchild that inherited the pipe can keep it open past the child's exit: don't wait for it forever.
        _ = collected.done.wait(timeout: .now() + 5)
        let output = String(decoding: collected.data.withLock { $0 }, as: UTF8.self)
        return Outcome(status: process.terminationStatus, output: output, timedOut: timedOut)
    }

    private static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
