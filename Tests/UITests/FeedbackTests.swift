import XCTest
import AppKit
@testable import UI
@testable import Core

@MainActor
final class FeedbackTests: XCTestCase {
    func testReportBugOpensPrefilledForm() async throws {
        let h = try await ShellHarness.make(self)
        let opener = RecordingURLOpener()
        FeedbackActions.open(.bug, context: h.context, opener: opener)
        let url = try XCTUnwrap(opener.opened.first)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/roniburd/macExplorer/issues/new?template=bug.yml"))
        XCTAssertTrue(url.absoluteString.contains("channel=release"))
    }

    func testRequestFeatureOpensFeatureForm() async throws {
        let h = try await ShellHarness.make(self)
        let opener = RecordingURLOpener()
        FeedbackActions.open(.feature, context: h.context, opener: opener)
        XCTAssertTrue(opener.opened.first?.absoluteString.contains("template=feature.yml") ?? false)
    }

    func testHelpMenuHasFeedbackItems() {
        let menu = MainMenuBuilder.build()
        let help = menu.items.first { $0.identifier?.rawValue == "macx.menu.help" }?.submenu
        let actions = help?.items.compactMap(\.action).map(NSStringFromSelector) ?? []
        XCTAssertTrue(actions.contains("macx_reportBug:"))
        XCTAssertTrue(actions.contains("macx_requestFeature:"))
    }

    func testToolbarHasFeedbackMenuBeforeUpdateBadge() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let window = try XCTUnwrap(controller.window)
        let ids = window.toolbar?.items.map(\.itemIdentifier) ?? []
        let f = try XCTUnwrap(ids.firstIndex(of: ToolbarController.feedbackID))
        let u = try XCTUnwrap(ids.firstIndex(of: ToolbarController.updateID))
        XCTAssertLessThan(f, u)
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == ToolbarController.feedbackID } as? NSMenuToolbarItem)
        XCTAssertEqual(item.menu.identifier?.rawValue, AXID.feedbackMenu)
        XCTAssertEqual(item.menu.items.compactMap(\.action).map(NSStringFromSelector), ["macx_reportBug:", "macx_requestFeature:"])
        XCTAssertFalse(item.label.isEmpty)
    }
}
