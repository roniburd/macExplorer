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
            case .banner(let text): events.append("banner:\(text ?? "nil")")
            }
        }
        defer { token.cancel() }
        let old = session.folder
        session.navigate(to: h.url("sub"))
        XCTAssertFalse(old === session.folder)
        XCTAssertEqual(events, ["folder:sub", "history"])
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
        session.viewMode = .icons
        session.viewMode = .icons
        session.viewMode = .details
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
}
