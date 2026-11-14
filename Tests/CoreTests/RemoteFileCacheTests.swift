import Foundation
import MacxFixtures
import MacxPluginKit
import Synchronization
import XCTest
@testable import Core

/// A provider whose fetch writes `content` and can be held open until `release()`; counts fetches and records
/// whether a held fetch was cancelled by the time it was released.
final class GatedRemoteProvider: RemoteProvider, Sendable {
    let id = "test.gated"
    let displayName = "Gated"
    let iconSymbol = "shippingbox"
    let content: String
    private let state = Mutex<(fetches: Int, gate: CheckedContinuation<Void, Never>?, held: Bool, failure: RemoteError?,
                               cancelled: Bool)>((0, nil, false, nil, false))

    init(content: String = "0123456789", held: Bool = false) {
        self.content = content
        state.withLock { $0.held = held }
    }
    var fetches: Int { state.withLock { $0.fetches } }
    var sawCancellation: Bool { state.withLock { $0.cancelled } }
    func fail(with error: RemoteError?) { state.withLock { $0.failure = error } }
    func release() {
        let gate = state.withLock { s -> CheckedContinuation<Void, Never>? in s.held = false; defer { s.gate = nil }; return s.gate }
        gate?.resume()
    }

    func parseAddress(_ text: String) -> RemoteLocation? { nil }
    func completions(for text: String) async -> [String] { [] }
    func displayRoot(_ location: RemoteLocation) -> String { location.repo }
    func webURL(_ location: RemoteLocation) -> URL? { nil }
    func listRefs(repo: String) async throws(RemoteError) -> [RemoteRef] { [] }
    func resolveRef(_ location: RemoteLocation) async throws(RemoteError) -> RemoteLocation { location }
    func list(_ location: RemoteLocation) -> AsyncThrowingStream<[RemoteItem], any Error> { AsyncThrowingStream { $0.finish() } }
    func invalidate(repo: String, ref: String?) {}

    func fetch(_ location: RemoteLocation, item: RemoteItem, to destination: URL) async throws(RemoteError) {
        let failure = state.withLock { s -> RemoteError? in s.fetches += 1; return s.failure }
        if state.withLock({ $0.held }) {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { s -> Bool in
                    guard s.held else { return true }
                    s.gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if Task.isCancelled {
            state.withLock { $0.cancelled = true }
            throw .network("cancelled")
        }
        if let failure { throw failure }
        do { try Data(content.utf8).write(to: destination) } catch { throw .network("write") }
    }
}

final class RemoteFileCacheTests: XCTestCase {
    private var sandbox: Sandbox!
    private var root: URL!

    override func setUp() async throws {
        sandbox = try Sandbox()
        root = try sandbox.createDirectory("cache")
    }
    override func tearDown() async throws { sandbox.destroy(); sandbox = nil }

    private func loc(_ path: [String], ref: String = "main") -> RemoteLocation {
        RemoteLocation(provider: "test.gated", repo: "octo/demo", ref: ref, path: path)
    }
    private func file(_ name: String, id: String?) -> RemoteItem {
        RemoteItem(name: name, kind: .file, size: 10, contentID: id)
    }

    func testDownloadsOnceIntoAReadOnlyContentKeyedPath() async throws {
        let cache = RemoteFileCache(root: root)
        let provider = GatedRemoteProvider()
        let url = try await cache.localURL(for: loc(["src", "a.txt"]), item: file("a.txt", id: "b1"), provider: provider)
        XCTAssertEqual(url, RemoteFileCache.entryURL(root: root, location: loc(["src", "a.txt"]), item: file("a.txt", id: "b1")))
        XCTAssertEqual(url.lastPathComponent, "a.txt")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "b1")
        XCTAssertTrue(url.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false) + "/test.gated/"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "0123456789")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o444)
        let again = try await cache.localURL(for: loc(["src", "a.txt"]), item: file("a.txt", id: "b1"), provider: provider)
        XCTAssertEqual(again, url)
        XCTAssertEqual(provider.fetches, 1, "a content-keyed entry is never fetched twice")
        let otherRef = try await cache.localURL(for: loc(["src", "a.txt"], ref: "dev"), item: file("a.txt", id: "b1"),
                                                provider: provider)
        XCTAssertEqual(otherRef, url, "the same blob in another ref is the same entry")
    }

    func testConcurrentRequestsShareOneDownload() async throws {
        let cache = RemoteFileCache(root: root)
        let provider = GatedRemoteProvider(held: true)
        let location = loc(["a.txt"]), item = file("a.txt", id: "b1")
        async let first = cache.localURL(for: location, item: item, provider: provider)
        async let second = cache.localURL(for: location, item: item, provider: provider)
        while provider.fetches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        provider.release()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(provider.fetches, 1)
    }

    /// Review (Task 11): cancelling the only request cancels its download.
    func testCancellingTheOnlyRequestCancelsTheDownload() async throws {
        let cache = RemoteFileCache(root: root)
        let provider = GatedRemoteProvider(held: true)
        let location = loc(["a.txt"]), item = file("a.txt", id: "b1")
        let request = Task { try await cache.localURL(for: location, item: item, provider: provider) }
        while provider.fetches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        request.cancel()
        try await Task.sleep(for: .milliseconds(50))   // the cancellation reaches the cache actor
        provider.release()
        do { _ = try await request.value; XCTFail("a cancelled request has no copy") } catch {}
        XCTAssertTrue(provider.sawCancellation, "the download itself was cancelled")
        let size = await cache.totalSize()
        XCTAssertEqual(size, 0)
    }

    /// Review (Task 11): a shared download keeps going while one of its requests still waits.
    func testCancellingOneOfTwoRequestsKeepsTheSharedDownload() async throws {
        let cache = RemoteFileCache(root: root)
        let provider = GatedRemoteProvider(held: true)
        let location = loc(["a.txt"]), item = file("a.txt", id: "b1")
        let first = Task { try await cache.localURL(for: location, item: item, provider: provider) }
        while provider.fetches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { try await cache.localURL(for: location, item: item, provider: provider) }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        try await Task.sleep(for: .milliseconds(50))
        provider.release()
        let url = try await second.value
        XCTAssertFalse(provider.sawCancellation)
        XCTAssertEqual(provider.fetches, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "0123456789")
    }

    func testWithoutAContentIDEveryRequestDownloadsAgain() async throws {
        let cache = RemoteFileCache(root: root)
        let provider = GatedRemoteProvider()
        _ = try await cache.localURL(for: loc(["a.txt"]), item: file("a.txt", id: nil), provider: provider)
        let url = try await cache.localURL(for: loc(["a.txt"]), item: file("a.txt", id: nil), provider: provider)
        XCTAssertEqual(provider.fetches, 2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "0123456789")
    }

    func testAFailedFetchLeavesNothingAndTheNextRequestRetries() async throws {
        let cache = RemoteFileCache(root: root)
        let provider = GatedRemoteProvider()
        provider.fail(with: .network("down"))
        do { _ = try await cache.localURL(for: loc(["a.txt"]), item: file("a.txt", id: "b1"), provider: provider); XCTFail() }
        catch { XCTAssertEqual(error, .network("down")) }
        let partials = root.appending(path: ".partial", directoryHint: .isDirectory)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: partials.path(percentEncoded: false))) ?? [], [])
        let failedSize = await cache.totalSize()
        XCTAssertEqual(failedSize, 0)
        provider.fail(with: nil)
        _ = try await cache.localURL(for: loc(["a.txt"]), item: file("a.txt", id: "b1"), provider: provider)
        XCTAssertEqual(provider.fetches, 2)
    }

    func testOnlyFilesAreCached() async {
        let cache = RemoteFileCache(root: root)
        for kind in [RemoteItemKind.directory, .symlink, .submodule] {
            do {
                _ = try await cache.localURL(for: loc(["x"]), item: RemoteItem(name: "x", kind: kind), provider: GatedRemoteProvider())
                XCTFail("\(kind)")
            } catch { XCTAssertEqual(error, .unsupported) }
        }
    }

    func testTrimRemovesTheLeastRecentlyUsedUntilItFits() async throws {
        let cache = RemoteFileCache(root: root, limitBytes: 25)        // room for two 10-byte files
        let provider = GatedRemoteProvider()
        let a = try await cache.localURL(for: loc(["a"]), item: file("a", id: "ka"), provider: provider)
        let b = try await cache.localURL(for: loc(["b"]), item: file("b", id: "kb"), provider: provider)
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -300)],
                             ofItemAtPath: a.deletingLastPathComponent().path(percentEncoded: false))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200)],
                             ofItemAtPath: b.deletingLastPathComponent().path(percentEncoded: false))
        _ = try await cache.localURL(for: loc(["a"]), item: file("a", id: "ka"), provider: provider)   // a used again
        let c = try await cache.localURL(for: loc(["c"]), item: file("c", id: "kc"), provider: provider)  // trims b
        XCTAssertTrue(fm.fileExists(atPath: a.path(percentEncoded: false)))
        XCTAssertFalse(fm.fileExists(atPath: b.path(percentEncoded: false)))
        XCTAssertTrue(fm.fileExists(atPath: c.path(percentEncoded: false)))
        let trimmedSize = await cache.totalSize()
        XCTAssertEqual(trimmedSize, 20)
    }

    func testClearEmptiesTheCache() async throws {
        let cache = RemoteFileCache(root: root)
        _ = try await cache.localURL(for: loc(["a"]), item: file("a", id: "ka"), provider: GatedRemoteProvider())
        let filledSize = await cache.totalSize()
        XCTAssertEqual(filledSize, 10)
        await cache.clear()
        let clearedSize = await cache.totalSize()
        XCTAssertEqual(clearedSize, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)), [])
    }

    func testUnsafeContentIDsStayOneFolder() {
        let url = RemoteFileCache.entryURL(root: root, location: loc(["a"]), item: file("a", id: "../x:y/z"))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".._x_y_z")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent, "test.gated")
    }
}
