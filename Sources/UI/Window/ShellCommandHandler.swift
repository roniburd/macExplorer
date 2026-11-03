import AppKit
import Core
import MacxFS

/// Interim CommandHandler (P1-26): navigation, window, view-mode and undo commands, so the shell is usable before
/// the file commands exist. P1-35's FileCommandController replaces it on every pane.
@MainActor
final class ShellCommandHandler: CommandHandler {
    private let context: UIContext
    private weak var window: BrowserWindowController?

    init(context: UIContext, window: BrowserWindowController) {
        self.context = context
        self.window = window
    }

    static let handled: Set<Command> = [
        .back, .forward, .up, .refresh, .newWindow, .closeWindow, .focusAddressBar,
        .viewAsDetails, .viewAsIcons, .undo, .redo,
    ]

    func canPerform(_ command: Command, target: CommandTarget) -> Bool {
        guard Self.handled.contains(command), let session = window?.session else { return false }
        let undo = context.environment.undo
        let state = CommandState(canUndo: undo.canUndo, canRedo: undo.canRedo,
                                 canGoBack: session.history.canGoBack, canGoForward: session.history.canGoForward,
                                 canGoUp: session.folder.directory.standardizedFileURL.path != "/")
        return CommandAvailability.isEnabled(command, focus: .content, state: state)
    }

    func perform(_ command: Command, target: CommandTarget, sender: Any?) {
        guard let window, canPerform(command, target: target) else {
            NSSound.beep()
            return
        }
        switch command {
        case .back: window.session.goBack()
        case .forward: window.session.goForward()
        case .up: window.session.goUp()
        case .refresh: window.session.reload()
        case .newWindow: context.windows.openWindow(at: window.session.folder.directory)
        case .closeWindow: window.window?.performClose(sender)
        case .focusAddressBar: window.focus(.addressBar)
        case .viewAsDetails: setViewMode(.details)
        case .viewAsIcons: setViewMode(.icons)
        case .undo: context.environment.undo.undoManager.undo()
        case .redo: context.environment.undo.undoManager.redo()
        default: break
        }
    }

    private func setViewMode(_ mode: ViewMode) {
        window?.session.viewMode = mode
        context.environment.settings.viewMode = mode
    }
}
