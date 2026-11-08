import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import XCTest

private let vol = VolumeID(raw: "mnt:/reader-tests")
/// Stall tests: a read without a heartbeat for 200 ms is overdue.
private let fastLanes = WatchdogConfig(stallTimeout: .milliseconds(200), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 4)
/// Tests that do not test stalls: a real read on a slow, shared runner may go 200 ms between heartbeats, and the
/// .stalled/.resumed notices that would add are not under test.
private let calmLanes = WatchdogConfig(stallTimeout: .seconds(60), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 4)

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
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: calmLanes))
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
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: calmLanes))
        let (batches, others) = await collect(await reader.read(sandbox.url("missing"), generation: .initial))
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(others, ["failed:\(ENOENT):open"])
    }

    func testStoppingIterationCancelsTheLaneWork() async throws {
        let calls = Recorder<Int>()
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: calmLanes), types: .shared) { _, gen, _, _, ctx, emit in
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
        let gate = Gate(); gates.append(gate)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes), types: .shared) { _, _, _, _, _, _ in
            gate.wait()                              // TCC prompt showing: no heartbeat until the user answers
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        var options = ReadOptions()
        options.permissionPending = true
        var others: [String] = []
        for await event in await reader.read(URL(filePath: "/unused"), generation: .initial, options: options) {
            switch event {
            case .waitingForPermission: others.append("waiting"); gate.open()   // the user answers the prompt
            case .stalled: others.append("stalled"); gate.open()
            case .resumed: others.append("resumed")
            case .completed(let s): others.append("completed:\(s.entryCount)")
            case .batch: others.append("batch")
            case .failed(let f): others.append("failed:\(f.code)")
            }
        }
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
        let lanes = LanePool(config: fastLanes)
        let reader = DirectoryReader(volume: vol, lanes: lanes, types: .shared) { url, gen, options, types, ctx, emit in
            if gen == Generation.initial.next() { gate.wait() }    // first attempt hangs
            return try BulkReader.read(url, generation: gen, options: options, types: types, context: ctx, emit: emit)
        }
        let g1 = Generation.initial.next(), g2 = g1.next()
        let late = Task { await collect(await reader.read(dir, generation: g1)) }
        let poisoned = await eventually { await lanes.poisonedCount(of: vol) >= 1 }
        XCTAssertTrue(poisoned, "g1's lane is poisoned before the retry")
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

    /// The 1 s timeout is a test-controlled sleep: cancelAll asks for exactly one second, is still waiting while the
    /// read hangs, and returns when that second is up although the read is still hung.
    func testCancelAllWaitsAtMostOneSecond() async throws {
        let gate = Gate(); gates.append(gate)
        let started = Recorder<Bool>()
        let requested = Recorder<Duration>()
        let timeout = TimeoutLatch()
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: calmLanes), types: .shared, implementation: { _, _, _, _, _, _ in
            started.append(true)
            gate.wait()
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }, idleTimeoutSleep: { duration in
            requested.append(duration)
            await timeout.wait()
        })
        let stream = await reader.read(URL(filePath: "/hung"), generation: .initial)
        let consumer = Task { await collect(stream) }
        let running = await eventually { started.values == [true] }
        XCTAssertTrue(running, "the read is hung on its lane")
        let returned = Recorder<Bool>()
        let cancelling = Task {
            await reader.cancelAll()
            returned.append(true)
        }
        let asked = await eventually { requested.values == [.seconds(1)] }
        XCTAssertTrue(asked, "cancelAll waits at most one second: \(requested.values)")
        try await Task.sleep(for: .milliseconds(50))         // negative check: may only false-pass
        XCTAssertEqual(returned.values, [], "a hung read keeps cancelAll waiting for the full timeout")
        await timeout.release()                               // the second is up
        await cancelling.value
        XCTAssertEqual(returned.values, [true])
        let stillHung = await reader.inFlightCount
        XCTAssertEqual(stillHung, 1, "cancelAll returned on the timeout, not because the read finished")
        gate.open()
        let (_, others) = await consumer.value
        XCTAssertFalse(others.contains { $0.hasPrefix("completed") }, "a cancelled read is not reported as complete")
    }

    func testCancelledReadThatStopsEarlyNeverYieldsCompleted() async throws {
        let emitted = Recorder<Int>()
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: calmLanes), types: .shared) { _, gen, _, _, ctx, emit in
            var n = 0
            while !ctx.isCancelled {                 // cooperative reader: stops with a partial count
                n += 1
                ctx.heartbeat()
                if !emit(Batch(generation: gen)) { break }
                emitted.append(n)
                usleep(2_000)
            }
            return ReadSummary(entryCount: n, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        let stream = await reader.read(URL(filePath: "/unused"), generation: .initial)
        let consumer = Task { await collect(stream) }
        let emitting = await eventually { !emitted.values.isEmpty }
        XCTAssertTrue(emitting, "the read emitted its first batch")
        await reader.cancelAll()
        let (batches, others) = await consumer.value
        XCTAssertFalse(batches.isEmpty)
        XCTAssertEqual(others, [], "partial listing: the stream just ends")
    }

    func testFallbackHeartbeatsWhileSkippingFilesForDirectoriesOnly() async throws {
        let dir = try FixtureTree.flat(in: sandbox, at: "files-only", count: 200)
        let job = LaneJob(id: 1, volume: vol, laneClass: .read, policy: .poison, onStall: nil)
        var options = ReadOptions()
        options.directoriesOnly = true
        let summary = try await Task.detached { [options] in               // readers never run on main
            try FallbackReader.read(dir, generation: .initial, options: options, types: .shared,
                                    context: LaneContext(job: job)) { _ in true }
        }.value
        XCTAssertEqual(summary.entryCount, 0)
        XCTAssertNotEqual(job.lastBeat.load(ordering: .relaxed), 0, "progress is reported even when no batch fills")
    }

    func testItemReaderHeartbeatsPerStat() async throws {
        let dir = try sandbox.createDirectory("beats")
        try sandbox.createFile("beats/a.txt")
        let job = LaneJob(id: 1, volume: vol, laneClass: .read, policy: .poison, onStall: nil)
        _ = try await Task.detached {
            try ItemReader.read(names: ["a.txt", "b"], in: dir, generation: .initial, types: .shared, context: LaneContext(job: job))
        }.value
        XCTAssertNotEqual(job.lastBeat.load(ordering: .relaxed), 0)
    }

    func testFallbackDegradedRowsKeepDistinctIdentities() async throws {
        let dir = try sandbox.createDirectory("unsearchable")
        try sandbox.createFile("unsearchable/a.txt")
        try sandbox.createFile("unsearchable/b.txt")
        try sandbox.setMode("unsearchable", 0o400)                    // readdir works, fstatat → EACCES
        defer { try? sandbox.setMode("unsearchable", 0o755) }
        let job = LaneJob(id: 1, volume: vol, laneClass: .read, policy: .poison, onStall: nil)
        let (summary, batches) = try await Task.detached {
            var batches: [Batch] = []
            let summary = try FallbackReader.read(dir, generation: .initial, options: ReadOptions(), types: .shared,
                                                  context: LaneContext(job: job)) { batches.append($0); return true }
            return (summary, batches)
        }.value
        XCTAssertEqual(summary.degradedCount, 2)
        var store = EntryStore(identityMode: .objectID)
        for b in batches { store.append(b) }
        XCTAssertEqual(store.count, 2)
        XCTAssertTrue((0..<2).allSatisfy { store.entry(UInt32($0)).fileID != 0 }, "d_ino is the file ID")
        XCTAssertNotEqual(store.identity(0), store.identity(1))
        XCTAssertEqual(store.errno(0), EACCES)
    }

    func testReadItemsReportsPresentAndMissing() async throws {
        let dir = try sandbox.createDirectory("items")
        try sandbox.createFile("items/a.txt")
        try sandbox.createSymlink("items/link", target: "nowhere")
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: calmLanes))
        let result = try await reader.readItems(["a.txt", "gone.txt", "link"], in: dir, generation: .initial)
        XCTAssertEqual((0..<result.batch.count).map { result.batch.name(at: $0) }, ["a.txt", "link"])
        XCTAssertEqual(result.batch.entries[1].kind, .symlink, "never follows symlinks")
        XCTAssertEqual(result.missing, ["gone.txt"])
        XCTAssertEqual(result.errors, [:])
    }

    func testReadItemsKeepsNamesThatFailForOtherReasons() async throws {
        let dir = try sandbox.createDirectory("noexec")
        try sandbox.createFile("noexec/a.txt")
        try sandbox.setMode("noexec", 0o400)                          // readable, not searchable: stat → EACCES
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: calmLanes))
        let result = try await reader.readItems(["a.txt"], in: dir, generation: .initial)
        try sandbox.setMode("noexec", 0o755)
        XCTAssertEqual(result.batch.count, 0)
        XCTAssertEqual(result.missing, [], "an unreadable name still exists")
        XCTAssertEqual(result.errors, ["a.txt": EACCES])
        let plain = try sandbox.createDirectory("plain")
        let long = String(repeating: "n", count: 300)
        let other = try await reader.readItems([long], in: plain, generation: .initial)
        XCTAssertEqual(other.errors, [long: ENAMETOOLONG])
    }

    func testReadItemsThrowsWhenTheDirectoryCannotBeOpened() async throws {
        let dir = try sandbox.createDirectory("locked")
        try sandbox.createFile("locked/a.txt")
        try sandbox.setMode("locked", 0o000)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: calmLanes))
        do {
            _ = try await reader.readItems(["a.txt"], in: dir, generation: .initial)
            XCTFail("expected a ReadFailure")
        } catch let failure as ReadFailure {
            XCTAssertEqual(failure, ReadFailure(code: EACCES, stage: .open))
        }
        try sandbox.setMode("locked", 0o755)
        let gone = try await reader.readItems(["a.txt", "b"], in: sandbox.url("vanished"), generation: .initial)
        XCTAssertEqual(gone.missing, ["a.txt", "b"], "a vanished directory means its names are gone")
    }
}
