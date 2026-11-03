// Tests/UITests/SelectionControllerTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class SelectionControllerTests: XCTestCase {
    private let one = IndexSet(integer: 1)

    func testPlainClickSelectsOnly() {
        XCTAssertEqual(SelectionController.click(row: 3, clickCount: 1, modifiers: [], selectedRows: one),
                       .select(.set(IndexSet(integer: 3), cursor: 3)))
    }

    func testModifierClicks() {
        XCTAssertEqual(SelectionController.click(row: 3, clickCount: 1, modifiers: .command, selectedRows: one), .select(.toggle(3)))
        XCTAssertEqual(SelectionController.click(row: 3, clickCount: 1, modifiers: .shift, selectedRows: one), .select(.extend(to: 3)))
        XCTAssertEqual(SelectionController.click(row: 3, clickCount: 1, modifiers: [.command, .shift], selectedRows: one),
                       .select(.extend(to: 3)))
        XCTAssertEqual(SelectionController.click(row: nil, clickCount: 1, modifiers: [], selectedRows: one), .select(.none))
        XCTAssertEqual(SelectionController.click(row: nil, clickCount: 1, modifiers: .command, selectedRows: one), .nothing)
    }

    func testClickInsideMultiSelectionDefersToMouseUp() {
        XCTAssertEqual(SelectionController.click(row: 2, clickCount: 1, modifiers: [], selectedRows: IndexSet([1, 2])),
                       .selectOnMouseUp(.set(IndexSet(integer: 2), cursor: 2)), "keeps the selection so it can be dragged")
    }

    func testDoubleClickOpensAndCommandDoubleClickOpensNewWindow() {
        XCTAssertEqual(SelectionController.click(row: 2, clickCount: 2, modifiers: [], selectedRows: one), .open(newWindow: false))
        XCTAssertEqual(SelectionController.click(row: 2, clickCount: 2, modifiers: .command, selectedRows: one), .open(newWindow: true))
        XCTAssertEqual(SelectionController.click(row: nil, clickCount: 2, modifiers: [], selectedRows: one), .nothing)
    }

    func testArrowsLinear() {
        let nav = SelectionController.linearNavigator(rowCount: 10)
        func arrow(_ key: NavKey, _ cursor: Int?, extend: Bool = false) -> SelectionCommand? {
            SelectionController.arrow(key, extend: extend, cursorRow: cursor, rowCount: 10, pageSize: 4, navigate: nav)
        }
        XCTAssertEqual(arrow(.down, 3), .set(IndexSet(integer: 4), cursor: 4))
        XCTAssertEqual(arrow(.up, 3, extend: true), .extend(to: 2))
        XCTAssertNil(arrow(.up, 0))
        XCTAssertNil(arrow(.down, 9))
        XCTAssertEqual(arrow(.down, nil), .set(IndexSet(integer: 0), cursor: 0), "no cursor: start at the first row")
        XCTAssertEqual(arrow(.end, 3), .set(IndexSet(integer: 9), cursor: 9))
        XCTAssertEqual(arrow(.home, 3, extend: true), .extend(to: 0))
        XCTAssertEqual(arrow(.pageDown, 8), .set(IndexSet(integer: 9), cursor: 9))
        XCTAssertEqual(arrow(.pageUp, 6), .set(IndexSet(integer: 2), cursor: 2))
        XCTAssertNil(SelectionController.arrow(.down, extend: false, cursorRow: nil, rowCount: 0, pageSize: 4, navigate: nav))
    }

    func testLeftRightDoNothingInDetails() {
        let nav = SelectionController.linearNavigator(rowCount: 10)
        XCTAssertNil(nav(3, .left))
        XCTAssertNil(nav(3, .right))
    }

    func testGridNavigatorMapping() {
        let grid = FileGridLayout()
        grid.itemCount = 10
        grid.fallbackWidth = 600
        let nav = SelectionController.gridNavigator(grid)
        XCTAssertEqual(nav(1, .down), 5)
        XCTAssertEqual(nav(4, .left), 3)
        XCTAssertNil(nav(1, .home), "Home/End/Page are handled by SelectionController.arrow, not the navigator")
    }

    // MARK: AppKit

    private func makeDetails(_ h: ContentTestHarness, names: [String]) async throws -> (DetailsViewController, FolderModel, NSWindow) {
        for name in names { try h.file(name) }
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        let window = try h.host(details)
        details.bind(folder)
        window.makeFirstResponder(details.tableView)
        return (details, folder, window)
    }

    private func click(_ details: DetailsViewController, row: Int, flags: NSEvent.ModifierFlags = [], count: Int = 1,
                       type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        let table = details.tableView
        let point = table.convert(NSPoint(x: table.rect(ofRow: row).midX, y: table.rect(ofRow: row).midY), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                                windowNumber: table.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                clickCount: count, pressure: 1))
    }

    func testShiftClickInTableExtendsModelSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder, _) = try await makeDetails(h, names: ["a", "b", "c", "d", "e"])
        details.tableView.mouseDown(with: try click(details, row: 1))
        details.tableView.mouseUp(with: try click(details, row: 1, type: .leftMouseUp))
        details.tableView.mouseDown(with: try click(details, row: 3, flags: .shift))
        XCTAssertEqual(folder.selection.rows, IndexSet(integersIn: 1...3))
        details.tableView.mouseDown(with: try click(details, row: 2, flags: .command))
        XCTAssertEqual(folder.selection.rows, IndexSet([1, 3]))
        XCTAssertEqual(details.tableView.selectedRowIndexes, IndexSet([1, 3]), "highlight mirrors the model")
    }

    func testMouseUpAppliesDeferredSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder, _) = try await makeDetails(h, names: ["a", "b", "c"])
        folder.select(.set(IndexSet([0, 2]), cursor: 2))
        details.tableView.mouseDown(with: try click(details, row: 2))
        XCTAssertEqual(folder.selection.rows, IndexSet([0, 2]), "unchanged until mouse-up")
        details.tableView.mouseUp(with: try click(details, row: 2, type: .leftMouseUp))
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 2))
    }

    func testCommandArrowDoesNotChangeSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder, window) = try await makeDetails(h, names: ["a", "b", "c"])
        folder.select(.set(IndexSet(integer: 1), cursor: 1))
        let down = String(Character(UnicodeScalar(UInt16(NSEvent.SpecialKey.downArrow.rawValue))!))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: down,
                                                   charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125))
        details.tableView.keyDown(with: event)
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 1))
        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: down,
                                                   charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125))
        details.tableView.keyDown(with: plain)
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 2))
    }

    func testBuiltInTableSelectionNeverReachesModel() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder, _) = try await makeDetails(h, names: ["a", "b", "c"])
        folder.select(.set(IndexSet(integer: 0), cursor: 0))
        let result = details.tableView(details.tableView, selectionIndexesForProposedSelection: IndexSet(integer: 2))
        XCTAssertEqual(result, IndexSet(integer: 0))
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 0))
    }
}
