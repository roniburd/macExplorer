import Foundation

/// The §5.6 built-in key table (defaults; the user's changes live in Settings › Shortcuts, see KeyBindings). This
/// table is the Explorer keymap preset; `KeymapPreset.finder` is a set of overrides on top of it.
/// Each command has at most one primary (its menu key equivalent) and any number of alternates, which only the
/// content views and sidebar handle (through `KeyDispatcher`).
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
        case .newTab: cmd("t")
        case .nextTab: KeyChord(.tab, .control)
        case .previousTab: KeyChord(.tab, [.control, .shift])
        case .showAllTabs: KeyChord(.character("\\"), [.command, .shift])
        case .viewAsDetails: cmd("1")
        case .viewAsIcons: cmd("2")
        case .viewAsColumns: cmd("3")
        // Phase 3. ⌥P types "π" on US layouts: it is a typing chord, so it collides with text editing (see
        // `KeyBindings.collidesWithTextEditing`) and Settings › Shortcuts would not accept it as a new primary.
        case .togglePreviewPane: KeyChord(.character("p"), .option)
        case .openContainingFolder: KeyChord(.character("r"), [.command, .option])
        case .previewZoomIn: cmd("=")
        case .previewZoomOut: cmd("-")
        case .previewActualSize: cmd("0")
        case .showCommandPalette: KeyChord(.character("p"), [.shift, .command])
        case .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder,
             .selectNone, .invertSelection, .makeAlias, .makeSymlink, .newTextFile, .newEmptyFile, .share,
             .cycleFocusForward, .cycleFocusBackward, .showOperations,
             .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .densityCompact, .densityRegular, .densityComfortable, .toggleCommandBar,
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending,
             .removeFromFavorites, .cancelOperation,
             // Quick Look's Space is a content-only alternate, so type-select and text fields keep it.
             .showTabBar, .moveTabToNewWindow, .mergeAllWindows, .openInNewTab, .quickLook,
             .groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName,
             .toggleFolderSizes, .applyViewToAllFolders, .useViewAsDefault, .resetFolderView,
             .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted,
             .saveSearch, .stopSearch, .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac,
             .searchModeName, .searchModeContents, .renameSavedSearch, .removeSavedSearch, .downloadForPreview, .showInPreview,
             .compressZip, .compressAppleArchive, .extractHere, .batchRename, .editTags:
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
        case .quickLook: [KeyChord(.space)]
        case .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder, .moveItemHere,
             .selectNone, .invertSelection, .duplicate, .makeAlias, .makeSymlink,
             .newFolder, .newTextFile, .newEmptyFile, .copyAsPath, .share,
             .newWindow, .closeWindow, .showOperations,
             .viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .densityCompact, .densityRegular, .densityComfortable, .toggleHidden, .toggleCommandBar,
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending,
             .eject, .removeFromFavorites,
             .newTab, .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows,
             .openInNewTab, .viewAsColumns,
             .groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName,
             .toggleFolderSizes, .applyViewToAllFolders, .useViewAsDefault, .resetFolderView,
             .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted,
             .togglePreviewPane, .openContainingFolder, .saveSearch, .stopSearch,
             .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac, .searchModeName, .searchModeContents,
             .renameSavedSearch, .removeSavedSearch, .downloadForPreview, .showInPreview,
             .previewZoomIn, .previewZoomOut, .previewActualSize,
             .showCommandPalette, .compressZip, .compressAppleArchive, .extractHere, .batchRename, .editTags:
            []
        }
    }

    /// Default mouse buttons (AppKit buttonNumber): the "back" side button (3) and the "forward" one (4), as in browsers.
    public static func defaultMouse(_ command: Command) -> [MouseButton] {
        switch command {
        case .back: [MouseButton(number: 3)!]
        case .forward: [MouseButton(number: 4)!]
        default: []
        }
    }

    /// Chords a text field uses for editing. A command whose primary is one of these is disabled while a field editor
    /// is active, so the key reaches the text (`KeyBindings.collidesWithTextEditing`). Two parts:
    /// - the default primaries that collide (⌘↑, ⌘↓, ⌘⌫, ⌥⌘⌫, ⌘[, ⌘], F2, ⌘D);
    /// - the Cocoa text system's movement and deletion keys a user might rebind onto: ⌥/⌘/⌃ + arrows (with or without
    ///   ⇧), ⌥⌫, ⌥Del, ⌃⌫, ⌘Del, and the emacs-style ⌃ letters (with or without ⇧). None is a default primary.
    public static let textEditingChords: Set<KeyChord> = {
        var chords: Set<KeyChord> = [
            KeyChord(.up, .command), KeyChord(.down, .command), KeyChord(.backspace, .command),
            KeyChord(.backspace, [.option, .command]), KeyChord(.character("["), .command), KeyChord(.character("]"), .command),
            KeyChord(.function(2)), KeyChord(.character("d"), .command),
            KeyChord(.backspace, .option), KeyChord(.forwardDelete, .option), KeyChord(.backspace, .control),
            KeyChord(.forwardDelete, .command),
        ]
        for modifier: KeyModifiers in [.option, .command, .control] {
            for key: Key in [.left, .right, .up, .down] {
                chords.insert(KeyChord(key, modifier))
                chords.insert(KeyChord(key, modifier.union(.shift)))
            }
        }
        for letter in ["a", "b", "d", "e", "f", "h", "k", "l", "n", "o", "p", "t", "v", "y"] {
            chords.insert(KeyChord(.character(letter), .control))
            chords.insert(KeyChord(.character(letter), [.control, .shift]))
        }
        return chords
    }()

    /// The default bindings' commands whose primary belongs to a text field being edited (by default ⌘↑, ⌘↓, ⌘⌫, ⌥⌘⌫,
    /// ⌘[, ⌘], F2, ⌘D and the typing chord ⌥P). Same as `KeyBindings.defaults.collidesWithTextEditing`.
    public static var collidesWithTextEditing: Set<Command> { KeyBindings.defaults.collidesWithTextEditing }

    private static func cmd(_ c: String) -> KeyChord { KeyChord(.character(c), .command) }
    private static func ctrl(_ c: String) -> KeyChord { KeyChord(.character(c), .control) }
}
