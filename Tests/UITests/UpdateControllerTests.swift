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
}
