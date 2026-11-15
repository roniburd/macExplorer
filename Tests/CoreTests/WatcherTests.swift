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

    /// Creates `relative` and waits until `sink` reports it: the stream is live, and every event numbered before
    /// the marker's has been delivered (FSEvents delivers in event-id order). Replaces "sleep, then assert".
    private func sentinel(_ relative: String, seenBy sink: WatchSink) async throws {
        _ = try sandbox.createFile(relative)
        let name = (relative as NSString).lastPathComponent
        try await wait("sentinel \(relative)") { sink.names.contains(name) || sink.all.contains(.fullRescan) }
    }

    func testDeliversDirectChildrenOnly() async throws {
        let dir = try sandbox.createDirectory("w")
        _ = try sandbox.createDirectory("w/sub")
        let sink = WatchSink()
        let watcher = Watcher(directory: dir, since: Watcher.currentEventID(), handler: sink.handler)
        defer { watcher.stop() }
        watcher.start()                  // `since` predates the writes below: they are replayed if the stream opens late
        _ = try sandbox.createFile("w/a.txt")
        _ = try sandbox.createFile("w/sub/deep.txt")
        try await wait("a.txt event") { sink.names.contains("a.txt") }
        try await sentinel("w/z-sentinel", seenBy: sink)   // deep.txt's event (numbered earlier) has had its chance
        XCTAssertFalse(sink.names.contains("deep.txt"), "events below the folder are dropped")
        XCTAssertFalse(sink.all.contains(.fullRescan))
        XCTAssertGreaterThan(watcher.lastEventID, 0)
    }

    func testNoGapReplaysEventsSinceTheCapturedID() async throws {
        let dir = try sandbox.createDirectory("gap")
        let since = Watcher.currentEventID()
        let witness = WatchSink()
        let first = Watcher(directory: dir, since: since, handler: witness.handler)
        defer { first.stop() }
        first.start()
        _ = try sandbox.createFile("gap/before-start.txt")     // between capture and stream start (the read)
        try await wait("event numbered") { witness.names.contains("before-start.txt") }   // in the past for the next stream
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
        try await sentinel("gone/ready", seenBy: sink)        // the stream is open before its root goes
        try sandbox.rename("gone", to: "moved")
        try await wait("rootChanged") { sink.all.contains(.rootChanged) }
    }

    /// The model starts its watcher after the read; the folder can be renamed away before the stream opens, and
    /// FSEvents does not reliably replay that rename to a stream whose root no longer exists (seen under load:
    /// only HistoryDone arrives). The ID here is captured after the rename, so no replay can cover it.
    func testRootGoneWhenTheStreamOpensIsRootChanged() async throws {
        let parentSink = WatchSink()
        let parent = Watcher(directory: sandbox.root, since: Watcher.currentEventID(), handler: parentSink.handler)
        defer { parent.stop() }
        parent.start()
        let dir = try sandbox.createDirectory("early")
        try sandbox.rename("early", to: "moved-early")
        // The rename's event has been assigned an ID (delivered to a stream on the parent) before the capture.
        try await wait("rename numbered") { parentSink.names.contains("moved-early") || parentSink.all.contains(.fullRescan) }
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
        try await sentinel("s/ready", seenBy: sink)           // delivering before the stop
        watcher.stop()
        watcher.stop()
        let delivered = sink.all.count
        // A second stream on the same folder sees late.txt and a later marker: the first had its chance at both.
        let witness = WatchSink()
        let second = Watcher(directory: dir, since: Watcher.currentEventID(), handler: witness.handler)
        defer { second.stop() }
        second.start()
        _ = try sandbox.createFile("s/late.txt")
        try await sentinel("s/after", seenBy: witness)
        XCTAssertEqual(sink.all.count, delivered, "nothing is delivered after stop returns")
        XCTAssertFalse(sink.names.contains("late.txt"))
    }

    /// Deliveries are cut by the latency window, so a burst arrives as item chunks (each ≤ the limit) and/or a
    /// full rescan; either way nothing is lost.
    func testBurstIsCoveredByItemsOrAFullRescan() async throws {
        let dir = try sandbox.createDirectory("burst")
        let sink = WatchSink()
        let watcher = Watcher(directory: dir, since: Watcher.currentEventID(), handler: sink.handler)
        defer { watcher.stop() }
        watcher.start()                  // `since` predates the burst: it is replayed if the stream opens late
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
        // A second watcher on the same folder reports child2: the unwatched one had its chance and stayed quiet.
        var witnessed: [URL] = []
        let witness = TreeWatcher { witnessed.append($0) }
        defer { witness.unwatch(dir) }
        XCTAssertTrue(witness.watch(dir, isLocalVolume: true))
        try await wait("witness open") { witness.liveCount == 1 }
        _ = try sandbox.createDirectory("tree/child2")
        try await wait("witness change") { witnessed.contains(dir) }
        await Task.yield()                                    // a change hop of the unwatched node already queued on main
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
