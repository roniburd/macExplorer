import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import XCTest

private let vol = VolumeID(raw: "mnt:/reader-tests")
private let fastLanes = WatchdogConfig(stallTimeout: .milliseconds(200), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 4)

final class DirectoryReaderTests: XCTestCase {
    private var sandbox: Sandbox!
    private var gates: [Gate] = []

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    override func tearDown() {
        for g in gates { g.open(count: 8) }
        super.tearDown()
    }

    func testStreamsBatchesOfAtMost2000ThenCompletes() async throws {
        let dir = try FixtureTree.flat(in: sandbox, at: "flat", count: 10_000)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes))
        let gen = Generation.initial.next()
        let (batches, others) = await collect(await reader.read(dir, generation: gen))
        XCTAssertEqual(batches.reduce(0) { $0 + $1.count }, 10_000)
        XCTAssertGreaterThanOrEqual(batches.count, 5)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 2_000 && $0.generation == gen })
        XCTAssertEqual(others, ["completed:10000"])
        let names = Set(batches.flatMap { b in (0..<b.count).map { b.name(at: $0) } })
        XCTAssertEqual(names.count, 10_000)
    }

    func testBatchIntervalFlushesSmallBatches() {
        var clock: UInt64 = 0
        var acc = BatchAccumulator(batchSize: 2_000, interval: .milliseconds(8), now: { clock })
        XCTAssertFalse(acc.shouldFlush(count: 10))
        clock += 7_000_000
        XCTAssertFalse(acc.shouldFlush(count: 500))
        clock += 1_000_000
        XCTAssertTrue(acc.shouldFlush(count: 501), "8 ms elapsed")
        XCTAssertTrue(acc.shouldFlush(count: 2_000), "size limit")
        XCTAssertFalse(acc.shouldFlush(count: 0))
    }

    func testFailureIsReportedOnTheStream() async throws {
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes))
        let (batches, others) = await collect(await reader.read(sandbox.url("missing"), generation: .initial))
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(others, ["failed:\(ENOENT):open"])
    }

    func testStoppingIterationCancelsTheLaneWork() async throws {
        let calls = Recorder<Int>()
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes), types: .shared) { _, gen, _, _, ctx, emit in
            var n = 0
            while !ctx.isCancelled {
                n += 1
                calls.append(n)
                ctx.heartbeat()
                if !emit(Batch(generation: gen)) { break }
                usleep(2_000)
            }
            return ReadSummary(entryCount: n, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        for await event in await reader.read(URL(filePath: "/unused"), generation: .initial) {
            if case .batch = event { break }        // consumer navigates away after the first batch
        }
        let idle = await eventually { await reader.inFlightCount == 0 }
        XCTAssertTrue(idle, "the lane work stopped")
        let count = calls.values.count
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.values.count, count, "no more work after cancellation")
    }

    func testHungReadReportsStalledThenResumed() async throws {
        let gate = Gate(); gates.append(gate)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes), types: .shared) { _, gen, _, _, _, emit in
            gate.wait()                              // hung network volume
            _ = emit(Batch(generation: gen))
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        let stream = await reader.read(URL(filePath: "/unused"), generation: .initial)
        var events: [String] = []
        for await event in stream {
            switch event {
            case .stalled: events.append("stalled"); gate.open()
            case .resumed: events.append("resumed")
            case .batch: events.append("batch")
            case .completed: events.append("completed")
            default: events.append("other")
            }
        }
        XCTAssertEqual(events, ["stalled", "batch", "resumed", "completed"])
    }

    func testPermissionPendingReportsWaitingNotStalled() async throws {
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes), types: .shared) { _, _, _, _, _, _ in
            usleep(400_000)                          // TCC prompt showing
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        var options = ReadOptions()
        options.permissionPending = true
        let (_, others) = await collect(await reader.read(URL(filePath: "/unused"), generation: .initial, options: options))
        XCTAssertEqual(others, ["waiting", "resumed", "completed:0"])
    }

    func testUnresponsiveVolumeFailsReadsImmediately() async throws {
        let gate = Gate(); gates.append(gate)
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(150), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 1))
        let reader = DirectoryReader(volume: vol, lanes: lanes, types: .shared) { _, _, _, _, _, _ in
            gate.wait()
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        let first = Task { await collect(await reader.read(URL(filePath: "/a"), generation: .initial)) }
        _ = await eventually { await lanes.health(of: vol) == .unresponsive }
        let (_, others) = await collect(await reader.read(URL(filePath: "/b"), generation: .initial.next()))
        XCTAssertEqual(others, ["failed:\(ETIMEDOUT):unresponsiveVolume"])
        gate.open()
        _ = await first.value
    }

    func testStaleGenerationResultsCanBeDiscardedByTheConsumer() async throws {
        // §9 lane test: Retry gets a fresh lane; the late result of the old generation arrives tagged with it.
        let dir = try FixtureTree.flat(in: sandbox, at: "three", count: 3)
        let gate = Gate(); gates.append(gate)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes), types: .shared) { url, gen, options, types, ctx, emit in
            if gen == Generation.initial.next() { gate.wait() }    // first attempt hangs
            return try BulkReader.read(url, generation: gen, options: options, types: types, context: ctx, emit: emit)
        }
        let g1 = Generation.initial.next(), g2 = g1.next()
        let late = Task { await collect(await reader.read(dir, generation: g1)) }
        try await Task.sleep(for: .milliseconds(300))              // g1 is poisoned by now
        let fresh = await collect(await reader.read(dir, generation: g2))
        XCTAssertEqual(fresh.batches.map(\.generation), [g2])
        gate.open()
        let old = await late.value
        XCTAssertEqual(old.batches.map(\.generation), [g1])
        var current = g2
        let applied = (old.batches + fresh.batches).filter { $0.generation == current }
        XCTAssertEqual(applied.reduce(0) { $0 + $1.count }, 3)
        current = g2
    }

    func testCancelAllWaitsAtMostOneSecond() async throws {
        let gate = Gate(); gates.append(gate)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: WatchdogConfig(stallTimeout: .seconds(30))), types: .shared) { _, _, _, _, _, _ in
            gate.wait()
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        let stream = await reader.read(URL(filePath: "/hung"), generation: .initial)
        let consumer = Task { await collect(stream) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        await reader.cancelAll()
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(1_500))
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(900), "a hung read keeps cancelAll waiting the full second")
        gate.open()
        _ = await consumer.value
    }

    func testReadItemsReportsPresentAndMissing() async throws {
        let dir = try sandbox.createDirectory("items")
        try sandbox.createFile("items/a.txt")
        try sandbox.createSymlink("items/link", target: "nowhere")
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes))
        let result = try await reader.readItems(["a.txt", "gone.txt", "link"], in: dir, generation: .initial)
        XCTAssertEqual((0..<result.batch.count).map { result.batch.name(at: $0) }, ["a.txt", "link"])
        XCTAssertEqual(result.batch.entries[1].kind, .symlink, "never follows symlinks")
        XCTAssertEqual(result.missing, ["gone.txt"])
    }
}
