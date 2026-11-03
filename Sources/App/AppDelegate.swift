import AppKit
import Core
import UI

/// App launch → AppBootstrap (UIContext/WindowManager); app-level commands (P1-30 adds AppLifecycle).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    let statePaths: StatePaths
    private(set) var context: UIContext?

    init(options: LaunchOptions) {
        self.options = options
        self.statePaths = options.stateDirectory.map { StatePaths(root: $0) } ?? .standard()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenuBuilder.install(in: NSApp)
        do {
            try FileManager.default.createDirectory(at: statePaths.root, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("macExplorer: cannot create state dir: \(error)\n".utf8))
            if options.isSandboxed { exit(73) }   // EX_CANTCREAT
        }
        Task { @MainActor [options, statePaths] in
            let context = await AppBootstrap.launch(options: options, statePaths: statePaths)
            self.context = context
            NSApp.activate()
            if let delay = options.smokeExitAfter { scheduleSmokeExit(after: delay) }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// §5.1: closing the last window leaves the app running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click with no window open: open one at the startup folder.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let context, context.windows.windows.isEmpty { newWindow(nil) }
        return true
    }

    /// ⌘N when no browser window handles it (no window open): the startup folder.
    @objc func macx_newWindow(_ sender: Any?) {
        guard let context else { return }
        let settings = context.environment.settings
        let url: URL = switch settings.startupFolder {
        case .home: settings.home
        case .lastLocation: settings.lastLocation ?? settings.home
        case .custom(let url): url
        }
        context.windows.openWindow(at: options.root ?? url)
    }

    private func newWindow(_ sender: Any?) { macx_newWindow(sender) }

    private func scheduleSmokeExit(after delay: Duration) {
        Task { @MainActor [options, statePaths] in
            try? await Task.sleep(for: delay)
            let titles = NSApp.orderedWindows.filter(\.isVisible).map(\.title)
            let report = SmokeReport(windowTitles: titles, root: options.root?.path(percentEncoded: false),
                                     processID: ProcessInfo.processInfo.processIdentifier)
            do {
                try report.write(to: statePaths.root.appending(path: SmokeReport.fileName))
            } catch {
                FileHandle.standardError.write(Data("macExplorer: cannot write smoke report: \(error)\n".utf8))
                exit(1)
            }
            exit(0)
        }
    }
}
