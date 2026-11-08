import AppKit
import Core
import UI

/// App launch → AppBootstrap (UIContext/WindowManager/AppLifecycle); app-level commands and termination go through
/// AppLifecycle (P1-30).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    let statePaths: StatePaths
    private(set) var context: UIContext?
    private(set) var lifecycle: AppLifecycle?
    /// Keeps the Sparkle updater alive for the app's lifetime (nil when updates are off).
    private var updateController: UpdateController?
    /// This session's dirty-exit marker; removed on clean termination (spec §4.2).
    private var sessionMarker: DirtyExitMarker?

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
            let launched = await AppBootstrap.launch(options: options, statePaths: statePaths)
            self.context = launched.context
            self.lifecycle = launched.lifecycle
            self.updateController = launched.updates
            self.sessionMarker = launched.marker
            ScenarioLaunch.runIfRequested(context: launched.context)
            if options.scenario == nil { NSApp.activate() }   // UI scenarios run inactive (P1-41)
            if let delay = options.smokeExitAfter { scheduleSmokeExit(after: delay) }
        }
    }

    /// §6.7: with jobs active or blocked, ask "N operations are in progress" (Stop and Quit / Cancel).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle?.shouldTerminate() ?? .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateController?.applicationWillTerminate()   // an armed rollback records itself before settings flush
        lifecycle?.willTerminate()
        sessionMarker?.end()
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

    /// macExplorer › Settings… (⌘,).
    @objc func macx_showSettings(_ sender: Any?) {
        lifecycle?.showSettings()
    }

    /// Window › Operations when no browser window handles it (AppLifecycle's Window › Operations entry).
    @objc func macx_showOperations(_ sender: Any?) {
        lifecycle?.showOperations()
    }

    /// macExplorer › Check for Updates…: the key window's update badge shows the result.
    @objc func macx_checkForUpdates(_ sender: Any?) {
        guard let context else { return }
        if context.windows.windows.isEmpty { newWindow(nil) }
        context.updates.checkNow()
    }

    /// macExplorer › Install Previous Version…: the release picker window.
    @objc func macx_installPreviousVersion(_ sender: Any?) {
        context?.updates.showInstallPreviousVersion()
    }

    /// Help › Report a Bug… and the toolbar's Send Feedback menu: the prefilled GitHub bug form.
    @objc func macx_reportBug(_ sender: Any?) { if let context { FeedbackActions.open(.bug, context: context) } }

    /// Help › Request a Feature… and the toolbar's Send Feedback menu: the GitHub feature form.
    @objc func macx_requestFeature(_ sender: Any?) { if let context { FeedbackActions.open(.feature, context: context) } }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == UpdateCommands.checkForUpdates { return context?.updates.isAvailable ?? false }
        if item.action == UpdateCommands.installPreviousVersion { return context?.updates.canInstallPreviousVersion ?? false }
        return true
    }

    private func scheduleSmokeExit(after delay: Duration) {
        Task { @MainActor [options, statePaths] in
            try? await Task.sleep(for: delay)
            let titles = NSApp.orderedWindows.filter(\.isVisible).map(\.title)
            let report = SmokeReport(windowTitles: titles, root: options.root?.path(percentEncoded: false),
                                     processID: ProcessInfo.processInfo.processIdentifier)
            self.lifecycle?.willTerminate()
            self.sessionMarker?.end()
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
