import XCTest
import AppKit
@testable import UI
import Core

@MainActor
final class ShortcutsModelTests: XCTestCase {
    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
    }
    private func chord(_ t: String) -> KeyChord { KeyChord(parsing: t)! }

    func testDisplayStrings() {
        XCTAssertEqual(chord("opt+cmd+delete").displayString, "⌥⌘⌫")
        XCTAssertEqual(chord("ctrl+opt+shift+cmd+up").displayString, "⌃⌥⇧⌘↑")
        XCTAssertEqual(chord("cmd+[").displayString, "⌘[")
        XCTAssertEqual(chord("shift+cmd+n").displayString, "⇧⌘N")
        XCTAssertEqual(chord("F2").displayString, "F2")
        XCTAssertEqual(chord("fn+delete").displayString, "⌦")
        XCTAssertEqual(chord("space").displayString, "Space")
        XCTAssertEqual(chord("return").displayString, "↩")
        XCTAssertEqual(MouseButton(number: 3)!.displayName, "Mouse 4")
        XCTAssertEqual(Trigger.mouse(MouseButton(number: 4)!).displayString, "Mouse 5")
    }

    func testGroupsListEveryCommandOnce() {
        let all = ShortcutsModel.allGroups.flatMap(\.commands)
        XCTAssertEqual(all.count, Command.allCases.count)
        XCTAssertEqual(Set(all), Set(Command.allCases))
        // P4-01: a Phase 4 command is listed (and rebindable) once its task ships it.
        let shipped = Command.allCases.filter(CommandAvailability.isShipped)
        let listed = ShortcutsModel.groups.flatMap(\.commands)
        XCTAssertEqual(listed.count, shipped.count)
        XCTAssertEqual(Set(listed), Set(shipped))
        XCTAssertFalse(ShortcutsModel.groups.contains { $0.commands.isEmpty })
    }

    func testPhase4CommandsHaveAGroupAndATitle() {
        func group(of c: Command) -> String? { ShortcutsModel.allGroups.first { $0.commands.contains(c) }?.id }
        for c: Command in [.compressZip, .compressAppleArchive, .extractHere, .batchRename, .editTags] {
            XCTAssertEqual(group(of: c), "file", "\(c)")
        }
        XCTAssertEqual(group(of: .showCommandPalette), "navigation", "next to its Go menu siblings")
        let m = ShortcutsModel(settings: settings())
        for c in CommandAvailability.phase4Commands { XCTAssertFalse(m.title(c).isEmpty, "\(c)") }
    }

    /// P3-07: the Phase 3 commands are listed (so they can be rebound) and found by title and key.
    func testPhase3CommandsAreRebindable() {
        func group(of c: Command) -> String? { ShortcutsModel.groups.first { $0.commands.contains(c) }?.id }
        XCTAssertEqual(group(of: .togglePreviewPane), "view")
        XCTAssertEqual(group(of: .downloadForPreview), "view")
        XCTAssertEqual(group(of: .openContainingFolder), "navigation")
        for c: Command in [.saveSearch, .stopSearch, .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac,
                           .searchModeName, .searchModeContents] {
            XCTAssertEqual(group(of: c), "search", "\(c)")
        }
        XCTAssertEqual(group(of: .renameSavedSearch), "sidebar")
        XCTAssertEqual(group(of: .removeSavedSearch), "sidebar")
        let s = settings()
        let m = ShortcutsModel(settings: s)
        XCTAssertEqual(m.groups(matching: "⌥P").flatMap(\.commands), [.togglePreviewPane])
        XCTAssertEqual(m.groups(matching: "opt+cmd+r").flatMap(\.commands), [.openContainingFolder])
        XCTAssertTrue(m.groups(matching: "preview pane").flatMap(\.commands).contains(.togglePreviewPane))
        XCTAssertEqual(m.apply(.key(chord("ctrl+cmd+p")), to: .togglePreviewPane, as: .primary, reassigning: false), .saved)
        XCTAssertEqual(s.keyBindings.primary(.togglePreviewPane), chord("ctrl+cmd+p"))
        XCTAssertEqual(m.apply(.key(chord("ctrl+cmd+g")), to: .saveSearch, as: .primary, reassigning: false), .saved)
        XCTAssertEqual(s.keyBindings.primary(.saveSearch), chord("ctrl+cmd+g"))
        m.reset(.togglePreviewPane)
        XCTAssertEqual(s.keyBindings.primary(.togglePreviewPane), chord("opt+p"))
    }

    // QA polish: ⌥P (a typing chord, so not allowed as a user primary) can be recorded again for Show Preview Pane,
    // whose default it is; other commands still can't take it as their primary.
    func testRecordingACommandsOwnTypingDefaultRestoresIt() {
        let s = settings()
        let m = ShortcutsModel(settings: s)
        XCTAssertEqual(m.apply(.key(chord("ctrl+cmd+p")), to: .togglePreviewPane, as: .primary, reassigning: false), .saved)
        XCTAssertEqual(m.apply(.key(chord("opt+p")), to: .togglePreviewPane, as: .primary, reassigning: false), .saved)
        XCTAssertEqual(s.keyBindings.primary(.togglePreviewPane), chord("opt+p"))
        XCTAssertFalse(m.isModified(.togglePreviewPane), "recording the default stores no override")
        XCTAssertTrue(s.keyBindings.collidesWithTextEditing.contains(.togglePreviewPane), "the field-editor guard still applies")
        XCTAssertEqual(m.apply(.key(chord("opt+p")), to: .saveSearch, as: .primary, reassigning: false), .rejected(.editsTextAsPrimary))
        XCTAssertEqual(m.apply(.key(chord("opt+q")), to: .togglePreviewPane, as: .primary, reassigning: false), .rejected(.editsTextAsPrimary))
        XCTAssertNil(KeyBindings.validate(.key(chord("opt+p")), as: .primary, for: .togglePreviewPane))
        XCTAssertEqual(KeyBindings.validate(.key(chord("opt+p")), as: .primary, for: .saveSearch), .editsTextAsPrimary)
    }

    func testSearchMatchesTitleGlyphTextAndMouse() {
        let m = ShortcutsModel(settings: settings())
        XCTAssertEqual(m.groups(matching: "").flatMap(\.commands).count, Command.allCases.filter(CommandAvailability.isShipped).count)
        XCTAssertTrue(m.groups(matching: "back").flatMap(\.commands).contains(.back))
        XCTAssertTrue(m.groups(matching: "⌘[").flatMap(\.commands).contains(.back))
        XCTAssertTrue(m.groups(matching: "cmd+[").flatMap(\.commands).contains(.back))
        XCTAssertEqual(m.groups(matching: "mouse 5").flatMap(\.commands), [.forward])
        XCTAssertEqual(m.groups(matching: "zzzz"), [])
    }

    func testApplySavesRejectsAndReportsConflicts() {
        let s = settings()
        let m = ShortcutsModel(settings: s)
        XCTAssertEqual(m.apply(.key(chord("opt+cmd+b")), to: .back, as: .primary, reassigning: false), .saved)
        XCTAssertEqual(s.keyBindings.primary(.back), chord("opt+cmd+b"))
        XCTAssertTrue(m.isModified(.back))
        XCTAssertEqual(m.apply(.key(chord("cmd+q")), to: .back, as: .primary, reassigning: false), .rejected(.reserved))
        XCTAssertEqual(m.apply(.key(chord("x")), to: .back, as: .primary, reassigning: false), .rejected(.editsTextAsPrimary))
        XCTAssertEqual(m.apply(.key(chord("cmd+d")), to: .newFolder, as: .primary, reassigning: false),
                       .conflict([.init(command: .duplicate, slot: .primary)]))
        XCTAssertEqual(s.keyBindings.primary(.duplicate), chord("cmd+d"), "a conflict saves nothing")
        XCTAssertEqual(m.apply(.key(chord("cmd+d")), to: .newFolder, as: .primary, reassigning: true), .saved)
        XCTAssertNil(s.keyBindings.primary(.duplicate))
        XCTAssertEqual(m.apply(.mouse(MouseButton(number: 5)!), to: .up, as: .mouse, reassigning: false), .saved)
        XCTAssertEqual(s.keyBindings.command(for: MouseButton(number: 5)!), .up)
    }

    func testReapplyingTheSameTriggerToTheSameSlotIsNotAConflict() {
        let m = ShortcutsModel(settings: settings())
        XCTAssertEqual(m.apply(.key(chord("cmd+[")), to: .back, as: .primary, reassigning: false), .saved)
        XCTAssertFalse(m.isModified(.back))
    }

    func testRemoveClearResetAndResetAll() {
        let s = settings()
        let m = ShortcutsModel(settings: s)
        m.remove(.mouse(MouseButton(number: 3)!), from: .back)
        XCTAssertNil(s.keyBindings.command(for: MouseButton(number: 3)!))
        m.clearPrimary(.forward)
        XCTAssertNil(s.keyBindings.primary(.forward))
        m.reset(.back)
        XCTAssertEqual(s.keyBindings.command(for: MouseButton(number: 3)!), .back)
        m.resetAll()
        XCTAssertEqual(s.keyBindingOverrides, .empty)
    }

    /// Spec §6: a trigger two commands hold (stored by hand, or left by an older build) is flagged on both rows.
    func testConflictsInStoredDataShowOnBothRows() {
        let s = settings()
        var o = KeyBindingOverrides.empty
        o.commands[.refresh] = .init(alternates: [chord("F3")])
        o.commands[.up] = .init(primary: .chord(chord("cmd+[")))
        s.keyBindingOverrides = o
        let m = ShortcutsModel(settings: s)
        XCTAssertEqual(m.conflicts(for: .refresh), [.key(chord("F3")): [.init(command: .focusSearch, slot: .alternate)]])
        XCTAssertEqual(m.conflicts(for: .focusSearch), [.key(chord("F3")): [.init(command: .refresh, slot: .alternate)]])
        XCTAssertEqual(m.conflicts(for: .back), [.key(chord("cmd+[")): [.init(command: .up, slot: .primary)]])
        XCTAssertEqual(m.conflicts(for: .up), [.key(chord("cmd+[")): [.init(command: .back, slot: .primary)]])
        XCTAssertEqual(m.conflicts(for: .forward), [:])
        XCTAssertEqual(ShortcutsModel(settings: settings()).conflicts(for: .back), [:], "defaults have no conflicts")
    }

    func testResetThroughTheModelLeavesNoSharedTrigger() {
        let s = settings()
        let m = ShortcutsModel(settings: s)
        XCTAssertEqual(m.apply(.key(chord("cmd+d")), to: .rename, as: .primary, reassigning: true), .saved)
        m.reset(.duplicate)
        XCTAssertEqual(s.keyBindings.uses(of: .key(chord("cmd+d"))), [.init(command: .duplicate, slot: .primary)])
        XCTAssertEqual(m.conflicts(for: .rename), [:])
    }

    func testMessages() {
        let m = ShortcutsModel(settings: settings())
        XCTAssertEqual(ShortcutsModel.message(.reserved), "Reserved by macOS or MacExplorer.")
        XCTAssertEqual(ShortcutsModel.message(.editsTextAsPrimary),
                       "Menu shortcuts need ⌘ or ⌃, or an F key. ⌥ alone works only with keys that don't type.")
        XCTAssertEqual(m.conflictMessage(.key(chord("cmd+d")), [.init(command: .duplicate, slot: .primary)]),
                       "⌘D is used by Duplicate.")
    }

    func testRecorderOutcomes() {
        typealias R = ShortcutRecorder
        XCTAssertEqual(R.outcome(for: KeyEvents.key(53, "\u{1b}"), acceptsMouse: true, backspaceClears: true), .cancel)
        XCTAssertEqual(R.outcome(for: KeyEvents.backspace(), acceptsMouse: false, backspaceClears: true), .clear)
        XCTAssertEqual(R.outcome(for: KeyEvents.backspace(), acceptsMouse: true, backspaceClears: false),
                       .trigger(.key(KeyChord(.backspace))))
        XCTAssertEqual(R.outcome(for: KeyEvents.key(11, "b", [.option, .command]), acceptsMouse: false, backspaceClears: true),
                       .trigger(.key(chord("opt+cmd+b"))))
        XCTAssertEqual(R.outcome(for: MouseEvents.otherDown(5), acceptsMouse: true, backspaceClears: false),
                       .trigger(.mouse(MouseButton(number: 5)!)))
        XCTAssertNil(R.outcome(for: MouseEvents.otherDown(5), acceptsMouse: false, backspaceClears: true))
        XCTAssertNil(R.outcome(for: MouseEvents.otherDown(2), acceptsMouse: true, backspaceClears: false))
    }

    private func click(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Spec §5: clicking elsewhere cancels without swallowing the click; events for another window cancel too.
    func testRecorderDecisions() {
        typealias R = ShortcutRecorder
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            XCTAssertEqual(R.decision(for: click(type), acceptsMouse: true, backspaceClears: true, inRecordingWindow: true),
                           .cancelAndPass)
        }
        let a = KeyEvents.key(0, "a")
        XCTAssertEqual(R.decision(for: a, acceptsMouse: true, backspaceClears: false, inRecordingWindow: false), .cancelAndPass)
        XCTAssertEqual(R.decision(for: MouseEvents.otherDown(5), acceptsMouse: true, backspaceClears: false,
                                  inRecordingWindow: false), .cancelAndPass)
        XCTAssertEqual(R.decision(for: a, acceptsMouse: true, backspaceClears: false, inRecordingWindow: true),
                       .finish(.trigger(.key(KeyChord(.character("a"))))))
        XCTAssertNil(R.decision(for: MouseEvents.otherDown(2), acceptsMouse: true, backspaceClears: false,
                                inRecordingWindow: true))
    }

    func testRecorderClickCancelsAndPassesTheClickThrough() {
        let recorder = ShortcutRecorder()
        var outcomes: [ShortcutRecorder.Outcome] = []
        recorder.start(in: nil, acceptsMouse: true, backspaceClears: false) { outcomes.append($0) }
        let event = click(.leftMouseDown)
        XCTAssertTrue(recorder.handle(event) === event, "the click is not swallowed")
        XCTAssertEqual(outcomes, [.cancel])
        XCTAssertFalse(recorder.isRecording)
        // Recording has ended: the next key is not captured.
        let key = KeyEvents.key(0, "a")
        XCTAssertTrue(recorder.handle(key) === key)
        XCTAssertEqual(outcomes, [.cancel])
    }

    func testRecorderCapturesKeyAndSwallowsIt() {
        let recorder = ShortcutRecorder()
        var outcomes: [ShortcutRecorder.Outcome] = []
        recorder.start(in: nil, acceptsMouse: true, backspaceClears: false) { outcomes.append($0) }
        XCTAssertNil(recorder.handle(KeyEvents.key(0, "a")))
        XCTAssertEqual(outcomes, [.trigger(.key(KeyChord(.character("a"))))])
        XCTAssertFalse(recorder.isRecording)
    }

    func testRecorderCancelsForOtherWindowAndOnResignKey() throws {
        try ShellHarness.requireWindowServer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let recorder = ShortcutRecorder()
        var outcomes: [ShortcutRecorder.Outcome] = []

        recorder.start(in: window, acceptsMouse: true, backspaceClears: false) { outcomes.append($0) }
        let elsewhere = KeyEvents.key(0, "a")      // windowNumber 0: not the Settings window
        XCTAssertTrue(recorder.handle(elsewhere) === elsewhere, "another window's key is not swallowed")
        XCTAssertEqual(outcomes, [.cancel])

        recorder.start(in: window, acceptsMouse: true, backspaceClears: false) { outcomes.append($0) }
        XCTAssertNil(recorder.handle(KeyEvents.key(0, "a", window: window)))
        XCTAssertEqual(outcomes, [.cancel, .trigger(.key(KeyChord(.character("a"))))])

        recorder.start(in: window, acceptsMouse: true, backspaceClears: false) { outcomes.append($0) }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(outcomes.last, .cancel)
        XCTAssertFalse(recorder.isRecording)

        recorder.start(in: window, acceptsMouse: true, backspaceClears: false) { outcomes.append($0) }
        recorder.stop()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(outcomes.count, 3, "stop() removes the observers and never calls done")
    }
}
