import XCTest
import AppKit
@testable import UI
@testable import Core

@MainActor final class CopyPathMenuTests: XCTestCase {
    func testSubmenuItemsAndSelectors() {
        let menu = CopyPathMenu.make()
        XCTAssertEqual(menu.title, "Copy Path As")
        XCTAssertEqual(menu.items.map(\.title), ["POSIX Path", "~ Path", "File URL", "Name", "Quoted for Shell"])
        XCTAssertEqual(menu.items.map { $0.action.map(NSStringFromSelector) },
                       [Command.copyAsPath, .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted].map(\.selectorName))
        XCTAssertTrue(menu.items.allSatisfy { $0.target == nil }, "nil-targeted: follows the first responder")
        XCTAssertTrue(menu.items.allSatisfy { $0.keyEquivalent.isEmpty }, "⇧⌘C stays on Copy as Path")
    }

    func testStylesMatchCommands() {
        XCTAssertEqual(CopyPathMenu.commands.map { FileCommandController.pathStyle(for: $0) },
                       [.posix, .tilde, .fileURL, .name, .shellQuoted])
        XCTAssertNil(FileCommandController.pathStyle(for: .copy))
    }

    func testEditMenuShowsTheSubmenuAfterCopyAsPath() {
        let menu = MainMenuBuilder.build()
        let edit = menu.items.first { $0.submenu?.title == "Edit" }?.submenu
        let titles = edit?.items.map(\.title) ?? []
        XCTAssertEqual(titles.firstIndex(of: "Copy Path As"), titles.firstIndex(of: "Copy as Path").map { $0 + 1 })
        let item = edit?.items.first { $0.title == "Copy Path As" }
        XCTAssertEqual(item?.isHidden, false)
        XCTAssertEqual(item?.submenu?.items.map(\.title), ["POSIX Path", "~ Path", "File URL", "Name", "Quoted for Shell"])
    }

    func testCommandBarMoreMenuHasTheSubmenu() {
        let bar = CommandBarView()
        let titles = bar.moreMenu.items.map(\.title)
        let item = bar.moreMenu.items.first { $0.title == "Copy Path As" }
        XCTAssertNotNil(item?.submenu)
        XCTAssertEqual(titles.firstIndex(of: "Copy Path As"), titles.firstIndex(of: "Copy as Path").map { $0 + 1 })
    }
}
