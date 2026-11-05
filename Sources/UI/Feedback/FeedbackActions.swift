import AppKit
import Core

/// Help › Report a Bug… / Request a Feature… and the toolbar Send Feedback menu (spec §4.1): open the GitHub issue
/// form in the browser, prefilled. Sandbox runs record the URL instead (ExternalOpeners).
@MainActor public enum FeedbackActions {
    static let reportBugAction = NSSelectorFromString("macx_reportBug:")
    static let requestFeatureAction = NSSelectorFromString("macx_requestFeature:")

    public static func open(_ kind: IssueKind, context: UIContext) { open(kind, context: context, opener: nil) }

    static func open(_ kind: IssueKind, context: UIContext, opener: (any ExternalURLOpening)?) {
        let url = IssueURLBuilder.url(kind: kind, environment: environment(context: context))
        (opener ?? ExternalOpeners.opener(for: context.options)).open(url)
    }

    static func environment(context: UIContext) -> EnvironmentSummary {
        EnvironmentSummary.current(channel: context.environment.settings.updateChannel)
    }

    /// The toolbar's Send Feedback menu (nil-targeted actions, handled by the app delegate).
    static func menu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("Send Feedback"))
        menu.identifier = NSUserInterfaceItemIdentifier(AXID.feedbackMenu)
        menu.addItem(NSMenuItem(title: L10n.string("Report a Bug…"), action: reportBugAction, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.string("Request a Feature…"), action: requestFeatureAction, keyEquivalent: ""))
        return menu
    }
}
