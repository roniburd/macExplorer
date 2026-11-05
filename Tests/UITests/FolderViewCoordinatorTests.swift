import XCTest
import AppKit
import Darwin
@testable import UI
@testable import Core
import MacxFS

/// P2-08: per-folder view state applied on every navigation, saved on every user change, identity correction and
/// "Apply to All Folders". Every file lives in the harness sandbox (`macx-tests-<UUID>/files`).
@MainActor
final class FolderViewCoordinatorTests: XCTestCase {
    private func makeSession(_ h: ShellHarness, _ relative: String = "") async throws -> BrowserSession {
        let session = BrowserSession(environment: h.environment, initialURL: h.url(relative))
        addTeardownBlock { @MainActor in session.close() }
        try await h.waitUntil("initial folder complete") { session.folder.state == .complete }
        return session
    }

    private func world(_ h: ShellHarness) throws {
        try h.dir("sub"); try h.file("sub/x.txt"); try h.file("y.txt")
    }

    // MARK: BrowserSession (no window server)

    func testModeChangeIsSavedForThisFolderOnly() async throws {
        let h = try await ShellHarness.make(self)
        try world(h)
        let session = try await makeSession(h)
        session.updateViewState { $0.mode = .icons }
        XCTAssertEqual(session.viewMode, .icons)
        XCTAssertEqual(h.environment.settings.viewMode, .details, "global default untouched")
        session.navigate(to: h.url("sub"))
        XCTAssertEqual(session.viewMode, .details)
        session.goBack()
        XCTAssertEqual(session.viewMode, .icons)
        session.goForward()
        XCTAssertEqual(session.viewMode, .details)
    }

    func testGroupByIsPerFolderAndAppliesOnlyInDetails() async throws {
        let h = try await ShellHarness.make(self)
        try world(h)
        let session = try await makeSession(h)
        XCTAssertEqual(session.folder.grouping, .none)
        session.updateViewState { $0.groupBy = .kind }
        XCTAssertEqual(session.folder.grouping, .kind)
        try await h.waitUntil("grouped") { session.folder.groups.count == 2 }
        XCTAssertEqual(session.folder.name(atRow: 0), "sub")
        session.updateViewState { $0.mode = .icons }
        XCTAssertEqual(session.folder.grouping, .none, "Icons is never grouped")
        session.updateViewState { $0.mode = .details }
        XCTAssertEqual(session.folder.grouping, .kind)
        session.navigate(to: h.url("sub"))
        XCTAssertEqual(session.folder.grouping, .none, "another folder keeps its own Group by")
        session.goBack()
        XCTAssertEqual(session.folder.grouping, .kind, "the model is built with the folder's Group by")
        try await h.waitUntil("grouped again") { session.folder.state == .complete && session.folder.groups.count == 2 }
        XCTAssertEqual(h.environment.settings.groupBy, .none, "global default untouched")
    }

    func testSortIsPerFolderAndDrivesTheQuery() async throws {
        let h = try await ShellHarness.make(self)
        try world(h)
        let session = try await makeSession(h)
        session.updateViewState { $0.sort = MacxFS.SortDescriptor(field: .size, ascending: false) }
        XCTAssertEqual(session.folder.query.sort, MacxFS.SortDescriptor(field: .size, ascending: false))
        XCTAssertEqual(h.environment.settings.sort, .default, "global default untouched")
        session.navigate(to: h.url("sub"))
        XCTAssertEqual(session.folder.query.sort, .default)
        session.goBack()
        XCTAssertEqual(session.folder.query.sort, MacxFS.SortDescriptor(field: .size, ascending: false),
                       "the model is built with the folder's sort")
    }

    func testNavigationEmitsTheViewStateAndModeChange() async throws {
        let h = try await ShellHarness.make(self)
        try world(h)
        let session = try await makeSession(h)
        session.navigate(to: h.url("sub"))
        session.updateViewState { $0.mode = .icons; $0.iconSize = .large }
        session.navigate(to: h.url(""))
        var events: [String] = []
        let token = session.observe { event in
            switch event {
            case .folderChanged: events.append("folder")
            case .viewModeChanged(let mode): events.append("mode:\(mode.rawValue)")
            case .viewStateChanged(let state): events.append("state:\(state.mode.rawValue):\(state.iconSize.rawValue)")
            case .historyChanged, .banner: break
            }
        }
        defer { token.cancel() }
        session.goBack()
        XCTAssertEqual(events, ["folder", "mode:icons", "state:icons:large"])
        events.removeAll()
        session.updateViewState { $0.iconSize = .large }
        XCTAssertEqual(events, [], "no change, no event")
        session.updateViewState { $0.iconSize = .small }
        XCTAssertEqual(events, ["state:icons:small"])
    }

    func testIdentityCorrectionAfterExternalRename() async throws {
        let h = try await ShellHarness.make(self)
        try world(h)
        let session = try await makeSession(h)
        let volume = h.environment.volumes.volume(for: h.url(""))
        try XCTSkipUnless(volume?.capabilities.idStable == true && volume?.id.raw.hasPrefix("uuid:") == true,
                          "temp volume lacks stable IDs")
        session.navigate(to: h.url("sub"))                    // no fileID: the probe refines the locator
        try await h.waitUntil("sub complete") { session.folder.state == .complete }
        session.updateViewState { $0.mode = .icons }
        try await h.waitUntil("locator refined") { session.locator.fileID != nil }
        try await h.waitUntil("object record") {
            h.environment.folderViews.hasOverride(for: FolderViewLocator(url: h.url("elsewhere"), volume: volume,
                                                                          fileID: session.locator.fileID))
        }
        session.navigate(to: h.url(""))
        // The test's own sandbox folder, renamed as another app would.
        XCTAssertEqual(rename(h.url("sub").path(percentEncoded: false), h.url("renamed").path(percentEncoded: false)), 0)
        session.navigate(to: h.url("renamed"))                // no fileID: path miss → defaults first
        XCTAssertEqual(session.viewMode, .details, "the first paint never waits for the probe")
        try await h.waitUntil("refined to the object record") { session.viewMode == .icons }
        XCTAssertEqual(session.viewState.mode, .icons)
    }

    func testOpeningADirectoryRowPassesItsFileID() async throws {
        let h = try await ShellHarness.make(self)
        try world(h)
        let session = try await makeSession(h)
        let row = try XCTUnwrap(session.folder.row(named: "sub"))
        let fileID = session.folder.entry(atRow: row).fileID
        session.navigate(to: h.url("sub"), folderID: fileID)
        XCTAssertEqual(session.locator.fileID, fileID, "known at once, no probe needed")
        var st = Darwin.stat()
        XCTAssertEqual(stat(h.url("sub").path(percentEncoded: false), &st), 0)
        XCTAssertEqual(UInt64(st.st_ino), fileID)
    }

    func testEditsBeforeTheProbeReturnsAreKept() async throws {
        let h = try await ShellHarness.make(self)
        try world(h)
        let session = try await makeSession(h)
        session.navigate(to: h.url("sub"))
        session.updateViewState { $0.iconSize = .small }      // before the probe can have returned
        try await h.waitUntil("probe done") {
            session.locator.fileID != nil || h.environment.volumes.volume(for: h.url(""))?.capabilities.idStable != true
        }
        XCTAssertEqual(session.viewState.iconSize, .small)
        session.navigate(to: h.url(""))
        session.navigate(to: h.url("sub"))
        XCTAssertEqual(session.viewState.iconSize, .small)
    }

    func testApplyToAllMakesDefaultAndClearsOverrides() async throws {
        let h = try await ShellHarness.make(self)
        try world(h)
        let env = h.environment
        let session = try await makeSession(h)
        session.navigate(to: h.url("sub"))
        session.updateViewState { $0.mode = .details; $0.iconSize = .small }
        session.navigate(to: h.url(""))
        session.updateViewState { $0.mode = .icons; $0.iconSize = .large }
        FolderViewCoordinator(store: env.folderViews, settings: env.settings, lanes: env.lanes, volumes: env.volumes)
            .applyToAll(session.viewState)
        XCTAssertEqual(env.folderViews.count, 0)
        XCTAssertEqual(env.settings.viewMode, .icons)
        XCTAssertEqual(env.settings.iconSize, .large)
        session.navigate(to: h.url("sub"))
        XCTAssertEqual(session.viewMode, .icons, "sub's own override was reset")
        XCTAssertEqual(session.viewState.iconSize, .large)
    }

    func testReloadViewStateFollowsNewDefaults() async throws {
        let h = try await ShellHarness.make(self)
        try world(h)
        let session = try await makeSession(h)
        XCTAssertEqual(session.viewMode, .details)
        h.environment.settings.applyDefaultView(FolderViewState(
            mode: .icons, columns: h.environment.settings.columns, sort: MacxFS.SortDescriptor(field: .kind, ascending: true),
            iconSize: .small, groupBy: .none, calculateFolderSizes: false))
        session.reloadViewState()
        XCTAssertEqual(session.viewMode, .icons)
        XCTAssertEqual(session.folder.query.sort.field, .kind)
        XCTAssertEqual(session.viewState.iconSize, .small)
    }

    // MARK: windows (window server)

    @MainActor
    private struct World {
        let h: ContentTestHarness
        let browser: BrowserWindowController
        let content: ContentViewController
        let commands: FileCommandController
        let prompts: ScriptedCommandPrompts
        var session: BrowserSession { browser.session }
        var target: CommandTarget { .currentFolder(browser.session.folder) }
    }

    private func windowWorld() async throws -> World {
        let h = try await ContentTestHarness.make(self)
        try h.dir("sub"); try h.file("sub/x.txt"); try h.file("y.txt")
        let browser = try await h.openBrowserWindow()
        let content = try h.content(of: browser)
        let commands = try XCTUnwrap(content.handler as? FileCommandController)
        let prompts = ScriptedCommandPrompts()
        commands.prompts = prompts
        return World(h: h, browser: browser, content: content, commands: commands, prompts: prompts)
    }

    func testViewSortAndIconSizeCommandsSaveForThisFolderOnly() async throws {
        let w = try await windowWorld()
        let settings = w.h.environment.settings
        w.commands.perform(.iconSizeLarge, target: w.target, sender: nil)
        w.commands.perform(.sortBySize, target: w.target, sender: nil)
        XCTAssertEqual(w.session.viewState.mode, .icons)
        XCTAssertEqual(w.session.viewState.iconSize, .large)
        XCTAssertTrue(w.content.activeList === w.content.icons)
        XCTAssertEqual(w.content.icons?.layout.iconSize, .large)
        XCTAssertEqual(w.session.folder.query.sort.field, .size)
        XCTAssertEqual(settings.viewMode, .details)
        XCTAssertEqual(settings.iconSize, .medium)
        XCTAssertEqual(settings.sort, .default)
        w.session.navigate(to: w.h.url("sub"))
        XCTAssertTrue(w.content.activeList === w.content.details)
        XCTAssertEqual(w.session.folder.query.sort, .default)
        w.session.goBack()
        XCTAssertTrue(w.content.activeList === w.content.icons)
        XCTAssertEqual(w.content.icons?.layout.iconSize, .large)
        w.commands.perform(.iconSizeSmall, target: w.target, sender: nil)
        XCTAssertEqual(w.content.icons?.layout.iconSize, .small)
    }

    func testToolbarSwitcherSavesForThisFolderOnly() async throws {
        let w = try await windowWorld()
        w.browser.toolbarController.selectViewMode(at: 1)
        XCTAssertEqual(w.session.viewMode, .icons)
        XCTAssertEqual(w.h.environment.settings.viewMode, .details)
        w.session.navigate(to: w.h.url("sub"))
        XCTAssertEqual(w.browser.toolbarController.viewSwitcher.selectedIndex, 0)
        w.session.goBack()
        XCTAssertEqual(w.browser.toolbarController.viewSwitcher.selectedIndex, 1)
    }

    func testColumnEditsAndHeaderSortSaveForThisFolderOnly() async throws {
        let w = try await windowWorld()
        let details = w.content.details
        let settings = w.h.environment.settings
        let kind = try XCTUnwrap(details.tableView.headerView?.menu?.items.first { $0.representedObject as? String == ColumnID.kind.rawValue })
        details.toggleColumn(kind)
        let size = try XCTUnwrap(details.tableView.tableColumns.first { DetailsColumns.columnID($0.identifier) == .size })
        details.tableView(details.tableView, didClick: size)
        XCTAssertEqual(w.session.viewState.columns.first { $0.id == .kind }?.visible, false)
        XCTAssertEqual(w.session.viewState.sort, MacxFS.SortDescriptor(field: .size, ascending: true))
        XCTAssertEqual(w.session.folder.query.sort.field, .size)
        XCTAssertEqual(settings.columns.first { $0.id == .kind }?.visible, true, "global default untouched")
        XCTAssertEqual(settings.sort, .default)
        func kindHidden() -> Bool? {
            details.tableView.tableColumns.first { DetailsColumns.columnID($0.identifier) == .kind }?.isHidden
        }
        XCTAssertEqual(kindHidden(), true)
        w.session.navigate(to: w.h.url("sub"))
        XCTAssertEqual(kindHidden(), false, "sub follows the defaults")
        XCTAssertNil(details.tableView.indicatorImage(in: try XCTUnwrap(details.tableView.tableColumns.first {
            DetailsColumns.columnID($0.identifier) == .size })))
        w.session.goBack()
        XCTAssertEqual(kindHidden(), true)
        let width = try XCTUnwrap(details.tableView.tableColumns.first { DetailsColumns.columnID($0.identifier) == .dateModified })
        width.width = 222
        try await w.h.waitUntil("resize saved") { w.session.viewState.columns.first { $0.id == .dateModified }?.width == 222 }
    }

    func testApplyViewToAllFoldersAsksThenResetsEveryWindow() async throws {
        let w = try await windowWorld()
        let other = try await w.h.openBrowserWindow("sub")
        other.session.updateViewState { $0.iconSize = .small }      // sub's own override, to be reset
        w.commands.perform(.viewAsIcons, target: w.target, sender: nil)
        w.commands.perform(.iconSizeLarge, target: w.target, sender: nil)
        XCTAssertEqual(other.session.viewMode, .details)
        w.prompts.confirmAnswers = [false]
        w.commands.perform(.applyViewToAllFolders, target: w.target, sender: nil)
        try await w.h.waitUntil("asked") { w.prompts.asked == [.applyViewToAllFolders] }
        XCTAssertEqual(other.session.viewMode, .details, "Cancel changes nothing")
        XCTAssertEqual(w.h.environment.settings.viewMode, .details)
        w.prompts.confirmAnswers = [true]
        w.commands.perform(.applyViewToAllFolders, target: w.target, sender: nil)
        try await w.h.waitUntil("other window reloaded") { other.session.viewMode == .icons }
        XCTAssertEqual(other.session.viewState.iconSize, .large)
        XCTAssertEqual(w.h.environment.settings.viewMode, .icons)
        XCTAssertEqual(w.h.environment.folderViews.count, 0)
        XCTAssertEqual(w.session.viewMode, .icons)
    }

    /// Review fix: opening a row no longer passes the listing's fileID (wrong for mount points); the session's stat
    /// probe supplies it, as on every other route. For a plain folder the two agree.
    func testOpenCommandOnAFolderRowKeysItByTheProbedIdentity() async throws {
        let w = try await windowWorld()
        let folder = w.session.folder
        let row = try XCTUnwrap(folder.row(named: "sub"))
        let fileID = folder.entry(atRow: row).fileID
        let volume = w.h.environment.volumes.volume(for: w.h.url(""))
        try XCTSkipUnless(volume?.capabilities.idStable == true, "temp volume lacks stable IDs")
        folder.select(.names(["sub"]))
        w.commands.perform(.open, target: .contentSelection(folder), sender: nil)
        try await w.h.waitUntil("opened sub") { w.session.folder.directory.lastPathComponent == "sub" }
        try await w.h.waitUntil("identity probed") { w.session.locator.fileID != nil }
        XCTAssertEqual(w.session.locator.fileID, fileID)
    }
}
