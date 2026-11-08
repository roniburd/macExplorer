import XCTest
import Core
import MacxFS
import MacxFixtures
@testable import UI

final class ScenarioInteractionTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws {
        sandbox = try Sandbox(prefix: "macx-tests")
        addTeardownBlock { [sandbox] in sandbox?.destroy() }
    }

    private func queue(_ interaction: any FileOpInteraction) throws -> FileOpQueue {
        let trash = try sandbox.createDirectory("trash")
        let state = try sandbox.createDirectory("state")
        return FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trash),
                           journal: Journal(fileURL: state.appending(path: "journal.json")),
                           interaction: interaction)
    }

    func testConflictIsPresentedByTheRealTargetButAnsweredByTheScenario() async throws {
        let src = try sandbox.createFile("src/a.txt", contents: Data("hello".utf8))
        try sandbox.createFile("dst/a.txt", contents: Data("x".utf8))
        let presenter = ScriptedInteraction(conflicts: [.cancelJob])     // would cancel if its answer were used
        let scenario = ScenarioInteraction(forwardingTo: presenter)
        let q = try queue(scenario)
        XCTAssertFalse(scenario.answer(.one(.skip)), "nothing pending yet")
        let id = await q.enqueue(JobRequest(.copy(sources: [src], destination: sandbox.url("dst")), registersUndo: false))
        let clock = ContinuousClock()
        // Generous: under a loaded parallel run the conflict took over 10 s. Without a pending conflict the job can
        // never finish, so fail instead of awaiting its outcome forever (that hung the whole test gate).
        let deadline = clock.now + .seconds(60)
        while scenario.pendingCount == 0 && clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard scenario.pendingCount == 1 else {
            await q.cancel(id)
            return XCTFail("no conflict pending after 60 s (pending \(scenario.pendingCount))")
        }
        XCTAssertTrue(scenario.answer(.one(.replace)))
        let outcome = await q.outcome(of: id)
        XCTAssertFalse(outcome.wasCancelled, "the scenario's answer wins over the presenter's")
        XCTAssertEqual(try Data(contentsOf: sandbox.url("dst/a.txt")), Data("hello".utf8))
        // The presenter runs in its own task on the cooperative pool, which a loaded runner can starve for seconds
        // after the job finished: the same generous condition wait as the conflict above.
        let presented = clock.now + .seconds(60)
        while presenter.askedConflicts().isEmpty && clock.now < presented { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(presenter.askedConflicts().count, 1, "the real dialog path was still invoked")
        XCTAssertEqual(scenario.askedCount, 1)
    }

    func testErrorsAreForwardedUnchanged() async throws {
        let presenter = ScriptedInteraction(errors: [.skip])
        let q = try queue(ScenarioInteraction(forwardingTo: presenter))
        let destination = try sandbox.createDirectory("d")
        let id = await q.enqueue(JobRequest(.copy(sources: [sandbox.url("missing.txt")], destination: destination), registersUndo: false))
        _ = await q.outcome(of: id)
        XCTAssertEqual(presenter.askedErrors().first?.kind, .sourceGone)
    }
}
