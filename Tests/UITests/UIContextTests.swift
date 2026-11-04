import XCTest
@testable import UI
import Core
import MacxFS

@MainActor
final class UIContextTests: XCTestCase {
    private func job() -> JobSnapshot {
        JobSnapshot(id: JobID(), description: JobDescription(verb: .copying, itemCount: 1, firstItemName: nil, sourceFolderName: nil,
                                                             destinationFolderName: nil),
                    state: .running, progress: JobProgress(), origin: nil, startedAt: .now)
    }

    func testInitInstallsInteractionRouter() async throws {   // P1-38 replaces BasicAlertInteraction
        let h = try await ShellHarness.make(self, start: false)
        let context = UIContext(environment: h.environment, options: h.context.options)
        XCTAssertTrue(context.interaction is InteractionRouter)
        XCTAssertTrue(context.windows.windows.isEmpty)
        XCTAssertEqual(context.options, h.context.options)
        XCTAssertTrue(context.environment === h.environment)
        context.installInteraction(h.interaction)   // the harness's script answers again
    }

    func testInstallInteractionTargetsTheEnvironmentProxy() async throws {
        let h = try await ShellHarness.make(self, start: false)
        let scripted = ScriptedInteraction(errors: [.retry])
        h.context.installInteraction(scripted)
        XCTAssertTrue(h.context.interaction as AnyObject === scripted)
        let answer = await h.environment.interaction.resolveError(FileOpError(kind: .inUse, url: h.url("a")), job: job())
        XCTAssertEqual(answer, .retry)
        XCTAssertEqual(scripted.askedErrors().count, 1)
    }
}
