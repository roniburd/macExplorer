import XCTest
import AppKit
import Synchronization
@testable import UI
import Core
import MacxFixtures
import MacxPluginKit

/// Holds the calls it gates until `open()`: a slow network, on demand.
final class RemoteGate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// FakeRemoteProvider whose resolveRef, and listings of `gatedRef`, wait for their gates.
struct GatedProvider: RemoteProvider {
    let base: FakeRemoteProvider
    var resolveGate: RemoteGate?
    var listGate: RemoteGate?
    var gatedRef: String?
    var id: String { base.id }
    var displayName: String { base.displayName }
    var iconSymbol: String { base.iconSymbol }
    func parseAddress(_ text: String) -> RemoteLocation? { base.parseAddress(text) }
    func completions(for text: String) async -> [String] { await base.completions(for: text) }
    func displayRoot(_ location: RemoteLocation) -> String { base.displayRoot(location) }
    func webURL(_ l: RemoteLocation) -> URL? { nil }
    func listRefs(repo: String) async throws(RemoteError) -> [RemoteRef] { try await base.listRefs(repo: repo) }
    func resolveRef(_ location: RemoteLocation) async throws(RemoteError) -> RemoteLocation {
        await resolveGate?.wait()
        return try await base.resolveRef(location)
    }
    func list(_ location: RemoteLocation) -> AsyncThrowingStream<[RemoteItem], any Error> {
        guard let listGate, gatedRef == nil || location.ref == gatedRef else { return base.list(location) }
        let base = self.base
        return AsyncThrowingStream { continuation in
            Task {
                await listGate.wait()
                do {
                    for try await chunk in base.list(location) { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    func fetch(_ location: RemoteLocation, item: RemoteItem, to destination: URL) async throws(RemoteError) {
        try await base.fetch(location, item: item, to: destination)
    }
    func invalidate(repo: String, ref: String?) { base.invalidate(repo: repo, ref: ref) }
}

@MainActor
final class RemoteActivityTests: XCTestCase {
    private func loc(_ path: [String] = [], ref: String = "main") -> RemoteLocation {
        RemoteLocation(provider: "test.fake", repo: "demo", ref: ref, path: path)
    }

    private func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
    }

    func testATypedRemoteAddressShowsConnectingUntilItResolves() async throws {
        let h = try await ShellHarness.make(self)
        let gate = RemoteGate()
        _ = h.environment.remote.register([GatedProvider(base: AddressResolverRemoteTestsFixture.demo(), resolveGate: gate)],
                                          source: "test")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        XCTAssertNil(bar.activityText, "a local folder shows no activity")
        let submit = Task { await bar.submitForTesting("fake:demo@main/src") }
        try await h.waitUntil("connecting shows") { bar.activityText == "Connecting to demo…" }
        XCTAssertTrue(bar.activitySpinner.superview?.isHidden == false)
        gate.open()
        await submit.value
        try await h.waitUntil("remote folder loaded") {
            controller.session.folder.directory == self.loc(["src"]).url && controller.session.folder.state == .complete
        }
        try await h.waitUntil("activity ends") { bar.activityText == nil }
    }

    func testEscWhileConnectingClearsTheActivity() async throws {
        let h = try await ShellHarness.make(self)
        let gate = RemoteGate()
        _ = h.environment.remote.register([GatedProvider(base: AddressResolverRemoteTestsFixture.demo(), resolveGate: gate)],
                                          source: "test")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        let submit = Task { await bar.submitForTesting("fake:demo") }
        try await h.waitUntil("connecting shows") { bar.activityText == "Connecting to demo…" }
        bar.cancelEditing()
        XCTAssertNil(bar.activityText)
        gate.open()
        await submit.value
        XCTAssertNil(bar.activityText)
    }

    func testARefSwitchShowsSwitchingUntilTheNewRefHasLoaded() async throws {
        let h = try await ShellHarness.make(self)
        let gate = RemoteGate()
        _ = h.environment.remote.register([GatedProvider(base: AddressResolverRemoteTestsFixture.demo(), listGate: gate,
                                                         gatedRef: "dev")], source: "test")
        let controller = try await h.openWindow()
        controller.session.navigate(to: loc(["src"]).url)
        try await h.waitUntil("remote loaded") { controller.session.folder.state == .complete }
        let bar = controller.addressBar
        try await h.waitUntil("no activity once listed") { bar.activityText == nil }
        bar.refChip.onChoose?("dev")
        XCTAssertEqual(bar.activityText, "Switching to dev…")
        try await settle()
        XCTAssertEqual(bar.activityText, "Switching to dev…", "still resolving the ref")
        gate.open()
        try await h.waitUntil("switched ref") {
            controller.session.folder.directory == self.loc(["src"], ref: "dev").url
                && controller.session.folder.state == .complete
        }
        try await h.waitUntil("activity ends") { bar.activityText == nil }
    }

    func testChoosingTheCurrentRefEndsTheSwitchAtOnce() async throws {
        let h = try await ShellHarness.make(self)
        _ = h.environment.remote.register([AddressResolverRemoteTestsFixture.demo()], source: "test")
        let controller = try await h.openWindow()
        controller.session.navigate(to: loc(["src"]).url)
        try await h.waitUntil("remote loaded") { controller.session.folder.state == .complete }
        let bar = controller.addressBar
        bar.refChip.onChoose?("main")
        try await h.waitUntil("activity ends") { bar.activityText == nil }
    }

    func testASlowRemoteListingShowsLoadingAfterTheDelay() async throws {
        let h = try await ShellHarness.make(self)
        let gate = RemoteGate()
        _ = h.environment.remote.register([GatedProvider(base: AddressResolverRemoteTestsFixture.demo(), listGate: gate)],
                                          source: "test")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        controller.session.navigate(to: loc(["src"]).url)
        XCTAssertNil(bar.activityText, "not before the delay")
        try await h.waitUntil("loading shows") { bar.activityText == "Loading…" }
        gate.open()
        try await h.waitUntil("remote loaded") { controller.session.folder.state == .complete }
        try await h.waitUntil("activity ends") { bar.activityText == nil }
    }

    func testTheRefChipPrefetchesSoThePickerOpensFilled() async throws {
        let h = try await ShellHarness.make(self)
        let fake = AddressResolverRemoteTestsFixture.demo()
        fake.refs = [RemoteRef(name: "main", kind: .branch, commit: nil), RemoteRef(name: "dev", kind: .branch, commit: nil)]
        _ = h.environment.remote.register([fake], source: "test")
        let controller = try await h.openWindow()
        controller.session.navigate(to: loc(["src"]).url)
        let chip = controller.addressBar.refChip
        try await h.waitUntil("refs prefetched") { chip.cachedRefs != nil }
        XCTAssertEqual(fake.calls.filter { $0 == "refs demo" }.count, 1, "listed once, before any click")
        // Another folder in the same repository reuses the list.
        controller.session.navigate(to: loc().url)
        try await h.waitUntil("root loaded") {
            controller.session.folder.directory == self.loc().url && controller.session.folder.state == .complete
        }
        XCTAssertEqual(fake.calls.filter { $0 == "refs demo" }.count, 1)
        chip.openPicker()
        XCTAssertEqual(chip.picker.refs.map(\.name), ["main", "dev"], "the cached list shows at once")
        XCTAssertEqual(chip.picker.status.stringValue, "")
        try await h.waitUntil("refreshed on open") { fake.calls.filter { $0 == "refs demo" }.count == 2 }
    }

    func testAFailedPrefetchIsRetriedWhenThePickerOpens() async throws {
        let h = try await ShellHarness.make(self)
        let fake = AddressResolverRemoteTestsFixture.demo()
        fake.refs = [RemoteRef(name: "main", kind: .branch, commit: nil)]
        _ = h.environment.remote.register([fake], source: "test")
        let controller = try await h.openWindow()
        let chip = controller.addressBar.refChip
        fake.failure = .network("offline")
        chip.show(location: loc(), provider: fake)
        try await h.waitUntil("prefetch tried") { fake.calls.contains("refs demo") }
        try await settle()
        XCTAssertNil(chip.cachedRefs)
        fake.failure = nil
        chip.openPicker()
        XCTAssertEqual(chip.picker.status.stringValue, "Loading…")
        try await h.waitUntil("listed on open") { chip.picker.refs.map(\.name) == ["main"] }
    }
}
