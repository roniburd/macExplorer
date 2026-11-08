import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

/// Columns (Miller) view UI (P2-19). Every file lives in the harness sandbox.
@MainActor
final class ColumnsViewTests: XCTestCase {
    private func makeChain(_ h: ContentTestHarness, _ relative: String) -> ColumnChain {
        let env = h.environment
        let chain = ColumnChain(root: h.url(relative)) { url in env.makeFolderModel(url) }
        addTeardownBlock { @MainActor in chain.close() }
        return chain
    }

    func testOneTablePerColumnAndActiveListForwarding() async throws {
        try requireGUISession()
        let h = try await ContentTestHarness.make(self)
        try h.file("A/B/c.txt")
        let controller = ColumnsViewController(context: h.context)
        try h.host(controller)
        let chain = makeChain(h, "")
        controller.bindChain(chain)
        try await h.waitUntil("root listed") { chain.models[0].state == .complete }
        chain.models[0].select(.names(["A"]))
        XCTAssertEqual(controller.columnControllers.count, 2)
        XCTAssertTrue(controller.folder === chain.activeModel)
        XCTAssertTrue(controller.columnControllers[1].model === chain.models[1])
        chain.moveRight()
        XCTAssertTrue(controller.folder === chain.models[1])
        XCTAssertEqual(controller.columnControllers[0].tableView.accessibilityIdentifier(), AXID.column(0))
        XCTAssertEqual(controller.columnControllers[1].tableView.accessibilityIdentifier(), AXID.column(1))
        XCTAssertEqual(controller.columnControllers[1].tableView.accessibilityLabel(), "A")
        XCTAssertEqual(controller.view.accessibilityIdentifier(), AXID.columnsView)
        XCTAssertEqual(controller.columnControllers[0].tableView.numberOfColumns, 1)
        XCTAssertNil(controller.columnControllers[0].tableView.headerView)
        XCTAssertFalse(controller.columnControllers[0].tableView.usesAlternatingRowBackgroundColors)
        // Selecting a file in column 0 closes column 1 and drops its controller.
        let first = controller.columnControllers[0]
        chain.activate(0)
        try h.file("r.txt")
        // Announced like the app's own file operations do, so no FSEvents delivery is waited for.
        chain.models[0].applyLocalChange(LocalChange(directory: h.url(""), added: ["r.txt"]))
        try await h.waitUntil("r.txt listed") { chain.models[0].row(named: "r.txt") != nil }
        chain.models[0].select(.names(["r.txt"]))
        XCTAssertEqual(controller.columnControllers.count, 1)
        XCTAssertTrue(controller.columnControllers[0] === first, "kept columns keep their controller (and scroll)")
    }

    func testColumnRowsUpdateFromTheirOwnModel() async throws {
        try requireGUISession()
        let h = try await ContentTestHarness.make(self)
        try h.file("A/x.txt")
        let controller = ColumnsViewController(context: h.context)
        try h.host(controller)
        let chain = makeChain(h, "")
        controller.bindChain(chain)
        try await h.waitUntil("root listed") { chain.models[0].state == .complete }
        chain.models[0].select(.names(["A"]))
        let child = controller.columnControllers[1]
        try await h.waitUntil("A listed") { child.tableView.numberOfRows == 1 }
        try h.file("A/y.txt")
        // The column's own model patches the change (announced like the app's file operations, not via FSEvents).
        child.model.applyLocalChange(LocalChange(directory: h.url("A"), added: ["y.txt"]))
        try await h.waitUntil("update reaches column 1") { child.tableView.numberOfRows == 2 }
        let cell = try XCTUnwrap(child.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? ColumnCellView)
        XCTAssertEqual(cell.label.stringValue, "y.txt")
        XCTAssertTrue(cell.chevron.isHidden, "files have no chevron")
        let folderCell = try XCTUnwrap(controller.columnControllers[0].tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                                       as? ColumnCellView)
        XCTAssertEqual(folderCell.label.stringValue, "A")
        XCTAssertFalse(folderCell.chevron.isHidden, "folders show a chevron")
        XCTAssertEqual(folderCell.label.lineBreakMode, .byTruncatingMiddle)
    }

    /// Columns show Finder display names like Details and Icons: hidden ".app", localized stems; auto-fit measures them.
    func testColumnCellsShowDisplayNames() async throws {
        try requireGUISession()
        let h = try await ContentTestHarness.make(self)
        let wide = "Wide " + String(repeating: "W", count: 18)
        try h.dir("\(wide).app/Contents")
        try h.dir("Projects.localized/inner")
        let controller = ColumnsViewController(context: h.context)
        try h.host(controller)
        let chain = makeChain(h, "")
        controller.bindChain(chain)
        let model = chain.models[0]
        try await h.waitUntil("root listed with localized stems") {
            model.state == .complete && (0..<model.rowCount).map { model.displayName(atRow: $0) }.contains("Projects")
        }
        let column = controller.columnControllers[0]
        func labels() -> Set<String> {
            Set((0..<column.tableView.numberOfRows).compactMap {
                (column.tableView.view(atColumn: 0, row: $0, makeIfNecessary: true) as? ColumnCellView)?.label.stringValue
            })
        }
        try await h.waitUntil("cells show display names") { labels() == [wide, "Projects"] }
        column.autoFit()
        XCTAssertEqual(column.width, ColumnWidth.fit(names: [wide, "Projects"], font: CellStyle.font))
    }

    func testKeyboardRightLeftReturn() async throws {
        try requireGUISession()
        let h = try await ContentTestHarness.make(self)
        try h.file("A/B/c.txt"); try h.file("A/x.txt")
        let controller = ColumnsViewController(context: h.context)
        try h.host(controller)
        let chain = makeChain(h, "A")
        controller.bindChain(chain)
        try await h.waitUntil("A listed") { chain.models[0].state == .complete }
        chain.models[0].select(.names(["B"]))
        try await h.waitUntil("B listed") { chain.models.count == 2 && chain.models[1].state == .complete }
        XCTAssertTrue(controller.handleColumnKey(KeyChord(.right)))
        XCTAssertEqual(chain.activeIndex, 1)
        XCTAssertEqual(chain.activeModel.selectedURLs.map(\.lastPathComponent), ["c.txt"])
        XCTAssertFalse(controller.handleColumnKey(KeyChord(.right)), "a file opens no further column")
        XCTAssertTrue(controller.handleColumnKey(KeyChord(.left)))
        XCTAssertEqual(chain.activeIndex, 0)
        XCTAssertTrue(controller.handleColumnKey(KeyChord(.returnKey)), "Return on the selected folder → into it")
        XCTAssertEqual(chain.activeIndex, 1)
        XCTAssertTrue(controller.handleColumnKey(KeyChord(.up, .command)))
        XCTAssertEqual(chain.activeIndex, 0)
        chain.models[0].select(.names(["x.txt"]))
        XCTAssertFalse(controller.handleColumnKey(KeyChord(.returnKey)), "Return on a file is the Phase 1 open")
        XCTAssertFalse(controller.handleColumnKey(KeyChord(.down)), "↓ is the column's own selection key")
    }

    func testKeyDownMovesFocusToTheActiveColumn() async throws {
        try requireGUISession()
        let h = try await ContentTestHarness.make(self)
        try h.file("A/B/c.txt")
        let controller = ColumnsViewController(context: h.context)
        let window = try h.host(controller)
        let chain = makeChain(h, "A")
        controller.bindChain(chain)
        try await h.waitUntil("A listed") { chain.models[0].state == .complete }
        chain.models[0].select(.names(["B"]))
        try await h.waitUntil("B listed") { chain.models.count == 2 && chain.models[1].state == .complete }
        window.makeFirstResponder(controller.columnControllers[0].tableView)
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                                                   charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                                                   isARepeat: false, keyCode: 124))
        controller.columnControllers[0].tableView.keyDown(with: right)
        XCTAssertEqual(chain.activeIndex, 1)
        XCTAssertTrue(window.firstResponder === controller.columnControllers[1].tableView, "focus follows the active column")
        XCTAssertTrue(controller.focusView === controller.columnControllers[1].tableView)
    }

    func testMoveRightSelectsFirstRowOnceTheColumnIsListed() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("A/B/c.txt")
        let chain = makeChain(h, "A")
        try await h.waitUntil("A listed") { chain.models[0].state == .complete }
        chain.models[0].select(.names(["B"]))
        XCTAssertTrue(chain.moveRight(), "moving into a column that is still listing")
        try await h.waitUntil("first row selected once listed") { chain.activeModel.selectedURLs.map(\.lastPathComponent) == ["c.txt"] }
    }

    func testAutoFitWidthMeasuresNamesAndClamps() {
        let font = CellStyle.font
        XCTAssertEqual(ColumnWidth.fit(names: [], font: font), ColumnWidth.minimum)
        XCTAssertEqual(ColumnWidth.fit(names: ["a"], font: font), ColumnWidth.minimum)
        XCTAssertEqual(ColumnWidth.fit(names: [String(repeating: "W", count: 400)], font: font), ColumnWidth.maximum)
        let mid = String(repeating: "m", count: 20)
        let fitted = ColumnWidth.fit(names: ["a", mid], font: font)
        XCTAssertGreaterThan(fitted, ColumnWidth.minimum)
        XCTAssertLessThan(fitted, ColumnWidth.maximum)
        XCTAssertGreaterThan(fitted, (mid as NSString).size(withAttributes: [.font: font]).width)
        XCTAssertEqual(ColumnWidth.clamp(50), ColumnWidth.minimum)
        XCTAssertEqual(ColumnWidth.clamp(9_000), ColumnWidth.maximum)
        XCTAssertEqual(ColumnWidth.fitSampleLimit, 2_000)
    }

    func testResizeHandleSetsTheColumnWidthAndSavesIt() async throws {
        try requireGUISession()
        let h = try await ContentTestHarness.make(self)
        try h.file("A/x.txt")
        let controller = ColumnsViewController(context: h.context)
        try h.host(controller)
        let chain = makeChain(h, "")
        controller.bindChain(chain)
        try await h.waitUntil("root listed") { chain.models[0].state == .complete }
        let column = controller.columnControllers[0]
        XCTAssertEqual(column.width, CGFloat(h.environment.settings.columnWidth))
        column.setWidth(300, save: true)
        XCTAssertEqual(column.width, 300)
        XCTAssertEqual(h.environment.settings.columnWidth, 300, "the last width is saved")
        column.setWidth(5, save: true)
        XCTAssertEqual(column.width, ColumnWidth.minimum)
        chain.models[0].select(.names(["A"]))
        XCTAssertEqual(controller.columnControllers[1].width, ColumnWidth.minimum, "new columns use the saved width")
        column.autoFit()
        XCTAssertEqual(column.width, ColumnWidth.fit(names: ["A"], font: CellStyle.font))
    }

    // MARK: in the content view and the window

    func testContentViewShowsColumnsAndFollowsTheChain() async throws {
        try requireGUISession()
        let h = try await ContentTestHarness.make(self)
        try h.file("A/B/c.txt"); try h.file("r.txt")
        let (content, session, _) = try await h.makeContent()
        session.updateViewState { $0.mode = .columns }
        let columns = try XCTUnwrap(content.activeList as? ColumnsViewController)
        XCTAssertTrue(columns.view.isDescendant(of: content.listContainer))
        XCTAssertEqual(columns.columnControllers.count, 1)
        session.folder.select(.names(["A"]))
        XCTAssertEqual(columns.columnControllers.count, 2)
        XCTAssertTrue(session.columnChain!.moveRight())
        XCTAssertTrue(columns.folder === session.folder)
        XCTAssertNil(content.emptyState.currentText, "the content-level empty state is not used in Columns")
        session.updateViewState { $0.mode = .details }
        XCTAssertTrue(content.activeList === content.details)
        XCTAssertTrue(columns.columnControllers.isEmpty, "leaving Columns drops every column")
        XCTAssertEqual(session.folder.directory.lastPathComponent, "A")
    }

    func testEmptyColumnShowsItsOwnEmptyState() async throws {
        try requireGUISession()
        let h = try await ContentTestHarness.make(self)
        try h.dir("E")
        let (content, session, _) = try await h.makeContent()
        session.updateViewState { $0.mode = .columns }
        let columns = try XCTUnwrap(content.activeList as? ColumnsViewController)
        session.folder.select(.names(["E"]))
        let column = columns.columnControllers[1]
        try await h.waitUntil("E listed") { column.model.state == .complete }
        XCTAssertEqual(column.emptyState.currentText, L10n.string("This folder is empty"))
        XCTAssertNil(columns.columnControllers[0].emptyState.currentText)
    }

    func testOpenAndUpCommandsMoveBetweenColumns() async throws {
        try requireGUISession()
        let h = try await ContentTestHarness.make(self)
        try h.file("A/B/c.txt"); try h.file("A/x.txt")
        let window = try await h.openBrowserWindow()
        let session = window.session
        let content = try h.content(of: window)
        let handler = try XCTUnwrap(content.handler)
        XCTAssertTrue(handler.canPerform(.viewAsColumns, target: .contentSelection(session.folder)))
        handler.perform(.viewAsColumns, target: .contentSelection(session.folder), sender: nil)
        XCTAssertEqual(session.viewMode, .columns)
        let chain = try XCTUnwrap(session.columnChain)
        session.folder.select(.names(["A"]))
        try await h.waitUntil("A listed") { chain.models.count == 2 && chain.models[1].state == .complete }
        handler.perform(.open, target: .contentSelection(session.folder), sender: nil)   // Return / ⌘↓ / double-click
        XCTAssertEqual(chain.activeIndex, 1, "open on the selected folder moves into its column")
        XCTAssertEqual(session.folder.directory.lastPathComponent, "A")
        XCTAssertEqual(session.history.backList.count, 0, "moving between columns records no history")
        handler.perform(.up, target: .contentSelection(session.folder), sender: nil)      // ⌘↑
        XCTAssertEqual(chain.activeIndex, 0)
        XCTAssertTrue(session.columnChain === chain)
        XCTAssertFalse(handler.canPerform(.toggleFolderSizes, target: .contentSelection(session.folder)))
        XCTAssertFalse(handler.canPerform(.groupByKind, target: .contentSelection(session.folder)))
    }

    func testLeavingColumnsForADeeperFolderRecordsItInHistory() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("A/x.txt")
        let session = BrowserSession(environment: h.environment, initialURL: h.url(""))
        defer { session.close() }
        session.updateViewState { $0.mode = .columns }
        try await h.waitUntil("root listed") { session.folder.state == .complete }
        session.folder.select(.names(["A"]))
        XCTAssertTrue(session.columnChain!.moveRight())
        session.updateViewState { $0.mode = .details }
        XCTAssertEqual(session.folder.directory.lastPathComponent, "A")
        XCTAssertTrue(session.history.canGoBack)
        session.goBack()
        XCTAssertEqual(session.folder.directory.standardizedFileURL, h.url("").standardizedFileURL)
        XCTAssertEqual(session.viewMode, .columns, "the root still remembers Columns")
    }

    func testToolbarAndCommandBarOfferColumns() {
        XCTAssertEqual(ToolbarController.switcherModes, [.details, .icons, .columns])
        let bar = CommandBarView()
        XCTAssertTrue(bar.viewMenu.items.contains { $0.action == Selector(Command.viewAsColumns.selectorName) })
        XCTAssertFalse(FileCommandController.pendingCommands.contains(.viewAsColumns))
    }
}
