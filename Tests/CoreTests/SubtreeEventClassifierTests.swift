import CoreServices
import XCTest
@testable import Core

final class SubtreeEventClassifierTests: XCTestCase {
    func ev(_ path: String, _ flags: Int = 0) -> RawFSEvent { RawFSEvent(path: path, flags: UInt32(flags), id: 1) }

    func testChildMapping() {
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/r/A/x"), ev("/r/A/B/"), ev("/r/C")], folder: "/r"), .children(["A", "C"]))
        XCTAssertNil(SubtreeEventClassifier.classify([ev("/r"), ev("/r/")], folder: "/r"), "the folder's own listing changed: no subfolder affected")
        XCTAssertNil(SubtreeEventClassifier.classify([ev("/rr/x"), ev("/other/A")], folder: "/r"), "prefix boundary")
    }

    func testRescanFlags() {
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/r", kFSEventStreamEventFlagMustScanSubDirs)], folder: "/r"), .all)
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/", kFSEventStreamEventFlagUserDropped)], folder: "/r"), .all)
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/r", kFSEventStreamEventFlagRootChanged)], folder: "/r"), .all)
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/r/A/deep", kFSEventStreamEventFlagMustScanSubDirs)], folder: "/r"), .children(["A"]))
    }

    /// FSEvents reports /private/var/… for a folder opened as /var/… (and the reverse); both spellings match.
    func testPrivateVarSpellingsMatch() {
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/private/var/folders/T/macx/A/x")], folder: "/var/folders/T/macx"),
                       .children(["A"]))
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/var/folders/T/macx/B")], folder: "/private/var/folders/T/macx/"),
                       .children(["B"]))
    }

    func testHistoryDoneIgnoredAndRootFolderWorks() {
        XCTAssertNil(SubtreeEventClassifier.classify([ev("/r/A", kFSEventStreamEventFlagHistoryDone)], folder: "/r"))
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/A/x"), ev("/B")], folder: "/"), .children(["A", "B"]))
    }
}
