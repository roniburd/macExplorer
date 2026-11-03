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
}

/// Runs commands. P1-26 installs the interim `ShellCommandHandler`; P1-35's FileCommandController replaces it.
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = MenuValidation.command(for: menuItem.action) else { return false }
        // While a field editor (rename, address bar) is first responder, the colliding keys belong to it.
        if MenuValidation.blockedByFieldEditor(command, window: viewIfLoaded?.window) { return false }
        guard let handler, let target = commandTarget else { return false }
        return handler.canPerform(command, target: target)
    }
}
