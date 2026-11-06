@testable import Core
import CoreServices
import XCTest

/// Pure FSEvents classification (§4.3 Watcher): parent filter, 256 cap, rescan and root flags.
final class EventClassifierTests: XCTestCase {
    private let folder = "/Users/u/Docs"
    private let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
    private let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
    private let removed = UInt32(kFSEventStreamEventFlagItemRemoved)

    private func e(_ path: String, _ flags: UInt32, _ id: UInt64 = 1) -> RawFSEvent { RawFSEvent(path: path, flags: flags, id: id) }

    func testDirectChildrenBecomeCoalescedItems() {
        let events = [e("/Users/u/Docs/a.txt", created), e("/Users/u/Docs/b.txt", created),
                      e("/Users/u/Docs/a.txt", UInt32(kFSEventStreamEventFlagItemModified))]
        XCTAssertEqual(EventClassifier.classify(events, folder: folder), .items(["a.txt", "b.txt"]))
    }

    func testEventsOutsideTheFolderAreDropped() {
        let events = [e("/Users/u/Docs/sub/deeper/deep.txt", created), e("/Users/u/Other/x", created), e("/Users/u/DocsX/y", created),
                      e("/Users/u", created)]
        XCTAssertNil(EventClassifier.classify(events, folder: folder))
        XCTAssertNil(EventClassifier.classify([], folder: folder))
    }

    /// An entry created, removed or renamed inside a child folder changes that child's own mtime, which FSEvents
    /// reports only as the grandchild's path: the child's row is re-read (QA round 1). Deeper paths change a
    /// grandchild's mtime, not the child's, and are dropped.
    func testGrandchildEventsReReadTheChildRow() {
        let events = [e("/Users/u/Docs/sub/new.txt", created), e("/Users/u/Docs/sub/old.txt", removed),
                      e("/Users/u/Docs/a.txt", created), e("/Users/u/Docs/other/x", renamed), e("/Users/u/Docs/sub", created)]
        XCTAssertEqual(EventClassifier.classify(events, folder: folder), .items(["sub", "a.txt", "other"]))
        XCTAssertNil(EventClassifier.classify([e("/Users/u/Docs/sub/deeper/deep.txt", created)], folder: folder))
        XCTAssertEqual(EventClassifier.classify([e("/private/var/t/f/sub/n", created)], folder: "/var/t/f"), .items(["sub"]))
    }

    func testFolderOwnMetadataEventIsIgnored() {
        let meta = UInt32(kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir)
        XCTAssertNil(EventClassifier.classify([e("/Users/u/Docs", meta)], folder: folder))
        XCTAssertNil(EventClassifier.classify([e("/Users/u/Docs", UInt32(kFSEventStreamEventFlagHistoryDone))], folder: folder))
    }

    func testRenamePairsAreBothChecked() {
        let events = [e("/Users/u/Docs/old", renamed), e("/Users/u/Docs/new", renamed)]
        XCTAssertEqual(EventClassifier.classify(events, folder: folder), .items(["old", "new"]))
    }

    func testMoreThanTheLimitIsAFullRescan() {
        XCTAssertEqual(EventClassifier.incrementalLimit, 256)
        let atLimit = (0..<256).map { e("/Users/u/Docs/f\($0)", created) }
        guard case .items(let names) = EventClassifier.classify(atLimit, folder: folder) else { return XCTFail("items") }
        XCTAssertEqual(names.count, 256)
        let over = atLimit + [e("/Users/u/Docs/f256", created)]
        XCTAssertEqual(EventClassifier.classify(over, folder: folder), .fullRescan)
        let repeats = atLimit + atLimit
        XCTAssertNotEqual(EventClassifier.classify(repeats, folder: folder), .fullRescan, "the cap counts distinct names")
    }

    func testMustScanSubDirsOnFolderOrAncestorRescans() {
        let must = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        XCTAssertEqual(EventClassifier.classify([e("/Users/u/Docs", must)], folder: folder), .fullRescan)
        XCTAssertEqual(EventClassifier.classify([e("/Users/u/", must)], folder: folder), .fullRescan)
        XCTAssertEqual(EventClassifier.classify([e("/", must)], folder: folder), .fullRescan)
        XCTAssertEqual(EventClassifier.classify([e("/Users/u/Docs/sub", must)], folder: folder), .items(["sub"]),
                       "a child's own contents changed: only its row is re-read")
        XCTAssertNil(EventClassifier.classify([e("/Users/u/Other", must)], folder: folder))
    }

    func testDroppedAndWrappedFlagsRescanWhateverThePath() {
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped] {
            XCTAssertEqual(EventClassifier.classify([e("/elsewhere", UInt32(flag))], folder: folder), .fullRescan)
        }
    }

    func testRootChangedAndFolderRemovedOrRenamed() {
        XCTAssertEqual(EventClassifier.classify([e("/Users/u/Docs", UInt32(kFSEventStreamEventFlagRootChanged))], folder: folder), .rootChanged)
        XCTAssertEqual(EventClassifier.classify([e("/Users/u/Docs/a", created), e("/Users/u/Docs", removed)], folder: folder), .rootChanged)
        XCTAssertEqual(EventClassifier.classify([e("/Users/u/Docs/", renamed)], folder: folder), .rootChanged)
        let must = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        XCTAssertEqual(EventClassifier.classify([e("/Users/u/Docs", must), e("/Users/u/Docs", removed)], folder: folder), .rootChanged,
                       "a gone root wins over a rescan")
    }

    func testPrivateFirmlinkSpellingsMatch() {
        let events = [e("/private/var/folders/x/T/macx-tests-1/f/a.txt", created)]
        XCTAssertEqual(EventClassifier.classify(events, folder: "/var/folders/x/T/macx-tests-1/f/"), .items(["a.txt"]))
        XCTAssertEqual(EventClassifier.classify([e("/var/tmp/q/b", created)], folder: "/private/var/tmp/q"), .items(["b"]))
    }
}
