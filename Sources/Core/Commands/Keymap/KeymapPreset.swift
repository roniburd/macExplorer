import Foundation

/// A starting point for Settings › Shortcuts. A preset is a set of `KeyBindingOverrides` on top of the built-in
/// table (`KeyMap`, which is the Explorer preset), so choosing one is writing its overrides to
/// `settings.keyBindingOverrides`; the user's edits then go on top as usual.
public enum KeymapPreset: String, Sendable, Codable, CaseIterable {
    /// The built-in table (spec §5.6): Windows Explorer keys plus the Mac menu keys.
    case explorer
    /// Finder's keys: ⌘O opens, ⇧⌘G goes to a folder, ⌥⌘C copies the path, ⌃⌘A makes an alias, ⌘1/⌘2 are Icons/List;
    /// none of the Windows-style alternates (Del, ⌃C, F2, F5, …). Return renames (`returnKey`).
    case finder

    public var overrides: KeyBindingOverrides {
        switch self {
        case .explorer: .empty
        case .finder: Self.finderOverrides
        }
    }

    /// The Settings › Return key value that goes with the preset (Finder: Return renames).
    public var returnKey: ReturnKeyBehavior {
        switch self {
        case .explorer: .open
        case .finder: .rename
        }
    }

    /// The preset whose bindings `overrides` gives exactly (same primaries, alternates and mouse buttons), if any.
    public init?(matching overrides: KeyBindingOverrides) {
        let bindings = KeyBindings(overrides: overrides)
        guard let preset = Self.allCases.first(where: { KeyBindings(overrides: $0.overrides).sameTriggers(as: bindings) })
        else { return nil }
        self = preset
    }

    private static let finderOverrides: KeyBindingOverrides = {
        var commands: [Command: KeyBindingOverrides.Entry] = [:]
        for command in Command.allCases {
            guard let (primary, alternates) = finder(command) else { continue }
            commands[command] = KeyBindingOverrides.normalizedEntry(command, primary: primary, alternates: alternates,
                                                                    mouse: KeyMap.defaultMouse(command))
        }
        return KeyBindingOverrides(commands: commands)
    }()

    private static func k(_ text: String) -> KeyChord { KeyChord(parsing: text)! }

    /// Finder's primary and alternates for `command`, or nil where Finder uses the Explorer (built-in) keys.
    /// Exhaustive on purpose (no `default:`), so each new command decides.
    private static func finder(_ command: Command) -> (KeyChord?, [KeyChord])? {
        switch command {
        // Return stays listed under Open: the Return key setting turns it into Rename in the content view.
        case .open: (k("cmd+o"), [k("return"), k("cmd+down")])
        case .rename: (nil, [])
        case .refresh: (nil, [])
        case .focusAddressBar: (k("shift+cmd+g"), [])
        case .copyAsPath: (k("opt+cmd+c"), [])
        case .makeAlias: (k("ctrl+cmd+a"), [])
        case .viewAsIcons: (k("cmd+1"), [])
        case .viewAsDetails: (k("cmd+2"), [])
        case .moveToTrash, .deletePermanently, .cut, .copy, .paste, .undo, .redo, .selectAll,
             .back, .forward, .up, .focusSearch, .properties:
            (KeyMap.primary(command), [])
        case .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder,
             .moveItemHere, .selectNone, .invertSelection,
             .duplicate, .makeSymlink, .newFolder, .newTextFile, .newEmptyFile, .share,
             .cycleFocusForward, .cycleFocusBackward, .newWindow, .closeWindow, .showOperations,
             .viewAsColumns, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .densityCompact, .densityRegular, .densityComfortable, .toggleHidden, .toggleCommandBar,
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending,
             .useViewAsDefault, .resetFolderView, .eject, .removeFromFavorites, .cancelOperation,
             .newTab, .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows, .openInNewTab,
             .quickLook, .groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName,
             .toggleFolderSizes, .applyViewToAllFolders, .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted,
             .togglePreviewPane, .openContainingFolder, .saveSearch, .stopSearch,
             .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac, .searchModeName, .searchModeContents,
             .renameSavedSearch, .removeSavedSearch, .downloadForPreview, .showInPreview,
             .previewZoomIn, .previewZoomOut, .previewActualSize,
             .showCommandPalette, .compressZip, .compressAppleArchive, .extractHere, .batchRename, .editTags:
            nil
        }
    }
}

extension KeyBindings {
    /// Same primary, alternates and mouse buttons for every command (unlike `==`, which compares the stored
    /// overrides, so two spellings of one table differ there).
    public func sameTriggers(as other: KeyBindings) -> Bool {
        Command.allCases.allSatisfy {
            primary($0) == other.primary($0) && alternates($0) == other.alternates($0) && mouse($0) == other.mouse($0)
        }
    }
}
