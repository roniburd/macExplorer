import AppKit
import Core

/// Command → localized title, shared by the main menu and the command palette (P4-03), so they never disagree.
/// `title(_:)` is the menu item's own title (`MainMenuTitles`, exhaustive over Command). The palette lists commands
/// out of their menus, so `paletteTitle(_:)` names a submenu item with its submenu ("Sort By › Name",
/// "Group By › Name", "Copy Path As › Name") and spells out View's "as Details" items.
@MainActor enum CommandTitles {
    static func title(_ command: Command) -> String { MainMenuTitles.title(command) }

    /// `menuTitle` is the title the menu item has right now (validation retitles a few: Close Tab, Hide Preview Pane);
    /// nil = `title(command)`.
    static func paletteTitle(_ command: Command, menuTitle: String? = nil) -> String {
        if let spelled = spelledOut[command] { return spelled }
        let title = menuTitle ?? title(command)
        guard let submenu = submenuTitles[command], !title.localizedCaseInsensitiveContains(submenu) else { return title }
        return submenu + " › " + title   // both parts localized; the menu-path separator is not text
    }

    /// Top-level items whose menu title reads only under their menu ("View ▸ as Details").
    private static let spelledOut: [Command: String] = [
        .viewAsDetails: L10n.string("View as Details"),
        .viewAsIcons: L10n.string("View as Icons"),
        .viewAsColumns: L10n.string("View as Columns"),
    ]

    /// Each command item's enclosing submenu title below the top-level menus (Icon Size, Sort By, Copy Path As, …),
    /// read once from the menu MainMenuBuilder builds, so a menu change carries over.
    private static let submenuTitles: [Command: String] = {
        var map: [Command: String] = [:]
        func walk(_ menu: NSMenu, depth: Int) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu, depth: depth + 1); continue }
                guard depth >= 2, let id = item.identifier?.rawValue, id.hasPrefix("macx.menu."),
                      let command = Command(rawValue: String(id.dropFirst("macx.menu.".count))) else { continue }
                map[command] = menu.title
            }
        }
        walk(MainMenuBuilder.build(), depth: 0)
        return map
    }()
}
