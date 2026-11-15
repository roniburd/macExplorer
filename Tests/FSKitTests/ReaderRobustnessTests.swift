import CFSKit
import Darwin
import Foundation
import Synchronization
import MacxFixtures
@testable import MacxFS
import XCTest

private let vol = VolumeID(raw: "mnt:/reader-robustness-tests")

/// BulkReader on a malformed getattrlistbulk buffer, FallbackReader cancellation, ItemReader name validation.
final class ReaderRobustnessTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func context() -> LaneContext {
        LaneContext(job: LaneJob(id: 1, volume: vol, laneClass: .read, policy: .poison, onStall: nil))
    }

    /// A real bulk read whose first buffer gets a zero length written into record `index` (CFSK_NEXT_TRUNCATED there).
    private static func corrupting(record index: Int) -> BulkReader.BulkRead {
        nonisolated(unsafe) var calls = 0
        return { fd, buffer, size in
            let n = cfsk_bulk_read(fd, buffer, size)
            calls += 1
            guard calls == 1, n > Int32(index) else { return n }
            var offset = 0
            for _ in 0..<index { offset += Int(buffer.load(fromByteOffset: offset, as: UInt32.self)) }
            buffer.storeBytes(of: UInt32(0), toByteOffset: offset, as: UInt32.self)
            return n
        }
    }

    private func names(_ batches: [Batch]) -> [String] {
        batches.flatMap { b in (0..<b.count).map { b.name(at: $0) } }.sorted()
    }

    func testTruncatedBufferBeforeAnyBatchFallsBackToReaddir() async throws {
        let dir = try FixtureTree.flat(in: sandbox, at: "flat", count: 10)
        var options = ReadOptions()
        options.batchSize = 1
        let ctx = context()
        let (summary, batches) = try await Task.detached {
            var batches: [Batch] = []
            let summary = try BulkReader.read(dir, generation: .initial, options: options, types: .shared, context: ctx,
                                              bulkRead: Self.corrupting(record: 0)) { batches.append($0); return true }
            return (summary, batches)
        }.value
        XCTAssertTrue(summary.usedFallback, "nothing emitted yet: the fallback reads the whole folder")
        XCTAssertEqual(summary.entryCount, 10)
        XCTAssertEqual(names(batches), (1...10).map { String(format: "file-%06d.txt", $0) })
    }

    func testTruncatedBufferAfterBatchesFailsInsteadOfCompleting() async throws {
        let dir = try FixtureTree.flat(in: sandbox, at: "flat", count: 10)
        var options = ReadOptions()
        options.batchSize = 1
        let ctx = context()
        let (result, emitted) = await Task.detached { () -> (Result<ReadSummary, ReadFailure>, Int) in
            var emitted = 0
            do throws(ReadFailure) {
                let summary = try BulkReader.read(dir, generation: .initial, options: options, types: .shared, context: ctx,
                                                  bulkRead: Self.corrupting(record: 3)) { _ in emitted += 1; return true }
                return (.success(summary), emitted)
            } catch {
                return (.failure(error), emitted)
            }
        }.value
        XCTAssertEqual(emitted, 3)
        XCTAssertEqual(result.failure, ReadFailure(code: EIO, stage: .truncatedRecords),
                       "a listing missing the rest of the buffer is never reported complete")
    }

    /// Cancelled during the read, from the heartbeat clock after `cancelAfter` heartbeats (one per readdir entry).
    private final class CancelAfterBeats: Sendable {
        let job = Mutex<LaneJob?>(nil)
        let beats = Atomic<Int>(0)
        let cancelAfter: Int
        init(_ n: Int) { cancelAfter = n }
        func clock() -> UInt64 {
            if beats.add(1, ordering: .relaxed).newValue == cancelAfter {
                job.withLock { $0 }?.cancelled.store(true, ordering: .relaxed)
            }
            return LaneJob.now()
        }
    }

    func testFallbackChecksCancellationPerEntry() async throws {
        let dir = try FixtureTree.flat(in: sandbox, at: "flat", count: 50)
        let cancel = CancelAfterBeats(11)        // 10 readdir entries, then cancelled before the 11th
        let job = LaneJob(id: 1, volume: vol, laneClass: .read, policy: .poison, onStall: nil, clock: { cancel.clock() })
        cancel.job.withLock { $0 = job }
        var options = ReadOptions()
        options.batchSize = 10_000              // never flushes on its own: only the per-entry check stops it
        options.batchInterval = .seconds(3_600)
        let (summary, emitted) = try await Task.detached {
            var emitted = 0
            let summary = try FallbackReader.read(dir, generation: .initial, options: options, types: .shared,
                                                  context: LaneContext(job: job)) { _ in emitted += 1; return true }
            return (summary, emitted)
        }.value
        XCTAssertTrue((8...10).contains(summary.entryCount), "stopped mid-read (10 entries less \".\"/\"..\"), got \(summary.entryCount)")
        XCTAssertEqual(emitted, 0, "a cancelled read emits nothing")
    }

    func testItemReaderReportsNonEntryNamesMissingWithoutStattingThem() async throws {
        let dir = try sandbox.createDirectory("items")
        try sandbox.createFile("items/ok.txt")
        try sandbox.createFile("items/sub/inner.txt")
        try sandbox.createFile("sibling.txt")
        let names = ["ok.txt", "sub/inner.txt", "../sibling.txt", ".", "..", "", "nul\u{0}ok.txt"]
        let ctx = context()
        let result = try await Task.detached {
            try ItemReader.read(names: names, in: dir, generation: .initial, types: .shared, context: ctx)
        }.value
        XCTAssertEqual((0..<result.batch.count).map { result.batch.name(at: $0) }, ["ok.txt"])
        XCTAssertEqual(result.missing, Array(names.dropFirst()))
        XCTAssertEqual(result.errors, [:])
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { e } else { nil } }
}
