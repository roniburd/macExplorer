import Foundation
import XCTest
@testable import MacxFixtures

/// ChildProcess (hdiutil, TrapProbe): output larger than a pipe buffer, and a child that outlives its timeout.
/// Touches no files.
final class ChildProcessTests: XCTestCase {
    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    func testOutputLargerThanThePipeBufferDoesNotHang() throws {
        let clock = ContinuousClock(), start = clock.now
        let outcome = try ChildProcess.run(shell("head -c 300000 /dev/zero | tr '\\000' x; echo done >&2"), timeout: .seconds(30))
        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.output.count, 300_000 + "done\n".count)
        XCTAssertTrue(outcome.output.hasSuffix("done\n"), "stderr shares the pipe")
        XCTAssertLessThan(clock.now - start, .seconds(20))
    }

    func testTimeoutTerminatesAndReapsTheChild() throws {
        let process = shell("exec sleep 60")
        let clock = ContinuousClock(), start = clock.now
        let outcome = try ChildProcess.run(process, timeout: .milliseconds(300))
        XCTAssertTrue(outcome.timedOut)
        XCTAssertFalse(process.isRunning, "terminated and waited for")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertLessThan(clock.now - start, .seconds(15))
    }

    func testFailingStatusIsReported() throws {
        let outcome = try ChildProcess.run(shell("echo oops; exit 3"), timeout: .seconds(30))
        XCTAssertEqual(outcome.status, 3)
        XCTAssertEqual(outcome.output, "oops\n")
        XCTAssertFalse(outcome.timedOut)
    }
}
