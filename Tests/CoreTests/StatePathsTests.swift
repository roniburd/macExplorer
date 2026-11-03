import XCTest
@testable import Core

final class StatePathsTests: XCTestCase {
    func testFilesLiveDirectlyInRoot() {
        let root = URL(filePath: "/tmp/macx-tests-X/state", directoryHint: .isDirectory)
        let paths = StatePaths(root: root)
        XCTAssertEqual(paths.root, root)
        XCTAssertEqual(paths.journal, root.appending(path: "journal.json", directoryHint: .notDirectory))
        XCTAssertEqual(paths.settingsFile, root.appending(path: "settings.json", directoryHint: .notDirectory))
        XCTAssertEqual(paths.journal.path(percentEncoded: false), "/tmp/macx-tests-X/state/journal.json")
        XCTAssertEqual(paths.settingsFile.path(percentEncoded: false), "/tmp/macx-tests-X/state/settings.json")
    }

    func testRootIsMutableAndDerivedPathsFollow() {
        var paths = StatePaths(root: URL(filePath: "/tmp/a", directoryHint: .isDirectory))
        paths.root = URL(filePath: "/tmp/b", directoryHint: .isDirectory)
        XCTAssertEqual(paths.journal.path(percentEncoded: false), "/tmp/b/journal.json")
    }

    func testStandardIsApplicationSupportMacExplorer() throws {
        // Pure path computation: standard() must not create anything, and tests never write there.
        let paths = StatePaths.standard()
        XCTAssertEqual(paths.root.lastPathComponent, "macExplorer")
        XCTAssertEqual(paths.root.deletingLastPathComponent().lastPathComponent, "Application Support")
        XCTAssertTrue(paths.root.hasDirectoryPath)
        let appSupport = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertEqual(paths.root.standardizedFileURL.path(percentEncoded: false),
                       appSupport.appending(path: "macExplorer", directoryHint: .isDirectory).standardizedFileURL.path(percentEncoded: false))
        XCTAssertEqual(StatePaths.standard(), paths, "deterministic")
    }

    func testEquatable() {
        let a = StatePaths(root: URL(filePath: "/tmp/a", directoryHint: .isDirectory))
        XCTAssertEqual(a, StatePaths(root: URL(filePath: "/tmp/a", directoryHint: .isDirectory)))
        XCTAssertNotEqual(a, StatePaths(root: URL(filePath: "/tmp/b", directoryHint: .isDirectory)))
    }
}
