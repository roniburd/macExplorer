import XCTest
@testable import UI
import Core

@MainActor
final class FolderSizeTextTests: XCTestCase {
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
}
