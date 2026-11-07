import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS

/// P3-10 in a window: results in the content, the address bar and title, the scope bar, the results command target,
/// context menus, Open Containing Folder and the search commands. Sandbox files only (ShellHarness).
@MainActor
final class SearchWindowTests: XCTestCase {
    private func ids(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).filter { !$0.isSeparatorItem }.compactMap { $0.identifier?.rawValue }
    }

    private func complete(_ m: SearchResultsModel?) -> Bool { if case .complete? = m?.state { true } else { false } }

    private func searchSubfolders(_ text: String, in controller: BrowserWindowController, _ h: ShellHarness) async throws -> SearchResultsModel {
        controller.searchController.scope = .subfolders
        controller.searchController.textDidChange(text)
        controller.searchController.commit()
        try await h.waitUntil("results complete") { self.complete(controller.session.results) }
        return try XCTUnwrap(controller.session.results)
    }

    private func content(_ controller: BrowserWindowController) throws -> ContentViewController {
        try XCTUnwrap(controller.contentPane as? ContentViewController)
    }

    func testResultsShowInTheContentWithSearchTitleAndScopeBar() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("tax.pdf"); try h.file("a/b/tax-2025.pdf"); try h.file("notes.txt")
        let controller = try await h.openWindow()
        let content = try content(controller)
        XCTAssertTrue(content.scopeBar.isHidden, "no search: no scope bar")
        let results = try await searchSubfolders("tax", in: controller, h)
        XCTAssertTrue(content.displayedResults === results)
        XCTAssertEqual(Set(controller.probeRowNames), ["tax.pdf", "tax-2025.pdf"])
        XCTAssertEqual(controller.addressBar.displayText, "Search Results in “files”")
        XCTAssertEqual(controller.window?.title, "Search Results in “files”")
        XCTAssertFalse(content.scopeBar.isHidden)
        XCTAssertEqual(content.scopeBar.scopeControl.selectedSegment, 1)
        XCTAssertEqual(content.scopeBar.statusLabel.stringValue, "2 results")
        XCTAssertTrue(content.scopeBar.stopButton.isHidden, "Stop only while searching")
        guard case .resultsSelection(let target)? = content.commandTarget, target === results else {
            return XCTFail("commands act on the results")
        }
        XCTAssertEqual(content.focusContext, .searchResults)
        controller.searchController.clear()
        XCTAssertNil(controller.session.results)
        XCTAssertEqual(controller.addressBar.displayText, controller.addressBar.breadcrumb.displayText, "the breadcrumb is back")
        XCTAssertNotEqual(controller.window?.title, "Search Results in “files”")
        XCTAssertTrue(content.scopeBar.isHidden)
    }

    func testDiagnosticsAndNoticesShowInTheScopeBar() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("tax.pdf")
        let controller = try await h.openWindow()
        let content = try content(controller)
        controller.searchController.scope = .thisFolder
        controller.searchController.textDidChange("tax size:big")
        XCTAssertEqual(content.scopeBar.noticeText, "Didn't understand 'size:big'")
        controller.searchController.clear()
        controller.searchController.mode = .contents          // sandboxed services: indexing disabled
        controller.searchController.textDidChange("tax")
        try await h.waitUntil("plan notice") { controller.session.lastPlan?.notices.isEmpty == false }
        XCTAssertEqual(content.scopeBar.noticeText?.contains("isn't indexed by Spotlight"), true)
    }

    func testResultsContextMenusHaveNoPasteOrNew() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("tax.pdf"); try h.file("a/tax-2.pdf")
        let controller = try await h.openWindow()
        let content = try content(controller)
        _ = try await searchSubfolders("tax", in: controller, h)
        let item = ids(content.contextMenu(forRow: 0))
        XCTAssertEqual(Array(item.prefix(2)), ["macx.menu.open", "macx.menu.openContainingFolder"])
        XCTAssertFalse(item.contains("macx.menu.paste"))
        XCTAssertTrue(item.contains("macx.menu.moveToTrash"))
        let empty = ids(content.contextMenu(forRow: nil))
        XCTAssertFalse(empty.contains("macx.menu.paste"))
        XCTAssertFalse(empty.contains("macx.menu.new"))
        XCTAssertTrue(empty.contains("macx.menu.saveSearch"))
        XCTAssertTrue(empty.contains("macx.menu.refresh"), "Search Again")
    }

    func testOpenContainingFolderCommandThenBackRestoresTheResults() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a/b/tax-2025.pdf"); try h.file("other.txt")
        let controller = try await h.openWindow()
        let content = try content(controller)
        let results = try await searchSubfolders("tax-2025", in: controller, h)
        XCTAssertEqual(results.rowCount, 1)
        results.select(.set([0], cursor: 0))
        let handler = try XCTUnwrap(content.handler)
        let target = try XCTUnwrap(content.commandTarget)
        XCTAssertTrue(handler.canPerform(.openContainingFolder, target: target))
        XCTAssertFalse(handler.canPerform(.paste, target: target))
        XCTAssertFalse(handler.canPerform(.newFolder, target: target))
        XCTAssertFalse(handler.canPerform(.groupByKind, target: target))
        handler.perform(.openContainingFolder, target: target, sender: nil)
        XCTAssertNil(controller.session.results)
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "b")
        try await h.waitUntil("selected") { controller.session.folder.selectedURLs.map(\.lastPathComponent) == ["tax-2025.pdf"] }
        XCTAssertEqual(controller.toolbarController.search.field.stringValue, "", "navigation clears the field")
        controller.session.goBack()
        XCTAssertTrue(controller.session.results === results)
        XCTAssertTrue(content.displayedResults === results)
        XCTAssertEqual(controller.addressBar.displayText, "Search Results in “files”")
        XCTAssertEqual(controller.toolbarController.search.field.stringValue, "tax-2025", "the field shows the search again")
        XCTAssertEqual(controller.searchController.scope, .subfolders)
    }

    func testSearchCommands() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("tax.pdf")
        let controller = try await h.openWindow()
        let content = try content(controller)
        let handler = try XCTUnwrap(content.handler)
        XCTAssertFalse(handler.canPerform(.saveSearch, target: try XCTUnwrap(content.commandTarget)), "no search yet")
        handler.perform(.searchScopeSubfolders, target: try XCTUnwrap(content.commandTarget), sender: nil)
        XCTAssertEqual(controller.searchController.scope, .subfolders)
        XCTAssertEqual(h.environment.settings.searchScope, .subfolders)
        _ = try await searchSubfolders("tax", in: controller, h)
        let target = try XCTUnwrap(content.commandTarget)
        XCTAssertFalse(handler.canPerform(.stopSearch, target: target), "complete: nothing to stop")
        XCTAssertTrue(handler.canPerform(.saveSearch, target: target))
        handler.perform(.saveSearch, target: target, sender: nil)
        XCTAssertEqual(h.environment.settings.savedSearches.map(\.name), ["tax"])
        XCTAssertEqual(h.environment.settings.savedSearches.first?.spec.scope, .subfolders)
        let item = NSMenuItem(title: "", action: Selector(Command.searchScopeSubfolders.selectorName), keyEquivalent: "")
        _ = content.validateMenuItem(item)
        XCTAssertEqual(item.state, .on, "View › Search ▸ shows the active scope")
        handler.perform(.searchModeContents, target: target, sender: nil)
        XCTAssertEqual(controller.searchController.mode, .contents)
    }

    func testEscapeInTheFieldClearsTheSearch() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("tax.pdf"); try h.file("a/tax-2.pdf")
        let controller = try await h.openWindow()
        _ = try await searchSubfolders("tax", in: controller, h)
        let field = controller.toolbarController.search
        field.field.stringValue = "tax"
        let editor = NSTextView()
        XCTAssertTrue(field.control(field.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(controller.session.results)
        XCTAssertEqual(field.field.stringValue, "")
        XCTAssertEqual(field.controller.text, "")
    }
}
