import AppKit
import Core

/// "Copy Path As ▸" (spec §11 Phase 2): POSIX Path, ~ Path, File URL, Name, Quoted for Shell. It follows Copy as Path
/// in the Edit menu, the item context menu and the command bar's ⋯ menu. Main-menu and command-bar items are
/// nil-targeted `Command.selectorName` actions (they follow the first responder); context-menu items carry their
/// (command, target) in a MenuActionBox like the rest of that menu. "POSIX Path" sends copyAsPath, but only Edit ›
/// Copy as Path carries ⇧⌘C and the `macx.menu.copyAsPath` identifier.
@MainActor
enum CopyPathMenu {
    static let commands: [Command] = [.copyAsPath, .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted]
    static let submenuID = "macx.menu.copyPathAs"
    /// The submenu's copyAsPath item; distinct from Edit › Copy as Path's `macx.menu.copyAsPath`.
    static let posixItemID = "macx.menu.copyPathAs.posix"

    static func title(_ command: Command) -> String {
        command == .copyAsPath ? L10n.string("POSIX Path") : MainMenuTitles.title(command)
    }

    /// The submenu. With a handler, items are bound to `target` through MenuActionBox (context menus); otherwise
    /// they are nil-targeted.
    static func make(target: CommandTarget? = nil, handler: (any CommandHandler)? = nil) -> NSMenu {
        let menu = NSMenu(title: L10n.string("Copy Path As"))
        for command in commands {
            let item = NSMenuItem(title: title(command), action: Selector(command.selectorName), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(command == .copyAsPath ? posixItemID : "macx.menu.\(command.rawValue)")
            if let target, let handler {
                let box = MenuActionBox(command: command, target: target, handler: handler)
                item.action = #selector(MenuActionBox.run(_:))
                item.target = box
                item.representedObject = box
            }
            menu.addItem(item)
        }
        return menu
    }

    /// "Copy Path As ▸" wrapping `make(target:handler:)`.
    static func submenuItem(target: CommandTarget? = nil, handler: (any CommandHandler)? = nil) -> NSMenuItem {
        let menu = make(target: target, handler: handler)
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(submenuID)
        item.submenu = menu
        return item
    }
}
