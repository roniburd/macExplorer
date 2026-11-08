// Tests/UITests/FileGridLayoutTests.swift
import XCTest
@testable import UI
import Core

@MainActor
final class FileGridLayoutTests: XCTestCase {
    private func layout(_ size: IconSize = .medium, items: Int, width: CGFloat = 600) -> FileGridLayout {
        let layout = FileGridLayout()
        layout.iconSize = size
        layout.itemCount = items
        layout.fallbackWidth = width
        return layout
    }

    func testColumnsPerIconSize() {
        // cell widths 80 / 112 / 176, spacing 8, insets 10+10: usable = 600 - 20 + 8 = 588
        XCTAssertEqual(layout(.small, items: 10).columns, 6)    // 588 / 88
        XCTAssertEqual(layout(.medium, items: 10).columns, 4)   // 588 / 120
        XCTAssertEqual(layout(.large, items: 10).columns, 3)    // 588 / 184
    }

    func testColumnsNeverZeroForNarrowWidths() {
        for width in [0, 1, 50, 100] as [CGFloat] { XCTAssertEqual(layout(.large, items: 5, width: width).columns, 1) }
    }

    func testFrameForItemIsArithmetic() {
        let grid = layout(items: 10)
        // medium: item 112 x 110 (6 + 64 + 4 + 30 + 6), pitch 120 x 118
        XCTAssertEqual(grid.frame(forItem: 0), NSRect(x: 10, y: 10, width: 112, height: 110))
        XCTAssertEqual(grid.frame(forItem: 5), NSRect(x: 130, y: 128, width: 112, height: 110))
    }

    func testRowColumnRoundTrip() {
        let grid = layout(items: 1_000)
        for index in 0..<1_000 {
            let (row, column) = grid.rowColumn(of: index)
            XCTAssertEqual(grid.index(atRow: row, column: column), index)
        }
        XCTAssertNil(grid.index(atRow: 250, column: 0), "past the end")
        XCTAssertNil(grid.index(atRow: 0, column: 4), "past the last column")
        XCTAssertNil(grid.index(atRow: -1, column: 0))
    }

    func testIndexesInRectAreBoundedByVisibleRows() {
        let grid = layout(items: 100_000)
        let visible = grid.indexes(in: NSRect(x: 0, y: 5_000, width: 600, height: 400))
        XCTAssertLessThanOrEqual(visible.count, (Int(400 / 118) + 2) * grid.columns)
        XCTAssertTrue(visible.contains(grid.itemIndex(at: NSPoint(x: 20, y: 5_100)) ?? -1))
        XCTAssertEqual(grid.indexes(in: NSRect(x: 0, y: 0, width: 600, height: 100)), 0..<4)
        XCTAssertEqual(layout(items: 0).indexes(in: NSRect(x: 0, y: 0, width: 600, height: 400)), 0..<0)
    }

    /// What keeps a 100k grid fast, checked structurally instead of with wall time (a debug build on a shared CI
    /// runner has no reliable timing): frames are closed-form (no per-item state), and a deep rect yields only the
    /// items of the rows it crosses.
    func testLargeGridIsClosedFormAndBoundedByTheRect() {
        let grid = layout(items: 100_000)
        let first = grid.frame(forItem: 0), second = grid.frame(forItem: 1), below = grid.frame(forItem: grid.columns)
        for index in [0, 1, grid.columns - 1, grid.columns, 54_321, 99_999] {
            let (row, column) = grid.rowColumn(of: index)
            let frame = grid.frame(forItem: index)
            XCTAssertEqual(frame.minX, first.minX + CGFloat(column) * (second.minX - first.minX), accuracy: 0.001, "item \(index)")
            XCTAssertEqual(frame.minY, first.minY + CGFloat(row) * (below.minY - first.minY), accuracy: 0.001, "item \(index)")
        }
        let rect = NSRect(x: 0, y: 1_000_000, width: 600, height: 800)
        let attributes = grid.layoutAttributesForElements(in: rect)
        XCTAssertFalse(attributes.isEmpty)
        XCTAssertLessThanOrEqual(attributes.count, 9 * grid.columns)
        let items = attributes.compactMap { $0.indexPath?.item }
        XCTAssertEqual(items.count, attributes.count)
        XCTAssertTrue(items.allSatisfy { grid.indexes(in: rect).contains($0) && grid.frame(forItem: $0).intersects(rect) })
    }

    func testNeighborNavigation() {
        let grid = layout(items: 10)   // 4 columns: rows [0-3] [4-7] [8-9]
        XCTAssertEqual(grid.neighbor(of: 5, .up), 1)
        XCTAssertNil(grid.neighbor(of: 2, .up))
        XCTAssertEqual(grid.neighbor(of: 1, .down), 5)
        XCTAssertEqual(grid.neighbor(of: 6, .down), 9, "no item below in the partial last row → its last item")
        XCTAssertNil(grid.neighbor(of: 9, .down))
        XCTAssertEqual(grid.neighbor(of: 4, .left), 3, "left wraps to the previous row like Explorer")
        XCTAssertNil(grid.neighbor(of: 0, .left))
        XCTAssertEqual(grid.neighbor(of: 3, .right), 4)
        XCTAssertNil(grid.neighbor(of: 9, .right))
    }

    func testContentSizeAndHitTesting() {
        let grid = layout(items: 10)
        XCTAssertEqual(grid.collectionViewContentSize.height, 10 + 3 * 118 - 8 + 10)
        XCTAssertEqual(grid.itemIndex(at: NSPoint(x: 135, y: 130)), 5)
        XCTAssertNil(grid.itemIndex(at: NSPoint(x: 125, y: 130)), "the spacing between cells is empty space")
        XCTAssertNil(grid.itemIndex(at: NSPoint(x: 135, y: 400)), "below the last row")
    }
}
