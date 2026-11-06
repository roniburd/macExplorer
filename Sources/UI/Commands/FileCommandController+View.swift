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
        case .iconSizeSmall: setIconSize(.small)
        case .iconSizeMedium: setIconSize(.medium)
        case .iconSizeLarge: setIconSize(.large)
        case .densityCompact: session.view.change { $0.density = .compact }
        case .densityRegular: session.view.change { $0.density = .regular }
        case .densityComfortable: session.view.change { $0.density = .comfortable }
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

    /// Per folder (design 2026-11-05 §2): changes the current folder's view only.
    private func setViewMode(_ mode: ViewMode) {
        session?.viewMode = mode
        contentController()?.setViewMode(mode)
    }

    private func setIconSize(_ size: IconSize) {
        session?.view.change { $0.iconSize = size }
        setViewMode(.icons)
    }

    private func setSort(field: SortField? = nil, ascending: Bool? = nil) {
        guard let folder = session?.folder else { return }
        var query = folder.query
        let newField = field ?? query.sort.field
        let keepDirection = newField == query.sort.field
        query.sort = SortDescriptor(field: newField, ascending: ascending ?? (keepDirection ? query.sort.ascending : true))
        folder.setQuery(query)
        session?.view.change { $0.sort = query.sort }
    }
}
