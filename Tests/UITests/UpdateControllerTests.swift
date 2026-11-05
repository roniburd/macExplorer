import XCTest
@testable import UI
@testable import Core

@MainActor
private final class FakeEngine: UpdaterEngine {
    var automaticallyChecksForUpdates = true
    private(set) var started = 0, checks = 0
    var startError: (any Error)?
    func start() throws {
        started += 1
        if let startError { throw startError }
    }
    func checkInBackground() { checks += 1 }
}

private struct StartFailure: Error {}

@MainActor
final class UpdateControllerTests: XCTestCase {
    private func make(channel: UpdateChannel = .release, automaticChecks: Bool = true, startError: (any Error)? = nil)
        -> (UpdateController, UpdateModel, FakeEngine, Core.Settings, () -> Int) {
        let settings = Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
        settings.updateChannel = channel
        settings.checkForUpdatesAutomatically = automaticChecks
        let model = UpdateModel(), engine = FakeEngine()
        engine.startError = startError
        var terminations = 0
        let c = UpdateController(model: model, settings: settings, engine: engine, installedVersion: "0.3.1",
                                 terminate: { terminations += 1 })
        return (c, model, engine, settings, { terminations })
    }

    func testStartAppliesSettingsAndChannels() {
        let (c, model, engine, settings, _) = make(channel: .beta)
        XCTAssertEqual(engine.started, 1)
        XCTAssertTrue(model.isAvailable)
        XCTAssertEqual(c.allowedChannels(), ["beta"])
        settings.updateChannel = .release
        XCTAssertEqual(c.allowedChannels(), [])
        model.setAutomaticChecks(false)
        XCTAssertFalse(engine.automaticallyChecksForUpdates)
        XCTAssertFalse(settings.checkForUpdatesAutomatically)
    }

    func testInitAppliesSavedAutomaticChecksSettingToEngine() {
        let (_, _, engine, _, _) = make(automaticChecks: false)
        XCTAssertFalse(engine.automaticallyChecksForUpdates)   // FakeEngine starts true: only init's sync flips it
    }

    func testStartFailureLeavesModelUnavailableAndInert() {
        let (_, model, engine, _, _) = make(startError: StartFailure())
        XCTAssertEqual(engine.started, 1)
        XCTAssertFalse(model.isAvailable)
        model.checkNow()
        XCTAssertEqual(engine.checks, 0)
        XCTAssertEqual(model.state, .idle)
    }

    func testUserCheckFlowsToUpToDate() {
        let (c, model, engine, _, _) = make()
        model.checkNow()
        XCTAssertEqual(engine.checks, 1)
        XCTAssertEqual(model.state, .checking(userInitiated: true))
        XCTAssertEqual(model.popoverRequest, 1)
        c.didNotFindUpdate()
        XCTAssertEqual(model.state, .upToDate(version: "0.3.1"))
    }

    func testBackgroundCheckDoesNotOpenPopover() {
        let (_, model, engine, _, _) = make()
        model.checkNow(userInitiated: false)
        XCTAssertEqual(engine.checks, 1)
        XCTAssertEqual(model.popoverRequest, 0)
        XCTAssertFalse(model.state.isBadgeVisible)
    }

    func testSilentInstallOnQuitShowsBadgeAndRestartInstalls() {
        let (c, model, _, _, terminations) = make()
        var installs = 0
        c.didFindUpdate(version: "0.4.0")
        c.willInstallOnQuit(version: "0.4.0", notesURL: nil) { installs += 1 }
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: nil))
        model.restartNow()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(terminations(), 0)
    }

    func testRestartWhileJobsActiveDefersToQuitPath() {
        // Sparkle's install block asks NSApp to terminate, which runs AppLifecycle.shouldTerminate (quit prompt).
        // If the user cancels, the badge stays and the block stays armed: Sparkle >= 2.3 documents the silent
        // install-on-quit handler as re-invocable after a cancelled termination, and only it installs *and relaunches*
        // (a plain terminate would install on quit without relaunching).
        let (c, model, _, _, terminations) = make()
        var installs = 0
        c.willInstallOnQuit(version: "0.4.0", notesURL: nil) { installs += 1 }
        model.restartNow()
        model.restartNow()
        XCTAssertEqual(installs, 2)
        XCTAssertEqual(terminations(), 0)
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: nil))
    }

    func testOneShotForegroundReplyIsNotReusedButRetryBlockIs() {
        // Foreground `reply(.install)` must be called once; after a cancelled quit Sparkle re-arms through
        // showInstallingUpdate's retryTerminatingApplication, which "may be invoked multiple times".
        let (c, model, _, _, terminations) = make()
        var replies = 0, retries = 0
        c.readyToInstall(version: "0.4.0", notesURL: nil) { replies += 1 }
        model.restartNow()
        model.restartNow()   // before Sparkle re-arms: no second reply; falls back to a terminate request
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(terminations(), 1)
        c.readyToInstall(version: "0.4.0", notesURL: nil, reusable: true) { retries += 1 }
        model.restartNow()
        model.restartNow()
        XCTAssertEqual(retries, 2)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(terminations(), 1)
    }

    func testBackgroundNetworkFailureIsSilent() {
        let (c, model, _, _, _) = make()
        c.didFindUpdate(version: "0.4.0")
        c.didAbort(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, message: "offline")
        XCTAssertEqual(model.state, .idle)
    }

    func testVerificationFailureIsShown() {
        let (c, model, _, _, _) = make()
        c.didFindUpdate(version: "0.4.0")
        c.didAbort(domain: "SUSparkleErrorDomain", code: 3001, message: "bad signature")
        XCTAssertEqual(model.state, .failed(.verificationFailed(version: "0.4.0"), userInitiated: false))
    }

    func testRunningFromDiskImageMapsToMoveToApplications() {
        XCTAssertEqual(UpdateController.mapError(domain: "SUSparkleErrorDomain", code: 1003, message: "", version: nil), .notInApplications)
        XCTAssertEqual(UpdateController.mapError(domain: "SUSparkleErrorDomain", code: 1005, message: "", version: nil), .notInApplications)
        XCTAssertEqual(UpdateController.mapError(domain: "SUSparkleErrorDomain", code: 3002, message: "", version: "1"), .verificationFailed(version: "1"))
        XCTAssertEqual(UpdateController.mapError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, message: "", version: nil), .offline)
        XCTAssertEqual(UpdateController.mapError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, message: "timed out", version: nil), .network("timed out"))
        XCTAssertEqual(UpdateController.mapError(domain: "X", code: 1, message: "boom", version: nil), .other("boom"))
    }

    func testIsConfiguredRequiresARealKeyAndFeed() {
        XCTAssertFalse(UpdateController.isConfigured(info: [:]))
        XCTAssertFalse(UpdateController.isConfigured(info: ["SUFeedURL": "https://x/appcast.xml", "SUPublicEDKey": "REPLACE_WITH_SPARKLE_PUBLIC_KEY"]))
        XCTAssertTrue(UpdateController.isConfigured(info: ["SUFeedURL": "https://x/appcast.xml", "SUPublicEDKey": "abc123="]))
    }

    func testModelWithoutControllerIsUnavailableAndInert() {
        let model = UpdateModel()
        XCTAssertFalse(model.isAvailable)
        model.checkNow()
        XCTAssertEqual(model.state, .idle)
    }

    func testObserversSeeEveryChange() {
        let model = UpdateModel()
        var seen: [UpdateState] = []
        let token = model.addObserver { seen.append($0) }
        model.send(.checkStarted(userInitiated: true))
        model.send(.noUpdateFound(currentVersion: "1"))
        XCTAssertEqual(seen, [.checking(userInitiated: true), .upToDate(version: "1")])
        _ = token
    }

    // MARK: branch review — the error shapes Sparkle 2.10.1 really delivers

    private static func sparkle(_ code: Int, _ message: String = "", underlying: NSError? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: "SUSparkleErrorDomain", code: code, userInfo: info)
    }

    /// SPUInstallerDriver re-wraps the Autoupdate validation failure: 4005 → SPUInstallerError (10) → 3002.
    private static var installerValidationFailure: NSError {
        sparkle(4005, "The update is improperly signed and could not be validated.",
                underlying: sparkle(10, "Update validation was a failure",
                                    underlying: sparkle(3002, "EdDSA signature does not match")))
    }

    /// SUAppcastDriver / SPUDownloadDriver: 2001 (SUDownloadError) → the NSURLError.
    private static func fetchFailure(_ urlCode: Int) -> NSError {
        sparkle(2001, "An error occurred in retrieving update information.",
                underlying: NSError(domain: NSURLErrorDomain, code: urlCode))
    }

    func testWrappedVerificationFailureIsShownInTheBackground() {
        let (c, model, _, _, _) = make()
        c.didFindUpdate(version: "0.4.0")
        c.didAbort(UpdateFailure(Self.installerValidationFailure))
        XCTAssertEqual(model.state, .failed(.verificationFailed(version: "0.4.0"), userInitiated: false))
        XCTAssertTrue(model.state.isBadgeVisible)
    }

    func testWrappedNetworkErrorsMapToOfflineAndNetwork() {
        XCTAssertEqual(UpdateController.mapError(UpdateFailure(Self.fetchFailure(NSURLErrorNotConnectedToInternet)), version: nil),
                       .offline)
        XCTAssertEqual(UpdateController.mapError(UpdateFailure(Self.fetchFailure(NSURLErrorTimedOut)), version: nil),
                       .network("An error occurred in retrieving update information."))
        XCTAssertEqual(UpdateController.mapError(UpdateFailure(Self.sparkle(4005, "nope")), version: nil), .other("nope"))
        let (c, model, _, _, _) = make()
        model.checkNow()
        c.didAbort(UpdateFailure(Self.fetchFailure(NSURLErrorNotConnectedToInternet)))
        XCTAssertEqual(model.state, .failed(.offline, userInitiated: true))
    }

    func testFailureChainIsBoundedAndNoUpdateIsNotAFailure() {
        var deep = Self.sparkle(3002)
        for _ in 0..<20 { deep = Self.sparkle(4005, underlying: deep) }
        XCTAssertEqual(UpdateFailure(deep).chain.count, UpdateFailure.maxDepth)
        let (c, model, _, _, _) = make()
        model.checkNow()
        c.didAbort(UpdateFailure(Self.sparkle(1001, "You're up to date!")))
        XCTAssertEqual(model.state, .checking(userInitiated: true), "SUNoUpdateError is reported by didNotFindUpdate")
    }

    // MARK: branch review — spec §3.4 verification-failure suppression

    func testVerificationFailureSuppressesTheVersionForTheSession() {
        let (c, model, _, _, _) = make()
        c.didFindUpdate(version: "0.4.0")
        c.didAbort(UpdateFailure(Self.installerValidationFailure))
        XCTAssertEqual(c.rejectedVersions, ["0.4.0"])
        model.acknowledge()
        XCTAssertEqual(model.state, .idle)

        // The next background check: Sparkle asks first and is told not to download 0.4.0 again; silent.
        model.checkNow(userInitiated: false)
        XCTAssertFalse(c.shouldProceed(version: "0.4.0"))
        XCTAssertTrue(c.shouldProceed(version: "0.4.1"))
        c.didAbort(UpdateFailure(UpdateController.suppressedError(version: "0.4.0")))
        XCTAssertEqual(model.state, .idle)

        // Paths that bypass shouldProceed (a resumed update) don't restart the download either.
        c.didFindUpdate(version: "0.4.0")
        XCTAssertEqual(model.state, .idle)
        var replies: [FoundUpdateReply] = []
        c.userDriverFoundUpdate(version: "0.4.0", notesURL: nil, informationOnly: false, stage: .notDownloaded) { replies.append($0) }
        XCTAssertEqual(replies, [.dismiss])
        XCTAssertEqual(model.state, .idle)

        // A manual check says why nothing is installed.
        model.checkNow()
        XCTAssertFalse(c.shouldProceed(version: "0.4.0"))
        c.didAbort(UpdateFailure(UpdateController.suppressedError(version: "0.4.0")))
        XCTAssertEqual(model.state, .failed(.verificationFailed(version: "0.4.0"), userInitiated: true))

        // A newer build is offered normally.
        model.acknowledge()
        c.didFindUpdate(version: "0.4.1")
        XCTAssertEqual(model.state, .downloading(version: "0.4.1", fraction: nil, userInitiated: false))
    }

    // MARK: branch review — user-driver decisions (SparkleBridge only translates types)

    func testNotDownloadedItemIsDownloadedWithProgress() {
        let (c, model, _, _, _) = make()
        let notes = URL(string: "https://example.invalid/notes")
        model.checkNow()
        var replies: [FoundUpdateReply] = []
        c.userDriverFoundUpdate(version: "0.4.0", notesURL: notes, informationOnly: false, stage: .notDownloaded) { replies.append($0) }
        XCTAssertEqual(replies, [.install])
        XCTAssertEqual(model.state, .downloading(version: "0.4.0", fraction: nil, userInitiated: true))
        c.userDriverDownloadStarted()
        c.userDriverDownloadExpectedLength(200)
        c.userDriverDownloadReceived(50)
        XCTAssertEqual(model.state, .downloading(version: "0.4.0", fraction: 0.25, userInitiated: true))
        c.userDriverDownloadReceived(500)
        XCTAssertEqual(model.state, .downloading(version: "0.4.0", fraction: 1, userInitiated: true), "clamped")
        c.userDriverDownloadStarted()   // a new download resets the counters
        c.userDriverDownloadReceived(10)
        XCTAssertEqual(model.state, .downloading(version: "0.4.0", fraction: nil, userInitiated: true), "unknown length")
        var installs = 0
        c.userDriverReadyToInstall { installs += 1 }
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: notes))
        model.restartNow()
        XCTAssertEqual(installs, 1)
    }

    func testDownloadedItemIsExtractedBeforeRestartIsOffered() {
        // For a downloaded item `.install` only starts extraction; showReady follows. Offering Restart Now before
        // that made the first click do nothing visible.
        let (c, model, _, _, terminations) = make()
        var replies: [FoundUpdateReply] = []
        c.userDriverFoundUpdate(version: "0.4.0", notesURL: nil, informationOnly: false, stage: .downloaded) { replies.append($0) }
        XCTAssertEqual(replies, [.install])
        XCTAssertEqual(model.state, .downloading(version: "0.4.0", fraction: nil, userInitiated: false))
        var installs = 0
        c.userDriverReadyToInstall { installs += 1 }
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: nil))
        model.restartNow()
        XCTAssertEqual(installs, 1, "a single Restart Now installs")
        XCTAssertEqual(terminations(), 0)
    }

    func testInstallingItemWaitsForRestartNow() {
        let (c, model, _, _, _) = make()
        var replies: [FoundUpdateReply] = []
        c.userDriverFoundUpdate(version: "0.4.0", notesURL: nil, informationOnly: false, stage: .installing) { replies.append($0) }
        XCTAssertEqual(replies, [])
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: nil))
        model.restartNow()
        XCTAssertEqual(replies, [.install])
    }

    func testInformationOnlyItemIsDismissedAndResolvesTheCheck() {
        let (c, model, _, _, _) = make()
        model.checkNow()
        c.validUpdateFound(version: "0.5.0", needsUserAttention: true)
        XCTAssertEqual(model.state, .checking(userInitiated: true), "nothing downloads yet")
        var replies: [FoundUpdateReply] = []
        c.userDriverFoundUpdate(version: "0.5.0", notesURL: nil, informationOnly: true, stage: .notDownloaded) { replies.append($0) }
        XCTAssertEqual(replies, [.dismiss], "Sparkle must not be told to install an informational item")
        XCTAssertEqual(model.state, .upToDate(version: "0.3.1"))
        model.acknowledge()

        model.checkNow(userInitiated: false)
        c.validUpdateFound(version: "0.5.0", needsUserAttention: true)
        c.userDriverFoundUpdate(version: "0.5.0", notesURL: nil, informationOnly: true, stage: .notDownloaded) { replies.append($0) }
        XCTAssertEqual(model.state, .idle)
        model.checkNow()
        XCTAssertEqual(model.state, .checking(userInitiated: true), "a later Check Now still works")

        c.validUpdateFound(version: "0.4.0", needsUserAttention: false)
        XCTAssertEqual(model.state, .downloading(version: "0.4.0", fraction: nil, userInitiated: true))
    }

    func testFinishedCycleResolvesOnlyInFlightStates() {
        let (c, model, _, _, _) = make()
        model.checkNow()
        c.didFinishUpdateCycle()
        XCTAssertEqual(model.state, .idle)
        c.didFindUpdate(version: "0.4.0")
        c.didFinishUpdateCycle()
        XCTAssertEqual(model.state, .idle)
        model.checkNow()
        c.didNotFindUpdate()
        c.didFinishUpdateCycle()
        XCTAssertEqual(model.state, .upToDate(version: "0.3.1"))
        c.willInstallOnQuit(version: "0.4.0", notesURL: nil) {}
        c.didFinishUpdateCycle()
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: nil))
    }

    func testCancelledTerminationReArmsTheRetryBlock() {
        let (c, model, _, _, _) = make()
        var retries = 0
        c.userDriverInstalling(applicationTerminated: true) { retries += 1 }
        XCTAssertEqual(model.state, .idle, "the app is quitting: nothing to show")
        c.userDriverFoundUpdate(version: "0.4.0", notesURL: nil, informationOnly: false, stage: .notDownloaded) { _ in }
        c.userDriverInstalling(applicationTerminated: false) { retries += 1 }
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: nil))
        model.restartNow()
        model.restartNow()
        XCTAssertEqual(retries, 2)
    }

    func testBridgeImplementsTheSparkleCallbacksItRelies() {
        // A misspelled optional delegate method compiles but is never called; check the Objective-C selectors.
        let forwarder = Forwarder()
        for selector in ["allowedChannelsForUpdater:", "updater:shouldProceedWithUpdate:updateCheck:error:",
                         "updater:didFindValidUpdate:", "updaterDidNotFindUpdate:error:",
                         "updater:willInstallUpdateOnQuit:immediateInstallationBlock:", "updater:didAbortWithError:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:"] {
            XCTAssertTrue(forwarder.responds(to: NSSelectorFromString(selector)), selector)
        }
    }

    // MARK: branch review — Review Focus 1 through the real quit path

    func testRestartNowWithAnActiveJobGoesThroughTheQuitPromptAndCancelKeepsTheBadge() async throws {
        let h = try await ShellHarness.make(self)
        let jobs = ActiveJobs(activeCount: 1), prompts = CancellingQuitPrompts()
        var replies: [Bool] = []
        let lifecycle = AppLifecycle(context: h.context, terminator: jobs, prompts: prompts,
                                     reply: { replies.append($0) }, dockBadge: { _ in }, flushSettings: {})
        let settings = Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
        let model = UpdateModel()
        let c = UpdateController(model: model, settings: settings, engine: FakeEngine(), installedVersion: "0.3.1",
                                 terminate: { XCTFail("the install block is on hand: no fallback terminate") })
        let badge = UpdateBadgeItem(model: model)
        // Sparkle's install block asks NSApp to terminate; AppDelegate.applicationShouldTerminate asks the lifecycle.
        var quitNow = 0
        c.willInstallOnQuit(version: "0.4.0", notesURL: nil) {
            if lifecycle.shouldTerminate() == .terminateNow { quitNow += 1 }
        }
        XCTAssertFalse(badge.isHidden)

        model.restartNow()
        await lifecycle.quitTask?.value
        XCTAssertEqual(prompts.asked, [1], "the quit prompt was shown")
        XCTAssertEqual(replies, [false], "Cancel keeps the app running")
        XCTAssertEqual(quitNow, 0)
        XCTAssertFalse(badge.isHidden, "and the badge visible")
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: nil))

        model.restartNow()
        await lifecycle.quitTask?.value
        XCTAssertEqual(prompts.asked, [1, 1], "a second Restart Now asks again")
        XCTAssertEqual(replies, [false, false])

        jobs.activeCount = 0
        model.restartNow()
        XCTAssertEqual(quitNow, 1, "with no job running it quits (and installs) at once")
        XCTAssertEqual(prompts.asked, [1, 1])
    }
}

@MainActor
private final class ActiveJobs: JobTerminating {
    var activeCount: Int
    init(activeCount: Int) { self.activeCount = activeCount }
    func stopAllAndWait(timeout: Duration) async -> Bool { activeCount = 0; return true }
}

@MainActor
private final class CancellingQuitPrompts: QuitPrompting {
    private(set) var asked: [Int] = []
    func confirmQuit(activeCount: Int) async -> QuitChoice {
        asked.append(activeCount)
        return .cancel
    }
    func dismiss() {}
}
