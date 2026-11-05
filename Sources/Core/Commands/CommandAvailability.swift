import Foundation

/// In-memory inputs to command enablement (§5.3), built by the UI for the current command target.
public struct CommandState: Sendable, Equatable {
    public var selectionCount: Int
    public var singleFolderSelected: Bool
    public var canPaste: Bool
    public var canUndo: Bool
    public var canRedo: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var canGoUp: Bool
    public var targetIsEjectable: Bool
    public var targetIsPackage: Bool
    public var folderIsReadOnly: Bool
    /// Folders (directories or packages opened as folders) among the selection; Open in New Tab needs one.
    public var selectedFolderCount: Int
    /// The Quick Look panel is open, so Space closes it even with nothing selected.
    public var quickLookVisible: Bool
    /// The command target's view mode (Group by and folder sizes are Details-only).
    public var viewMode: ViewMode
    public init(selectionCount: Int = 0, singleFolderSelected: Bool = false, canPaste: Bool = false,
                canUndo: Bool = false, canRedo: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false,
                canGoUp: Bool = false, targetIsEjectable: Bool = false, targetIsPackage: Bool = false,
                folderIsReadOnly: Bool = false, selectedFolderCount: Int = 0, quickLookVisible: Bool = false,
                viewMode: ViewMode = .details) {
        self.selectionCount = selectionCount
        self.singleFolderSelected = singleFolderSelected
        self.canPaste = canPaste
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.canGoUp = canGoUp
        self.targetIsEjectable = targetIsEjectable
        self.targetIsPackage = targetIsPackage
        self.folderIsReadOnly = folderIsReadOnly
        self.selectedFolderCount = selectedFolderCount
        self.quickLookVisible = quickLookVisible
        self.viewMode = viewMode
    }
}

public enum CommandAvailability {
    /// Encodes §5.3 enablement and the §5.4 sidebar table (e.g. Favorites: Del = removeFromFavorites,
    /// ⇧Del/⌘X/⌘D/F2 disabled; Locations: ⌘E eject, Del/⇧Del/⌘X/⌘D/F2 disabled).
    ///
    /// `.content` with no selection means "the current folder" (Properties, Open in Terminal, Reveal in Finder still
    /// work). Sidebar foci act on the focused row; `selectionCount` is 1 when that row has a usable target.
    /// `.fieldEditor` disables the commands in `KeyMap.collidesWithTextEditing` so their keys reach the text field;
    /// the standard edit actions stay enabled there because the field editor validates them itself.
    public static func isEnabled(_ command: Command, focus: FocusContext, state: CommandState) -> Bool {
        let section = Section(focus)
        if section == .fieldEditor {
            if KeyMap.collidesWithTextEditing.contains(command) { return false }
            if fieldEditorOwned.contains(command) { return true }
        }
        if section.isSidebarPointer, sidebarPointerDisabled.contains(command) { return false }

        let selected = state.selectionCount > 0
        let writable = !state.folderIsReadOnly
        let actsOnFolderWhenEmpty = section.actsOnCurrentFolder || selected
        switch command {
        case .open: return selected
        case .openInNewWindow: return state.singleFolderSelected
        case .showPackageContents: return state.targetIsPackage
        case .openInTerminal, .revealInFinder, .properties: return actsOnFolderWhenEmpty
        case .cut: return selected && writable
        case .copy, .copyAsPath, .share: return selected
        case .paste, .moveItemHere: return state.canPaste && writable
        case .selectAll, .invertSelection: return section.hasItemSelection
        case .selectNone: return section.hasItemSelection && selected
        case .undo: return state.canUndo
        case .redo: return state.canRedo
        case .rename: return state.selectionCount == 1 && writable
        case .moveToTrash, .deletePermanently, .duplicate, .makeAlias, .makeSymlink: return selected && writable
        case .newFolder, .newTextFile, .newEmptyFile: return writable
        case .back: return state.canGoBack
        case .forward: return state.canGoForward
        case .up: return state.canGoUp
        case .focusAddressBar, .focusSearch, .cycleFocusForward, .cycleFocusBackward, .refresh,
             .newWindow, .closeWindow, .showOperations,
             .viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .densityCompact, .densityRegular, .densityComfortable, .toggleHidden, .toggleCommandBar,
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending,
             .cancelOperation:
            return true
        case .eject: return section == .locations && state.targetIsEjectable
        case .removeFromFavorites: return section == .favorites    // stale favorites can be removed too
        case .quickLook: return focus == .content && (state.selectionCount > 0 || state.quickLookVisible)
        case .openInNewTab:
            switch focus {
            case .content: return state.selectedFolderCount > 0
            case .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot: return true
            case .addressBar, .fieldEditor: return false
            }
        case .groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName, .toggleFolderSizes:
            return state.viewMode == .details && (focus == .content || focus.isSidebar)
        case .newTab, .viewAsColumns, .applyViewToAllFolders,
             .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows:
            return true   // the tab commands are validated again by NSWindow
        case .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted:
            return isEnabled(.copyAsPath, focus: focus, state: state)
        }
    }

    /// Sidebar remaps (Favorites: moveToTrash → removeFromFavorites). Identity elsewhere. Idempotent.
    public static func effectiveCommand(_ command: Command, focus: FocusContext) -> Command? {
        if focus == .sidebarFavorites, command == .moveToTrash { return .removeFromFavorites }
        return command
    }

    /// Favorites and Locations rows point at a folder or volume; they are not items to edit (§5.4).
    /// Favorites never trash their target: Del there is remapped to removeFromFavorites by `effectiveCommand`.
    private static let sidebarPointerDisabled: Set<Command> = [
        .moveToTrash, .deletePermanently, .cut, .duplicate, .rename, .makeAlias, .makeSymlink,
        .newFolder, .newTextFile, .newEmptyFile, .selectAll, .selectNone, .invertSelection, .showPackageContents,
    ]

    /// Standard edit actions the field editor validates itself.
    private static let fieldEditorOwned: Set<Command> = [.cut, .copy, .paste, .selectAll, .undo, .redo, .cancelOperation]

    private enum Section: Equatable {
        case content, favorites, locations, folders, addressBar, fieldEditor

        init(_ focus: FocusContext) {
            switch focus {
            case .content: self = .content
            case .sidebarFavorites: self = .favorites
            case .sidebarLocations, .sidebarVolumeRoot: self = .locations
            case .sidebarFolders: self = .folders
            case .addressBar: self = .addressBar
            case .fieldEditor: self = .fieldEditor
            }
        }

        var isSidebarPointer: Bool { self == .favorites || self == .locations }
        /// No selection here means the current folder rather than nothing.
        var actsOnCurrentFolder: Bool { self != .favorites && self != .locations && self != .folders }
        var hasItemSelection: Bool { self == .content || self == .addressBar || self == .fieldEditor }
    }
}
