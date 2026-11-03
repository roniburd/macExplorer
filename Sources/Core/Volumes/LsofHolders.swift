import Darwin
import Foundation
import MacxFS
import Synchronization

/// Processes holding files open on a mount point, from `lsof -F pc +f -- <mount point>` (§5.9).
enum LsofHolders {
    struct Holder: Sendable, Equatable { var pid: Int32; var command: String }

    /// Lane only. Runs lsof with a timeout; an empty list when it fails or times out.
    static func holders(of mountPoint: URL, timeout: Duration, lane: LaneContext) -> [Holder] {
        let path = mountPoint.standardizedFileURL.path(percentEncoded: false)
        let result = ToolRunner.run("/usr/sbin/lsof", ["-F", "pc", "+f", "--", path], timeout: timeout, lane: lane)
        return parse(result.output)
    }

    /// `-F pc` output: "p<pid>" starts a process set, "c<command>" names it; other fields are ignored.
    static func parse(_ output: String) -> [Holder] {
        var out: [Holder] = []
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("c"), let p = pid {
                out.append(Holder(pid: p, command: String(line.dropFirst())))
                pid = nil
            }
        }
        return out
    }

    /// Distinct command names in first-seen order, without `pid`'s.
    static func names(_ holders: [Holder], excluding pid: Int32) -> [String] {
        var names: [String] = []
        for h in holders where h.pid != pid && !names.contains(h.command) { names.append(h.command) }
        return names
    }

    static func onlyHeld(by pid: Int32, _ holders: [Holder]) -> Bool {
        !holders.isEmpty && holders.allSatisfy { $0.pid == pid }
    }
}

/// Runs a command-line tool on the current lane thread, heartbeating while it runs, terminating it at `timeout`.
enum ToolRunner {
    private final class Output: Sendable {
        let data = Mutex(Data())
        let eof = DispatchSemaphore(value: 0)
    }

    static func run(_ tool: String, _ arguments: [String], timeout: Duration, lane: LaneContext) -> (status: Int32, output: String) {
        assertOffMain()
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let output = Output()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                output.eof.signal()
            } else {
                output.data.withLock { $0.append(chunk) }
            }
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (ENOENT, "")
        }
        let deadline = ContinuousClock.now + timeout
        var timedOut = false
        while process.isRunning {
            lane.heartbeat()
            if lane.isCancelled || ContinuousClock.now > deadline {
                timedOut = true
                process.terminate()
                break
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        if output.eof.wait(timeout: .now() + 1) == .timedOut { pipe.fileHandleForReading.readabilityHandler = nil }
        let all = output.data.withLock { $0 }
        return (timedOut ? ETIMEDOUT : process.terminationStatus, String(decoding: all, as: UTF8.self))
    }
}
