@testable import Core
import Darwin
import Foundation
import MacxFixtures
import Synchronization
import XCTest

/// Collects WatchEvents delivered on the watcher's queue.
final class WatchSink: Sendable {
    private let events = Mutex<[WatchEvent]>([])
    var handler: @Sendable (WatchEvent) -> Void { { [self] e in events.withLock { $0.append(e) } } }
    var all: [WatchEvent] { events.withLock { $0 } }
    var names: Set<String> {
        Set(all.flatMap { event -> [String] in if case .items(let n) = event { n } else { [] } })
    }
}

/// Real FSEvents streams and vnode sources, only ever on fresh sandbox directories.
@MainActor
final class WatcherTests: XCTestCase {
    private var _sandbox: Sandbox?

    /// A fresh sandbox per test, destroyed in teardown.
    private var sandbox: Sandbox {
        if let s = _sandbox { return s }
        let s = try! Sandbox(prefix: "macx-tests")
        _sandbox = s
        addTeardownBlock { s.destroy() }
        return s
    }

    private func wait(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { throw WaitTimeout(what: what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testDeliversDirectChildrenOnly() async throws {
        let dir = try sandbox.createDirectory("w")
        _ = try sandbox.createDirectory("w/sub")
        let sink = WatchSink()
        let watcher = Watcher(directory: dir, since: Watcher.currentEventID(), handler: sink.handler)
        defer { watcher.stop() }
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        _ = try sandbox.createFile("w/a.txt")
        _ = try sandbox.createFile("w/sub/deep.txt")
        try await wait("a.txt event") { sink.names.contains("a.txt") }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(sink.names.contains("deep.txt"), "events below the folder are dropped")
        XCTAssertFalse(sink.all.contains(.fullRescan))
        XCTAssertGreaterThan(watcher.lastEventID, 0)
    }

    func testNoGapReplaysEventsSinceTheCapturedID() async throws {
        let dir = try sandbox.createDirectory("gap")
        let since = Watcher.currentEventID()
        _ = try sandbox.createFile("gap/before-start.txt")     // between capture and stream start (the read)
        try await Task.sleep(for: .milliseconds(200))
        let sink = WatchSink()
        let watcher = Watcher(directory: dir, since: since, handler: sink.handler)
        defer { watcher.stop() }
        watcher.start()
        try await wait("replayed event") { sink.names.contains("before-start.txt") }
    }

    func testRootRemovedIsRootChanged() async throws {
        let dir = try sandbox.createDirectory("gone")
        let sink = WatchSink()
        let watcher = Watcher(directory: dir, since: Watcher.currentEventID(), handler: sink.handler)
        defer { watcher.stop() }
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        try sandbox.rename("gone", to: "moved")
        try await wait("rootChanged") { sink.all.contains(.rootChanged) }
    }

    /// The model starts its watcher after the read; the folder can be renamed away before the stream opens, and
    /// FSEvents does not reliably replay that rename to a stream whose root no longer exists (seen under load:
    /// only HistoryDone arrives). The ID here is captured after the rename, so no replay can cover it.
    func testRootGoneWhenTheStreamOpensIsRootChanged() async throws {
        let dir = try sandbox.createDirectory("early")
        try sandbox.rename("early", to: "moved-early")
        try await Task.sleep(for: .milliseconds(500))           // the rename's event is assigned an ID before the capture
        let since = Watcher.currentEventID()
        let sink = WatchSink()
        let watcher = Watcher(directory: dir, since: since, handler: sink.handler)
        defer { watcher.stop() }
        watcher.start()
        try await wait("rootChanged", timeout: .seconds(5)) { sink.all.contains(.rootChanged) }
    }

    func testStopEndsDelivery() async throws {
        let dir = try sandbox.createDirectory("s")
        let sink = WatchSink()
        let watcher = Watcher(directory: dir, since: Watcher.currentEventID(), handler: sink.handler)
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        watcher.stop()
        watcher.stop()
        try await Task.sleep(for: .milliseconds(100))
        _ = try sandbox.createFile("s/late.txt")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(sink.all.isEmpty)
    }

    /// Deliveries are cut by the latency window, so a burst arrives as item chunks (each ≤ the limit) and/or a
    /// full rescan; either way nothing is lost.
    func testBurstIsCoveredByItemsOrAFullRescan() async throws {
        let dir = try sandbox.createDirectory("burst")
        let sink = WatchSink()
        let watcher = Watcher(directory: dir, since: Watcher.currentEventID(), handler: sink.handler)
        defer { watcher.stop() }
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        for i in 0..<600 { _ = try sandbox.createFile("burst/f\(i)") }
        let expected = Set((0..<600).map { "f\($0)" })
        try await wait("burst covered") { sink.all.contains(.fullRescan) || sink.names.isSuperset(of: expected) }
        for case .items(let names) in sink.all { XCTAssertLessThanOrEqual(names.count, EventClassifier.incrementalLimit) }
    }

    // MARK: TreeWatcher

    func testTreeWatcherReportsChangesInWatchedDirectories() async throws {
        let dir = try sandbox.createDirectory("tree")
        var changed: [URL] = []
        let tree = TreeWatcher { changed.append($0) }
        XCTAssertTrue(tree.watch(dir, isLocalVolume: true))
        XCTAssertTrue(tree.watch(dir, isLocalVolume: true), "watching twice is one source")
        XCTAssertEqual(tree.count, 1)
        try await wait("source open") { tree.liveCount == 1 }
        _ = try sandbox.createDirectory("tree/child")
        try await wait("tree change") { changed.contains(dir) }
        tree.unwatch(dir)
        XCTAssertEqual(tree.count, 0)
        changed.removeAll()
        try await Task.sleep(for: .milliseconds(100))
        _ = try sandbox.createDirectory("tree/child2")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(changed.isEmpty, "an unwatched node reports nothing")
    }

    /// liveCount == 1 promises "changes from now on are reported": a change made the instant it flips must still
    /// arrive (the source used to count as live before it was resumed and registered with the kernel).
    func testTreeWatcherLiveMeansRegistered() async throws {
        for i in 0..<150 {
            let dir = try sandbox.createDirectory("live\(i)")
            var changed = false
            let tree = TreeWatcher { _ in changed = true }
            XCTAssertTrue(tree.watch(dir, isLocalVolume: true))
            let deadline = ContinuousClock.now + .seconds(10)
            while tree.liveCount == 0 {
                guard ContinuousClock.now < deadline else { return XCTFail("source \(i) never opened") }
                await Task.yield()
            }
            _ = try sandbox.createDirectory("live\(i)/child")
            try await wait("change \(i)", timeout: .seconds(5)) { changed }
            tree.unwatch(dir)
        }
    }

    func testTreeWatcherCapAndNonLocalVolumes() throws {
        XCTAssertEqual(TreeWatcher.sourceCap, 256)
        let tree = TreeWatcher { _ in }
        defer { tree.unwatchAll(under: sandbox.root) }
        XCTAssertFalse(tree.watch(try sandbox.createDirectory("net"), isLocalVolume: false))
        XCTAssertEqual(tree.count, 0)
        for i in 0..<TreeWatcher.sourceCap {
            XCTAssertTrue(tree.watch(try sandbox.createDirectory("d\(i)"), isLocalVolume: true))
        }
        XCTAssertFalse(tree.watch(try sandbox.createDirectory("over"), isLocalVolume: true), "above the cap")
        XCTAssertEqual(tree.count, TreeWatcher.sourceCap)
        tree.unwatch(sandbox.url("d0"))
        XCTAssertTrue(tree.watch(sandbox.url("over"), isLocalVolume: true))
    }

    func testTreeWatcherUnwatchAllUnderAVolume() throws {
        let tree = TreeWatcher { _ in }
        _ = try sandbox.createDirectory("vol")
        XCTAssertTrue(tree.watch(try sandbox.createDirectory("vol/a"), isLocalVolume: true))
        XCTAssertTrue(tree.watch(try sandbox.createDirectory("vol/a/b"), isLocalVolume: true))
        XCTAssertTrue(tree.watch(try sandbox.createDirectory("volume2"), isLocalVolume: true))
        tree.unwatchAll(under: sandbox.url("vol"))
        XCTAssertEqual(tree.count, 1, "only paths inside the mount point, not prefix siblings")
        tree.unwatchAll(under: sandbox.root)
        XCTAssertEqual(tree.count, 0)
    }
}
