import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

/// P4-06: the sidebar's TAGS section (rows and colours, Hide Tags / Show All Tags…, drop-to-tag, click → results).
/// Every file lives in a test sandbox; tag results come from the sandbox crawl (never Spotlight), drags use private
/// pasteboards and the Show All Tags… sheet is never presented.
@MainActor final class SidebarTagsTests: XCTestCase {
    private func read(_ url: URL, _ env: CoreEnvironment) async throws -> [FileTag] {
        try await env.lanes.perform(on: .unknown) { _ in try TagIO.read(url) }
    }

    private func write(_ tags: [FileTag], _ url: URL, _ env: CoreEnvironment) async throws {
        try await env.lanes.perform(on: .unknown) { _ in try TagIO.write(tags, to: url) }
    }

    private func sidebar(of window: BrowserWindowController) throws -> SidebarViewController {
        try XCTUnwrap(window.splitController?.sidebarController)
    }

    // MARK: rows

    func testSectionComesAfterLocationsAndListsSidebarTagsWithColours() async throws {
        let h = try await SidebarHarness.make(self)
        XCTAssertEqual(h.sidebar.sectionHeaders, [.favorites, .locations, .tags, .folders])
        XCTAssertEqual(h.names(in: .tags), ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        XCTAssertEqual(h.sidebar.tagsSection.rows.first, SidebarTag(name: "Red", color: .red))
        let headers = (0..<h.outline.numberOfRows).compactMap { h.sidebar.item(atRow: $0) }.filter(\.isHeader).map(\.section)
        XCTAssertEqual(headers, [.favorites, .locations, .tags, .folders])

        h.settings.setSidebarTag("Orange", visible: false)
        try await h.waitUntil("row removed") { !h.names(in: .tags).contains("Orange") }
        h.settings.setSidebarTag("Work", visible: true)
        try await h.waitUntil("unknown tag appended") { h.names(in: .tags).last == "Work" }
        XCTAssertEqual(h.sidebar.tagsSection.row(named: "work")?.color, TagColor.none, "unknown names are colourless")
        h.settings.noteTagUsed(FileTag(name: "Work", color: .purple))
        try await h.waitUntil("colour follows known tags") { h.sidebar.tagsSection.row(named: "Work")?.color == .purple }
        XCTAssertEqual(h.cell(atRow: h.row(named: "Work", in: .tags))?.textField?.stringValue, "Work")
    }

    func testRowsDropDuplicateNames() {
        let rows = SidebarTagsSection.rows(sidebarTags: ["Red", "red", "", "X"], knownTags: FileTag.standard)
        XCTAssertEqual(rows, [SidebarTag(name: "Red", color: .red), SidebarTag(name: "X", color: .none)])
    }

    func testCollapseIsRemembered() async throws {
        let h = try await SidebarHarness.make(self)
        h.settings.collapsedSections.insert(.tags)
        try await h.waitUntil("collapsed") { h.names(in: .tags).isEmpty }
        XCTAssertFalse(h.outline.isItemExpanded(h.sidebar.box(.tagsHeader)))
        h.outline.expandItem(h.sidebar.box(.tagsHeader))
        XCTAssertFalse(h.settings.collapsedSections.contains(.tags))
    }

    // MARK: menus

    func testHeaderMenuHidesTagsAndSettingsShowThemAgain() async throws {
        let h = try await SidebarHarness.make(self)
        let header = h.sidebar.row(of: .tagsHeader)
        let menu = try XCTUnwrap(h.sidebar.menu(forRow: header))
        XCTAssertEqual(menu.items.map(\.title), [L10n.string("Show All Tags…"), L10n.string("Hide Tags")])
        let hide = try XCTUnwrap(menu.items.last as? SidebarMenuItem)
        _ = hide.target?.perform(hide.action, with: hide)
        XCTAssertFalse(h.settings.showTagsInSidebar)
        try await h.waitUntil("section hidden") { h.sidebar.row(of: .tagsHeader) < 0 }
        XCTAssertEqual(h.sidebar.sectionHeaders, [.favorites, .locations, .folders])
        h.settings.showTagsInSidebar = true
        try await h.waitUntil("section back") { h.names(in: .tags).count == 7 }
        XCTAssertTrue(h.outline.isItemExpanded(h.sidebar.box(.tagsHeader)))
    }

    func testRowMenuRemovesFromSidebarAndOpensShowAllTags() async throws {
        let h = try await SidebarHarness.make(self)
        var presented = 0
        h.sidebar.presentTagsSheet = { _ in presented += 1 }
        let menu = try XCTUnwrap(h.sidebar.menu(forRow: h.row(named: "Blue", in: .tags)))
        XCTAssertEqual(menu.items.map(\.title), [L10n.string("Remove from Sidebar"), L10n.string("Show All Tags…")])
        for item in menu.items.reversed() { _ = (item.target as AnyObject?)?.perform(item.action, with: item) }
        XCTAssertEqual(presented, 1)
        try await h.waitUntil("Blue removed") { !h.names(in: .tags).contains("Blue") }
        XCTAssertFalse(h.settings.sidebarTags.contains("Blue"))
    }

    func testShowAllTagsChoicesListKnownTagsAndShownState() async throws {
        let h = try await SidebarHarness.make(self)
        h.settings.setSidebarTag("Gray", visible: false)
        h.settings.setSidebarTag("Legacy", visible: true)            // shown but not a known tag
        h.settings.noteTagUsed(FileTag(name: "Work"))                 // known, not shown
        let items = SidebarTagChoices.items(h.settings)
        XCTAssertEqual(items.map(\.tag.name), ["Work", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray", "Legacy"])
        XCTAssertEqual(items.filter { !$0.shown }.map(\.tag.name), ["Work", "Gray"])
    }

    // MARK: drops

    func testDropValidationAcceptsFilesRejectsOtherDrags() async throws {
        let h = try await SidebarHarness.make(self)
        let a = try h.file("home/a.txt")
        let section = h.sidebar.tagsSection
        XCTAssertEqual(section.validateDrop(fileURLs: [a]), .copy)
        XCTAssertEqual(section.validateDrop(fileURLs: []), [])
        let tagRow = h.sidebar.box(.tag(try XCTUnwrap(section.row(named: "Red"))))
        let files = FakeDraggingInfo(fileURLs: [a], sourceMask: [.move])          // ⌘-drag: still copy (tagging)
        defer { files.release() }
        XCTAssertEqual(h.sidebar.outlineView(h.outline, validateDrop: files, proposedItem: tagRow,
                                             proposedChildIndex: NSOutlineViewDropOnItemIndex), .copy)
        XCTAssertEqual(h.sidebar.outlineView(h.outline, validateDrop: files, proposedItem: tagRow, proposedChildIndex: 0), [])
        let none = FakeDraggingInfo(fileURLs: [])
        defer { none.release() }
        XCTAssertEqual(h.sidebar.outlineView(h.outline, validateDrop: none, proposedItem: tagRow,
                                             proposedChildIndex: NSOutlineViewDropOnItemIndex), [])
    }

    func testDropOntoTagRowAddsTagWithOneUndo() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        try await write([FileTag(name: "Work")], b, ui.environment)
        let window = try await ui.openBrowserWindow()
        let sidebar = try sidebar(of: window)
        let tagRow = sidebar.box(.tag(try XCTUnwrap(sidebar.tagsSection.row(named: "Blue"))))
        let drag = FakeDraggingInfo(fileURLs: [a, b])
        defer { drag.release() }
        XCTAssertTrue(sidebar.outlineView(sidebar.outlineView, acceptDrop: drag, item: tagRow,
                                          childIndex: NSOutlineViewDropOnItemIndex))
        let blue = FileTag(name: "Blue", color: .blue)
        try await ui.waitUntil("tagged") { ui.environment.undo.canUndo }
        await ui.environment.fileOps.waitUntilIdle()
        let ta = try await read(a, ui.environment), tb = try await read(b, ui.environment)
        XCTAssertEqual(ta, [blue])
        XCTAssertEqual(tb, [FileTag(name: "Work"), blue])
        XCTAssertEqual(ui.environment.settings.knownTags.first, blue, "the dropped tag is the most recently used")
        ui.environment.undo.undoManager.undo()
        let deadline = ContinuousClock.now + .seconds(30)
        while try await read(a, ui.environment) != [], ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await ui.environment.fileOps.waitUntilIdle()
        let ua = try await read(a, ui.environment), ub = try await read(b, ui.environment)
        XCTAssertEqual(ua, [], "one undo restores both items")
        XCTAssertEqual(ub, [FileTag(name: "Work")])
        XCTAssertFalse(ui.environment.undo.canUndo, "the drop was one undo entry")
    }

    // MARK: results (Step 5)

    func testClickingTagShowsResultsInSandboxCrawl() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), sub = try ui.file("sub/c.txt")
        _ = try ui.file("b.txt")
        try await write([FileTag(name: "Red", color: .red)], a, ui.environment)
        try await write([FileTag(name: "red")], sub, ui.environment)
        let window = try await ui.openBrowserWindow()
        let sidebar = try sidebar(of: window)
        let (query, scope, _) = sidebar.tagsSection.makeQuery()
        XCTAssertTrue(query is CrawlTagQuery, "sandboxed runs never query Spotlight")
        XCTAssertEqual(scope, .directory(ui.url("")))

        let row = sidebar.row(of: .tag(try XCTUnwrap(sidebar.tagsSection.row(named: "Red"))))
        sidebar.activateRow(row)
        try await ui.waitUntil("results") { Set(window.probeRowNames) == ["a.txt", "c.txt"] }
        let model = try XCTUnwrap(window.session.results)
        XCTAssertEqual(model.title, "Red")
        try await ui.waitUntil("complete") { if case .complete = model.state { true } else { false } }
        let content = try ui.content(of: window)
        XCTAssertTrue(content.details.columns.contains { $0.id == .path && $0.visible }, "the Path column shows")
        XCTAssertEqual(sidebar.selectedItem?.identity, "tag.red", "the row stays selected")

        sidebar.activateRow(row)                                       // the same tag again: not restarted
        XCTAssertTrue(window.session.results === model)

        window.session.goBack()
        try await ui.waitUntil("back to the folder") { window.session.results == nil }
        XCTAssertEqual(Set(window.probeRowNames), ["a.txt", "b.txt", "sub"])
    }

    func testTaggingFromTheSidebarShowsInOpenResultsAfterRerun() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        try await write([FileTag(name: "Green", color: .green)], a, ui.environment)
        let window = try await ui.openBrowserWindow()
        let sidebar = try sidebar(of: window)
        sidebar.activateRow(sidebar.row(of: .tag(try XCTUnwrap(sidebar.tagsSection.row(named: "Green")))))
        try await ui.waitUntil("results") { window.probeRowNames == ["a.txt"] }
        await sidebar.tagsSection.performDrop([b], onto: "Green")
        await ui.environment.fileOps.waitUntilIdle()
        window.session.results?.rerun()
        try await ui.waitUntil("rerun finds b") { Set(window.probeRowNames) == ["a.txt", "b.txt"] }
    }
}
