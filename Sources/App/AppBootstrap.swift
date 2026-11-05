import AppKit
import Core
import MacxFS
import UI

/// Builds the app's CoreEnvironment from LaunchOptions and runs the §3.14 launch obligations (S3 notes 6–7):
/// sandbox `home`, localized undo action names, `await environment.start()` before any window opens.
@MainActor
enum AppBootstrap {
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
            volumeEvents: WorkspaceVolumeEvents(), pasteboard: SystemPasteboard(name: options.pasteboardName),
            launchServices: launchServices, ejector: ejector, trash: trash, home: home)
        environment.undoActionName = { UndoActionNames.name(for: $0) }
        return environment
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
        let context = UIContext(environment: environment, options: options)
        let recovery = await environment.start()
        await context.windows.restoreOrOpenInitial()
        let lifecycle = AppLifecycle(context: context, flushSettings: { (storage as? FileSettingsStorage)?.flush() })
        lifecycle.didLaunch(recovery: recovery)
        if options.scenario == nil { CrashReporting.start(context: context, previous: previous, statePaths: statePaths) }
        let updates = UpdateController.live(model: context.updates, settings: environment.settings, options: options)
        return (context, lifecycle, updates, marker)
    }
}
