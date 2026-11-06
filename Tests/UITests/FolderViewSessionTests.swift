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
        session.updateViewState { $0.mode = .icons }
        session.updateViewState { $0.iconSize = .large }
        try await go(session, h, "b")
        XCTAssertEqual(session.viewMode, .details)
        XCTAssertEqual(session.viewState.iconSize, .medium)
        try await go(session, h, "a")
        XCTAssertEqual(session.viewMode, .icons)
        XCTAssertEqual(session.viewState.iconSize, .large)
        // Global defaults are untouched.
        XCTAssertEqual(h.environment.settings.viewMode, .details)
        XCTAssertEqual(h.environment.settings.iconSize, .medium)
    }

    func testSortIsPerFolder() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a/x.txt"); try h.dir("b")
        let session = try await makeSession(h, "a")
        let bySize = MacxFS.SortDescriptor(field: .size, ascending: false)
        session.updateViewState { $0.sort = bySize }
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
        session.updateViewState { $0.density = .compact }
        session.resetFolderView()
        XCTAssertEqual(session.viewState.density, .regular)

        session.updateViewState { $0.density = .comfortable }
        session.useViewAsDefault()
        XCTAssertEqual(h.environment.settings.density, .comfortable)
        try await go(session, h, "b")
        XCTAssertEqual(session.viewState.density, .comfortable)
    }

    /// The merge: Phase 2's fields are per folder too, and a folder's record holds only the fields changed there,
    /// so the others keep following the defaults.
    func testRecordsHoldOnlyChangedFieldsAndFollowDefaultsForTheRest() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("a"); try h.dir("b")
        let session = try await makeSession(h, "a")
        session.updateViewState { $0.groupBy = .kind }
        let locator = session.locator
        XCTAssertEqual(h.environment.folderViews.settings(for: locator), FolderViewSettings(groupBy: .kind))
        h.environment.settings.iconSize = .small      // a new global default (Settings window, another window)
        try await h.waitUntil("defaults followed") { session.viewState.iconSize == .small }
        XCTAssertEqual(session.viewState.groupBy, .kind)
        try await go(session, h, "b")
        XCTAssertEqual(session.viewState.groupBy, .none)
        XCTAssertEqual(session.viewState.iconSize, .small)
    }

    /// Finder's view of a folder (here already read this launch) applies to the fields the folder doesn't set itself;
    /// "Reset View for This Folder" falls back to it, and Finder's column view opens as Columns.
    func testFinderViewIsTheFallbackForFieldsTheFolderDoesNotSet() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("a/sub"); try h.dir("b")
        h.environment.folderViews.setFinderView(FolderViewSettings(viewMode: .icons, iconSize: .small), for: h.url("a"))
        h.environment.folderViews.setFinderView(FolderViewSettings(viewMode: .columns), for: h.url("b"))
        let session = try await makeSession(h, "a")
        XCTAssertEqual(session.viewMode, .icons)
        XCTAssertEqual(session.viewState.iconSize, .small)
        session.updateViewState { $0.iconSize = .large }
        XCTAssertEqual(h.environment.folderViews.settings(for: session.locator), FolderViewSettings(iconSize: .large),
                       "only the changed field is the folder's own")
        session.resetFolderView()
        XCTAssertEqual(session.viewState.iconSize, .small)
        XCTAssertNil(h.environment.folderViews.settings(for: session.locator))
        session.navigate(to: h.url("b"))
        XCTAssertEqual(session.viewMode, .columns)
        XCTAssertNotNil(session.columnChain)
    }

    /// Post-merge review: "Apply to All Folders…" means every folder, so Finder's `.DS_Store` views recorded before
    /// it no longer apply ("Use as Default for All Folders" keeps them).
    func testApplyToAllOverridesFinderViewsButUseAsDefaultKeepsThem() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("a"); try h.dir("b"); try h.dir("c")
        let env = h.environment
        env.folderViews.setFinderView(FolderViewSettings(viewMode: .icons, iconSize: .small), for: h.url("a"))
        env.folderViews.setFinderView(FolderViewSettings(viewMode: .columns), for: h.url("b"))
        let session = try await makeSession(h, "c")
        session.updateViewState { $0.groupBy = .kind }
        session.useViewAsDefault()
        try await go(session, h, "a")
        XCTAssertEqual(session.viewMode, .icons, "Use as Default keeps Finder's view")
        XCTAssertEqual(session.viewState.iconSize, .small)
        XCTAssertNil(env.settings.finderViewsIgnoredBefore)

        let before = Date()
        FolderViewCoordinator(store: env.folderViews, settings: env.settings, lanes: env.lanes, volumes: env.volumes)
            .applyToAll(env.settings.defaultFolderViewState())
        session.reloadViewState()
        XCTAssertEqual(session.viewMode, .details, "Apply to All overrides Finder's view")
        XCTAssertEqual(session.viewState.iconSize, .medium)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(env.settings.finderViewsIgnoredBefore), before)
        XCTAssertNil(env.folderViews.finderView(for: h.url("b")), "the launch cache is dropped")
        try await go(session, h, "b")
        XCTAssertEqual(session.viewMode, .details)
        XCTAssertNil(session.columnChain)
        try await go(session, h, "a")
        XCTAssertEqual(session.viewMode, .details)
    }

    /// Review: "Apply to All Folders…" also reaches the folders whose built-in default is Large Icons (~/Applications
    /// and its Utilities, here in the sandbox home); "Use as Default" keeps the built-in rule.
    func testApplyToAllOverridesTheBuiltInApplicationsRule() async throws {
        let h = try await ShellHarness.make(self)
        let env = h.environment
        let apps = try h.sandbox.createDirectory("Applications")
        let utilities = try h.sandbox.createDirectory("Applications/Utilities")
        XCTAssertEqual(env.settings.home.standardizedFileURL, h.sandbox.root.standardizedFileURL)
        let session = try await makeSession(h)
        session.navigate(to: apps)
        try await h.waitUntil("Applications complete") { session.folder.state == .complete }
        XCTAssertEqual(session.viewMode, .icons, "built-in rule: Applications opens as Large Icons")
        XCTAssertEqual(session.viewState.iconSize, .large)
        session.navigate(to: h.url(""))
        try await h.waitUntil("files complete") { session.folder.state == .complete }
        session.useViewAsDefault()
        session.navigate(to: apps)
        XCTAssertEqual(session.viewMode, .icons, "Use as Default keeps the built-in rule")
        XCTAssertFalse(env.settings.builtInFolderViewsOff)

        FolderViewCoordinator(store: env.folderViews, settings: env.settings, lanes: env.lanes, volumes: env.volumes)
            .applyToAll(env.settings.defaultFolderViewState())
        XCTAssertTrue(env.settings.builtInFolderViewsOff)
        session.reloadViewState()
        XCTAssertEqual(session.viewMode, .details, "Apply to All reaches Applications")
        XCTAssertEqual(session.viewState.iconSize, .medium)
        session.navigate(to: utilities)
        try await h.waitUntil("Utilities complete") { session.folder.state == .complete }
        XCTAssertEqual(session.viewMode, .details, "and its Utilities folder")
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
