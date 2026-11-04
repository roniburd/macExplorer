import AppKit
import Core

/// The menu bar (§5.3: every command is in it, so Help search finds them all). Command items are nil-targeted
/// `Selector(command.selectorName)` actions that follow the first responder (§5.6 step 5), carry the identifier
/// `macx.menu.<rawValue>`, and take their single key equivalent from `KeyMap.primary` (rebindable in System Settings ›
/// Keyboard › App Shortcuts). Titles are matched in English by the scenario runner (`menu` steps).
@MainActor public enum MainMenuBuilder {
    /// Commands with no main-menu item. Esc (cancelOperation) is a key, not a menu command.
    static let notInMenu: Set<Command> = [.cancelOperation]

    public static func build() -> NSMenu {
        let main = NSMenu(title: "MainMenu")
        for (title, id, items) in [
            ("MacExplorer", "app", appItems()), ("File", "file", fileItems()), ("Edit", "edit", editItems()),
            ("View", "view", viewItems()), ("Go", "go", goItems()), ("Window", "window", windowItems()),
            ("Help", "help", helpItems()),
        ] {
            main.addItem(submenu(L10n.string(title), id: id, items))
        }
        return main
    }

    /// Installs `build()` as the app's main menu and registers its Services, Window and Help menus.
    public static func install(in app: NSApplication) {
        let menu = build()
        app.mainMenu = menu
        func top(_ id: String) -> NSMenu? { menu.items.first { $0.identifier?.rawValue == "macx.menu.\(id)" }?.submenu }
        app.servicesMenu = top("app")?.items.first { $0.identifier?.rawValue == "macx.menu.services" }?.submenu
        if let window = top("window") { app.windowsMenu = window }
        app.helpMenu = top("help")
    }

    /// KeyChord → NSMenuItem key equivalent. Shifted characters keep the unshifted key plus `.shift` (⌘⇧. is "." with
    /// [.command, .shift]); ⌫ is BS (0x08), Del is NSDeleteFunctionKey.
    static func keyEquivalent(for chord: KeyChord) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        func scalar(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
        var modifiers: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.command) { modifiers.insert(.command) }
        if chord.modifiers.contains(.option) { modifiers.insert(.option) }
        if chord.modifiers.contains(.control) { modifiers.insert(.control) }
        if chord.modifiers.contains(.shift) { modifiers.insert(.shift) }
        let key: String
        switch chord.key {
        case .character(let c): key = c
        case .up: key = scalar(NSUpArrowFunctionKey)
        case .down: key = scalar(NSDownArrowFunctionKey)
        case .left: key = scalar(NSLeftArrowFunctionKey)
        case .right: key = scalar(NSRightArrowFunctionKey)
        case .returnKey: key = "\r"
        case .enter: key = "\u{3}"
        case .tab: key = "\t"
        case .escape: key = "\u{1b}"
        case .space: key = " "
        case .backspace: key = "\u{8}"
        case .forwardDelete: key = scalar(NSDeleteFunctionKey)
        case .function(let n):
            guard (1...20).contains(n) else { return nil }
            key = scalar(NSF1FunctionKey + n - 1)
        }
        return (key, modifiers)
    }

    // MARK: menus

    private static func appItems() -> [NSMenuItem] {
        let services = submenu(L10n.string("Services"), id: "services", [])
        return [
            standard("About MacExplorer", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            // P1-30's AppDelegate implements macx_showSettings: (disabled until then).
            standard("Settings…", NSSelectorFromString("macx_showSettings:"), ","),
            .separator(),
            services,
            .separator(),
            standard("Hide MacExplorer", #selector(NSApplication.hide(_:)), "h"),
            standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            standard("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            standard("Quit MacExplorer", #selector(NSApplication.terminate(_:)), "q"),
        ]
    }

    private static func fileItems() -> [NSMenuItem] {
        [
            item(.newWindow), item(.newFolder), item(.newTextFile), item(.newEmptyFile), .separator(),
            item(.open), item(.openInNewWindow), item(.showPackageContents), item(.openInTerminal), item(.revealInFinder),
            .separator(),
            item(.rename), item(.duplicate), item(.makeAlias), item(.makeSymlink), .separator(),
            item(.moveToTrash), item(.deletePermanently), .separator(),
            item(.share), item(.properties), .separator(),
            item(.eject), item(.removeFromFavorites), .separator(),
            item(.closeWindow),
        ]
    }

    private static func editItems() -> [NSMenuItem] {
        [
            item(.undo), item(.redo), .separator(),
            item(.cut), item(.copy), item(.paste), item(.moveItemHere), item(.copyAsPath), .separator(),
            item(.selectAll), item(.selectNone), item(.invertSelection),
        ]
    }

    private static func viewItems() -> [NSMenuItem] {
        [
            item(.viewAsDetails), item(.viewAsIcons), .separator(),
            submenu(L10n.string("Icon Size"), id: "iconSize", [item(.iconSizeSmall), item(.iconSizeMedium), item(.iconSizeLarge)]),
            submenu(L10n.string("Density"), id: "density", [item(.densityCompact), item(.densityRegular), item(.densityComfortable)]),
            submenu(L10n.string("Sort By"), id: "sortBy", [
                item(.sortByName), item(.sortByDateModified), item(.sortBySize), item(.sortByKind), item(.sortByDateCreated),
                .separator(), item(.sortAscending), item(.sortDescending),
            ]),
            .separator(),
            item(.toggleHidden), item(.toggleCommandBar),
            standard("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            .separator(),
            item(.refresh), .separator(),
            standard("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
    }

    private static func goItems() -> [NSMenuItem] {
        [
            item(.back), item(.forward), item(.up), .separator(),
            item(.focusAddressBar), item(.focusSearch), .separator(),
            item(.cycleFocusForward), item(.cycleFocusBackward),
        ]
    }

    private static func windowItems() -> [NSMenuItem] {
        [
            standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            standard("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(.showOperations),
            .separator(),
            standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ]
    }

    private static func helpItems() -> [NSMenuItem] {
        [standard("MacExplorer Help", #selector(NSApplication.showHelp(_:)), "?")]
    }

    // MARK: items

    /// A command item: nil target, `macx.menu.<raw>` identifier, KeyMap primary.
    static func item(_ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: MainMenuTitles.title(command), action: Selector(command.selectorName), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.\(command.rawValue)")
        if let chord = KeyMap.primary(command), let equivalent = keyEquivalent(for: chord) {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        return item
    }

    private static func standard(_ title: String, _ action: Selector, _ key: String = "",
                                 _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string(title), action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    /// Submenu identifiers ("macx.menu.file", "macx.menu.sortBy") never equal a Command raw value.
    private static func submenu(_ title: String, id: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for child in items { menu.addItem(child) }
        item.submenu = menu
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.\(id)")
        return item
    }
}
