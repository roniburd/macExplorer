import XCTest
@testable import UI
import Core
import MacxFS

@MainActor
final class BrowserSessionTests: XCTestCase {
    private func makeSession(_ h: ShellHarness, _ relative: String = "") async throws -> BrowserSession {
        let session = BrowserSession(environment: h.environment, initialURL: h.url(relative))
        addTeardownBlock { @MainActor in session.close() }
        try await h.waitUntil("initial folder complete") { session.folder.state == .complete }
        return session
    }

    /// P2-14: the folder-size session lives while "Calculate Folder Sizes" is on and Details is shown; it stops on a
    /// mode change away, on navigation (the next folder's own toggle decides) and when the toggle is turned off.
    func testFolderSizeSessionFollowsToggleModeAndNavigation() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("big/a.bin"); try h.dir("other")
        let session = try await makeSession(h)
        XCTAssertNil(session.sizeSession)
        XCTAssertFalse(session.folder.folderSizesEnabled)
        session.updateViewState { $0.calculateFolderSizes = true }
        let first = try XCTUnwrap(session.sizeSession)
        XCTAssertTrue(session.folder.folderSizesEnabled)
        await first.waitUntilIdle()
        let big = try XCTUnwrap(session.folder.row(named: "big"))
        XCTAssertNotNil(session.folder.folderSize(atRow: big))
        session.updateViewState { $0.mode = .icons }
        XCTAssertNil(session.sizeSession, "Icons: no folder sizes")
        XCTAssertFalse(session.folder.folderSizesEnabled)
        XCTAssertNil(session.folder.folderSize(atRow: big))
        session.updateViewState { $0.mode = .details }
        XCTAssertNotNil(session.sizeSession)
        session.navigate(to: h.url("other"))
        XCTAssertNil(session.sizeSession, "the other folder has its own toggle (off)")
        XCTAssertFalse(session.folder.folderSizesEnabled)
        session.goBack()
        XCTAssertNotNil(session.sizeSession, "back: this folder's saved toggle is on")
        XCTAssertTrue(session.folder.folderSizesEnabled)
        session.updateViewState { $0.calculateFolderSizes = false }
        XCTAssertNil(session.sizeSession)
        XCTAssertFalse(session.folder.folderSizesEnabled)
    }

    func testInitStartsTheModelAtTheInitialURLWithTheSettingsViewMode() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        h.environment.settings.viewMode = .icons
        let session = try await makeSession(h)
        XCTAssertEqual(session.folder.directory.standardizedFileURL.path, h.url("").standardizedFileURL.path)
        XCTAssertEqual(Set(ShellHarness.names(session.folder)), ["a.txt", "sub"])
        XCTAssertEqual(session.history.current.standardizedFileURL.path, h.url("").standardizedFileURL.path)
        XCTAssertFalse(session.history.canGoBack)
        XCTAssertEqual(session.viewMode, .icons)
    }

    func testNavigateReplacesTheModelRecordsHistoryAndEmitsEvents() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("sub/inner.txt")
        let session = try await makeSession(h)
        var events: [String] = []
        let token = session.observe { event in
            switch event {
            case .folderChanged(let model): events.append("folder:" + model.directory.lastPathComponent)
            case .historyChanged: events.append("history")
            case .viewModeChanged: events.append("viewMode")
            case .viewStateChanged: events.append("viewState")
            case .banner(let text): events.append("banner:\(text ?? "nil")")
            case .columnsChanged: events.append("columns")
            case .resultsChanged, .searchTextChanged, .searchChanged: break       // search (P3-10)
            }
        }
        defer { token.cancel() }
        let old = session.folder
        session.navigate(to: h.url("sub"))
        XCTAssertFalse(old === session.folder)
        XCTAssertEqual(events, ["folder:sub", "viewState", "history"])
        try await h.waitUntil("sub complete") { session.folder.state == .complete }
        XCTAssertEqual(ShellHarness.names(session.folder), ["inner.txt"])
        XCTAssertTrue(session.history.canGoBack)
        XCTAssertEqual(session.history.current.lastPathComponent, "sub")
    }

    func testNavigateWithoutRecordingHistoryKeepsTheStacks() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let session = try await makeSession(h)
        session.navigate(to: h.url("sub"), recordHistory: false)
        XCTAssertFalse(session.history.canGoBack)
        XCTAssertEqual(session.folder.directory.lastPathComponent, "sub")
    }

    func testBackForwardAndUp() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("a/b")
        let session = try await makeSession(h)
        session.navigate(to: h.url("a"))
        session.navigate(to: h.url("a/b"))
        session.goBack()
        XCTAssertEqual(session.folder.directory.lastPathComponent, "a")
        XCTAssertTrue(session.history.canGoForward)
        session.goForward()
        XCTAssertEqual(session.folder.directory.lastPathComponent, "b")
        XCTAssertFalse(session.history.canGoForward)
        session.goUp()
        XCTAssertEqual(session.folder.directory.lastPathComponent, "a")
        XCTAssertEqual(session.history.backList.count, 3, "up is a visit")
        try await h.waitUntil("up selects the folder it came from") {
            session.folder.selectedURLs.map(\.lastPathComponent) == ["b"]
        }
    }

    func testGoBackAndForwardWithEmptyStacksDoNothing() async throws {
        let h = try await ShellHarness.make(self)
        let session = try await makeSession(h)
        let model = session.folder
        session.goBack()
        session.goForward()
        XCTAssertTrue(model === session.folder)
    }

    func testGoUpAtTheFileSystemRootDoesNothing() async throws {
        let h = try await ShellHarness.make(self)
        // Reads "/" (read-only listing); nothing is written outside the sandbox.
        let session = BrowserSession(environment: h.environment, initialURL: URL(filePath: "/", directoryHint: .isDirectory))
        defer { session.close() }
        let model = session.folder
        session.goUp()
        XCTAssertTrue(model === session.folder)
    }

    func testNavigateSelectingNameSelectsItOnceListed() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("sub/x.txt"); try h.file("sub/y.txt")
        let session = try await makeSession(h)
        session.navigate(to: h.url("sub"), selecting: "y.txt")
        try await h.waitUntil("y.txt selected") { session.folder.selectedURLs.map(\.lastPathComponent) == ["y.txt"] }
    }

    func testSessionNavigateCancelsPreviousModel() async throws {
        // Overview Review Focus 3: a large folder still streaming, then rapid navigation.
        let h = try await ShellHarness.make(self)
        for i in 0..<3000 { try h.file("big/f\(i).txt") }
        try h.file("small/1.txt"); try h.file("small/2.txt"); try h.file("small/3.txt")
        let session = try await makeSession(h)
        session.navigate(to: h.url("big"))
        let big = session.folder
        var lateEvents = 0
        let token = big.observe { _ in lateEvents += 1 }
        defer { token.cancel() }
        for _ in 0..<20 {
            session.navigate(to: h.url("small"))
            session.navigate(to: h.url("big"))
        }
        session.navigate(to: h.url("small"))
        try await h.waitUntil("small complete") { session.folder.state == .complete }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(lateEvents, 0, "the replaced model was closed and emits nothing")
        XCTAssertEqual(ShellHarness.names(session.folder), ["1.txt", "2.txt", "3.txt"])
        XCTAssertTrue(session.folder.selection.isEmpty, "stale reads never disturb the new folder's selection")
    }

    func testReloadPicksUpChanges() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt")
        let session = try await makeSession(h)
        let model = session.folder
        try h.file("b.txt")
        session.reload()
        try await h.waitUntil("b.txt listed") { Set(ShellHarness.names(session.folder)) == ["a.txt", "b.txt"] }
        XCTAssertTrue(model === session.folder, "reload keeps the model (re-read + diff)")
    }

    func testViewModeChangeEmitsOnlyOnChange() async throws {
        let h = try await ShellHarness.make(self)
        let session = try await makeSession(h)
        var modes: [ViewMode] = []
        let token = session.observe { if case .viewModeChanged(let m) = $0 { modes.append(m) } }
        defer { token.cancel() }
        session.updateViewState { $0.mode = .icons }
        session.updateViewState { $0.mode = .icons }
        session.updateViewState { $0.mode = .details }
        XCTAssertEqual(modes, [.icons, .details])
    }

    func testRemovedFolderRelocatesToTheParentWithABanner() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("parent/Old")
        let session = try await makeSession(h, "parent/Old")
        var banners: [String?] = []
        let token = session.observe { if case .banner(let text) = $0 { banners.append(text) } }
        defer { token.cancel() }
        try h.sandbox.rename("files/parent/Old", to: "files/parent/New")
        try await h.waitUntil("relocated to the parent", timeout: .seconds(10)) {
            session.folder.directory.lastPathComponent == "parent"
        }
        XCTAssertEqual(banners.last ?? nil, "'Old' was moved or deleted")
        session.navigate(to: h.url("parent/New"))
        XCTAssertEqual(banners.last ?? "not cleared", nil, "a user navigation clears the banner")
    }

    func testGoingForwardToAMissingFolderRelocatesToTheNearestAncestorWithABanner() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a/deep/x.txt")
        let session = try await makeSession(h)
        var banners: [String?] = []
        let token = session.observe { if case .banner(let text) = $0 { banners.append(text) } }
        defer { token.cancel() }
        session.navigate(to: h.url("a/deep"))
        try await h.waitUntil("deep complete") { session.folder.state == .complete }
        session.goBack()
        try await h.waitUntil("root complete") { session.folder.state == .complete }
        try h.sandbox.rename("files/a/deep", to: "files/moved")
        session.goForward()
        try await h.waitUntil("relocated to the nearest ancestor", timeout: .seconds(10)) {
            session.folder.directory.lastPathComponent == "a" && session.folder.state == .complete
        }
        XCTAssertEqual(banners.last ?? nil, "'deep' was moved or deleted")
        XCTAssertTrue(session.history.canGoBack, "the root stays reachable with Back")
    }

    func testCloseClosesTheModel() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt")
        let session = BrowserSession(environment: h.environment, initialURL: h.url(""))
        let model = session.folder
        var events = 0
        let token = model.observe { _ in events += 1 }
        defer { token.cancel() }
        session.close()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(events, 0)
        XCTAssertNotEqual(model.state, .complete)
    }

    // MARK: QA round 1

    func testEverySessionFollowsTheShowHiddenSetting() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("top.txt"); try h.file(".dot")
        h.environment.settings.showHidden = false
        let one = try await makeSession(h), two = try await makeSession(h)
        h.environment.settings.showHidden = true
        try await h.waitUntil("both windows show hidden items") {
            one.folder.query.showHidden && two.folder.query.showHidden && one.folder.rowCount == 2 && two.folder.rowCount == 2
        }
        h.environment.settings.showHidden = false
        try await h.waitUntil("both windows hide them again") {
            !one.folder.query.showHidden && !two.folder.query.showHidden && one.folder.rowCount == 1 && two.folder.rowCount == 1
        }
        one.navigate(to: h.url(""))
        XCTAssertFalse(one.folder.query.showHidden, "a new model starts from the setting")
    }

    func testAPendingSelectionOfAnUnlistedNameIsDroppedWhenTheListingCompletes() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("top.txt"); try h.file("other.txt"); try h.file(".dot")
        h.environment.settings.showHidden = false
        let session = try await makeSession(h)
        session.navigate(to: h.url(""), selecting: ".dot")
        try await h.waitUntil("listed") { session.folder.state == .complete && session.folder.rowCount == 2 }
        let top = try XCTUnwrap(session.folder.row(named: "top.txt"))
        session.folder.select(.set(IndexSet(integer: top), cursor: top))
        var query = session.folder.query
        query.showHidden = true
        session.folder.setQuery(query)
        try await h.waitUntil("hidden rows shown") { session.folder.rowCount == 3 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.folder.selectedURLs.map(\.lastPathComponent), ["top.txt"])
    }

    func testAPendingSelectionNeverFiresForAnItemCreatedLater() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt")
        let session = try await makeSession(h)
        session.navigate(to: h.url(""), selecting: "later.txt")
        try await h.waitUntil("listed") { session.folder.state == .complete }
        try h.file("later.txt")
        try await h.waitUntil("later.txt listed", timeout: .seconds(10)) { session.folder.row(named: "later.txt") != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.folder.selectedURLs, [])
    }

    func testAUserSelectionCancelsAPendingSelection() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt")
        let session = try await makeSession(h)
        session.selectWhenListed("later.txt")
        let row = try XCTUnwrap(session.folder.row(named: "a.txt"))
        session.folder.select(.set(IndexSet(integer: row), cursor: row))
        try h.file("later.txt")
        try await h.waitUntil("later.txt listed", timeout: .seconds(10)) { session.folder.row(named: "later.txt") != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.folder.selectedURLs.map(\.lastPathComponent), ["a.txt"])
    }
}
