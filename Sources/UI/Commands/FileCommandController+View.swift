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
        case .showOperations: NSSound.beep()   // P1-38 shows the Operations panel
        default: break
        }
    }

    func performViewCommand(_ command: Command) {
        guard let session else { return }
        let settings = environment.settings
        switch command {
        case .viewAsDetails: setViewMode(.details)
        case .viewAsIcons: setViewMode(.icons)
        case .iconSizeSmall: settings.iconSize = .small; setViewMode(.icons)
        case .iconSizeMedium: settings.iconSize = .medium; setViewMode(.icons)
        case .iconSizeLarge: settings.iconSize = .large; setViewMode(.icons)
        case .densityCompact: settings.density = .compact
        case .densityRegular: settings.density = .regular
        case .densityComfortable: settings.density = .comfortable
        case .toggleHidden:
            settings.showHidden.toggle()
            var query = session.folder.query
            query.showHidden = settings.showHidden
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

    private func setViewMode(_ mode: ViewMode) {
        session?.viewMode = mode
        environment.settings.viewMode = mode
        contentController()?.setViewMode(mode)
    }

    private func setSort(field: SortField? = nil, ascending: Bool? = nil) {
        guard let folder = session?.folder else { return }
        var query = folder.query
        let newField = field ?? query.sort.field
        let keepDirection = newField == query.sort.field
        query.sort = SortDescriptor(field: newField, ascending: ascending ?? (keepDirection ? query.sort.ascending : true))
        folder.setQuery(query)
        environment.settings.sort = query.sort
    }
}
