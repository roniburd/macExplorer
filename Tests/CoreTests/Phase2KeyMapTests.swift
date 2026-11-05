import XCTest
@testable import Core

final class Phase2KeyMapTests: XCTestCase {
    func chord(_ s: String) -> KeyChord { KeyChord(parsing: s)! }

    func testPhase2Primaries() {
        XCTAssertEqual(KeyMap.primary(.newTab), chord("cmd+t"))
        XCTAssertEqual(KeyMap.primary(.nextTab), chord("ctrl+tab"))
        XCTAssertEqual(KeyMap.primary(.previousTab), chord("ctrl+shift+tab"))
        XCTAssertEqual(KeyMap.primary(.showAllTabs), KeyChord(.character("\\"), [.command, .shift]))
        XCTAssertEqual(KeyMap.primary(.viewAsDetails), chord("cmd+1"))
        XCTAssertEqual(KeyMap.primary(.viewAsIcons), chord("cmd+2"))
        XCTAssertEqual(KeyMap.primary(.viewAsColumns), chord("cmd+3"))
        XCTAssertNil(KeyMap.primary(.quickLook), "Space is content-only so type-select and text fields keep it")
        XCTAssertEqual(KeyMap.alternates(.quickLook), [KeyChord(.space)])
        XCTAssertNil(KeyMap.primary(.copyPathTilde))
        XCTAssertEqual(KeyMap.primary(.copyAsPath), chord("cmd+shift+c"))   // Phase 1, unchanged
    }

    func testPrimariesAreUnique() {
        var seen: [KeyChord: Command] = [:]
        for c in Command.allCases {
            guard let k = KeyMap.primary(c) else { continue }
            XCTAssertNil(seen[k], "\(k) bound to both \(seen[k].map { "\($0)" } ?? "") and \(c)")
            seen[k] = c
        }
    }

    func testSelectorNames() {
        XCTAssertEqual(Command.newTab.selectorName, "newWindowForTab:")
        XCTAssertEqual(Command.nextTab.selectorName, "selectNextTab:")
        XCTAssertEqual(Command.previousTab.selectorName, "selectPreviousTab:")
        XCTAssertEqual(Command.showTabBar.selectorName, "toggleTabBar:")
        XCTAssertEqual(Command.showAllTabs.selectorName, "toggleTabOverview:")
        XCTAssertEqual(Command.moveTabToNewWindow.selectorName, "moveTabToNewWindow:")
        XCTAssertEqual(Command.mergeAllWindows.selectorName, "mergeAllWindows:")
        XCTAssertEqual(Command.quickLook.selectorName, "macx_quickLook:")
        XCTAssertEqual(Command.copyPathShellQuoted.selectorName, "macx_copyPathShellQuoted:")
    }

    func testWindowTabCommandsAreTheNSWindowActions() {
        XCTAssertEqual(Command.windowTabCommands,
                       [.newTab, .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows])
        for c in Command.allCases where !Command.windowTabCommands.contains(c) {
            XCTAssertFalse(c.isWindowTabCommand)
        }
    }

    func testDispatcherSpaceAndControlTab() {
        let d = KeyDispatcher(returnKey: .open)
        XCTAssertEqual(d.command(for: KeyChord(.space), in: .content), .quickLook)
        XCTAssertNil(d.command(for: KeyChord(.space), in: .sidebarFolders))
        XCTAssertNil(d.command(for: KeyChord(.space), in: .fieldEditor))
        XCTAssertNil(d.command(for: KeyChord(.tab, [.control]), in: .content), "⌃Tab is the next-tab menu key, never focus cycling")
        XCTAssertNil(d.command(for: KeyChord(.tab, [.control, .shift]), in: .sidebarFolders))
        XCTAssertEqual(d.command(for: KeyChord(.tab), in: .content), .cycleFocusForward)   // Phase 1 unchanged
    }

    func testAvailability() {
        func on(_ c: Command, _ f: FocusContext = .content, _ s: CommandState) -> Bool { CommandAvailability.isEnabled(c, focus: f, state: s) }
        XCTAssertFalse(on(.quickLook, .content, CommandState()))
        XCTAssertTrue(on(.quickLook, .content, CommandState(selectionCount: 1)))
        XCTAssertTrue(on(.quickLook, .content, CommandState(quickLookVisible: true)), "Space closes an open panel with nothing selected")
        XCTAssertFalse(on(.quickLook, .sidebarFolders, CommandState(selectionCount: 1)))
        XCTAssertFalse(on(.openInNewTab, .content, CommandState(selectionCount: 2, selectedFolderCount: 0)))
        XCTAssertTrue(on(.openInNewTab, .content, CommandState(selectionCount: 2, selectedFolderCount: 1)))
        XCTAssertTrue(on(.openInNewTab, .sidebarFavorites, CommandState()))
        XCTAssertTrue(on(.groupByKind, .content, CommandState(viewMode: .details)))
        XCTAssertFalse(on(.groupByKind, .content, CommandState(viewMode: .icons)))
        XCTAssertFalse(on(.toggleFolderSizes, .content, CommandState(viewMode: .columns)))
        XCTAssertTrue(on(.newTab, .sidebarLocations, CommandState()))
        for c in [Command.copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted] {
            XCTAssertEqual(on(c, .content, CommandState(selectionCount: 1)), on(.copyAsPath, .content, CommandState(selectionCount: 1)))
            XCTAssertFalse(on(c, .content, CommandState()))
        }
    }

    func testFocusContextIsSidebar() {
        XCTAssertEqual([FocusContext.content, .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot,
                        .addressBar, .fieldEditor].map(\.isSidebar),
                       [false, true, true, true, true, false, false])
    }

    func testQuickLookIsNotATextCollision() {
        XCTAssertFalse(KeyMap.collidesWithTextEditing.contains(.quickLook))
        XCTAssertFalse(KeyMap.collidesWithTextEditing.contains(.nextTab))
    }
}
