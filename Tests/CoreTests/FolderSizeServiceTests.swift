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

    /// Moving the visible window re-prioritizes only the newly visible queued rows (latest window first, then the
    /// earlier one, then the rest in queue order); stale queue copies never cause a second scan.
    func testChangingVisibleRowsKeepsTheRestOfTheQueueAndScansEachRowOnce() async throws {
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
        session.setVisibleRows(IndexSet(integersIn: 25..<30))           // same rows: no-op
        session.setVisibleRows(IndexSet(integersIn: 10..<15))
        XCTAssertEqual(session.pendingCount, 29, "moving rows never duplicates pending work")
        await session.waitUntilIdle()
        let name = { (i: Int) in String(format: "d%02d", i) }
        let expected = (10..<15).map(name) + (25..<30).map(name) + (1..<30).filter { !(10..<15).contains($0) && !(25..<30).contains($0) }.map(name)
        XCTAssertEqual(Array(order.dropFirst()), expected)
        XCTAssertEqual(order.count, 30)
        XCTAssertEqual(session.scansStarted, 30, "every row is scanned exactly once")
        session.stop()
    }

    func testDeepChangeRescansOnlyThatChild() async throws {
        try sandbox.createFile("big/a.bin", contents: Data(count: 3_000))
        try sandbox.createFile("small/c.bin", contents: Data(count: 1_000))
        let model = try await model()
        let session = env.folderSizes.attach(to: model)
        await session.waitUntilIdle()
        let big = model.identity(atRow: model.row(named: "big")!), small = model.identity(atRow: model.row(named: "small")!)
        let before = session.scanCounts
        try sandbox.createFile("big/deep/new.bin", contents: Data(count: 4_000))   // FSEvents → SubtreeWatcher
        await waitUntil { model.folderSize(atRow: model.row(named: "big")!)?.bytes == 7_000 }
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "big")!)?.bytes, 7_000)
        try await Task.sleep(for: .milliseconds(1_500))   // let the 1 s subtree delivery arrive too
        await session.waitUntilIdle()
        XCTAssertEqual(session.scanCounts[small], before[small], "small was not rescanned")
        // Normally once: the folder watcher's mtime change and the subtree delivery are deduplicated by event id.
        // Under heavy load fseventsd can number the event after the id the rescan read at its start, which costs
        // one more (rate-limited) rescan; anything beyond that would be a dedup failure.
        let rescans = session.scanCounts[big, default: 0] - before[big, default: 0]
        XCTAssertTrue((1...2).contains(rescans), "big was rescanned \(rescans) times")
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

    /// The folder watcher refreshes a child's row when an entry inside it changes, so the session's cache key
    /// (the row's mtime) matches what the rescan stored: turning sizes off and on again is a hit (QA round 1).
    func testAfterAChangeInsideAChildReattachingIsACacheHit() async throws {
        try sandbox.createFile("A/a.bin", contents: Data(count: 3_000))
        try sandbox.createFile("B/sub/b.bin", contents: Data(count: 5_000))
        let model = try await model()
        try await Task.sleep(for: .milliseconds(1_500))      // the fixture's own events have been delivered
        try sandbox.createFile("A/extra.bin", contents: Data(count: 1_000))
        model.setFolderSizesEnabled(true)
        let first = env.folderSizes.attach(to: model)
        await waitUntil { model.folderSize(atRow: model.row(named: "A")!)?.bytes == 4_000 }
        var st = stat()
        XCTAssertEqual(lstat(sandbox.url("A").path(percentEncoded: false), &st), 0)
        let onDisk = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        await waitUntil { model.entry(atRow: model.row(named: "A")!).mtime == onDisk }
        XCTAssertEqual(model.entry(atRow: model.row(named: "A")!).mtime, onDisk, "the row follows the child's mtime")
        await first.waitUntilIdle()
        first.stop()
        model.setFolderSizesEnabled(false)
        XCTAssertNil(model.folderSize(atRow: model.row(named: "A")!))
        model.setFolderSizesEnabled(true)
        let second = env.folderSizes.attach(to: model)
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "A")!)?.bytes, 4_000, "cache hit set synchronously")
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "B")!)?.bytes, 5_000, "cache hit set synchronously")
        second.stop()
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

    func testInvalidateAncestorsFollowsRestoredPathsAndRoot() {
        let cache = FolderSizeCache()
        let id = FolderSizeIdentity.object(VolumeID(raw: "v"), 7)
        cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: id, mtime: 0), path: "/a")
        cache.store(FolderSize(bytes: 2), for: FolderSizeKey(identity: id, mtime: 0), path: "/b")   // renamed
        cache.invalidateAncestors(ofDirectory: "/a/x")
        XCTAssertNotNil(cache.value(for: FolderSizeKey(identity: id, mtime: 0)), "the old path no longer holds it")
        cache.invalidateAncestors(ofDirectory: "/b/y")
        XCTAssertNil(cache.value(for: FolderSizeKey(identity: id, mtime: 0)))
        cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: .path("/"), mtime: 0), path: "/")
        cache.invalidateAncestors(ofDirectory: "/q/r")
        XCTAssertNil(cache.value(for: FolderSizeKey(identity: .path("/"), mtime: 0)), "/ is everyone's ancestor")
        XCTAssertEqual(cache.count, 0)
    }

    /// A folder row that is another volume's mount point is scanned on that volume's lanes, so a hung volume
    /// never poisons the lanes of the volume being listed (§4.2).
    func testMountPointRowScansOnItsOwnVolumeLanes() async throws {
        guard DiskImage.isAvailable, let image = try? DiskImage.create(in: sandbox, format: .apfs, sizeMB: 8) else {
            throw XCTSkip("hdiutil unavailable")
        }
        addTeardownBlock { try? image.detach() }
        try Data(count: 1_000).write(to: image.mountPoint.appending(path: "inside"))   // inside the test's own image
        let lanes = LanePool()
        let table = MountTableStore(MountTable([
            VolumeInfoFixtures.volume(id: "uuid:ROOT", mountPoint: URL(filePath: "/", directoryHint: .isDirectory)),
            VolumeInfoFixtures.volume(id: "uuid:IMG", mountPoint: image.mountPoint),
        ]))
        let service = FolderSizeService(lanes: lanes, mountTable: table, changeBus: env.changeBus,
                                        makeSubtreeWatcher: { _, _ in NoopWatcher() })
        let model = try await model()
        let name = image.mountPoint.lastPathComponent
        let session = service.attach(to: model)
        await session.waitUntilIdle()
        XCTAssertEqual(model.folderSize(atRow: try XCTUnwrap(model.row(named: name)))?.files, 1)
        let imageLanes = await lanes.liveLaneCount(of: VolumeID(raw: "uuid:IMG"), .scan)
        XCTAssertEqual(imageLanes, 1, "the mount point row ran on the image's own scan lane")
        session.stop()
    }

    /// P2-13 failure rule: `volumeUnresponsive` stops the queue, cells stay "Calculating…", retry() sizes again.
    func testUnresponsiveVolumeHaltsUntilRetry() async throws {
        try sandbox.createFile("big/a.bin", contents: Data(count: 100))
        let volume = VolumeID(raw: "uuid:HUNG")
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(50), tick: .milliseconds(10), poisonCap: 1))
        _ = try? await lanes.perform(on: volume, .scan) { _ in Thread.sleep(forTimeInterval: 0.3) }   // no heartbeats
        let deadline = ContinuousClock.now + .seconds(5)
        while await lanes.health(of: volume) != .unresponsive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let health = await lanes.health(of: volume)
        XCTAssertEqual(health, .unresponsive)
        let table = MountTableStore(MountTable([
            VolumeInfoFixtures.volume(id: "uuid:HUNG", mountPoint: URL(filePath: "/", directoryHint: .isDirectory)),
        ]))
        let service = FolderSizeService(lanes: lanes, mountTable: table, changeBus: env.changeBus,
                                        makeSubtreeWatcher: { _, _ in NoopWatcher() })
        let model = try await model()
        let session = service.attach(to: model)
        await session.waitUntilIdle()
        XCTAssertTrue(session.halted)
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertNil(model.folderSize(atRow: model.row(named: "big")!), "no size is published")
        await lanes.resetVolume(volume)
        session.retry()
        XCTAssertFalse(session.halted)
        await session.waitUntilIdle()
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "big")!)?.bytes, 100)
        session.stop()
    }

    /// One hung volume (a mount point row in /Volumes) halts only its own rows: the other rows keep sizing.
    func testUnresponsiveMountPointHaltsOnlyItsOwnRows() async throws {
        try sandbox.createFile("hung/a.bin", contents: Data(count: 10))
        try sandbox.createFile("ok/b.bin", contents: Data(count: 70))
        let hungVolume = VolumeID(raw: "uuid:HUNG")
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(50), tick: .milliseconds(10), poisonCap: 1))
        _ = try? await lanes.perform(on: hungVolume, .scan) { _ in Thread.sleep(forTimeInterval: 0.3) }   // no heartbeats
        let deadline = ContinuousClock.now + .seconds(5)
        while await lanes.health(of: hungVolume) != .unresponsive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let health = await lanes.health(of: hungVolume)
        XCTAssertEqual(health, .unresponsive)
        let table = MountTableStore(MountTable([
            VolumeInfoFixtures.volume(id: "uuid:ROOT", mountPoint: URL(filePath: "/", directoryHint: .isDirectory)),
            VolumeInfoFixtures.volume(id: "uuid:HUNG", mountPoint: sandbox.root.appending(path: "hung", directoryHint: .isDirectory)),
        ]))
        let service = FolderSizeService(lanes: lanes, mountTable: table, changeBus: env.changeBus,
                                        makeSubtreeWatcher: { _, _ in NoopWatcher() }, maxConcurrentScans: 1)
        let model = try await model()
        let session = service.attach(to: model)
        await session.waitUntilIdle()
        XCTAssertTrue(session.halted)
        XCTAssertEqual(session.pendingCount, 0)
        XCTAssertNil(model.folderSize(atRow: try XCTUnwrap(model.row(named: "hung"))), "the hung row stays Calculating…")
        XCTAssertEqual(model.folderSize(atRow: try XCTUnwrap(model.row(named: "ok")))?.bytes, 70, "the healthy row is sized")
        await lanes.resetVolume(hungVolume)
        session.retry()
        XCTAssertFalse(session.halted)
        await session.waitUntilIdle()
        XCTAssertEqual(model.folderSize(atRow: try XCTUnwrap(model.row(named: "hung")))?.bytes, 10)
        session.stop()
    }

    /// A busy subtree (~/Library) does not keep a full rescan running back to back: after the first rescan,
    /// further rescans of a row wait at least `minRescanInterval` and the events of that window are coalesced.
    func testRepeatedSubtreeEventsAreRateLimited() async throws {
        try sandbox.createFile("big/a.bin", contents: Data(count: 100))
        let watcher = ManualWatcher()
        let service = FolderSizeService(lanes: env.lanes, mountTable: env.volumes.mountTableStore, changeBus: env.changeBus,
                                        makeSubtreeWatcher: { _, handler in watcher.handler = handler; return watcher },
                                        minRescanInterval: .seconds(1))
        let model = try await model()
        let session = service.attach(to: model)
        await session.waitUntilIdle()
        let before = session.scansStarted
        try sandbox.createFile("big/b.bin", contents: Data(count: 50))
        let start = ContinuousClock.now
        for _ in 0..<30 {
            watcher.handler?(.children(["big"]))
            try await Task.sleep(for: .milliseconds(50))
        }
        let eventSpan = ContinuousClock.now - start
        await session.waitUntilIdle()
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "big")!)?.bytes, 150, "the last value still arrives")
        let scans = session.scansStarted - before
        XCTAssertGreaterThanOrEqual(scans, 1)
        // At most one rescan per started second of events, plus the trailing rescan that coalesces the last window.
        // Bounded by the measured span, not the nominal 1.5 s: on a loaded machine the 50 ms sleeps run long.
        let allowed = 2 + Int(eventSpan / .seconds(1))
        XCTAssertLessThanOrEqual(scans, allowed, "rescans are rate limited (events spanned \(eventSpan))")
        XCTAssertLessThan(scans, 10, "rescans are rate limited, not one per event")
        session.stop()
    }

    func testChildNamesResolveByIdentityName() async throws {
        try sandbox.createFile("big/a.bin", contents: Data(count: 100))
        let watcher = ManualWatcher()
        let service = FolderSizeService(lanes: env.lanes, mountTable: env.volumes.mountTableStore, changeBus: env.changeBus,
                                        makeSubtreeWatcher: { _, handler in watcher.handler = handler; return watcher })
        let model = try await model()
        let session = service.attach(to: model)
        await session.waitUntilIdle()
        let before = session.scansStarted
        watcher.handler?(.children(["BIG", "nothing-here"]))
        try await Task.sleep(for: .milliseconds(50))
        await session.waitUntilIdle()
        XCTAssertEqual(session.scansStarted - before, model.caseSensitive ? 0 : 1)
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

/// A subtree watcher the test drives by hand (main actor only).
final class ManualWatcher: ContentWatching, @unchecked Sendable {
    var handler: (@Sendable (SubtreeChange) -> Void)?
    func start() {}
    func stop() {}
    var lastEventID: UInt64 { 0 }
}
