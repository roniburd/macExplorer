import Foundation
import MacxFS
import Synchronization
import XCTest
@testable import Core

private let textEdit = AppInfo(url: URL(filePath: "/System/Applications/TextEdit.app"), name: "TextEdit",
                               bundleIdentifier: "com.apple.TextEdit")
private let other = AppInfo(url: URL(filePath: "/Applications/Other.app"), name: "Other", bundleIdentifier: nil)

/// A provider whose lookups wait until the test opens the gate, so in-flight behaviour can be observed.
private final class GatedProvider: LaunchServicesProviding {
    private struct State {
        var open = false
        var apps: [AppInfo] = [textEdit]
        var defaultApp: AppInfo? = textEdit
        var appLookups = 0
        var defaultLookups = 0
        var rescued = false
    }
    private let state = Mutex(State())

    func setOpen(_ open: Bool) { state.withLock { $0.open = open } }
    func setDefault(_ app: AppInfo?) { state.withLock { $0.defaultApp = app } }
    var appLookups: Int { state.withLock { $0.appLookups } }
    var defaultLookups: Int { state.withLock { $0.defaultLookups } }

    /// Watchdog escape hatch: opens the gate and records that something was stuck waiting on it.
    func rescue() { state.withLock { $0.rescued = true; $0.open = true } }
    var rescued: Bool { state.withLock { $0.rescued } }

    private func waitForGate() async {
        while !state.withLock({ $0.open }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func applications(toOpen file: URL) async -> [AppInfo] {
        state.withLock { $0.appLookups += 1 }
        await waitForGate()
        return state.withLock { $0.apps }
    }
    func defaultApplication(toOpen file: URL) async -> AppInfo? {
        state.withLock { $0.defaultLookups += 1 }
        await waitForGate()
        return state.withLock { $0.defaultApp }
    }
    func appInfo(at appURL: URL) async -> AppInfo? { nil }
    func open(_ files: [URL]) async throws {}
    func open(_ files: [URL], withApplicationAt app: URL) async throws {}
    func setDefaultApplication(_ app: URL, forContentTypeOf file: URL) async throws {}
    func setDefaultApplication(_ app: URL, forFile file: URL) async throws {}
    func revealInFinder(_ urls: [URL]) async {}
}

/// A manual time source for the cache: time only moves when a test advances it, so entry expiry never depends on
/// how quickly a (possibly loaded) runner gets through the test's polling.
@MainActor
private final class TestClock {
    private(set) var now = ContinuousClock.now
    func advance(by duration: Duration) { now += duration }
}

@MainActor
final class LaunchServicesCacheTests: XCTestCase {
    private let types = TypeRegistry()
    private var txt: UInt16 { types.index(forExtension: "txt", isDirectory: false) }
    private var md: UInt16 { types.index(forExtension: "md", isDirectory: false) }
    private let fileA = URL(filePath: "/tmp/macx-none/a.txt")
    private let fileB = URL(filePath: "/tmp/macx-none/b.txt")

    private func eventually(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("timed out waiting for \(what)"); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testMissReturnsNilThenObserversFireWhenTheFetchLands() async {
        let fake = FakeLaunchServices(apps: [textEdit, other], defaultApp: textEdit)
        let cache = LaunchServicesCache(provider: fake, types: types)
        var notified: [URL] = []
        let token = cache.observe { notified.append($0) }
        XCTAssertNil(cache.cachedApplications(for: fileA, typeIndex: txt))
        XCTAssertTrue(cache.cachedDefault(for: fileA) == nil)
        await eventually("both lookups") {
            cache.cachedApplications(for: fileA, typeIndex: txt) != nil && cache.cachedDefault(for: fileA) != nil
        }
        XCTAssertEqual(cache.cachedApplications(for: fileA, typeIndex: txt), [textEdit, other])
        XCTAssertEqual(cache.cachedDefault(for: fileA), .some(textEdit))
        XCTAssertTrue(notified.contains(fileA))
        XCTAssertTrue(notified.allSatisfy { $0 == fileA })
        token.cancel()
    }

    func testKnownNoDefaultIsSomeNil() async {
        let cache = LaunchServicesCache(provider: FakeLaunchServices(apps: [other], defaultApp: nil), types: types)
        cache.prefetch(file: fileA, typeIndex: txt)
        await eventually("default lookup") { cache.cachedDefault(for: fileA) != nil }
        let value = cache.cachedDefault(for: fileA)
        guard case .some(.none) = value else { return XCTFail("expected .some(nil), got \(String(describing: value))") }
    }

    func testApplicationsAreSharedPerTypeAndLookedUpOnce() async {
        let fake = FakeLaunchServices(apps: [textEdit], defaultApp: textEdit)
        let cache = LaunchServicesCache(provider: fake, types: types)
        cache.prefetch(file: fileA, typeIndex: txt)
        await eventually("apps") { cache.cachedApplications(for: fileA, typeIndex: txt) != nil }
        XCTAssertEqual(cache.cachedApplications(for: fileB, typeIndex: txt), [textEdit], "same UTType: hit for another file")
        XCTAssertEqual(fake.applicationLookups(), [fileA])
        XCTAssertNil(cache.cachedApplications(for: fileA, typeIndex: md), "another type is a separate entry")
    }

    func testDefaultIsPerFile() async {
        let fake = FakeLaunchServices(apps: [textEdit, other], defaultApp: textEdit)
        try? await fake.setDefaultApplication(other.url, forFile: fileB)
        let cache = LaunchServicesCache(provider: fake, types: types)
        cache.prefetch(file: fileA, typeIndex: txt)
        cache.prefetch(file: fileB, typeIndex: txt)
        await eventually("defaults") { cache.cachedDefault(for: fileA) != nil && cache.cachedDefault(for: fileB) != nil }
        XCTAssertEqual(cache.cachedDefault(for: fileA), .some(textEdit))
        XCTAssertEqual(cache.cachedDefault(for: fileB), .some(other), "per-file override honoured")
    }

    func testRepeatedMissesWhileInFlightIssueOneLookup() async {
        let provider = GatedProvider()
        let cache = LaunchServicesCache(provider: provider, types: types)
        for _ in 0..<5 {
            XCTAssertNil(cache.cachedApplications(for: fileA, typeIndex: txt))
            XCTAssertTrue(cache.cachedDefault(for: fileA) == nil)
            cache.prefetch(file: fileA, typeIndex: txt)
        }
        XCTAssertNil(cache.cachedApplications(for: fileB, typeIndex: txt))
        await eventually("lookups started") { provider.appLookups == 1 && provider.defaultLookups == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(provider.appLookups, 1)
        XCTAssertEqual(provider.defaultLookups, 1)
        var notified: Set<URL> = []
        let token = cache.observe { notified.insert($0) }
        provider.setOpen(true)
        await eventually("landed") { cache.cachedDefault(for: fileA) != nil }
        await eventually("both waiters notified") { notified.isSuperset(of: [fileA, fileB]) }
        XCTAssertEqual(provider.appLookups, 1, "the waiters shared the one lookup")
        XCTAssertEqual(provider.defaultLookups, 1, "the waiters shared the one lookup")
        token.cancel()
    }

    func testMenuRebuildNeverBlocksOnAHungProvider() {
        let provider = GatedProvider()   // never opened by the test
        let cache = LaunchServicesCache(provider: provider, types: types)
        // If a lookup ever made the caller wait for the provider, this loop would hang forever on the closed gate.
        // The watchdog turns such a hang into a failure (it releases the gate and records that it had to); a cache
        // that never waits finishes the loop with the gate still closed, however slow the runner is.
        let watchdog = DispatchWorkItem { provider.rescue() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        for _ in 0..<100 {
            XCTAssertNil(cache.cachedApplications(for: fileA, typeIndex: txt), "a miss while the provider hangs")
            XCTAssertTrue(cache.cachedDefault(for: fileA) == nil, "a miss while the provider hangs")
        }
        watchdog.cancel()
        XCTAssertFalse(provider.rescued, "a cache lookup waited on the hung provider")
        // No wall-clock budget: a loaded runner can preempt main for any length of time. Finishing 200 calls with the
        // gate still closed (and the watchdog never needed) is the proof that no call waited on the provider.
        provider.setOpen(true)
    }

    func testInvalidateDropsTheFileDefaultAndRefetches() async {
        let fake = FakeLaunchServices(apps: [textEdit, other], defaultApp: textEdit)
        let cache = LaunchServicesCache(provider: fake, types: types)
        cache.prefetch(file: fileA, typeIndex: txt)
        await eventually("default") { cache.cachedDefault(for: fileA) != nil }
        try? await fake.setDefaultApplication(other.url, forFile: fileA)
        XCTAssertEqual(cache.cachedDefault(for: fileA), .some(textEdit), "still cached until invalidated")
        cache.invalidate(file: fileA)
        XCTAssertTrue(cache.cachedDefault(for: fileA) == nil, "a miss after invalidate")
        await eventually("refetched") { cache.cachedDefault(for: fileA) == .some(other) }
        XCTAssertEqual(fake.defaultLookups().count, 2)
    }

    func testInvalidateMarksTheTypeStaleAndRefreshesInTheBackground() async {
        let fake = FakeLaunchServices(apps: [textEdit], defaultApp: textEdit)
        let cache = LaunchServicesCache(provider: fake, types: types)
        cache.prefetch(file: fileA, typeIndex: txt)
        await eventually("apps") { cache.cachedApplications(for: fileA, typeIndex: txt) != nil }
        fake.setApplications([textEdit, other])
        cache.invalidate(file: fileA)
        XCTAssertEqual(cache.cachedApplications(for: fileA, typeIndex: txt), [textEdit], "stale value still served")
        await eventually("refreshed") { cache.cachedApplications(for: fileA, typeIndex: txt) == [textEdit, other] }
        XCTAssertEqual(fake.applicationLookups().count, 2)
    }

    func testInvalidateDropsOtherFileDefaultsOfTheSameType() async {
        let fake = FakeLaunchServices(apps: [textEdit, other], defaultApp: textEdit)
        let cache = LaunchServicesCache(provider: fake, types: types)
        cache.prefetch(file: fileA, typeIndex: txt)
        cache.prefetch(file: fileB, typeIndex: txt)
        await eventually("defaults") { cache.cachedDefault(for: fileA) != nil && cache.cachedDefault(for: fileB) != nil }
        cache.invalidate(file: fileA)   // e.g. "Change All…" for .txt
        XCTAssertTrue(cache.cachedDefault(for: fileB) == nil)
    }

    func testResultInFlightDuringInvalidateIsDiscarded() async {
        let provider = GatedProvider()
        let cache = LaunchServicesCache(provider: provider, types: types)
        XCTAssertTrue(cache.cachedDefault(for: fileA) == nil)
        await eventually("lookup started") { provider.defaultLookups == 1 }
        cache.invalidate(file: fileA)                 // the default changed while the old lookup was running
        provider.setDefault(other)
        provider.setOpen(true)
        await eventually("fresh value") { cache.cachedDefault(for: fileA) == .some(other) }
        XCTAssertEqual(provider.defaultLookups, 2)
    }

    func testDefaultExpiresAfterItsLifetime() async {
        let fake = FakeLaunchServices(apps: [textEdit], defaultApp: textEdit)
        let clock = TestClock()
        let cache = LaunchServicesCache(provider: fake, types: types, now: { clock.now })
        cache.defaultLifetime = .milliseconds(50)
        cache.prefetch(file: fileA, typeIndex: txt)
        await eventually("default") { cache.cachedDefault(for: fileA) != nil }
        XCTAssertEqual(fake.defaultLookups().count, 1)
        clock.advance(by: .milliseconds(50))
        XCTAssertEqual(cache.cachedDefault(for: fileA), .some(textEdit), "still valid at exactly its lifetime")
        clock.advance(by: .milliseconds(30))
        XCTAssertTrue(cache.cachedDefault(for: fileA) == nil, "expired: a miss that refetches")
        await eventually("refetched") { cache.cachedDefault(for: fileA) != nil }
        XCTAssertEqual(fake.defaultLookups().count, 2, "the miss caused exactly one refetch")
    }

    func testStaleApplicationsAreServedAndRefreshedInTheBackground() async {
        let fake = FakeLaunchServices(apps: [textEdit], defaultApp: textEdit)
        let clock = TestClock()
        let cache = LaunchServicesCache(provider: fake, types: types, now: { clock.now })
        cache.applicationsLifetime = .milliseconds(50)
        cache.prefetch(file: fileA, typeIndex: txt)
        await eventually("apps") { cache.cachedApplications(for: fileA, typeIndex: txt) != nil }
        fake.setApplications([other])
        clock.advance(by: .milliseconds(50))
        XCTAssertEqual(cache.cachedApplications(for: fileA, typeIndex: txt), [textEdit], "fresh at exactly its lifetime")
        XCTAssertEqual(fake.applicationLookups().count, 1, "no refresh while still fresh")
        clock.advance(by: .milliseconds(30))
        XCTAssertEqual(cache.cachedApplications(for: fileA, typeIndex: txt), [textEdit], "stale hit, never nil")
        await eventually("refreshed") { cache.cachedApplications(for: fileA, typeIndex: txt) == [other] }
        XCTAssertEqual(fake.applicationLookups().count, 2, "the stale hit caused exactly one refresh")
    }

    func testCancelledObserverIsNotCalled() async {
        let cache = LaunchServicesCache(provider: FakeLaunchServices(apps: [textEdit], defaultApp: textEdit), types: types)
        var calls = 0
        let token = cache.observe { _ in calls += 1 }
        token.cancel()
        cache.prefetch(file: fileA, typeIndex: txt)
        await eventually("landed") { cache.cachedDefault(for: fileA) != nil && cache.cachedApplications(for: fileA, typeIndex: txt) != nil }
        XCTAssertEqual(calls, 0)
    }

    func testProviderIsExposed() {
        let fake = FakeLaunchServices()
        let cache = LaunchServicesCache(provider: fake)
        XCTAssertTrue(cache.provider is FakeLaunchServices)
    }
}

final class FakeLaunchServicesTests: XCTestCase {
    private let file = URL(filePath: "/tmp/macx-none/a.custom-ext")

    func testRecordsOpensAndNeverOpensAnything() async throws {
        let fake = FakeLaunchServices()
        try await fake.open([file])
        try await fake.open([file], withApplicationAt: other.url)
        XCTAssertEqual(fake.opened().map(\.files), [[file], [file]])
        XCTAssertEqual(fake.opened().map(\.app), [nil, other.url])
    }

    func testRecordsDefaultsInOrderAndHonoursThem() async throws {
        let fake = FakeLaunchServices(apps: [textEdit, other], defaultApp: textEdit)
        try await fake.setDefaultApplication(other.url, forContentTypeOf: file)
        try await fake.setDefaultApplication(other.url, forFile: file)
        XCTAssertEqual(fake.defaultsSet().map(\.forType), [true, false])
        XCTAssertEqual(fake.defaultsSet().map(\.app), [other.url, other.url])
        XCTAssertEqual(fake.defaultsSet().map(\.file), [file, file])
        let viaFile = await fake.defaultApplication(toOpen: file)
        XCTAssertEqual(viaFile, other)
    }

    func testTypeDefaultAppliesToOtherFilesOfTheSameExtension() async throws {
        let fake = FakeLaunchServices(apps: [textEdit, other], defaultApp: textEdit)
        try await fake.setDefaultApplication(other.url, forContentTypeOf: file)
        let sibling = await fake.defaultApplication(toOpen: URL(filePath: "/tmp/macx-none/b.CUSTOM-EXT"))
        XCTAssertEqual(sibling, other)
        let unrelated = await fake.defaultApplication(toOpen: URL(filePath: "/tmp/macx-none/c.txt"))
        XCTAssertEqual(unrelated, textEdit)
    }

    func testUnknownAppGetsASynthesizedInfo() async throws {
        let fake = FakeLaunchServices()
        let app = URL(filePath: "/Applications/Some Editor.app")
        try await fake.setDefaultApplication(app, forFile: file)
        let info = await fake.defaultApplication(toOpen: file)
        XCTAssertEqual(info?.url, app)
        XCTAssertEqual(info?.name, "Some Editor")
        let unknown = await fake.appInfo(at: app)
        XCTAssertNil(unknown)
        let known = await fake.appInfo(at: textEdit.url)
        XCTAssertNil(known)
        let listed = FakeLaunchServices(apps: [textEdit])
        let found = await listed.appInfo(at: textEdit.url)
        XCTAssertEqual(found, textEdit)
    }

    func testScriptedOpenErrorIsThrownAndStillRecorded() async {
        let fake = FakeLaunchServices()
        fake.setOpenError(CocoaError(.fileNoSuchFile))
        do {
            try await fake.open([file], withApplicationAt: other.url)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
        }
        XCTAssertEqual(fake.opened().count, 1)
    }

    func testRevealIsRecorded() async {
        let fake = FakeLaunchServices()
        await fake.revealInFinder([file])
        XCTAssertEqual(fake.revealed(), [[file]])
        XCTAssertTrue(fake.opened().isEmpty)
    }

    func testAppInfoIdIsItsURL() {
        XCTAssertEqual(textEdit.id, textEdit.url)
    }
}
