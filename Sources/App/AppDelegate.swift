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
        NSApp.mainMenu = makeMainMenu()
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

    /// Interim menu (P1-29's MainMenuBuilder replaces it): Quit, New Window (⌘N), Close Window (⌘W), Edit basics.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            for child in items { menu.addItem(child) }
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: String, _ key: String) -> NSMenuItem {
            NSMenuItem(title: L10n.string(title), action: NSSelectorFromString(action), keyEquivalent: key)
        }
        submenu("macExplorer", [item("Quit macExplorer", "terminate:", "q")])
        submenu(L10n.string("File"), [item("New Window", Command.newWindow.selectorName, "n"),
                                      item("Close Window", "performClose:", "w")])
        let redo = item("Redo", "redo:", "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu(L10n.string("Edit"), [item("Undo", "undo:", "z"), redo, .separator(),
                                      item("Cut", "cut:", "x"), item("Copy", "copy:", "c"), item("Paste", "paste:", "v"),
                                      item("Select All", "selectAll:", "a")])
        submenu(L10n.string("Window"), [item("Minimize", "performMiniaturize:", "m")])
        return main
    }
}
