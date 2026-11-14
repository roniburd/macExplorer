import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFixtures
import MacxFS
import MacxPluginKit

/// FakeRemoteProvider plus web URLs (the fake's own `webURL` is nil), for Copy / Copy as Path.
struct WebURLProvider: RemoteProvider {
    let base: FakeRemoteProvider
    var id: String { base.id }
    var displayName: String { base.displayName }
    var iconSymbol: String { base.iconSymbol }
    func parseAddress(_ text: String) -> RemoteLocation? { base.parseAddress(text) }
    func completions(for text: String) async -> [String] { await base.completions(for: text) }
    func displayRoot(_ location: RemoteLocation) -> String { base.displayRoot(location) }
    func webURL(_ l: RemoteLocation) -> URL? { URL(string: "https://fake.example/\(l.repo)/\(l.ref ?? "main")/\(l.pathString)") }
    func listRefs(repo: String) async throws(RemoteError) -> [RemoteRef] { try await base.listRefs(repo: repo) }
    func resolveRef(_ location: RemoteLocation) async throws(RemoteError) -> RemoteLocation { try await base.resolveRef(location) }
    func list(_ location: RemoteLocation) -> AsyncThrowingStream<[RemoteItem], any Error> { base.list(location) }
    func fetch(_ location: RemoteLocation, item: RemoteItem, to destination: URL) async throws(RemoteError) {
        try await base.fetch(location, item: item, to: destination)
    }
    func invalidate(repo: String, ref: String?) { base.invalidate(repo: repo, ref: ref) }
}

/// FakeRemoteProvider that cancels the calling task right after fetching `cancelAfter`, without throwing: a provider
/// that ignores cancellation (or a fast or cached fetch).
struct CancellingProvider: RemoteProvider {
    let base: FakeRemoteProvider
    let cancelAfter: String
    var id: String { base.id }
    var displayName: String { base.displayName }
    var iconSymbol: String { base.iconSymbol }
    func parseAddress(_ text: String) -> RemoteLocation? { base.parseAddress(text) }
    func completions(for text: String) async -> [String] { await base.completions(for: text) }
    func displayRoot(_ location: RemoteLocation) -> String { base.displayRoot(location) }
    func webURL(_ l: RemoteLocation) -> URL? { nil }
    func listRefs(repo: String) async throws(RemoteError) -> [RemoteRef] { try await base.listRefs(repo: repo) }
    func resolveRef(_ location: RemoteLocation) async throws(RemoteError) -> RemoteLocation { try await base.resolveRef(location) }
    func list(_ location: RemoteLocation) -> AsyncThrowingStream<[RemoteItem], any Error> { base.list(location) }
    func fetch(_ location: RemoteLocation, item: RemoteItem, to destination: URL) async throws(RemoteError) {
        try await base.fetch(location, item: item, to: destination)
        if location.pathString == cancelAfter { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func invalidate(repo: String, ref: String?) { base.invalidate(repo: repo, ref: ref) }
}

@MainActor
final class RemoteTransferTests: XCTestCase {
    var sandbox: Sandbox!
    var context: UIContext!
    var fake: FakeRemoteProvider!
    var env: CoreEnvironment { context.environment }

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        fake = FakeRemoteProvider()
        fake.setTree(repo: "demo", [
            "": [RemoteItem(name: "a.txt", kind: .file, size: 1), RemoteItem(name: "src", kind: .directory)],
            "src": [RemoteItem(name: "b.txt", kind: .file, size: 1)],
        ])
        _ = try sandbox.createDirectory("dest")
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = try sandbox.createDirectory("state")
        context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root, remoteProviders: [WebURLProvider(base: fake)]),
                            options: options)
        _ = await env.start()
    }

    override func tearDown() async throws { context = nil }

    private func url(_ path: String...) -> URL { RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: path).url }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), file: StaticString = #filePath,
                           line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for: \(what)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testCopyIntoALocalFolderDownloadsThenCopiesAndCleansStaging() async throws {
        let dest = sandbox.url("dest")
        let task = try XCTUnwrap(RemoteTransfer.copy([url("a.txt"), url("src")], into: dest, environment: env, origin: nil))
        let ok = await task.value
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: dest.appending(path: "a.txt"), encoding: .utf8), "content of a.txt")
        XCTAssertEqual(try String(contentsOf: dest.appending(path: "src/b.txt"), encoding: .utf8), "content of src/b.txt")
        let staging = env.statePaths.root.appending(path: "remote-staging")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []
        XCTAssertEqual(left, [], "staging folder removed after the copy")
        XCTAssertTrue(env.operations.jobs.isEmpty)
    }

    func testCopyIntoARemoteFolderIsRefused() {
        XCTAssertNil(RemoteTransfer.copy([url("a.txt")], into: url("src"), environment: env, origin: nil))
    }

    func testPromiseProviderCarriesTheRemoteURLForInAppDrops() {
        let promise = RemoteFilePromiseProvider(remoteURL: url("a.txt"), fileType: "public.plain-text",
                                                delegate: RemoteFilePromiseDelegate(environment: env))
        let board = NSPasteboard(name: NSPasteboard.Name("macx-tests-\(UUID().uuidString)"))
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([promise])
        XCTAssertEqual(RemoteItemsPasteboard.read(board), [url("a.txt")])
    }

    func testCopyCommandInARemoteFolderWritesRemoteItemsAndWebURLs() async throws {
        let browser = BrowserWindowController(context: context, initialURL: url())
        addTeardownBlock { @MainActor in browser.close() }
        let m = browser.session.folder
        await waitUntil("loaded") { m.isRemote && m.state == .complete }
        m.select(.names(["a.txt"]))
        let commands = FileCommandController(context: context, window: browser)
        commands.perform(.copy, target: .contentSelection(m), sender: nil)
        XCTAssertEqual(env.clipboard.remoteItems, [url("a.txt")])
        XCTAssertEqual(env.clipboard.backend.readString(), "https://fake.example/demo/main/a.txt")
        commands.perform(.copyAsPath, target: .contentSelection(m), sender: nil)
        XCTAssertEqual(env.clipboard.backend.readString(), "https://fake.example/demo/main/a.txt")
        commands.perform(.copyName, target: .contentSelection(m), sender: nil)
        XCTAssertEqual(env.clipboard.backend.readString(), "a.txt")
    }

    func testCopyCommandWithoutWebURLsWritesDisplayRootPaths() async throws {
        // The plain fake has no web pages: the text flavour falls back to "<display root>/<path>", as Copy as Path does.
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = try sandbox.createDirectory("state-plain")
        let plain = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root, remoteProviders: [fake]), options: options)
        _ = await plain.environment.start()
        let browser = BrowserWindowController(context: plain, initialURL: url())
        addTeardownBlock { @MainActor in browser.close() }
        let m = browser.session.folder
        await waitUntil("loaded") { m.isRemote && m.state == .complete }
        m.select(.names(["a.txt", "src"]))
        FileCommandController(context: plain, window: browser).perform(.copy, target: .contentSelection(m), sender: nil)
        let root = try fake.displayRoot(XCTUnwrap(RemoteLocation(url: url())))
        XCTAssertEqual(Set(plain.environment.clipboard.remoteItems.compactMap(RemoteLocation.init(url:))),
                       Set([url("a.txt"), url("src")].compactMap(RemoteLocation.init(url:))))
        XCTAssertEqual(Set(plain.environment.clipboard.backend.readString()?.components(separatedBy: "\n") ?? []),
                       ["\(root)/a.txt", "\(root)/src"])
    }

    func testFailedDownloadIsReportedAndEndsTheRow() async throws {
        let dest = sandbox.url("dest")
        fake.failNext(.network("offline"))
        var reported: [RemoteTransfer.Failure] = []
        let task = try XCTUnwrap(RemoteTransfer.copy([url("a.txt")], into: dest, environment: env, origin: nil,
                                                     report: { failure, _ in reported.append(failure) }))
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(reported, [RemoteTransfer.Failure(title: "Couldn't download 'a.txt'", detail: "Can't reach Fake (offline)")])
        XCTAssertTrue(env.operations.jobs.isEmpty, "the Downloading row is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appending(path: "a.txt").path(percentEncoded: false)))
    }

    func testCancelledDownloadIsNotReported() async throws {
        var reported: [RemoteTransfer.Failure] = []
        let task = try XCTUnwrap(RemoteTransfer.copy([url("a.txt"), url("src")], into: sandbox.url("dest"), environment: env,
                                                     origin: nil, report: { failure, _ in reported.append(failure) }))
        task.cancel()
        _ = await task.value
        XCTAssertEqual(reported, [])
        XCTAssertTrue(env.operations.jobs.isEmpty)
    }

    func testCancelDuringTheLastFetchCopiesNothingAndCleansStaging() async throws {
        let environment = CoreEnvironment.sandboxed(root: sandbox.root,
                                                    remoteProviders: [CancellingProvider(base: fake, cancelAfter: "src/b.txt")])
        _ = await environment.start()
        let dest = sandbox.url("dest")
        var reported: [RemoteTransfer.Failure] = []
        let task = try XCTUnwrap(RemoteTransfer.copy([url("a.txt"), url("src")], into: dest, environment: environment,
                                                     origin: nil, report: { failure, _ in reported.append(failure) }))
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(reported, [])
        XCTAssertEqual(fake.fetchCount, 2, "the last file was fetched before the cancel was seen")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path(percentEncoded: false)), [],
                       "nothing copied after Cancel")
        let staging = environment.statePaths.root.appending(path: "remote-staging")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []
        XCTAssertEqual(left, [], "staging folder removed although the task was cancelled")
        XCTAssertTrue(environment.operations.jobs.isEmpty)
    }

    func testPasteOfCopiedRemoteItemsIntoALocalFolderDownloadsThem() async throws {
        let remote = BrowserWindowController(context: context, initialURL: url())
        addTeardownBlock { @MainActor in remote.close() }
        let m = remote.session.folder
        await waitUntil("loaded") { m.isRemote && m.state == .complete }
        m.select(.names(["a.txt", "src"]))
        FileCommandController(context: context, window: remote).perform(.copy, target: .contentSelection(m), sender: nil)
        XCTAssertEqual(Set(env.clipboard.remoteItems.compactMap(RemoteLocation.init(url:))),
                       Set([url("a.txt"), url("src")].compactMap(RemoteLocation.init(url:))))

        let dest = sandbox.url("dest")
        let local = BrowserWindowController(context: context, initialURL: dest)
        addTeardownBlock { @MainActor in local.close() }
        let folder = local.session.folder
        await waitUntil("local loaded") { folder.state == .complete }
        FileCommandController(context: context, window: local).perform(.paste, target: .currentFolder(folder), sender: nil)
        await waitUntil("downloaded and copied") {
            FileManager.default.fileExists(atPath: dest.appending(path: "src/b.txt").path(percentEncoded: false))
                && FileManager.default.fileExists(atPath: dest.appending(path: "a.txt").path(percentEncoded: false))
        }
        XCTAssertEqual(try String(contentsOf: dest.appending(path: "a.txt"), encoding: .utf8), "content of a.txt")
    }

    func testOpenOnProviderMenuOpensTheItemsWebPages() async throws {
        let browser = BrowserWindowController(context: context, initialURL: url())
        addTeardownBlock { @MainActor in browser.close() }
        let m = browser.session.folder
        await waitUntil("loaded") { m.isRemote && m.state == .complete }
        let row = try XCTUnwrap(m.row(named: "a.txt"))
        let menu = ContextMenuBuilder(context: context)
            .itemMenu(for: IndexSet(integer: row), in: m, handler: FileCommandController(context: context, window: browser))
        let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "macx.menu.openOnProvider" })
        XCTAssertEqual(item.title, "Open on Fake")
        RecordingURLOpener.shared.reset()
        addTeardownBlock { @MainActor in RecordingURLOpener.shared.reset() }
        RemoteMenuTarget.shared.open(item)
        XCTAssertEqual(RecordingURLOpener.shared.opened, [URL(string: "https://fake.example/demo/main/a.txt")!])
    }
}
