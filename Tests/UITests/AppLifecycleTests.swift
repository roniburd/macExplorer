import XCTest
import AppKit
import Observation
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
private final class FakeTerminator: JobTerminating {
    var activeCount: Int
    var result: Bool
    private(set) var stopCalls: [Duration] = []
    init(activeCount: Int, result: Bool = true) { self.activeCount = activeCount; self.result = result }
    func stopAllAndWait(timeout: Duration) async -> Bool {
        stopCalls.append(timeout)
        activeCount = 0
        return result
    }
}

@MainActor
private final class ScriptedQuitPrompts: QuitPrompting {
    var answer: QuitChoice
    private(set) var asked: [Int] = []
    private(set) var dismissals = 0
    init(_ answer: QuitChoice) { self.answer = answer }
    func confirmQuit(activeCount: Int) async -> QuitChoice {
        asked.append(activeCount)
        return answer
    }
    func dismiss() { dismissals += 1 }
}

/// A prompt the user never answers: it returns only when the lifecycle dismisses it (QA round 2).
@MainActor
private final class UnansweredQuitPrompts: QuitPrompting {
    private(set) var asked: [Int] = []
    private(set) var dismissals = 0
    private var continuation: CheckedContinuation<QuitChoice, Never>?
    func confirmQuit(activeCount: Int) async -> QuitChoice {
        asked.append(activeCount)
        return await withCheckedContinuation { continuation = $0 }
    }
    func dismiss() {
        dismissals += 1
        continuation?.resume(returning: .jobsFinished)
        continuation = nil
    }
}

@MainActor
private final class Recorder {
    var replies: [Bool] = []
    var badges: [String?] = []
    var flushes = 0
}

/// §6.7 quit with jobs (Stop and Quit / Cancel, 10 s), Dock badge, launch notices, settings flush.
@MainActor
final class AppLifecycleTests: XCTestCase {
    private func lifecycle(_ h: ShellHarness, _ terminator: any JobTerminating, _ prompts: any QuitPrompting,
                           _ r: Recorder) -> AppLifecycle {
        AppLifecycle(context: h.context, terminator: terminator, prompts: prompts,
                     reply: { r.replies.append($0) }, dockBadge: { r.badges.append($0) }, flushSettings: { r.flushes += 1 })
    }

    func testQuitWithNoJobsTerminatesNowWithoutAsking() async throws {
        let h = try await ShellHarness.make(self)
        let prompts = ScriptedQuitPrompts(.cancel), r = Recorder()
        let l = lifecycle(h, h.environment.termination, prompts, r)
        XCTAssertEqual(l.shouldTerminate(), .terminateNow)
        XCTAssertEqual(prompts.asked, [])
        XCTAssertEqual(r.replies, [])
    }

    func testCancelKeepsTheAppAndTheJobsRunning() async throws {
        let h = try await ShellHarness.make(self)
        let terminator = FakeTerminator(activeCount: 2), prompts = ScriptedQuitPrompts(.cancel), r = Recorder()
        let l = lifecycle(h, terminator, prompts, r)
        XCTAssertEqual(l.shouldTerminate(), .terminateLater)
        await l.quitTask?.value
        XCTAssertEqual(prompts.asked, [2], "“2 operations are in progress”")
        XCTAssertEqual(r.replies, [false])
        XCTAssertEqual(terminator.stopCalls, [])
        XCTAssertEqual(r.flushes, 0)
    }

    func testStopAndQuitCancelsEveryJobWithTheTenSecondTimeoutThenQuits() async throws {
        let h = try await ShellHarness.make(self)
        let terminator = FakeTerminator(activeCount: 3), prompts = ScriptedQuitPrompts(.stopAndQuit), r = Recorder()
        let l = lifecycle(h, terminator, prompts, r)
        XCTAssertEqual(l.shouldTerminate(), .terminateLater)
        await l.quitTask?.value
        XCTAssertEqual(terminator.stopCalls, [.seconds(10)])
        XCTAssertEqual(AppLifecycle.stopTimeout, .seconds(10))
        XCTAssertEqual(r.replies, [true])
    }

    func testStopAndQuitQuitsAnywayWhenCancellationTimesOut() async throws {
        let h = try await ShellHarness.make(self)
        let terminator = FakeTerminator(activeCount: 1, result: false), r = Recorder()
        let l = lifecycle(h, terminator, ScriptedQuitPrompts(.stopAndQuit), r)
        _ = l.shouldTerminate()
        await l.quitTask?.value
        XCTAssertEqual(r.replies, [true], "§6.7: quit anyway; launch cleanup uses the journal")
    }

    func testASecondQuitWhileThePromptIsOpenDoesNotAskTwice() async throws {
        let h = try await ShellHarness.make(self)
        let terminator = FakeTerminator(activeCount: 1), prompts = ScriptedQuitPrompts(.cancel), r = Recorder()
        let l = lifecycle(h, terminator, prompts, r)
        XCTAssertEqual(l.shouldTerminate(), .terminateLater)
        XCTAssertEqual(l.shouldTerminate(), .terminateCancel)
        await l.quitTask?.value
        XCTAssertEqual(prompts.asked.count, 1)
        XCTAssertEqual(r.replies, [false])
        XCTAssertEqual(l.shouldTerminate(), .terminateLater, "after the answer, a new quit asks again")
        await l.quitTask?.value
        XCTAssertEqual(prompts.asked.count, 2)
    }

    func testAnUnansweredPromptClosesAndQuitsWhenTheLastJobFinishes() async throws {
        let h = try await ShellHarness.make(self)
        let terminator = FakeTerminator(activeCount: 1), prompts = UnansweredQuitPrompts(), r = Recorder()
        let l = lifecycle(h, terminator, prompts, r)
        XCTAssertEqual(l.shouldTerminate(), .terminateLater)
        try await h.waitUntil("asked") { prompts.asked == [1] }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(r.replies, [], "still asking while the job runs")
        terminator.activeCount = 0                  // the job finished in the background
        try await h.waitUntil("quit") { r.replies == [true] }
        XCTAssertEqual(prompts.dismissals, 1, "the prompt closed itself")
        XCTAssertEqual(terminator.stopCalls, [], "nothing to stop")
        await l.quitTask?.value
        XCTAssertNil(l.quitTask)
    }

    func testAlertQuitPromptDoesNotBlockTheMainActor() async throws {
        let prompts = AlertQuitPrompts()
        var ticks = 0
        let answer = Task { @MainActor in await prompts.confirmQuit(activeCount: 1) }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            ticks += 1
        }
        XCTAssertEqual(ticks, 5, "main-actor work keeps running while the question shows")
        prompts.dismiss()
        let choice = await answer.value
        XCTAssertEqual(choice, .jobsFinished)
    }

    func testQuitPromptText() {
        XCTAssertEqual(QuitPromptText.message(activeCount: 1), "1 operation is in progress")
        XCTAssertEqual(QuitPromptText.message(activeCount: 3), "3 operations are in progress")
        XCTAssertEqual(QuitPromptText.stopAndQuit, "Stop and Quit")
        XCTAssertEqual(QuitPromptText.cancel, "Cancel")
    }

    func testWillTerminateFlushesSettings() async throws {
        let h = try await ShellHarness.make(self)
        let r = Recorder()
        let l = lifecycle(h, FakeTerminator(activeCount: 0), ScriptedQuitPrompts(.cancel), r)
        l.willTerminate()
        XCTAssertEqual(r.flushes, 1)
    }

    func testStopAndQuitWithRealRunningJobsCancelsThem() async throws {
        let sandbox = try Sandbox(prefix: "macx-tests")
        addTeardownBlock { sandbox.destroy() }
        var tuning = FileOpTuning(progressInterval: .milliseconds(20))
        tuning.bodyOverride = { ctx in while await ctx.checkpoint() { try? await Task.sleep(for: .milliseconds(5)) } }
        let lanes = LanePool()
        let environment = CoreEnvironment(
            statePaths: StatePaths(root: sandbox.root.appending(path: "state", directoryHint: .isDirectory)), lanes: lanes,
            settingsStorage: InMemorySettingsStorage(), volumeScanner: SystemVolumeScanner(), volumeEvents: nil,
            pasteboard: InMemoryPasteboard(), launchServices: FakeLaunchServices(),
            ejector: SandboxEjector(root: sandbox.root, lanes: lanes),
            trash: SandboxTrash(directory: sandbox.root.appending(path: ".trash", directoryHint: .isDirectory)),
            fileOpTuning: tuning, home: sandbox.root, searchServices: .fake())
        environment.interaction.setTarget(ScriptedInteraction())
        _ = await environment.start()
        var options = LaunchOptions()
        options.stateDirectory = environment.statePaths.root
        options.skipOnboarding = true
        let context = UIContext(environment: environment, options: options)
        context.installInteraction(ScriptedInteraction())
        let destination = try sandbox.createDirectory("d")
        for name in ["a", "b"] {
            _ = await environment.fileOps.enqueue(JobRequest(.copy(sources: [try sandbox.createFile(name)], destination: destination)))
        }
        // Each wait has its own generous deadline: planning and lane start-up are slow on a starved CI runner.
        let started = ContinuousClock.now + .seconds(30)
        while environment.termination.activeCount < 2, ContinuousClock.now < started { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(environment.termination.activeCount, 2, "both jobs running")
        let r = Recorder()
        let l = AppLifecycle(context: context, terminator: environment.termination, prompts: ScriptedQuitPrompts(.stopAndQuit),
                             reply: { r.replies.append($0) }, dockBadge: { r.badges.append($0) }, flushSettings: {})
        XCTAssertEqual(l.shouldTerminate(), .terminateLater)
        await l.quitTask?.value
        XCTAssertEqual(r.replies, [true])
        let stopped = ContinuousClock.now + .seconds(30)
        while environment.termination.activeCount > 0, ContinuousClock.now < stopped { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(environment.termination.activeCount, 0, "both jobs cancelled")
        await environment.fileOps.waitUntilIdle()
    }

    // MARK: launch notices

    func testDidLaunchShowsOnboardingOnTheFirstWindowThenTheRecoveryNotice() async throws {
        let h = try await ShellHarness.make(self) { $0.skipOnboarding = false }
        let controller = try await h.openWindow()
        let r = Recorder()
        let l = lifecycle(h, FakeTerminator(activeCount: 0), ScriptedQuitPrompts(.cancel), r)
        var shown: [String] = []
        l.presentOnboarding = { window in shown.append(window === controller.window ? "onboarding" : "onboarding?") }
        l.presentRecoveryNotice = { notice, window in shown.append(window === controller.window ? "recovery" : "recovery?") }
        var report = RecoveryReport()
        report.removedPartials = [h.url("x.macx-partial")]
        l.didLaunch(recovery: report)
        XCTAssertEqual(shown, ["onboarding", "recovery"])
    }

    func testDidLaunchShowsNothingWhenOnboardingIsSkippedAndNothingWasRecovered() async throws {
        let h = try await ShellHarness.make(self)
        _ = try await h.openWindow()
        let l = lifecycle(h, FakeTerminator(activeCount: 0), ScriptedQuitPrompts(.cancel), Recorder())
        var shown = 0
        l.presentOnboarding = { _ in shown += 1 }
        l.presentRecoveryNotice = { _, _ in shown += 1 }
        l.didLaunch(recovery: RecoveryReport())
        XCTAssertEqual(shown, 0)
    }

    func testRecoveryNoticeTexts() throws {
        XCTAssertNil(RecoveryNotice(RecoveryReport()))
        var report = RecoveryReport()
        report.removedPartials = [URL(filePath: "/tmp/a"), URL(filePath: "/tmp/b")]
        report.restoredDestinations = [URL(filePath: "/tmp/c")]
        report.restoredRenames = [URL(filePath: "/tmp/d")]
        report.incompleteJobs = [JobDescription(verb: .moving, itemCount: 4, firstItemName: "x", sourceFolderName: nil,
                                                destinationFolderName: nil)]
        let notice = try XCTUnwrap(RecoveryNotice(report))
        XCTAssertEqual(notice.message, "MacExplorer cleaned up after operations that were interrupted")
        XCTAssertEqual(notice.details.components(separatedBy: "\n"), [
            "1 operation didn't finish.",
            "Removed 2 incomplete copies.",
            "Put back 1 item that was being replaced.",
            "Restored the original name of 1 item.",
        ])
    }
}

@MainActor @Observable
private final class FakeOperations {
    var visible = 0
    var fraction: Double?
}

@MainActor
final class DockBadgeTests: XCTestCase {
    func testLabel() {
        XCTAssertNil(DockBadge.label(visibleJobs: 0, fraction: 0.5), "jobs under 1 s show nothing (§6.2)")
        XCTAssertEqual(DockBadge.label(visibleJobs: 1, fraction: 0.426), "42%")
        XCTAssertEqual(DockBadge.label(visibleJobs: 2, fraction: 0), "0%")
        XCTAssertEqual(DockBadge.label(visibleJobs: 1, fraction: 1.2), "100%")
        XCTAssertEqual(DockBadge.label(visibleJobs: 1, fraction: nil), "…", "still planning")
    }

    func testControllerFollowsTheOperations() async throws {
        let ops = FakeOperations()
        var badges: [String?] = []
        let controller = DockBadgeController(read: { (ops.visible, ops.fraction) }, sink: { badges.append($0) })
        XCTAssertEqual(badges, [nil])
        ops.visible = 1
        ops.fraction = 0.25
        try await waitUntil { badges.last == "25%" }
        ops.visible = 0
        try await waitUntil { badges.last == .some(nil) }
        let count = badges.count
        controller.stop()
        XCTAssertEqual(badges.last, .some(nil))
        ops.visible = 1
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(badges.count, count, "stopped")
    }

    func testControllerOverOperationsCenterStartsEmpty() async throws {
        let h = try await ShellHarness.make(self)
        var badges: [String?] = []
        let controller = DockBadgeController(operations: h.environment.operations, sink: { badges.append($0) })
        XCTAssertEqual(badges, [nil])
        controller.stop()
    }

    func testBadgeCountsOnlyTheVisibleJobs() async throws {
        let h = try await ShellHarness.make(self)
        let ops = h.environment.operations
        ops.revealDelay = .seconds(30)              // the running job stays hidden (under 1 s so far)
        func snap(_ state: JobState, done: Int64) -> JobSnapshot {
            var p = JobProgress.zero
            p.bytesDone = done; p.bytesTotal = 100
            let description = JobDescription(verb: .copying, itemCount: 1, firstItemName: "a", sourceFolderName: nil,
                                             destinationFolderName: nil)
            return JobSnapshot(id: JobID(), description: description, state: state,
                               progress: p, origin: nil, startedAt: .now)
        }
        await ops.handle(.added(snap(.waitingForUser, done: 20)))   // visible at once
        await ops.handle(.added(snap(.running, done: 100)))         // hidden
        XCTAssertEqual(ops.visibleJobs.count, 1)
        var badges: [String?] = []
        let controller = DockBadgeController(operations: ops, sink: { badges.append($0) })
        XCTAssertEqual(badges.last, .some("20%"), "the hidden job doesn't count")
        controller.stop()
    }

    /// A pure condition wait on the observation loop: a generous deadline, and a timeout fails at the caller's line.
    private func waitUntil(timeout: Duration = .seconds(30), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out after \(timeout)", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
