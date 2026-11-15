import XCTest
@testable import UI
import Core

extension UIContext {
    /// Harness teardown: end the environment's jobs the way quitting does (AppLifecycle `.stopAndQuit`). The app's
    /// router stops answering, so its dialogs return their fallback; every job is cancelled. A job still running after
    /// `timeout` (one waiting on a dialog of a router nobody stops) is reported as a failure. Teardown used to wait
    /// for such a job forever, which hung whole test runs (one CI run hit its 45-minute limit).
    func stopJobsForTeardown(timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line) async {
        operationsUI.router.stopAnswering()
        if await environment.termination.stopAllAndWait(timeout: timeout) { return }
        let jobs = await environment.fileOps.snapshots().map { "\($0.description.verb) \($0.state)" }
        XCTFail("teardown: jobs still running after \(timeout), most likely waiting on a dialog nobody answered: \(jobs)",
                file: file, line: line)
    }
}
