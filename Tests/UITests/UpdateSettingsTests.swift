import XCTest
@testable import UI
@testable import Core

@MainActor
final class UpdateSettingsTests: XCTestCase {
    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
    }

    func testSwitchingToBetaTriggersABackgroundCheck() {
        let s = settings(), model = UpdateModel()
        var checks: [Bool] = []
        model.checkHandler = { checks.append($0) }
        SettingsChoices.selectChannel(.beta, in: s, updates: model)
        XCTAssertEqual(s.updateChannel, .beta)
        XCTAssertEqual(checks, [false])
        XCTAssertEqual(model.popoverRequest, 0)
        SettingsChoices.selectChannel(.release, in: s, updates: model)
        XCTAssertEqual(s.updateChannel, .release)
        XCTAssertEqual(checks, [false], "Beta → Release never checks (no downgrade)")
    }

    func testBetaNoteShownOnlyWhenRunningABetaOnRelease() {
        let s = settings()
        XCTAssertFalse(SettingsChoices.showsBetaToReleaseNote(settings: s, installedVersion: "0.4.0"))
        XCTAssertTrue(SettingsChoices.showsBetaToReleaseNote(settings: s, installedVersion: "0.4.0-beta.2"))
        s.updateChannel = .beta
        XCTAssertFalse(SettingsChoices.showsBetaToReleaseNote(settings: s, installedVersion: "0.4.0-beta.2"))
    }

    func testChannelTitles() {
        XCTAssertEqual(SettingsChoices.title(for: UpdateChannel.release), "Release")
        XCTAssertEqual(SettingsChoices.title(for: UpdateChannel.beta), "Beta")
    }

    func testCheckNowGoesThroughTheAppCheckForUpdatesAction() {
        // Branch review: the app action opens a browser window when none is open, so a badge shows the result.
        let model = UpdateModel()
        var checks: [Bool] = [], sent: [Selector] = []
        model.checkHandler = { checks.append($0) }
        SettingsChoices.checkNow(updates: model) { sent.append($0); return true }
        XCTAssertEqual(sent, [UpdateCommands.checkForUpdates])
        XCTAssertEqual(checks, [], "the app action does the check")
        SettingsChoices.checkNow(updates: model) { sent.append($0); return false }
        XCTAssertEqual(checks, [true], "nobody handled the action: the model checks directly")
        XCTAssertEqual(UpdateCommands.checkForUpdates, NSSelectorFromString("macx_checkForUpdates:"))
    }

    func testSettingsWindowStillOpens() async throws {
        let h = try await ShellHarness.make(self)
        let controller = SettingsWindowController.show(context: h.context)
        XCTAssertNotNil(controller.window)
        controller.close()
    }
}
