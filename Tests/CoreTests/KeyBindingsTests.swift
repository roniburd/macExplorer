import XCTest
@testable import Core

final class KeyBindingsTests: XCTestCase {
    private func chord(_ text: String) -> KeyChord { KeyChord(parsing: text)! }
    private let mouse4 = MouseButton(number: 3)!
    private let mouse5 = MouseButton(number: 4)!
    private let mouse6 = MouseButton(number: 5)!

    func testDefaultsMatchKeyMap() {
        let b = KeyBindings.defaults
        for c in Command.allCases {
            XCTAssertEqual(b.primary(c), KeyMap.primary(c), "\(c)")
            XCTAssertEqual(b.alternates(c), KeyMap.alternates(c), "\(c)")
            XCTAssertEqual(b.mouse(c), KeyMap.defaultMouse(c), "\(c)")
        }
        XCTAssertEqual(b.command(for: mouse4), .back)
        XCTAssertEqual(b.command(for: mouse5), .forward)
        XCTAssertNil(b.command(for: mouse6))
        XCTAssertEqual(b.alternateCommand(for: chord("delete")), .back)
        XCTAssertNil(b.alternateCommand(for: chord("cmd+[")), "primaries are not alternates")
    }

    func testEachOverrideSlotAppliesAlone() {
        var o = KeyBindingOverrides.empty
        o.commands[.back] = .init(primary: .chord(chord("opt+cmd+b")))
        o.commands[.forward] = .init(alternates: [])
        o.commands[.up] = .init(mouse: [mouse6])
        o.commands[.duplicate] = .init(primary: .unbound)
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.back), chord("opt+cmd+b"))
        XCTAssertEqual(b.alternates(.back), KeyMap.alternates(.back))
        XCTAssertEqual(b.mouse(.back), [mouse4])
        XCTAssertEqual(b.alternates(.forward), [])
        XCTAssertNil(b.alternateCommand(for: chord("opt+right")))
        XCTAssertEqual(b.command(for: mouse6), .up)
        XCTAssertNil(b.primary(.duplicate))
    }

    func testInvalidStoredPrimaryFallsBackToDefault() {
        var o = KeyBindingOverrides.empty
        o.commands[.back] = .init(primary: .chord(chord("cmd+q")))
        o.commands[.forward] = .init(primary: .chord(chord("x")))
        o.commands[.moveToTrash] = .init(primary: .chord(chord("fn+delete")))
        o.commands[.open] = .init(primary: .chord(chord("return")))
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.back), KeyMap.primary(.back))
        XCTAssertEqual(b.primary(.forward), KeyMap.primary(.forward))
        XCTAssertEqual(b.primary(.moveToTrash), KeyMap.primary(.moveToTrash))
        XCTAssertEqual(b.primary(.open), KeyMap.primary(.open))
    }

    func testFixedCommandsIgnoreOverrides() {
        var o = KeyBindingOverrides.empty
        o.commands[.cancelOperation] = .init(alternates: [])
        XCTAssertEqual(KeyBindings(overrides: o).alternateCommand(for: chord("esc")), .cancelOperation)
        XCTAssertEqual(KeyBindings.fixedCommands, [.cycleFocusForward, .cycleFocusBackward, .cancelOperation])
    }

    func testStoredAlternatesCannotClaimReservedChords() {
        var o = KeyBindingOverrides.empty
        o.commands[.open] = .init(alternates: [chord("tab"), chord("f6")])
        o.commands[.back] = .init(alternates: [chord("esc"), chord("cmd+q")])
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.alternateCommand(for: chord("tab")), .cycleFocusForward)
        XCTAssertEqual(b.alternateCommand(for: chord("esc")), .cancelOperation)
        XCTAssertNil(b.alternateCommand(for: chord("cmd+q")))
        XCTAssertEqual(b.alternates(.open), [chord("f6")], "valid stored alternates are kept")
        XCTAssertEqual(b.alternates(.back), [])
        XCTAssertEqual(b.uses(of: .key(chord("tab"))), [.init(command: .cycleFocusForward, slot: .alternate)])
    }

    func testDuplicateStoredTriggersFirstCommandWins() {
        var o = KeyBindingOverrides.empty
        o.commands[.open] = .init(mouse: [mouse6])
        o.commands[.up] = .init(mouse: [mouse6])
        XCTAssertEqual(KeyBindings(overrides: o).command(for: mouse6), .open, "Command.allCases order")
    }

    func testValidate() {
        for text in ["cmd+q", "cmd+h", "opt+cmd+h", "cmd+m", "cmd+,", "cmd+`", "tab", "shift+tab", "esc"] {
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .alternate), .reserved, text)
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .primary), .reserved, text)
        }
        for text in ["x", "shift+x", "space", "return", "enter", "delete", "shift+delete", "fn+delete",
                     "shift+fn+delete", "down", "up", "shift+left", "shift+right"] {
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .primary), .editsTextAsPrimary, text)
            XCTAssertNil(KeyBindings.validate(.key(chord(text)), as: .alternate), text)
        }
        XCTAssertNil(KeyBindings.validate(.key(chord("F6")), as: .primary))
        XCTAssertNil(KeyBindings.validate(.key(chord("shift+F6")), as: .primary))
        XCTAssertNil(KeyBindings.validate(.key(chord("ctrl+return")), as: .primary))
        XCTAssertNil(KeyBindings.validate(.key(chord("opt+down")), as: .primary))
        XCTAssertNil(KeyBindings.validate(.key(chord("opt+cmd+b")), as: .primary))
        XCTAssertNil(KeyBindings.validate(.mouse(mouse6), as: .mouse))
        XCTAssertEqual(KeyBindings.validate(.mouse(mouse6), as: .primary), .wrongSlot)
        XCTAssertEqual(KeyBindings.validate(.key(chord("cmd+k")), as: .mouse), .wrongSlot)
    }

    func testCollisionFollowsTheChord() {
        XCTAssertEqual(KeyBindings.defaults.collidesWithTextEditing,
                       [.open, .up, .moveToTrash, .deletePermanently, .back, .forward, .rename, .duplicate,
                        .togglePreviewPane])   // ⌥P types "π" (P3-07)
        var o = KeyBindingOverrides.empty
        o.setPrimary(chord("opt+cmd+d"), for: .duplicate)
        o.setPrimary(chord("cmd+d"), for: .newFolder)
        let b = KeyBindings(overrides: o)
        XCTAssertFalse(b.collidesWithTextEditing.contains(.duplicate))
        XCTAssertTrue(b.collidesWithTextEditing.contains(.newFolder))
    }

    /// Word/line movement and Cocoa emacs keys belong to a text field being edited: a primary rebound onto one is
    /// disabled there (and its key goes to the field editor) instead of hijacking the cursor movement.
    func testTextSystemChordsCollideWhenRebound() {
        let texts = ["opt+left", "opt+right", "shift+opt+left", "opt+up", "shift+opt+down", "cmd+left", "shift+cmd+right",
                     "shift+cmd+up", "ctrl+left", "opt+delete", "opt+fn+delete", "ctrl+delete", "cmd+fn+delete",
                     "ctrl+a", "ctrl+e", "ctrl+k", "ctrl+t", "shift+ctrl+f"]
        for text in texts {
            XCTAssertTrue(KeyMap.textEditingChords.contains(chord(text)), text)
            var o = KeyBindingOverrides.empty
            o.setPrimary(chord(text), for: .newFolder)
            XCTAssertEqual(KeyBindings(overrides: o).primary(.newFolder), chord(text), "still allowed as a primary: \(text)")
            XCTAssertTrue(KeyBindings(overrides: o).collidesWithTextEditing.contains(.newFolder), text)
        }
        for text in ["opt+cmd+b", "ctrl+cmd+k", "F6", "ctrl+opt+left"] {
            XCTAssertFalse(KeyMap.textEditingChords.contains(chord(text)), text)
        }
    }

    func testUses() {
        let b = KeyBindings.defaults
        XCTAssertEqual(b.uses(of: .key(chord("cmd+["))), [.init(command: .back, slot: .primary)])
        XCTAssertEqual(b.uses(of: .key(chord("delete"))), [.init(command: .back, slot: .alternate)])
        XCTAssertEqual(b.uses(of: .mouse(mouse5)), [.init(command: .forward, slot: .mouse)])
        XCTAssertEqual(b.uses(of: .key(chord("opt+cmd+k"))), [])
    }

    // MARK: editing

    func testEditsBackToDefaultsLeaveNoEntry() {
        var o = KeyBindingOverrides.empty
        o.setPrimary(chord("opt+cmd+b"), for: .back)
        XCTAssertNotNil(o.commands[.back])
        o.setPrimary(chord("cmd+["), for: .back)
        XCTAssertNil(o.commands[.back])
        o.removeMouse(mouse4, from: .back)
        XCTAssertEqual(o.commands[.back], .init(mouse: []))
        o.reassign(.mouse(mouse4), to: .back, as: .mouse)
        XCTAssertEqual(o, .empty)
    }

    func testClearPrimaryStoresUnbound() {
        var o = KeyBindingOverrides.empty
        o.setPrimary(nil, for: .duplicate)
        XCTAssertEqual(o.commands[.duplicate], .init(primary: .unbound))
        XCTAssertNil(KeyBindings(overrides: o).primary(.duplicate))
    }

    func testReassignMovesTheTriggerFromEveryOtherUser() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("cmd+d")), to: .newFolder, as: .primary)
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.newFolder), chord("cmd+d"))
        XCTAssertNil(b.primary(.duplicate))
        o.reassign(.mouse(mouse4), to: .up, as: .mouse)
        let b2 = KeyBindings(overrides: o)
        XCTAssertEqual(b2.mouse(.up), [mouse4])
        XCTAssertEqual(b2.mouse(.back), [])
        XCTAssertEqual(b2.command(for: mouse4), .up)
    }

    func testReassignRemovesTheTriggerFromTheSameCommandsOtherSlot() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("opt+left")), to: .back, as: .primary)
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.back), chord("opt+left"))
        XCTAssertFalse(b.alternates(.back).contains(chord("opt+left")))
    }

    func testReassignAddsAlternatesWithoutDuplicates() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("ctrl+b")), to: .back, as: .alternate)
        o.reassign(.key(chord("ctrl+b")), to: .back, as: .alternate)
        XCTAssertEqual(KeyBindings(overrides: o).alternates(.back), KeyMap.alternates(.back) + [chord("ctrl+b")])
        o.removeAlternate(chord("ctrl+b"), from: .back)
        XCTAssertEqual(o, .empty)
    }

    func testInvalidEditsAndFixedCommandsAreIgnored() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("cmd+q")), to: .back, as: .primary)
        o.reassign(.key(chord("x")), to: .back, as: .primary)
        o.reassign(.key(chord("fn+delete")), to: .moveToTrash, as: .primary)
        o.setPrimary(chord("down"), for: .open)
        o.reassign(.mouse(mouse6), to: .back, as: .alternate)
        o.reassign(.key(chord("ctrl+e")), to: .cancelOperation, as: .alternate)
        o.setPrimary(chord("opt+cmd+e"), for: .cycleFocusForward)
        XCTAssertEqual(o, .empty)
    }

    func testReset() {
        var o = KeyBindingOverrides.empty
        o.setPrimary(nil, for: .back)
        o.setPrimary(nil, for: .forward)
        o.reset(.back)
        XCTAssertNil(o.commands[.back])
        XCTAssertNotNil(o.commands[.forward])
    }

    /// Review of the branch: ↺ on a command whose default was reassigned must not leave two commands on one trigger.
    func testResetTakesBackTheDefaultsFromWhoeverHoldsThem() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("cmd+[")), to: .up, as: .primary)
        o.reassign(.key(chord("delete")), to: .open, as: .alternate)
        o.reassign(.mouse(mouse4), to: .forward, as: .mouse)
        o.reset(.back)
        let b = KeyBindings(overrides: o)
        XCTAssertNil(o.commands[.back])
        XCTAssertEqual(b.uses(of: .key(chord("cmd+["))), [.init(command: .back, slot: .primary)])
        XCTAssertEqual(b.uses(of: .key(chord("delete"))), [.init(command: .back, slot: .alternate)])
        XCTAssertEqual(b.uses(of: .mouse(mouse4)), [.init(command: .back, slot: .mouse)])
        XCTAssertNil(b.primary(.up), "Up gives ⌘[ back and is left unbound, as after a reassign")
        XCTAssertEqual(b.mouse(.forward), [mouse5])
        XCTAssertNil(o.commands[.forward], "Forward is back to its defaults")
    }

    func testResolvedListsDropRepeatedEntries() {
        var o = KeyBindingOverrides.empty
        o.commands[.refresh] = .init(alternates: [chord("F5"), chord("F5")], mouse: [mouse6, mouse6])
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.alternates(.refresh), [chord("F5")])
        XCTAssertEqual(b.mouse(.refresh), [mouse6])
    }

    /// Fixed (non-command) menu items: Show Sidebar ⌃⌘S, Enter Full Screen ⌃⌘F, Help ⌘? (⇧⌘/).
    func testFixedMenuItemChordsAreReserved() {
        for text in ["ctrl+cmd+s", "ctrl+cmd+f", "shift+cmd+/"] {
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .primary), .reserved, text)
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .alternate), .reserved, text)
        }
        XCTAssertTrue(Set(KeyBindings.fixedMenuChords.values).isSubset(of: KeyBindings.reservedChords))
    }

    /// ⌥/⇧ + a character or space types a character (⌥L is @ on a German layout), so it can't be a menu shortcut.
    func testOptionCharacterPrimariesAreRejected() {
        for text in ["opt+l", "opt+shift+l", "opt+5", "opt+space", "opt+shift+space", "opt+["] {
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .primary), .editsTextAsPrimary, text)
            XCTAssertNil(KeyBindings.validate(.key(chord(text)), as: .alternate), text)
        }
        for text in ["opt+cmd+l", "ctrl+opt+l", "ctrl+l", "opt+down", "opt+F5"] {
            XCTAssertNil(KeyBindings.validate(.key(chord(text)), as: .primary), text)
        }
    }

    func testDispatcherUsesCustomAlternates() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("ctrl+b")), to: .back, as: .alternate)
        o.removeAlternate(chord("delete"), from: .back)
        let d = KeyDispatcher(returnKey: .rename, bindings: KeyBindings(overrides: o))
        XCTAssertEqual(d.command(for: chord("ctrl+b"), in: .content), .back)
        XCTAssertNil(d.command(for: chord("delete"), in: .content))
        XCTAssertEqual(d.command(for: chord("return"), in: .content), .rename, "Return → Rename still applies")
        XCTAssertNil(d.command(for: chord("ctrl+b"), in: .fieldEditor))
    }

    func testFieldEditorDisablesWhateverNowCollides() {
        var o = KeyBindingOverrides.empty
        o.setPrimary(chord("opt+cmd+d"), for: .duplicate)
        o.setPrimary(chord("cmd+d"), for: .newFolder)
        let collides = KeyBindings(overrides: o).collidesWithTextEditing
        let s = CommandState(selectionCount: 1)
        XCTAssertTrue(CommandAvailability.isEnabled(.duplicate, focus: .fieldEditor, state: s, collidesWithTextEditing: collides))
        XCTAssertFalse(CommandAvailability.isEnabled(.newFolder, focus: .fieldEditor, state: s, collidesWithTextEditing: collides))
    }
}
