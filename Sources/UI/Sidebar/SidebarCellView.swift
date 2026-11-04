import AppKit
import Core

/// Source-list row: icon, name, and (ejectable volumes) a ⏏ button. Stale favorites are dimmed.
@MainActor
final class SidebarCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("macx.sidebar.cell")
    static let headerIdentifier = NSUserInterfaceItemIdentifier("macx.sidebar.header")

    let ejectButton = NSButton()
    var onEject: (() -> Void)?

    init(header: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        identifier = header ? Self.headerIdentifier : Self.identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        if header {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return
        }
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        imageView = icon
        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.bezelStyle = .accessoryBarAction
        ejectButton.isBordered = false
        ejectButton.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: L10n.string("Eject"))
        ejectButton.imagePosition = .imageOnly
        ejectButton.setAccessibilityLabel(L10n.string("Eject"))
        ejectButton.toolTip = L10n.string("Eject")
        ejectButton.target = self
        ejectButton.action = #selector(ejectClicked(_:))
        ejectButton.isHidden = true
        addSubview(ejectButton)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    func configure(title: String, symbol: String?, dimmed: Bool, ejectable: Bool, toolTip: String?) {
        textField?.stringValue = title
        textField?.textColor = dimmed ? .tertiaryLabelColor : (identifier == Self.headerIdentifier ? .secondaryLabelColor : .labelColor)
        if let symbol { imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        imageView?.alphaValue = dimmed ? 0.4 : 1
        imageView?.contentTintColor = .controlAccentColor
        ejectButton.isHidden = !ejectable
        self.toolTip = toolTip
        setAccessibilityLabel(dimmed ? String(format: L10n.string("%@ (not available)"), title) : title)
    }

    @objc private func ejectClicked(_ sender: Any?) { onEject?() }
}

/// The sidebar's NSOutlineView: takes focus, Return activates the selected row, right-click asks for a row menu.
/// ← / → collapse and expand (NSOutlineView's own handling).
@MainActor
final class SidebarOutlineView: NSOutlineView {
    var onActivate: ((Int) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    /// KeyRouter alternates (P1-29), after Return.
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, let chars = event.charactersIgnoringModifiers, chars == "\r" || chars == "\u{3}" {
            if selectedRow >= 0 { onActivate?(selectedRow) }
            return
        }
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return menuProvider?(row)
    }

    // MARK: right-drag (§5.6: tracked on rightMouseDown in the sidebar too)

    /// A right-drag past the threshold started on `row` (the sidebar begins a secondary drag for tree folders).
    var onSecondaryDrag: ((_ row: Int, _ event: NSEvent) -> Void)?
    /// Shows the context menu on a right-click that did not drag (tests replace it; the default runs the menu).
    var presentMenu: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in NSMenu.popUpContextMenu(menu, with: event, for: view) }
    private var rightDrag = RightDragTracker()
    private var rightDownEvent: NSEvent?

    override func rightMouseDown(with event: NSEvent) {
        rightDrag.rightMouseDown(at: event.locationInWindow)
        rightDownEvent = event
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard rightDrag.rightMouseDragged(to: event.locationInWindow) == .beginDrag, let down = rightDownEvent else { return }
        let row = self.row(at: convert(down.locationInWindow, from: nil))
        if row >= 0 { onSecondaryDrag?(row, event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        defer { rightDownEvent = nil }
        guard case .showMenu = rightDrag.rightMouseUp(at: event.locationInWindow), let down = rightDownEvent,
              let menu = menu(for: down) else { return }
        presentMenu(menu, down, self)
    }
}
