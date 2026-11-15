import XCTest
import AppKit
@testable import UI
@testable import Core

/// The View menu's icons: key items only, never submenu contents.
@MainActor final class ViewMenuIconsTests: XCTestCase {
    private var view: NSMenu? {
        MainMenuBuilder.build().items.first { $0.identifier?.rawValue == "macx.menu.view" }?.submenu
    }

    // Other menus are left alone: on macOS 26 AppKit gives some standard items there (Undo, Copy, Minimize…) icons.
    func testExactlyTheChosenItemsHaveIcons() {
        let withIcons = (view?.items ?? []).filter { $0.image != nil }.map(\.title)
        XCTAssertEqual(withIcons, [
            "as Details", "as Icons", "as Columns",
            "Icon Size", "Density", "Sort By", "Group By",
            "Show Hidden Items", "Show Command Bar", "Show Sidebar", "Show Preview Pane",
            "Search", "Refresh", "Enter Full Screen",
        ])
    }

    func testEverySymbolExists() {
        for symbol in MainMenuBuilder.viewMenuSymbols.values {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testSubmenuContentsStayTextOnly() {
        for item in view?.items ?? [] {
            guard let submenu = item.submenu else { continue }
            XCTAssertTrue(submenu.items.allSatisfy { $0.image == nil }, item.title)
        }
    }
}
