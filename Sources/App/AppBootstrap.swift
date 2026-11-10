import AppKit
import Core
import MacxFS
import UI

/// Builds the app's CoreEnvironment from LaunchOptions and runs the §3.14 launch obligations (S3 notes 6–7):
/// sandbox `home`, localized undo action names, `await environment.start()` before any window opens.
@MainActor
enum AppBootstrap {
    /// The longest the first window waits for a stored icon pack (QA round 1: a 2,000-image pack rasterizes in about
    /// 0.35 s on every core, so ordinary packs make it).
    static let iconPackLaunchWait: Duration = .milliseconds(500)

    /// Live services, or their sandbox stand-ins when `--state-dir` is given (overview Global Constraints › Safety):
    /// settings in `<state-dir>/settings.json`, a sandbox Trash, eject limited to images under the sandbox.
    static func makeEnvironment(options: LaunchOptions, statePaths: StatePaths,
                                settingsStorage: any SettingsStorage) -> CoreEnvironment {
        let lanes = LanePool()
        let sandboxed = options.isSandboxed
        let settings = settingsStorage
        let trash: any TrashService
        if let directory = options.sandboxTrash {
            trash = SandboxTrash(directory: directory)
        } else if sandboxed {
            trash = SandboxTrash(directory: statePaths.root.appending(path: "trash", directoryHint: .isDirectory))
        } else {
            trash = SystemTrash()
        }
        let ejector: any Ejecting = sandboxed ? SandboxEjector(root: options.root ?? statePaths.root, lanes: lanes)
                                              : WorkspaceEjector(lanes: lanes)
        let launchServices: any LaunchServicesProviding = options.fakeLaunchServices ? FakeLaunchServices()
                                                                                       : WorkspaceLaunchServices(lanes: lanes)
        let home = (sandboxed ? options.root : nil) ?? FileManager.default.homeDirectoryForCurrentUser
        let environment = CoreEnvironment(
            statePaths: statePaths, lanes: lanes, settingsStorage: settings, volumeScanner: SystemVolumeScanner(),
            volumeEvents: WorkspaceVolumeEvents(), pasteboard: makePasteboard(options: options),
            launchServices: launchServices, ejector: ejector, trash: trash, home: home,
            searchServices: SearchServices.forLaunch(options, lanes: lanes))
        environment.undoActionName = { UndoActionNames.name(for: $0) }
        return environment
    }

    /// The private --pasteboard when given; a sandboxed run without one keeps its clipboard in memory, so it never
    /// writes NSPasteboard.general (S5-C2, which P2-04 extends from Copy as Path to every clipboard write).
    static func makePasteboard(options: LaunchOptions) -> any PasteboardBackend {
        if options.pasteboardName == nil, options.isSandboxed { return InMemoryPasteboard() }
        return SystemPasteboard(name: options.pasteboardName)
    }

    /// Settings in `<state-dir>/settings.json` in sandbox runs, else the app's user defaults.
    static func makeSettingsStorage(options: LaunchOptions, statePaths: StatePaths) -> any SettingsStorage {
        options.isSandboxed ? FileSettingsStorage(fileURL: statePaths.settingsFile) : UserDefaultsStorage()
    }

    /// Environment → UIContext → launch recovery and Core start → initial windows → AppLifecycle (onboarding sheet,
    /// recovery notice when the RecoveryReport is not empty, Dock badge) → the updater (nil in debug, sandbox and
    /// scenario runs, or when Info.plist has no real feed/key). First of all, the previous session's dirty-exit marker
    /// is read and this session's is written; after a dirty exit the crash-report flow runs (never in scenarios,
    /// which kill the app on purpose and must not hang on a prompt at their next launch).
    static func launch(options: LaunchOptions, statePaths: StatePaths)
        async -> (context: UIContext, lifecycle: AppLifecycle, updates: UpdateController?, marker: DirtyExitMarker) {
        let marker = DirtyExitMarker(fileURL: statePaths.sessionMarker)
        let previous = marker.previous()
        let info = Bundle.main.infoDictionary ?? [:]
        try? marker.begin(SessionMarker(pid: ProcessInfo.processInfo.processIdentifier,
                                        version: info["CFBundleShortVersionString"] as? String ?? "unknown",
                                        build: info["CFBundleVersion"] as? String ?? "unknown", launchedAt: Date()))
        let storage = makeSettingsStorage(options: options, statePaths: statePaths)
        let environment = makeEnvironment(options: options, statePaths: statePaths, settingsStorage: storage)
        if let keymapFile = options.keymapFile, await !applyKeymap(keymapFile, to: environment) {
            marker.end()   // a usage error, not a crash: no crash-report flow at the next launch
            exit(65)       // EX_DATAERR
        }
        let context = UIContext(environment: environment, options: options)
        // The icon pack (P4-08) loads and rasterizes on lanes alongside Core's start; the windows wait for it (at most
        // `iconPackLaunchWait`) so their first frame already uses it. A pack that takes longer lands later and redraws.
        async let iconPack: Void = context.restoreIconPack(waitingAtMost: iconPackLaunchWait)
        let recovery = await environment.start()
        await iconPack
        await context.windows.restoreOrOpenInitial()
        let lifecycle = AppLifecycle(context: context, flushSettings: { (storage as? FileSettingsStorage)?.flush() })
        lifecycle.didLaunch(recovery: recovery)
        if options.scenario == nil { CrashReporting.start(context: context, previous: previous, statePaths: statePaths) }
        let updates = UpdateController.live(model: context.updates, settings: environment.settings, options: options)
        return (context, lifecycle, updates, marker)
    }

    /// `--keymap <file>` (P4-02; sandbox runs only, `LaunchOptions` requires `--state-dir`): reads the file on a lane
    /// and imports it into the sandbox settings before any window or menu reads them. false (after printing why) when
    /// the file can't be read or used; the caller exits 65 (EX_DATAERR).
    private static func applyKeymap(_ file: URL, to environment: CoreEnvironment) async -> Bool {
        do {
            let data = try await environment.lanes.perform(on: .unknown, .fileOp) { _ in try Data(contentsOf: file) }
            for warning in try environment.settings.importKeymap(data) {
                FileHandle.standardError.write(Data("macExplorer: --keymap: skipped \(warning)\n".utf8))
            }
            return true
        } catch {
            FileHandle.standardError.write(Data("macExplorer: --keymap \(file.path(percentEncoded: false)): \(error)\n".utf8))
            return false
        }
    }
}
