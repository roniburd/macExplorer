import XCTest
@testable import UI
import Core
import MacxFixtures
import MacxFS
import MacxPluginKit

@MainActor
final class RemoteBrowsingTests: XCTestCase {
    private let root = RemoteLocation(provider: "test.fake", repo: "o/r", ref: "main")

    private func makeSession(_ h: ShellHarness) async throws -> (BrowserSession, FakeRemoteProvider) {
        let fake = FakeRemoteProvider()
        fake.setTree(repo: "o/r", ["": [RemoteItem(name: "src", kind: .directory), RemoteItem(name: "a.txt", kind: .file, size: 1)],
                                   "src": [RemoteItem(name: "main.swift", kind: .file, size: 2)]])
        h.environment.remote.register([fake], source: "tests")
        try h.file("local.txt")
        let session = BrowserSession(environment: h.environment, initialURL: h.url(""))
        addTeardownBlock { @MainActor in session.close() }
        try await h.waitUntil("local complete") { session.folder.state == .complete }
        return (session, fake)
    }

    func testNavigateIntoUpAndBack() async throws {
        let h = try await ShellHarness.make(self)
        let (session, _) = try await makeSession(h)
        session.navigate(to: root.url.appending(path: "src"))
        try await h.waitUntil("remote complete") { session.folder.isRemote && session.folder.state == .complete }
        XCTAssertNotNil(session.folder.row(named: "main.swift"))
        session.goUp()
        try await h.waitUntil("repo root") { RemoteLocation(url: session.folder.directory) == root && session.folder.state == .complete }
        session.goUp()
        XCTAssertEqual(RemoteLocation(url: session.folder.directory), root, "nothing above the repository root")
        session.goBack(); session.goBack()
        try await h.waitUntil("back to local") { !session.folder.isRemote && session.folder.state == .complete }
    }

    func testUpInColumnsMovesLeftOneColumn() async throws {
        let h = try await ShellHarness.make(self)
        let (session, fake) = try await makeSession(h)
        session.navigate(to: root.url)
        try await h.waitUntil("remote complete") { session.folder.isRemote && session.folder.state == .complete }
        session.updateViewState { $0.mode = .columns }
        let chain = try XCTUnwrap(session.columnChain)
        chain.models[0].select(.names(["src"]))
        try await h.waitUntil("src column listed") { chain.models.count >= 2 && chain.models[1].state == .complete }
        chain.moveRight()
        XCTAssertEqual(RemoteLocation(url: session.folder.directory), root.appending("src"))
        let historyBefore = session.history.current
        let listsBefore = fake.calls.count
        session.goUp()
        XCTAssertTrue(session.columnChain === chain)
        XCTAssertEqual(chain.activeIndex, 0, "up moves left one column")
        XCTAssertEqual(chain.models.count, 2, "every column stays open")
        XCTAssertTrue(session.folder === chain.models[0])
        XCTAssertEqual(session.history.current, historyBefore, "no history visit")
        XCTAssertEqual(fake.calls.count, listsBefore, "nothing is listed again")
    }

    func testColumnChainUpStopsAtRepositoryRoot() async throws {
        let h = try await ShellHarness.make(self)
        let (session, _) = try await makeSession(h)
        session.navigate(to: root.url)
        try await h.waitUntil("remote complete") { session.folder.isRemote && session.folder.state == .complete }
        session.updateViewState { $0.mode = .columns }
        let chain = try XCTUnwrap(session.columnChain)
        XCTAssertEqual(chain.activeIndex, 0)
        chain.up()   // the ⌘↑ key path in Columns (handleColumnKey) calls this directly
        XCTAssertEqual(RemoteLocation(url: session.folder.directory), root, "nothing above the repository root")
        XCTAssertEqual(RemoteLocation(url: chain.models[0].directory), root)
    }

    func testColumnChainUpFromRemoteSubfolderRootGoesToParent() async throws {
        let h = try await ShellHarness.make(self)
        let (session, _) = try await makeSession(h)
        session.navigate(to: root.appending("src").url)
        try await h.waitUntil("remote complete") { session.folder.isRemote && session.folder.state == .complete }
        session.updateViewState { $0.mode = .columns }
        let chain = try XCTUnwrap(session.columnChain)
        chain.up()
        try await h.waitUntil("repo root column") {
            RemoteLocation(url: chain.models[0].directory) == root && chain.models[0].state == .complete
        }
        XCTAssertEqual(chain.models[0].directory.absoluteString, root.url.absoluteString, "parent built via RemoteLocation")
    }

    func testCommandStateAndSizes() async throws {
        let h = try await ShellHarness.make(self)
        let (session, _) = try await makeSession(h)
        session.navigate(to: root.url)
        try await h.waitUntil("remote complete") { session.folder.isRemote && session.folder.state == .complete }
        session.updateViewState { $0.calculateFolderSizes = true }
        XCTAssertNil(session.sizeSession)
        let s = CommandStateBuilder.state(for: .currentFolder(session.folder), session: session, environment: h.environment, previewPaneVisible: false)
        XCTAssertTrue(s.isRemote)
        XCTAssertTrue(s.folderIsReadOnly)
        XCTAssertFalse(s.canGoUp, "at the repository root")
    }

    func testRestorationEncodesRemoteURL() throws {
        let url = root.appending("src").url
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        BrowserWindowRestoration.encode(url, into: coder)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        XCTAssertEqual(BrowserWindowRestoration.folderURL(from: decoder), url)
        let local = URL(filePath: "/tmp/x", directoryHint: .isDirectory)
        let c2 = NSKeyedArchiver(requiringSecureCoding: true)
        BrowserWindowRestoration.encode(local, into: c2)
        XCTAssertEqual(BrowserWindowRestoration.folderURL(from: try NSKeyedUnarchiver(forReadingFrom: c2.encodedData))?.path, "/tmp/x")
    }

    func testDropsOntoRemoteFoldersAreRefused() async throws {
        let h = try await ShellHarness.make(self)
        _ = try await makeSession(h)
        let drops = DropTarget(context: h.context)
        XCTAssertEqual(drops.operation(sources: [h.url("local.txt")], destination: root.url, modifiers: [], secondary: false), .none)
        XCTAssertEqual(drops.operation(sources: [h.url("local.txt")], destination: root.url, modifiers: .option, secondary: true), .none)
    }
}
