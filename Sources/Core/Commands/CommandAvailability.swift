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
    /// Whether directories are among the selection (0 or 1, not a full count; packages and links to folders don't
    /// count); Open in New Tab needs one. The UI fills it only when validating Open in New Tab (CommandStateBuilder).
    public var selectedFolderCount: Int
    /// The Quick Look panel is open, so Space closes it even with nothing selected.
    public var quickLookVisible: Bool
    /// The command target's view mode (Group by and folder sizes are Details-only).
    public var viewMode: ViewMode
    /// Phase 3: a crawler or Spotlight search is running (Stop Search).
    public var isSearching: Bool
    /// Phase 3: the window has a search query to save (Save Search…).
    public var hasSearchQuery: Bool
    /// Phase 3: the content view shows search results (Open Containing Folder).
    public var showingResults: Bool
    /// Phase 3: the preview pane is open (Download for Preview).
    public var previewPaneVisible: Bool
    public init(selectionCount: Int = 0, singleFolderSelected: Bool = false, canPaste: Bool = false,
                canUndo: Bool = false, canRedo: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false,
                canGoUp: Bool = false, targetIsEjectable: Bool = false, targetIsPackage: Bool = false,
                folderIsReadOnly: Bool = false, selectedFolderCount: Int = 0, quickLookVisible: Bool = false,
                viewMode: ViewMode = .details, isSearching: Bool = false, hasSearchQuery: Bool = false,
                showingResults: Bool = false, previewPaneVisible: Bool = false) {
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
        self.isSearching = isSearching
        self.hasSearchQuery = hasSearchQuery
        self.showingResults = showingResults
        self.previewPaneVisible = previewPaneVisible
    }
}

public enum CommandAvailability {
    /// Encodes §5.3 enablement and the §5.4 sidebar table (e.g. Favorites: Del = removeFromFavorites,
    /// ⇧Del/⌘X/⌘D/F2 disabled; Locations: ⌘E eject, Del/⇧Del/⌘X/⌘D/F2 disabled).
    ///
    /// `.content` with no selection means "the current folder" (Properties, Open in Terminal, Reveal in Finder still
    /// work). Sidebar foci act on the focused row; `selectionCount` is 1 when that row has a usable target.
    /// `.fieldEditor` disables the commands in `collidesWithTextEditing` (pass `KeyBindings.collidesWithTextEditing`
    /// for the bindings in use) so their keys reach the text field; the standard edit actions stay enabled there
    /// because the field editor validates them itself.
    public static func isEnabled(_ command: Command, focus: FocusContext, state: CommandState,
                                 collidesWithTextEditing: Set<Command> = KeyBindings.defaults.collidesWithTextEditing) -> Bool {
        if focus == .fieldEditor {
            if collidesWithTextEditing.contains(command) { return false }
            if fieldEditorOwned.contains(command) { return true }
        }
        // Phase 3 commands (projections over a few commands; the exhaustive switch below stays default-free).
        switch command {
        case .togglePreviewPane, .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac,
             .searchModeName, .searchModeContents:
            return true
        case .openContainingFolder:
            return state.showingResults && state.selectionCount >= 1 && (focus == .searchResults || focus == .content)
        case .saveSearch: return state.hasSearchQuery
        case .showInPreview: return (focus == .content || focus == .searchResults) && state.selectionCount == 1
        case .previewZoomIn, .previewZoomOut, .previewActualSize: return focus != .fieldEditor   // the window checks the pane
        case .viewAsIcons, .viewAsColumns: return !state.showingResults   // results show only in Details (§11)
        case .stopSearch: return state.isSearching
        case .renameSavedSearch, .removeSavedSearch: return focus == .sidebarSavedSearch
        case .downloadForPreview: return state.previewPaneVisible && state.selectionCount == 1
        default: break
        }
        switch focus {
        case .searchResults:
            // No single destination folder, and Columns view can't show results.
            if searchResultsDenied.contains(command) { return false }
            return isEnabled(command, focus: .content, state: state, collidesWithTextEditing: collidesWithTextEditing)
        case .sidebarSavedSearch:
            if [.open, .openInNewWindow, .openInNewTab].contains(command) { return state.selectionCount >= 1 }
            if savedSearchDenied.contains(command) { return false }
            return isEnabled(command, focus: .sidebarFavorites, state: state, collidesWithTextEditing: collidesWithTextEditing)
        default: break
        }
        let section = Section(focus)
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
             .viewAsDetails, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .densityCompact, .densityRegular, .densityComfortable, .toggleHidden, .toggleCommandBar,
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending, .useViewAsDefault, .resetFolderView,
             .cancelOperation:
            return true
        case .eject: return section == .locations && state.targetIsEjectable
        case .removeFromFavorites: return section == .favorites    // stale favorites can be removed too
        case .quickLook: return focus == .content && (state.selectionCount > 0 || state.quickLookVisible)
        case .openInNewTab:
            switch focus {
            case .content: return state.selectedFolderCount > 0
            case .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot, .sidebarSavedSearch: return true
            case .addressBar, .fieldEditor: return false
            case .searchResults: return state.selectedFolderCount > 0   // handled above via .content
            }
        case .groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName, .toggleFolderSizes:
            return state.viewMode == .details && (focus == .content || focus.isSidebar)
        case .newTab, .applyViewToAllFolders,
             .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows:
            return true   // the tab commands are validated again by NSWindow
        case .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted:
            return isEnabled(.copyAsPath, focus: focus, state: state)
        case .togglePreviewPane, .openContainingFolder, .saveSearch, .stopSearch,
             .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac, .searchModeName, .searchModeContents,
             .renameSavedSearch, .removeSavedSearch, .downloadForPreview, .showInPreview, .viewAsIcons, .viewAsColumns,
             .previewZoomIn, .previewZoomOut, .previewActualSize:
            return false   // decided above
        }
    }

    /// Sidebar remaps (Favorites: moveToTrash → removeFromFavorites; Searches: moveToTrash → removeSavedSearch,
    /// rename → renameSavedSearch, deletePermanently → nil, so Del never deletes files from SEARCHES).
    /// `.searchResults` remaps like `.content`. Identity elsewhere. Idempotent.
    public static func effectiveCommand(_ command: Command, focus: FocusContext) -> Command? {
        switch focus {
        case .sidebarFavorites:
            return command == .moveToTrash ? .removeFromFavorites : command
        case .sidebarSavedSearch:
            switch command {
            case .moveToTrash: return .removeSavedSearch
            case .rename: return .renameSavedSearch
            case .deletePermanently: return nil
            default: return command
            }
        case .searchResults:
            return effectiveCommand(command, focus: .content)
        case .content, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot, .addressBar, .fieldEditor:
            return command
        }
    }

    /// In search results there is no single destination folder (paste, new items) and Columns view can't show them.
    static let searchResultsDenied: Set<Command> = [.paste, .moveItemHere, .newFolder, .newTextFile, .newEmptyFile, .viewAsColumns]

    /// A SEARCHES row is a query, not an item: every item-level file command is off there.
    static let savedSearchDenied: Set<Command> = [
        .cut, .copy, .paste, .moveItemHere, .duplicate, .makeAlias, .makeSymlink, .moveToTrash, .deletePermanently, .rename,
        .eject, .removeFromFavorites, .showPackageContents, .openInTerminal, .revealInFinder, .copyAsPath, .properties, .share,
        .newFolder, .newTextFile, .newEmptyFile, .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted,
    ]

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
            case .content, .searchResults: self = .content
            case .sidebarFavorites, .sidebarSavedSearch: self = .favorites
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
