import AppKit
import Core
import Sparkle

/// Sparkle 2 behind `UpdaterEngine` (spec §2.2). Delegate and user-driver callbacks are forwarded to UpdateController;
/// nothing here decides anything, it only translates Sparkle types (the decisions are unit-tested on the
/// controller). Silent path: SUAutomaticallyUpdate downloads in the background and calls `willInstallUpdateOnQuit`
/// with an "install now" block. Foreground path (user driver) covers updates Sparkle can't install silently.
@MainActor
enum SparkleBridge {
    static func makeController(model: UpdateModel, settings: Core.Settings, bundle: Bundle) -> UpdateController {
        let info = bundle.infoDictionary ?? [:]
        let installed = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = (info["CFBundleVersion"] as? String).flatMap { Int($0) }
        let forwarder = Forwarder()
        let driver = UserDriver(forwarder: forwarder, settings: settings)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: forwarder)
        let engine = SparkleEngine(updater: updater, retained: [forwarder, driver])
        let controller = UpdateController(model: model, settings: settings, engine: engine, installedVersion: installed,
                                          installedBuild: build, trash: RollbackService.trashQuietly, sparkleSkip: .live,
                                          terminate: { NSApp.terminate(nil) })
        forwarder.controller = controller
        controller.rollback = RollbackService.live(controller: controller, settings: settings, bundle: bundle)
        return controller
    }

    static func notes(_ item: SUAppcastItem) -> URL? { item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL }
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

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        let version = updateItem.displayVersionString
        guard let controller, !controller.shouldProceed(version: version, build: Int(updateItem.versionString)) else { return }
        throw UpdateController.suppressedError(version: version)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        controller?.validUpdateFound(version: item.displayVersionString,
                                     needsUserAttention: item.isInformationOnlyUpdate || item.isMajorUpgrade)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        controller?.didNotFindUpdate()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let controller else { return false }
        controller.willInstallOnQuit(version: item.displayVersionString, notesURL: SparkleBridge.notes(item),
                                     install: { immediateInstallHandler() })
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        controller?.didAbort(UpdateFailure(error))
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        controller?.didFinishUpdateCycle()
    }
}

/// Replaces Sparkle's standard windows. Only reached for user-driver (foreground) flows.
@MainActor
final class UserDriver: NSObject, SPUUserDriver {
    private let forwarder: Forwarder
    private let settings: Core.Settings

    init(forwarder: Forwarder, settings: Core.Settings) { self.forwarder = forwarder; self.settings = settings }
    private var controller: UpdateController? { forwarder.controller }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: settings.checkForUpdatesAutomatically, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let stage: FoundUpdateStage = switch state.stage {
        case .downloaded: .downloaded
        case .installing: .installing
        default: .notDownloaded
        }
        guard let controller else { reply(.dismiss); return }
        controller.userDriverFoundUpdate(version: appcastItem.displayVersionString, notesURL: SparkleBridge.notes(appcastItem),
                                         informationOnly: appcastItem.isInformationOnlyUpdate, stage: stage) { choice in
            reply(choice == .install ? .install : .dismiss)
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.didNotFindUpdate()
        acknowledgement()
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.didAbort(UpdateFailure(error))
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { controller?.userDriverDownloadStarted() }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller?.userDriverDownloadExpectedLength(expectedContentLength)
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) { controller?.userDriverDownloadReceived(length) }
    func showDownloadDidStartExtractingUpdate() { controller?.downloadProgress(nil) }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller?.userDriverReadyToInstall { reply(.install) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        controller?.userDriverInstalling(applicationTerminated: applicationTerminated) { retryTerminatingApplication() }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}
