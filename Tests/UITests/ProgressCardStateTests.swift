import XCTest
@testable import UI
import Core

@MainActor
final class ProgressCardStateTests: XCTestCase {
    private let t0 = ContinuousClock.now

    private func job(startedAt: ContinuousClock.Instant, state: JobState = .running) -> JobSnapshot {
        JobSnapshot(id: JobID(), description: JobDescription(verb: .copying, itemCount: 1, firstItemName: "big.mov",
                                                             sourceFolderName: "Documents", destinationFolderName: "Desktop"),
                    state: state, progress: .zero, origin: nil, startedAt: startedAt)
    }

    func testOpensOnlyAfterTheJobRanFourSeconds() {
        let card = ProgressCardState()
        let a = job(startedAt: t0)
        card.update(jobs: [a], now: t0 + .seconds(1))
        XCTAssertFalse(card.isOpen, "a job under 4 s shows only the capsule")
        card.update(jobs: [a], now: t0 + .milliseconds(3_999))
        XCTAssertFalse(card.isOpen)
        card.update(jobs: [a], now: t0 + .seconds(4))
        XCTAssertTrue(card.isOpen)
    }

    func testClosingSticksForRunningJobsAndANewLongJobReopens() {
        let card = ProgressCardState()
        let a = job(startedAt: t0)
        card.update(jobs: [a], now: t0 + .seconds(5))
        card.close(jobs: [a])
        XCTAssertFalse(card.isOpen)
        XCTAssertEqual(card.closeCount, 1, "the capsules pulse once")
        card.update(jobs: [a], now: t0 + .seconds(60))
        XCTAssertFalse(card.isOpen, "closed stays closed for the jobs already running")
        let b = job(startedAt: t0 + .seconds(60))
        card.update(jobs: [a, b], now: t0 + .seconds(62))
        XCTAssertFalse(card.isOpen, "the new job has not run 4 s yet")
        card.update(jobs: [a, b], now: t0 + .seconds(64))
        XCTAssertTrue(card.isOpen, "a new job that runs 4 s opens it again")
    }

    func testToggleOpensWithoutWaitingAndClosesWithPulse() {
        let card = ProgressCardState()
        let a = job(startedAt: t0)
        card.toggle(jobs: [a])
        XCTAssertTrue(card.isOpen, "the capsule opens the card at once")
        card.update(jobs: [a], now: t0 + .seconds(10))
        XCTAssertTrue(card.isOpen)
        card.toggle(jobs: [a])
        XCTAssertFalse(card.isOpen)
        XCTAssertEqual(card.closeCount, 1)
        card.update(jobs: [a], now: t0 + .seconds(20))
        XCTAssertFalse(card.isOpen, "opening by hand counts the job as seen: it does not reopen on its own")
        card.toggle(jobs: [])
        XCTAssertFalse(card.isOpen, "nothing to show: the capsule does not open an empty card")
    }

    func testHidesWithoutPulseWhenEverythingFinishes() {
        let card = ProgressCardState()
        let a = job(startedAt: t0)
        card.update(jobs: [a], now: t0 + .seconds(5))
        XCTAssertTrue(card.isOpen)
        card.update(jobs: [], now: t0 + .seconds(6))
        XCTAssertFalse(card.isOpen)
        XCTAssertEqual(card.closeCount, 0, "no capsule to point at once the work is done")
        card.close(jobs: [])
        XCTAssertEqual(card.closeCount, 0, "closing a closed card is a no-op")
    }

    func testFinishedJobsAreForgotten() {
        let card = ProgressCardState()
        let a = job(startedAt: t0)
        card.update(jobs: [a], now: t0 + .seconds(5))
        card.close(jobs: [a])
        card.update(jobs: [], now: t0 + .seconds(6))
        // The same id can't come back, but a later job must open the card again after everything went idle.
        let b = job(startedAt: t0 + .seconds(10))
        card.update(jobs: [b], now: t0 + .seconds(14))
        XCTAssertTrue(card.isOpen)
    }

    func testVisibleRowsCapAtThreeUntilExpanded() {
        XCTAssertEqual(ProgressCardState.rows(count: 2, expanded: false), .init(shown: 2, hidden: 0))
        XCTAssertEqual(ProgressCardState.rows(count: 5, expanded: false), .init(shown: 3, hidden: 2))
        XCTAssertEqual(ProgressCardState.rows(count: 5, expanded: true), .init(shown: 5, hidden: 0))
    }
}
