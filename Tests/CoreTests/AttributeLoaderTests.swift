import XCTest
@testable import Core
import MacxFS

/// FolderModel's attribute-read bookkeeping (AttributeLoader) and re-read state (RereadState), extracted from
/// FolderModel: the queueing, stale-serial and re-read rules the model relies on. No I/O.
@MainActor
final class AttributeLoaderTests: XCTestCase {
    private func request(_ rows: Int...) -> AttributeRequest {
        AttributeRequest(rows: IndexSet(rows), wanted: .tags)
    }

    func testOneReadInFlightAndOnlyTheLatestRequestWaits() {
        var loader = AttributeLoader()
        XCTAssertEqual(loader.admit(request(0)), request(0), "nothing in flight: starts now")
        loader.task = Task {}
        XCTAssertNil(loader.admit(request(1)))
        XCTAssertNil(loader.admit(request(2)))
        XCTAssertEqual(loader.pending, request(2), "only the latest request is kept")
        loader.task = nil
        XCTAssertEqual(loader.takePending(), request(2))
        XCTAssertNil(loader.takePending(), "taken once")
    }

    func testAReadReplacesOnlyEntriesInvalidatedBeforeItBegan() {
        var loader = AttributeLoader()
        let before = RowID.name("before"), during = RowID.name("during"), fresh = RowID.name("fresh")
        loader.stale[before] = loader.beginInvalidation()
        let readSerial = loader.serial
        loader.stale[during] = loader.beginInvalidation()
        XCTAssertEqual(loader.adopt(before, readSerial: readSerial), true)
        XCTAssertNil(loader.stale[before], "replaced: no longer stale")
        XCTAssertEqual(loader.adopt(during, readSerial: readSerial), false)
        XCTAssertNotNil(loader.stale[during], "invalidated while the read ran: stays stale for the follow-up read")
        XCTAssertNil(loader.adopt(fresh, readSerial: readSerial), "not stale: the read merges")
        XCTAssertEqual(loader.serial, 2)
    }

    func testScheduledRefreshRunsOnceAndCancelDropsIt() {
        var loader = AttributeLoader()
        XCTAssertFalse(loader.takeScheduledRefresh())
        loader.scheduleRefresh()
        XCTAssertTrue(loader.takeScheduledRefresh())
        XCTAssertFalse(loader.takeScheduledRefresh(), "runs once")
        loader.scheduleRefresh()
        loader.cancel()
        XCTAssertFalse(loader.takeScheduledRefresh(), "closing cancels it")
    }

    func testResetDropsTheReadPendingRequestAndStaleMarksButKeepsTheRefresh() {
        var loader = AttributeLoader()
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        loader.task = task
        _ = loader.admit(request(1))
        loader.stale[.name("a")] = loader.beginInvalidation()
        loader.scheduleRefresh()
        loader.reset()
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(loader.task)
        XCTAssertNil(loader.pending)
        XCTAssertTrue(loader.stale.isEmpty)
        XCTAssertEqual(loader.serial, 1, "serials only grow")
        XCTAssertTrue(loader.refreshScheduled, "a fresh load re-issues the last request")
    }

    func testRereadStatePendingAndStalledOnlyWhileRunning() {
        var state = RereadState.idle
        state.setPending()
        state.setStalled(true)
        XCTAssertEqual(state, .idle, "no effect when idle")
        state = .running(pending: false, stalled: false)
        state.setStalled(true)
        XCTAssertTrue(state.isStalled)
        XCTAssertFalse(state.isPending)
        state.setPending()
        XCTAssertEqual(state, .running(pending: true, stalled: true))
        state.setStalled(false)
        XCTAssertEqual(state, .running(pending: true, stalled: false), "resuming keeps the pending re-read")
    }
}
