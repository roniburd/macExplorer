import AppKit

/// One row of the address-bar dropdown (§5.2): a subfolder completion of the typed path, or a recent location.
struct AddressSuggestion: Equatable {
    enum Kind: Equatable { case subfolder, recent }
    var kind: Kind
    var title: String          // shown in the list
    var text: String           // what the field holds when the row is accepted
}

enum AddressSuggestions {
    /// Completions first (the typed head + name + "/", so the next level completes), then `recents` (already
    /// matched against the text, most recent first) minus any equal to a completion.
    static func make(for text: String, subfolders: [String], recents: [String]) -> [AddressSuggestion] {
        let head = text.lastIndex(of: "/").map { String(text[...$0]) } ?? ""
        let completions = subfolders.map { AddressSuggestion(kind: .subfolder, title: $0, text: head + $0 + "/") }
        let taken = Set(completions.map { trimmed($0.text) })
        let recentRows = recents.filter { !taken.contains(trimmed($0)) }
            .map { AddressSuggestion(kind: .recent, title: $0, text: $0) }
        return completions + recentRows
    }

    private static func trimmed(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// The dropdown under the address field: a borderless child panel that never becomes key, so the field keeps
/// the keyboard while arrows move the highlight (AddressEditField drives it).
@MainActor
final class AddressSuggestionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onChoose: ((Int) -> Void)?
    private(set) var items: [AddressSuggestion] = []
    private let panel: NSPanel
    private let table = SuggestionTableView()
    private static let rowHeight: CGFloat = 22
    private static let maxVisibleRows = 12

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        panel.contentView = scroll
    }

    var isVisible: Bool { panel.isVisible }

    var selectedIndex: Int? { table.selectedRow >= 0 ? table.selectedRow : nil }

    func select(_ index: Int?) {
        guard let index, items.indices.contains(index) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    /// Shows `items` under `anchor` (a view in a window); hides for an empty list.
    func show(_ items: [AddressSuggestion], below anchor: NSView) {
        self.items = items
        table.reloadData()
        table.deselectAll(nil)
        guard !items.isEmpty, let parent = anchor.window else { return hide() }
        let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let height = CGFloat(min(items.count, Self.maxVisibleRows)) * (Self.rowHeight + 2) + 4
        let width = max(rect.width, 240)
        panel.setFrame(NSRect(x: rect.minX, y: rect.minY - height - 2, width: width, height: height), display: true)
        table.tableColumns.first?.width = width - 4
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        table.deselectAll(nil)
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        if items.indices.contains(row) { onChoose?(row) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: item.kind == .recent ? "clock" : "folder",
                                               accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: item.title)
        label.lineBreakMode = .byTruncatingMiddle
        for view in [image, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = label
        cell.imageView = image
        cell.setAccessibilityLabel(item.title)
        return cell
    }
}

/// Clicks land even though the panel never becomes key.
@MainActor
private final class SuggestionTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}
