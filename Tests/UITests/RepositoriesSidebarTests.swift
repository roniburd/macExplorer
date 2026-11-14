import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFixtures
import MacxPluginKit

/// The REPOSITORIES sidebar section (spec §4.6): recent and favorited repositories, grouped by provider then name.
/// Sandbox files only; the providers are in-memory fakes.
@MainActor
final class RepositoriesSidebarTests: XCTestCase {
    func testRowsMergeRecentsAndFavoritesGroupedByProviderThenName() {
        let gh = FakeRemoteProvider(id: "test.a", displayName: "Alpha"), other = FakeRemoteProvider(id: "test.b", displayName: "Beta")
        let registry = ProviderRegistry(builtIns: [gh, other])
        func root(_ p: String, _ r: String) -> URL { RemoteLocation(provider: p, repo: r).url }
        let favorites = [FavoritesResolver.makeRemoteFavorite(url: RemoteLocation(provider: "test.b", repo: "z/z", ref: "main", path: ["d"]).url, displayName: "d")]
        let rows = RepositoryRows.rows(recent: [root("test.b", "m/m").absoluteString, root("test.a", "y/y").absoluteString,
                                                root("test.a", "b/b").absoluteString],
                                       favorites: favorites, registry: registry)
        XCTAssertEqual(rows, [root("test.a", "b/b"), root("test.a", "y/y"), root("test.b", "m/m"), root("test.b", "z/z")])
    }

    func testRowsSkipProvidersThatAreNotLoaded() {
        let rows = RepositoryRows.rows(recent: [RemoteLocation(provider: "gone.plugin", repo: "a/b").url.absoluteString],
                                       favorites: [], registry: ProviderRegistry(builtIns: []))
        XCTAssertEqual(rows, [])
    }

    func testRemoteLastLocationReachesTheInitialWindowPlan() {
        // Task 5 made restore and lastLocation remote-aware; the startup plan must pass the URL through untouched.
        let url = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["src"]).url
        XCTAssertEqual(InitialWindows.plan(root: nil, hasRestoredWindows: false, startup: .lastLocation, lastLocation: url,
                                           home: URL(filePath: "/tmp/h")), .open(url))
    }

    func testSectionHeaderOnlyWithRows() async throws {
        _ = NSApplication.shared
        let sandbox = try Sandbox()
        addTeardownBlock { sandbox.destroy() }
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = try sandbox.createDirectory("state")
        options.pasteboardName = "macx-tests-\(UUID().uuidString)"
        let fake = FakeRemoteProvider()
        let context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root, remoteProviders: [fake]), options: options)
        let session = BrowserSession(environment: context.environment, initialURL: sandbox.root)
        let sidebar = SidebarViewController(context: context, session: session)
        _ = sidebar.view
        addTeardownBlock { @MainActor in sidebar.close(); session.close() }
        XCTAssertFalse(sidebar.sectionHeaders.contains(.repositories))
        let demo = RemoteLocation(provider: "test.fake", repo: "demo").url
        context.environment.settings.addRecentRepository(RemoteLocation(provider: "test.fake", repo: "demo", ref: "dev", path: ["src"]).url)
        let deadline = ContinuousClock.now + .seconds(10)
        while !sidebar.sectionHeaders.contains(.repositories), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sidebar.sectionHeaders.contains(.repositories))
        XCTAssertEqual(sidebar.children(of: .repositoriesHeader), [.repository(demo)])
        let row = sidebar.row(of: .repository(demo))
        XCTAssertGreaterThanOrEqual(row, 0, "the row is in the outline")
        let cell = try XCTUnwrap(sidebar.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        XCTAssertEqual(cell.textField?.stringValue, "demo", "the provider's display root")
    }

    func testRemoteFavoritesAreDroppedThroughTheProviderAndShownInSandboxMode() async throws {
        _ = NSApplication.shared
        let sandbox = try Sandbox()
        addTeardownBlock { sandbox.destroy() }
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = try sandbox.createDirectory("state")
        options.pasteboardName = "macx-tests-\(UUID().uuidString)"
        let fake = FakeRemoteProvider(tree: ["main": ["": [RemoteItem(name: "src", kind: .directory),
                                                           RemoteItem(name: "a.txt", kind: .file, size: 3)],
                                                      "src": []]])
        let context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root, remoteProviders: [fake]), options: options)
        let session = BrowserSession(environment: context.environment, initialURL: sandbox.root)
        let sidebar = SidebarViewController(context: context, session: session)
        _ = sidebar.view
        addTeardownBlock { @MainActor in sidebar.close(); session.close() }
        func url(_ path: String...) -> URL { RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: path).url }
        let added = await sidebar.favorites.addRemote([url("src"), url("a.txt"), url("src")], atUserIndex: 0)
        XCTAssertEqual(added, 1, "folders only, no duplicates")
        XCTAssertEqual(context.environment.settings.favorites.map(\.remoteURL), [url("src").absoluteString])
        let again = await sidebar.favorites.addRemote([url("src")], atUserIndex: 0)
        XCTAssertEqual(again, 0, "already a favorite")
        let deadline = ContinuousClock.now + .seconds(10)
        func favoriteURLs() -> [URL] { sidebar.favorites.rows.filter { $0.defaultKind == nil }.compactMap(\.url) }
        while favoriteURLs().isEmpty || !sidebar.sectionHeaders.contains(.repositories), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(favoriteURLs(), [url("src")], "a remote favorite isn't confined to the sandbox root")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macx-tests-\(UUID().uuidString)"))
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let dragged = NSPasteboardItem()
        dragged.setString(url("src").absoluteString, forType: RemoteItemsPasteboard.type)
        pasteboard.writeObjects([dragged])
        XCTAssertEqual(sidebar.favoritesDropOperation(pasteboard, childIndex: 0), .link, "dragged remote items add favorites")
        XCTAssertEqual(sidebar.children(of: .repositoriesHeader), [.repository(RemoteLocation(provider: "test.fake", repo: "demo").url)])
    }

    func testRemoteSidebarRowsDisableLocalAndMutatingCommandsInALocalWindow() throws {
        let sandbox = try Sandbox()
        addTeardownBlock { sandbox.destroy() }
        let environment = CoreEnvironment.sandboxed(root: sandbox.root, remoteProviders: [FakeRemoteProvider()])
        let session = BrowserSession(environment: environment, initialURL: sandbox.root)   // a local folder
        addTeardownBlock { @MainActor in session.close() }
        let repo = RemoteLocation(provider: "test.fake", repo: "owner/repo").url
        let favorite = ResolvedFavorite(favorite: FavoritesResolver.makeRemoteFavorite(url: repo, displayName: "repo"),
                                        url: repo, isStale: false)
        let rows: [(SidebarItem, FocusContext)] = [(.repository(repo), .sidebarLocations),
                                                    (.favorite(SidebarFavorite(resolved: favorite)), .sidebarFavorites)]
        for (item, focus) in rows {
            XCTAssertEqual(item.focusContext, focus)
            var state = CommandStateBuilder.state(for: item.commandTarget, session: session, environment: environment,
                                                  previewPaneVisible: false)
            state.canPaste = true   // something is on the clipboard
            XCTAssertTrue(state.targetIsRemote, "\(item)")
            for c: Command in [.paste, .moveItemHere, .properties, .openInTerminal, .revealInFinder, .share,
                               .copyPathTilde, .copyPathFileURL, .copyPathShellQuoted] {
                XCTAssertFalse(CommandAvailability.isEnabled(c, focus: focus, state: state), "\(c) on \(item)")
            }
            for c: Command in [.open, .copy, .copyAsPath] {
                XCTAssertTrue(CommandAvailability.isEnabled(c, focus: focus, state: state), "\(c) on \(item)")
            }
        }
        let local = CommandStateBuilder.state(for: .location(sandbox.root), session: session, environment: environment,
                                              previewPaneVisible: false)
        XCTAssertFalse(local.targetIsRemote, "a local row is not gated")
    }
}
