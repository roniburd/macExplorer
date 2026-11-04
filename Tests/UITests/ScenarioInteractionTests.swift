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
        let deadline = clock.now + .seconds(10)
        while scenario.pendingCount == 0 && clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(scenario.pendingCount, 1)
        XCTAssertTrue(scenario.answer(.one(.replace)))
        let outcome = await q.outcome(of: id)
        XCTAssertFalse(outcome.wasCancelled, "the scenario's answer wins over the presenter's")
        XCTAssertEqual(try Data(contentsOf: sandbox.url("dst/a.txt")), Data("hello".utf8))
        let presented = clock.now + .seconds(2)
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
