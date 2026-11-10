import AppKit
import Core

/// Shared UI services for one app (or one test/scenario world): the Core environment, launch options, the window
/// manager and the file-operation interaction (overview §3.14).
@MainActor
public final class UIContext {
    public let environment: CoreEnvironment
    public let options: LaunchOptions
    /// Update state for the badge, the app menu and Settings; inert unless the app installs an UpdateController.
    public let updates = UpdateModel()
    /// Created on first use (it holds an unowned reference back to this context); `init` touches it once so the
    /// volume-release handler is registered at launch.
    public private(set) lazy var windows: WindowManager = WindowManager(context: self)
    /// InteractionRouter (P1-38) unless a test installs another. Also sets environment.interaction's target.
    public private(set) var interaction: any FileOpInteraction
    /// §4.4 icon tiers (P1-31), shared by every window's lists.
    let icons: IconCache
    /// Settings › General › Icon pack (P4-08), applied to `icons`.
    private(set) lazy var iconPack = IconPackModel(settings: environment.settings, lanes: environment.lanes, icons: icons,
                                                   options: options)
    /// Tier 2 (P2-17): Quick Look thumbnails shared by every window's Icons view (64 MB cost limit).
    let thumbnails = ThumbnailCache()
    /// Makes each Icons view's thumbnail generator; tests install a fake so nothing calls Quick Look.
    var makeThumbnailGenerator: @MainActor () -> any ThumbnailGenerating = { QLThumbnailGeneratorAdapter() }
    /// Eject questions and errors (P1-28 EjectFlow); tests install a scripted one.
    var ejectPrompts: any EjectPrompting = AlertEjectPrompts()
    /// Save Search… and Rename Saved Search ask for a name here (P3-11); tests install a scripted one.
    var namePrompter: any NamePrompting = SheetNamePrompter()
    /// The open Settings window (P1-30), if any; SettingsWindowController.show reuses it.
    var settingsWindow: SettingsWindowController?
    /// Keeps the active key table and the menu bar in step with Settings › Shortcuts.
    private var keyBindings: KeyBindingsController?
    /// P1-38: interaction router, Operations panel and job list (§6.2, §6.7).
    private(set) lazy var operationsUI = OperationsUI(context: self)

    public init(environment: CoreEnvironment, options: LaunchOptions) {
        self.environment = environment
        self.options = options
        // Kind for unregistered extensions (dynamic types have no description): never the dyn.* identifier.
        environment.types.setGenericDescriptions(document: L10n.string("Document"), folder: L10n.string("Folder"))
        self.icons = IconCache(lanes: environment.lanes, types: environment.types)
        self.interaction = BasicAlertInteraction()
        _ = windows
        installInteraction(operationsUI.router)   // P1-38: InteractionRouter replaces BasicAlertInteraction
        keyBindings = KeyBindingsController(settings: environment.settings)
    }

    /// The pasteboard for image Copy/Paste in Properties' icon well (P4-08): the private `--pasteboard` when given,
    /// none in other sandbox runs (never the system clipboard there), else the general pasteboard.
    var imagePasteboard: NSPasteboard? {
        if let name = options.pasteboardName { return NSPasteboard(name: NSPasteboard.Name(name)) }
        return options.isSandboxed ? nil : .general
    }

    /// At launch (AppBootstrap): the icon pack stored in Settings, if any (P4-08).
    public func restoreIconPack() async { await iconPack.restore() }

    /// AppBootstrap: `restoreIconPack`, waiting for it at most `limit` so the first window frame already shows the
    /// pack (P4-08). A pack still loading then lands later and the lists redraw (`IconCache.iconPackChanged`).
    public func restoreIconPack(waitingAtMost limit: Duration) async {
        // Not a task group: a group waits for every child, and awaiting the restore can't be cancelled.
        final class Once { var continuation: CheckedContinuation<Void, Never>? }
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.continuation = continuation
            func finish() { once.continuation?.resume(); once.continuation = nil }
            Task { await self.restoreIconPack(); finish() }
            Task { try? await Task.sleep(for: limit); finish() }
        }
    }

    /// Window › Operations; the app delegate calls it when no browser window is open.
    public func showOperationsPanel() { operationsUI.showPanel() }

    public func installInteraction(_ interaction: any FileOpInteraction) {
        self.interaction = interaction
        environment.interaction.setTarget(interaction)
    }
}
