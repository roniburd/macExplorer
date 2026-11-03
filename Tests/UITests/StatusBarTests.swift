import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class StatusBarTests: XCTestCase {
    private func label(_ id: String, in bar: StatusBarView) throws -> NSTextField {
        try XCTUnwrap(Self.find(id, in: bar) as? NSTextField, id)
    }

    static func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews { if let match = find(identifier, in: subview) { return match } }
        return nil
    }

    private static let none = SelectionSummary(count: 0, files: 0, folders: 0, bytes: 0)

    func testItemCount() throws {
        let bar = StatusBarView()
        bar.update(itemCount: 0, selection: Self.none, available: nil)
        XCTAssertEqual(try label(AXID.statusCount, in: bar).stringValue, "0 items")
        bar.update(itemCount: 1, selection: Self.none, available: nil)
        XCTAssertEqual(try label(AXID.statusCount, in: bar).stringValue, "1 item")
        bar.update(itemCount: 12345, selection: Self.none, available: nil)
        XCTAssertEqual(try label(AXID.statusCount, in: bar).stringValue, "\(12345.formatted()) items")
    }

    func testSelectionSummary() throws {
        let bar = StatusBarView()
        bar.update(itemCount: 3, selection: Self.none, available: nil)
        let selection = try label(AXID.statusSelection, in: bar)
        XCTAssertEqual(selection.stringValue, "")
        bar.update(itemCount: 3, selection: SelectionSummary(count: 2, files: 2, folders: 0, bytes: 30), available: nil)
        XCTAssertEqual(selection.stringValue, "2 selected (30 bytes)")
        bar.update(itemCount: 3, selection: SelectionSummary(count: 3, files: 2, folders: 1, bytes: 1_500_000), available: nil)
        XCTAssertEqual(selection.stringValue, "3 selected (\(ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file)))", "folder sizes are not included in Phase 1")
        bar.update(itemCount: 3, selection: SelectionSummary(count: 1, files: 0, folders: 1, bytes: 0), available: nil)
        XCTAssertEqual(selection.stringValue, "1 selected", "only folders: no size")
        XCTAssertEqual(bar.selectionText, selection.stringValue)
    }

    func testAvailableSpace() throws {
        let bar = StatusBarView()
        bar.update(itemCount: 0, selection: Self.none, available: 2_500_000_000)
        let free = try label(AXID.statusFree, in: bar)
        XCTAssertEqual(free.stringValue, "\(ByteCountFormatter.string(fromByteCount: 2_500_000_000, countStyle: .file)) available")
        bar.update(itemCount: 0, selection: Self.none, available: nil)
        XCTAssertEqual(free.stringValue, "", "unknown: nothing shown")
    }

    func testOperationsSlotSitsAtTheTrailingEnd() {
        let bar = StatusBarView()
        XCTAssertTrue(bar.operationsSlot.isDescendant(of: bar))
        XCTAssertTrue(bar.operationsSlot.subviews.isEmpty, "P1-38 puts the operations capsule here")
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 22)
        bar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(bar.operationsSlot.frame.minX, 300)
    }

    func testPlaceholderStatusShowsCountSelectionAndFreeSpace() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let controller = try await h.openWindow()
        let content = try XCTUnwrap(controller.contentPane as? PlaceholderContentViewController)
        let count = try label(AXID.statusCount, in: content.statusBar)
        try await h.waitUntil("count") { count.stringValue == "2 items" }
        content.session.folder.select(.set(IndexSet([0, 1]), cursor: 1))
        try await h.waitUntil("selection") { content.statusBar.selectionText.hasPrefix("2 selected") }
        let free = try label(AXID.statusFree, in: content.statusBar)
        try await h.waitUntil("free space", timeout: .seconds(10)) { free.stringValue.hasSuffix("available") }
    }
}
