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

    func testControllerTracksSettings() async throws {
        _ = NSApplication.shared
        let s = settings()
        let menu = MainMenuBuilder.build()
        let controller = KeyBindingsController(settings: s, menu: { menu })
        XCTAssertEqual(ActiveKeyBindings.current, .defaults)
        s.keyBindingOverrides.setPrimary(KeyChord(parsing: "opt+cmd+b"), for: .back)
        let deadline = ContinuousClock.now + .seconds(5)
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
