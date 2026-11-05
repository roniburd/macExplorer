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

    // MARK: review of Task 10 — restored toolbar configurations get the feedback menu once

    func testFirstWindowMarksTheFeedbackItemOffered() async throws {
        let h = try await ShellHarness.make(self)
        XCTAssertFalse(h.context.environment.settings.toolbarFeedbackItemOffered, "precondition")
        _ = try await h.openWindow()
        XCTAssertTrue(h.context.environment.settings.toolbarFeedbackItemOffered)
    }

    func testRestoredConfigurationWithoutFeedbackGetsItOnceBeforeTheBadge() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        // What an autosaved configuration from a build before the feedback menu looks like, on a first launch of this build.
        toolbar.itemIdentifiers = [ToolbarController.navigationID, ToolbarController.addressID, ToolbarController.searchID,
                                  ToolbarController.viewSwitcherID, ToolbarController.updateID]
        h.context.environment.settings.toolbarFeedbackItemOffered = false
        controller.toolbarController.ensureDefaultItems(in: toolbar)
        XCTAssertEqual(Array(toolbar.items.map(\.itemIdentifier).suffix(2)), [ToolbarController.feedbackID, ToolbarController.updateID])
        XCTAssertTrue(h.context.environment.settings.toolbarFeedbackItemOffered)
        controller.toolbarController.ensureDefaultItems(in: toolbar)
        XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier == ToolbarController.feedbackID }.count, 1)
    }

    func testRestoredConfigurationMissingBothGetsFeedbackThenBadge() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        toolbar.itemIdentifiers = [ToolbarController.navigationID, ToolbarController.addressID]   // a Phase 1 customization
        h.context.environment.settings.toolbarFeedbackItemOffered = false
        controller.toolbarController.ensureDefaultItems(in: toolbar)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), [ToolbarController.navigationID, ToolbarController.addressID,
                                                             ToolbarController.feedbackID, ToolbarController.updateID])
    }

    func testRestoredConfigurationGetsTheNewTabButtonOnceAfterTheViewSwitcher() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        toolbar.itemIdentifiers = [ToolbarController.navigationID, ToolbarController.viewSwitcherID, ToolbarController.updateID]
        h.context.environment.settings.toolbarNewTabItemOffered = false
        controller.toolbarController.ensureDefaultItems(in: toolbar)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), [ToolbarController.navigationID, ToolbarController.viewSwitcherID,
                                                             ToolbarController.newTabID, ToolbarController.updateID])
        XCTAssertTrue(h.context.environment.settings.toolbarNewTabItemOffered)
        toolbar.removeItem(at: 2)
        controller.toolbarController.ensureDefaultItems(in: toolbar)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier == ToolbarController.newTabID }, "removed on purpose stays removed")
    }

    func testFeedbackItemTheUserRemovedStaysRemoved() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        XCTAssertTrue(h.context.environment.settings.toolbarFeedbackItemOffered, "already offered by the first window")
        let index = try XCTUnwrap(toolbar.items.firstIndex { $0.itemIdentifier == ToolbarController.feedbackID })
        toolbar.removeItem(at: index)
        controller.toolbarController.ensureDefaultItems(in: toolbar)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier == ToolbarController.feedbackID })
        XCTAssertTrue(toolbar.items.contains { $0.itemIdentifier == ToolbarController.updateID })
    }
}
