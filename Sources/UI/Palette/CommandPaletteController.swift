import AppKit
import Core

/// The palette's window: a borderless-looking titled panel that takes the keyboard but never becomes main, so the
/// browser window it opened over stays the main window (menu validation and key equivalents keep following it).
@MainActor final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// ⌘⇧P (P4-03): a search field over every command that is enabled for the window's current command target, plus
/// "Go to …" rows for the sidebar's favorites and the recent locations. Ranking is `PaletteCatalog` (in memory; the
/// rows come from menu validation and already-resolved favorites, never from file-system calls). Running a row
/// closes the palette, gives the keyboard back to the window's previous first responder and sends the command's
/// action through that window's responder chain, so it does exactly what its menu item does.
@MainActor
final class CommandPaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    /// The open palette (one at a time, app-wide).
    private(set) static var shown: CommandPaletteController?

    let context: UIContext
    let panel: PalettePanel
    private weak var targetWindow: NSWindow?
    private weak var targetResponder: NSResponder?
    private let items: [PaletteItem]
    private var ranked: [RankedPaletteItem] = []
    private let field = NSTextField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: L10n.string("No Matches"))
    private var closed = false

    /// Opens the palette over `window` (a second ⌘⇧P closes an open one instead). `window`'s first responder is
    /// the command target, as for the menu bar.
    @discardableResult
    static func show(over window: NSWindow, context: UIContext) -> CommandPaletteController {
        if let open = shown {
            open.close()
            if open.targetWindow === window { return open }
        }
        let controller = CommandPaletteController(window: window, context: context)
        shown = controller
        controller.present()
        return controller
    }

    private init(window: NSWindow, context: UIContext) {
        self.context = context
        self.targetWindow = window
        self.targetResponder = window.firstResponder
        self.items = Self.items(for: window)
        self.panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        buildPanel()
        setQuery("")
    }

    // MARK: test seams

    /// Replaces the search text and re-ranks (what typing does).
    func setQuery(_ query: String) {
        if field.stringValue != query { field.stringValue = query }
        rerank()
    }

    var visibleTitles: [String] { ranked.map(\.item.title) }
    var visibleItems: [PaletteItem] { ranked.map(\.item) }
    var selectedRow: Int { table.selectedRow }
    var isOpen: Bool { !closed }

    /// Return: runs the selected row (nothing when no row matches).
    func runSelected() {
        let row = table.selectedRow
        guard ranked.indices.contains(row) else { NSSound.beep(); return }
        run(ranked[row].item)
    }

    // MARK: items

    /// Every enabled command (validated like its menu item, through `window`'s responder chain) except the palette
    /// itself and commands with no menu item (Esc), then one "Go to" row per favorite and recent location.
    static func items(for window: NSWindow) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let bindings = ActiveKeyBindings.current
        let hidden = pointlessTabCommands(for: window)
        for command in Command.allCases where command != .showCommandPalette && !MainMenuBuilder.notInMenu.contains(command)
            && !hidden.contains(command) {
            let action = Selector(command.selectorName)
            guard let target = target(for: action, in: window) else { continue }
            let menuItem = NSMenuItem(title: CommandTitles.title(command), action: action, keyEquivalent: "")
            guard validate(menuItem, with: target) else { continue }
            items.append(PaletteItem(target: .command(command),
                                     title: CommandTitles.paletteTitle(command, menuTitle: menuItem.title),
                                     subtitle: bindings.primary(command)?.displayString))
        }
        guard let browser = window.windowController as? BrowserWindowController else { return items }
        var seen = Set<PaletteTarget>()
        func addLocation(_ url: URL, name: String) {
            let target = PaletteTarget.location(url)
            guard seen.insert(target).inserted else { return }
            items.append(PaletteItem(target: target, title: String(format: L10n.string("Go to %@"), name),
                                     subtitle: url.path(percentEncoded: false)))
        }
        if let sidebar = browser.sidebarPane as? SidebarViewController {
            for row in sidebar.favorites.rows where !row.isStale {
                if let url = row.url { addLocation(url, name: row.name) }
            }
        }
        for path in browser.context.environment.settings.recentLocations.prefix(Settings.recentLocationsLimit) {
            let url = URL(filePath: path, directoryHint: .isDirectory)
            let name = url.lastPathComponent.isEmpty || path == "/" ? path : url.lastPathComponent
            addLocation(url, name: name)
        }
        return items
    }

    /// NSWindow validates its tab actions as enabled even for a window without tabs; the palette leaves out the ones
    /// that would do nothing there (switching or detaching tabs without tabs, merging without other windows).
    private static func pointlessTabCommands(for window: NSWindow) -> Set<Command> {
        let tabs = window.tabbedWindows?.count ?? 1
        var hidden: Set<Command> = []
        if tabs <= 1 { hidden.formUnion([.nextTab, .previousTab, .moveTabToNewWindow]) }
        let windows = (window.windowController as? BrowserWindowController)?.context.windows.windows.count ?? 1
        if windows <= tabs { hidden.insert(.mergeAllWindows) }
        return hidden
    }

    /// What `NSApp.sendAction(action, to: nil, …)` would reach from `window`'s first responder (its responder chain
    /// with supplemental targets, then the window's delegate), found without needing `window` to be key.
    static func target(for action: Selector, in window: NSWindow) -> AnyObject? {
        var responder: NSResponder? = window.firstResponder ?? window
        while let current = responder {
            if current.responds(to: action) { return current }
            if let supplemental = current.supplementalTarget(forAction: action, sender: nil) { return supplemental as AnyObject }
            responder = current.nextResponder
        }
        if let delegate = window.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        return nil
    }

    /// The target's own menu validation (it may retitle `item`: Close Tab, Hide Preview Pane). Targets without
    /// validation are enabled, as AppKit treats them.
    private static func validate(_ item: NSMenuItem, with target: AnyObject) -> Bool {
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    // MARK: running

    private func run(_ item: PaletteItem) {
        let window = targetWindow
        let responder = targetResponder
        close()
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        // An open field editor (address bar, inline rename) stays the window's first responder while the palette
        // is key; anything else that lost it gets it back.
        if let responder, window.firstResponder !== responder, !((responder as? NSTextView)?.isFieldEditor ?? false) {
            window.makeFirstResponder(responder)
        }
        switch item.target {
        case .command(let command):
            let action = Selector(command.selectorName)
            guard let target = Self.target(for: action, in: window) else { NSSound.beep(); return }
            NSApp.sendAction(action, to: target, from: self)
        case .location(let url):
            (window.windowController as? BrowserWindowController)?.navigate(to: url)
        }
        context.environment.settings.notePaletteUsed(item.target)
    }

    /// Closes without running anything (Esc, a click elsewhere, a second ⌘⇧P).
    func close() {
        guard !closed else { return }
        closed = true
        if Self.shown === self { Self.shown = nil }
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: panel

    private func present() {
        guard let window = targetWindow else { return }
        let size = panel.frame.size
        let frame = window.frame
        let top = frame.maxY - min(90, frame.height / 4)
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: top - size.height))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func buildPanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        // UI scenario runs never activate the app (ScenarioDriver pins the key window instead), so a panel that hides on
        // deactivation would never show there.
        panel.hidesOnDeactivate = context.options.scenario == nil
        panel.animationBehavior = .utilityWindow
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.setAccessibilityIdentifier(AXID.palette)

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        field.placeholderString = L10n.string("Type a command or folder name")
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityIdentifier(AXID.paletteField)
        field.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("macx.palette.column"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 26
        table.backgroundColor = .clear
        table.refusesFirstResponder = true   // typing stays in the field; ↑/↓ move the selection from there
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked(_:))
        table.setAccessibilityIdentifier(AXID.paletteTable)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [field, separator, scroll, emptyLabel] as [NSView] { background.addSubview(view) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
        ])
    }

    private func rerank() {
        ranked = PaletteCatalog.rank(items, query: field.stringValue,
                                     recent: context.environment.settings.paletteRecentTargets)
        table.reloadData()
        emptyLabel.isHidden = !ranked.isEmpty
        select(ranked.isEmpty ? -1 : 0)
    }

    private func select(_ row: Int) {
        guard ranked.indices.contains(row) else { table.deselectAll(nil); return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func tableClicked(_ sender: Any?) {
        guard ranked.indices.contains(table.clickedRow) else { return }
        select(table.clickedRow)
        runSelected()
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { rerank() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            select(max(table.selectedRow - 1, 0))
        case #selector(NSResponder.moveDown(_:)):
            select(min(table.selectedRow + 1, ranked.count - 1))
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            select(max(table.selectedRow - 10, 0))
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            select(min(table.selectedRow + 10, ranked.count - 1))
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { ranked.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("macx.palette.row")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PaletteRowView ?? PaletteRowView(identifier: id)
        if ranked.indices.contains(row) { cell.show(ranked[row]) }
        return cell
    }
}

/// One palette row: the title (matched characters in bold) and, trailing, the key binding or the folder's path.
@MainActor final class PaletteRowView: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingMiddle
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("PaletteRowView is created in code") }

    func show(_ ranked: RankedPaletteItem) {
        title.attributedStringValue = Self.highlighted(ranked.item.title, ranked.match.matchedIndices)
        detail.stringValue = ranked.item.subtitle ?? ""
        setAccessibilityLabel(ranked.item.title)
    }

    /// Bold matched characters, when folding kept the title's length (so the indices are the title's own).
    static func highlighted(_ text: String, _ indices: [Int]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font])
        let count = text.count
        guard !indices.isEmpty, FuzzyMatcher.fold(text).count == count else { return result }
        let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        for offset in indices where offset < count {
            let index = text.index(text.startIndex, offsetBy: offset)
            result.addAttribute(.font, value: bold, range: NSRange(index...index, in: text))
        }
        return result
    }
}
