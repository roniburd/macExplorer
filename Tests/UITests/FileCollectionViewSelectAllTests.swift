import AppKit
import XCTest
@testable import UI

/// P1-41 (icons-view scenario): ⌘A in Icons must validate where selectAll: runs (the content controller), not
/// against NSCollectionView's own selection settings (the grid is isSelectable = false; the model owns selection).
@MainActor
final class FileCollectionViewSelectAllTests: XCTestCase {
    private final class Pane: NSResponder, NSMenuItemValidation {
        var enabled = true
        var performed = 0
        override func selectAll(_ sender: Any?) { performed += 1 }
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled }
    }

    func testSelectAllValidatesAndRunsThroughTheResponderThatPerformsIt() {
        let grid = FileCollectionView()
        grid.isSelectable = false
        let pane = Pane()
        grid.nextResponder = pane
        let item = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        XCTAssertTrue(grid.validateUserInterfaceItem(item))
        pane.enabled = false
        XCTAssertFalse(grid.validateUserInterfaceItem(item))
        grid.selectAll(nil)
        XCTAssertEqual(pane.performed, 1)
        let other = NSMenuItem(title: "Other", action: #selector(NSResponder.cancelOperation(_:)), keyEquivalent: "")
        _ = grid.validateUserInterfaceItem(other)    // other actions use NSCollectionView's own validation
    }
}
