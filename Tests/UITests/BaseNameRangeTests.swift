import XCTest
@testable import UI

final class BaseNameRangeTests: XCTestCase {
    private func selected(_ name: String, folder: Bool = false) -> String {
        String(name[BaseNameRange.range(of: name, isFolder: folder)])
    }

    func testFileSelectsBaseName() {
        XCTAssertEqual(selected("report.pdf"), "report")
        XCTAssertEqual(selected("Safari.app"), "Safari", "packages rename like files (§5.7)")
    }

    func testMultipleDotsSelectUpToLastDot() {
        XCTAssertEqual(selected("archive.tar.gz"), "archive.tar")
    }

    func testFoldersSelectWholeName() {
        XCTAssertEqual(selected("My.Folder", folder: true), "My.Folder")
    }

    func testDotFilesAndTrailingDotSelectWholeName() {
        XCTAssertEqual(selected(".env"), ".env")
        XCTAssertEqual(selected("name."), "name.")
        XCTAssertEqual(selected("README"), "README")
    }

    func testLeadingDotWithExtension() {
        XCTAssertEqual(selected(".config.json"), ".config")
    }

    func testNSRangeCountsUTF16ForEmojiAndCombiningMarks() {
        let name = "👨‍👩‍👧e\u{301}.txt"
        let range = BaseNameRange.nsRange(of: name, isFolder: false)
        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, "👨‍👩‍👧e\u{301}".utf16.count)
        XCTAssertEqual((name as NSString).substring(with: NSRange(location: range.length, length: 1)), ".")
        let long = String(repeating: "é", count: 120) + ".txt"   // 244 UTF-8 bytes
        XCTAssertEqual(BaseNameRange.nsRange(of: long, isFolder: false).length, 120)
    }
}
