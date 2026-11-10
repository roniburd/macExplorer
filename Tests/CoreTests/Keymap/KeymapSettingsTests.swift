import XCTest
import MacxFixtures
@testable import Core

/// P4-02: presets, import and export applied to `Settings` (Settings › Shortcuts and `--keymap`). Files are read and
/// written only in a Sandbox; no open/save panels.
@MainActor
final class KeymapSettingsTests: XCTestCase {
    private func settings() -> Settings {
        Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
    }
    private func k(_ s: String) -> KeyChord { KeyChord(parsing: s)! }

    func testPresetFollowsTheOverrides() {
        let s = settings()
        XCTAssertEqual(s.keymapPreset, .explorer)
        s.keyBindingOverrides.setPrimary(nil, for: .duplicate)
        XCTAssertNil(s.keymapPreset, "edited: no preset (Custom)")
        s.keyBindingOverrides = KeymapPreset.finder.overrides
        XCTAssertEqual(s.keymapPreset, .finder)
    }

    func testApplyingAPresetSetsItsKeysAndReturnKey() {
        let s = settings()
        s.keyBindingOverrides.setPrimary(nil, for: .duplicate)
        s.applyKeymapPreset(.finder)
        XCTAssertEqual(s.keyBindingOverrides, KeymapPreset.finder.overrides)
        XCTAssertEqual(s.returnKey, .rename, "Finder preset implies Return = Rename")
        XCTAssertEqual(s.keyBindings.primary(.open), k("cmd+o"))
        s.applyKeymapPreset(.explorer)
        XCTAssertEqual(s.keyBindingOverrides, .empty)
        XCTAssertEqual(s.returnKey, .open)
        XCTAssertEqual(s.keymapPreset, .explorer)
    }

    func testExportImportCarriesBindingsAndReturnKeyThroughASandboxFile() throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        let a = settings()
        a.applyKeymapPreset(.finder)
        a.keyBindingOverrides.reassign(.key(k("ctrl+r")), to: .refresh, as: .alternate)
        let url = try sandbox.createFile("k.json", contents: a.exportKeymap())
        let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(json.contains(#""returnKey" : "rename""#), json)

        let b = settings()
        XCTAssertEqual(try b.importKeymap(Data(contentsOf: url)), [])
        XCTAssertTrue(b.keyBindings.sameTriggers(as: a.keyBindings))
        XCTAssertEqual(b.returnKey, .rename)
    }

    /// Review fix: a user's stored binding on a chord that a later release gives to a new command as its default
    /// (⇧⌘P, Finder's Show Preview, now Command Palette…) wins; the new command starts with no primary, so there is
    /// no duplicate, and export → import round-trips.
    func testStoredOverrideBeatsANewlyAddedDefault() throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        let a = settings()
        a.keyBindingOverrides.setPrimary(k("shift+cmd+p"), for: .togglePreviewPane)
        XCTAssertEqual(a.keyBindings.primary(.togglePreviewPane), k("shift+cmd+p"))
        XCTAssertNil(a.keyBindings.primary(.showCommandPalette))
        XCTAssertEqual(a.keyBindings.uses(of: .key(k("shift+cmd+p"))),
                       [KeyBindings.Use(command: .togglePreviewPane, slot: .primary)])
        XCTAssertEqual(KeymapValidator.issues(a.keyBindingOverrides), [])
        let url = try sandbox.createFile("k.json", contents: a.exportKeymap())
        let b = settings()
        XCTAssertEqual(try b.importKeymap(Data(contentsOf: url)), [])
        XCTAssertTrue(b.keyBindings.sameTriggers(as: a.keyBindings))
        // An alternate holding it works the same way; an older command's default still conflicts (import rejects).
        var o = KeyBindingOverrides.empty
        o.commands[.refresh] = .init(alternates: [k("shift+cmd+p")])
        XCTAssertNil(KeyBindings(overrides: o).primary(.showCommandPalette))
        XCTAssertEqual(KeymapValidator.issues(o), [])
    }

    /// Review fix: a stored binding on a macOS chord (⌃↑, ⌘Space…) from before they were reserved keeps working;
    /// only new recordings and imports reject them.
    func testStoredSystemChordBindingKeepsWorking() {
        var o = KeyBindingOverrides.empty
        o.commands[.refresh] = .init(primary: .chord(k("ctrl+up")), alternates: [k("ctrl+down")])
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.refresh), k("ctrl+up"))
        XCTAssertEqual(b.alternates(.refresh), [k("ctrl+down")])
        XCTAssertEqual(b.alternateCommand(for: k("ctrl+down")), .refresh)
        XCTAssertEqual(KeyBindings.validate(.key(k("ctrl+up")), as: .primary), .reserved, "new recordings still refuse it")
        // App-reserved chords still fall back as before.
        o.commands[.refresh] = .init(primary: .chord(k("cmd+q")), alternates: [k("cmd+`")])
        XCTAssertEqual(KeyBindings(overrides: o).primary(.refresh), KeyMap.primary(.refresh))
        XCTAssertEqual(KeyBindings(overrides: o).alternates(.refresh), [])
    }

    func testImportWithoutReturnKeyKeepsTheSetting() throws {
        let s = settings()
        s.returnKey = .rename
        let data = Data(#"{"format":"macexplorer-keymap","version":1,"base":"explorer","bindings":{"duplicate":{"primary":null}}}"#.utf8)
        XCTAssertEqual(try s.importKeymap(data), [])
        XCTAssertEqual(s.returnKey, .rename)
        XCTAssertNil(s.keyBindings.primary(.duplicate))
        // An unknown returnKey value is ignored like an absent one.
        let odd = Data(#"{"format":"macexplorer-keymap","version":1,"returnKey":"explode","bindings":{}}"#.utf8)
        XCTAssertEqual(try s.importKeymap(odd), [])
        XCTAssertEqual(s.returnKey, .rename)
    }

    /// Review Focus 3: a rejected import changes nothing.
    func testRejectedImportKeepsThePreviousKeysAndReturnKey() {
        let s = settings()
        s.keyBindingOverrides.reassign(.key(k("ctrl+r")), to: .refresh, as: .alternate)
        let before = s.keyBindingOverrides
        let data = Data(#"{"format":"macexplorer-keymap","version":1,"returnKey":"rename","bindings":{"newFolder":{"primary":"cmd+l"}}}"#.utf8)
        XCTAssertThrowsError(try s.importKeymap(data)) {
            XCTAssertEqual($0 as? KeymapImportError,
                           .issues([.conflict(trigger: .key(self.k("cmd+l")), commands: [.focusAddressBar, .newFolder])]))
        }
        XCTAssertEqual(s.keyBindingOverrides, before)
        XCTAssertEqual(s.returnKey, .open)
    }

    func testImportWarnsAboutUnknownCommandsAndAppliesTheRest() throws {
        let s = settings()
        let data = Data(#"{"format":"macexplorer-keymap","version":1,"bindings":{"teleport":{"primary":"opt+cmd+t"},"duplicate":{"primary":null}}}"#.utf8)
        XCTAssertEqual(try s.importKeymap(data), [.unknownCommand("teleport")])
        XCTAssertNil(s.keyBindings.primary(.duplicate))
    }

    func testLaunchOptionKeymapParsesAndNeedsStateDir() throws {
        let o = try LaunchOptions.parse(["macExplorer", "--root", "/tmp/macx-scenario-x", "--state-dir", "/tmp/macx-scenario-x/state",
                                         "--keymap", "/tmp/macx-scenario-x/k.json"])
        XCTAssertEqual(o.keymapFile?.lastPathComponent, "k.json")
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--keymap", "/tmp/macx-scenario-x/k.json"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .stateDirectoryRequired)
        }
        XCTAssertNil(try LaunchOptions.parse(["macExplorer"]).keymapFile)
    }
}
