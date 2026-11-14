import MacxPluginKit
import XCTest

final class APIVersionTests: XCTestCase {
    func testParseAndDescribe() {
        XCTAssertEqual(APIVersion(string: "1.0"), APIVersion(major: 1, minor: 0))
        XCTAssertEqual(APIVersion(string: " 2.13 "), APIVersion(major: 2, minor: 13))
        XCTAssertEqual(APIVersion(string: "3"), APIVersion(major: 3, minor: 0))
        for bad in ["", "x", "1.x", "-1.0", "1.0.0", "1."] { XCTAssertNil(APIVersion(string: bad), bad) }
        XCTAssertEqual(APIVersion(major: 1, minor: 2).description, "1.2")
    }

    func testCompatibilityIsMajorOnly() {
        let app = APIVersion(major: 1, minor: 0)
        XCTAssertTrue(APIVersion(major: 1, minor: 4).isCompatible(with: app))
        XCTAssertFalse(APIVersion(major: 2, minor: 0).isCompatible(with: app))
        XCTAssertFalse(APIVersion(major: 0, minor: 9).isCompatible(with: app))
    }

    func testCurrentVersion() {
        XCTAssertEqual(MacxPluginAPI.version, APIVersion(major: 1, minor: 0))
        XCTAssertEqual(MacxPluginAPI.infoPlistKey, "MacxPluginAPIVersion")
    }
}
