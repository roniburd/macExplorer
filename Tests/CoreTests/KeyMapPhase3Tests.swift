import XCTest
@testable import Core

final class KeyMapPhase3Tests: XCTestCase {
    func chord(_ s: String) -> KeyChord { KeyChord(parsing: s)! }

    static let phase3: [Command] = [
        .togglePreviewPane, .openContainingFolder, .saveSearch, .stopSearch, .searchScopeThisFolder, .searchScopeSubfolders,
        .searchScopeThisMac, .searchModeName, .searchModeContents, .renameSavedSearch, .removeSavedSearch, .downloadForPreview,
    ]

    func testPhase3CommandsExistInOrder() {
        XCTAssertEqual(Array(Command.allCases.suffix(Self.phase3.count)), Self.phase3)
    }

    func testPrimaries() {
        XCTAssertEqual(KeyMap.primary(.togglePreviewPane), chord("opt+p"))
        XCTAssertEqual(KeyMap.primary(.openContainingFolder), chord("cmd+opt+r"))
        for c: Command in [.saveSearch, .stopSearch, .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac,
                           .searchModeName, .searchModeContents, .renameSavedSearch, .removeSavedSearch, .downloadForPreview] {
            XCTAssertNil(KeyMap.primary(c), "\(c)")
        }
        for c in Self.phase3 {
            XCTAssertEqual(KeyMap.alternates(c), [], "\(c)")
            XCTAssertEqual(KeyMap.defaultMouse(c), [], "\(c)")
        }
    }

    func testPrimariesStayUnique() {
        var seen: [KeyChord: Command] = [:]
        for c in Command.allCases {
            guard let k = KeyMap.primary(c) else { continue }
            XCTAssertNil(seen[k], "\(k) bound to both \(String(describing: seen[k])) and \(c)")
            seen[k] = c
        }
    }

    func testSelectorNames() {
        XCTAssertEqual(Command.togglePreviewPane.selectorName, "macx_togglePreviewPane:")
        XCTAssertEqual(Command.openContainingFolder.selectorName, "macx_openContainingFolder:")
        XCTAssertEqual(Command.removeSavedSearch.selectorName, "macx_removeSavedSearch:")
        for c in Self.phase3 { XCTAssertEqual(c.selectorName, "macx_\(c.rawValue):") }
    }

    // Review Focus 2
    func testTogglePreviewPaneCollidesWithTextEditing() {
        XCTAssertTrue(KeyMap.collidesWithTextEditing.contains(.togglePreviewPane))
        XCTAssertFalse(KeyMap.collidesWithTextEditing.contains(.openContainingFolder))
        XCTAssertTrue(KeyBindings.defaults.collidesWithTextEditing.contains(.togglePreviewPane))
        let d = KeyDispatcher(returnKey: .open)
        XCTAssertNil(d.command(for: chord("opt+p"), in: .fieldEditor))
        XCTAssertNil(d.command(for: chord("opt+p"), in: .addressBar))
        XCTAssertFalse(CommandAvailability.isEnabled(.togglePreviewPane, focus: .fieldEditor, state: CommandState()))
        XCTAssertTrue(CommandAvailability.isEnabled(.openContainingFolder, focus: .searchResults,
                                                    state: CommandState(selectionCount: 1, showingResults: true)))
    }

    /// A user who moves Toggle Preview Pane to a ⌘ chord gets a key that no longer collides; ⌥P stays a default only
    /// (Settings › Shortcuts still rejects typing chords as new primaries).
    func testReboundPreviewPaneNoLongerCollides() {
        var o = KeyBindingOverrides.empty
        o.setPrimary(chord("opt+cmd+p"), for: .togglePreviewPane)
        XCTAssertFalse(KeyBindings(overrides: o).collidesWithTextEditing.contains(.togglePreviewPane))
        XCTAssertEqual(KeyBindings(overrides: o).primary(.togglePreviewPane), chord("opt+cmd+p"))
        XCTAssertEqual(KeyBindings.validate(.key(chord("opt+p")), as: .primary), .editsTextAsPrimary)
    }

    func testDispatcherInNewFocusContexts() {
        let d = KeyDispatcher(returnKey: .open)
        for (key, cmd) in [("return", Command.open), ("fn+delete", .moveToTrash), ("delete", .back), ("shift+fn+delete", .deletePermanently),
                           ("space", .quickLook)] {
            XCTAssertEqual(d.command(for: chord(key), in: .searchResults), d.command(for: chord(key), in: .content), key)
            XCTAssertEqual(d.command(for: chord(key), in: .searchResults), cmd, key)
        }
        XCTAssertEqual(KeyDispatcher(returnKey: .rename).command(for: chord("return"), in: .searchResults), .rename)
        XCTAssertEqual(d.command(for: chord("fn+delete"), in: .sidebarSavedSearch), .removeSavedSearch)
        XCTAssertEqual(d.command(for: chord("cmd+shift+r"), in: .sidebarSavedSearch), .renameSavedSearch)
        XCTAssertNil(d.command(for: chord("shift+fn+delete"), in: .sidebarSavedSearch))
        XCTAssertNil(d.command(for: chord("space"), in: .sidebarSavedSearch))
        XCTAssertEqual(d.command(for: chord("return"), in: .sidebarSavedSearch), .open)
        XCTAssertTrue(FocusContext.sidebarSavedSearch.isSidebar)
        XCTAssertFalse(FocusContext.searchResults.isSidebar)
    }

    // "Del never deletes files" in SEARCHES
    func testSavedSearchRemaps() {
        XCTAssertEqual(CommandAvailability.effectiveCommand(.moveToTrash, focus: .sidebarSavedSearch), .removeSavedSearch)
        XCTAssertEqual(CommandAvailability.effectiveCommand(.rename, focus: .sidebarSavedSearch), .renameSavedSearch)
        XCTAssertNil(CommandAvailability.effectiveCommand(.deletePermanently, focus: .sidebarSavedSearch))
        XCTAssertEqual(CommandAvailability.effectiveCommand(.moveToTrash, focus: .searchResults), .moveToTrash)
        XCTAssertEqual(CommandAvailability.effectiveCommand(.open, focus: .sidebarSavedSearch), .open)
    }

    func testAvailability() {
        let results = CommandState(selectionCount: 1, canPaste: true, showingResults: true)
        XCTAssertTrue(CommandAvailability.isEnabled(.openContainingFolder, focus: .searchResults, state: results))
        XCTAssertFalse(CommandAvailability.isEnabled(.openContainingFolder, focus: .searchResults, state: CommandState(showingResults: true)))
        XCTAssertFalse(CommandAvailability.isEnabled(.openContainingFolder, focus: .content, state: CommandState(selectionCount: 1)))
        XCTAssertFalse(CommandAvailability.isEnabled(.openContainingFolder, focus: .sidebarFolders, state: results))
        for c: Command in [.paste, .moveItemHere, .newFolder, .newTextFile, .newEmptyFile, .viewAsColumns] {
            XCTAssertFalse(CommandAvailability.isEnabled(c, focus: .searchResults, state: results), "\(c)")
        }
        XCTAssertTrue(CommandAvailability.isEnabled(.moveToTrash, focus: .searchResults, state: results))
        XCTAssertTrue(CommandAvailability.isEnabled(.copy, focus: .searchResults, state: results))
        XCTAssertTrue(CommandAvailability.isEnabled(.quickLook, focus: .searchResults, state: results))
        XCTAssertTrue(CommandAvailability.isEnabled(.togglePreviewPane, focus: .content, state: CommandState()))
        for c: Command in [.searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac, .searchModeName, .searchModeContents] {
            XCTAssertTrue(CommandAvailability.isEnabled(c, focus: .content, state: CommandState()), "\(c)")
        }
        XCTAssertTrue(CommandAvailability.isEnabled(.stopSearch, focus: .content, state: CommandState(isSearching: true)))
        XCTAssertFalse(CommandAvailability.isEnabled(.stopSearch, focus: .content, state: CommandState()))
        XCTAssertTrue(CommandAvailability.isEnabled(.saveSearch, focus: .content, state: CommandState(hasSearchQuery: true)))
        XCTAssertFalse(CommandAvailability.isEnabled(.saveSearch, focus: .content, state: CommandState()))
        XCTAssertTrue(CommandAvailability.isEnabled(.downloadForPreview, focus: .content, state: CommandState(selectionCount: 1, previewPaneVisible: true)))
        XCTAssertFalse(CommandAvailability.isEnabled(.downloadForPreview, focus: .content, state: CommandState(selectionCount: 1)))
        XCTAssertFalse(CommandAvailability.isEnabled(.downloadForPreview, focus: .content, state: CommandState(selectionCount: 2, previewPaneVisible: true)))
        let sidebar = CommandState(selectionCount: 1)
        for c: Command in [.open, .openInNewWindow, .openInNewTab, .renameSavedSearch, .removeSavedSearch] {
            XCTAssertTrue(CommandAvailability.isEnabled(c, focus: .sidebarSavedSearch, state: sidebar), "\(c)")
        }
        for c: Command in [.cut, .copy, .paste, .moveItemHere, .duplicate, .makeAlias, .makeSymlink, .moveToTrash, .rename,
                           .deletePermanently, .eject, .removeFromFavorites, .showPackageContents, .openInTerminal, .revealInFinder,
                           .copyAsPath, .properties, .share, .newFolder, .newTextFile, .newEmptyFile,
                           .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted, .quickLook] {
            XCTAssertFalse(CommandAvailability.isEnabled(c, focus: .sidebarSavedSearch, state: sidebar), "\(c)")
        }
        XCTAssertFalse(CommandAvailability.isEnabled(.removeSavedSearch, focus: .content, state: sidebar))
        XCTAssertFalse(CommandAvailability.isEnabled(.renameSavedSearch, focus: .sidebarFavorites, state: sidebar))
    }
}
