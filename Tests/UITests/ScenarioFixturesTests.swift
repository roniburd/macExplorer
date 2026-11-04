import Darwin
import XCTest
import MacxFixtures
@testable import UI

final class ScenarioFixturesTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(prefix: "macx-tests")
        addTeardownBlock { [sandbox] in
            // a mode-000 fixture folder must not block teardown
            if let s = sandbox { chmod(s.url("macx-scenario-root/closed").path, 0o755); s.destroy() }
        }
    }

    private func root() throws -> URL { try sandbox.createDirectory("macx-scenario-root").resolvingSymlinksInPath() }

    func testCreatesFilesDirsHiddenSizesAndModes() throws {
        let r = try root()
        let f = ScenarioFile.Fixture(files: ["a.txt", "dest/b.txt", "closed/c.txt"], dirs: ["empty", "closed"],
                                     hidden: ["flagged.txt"], sizes: ["dest/b.txt": 10], modes: ["closed": "000"])
        try ScenarioFixtures.create(f, in: r)
        var st = stat()
        XCTAssertEqual(lstat(r.appending(path: "dest/b.txt").path, &st), 0)
        XCTAssertEqual(st.st_size, 10)
        XCTAssertEqual(lstat(r.appending(path: "flagged.txt").path, &st), 0)
        XCTAssertNotEqual(st.st_flags & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(lstat(r.appending(path: "closed").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0)
        XCTAssertEqual(ScenarioFixtures.topLevelVisibleNames(f), ["a.txt", "dest", "closed", "empty"])
    }

    func testRefusesRootsThatAreNotEmptyScenarioSandboxes() throws {
        let other = try sandbox.createDirectory("other").resolvingSymlinksInPath()
        XCTAssertThrowsError(try ScenarioFixtures.create(.init(files: ["a"], dirs: []), in: other)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .rootNotScenarioSandbox(other.path))
        }
        let r = try root()
        try sandbox.createFile("macx-scenario-root/existing.txt")
        XCTAssertThrowsError(try ScenarioFixtures.create(.init(files: ["a"], dirs: []), in: r)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .rootNotEmpty(r.path))
        }
    }

    func testFixturesRefuseEscapingPaths() throws {
        let r = try root()
        XCTAssertThrowsError(try ScenarioFixtures.create(.init(files: ["../escape.txt"], dirs: []), in: r)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .unsafePath("../escape.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.root.appending(path: "escape.txt").path))
    }
}
