import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
private final class RecordingSink: RowUpdateSink {
    var log: [String] = []
    func reloadAll() { log.append("reloadAll") }
    func beginRowUpdates() { log.append("begin") }
    func insertRows(_ rows: IndexSet) { log.append("insert\(Array(rows))") }
    func removeRows(_ rows: IndexSet) { log.append("remove\(Array(rows))") }
    func moveRow(_ from: Int, _ to: Int) { log.append("move\(from)>\(to)") }
    func reloadRows(_ rows: IndexSet) { log.append("reload\(Array(rows))") }
    func endRowUpdates() { log.append("end") }
}

@MainActor
final class DetailsViewTests: XCTestCase {
    // MARK: pure

    func testChangeApplierReloadsForResetAndLargeSets() {
        let sink = RecordingSink()
        ChangeApplier.apply(.reset, to: sink)
        ChangeApplier.apply(ChangeSet([.insert(IndexSet(integersIn: 0..<1_500))]), to: sink)
        XCTAssertEqual(sink.log, ["reloadAll", "reloadAll"])
    }

    func testChangeApplierAppliesSmallSetsInOrderWithReloadsLast() {
        let sink = RecordingSink()
        ChangeApplier.apply(ChangeSet([.reload(IndexSet(integer: 4)), .remove(IndexSet(integer: 1)),
                                       .insert(IndexSet(integer: 2)), .move(from: 0, to: 3)]), to: sink)
        XCTAssertEqual(sink.log, ["begin", "remove[1]", "insert[2]", "move0>3", "end", "reload[4]"])
        let empty = RecordingSink()
        ChangeApplier.apply(ChangeSet([]), to: empty)
        XCTAssertEqual(empty.log, [])
    }

    func testNextSortTogglesAndSwitchesField() {
        let byName = MacxFS.SortDescriptor(field: .name, ascending: true)
        XCTAssertEqual(DetailsColumns.nextSort(current: byName, clicked: .name), MacxFS.SortDescriptor(field: .name, ascending: false))
        XCTAssertEqual(DetailsColumns.nextSort(current: byName, clicked: .size), MacxFS.SortDescriptor(field: .size, ascending: true))
        XCTAssertEqual(DetailsColumns.nextSort(current: MacxFS.SortDescriptor(field: .size, ascending: true), clicked: .size),
                       MacxFS.SortDescriptor(field: .size, ascending: false))
    }

    func testColumnSettingsNormalizeAndToggle() {
        let messy = [ColumnSetting(id: .size, width: 10, visible: true), ColumnSetting(id: .name, width: 300, visible: false),
                     ColumnSetting(id: .size, width: 99, visible: false)]
        let normalized = DetailsColumns.normalized(messy)
        XCTAssertEqual(normalized.map(\.id).count, ColumnID.allCases.count, "every column exactly once")
        XCTAssertEqual(normalized.first?.id, .size, "stored order wins")
        XCTAssertEqual(normalized.first?.width, DetailsColumns.minWidth(.size), "width clamped to the minimum")
        XCTAssertEqual(normalized.first { $0.id == .name }?.visible, true, "Name can't be hidden")
        let toggled = DetailsColumns.toggling(normalized, .kind)
        XCTAssertNotEqual(toggled.first { $0.id == .kind }?.visible, normalized.first { $0.id == .kind }?.visible)
        XCTAssertEqual(DetailsColumns.toggling(normalized, .name).first { $0.id == .name }?.visible, true)
    }

    // MARK: AppKit (offscreen window)

    private func makeDetails(_ h: ContentTestHarness) async throws -> (DetailsViewController, FolderModel) {
        h.environment.settings.columns = DetailsColumns.defaults
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        try h.host(details)
        details.bind(folder)
        return (details, folder)
    }

    func testRowsFollowModelFoldersFirst() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("b.txt", bytes: 1_234); try h.file("a.txt"); try h.dir("zdir")
        let (details, _) = try await makeDetails(h)
        XCTAssertEqual(details.tableView.numberOfRows, 3)
        XCTAssertEqual(details.cellView(row: 0, column: .name)?.textField?.stringValue, "zdir")
        XCTAssertEqual(details.cellView(row: 0, column: .size)?.textField?.stringValue, "--")
        XCTAssertEqual(details.cellView(row: 2, column: .size)?.textField?.stringValue,
                       ByteCountFormatter.string(fromByteCount: 1_234, countStyle: .file))
        XCTAssertTrue(details.tableView.usesAlternatingRowBackgroundColors)
        XCTAssertEqual(details.tableView.accessibilityIdentifier(), AXID.detailsTable)
    }

    /// Unregistered extensions read "Document" in Kind, never the dyn.* identifier (QA round 3).
    func testKindOfUnknownExtensionIsDocument() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("c.dat", bytes: 1_500_000); try h.file("d.zzqq")
        let (details, folder) = try await makeDetails(h)
        for name in ["c.dat", "d.zzqq"] {
            let row = try XCTUnwrap(folder.row(named: name))
            XCTAssertEqual(details.cellView(row: row, column: .kind)?.textField?.stringValue, "Document", name)
        }
    }

    func testCutRowsAreDimmedAndItalic() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let (details, folder) = try await makeDetails(h)
        folder.cutNames = ["a.txt"]
        details.reloadSelectionDrawing()
        let row = try XCTUnwrap(folder.row(named: "a.txt"))
        let cut = try XCTUnwrap(details.cellView(row: row, column: .name) as? NameCellView)
        XCTAssertEqual(cut.alphaValue, 0.5, accuracy: 0.001)
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(cut.label.font)).contains(.italicFontMask))
        let other = try XCTUnwrap(details.cellView(row: 1 - row, column: .name) as? NameCellView)
        XCTAssertEqual(other.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(details.cellView(row: row, column: .size)?.alphaValue ?? 0, 0.5, accuracy: 0.001)
    }

    func testDensityChangesRowHeight() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (details, _) = try await makeDetails(h)
        h.environment.settings.density = .compact
        try await h.waitUntil("compact rows") { details.tableView.rowHeight == 20 }
        h.environment.settings.density = .comfortable
        try await h.waitUntil("comfortable rows") { details.tableView.rowHeight == 30 }
    }

    func testHeaderClickSortsAndReportsTheSort() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("big.txt", bytes: 3_000); try h.file("small.txt", bytes: 10); try h.file("mid.txt", bytes: 500)
        let (details, folder) = try await makeDetails(h)
        var reported: [MacxFS.SortDescriptor] = []
        details.onSortChanged = { sort in   // as BrowserSession.updateViewState does (P2-08)
            reported.append(sort)
            var query = folder.query
            query.sort = sort
            folder.setQuery(query)
        }
        let sizeColumn = try XCTUnwrap(details.tableView.tableColumns.first { DetailsColumns.columnID($0.identifier) == .size })
        details.tableView(details.tableView, didClick: sizeColumn)
        try await h.waitUntil("ascending by size") { (0..<3).map(folder.name(atRow:)) == ["small.txt", "mid.txt", "big.txt"] }
        details.tableView(details.tableView, didClick: sizeColumn)
        try await h.waitUntil("descending by size") { (0..<3).map(folder.name(atRow:)) == ["big.txt", "mid.txt", "small.txt"] }
        XCTAssertEqual(reported.last, MacxFS.SortDescriptor(field: .size, ascending: false))
        XCTAssertEqual(h.environment.settings.sort, .default, "per-folder state, not the global default (P2-08)")
        XCTAssertNotNil(details.tableView.indicatorImage(in: sizeColumn))
    }

    func testHidingColumnReportsTheColumns() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (details, _) = try await makeDetails(h)
        var reported: [ColumnSetting]?
        details.onColumnsChanged = { reported = $0 }
        let item = try XCTUnwrap(details.tableView.headerView?.menu?.items.first { $0.representedObject as? String == ColumnID.kind.rawValue })
        details.toggleColumn(item)
        XCTAssertEqual(reported?.first { $0.id == .kind }?.visible, false)
        XCTAssertEqual(h.environment.settings.columns.first { $0.id == .kind }?.visible, true, "global default untouched (P2-08)")
        XCTAssertEqual(details.tableView.tableColumns.first { DetailsColumns.columnID($0.identifier) == .kind }?.isHidden, true)
    }

    func testColumnMoveReportsTheOrder() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (details, _) = try await makeDetails(h)
        var reported: [ColumnSetting]?
        details.onColumnsChanged = { reported = $0 }
        let moved = DetailsColumns.columnID(details.tableView.tableColumns[1].identifier)
        details.tableView.moveColumn(1, toColumn: 3)
        XCTAssertEqual(reported?.map(\.id)[3], moved)
        XCTAssertEqual(details.columns.map(\.id)[3], moved)
    }

    func testLocalChangeInsertsRowThroughContentController() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let (content, session, _) = try await h.makeContent()
        XCTAssertEqual(content.details.tableView.numberOfRows, 2)
        try h.file("new.txt")
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), added: ["new.txt"]))
        try await h.waitUntil("row inserted") { content.details.tableView.numberOfRows == 3 }
        XCTAssertNotNil(session.folder.row(named: "new.txt"))
    }

    /// P2-14: with Calculate Folder Sizes on, folder Size cells go "Calculating…" → size (through `.folderSizes`),
    /// partial sizes read "≥ …" with an "at least" label, the status bar adds the folders' sizes, and the toggle off
    /// goes back to "--". `cellText` (scenario hook) reports what the cell shows.
    func testFolderSizeCellsAndSelectionTotal() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("big/a.bin", bytes: 5_000); try h.file("part/b.bin", bytes: 10); try h.file("f.txt", bytes: 3)
        let (content, session, _) = try await h.makeContent()
        let details = content.details
        let folder = session.folder
        let big = try XCTUnwrap(folder.row(named: "big")), part = try XCTUnwrap(folder.row(named: "part"))
        XCTAssertEqual(details.cellView(row: big, column: .size)?.textField?.stringValue, "--")
        XCTAssertEqual(details.cellText(rowNamed: "big", column: "size"), "--")
        session.updateViewState { $0.calculateFolderSizes = true }
        session.sizeSession?.stop()                      // sizes are set by hand below
        XCTAssertEqual(details.cellView(row: big, column: .size)?.textField?.stringValue, "Calculating…")
        XCTAssertEqual(details.cellView(row: big, column: .size)?.textField?.textColor, .secondaryLabelColor,
                       "pending folder sizes are in the secondary colour")
        folder.select(.names(["big", "f.txt"]))
        XCTAssertEqual(content.statusBar.selectionText, "2 selected (3 bytes + calculating…)")
        folder.setFolderSizes([folder.identity(atRow: big): FolderSize(bytes: 5_000),
                               folder.identity(atRow: part): FolderSize(bytes: 1_200_000, isPartial: true)])
        XCTAssertEqual(details.cellView(row: big, column: .size)?.textField?.stringValue, "5 KB")
        XCTAssertEqual(details.cellText(rowNamed: "big", column: "size"), "5 KB")
        let partial = try XCTUnwrap(details.cellView(row: part, column: .size)?.textField)
        XCTAssertEqual(partial.stringValue, "≥ 1.2 MB")
        XCTAssertEqual(partial.accessibilityLabel(), "at least 1.2 MB")
        XCTAssertEqual(content.statusBar.selectionText, "2 selected (5 KB)")
        session.updateViewState { $0.calculateFolderSizes = false }
        XCTAssertEqual(details.cellView(row: big, column: .size)?.textField?.stringValue, "--")
        XCTAssertEqual(content.statusBar.selectionText, "2 selected (3 bytes)")
    }

    func testScrollAnchorSurvivesResort() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<300 { try h.file(String(format: "f%03d.txt", i)) }
        let (content, session, _) = try await h.makeContent(size: NSSize(width: 800, height: 400))
        let details = content.details
        details.scrollRowToTop(150)
        let anchor = try XCTUnwrap(session.folder.scrollAnchor, "scrolling records the top row's identity")
        XCTAssertEqual(session.folder.row(of: anchor), 150)
        var query = session.folder.query
        query.sort = MacxFS.SortDescriptor(field: .name, ascending: false)
        session.folder.setQuery(query)
        try await h.waitUntil("re-sorted") { session.folder.row(of: anchor) == 149 }
        try await h.waitUntil("anchor row back on top") { details.topVisibleRow() == 149 }
    }

    func testScrollAtTopKeepsNoAnchor() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<100 { try h.file(String(format: "f%03d.txt", i)) }
        let (content, session, _) = try await h.makeContent(size: NSSize(width: 800, height: 300))
        content.details.scrollRowToTop(40)
        XCTAssertNotNil(session.folder.scrollAnchor)
        content.details.scrollRowToTop(0)
        XCTAssertNil(session.folder.scrollAnchor, "at the top there is no anchor, so resets keep the view at the top")
    }

    func testCellConfigureIsFast() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<1_000 { try h.file(String(format: "n%04d.txt", i), bytes: i) }
        let (details, _) = try await makeDetails(h)
        let columns = details.tableView.tableColumns.filter { !$0.isHidden }
        let start = ContinuousClock.now
        for row in 0..<1_000 { for column in columns { _ = details.tableView(details.tableView, viewFor: column, row: row) } }
        let perCell = (ContinuousClock.now - start) / (1_000 * columns.count)
        XCTAssertLessThan(perCell, .milliseconds(2), "budget 0.5 ms (§4.4); debug tests allow 4x")
    }
}
