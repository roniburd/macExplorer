import AppKit
import Core
import MacxFS

/// What a command acts on (§5.3, §5.4).
enum CommandTarget {
    case contentSelection(FolderModel)                   // content view focus
    case currentFolder(FolderModel)                      // empty-space menu, ⌘V
    case folder(URL)                                     // item-context Paste into one folder, tree node
    case favorite(ResolvedFavorite)
    case volume(VolumeInfo)
    case location(URL)                                   // a LOCATIONS row that is a folder, not a volume (iCloud Drive)
}

/// Runs commands. BrowserWindowController installs one FileCommandController (P1-35) on the content and sidebar panes.
@MainActor protocol CommandHandler: AnyObject {
    func canPerform(_ command: Command, target: CommandTarget) -> Bool
    func perform(_ command: Command, target: CommandTarget, sender: Any?)
}

/// Base for views that take file commands (content, sidebar). One @objc method per Command.selectorName
/// (CommandActions+Selectors.swift, e.g. @objc func macx_moveToTrash(_ sender: Any?)), each calling
/// handler.perform(_, target: commandTarget, ...). Also implements validateMenuItem via MenuValidation.
@MainActor class CommandHandlingViewController: NSViewController, NSMenuItemValidation {
    /// Strong: the handler holds its window weakly, so there is no cycle.
    var handler: CommandHandler?

    /// Overridden by subclasses.
    var focusContext: FocusContext { .content }

    /// Overridden by subclasses; nil = nothing to act on (actions do nothing, menu items are disabled).
    var commandTarget: CommandTarget? { nil }

    /// Every @objc command action ends here.
    func run(_ command: Command, sender: Any?) {
        guard let handler, let target = commandTarget else { return }
        handler.perform(command, target: target, sender: sender)
    }

    /// While a field editor (inline rename, address bar) is first responder, ⌘Z/⇧⌘Z belong to its typing (§6.6):
    /// the view controller steps out of the chain for undo:/redo:, so NSWindow's undo: runs with the per-edit
    /// manager from windowWillReturnUndoManager instead of the app-wide file-operation stack (QA round 1).
    override nonisolated func responds(to aSelector: Selector!) -> Bool {
        if let aSelector, Thread.isMainThread, ["undo:", "redo:"].contains(NSStringFromSelector(aSelector)),
           MainActor.assumeIsolated({ MenuValidation.isFieldEditorActive(in: viewIfLoaded?.window) }) { return false }
        return super.responds(to: aSelector)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = MenuValidation.command(for: menuItem.action) else { return false }
        // While a field editor (rename, address bar) is first responder, the colliding keys belong to it.
        if MenuValidation.blockedByFieldEditor(command, window: viewIfLoaded?.window) { return false }
        guard let handler, let target = commandTarget else { return false }
        return handler.canPerform(command, target: target)
    }
}

/// The manager ⌘Z acts on from a command handler: the field editor's own while one is first responder (its
/// typing, §6.6), else the app-wide file-operation stack.
@MainActor enum UndoTarget {
    static func manager(window: NSWindow?, fallback: UndoManager) -> UndoManager {
        guard let window, MenuValidation.isFieldEditorActive(in: window), let manager = window.firstResponder?.undoManager else {
            return fallback
        }
        return manager
    }
}
