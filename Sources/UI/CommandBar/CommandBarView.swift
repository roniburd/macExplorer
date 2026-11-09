import AppKit
import Core

/// The command bar (§5.3), about 28 pt, inside the content area:
/// `[＋ New ▾] | [Cut] [Copy] [Paste] [Rename] [Share] [Delete] | [Sort ▾] [View ▾] [⋯]      [Properties]`.
/// Buttons and menu items are nil-targeted `Command.selectorName` actions, so they follow the first responder (content
/// or sidebar, §5.4). `update` enables the buttons from the owner's CommandState and focus; pull-down items validate
/// through the responder chain. Delete becomes Delete Permanently while ⇧ is held.
///
/// Look ("duotone accent"): enabled icons are hierarchical SF Symbols in the accent colour (Delete in red, ⋯ in
/// secondary label) with primary-label titles; disabled buttons switch icon and title to tertiary label, so a selection
/// visibly lights the bar up. A hairline separates the bar from the list; `listGap` of list background follows it.
@MainActor
final class CommandBarView: NSView {
    /// Space between the bar and the start of the list (drawn in the list's background by the content pane).
    static let listGap: CGFloat = 8

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
    /// Titled buttons show only their icons (tool tips and accessibility labels keep the titles): the bar is
    /// narrower than it needs with titles, which would otherwise cut one button's title to a letter ("+ N").
    private(set) var isCompact = false
    private let hairline = NSBox()
    /// Per control: its SF Symbol, its enabled tint, and the enabled state its look was last drawn for.
    private var looks: [ObjectIdentifier: Look] = [:]

    private struct Look {
        var symbol: String
        var tint: NSColor
        var drawnEnabled: Bool?
    }

    init() {
        newButton = Self.pullDown(id: Self.newMenuID, title: L10n.string("New"), symbol: "plus",
                                  [.newFolder, .newTextFile, .newEmptyFile])
        sortButton = Self.pullDown(id: Self.sortMenuID, title: L10n.string("Sort"), symbol: "arrow.up.arrow.down",
                                   [.sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, nil,
                                    .sortAscending, .sortDescending])
        viewButton = Self.pullDown(id: Self.viewMenuID, title: L10n.string("View"), symbol: "rectangle.grid.1x2",
                                   [.viewAsDetails, .viewAsIcons, .viewAsColumns, nil, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge, nil,
                                    .densityCompact, .densityRegular, .densityComfortable, nil,
                                    .toggleHidden, .toggleCommandBar])
        moreButton = Self.pullDown(id: Self.moreMenuID, title: nil, symbol: "ellipsis",
                                   [.copyAsPath, nil, .selectAll, .selectNone, .invertSelection, nil,
                                    .openInTerminal, .revealInFinder])
        if let index = moreButton.pullDownMenu.items.firstIndex(where: { $0.action == Selector(Command.copyAsPath.selectorName) }) {
            moreButton.pullDownMenu.insertItem(CopyPathMenu.submenuItem(), at: index + 1)
        }
        viewButton.pullDownMenu.addItem(.separator())
        viewButton.pullDownMenu.addItem(Self.groupBySubmenu())
        moreButton.setAccessibilityLabel(L10n.string("More"))
        moreButton.toolTip = L10n.string("More")
        deleteButton = Self.button(.moveToTrash)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        for command in [Command.cut, .copy, .paste, .rename, .share, .properties] { buttons[command] = Self.button(command) }
        buttons[.moveToTrash] = deleteButton
        layoutBar()
        for (command, button) in buttons { looks[ObjectIdentifier(button)] = Look(symbol: CommandBarTitles.symbol(command), tint: CommandBarTitles.tint(command)) }
        looks[ObjectIdentifier(newButton)] = Look(symbol: "plus", tint: .controlAccentColor)
        looks[ObjectIdentifier(sortButton)] = Look(symbol: "arrow.up.arrow.down", tint: .controlAccentColor)
        looks[ObjectIdentifier(viewButton)] = Look(symbol: "rectangle.grid.1x2", tint: .controlAccentColor)
        looks[ObjectIdentifier(moreButton)] = Look(symbol: "ellipsis", tint: .secondaryLabelColor)
        for control in controls { (control.cell as? NSButtonCell)?.imageDimsWhenDisabled = false }
        applyLooks(force: true)
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsChanged(_:)),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
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
        applyLooks()
    }

    // MARK: compact

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCompact()
    }

    /// The width the bar needs to show every title, whichever mode it is in now.
    var titledWidth: CGFloat {
        let views = stack.arrangedSubviews.filter { !$0.isHidden }
        let content = views.reduce(CGFloat(0)) { sum, view in
            guard let button = view as? NSButton else { return sum + (view is NSBox ? 1 : 0) }
            guard let cell = button.cell?.copy() as? NSButtonCell else { return sum + button.intrinsicContentSize.width }
            if !button.title.isEmpty { cell.imagePosition = .imageLeading }
            return sum + ceil(cell.cellSize.width)
        }
        return content + stack.spacing * CGFloat(max(views.count - 1, 0)) + stack.edgeInsets.left + stack.edgeInsets.right
    }

    private func updateCompact() {
        guard bounds.width > 0 else { return }
        let compact = bounds.width < titledWidth
        guard compact != isCompact else { return }
        isCompact = compact
        for control in controls {
            guard let button = control as? NSButton, !button.title.isEmpty else { continue }
            button.imagePosition = compact ? .imageOnly : .imageLeading
        }
    }

    // MARK: look

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLooks(force: true)
        updateCompact()
    }

    @objc private func systemColorsChanged(_ note: Notification) { applyLooks(force: true) }   // accent colour changed

    /// Enabled: hierarchical symbol in the control's tint + primary-label title. Disabled: both in tertiary label.
    /// Only redraws controls whose enabled state changed, unless `force`.
    private func applyLooks(force: Bool = false) {
        for control in controls {
            guard let button = control as? NSButton, var look = looks[ObjectIdentifier(button)] else { continue }
            let enabled = button.isEnabled
            guard force || look.drawnEnabled != enabled else { continue }
            look.drawnEnabled = enabled
            looks[ObjectIdentifier(button)] = look
            let color: NSColor = enabled ? look.tint : .tertiaryLabelColor
            let description = button.accessibilityLabel() ?? button.title
            button.image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: description)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(hierarchicalColor: color))
            guard !button.title.isEmpty else { continue }
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .foregroundColor: enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: Self.singleLine,
            ])
        }
    }

    /// Attributed titles word-wrap by default: squeezed for a moment (the preview pane sliding open), a button then
    /// reports a wrapped, narrow intrinsic size that sticks once the bar widens again ("+ N", v0.2.0-beta.22).
    private static let singleLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    // MARK: building

    private func setDeleteCommand(_ command: Command) {
        guard command != deleteCommand else { return }
        deleteCommand = command
        Self.configure(deleteButton, command)
        if isCompact { deleteButton.imagePosition = .imageOnly }
        updateCompact()                     // "Delete Permanently" is wider
        looks[ObjectIdentifier(deleteButton)]?.symbol = CommandBarTitles.symbol(command)
        looks[ObjectIdentifier(deleteButton)]?.drawnEnabled = nil   // configure reset the image and title
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
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
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

    /// View ▾ › Group By ▸ (P2-10): nil-targeted items; the content pane validates them and sets the checkmark.
    private static func groupBySubmenu() -> NSMenuItem {
        let title = L10n.string("Group By")
        let submenu = NSMenu(title: title)
        for command in [Command.groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName] {
            let item = NSMenuItem(title: CommandBarTitles.menuTitle(command), action: Selector(command.selectorName), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("macx.commandBar.\(command.rawValue)")
            submenu.addItem(item)
            if command == .groupByNone { submenu.addItem(.separator()) }
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("macx.commandBar.groupBy")
        item.submenu = submenu
        return item
    }

    private static func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true   // else it soaks up slack and turns horizontal
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
