import XCTest
import AppKit
@testable import UI
@testable import Core

@MainActor
final class UpdateBadgeTests: XCTestCase {
    func testTextForEachState() {
        XCTAssertNil(UpdateBadgeText.pill(.idle))
        XCTAssertEqual(UpdateBadgeText.pill(.readyToRestart(version: "0.4.0", notesURL: nil)), "Restart to Update")
        XCTAssertEqual(UpdateBadgeText.pill(.checking(userInitiated: true)), "Checking…")
        XCTAssertEqual(UpdateBadgeText.headline(.readyToRestart(version: "0.4.0", notesURL: nil)), "MacExplorer 0.4.0 is ready")
        XCTAssertEqual(UpdateBadgeText.headline(.upToDate(version: "0.3.1")), "You're up to date (0.3.1)")
        XCTAssertEqual(UpdateBadgeText.headline(.failed(.verificationFailed(version: "0.4.0"), userInitiated: false)),
                       "This update couldn't be verified and wasn't installed.")
        XCTAssertEqual(UpdateBadgeText.headline(.failed(.notInApplications, userInitiated: true)),
                       "Move MacExplorer to the Applications folder to get updates.")
        XCTAssertEqual(UpdateBadgeText.headline(.failed(.offline, userInitiated: true)),
                       "Couldn't check for updates. You're offline.")
        XCTAssertEqual(UpdateBadgeText.detail(.downloading(version: "0.4.0", fraction: 0.5, userInitiated: true)), "50%")
    }

    func testItemHiddenUntilVisibleStateAndFollowsModel() {
        let model = UpdateModel()
        let item = UpdateBadgeItem(model: model)
        XCTAssertTrue(item.isHidden)
        model.send(.readyToInstall(version: "0.4.0", notesURL: nil))
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.view?.accessibilityIdentifier(), AXID.updateBadge)
    }

    func testBadgeStaysAfterCancelledRestart() {
        let model = UpdateModel()
        var restarts = 0
        model.restartHandler = { restarts += 1 }   // the real handler runs the quit path; Cancel leaves state alone
        let item = UpdateBadgeItem(model: model)
        model.send(.readyToInstall(version: "0.4.0", notesURL: nil))
        model.restartNow()
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(item.isHidden)
    }

    func testToolbarHasTheUpdateItem() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        let ids = toolbar.items.map(\.itemIdentifier)
        XCTAssertTrue(ids.contains(ToolbarController.updateID))
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == ToolbarController.updateID })
        XCTAssertTrue(item.isHidden, "no controller in tests: the model stays idle and the badge hidden")
    }
}
