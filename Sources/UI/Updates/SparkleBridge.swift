import AppKit
import Core
import Sparkle

/// Sparkle 2 behind `UpdaterEngine` (spec §2.2). Delegate and user-driver callbacks are forwarded to UpdateController;
/// nothing here decides UI. Silent path: SUAutomaticallyUpdate downloads in the background and calls
/// `willInstallUpdateOnQuit` with an "install now" block. Foreground path (user driver) covers updates Sparkle can't
/// install silently.
@MainActor
enum SparkleBridge {
    static func makeController(model: UpdateModel, settings: Core.Settings, bundle: Bundle) -> UpdateController {
        let installed = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let forwarder = Forwarder()
        let driver = UserDriver(forwarder: forwarder, settings: settings)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: forwarder)
        let engine = SparkleEngine(updater: updater, retained: [forwarder, driver])
        let controller = UpdateController(model: model, settings: settings, engine: engine, installedVersion: installed,
                                          terminate: { NSApp.terminate(nil) })
        forwarder.controller = controller
        return controller
    }
}

@MainActor
final class SparkleEngine: UpdaterEngine {
    let updater: SPUUpdater
    private let retained: [AnyObject]
    init(updater: SPUUpdater, retained: [AnyObject]) { self.updater = updater; self.retained = retained }
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    func start() throws { try updater.start() }
    /// Background check even when the user asked: the silent download path then applies (spec §3.2); the popover
    /// shows progress from the delegate callbacks.
    func checkInBackground() { updater.checkForUpdatesInBackground() }
}

/// `SPUUpdaterDelegate` and `SPUUserDriver` are `NS_SWIFT_UI_ACTOR` in the pinned Sparkle headers, so every
/// callback below already runs on the main actor.
@MainActor
final class Forwarder: NSObject, SPUUpdaterDelegate {
    weak var controller: UpdateController?

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        controller?.allowedChannels() ?? []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        controller?.didFindUpdate(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        controller?.didNotFindUpdate()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let controller else { return false }
        let notes = item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL
        controller.willInstallOnQuit(version: item.displayVersionString, notesURL: notes,
                                     install: { immediateInstallHandler() })
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let e = error as NSError
        guard !(e.domain == SUSparkleErrorDomain && e.code == Int(SUError.noUpdateError.rawValue)) else { return }
        controller?.didAbort(domain: e.domain, code: e.code, message: e.localizedDescription)
    }
}

/// Replaces Sparkle's standard windows. Only reached for user-driver (foreground) flows.
@MainActor
final class UserDriver: NSObject, SPUUserDriver {
    private let forwarder: Forwarder
    private let settings: Core.Settings
    private var expected: UInt64 = 0, received: UInt64 = 0
    private var version = ""
    private var notes: URL?

    init(forwarder: Forwarder, settings: Core.Settings) { self.forwarder = forwarder; self.settings = settings }
    private var controller: UpdateController? { forwarder.controller }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: settings.checkForUpdatesAutomatically, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        version = appcastItem.displayVersionString
        notes = appcastItem.fullReleaseNotesURL ?? appcastItem.releaseNotesURL ?? appcastItem.infoURL
        if state.stage == .notDownloaded {
            controller?.didFindUpdate(version: version)
            reply(.install)   // download now; showReady follows
        } else {
            controller?.readyToInstall(version: version, notesURL: notes) { reply(.install) }
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.didNotFindUpdate()
        acknowledgement()
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let e = error as NSError
        controller?.didAbort(domain: e.domain, code: e.code, message: e.localizedDescription)
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { expected = 0; received = 0; controller?.downloadProgress(nil) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        controller?.downloadProgress(expected > 0 ? min(1, Double(received) / Double(expected)) : nil)
    }
    func showDownloadDidStartExtractingUpdate() { controller?.downloadProgress(nil) }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller?.readyToInstall(version: version, notesURL: notes) { reply(.install) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        // Termination was cancelled (quit prompt → Cancel): keep the badge; Restart Now retries.
        if !applicationTerminated { controller?.readyToInstall(version: version, notesURL: notes) { retryTerminatingApplication() } }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}
