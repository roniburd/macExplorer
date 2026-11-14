import XCTest
import AppKit
@testable import UI
import Core
import MacxFixtures
import MacxPluginKit

@MainActor
final class RefChipTests: XCTestCase {
    private let refs = [RemoteRef(name: "v1.0", kind: .tag, commit: nil), RemoteRef(name: "main", kind: .branch, commit: nil),
                        RemoteRef(name: "feature/x", kind: .branch, commit: nil)]

    func testRowsAreBranchesThenTagsFilteredBySubstring() {
        XCTAssertEqual(RefFilter.rows(refs, matching: "").map(\.name), ["main", "feature/x", "v1.0"])
        XCTAssertEqual(RefFilter.rows(refs, matching: "X").map(\.name), ["feature/x"])
        XCTAssertEqual(RefFilter.rows(refs, matching: "zzz"), [])
    }

    func testReturnTakesTheHighlightedRowElseTheTypedText() {
        let rows = RefFilter.rows(refs, matching: "")
        XCTAssertEqual(RefFilter.choice(text: "", rows: rows, selected: 1), "feature/x")
        XCTAssertEqual(RefFilter.choice(text: " 0123abc ", rows: [], selected: nil), "0123abc")
        XCTAssertNil(RefFilter.choice(text: "  ", rows: [], selected: nil))
    }

    func testReturnPrefersAnExactNameOverAListedNameContainingIt() {
        let listed = [RemoteRef(name: "domain", kind: .branch, commit: nil), RemoteRef(name: "main", kind: .branch, commit: nil),
                      RemoteRef(name: "release-2", kind: .tag, commit: nil)]
        let mainRows = RefFilter.rows(listed, matching: "Main")
        XCTAssertEqual(mainRows.map(\.name), ["main", "domain"])
        XCTAssertEqual(RefFilter.highlight(text: "Main", rows: mainRows), 0)
        XCTAssertEqual(RefFilter.choice(text: "Main", rows: mainRows,
                                        selected: RefFilter.highlight(text: "Main", rows: mainRows)), "main")
        let releaseRows = RefFilter.rows(listed, matching: "release")
        XCTAssertNil(RefFilter.highlight(text: "release", rows: releaseRows))
        XCTAssertEqual(RefFilter.choice(text: "release", rows: releaseRows, selected: nil), "release")
        XCTAssertNil(RefFilter.highlight(text: "ma", rows: RefFilter.rows(listed, matching: "ma")))
        XCTAssertNil(RefFilter.highlight(text: "", rows: RefFilter.rows(listed, matching: "")))
    }

    func testTheChipShowsTheRefAndShortensASHA() {
        let chip = RefChipController()
        let fake = FakeRemoteProvider(tree: [:])
        chip.show(location: RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: []), provider: fake)
        XCTAssertEqual(chip.button.title, "main ▾")
        chip.show(location: RemoteLocation(provider: "test.fake", repo: "demo",
                                           ref: "0123456789abcdef0123456789abcdef01234567", path: []), provider: fake)
        XCTAssertEqual(chip.button.title, "0123456 ▾")
        XCTAssertEqual(chip.button.accessibilityIdentifier(), AXID.refChip)
    }

    func testARemoteFolderShowsTheChipAndChoosingARefNavigates() async throws {
        let h = try await ShellHarness.make(self)
        let fake = AddressResolverRemoteTestsFixture.demo()
        fake.refs = [RemoteRef(name: "main", kind: .branch, commit: nil), RemoteRef(name: "dev", kind: .branch, commit: nil)]
        _ = h.environment.remote.register([fake], source: "test")
        let controller = try await h.openWindow()
        let src = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["src"])
        controller.session.navigate(to: src.url)
        try await h.waitUntil("remote loaded") { controller.session.folder.state == .complete }
        let bar = controller.addressBar
        XCTAssertEqual(bar.breadcrumb.segmentButtons.map(\.title), ["demo", "src"])
        XCTAssertTrue(bar.breadcrumb.accessoryAfterRoot === bar.refChip.button)
        bar.refChip.onChoose?("dev")
        try await h.waitUntil("switched ref") {
            controller.session.folder.directory == src.withRef("dev").url && controller.session.folder.state == .complete
        }
        controller.session.navigate(to: URL(filePath: h.filesRoot.path(percentEncoded: false), directoryHint: .isDirectory))
        try await h.waitUntil("local again") { controller.session.folder.state == .complete }
        XCTAssertNil(bar.breadcrumb.accessoryAfterRoot, "local folders have no chip")
    }

    func testAStaleRefSwitchDoesNotNavigateOnceTheBarMovedOn() async throws {
        let h = try await ShellHarness.make(self)
        let fake = AddressResolverRemoteTestsFixture.demo()
        fake.refs = [RemoteRef(name: "main", kind: .branch, commit: nil), RemoteRef(name: "dev", kind: .branch, commit: nil),
                     RemoteRef(name: "next", kind: .branch, commit: nil)]
        _ = h.environment.remote.register([fake], source: "test")
        let controller = try await h.openWindow()
        let src = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["src"])
        controller.session.navigate(to: src.url)
        try await h.waitUntil("remote loaded") { controller.session.folder.state == .complete }
        let bar = controller.addressBar
        var navigated: [URL] = []
        bar.onNavigate = { url, _ in navigated.append(url) }
        // A second choice supersedes the first; only the last one may navigate.
        bar.refChip.onChoose?("dev")
        bar.refChip.onChoose?("next")
        try await h.waitUntil("last choice navigated") { !navigated.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(navigated, [RemoteLocation(provider: "test.fake", repo: "demo", ref: "next", path: []).url], "no src in next: the switch lands on its root")
        // Moving to another folder before the switch resolves drops it.
        navigated = []
        bar.refChip.onChoose?("dev")
        bar.show(RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: []).url, volume: nil)
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(navigated, [])
    }

    func testRemoteSubfolderMenusListThroughTheProvider() async throws {
        let h = try await ShellHarness.make(self)
        _ = h.environment.remote.register([AddressResolverRemoteTestsFixture.demo()], source: "test")
        let url = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: []).url
        let names = await SubfolderLister.list(url, readers: h.environment.readers, remote: h.environment.remote,
                                               showHidden: false)
        XCTAssertEqual(names, ["src"])
    }

    func testRefreshInvalidatesTheProviderBeforeReading() async throws {
        let h = try await ShellHarness.make(self)
        let fake = AddressResolverRemoteTestsFixture.demo()
        _ = h.environment.remote.register([fake], source: "test")
        let controller = try await h.openWindow()
        controller.session.navigate(to: RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: []).url)
        try await h.waitUntil("remote loaded") { controller.session.folder.state == .complete }
        controller.session.reload()
        XCTAssertEqual(fake.invalidations.map(\.repo), ["demo"])
        XCTAssertEqual(fake.invalidations.map(\.ref), ["main"])
    }
}
