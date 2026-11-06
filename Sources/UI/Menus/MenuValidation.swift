import AppKit
import Core

/// Menu-item enablement shared by the main menu (P1-29), the command bar and CommandHandlingViewController.
@MainActor enum MenuValidation {
    /// false for the active bindings' colliding commands while a field editor is first responder.
    static func isEnabled(_ command: Command, window: NSWindow?, state: CommandState, focus: FocusContext) -> Bool {
        CommandAvailability.isEnabled(command, focus: isFieldEditorActive(in: window) ? .fieldEditor : focus, state: state,
                                      collidesWithTextEditing: ActiveKeyBindings.current.collidesWithTextEditing)
    }

    /// The colliding command's key (⌘⌫, ⌘[, F2, ⌘D…) must reach the text field being edited.
    static func blockedByFieldEditor(_ command: Command, window: NSWindow?) -> Bool {
        ActiveKeyBindings.current.collidesWithTextEditing.contains(command) && isFieldEditorActive(in: window)
    }

    static func isFieldEditorActive(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSText)?.isFieldEditor ?? false
    }

    private static let commandsBySelector: [String: Command] = {
        var table: [String: Command] = [:]
        for command in Command.allCases { table[command.selectorName] = command }
        return table
    }()

    /// The Command whose `selectorName` is `action`, if any.
    static func command(for action: Selector?) -> Command? {
        action.flatMap { commandsBySelector[NSStringFromSelector($0)] }
    }
}
