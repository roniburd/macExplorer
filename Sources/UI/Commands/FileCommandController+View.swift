import AppKit
import Core
import MacxFS

extension FileCommandController {
    func performWindowCommand(_ command: Command, target: CommandTarget) {
        guard let window else { return }
        switch command {
        case .back: window.session.goBack()
        case .forward: window.session.goForward()
        case .up: window.session.goUp()
        case .refresh: window.session.reload()
        case .focusAddressBar: window.focus(.addressBar)
        case .focusSearch: window.toolbarController.beginSearch()
        case .cycleFocusForward: window.focus(FocusCycle.next(after: Self.focus(for: target), forward: true))
        case .cycleFocusBackward: window.focus(FocusCycle.next(after: Self.focus(for: target), forward: false))
        case .newWindow: context.windows.openWindow(at: window.session.folder.directory)
        case .closeWindow: window.window?.performClose(nil)
        case .showOperations: context.showOperationsPanel()
        default: break
        }
    }

    func performViewCommand(_ command: Command) {
        guard let session else { return }
        let settings = environment.settings
        switch command {
        case .viewAsDetails: setViewMode(.details)
        case .viewAsIcons: setViewMode(.icons)
        case .viewAsColumns: setViewMode(.columns)
        case .iconSizeSmall: setIconSize(.small)
        case .iconSizeMedium: setIconSize(.medium)
        case .iconSizeLarge: setIconSize(.large)
        case .densityCompact: session.updateViewState { $0.density = .compact }
        case .densityRegular: session.updateViewState { $0.density = .regular }
        case .densityComfortable: session.updateViewState { $0.density = .comfortable }
        case .useViewAsDefault: session.useViewAsDefault()
        case .resetFolderView: session.resetFolderView()
        case .toggleHidden:
            // Flip what this window shows; every session (this one included) follows the setting.
            let show = !session.folder.query.showHidden
            settings.showHidden = show
            var query = session.folder.query
            query.showHidden = show
            session.folder.setQuery(query)
        case .toggleCommandBar: settings.commandBarVisible.toggle()
        case .sortByName: setSort(field: .name)
        case .sortByDateModified: setSort(field: .dateModified)
        case .sortBySize: setSort(field: .size)
        case .sortByKind: setSort(field: .kind)
        case .sortByDateCreated: setSort(field: .dateCreated)
        case .sortAscending: setSort(ascending: true)
        case .sortDescending: setSort(ascending: false)
        default: break
        }
    }

    // View, icon-size and sort commands change this folder's view state only (P2-08); the session applies it.

    private func setViewMode(_ mode: ViewMode) {
        session?.updateViewState { $0.mode = mode }
    }

    private func setIconSize(_ size: IconSize) {
        session?.updateViewState { $0.iconSize = size; $0.mode = .icons }
    }

    private func setSort(field: SortField? = nil, ascending: Bool? = nil) {
        guard let session else { return }
        let results = session.results
        let current = results?.sortDescriptor ?? session.folder.query.sort
        let newField = field ?? current.field
        let keepDirection = newField == current.field
        let sort = SortDescriptor(field: newField, ascending: ascending ?? (keepDirection ? current.ascending : true))
        if let results {                 // results sort themselves; the folder's saved sort is untouched
            results.setSortDescriptor(sort)
            return
        }
        session.updateViewState { $0.sort = sort }
    }

    /// "Apply to All Folders…": asks on a sheet, then this folder's view becomes the default, every folder's own
    /// state is dropped (Finder's older views and the built-in Applications rule stop applying too) and every open
    /// window and tab re-reads its state.
    func applyViewToAllFolders() {
        guard let session else { return }
        let state = session.viewState
        let environment = self.environment, windows = context.windows
        Task {
            guard await self.prompts.confirm(.applyViewToAllFolders, window: self.window?.window) else { return }
            FolderViewCoordinator(store: environment.folderViews, settings: environment.settings,
                                  lanes: environment.lanes, volumes: environment.volumes).applyToAll(state)
            for controller in windows.windows { controller.session.reloadViewState() }
        }
    }
}
