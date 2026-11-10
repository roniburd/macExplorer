import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

/// P4-03: the command palette (⌘⇧P) over a real browser window on a Sandbox folder. Rows run through the target
/// window's responder chain; no system pasteboard, no panels, files only in the harness sandbox.
@MainActor final class CommandPaletteTests: XCTestCase {
    override func tearDown() async throws {
        CommandPaletteController.shown?.close()
        try await super.tearDown()
    }

    func testPaletteRunsCommandThroughResponderChainOfTargetWindow() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt")
        let window = try await ui.openBrowserWindow()
        let palette = CommandPaletteController.show(over: window.window!, context: ui.context)
        XCTAssertEqual(palette.panel.accessibilityIdentifier(), AXID.palette)
        palette.setQuery("new folder")
        XCTAssertEqual(palette.visibleTitles.first, CommandTitles.title(.newFolder))
        XCTAssertEqual(palette.visibleItems.first?.subtitle, "⇧⌘N")
        palette.runSelected()
        XCTAssertFalse(palette.isOpen)
        try await ui.waitUntil("New Folder row") { window.probeRowNames.contains("New Folder") }
        XCTAssertEqual(ui.context.environment.settings.paletteRecent.first, "cmd:newFolder")
    }

    func testDisabledCommandsAreNotListed() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)
        let window = try await ui.openBrowserWindow()                // empty folder, nothing selected
        let palette = CommandPaletteController.show(over: window.window!, context: ui.context)
        palette.setQuery("rename")
        XCTAssertFalse(palette.visibleTitles.contains(CommandTitles.title(.rename)))
        palette.setQuery("")
        XCTAssertFalse(palette.visibleTitles.contains(CommandTitles.title(.showCommandPalette)), "the palette never lists itself")
        XCTAssertFalse(palette.visibleTitles.contains(CommandTitles.title(.moveToTrash)))
        XCTAssertTrue(palette.visibleTitles.contains(CommandTitles.title(.newFolder)))
        XCTAssertTrue(palette.visibleTitles.contains("Sort By › Name"), "submenu items carry their submenu")
        XCTAssertTrue(palette.visibleTitles.contains("View as Icons"))
        XCTAssertFalse(palette.visibleTitles.contains(CommandTitles.title(.compressZip)), "unshipped Phase 4 commands stay out")
        // A window without tabs (and no other window) lists no tab-switching commands; New Tab stays.
        for c: Command in [.nextTab, .previousTab, .moveTabToNewWindow, .mergeAllWindows] {
            XCTAssertFalse(palette.visibleTitles.contains(CommandTitles.title(c)), "\(c)")
        }
        XCTAssertTrue(palette.visibleTitles.contains(CommandTitles.title(.newTab)))
    }

    func testSelectionEnablesItemCommands() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt")
        let window = try await ui.openBrowserWindow()
        window.focus(.content)
        window.session.folder.select(.names(["a.txt"]))
        let palette = CommandPaletteController.show(over: window.window!, context: ui.context)
        palette.setQuery("rename")
        XCTAssertEqual(palette.visibleTitles.first, CommandTitles.title(.rename))
        palette.setQuery("dup")
        XCTAssertEqual(palette.visibleTitles.first, CommandTitles.title(.duplicate))
        palette.runSelected()
        try await ui.waitUntil("duplicate") { window.probeRowNames.contains("a copy.txt") }
        XCTAssertTrue(ui.exists("a.txt"))
    }

    func testGoToRecentLocationNavigatesAndIsRemembered() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)
        let projects = try ui.dir("Projects")
        try ui.file("Projects/inside.txt")
        let settings = ui.context.environment.settings
        settings.recentLocations = [projects.path(percentEncoded: false)]
        let window = try await ui.openBrowserWindow()
        let palette = CommandPaletteController.show(over: window.window!, context: ui.context)
        palette.setQuery("go proj")
        let first = try XCTUnwrap(palette.visibleItems.first)
        XCTAssertEqual(first.title, "Go to Projects")
        XCTAssertEqual(first.target, .location(projects))
        palette.runSelected()
        try await ui.waitUntil("Projects shown") { window.probeRowNames == ["inside.txt"] }
        XCTAssertEqual(settings.paletteRecent.first, PaletteTarget.location(projects).encoded)
        // The next palette lists it first on an empty query (MRU).
        let again = CommandPaletteController.show(over: window.window!, context: ui.context)
        XCTAssertEqual(again.visibleItems.first?.target, .location(projects))
    }

    func testEscapeClosesAndSecondShowToggles() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)
        let window = try await ui.openBrowserWindow()
        let palette = CommandPaletteController.show(over: window.window!, context: ui.context)
        XCTAssertTrue(palette.isOpen)
        XCTAssertTrue(palette.panel.isVisible)
        palette.panel.cancelOperation(nil)
        XCTAssertFalse(palette.isOpen)
        XCTAssertFalse(palette.panel.isVisible)
        XCTAssertNil(CommandPaletteController.shown)
        XCTAssertEqual(ui.context.environment.settings.paletteRecent, [], "closing runs nothing")
        let second = CommandPaletteController.show(over: window.window!, context: ui.context)
        XCTAssertTrue(second.isOpen)
        let third = CommandPaletteController.show(over: window.window!, context: ui.context)
        XCTAssertTrue(third === second && !second.isOpen, "⌘⇧P while open closes it")
    }

    func testMenuItemSelectorOpensThePaletteFromTheContentPane() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)
        let window = try await ui.openBrowserWindow()
        let action = Selector(Command.showCommandPalette.selectorName)
        let target = try XCTUnwrap(CommandPaletteController.target(for: action, in: window.window!))
        XCTAssertTrue(target is CommandHandlingViewController)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: nil))
        XCTAssertTrue(CommandPaletteController.shown?.isOpen ?? false)
        // From the address bar's field editor too (the palette opens from any focus).
        CommandPaletteController.shown?.close()
        window.addressBar.beginEditing()
        let fromEditor = try XCTUnwrap(CommandPaletteController.target(for: action, in: window.window!))
        XCTAssertTrue(NSApp.sendAction(action, to: fromEditor, from: nil))
        XCTAssertTrue(CommandPaletteController.shown?.isOpen ?? false)
    }

    func testPaletteTitlesAreUniqueAndGoMenuHasTheItem() throws {
        let commands = Command.allCases.filter { CommandAvailability.isShipped($0) && !MainMenuBuilder.notInMenu.contains($0) }
        let titles = commands.map { CommandTitles.paletteTitle($0) }
        let duplicates = Dictionary(grouping: zip(titles, commands), by: \.0).filter { $0.value.count > 1 }
        XCTAssertEqual(duplicates.mapValues { $0.map(\.1) }, [:])
        XCTAssertEqual(CommandTitles.paletteTitle(.groupByName), "Group By › Name")
        XCTAssertEqual(CommandTitles.paletteTitle(.copyName), "Copy Path As › Name")
        XCTAssertEqual(CommandTitles.paletteTitle(.stopSearch), "Stop Search", "no repeated submenu name")
        let go = MainMenuBuilder.build().items.first { $0.identifier?.rawValue == "macx.menu.go" }?.submenu
        let item = try XCTUnwrap(go?.items.first { $0.identifier?.rawValue == "macx.menu.showCommandPalette" })
        XCTAssertEqual(item.title, "Command Palette…")
        XCTAssertEqual(item.keyEquivalent, "p")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func testHighlightBoldsMatchedCharacters() {
        let text = PaletteRowView.highlighted("New Folder", [0, 4])
        let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        XCTAssertEqual(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, bold)
        XCTAssertEqual(text.attribute(.font, at: 4, effectiveRange: nil) as? NSFont, bold)
        XCTAssertNotEqual(text.attribute(.font, at: 1, effectiveRange: nil) as? NSFont, bold)
    }
}
