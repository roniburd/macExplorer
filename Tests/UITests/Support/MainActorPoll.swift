import XCTest

/// Polls `condition` on the main actor every 10 ms (ObservationLoop and other main-actor tasks run in between);
/// a timeout is an XCTFail at the caller's line and a thrown error.
@MainActor
func pollUntil(_ what: String, timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("timed out after \(timeout) waiting for: \(what)", file: file, line: line)
            throw PollTimeout(what: what)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct PollTimeout: Error { let what: String }
