import Foundation

/// The §5.6 key table. Each command has at most one primary (its menu key equivalent, rebindable in System Settings)
/// and any number of alternates, which only the content views and sidebar handle (through `KeyDispatcher`).
public enum KeyMap {
    /// Menu key equivalent (§5.6).
    public static func primary(_ command: Command) -> KeyChord? {
        switch command {
        case .open: KeyChord(.down, .command)
        case .rename: KeyChord(.function(2))
        case .moveToTrash: KeyChord(.backspace, .command)
        case .deletePermanently: KeyChord(.backspace, [.option, .command])
        case .cut: cmd("x")
        case .copy: cmd("c")
        case .paste: cmd("v")
        case .moveItemHere: KeyChord(.character("v"), [.option, .command])
        case .undo: cmd("z")
        case .redo: KeyChord(.character("z"), [.shift, .command])
        case .back: cmd("[")
        case .forward: cmd("]")
        case .up: KeyChord(.up, .command)
        case .focusAddressBar: cmd("l")
        case .focusSearch: cmd("f")
        case .newFolder: KeyChord(.character("n"), [.shift, .command])
        case .newWindow: cmd("n")
        case .closeWindow: cmd("w")
        case .properties: cmd("i")
        case .refresh: cmd("r")
        case .copyAsPath: KeyChord(.character("c"), [.shift, .command])
        case .toggleHidden: KeyChord(.character("."), [.shift, .command])
        case .selectAll: cmd("a")
        case .duplicate: cmd("d")
        case .eject: cmd("e")
        case .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder,
             .selectNone, .invertSelection, .makeAlias, .makeSymlink, .newTextFile, .newEmptyFile, .share,
             .cycleFocusForward, .cycleFocusBackward, .showOperations,
             .viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .densityCompact, .densityRegular, .densityComfortable, .toggleCommandBar,
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending, .useViewAsDefault, .resetFolderView,
             .removeFromFavorites, .cancelOperation:
            nil
        }
    }

    /// Content/sidebar only. Return is listed under `open`; `KeyDispatcher` sends it to `rename` in the content view
    /// when Settings › Return key = Rename.
    public static func alternates(_ command: Command) -> [KeyChord] {
        switch command {
        case .open: [KeyChord(.returnKey)]
        case .rename: [KeyChord(.character("r"), [.shift, .command])]
        case .moveToTrash: [KeyChord(.forwardDelete)]
        case .deletePermanently: [KeyChord(.forwardDelete, .shift)]
        case .cut: [ctrl("x")]
        case .copy: [ctrl("c")]
        case .paste: [ctrl("v")]
        case .undo: [ctrl("z")]
        case .redo: [cmd("y")]
        case .selectAll: [ctrl("a")]
        case .back: [KeyChord(.backspace), KeyChord(.left, .option)]
        case .forward: [KeyChord(.right, .option)]
        case .up: [KeyChord(.up, .option)]
        case .focusAddressBar: [KeyChord(.character("d"), .option), KeyChord(.function(4))]
        case .focusSearch: [KeyChord(.function(3))]
        case .properties: [KeyChord(.returnKey, .option)]
        case .refresh: [KeyChord(.function(5))]
        case .cycleFocusForward: [KeyChord(.tab)]
        case .cycleFocusBackward: [KeyChord(.tab, .shift)]
        case .cancelOperation: [KeyChord(.escape)]
        case .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder, .moveItemHere,
             .selectNone, .invertSelection, .duplicate, .makeAlias, .makeSymlink,
             .newFolder, .newTextFile, .newEmptyFile, .copyAsPath, .share,
             .newWindow, .closeWindow, .showOperations,
             .viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .densityCompact, .densityRegular, .densityComfortable, .toggleHidden, .toggleCommandBar,
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending, .useViewAsDefault, .resetFolderView,
             .eject, .removeFromFavorites:
            []
        }
    }

    /// Commands whose primary is also a text-editing key: open(⌘↓), up(⌘↑), moveToTrash(⌘⌫),
    /// deletePermanently(⌥⌘⌫), back(⌘[), forward(⌘]), rename(F2), duplicate(⌘D).
    public static let collidesWithTextEditing: Set<Command> = [
        .open, .up, .moveToTrash, .deletePermanently, .back, .forward, .rename, .duplicate,
    ]

    private static func cmd(_ c: String) -> KeyChord { KeyChord(.character(c), .command) }
    private static func ctrl(_ c: String) -> KeyChord { KeyChord(.character(c), .control) }
}
