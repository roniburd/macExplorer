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

    /// QA round 2: a drop destination must resolve inside --root too, not only its sources ("crumb:<n>" above the
    /// root resolved to /var, $TMPDIR, …; a sidebar favorite can point anywhere).
    @MainActor
    func testDropDestinationsOutsideTheRootAreRejected() throws {
        let root = "/private/var/folders/x/T/macx-scenario-1/a/macx-scenario-root"
        let roots = [String(root.dropFirst("/private".count)), root]
        let folder = URL(filePath: root + "/sub", directoryHint: .isDirectory)
        let crumb0 = DropDestinationResolver.crumbURL(0, of: folder, volumeRoot: nil)
        XCTAssertThrowsError(try ScenarioDriver.confinedDropDestination(crumb0, onto: "crumb:0", roots: roots), "/")
        let crumb5 = DropDestinationResolver.crumbURL(5, of: folder, volumeRoot: nil)
        XCTAssertThrowsError(try ScenarioDriver.confinedDropDestination(crumb5, onto: "crumb:5", roots: roots), "$TMPDIR")
        let favorite = URL(filePath: "/Volumes/Elsewhere/Documents", directoryHint: .isDirectory)
        XCTAssertThrowsError(try ScenarioDriver.confinedDropDestination(favorite, onto: "sidebar:Documents", roots: roots))
        XCTAssertThrowsError(try ScenarioDriver.confinedDropDestination(nil, onto: "crumb:99", roots: roots), "unresolvable")
        let atRoot = DropDestinationResolver.crumbURL(8, of: folder, volumeRoot: nil)
        XCTAssertEqual(try ScenarioDriver.confinedDropDestination(atRoot, onto: "crumb:8", roots: roots).path, root)
        XCTAssertEqual(try ScenarioDriver.confinedDropDestination(folder, onto: "", roots: roots).lastPathComponent, "sub")
    }
}
