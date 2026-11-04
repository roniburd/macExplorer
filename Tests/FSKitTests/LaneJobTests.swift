@testable import MacxFS
import Synchronization
import XCTest

/// LaneJob's stall state machine: the watchdog (actor) and the lane thread race on it, so every
/// transition and its notice happen under one lock.
private final class NoticeLog: Sendable {
    private let notices = Mutex<[StallNotice]>([])
    func append(_ notice: StallNotice) { notices.withLock { $0.append(notice) } }
    var all: [StallNotice] { notices.withLock { $0 } }
}

final class LaneJobTests: XCTestCase {
    private func job(_ policy: StallPolicy, log: NoticeLog) -> LaneJob {
        LaneJob(id: 1, volume: VolumeID(raw: "mnt:/test"), laneClass: .read, policy: policy) { log.append($0) }
    }

    func testAFinishedJobNeverReportsAStall() {
        let log = NoticeLog()
        let j = job(.awaitingPermission, log: log)
        XCTAssertTrue(j.markStalled(.waitingForPermission))
        j.markFinished()
        // The watchdog tick that runs after the work returned but before the pool forgot the job.
        XCTAssertFalse(j.markStalled(.waitingForPermission))
        XCTAssertEqual(log.all, [.waitingForPermission, .resumed])
    }

    func testHeartbeatResumesOnceAndAllowsANewWaitingNotice() {
        let log = NoticeLog()
        let j = job(.awaitingPermission, log: log)
        XCTAssertTrue(j.markStalled(.waitingForPermission))
        XCTAssertFalse(j.markStalled(.waitingForPermission), "one notice per stall")
        j.beat()
        j.beat()
        XCTAssertTrue(j.markStalled(.waitingForPermission))
        j.markFinished()
        j.markFinished()
        XCTAssertEqual(log.all, [.waitingForPermission, .resumed, .waitingForPermission, .resumed])
    }

    func testStallActionRunsBeforeTheNoticeAndNotWhenFinished() {
        let log = NoticeLog()
        let j = job(.poison, log: log)
        var actions = 0
        XCTAssertTrue(j.markStalled(.stalled) { actions += 1; XCTAssertTrue(log.all.isEmpty) })
        j.markFinished()
        XCTAssertFalse(j.markStalled(.stalled) { actions += 1 })
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(log.all, [.stalled, .resumed])
    }
}
