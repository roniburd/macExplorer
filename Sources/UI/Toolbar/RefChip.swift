import AppKit
import Core
import MacxPluginKit

/// The picker's rows and Return (spec §4.2). Pure.
enum RefFilter {
    /// Branches, then tags, then commits; a case-insensitive substring filter on the name.
    static func rows(_ refs: [RemoteRef], matching text: String) -> [RemoteRef] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let matched = typed.isEmpty ? refs : refs.filter { $0.name.range(of: typed, options: .caseInsensitive) != nil }
        return matched.filter { $0.kind == .branch } + matched.filter { $0.kind == .tag } + matched.filter { $0.kind == .commit }
    }

    /// The highlighted row, else the typed text as is (a commit SHA or a ref beyond the list); nil for nothing.
    static func choice(text: String, rows: [RemoteRef], selected: Int?) -> String? {
        if let selected, rows.indices.contains(selected) { return rows[selected].name }
        let typed = text.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? nil : typed
    }
}

/// The `main ▾` chip after a remote folder's root segment. A click opens a searchable list of branches and tags
/// (listed when it opens); choosing one calls `onChoose` with the ref's name.
@MainActor
final class RefChipController: NSObject {
    let button = NSButton(title: "", target: nil, action: nil)
    var onChoose: ((String) -> Void)?
    private(set) var location: RemoteLocation?
    private var provider: (any RemoteProvider)?
    private var popover: NSPopover?
    let picker = RefPickerViewController()

    override init() {
        super.init()
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(clicked(_:))
        button.setAccessibilityIdentifier(AXID.refChip)
        button.setAccessibilityLabel(L10n.string("Branch or Tag"))
        picker.onChoose = { [weak self] ref in
            self?.popover?.performClose(nil)
            self?.onChoose?(ref)
        }
    }

    func show(location: RemoteLocation, provider: any RemoteProvider) {
        self.location = location
        self.provider = provider
        button.title = (location.ref.map(Self.shortRef) ?? L10n.string("Default Branch")) + " ▾"
    }

    /// A 40-hex commit shows its first 7 characters.
    static func shortRef(_ ref: String) -> String {
        ref.count == 40 && ref.allSatisfy(\.isHexDigit) ? String(ref.prefix(7)) : ref
    }

    @objc private func clicked(_ sender: NSButton) { openPicker() }

    func openPicker() {
        guard let location, let provider else { return }
        picker.reset(current: location.ref)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        self.popover = popover
        if button.window != nil { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY) }
        Task { @MainActor [weak picker] in
            do {
                let refs = try await provider.listRefs(repo: location.repo)
                picker?.show(refs: refs)
            } catch {
                picker?.showError(L10n.string("Couldn't load branches and tags"))
            }
        }
    }
}

/// Search field + list. Typing filters; ↑/↓ move the highlight; Return or a click chooses (RefFilter.choice).
@MainActor
final class RefPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onChoose: ((String) -> Void)?
    let searchField = NSSearchField()
    let table = NSTableView()
    let status = NSTextField(labelWithString: "")
    private(set) var refs: [RemoteRef] = []
    private(set) var rows: [RemoteRef] = []
    private var current: String?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 320))
        searchField.placeholderString = L10n.string("Filter branches and tags, or type a commit")
        searchField.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ref"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        status.textColor = .secondaryLabelColor
        for view in [searchField, scroll, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
    }

    func reset(current: String?) {
        _ = view
        self.current = current
        refs = []
        searchField.stringValue = ""
        status.stringValue = L10n.string("Loading…")
        reload()
    }

    func show(refs: [RemoteRef]) {
        self.refs = refs
        status.stringValue = ""
        reload()
    }

    func showError(_ text: String) {
        status.stringValue = text
    }

    private func reload() {
        rows = RefFilter.rows(refs, matching: searchField.stringValue)
        table.reloadData()
        let currentRow = rows.firstIndex { $0.name == current }
        if searchField.stringValue.isEmpty, let currentRow { table.selectRowIndexes([currentRow], byExtendingSelection: false) }
    }

    func choose() {
        let selected = table.selectedRow >= 0 ? table.selectedRow : nil
        if let ref = RefFilter.choice(text: searchField.stringValue, rows: rows, selected: selected) { onChoose?(ref) }
    }

    @objc private func rowClicked(_ sender: Any?) { if table.clickedRow >= 0 { choose() } }

    func controlTextDidChange(_ obj: Notification) {
        reload()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): choose(); return true
        case #selector(NSResponder.moveDown(_:)): moveHighlight(1); return true
        case #selector(NSResponder.moveUp(_:)): moveHighlight(-1); return true
        default: return false
        }
    }

    private func moveHighlight(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = min(max(0, table.selectedRow + delta), rows.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let ref = rows[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: ref.name)
        let symbol = ref.kind == .tag ? "tag" : "arrow.triangle.branch"
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        for view in [image, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if ref.name == current { label.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        return cell
    }
}
