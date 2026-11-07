import XCTest
@testable import Core
@testable import MacxFS

final class IndexStatusTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(MdutilIndexStatus.parse("/:\n\tIndexing enabled. \n"), .enabled)
        XCTAssertEqual(MdutilIndexStatus.parse("/Volumes/X:\n\tIndexing disabled.\n"), .disabled)
        XCTAssertEqual(MdutilIndexStatus.parse("/Volumes/X:\n\tIndexing and searching disabled.\n"), .disabled)
        XCTAssertEqual(MdutilIndexStatus.parse("/Volumes/X:\n\tError: unable to perform operation.  (-400)\n"), .unknown)
        XCTAssertEqual(MdutilIndexStatus.parse(""), .unknown)
        // macOS 26 reports the sealed system volume and its Data volume this way; the index is still searchable.
        XCTAssertEqual(MdutilIndexStatus.parse("/System/Volumes/Data:\n\tIndex is read-only.\n"), .enabled)
        XCTAssertEqual(MdutilIndexStatus.parse("/x:\n\tError: unknown indexing state.\n"), .unknown)
    }

    func testFixed() async {
        let fixed = FixedIndexStatus(.disabled)
        let status = await fixed.status(ofVolumeAt: URL(filePath: "/"))
        XCTAssertEqual(status, .disabled)
    }

    /// Read-only: `mdutil -s /` only reports status.
    func testLiveStatusOfRootIsCached() async {
        let provider = MdutilIndexStatus(lanes: LanePool())
        let first = await provider.status(ofVolumeAt: URL(filePath: "/"))
        let start = ContinuousClock.now
        let second = await provider.status(ofVolumeAt: URL(filePath: "/"))
        XCTAssertEqual(first, second)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(20), "second answer comes from the cache")
    }
}
