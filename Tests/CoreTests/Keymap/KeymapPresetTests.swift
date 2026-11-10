import XCTest
@testable import Core

/// P4-01: the Phase 4 commands (kept features only) and the keymap presets on top of Settings › Shortcuts.
final class KeymapPresetTests: XCTestCase {
    private func chord(_ s: String) -> KeyChord { KeyChord(parsing: s)! }

    static let phase4: [Command] = [.showCommandPalette, .compressZip, .compressAppleArchive, .extractHere, .batchRename, .editTags]

    func testPhase4CommandsAreAppendedWithMacxSelectors() {
        XCTAssertEqual(Array(Command.allCases.suffix(Self.phase4.count)), Self.phase4)
        XCTAssertEqual(CommandAvailability.phase4Commands, Set(Self.phase4))
        for c in Self.phase4 { XCTAssertEqual(c.selectorName, "macx_\(c.rawValue):") }
    }

    func testPhase4DefaultBindings() {
        XCTAssertEqual(KeyMap.primary(.showCommandPalette), chord("cmd+shift+p"))
        for c in Self.phase4 where c != .showCommandPalette { XCTAssertNil(KeyMap.primary(c), "\(c)") }
        for c in Self.phase4 {
            XCTAssertEqual(KeyMap.alternates(c), [], "\(c)")
            XCTAssertEqual(KeyMap.defaultMouse(c), [], "\(c)")
        }
    }

    func testPhase4CommandsDisabledAndUnboundUntilShipped() {
        let state = CommandState(selectionCount: 3, selectionIsArchive: true)
        for c in Self.phase4 where !CommandAvailability.isShipped(c) {
            for focus: FocusContext in [.content, .sidebarFolders, .searchResults] {
                XCTAssertFalse(CommandAvailability.isEnabled(c, focus: focus, state: state), "\(c) \(focus)")
            }
            // An unshipped command holds no keys, so it never steals a chord or shows up as a conflict.
            XCTAssertNil(KeyBindings.defaults.primary(c), "\(c)")
            XCTAssertEqual(KeyBindings.defaults.uses(of: .key(chord("cmd+shift+p"))).map(\.command).contains(c), false)
        }
        for c in Command.allCases where !CommandAvailability.phase4Commands.contains(c) {
            XCTAssertTrue(CommandAvailability.isShipped(c), "\(c)")
        }
    }

    private func on(_ c: Command, _ state: CommandState) -> Bool { on(c, .content, state) }
    private func on(_ c: Command, _ focus: FocusContext, _ state: CommandState) -> Bool {
        CommandAvailability.phase4Enabled(c, focus: focus, state: state)
    }

    /// The table each Phase 4 command follows once its task ships it.
    func testPhase4AvailabilityRows() {
        XCTAssertTrue(on(.showCommandPalette, CommandState()))
        XCTAssertTrue(on(.showCommandPalette, .sidebarFavorites, CommandState()))
        XCTAssertTrue(on(.compressZip, CommandState(selectionCount: 1)))
        XCTAssertTrue(on(.compressAppleArchive, .sidebarFolders, CommandState(selectionCount: 1)))
        XCTAssertFalse(on(.compressZip, CommandState()))
        XCTAssertFalse(on(.compressZip, CommandState(selectionCount: 1, folderIsReadOnly: true)))
        XCTAssertFalse(on(.compressZip, .sidebarFavorites, CommandState(selectionCount: 1)))
        XCTAssertTrue(on(.extractHere, CommandState(selectionCount: 1, selectionIsArchive: true)))
        XCTAssertFalse(on(.extractHere, CommandState(selectionCount: 1)))
        XCTAssertFalse(on(.extractHere, CommandState(selectionCount: 1, folderIsReadOnly: true, selectionIsArchive: true)))
        XCTAssertFalse(on(.extractHere, .sidebarFolders, CommandState(selectionCount: 1, selectionIsArchive: true)))
        XCTAssertTrue(on(.batchRename, CommandState(selectionCount: 2)))
        XCTAssertFalse(on(.batchRename, CommandState(selectionCount: 1)))
        XCTAssertFalse(on(.batchRename, CommandState(selectionCount: 2, folderIsReadOnly: true)))
        XCTAssertFalse(on(.batchRename, .sidebarFolders, CommandState(selectionCount: 2)))
        XCTAssertTrue(on(.editTags, CommandState(selectionCount: 1)))
        XCTAssertTrue(on(.editTags, .sidebarFolders, CommandState(selectionCount: 1)))
        XCTAssertFalse(on(.editTags, CommandState()))
        XCTAssertFalse(on(.editTags, .sidebarLocations, CommandState(selectionCount: 1)))
        // Search results act like the content view.
        XCTAssertTrue(on(.editTags, .searchResults, CommandState(selectionCount: 1)))
        XCTAssertTrue(on(.batchRename, .searchResults, CommandState(selectionCount: 2)))
        // Compress and Extract write next to the items: search results have no single folder.
        for c: Command in [.compressZip, .compressAppleArchive, .extractHere] {
            XCTAssertFalse(on(c, .searchResults, CommandState(selectionCount: 1, selectionIsArchive: true)), "\(c)")
        }
        // The palette opens from anywhere (like ⌘F); the item commands never act on a field being edited.
        XCTAssertTrue(on(.showCommandPalette, .fieldEditor, CommandState()))
        for c in Self.phase4 where c != .showCommandPalette {
            XCTAssertFalse(on(c, .fieldEditor, CommandState(selectionCount: 2, selectionIsArchive: true)), "\(c)")
            XCTAssertFalse(on(c, .addressBar, CommandState(selectionCount: 2, selectionIsArchive: true)), "\(c)")
        }
    }

    func testExplorerPresetIsTheBuiltInTable() {
        XCTAssertEqual(KeymapPreset.explorer.overrides, .empty)
        XCTAssertEqual(KeymapPreset.explorer.returnKey, .open)
        XCTAssertEqual(KeyBindings(overrides: KeymapPreset.explorer.overrides), KeyBindings.defaults)
    }

    func testFinderPreset() {
        XCTAssertEqual(KeymapPreset.finder.returnKey, .rename)
        let f = KeyBindings(overrides: KeymapPreset.finder.overrides)
        XCTAssertEqual(f.primary(.open), chord("cmd+o"))
        XCTAssertEqual(f.alternates(.open), [chord("return"), chord("cmd+down")])
        XCTAssertEqual(f.primary(.focusAddressBar), chord("cmd+shift+g"))
        XCTAssertEqual(f.alternates(.focusAddressBar), [])
        XCTAssertEqual(f.primary(.copyAsPath), chord("cmd+opt+c"))
        XCTAssertEqual(f.primary(.makeAlias), chord("cmd+ctrl+a"))
        XCTAssertEqual(f.primary(.viewAsIcons), chord("cmd+1"))
        XCTAssertEqual(f.primary(.viewAsDetails), chord("cmd+2"))
        XCTAssertEqual(f.primary(.viewAsColumns), chord("cmd+3"))
        XCTAssertNil(f.primary(.rename))
        XCTAssertEqual(f.alternates(.rename), [])
        XCTAssertNil(f.primary(.refresh))
        XCTAssertEqual(f.alternates(.refresh), [])
        XCTAssertEqual(f.alternates(.moveToTrash), [], "no Del alternate in Finder")
        XCTAssertEqual(f.alternates(.deletePermanently), [])
        for c: Command in [.cut, .copy, .paste, .undo, .redo, .selectAll, .back, .forward, .up, .focusSearch, .properties] {
            XCTAssertEqual(f.primary(c), KeyMap.primary(c), "\(c) keeps its menu key")
            XCTAssertEqual(f.alternates(c), [], "\(c) has no Windows-style alternate")
        }
        XCTAssertEqual(f.alternates(.quickLook), [chord("space")])
        XCTAssertEqual(f.mouse(.back), KeyMap.defaultMouse(.back))
        XCTAssertEqual(f.primary(.newFolder), KeyMap.primary(.newFolder))
        // Return renames in the content view (Settings › Return key = Rename, which the preset brings along).
        XCTAssertEqual(KeyDispatcher(returnKey: KeymapPreset.finder.returnKey, bindings: f).command(for: chord("return"), in: .content),
                       .rename)
    }

    func testBothPresetsAreValidAndConflictFree() {
        for p in KeymapPreset.allCases {
            XCTAssertEqual(KeymapValidator.issues(p.overrides), [], "\(p)")
            // Every override survives KeyBindings' own validation (nothing silently falls back to the default).
            let b = KeyBindings(overrides: p.overrides)
            for (c, entry) in p.overrides.commands {
                if case .chord(let k)? = entry.primary { XCTAssertEqual(b.primary(c), k, "\(p) \(c)") }
                if let alts = entry.alternates { XCTAssertEqual(b.alternates(c), alts, "\(p) \(c)") }
            }
        }
    }

    func testPresetOverridesAreNormalized() {
        // An entry exists only where the preset differs from the built-in table (the Shortcuts editing invariant).
        for (c, entry) in KeymapPreset.finder.overrides.commands {
            if case .chord(let k)? = entry.primary { XCTAssertNotEqual(k, KeyMap.primary(c), "\(c)") }
            if case .unbound? = entry.primary { XCTAssertNotNil(KeyMap.primary(c), "\(c)") }
            if let alts = entry.alternates { XCTAssertNotEqual(alts, KeyMap.alternates(c), "\(c)") }
            XCTAssertFalse(KeyBindings.fixedCommands.contains(c))
        }
    }

    func testDetectPreset() {
        XCTAssertEqual(KeymapPreset(matching: .empty), .explorer)
        XCTAssertEqual(KeymapPreset(matching: KeymapPreset.finder.overrides), .finder)
        var o = KeymapPreset.finder.overrides
        o.setPrimary(chord("cmd+opt+n"), for: .newWindow)
        XCTAssertNil(KeymapPreset(matching: o))
    }

    func testParserAliases() {
        XCTAssertEqual(chord("shift+fwddelete"), chord("shift+fn+delete"))
        XCTAssertEqual(chord("cmd+backspace"), chord("cmd+delete"))
        XCTAssertEqual(chord("cmd+plus"), chord("cmd++"))
    }

    /// Review Focus 3: system chords can't be bound anywhere (Settings › Shortcuts or an imported keymap).
    func testSystemChordsAreReserved() {
        for text in ["cmd+q", "cmd+tab", "shift+cmd+tab", "cmd+space", "ctrl+space", "ctrl+up", "ctrl+down",
                     "shift+cmd+3", "shift+cmd+4", "shift+cmd+5", "ctrl+cmd+q", "opt+cmd+esc"] {
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .primary), .reserved, text)
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .alternate), .reserved, text)
        }
        for c in Command.allCases {
            if let k = KeyMap.primary(c) { XCTAssertFalse(KeyBindings.reservedChords.contains(k), "\(c)") }
            if !KeyBindings.fixedCommands.contains(c) {
                for k in KeyMap.alternates(c) { XCTAssertFalse(KeyBindings.reservedChords.contains(k), "\(c) \(k)") }
            }
        }
    }
}
