import Foundation
import Core

/// The Sparkle engine as `UpdateController` needs it (a fake in tests; `SparkleEngine` in SparkleBridge.swift).
@MainActor protocol UpdaterEngine: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    func start() throws
    func checkInBackground()
}

/// A Sparkle-free copy of an error and its `NSUnderlyingErrorKey` chain. Sparkle wraps the error that matters:
/// verification failures reach the app as 4005 (SUInstallationError) → 10 (SPUInstallerError) → 3002
/// (SUValidationError), network failures as 2001 (SUDownloadError) → NSURLError (pinned 2.10.1 sources:
/// SPUInstallerDriver.m, Autoupdate/AppInstaller.m, SUAppcastDriver.m).
struct UpdateFailure: Sendable, Equatable {
    struct Link: Sendable, Equatable {
        var domain: String
        var code: Int
    }

    static let maxDepth = 8
    /// Top-level error first; never empty.
    let chain: [Link]
    /// The top-level error's localized description.
    let message: String

    init(chain: [Link], message: String) {
        precondition(!chain.isEmpty, "an UpdateFailure needs at least one error")
        self.chain = chain
        self.message = message
    }

    init(domain: String, code: Int, message: String) {
        self.init(chain: [Link(domain: domain, code: code)], message: message)
    }

    init(_ error: any Error) {
        let top = error as NSError
        var links: [Link] = []
        var current: NSError? = top
        while let e = current, links.count < Self.maxDepth {
            links.append(Link(domain: e.domain, code: e.code))
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        self.init(chain: links, message: top.localizedDescription)
    }

    var top: Link { chain[0] }

    func contains(domain: String, codes: Set<Int>) -> Bool {
        chain.contains { $0.domain == domain && codes.contains($0.code) }
    }

    /// Sparkle's SUNoUpdateError: "no update", not a failure.
    var isNoUpdate: Bool { top == Link(domain: UpdateController.sparkleDomain, code: 1001) }
}

/// What the user driver's `showUpdateFound` was told (SPUUserUpdateStage without Sparkle).
enum FoundUpdateStage: Sendable, Equatable { case notDownloaded, downloaded, installing }
/// The user driver's answer to `showUpdateFound` (SPUUserUpdateChoice without Sparkle).
enum FoundUpdateReply: Sendable, Equatable { case install, dismiss }

/// Glue between Sparkle callbacks (forwarded by SparkleBridge) and `UpdateModel` (spec §3). No Sparkle types here:
/// SparkleBridge only translates types, every decision is made (and unit-tested) here.
@MainActor
public final class UpdateController {
    /// The Info.plist sentinel for "no EdDSA key configured yet".
    static let unsetKey = "REPLACE_WITH_SPARKLE_PUBLIC_KEY"
    nonisolated static let sparkleDomain = "SUSparkleErrorDomain"
    /// `shouldProceedWithUpdate` rejects a version that failed verification earlier this session with this domain.
    nonisolated static let suppressedDomain = "com.macexplorer.updates.suppressed"

    let model: UpdateModel
    private let settings: Core.Settings
    private let engine: any UpdaterEngine
    private let installedVersion: String
    private let terminate: @MainActor () -> Void
    /// Sparkle's "install and relaunch now" action. `reusable` blocks (silent install-on-quit handler, Sparkle >= 2.3;
    /// `retryTerminatingApplication`) may be invoked again after a cancelled quit; one-shot `reply` blocks may not.
    private var pendingInstall: (run: @MainActor () -> Void, reusable: Bool)?
    private var foundVersion: String?
    /// Release notes of the item the user driver is handling (showReady / showInstallingUpdate carry no item).
    private var driverNotes: URL?
    private var expectedBytes: UInt64 = 0, receivedBytes: UInt64 = 0
    /// Spec §3.4: a version that failed EdDSA / code-signature validation is not offered again this session.
    private(set) var rejectedVersions: Set<String> = []

    init(model: UpdateModel, settings: Core.Settings, engine: any UpdaterEngine, installedVersion: String,
         terminate: @escaping @MainActor () -> Void) {
        self.model = model
        self.settings = settings
        self.engine = engine
        self.installedVersion = installedVersion
        self.terminate = terminate
        model.installedVersion = installedVersion
        engine.automaticallyChecksForUpdates = settings.checkForUpdatesAutomatically
        // Check and auto-check handlers hold the engine and settings directly, so they keep working however the
        // owner holds this controller; only restart needs the controller's pending install block.
        model.checkHandler = { [engine] _ in engine.checkInBackground() }
        model.restartHandler = { [weak self] in self?.restart() }
        model.automaticChecksHandler = { [settings, engine] on in
            settings.checkForUpdatesAutomatically = on
            engine.automaticallyChecksForUpdates = on
        }
        do { try engine.start() } catch {
            NSLog("MacExplorer updater failed to start: %@", String(describing: error))
            model.checkHandler = nil
        }
    }

    // MARK: Sparkle delegate → model (called by SparkleBridge.Forwarder)

    func allowedChannels() -> Set<String> { settings.updateChannel.sparkleChannels }

    /// `shouldProceedWithUpdate`: false for a version rejected earlier this session, so Sparkle neither shows nor
    /// downloads it again (the bridge then throws `suppressedError`, which comes back through `didAbort`).
    func shouldProceed(version: String) -> Bool {
        guard rejectedVersions.contains(version) else { return true }
        foundVersion = version
        NSLog("MacExplorer update %@ failed verification earlier this session; not offering it again", version)
        return false
    }

    static func suppressedError(version: String) -> NSError {
        NSError(domain: suppressedDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "MacExplorer \(version) failed verification earlier in this session",
        ])
    }

    /// `didFindValidUpdate`. Sparkle's automatic driver reports informational and major-upgrade items here too and
    /// then hands them to the user driver (`showUpdateFound`), which decides; nothing is downloading yet.
    func validUpdateFound(version: String, needsUserAttention: Bool) {
        guard !needsUserAttention else { return }
        didFindUpdate(version: version)
    }

    func didFindUpdate(version: String) {
        guard !rejectedVersions.contains(version) else { return }
        foundVersion = version
        model.send(.updateFound(version: version))
    }

    func didNotFindUpdate() { model.send(.noUpdateFound(currentVersion: installedVersion)) }

    func downloadProgress(_ fraction: Double?) { model.send(.downloadProgress(fraction)) }

    /// Silent path: Sparkle downloaded and will install on quit; `install` installs and relaunches now.
    /// Sparkle documents this block as re-invocable after the app cancels termination, so it stays armed.
    func willInstallOnQuit(version: String, notesURL: URL?, install: @escaping @MainActor () -> Void) {
        readyToInstall(version: version, notesURL: notesURL, reusable: true, install: install)
    }

    /// Foreground (user-driver) path: same UI, different Sparkle reply. `reusable: false` (a `reply` block) is
    /// dropped after one use; `reusable: true` (e.g. `retryTerminatingApplication`) stays armed.
    func readyToInstall(version: String, notesURL: URL?, reusable: Bool = false,
                        install: @escaping @MainActor () -> Void) {
        pendingInstall = (install, reusable)
        model.send(.readyToInstall(version: version, notesURL: notesURL))
    }

    func didAbort(domain: String, code: Int, message: String) {
        didAbort(UpdateFailure(domain: domain, code: code, message: message))
    }

    /// `didAbortWithError` and the user driver's `showUpdaterError` (Sparkle may report one failure through both;
    /// the reducer ignores the repeat).
    func didAbort(_ failure: UpdateFailure) {
        guard !failure.isNoUpdate else { return }
        if failure.top.domain == Self.suppressedDomain {
            // A manual check says again why nothing is installed; a background check stays silent.
            if case .checking(userInitiated: true) = model.state {
                model.send(.failed(.verificationFailed(version: foundVersion)))
            } else {
                model.send(.noUpdateFound(currentVersion: installedVersion))
            }
            return
        }
        let error = Self.mapError(failure, version: foundVersion)
        if case .verificationFailed(let version?) = error { rejectedVersions.insert(version) }
        let chain = failure.chain.map { "\($0.domain) \($0.code)" }.joined(separator: " → ")
        NSLog("MacExplorer update failed: %@ %@", chain, failure.message)
        model.send(.failed(error))
    }

    /// `didFinishUpdateCycleForUpdateCheck:error:`: whatever ended the cycle, an in-flight check or download
    /// resolves (results and errors were already delivered by the callbacks above).
    func didFinishUpdateCycle() {
        switch model.state {
        case .checking, .downloading: model.send(.sessionEnded)
        default: break
        }
    }

    // MARK: Sparkle user driver → model (called by SparkleBridge.UserDriver)

    /// `showUpdateFound`. Informational items can't be installed (Sparkle turns `.install` into `.dismiss` and ends
    /// the session without another callback), so they resolve the check here. A downloaded item is extracted first:
    /// answering `.install` now and publishing "Restart to Update" at `showReady` keeps Restart Now a single click.
    func userDriverFoundUpdate(version: String, notesURL: URL?, informationOnly: Bool, stage: FoundUpdateStage,
                               reply: @escaping @MainActor (FoundUpdateReply) -> Void) {
        driverNotes = notesURL
        if informationOnly || rejectedVersions.contains(version) {
            NSLog("MacExplorer update %@ is %@; nothing to install", version,
                  informationOnly ? "informational only" : "rejected this session")
            if case .checking = model.state { model.send(.noUpdateFound(currentVersion: installedVersion)) }
            reply(.dismiss)
            didFinishUpdateCycle()
            return
        }
        switch stage {
        case .notDownloaded, .downloaded:
            didFindUpdate(version: version)
            reply(.install)   // download / extract now; showReady follows
        case .installing:
            foundVersion = version
            readyToInstall(version: version, notesURL: notesURL) { reply(.install) }
        }
    }

    func userDriverDownloadStarted() {
        expectedBytes = 0
        receivedBytes = 0
        downloadProgress(nil)
    }

    func userDriverDownloadExpectedLength(_ length: UInt64) { expectedBytes = length }

    func userDriverDownloadReceived(_ length: UInt64) {
        receivedBytes += length
        downloadProgress(expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil)
    }

    /// `showReady(toInstallAndRelaunch:)`: a one-shot reply.
    func userDriverReadyToInstall(reply: @escaping @MainActor () -> Void) {
        readyToInstall(version: foundVersion ?? "", notesURL: driverNotes, install: reply)
    }

    /// `showInstallingUpdate`: termination was cancelled (quit prompt → Cancel), so keep the badge; Restart Now
    /// retries through Sparkle's re-invocable `retryTerminatingApplication`.
    func userDriverInstalling(applicationTerminated: Bool, retry: @escaping @MainActor () -> Void) {
        guard !applicationTerminated else { return }
        readyToInstall(version: foundVersion ?? "", notesURL: driverNotes, reusable: true, install: retry)
    }

    // MARK: model → Sparkle

    private func restart() {
        if let install = pendingInstall {
            if !install.reusable { pendingInstall = nil }
            install.run()   // asks NSApp to terminate → quit prompt; Cancel keeps us running with the block armed.
        } else if case .readyToRestart = model.state {
            terminate()   // Fallback only: no install block on hand. Sparkle still installs on quit.
        }
    }

    // MARK: pure helpers

    static func mapError(domain: String, code: Int, message: String, version: String?) -> UpdateError {
        mapError(UpdateFailure(domain: domain, code: code, message: message), version: version)
    }

    /// Sparkle codes from the pinned SUErrors.h: 1003 running from a disk image, 1005 translocated, 3001 signature,
    /// 3002 validation. The whole underlying chain is searched because Sparkle wraps verification and network errors.
    static func mapError(_ failure: UpdateFailure, version: String?) -> UpdateError {
        if failure.contains(domain: sparkleDomain, codes: [3001, 3002]) { return .verificationFailed(version: version) }
        if failure.contains(domain: sparkleDomain, codes: [1003, 1005]) { return .notInApplications }
        if let url = failure.chain.first(where: { $0.domain == NSURLErrorDomain }) {
            switch url.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed: return .offline
            default: return .network(failure.message)
            }
        }
        return .other(failure.message)
    }

    static func isConfigured(info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty, key != unsetKey else { return false }
        return true
    }

    /// The app's controller, or nil when updates must stay off: debug builds, sandbox/scenario runs, unconfigured keys.
    public static func live(model: UpdateModel, settings: Core.Settings, options: LaunchOptions,
                            bundle: Bundle = .main) -> UpdateController? {
        #if DEBUG
        return nil
        #else
        guard !options.isSandboxed, bundle.bundleIdentifier?.hasSuffix(".scenarios") == false,
              isConfigured(info: bundle.infoDictionary ?? [:]) else { return nil }
        return SparkleBridge.makeController(model: model, settings: settings, bundle: bundle)
        #endif
    }
}
