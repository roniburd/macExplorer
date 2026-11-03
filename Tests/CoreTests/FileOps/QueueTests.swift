import XCTest
import Synchronization
@testable import Core
import MacxFS

final class EventLog: Sendable {
    private let m = Mutex<[String]>([])
    func add(_ s: String) { m.withLock { $0.append(s) } }
    var all: [String] { m.withLock { $0 } }
}

final class QueueTests: FileOpsTestCase {
    /// Body used by scheduling tests: logs start/end with the first source's name.
    private func timedBody(_ log: EventLog, _ duration: Duration) -> @Sendable (JobContext) async -> Void {
        { ctx in
            let name = ctx.kind.allURLs.first?.lastPathComponent ?? "?"
            log.add("start \(name)")
            try? await Task.sleep(for: duration)
            log.add("end \(name)")
        }
    }

    func testSameVolumeJobsRunFIFO() async throws {
        let log = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = timedBody(log, .milliseconds(150))
        let (queue, _) = makeQueue(tuning: tuning)
        let a = try file("a"), b = try file("b"), d = try dir("d")
        let ida = await queue.enqueue(JobRequest(.copy(sources: [a], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [b], destination: d)))
        _ = await queue.outcome(of: ida)
        _ = await queue.outcome(of: idb)
        XCTAssertEqual(log.all, ["start a", "end a", "start b", "end b"])
    }

    func testDisjointVolumesRunConcurrently() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let log = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = timedBody(log, .milliseconds(300))
        let (queue, _) = makeQueue(tuning: tuning)
        let a = try file("a"), d = try dir("d")
        let b = mnt.appending(path: "b"); try Data("b".utf8).write(to: b)
        let d2 = mnt.appending(path: "d2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: d2, withIntermediateDirectories: false)
        let ida = await queue.enqueue(JobRequest(.copy(sources: [a], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [b], destination: d2)))
        _ = await queue.outcome(of: ida)
        _ = await queue.outcome(of: idb)
        XCTAssertEqual(Set(log.all.prefix(2)), ["start a", "start b"], "both started before either ended: \(log.all)")
    }

    func testPauseResumeCancelRunningJob() async throws {
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            ctx.setTotals(items: 400, bytes: nil)
            for _ in 0..<400 {
                guard await ctx.checkpoint() else { return }
                ctx.addProgress(items: 1)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let (queue, _) = makeQueue(tuning: tuning)
        let id = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: try dir("d"))))
        await waitUntil { await queue.snapshots().first?.progress.itemsDone ?? 0 > 5 }
        await queue.pause(id)
        try await Task.sleep(for: .milliseconds(60))
        let paused = await queue.snapshots().first!
        XCTAssertEqual(paused.state, .paused)
        try await Task.sleep(for: .milliseconds(150))
        let stillPaused = await queue.snapshots().first!
        XCTAssertEqual(stillPaused.progress.itemsDone, paused.progress.itemsDone)
        await queue.resume(id)
        await waitUntil { await queue.snapshots().first?.progress.itemsDone ?? 0 > paused.progress.itemsDone + 3 }
        await queue.cancel(id)
        let outcome = await queue.outcome(of: id)
        XCTAssertTrue(outcome.wasCancelled)
        let hasActive = await queue.hasActiveJobs
        XCTAssertFalse(hasActive)
    }

    func testProgressUpdatesAreAtMost10Hz() async throws {
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            for _ in 0..<500 { ctx.addProgress(bytes: 10); try? await Task.sleep(for: .milliseconds(1)) }
        }
        let (queue, _) = makeQueue(tuning: tuning)
        let counter = EventLog()
        let consumer = Task {
            for await e in queue.events {
                switch e {
                case .added: counter.add("added")
                case .updated: counter.add("updated")
                case .finished: counter.add("finished"); return
                }
            }
        }
        let start = ContinuousClock.now
        let id = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: try dir("d"))))
        _ = await queue.outcome(of: id)
        await consumer.value
        let elapsed = (ContinuousClock.now - start).inSeconds
        let updates = counter.all.filter { $0 == "updated" }.count
        XCTAssertEqual(counter.all.first, "added")
        XCTAssertEqual(counter.all.last, "finished")
        XCTAssertGreaterThanOrEqual(updates, 1)
        XCTAssertLessThanOrEqual(Double(updates), elapsed * 10 + 2, "\(updates) updates in \(elapsed) s")
    }

    func testCancelQueuedJobFinishesWithoutRunning() async throws {
        let log = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = timedBody(log, .milliseconds(200))
        let (queue, _) = makeQueue(tuning: tuning)
        let d = try dir("d")
        let ida = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [try file("b")], destination: d)))
        await queue.cancel(idb)
        let ob = await queue.outcome(of: idb)
        XCTAssertTrue(ob.wasCancelled)
        _ = await queue.outcome(of: ida)
        XCTAssertFalse(log.all.contains("start b"))
    }

    func testCancelAllReturnsWhenEveryJobFinished() async throws {
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in while await ctx.checkpoint() { try? await Task.sleep(for: .milliseconds(5)) } }
        let (queue, _) = makeQueue(tuning: tuning)
        let d = try dir("d")
        for n in ["a", "b", "c"] { await queue.enqueue(JobRequest(.copy(sources: [try file(n)], destination: d))) }
        await queue.cancelAll()
        let active = await queue.hasActiveJobs
        XCTAssertFalse(active)
        let snaps = await queue.snapshots()
        XCTAssertEqual(snaps, [])
    }

    func testSuspendJobsTouchingMountPointPausesQueuedAndReportsRunning() async throws {
        let gate = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            gate.add("run \(ctx.kind.allURLs.first!.lastPathComponent)")
            while await ctx.checkpoint(), !gate.all.contains("release") { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let (queue, _) = makeQueue(tuning: tuning)
        let d = try dir("d")
        let ida = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [try file("b")], destination: d)))
        await waitUntil { gate.all.contains("run a") }
        let running = await queue.suspendJobs(touching: root)
        XCTAssertEqual(running, [ida])
        gate.add("release")
        _ = await queue.outcome(of: ida)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(gate.all.contains("run b"), "suspended job must not start")
        let stateB = await queue.snapshots().first { $0.id == idb }?.state
        XCTAssertEqual(stateB, .paused)
        await queue.resume(idb)
        _ = await queue.outcome(of: idb)
        XCTAssertTrue(gate.all.contains("run b"))
    }

    func testRegistersUndoFlagIsKept() async throws {
        var tuning = FileOpTuning()
        tuning.bodyOverride = { _ in }
        let (queue, _) = makeQueue(tuning: tuning)
        let id1 = await queue.enqueue(JobRequest(.trash([try file("a")]), registersUndo: false))
        let id2 = await queue.enqueue(JobRequest(.trash([try file("b")])))
        _ = await queue.outcome(of: id1); _ = await queue.outcome(of: id2)
        let r1 = await queue.registersUndo(id1), r2 = await queue.registersUndo(id2)
        XCTAssertFalse(r1); XCTAssertTrue(r2)
    }

    /// Review Focus 1 at job level: the plan phase asks per refused item and continues with the rest.
    func testPlanPhaseReportsIntoItselfPerItemAndContinues() async throws {
        let scripted = ScriptedInteraction(errors: [.skip])
        let a = try dir("A/sub"), b = try file("B")
        let bigA = url("A")
        let planned = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            if let plan = await ctx.plan(sources: [bigA, b], destination: a, mode: .copy) {
                planned.add(plan.items.map(\.source.lastPathComponent).joined(separator: ","))
            }
        }
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let outcome = try await run(.copy(sources: [url("A"), b], destination: a), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.intoItself])
        XCTAssertEqual(outcome.skipped, [SkippedItem(url: url("A"), reason: .intoItself)])
        XCTAssertEqual(planned.all, ["B"])
    }

    func testInsufficientSpacePromptsBeforeExecution() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let big = try bigFile("big", bytes: 40 << 20)
        let scripted = ScriptedInteraction(space: [false])
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in _ = await ctx.plan(sources: [big], destination: mnt, mode: .copy) }
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let id = await queue.enqueue(JobRequest(.copy(sources: [big], destination: mnt)))
        let outcome = await queue.outcome(of: id)
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(scripted.askedSpace().count, 1)
        XCTAssertGreaterThan(scripted.askedSpace()[0].needed, scripted.askedSpace()[0].available)
    }

    /// The boot volume's mount point is "/": every absolute path is on it (P1-18's prefix test missed it).
    func testSuspendJobsTouchingTheRootMountPointPausesQueuedJobs() async throws {
        let gate = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            while await ctx.checkpoint(), !gate.all.contains("go") { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let (queue, _) = makeQueue(tuning: tuning)
        let d = try dir("d")
        let ida = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [try file("b")], destination: d)))
        await waitUntil { await queue.snapshots().first { $0.id == ida }?.state == .running }
        let running = await queue.suspendJobs(touching: URL(filePath: "/", directoryHint: .isDirectory))
        XCTAssertEqual(running, [ida])
        let stateB = await queue.snapshots().first { $0.id == idb }?.state
        XCTAssertEqual(stateB, .paused)
        gate.add("go")
        _ = await queue.outcome(of: ida)
        await queue.resume(idb)
        _ = await queue.outcome(of: idb)
    }
}
