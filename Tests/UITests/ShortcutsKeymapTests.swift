import XCTest
import AppKit
import SwiftUI
@testable import UI
import Core
import MacxFS
import MacxFixtures

/// P4-02: Settings › Shortcuts preset picker, keymap import/export and the import problem report. Import and export
/// read and write only Sandbox files (never NSOpenPanel/NSSavePanel); the menus are built in memory.
@MainActor
final class ShortcutsKeymapTests: XCTestCase {
    private var sandbox: Sandbox!
    private let lanes = LanePool()

    override func setUp() async throws {
        sandbox = try Sandbox()
    }

    override func tearDown() async throws {
        ActiveKeyBindings.current = .defaults
        sandbox?.destroy()
    }

    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
    }
    private func k(_ s: String) -> KeyChord { KeyChord(parsing: s)! }
    private func doc(_ bindings: String, extra: String = "") -> Data {
        Data(#"{"format":"macexplorer-keymap","version":1,"base":"explorer",\#(extra)"bindings":\#(bindings)}"#.utf8)
    }

    private func waitForActiveBindings(_ condition: @escaping @MainActor (KeyBindings) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)   // condition wait: generous on a starved runner
        while !condition(ActiveKeyBindings.current) {
            guard ContinuousClock.now < deadline else { return XCTFail("active bindings never updated") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: presets

    func testPresetPickerChoicesAndSelection() {
        let s = settings()
        let m = ShortcutsModel(settings: s)
        XCTAssertEqual(ShortcutsModel.presetChoices, [.preset(.explorer), .preset(.finder), .custom])
        XCTAssertEqual(ShortcutsModel.presetChoices.map(ShortcutsModel.title), ["Explorer (default)", "Finder", "Custom (edited)"])
        XCTAssertEqual(m.presetChoice, .preset(.explorer))
        m.applyPreset(.finder)
        XCTAssertEqual(m.presetChoice, .preset(.finder))
        XCTAssertEqual(s.returnKey, .rename)
        XCTAssertEqual(s.keyBindings.primary(.focusAddressBar), k("shift+cmd+g"))
        _ = m.apply(.key(k("opt+cmd+n")), to: .newWindow, as: .primary, reassigning: false)
        XCTAssertEqual(m.presetChoice, .custom, "an edit on top of a preset shows Custom")
        m.applyPreset(.explorer)
        XCTAssertEqual(s.keyBindingOverrides, .empty)
        XCTAssertEqual(s.returnKey, .open)
    }

    func testPresetChangeUpdatesMenusAndRoutingLive() async throws {
        _ = NSApplication.shared
        let s = settings()
        let menu = MainMenuBuilder.build()
        let controller = KeyBindingsController(settings: s, menu: { menu })
        ShortcutsModel(settings: s).applyPreset(.finder)
        try await waitForActiveBindings { $0.primary(.open) == KeyChord(parsing: "cmd+o") }
        let open = try XCTUnwrap(MenuValidationTests.find(.open, in: menu))
        XCTAssertEqual(open.keyEquivalent, "o")
        XCTAssertEqual(open.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(MenuValidationTests.find(.rename, in: menu)?.keyEquivalent, "", "Finder has no rename key")
        withExtendedLifetime(controller) {}
    }

    // MARK: import / export

    func testImportExportThroughSandboxFiles() async throws {
        let a = settings()
        let model = ShortcutsModel(settings: a)
        _ = model.apply(.key(k("opt+cmd+c")), to: .copyAsPath, as: .primary, reassigning: true)
        _ = model.apply(.key(k("ctrl+r")), to: .refresh, as: .alternate, reassigning: false)
        a.returnKey = .rename
        let url = sandbox.url("k.json")
        try await model.exportKeymap(to: url, lanes: lanes)
        XCTAssertTrue(sandbox.contains(url))
        XCTAssertEqual(try Data(contentsOf: url), a.exportKeymap())

        let b = settings()
        let other = ShortcutsModel(settings: b)
        let result = await other.importKeymap(from: url, lanes: lanes)
        XCTAssertEqual(result, .imported(warnings: []))
        XCTAssertTrue(b.keyBindings.sameTriggers(as: a.keyBindings))
        XCTAssertEqual(b.returnKey, .rename)
        XCTAssertEqual(other.presetChoice, .custom)
    }

    func testExportReplacesAnExistingSandboxFile() async throws {
        let url = try sandbox.createFile("k.json", contents: Data("old".utf8))
        let s = settings()
        try await ShortcutsModel(settings: s).exportKeymap(to: url, lanes: lanes)
        XCTAssertEqual(try Data(contentsOf: url), s.exportKeymap())
    }

    /// Review Focus 3: a colliding import is rejected with the offending pairs listed and changes nothing; unknown
    /// commands are skipped with a warning.
    func testImportReportsConflictsReservedAndUnknown() async throws {
        let s = settings()
        let model = ShortcutsModel(settings: s)
        _ = model.apply(.key(k("ctrl+r")), to: .refresh, as: .alternate, reassigning: false)
        let before = s.keyBindingOverrides

        let bad = try sandbox.createFile("bad.json", contents: doc(#"{"newFolder":{"primary":"cmd+l"},"undo":{"primary":"cmd+q"}}"#))
        let result = await model.importKeymap(from: bad, lanes: lanes)
        XCTAssertEqual(result, .failed(.invalid(.issues([
            .conflict(trigger: .key(k("cmd+l")), commands: [.focusAddressBar, .newFolder]),
            .reserved(chord: k("cmd+q"), command: .undo),
        ]))))
        XCTAssertEqual(s.keyBindingOverrides, before, "a rejected import changes nothing")
        guard case .failed(let failure) = result else { return XCTFail() }
        let report = ShortcutsModel.report(failure)
        XCTAssertEqual(report.summary, "This keymap can’t be used. Nothing was changed.")
        XCTAssertEqual(report.details, [
            "⌘L is used by \(MainMenuTitles.title(.focusAddressBar)), \(MainMenuTitles.title(.newFolder)).",
            "⌘Q is reserved by macOS or MacExplorer (\(MainMenuTitles.title(.undo))).",
        ])

        let unknown = try sandbox.createFile("unknown.json", contents: doc(#"{"teleport":{"primary":"opt+cmd+t"},"duplicate":{"primary":null}}"#))
        let ok = await model.importKeymap(from: unknown, lanes: lanes)
        XCTAssertEqual(ok, .imported(warnings: [.unknownCommand("teleport")]))
        XCTAssertNil(s.keyBindings.primary(.duplicate))
        XCTAssertEqual(ShortcutsModel.message(KeymapWarning.unknownCommand("teleport")),
                       "Skipped “teleport”: not a command in this version of MacExplorer.")
    }

    func testImportOfMissingOrBadFiles() async throws {
        let model = ShortcutsModel(settings: settings())
        let missing = await model.importKeymap(from: sandbox.url("nope.json"), lanes: lanes)
        XCTAssertEqual(missing, .failed(.unreadable))
        let junk = try sandbox.createFile("junk.json", contents: Data("not json".utf8))
        let notKeymap = await model.importKeymap(from: junk, lanes: lanes)
        XCTAssertEqual(notKeymap, .failed(.invalid(.notAKeymap)))
        let huge = try sandbox.createFile("huge.json", contents: Data(count: ShortcutsModel.maxKeymapFileSize + 1))
        let tooLarge = await model.importKeymap(from: huge, lanes: lanes)
        XCTAssertEqual(tooLarge, .failed(.unreadable))
        // Every failure has words.
        let failures: [ShortcutsModel.KeymapImportFailure] = [
            .unreadable, .invalid(.notAKeymap), .invalid(.unsupportedVersion(2)), .invalid(.unknownBase("vim")),
            .invalid(.invalidChord(command: "refresh", text: "hyper+r")), .invalid(.issues([])),
        ]
        for f in failures { XCTAssertFalse(ShortcutsModel.report(f).summary.isEmpty, "\(f)") }
        XCTAssertFalse(ShortcutsModel.message(KeymapWarning.fixedCommand(.cancelOperation)).isEmpty)
        XCTAssertFalse(ShortcutsModel.message(KeymapIssue.notAPrimary(chord: k("a"), command: .copy)).isEmpty)
    }

    /// Review Focus 3 (UI half): an imported text-editing chord as a primary is accepted, shows in the menu, and is
    /// disabled while a field editor has focus so the key reaches the text.
    func testCustomPrimaryCollidingWithTextEditingIsDisabledInFieldEditor() async throws {
        try ShellHarness.requireWindowServer()
        let s = settings()
        let menu = MainMenuBuilder.build()
        let controller = KeyBindingsController(settings: s, menu: { menu })
        let file = try sandbox.createFile("edit.json", contents: doc(#"{"newFolder":{"primary":"cmd+shift+left"}}"#))
        let result = await ShortcutsModel(settings: s).importKeymap(from: file, lanes: lanes)
        XCTAssertEqual(result, .imported(warnings: []))
        try await waitForActiveBindings { $0.primary(.newFolder) == KeyChord(parsing: "cmd+shift+left") }
        XCTAssertTrue(ActiveKeyBindings.current.collidesWithTextEditing.contains(.newFolder))
        XCTAssertEqual(MenuValidationTests.find(.newFolder, in: menu)?.keyEquivalentModifierMask, [.command, .shift])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(MenuValidation.isEnabled(.newFolder, window: window, state: CommandState(), focus: .content))
        XCTAssertTrue(MenuValidation.blockedByFieldEditor(.newFolder, window: window))
        window.makeFirstResponder(nil)
        XCTAssertTrue(MenuValidation.isEnabled(.newFolder, window: window, state: CommandState(), focus: .content))
        withExtendedLifetime(controller) {}
    }

    func testShortcutsPageRendersWithPresetAndImportControls() {
        let host = NSHostingView(rootView: ShortcutsSettingsView(settings: settings(), panels: nil, lanes: lanes))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 560)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
