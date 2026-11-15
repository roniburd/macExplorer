import XCTest
@testable import Core

final class KeyMapTests: XCTestCase {
    private func chord(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> KeyChord {
        guard let c = KeyChord(parsing: text) else {
            XCTFail("cannot parse '\(text)'", file: file, line: line)
            return KeyChord(.escape)
        }
        return c
    }

    // MARK: Command

    func testStandardSelectorNames() {
        XCTAssertEqual(Command.cut.selectorName, "cut:")
        XCTAssertEqual(Command.copy.selectorName, "copy:")
        XCTAssertEqual(Command.paste.selectorName, "paste:")
        XCTAssertEqual(Command.selectAll.selectorName, "selectAll:")
        XCTAssertEqual(Command.undo.selectorName, "undo:")
        XCTAssertEqual(Command.redo.selectorName, "redo:")
        XCTAssertEqual(Command.cancelOperation.selectorName, "cancelOperation:")
    }

    func testCustomSelectorNamesArePrefixed() {
        XCTAssertEqual(Command.moveToTrash.selectorName, "macx_moveToTrash:")
        XCTAssertEqual(Command.open.selectorName, "macx_open:")
        XCTAssertEqual(Command.moveItemHere.selectorName, "macx_moveItemHere:")
        let standard: Set<Command> = [.cut, .copy, .paste, .selectAll, .undo, .redo, .cancelOperation]
        // Phase 2's tab commands use NSWindow's own actions (testPhase2SelectorNames).
        for c in Command.allCases where !standard.contains(c) && !c.isWindowTabCommand {
            XCTAssertEqual(c.selectorName, "macx_\(c.rawValue):", "\(c)")
        }
    }

    func testSelectorNamesAreUnique() {
        let names = Command.allCases.map(\.selectorName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testCommandCodableRoundTrip() throws {
        let data = try JSONEncoder().encode([Command.moveToTrash, .sortByKind])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["moveToTrash","sortByKind"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Command].self, from: data), [.moveToTrash, .sortByKind])
    }

    // MARK: KeyChord parsing

    func testParsesScenarioKeyNames() {
        let table: [(String, KeyChord)] = [
            ("cmd+l", KeyChord(.character("l"), .command)), ("F2", KeyChord(.function(2))),
            ("opt+left", KeyChord(.left, .option)), ("cmd+up", KeyChord(.up, .command)),
            ("delete", KeyChord(.backspace)), ("cmd+delete", KeyChord(.backspace, .command)),
            ("opt+cmd+delete", KeyChord(.backspace, [.option, .command])), ("fn+delete", KeyChord(.forwardDelete)),
            ("shift+fn+delete", KeyChord(.forwardDelete, .shift)), ("cmd+shift+.", KeyChord(.character("."), [.command, .shift])),
            ("cmd+[", KeyChord(.character("["), .command)), ("opt+return", KeyChord(.returnKey, .option)),
            ("esc", KeyChord(.escape)), ("return", KeyChord(.returnKey)), ("ctrl+z", KeyChord(.character("z"), .control)),
            ("tab", KeyChord(.tab)), ("F4", KeyChord(.function(4))), ("F5", KeyChord(.function(5))),
            ("up", KeyChord(.up)), ("down", KeyChord(.down)), ("left", KeyChord(.left)), ("right", KeyChord(.right)),
            ("cmd+]", KeyChord(.character("]"), .command)), ("opt+right", KeyChord(.right, .option)),
            ("opt+up", KeyChord(.up, .option)), ("opt+d", KeyChord(.character("d"), .option)),
            ("shift+right", KeyChord(.right, .shift)), ("cmd+shift+z", KeyChord(.character("z"), [.command, .shift])),
            ("cmd+shift+n", KeyChord(.character("n"), [.command, .shift])), ("cmd+shift+r", KeyChord(.character("r"), [.command, .shift])),
            ("cmd+down", KeyChord(.down, .command)), ("ctrl+x", KeyChord(.character("x"), .control)),
            ("ctrl+v", KeyChord(.character("v"), .control)), ("cmd+y", KeyChord(.character("y"), .command)),
        ]
        for (text, expected) in table { XCTAssertEqual(KeyChord(parsing: text), expected, text) }
    }

    func testParsingSynonymsAndCase() {
        XCTAssertEqual(KeyChord(parsing: "Command+Shift+N"), KeyChord(.character("n"), [.command, .shift]))
        XCTAssertEqual(KeyChord(parsing: "alt+option+opt+d"), KeyChord(.character("d"), .option))
        XCTAssertEqual(KeyChord(parsing: "control+c"), KeyChord(.character("c"), .control))
        XCTAssertEqual(KeyChord(parsing: "escape"), KeyChord(.escape))
        XCTAssertEqual(KeyChord(parsing: "f12"), KeyChord(.function(12)))
        XCTAssertEqual(KeyChord(parsing: "F20"), KeyChord(.function(20)))
        XCTAssertEqual(KeyChord(parsing: "backspace"), KeyChord(.backspace))
        XCTAssertEqual(KeyChord(parsing: "cmd+backspace"), KeyChord(.backspace, .command))
        XCTAssertEqual(KeyChord(parsing: "del"), KeyChord(.forwardDelete))
        XCTAssertEqual(KeyChord(parsing: "space"), KeyChord(.space))
        XCTAssertEqual(KeyChord(parsing: "enter"), KeyChord(.enter))
        XCTAssertEqual(KeyChord(parsing: "cmd+A"), KeyChord(.character("a"), .command), "letters are lowercased")
        XCTAssertEqual(KeyChord(parsing: "cmd++"), KeyChord(.character("+"), .command))
        XCTAssertEqual(KeyChord(parsing: "+"), KeyChord(.character("+")))
        XCTAssertEqual(KeyChord(parsing: "fn+F2"), KeyChord(.function(2)), "fn is implied for F-keys")
        XCTAssertEqual(KeyChord(parsing: "cmd+1"), KeyChord(.character("1"), .command))
    }

    func testParsingRejectsGarbage() {
        for bad in ["", "cmd+", "hyper+q", "cmd+shift", "foo", "F0", "F21", "cmd++shift+x", "fn+a", "fn+left", "+cmd"] {
            XCTAssertNil(KeyChord(parsing: bad), bad)
        }
    }

    func testDescriptionRoundTripsThroughParsing() {
        var chords: [KeyChord] = []
        for c in Command.allCases {
            if let p = KeyMap.primary(c) { chords.append(p) }
            chords += KeyMap.alternates(c)
        }
        chords += [KeyChord(.character("+"), .command), KeyChord(.space), KeyChord(.enter), KeyChord(.function(20)),
                   KeyChord(.forwardDelete, [.shift, .control])]
        for c in chords { XCTAssertEqual(KeyChord(parsing: c.description), c, c.description) }
    }

    func testDescriptionIsCanonical() {
        XCTAssertEqual(KeyChord(.backspace, [.command, .option]).description, "opt+cmd+delete")
        XCTAssertEqual(KeyChord(.forwardDelete, .shift).description, "shift+fn+delete")
        XCTAssertEqual(KeyChord(.character("n"), [.shift, .command]).description, "shift+cmd+n")
        XCTAssertEqual(KeyChord(.function(2)).description, "F2")
        XCTAssertEqual(KeyChord(.character("c"), .control).description, "ctrl+c")
    }

    // MARK: KeyMap primaries (§5.6)

    func testPrimariesMatchSpecTable() {
        let expected: [Command: String] = [
            .open: "cmd+down", .rename: "F2", .moveToTrash: "cmd+delete", .deletePermanently: "opt+cmd+delete",
            .cut: "cmd+x", .copy: "cmd+c", .paste: "cmd+v", .moveItemHere: "opt+cmd+v",
            .undo: "cmd+z", .redo: "cmd+shift+z", .back: "cmd+[", .forward: "cmd+]", .up: "cmd+up",
            .focusAddressBar: "cmd+l", .focusSearch: "cmd+f", .newFolder: "cmd+shift+n", .newWindow: "cmd+n",
            .closeWindow: "cmd+w", .properties: "cmd+i", .refresh: "cmd+r", .copyAsPath: "cmd+shift+c",
            .toggleHidden: "cmd+shift+.", .selectAll: "cmd+a", .duplicate: "cmd+d", .eject: "cmd+e",
            // Phase 2 (P2-02)
            .newTab: "cmd+t", .nextTab: "ctrl+tab", .previousTab: "ctrl+shift+tab", .showAllTabs: "cmd+shift+\\",
            .viewAsDetails: "cmd+1", .viewAsIcons: "cmd+2", .viewAsColumns: "cmd+3",
            // Phase 3 (P3-07)
            .togglePreviewPane: "opt+p", .openContainingFolder: "cmd+opt+r",
            // Preview pane zoom
            .previewZoomIn: "cmd+=", .previewZoomOut: "cmd+-", .previewActualSize: "cmd+0",
            // Phase 4 (spec §11): the command palette
            .showCommandPalette: "cmd+shift+p",
        ]
        for c in Command.allCases {
            if let text = expected[c] {
                XCTAssertEqual(KeyMap.primary(c), chord(text), "\(c)")
            } else {
                XCTAssertNil(KeyMap.primary(c), "\(c) has no primary in §5.6")
            }
        }
    }

    func testPrimariesAreUnique() {
        var seen: [KeyChord: Command] = [:]
        for c in Command.allCases {
            guard let k = KeyMap.primary(c) else { continue }
            XCTAssertNil(seen[k], "\(k) bound to both \(seen[k].map { "\($0)" } ?? "") and \(c)")
            seen[k] = c
        }
    }

    /// Chords reserved for later phases go only to the command that phase assigns them (Phase 2 took ⌘T, ⌘1–⌘3, ⌃Tab).
    func testPrimariesAvoidLaterPhaseChords() {
        let owners: [String: Command?] = [
            "cmd+t": .newTab, "cmd+1": .viewAsDetails, "cmd+2": .viewAsIcons, "cmd+3": .viewAsColumns, "ctrl+tab": .nextTab,
            "opt+p": .togglePreviewPane, "cmd+opt+r": .openContainingFolder,
        ]
        for c in Command.allCases {
            guard let p = KeyMap.primary(c), let owner = owners.first(where: { chord($0.key) == p })?.value else { continue }
            XCTAssertEqual(owner, c, "\(c) uses \(p)")
        }
    }

    // MARK: Alternates

    func testAlternatesMatchSpecTable() {
        let expected: [Command: [String]] = [
            .open: ["return"], .rename: ["cmd+shift+r"], .moveToTrash: ["fn+delete"], .deletePermanently: ["shift+fn+delete"],
            .cut: ["ctrl+x"], .copy: ["ctrl+c"], .paste: ["ctrl+v"], .undo: ["ctrl+z"], .redo: ["cmd+y"],
            .back: ["delete", "opt+left"], .forward: ["opt+right"], .up: ["opt+up"], .focusAddressBar: ["opt+d", "F4"],
            .focusSearch: ["F3"], .properties: ["opt+return"], .refresh: ["F5"], .selectAll: ["ctrl+a"],
            .cycleFocusForward: ["tab"], .cycleFocusBackward: ["shift+tab"], .cancelOperation: ["esc"],
            .quickLook: ["space"],   // Phase 2 (P2-02), content only
        ]
        for c in Command.allCases {
            XCTAssertEqual(KeyMap.alternates(c), (expected[c] ?? []).map { chord($0) }, "\(c)")
        }
    }

    func testAlternatesAreUniqueAndNeverPrimaries() {
        let primaries = Set(Command.allCases.compactMap { KeyMap.primary($0) })
        var seen: [KeyChord: Command] = [:]
        for c in Command.allCases {
            for k in KeyMap.alternates(c) {
                XCTAssertNil(seen[k], "\(k) is an alternate of \(seen[k].map { "\($0)" } ?? "") and \(c)")
                XCTAssertFalse(primaries.contains(k), "\(k) is both a primary and an alternate")
                seen[k] = c
            }
        }
    }

    func testEveryFunctionKeyCommandHasANonFunctionKeyBinding() {
        for c in Command.allCases {
            let all = [KeyMap.primary(c)].compactMap { $0 } + KeyMap.alternates(c)
            let usesF = all.contains { if case .function = $0.key { true } else { false } }
            guard usesF else { continue }
            XCTAssertTrue(all.contains { if case .function = $0.key { false } else { true } }, "\(c)")
        }
    }

    // MARK: KeyDispatcher

    func testDispatchesAlternatesInContent() {
        let d = KeyDispatcher(returnKey: .open)
        let table: [(String, Command)] = [
            ("return", .open), ("opt+return", .properties), ("fn+delete", .moveToTrash), ("shift+fn+delete", .deletePermanently),
            ("ctrl+x", .cut), ("ctrl+c", .copy), ("ctrl+v", .paste), ("ctrl+z", .undo), ("cmd+y", .redo), ("ctrl+a", .selectAll),
            ("delete", .back), ("opt+left", .back), ("opt+right", .forward), ("opt+up", .up), ("opt+d", .focusAddressBar),
            ("F4", .focusAddressBar), ("F3", .focusSearch), ("F5", .refresh), ("cmd+shift+r", .rename),
            ("tab", .cycleFocusForward), ("shift+tab", .cycleFocusBackward), ("esc", .cancelOperation),
        ]
        for (text, command) in table { XCTAssertEqual(d.command(for: chord(text), in: .content), command, text) }
    }

    func testPrimariesAreNotDispatched() {
        let d = KeyDispatcher(returnKey: .open)
        for c in Command.allCases {
            guard let p = KeyMap.primary(c) else { continue }
            XCTAssertNil(d.command(for: p, in: .content), "\(p) belongs to the menu")
        }
        XCTAssertNil(d.command(for: chord("x"), in: .content), "plain letters are type-select")
        XCTAssertNil(d.command(for: chord("space"), in: .sidebarFolders), "Space is Quick Look in the content view only")
    }

    func testReturnKeyBehaviour() {
        XCTAssertEqual(KeyDispatcher(returnKey: .open).command(for: chord("return"), in: .content), .open)
        XCTAssertEqual(KeyDispatcher(returnKey: .rename).command(for: chord("return"), in: .content), .rename)
        XCTAssertEqual(KeyDispatcher(returnKey: .rename).command(for: chord("opt+return"), in: .content), .properties)
        for focus: FocusContext in [.sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot] {
            XCTAssertEqual(KeyDispatcher(returnKey: .rename).command(for: chord("return"), in: focus), .open,
                           "Return navigates in the sidebar (\(focus))")
        }
    }

    func testTextFocusNeverDispatches() {
        for returnKey: ReturnKeyBehavior in [.open, .rename] {
            let d = KeyDispatcher(returnKey: returnKey)
            for c in Command.allCases {
                for k in KeyMap.alternates(c) + ["return", "tab", "esc"].map({ chord($0) }) {
                    XCTAssertNil(d.command(for: k, in: .fieldEditor), "\(k)")
                    XCTAssertNil(d.command(for: k, in: .addressBar), "\(k)")
                }
            }
        }
    }

    func testSidebarRemaps() {
        let d = KeyDispatcher(returnKey: .open)
        XCTAssertEqual(d.command(for: chord("fn+delete"), in: .sidebarFavorites), .removeFromFavorites)
        XCTAssertEqual(d.command(for: chord("fn+delete"), in: .sidebarFolders), .moveToTrash)
        XCTAssertEqual(d.command(for: chord("fn+delete"), in: .sidebarLocations), .moveToTrash, "disabled, not remapped")
        XCTAssertEqual(d.command(for: chord("ctrl+c"), in: .sidebarLocations), .copy)
        XCTAssertEqual(d.command(for: chord("opt+return"), in: .sidebarLocations), .properties)
    }

    // MARK: Phase 2 commands (tabs, views, Quick Look)


    func testPhase2Primaries() {
        XCTAssertEqual(KeyMap.primary(.newTab), chord("cmd+t"))
        XCTAssertEqual(KeyMap.primary(.nextTab), chord("ctrl+tab"))
        XCTAssertEqual(KeyMap.primary(.previousTab), chord("ctrl+shift+tab"))
        XCTAssertEqual(KeyMap.primary(.showAllTabs), KeyChord(.character("\\"), [.command, .shift]))
        XCTAssertEqual(KeyMap.primary(.viewAsDetails), chord("cmd+1"))
        XCTAssertEqual(KeyMap.primary(.viewAsIcons), chord("cmd+2"))
        XCTAssertEqual(KeyMap.primary(.viewAsColumns), chord("cmd+3"))
        XCTAssertNil(KeyMap.primary(.quickLook), "Space is content-only so type-select and text fields keep it")
        XCTAssertEqual(KeyMap.alternates(.quickLook), [KeyChord(.space)])
        XCTAssertNil(KeyMap.primary(.copyPathTilde))
        XCTAssertEqual(KeyMap.primary(.copyAsPath), chord("cmd+shift+c"))   // Phase 1, unchanged
    }

    func testPhase2SelectorNames() {
        XCTAssertEqual(Command.newTab.selectorName, "newWindowForTab:")
        XCTAssertEqual(Command.nextTab.selectorName, "selectNextTab:")
        XCTAssertEqual(Command.previousTab.selectorName, "selectPreviousTab:")
        XCTAssertEqual(Command.showTabBar.selectorName, "toggleTabBar:")
        XCTAssertEqual(Command.showAllTabs.selectorName, "toggleTabOverview:")
        XCTAssertEqual(Command.moveTabToNewWindow.selectorName, "moveTabToNewWindow:")
        XCTAssertEqual(Command.mergeAllWindows.selectorName, "mergeAllWindows:")
        XCTAssertEqual(Command.quickLook.selectorName, "macx_quickLook:")
        XCTAssertEqual(Command.copyPathShellQuoted.selectorName, "macx_copyPathShellQuoted:")
    }

    func testWindowTabCommandsAreTheNSWindowActions() {
        XCTAssertEqual(Command.windowTabCommands,
                       [.newTab, .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows])
        for c in Command.allCases where !Command.windowTabCommands.contains(c) {
            XCTAssertFalse(c.isWindowTabCommand)
        }
    }

    func testDispatcherSpaceAndControlTab() {
        let d = KeyDispatcher(returnKey: .open)
        XCTAssertEqual(d.command(for: KeyChord(.space), in: .content), .quickLook)
        XCTAssertNil(d.command(for: KeyChord(.space), in: .sidebarFolders))
        XCTAssertNil(d.command(for: KeyChord(.space), in: .fieldEditor))
        XCTAssertNil(d.command(for: KeyChord(.tab, [.control]), in: .content), "⌃Tab is the next-tab menu key, never focus cycling")
        XCTAssertNil(d.command(for: KeyChord(.tab, [.control, .shift]), in: .sidebarFolders))
        XCTAssertEqual(d.command(for: KeyChord(.tab), in: .content), .cycleFocusForward)   // Phase 1 unchanged
    }

    func testPhase2Availability() {
        func on(_ c: Command, _ f: FocusContext = .content, _ s: CommandState) -> Bool { CommandAvailability.isEnabled(c, focus: f, state: s) }
        XCTAssertFalse(on(.quickLook, .content, CommandState()))
        XCTAssertTrue(on(.quickLook, .content, CommandState(selectionCount: 1)))
        XCTAssertTrue(on(.quickLook, .content, CommandState(quickLookVisible: true)), "Space closes an open panel with nothing selected")
        XCTAssertFalse(on(.quickLook, .sidebarFolders, CommandState(selectionCount: 1)))
        XCTAssertFalse(on(.openInNewTab, .content, CommandState(selectionCount: 2, selectedFolderCount: 0)))
        XCTAssertTrue(on(.openInNewTab, .content, CommandState(selectionCount: 2, selectedFolderCount: 1)))
        XCTAssertTrue(on(.openInNewTab, .sidebarFavorites, CommandState()))
        XCTAssertTrue(on(.groupByKind, .content, CommandState(viewMode: .details)))
        XCTAssertFalse(on(.groupByKind, .content, CommandState(viewMode: .icons)))
        XCTAssertFalse(on(.toggleFolderSizes, .content, CommandState(viewMode: .columns)))
        XCTAssertTrue(on(.newTab, .sidebarLocations, CommandState()))
        for c in [Command.copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted] {
            XCTAssertEqual(on(c, .content, CommandState(selectionCount: 1)), on(.copyAsPath, .content, CommandState(selectionCount: 1)))
            XCTAssertFalse(on(c, .content, CommandState()))
        }
    }

    func testFocusContextIsSidebar() {
        XCTAssertEqual([FocusContext.content, .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot,
                        .addressBar, .fieldEditor].map(\.isSidebar),
                       [false, true, true, true, true, false, false])
    }

    func testQuickLookIsNotATextCollision() {
        XCTAssertFalse(KeyBindings.defaults.collidesWithTextEditing.contains(.quickLook))
        XCTAssertFalse(KeyBindings.defaults.collidesWithTextEditing.contains(.nextTab))
    }

    // MARK: Phase 3 commands (preview, search)


    static let phase3Commands: [Command] = [
        .togglePreviewPane, .openContainingFolder, .saveSearch, .stopSearch, .searchScopeThisFolder, .searchScopeSubfolders,
        .searchScopeThisMac, .searchModeName, .searchModeContents, .renameSavedSearch, .removeSavedSearch, .downloadForPreview,
    ]

    /// Added after Phase 3 (Preview in the item context menu).
    static let laterPreviewCommands: [Command] = [.showInPreview, .previewZoomIn, .previewZoomOut, .previewActualSize]

    func testPhase3CommandsExistInOrder() {
        // The Phase 4 commands follow (KeymapPresetTests).
        let beforePhase4 = Command.allCases.dropLast(CommandAvailability.phase4Commands.count)
        XCTAssertEqual(Array(beforePhase4.suffix(Self.phase3Commands.count + Self.laterPreviewCommands.count)), Self.phase3Commands + Self.laterPreviewCommands)
        XCTAssertNil(KeyMap.primary(.showInPreview), "Preview has no default shortcut")
    }

    func testPhase3Primaries() {
        XCTAssertEqual(KeyMap.primary(.togglePreviewPane), chord("opt+p"))
        XCTAssertEqual(KeyMap.primary(.openContainingFolder), chord("cmd+opt+r"))
        for c: Command in [.saveSearch, .stopSearch, .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac,
                           .searchModeName, .searchModeContents, .renameSavedSearch, .removeSavedSearch, .downloadForPreview] {
            XCTAssertNil(KeyMap.primary(c), "\(c)")
        }
        for c in Self.phase3Commands {
            XCTAssertEqual(KeyMap.alternates(c), [], "\(c)")
            XCTAssertEqual(KeyMap.defaultMouse(c), [], "\(c)")
        }
    }

    func testPhase3SelectorNames() {
        XCTAssertEqual(Command.togglePreviewPane.selectorName, "macx_togglePreviewPane:")
        XCTAssertEqual(Command.openContainingFolder.selectorName, "macx_openContainingFolder:")
        XCTAssertEqual(Command.removeSavedSearch.selectorName, "macx_removeSavedSearch:")
        for c in Self.phase3Commands { XCTAssertEqual(c.selectorName, "macx_\(c.rawValue):") }
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

    func testPhase3Availability() {
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
