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
    case useViewAsDefault, resetFolderView
    // sidebar / volumes
    case eject, removeFromFavorites
    // escape: clear cut marks / cancel inline state
    case cancelOperation

    /// "cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:", "cancelOperation:" for the standard ones;
    /// otherwise "macx_<rawValue>:" (e.g. "macx_moveToTrash:").
    public var selectorName: String {
        isStandardSelector ? "\(rawValue):" : "macx_\(rawValue):"
    }

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
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending, .useViewAsDefault, .resetFolderView,
             .eject, .removeFromFavorites:
            false
        }
    }
}
