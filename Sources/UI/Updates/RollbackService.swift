import AppKit
import Core
import Security

/// Why Install Previous Version… stopped. The installed app is never touched when one of these is thrown.
enum RollbackError: Error, Equatable {
    case updatePending
    case notReplaceable(String)
    case network(String)
    case badFeed
    case badSignature
    case wrongApp(String)
    case unpackFailed(String)

    var message: String {
        switch self {
        case .updatePending:
            L10n.string("An update is waiting to install. Restart to finish it, then install the previous version.")
        case .notReplaceable(let path):
            String(format: L10n.string("MacExplorer can't replace itself at %@. Move it to the Applications folder and try again."), path)
        case .network(let detail):
            String(format: L10n.string("Couldn't download from the update server (%@)."), detail)
        case .badFeed:
            L10n.string("The list of releases couldn't be read.")
        case .badSignature:
            L10n.string("The download failed its signature check and was deleted. Nothing was changed.")
        case .wrongApp(let detail):
            String(format: L10n.string("The downloaded app isn't a MacExplorer release signed like this one (%@). Nothing was changed."), detail)
        case .unpackFailed(let detail):
            String(format: L10n.string("The download couldn't be unpacked (%@)."), detail)
        }
    }
}

/// A verified older app waiting in a staging folder on the app's volume.
struct StagedRollback: Equatable {
    var item: AppcastItem
    var stagedApp: URL
    var backup: URL
    var directory: URL
}

/// What RollbackModel needs (a fake in tests; `RollbackService` live).
@MainActor protocol RollbackServicing: AnyObject {
    var installedVersion: String { get }
    func preflight() -> RollbackError?
    func candidates() async throws(RollbackError) -> [AppcastItem]
    func prepare(_ item: AppcastItem, progress: @escaping @MainActor (Double?) -> Void) async throws(RollbackError) -> StagedRollback
    /// The staged app replaces this one when MacExplorer quits (the swap runs from `willTerminate`).
    func arm(_ staged: StagedRollback)
    func disarm()
    func quit()
}

// MARK: dependencies

@MainActor protocol RollbackTransport {
    func data(from url: URL) async throws -> Data
    /// Downloads to a temporary file the caller moves or deletes.
    func download(_ url: URL, progress: @escaping @MainActor (Double?) -> Void) async throws -> URL
}

protocol RollbackUnpacker: Sendable {
    func unzip(_ archive: URL, into directory: URL) async throws
}

/// The app's own designated requirement against a candidate bundle.
protocol RollbackCodeCheck: Sendable {
    func signedLikeRunningApp(_ app: URL) -> Bool
}

/// Starts the swap helper (a Process in the app; recorded in tests).
protocol RollbackLauncher {
    func launch(script: URL, arguments: [String], log: URL) throws
}

/// Install Previous Version…: lists older releases from the appcast, downloads one, verifies it (EdDSA, bundle id,
/// build, designated requirement), stages it next to the app and, at quit, hands it to the swap helper.
@MainActor
final class RollbackService: RollbackServicing {
    struct Config {
        var feedURL: URL
        var publicKey: String
        var appURL: URL
        var bundleID: String
        var installedVersion: String
        var installedBuild: Int
        var processID: Int32 = ProcessInfo.processInfo.processIdentifier
        /// Command the helper runs to relaunch (tests pass /usr/bin/true).
        var opener: String = "/usr/bin/open"
    }

    let config: Config
    private let settings: Core.Settings
    private let updateInFlight: @MainActor () -> Bool
    private let transport: any RollbackTransport
    private let unpacker: any RollbackUnpacker
    private let codeCheck: any RollbackCodeCheck
    private let launcher: any RollbackLauncher
    private let terminate: @MainActor () -> Void
    private let sparkleSkip: SparkleSkippedVersion
    private(set) var armed: StagedRollback?

    init(config: Config, settings: Core.Settings, updateInFlight: @escaping @MainActor () -> Bool,
         transport: any RollbackTransport, unpacker: any RollbackUnpacker, codeCheck: any RollbackCodeCheck,
         launcher: any RollbackLauncher, sparkleSkip: SparkleSkippedVersion = .inert,
         terminate: @escaping @MainActor () -> Void) {
        self.config = config
        self.settings = settings
        self.sparkleSkip = sparkleSkip
        self.updateInFlight = updateInFlight
        self.transport = transport
        self.unpacker = unpacker
        self.codeCheck = codeCheck
        self.launcher = launcher
        self.terminate = terminate
    }

    var installedVersion: String { config.installedVersion }

    /// Live service, or nil when the bundle has no feed, key or numeric build.
    static func live(controller: UpdateController, settings: Core.Settings, bundle: Bundle) -> RollbackService? {
        let info = bundle.infoDictionary ?? [:]
        guard UpdateController.isConfigured(info: info),
              let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
              let key = info["SUPublicEDKey"] as? String,
              let build = controller.installedBuild,
              let id = bundle.bundleIdentifier else { return nil }
        let config = Config(feedURL: feed, publicKey: key, appURL: bundle.bundleURL, bundleID: id,
                            installedVersion: info["CFBundleShortVersionString"] as? String ?? "\(build)",
                            installedBuild: build)
        return RollbackService(config: config, settings: settings,
                               updateInFlight: { [weak controller] in controller?.updateInFlight ?? false },
                               transport: URLSessionRollbackTransport(), unpacker: DittoUnpacker(),
                               codeCheck: DesignatedRequirementCheck(), launcher: ProcessRollbackLauncher(),
                               sparkleSkip: .live, terminate: { NSApp.terminate(nil) })
    }

    static func trashQuietly(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
            NSLog("MacExplorer couldn't move the replaced app %@ to the Trash: %@", url.path(percentEncoded: false), String(describing: error))
        }
    }

    // MARK: RollbackServicing

    func preflight() -> RollbackError? {
        if updateInFlight() { return .updatePending }
        let app = config.appURL.standardizedFileURL
        let path = app.path(percentEncoded: false)
        let parent = app.deletingLastPathComponent().path(percentEncoded: false)
        if path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: parent) {
            return .notReplaceable(path)
        }
        return nil
    }

    func candidates() async throws(RollbackError) -> [AppcastItem] {
        let data: Data
        do { data = try await transport.data(from: config.feedURL) } catch { throw .network(Self.describe(error)) }
        guard let items = try? AppcastParser.parse(data) else { throw .badFeed }
        return RollbackCatalog.candidates(items, channel: settings.updateChannel, installedBuild: config.installedBuild,
                                          osVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }

    func prepare(_ item: AppcastItem, progress: @escaping @MainActor (Double?) -> Void) async throws(RollbackError) -> StagedRollback {
        if let blocked = preflight() { throw blocked }
        let fm = FileManager.default
        let directory: URL
        do {
            directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: config.appURL, create: true)
        } catch { throw .notReplaceable(config.appURL.path(percentEncoded: false)) }
        do {
            let staged = try await stage(item, in: directory, progress: progress)
            return staged
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    private func stage(_ item: AppcastItem, in directory: URL,
                       progress: @escaping @MainActor (Double?) -> Void) async throws(RollbackError) -> StagedRollback {
        let fm = FileManager.default
        let archive = directory.appending(path: "rollback.zip")
        do {
            let downloaded = try await transport.download(item.enclosureURL, progress: progress)
            try fm.moveItem(at: downloaded, to: archive)
        } catch { throw .network(Self.describe(error)) }
        progress(nil)
        guard RollbackSignature.isValid(file: archive, signature: item.edSignature, publicKey: config.publicKey) else {
            throw .badSignature
        }
        let unpacked = directory.appending(path: "unpacked", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await unpacker.unzip(archive, into: unpacked)
        } catch { throw .unpackFailed(Self.describe(error)) }
        try? fm.removeItem(at: archive)
        let apps = (try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else { throw .wrongApp(L10n.string("no single app in the archive")) }
        let plist = app.appending(path: "Contents/Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? [:]
        guard info["CFBundleIdentifier"] as? String == config.bundleID else { throw .wrongApp(L10n.string("bundle identifier")) }
        guard (info["CFBundleVersion"] as? String).flatMap({ Int($0) }) == item.build else { throw .wrongApp(L10n.string("build number")) }
        guard codeCheck.signedLikeRunningApp(app) else { throw .wrongApp(L10n.string("code signature")) }
        let backup = directory.appending(path: "Replaced-\(config.installedBuild).app", directoryHint: .isDirectory)
        return StagedRollback(item: item, stagedApp: app, backup: backup, directory: directory)
    }

    func arm(_ staged: StagedRollback) {
        if let old = armed, old.directory != staged.directory { try? FileManager.default.removeItem(at: old.directory) }
        armed = staged
    }

    func disarm() {
        guard let staged = armed else { return }
        armed = nil
        try? FileManager.default.removeItem(at: staged.directory)
    }

    func quit() { terminate() }

    /// `applicationWillTerminate`: the quit is certain, so record the rollback and start the swap helper. A cancelled
    /// quit never gets here, so nothing is swapped behind the user's back.
    func willTerminate() {
        guard let staged = armed else { return }
        armed = nil
        let script = staged.directory.appending(path: "swap.sh")
        do {
            try Data(RollbackSwap.script.utf8).write(to: script)
            settings.pendingRollback = PendingRollback(targetBuild: staged.item.build, fromBuild: config.installedBuild,
                                                       backupPath: staged.backup.path(percentEncoded: false))
            // Read by the older build's Sparkle, which knows nothing of `updateSkipThroughBuild`. If the swap fails,
            // skipping builds ≤ the one still installed changes nothing.
            sparkleSkip.set(config.installedBuild)
            try launcher.launch(script: script, arguments: RollbackSwap.arguments(
                pid: config.processID, app: config.appURL, staged: staged.stagedApp, backup: staged.backup, opener: config.opener),
                log: staged.directory.appending(path: "swap.log"))
        } catch {
            settings.pendingRollback = nil
            NSLog("MacExplorer couldn't start the rollback to %@: %@", staged.item.version, String(describing: error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain ? ns.localizedDescription : String(describing: error)
    }
}

/// The swap helper (install-previous-version spec): waits for MacExplorer to exit, moves it aside, moves the staged
/// app in and reopens it; if the second move fails it puts the original back and reopens that.
enum RollbackSwap {
    static let script = #"""
    #!/bin/sh
    # MacExplorer Install Previous Version swap: <pid> <app> <staged app> <backup path> <opener>
    pid="$1"; app="$2"; staged="$3"; backup="$4"; opener="$5"
    n=0
    while kill -0 "$pid" 2>/dev/null; do
      n=$((n + 1))
      if [ "$n" -gt 600 ]; then echo "MacExplorer ($pid) did not quit; nothing changed"; exit 1; fi
      sleep 0.1
    done
    if ! mv "$app" "$backup"; then echo "cannot move $app aside; nothing changed"; "$opener" "$app"; exit 2; fi
    if ! mv "$staged" "$app"; then
      echo "cannot move $staged into place; restoring"
      mv "$backup" "$app"
      "$opener" "$app"
      exit 3
    fi
    echo "installed $app"
    "$opener" "$app"
    """#

    static func arguments(pid: Int32, app: URL, staged: URL, backup: URL, opener: String) -> [String] {
        [String(pid), app.path(percentEncoded: false), staged.path(percentEncoded: false),
         backup.path(percentEncoded: false), opener]
    }
}

// MARK: live dependencies

@MainActor
final class URLSessionRollbackTransport: RollbackTransport {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try Self.check(response)
        return data
    }

    func download(_ url: URL, progress: @escaping @MainActor (Double?) -> Void) async throws -> URL {
        let observer = ProgressRelay(progress)
        let (file, response) = try await session.download(from: url, delegate: observer)
        try Self.check(response)
        // The system deletes `file` when this returns to the run loop: move it now.
        let kept = FileManager.default.temporaryDirectory.appending(path: "macx-rollback-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
    }
}

/// Forwards a download task's fraction to the main actor.
private final class ProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Confinement: `observation` is written once in didCreateTask (URLSession's delegate queue) and only read by deinit.
    private let report: @MainActor (Double?) -> Void
    private var observation: NSKeyValueObservation?
    init(_ report: @escaping @MainActor (Double?) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            Task { @MainActor in report(fraction) }
        }
    }
}

struct DittoUnpacker: RollbackUnpacker {
    func unzip(_ archive: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path(percentEncoded: false), directory.path(percentEncoded: false)]
        let pipe = Pipe()
        process.standardError = pipe
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { continuation.resume() } else {
                    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: NSError(domain: "ditto", code: Int(p.terminationStatus),
                                                          userInfo: [NSLocalizedDescriptionKey: text]))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// The running app's designated requirement (for releases: bundle id + the persistent cert's leaf hash) checked
/// against the candidate, all architectures and nested code included. An ad-hoc running app never matches.
struct DesignatedRequirementCheck: RollbackCodeCheck {
    func signedLikeRunningApp(_ app: URL) -> Bool {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess
    }
}

struct ProcessRollbackLauncher: RollbackLauncher {
    func launch(script: URL, arguments: [String], log: URL) throws {
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path(percentEncoded: false)] + arguments
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }
}
