import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

/// Builds the NSEvent a real ANSI keyboard produces (key codes as in P1-41's KeySynth).
@MainActor
enum KeyEvents {
    static func key(_ code: UInt16, _ characters: String, ignoring: String? = nil,
                    _ flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown, window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code)!
    }

    static func function(_ scalar: Int, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        let s = String(Character(UnicodeScalar(UInt32(scalar))!))
        return key(code, s, flags.union(.function), window: window)
    }

    static let forwardDelete = { function(NSDeleteFunctionKey, 117) }
    static let backspace = { key(51, "\u{7F}") }
    static let returnKey = { key(36, "\r") }
    static let tab = { key(48, "\t") }
    static let shiftTab = { key(48, "\u{19}", [.shift]) }
}

@MainActor
private final class RecordingHandler: CommandHandler {
    var performed: [Command] = []
    func canPerform(_ command: Command, target: CommandTarget) -> Bool { true }
    func perform(_ command: Command, target: CommandTarget, sender: Any?) { performed.append(command) }
}

@MainActor
private final class KeyPane: CommandHandlingViewController {
    var focus: FocusContext = .content
    override var focusContext: FocusContext { focus }
    override var commandTarget: CommandTarget? { .folder(URL(filePath: "/tmp/macx-tests-keys", directoryHint: .isDirectory)) }
    override func loadView() { view = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)) }
}

@MainActor
final class KeyEventTranslatorTests: XCTestCase {
    func testCharactersUseTheBaseCharacterLowercased() {
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(8, "c", [.command])), KeyChord(.character("c"), .command))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(8, "\u{3}", ignoring: "c", [.control])),
                       KeyChord(.character("c"), .control))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(45, "N", ignoring: "N", [.command, .shift])),
                       KeyChord(.character("n"), [.command, .shift]))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(2, "∂", ignoring: "d", [.option])),
                       KeyChord(.character("d"), .option), "⌥D types ∂ but the chord is opt+d")
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(33, "[", [.command])), KeyChord(.character("["), .command))
    }

    func testShiftedPunctuationKeepsTheUnshiftedKey() {
        // ⌘⇧. on a real keyboard reports ">" as charactersIgnoringModifiers; the key map says "shift+cmd+.".
        let event = KeyEvents.key(47, ">", ignoring: ">", [.command, .shift])
        XCTAssertEqual(KeyEventTranslator.chord(for: event), KeyChord(.character("."), [.command, .shift]))
    }

    func testSpecialKeys() {
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.returnKey()), KeyChord(.returnKey))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(36, "\r", [.option])), KeyChord(.returnKey, .option))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(76, "\u{3}")), KeyChord(.enter))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.tab()), KeyChord(.tab))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.shiftTab()), KeyChord(.tab, .shift))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(53, "\u{1B}")), KeyChord(.escape))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(49, " ")), KeyChord(.space))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.backspace()), KeyChord(.backspace))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(51, "\u{7F}", [.command])), KeyChord(.backspace, .command))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.forwardDelete()), KeyChord(.forwardDelete), "fn flag ignored")
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.function(NSDeleteFunctionKey, 117, [.shift])),
                       KeyChord(.forwardDelete, .shift))
    }

    func testArrowsIgnoreFunctionAndNumericPadFlags() {
        let left = KeyEvents.function(NSLeftArrowFunctionKey, 123, [.option, .numericPad])
        XCTAssertEqual(KeyEventTranslator.chord(for: left), KeyChord(.left, .option))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.function(NSUpArrowFunctionKey, 126, [.command, .numericPad])),
                       KeyChord(.up, .command))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.function(NSDownArrowFunctionKey, 125)), KeyChord(.down))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.function(NSRightArrowFunctionKey, 124)), KeyChord(.right))
    }

    func testFunctionKeys() {
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.function(NSF2FunctionKey, 120)), KeyChord(.function(2)))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.function(NSF5FunctionKey, 96)), KeyChord(.function(5)))
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.function(NSF4FunctionKey, 118, [.shift])),
                       KeyChord(.function(4), .shift))
    }

    func testCapsLockIsIgnored() {
        XCTAssertEqual(KeyEventTranslator.chord(for: KeyEvents.key(8, "C", ignoring: "C", [.command, .capsLock])),
                       KeyChord(.character("c"), .command))
    }

    func testNonKeyEventsAndEmptyCharactersGiveNil() {
        XCTAssertNil(KeyEventTranslator.chord(for: KeyEvents.key(255, "", ignoring: "")))
        let flags = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)
        XCTAssertNil(flags.flatMap { KeyEventTranslator.chord(for: $0) })
    }

    func testEveryAlternateRoundTripsThroughAnEvent() {
        // The events P1-41's KeySynth posts for each alternate must translate back to the same chord.
        let events: [(NSEvent, KeyChord)] = [
            (KeyEvents.returnKey(), KeyChord(.returnKey)),
            (KeyEvents.key(15, "R", ignoring: "r", [.shift, .command]), KeyChord(.character("r"), [.shift, .command])),
            (KeyEvents.key(7, "x", [.control]), KeyChord(.character("x"), .control)),
            (KeyEvents.key(16, "y", [.command]), KeyChord(.character("y"), .command)),
            (KeyEvents.function(NSF3FunctionKey, 99), KeyChord(.function(3))),
        ]
        for (event, chord) in events { XCTAssertEqual(KeyEventTranslator.chord(for: event), chord, "\(chord)") }
    }
}

@MainActor
final class KeyRouterTests: XCTestCase {
    private func makeWindow(_ pane: KeyPane) throws -> NSWindow {
        try ShellHarness.requireWindowServer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    func testAlternateSendsTheCommandThroughTheResponderChainFromTheView() throws {
        let pane = KeyPane()
        let handler = RecordingHandler()
        pane.handler = handler
        _ = try makeWindow(pane)
        // No key window in tests: the router still reaches the pane by walking up from the view.
        XCTAssertTrue(KeyRouter.handle(KeyEvents.forwardDelete(), focus: .content, returnKey: .open, from: pane.view))
        XCTAssertTrue(KeyRouter.handle(KeyEvents.function(NSDeleteFunctionKey, 117, [.shift]), focus: .content,
                                       returnKey: .open, from: pane.view))
        XCTAssertTrue(KeyRouter.handle(KeyEvents.backspace(), focus: .content, returnKey: .open, from: pane.view))
        XCTAssertTrue(KeyRouter.handle(KeyEvents.key(8, "c", [.control]), focus: .content, returnKey: .open, from: pane.view))
        XCTAssertTrue(KeyRouter.handle(KeyEvents.key(36, "\r", [.option]), focus: .content, returnKey: .open, from: pane.view))
        XCTAssertTrue(KeyRouter.handle(KeyEvents.key(53, "\u{1B}"), focus: .content, returnKey: .open, from: pane.view))
        XCTAssertEqual(handler.performed, [.moveToTrash, .deletePermanently, .back, .copy, .properties, .cancelOperation])
    }

    func testReturnFollowsTheReturnKeySetting() throws {
        let pane = KeyPane()
        let handler = RecordingHandler()
        pane.handler = handler
        _ = try makeWindow(pane)
        XCTAssertTrue(KeyRouter.handle(KeyEvents.returnKey(), focus: .content, returnKey: .open, from: pane.view))
        XCTAssertTrue(KeyRouter.handle(KeyEvents.returnKey(), focus: .content, returnKey: .rename, from: pane.view))
        pane.focus = .sidebarFolders
        XCTAssertTrue(KeyRouter.handle(KeyEvents.returnKey(), focus: .sidebarFolders, returnKey: .rename, from: pane.view))
        XCTAssertEqual(handler.performed, [.open, .rename, .open], "Return opens in the sidebar whatever the setting")
    }

    func testTabCyclesFocus() throws {
        let pane = KeyPane()
        let handler = RecordingHandler()
        pane.handler = handler
        _ = try makeWindow(pane)
        XCTAssertTrue(KeyRouter.handle(KeyEvents.tab(), focus: .content, returnKey: .open, from: pane.view))
        XCTAssertTrue(KeyRouter.handle(KeyEvents.shiftTab(), focus: .content, returnKey: .open, from: pane.view))
        XCTAssertEqual(handler.performed, [.cycleFocusForward, .cycleFocusBackward])
    }

    func testFavoritesDelIsRemoveFromFavorites() throws {
        let pane = KeyPane()
        pane.focus = .sidebarFavorites
        let handler = RecordingHandler()
        pane.handler = handler
        _ = try makeWindow(pane)
        XCTAssertTrue(KeyRouter.handle(KeyEvents.forwardDelete(), focus: .sidebarFavorites, returnKey: .open, from: pane.view))
        XCTAssertEqual(handler.performed, [.removeFromFavorites])
    }

    func testPrimariesUnmappedKeysAndTextFocusAreNotHandled() throws {
        let pane = KeyPane()
        let handler = RecordingHandler()
        pane.handler = handler
        _ = try makeWindow(pane)
        // Primaries belong to the menu (performKeyEquivalent), not to keyDown.
        XCTAssertFalse(KeyRouter.handle(KeyEvents.key(8, "c", [.command]), focus: .content, returnKey: .open, from: pane.view))
        XCTAssertFalse(KeyRouter.handle(KeyEvents.key(0, "a"), focus: .content, returnKey: .open, from: pane.view),
                       "plain letters are type-select")
        XCTAssertFalse(KeyRouter.handle(KeyEvents.function(NSLeftArrowFunctionKey, 123, [.numericPad]), focus: .content,
                                        returnKey: .open, from: pane.view), "plain arrows move the selection")
        XCTAssertFalse(KeyRouter.handle(KeyEvents.forwardDelete(), focus: .fieldEditor, returnKey: .open, from: pane.view))
        XCTAssertFalse(KeyRouter.handle(KeyEvents.backspace(), focus: .addressBar, returnKey: .open, from: pane.view))
        XCTAssertFalse(KeyRouter.handle(KeyEvents.key(8, "c", [.control], type: .keyUp), focus: .content, returnKey: .open,
                                        from: pane.view), "keyUp is ignored")
        XCTAssertEqual(handler.performed, [])
    }

    func testNoResponderMeansNotHandled() throws {
        try ShellHarness.requireWindowServer()
        let lonely = FocusableView(frame: .zero)   // no window, no pane, nothing implements macx_moveToTrash:
        XCTAssertFalse(KeyRouter.handle(KeyEvents.forwardDelete(), focus: .content, returnKey: .open, from: lonely))
    }
}

@MainActor
final class FocusCycleTests: XCTestCase {
    func testOrderIsSidebarAddressBarContent() {
        XCTAssertEqual(FocusCycle.next(after: .sidebarFavorites, forward: true), .addressBar)
        XCTAssertEqual(FocusCycle.next(after: .sidebarFolders, forward: true), .addressBar)
        XCTAssertEqual(FocusCycle.next(after: .sidebarLocations, forward: true), .addressBar)
        XCTAssertEqual(FocusCycle.next(after: .sidebarVolumeRoot, forward: true), .addressBar)
        XCTAssertEqual(FocusCycle.next(after: .addressBar, forward: true), .content)
        XCTAssertEqual(FocusCycle.next(after: .content, forward: true), .sidebarFavorites)
        XCTAssertEqual(FocusCycle.next(after: .content, forward: false), .addressBar)
        XCTAssertEqual(FocusCycle.next(after: .addressBar, forward: false), .sidebarFavorites)
        XCTAssertEqual(FocusCycle.next(after: .sidebarFavorites, forward: false), .content)
        XCTAssertEqual(FocusCycle.next(after: .fieldEditor, forward: true), .sidebarFavorites, "a field editor counts as content")
    }

    func testTabInTheContentMovesToTheSidebarAndShiftTabToTheAddressBar() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        controller.focus(.content)
        XCTAssertEqual(controller.probeFocus, .content)
        let contentView = try XCTUnwrap(controller.window?.firstResponder as? NSView)
        XCTAssertTrue(KeyRouter.handle(KeyEvents.tab(), focus: .content, returnKey: .open, from: contentView))
        XCTAssertTrue([.sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot].contains(controller.probeFocus),
                      "Tab: content → sidebar, got \(controller.probeFocus)")

        controller.focus(.content)
        var addressFocused = false
        controller.focusAddressBar = { addressFocused = true }
        XCTAssertTrue(KeyRouter.handle(KeyEvents.shiftTab(), focus: .content, returnKey: .open, from: contentView))
        XCTAssertTrue(addressFocused, "⇧Tab: content → address bar")
    }

    func testTabInTheSidebarMovesToTheAddressBar() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        controller.focus(.sidebarFavorites)
        let sidebar = try XCTUnwrap(controller.sidebarPane as? SidebarViewController)
        var addressFocused = false
        controller.focusAddressBar = { addressFocused = true }
        sidebar.outlineView.keyDown(with: KeyEvents.tab(window: controller.window))
        XCTAssertTrue(addressFocused, "Tab: sidebar → address bar")
        sidebar.outlineView.keyDown(with: KeyEvents.shiftTab(window: controller.window))
        XCTAssertEqual(controller.probeFocus, .content, "⇧Tab: sidebar → content")
    }

    func testTabLeavesTheSidebarWithNoRowSelected() async throws {
        let h = try await ShellHarness.make(self)
        h.environment.settings.autoRevealInTree = false
        let controller = try await h.openWindow()
        let sidebar = try XCTUnwrap(controller.sidebarPane as? SidebarViewController)
        controller.focus(.content)
        controller.focus(.sidebarFavorites)
        XCTAssertNil(sidebar.selectedItem)
        XCTAssertTrue(controller.window?.firstResponder === sidebar.outlineView)
        for command in [Command.newWindow, .closeWindow] {
            let item = NSMenuItem(title: "", action: Selector(command.selectorName), keyEquivalent: "")
            XCTAssertTrue(sidebar.validateMenuItem(item), "\(command) stays enabled")
        }
        var addressFocused = false
        controller.focusAddressBar = { addressFocused = true }
        sidebar.outlineView.keyDown(with: KeyEvents.tab(window: controller.window))
        XCTAssertTrue(addressFocused, "Tab: sidebar → address bar")
        controller.focus(.sidebarFavorites)
        sidebar.outlineView.keyDown(with: KeyEvents.shiftTab(window: controller.window))
        XCTAssertEqual(controller.probeFocus, .content, "⇧Tab: sidebar → content")
    }

    func testBackspaceInTheSidebarGoesBack() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let controller = try await h.openWindow()
        controller.navigate(to: h.url("sub"))
        try await h.waitUntil("in sub") { controller.session.folder.directory.lastPathComponent == "sub" }
        let sidebar = try XCTUnwrap(controller.sidebarPane as? SidebarViewController)
        controller.focus(.sidebarFavorites)
        sidebar.outlineView.keyDown(with: KeyEvents.backspace(window: controller.window))
        try await h.waitUntil("went back") {
            controller.session.folder.directory.standardizedFileURL.path == h.filesRoot.standardizedFileURL.path
        }
    }

    func testContentPlaceholderRoutesAlternates() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let controller = try await h.openWindow()
        controller.navigate(to: h.url("sub"))
        try await h.waitUntil("in sub") { controller.session.folder.directory.lastPathComponent == "sub" }
        controller.focus(.content)
        let view = try XCTUnwrap(controller.window?.firstResponder as? NSView)
        view.keyDown(with: KeyEvents.function(NSUpArrowFunctionKey, 126, [.option, .numericPad], window: controller.window))
        try await h.waitUntil("went up") {
            controller.session.folder.directory.standardizedFileURL.path == h.filesRoot.standardizedFileURL.path
        }
    }
}

extension KeyEvents {
    static func tab(window: NSWindow?) -> NSEvent { key(48, "\t", window: window) }
    static func shiftTab(window: NSWindow?) -> NSEvent { key(48, "\u{19}", [.shift], window: window) }
    static func backspace(window: NSWindow?) -> NSEvent { key(51, "\u{7F}", window: window) }
}
