import Foundation
import MacxFixtures
import XCTest
@testable import Core

final class DirtyExitMarkerTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private func marker() -> DirtyExitMarker { DirtyExitMarker(fileURL: sandbox.url("state/session.marker")) }
    private let sample = SessionMarker(pid: 42, version: "0.4.0", build: "812", launchedAt: Date(timeIntervalSince1970: 1_800_000_000))

    func testFirstLaunchIsClean() { XCTAssertEqual(marker().previous(), .clean) }

    func testBeginThenNoEndIsDirty() throws {
        try marker().begin(sample)
        XCTAssertEqual(marker().previous(), .dirty(sample))
    }

    func testEndMakesItClean() throws {
        try marker().begin(sample)
        marker().end()
        XCTAssertEqual(marker().previous(), .clean)
        marker().end()   // idempotent
    }

    func testCorruptMarkerIsDirtyUnknown() throws {
        _ = try sandbox.createDirectory("state")
        _ = try sandbox.createFile("state/session.marker", contents: Data("{nope".utf8))
        XCTAssertEqual(marker().previous(), .dirtyUnknown)
    }

    func testStatePaths() {
        let paths = StatePaths(root: sandbox.root)
        XCTAssertEqual(paths.sessionMarker.lastPathComponent, "session.marker")
        XCTAssertEqual(paths.diagnosticReports(sandboxed: true), sandbox.root.appending(path: "DiagnosticReports", directoryHint: .isDirectory))
        XCTAssertTrue(paths.diagnosticReports(sandboxed: false).path.hasSuffix("Library/Logs/DiagnosticReports"))
    }
}
