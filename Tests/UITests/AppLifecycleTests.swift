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
    init(_ answer: QuitChoice) { self.answer = answer }
    func confirmQuit(activeCount: Int) async -> QuitChoice {
        asked.append(activeCount)
        return answer
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
            fileOpTuning: tuning, home: sandbox.root)
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
        let deadline = ContinuousClock.now + .seconds(5)
        while environment.termination.activeCount < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(environment.termination.activeCount, 2)
        let r = Recorder()
        let l = AppLifecycle(context: context, terminator: environment.termination, prompts: ScriptedQuitPrompts(.stopAndQuit),
                             reply: { r.replies.append($0) }, dockBadge: { r.badges.append($0) }, flushSettings: {})
        XCTAssertEqual(l.shouldTerminate(), .terminateLater)
        await l.quitTask?.value
        XCTAssertEqual(r.replies, [true])
        while environment.termination.activeCount > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(environment.termination.activeCount, 0)
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
        XCTAssertEqual(notice.message, "macExplorer cleaned up after operations that were interrupted")
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

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
