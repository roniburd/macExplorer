import AppKit
import Core

/// App-level lifecycle the AppDelegate forwards to (§6.7, §5.9): quit while jobs run (Stop and Quit / Cancel, at most
/// 10 s of cancelling), the Dock badge, the first-launch onboarding sheet and the launch-recovery notice, Settings…
/// and Window › Operations, and the flush at termination.
@MainActor
public final class AppLifecycle {
    /// §6.7: after this long the app quits anyway and launch cleanup uses the journal.
    public static let stopTimeout: Duration = .seconds(10)
    /// How often an open quit question checks whether the jobs finished on their own.
    static let quitWatchInterval: Duration = .milliseconds(100)

    let context: UIContext
    private let terminator: any JobTerminating
    private let prompts: any QuitPrompting
    private let reply: @MainActor (Bool) -> Void
    private let flushSettings: @MainActor () -> Void
    private var dockBadge: DockBadgeController?
    /// The running quit question / Stop and Quit (nil when none). Tests await it.
    private(set) var quitTask: Task<Void, Never>?

    /// Launch presenters (tests record instead).
    var presentOnboarding: @MainActor (NSWindow) -> Void = { _ in }
    var presentRecoveryNotice: @MainActor (RecoveryNotice, NSWindow?) -> Void = { notice, window in
        AppLifecycle.showAlert(notice, on: window)
    }

    /// The app: TerminationCoordinator, an app-modal quit alert, NSApp's terminate reply and the Dock tile.
    /// `flushSettings` writes pending settings synchronously (FileSettingsStorage.flush in sandbox runs).
    public convenience init(context: UIContext, flushSettings: @escaping @MainActor () -> Void = {}) {
        self.init(context: context, terminator: context.environment.termination, prompts: AlertQuitPrompts(),
                  reply: { NSApp.reply(toApplicationShouldTerminate: $0) },
                  dockBadge: { NSApp.dockTile.badgeLabel = $0 }, flushSettings: flushSettings)
    }

    init(context: UIContext, terminator: any JobTerminating, prompts: any QuitPrompting,
         reply: @escaping @MainActor (Bool) -> Void, dockBadge: @escaping @MainActor (String?) -> Void,
         flushSettings: @escaping @MainActor () -> Void) {
        self.context = context
        self.terminator = terminator
        self.prompts = prompts
        self.reply = reply
        self.flushSettings = flushSettings
        self.dockBadge = DockBadgeController(operations: context.environment.operations, sink: dockBadge)
        presentOnboarding = { [unowned context] window in OnboardingSheet.present(on: window, context: context) }
    }

    // MARK: launch

    /// After `environment.start()` and the first windows: onboarding on the first window (first launch only), then the
    /// recovery notice when LaunchRecovery cleaned anything up.
    public func didLaunch(recovery: RecoveryReport) {
        let window = context.windows.windows.first?.window
        if let window, OnboardingSheet.shouldShow(settings: context.environment.settings, options: context.options) {
            presentOnboarding(window)
        }
        if let notice = RecoveryNotice(recovery) { presentRecoveryNotice(notice, window) }
    }

    // MARK: quit (§6.7)

    /// `applicationShouldTerminate(_:)`: quit now when no job is active or blocked; otherwise ask and reply later.
    public func shouldTerminate() -> NSApplication.TerminateReply {
        guard quitTask == nil else { return .terminateCancel }
        let count = terminator.activeCount
        guard count > 0 else { return .terminateNow }
        // While the question shows, keep watching the queue: once no job is active or blocked any more, close it
        // and quit (QA round 2: the prompt used to outlive the jobs).
        let watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.quitWatchInterval)
                guard let self, !Task.isCancelled else { return }
                if self.terminator.activeCount == 0 {
                    self.prompts.dismiss()
                    return
                }
            }
        }
        quitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let choice = await prompts.confirmQuit(activeCount: count)
            watcher.cancel()
            switch choice {
            case .cancel:
                reply(false)
            case .jobsFinished:
                reply(true)
            case .stopAndQuit:
                // Cancel every job through the §6.1 cancel path; quit even if that times out (journal cleanup).
                context.operationsUI.router.stopAnswering()
                _ = await terminator.stopAllAndWait(timeout: Self.stopTimeout)
                reply(true)
            }
            quitTask = nil
        }
        return .terminateLater
    }

    /// `applicationWillTerminate(_:)` (and the smoke exit): write pending settings, clear the Dock badge, release the
    /// private pasteboard of a sandboxed run.
    public func willTerminate() {
        flushSettings()
        context.environment.folderViews.flush()
        dockBadge?.stop()
        dockBadge = nil
        if let name = context.options.pasteboardName { NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally() }
    }

    // MARK: app commands

    /// macExplorer › Settings… (⌘,).
    public func showSettings() {
        SettingsWindowController.show(context: context)
    }

    /// Window › Operations with no browser window to handle it: the standalone Operations panel (§6.7).
    public func showOperations() {
        context.showOperationsPanel()
    }

    // MARK: presenters

    private static func showAlert(_ notice: RecoveryNotice, on window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = notice.message
        alert.informativeText = notice.details
        alert.addButton(withTitle: L10n.string("OK"))
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
