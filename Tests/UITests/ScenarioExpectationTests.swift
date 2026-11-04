import XCTest
import Core
@testable import UI

final class ScenarioExpectationTests: XCTestCase {
    func testMatchingSnapshotHasNoMismatches() {
        var s = ProbeSnapshot()
        s.rows = ["sub", "b.txt"]
        s.selection = ["b.txt"]
        s.folder = "sub"
        s.emptyState = nil
        s.fileSizes = ["sub/b.txt": 3]
        let e = ScenarioFile.Expectation(rows: ["sub", "b.txt"], rowsContain: ["b.txt"], selection: ["b.txt"], folder: "sub",
                                         filesExist: ["sub/b.txt"], filesAbsent: ["a.txt"], rowCount: 2, fileSizes: ["sub/b.txt": 3])
        XCTAssertEqual(ExpectationMatcher.mismatches(e, s), [])
    }

    func testEveryMismatchIsReported() {
        var s = ProbeSnapshot()
        s.rows = ["a.txt"]
        s.folder = nil
        s.emptyState = "This folder is empty"
        let e = ScenarioFile.Expectation(rows: ["b.txt"], folder: "", emptyState: "No items match", filesExist: ["x"], editingAddress: true)
        let m = ExpectationMatcher.mismatches(e, s)
        XCTAssertEqual(m.count, 5, m.joined(separator: "\n"))
        XCTAssertTrue(m.contains { $0.contains("outside root") })
    }

    func testEmptyStateAndBannerAreSubstringMatches() {
        var s = ProbeSnapshot()
        s.emptyState = "You don't have permission to view 'locked'"
        s.banner = "'sub' was moved or deleted"
        XCTAssertEqual(ExpectationMatcher.mismatches(ScenarioFile.Expectation(emptyState: "permission", banner: "moved or deleted"), s), [])
    }

    func testStateAndFocusStrings() {
        XCTAssertEqual(ScenarioStrings.state(.complete), "complete")
        XCTAssertEqual(ScenarioStrings.state(.error(.permissionPOSIX)), "error.permissionPOSIX")
        XCTAssertEqual(ScenarioStrings.state(.error(.other(5))), "error.other.5")
        XCTAssertEqual(ScenarioStrings.focus(.sidebarFavorites), "sidebarFavorites")
    }

    func testRequestedPathsCoverAllFileExpectations() {
        let e = ScenarioFile.Expectation(filesExist: ["a"], filesAbsent: ["b"], fileSizes: ["c": 1])
        XCTAssertEqual(Set(ExpectationMatcher.requestedPaths(e)), ["a", "b", "c"])
    }
}
