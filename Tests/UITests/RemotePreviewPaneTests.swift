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
                 RemoteItem(name: "src", kind: .directory)],
            "src": [],
        ])
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
