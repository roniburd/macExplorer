import XCTest
import AppKit
@testable import UI
import Core

@MainActor
final class KeyBindingsRoutingTests: XCTestCase {
    override func tearDown() async throws {
        ActiveKeyBindings.current = .defaults
        try await super.tearDown()
    }

    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
    }

    private func item(_ command: Command, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == "macx.menu.\(command.rawValue)" { return item }
            if let sub = item.submenu, let found = self.item(command, in: sub) { return found }
        }
        return nil
    }

    /// Every key equivalent on a non-command menu item (Show Sidebar, Enter Full Screen, Help…) is reserved, so no
    /// rebinding can be shadowed by it or take it away.
    func testFixedMenuItemKeyEquivalentsAreReserved() {
        _ = NSApplication.shared
        var found: [KeyChord] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub) }
                let id = item.identifier?.rawValue ?? ""
                guard !item.keyEquivalent.isEmpty,
                      !(id.hasPrefix("macx.menu.") && Command(rawValue: String(id.dropFirst("macx.menu.".count))) != nil)
                else { continue }
                var modifiers: KeyModifiers = []
                let mask = item.keyEquivalentModifierMask
                if mask.contains(.command) { modifiers.insert(.command) }
                if mask.contains(.option) { modifiers.insert(.option) }
                if mask.contains(.control) { modifiers.insert(.control) }
                if mask.contains(.shift) { modifiers.insert(.shift) }
                var key = item.keyEquivalent
                if key == "?" { key = "/"; modifiers.insert(.shift) }      // ⌘? is ⇧⌘/
                let chord = KeyChord(.character(key.lowercased()), modifiers)
                found.append(chord)
                XCTAssertTrue(KeyBindings.reservedChords.contains(chord), "\(item.title): \(chord)")
            }
        }
        walk(MainMenuBuilder.build())
        XCTAssertEqual(Set(found), Set(KeyBindings.fixedMenuChords.values))
    }

    func testApplyKeyEquivalentsSetsChangesAndClears() throws {
        _ = NSApplication.shared
        let menu = MainMenuBuilder.build()
        var o = KeyBindingOverrides.empty
        o.setPrimary(KeyChord(parsing: "opt+cmd+b"), for: .back)
        o.setPrimary(nil, for: .duplicate)
        o.setPrimary(KeyChord(parsing: "opt+cmd+t"), for: .openInTerminal)
        MainMenuBuilder.applyKeyEquivalents(KeyBindings(overrides: o), to: menu)
        let back = try XCTUnwrap(item(.back, in: menu))
        XCTAssertEqual(back.keyEquivalent, "b")
        XCTAssertEqual(back.keyEquivalentModifierMask, [.option, .command])
        XCTAssertEqual(try XCTUnwrap(item(.duplicate, in: menu)).keyEquivalent, "")
        XCTAssertEqual(try XCTUnwrap(item(.openInTerminal, in: menu)).keyEquivalent, "t")
        MainMenuBuilder.applyKeyEquivalents(.defaults, to: menu)
        XCTAssertEqual(back.keyEquivalent, "[")
        XCTAssertEqual(back.keyEquivalentModifierMask, .command)
    }

    /// Review (P3-09..13): the menu-less Phase 3 commands have main-menu items, so a primary assigned in Settings ›
    /// Shortcuts becomes their key equivalent and the key performs the command (primaries fire only through the menu).
    func testPrimaryOnPhase3CommandsPerformsThroughTheMenu() throws {
        _ = NSApplication.shared
        final class Target: NSObject {
            var hits: [String] = []
            @objc func macx_downloadForPreview(_ sender: Any?) { hits.append("download") }
            @objc func macx_renameSavedSearch(_ sender: Any?) { hits.append("rename") }
            @objc func macx_removeSavedSearch(_ sender: Any?) { hits.append("remove") }
        }
        let target = Target()
        let menu = MainMenuBuilder.build()
        var o = KeyBindingOverrides.empty
        o.setPrimary(KeyChord(parsing: "ctrl+opt+cmd+d"), for: .downloadForPreview)
        o.setPrimary(KeyChord(parsing: "ctrl+opt+cmd+r"), for: .renameSavedSearch)
        o.setPrimary(KeyChord(parsing: "ctrl+opt+cmd+x"), for: .removeSavedSearch)
        MainMenuBuilder.applyKeyEquivalents(KeyBindings(overrides: o), to: menu)
        for (command, key) in [(Command.downloadForPreview, "d"), (.renameSavedSearch, "r"), (.removeSavedSearch, "x")] {
            let menuItem = try XCTUnwrap(item(command, in: menu), "\(command) has a main-menu item")
            XCTAssertEqual(menuItem.keyEquivalent, key)
            XCTAssertEqual(menuItem.keyEquivalentModifierMask, [.control, .option, .command])
            menuItem.target = target
        }
        for (key, code) in [("d", UInt16(2)), ("r", 15), ("x", 7)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .command],
                                                       timestamp: 0, windowNumber: 0, context: nil, characters: key,
                                                       charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            XCTAssertTrue(menu.performKeyEquivalent(with: event), key)
        }
        XCTAssertEqual(target.hits, ["download", "rename", "remove"])
    }

    func testControllerTracksSettings() async throws {
        _ = NSApplication.shared
        let s = settings()
        let menu = MainMenuBuilder.build()
        let controller = KeyBindingsController(settings: s, menu: { menu })
        XCTAssertEqual(ActiveKeyBindings.current, .defaults)
        s.keyBindingOverrides.setPrimary(KeyChord(parsing: "opt+cmd+b"), for: .back)
        let deadline = ContinuousClock.now + .seconds(30)   // condition wait: generous on a starved runner
        while ActiveKeyBindings.current.primary(.back) != KeyChord(parsing: "opt+cmd+b") {
            guard ContinuousClock.now < deadline else { return XCTFail("bindings never updated") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(item(.back, in: menu)?.keyEquivalent, "b")
        withExtendedLifetime(controller) {}
    }

    func testFieldEditorRoutingFollowsRebinding() {
        let cmdD = KeyEvents.key(2, "d", [.command])
        XCTAssertEqual(FieldEditorKeyRouting.collidingCommand(for: cmdD), .duplicate)
        var o = KeyBindingOverrides.empty
        o.setPrimary(KeyChord(parsing: "opt+cmd+d"), for: .duplicate)
        ActiveKeyBindings.current = KeyBindings(overrides: o)
        XCTAssertNil(FieldEditorKeyRouting.collidingCommand(for: cmdD))
        o.setPrimary(KeyChord(parsing: "cmd+d"), for: .newFolder)
        ActiveKeyBindings.current = KeyBindings(overrides: o)
        XCTAssertEqual(FieldEditorKeyRouting.collidingCommand(for: cmdD), .newFolder)
    }

    func testKeyRouterUsesActiveAlternates() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(KeyChord(parsing: "ctrl+b")!), to: .back, as: .alternate)
        ActiveKeyBindings.current = KeyBindings(overrides: o)
        let ctrlB = KeyEvents.key(11, "\u{2}", ignoring: "b", [.control])
        XCTAssertEqual(KeyRouter.command(for: ctrlB, focus: .content, returnKey: .open), .back)
    }
}
