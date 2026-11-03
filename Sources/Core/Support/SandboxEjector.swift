import Foundation
import Darwin
import Synchronization
import MacxFS

/// `Ejecting` for sandboxed environments (tests, macx-scenarios): only disk images mounted under `root` are
/// detached (`hdiutil detach` without -force, so a busy volume reports busy). Everything else is refused before
/// any tool runs. Tools run on a fileOp lane of the image's volume and heartbeat while they wait.
public struct SandboxEjector: Ejecting {
    struct Holder: Sendable, Equatable { var pid: Int32; var command: String }

    let root: URL
    let lanes: LanePool

    /// Public for the app's sandbox mode (P1-26 AppBootstrap): only images mounted under `root` can be ejected.
    public init(root: URL, lanes: LanePool) { self.root = root; self.lanes = lanes }

    func isInside(_ mountPoint: URL) -> Bool {
        let r = CoreEnvironment.canonicalTempPath(root.standardizedFileURL.path)
        let m = CoreEnvironment.canonicalTempPath(mountPoint.standardizedFileURL.path)
        return m.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    private func lane(_ mountPoint: URL) -> VolumeID { VolumeID(raw: "mnt:" + mountPoint.standardizedFileURL.path) }

    public func eject(_ mountPoint: URL) async throws(EjectError) {
        guard isInside(mountPoint) else { throw EjectError.failed(code: EPERM, message: "") }
        let path = mountPoint.standardizedFileURL.path
        let result: (status: Int32, output: String)
        do {
            result = try await lanes.perform(on: lane(mountPoint), .fileOp) { lane in
                Self.runTool("/usr/bin/hdiutil", ["detach", path], timeout: .seconds(30), lane: lane)
            }
        } catch {
            throw EjectError.failed(code: EIO, message: "")
        }
        guard result.status != 0 else { return }
        if result.output.localizedCaseInsensitiveContains("busy") {
            throw EjectError.busy(processes: await blockingProcesses(mountPoint, timeout: .seconds(2)))
        }
        throw EjectError.failed(code: result.status, message: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func blockingProcesses(_ mountPoint: URL, timeout: Duration) async -> [String] {
        let me = getpid()
        var names: [String] = []
        for h in await holders(mountPoint, timeout: timeout) where h.pid != me && !names.contains(h.command) {
            names.append(h.command)
        }
        return names
    }

    public func onlyOwnProcessHolds(_ mountPoint: URL, timeout: Duration) async -> Bool {
        let me = getpid()
        let h = await holders(mountPoint, timeout: timeout)
        return h.contains { $0.pid == me } && h.allSatisfy { $0.pid == me }
    }

    private func holders(_ mountPoint: URL, timeout: Duration) async -> [Holder] {
        guard isInside(mountPoint) else { return [] }
        let path = mountPoint.standardizedFileURL.path
        let out = try? await lanes.perform(on: lane(mountPoint), .fileOp) { lane in
            Self.runTool("/usr/sbin/lsof", ["-F", "pc", "--", path], timeout: timeout, lane: lane)
        }
        return Self.parseLsof(out?.output ?? "")
    }

    /// `lsof -F pc` output: "p<pid>" then "c<command>" lines (other field lines ignored).
    static func parseLsof(_ output: String) -> [Holder] {
        var out: [Holder] = []
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            else if line.hasPrefix("c"), let p = pid { out.append(Holder(pid: p, command: String(line.dropFirst()))) }
        }
        return out
    }

    final class OutputBox: Sendable {
        let data = Mutex(Data())
    }

    /// Lane only. Runs a tool, heartbeating while it runs; terminates it after `timeout` (status ETIMEDOUT).
    static func runTool(_ tool: String, _ arguments: [String], timeout: Duration, lane: LaneContext) -> (status: Int32, output: String) {
        assertOffMain()
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let box = OutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            box.data.withLock { $0.append(chunk) }
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (ENOENT, "")
        }
        let deadline = ContinuousClock.now + timeout
        var timedOut = false
        while process.isRunning {
            lane.heartbeat()
            if ContinuousClock.now > deadline { timedOut = true; process.terminate(); break }
            usleep(20_000)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        let data = box.data.withLock { $0 } + rest
        return (timedOut ? ETIMEDOUT : process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
