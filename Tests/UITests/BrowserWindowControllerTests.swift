import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class BrowserWindowControllerTests: XCTestCase {
    func testProbesReportTheModel() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("b.txt"); try h.file("a.txt"); try h.dir("sub")
        let controller = try await h.openWindow()
        XCTAssertEqual(controller.probeFolderURL.standardizedFileURL.path, h.filesRoot.standardizedFileURL.path)
        XCTAssertEqual(controller.probeRowNames, ShellHarness.names(controller.session.folder))
        XCTAssertEqual(Set(controller.probeRowNames), ["a.txt", "b.txt", "sub"])
        XCTAssertEqual(controller.probeFolderState, .complete)
        XCTAssertEqual(controller.probeViewMode, controller.session.viewMode)
        XCTAssertEqual(controller.probeSelectedNames, [])
        let folder = controller.session.folder
        let a = try XCTUnwrap(folder.row(named: "a.txt")), b = try XCTUnwrap(folder.row(named: "b.txt"))
        folder.select(.set(IndexSet([a, b]), cursor: b))
        XCTAssertEqual(controller.probeSelectedNames, [a, b].sorted().map { folder.name(atRow: $0) })
        folder.cutNames = ["b.txt"]
        XCTAssertEqual(controller.probeCutNames, ["b.txt"])
    }

    func testUninstalledHooksReturnDefaultsAndInstalledHooksAreUsed() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        controller.scenarioHooks = ScenarioHooks()   // P1-27+ install hooks; check the uninstalled defaults
        XCTAssertEqual(controller.probeAddressText, "")
        XCTAssertFalse(controller.probeIsEditingAddress)
        XCTAssertNil(controller.probeRenameText)
        XCTAssertNil(controller.probeEmptyStateText)
        XCTAssertNil(controller.probeBannerText)
        await controller.probePerformDrop(sources: [], onto: "", modifiers: [], secondary: false, menuChoice: nil)

        controller.scenarioHooks.addressText = { "files" }
        controller.scenarioHooks.isEditingAddress = { true }
        controller.scenarioHooks.renameText = { "a.txt" }
        controller.scenarioHooks.emptyStateText = { "This folder is empty" }
        controller.scenarioHooks.bannerText = { "'X' was moved or deleted" }
        var dropped: (sources: [URL], onto: String, modifiers: DragModifiers, secondary: Bool, choice: DragOperation?)?
        controller.scenarioHooks.performDrop = { sources, onto, modifiers, secondary, choice in
            dropped = (sources, onto, modifiers, secondary, choice)
        }
        XCTAssertEqual(controller.probeAddressText, "files")
        XCTAssertTrue(controller.probeIsEditingAddress)
        XCTAssertEqual(controller.probeRenameText, "a.txt")
        XCTAssertEqual(controller.probeEmptyStateText, "This folder is empty")
        XCTAssertEqual(controller.probeBannerText, "'X' was moved or deleted")
        let source = h.url("a.txt")
        await controller.probePerformDrop(sources: [source], onto: "sub", modifiers: [.option], secondary: true, menuChoice: .copy)
        XCTAssertEqual(dropped?.sources, [source])
        XCTAssertEqual(dropped?.onto, "sub")
        XCTAssertEqual(dropped?.modifiers, [.option])
        XCTAssertEqual(dropped?.secondary, true)
        XCTAssertEqual(dropped?.choice, .copy)
    }

    func testNavigateUpdatesTitleAndProbes() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("Docs/readme.md")
        let controller = try await h.openWindow()
        controller.navigate(to: h.url("Docs"))
        XCTAssertEqual(controller.window?.title, "Docs")
        try await h.waitUntil("Docs listed") { controller.probeRowNames == ["readme.md"] }
        h.environment.settings.showFullPathInTitle = true
        controller.navigate(to: h.url(""))
        XCTAssertEqual(controller.window?.title, h.filesRoot.path(percentEncoded: false).trimmingSuffixSlash)
    }

    func testWindowHasToolbarAndSidebarContentSplit() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let window = try XCTUnwrap(controller.window)
        XCTAssertNotNil(window.toolbar)
        let split = try XCTUnwrap(window.contentViewController as? BrowserSplitViewController)
        XCTAssertEqual(split.splitViewItems.count, 2)
        XCTAssertEqual(split.splitViewItems[0].behavior, .sidebar)
        XCTAssertEqual(split.splitViewItems[0].viewController.view.accessibilityIdentifier(), AXID.sidebar)
        XCTAssertNil(split.splitView.autosaveName, "no autosave names in sandbox mode")
    }

    func testPlaceholderContentShowsTheRowCount() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let controller = try await h.openWindow()
        let content = try XCTUnwrap(controller.contentPane as? PlaceholderContentViewController)
        XCTAssertEqual(content.focusContext, .content)
        guard case .contentSelection(let model)? = content.commandTarget else { return XCTFail("content target") }
        XCTAssertTrue(model === controller.session.folder)
        try await h.waitUntil("count label") { content.countText == "2 items" }
        try h.file("c.txt")
        controller.session.reload()
        try await h.waitUntil("count label updates") { content.countText == "3 items" }
    }

    func testFocusAndProbeFocus() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        controller.focus(.content)
        XCTAssertEqual(controller.probeFocus, .content)
        controller.focus(.sidebarFavorites)
        XCTAssertEqual(controller.probeFocus, controller.sidebarPane?.focusContext)
        var addressFocused = false
        controller.focusAddressBar = { addressFocused = true }
        controller.focus(.addressBar)
        XCTAssertTrue(addressFocused, "P1-27 installs the address bar's focus action")
        XCTAssertNil(controller.probeFieldEditorText)
    }

    func testFieldEditorProbesAndUndoManagers() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.windowWillReturnUndoManager(window) === h.environment.undo.undoManager, "§6.6 one app-wide stack")

        let field = NSTextField(string: "hello")
        let other = NSTextField(string: "other")
        let contentView = try XCTUnwrap(controller.contentPane?.view)
        contentView.addSubview(field)
        contentView.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertEqual(controller.probeFieldEditorText, "hello")
        XCTAssertEqual(controller.probeFocus, .fieldEditor)
        let editManager = controller.windowWillReturnUndoManager(window)
        XCTAssertNotNil(editManager)
        XCTAssertFalse(editManager === h.environment.undo.undoManager, "a per-edit manager while a field editor is editing")
        XCTAssertTrue(controller.windowWillReturnUndoManager(window) === editManager, "stable during one edit")

        XCTAssertTrue(window.makeFirstResponder(other))
        let otherManager = controller.windowWillReturnUndoManager(window)
        XCTAssertFalse(otherManager === editManager, "a new edit gets a fresh manager")

        field.identifier = NSUserInterfaceItemIdentifier(AXID.addressField)
        field.setAccessibilityIdentifier(AXID.addressField)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertEqual(controller.probeFocus, .addressBar, "editing the address field is address-bar focus")

        controller.focus(.content)
        XCTAssertTrue(controller.windowWillReturnUndoManager(window) === h.environment.undo.undoManager)
        XCTAssertNil(controller.probeFieldEditorText)
    }

    func testRestorableStateEncodesTheFolder() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let controller = try await h.openWindow("sub")
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        controller.window(controller.window!, willEncodeRestorableState: coder)
        coder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        XCTAssertEqual(BrowserWindowRestoration.folderURL(from: decoder)?.lastPathComponent, "sub")
    }

    func testCommandHandlerIsInstalledOnPanes() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        XCTAssertNotNil(controller.contentPane?.handler)
        XCTAssertNotNil(controller.sidebarPane?.handler)
    }
}

private extension String {
    var trimmingSuffixSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}
