import AppKit
import Core
import MacxFS

/// Retains the (command, target) of a context-menu item and validates it through the handler. NSMenuItem.target is
/// weak, so the item's representedObject holds the box.
@MainActor
final class MenuActionBox: NSObject, NSMenuItemValidation {
    let command: Command
    let target: CommandTarget
    weak var handler: (any CommandHandler)?

    init(command: Command, target: CommandTarget, handler: any CommandHandler) {
        self.command = command
        self.target = target
        self.handler = handler
    }

    @objc func run(_ sender: Any?) { handler?.perform(command, target: target, sender: sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { handler?.canPerform(command, target: target) ?? false }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private var handler: (@MainActor () -> Void)?

    convenience init(title: String, handler: @escaping @MainActor () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    @objc private func fire() { handler?() }
}

@MainActor
enum ContextMenuTitles {
    static func title(_ command: Command) -> String {
        switch command {
        case .open: L10n.string("Open")
        case .openInNewWindow: L10n.string("Open in New Window")
        case .openInNewTab: L10n.string("Open in New Tab")
        case .showPackageContents: L10n.string("Show Package Contents")
        case .quickLook: L10n.string("Quick Look")
        case .showInPreview: L10n.string("Preview")
        case .cut: L10n.string("Cut")
        case .copy: L10n.string("Copy")
        case .paste: L10n.string("Paste")
        case .copyAsPath: L10n.string("Copy as Path")
        case .duplicate: L10n.string("Duplicate")
        case .makeAlias: L10n.string("Make Alias")
        case .makeSymlink: L10n.string("Create Symbolic Link")
        case .rename: L10n.string("Rename")
        case .moveToTrash: L10n.string("Move to Trash")
        case .deletePermanently: L10n.string("Delete Permanently…")
        case .revealInFinder: L10n.string("Reveal in Finder")
        case .openInTerminal: L10n.string("Open in Terminal")
        case .properties: L10n.string("Properties")
        case .refresh: L10n.string("Refresh")
        case .newFolder: L10n.string("Folder")
        case .newTextFile: L10n.string("Text File")
        case .newEmptyFile: L10n.string("Empty File")
        case .viewAsDetails: L10n.string("Details")
        case .viewAsIcons: L10n.string("Icons")
        case .iconSizeSmall: L10n.string("Small Icons")
        case .iconSizeMedium: L10n.string("Medium Icons")
        case .iconSizeLarge: L10n.string("Large Icons")
        case .densityCompact: L10n.string("Compact")
        case .densityRegular: L10n.string("Regular")
        case .densityComfortable: L10n.string("Comfortable")
        case .toggleHidden: L10n.string("Hidden Items")
        case .toggleCommandBar: L10n.string("Command Bar")
        case .sortByName: L10n.string("Name")
        case .sortByDateModified: L10n.string("Date Modified")
        case .sortBySize: L10n.string("Size")
        case .sortByKind: L10n.string("Kind")
        case .sortByDateCreated: L10n.string("Date Created")
        case .sortAscending: L10n.string("Ascending")
        case .sortDescending: L10n.string("Descending")
        case .groupByNone: L10n.string("None")
        case .groupByKind: L10n.string("Kind")
        case .groupByDateModified: L10n.string("Date Modified")
        case .groupBySize: L10n.string("Size")
        case .groupByName: L10n.string("Name")
        case .useViewAsDefault: L10n.string("Use as Default for All Folders")
        case .resetFolderView: L10n.string("Reset View for This Folder")
        case .openContainingFolder: L10n.string("Open Containing Folder")
        case .saveSearch: L10n.string("Save Search…")
        case .stopSearch: L10n.string("Stop Search")
        case .extractHere: L10n.string("Extract Here")
        default: command.rawValue
        }
    }
}

/// Item and empty-space context menus (§5.6). Built from in-memory state only, so building never blocks.
@MainActor
final class ContextMenuBuilder {
    private let context: UIContext

    init(context: UIContext) { self.context = context }

    /// Right-click on an unselected row selects just it; inside the selection keeps it; nil = empty space.
    static func contextRows(clickedRow: Int?, selectedRows: IndexSet) -> (select: SelectionCommand?, rows: IndexSet?) {
        guard let row = clickedRow else { return (nil, nil) }
        if selectedRows.contains(row) { return (nil, selectedRows) }
        return (.set(IndexSet(integer: row), cursor: row), IndexSet(integer: row))
    }

    func itemMenu(for rows: IndexSet, in folder: FolderModel, handler: CommandHandler) -> NSMenu {
        let menu = NSMenu()
        let target = CommandTarget.contentSelection(folder)
        let valid = rows.filteredIndexSet { $0 < folder.rowCount }
        let kinds = valid.map { folder.entry(atRow: $0).kind }
        if previewable(valid, entry: folder.entry(atRow:)) {
            add(.showInPreview, target, handler, to: menu)
            menu.addItem(.separator())
        }
        add(.open, target, handler, to: menu)
        if let openWith = openWithItem(rows: valid, folder: folder, handler: handler) { menu.addItem(openWith) }
        if valid.count == 1, let row = valid.first, kinds.first != .directory,
           ArchiveFormat.detect(byName: folder.url(atRow: row).lastPathComponent) != nil {
            add(.extractHere, target, handler, to: menu)                 // P4-10: a single archive, under Open With
        }
        add(.quickLook, target, handler, to: menu)
        if kinds.contains(.directory) {
            add(.openInNewWindow, target, handler, to: menu)
            add(.openInNewTab, target, handler, to: menu)
        }
        if kinds.contains(.package) { add(.showPackageContents, target, handler, to: menu) }
        menu.addItem(.separator())
        add(.cut, target, handler, to: menu)
        add(.copy, target, handler, to: menu)
        if valid.count == 1, let row = valid.first, folder.entry(atRow: row).kind == .directory {
            add(.paste, .folder(folder.url(atRow: row)), handler, to: menu)   // only for one right-clicked folder (§5.6)
        }
        add(.copyAsPath, target, handler, to: menu)
        menu.addItem(CopyPathMenu.submenuItem(target: target, handler: handler))
        menu.addItem(.separator())
        for command in [Command.duplicate, .makeAlias, .makeSymlink] { add(command, target, handler, to: menu) }
        menu.addItem(compressItem(names: valid.map { folder.url(atRow: $0).lastPathComponent }, target: target, handler: handler))
        menu.addItem(.separator())
        for command in [Command.rename, .moveToTrash, .deletePermanently] { add(command, target, handler, to: menu) }
        menu.addItem(.separator())
        menu.addItem(newSubmenu(folder: folder, handler: handler))
        add(.revealInFinder, target, handler, to: menu)
        add(.openInTerminal, target, handler, to: menu)
        menu.addItem(.separator())
        let share = NSSharingServicePicker(items: valid.map { folder.url(atRow: $0) }).standardShareMenuItem
        share.identifier = NSUserInterfaceItemIdentifier("macx.menu.share")
        menu.addItem(share)
        menu.addItem(.separator())
        add(.properties, target, handler, to: menu)
        return menu   // AppKit appends Services ▸ for the list views' NSServicesMenuRequestor when it pops the menu
    }

    /// A right-click on search results (P3-10): Open, Open Containing Folder, Open in New Tab, Open With ▸, Quick Look,
    /// —, Cut, Copy, Copy as Path (+ Copy Path As ▸), —, Rename, Move to Trash, —, Get Info. No Paste (no single
    /// destination folder).
    func itemMenu(for rows: IndexSet, in results: SearchResultsModel, handler: CommandHandler) -> NSMenu {
        let menu = NSMenu()
        let target = CommandTarget.resultsSelection(results)
        let valid = rows.filteredIndexSet { $0 < results.rowCount }
        if previewable(valid, entry: results.entry(atRow:)) {
            add(.showInPreview, target, handler, to: menu)
            menu.addItem(.separator())
        }
        add(.open, target, handler, to: menu)
        add(.openContainingFolder, target, handler, to: menu)
        if valid.contains(where: { MiddleClickRouter.folderTarget(row: $0, in: results) != nil }) {
            add(.openInNewTab, target, handler, to: menu)
        }
        if let openWith = openWithItem(rows: valid, folder: results, handler: handler) { menu.addItem(openWith) }
        add(.quickLook, target, handler, to: menu)
        menu.addItem(.separator())
        add(.cut, target, handler, to: menu)
        add(.copy, target, handler, to: menu)
        add(.copyAsPath, target, handler, to: menu)
        menu.addItem(CopyPathMenu.submenuItem(target: target, handler: handler))
        menu.addItem(.separator())
        add(.rename, target, handler, to: menu)
        add(.moveToTrash, target, handler, to: menu)
        menu.addItem(.separator())
        add(.properties, target, handler, to: menu).title = L10n.string("Get Info")
        return menu
    }

    /// Empty space in search results (P3-10): Sort By ▸, View ▸, —, Search Again, Save Search…. No Paste, no New.
    func emptySpaceMenu(for results: SearchResultsModel, viewState: FolderViewState? = nil, handler: CommandHandler) -> NSMenu {
        let view = viewState ?? context.environment.settings.defaultFolderViewState()
        let menu = NSMenu()
        let target = CommandTarget.resultsSelection(results)
        let sortItem = NSMenuItem(title: L10n.string("Sort By"), action: nil, keyEquivalent: "")
        sortItem.identifier = NSUserInterfaceItemIdentifier("macx.menu.sortBy")
        let sortMenu = NSMenu(title: sortItem.title)
        let sort = results.sortDescriptor
        for command in [Command.sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending] {
            let on: Bool = switch command {
            case .sortByName: sort.field == .name
            case .sortByDateModified: sort.field == .dateModified
            case .sortBySize: sort.field == .size
            case .sortByKind: sort.field == .kind
            case .sortByDateCreated: sort.field == .dateCreated
            case .sortAscending: sort.ascending
            default: !sort.ascending
            }
            add(command, target, handler, to: sortMenu).state = on ? .on : .off
        }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        let viewItem = NSMenuItem(title: L10n.string("View"), action: nil, keyEquivalent: "")
        viewItem.identifier = NSUserInterfaceItemIdentifier("macx.menu.view")
        let viewMenu = NSMenu(title: viewItem.title)
        for command in [Command.viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge, .toggleHidden] {
            let on: Bool = switch command {
            case .viewAsDetails: true                   // results show only in Details (§11)
            case .viewAsIcons: false
            case .iconSizeSmall: view.iconSize == .small
            case .iconSizeMedium: view.iconSize == .medium
            case .iconSizeLarge: view.iconSize == .large
            default: context.environment.settings.showHidden
            }
            add(command, target, handler, to: viewMenu).state = on ? .on : .off
        }
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        menu.addItem(.separator())
        add(.refresh, target, handler, to: menu).title = L10n.string("Search Again")
        add(.saveSearch, target, handler, to: menu)
        return menu
    }

    /// `viewState` is the folder's view state (P2-08), for the View ▸ checkmarks; nil uses the defaults.
    func emptySpaceMenu(for folder: FolderModel, viewState: FolderViewState? = nil, handler: CommandHandler) -> NSMenu {
        let view = viewState ?? context.environment.settings.defaultFolderViewState()
        let menu = NSMenu()
        let target = CommandTarget.currentFolder(folder)
        add(.paste, target, handler, to: menu)
        menu.addItem(newSubmenu(folder: folder, handler: handler))
        menu.addItem(submenu(L10n.string("View"), id: "view", [.viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium,
                                                              .iconSizeLarge, .densityCompact, .densityRegular, .densityComfortable,
                                                              .toggleHidden, .toggleCommandBar, .useViewAsDefault, .resetFolderView],
                             target, handler, folder, view))
        menu.addItem(submenu(L10n.string("Sort By"), id: "sortBy", [.sortByName, .sortByDateModified, .sortBySize, .sortByKind,
                                                                   .sortByDateCreated, .sortAscending, .sortDescending], target, handler, folder, view))
        menu.addItem(submenu(L10n.string("Group By"), id: "groupBy", [.groupByNone, .groupByKind, .groupByDateModified, .groupBySize,
                                                                     .groupByName], target, handler, folder, view))
        add(.refresh, target, handler, to: menu)
        menu.addItem(.separator())
        add(.openInTerminal, target, handler, to: menu)
        menu.addItem(.separator())
        add(.properties, target, handler, to: menu)
        return menu
    }

    // MARK: private

    /// Preview heads the menu for one file of a type the preview pane shows well (text, Markdown, Word, PDF,
    /// images, media, Office/iWork documents). From the in-memory entry only: nothing is read.
    private func previewable(_ rows: IndexSet, entry: (Int) -> Entry) -> Bool {
        guard rows.count == 1, let row = rows.first else { return false }
        let e = entry(row)
        guard e.kind == .file || e.kind == .alias || e.kind == .symlink else { return false }
        return PreviewPlanner.isPreviewable(context.environment.types.type(at: e.typeIndex))
    }

    @discardableResult
    private func add(_ command: Command, _ target: CommandTarget, _ handler: CommandHandler, to menu: NSMenu) -> NSMenuItem {
        let box = MenuActionBox(command: command, target: target, handler: handler)
        let item = NSMenuItem(title: ContextMenuTitles.title(command), action: #selector(MenuActionBox.run(_:)), keyEquivalent: "")
        item.target = box
        item.representedObject = box
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.\(command.rawValue)")
        menu.addItem(item)
        return item
    }

    private func newSubmenu(folder: FolderModel, handler: CommandHandler) -> NSMenuItem {
        submenu(L10n.string("New"), id: "new", [.newFolder, .newTextFile, .newEmptyFile], .currentFolder(folder), handler, folder)
    }

    private func submenu(_ title: String, id: String, _ commands: [Command], _ target: CommandTarget,
                         _ handler: CommandHandler, _ folder: FolderModel, _ view: FolderViewState? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.\(id)")
        let submenu = NSMenu(title: title)
        let view = view ?? context.environment.settings.defaultFolderViewState()
        for command in commands { add(command, target, handler, to: submenu).state = state(command, folder: folder, view: view) }
        item.submenu = submenu
        return item
    }

    private func state(_ command: Command, folder: FolderModel, view: FolderViewState) -> NSControl.StateValue {
        let settings = context.environment.settings
        let sort = folder.query.sort
        let on: Bool = switch command {
        case .viewAsDetails: view.mode == .details
        case .viewAsIcons: view.mode == .icons
        case .iconSizeSmall: view.iconSize == .small
        case .iconSizeMedium: view.iconSize == .medium
        case .iconSizeLarge: view.iconSize == .large
        case .densityCompact: view.density == .compact
        case .densityRegular: view.density == .regular
        case .densityComfortable: view.density == .comfortable
        case .toggleHidden: folder.query.showHidden
        case .toggleCommandBar: settings.commandBarVisible
        case .sortByName: sort.field == .name
        case .sortByDateModified: sort.field == .dateModified
        case .sortBySize: sort.field == .size
        case .sortByKind: sort.field == .kind
        case .sortByDateCreated: sort.field == .dateCreated
        case .sortAscending: sort.ascending
        case .sortDescending: !sort.ascending
        case .groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName:
            MenuValidation.groupByState(command, view) == .on
        default: false
        }
        return on ? .on : .off
    }

    /// Compress ▸ (P4-09): "Compress “name” to .zip" for one item, "Compress 3 Items to .zip" for several, and the same
    /// for .aar.
    private func compressItem(names: [String], target: CommandTarget, handler: CommandHandler) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string("Compress"), action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.compress")
        let submenu = NSMenu(title: item.title)
        for command in [Command.compressZip, .compressAppleArchive] {
            add(command, target, handler, to: submenu).title = Self.compressTitle(command, names: names)
        }
        item.submenu = submenu
        return item
    }

    static func compressTitle(_ command: Command, names: [String]) -> String {
        let ext = command == .compressAppleArchive ? ".aar" : ".zip"
        if names.count == 1, let name = names.first {
            return String(format: L10n.string("Compress “%@” to %@"), name, ext)
        }
        return String(format: L10n.string("Compress %lld Items to %@"), Int64(names.count), ext)
    }

    private func openWithItem(rows: IndexSet, folder: any RowSource, handler: CommandHandler) -> NSMenuItem? {
        guard let commands = handler as? FileCommandController else { return nil }
        let fileRows = rows.filter { folder.entry(atRow: $0).kind != .directory }
        guard let first = fileRows.first else { return nil }
        let files = fileRows.map { folder.url(atRow: $0) }
        let openWith = OpenWithMenu(files: files, typeIndex: folder.entry(atRow: first).typeIndex,
                                    cache: context.environment.launchServices, icons: context.icons,
                                    openWith: { [weak commands] app in commands?.openWith(files, app: app) },
                                    other: { [weak commands] in commands?.openWithOther(files) },
                                    chooseDefault: { [weak commands] in commands?.chooseDefaultApp(for: files[0]) })
        let item = NSMenuItem(title: L10n.string("Open With"), action: nil, keyEquivalent: "")
        item.submenu = openWith.menu
        item.representedObject = openWith
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.openWith")
        return item
    }
}
