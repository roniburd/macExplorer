import Foundation
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
    /// Tier 2 (P2-17): Quick Look thumbnails shared by every window's Icons view (64 MB cost limit).
    let thumbnails = ThumbnailCache()
    /// Makes each Icons view's thumbnail generator; tests install a fake so nothing calls Quick Look.
    var makeThumbnailGenerator: @MainActor () -> any ThumbnailGenerating = { QLThumbnailGeneratorAdapter() }
    /// Eject questions and errors (P1-28 EjectFlow); tests install a scripted one.
    var ejectPrompts: any EjectPrompting = AlertEjectPrompts()
    /// The open Settings window (P1-30), if any; SettingsWindowController.show reuses it.
    var settingsWindow: SettingsWindowController?
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
    }

    /// Window › Operations; the app delegate calls it when no browser window is open.
    public func showOperationsPanel() { operationsUI.showPanel() }

    public func installInteraction(_ interaction: any FileOpInteraction) {
        self.interaction = interaction
        environment.interaction.setTarget(interaction)
    }
}
