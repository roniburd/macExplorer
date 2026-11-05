import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class CommandBarTests: XCTestCase {
    private func identifiers(_ bar: CommandBarView) -> [String] {
        bar.controls.compactMap { $0.accessibilityIdentifier() }
    }

    func testItemsInSpecOrderWithIdentifiersAndLabels() {
        let bar = CommandBarView()
        XCTAssertEqual(identifiers(bar), [
            CommandBarView.newMenuID,
            AXID.commandBarItem(.cut), AXID.commandBarItem(.copy), AXID.commandBarItem(.paste),
            AXID.commandBarItem(.rename), AXID.commandBarItem(.share), AXID.commandBarItem(.moveToTrash),
            CommandBarView.sortMenuID, CommandBarView.viewMenuID, CommandBarView.moreMenuID,
            AXID.commandBarItem(.properties),
        ])
        for control in bar.controls {
            XCTAssertFalse((control.accessibilityLabel() ?? "").isEmpty, "\(control.accessibilityIdentifier())")
        }
    }

    func testButtonsSendTheirCommandThroughTheResponderChain() throws {
        let bar = CommandBarView()
        for command in [Command.cut, .copy, .paste, .rename, .share, .moveToTrash, .properties] {
            let button = try XCTUnwrap(bar.button(for: command), "\(command)")
            XCTAssertEqual(button.action, Selector(command.selectorName))
            XCTAssertNil(button.target)
        }
    }

    func testMenusHoldTheSpecItems() {
        let bar = CommandBarView()
        func actions(_ menu: NSMenu) -> [Command] {
            menu.items.compactMap { MenuValidation.command(for: $0.action) }
        }
        XCTAssertEqual(actions(bar.newMenu), [.newFolder, .newTextFile, .newEmptyFile])
        XCTAssertEqual(actions(bar.sortMenu), [.sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated,
                                               .sortAscending, .sortDescending])
        XCTAssertEqual(actions(bar.viewMenu), [.viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
                                               .densityCompact, .densityRegular, .densityComfortable,
                                               .toggleHidden, .toggleCommandBar])
        XCTAssertEqual(actions(bar.moreMenu), [.copyAsPath, .selectAll, .selectNone, .invertSelection,
                                               .openInTerminal, .revealInFinder])
        for menu in [bar.newMenu, bar.sortMenu, bar.viewMenu, bar.moreMenu] {
            for item in menu.items where item.action != nil && item.submenu == nil { XCTAssertNil(item.target) }
            for item in menu.items.compactMap(\.submenu).flatMap(\.items) { XCTAssertNil(item.target) }
        }
    }

    func testEnablementFollowsCommandAvailability() throws {
        let bar = CommandBarView()
        bar.update(state: CommandState(), focus: .content, shiftHeld: false)
        for command in [Command.cut, .copy, .paste, .rename, .share, .moveToTrash] {
            XCTAssertFalse(try XCTUnwrap(bar.button(for: command)).isEnabled, "\(command) with nothing selected")
        }
        XCTAssertTrue(try XCTUnwrap(bar.button(for: .properties)).isEnabled, "Properties of the current folder")
        XCTAssertTrue(bar.newButton.isEnabled)

        bar.update(state: CommandState(selectionCount: 2, canPaste: true), focus: .content, shiftHeld: false)
        for command in [Command.cut, .copy, .paste, .share, .moveToTrash, .properties] {
            XCTAssertTrue(try XCTUnwrap(bar.button(for: command)).isEnabled, "\(command)")
        }
        XCTAssertFalse(try XCTUnwrap(bar.button(for: .rename)).isEnabled, "rename needs exactly one item")

        bar.update(state: CommandState(selectionCount: 1, canPaste: true, folderIsReadOnly: true), focus: .content, shiftHeld: false)
        XCTAssertFalse(bar.newButton.isEnabled, "read-only folder")
        XCTAssertFalse(try XCTUnwrap(bar.button(for: .paste)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(bar.button(for: .moveToTrash)).isEnabled)
        XCTAssertTrue(try XCTUnwrap(bar.button(for: .copy)).isEnabled)
    }

    func testShiftTurnsDeleteIntoDeletePermanently() throws {
        let bar = CommandBarView()
        let state = CommandState(selectionCount: 1)
        bar.update(state: state, focus: .content, shiftHeld: true)
        let delete = bar.deleteButton
        XCTAssertEqual(delete.action, Selector(Command.deletePermanently.selectorName))
        XCTAssertEqual(delete.accessibilityIdentifier(), AXID.commandBarItem(.deletePermanently))
        XCTAssertEqual(delete.accessibilityLabel(), "Delete Permanently…", "it asks for confirmation")
        XCTAssertTrue(delete.isEnabled)
        XCTAssertTrue(bar.button(for: .deletePermanently) === delete)
        bar.update(state: state, focus: .content, shiftHeld: false)
        XCTAssertEqual(delete.action, Selector(Command.moveToTrash.selectorName))
        XCTAssertEqual(delete.accessibilityIdentifier(), AXID.commandBarItem(.moveToTrash))
        XCTAssertEqual(delete.accessibilityLabel(), "Delete")
    }

    func testSidebarFocusFollowsTheSidebarTable() throws {
        let bar = CommandBarView()
        let row = CommandState(selectionCount: 1, singleFolderSelected: true, canPaste: true)
        bar.update(state: row, focus: .sidebarFavorites, shiftHeld: false)
        XCTAssertTrue(bar.deleteButton.isEnabled, "Delete on a favorite = Remove from Favorites")
        XCTAssertFalse(try XCTUnwrap(bar.button(for: .cut)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(bar.button(for: .rename)).isEnabled)
        XCTAssertTrue(try XCTUnwrap(bar.button(for: .copy)).isEnabled)
        bar.update(state: row, focus: .sidebarFavorites, shiftHeld: true)
        XCTAssertFalse(bar.deleteButton.isEnabled, "⇧Del is disabled on Favorites")
        bar.update(state: row, focus: .sidebarLocations, shiftHeld: false)
        XCTAssertFalse(bar.deleteButton.isEnabled)
        XCTAssertFalse(bar.newButton.isEnabled)
        bar.update(state: row, focus: .sidebarFolders, shiftHeld: false)
        XCTAssertTrue(bar.deleteButton.isEnabled)
        XCTAssertTrue(try XCTUnwrap(bar.button(for: .rename)).isEnabled)
    }

    func testFieldEditorDisablesCollidingButtons() throws {
        try ShellHarness.requireWindowServer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bar = CommandBarView()
        let field = NSTextField(string: "x")
        window.contentView?.addSubview(bar)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        bar.update(state: CommandState(selectionCount: 1), focus: .content, shiftHeld: false)
        XCTAssertFalse(try XCTUnwrap(bar.button(for: .rename)).isEnabled, "F2 belongs to the text field")
        XCTAssertFalse(bar.deleteButton.isEnabled, "⌘⌫ belongs to the text field")
        XCTAssertTrue(try XCTUnwrap(bar.button(for: .copy)).isEnabled)
    }

    func testContentHostsTheCommandBarAndStatusBar() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt")
        let controller = try await h.openWindow()
        let content = try XCTUnwrap(controller.contentPane as? ContentViewController)
        XCTAssertTrue(content.commandBar.isDescendant(of: content.view))
        XCTAssertTrue(content.statusBar.isDescendant(of: content.view))
        XCTAssertFalse(try XCTUnwrap(content.commandBar.button(for: .copy)).isEnabled)
        content.session.folder.select(.set(IndexSet(integer: 0), cursor: 0))
        try await h.waitUntil("copy enabled") { content.commandBar.button(for: .copy)?.isEnabled == true }

        h.environment.settings.commandBarVisible = false
        try await h.waitUntil("command bar hidden") { content.commandBar.isHidden }
        h.environment.settings.commandBarVisible = true
        try await h.waitUntil("command bar shown") { !content.commandBar.isHidden }
    }

    func testToggleCommandBarCommand() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let content = try XCTUnwrap(controller.contentPane)
        let before = h.environment.settings.commandBarVisible
        _ = content.perform(Selector(Command.toggleCommandBar.selectorName), with: nil)
        XCTAssertEqual(h.environment.settings.commandBarVisible, !before)
    }
}
