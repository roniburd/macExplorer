@testable import Core
import Foundation
import MacxFixtures
import XCTest

@MainActor
final class OperationsCenterExternalTests: XCTestCase {
    func testExternalActivityIsListedUpdatedCancelledAndEnded() async throws {
        let sandbox = try Sandbox()
        addTeardownBlock { sandbox.destroy() }
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        let ops = env.operations
        var cancelled = false
        let id = ops.beginExternal(JobDescription(verb: .downloading, itemCount: 2, firstItemName: "a.txt",
                                                  sourceFolderName: "demo", destinationFolderName: "dest"),
                                   cancel: { cancelled = true })
        XCTAssertEqual(ops.jobs.map(\.id), [id])
        var p = JobProgress(); p.itemsDone = 1; p.itemsTotal = 2
        ops.updateExternal(id, p)
        XCTAssertEqual(ops.jobs.first?.progress.itemsDone, 1)
        XCTAssertTrue(ops.cancelExternal(id))
        XCTAssertTrue(cancelled)
        XCTAssertEqual(ops.jobs.first?.state, .cancelling)
        ops.endExternal(id)
        XCTAssertTrue(ops.jobs.isEmpty)
        XCTAssertFalse(ops.cancelExternal(JobID()), "a queue job is not external")
    }
}
