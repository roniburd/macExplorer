import AppKit
import Core

/// The command bar (§5.3), about 28 pt, inside the content area:
/// `[＋ New ▾] | [Cut] [Copy] [Paste] [Rename] [Share] [Delete] | [Sort ▾] [View ▾] [⋯]      [Properties]`.
/// Buttons and menu items are nil-targeted `Command.selectorName` actions, so they follow the first responder (content
/// or sidebar, §5.4). `update` enables the buttons from the owner's CommandState and focus; pull-down items validate
/// through the responder chain. Delete becomes Delete Permanently while ⇧ is held.
@MainActor
final class CommandBarView: NSView {
    static let newMenuID = "macx.commandBar.new"
    static let sortMenuID = "macx.commandBar.sort"
    static let viewMenuID = "macx.commandBar.view"
    static let moreMenuID = "macx.commandBar.more"

    let newButton: PullDownButton
    let sortButton: PullDownButton
    let viewButton: PullDownButton
    let moreButton: PullDownButton
    let deleteButton: NSButton
    private var buttons: [Command: NSButton] = [:]
    private var deleteCommand: Command = .moveToTrash
    private let stack = NSStackView()

    init() {
        newButton = Self.pullDown(id: Self.newMenuID, title: L10n.string("New"), symbol: "plus",
                                  [.newFolder, .newTextFile, .newEmptyFile])
        sortButton = Self.pullDown(id: Self.sortMenuID, title: L10n.string("Sort"), symbol: "arrow.up.arrow.down",
                                   [.sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, nil,
                                    .sortAscending, .sortDescending])
        viewButton = Self.pullDown(id: Self.viewMenuID, title: L10n.string("View"), symbol: "rectangle.grid.1x2",
                                   [.viewAsDetails, nil, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge, nil,
                                    .densityCompact, .densityRegular, .densityComfortable, nil,
                                    .toggleHidden, .toggleCommandBar])
        moreButton = Self.pullDown(id: Self.moreMenuID, title: nil, symbol: "ellipsis",
                                   [.copyAsPath, nil, .selectAll, .selectNone, .invertSelection, nil,
                                    .openInTerminal, .revealInFinder])
        moreButton.setAccessibilityLabel(L10n.string("More"))
        moreButton.toolTip = L10n.string("More")
        deleteButton = Self.button(.moveToTrash)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        for command in [Command.cut, .copy, .paste, .rename, .share, .properties] { buttons[command] = Self.button(command) }
        buttons[.moveToTrash] = deleteButton
        layoutBar()
    }

    required init?(coder: NSCoder) { fatalError("CommandBarView is created in code") }

    var newMenu: NSMenu { newButton.pullDownMenu }
    var sortMenu: NSMenu { sortButton.pullDownMenu }
    var viewMenu: NSMenu { viewButton.pullDownMenu }
    var moreMenu: NSMenu { moreButton.pullDownMenu }

    /// Every control in display order.
    var controls: [NSControl] {
        [newButton] + [Command.cut, .copy, .paste, .rename, .share].compactMap { buttons[$0] }
            + [deleteButton, sortButton, viewButton, moreButton] + [buttons[.properties]].compactMap { $0 }
    }

    /// The button that currently sends `command` (Delete answers for moveToTrash or deletePermanently, whichever it is now).
    func button(for command: Command) -> NSButton? {
        if command == .moveToTrash || command == .deletePermanently { return command == deleteCommand ? deleteButton : nil }
        return buttons[command]
    }

    func update(state: CommandState, focus: FocusContext, shiftHeld: Bool) {
        setDeleteCommand(shiftHeld ? .deletePermanently : .moveToTrash)
        func enabled(_ command: Command) -> Bool {
            let effective = CommandAvailability.effectiveCommand(command, focus: focus) ?? command
            return MenuValidation.isEnabled(effective, window: window, state: state, focus: focus)
        }
        for (command, button) in buttons where button !== deleteButton { button.isEnabled = enabled(command) }
        deleteButton.isEnabled = enabled(deleteCommand)
        newButton.isEnabled = [Command.newFolder, .newTextFile, .newEmptyFile].contains(where: enabled)
    }

    // MARK: building

    private func setDeleteCommand(_ command: Command) {
        guard command != deleteCommand else { return }
        deleteCommand = command
        Self.configure(deleteButton, command)
    }

    private func layoutBar() {
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let views: [NSView] = [newButton, Self.divider()]
            + [Command.cut, .copy, .paste, .rename, .share].compactMap { buttons[$0] }
            + [deleteButton, Self.divider(), sortButton, viewButton, moreButton, spacer]
            + [buttons[.properties]].compactMap { $0 }
        for view in views {
            stack.addArrangedSubview(view)
            if view is NSControl { view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(L10n.string("Command Bar"))
    }

    private static func button(_ command: Command) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.controlSize = .regular
        button.refusesFirstResponder = true    // Tab cycles sidebar → address bar → content (§5.6), not bar items
        configure(button, command)
        return button
    }

    private static func configure(_ button: NSButton, _ command: Command) {
        let title = CommandBarTitles.title(command)
        button.title = title
        button.image = NSImage(systemSymbolName: CommandBarTitles.symbol(command), accessibilityDescription: title)
        button.action = Selector(command.selectorName)
        button.target = nil
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(AXID.commandBarItem(command))
    }

    private static func pullDown(id: String, title: String?, symbol: String, _ commands: [Command?]) -> PullDownButton {
        let menu = NSMenu(title: title ?? L10n.string("More"))
        for command in commands {
            guard let command else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: CommandBarTitles.menuTitle(command), action: Selector(command.selectorName),
                                  keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("macx.commandBar.\(command.rawValue)")
            menu.addItem(item)
        }
        let button = PullDownButton(menu: menu)
        button.title = title ?? ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? L10n.string("More"))
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        button.setAccessibilityIdentifier(id)
        if let title {
            button.setAccessibilityLabel(title)
            button.toolTip = title
        }
        return button
    }

    private static func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return box
    }
}

/// A command-bar button that pops up a menu of nil-targeted command items below itself (New ▾, Sort ▾, View ▾, ⋯).
/// The items validate through the responder chain when the menu opens.
@MainActor
final class PullDownButton: NSButton {
    let pullDownMenu: NSMenu

    init(menu: NSMenu) {
        pullDownMenu = menu
        super.init(frame: .zero)
        bezelStyle = .accessoryBarAction
        isBordered = false
        refusesFirstResponder = true
        target = self
        action = #selector(showMenu(_:))
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError("PullDownButton is created in code") }

    @objc private func showMenu(_ sender: Any?) {
        pullDownMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }
}
