import Foundation
import Core

/// Shared UI services for one app (or one test/scenario world): the Core environment, launch options, the window
/// manager and the file-operation interaction (overview §3.14).
@MainActor
public final class UIContext {
    public let environment: CoreEnvironment
    public let options: LaunchOptions
    /// Created on first use (it holds an unowned reference back to this context); `init` touches it once so the
    /// volume-release handler is registered at launch.
    public private(set) lazy var windows: WindowManager = WindowManager(context: self)
    /// P1-26 installs BasicAlertInteraction; P1-38 installs InteractionRouter. Also sets environment.interaction's target.
    public private(set) var interaction: any FileOpInteraction
    /// Eject questions and errors (P1-28 EjectFlow); tests install a scripted one.
    var ejectPrompts: any EjectPrompting = AlertEjectPrompts()

    public init(environment: CoreEnvironment, options: LaunchOptions) {
        self.environment = environment
        self.options = options
        self.interaction = BasicAlertInteraction()
        _ = windows
        installInteraction(BasicAlertInteraction())
    }

    public func installInteraction(_ interaction: any FileOpInteraction) {
        self.interaction = interaction
        environment.interaction.setTarget(interaction)
    }
}
