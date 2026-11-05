import Foundation

/// Every user command (menus, command bar, context menus, keys). Its `selectorName` is the action the UI sends
/// through the responder chain (§5.6 key routing).
public enum Command: String, Sendable, Codable, CaseIterable {
    // open
    case open, openInNewWindow, showPackageContents, openInTerminal, revealInFinder
    // edit / clipboard (responder-chain standard selectors)
    case cut, copy, paste, moveItemHere, selectAll, undo, redo
    // selection
    case selectNone, invertSelection
    // file
    case rename, moveToTrash, deletePermanently, duplicate, makeAlias, makeSymlink
    case newFolder, newTextFile, newEmptyFile, copyAsPath, properties, share
    // navigation / focus
    case back, forward, up, focusAddressBar, focusSearch, cycleFocusForward, cycleFocusBackward, refresh
    // window / app
    case newWindow, closeWindow, showOperations
    // view
    case viewAsDetails, viewAsIcons, iconSizeSmall, iconSizeMedium, iconSizeLarge
    case densityCompact, densityRegular, densityComfortable, toggleHidden, toggleCommandBar
    case sortByName, sortByDateModified, sortBySize, sortByKind, sortByDateCreated, sortAscending, sortDescending
    // sidebar / volumes
    case eject, removeFromFavorites
    // escape: clear cut marks / cancel inline state
    case cancelOperation
    // Phase 2: tabs (NSWindow's own actions, see `windowTabCommands`) and open in new tab
    case newTab, nextTab, previousTab, showTabBar, showAllTabs, moveTabToNewWindow, mergeAllWindows, openInNewTab
    // Phase 2: Quick Look, Columns view, Group by, folder sizes, per-folder view state
    case quickLook, viewAsColumns, groupByNone, groupByKind, groupByDateModified, groupBySize, groupByName
    case toggleFolderSizes, applyViewToAllFolders
    // Phase 2: copy-path variants
    case copyPathTilde, copyPathFileURL, copyName, copyPathShellQuoted

    /// "cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:", "cancelOperation:" for the standard ones;
    /// AppKit's NSWindow tab actions ("newWindowForTab:", "selectNextTab:", "selectPreviousTab:", "toggleTabBar:",
    /// "toggleTabOverview:", "moveTabToNewWindow:", "mergeAllWindows:") for the tab commands;
    /// otherwise "macx_<rawValue>:" (e.g. "macx_moveToTrash:").
    public var selectorName: String {
        switch self {
        case .newTab: "newWindowForTab:"
        case .nextTab: "selectNextTab:"
        case .previousTab: "selectPreviousTab:"
        case .showTabBar: "toggleTabBar:"
        case .showAllTabs: "toggleTabOverview:"
        case .moveTabToNewWindow: "moveTabToNewWindow:"
        case .mergeAllWindows: "mergeAllWindows:"
        default: isStandardSelector ? "\(rawValue):" : "macx_\(rawValue):"
        }
    }

    /// Commands whose action NSWindow (or BrowserWindowController, for newWindowForTab:) implements and validates
    /// itself. The content and sidebar panes never implement these selectors, so they cannot intercept them.
    public static let windowTabCommands: Set<Command> = [
        .newTab, .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows,
    ]

    public var isWindowTabCommand: Bool { Self.windowTabCommands.contains(self) }

    /// Exhaustive on purpose (no `default:`), so new cases must decide.
    private var isStandardSelector: Bool {
        switch self {
        case .cut, .copy, .paste, .selectAll, .undo, .redo, .cancelOperation:
            true
        case .open, .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder,
             .moveItemHere, .selectNone, .invertSelection,
             .rename, .moveToTrash, .deletePermanently, .duplicate, .makeAlias, .makeSymlink,
             .newFolder, .newTextFile, .newEmptyFile, .copyAsPath, .properties, .share,
             .back, .forward, .up, .focusAddressBar, .focusSearch, .cycleFocusForward, .cycleFocusBackward, .refresh,
             .newWindow, .closeWindow, .showOperations,
             .viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .densityCompact, .densityRegular, .densityComfortable, .toggleHidden, .toggleCommandBar,
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending,
             .eject, .removeFromFavorites,
             .newTab, .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows,
             .openInNewTab, .quickLook, .viewAsColumns,
             .groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName,
             .toggleFolderSizes, .applyViewToAllFolders,
             .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted:
            false
        }
    }
}
