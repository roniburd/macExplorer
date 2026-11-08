import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

/// Details rubber band (owner's design 2026-11-07): a file's icon + name, or anywhere on a selected row, is the item
/// (click selects, drag moves files). A press anywhere else draws a selection box; ⇧ adds, ⌘ toggles.
private struct NoBand: Error { let point: NSPoint }

@MainActor
final class DetailsRubberBandTests: XCTestCase {
    private func makeDetails(_ h: ContentTestHarness, names: [String]) async throws -> (DetailsViewController, FolderModel) {
        h.environment.settings.columns = DetailsColumns.defaults
        for name in names { try h.file(name) }
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        let window = try h.host(details)
        details.bind(folder)
        window.makeFirstResponder(details.tableView)
        details.view.layoutSubtreeIfNeeded()
        return (details, folder)
    }

    /// A point in the Kind column of `row` (blank as far as the item goes); `row == numberOfRows` is empty space.
    private func blank(_ details: DetailsViewController, row: Int) -> NSPoint {
        let table = details.tableView
        let column = table.rect(ofColumn: table.column(withIdentifier: DetailsColumns.identifier(.kind)))
        let y = row < table.numberOfRows ? table.rect(ofRow: row).midY : table.rect(ofRow: table.numberOfRows - 1).maxY + 30
        return NSPoint(x: column.midX, y: y)
    }

    /// The middle of `row`'s name text.
    private func name(_ details: DetailsViewController, row: Int) throws -> NSPoint {
        let cell = try XCTUnwrap(details.cellView(row: row, column: .name) as? NameCellView)
        cell.layoutSubtreeIfNeeded()
        let frame = cell.label.convert(cell.label.bounds, to: details.tableView)
        return NSPoint(x: frame.minX + 3, y: frame.midY)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in details: DetailsViewController,
                       flags: NSEvent.ModifierFlags = [], count: Int = 1) throws -> NSEvent {
        let table = details.tableView
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: table.convert(point, to: nil), modifierFlags: flags,
                                                timestamp: 0, windowNumber: table.window?.windowNumber ?? 0, context: nil,
                                                eventNumber: 0, clickCount: count, pressure: 1))
    }

    private func drag(_ details: DetailsViewController, from a: NSPoint, to b: NSPoint, flags: NSEvent.ModifierFlags = [])
        throws {
        let table = details.tableView
        table.mouseDown(with: try event(.leftMouseDown, at: a, in: details, flags: flags))
        // A file drag would start a real drag session and hang the run: stop here instead.
        guard details.isTrackingRubberBand else { throw NoBand(point: a) }
        table.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), in: details,
                                           flags: flags))
        table.mouseDragged(with: try event(.leftMouseDragged, at: b, in: details, flags: flags))
    }

    func testDragFromBlankPartOfRowSelectsTouchedRows() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder) = try await makeDetails(h, names: ["a", "b", "c", "d", "e"])
        try drag(details, from: blank(details, row: 1), to: blank(details, row: 3))
        XCTAssertTrue(details.isTrackingRubberBand)
        XCTAssertFalse(details.dragSource.isDragging, "a box, not a file drag")
        XCTAssertEqual(folder.selection.rows, IndexSet(integersIn: 1...3))
        XCTAssertEqual(details.tableView.selectedRowIndexes, IndexSet(integersIn: 1...3), "highlight mirrors the model")
        details.tableView.mouseUp(with: try event(.leftMouseUp, at: blank(details, row: 3), in: details))
        XCTAssertFalse(details.isTrackingRubberBand)
        XCTAssertFalse(details.tableView.subviews.contains { $0 is RubberBandView }, "the box is removed on mouse-up")
        XCTAssertEqual(folder.selection.rows, IndexSet(integersIn: 1...3))
    }

    func testBandShrinksBackWhenDraggedBack() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder) = try await makeDetails(h, names: ["a", "b", "c", "d", "e"])
        try drag(details, from: blank(details, row: 0), to: blank(details, row: 4))
        details.tableView.mouseDragged(with: try event(.leftMouseDragged, at: blank(details, row: 1), in: details))
        XCTAssertEqual(folder.selection.rows, IndexSet(integersIn: 0...1))
    }

    func testDragUpFromEmptySpaceBelowRows() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder) = try await makeDetails(h, names: ["a", "b", "c"])
        folder.select(.set(IndexSet(integer: 0), cursor: 0))
        try drag(details, from: blank(details, row: 3), to: blank(details, row: 1))
        XCTAssertEqual(folder.selection.rows, IndexSet(integersIn: 1...2))
    }

    func testShiftAddsAndCommandToggles() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder) = try await makeDetails(h, names: ["a", "b", "c", "d", "e"])
        folder.select(.set(IndexSet(integer: 0), cursor: 0))
        try drag(details, from: blank(details, row: 2), to: blank(details, row: 3), flags: .shift)
        XCTAssertEqual(folder.selection.rows, IndexSet([0, 2, 3]))
        details.tableView.mouseUp(with: try event(.leftMouseUp, at: blank(details, row: 3), in: details))
        try drag(details, from: blank(details, row: 4), to: blank(details, row: 3), flags: .command)
        XCTAssertEqual(folder.selection.rows, IndexSet([0, 2, 4]), "⌘ toggles the rows the box touches")
    }

    func testPlainClickOnBlankPartOfRowStillSelectsThatRow() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder) = try await makeDetails(h, names: ["a", "b", "c"])
        details.tableView.mouseDown(with: try event(.leftMouseDown, at: blank(details, row: 2), in: details))
        details.tableView.mouseUp(with: try event(.leftMouseUp, at: blank(details, row: 2), in: details))
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 2))
        details.tableView.mouseDown(with: try event(.leftMouseDown, at: blank(details, row: 3), in: details))
        details.tableView.mouseUp(with: try event(.leftMouseUp, at: blank(details, row: 3), in: details))
        XCTAssertEqual(folder.selection.rows, IndexSet(), "a click on empty space clears")
    }

    func testTinyMoveIsStillAClick() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder) = try await makeDetails(h, names: ["a", "b", "c"])
        let start = blank(details, row: 1)
        details.tableView.mouseDown(with: try event(.leftMouseDown, at: start, in: details))
        details.tableView.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: start.x + 1, y: start.y + 1), in: details))
        XCTAssertFalse(details.tableView.subviews.contains { $0 is RubberBandView })
        details.tableView.mouseUp(with: try event(.leftMouseUp, at: start, in: details))
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 1))
    }

    func testPressOnNameIsTheItemNotABox() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder) = try await makeDetails(h, names: ["a.txt", "b.txt", "c.txt"])
        details.tableView.mouseDown(with: try event(.leftMouseDown, at: try name(details, row: 1), in: details))
        XCTAssertFalse(details.isTrackingRubberBand, "the name drags the file")
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 1))
        details.tableView.mouseUp(with: try event(.leftMouseUp, at: try name(details, row: 1), in: details))
    }

    func testPressAnywhereOnSelectedRowIsTheItem() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder) = try await makeDetails(h, names: ["a", "b", "c", "d"])
        folder.select(.set(IndexSet([1, 2]), cursor: 2))
        details.tableView.mouseDown(with: try event(.leftMouseDown, at: blank(details, row: 2), in: details))
        XCTAssertFalse(details.isTrackingRubberBand, "a blue row drags the selection")
        XCTAssertEqual(folder.selection.rows, IndexSet([1, 2]), "kept for the drag until mouse-up")
        details.tableView.mouseUp(with: try event(.leftMouseUp, at: blank(details, row: 2), in: details))
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 2))
    }

    func testPressOnUnselectedRowBeyondNameTextIsBlank() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, _) = try await makeDetails(h, names: ["a", "b"])
        let table = details.tableView
        let nameColumn = table.rect(ofColumn: table.column(withIdentifier: DetailsColumns.identifier(.name)))
        let point = NSPoint(x: nameColumn.maxX - 8, y: table.rect(ofRow: 0).midY)
        table.mouseDown(with: try event(.leftMouseDown, at: point, in: details))
        XCTAssertTrue(details.isTrackingRubberBand, "blank part of the Name column starts a box")
    }

    func testDoubleClickOnBlankPartOfRowNeverStartsABox() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, _) = try await makeDetails(h, names: ["a", "b"])
        details.tableView.mouseDown(with: try event(.leftMouseDown, at: blank(details, row: 3), in: details, count: 2))
        XCTAssertFalse(details.isTrackingRubberBand)
    }
}
