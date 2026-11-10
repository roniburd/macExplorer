import XCTest
import AppKit
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

/// P3-11: the sidebar's SEARCHES section (save, open, rename, remove, reorder; Del never deletes files).
/// Sandbox files only; searches run in the sandbox with the fake Spotlight services.
@MainActor
final class SidebarSearchesTests: XCTestCase {
    var sandbox: Sandbox!
    var context: UIContext!
    var session: BrowserSession!
    var sidebar: SidebarViewController!
    var env: CoreEnvironment { context.environment }

    override func setUp() async throws {
        _ = NSApplication.shared
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        try sandbox.createFile("work/tax.pdf")
        try sandbox.createFile("work/sub/tax-2.pdf")
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = sandbox.url("state")
        options.pasteboardName = "macx-tests-\(UUID().uuidString)"
        context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root), options: options)
        session = BrowserSession(environment: env, initialURL: sandbox.url("work"))
        sidebar = SidebarViewController(context: context, session: session)
        _ = sidebar.view
        let shown = session!
        let bar = sidebar!
        addTeardownBlock { @MainActor in bar.close(); shown.close() }
    }

    /// A condition wait with a deadline generous enough for a CPU-starved CI runner; a timeout fails at the caller's line.
    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), file: StaticString = #filePath,
                           line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("timed out after \(timeout) waiting for: \(what)", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func savedRows() -> [String] {
        (0..<sidebar.outlineView.numberOfRows).compactMap {
            if case .savedSearch(let s)? = sidebar.outlineView.item(atRow: $0) as? SidebarItem { s.name } else { nil }
        }
    }
    func row(of name: String) -> Int {
        (0..<sidebar.outlineView.numberOfRows).first {
            if case .savedSearch(let s)? = sidebar.outlineView.item(atRow: $0) as? SidebarItem { s.name == name } else { false }
        } ?? -1
    }
    var spec: SearchSpec { SearchSpec(text: "tax", scope: .subfolders, root: sandbox.url("work")) }

    /// A window whose FileCommandController handles the sidebar's commands (as in the app).
    func installHandler() -> BrowserWindowController {
        let window = BrowserWindowController(context: context, initialURL: sandbox.url("work"))
        addTeardownBlock { @MainActor in window.close() }
        sidebar.handler = FileCommandController(context: context, window: window)
        return window
    }

    func testSectionAppearsOnlyWithSavedSearches() async {
        XCTAssertFalse(sidebar.sectionHeaders.contains(.searches))
        XCTAssertEqual(sidebar.sectionHeaders, [.favorites, .locations, .tags, .folders])
        env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("section") { self.savedRows() == ["Taxes"] }
        XCTAssertEqual(sidebar.sectionHeaders, [.favorites, .searches, .locations, .tags, .folders])
        let headers = (0..<sidebar.outlineView.numberOfRows).compactMap { sidebar.item(atRow: $0) }.filter(\.isHeader)
        XCTAssertEqual(headers.map(\.section), [.favorites, .searches, .locations, .tags, .folders])
        env.settings.collapsedSections.insert(.searches)
        await waitUntil("collapsed") { self.savedRows().isEmpty }
        XCTAssertTrue(sidebar.sectionHeaders.contains(.searches))
        env.settings.collapsedSections.remove(.searches)
        await waitUntil("expanded") { self.savedRows() == ["Taxes"] }
        sidebar.outlineView.collapseItem(sidebar.box(.searchesHeader))
        XCTAssertTrue(env.settings.collapsedSections.contains(.searches), "collapsing the header persists")
        sidebar.outlineView.expandItem(sidebar.box(.searchesHeader))
        XCTAssertFalse(env.settings.collapsedSections.contains(.searches))
        env.settings.removeSavedSearch(env.settings.savedSearches[0].id)
        await waitUntil("section gone") { !self.sidebar.sectionHeaders.contains(.searches) }
        XCTAssertEqual(sidebar.sectionHeaders, [.favorites, .locations, .tags, .folders])
        XCTAssertFalse((0..<sidebar.outlineView.numberOfRows).contains { sidebar.item(atRow: $0) == .searchesHeader })
    }

    func testRowShowsSymbolTooltipAndAccessibility() async throws {
        env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("row") { self.row(of: "Taxes") >= 0 }
        let cell = try XCTUnwrap(sidebar.outlineView.view(atColumn: 0, row: row(of: "Taxes"), makeIfNecessary: true) as? SidebarCellView)
        XCTAssertEqual(cell.textField?.stringValue, "Taxes")
        XCTAssertEqual(cell.toolTip, "tax — Subfolders of “work”")
        XCTAssertEqual(cell.accessibilityLabel(), "Saved search, Taxes")
        XCTAssertEqual(cell.accessibilityIdentifier(), "macx.sidebar.search.Taxes")
        XCTAssertNotNil(cell.imageView?.image)
        let folderOnly = SearchSpec(text: "", scope: .thisFolder, root: sandbox.url("work"))
        XCTAssertEqual(SearchStrings.savedSearchTooltip(folderOnly), "(filters only) — in “work”")
        XCTAssertEqual(SearchStrings.savedSearchTooltip(SearchSpec(text: "x", scope: .thisMac, root: sandbox.url("work"))),
                       "x — This Mac")
    }

    func testRenameKeepsTheRowSelected() async {
        let saved = env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("row") { self.row(of: "Taxes") >= 0 }
        sidebar.select(row: row(of: "Taxes"))
        env.settings.renameSavedSearch(saved.id, to: "Old taxes")
        await waitUntil("renamed") { self.savedRows() == ["Old taxes"] }
        guard case .savedSearch(let selected)? = sidebar.selectedItem else { return XCTFail("selection kept") }
        XCTAssertEqual(selected.name, "Old taxes")
    }

    func testClickRunsTheSearchAndFillsTheField() async {
        env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("row") { self.row(of: "Taxes") >= 0 }
        var texts: [String] = []
        let token = session.observe { if case .searchTextChanged(let t) = $0 { texts.append(t) } }
        defer { token.cancel() }
        sidebar.activateRow(row(of: "Taxes"), newTab: false)
        await waitUntil("results") { self.session.results != nil }
        XCTAssertEqual(session.searchSpec, spec)
        XCTAssertEqual(texts.last, "tax")
        XCTAssertEqual(sidebar.focusContext, .sidebarSavedSearch)
        guard case .savedSearch(let target)? = sidebar.commandTarget else { return XCTFail("saved-search target") }
        XCTAssertEqual(target.name, "Taxes")
    }

    func testThisFolderSavedSearchNavigatesToItsRoot() async {
        let s = SearchSpec(text: "tax", scope: .thisFolder, root: sandbox.url("work/sub"))
        env.settings.addSavedSearch(name: "Sub", spec: s)
        await waitUntil("row") { self.row(of: "Sub") >= 0 }
        sidebar.activateRow(row(of: "Sub"), newTab: false)
        await waitUntil("filter applied in root") {
            self.session.folder.directory.standardizedFileURL == self.sandbox.url("work/sub").standardizedFileURL
                && self.session.folder.query.criteria != nil
        }
        XCTAssertEqual(session.searchSpec, s)
        await sidebar.revealSettled()
        XCTAssertEqual(sidebar.focusContext, .sidebarSavedSearch, "the reveal doesn't steal the saved-search row")
    }

    func testDelRemovesTheSavedSearchAndNeverTouchesFiles() async {
        _ = installHandler()
        let saved = env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("row") { self.row(of: "Taxes") >= 0 }
        sidebar.outlineView.selectRowIndexes([row(of: "Taxes")], byExtendingSelection: false)
        XCTAssertEqual(sidebar.focusContext, .sidebarSavedSearch)
        let effective = CommandAvailability.effectiveCommand(.moveToTrash, focus: sidebar.focusContext)
        XCTAssertEqual(effective, .removeSavedSearch)
        sidebar.handler?.perform(effective!, target: .savedSearch(saved), sender: nil)
        await waitUntil("removed") { self.env.settings.savedSearches.isEmpty }
        XCTAssertNil(CommandAvailability.effectiveCommand(.deletePermanently, focus: .sidebarSavedSearch))
        let jobs = await env.fileOps.snapshots()
        XCTAssertTrue(jobs.isEmpty, "no file operation for a saved-search row")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.url("work/tax.pdf").path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.url("work").path(percentEncoded: false)))
    }

    func testDelKeysThroughTheSidebarNeverDeleteFiles() async {
        _ = installHandler()
        env.settings.addSavedSearch(name: "A", spec: spec)
        env.settings.addSavedSearch(name: "B", spec: spec)
        await waitUntil("rows") { self.savedRows() == ["A", "B"] }
        sidebar.select(row: row(of: "A"))
        sidebar.run(.deletePermanently, sender: nil)          // ⇧Del does nothing
        XCTAssertEqual(env.settings.savedSearches.map(\.name), ["A", "B"])
        sidebar.run(.moveToTrash, sender: nil)                // Del → Remove from Sidebar
        XCTAssertEqual(env.settings.savedSearches.map(\.name), ["B"])
        for command in [Command.cut, .copy, .duplicate, .makeAlias, .makeSymlink, .copyAsPath, .properties, .revealInFinder] {
            XCTAssertFalse(sidebar.handler?.canPerform(command, target: .savedSearch(env.settings.savedSearches[0])) ?? true,
                           "\(command)")
        }
        let jobs = await env.fileOps.snapshots()
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.url("work/tax.pdf").path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.url("work/sub/tax-2.pdf").path(percentEncoded: false)))
    }

    func testContextMenuItems() async throws {
        env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("row") { self.row(of: "Taxes") >= 0 }
        let menu = try XCTUnwrap(sidebar.menu(forRow: row(of: "Taxes")))
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title },
                       ["Open", "Open in New Tab", "—", "Rename…", "Remove from Sidebar"])
    }

    func testRenameAndSaveUseThePrompt() async throws {
        try requireGUISession()
        let prompter = FakePrompter(["Taxes", "Taxes", nil])
        context.namePrompter = prompter
        let window = BrowserWindowController(context: context, initialURL: sandbox.url("work"))
        addTeardownBlock { @MainActor in window.close() }
        let controller = FileCommandController(context: context, window: window)
        await window.session.search(spec)
        controller.perform(.saveSearch, target: .currentFolder(window.session.folder), sender: nil)
        await waitUntil("saved") { self.env.settings.savedSearches.map(\.name) == ["Taxes"] }
        controller.perform(.saveSearch, target: .currentFolder(window.session.folder), sender: nil)
        await waitUntil("second saved unique") { self.env.settings.savedSearches.map(\.name) == ["Taxes", "Taxes 2"] }
        controller.perform(.saveSearch, target: .currentFolder(window.session.folder), sender: nil)   // cancelled
        await controller.namePromptTask?.value
        XCTAssertEqual(env.settings.savedSearches.count, 2)
        XCTAssertEqual(prompter.asked, ["tax", "tax", "tax"])
        XCTAssertEqual(prompter.titles.first, "Save Search")
        let second = env.settings.savedSearches[1]
        prompter.answers = ["Old taxes"]
        controller.perform(.renameSavedSearch, target: .savedSearch(second), sender: nil)
        await waitUntil("renamed") { self.env.settings.savedSearches.map(\.name) == ["Taxes", "Old taxes"] }
        XCTAssertEqual(prompter.asked.last, "Taxes 2")
        XCTAssertEqual(prompter.titles.last, "Rename Saved Search")
        prompter.answers = [nil]
        controller.perform(.renameSavedSearch, target: .savedSearch(env.settings.savedSearches[1]), sender: nil)
        await controller.namePromptTask?.value
        XCTAssertEqual(prompter.asked.last, "Old taxes", "the cancelled rename still prompted")   // positive control
        XCTAssertEqual(env.settings.savedSearches.map(\.name), ["Taxes", "Old taxes"], "cancel renames nothing")
    }

    func testReorderByDrop() async {
        let a = env.settings.addSavedSearch(name: "A", spec: spec)
        env.settings.addSavedSearch(name: "B", spec: spec)
        env.settings.addSavedSearch(name: "C", spec: spec)
        await waitUntil("rows") { self.savedRows() == ["A", "B", "C"] }
        XCTAssertTrue(sidebar.moveSavedSearch(id: a.id, to: 2))
        await waitUntil("reordered") { self.savedRows() == ["B", "C", "A"] }
        XCTAssertFalse(sidebar.moveSavedSearch(id: UUID(), to: 0))
        // The outline's child index counts before the removal: dropping A below the last row lands it last.
        let c = env.settings.savedSearches[1]
        XCTAssertTrue(sidebar.moveSavedSearch(id: c.id, toChildIndex: 3))
        await waitUntil("C last") { self.savedRows() == ["B", "A", "C"] }
        XCTAssertTrue(sidebar.moveSavedSearch(id: c.id, toChildIndex: 0))
        await waitUntil("C first") { self.savedRows() == ["C", "B", "A"] }
    }

    func testDragWritesTheIDAndDropsAreLimitedToSearches() async throws {
        let a = env.settings.addSavedSearch(name: "A", spec: spec)
        await waitUntil("row") { self.row(of: "A") >= 0 }
        let writer = try XCTUnwrap(sidebar.outlineView(sidebar.outlineView, pasteboardWriterForItem: sidebar.box(.savedSearch(a)))
                                   as? NSPasteboardItem)
        XCTAssertEqual(writer.string(forType: SidebarViewController.savedSearchPasteboardType), a.id.uuidString)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macx-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(a.id.uuidString, forType: SidebarViewController.savedSearchPasteboardType)
        XCTAssertEqual(sidebar.savedSearchesDropOperation(pasteboard), .move)
        XCTAssertEqual(sidebar.favoritesDropOperation(pasteboard, childIndex: 0), [], "not into Favorites")
        pasteboard.clearContents()
        pasteboard.writeObjects([sandbox.url("work") as NSURL])
        XCTAssertEqual(sidebar.savedSearchesDropOperation(pasteboard), [], "files are refused in SEARCHES")
        pasteboard.clearContents()
        pasteboard.setString(UUID().uuidString, forType: SidebarViewController.savedSearchPasteboardType)
        XCTAssertEqual(sidebar.savedSearchesDropOperation(pasteboard), [], "unknown id")
    }

    func testNewTabGestureOpensTheSavedSearchInATab() async {
        let saved = env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("row") { self.row(of: "Taxes") >= 0 }
        var opened: [(SavedSearch, Bool)] = []
        sidebar.openSavedSearchInTab = { opened.append(($0, $1)) }
        XCTAssertTrue(sidebar.handleNewTabGesture(.middleClick, row: row(of: "Taxes")))
        XCTAssertEqual(opened.map(\.0.id), [saved.id])
        XCTAssertEqual(opened.map(\.1), [false], "middle-click: a background tab")
        sidebar.activateRow(row(of: "Taxes"), newTab: true)
        XCTAssertEqual(opened.map(\.1), [false, true])
        XCTAssertNil(session.results, "the window's own session doesn't run it")
    }
}
