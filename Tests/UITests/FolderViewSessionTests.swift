import XCTest
@testable import UI
import Core
import MacxFS

/// Per-folder views and display names in a window session (design 2026-11-05).
@MainActor
final class FolderViewSessionTests: XCTestCase {
    private func makeSession(_ h: ShellHarness, _ relative: String = "") async throws -> BrowserSession {
        let session = BrowserSession(environment: h.environment, initialURL: h.url(relative))
        addTeardownBlock { @MainActor in session.close() }
        try await h.waitUntil("initial folder complete") { session.folder.state == .complete }
        return session
    }

    private func go(_ session: BrowserSession, _ h: ShellHarness, _ relative: String) async throws {
        session.navigate(to: h.url(relative))
        try await h.waitUntil("\(relative) complete") { session.folder.state == .complete }
    }

    func testViewChangesStayWithTheirFolder() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("a"); try h.dir("b")
        let session = try await makeSession(h, "a")
        session.viewMode = .icons
        session.view.change { $0.iconSize = .large }
        try await go(session, h, "b")
        XCTAssertEqual(session.viewMode, .details)
        XCTAssertEqual(session.view.resolved.iconSize, .medium)
        try await go(session, h, "a")
        XCTAssertEqual(session.viewMode, .icons)
        XCTAssertEqual(session.view.resolved.iconSize, .large)
        // Global defaults are untouched.
        XCTAssertEqual(h.environment.settings.viewMode, .details)
        XCTAssertEqual(h.environment.settings.iconSize, .medium)
    }

    func testSortIsPerFolder() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a/x.txt"); try h.dir("b")
        let session = try await makeSession(h, "a")
        let bySize = MacxFS.SortDescriptor(field: .size, ascending: false)
        session.view.change { $0.sort = bySize }
        XCTAssertEqual(session.folder.query.sort, bySize)
        try await go(session, h, "b")
        XCTAssertEqual(session.folder.query.sort, .default)
        try await go(session, h, "a")
        XCTAssertEqual(session.folder.query.sort, bySize)
    }

    func testResetFallsBackAndUseAsDefaultChangesEveryFolder() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("a"); try h.dir("b")
        let session = try await makeSession(h, "a")
        session.view.change { $0.density = .compact }
        session.resetFolderView()
        XCTAssertEqual(session.view.resolved.density, .regular)

        session.view.change { $0.density = .comfortable }
        session.useViewAsDefault()
        XCTAssertEqual(h.environment.settings.density, .comfortable)
        try await go(session, h, "b")
        XCTAssertEqual(session.view.resolved.density, .comfortable)
    }

    func testAppBundlesShowWithoutTheirExtension() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("Apps/Tool.app/Contents/Info.plist")
        try h.file("Apps/readme.txt")
        let session = try await makeSession(h, "Apps")
        let names = (0..<session.folder.rowCount).map { session.folder.displayName(atRow: $0) }
        XCTAssertEqual(Set(names), ["Tool", "readme.txt"])
        XCTAssertTrue((0..<session.folder.rowCount).map { session.folder.name(atRow: $0) }.contains("Tool.app"))

        h.environment.settings.showAllExtensions = true
        try await h.waitUntil("extensions shown") { session.folder.query.showAllExtensions }
        let shown = (0..<session.folder.rowCount).map { session.folder.displayName(atRow: $0) }
        XCTAssertEqual(Set(shown), ["Tool.app", "readme.txt"])
    }
}
