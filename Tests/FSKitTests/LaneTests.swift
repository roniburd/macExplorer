import CFSKit
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import XCTest

/// Stall tests: a job without a heartbeat for 200 ms is overdue.
private let fast = WatchdogConfig(stallTimeout: .milliseconds(200), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 4)
/// Tests that do not test stalls: on a slow, shared runner a descheduled lane thread must not be poisoned.
private let calm = WatchdogConfig(stallTimeout: .seconds(60), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 4)
private let volume = VolumeID(raw: "mnt:/test")

final class LaneTests: XCTestCase {
    private var gates: [Gate] = []

    override func tearDown() {
        for gate in gates { gate.open(count: 8) }   // never leave a lane thread blocked
        gates.removeAll()
        super.tearDown()
    }

    private func gate() -> Gate { let g = Gate(); gates.append(g); return g }

    func testWorkRunsOnNamedLaneThreadOffMain() async throws {
        let pool = LanePool(config: calm)
        let (isMain, name) = try await pool.perform(on: volume) { _ in
            assertOffMain()
            return (Thread.isMainThread, Thread.current.name ?? "")
        }
        XCTAssertFalse(isMain)
        XCTAssertTrue(name.hasPrefix("macx.lane.read.mnt:/test."), name)
    }

    func testScanClassHasItsOwnLanes() async throws {
        let pool = LanePool(config: calm)
        _ = try await pool.perform(on: .unknown, .scan) { _ in 1 }
        let scan = await pool.liveLaneCount(of: .unknown, .scan)
        let read = await pool.liveLaneCount(of: .unknown, .read)
        XCTAssertEqual(scan, 1); XCTAssertEqual(read, 0)
    }

    func testErrorsPropagate() async {
        struct Boom: Error {}
        let pool = LanePool(config: calm)
        do {
            _ = try await pool.perform(on: volume) { _ -> Int in throw Boom() }
            XCTFail("expected throw")
        } catch { XCTAssertTrue(error is Boom) }
    }

    func testAtMostLanesPerClassAndClassesAreSeparate() async throws {
        // A watchdog that never fires here: on a slow runner a descheduled 20 ms job must not poison its lane and
        // spawn a replacement (or leave the class with no live lane), which is what this test counts.
        let config = WatchdogConfig(stallTimeout: .seconds(60), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 4)
        let pool = LanePool(config: config)
        let lanesSeen = Recorder<UInt64>()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    try await pool.perform(on: volume, i.isMultiple(of: 3) ? .fileOp : .read) { ctx in
                        lanesSeen.append(ctx.laneID.raw)
                        usleep(20_000)
                        ctx.heartbeat()
                    }
                }
            }
            try await group.waitForAll()
        }
        let readCount = await pool.liveLaneCount(of: volume, .read)
        let opCount = await pool.liveLaneCount(of: volume, .fileOp)
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(opCount, 2)
        XCTAssertEqual(Set(lanesSeen.values).count, 4, "\(lanesSeen.values)")
    }

    /// The watchdog reads the clock once per pass; a lane that heartbeats after that read has a beat newer than
    /// `now`. That job is not overdue (the unsigned difference must not wrap into a huge stall).
    func testBeatNewerThanTheWatchdogsClockIsNotOverdue() {
        let limit = fast.stallNanoseconds
        XCTAssertFalse(WatchdogConfig.isOverdue(lastBeat: 1_000_000_500, now: 1_000_000_000, limit: limit))
        XCTAssertFalse(WatchdogConfig.isOverdue(lastBeat: 0, now: 1_000_000_000, limit: limit), "not started")
        XCTAssertFalse(WatchdogConfig.isOverdue(lastBeat: 1_000_000_000, now: 1_000_000_000 + limit - 1, limit: limit))
        XCTAssertTrue(WatchdogConfig.isOverdue(lastBeat: 1_000_000_000, now: 1_000_000_000 + limit, limit: limit))
    }

    func testHungReadPoisonsLaneAndRetryGetsFreshLane() async throws {
        let pool = LanePool(config: fast)
        let hung = gate()
        let notices = Recorder<StallNotice>()
        let hungLane = Recorder<UInt64>()
        let late = Task {
            try await pool.perform(on: volume, onStall: { notices.append($0) }) { ctx -> String in
                hungLane.append(ctx.laneID.raw)
                hung.wait()                    // simulated hung getattrlistbulk: no heartbeat
                return "late"
            }
        }
        let stalled = await eventually { notices.values == [.stalled] }
        XCTAssertTrue(stalled)
        let poisonedCount = await pool.poisonedCount(of: volume)
        let health = await pool.health(of: volume)
        XCTAssertEqual(poisonedCount, 1)
        XCTAssertEqual(health, .healthy)

        // Retry: a fresh lane answers while the poisoned one is still blocked.
        let retryLane = try await pool.perform(on: volume) { ctx in ctx.laneID.raw }
        XCTAssertNotEqual(retryLane, hungLane.values.first)

        hung.open()
        let value = try await late.value                 // the late result still arrives…
        XCTAssertEqual(value, "late")
        XCTAssertEqual(notices.values, [.stalled, .resumed])
        // …and the poisoned lane is never used again.
        for _ in 0..<5 {
            let lane = try await pool.perform(on: volume) { ctx in ctx.laneID.raw }
            XCTAssertNotEqual(lane, hungLane.values.first)
        }
    }

    /// The manual watchdog clock: time passes only when the test advances it, and the watchdog looks only when the
    /// test runs a pass. A job without heartbeats is overdue at exactly the stall timeout, not a moment before.
    func testManualWatchdogClockReportsAStallOnlyAtTheTimeout() async throws {
        let clock = ManualClock()
        let pool = LanePool(config: fast, manualClock: { clock.now })
        let notices = Recorder<StallNotice>()
        let started = Recorder<Bool>()
        let hung = gate()
        let work = Task {
            try await pool.perform(on: volume, onStall: { notices.append($0) }) { _ in
                started.append(true)
                hung.wait()                    // no heartbeat
            }
        }
        let running = await eventually { started.values == [true] }
        XCTAssertTrue(running)
        clock.advance(by: .milliseconds(199))
        await pool.runWatchdogPass()
        XCTAssertEqual(notices.values, [], "1 ms before the stall timeout")
        clock.advance(by: .milliseconds(1))
        await pool.runWatchdogPass()
        XCTAssertEqual(notices.values, [.stalled])
        let poisonedCount = await pool.poisonedCount(of: volume)
        XCTAssertEqual(poisonedCount, 1)
        hung.open()
        try await work.value
        XCTAssertEqual(notices.values, [.stalled, .resumed])
    }

    /// 12 heartbeats, each followed by 150 ms (under the 200 ms stall timeout) and a watchdog pass: 1.8 s of work
    /// without a stall notice. Time is the manual clock, so a descheduled lane thread cannot look like a stall.
    func testHeartbeatingWorkIsNotPoisoned() async throws {
        let clock = ManualClock()
        let pool = LanePool(config: fast, manualClock: { clock.now })
        let notices = Recorder<StallNotice>()
        let beats = Recorder<Int>()
        let step = gate()
        let work = Task {
            try await pool.perform(on: volume, onStall: { notices.append($0) }) { ctx in
                for i in 0..<12 {
                    ctx.heartbeat()
                    beats.append(i)
                    step.wait()
                }
            }
        }
        for i in 0..<12 {
            let beat = await eventually { beats.values.count == i + 1 }
            XCTAssertTrue(beat, "heartbeat \(i)")
            clock.advance(by: .milliseconds(150))
            await pool.runWatchdogPass()
            XCTAssertEqual(notices.values, [], "after heartbeat \(i)")
            step.open()
        }
        try await work.value
        XCTAssertEqual(notices.values, [])
        let count = await pool.poisonedCount(of: volume)
        XCTAssertEqual(count, 0)
    }

    func testAwaitingPermissionReportsWaitingAndNeverPoisons() async throws {
        let clock = ManualClock()
        let pool = LanePool(config: fast, manualClock: { clock.now })
        let notices = Recorder<StallNotice>()
        let started = Recorder<Bool>()
        let prompt = gate()
        let work = Task {
            try await pool.perform(on: volume, stallPolicy: .awaitingPermission, onStall: { notices.append($0) }) { _ in
                started.append(true)
                prompt.wait()            // the TCC prompt is up: no heartbeat
            }
        }
        let running = await eventually { started.values == [true] }
        XCTAssertTrue(running)
        for _ in 0..<3 {                 // well past the stall timeout, several watchdog passes
            clock.advance(by: .milliseconds(250))
            await pool.runWatchdogPass()
        }
        XCTAssertEqual(notices.values, [.waitingForPermission], "one notice per wait")
        let lanesWhileWaiting = await pool.liveLaneCount(of: volume, .read)
        XCTAssertEqual(lanesWhileWaiting, 1)
        prompt.open()
        try await work.value
        XCTAssertEqual(notices.values, [.waitingForPermission, .resumed])
        let count = await pool.poisonedCount(of: volume)
        let lanes = await pool.liveLaneCount(of: volume, .read)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(lanes, 1)
    }

    func testPoisonCapMarksVolumeUnresponsiveUntilReset() async throws {
        let config = WatchdogConfig(stallTimeout: .milliseconds(150), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 2)
        let pool = LanePool(config: config)
        let healthEvents = Recorder<VolumeHealth>()
        let watcher = Task {
            for await (id, health) in pool.healthChanges where id == volume { healthEvents.append(health) }
        }
        defer { watcher.cancel() }
        let hung = gate()
        let other = VolumeID(raw: "mnt:/other")
        let a = Task { try await pool.perform(on: volume) { _ in hung.wait() } }
        let b = Task { try await pool.perform(on: volume) { _ in hung.wait() } }
        let marked = await eventually { await pool.health(of: volume) == .unresponsive }
        XCTAssertTrue(marked)
        do {
            try await pool.perform(on: volume) { _ in }
            XCTFail("an unresponsive volume must not get new reads")
        } catch {
            XCTAssertEqual(error as? LaneError, .volumeUnresponsive(volume))
        }
        let otherValue = try await pool.perform(on: other) { _ in 7 }      // other volumes unaffected
        XCTAssertEqual(otherValue, 7)

        await pool.resetVolume(volume)                                     // remount
        let health = await pool.health(of: volume)
        XCTAssertEqual(health, .healthy)
        let after = try await pool.perform(on: volume) { _ in 1 }
        XCTAssertEqual(after, 1)
        let sawBoth = await eventually { healthEvents.values == [.unresponsive, .healthy] }
        XCTAssertTrue(sawBoth, "\(healthEvents.values)")
        hung.open(count: 2)
        _ = try await (a.value, b.value)
    }

    func testJobsQueuedBehindAHungJobMoveToAFreshLane() async throws {
        let config = WatchdogConfig(stallTimeout: .milliseconds(150), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 4)
        let clock = ManualClock()
        let pool = LanePool(config: config, manualClock: { clock.now })
        let hung = gate()
        let hungLane = Recorder<UInt64>()
        let a = Task {
            try await pool.perform(on: volume) { ctx in
                hungLane.append(ctx.laneID.raw)
                hung.wait()
            }
        }
        let aRunning = await eventually { hungLane.values.count == 1 }
        XCTAssertTrue(aRunning, "a occupies the only lane")
        let b = Task { try await pool.perform(on: volume) { ctx in ctx.laneID.raw } }
        let bQueued = await eventually { await pool.inFlightJobCount == 2 }
        XCTAssertTrue(bQueued, "b is queued behind a")
        clock.advance(by: .milliseconds(150))
        await pool.runWatchdogPass()                                       // poisons a's lane, re-dispatches b
        let bLane = try await b.value
        XCTAssertNotEqual(bLane, hungLane.values.first, "b ran on a fresh lane")
        let poisonedCount = await pool.poisonedCount(of: volume)
        XCTAssertEqual(poisonedCount, 1)
        hung.open()
        _ = try await a.value
    }

    func testCancellingAQueuedJobThrowsCancelledWithoutRunningIt() async throws {
        let config = WatchdogConfig(stallTimeout: .seconds(30), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 4)
        let pool = LanePool(config: config)
        let busy = gate()
        let ran = Recorder<Bool>()
        let started = Recorder<Bool>()
        let a = Task {
            try await pool.perform(on: volume) { _ in
                started.append(true)
                busy.wait()
            }
        }
        let aRunning = await eventually { started.values == [true] }
        XCTAssertTrue(aRunning, "a occupies the only lane")
        let b = Task { try await pool.perform(on: volume) { _ in ran.append(true) } }
        let bQueued = await eventually { await pool.inFlightJobCount == 2 }
        XCTAssertTrue(bQueued, "b is queued behind a")
        b.cancel()
        do {
            try await b.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? LaneError, .cancelled)
        }
        busy.open()
        _ = try await a.value
        XCTAssertEqual(ran.values, [])
    }

    func testRunningJobSeesCancellation() async throws {
        let pool = LanePool(config: calm)
        let started = Recorder<Bool>()
        let task = Task {
            try await pool.perform(on: volume) { ctx -> Bool in
                started.append(true)
                while !ctx.isCancelled { usleep(5_000); ctx.heartbeat() }
                return true
            }
        }
        _ = await eventually { started.values == [true] }
        task.cancel()
        let sawCancel = try await task.value
        XCTAssertTrue(sawCancel)
    }

    func testNoMaterializationAppliesOnlyInsideBody() async throws {
        let pool = LanePool(config: calm)
        let (inside, after) = try await pool.perform(on: volume) { _ in
            let inside = withNoMaterialization {
                getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            }
            return (inside, getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD))
        }
        XCTAssertEqual(inside, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertNotEqual(after, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    func testGenerationOrdering() {
        let g0 = Generation.initial
        let g1 = g0.next()
        XCTAssertEqual(g0.raw, 0)
        XCTAssertEqual(g1.raw, 1)
        XCTAssertLessThan(g0, g1)
        XCTAssertEqual(g1.next().description, "gen2")
    }

    @MainActor
    func testObserversDeliverInOrderAndTokensCancel() {
        let observers = Observers<Int>()
        var log: [String] = []
        let a = observers.add { log.append("a\($0)") }
        var b: ObserverToken? = observers.add { log.append("b\($0)") }
        observers.send(1)
        b = nil                                   // deinit cancels
        observers.send(2)
        a.cancel(); a.cancel()                    // idempotent
        observers.send(3)
        XCTAssertEqual(log, ["a1", "b1", "a2"])
        XCTAssertTrue(observers.isEmpty)
        _ = b
    }

    func testAssertOffMainTrapsOnMainThread() throws {
        #if DEBUG
        if TrapProbe.value(TrapProbe.environmentKey) != nil { throw XCTSkip("in child") }
        let result = try TrapProbe.run(name: "main", testIdentifier: "FSKitTests.LaneTrapProbes/testProbeAssertOffMainOnMain",
                                       bundle: Bundle(for: LaneTests.self).bundleURL)
        XCTAssertTrue(result.trapped, "status \(result.status)\n\(result.output.suffix(1500))")
        #else
        throw XCTSkip("assertOffMain is a no-op in release builds")
        #endif
    }
}

final class LaneTrapProbes: XCTestCase {
    func testProbeAssertOffMainOnMain() throws {
        guard TrapProbe.isChild("main") else { throw XCTSkip("trap probe child only") }
        XCTAssertTrue(Thread.isMainThread)
        assertOffMain()
        XCTFail("assertOffMain did not trap on the main thread")
    }
}
