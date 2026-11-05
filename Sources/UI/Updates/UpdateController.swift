import Foundation
import Core

/// The Sparkle engine as `UpdateController` needs it (a fake in tests; `SparkleEngine` in SparkleBridge.swift).
@MainActor protocol UpdaterEngine: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    func start() throws
    func checkInBackground()
}

/// Glue between Sparkle callbacks (forwarded by SparkleBridge) and `UpdateModel` (spec §3). No Sparkle types here.
@MainActor
public final class UpdateController {
    /// The Info.plist sentinel for "no EdDSA key configured yet".
    static let unsetKey = "REPLACE_WITH_SPARKLE_PUBLIC_KEY"

    let model: UpdateModel
    private let settings: Core.Settings
    private let engine: any UpdaterEngine
    private let installedVersion: String
    private let terminate: @MainActor () -> Void
    private var pendingInstall: (@MainActor () -> Void)?
    private var foundVersion: String?

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

    // MARK: Sparkle → model (called by SparkleBridge)

    func allowedChannels() -> Set<String> { settings.updateChannel.sparkleChannels }

    func didFindUpdate(version: String) {
        foundVersion = version
        model.send(.updateFound(version: version))
    }

    func didNotFindUpdate() { model.send(.noUpdateFound(currentVersion: installedVersion)) }

    func downloadProgress(_ fraction: Double?) { model.send(.downloadProgress(fraction)) }

    /// Silent path: Sparkle downloaded and will install on quit; `install` installs and relaunches now.
    func willInstallOnQuit(version: String, notesURL: URL?, install: @escaping @MainActor () -> Void) {
        readyToInstall(version: version, notesURL: notesURL, install: install)
    }

    /// Foreground (user-driver) path: same UI, different Sparkle reply.
    func readyToInstall(version: String, notesURL: URL?, install: @escaping @MainActor () -> Void) {
        pendingInstall = install
        model.send(.readyToInstall(version: version, notesURL: notesURL))
    }

    func didAbort(domain: String, code: Int, message: String) {
        let error = Self.mapError(domain: domain, code: code, message: message, version: foundVersion)
        NSLog("MacExplorer update failed: %@ %ld %@", domain, code, message)
        model.send(.failed(error))
    }

    // MARK: model → Sparkle

    private func restart() {
        if let install = pendingInstall {
            pendingInstall = nil
            install()
        } else if case .readyToRestart = model.state {
            terminate()   // Sparkle still installs on quit; the quit prompt guards running jobs.
        }
    }

    // MARK: pure helpers

    /// Sparkle codes from SUErrors.h (verify against the pinned version's header): 1003 running from a disk image,
    /// 1005 translocated, 3001 signature, 3002 validation.
    static func mapError(domain: String, code: Int, message: String, version: String?) -> UpdateError {
        if domain == "SUSparkleErrorDomain" {
            switch code {
            case 1003, 1005: return .notInApplications
            case 3001, 3002: return .verificationFailed(version: version)
            default: return .other(message)
            }
        }
        if domain == NSURLErrorDomain {
            switch code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed: return .offline
            default: return .network(message)
            }
        }
        return .other(message)
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
