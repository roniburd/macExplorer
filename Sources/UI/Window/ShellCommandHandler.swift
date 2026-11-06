import AppKit
import Core
import MacxFS

/// Interim CommandHandler (P1-26): navigation, window, view-mode and undo commands, so the shell is usable before
/// the file commands exist; P1-28 adds the sidebar row commands (Open, Open in New Window, Eject, Remove from
/// Favorites), P1-29 the Tab focus cycle and Show Command Bar. P1-35's FileCommandController replaces it on every pane.
@MainActor
final class ShellCommandHandler: CommandHandler {
    private let context: UIContext
    private weak var window: BrowserWindowController?

    init(context: UIContext, window: BrowserWindowController) {
        self.context = context
        self.window = window
    }

    static let handled: Set<Command> = [
        .back, .forward, .up, .refresh, .newWindow, .closeWindow, .focusAddressBar, .focusSearch,
        .viewAsDetails, .viewAsIcons, .undo, .redo,
        .open, .openInNewWindow, .eject, .removeFromFavorites,
        .cycleFocusForward, .cycleFocusBackward, .toggleCommandBar,
    ]

    /// Open and Open in New Window only for sidebar rows here (content items open in P1-35).
    private static let sidebarOnly: Set<Command> = [.open, .openInNewWindow, .eject, .removeFromFavorites]

    func canPerform(_ command: Command, target: CommandTarget) -> Bool {
        guard Self.handled.contains(command), let session = window?.session else { return false }
        let undo = context.environment.undo
        var state = CommandState(canUndo: undo.canUndo, canRedo: undo.canRedo,
                                 canGoBack: session.history.canGoBack, canGoForward: session.history.canGoForward,
                                 canGoUp: session.folder.directory.standardizedFileURL.path != "/")
        let focus: FocusContext
        switch target {
        case .contentSelection, .currentFolder:
            if Self.sidebarOnly.contains(command) { return false }
            focus = .content
        case .favorite(let favorite):
            focus = .sidebarFavorites
            state.selectionCount = favorite.url == nil ? 0 : 1
            state.singleFolderSelected = favorite.url != nil
        case .volume(let volume):
            focus = .sidebarLocations
            state.selectionCount = 1
            state.singleFolderSelected = true
            state.targetIsEjectable = volume.isEjectable
        case .location:
            focus = .sidebarLocations
            state.selectionCount = 1
            state.singleFolderSelected = true
        case .folder:
            focus = .sidebarFolders
            state.selectionCount = 1
            state.singleFolderSelected = true
        }
        return CommandAvailability.isEnabled(command, focus: focus, state: state)
    }

    /// The focus a command target comes from (Tab cycle origin).
    private static func focus(of target: CommandTarget) -> FocusContext {
        switch target {
        case .contentSelection, .currentFolder: .content
        case .favorite: .sidebarFavorites
        case .volume, .location: .sidebarLocations
        case .folder: .sidebarFolders
        }
    }

    private static func url(of target: CommandTarget) -> URL? {
        switch target {
        case .favorite(let favorite): favorite.url
        case .volume(let volume): volume.mountPoint
        case .folder(let url), .location(let url): url
        case .contentSelection, .currentFolder: nil
        }
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
        case .focusSearch: window.toolbarController.beginSearch()
        case .cycleFocusForward: window.focus(FocusCycle.next(after: Self.focus(of: target), forward: true))
        case .cycleFocusBackward: window.focus(FocusCycle.next(after: Self.focus(of: target), forward: false))
        case .toggleCommandBar: context.environment.settings.commandBarVisible.toggle()
        case .viewAsDetails: setViewMode(.details)
        case .viewAsIcons: setViewMode(.icons)
        case .undo: UndoTarget.manager(window: window.window, fallback: context.environment.undo.undoManager).undo()
        case .redo: UndoTarget.manager(window: window.window, fallback: context.environment.undo.undoManager).redo()
        case .open: if let url = Self.url(of: target) { window.session.navigate(to: url) }
        case .openInNewWindow: if let url = Self.url(of: target) { context.windows.openWindow(at: url) }
        case .eject:
            guard case .volume(let volume) = target else { return }
            let flow = EjectFlow(environment: context.environment, prompts: context.ejectPrompts)
            let host = window.window
            Task { await flow.eject(volume, window: host) }
        case .removeFromFavorites:
            guard case .favorite(let favorite) = target else { return }
            SidebarFavoritesModel.remove(id: favorite.favorite.id, from: context.environment.settings)
        default: break
        }
    }

    private func setViewMode(_ mode: ViewMode) {
        window?.session.viewMode = mode
    }
}
