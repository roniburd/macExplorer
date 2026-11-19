import XCTest
@testable import Core
import MacxFS

/// The row of a file being copied shows its size growing: FSEvents reports a file's data writes only when it is
/// closed, so the copy names the file it is writing (JobProgress.writingNow) and OperationsCenter posts a
/// "modified" change for it about once a second.
@MainActor
final class WriteRefreshTests: FileOpsTestCase {
    private func modifiedPosts(_ bus: ChangeBus, _ log: MainLog<LocalChange>) -> ObserverToken {
        bus.observeAll { change in if !change.modified.isEmpty { log.items.append(change) } }
    }

    func testCopyNamesTheFileItIsWritingAndItsRowIsRefreshed() async throws {
        let w = world
        let big = try w.file("src/big.mov", String(repeating: "x", count: 4 << 20))
        let d = try w.dir("d")
        let reached = EventLog()
        let proceed = DispatchSemaphore(value: 0)
        var tuning = FileOpTuning(progressInterval: .milliseconds(20), copyChunkBytes: 1 << 20, faultHook: { point, _ in
            if point == .midCopyChunk, !reached.all.contains("chunk") { reached.add("chunk"); proceed.wait() }
        })
        tuning.allowClone = false
        let (queue, _) = w.makeQueue(tuning: tuning)
        let (center, _, bus) = makeCenter(queue)
        let log = MainLog<LocalChange>()
        let token = modifiedPosts(bus, log)
        defer { token.cancel() }
        let id = await queue.enqueue(w.request(.copy(sources: [big], destination: d)))
        await w.waitUntil { reached.all.contains("chunk") }
        let target = d.appending(path: "big.mov").standardizedFileURL
        await w.waitUntil { @MainActor in center.jobs.first?.progress.writingNow?.standardizedFileURL == target }
        await w.waitUntil { @MainActor in
            log.items.contains { $0.modified == ["big.mov"] && ChangeBus.key(for: $0.directory) == ChangeBus.key(for: d) }
        }
        proceed.signal()
        _ = await queue.outcome(of: id)
        await w.waitUntil { @MainActor in center.jobs.isEmpty }
    }

    func testRefreshesAreThrottledPerJobAndStopWhenTheWriteEnds() async throws {
        let w = world, gate = Gate(), stop = Gate()
        let d = try w.dir("d")
        let target = d.appending(path: "big.mov")
        var tuning = FileOpTuning(progressInterval: .milliseconds(20))
        tuning.bodyOverride = { ctx in
            ctx.setWriting(target)
            await stop.wait()
            ctx.setWriting(nil)
            await gate.wait()
        }
        let (queue, _) = w.makeQueue(tuning: tuning)
        let (center, _, bus) = makeCenter(queue)
        center.writeRefreshInterval = .milliseconds(150)
        let log = MainLog<LocalChange>()
        let token = modifiedPosts(bus, log)
        defer { token.cancel() }
        await queue.enqueue(w.request(.copy(sources: [try w.file("a")], destination: d)))
        await w.waitUntil { @MainActor in log.items.count >= 3 }
        let started = ContinuousClock.now
        let before = log.items.count
        try await Task.sleep(for: .milliseconds(450))
        let rate = Double(log.items.count - before) / ((ContinuousClock.now - started) / .milliseconds(150))
        XCTAssertLessThanOrEqual(rate, 1.5, "about one refresh per interval, not one per 20 ms progress tick")
        XCTAssertTrue(log.items.allSatisfy { $0.modified == ["big.mov"] })
        stop.open()
        await w.waitUntil { @MainActor in center.jobs.first?.progress.writingNow == nil }
        let settled = log.items.count
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(log.items.count, settled, "no refreshes once nothing is being written")
        gate.open()
        await w.waitUntil { @MainActor in center.jobs.isEmpty }
    }
}
