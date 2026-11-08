import XCTest
@testable import Core
@testable import MacxFS
import Synchronization

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

    /// Read-only: `mdutil -s /` only reports status. A smoke test of the real command, with no time budget.
    func testLiveStatusOfRootIsCached() async {
        let provider = MdutilIndexStatus(lanes: LanePool())
        let first = await provider.status(ofVolumeAt: URL(filePath: "/"))
        let second = await provider.status(ofVolumeAt: URL(filePath: "/"))
        XCTAssertEqual(first, second)
    }

    /// The cache is proven by counting command runs, not by how fast the second answer comes.
    func testSecondStatusComesFromTheCache() async {
        let runs = RunLog()
        let provider = MdutilIndexStatus(lanes: LanePool()) { path, _, _ in
            runs.record(path)
            return .disabled
        }
        let first = await provider.status(ofVolumeAt: URL(filePath: "/Volumes/X"))
        let second = await provider.status(ofVolumeAt: URL(filePath: "/Volumes/X/"))
        XCTAssertEqual(first, .disabled)
        XCTAssertEqual(second, .disabled)
        XCTAssertEqual(runs.paths, ["/Volumes/X"], "second answer comes from the cache")
        let expired = MdutilIndexStatus(lanes: LanePool(), cacheLifetime: .zero) { path, _, _ in
            runs.record(path)
            return .enabled
        }
        _ = await expired.status(ofVolumeAt: URL(filePath: "/Volumes/Y"))
        let again = await expired.status(ofVolumeAt: URL(filePath: "/Volumes/Y"))
        XCTAssertEqual(again, .enabled)
        XCTAssertEqual(runs.paths, ["/Volumes/X", "/Volumes/Y", "/Volumes/Y"], "an expired entry runs the command again")
    }
}

/// The mount points a stand-in status command was run for, from any lane.
private final class RunLog: Sendable {
    private let log = Mutex<[String]>([])
    func record(_ path: String) { log.withLock { $0.append(path) } }
    var paths: [String] { log.withLock { $0 } }
}
