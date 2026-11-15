import Darwin
import Foundation

/// Proves that a code path traps (preconditionFailure) by re-running one XCTest method of the current
/// test bundle in a child `xctest` process. The child sees `MACX_TRAP_PROBE=<name>`; when it traps, a
/// signal handler exits with `TrapProbe.trappedStatus` so no crash report is written.
public enum TrapProbe {
    public static let environmentKey = "MACX_TRAP_PROBE"
    public static let trappedStatus: Int32 = 86

    public struct Result: Sendable, Equatable {
        public var status: Int32
        public var trapped: Bool { status == TrapProbe.trappedStatus }
        public var output: String
    }

    /// Call first thing inside the probe test. Returns true in the child (and installs the trap handler).
    public static func isChild(_ name: String) -> Bool {
        guard ProcessInfo.processInfo.environment[environmentKey] == name else { return false }
        for sig in [SIGTRAP, SIGILL, SIGABRT] {
            signal(sig) { _ in _exit(TrapProbe.trappedStatus) }
        }
        return true
    }

    /// The value the parent passed for `key` (e.g. a sandbox root the child adopts).
    public static func value(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

    public struct TimedOut: Error, Sendable, CustomStringConvertible {
        public var testIdentifier: String
        public var output: String
        public var description: String { "trap probe \(testIdentifier) did not exit within its timeout\n\(output.suffix(2000))" }
    }

    /// Runs `xcrun xctest -XCTest <testIdentifier> <bundle>` with the probe environment and waits (≤ `timeout`). A child
    /// still running then is terminated (SIGKILL if needed), reaped, and reported by throwing `TimedOut`.
    public static func run(name: String, testIdentifier: String, bundle: URL,
                           environment: [String: String] = [:], timeout: Duration = .seconds(120)) throws -> Result {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", testIdentifier, bundle.path(percentEncoded: false)]
        var env = ProcessInfo.processInfo.environment
        env[environmentKey] = name
        env.merge(environment) { _, new in new }
        process.environment = env
        let outcome = try ChildProcess.run(process, timeout: timeout)
        if outcome.timedOut { throw TimedOut(testIdentifier: testIdentifier, output: outcome.output) }
        return Result(status: outcome.status, output: outcome.output)
    }
}
