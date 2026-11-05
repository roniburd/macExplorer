import XCTest
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class FolderSizeServiceTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!

    override func setUp() async throws {
        let sandbox = try Sandbox()
        self.sandbox = sandbox
        addTeardownBlock { sandbox.destroy() }
        env = CoreEnvironment.sandboxed(root: sandbox.root)
        _ = await env.start()
    }

    func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func model() async throws -> FolderModel {
        let model = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in model.close() }
        return model
    }

    func testCacheKeyedByIdentityAndMtime() {
        let cache = FolderSizeCache(capacity: 2)
        let id = FolderSizeIdentity.path("/a")
        cache.store(FolderSize(bytes: 5), for: FolderSizeKey(identity: id, mtime: 1), path: "/a")
        XCTAssertEqual(cache.value(for: FolderSizeKey(identity: id, mtime: 1))?.bytes, 5)
        XCTAssertNil(cache.value(for: FolderSizeKey(identity: id, mtime: 2)))
        cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: .path("/b"), mtime: 0), path: "/b")
        cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: .path("/c"), mtime: 0), path: "/c")
        XCTAssertEqual(cache.count, 2, "LRU capacity")
        XCTAssertNil(cache.value(for: FolderSizeKey(identity: id, mtime: 1)), "least recently used was evicted")
    }

    func testInvalidateAncestorsIsComponentWise() {
        let cache = FolderSizeCache()
        for p in ["/a", "/a/b", "/a/b/c", "/a/bc", "/x"] {
            cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: .path(p), mtime: 0), path: p)
        }
        cache.invalidateAncestors(ofDirectory: "/a/b")
        XCTAssertNil(cache.value(for: FolderSizeKey(identity: .path("/a"), mtime: 0)))
        XCTAssertNil(cache.value(for: FolderSizeKey(identity: .path("/a/b"), mtime: 0)))
        for p in ["/a/b/c", "/a/bc", "/x"] { XCTAssertNotNil(cache.value(for: FolderSizeKey(identity: .path(p), mtime: 0)), p) }
    }

    func testSessionSizesEveryFolderAndCaches() async throws {
        try sandbox.createFile("big/a.bin", contents: Data(count: 3_000))
        try sandbox.createFile("big/deep/b.bin", contents: Data(count: 2_000))
        try sandbox.createFile("small/c.bin", contents: Data(count: 1_000))
        try sandbox.createFile("file.txt", contents: Data(count: 7))
        let model = try await model()
        let session = env.folderSizes.attach(to: model)
        await session.waitUntilIdle()
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "big")!)?.bytes, 5_000)
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "small")!)?.bytes, 1_000)
        XCTAssertNil(model.folderSize(atRow: model.row(named: "file.txt")!))
        XCTAssertEqual(env.folderSizes.cache.count, 2)
        session.stop()
    }

    func testCacheHitsShowAtOnceAndAreRevalidated() async throws {
        try sandbox.createFile("big/a.bin", contents: Data(count: 3_000))
        let model = try await model()
        let first = env.folderSizes.attach(to: model)
        await first.waitUntilIdle()
        first.stop()
        let other = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in other.close() }
        let second = env.folderSizes.attach(to: other)
        XCTAssertEqual(other.folderSize(atRow: other.row(named: "big")!)?.bytes, 3_000, "cache hit set synchronously")
        await second.waitUntilIdle()
        XCTAssertEqual(second.scansStarted, 1, "the hit is revalidated in the background")
        second.stop()
    }

    func testVisibleRowsScanFirst() async throws {
        for i in 0..<30 { try sandbox.createFile(String(format: "d%02d/f", i), contents: Data(count: 1)) }
        let service = FolderSizeService(lanes: env.lanes, mountTable: env.volumes.mountTableStore, changeBus: env.changeBus,
                                        makeSubtreeWatcher: { _, _ in NoopWatcher() }, maxConcurrentScans: 1)
        let model = try await model()
        var order: [String] = []
        let token = model.observe { e in
            if case .folderSizes(let ids) = e { for id in ids { if let r = model.row(of: id) { order.append(model.name(atRow: r)) } } }
        }
        defer { token.cancel() }
        let session = service.attach(to: model)
        session.setVisibleRows(IndexSet(integersIn: 25..<30))
        await session.waitUntilIdle()
        XCTAssertEqual(order.count, 30)
        XCTAssertEqual(Set(order.dropFirst().prefix(5)), Set((25..<30).map { String(format: "d%02d", $0) }),
                       "after the scan already in flight, visible folders come first")
        session.stop()
    }

    func testDeepChangeRescansOnlyThatChild() async throws {
        try sandbox.createFile("big/a.bin", contents: Data(count: 3_000))
        try sandbox.createFile("small/c.bin", contents: Data(count: 1_000))
        let model = try await model()
        let session = env.folderSizes.attach(to: model)
        await session.waitUntilIdle()
        let before = session.scansStarted
        try sandbox.createFile("big/deep/new.bin", contents: Data(count: 4_000))   // FSEvents → SubtreeWatcher
        await waitUntil { model.folderSize(atRow: model.row(named: "big")!)?.bytes == 7_000 }
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "big")!)?.bytes, 7_000)
        try await Task.sleep(for: .milliseconds(1_500))   // let the 1 s subtree delivery arrive too
        await session.waitUntilIdle()
        XCTAssertEqual(session.scansStarted - before, 1, "only big was rescanned, once")
        session.stop()
    }

    /// A change two levels down does not touch the child's own mtime: only the subtree watcher sees it.
    func testDeeperChangeWithoutChildMtimeChangeIsSeenBySubtreeWatcher() async throws {
        try sandbox.createFile("big/deep/a.bin", contents: Data(count: 3_000))
        let model = try await model()
        let session = env.folderSizes.attach(to: model)
        await session.waitUntilIdle()
        try sandbox.createFile("big/deep/b.bin", contents: Data(count: 500))
        await waitUntil { model.folderSize(atRow: model.row(named: "big")!)?.bytes == 3_500 }
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "big")!)?.bytes, 3_500)
        session.stop()
    }

    func testStopCancelsEverything() async throws {
        for i in 0..<200 { try sandbox.createFile("d\(i)/f", contents: Data(count: 1)) }
        let model = try await model()
        var late = 0
        let session = env.folderSizes.attach(to: model)
        session.stop()
        let token = model.observe { if case .folderSizes = $0 { late += 1 } }
        defer { token.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertEqual(session.inFlightCount, 0)
        XCTAssertEqual(late, 0, "cancelled scans never publish")
    }

    func testRemovedRowsAreUnqueuedAndDropped() async throws {
        for i in 0..<5 { try sandbox.createFile("d\(i)/f", contents: Data(count: 10)) }
        let service = FolderSizeService(lanes: env.lanes, mountTable: env.volumes.mountTableStore, changeBus: env.changeBus,
                                        makeSubtreeWatcher: { _, _ in NoopWatcher() }, maxConcurrentScans: 1)
        let model = try await model()
        let session = service.attach(to: model)
        await session.waitUntilIdle()
        let id = model.identity(atRow: model.row(named: "d0")!)
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "d0")!)?.bytes, 10)
        try sandbox.remove("d0")
        await waitUntil { model.row(named: "d0") == nil }
        XCTAssertNil(model.row(named: "d0"))
        XCTAssertNil(model.sizeTable[id], "a removed row's size is dropped")
        session.stop()
    }

    func testLocalChangeInvalidatesCachedAncestors() {
        let big = sandbox.url("big").path(percentEncoded: false)
        env.folderSizes.cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: .path(big), mtime: 0), path: big)
        env.changeBus.post([LocalChange(directory: sandbox.url("big/deep"), added: ["n"])])
        XCTAssertNil(env.folderSizes.cache.value(for: FolderSizeKey(identity: .path(big), mtime: 0)))
    }

    func testLocalChangeRequeuesAffectedChildAtOnce() async throws {
        try sandbox.createFile("big/deep/a.bin", contents: Data(count: 3_000))
        let service = FolderSizeService(lanes: env.lanes, mountTable: env.volumes.mountTableStore, changeBus: env.changeBus,
                                        makeSubtreeWatcher: { _, _ in NoopWatcher() })
        let model = try await model()
        let session = service.attach(to: model)
        await session.waitUntilIdle()
        try sandbox.createFile("big/deep/b.bin", contents: Data(count: 1_000))
        env.changeBus.post([LocalChange(directory: sandbox.url("big/deep"), added: ["b.bin"])])
        XCTAssertEqual(session.pendingCount + session.inFlightCount, 1, "re-queued without waiting for FSEvents")
        await session.waitUntilIdle()
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "big")!)?.bytes, 4_000)
        session.stop()
    }

    func testChangeBusObserveAllSeesEveryDirectoryAfterDirectoryObservers() {
        let bus = ChangeBus()
        var log: [String] = []
        let a = bus.observe(directory: sandbox.url("x")) { _ in log.append("dir") }
        let b = bus.observeAll { log.append("all:" + $0.added.joined()) }
        bus.post([LocalChange(directory: sandbox.url("x"), added: ["1"]), LocalChange(directory: sandbox.url("y"), added: ["2"])])
        XCTAssertEqual(log, ["dir", "all:1", "all:2"])
        b.cancel()
        bus.post([LocalChange(directory: sandbox.url("y"), added: ["3"])])
        XCTAssertEqual(log.count, 3)
        _ = a
    }
}
