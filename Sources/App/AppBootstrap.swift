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
    static func makeEnvironment(options: LaunchOptions, statePaths: StatePaths) -> CoreEnvironment {
        let lanes = LanePool()
        let sandboxed = options.isSandboxed
        let settings: any SettingsStorage = sandboxed ? FileSettingsStorage(fileURL: statePaths.settingsFile) : UserDefaultsStorage()
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

    /// Environment → UIContext → launch recovery and Core start → initial windows.
    static func launch(options: LaunchOptions, statePaths: StatePaths) async -> UIContext {
        let environment = makeEnvironment(options: options, statePaths: statePaths)
        let context = UIContext(environment: environment, options: options)
        _ = await environment.start()   // P1-30 shows the RecoveryReport notice when it is not empty
        await context.windows.restoreOrOpenInitial()
        return context
    }
}
