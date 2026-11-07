import AppKit
import Core
import MacxFS

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

    /// ⌘W's title (P2-05): "Close Tab" while `window` has other tabs, else "Close Window". AppKit closes only the
    /// selected tab either way, and closing a tab never cancels jobs (§6.7).
    static func closeTitle(for window: NSWindow?) -> String {
        (window?.tabbedWindows?.count ?? 0) > 1 ? L10n.string("Close Tab") : MainMenuTitles.title(.closeWindow)
    }

    /// Validation-time title updates for items whose title depends on the window (Close Tab / Close Window).
    static func updateTitle(of item: NSMenuItem, command: Command, window: NSWindow?) {
        let title: String
        switch command {
        case .closeWindow: title = closeTitle(for: window)
        case .togglePreviewPane: title = previewPaneTitle(visible: previewPaneVisible(in: window))
        default: return
        }
        if item.title != title { item.title = title }
    }

    /// Whether `window` (a browser window or tab) shows its own preview pane. Each window has one; the setting is
    /// only what new windows start with (QA polish).
    static func previewPaneVisible(in window: NSWindow?) -> Bool {
        (window?.windowController as? BrowserWindowController)?.splitController?.isPreviewPaneVisible ?? false
    }

    /// The checkmark of a Group By ▸ item for a folder's view state; nil for other commands (P2-10).
    static func groupByState(_ command: Command, _ state: FolderViewState) -> NSControl.StateValue? {
        guard let groupBy = groupBy(for: command) else { return nil }
        return groupBy == state.groupBy ? .on : .off
    }

    /// The checkmark of View ▸ Calculate Folder Sizes for a folder's view state; nil for other commands (P2-14).
    static func folderSizesState(_ command: Command, _ state: FolderViewState) -> NSControl.StateValue? {
        command == .toggleFolderSizes ? (state.calculateFolderSizes ? .on : .off) : nil
    }

    /// The checkmark of View › Search ▸ scope and mode items (P3-10); nil for other commands.
    static func searchState(_ command: Command, scope: SearchScope, mode: SearchMode) -> NSControl.StateValue? {
        let on: Bool
        switch command {
        case .searchScopeThisFolder: on = scope == .thisFolder
        case .searchScopeSubfolders: on = scope == .subfolders
        case .searchScopeThisMac: on = scope == .thisMac
        case .searchModeName: on = mode == .name
        case .searchModeContents: on = mode == .contents
        default: return nil
        }
        return on ? .on : .off
    }

    /// View › Show / Hide Preview Pane, from the window's own pane (`previewPaneVisible(in:)`).
    static func previewPaneTitle(visible: Bool) -> String {
        visible ? L10n.string("Hide Preview Pane") : MainMenuTitles.title(.togglePreviewPane)
    }

    static func groupBy(for command: Command) -> GroupBy? {
        switch command {
        case .groupByNone: GroupBy.none
        case .groupByKind: .kind
        case .groupByDateModified: .dateModified
        case .groupBySize: .size
        case .groupByName: .nameFirstLetter
        default: nil
        }
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
