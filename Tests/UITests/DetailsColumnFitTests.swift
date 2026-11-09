import XCTest
import AppKit
@testable import UI
import Core

/// With the preview pane open the content pane can be narrower than the stored columns: columns shrink on screen
/// from the right to fit (no Size and Kind off the edge behind a horizontal scroller) and keep their stored widths.
@MainActor
final class DetailsColumnFitTests: XCTestCase {
    func testColumnsShrinkFromTheRightToFitAndKeepTheirStoredWidths() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt")
        h.environment.settings.columns = DetailsColumns.normalized([
            ColumnSetting(id: .name, width: 250, visible: true), ColumnSetting(id: .dateModified, width: 248, visible: true),
            ColumnSetting(id: .size, width: 400, visible: true), ColumnSetting(id: .kind, width: 600, visible: true),
        ]).map { [.name, .dateModified, .size, .kind].contains($0.id) ? $0 : ColumnSetting(id: $0.id, width: $0.width, visible: false) }
        let controller = try await h.openWindow()
        let content = try XCTUnwrap(controller.contentPane as? ContentViewController)
        let details = content.details
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.layoutIfNeeded()
        let table = details.tableView
        func kind() throws -> NSTableColumn { try XCTUnwrap(table.tableColumns.first { DetailsColumns.columnID($0.identifier) == .kind }) }
        func overflow() -> CGFloat {
            let visible = table.tableColumns.filter { !$0.isHidden }
            let used = visible.reduce(CGFloat(0)) { $0 + $1.width } + table.intercellSpacing.width * CGFloat(visible.count)
            return used - details.scrollView.contentView.bounds.width
        }
        try await h.waitUntil("columns fit") { details.scrollView.contentView.bounds.width > 0 && overflow() <= 0.5 }
        XCTAssertEqual(try kind().width, try kind().minWidth, "Kind, the rightmost, gives up its room first")
        XCTAssertLessThan(try XCTUnwrap(table.tableColumns.first { DetailsColumns.columnID($0.identifier) == .size }).width, 400,
                          "then Size")
        XCTAssertEqual(details.columns.first { $0.id == .kind }?.width, 600, "the stored widths are kept")
        table.tile()
        XCTAssertLessThanOrEqual(table.frame.width, details.scrollView.contentView.bounds.width, "no horizontal scrolling")
        XCTAssertEqual(details.columns.first { $0.id == .size }?.width, 400)

        // Another column's change is saved without saving Kind's on-screen width.
        let name = try XCTUnwrap(table.tableColumns.first { DetailsColumns.columnID($0.identifier) == .name })
        name.width = 260
        try await h.waitUntil("name saved") { details.columns.first { $0.id == .name }?.width == 260 }
        XCTAssertEqual(details.columns.first { $0.id == .kind }?.width, 600)
        XCTAssertLessThanOrEqual(overflow(), 0.5, "Kind gave up the room Name took")

        // Room comes back: Kind grows back to its stored width.
        window.setContentSize(NSSize(width: 2400, height: 700))
        window.layoutIfNeeded()
        try await h.waitUntil("kind restored") { (try? kind().width) == 600 }
        XCTAssertEqual(table.tableColumns.first { DetailsColumns.columnID($0.identifier) == .size }?.width, 400)
    }
}
