import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

/// P2-10: grouped Details view (floating, collapsible group rows). Every file lives in the harness sandbox
/// (`macx-tests-<UUID>/files`); the folder is never anything else.
@MainActor
final class GroupedDetailsTests: XCTestCase {
    let runs = [GroupRun(key: .size(.folders), rows: 0..<1), GroupRun(key: .size(.tiny), rows: 1..<3),
                GroupRun(key: .size(.large), rows: 3..<4)]

    // MARK: pure

    func testRowMappingIdentityAndGrouped() {
        let id = RowMapping.identity(count: 3)
        XCTAssertEqual(id.tableRowCount, 3); XCTAssertEqual(id.modelRow(forTableRow: 2), 2)
        XCTAssertNil(id.modelRow(forTableRow: 3))
        XCTAssertEqual(id.tableRows(forModelRows: IndexSet([0, 2, 7])), IndexSet([0, 2]))
        let g = RowMapping.grouped(GroupedRows(runs: runs, collapsed: []))
        XCTAssertEqual(g.tableRowCount, 7)
        XCTAssertNil(g.modelRow(forTableRow: 0))
        XCTAssertEqual(g.modelRow(forTableRow: 3), 1)
        XCTAssertEqual(g.tableRow(forModelRow: 3), 6)
        XCTAssertEqual(g.modelRows(forTableRows: IndexSet([0, 1, 2, 3])), IndexSet([0, 1]))
        XCTAssertEqual(g.tableRows(forModelRows: IndexSet([1, 3])), IndexSet([3, 6]))
        XCTAssertEqual(g.groupIndex(forTableRow: 2), 1)
        XCTAssertNil(g.groupIndex(forTableRow: 3), "an item row is not a header")
    }

    func testAdjacentVisibleModelRowSkipsHeadersAndCollapsedGroups() {
        let g = RowMapping.grouped(GroupedRows(runs: runs, collapsed: [.size(.tiny)]))
        XCTAssertEqual(g.adjacentVisibleModelRow(from: 0, by: 1), 3, "skips the collapsed Tiny group")
        XCTAssertEqual(g.adjacentVisibleModelRow(from: 3, by: -1), 0)
        XCTAssertNil(g.adjacentVisibleModelRow(from: 3, by: 1))
        XCTAssertEqual(g.adjacentVisibleModelRow(from: 1, by: 1), 3, "a cursor inside a collapsed group moves from its header")
        XCTAssertEqual(RowMapping.identity(count: 2).adjacentVisibleModelRow(from: 0, by: 1), 1)
        XCTAssertNil(RowMapping.identity(count: 2).adjacentVisibleModelRow(from: 1, by: 1))
    }

    func testGroupedNavigationHomeEndAndPagesLandOnVisibleItems() {
        let g = RowMapping.grouped(GroupedRows(runs: runs, collapsed: [.size(.large)]))
        XCTAssertEqual(g.firstVisibleModelRow, 0)
        XCTAssertEqual(g.lastVisibleModelRow, 2, "the collapsed Large group holds the last model row")
        XCTAssertEqual(SelectionController.groupedTarget(.home, cursorRow: 2, mapping: g, pageSize: 3), 0)
        XCTAssertEqual(SelectionController.groupedTarget(.end, cursorRow: 0, mapping: g, pageSize: 3), 2)
        XCTAssertEqual(SelectionController.groupedTarget(.down, cursorRow: nil, mapping: g, pageSize: 3), 0)
        XCTAssertEqual(SelectionController.groupedTarget(.pageDown, cursorRow: 0, mapping: g, pageSize: 10), 2)
        XCTAssertEqual(SelectionController.groupedTarget(.pageUp, cursorRow: 2, mapping: g, pageSize: 10), 0)
        XCTAssertEqual(SelectionController.groupedTarget(.down, cursorRow: 2, mapping: g, pageSize: 3), nil)
        XCTAssertNil(SelectionController.groupedTarget(.left, cursorRow: 1, mapping: g, pageSize: 3))
        let allCollapsed = RowMapping.grouped(GroupedRows(runs: runs, collapsed: Set(runs.map(\.key))))
        XCTAssertNil(allCollapsed.firstVisibleModelRow)
        XCTAssertNil(SelectionController.groupedTarget(.home, cursorRow: nil, mapping: allCollapsed, pageSize: 3))
    }

    func testGroupTitles() {
        XCTAssertEqual(GroupTitles.title(for: .date(.today)), "Today")
        XCTAssertEqual(GroupTitles.title(for: .date(.longAgo)), "A long time ago")
        XCTAssertEqual(GroupTitles.title(for: .date(.future)), "In the future")
        XCTAssertEqual(GroupTitles.title(for: .size(.folders)), "Folders")
        XCTAssertEqual(GroupTitles.title(for: .size(.tiny)), "Tiny (0 – 16 KB)")
        XCTAssertEqual(GroupTitles.title(for: .size(.gigantic)), "Gigantic (> 4 GB)")
        XCTAssertEqual(GroupTitles.title(for: .letter(.digits)), "0–9")
        XCTAssertEqual(GroupTitles.title(for: .letter(.other)), "Other")
        XCTAssertEqual(GroupTitles.title(for: .letter(.letter("Ω"))), "Ω")
        XCTAssertEqual(GroupTitles.title(for: .kind("PNG image", isFolder: false)), "PNG image")
        for bucket in DateBucket.allCases { XCTAssertFalse(GroupTitles.title(for: .date(bucket)).isEmpty) }
        for bucket in SizeBucket.allCases { XCTAssertFalse(GroupTitles.title(for: .size(bucket)).isEmpty) }
    }

    // MARK: AppKit (offscreen window)

    /// sub/, a.txt (10 B), b.txt (20 B), big.bin (sparse 200 MB): Folders (1), Tiny (2), Large (1) when grouped by size.
    private func grouped(_ h: ContentTestHarness) async throws -> (ContentViewController, BrowserSession, DetailsViewController) {
        try requireGUISession()
        try h.dir("sub"); try h.file("a.txt", bytes: 10); try h.file("b.txt", bytes: 20)
        _ = try h.sandbox.createSparseFile("files/big.bin", size: 200_000_000)   // Large bucket by logical size
        let (content, session, window) = try await h.makeContent()
        let details = content.details
        window.makeFirstResponder(details.tableView)
        session.updateViewState { $0.groupBy = .size }
        try await h.waitUntil("grouped rows") { details.tableView.numberOfRows == 7 }
        return (content, session, details)
    }

    private func names(_ folder: FolderModel) -> [String] { folder.selectedURLs.map(\.lastPathComponent) }

    func testDetailsControllerHeadersSelectionAndCollapse() async throws {
        let h = try await ContentTestHarness.make(self)
        let (_, session, details) = try await grouped(h)
        let model = session.folder
        XCTAssertEqual(details.tableView.numberOfRows, 7)     // 3 headers + 4 items
        XCTAssertTrue(details.tableView.floatsGroupRows)
        XCTAssertTrue(details.tableView(details.tableView, isGroupRow: 0))
        XCTAssertFalse(details.tableView(details.tableView, isGroupRow: 1))
        XCTAssertFalse(details.tableView(details.tableView, shouldSelectRow: 0))
        XCTAssertTrue(details.tableView(details.tableView, shouldSelectRow: 1))
        XCTAssertFalse(details.responds(to: #selector(NSTableViewDelegate.tableView(_:heightOfRow:))),
                       "no heightOfRow delegate: the table keeps its fixed-height layout")
        for row in 0..<7 {   // hit-testing agrees with the row frames AppKit lays out around group rows
            let rect = details.tableView.rect(ofRow: row)
            XCTAssertEqual(details.tableView.hitRow(at: NSPoint(x: rect.midX, y: rect.midY)), row)
        }
        let header = try XCTUnwrap(details.tableView.view(atColumn: 0, row: 2, makeIfNecessary: true) as? GroupHeaderView)
        XCTAssertEqual(header.titleField.stringValue, "Tiny (0 – 16 KB)")
        details.clickTableRow(4, modifiers: [])              // second item of the Tiny group = model row 2
        XCTAssertEqual(names(model), ["b.txt"])
        XCTAssertEqual(details.tableView.selectedRowIndexes, IndexSet(integer: 4), "highlight is in table rows")
        details.toggleGroup(1)                               // collapse Tiny
        XCTAssertEqual(details.tableView.numberOfRows, 5)
        XCTAssertEqual(names(model), ["b.txt"], "selection survives collapse")
        XCTAssertEqual(details.tableView.selectedRowIndexes, IndexSet(), "a collapsed item has no highlight")
        XCTAssertEqual(details.groupHeaderTitles(), ["Folders (1)", "Tiny (0 – 16 KB) (2)", "Large (128 MB – 1 GB) (1)"])
        XCTAssertEqual(details.visibleRowNames(), ["sub", "big.bin"])
        details.clickTableRow(2, modifiers: [])              // a click on the Tiny header expands it again
        XCTAssertEqual(details.tableView.numberOfRows, 7)
        XCTAssertEqual(names(model), ["b.txt"], "a header click never changes the selection")
        XCTAssertEqual(details.tableView.selectedRowIndexes, IndexSet(integer: 4))
        details.collapseAllGroups()
        XCTAssertEqual(details.tableView.numberOfRows, 3)
        details.expandAllGroups()
        XCTAssertEqual(details.tableView.numberOfRows, 7)
    }

    func testHeaderMouseClickTogglesAndItemClickSelectsModelRow() async throws {
        let h = try await ContentTestHarness.make(self)
        let (_, session, details) = try await grouped(h)
        let table = details.tableView
        func event(_ row: Int, _ type: NSEvent.EventType) throws -> NSEvent {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: table.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        }
        table.mouseDown(with: try event(6, .leftMouseDown)); table.mouseUp(with: try event(6, .leftMouseUp))
        XCTAssertEqual(names(session.folder), ["big.bin"])
        table.mouseDown(with: try event(0, .leftMouseDown)); table.mouseUp(with: try event(0, .leftMouseUp))
        XCTAssertEqual(table.numberOfRows, 6, "the Folders header collapsed")
        XCTAssertEqual(names(session.folder), ["big.bin"])
    }

    func testArrowsSkipCollapsedGroupsAndLeftRightCollapseExpand() async throws {
        let h = try await ContentTestHarness.make(self)
        let (_, session, details) = try await grouped(h)
        let model = session.folder
        let window = details.tableView.window
        details.clickTableRow(1, modifiers: [])              // sub
        XCTAssertTrue(details.handleKeyDown(try key(.downArrow, window: window)))
        XCTAssertEqual(names(model), ["a.txt"], "↓ skips the Tiny header")
        XCTAssertTrue(details.handleKeyDown(try key(.leftArrow, window: window)))
        XCTAssertEqual(details.tableView.numberOfRows, 5, "← collapses the cursor's group")
        XCTAssertTrue(details.handleKeyDown(try key(.downArrow, window: window)))
        XCTAssertEqual(names(model), ["big.bin"], "↓ from a collapsed group moves on from its header")
        XCTAssertTrue(details.handleKeyDown(try key(.upArrow, window: window)))
        XCTAssertEqual(names(model), ["sub"], "↑ skips the collapsed group")
        details.clickTableRow(2, modifiers: [])              // the collapsed Tiny header: expand it
        details.clickTableRow(3, modifiers: [])              // a.txt
        XCTAssertTrue(details.handleKeyDown(try key(.leftArrow, window: window)))
        XCTAssertEqual(details.tableView.numberOfRows, 5)
        XCTAssertTrue(details.handleKeyDown(try key(.rightArrow, window: window)))
        XCTAssertEqual(details.tableView.numberOfRows, 7, "→ expands the cursor's group")
        details.toggleGroup(1)
        model.select(.all)
        XCTAssertEqual(model.selection.count, 4, "⌘A selects collapsed items too: the selection lives in the model")
    }

    func testTypeSelectFindsVisibleItemsOnly() async throws {
        let h = try await ContentTestHarness.make(self)
        let (_, session, details) = try await grouped(h)
        let model = session.folder
        details.toggleGroup(1)                               // collapse Tiny (a.txt, b.txt)
        details.typeSelect.handle("b", folder: model, list: details, mapping: details.mapping)
        XCTAssertEqual(names(model), ["big.bin"], "b.txt is collapsed, so 'b' reaches big.bin")
    }

    func testScrollAndRenameExpandTheGroupFirst() async throws {
        let h = try await ContentTestHarness.make(self)
        let (_, session, details) = try await grouped(h)
        details.toggleGroup(1)
        XCTAssertEqual(details.tableView.numberOfRows, 5)
        details.scrollToRow(2)                               // b.txt, collapsed
        XCTAssertEqual(details.tableView.numberOfRows, 7)
        details.toggleGroup(1)
        session.folder.select(.set(IndexSet(integer: 1), cursor: 1))
        details.beginInlineRename(row: 1)                    // a.txt, collapsed
        XCTAssertEqual(details.tableView.numberOfRows, 7)
        XCTAssertNotNil(details.renameFieldFrame(forRow: 1))
        XCTAssertNotNil(details.renameController?.editingID)
        details.renameController?.cancel()
        XCTAssertEqual(details.topVisibleRow(), 0, "first item at or below the top header")
    }

    func testHeaderAccessibilityAndContextMenu() async throws {
        let h = try await ContentTestHarness.make(self)
        try requireGUISession()
        try h.dir("sub"); try h.file("a.txt", bytes: 10); try h.file("b.txt", bytes: 20)
        _ = try h.sandbox.createSparseFile("files/big.bin", size: 200_000_000)
        let browser = try await h.openBrowserWindow()   // a command handler, so the empty-space menu is built
        let details = try h.content(of: browser).details
        browser.session.updateViewState { $0.groupBy = .size }
        try await h.waitUntil("grouped rows") { details.tableView.numberOfRows == 7 }
        let header = try XCTUnwrap(details.tableView.view(atColumn: 0, row: 2, makeIfNecessary: true) as? GroupHeaderView)
        XCTAssertEqual(header.accessibilityIdentifier(), AXID.groupHeader("Tiny (0 – 16 KB)"))
        XCTAssertEqual(header.accessibilityValue() as? String, "Tiny (0 – 16 KB), 2 items, expanded")
        XCTAssertEqual(header.disclosure.accessibilityLabel(), "Collapse Tiny (0 – 16 KB)")
        header.disclosure.performClick(nil)
        XCTAssertEqual(details.tableView.numberOfRows, 5)
        let collapsed = try XCTUnwrap(details.tableView.view(atColumn: 0, row: 2, makeIfNecessary: true) as? GroupHeaderView)
        XCTAssertEqual(collapsed.accessibilityValue() as? String, "Tiny (0 – 16 KB), 2 items, collapsed")
        XCTAssertEqual(collapsed.disclosure.accessibilityLabel(), "Expand Tiny (0 – 16 KB)")
        let menu = try XCTUnwrap(details.contextMenu(forTableRow: 0))
        XCTAssertEqual(Array(menu.items.prefix(2).map(\.title)), ["Collapse All Groups", "Expand All Groups"])
        XCTAssertTrue(menu.items.contains { $0.identifier?.rawValue == "macx.menu.groupBy" }, "then the empty-space menu")
    }

    func testGroupByCommandsSaveTheFolderViewStateAndCheckTheMenu() async throws {
        let h = try await ContentTestHarness.make(self)
        try requireGUISession()
        try h.dir("sub"); try h.file("a.txt")
        let browser = try await h.openBrowserWindow()
        let content = try h.content(of: browser)
        let commands = try XCTUnwrap(content.handler as? FileCommandController)
        let target = CommandTarget.currentFolder(browser.session.folder)
        XCTAssertTrue(commands.canPerform(.groupByKind, target: target))
        commands.perform(.groupByKind, target: target, sender: nil)
        XCTAssertEqual(browser.session.viewState.groupBy, .kind)
        XCTAssertEqual(browser.session.folder.grouping, .kind)
        XCTAssertEqual(browser.probeGrouping, .kind)
        XCTAssertEqual(h.environment.settings.groupBy, .none, "the global default is never written")
        let item = NSMenuItem(title: "Kind", action: Selector(Command.groupByKind.selectorName), keyEquivalent: "")
        XCTAssertTrue(content.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        let none = NSMenuItem(title: "None", action: Selector(Command.groupByNone.selectorName), keyEquivalent: "")
        _ = content.validateMenuItem(none)
        XCTAssertEqual(none.state, .off)
        try await h.waitUntil("grouped") { content.details.tableView.numberOfRows == 4 }
        commands.perform(.viewAsIcons, target: target, sender: nil)
        XCTAssertEqual(browser.probeGrouping, .kind, "the folder's saved choice, also while Icons is ungrouped")
        XCTAssertEqual(browser.session.folder.grouping, GroupBy.none)
        XCTAssertFalse(commands.canPerform(.groupByName, target: target), "Group By is a Details command")
        commands.perform(.viewAsDetails, target: target, sender: nil)
        commands.perform(.groupByNone, target: target, sender: nil)
        try await h.waitUntil("ungrouped") { content.details.tableView.numberOfRows == 2 }
    }

    private func key(_ special: NSEvent.SpecialKey, flags: NSEvent.ModifierFlags = [], window: NSWindow?) throws -> NSEvent {
        let characters = String(Character(UnicodeScalar(UInt16(special.rawValue))!))
        let codes: [NSEvent.SpecialKey: UInt16] = [.upArrow: 126, .downArrow: 125, .leftArrow: 123, .rightArrow: 124]
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                              windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                              charactersIgnoringModifiers: characters, isARepeat: false,
                                              keyCode: codes[special] ?? 0))
    }
}

