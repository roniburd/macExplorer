import XCTest
@testable import UI

final class ScenarioDriverLogicTests: XCTestCase {
    func testPickKeyWindowPrefersFrontmostNonSheetWindow() {
        let candidates = [
            KeyCandidate(isVisible: true, isSheet: true, canBecomeKey: true, isPanel: false),    // conflict sheet
            KeyCandidate(isVisible: false, isSheet: false, canBecomeKey: true, isPanel: false),  // closed window
            KeyCandidate(isVisible: true, isSheet: false, canBecomeKey: true, isPanel: true),    // Operations panel
            KeyCandidate(isVisible: true, isSheet: false, canBecomeKey: true, isPanel: false),   // Properties window
            KeyCandidate(isVisible: true, isSheet: false, canBecomeKey: true, isPanel: false),   // browser window
        ]
        XCTAssertEqual(ScenarioDriver.pickKeyWindow(candidates), 3)
        XCTAssertNil(ScenarioDriver.pickKeyWindow([candidates[0]]))
    }

    func testRelativePathAcceptsBothTmpSpellings() {
        let roots = ["/var/folders/x/T/macx-scenario-1/a/macx-scenario-root", "/private/var/folders/x/T/macx-scenario-1/a/macx-scenario-root"]
        XCTAssertEqual(ScenarioDriver.relativePath("/private/var/folders/x/T/macx-scenario-1/a/macx-scenario-root", roots: roots), "")
        XCTAssertEqual(ScenarioDriver.relativePath("/var/folders/x/T/macx-scenario-1/a/macx-scenario-root/sub/deep", roots: roots), "sub/deep")
        XCTAssertNil(ScenarioDriver.relativePath("/var/folders/x/T/macx-scenario-1/a/macx-scenario-rootless", roots: roots))
        XCTAssertNil(ScenarioDriver.relativePath("/Library", roots: roots))
    }
}
