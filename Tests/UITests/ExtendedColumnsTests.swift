import XCTest
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class ExtendedColumnsTests: XCTestCase {
    func testChooserHidesPathOutsideSearchResults() {
        XCTAssertFalse(DetailsColumns.availableColumns(isMultiFolder: false).contains(.path))
        XCTAssertTrue(DetailsColumns.availableColumns(isMultiFolder: true).contains(.path))
        XCTAssertTrue(DetailsColumns.availableColumns(isMultiFolder: false).contains(.tags))
        XCTAssertEqual(DetailsColumns.availableColumns(isMultiFolder: false).count, ColumnID.allCases.count - 1)
        XCTAssertEqual(ExtendedColumns.definition(.permissions).required, .permissions)
        XCTAssertEqual(ExtendedColumns.definition(.name).required, [])
        XCTAssertEqual(ExtendedColumns.definition(.path).required, [])
        XCTAssertEqual(ExtendedColumns.definition(.size).alignment, .right)
    }

    func testHeaderMenuOffersEveryColumnButNameAndPath() {
        let menu = DetailsColumns.headerMenu(columns: DetailsColumns.defaults, isMultiFolder: false, target: self,
                                             action: #selector(NSObject.description))
        let ids = menu.items.compactMap { $0.representedObject as? String }
        XCTAssertEqual(ids, DetailsColumns.availableColumns(isMultiFolder: false).filter { $0 != .name }.map(\.rawValue))
        XCTAssertTrue(menu.items.contains { $0.title == "Tags" })
    }

    func testRequiredAttributesOfVisibleColumns() {
        let columns = DetailsColumns.normalized(DetailsColumns.defaults).map { column in
            ColumnSetting(id: column.id, width: column.width, visible: column.visible || column.id == .tags || column.id == .owner)
        }
        XCTAssertEqual(ExtendedColumns.required(visible: columns), [.tags, .owner])
        XCTAssertEqual(ExtendedColumns.required(visible: DetailsColumns.defaults), [])
    }

    func testCellTexts() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.createFile("a.txt", contents: Data(count: 1)); try sandbox.setMode("a.txt", 0o640)
        try sandbox.setFinderTags(["Work", "Home"], on: "a.txt"); try sandbox.setFinderComment("line1\nline2", on: "a.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        defer { model.close() }
        let row = try XCTUnwrap(model.row(named: "a.txt"))
        XCTAssertEqual(ExtendedColumns.text(.tags, row: row, in: model, dateStyle: .absolute), "", "not loaded yet: empty, no I/O")
        XCTAssertEqual(ExtendedColumns.text(.owner, row: row, in: model, dateStyle: .absolute), "")
        model.requestExtendedAttributes(rows: IndexSet(integersIn: 0..<model.rowCount), .all)
        try await waitUntil("extended attributes loaded") { model.extendedAttributes(atRow: row) != nil }
        XCTAssertEqual(ExtendedColumns.text(.tags, row: row, in: model, dateStyle: .absolute), "Work, Home")
        XCTAssertEqual(ExtendedColumns.text(.permissions, row: row, in: model, dateStyle: .absolute), "-rw-r-----")
        XCTAssertEqual(ExtendedColumns.text(.owner, row: row, in: model, dateStyle: .absolute), NSUserName())
        XCTAssertEqual(ExtendedColumns.text(.comments, row: row, in: model, dateStyle: .absolute), "line1 line2")
        XCTAssertEqual(ExtendedColumns.text(.dateLastOpened, row: row, in: model, dateStyle: .absolute), "--")
        XCTAssertEqual(ExtendedColumns.text(.path, row: row, in: model, dateStyle: .absolute, home: env.settings.home), "~",
                       "the item's parent folder in ~ form (the sandbox root is Home here)")
    }

    func testLastOpenedText() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.createFile("a.txt")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try sandbox.setLastUsedDate(date, on: "a.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        defer { model.close() }
        let row = try XCTUnwrap(model.row(named: "a.txt"))
        model.requestExtendedAttributes(rows: IndexSet(integer: row), .lastOpened)
        try await waitUntil("last opened date loaded") { model.extendedAttributes(atRow: row) != nil }
        XCTAssertEqual(ExtendedColumns.text(.dateLastOpened, row: row, in: model, dateStyle: .absolute),
                       Formatters.date(date, style: .absolute))
    }

    func testSortByTagsLoadsAllAttributesThenSorts() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["b.txt", "a.txt"] { try sandbox.createFile(n, contents: Data(count: 1)) }
        try sandbox.setFinderTags(["zeta"], on: "a.txt"); try sandbox.setFinderTags(["alpha"], on: "b.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        defer { model.close() }
        XCTAssertEqual((0..<2).map(model.name(atRow:)), ["a.txt", "b.txt"])
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)))
        XCTAssertEqual(model.query.sort.field, .tags, "query (header indicator) updates immediately")
        XCTAssertEqual((0..<2).map(model.name(atRow:)), ["a.txt", "b.txt"], "rows keep their order until the load finishes")
        try await waitUntil("sorted by tags once loaded") { model.name(atRow: 0) == "b.txt" }
        XCTAssertEqual((0..<2).map(model.name(atRow:)), ["b.txt", "a.txt"])
    }

    /// The chooser adds a column to the table; its cells fill from visible-row reads (empty until loaded), a header
    /// click sorts by it (saved in the folder's view state), and Path is never in a folder listing's table.
    func testDetailsShowsLoadsAndSortsByExtendedColumn() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        try h.sandbox.setFinderTags(["zeta"], on: "files/a.txt"); try h.sandbox.setFinderTags(["alpha", "Red"], on: "files/b.txt")
        let (content, session, _) = try await h.makeContent()
        let details = content.details
        XCTAssertFalse(details.visibleColumnIDs().contains("tags"))
        XCTAssertEqual(details.tableView.column(withIdentifier: DetailsColumns.identifier(.path)), -1, "no Path column outside search results")
        let menu = details.headerMenu()
        let tagsItem = try XCTUnwrap(menu.items.first { $0.representedObject as? String == "tags" })
        XCTAssertEqual(tagsItem.state, .off)
        XCTAssertNil(menu.items.first { $0.representedObject as? String == "path" })
        menu.performActionForItem(at: menu.index(of: tagsItem))
        XCTAssertTrue(details.visibleColumnIDs().contains("tags"))
        XCTAssertEqual(details.headerMenu().items.first { $0.representedObject as? String == "tags" }?.state, .on)
        XCTAssertTrue(session.viewState.columns.contains { $0.id == .tags && $0.visible }, "saved for the folder")
        let b = try XCTUnwrap(session.folder.row(named: "b.txt"))
        try await h.waitUntil("tags cell loaded") { details.cellView(row: b, column: .tags)?.textField?.stringValue == "alpha, Red" }
        XCTAssertEqual(details.cellText(rowNamed: "a.txt", column: "tags"), "zeta")
        XCTAssertTrue(details.clickHeader("tags"))
        XCTAssertEqual(session.folder.query.sort, SortDescriptor(field: .tags, ascending: true))
        XCTAssertEqual(session.viewState.sort, SortDescriptor(field: .tags, ascending: true))
        try await h.waitUntil("sorted by tags") { details.visibleRowNames() == ["b.txt", "a.txt"] }
        XCTAssertTrue(details.clickHeader("tags"))
        try await h.waitUntil("sorted by tags descending") { details.visibleRowNames() == ["a.txt", "b.txt"] }
        XCTAssertFalse(details.clickHeader("path"), "not in the table")
    }

    // Moved from FolderSizeTextTests (P2-14).
    func testSizeTexts() {
        XCTAssertEqual(FolderSizeText.text(nil, enabled: false), "--")
        XCTAssertEqual(FolderSizeText.text(nil, enabled: true), "Calculating…")
        XCTAssertEqual(FolderSizeText.text(FolderSize(bytes: 5_000_000), enabled: true), "5 MB")
        XCTAssertEqual(FolderSizeText.text(FolderSize(bytes: 1_200_000, isPartial: true), enabled: true), "≥ 1.2 MB")
        XCTAssertEqual(FolderSizeText.accessibilityLabel(FolderSize(bytes: 1_200_000, isPartial: true), enabled: true), "at least 1.2 MB")
        XCTAssertNil(FolderSizeText.accessibilityLabel(FolderSize(bytes: 1_200_000), enabled: true))
    }

    func testSelectionSizeText() {
        var s = SelectionSummary(count: 2, files: 1, folders: 1, bytes: 3_000)
        XCTAssertEqual(SelectionSizeText.text(s, sizesEnabled: false), "3 KB")
        XCTAssertEqual(SelectionSizeText.text(s, sizesEnabled: true), "3 KB + calculating…")
        s.folderBytes = 5_000
        XCTAssertEqual(SelectionSizeText.text(s, sizesEnabled: true), "8 KB")
        XCTAssertEqual(SelectionSizeText.text(s, sizesEnabled: false), "3 KB", "sizes off: Phase 1 text")
    }

    func testStatusSelectionIncludesFolderSizes() {
        var s = SelectionSummary(count: 1, files: 0, folders: 1, bytes: 0)
        XCTAssertEqual(StatusText.selection(s, sizesEnabled: false), "1 selected", "Phase 1: folders only, no size")
        XCTAssertEqual(StatusText.selection(s, sizesEnabled: true), "1 selected (calculating…)")
        s.folderBytes = 2_000
        XCTAssertEqual(StatusText.selection(s, sizesEnabled: true), "1 selected (2 KB)")
    }

    // MARK: helpers

    private func loadedModel(_ directory: URL, env: CoreEnvironment) async throws -> FolderModel {
        let model = env.makeFolderModel(directory, query: nil)
        model.start()
        let deadline = ContinuousClock.now + .seconds(30)
        while model.state != .complete {
            guard ContinuousClock.now < deadline else { model.close(); throw LoadTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
        return model
    }

    /// Extended attributes are read off-main on lanes and applied on the main actor, which a CPU-starved CI runner
    /// can delay for seconds: a generous deadline, and a timeout fails at the caller's line (not as a wrong text).
    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out after \(timeout) waiting for: \(what)", file: file, line: line)
                throw LoadTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct LoadTimeout: Error {}
