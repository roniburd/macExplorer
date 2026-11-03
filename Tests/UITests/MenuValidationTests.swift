import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class MenuValidationTests: XCTestCase {
    func testWithoutFieldEditorUsesCommandAvailability() {
        var state = CommandState()
        XCTAssertFalse(MenuValidation.isEnabled(.moveToTrash, window: nil, state: state, focus: .content))
        state.selectionCount = 1
        XCTAssertTrue(MenuValidation.isEnabled(.moveToTrash, window: nil, state: state, focus: .content))
        XCTAssertTrue(MenuValidation.isEnabled(.newFolder, window: nil, state: CommandState(), focus: .content))
        XCTAssertEqual(MenuValidation.isEnabled(.removeFromFavorites, window: nil, state: state, focus: .sidebarFavorites),
                       CommandAvailability.isEnabled(.removeFromFavorites, focus: .sidebarFavorites, state: state))
    }

    func testFieldEditorDisablesCollidingCommands() throws {
        try ShellHarness.requireWindowServer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(string: "x")
        window.contentView?.addSubview(field)
        XCTAssertFalse(MenuValidation.isFieldEditorActive(in: window))
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(MenuValidation.isFieldEditorActive(in: window))
        var state = CommandState(selectionCount: 1, canGoBack: true)
        state.canGoUp = true
        for command in KeyMap.collidesWithTextEditing {
            XCTAssertFalse(MenuValidation.isEnabled(command, window: window, state: state, focus: .content), "\(command)")
            XCTAssertTrue(MenuValidation.blockedByFieldEditor(command, window: window))
        }
        XCTAssertTrue(MenuValidation.isEnabled(.newFolder, window: window, state: state, focus: .content))
        XCTAssertTrue(MenuValidation.isEnabled(.copy, window: window, state: state, focus: .content))
        XCTAssertFalse(MenuValidation.blockedByFieldEditor(.copy, window: window))
    }

    // MARK: MainMenuBuilder (P1-29)

    static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
    }

    static func find(_ c: Command, in menu: NSMenu) -> NSMenuItem? {
        items(in: menu).first { $0.identifier?.rawValue == "macx.menu.\(c.rawValue)" }
    }

    static func item(at path: [String], in menu: NSMenu) -> NSMenuItem? {
        var current: NSMenu? = menu
        var found: NSMenuItem?
        for title in path {
            found = current?.items.first { $0.title == title || $0.submenu?.title == title }
            current = found?.submenu
        }
        return found
    }

    func testTopLevelMenus() {
        let menu = MainMenuBuilder.build()
        XCTAssertEqual(menu.items.compactMap { $0.submenu?.title },
                       ["macExplorer", "File", "Edit", "View", "Go", "Window", "Help"])
    }

    func testEveryCommandHasExactlyOneMainMenuItem() {
        let all = Self.items(in: MainMenuBuilder.build())
        for command in Command.allCases where !MainMenuBuilder.notInMenu.contains(command) {
            let matching = all.filter { $0.action == Selector(command.selectorName) }
            XCTAssertEqual(matching.count, 1, "\(command) needs one main-menu item")
            guard let item = matching.first else { continue }
            XCTAssertNil(item.target, "\(command) follows the first responder")
            XCTAssertEqual(item.identifier?.rawValue, "macx.menu.\(command.rawValue)")
            XCTAssertFalse(item.title.isEmpty)
        }
        XCTAssertEqual(MainMenuBuilder.notInMenu, [.cancelOperation], "Esc is a key, not a menu command")
    }

    func testKeyEquivalentsComeFromKeyMapPrimaries() throws {
        let menu = MainMenuBuilder.build()
        for command in Command.allCases {
            guard let item = Self.find(command, in: menu) else { continue }
            if let chord = KeyMap.primary(command) {
                let expected = try XCTUnwrap(MainMenuBuilder.keyEquivalent(for: chord))
                XCTAssertEqual(item.keyEquivalent, expected.key, "\(command)")
                XCTAssertEqual(item.keyEquivalentModifierMask, expected.modifiers, "\(command)")
            } else {
                XCTAssertEqual(item.keyEquivalent, "", "\(command) has no primary")
            }
        }
    }

    func testKeyEquivalentRendering() {
        func fn(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
        let menu = MainMenuBuilder.build()
        func check(_ c: Command, _ key: String, _ mods: NSEvent.ModifierFlags, line: UInt = #line) {
            let item = Self.find(c, in: menu)
            XCTAssertEqual(item?.keyEquivalent, key, "\(c)", line: line)
            XCTAssertEqual(item?.keyEquivalentModifierMask, mods, "\(c)", line: line)
        }
        check(.moveToTrash, "\u{8}", [.command])
        check(.deletePermanently, "\u{8}", [.command, .option])
        check(.toggleHidden, ".", [.command, .shift])
        check(.newFolder, "n", [.command, .shift])
        check(.rename, fn(NSF2FunctionKey), [])
        check(.open, fn(NSDownArrowFunctionKey), [.command])
        check(.up, fn(NSUpArrowFunctionKey), [.command])
        check(.back, "[", [.command])
        check(.moveItemHere, "v", [.command, .option])
        check(.redo, "z", [.command, .shift])
        check(.copyAsPath, "c", [.command, .shift])
        check(.eject, "e", [.command])
    }

    func testNoTwoItemsShareAKeyEquivalent() {
        var seen: [String: String] = [:]
        for item in Self.items(in: MainMenuBuilder.build()) where !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
            XCTAssertNil(seen[key], "'\(item.title)' and '\(seen[key] ?? "")' share a key equivalent")
            seen[key] = item.title
        }
    }

    func testMenuTitlesUsedByScenarios() {
        let menu = MainMenuBuilder.build()
        XCTAssertEqual(Self.item(at: ["View", "Sort By", "Size"], in: menu)?.action, Selector(Command.sortBySize.selectorName))
        XCTAssertEqual(Self.item(at: ["Edit", "Copy as Path"], in: menu)?.action, Selector(Command.copyAsPath.selectorName))
        XCTAssertEqual(Self.item(at: ["Edit", "Paste"], in: menu)?.action, Selector(Command.paste.selectorName))
        XCTAssertEqual(Self.item(at: ["File", "Duplicate"], in: menu)?.action, Selector(Command.duplicate.selectorName))
        XCTAssertEqual(Self.item(at: ["File", "Move to Trash"], in: menu)?.action, Selector(Command.moveToTrash.selectorName))
        XCTAssertEqual(Self.item(at: ["File", "Delete Permanently…"], in: menu)?.action,
                       Selector(Command.deletePermanently.selectorName))
        XCTAssertEqual(Self.item(at: ["View", "as Icons"], in: menu)?.action, Selector(Command.viewAsIcons.selectorName))
        XCTAssertEqual(Self.item(at: ["Go", "Back"], in: menu)?.action, Selector(Command.back.selectorName))
        XCTAssertEqual(Self.item(at: ["Window", "Operations"], in: menu)?.action, Selector(Command.showOperations.selectorName))
    }

    func testStandardAppItems() {
        let menu = MainMenuBuilder.build()
        let quit = Self.item(at: ["macExplorer", "Quit macExplorer"], in: menu)
        XCTAssertEqual(quit?.action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(quit?.keyEquivalent, "q")
        XCTAssertNotNil(Self.item(at: ["macExplorer", "Services"], in: menu)?.submenu)
        XCTAssertEqual(Self.item(at: ["Window", "Minimize"], in: menu)?.action, #selector(NSWindow.performMiniaturize(_:)))
        XCTAssertNotNil(Self.items(in: menu).first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
        XCTAssertNotNil(Self.items(in: menu).first { $0.action == #selector(NSSplitViewController.toggleSidebar(_:)) })
    }

    func testInstallSetsSpecialMenus() throws {
        let app = NSApplication.shared
        let previous = (app.mainMenu, app.windowsMenu, app.helpMenu, app.servicesMenu)
        defer {
            app.mainMenu = previous.0
            if let w = previous.1 { app.windowsMenu = w }
            app.helpMenu = previous.2
            app.servicesMenu = previous.3
        }
        MainMenuBuilder.install(in: app)
        XCTAssertEqual(app.mainMenu?.items.compactMap { $0.submenu?.title }.first, "macExplorer")
        XCTAssertEqual(app.windowsMenu?.title, "Window")
        XCTAssertEqual(app.helpMenu?.title, "Help")
        XCTAssertEqual(app.servicesMenu?.title, "Services")
    }

    func testMainMenuItemsValidateThroughTheFocusedPane() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let controller = try await h.openWindow()
        let menu = MainMenuBuilder.build()
        let back = try XCTUnwrap(Self.find(.back, in: menu))
        let trash = try XCTUnwrap(Self.find(.moveToTrash, in: menu))
        let content = try XCTUnwrap(controller.contentPane)
        XCTAssertFalse(content.validateMenuItem(back), "no history yet")
        controller.navigate(to: h.url("sub"))
        try await h.waitUntil("in sub") { controller.session.folder.directory.lastPathComponent == "sub" }
        XCTAssertTrue(content.validateMenuItem(back))
        XCTAssertFalse(content.validateMenuItem(trash), "nothing selected")
    }

    func testWindowForwardsCommandsToTheContentWhenNothingInThePanesIsFocused() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let window = try XCTUnwrap(controller.window)
        window.makeFirstResponder(nil)
        let selector = Selector(Command.refresh.selectorName)
        let target = controller.supplementalTarget(forAction: selector, sender: nil)
        XCTAssertTrue(target as AnyObject? === controller.contentPane)
        XCTAssertNil(controller.supplementalTarget(forAction: #selector(NSApplication.terminate(_:)), sender: nil))
    }
}
