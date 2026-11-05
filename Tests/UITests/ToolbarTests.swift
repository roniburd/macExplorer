import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class ToolbarTests: XCTestCase {
    func testToolbarHasNavigationAddressSearchAndViewSwitcher() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        XCTAssertTrue(toolbar.delegate === controller.toolbarController)
        let ids = toolbar.items.map(\.itemIdentifier)
        for id in [ToolbarController.navigationID, ToolbarController.addressID, ToolbarController.searchID,
                   ToolbarController.viewSwitcherID, ToolbarController.feedbackID, ToolbarController.updateID] {
            XCTAssertTrue(ids.contains(id), "\(id.rawValue) in \(ids.map(\.rawValue))")
        }
        let nav = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == ToolbarController.navigationID } as? NSToolbarItemGroup)
        XCTAssertEqual(nav.subitems.count, 3)
        let search = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == ToolbarController.searchID } as? NSSearchToolbarItem)
        XCTAssertEqual(search.searchField.accessibilityIdentifier(), AXID.search)
        let address = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == ToolbarController.addressID })
        XCTAssertTrue(address.view === controller.addressBar)
        XCTAssertFalse(toolbar.autosavesConfiguration, "no autosave in sandbox mode")
    }

    func testCustomizationPaletteGetsPlaceholdersNotTheLiveItems() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        let delegate = controller.toolbarController
        for id in delegate.toolbarDefaultItemIdentifiers(toolbar) {
            let live = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == id })
            let palette = try XCTUnwrap(delegate.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false))
            XCTAssertFalse(palette === live, "\(id.rawValue): a fresh palette item")
            XCTAssertNil(palette.view, "\(id.rawValue): no shared view")
            XCTAssertEqual(palette.itemIdentifier, id)
            XCTAssertFalse(palette.label.isEmpty, "\(id.rawValue) has a label")
            XCTAssertNotNil(palette.image, "\(id.rawValue) has an image")
            XCTAssertTrue(delegate.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true) === live)
        }
        let address = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == ToolbarController.addressID })
        XCTAssertTrue(address.view === controller.addressBar, "the live address bar stays in the toolbar")
        XCTAssertTrue(controller.toolbarController.searchItem.searchField === controller.toolbarController.search.field)
    }

    // MARK: navigation buttons

    func testNavigationButtonsFollowHistory() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let controller = try await h.openWindow()
        let nav = controller.toolbarController.navigation
        XCTAssertFalse(nav.backButton.isEnabled)
        XCTAssertFalse(nav.forwardButton.isEnabled)
        XCTAssertTrue(nav.upButton.isEnabled)
        for button in [nav.backButton, nav.forwardButton, nav.upButton] {
            XCTAssertFalse((button.accessibilityLabel() ?? "").isEmpty, "icon-only buttons have labels")
        }
        controller.navigate(to: h.url("sub"))
        XCTAssertTrue(nav.backButton.isEnabled)
        nav.backButton.performClick(nil)
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "files")
        XCTAssertTrue(nav.forwardButton.isEnabled)
        XCTAssertFalse(nav.backButton.isEnabled)
        nav.forwardButton.performClick(nil)
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "sub")
        nav.upButton.performClick(nil)
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "files")
        try await h.waitUntil("up selects the child") { controller.probeSelectedNames == ["sub"] }
    }

    func testUpIsDisabledOnlyAtTheFileSystemRoot() {
        // Pure path checks; nothing is read.
        XCTAssertFalse(NavigationButtons.canGoUp(from: URL(filePath: "/", directoryHint: .isDirectory)))
        XCTAssertTrue(NavigationButtons.canGoUp(from: URL(filePath: "/Library", directoryHint: .isDirectory)))
    }

    func testHistoryMenusListAndJump() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("a"); try h.dir("b"); try h.dir("c")
        let controller = try await h.openWindow()
        let nav = controller.toolbarController.navigation
        for name in ["a", "b", "c"] { controller.navigate(to: h.url(name)) }
        let back = nav.backMenu()
        XCTAssertEqual(back.items.map(\.title), ["b", "a", "files"], "most recent first")
        let item = back.items[1]
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "a")
        XCTAssertEqual(nav.forwardMenu().items.map(\.title), ["b", "c"], "next first")
        XCTAssertEqual(nav.backMenu().items.map(\.title), ["files"])
        let forward = nav.forwardMenu().items[1]
        _ = forward.target?.perform(forward.action, with: forward)
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "c")
        XCTAssertEqual(nav.backMenu().items.map(\.title), ["b", "a", "files"])
        XCTAssertNotNil(nav.backButton.historyMenu, "long-press / right-click menu installed")
    }

    func testSessionJumpsKeepHistoryConsistent() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("a"); try h.dir("b")
        let controller = try await h.openWindow()
        let session = controller.session
        session.navigate(to: h.url("a")); session.navigate(to: h.url("b"))
        session.goBack(toIndex: 0)
        XCTAssertEqual(session.folder.directory.lastPathComponent, "files")
        XCTAssertEqual(session.history.forwardList.map(\.lastPathComponent), ["a", "b"])
        session.goForward(toIndex: 1)
        XCTAssertEqual(session.folder.directory.lastPathComponent, "b")
        session.goForward(toIndex: 5)   // out of range: nothing
        XCTAssertEqual(session.folder.directory.lastPathComponent, "b")
    }

    // MARK: search filter

    func testSearchFieldFiltersLiveAndClearsOnNavigation() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("Résumé.pdf"); try h.file("resume-old.txt"); try h.file("notes.txt"); try h.dir("sub")
        let controller = try await h.openWindow()
        let search = controller.toolbarController.search
        XCTAssertEqual(search.field.accessibilityIdentifier(), AXID.search)
        search.field.stringValue = "RESUME"
        search.textDidChange()
        XCTAssertEqual(controller.session.folder.query.filter, "RESUME")
        try await h.waitUntil("filtered") { Set(controller.probeRowNames) == ["Résumé.pdf", "resume-old.txt"] }
        search.field.stringValue = ""
        search.textDidChange()
        try await h.waitUntil("unfiltered") { controller.probeRowNames.count == 4 }
        search.field.stringValue = "notes"
        search.textDidChange()
        controller.navigate(to: h.url("sub"))
        XCTAssertEqual(search.field.stringValue, "", "the filter clears on navigation")
        XCTAssertEqual(controller.session.folder.query.filter, "")
        controller.session.goBack()
        try await h.waitUntil("back unfiltered") { controller.probeRowNames.count == 4 }
    }

    func testSearchKeepsSortAndHiddenFlags() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let folder = controller.session.folder
        folder.setQuery(ViewQuery(sort: SortDescriptor(field: .size, ascending: false), showHidden: true))
        let search = controller.toolbarController.search
        search.field.stringValue = "x"
        search.textDidChange()
        XCTAssertEqual(folder.query, ViewQuery(sort: SortDescriptor(field: .size, ascending: false), showHidden: true, filter: "x"))
    }

    func testFocusSearchMakesTheFieldFirstResponder() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        controller.toolbarController.beginSearch()
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate as? NSSearchField === controller.toolbarController.search.field)
        XCTAssertEqual(controller.probeFocus, .fieldEditor)
    }

    // MARK: view switcher

    func testViewSwitcherSetsAndFollowsTheViewMode() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let switcher = controller.toolbarController.viewSwitcher
        XCTAssertEqual(switcher.subitems.count, ToolbarController.switcherModes.count)
        XCTAssertEqual(switcher.selectedIndex, ToolbarController.switcherModes.firstIndex(of: controller.session.viewMode))
        controller.toolbarController.selectViewMode(at: 1)
        XCTAssertEqual(controller.session.viewMode, .icons)
        XCTAssertEqual(h.environment.settings.viewMode, .icons)
        controller.session.viewMode = .details
        XCTAssertEqual(switcher.selectedIndex, 0)
        XCTAssertTrue(switcher.subitems.allSatisfy { !$0.label.isEmpty })
    }
}
