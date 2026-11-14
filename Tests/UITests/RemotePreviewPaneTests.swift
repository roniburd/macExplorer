import XCTest
import AppKit
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures
import MacxPluginKit

@MainActor
final class RemotePreviewPaneTests: XCTestCase {
    var sandbox: Sandbox!
    var context: UIContext!
    var fake: FakeRemoteProvider!
    var host: FakeQuickLookHost!
    var env: CoreEnvironment { context.environment }

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        fake = FakeRemoteProvider()
        fake.setTree(repo: "demo", [
            "": [RemoteItem(name: "a.txt", kind: .file, size: 20, contentID: "a1"),
                 RemoteItem(name: "big.txt", kind: .file, size: 11 << 20, contentID: "b1"),
                 RemoteItem(name: "b.txt", kind: .file, size: 20, contentID: "bb"),
                 RemoteItem(name: "README.md", kind: .file, size: 40, contentID: "r1"),
                 RemoteItem(name: "src", kind: .directory)],
            "src": [RemoteItem(name: "guide.md", kind: .file, size: 10, contentID: "g1"),
                    RemoteItem(name: "logo.png", kind: .file, size: 10, contentID: "l1")],
        ])
        fake.setContent(repo: "demo", path: "README.md", Data("[Guide](src/guide.md)\n\n![logo](src/logo.png)\n".utf8))
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = try sandbox.createDirectory("state")
        context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root, remoteProviders: [fake]), options: options)
        host = FakeQuickLookHost()
    }

    override func tearDown() async throws { host = nil; context = nil }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), file: StaticString = #filePath,
                           line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for: \(what)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private var rootURL: URL { RemoteLocation(provider: "test.fake", repo: "demo", ref: "main").url }

    private func remoteFolder() async -> FolderModel {
        let m = env.makeFolderModel(rootURL)
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        await waitUntil("loaded") { m.state == .complete }
        return m
    }

    private func pane() -> PreviewPaneController {
        let host = self.host!
        let p = PreviewPaneController(context: context, makeHost: { host }, debounce: .milliseconds(20))
        _ = p.view
        p.isActive = true
        addTeardownBlock { @MainActor in p.close() }
        return p
    }

    func testSmallRemoteFileIsFetchedAndShownAsText() async {
        let m = await remoteFolder()
        let p = pane()
        p.bind(m)
        m.select(.names(["a.txt"]))
        await waitUntil("text") { p.displayState == .text("content of a.txt", truncated: false) }
        XCTAssertNil(p.details, "no POSIX metadata for a remote item")
    }

    func testLargeRemoteFileOffersADownloadThenPreviews() async {
        let m = await remoteFolder()
        let p = pane()
        p.bind(m)
        m.select(.names(["big.txt"]))
        await waitUntil("offer") { p.probeState == "remoteDownload" }
        XCTAssertEqual(p.messageButtonTitle, String(format: L10n.string("Download to preview (%@)"), Formatters.bytes(11 << 20)))
        XCTAssertEqual(fake.fetchCount, 0)
        p.performDownload()
        await waitUntil("text after download") { p.probeState == "text" }
    }

    func testRemoteFolderShowsTheFolderMessage() async {
        let m = await remoteFolder()
        let p = pane()
        p.bind(m)
        m.select(.names(["src"]))
        await waitUntil("folder") { p.probeState == "folder" }
    }

    /// Review (Task 11): links and images of a remote README resolve in the repository, not in the cache.
    func testRemoteMarkdownLinksPointIntoTheRepository() async {
        env.settings.previewRendersMarkdown = true
        let m = await remoteFolder()
        let p = pane()
        var revealed: [URL] = []
        p.onRevealFile = { revealed.append($0) }
        p.bind(m)
        m.select(.names(["README.md"]))
        let readme = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["README.md"]).url
        await waitUntil("markdown") {
            if case .markdown(_, _, let url) = p.displayState { return url == readme }
            return false
        }
        let guide = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["src", "guide.md"]).url
        XCTAssertTrue(p.followLink(guide))
        XCTAssertEqual(revealed, [guide])
        await waitUntil("the repository image is fetched") { fake.calls.contains("fetch demo/src/logo.png") }
    }

    /// A gated `localize`: Quick Look's copies arrive only when the test says so.
    @MainActor private final class Gate {
        var waiting: [CheckedContinuation<Void, Never>] = []
        var requests: [[URL]] = []
        func open() { let w = waiting; waiting = []; w.forEach { $0.resume() } }
    }

    private func gatedQuickLook(_ m: FolderModel) -> (QuickLookController, FakeQuickLookPanel, Gate) {
        let panel = FakeQuickLookPanel()
        let gate = Gate()
        let ql = QuickLookController(panel: { panel })
        ql.localize = { [env] urls in
            gate.requests.append(urls)
            await withCheckedContinuation { gate.waiting.append($0) }
            return await RemotePreview.localCopies(urls, registry: env.remote, cache: env.remoteFiles).local
        }
        ql.bind(m)
        return (ql, panel, gate)
    }

    /// Review (Task 11): Space, then another selection before the copies arrive: the old copies never show.
    func testQuickLookDropsCopiesOfAnEarlierSelection() async {
        let m = await remoteFolder()
        let (ql, panel, gate) = gatedQuickLook(m)
        m.select(.names(["a.txt"]))
        ql.toggle()
        await waitUntil("fetching") { gate.requests.count == 1 }
        m.select(.names(["b.txt"]))
        XCTAssertFalse(ql.isLocalizing, "a selection change cancels the fetch")
        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(panel.isVisible, "the panel does not open on the earlier selection")
        XCTAssertEqual(fake.fetchCount, 0, "the cancelled request started no download")
    }

    /// Review (Task 11): the panel is open and the selection moves from remote to a local folder's items: a late
    /// remote result does not overwrite them.
    func testQuickLookKeepsTheLocalItemsWhenALateRemoteResultArrives() async throws {
        let m = await remoteFolder()
        let (ql, panel, gate) = gatedQuickLook(m)
        m.select(.names(["a.txt"]))
        ql.toggle()
        await waitUntil("fetching") { gate.requests.count == 1 }
        gate.open()
        await waitUntil("shown") { panel.isVisible }
        m.select(.names(["b.txt"]))
        await waitUntil("fetching b") { gate.requests.count == 2 }
        let local = try sandbox.createDirectory("local")
        try Data("x".utf8).write(to: local.appending(path: "x.txt"))
        let localModel = env.makeFolderModel(local)
        addTeardownBlock { @MainActor in localModel.close() }
        localModel.start()
        await waitUntil("local loaded") { localModel.state == .complete }
        localModel.select(.names(["x.txt"]))
        ql.bind(localModel)
        XCTAssertFalse(ql.isLocalizing, "a rebind cancels the fetch")
        XCTAssertEqual(ql.items.map(\.lastPathComponent), ["x.txt"])
        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ql.items.map(\.lastPathComponent), ["x.txt"], "the late remote copies are dropped")
        XCTAssertTrue(ql.items[0].path(percentEncoded: false).hasPrefix(local.path(percentEncoded: false)))
    }

    /// Review (Task 11): Esc while the copies are still coming cancels them.
    func testHidingCancelsTheFetch() async {
        let m = await remoteFolder()
        let (ql, panel, gate) = gatedQuickLook(m)
        m.select(.names(["a.txt"]))
        ql.toggle()
        await waitUntil("fetching") { gate.requests.count == 1 }
        ql.hideIfVisible()
        XCTAssertFalse(ql.isLocalizing)
        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(panel.isVisible)
    }

    func testQuickLookGetsLocalCopies() async {
        let m = await remoteFolder()
        let panel = FakeQuickLookPanel()
        let ql = QuickLookController(panel: { panel })
        ql.localize = { [env] urls in await RemotePreview.localCopies(urls, registry: env.remote, cache: env.remoteFiles).local }
        ql.bind(m)
        m.select(.names(["a.txt"]))
        ql.toggle()
        await waitUntil("panel shown") { panel.isVisible }
        XCTAssertEqual(ql.items.count, 1)
        XCTAssertTrue(ql.items[0].isFileURL)
        XCTAssertEqual(ql.items[0].lastPathComponent, "a.txt")
    }
}
