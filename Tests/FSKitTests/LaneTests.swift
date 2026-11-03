import CFSKit
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import XCTest

private let fast = WatchdogConfig(stallTimeout: .milliseconds(200), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 4)
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
        let pool = LanePool(config: fast)
        let (isMain, name) = try await pool.perform(on: volume) { _ in
            assertOffMain()
            return (Thread.isMainThread, Thread.current.name ?? "")
        }
        XCTAssertFalse(isMain)
        XCTAssertTrue(name.hasPrefix("macx.lane.read.mnt:/test."), name)
    }

    func testErrorsPropagate() async {
        struct Boom: Error {}
        let pool = LanePool(config: fast)
        do {
            _ = try await pool.perform(on: volume) { _ -> Int in throw Boom() }
            XCTFail("expected throw")
        } catch { XCTAssertTrue(error is Boom) }
    }

    func testAtMostLanesPerClassAndClassesAreSeparate() async throws {
        let pool = LanePool(config: fast)
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
        XCTAssertEqual(Set(lanesSeen.values).count, 4)
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

    func testHeartbeatingWorkIsNotPoisoned() async throws {
        let pool = LanePool(config: fast)
        let notices = Recorder<StallNotice>()
        try await pool.perform(on: volume, onStall: { notices.append($0) }) { ctx in
            for _ in 0..<12 { usleep(50_000); ctx.heartbeat() }   // 600 ms total, beats every 50 ms
        }
        XCTAssertEqual(notices.values, [])
        let count = await pool.poisonedCount(of: volume)
        XCTAssertEqual(count, 0)
    }

    func testAwaitingPermissionReportsWaitingAndNeverPoisons() async throws {
        let pool = LanePool(config: fast)
        let notices = Recorder<StallNotice>()
        try await pool.perform(on: volume, stallPolicy: .awaitingPermission, onStall: { notices.append($0) }) { _ in
            usleep(500_000)          // the TCC prompt is up
        }
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
        let pool = LanePool(config: config)
        let hung = gate()
        let a = Task { try await pool.perform(on: volume) { _ in hung.wait() } }
        try await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        let b = try await pool.perform(on: volume) { _ in "b" }            // queued behind `a` on the only lane
        XCTAssertEqual(b, "b")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        hung.open()
        _ = try await a.value
    }

    func testCancellingAQueuedJobThrowsCancelledWithoutRunningIt() async throws {
        let config = WatchdogConfig(stallTimeout: .seconds(30), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 4)
        let pool = LanePool(config: config)
        let busy = gate()
        let ran = Recorder<Bool>()
        let a = Task { try await pool.perform(on: volume) { _ in busy.wait() } }
        try await Task.sleep(for: .milliseconds(30))
        let b = Task { try await pool.perform(on: volume) { _ in ran.append(true) } }
        try await Task.sleep(for: .milliseconds(30))
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
        let pool = LanePool(config: fast)
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
        let pool = LanePool(config: fast)
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
