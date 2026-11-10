import AppKit
import SwiftUI
import Core
import MacxFS

/// The batch rename preview (P4-12): Original | New | Status in a view-based NSTableView (cell reuse, so 10,000 rows
/// cost what the visible ones cost). Blocking rows show a red status, unchanged rows are dimmed, and a changed
/// extension gets a yellow note.
struct BatchRenamePreviewTable: NSViewRepresentable {
    var rows: [BatchRenameRow]

    func makeCoordinator() -> Controller { Controller() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.setRows(rows) }

    /// Tests: a table outside SwiftUI.
    @MainActor static func makeTableForTesting() -> Controller { Controller() }

    static func statusText(_ status: BatchRenameStatus, extensionChanged: Bool) -> String {
        switch status {
        case .duplicateInBatch: L10n.string("Duplicate name")
        case .collidesWithExisting: L10n.string("Already exists")
        case .invalid: L10n.string("Invalid name")
        case .invalidPattern: L10n.string("Invalid pattern")
        case .unchanged: L10n.string("Unchanged")
        case .ok: extensionChanged ? L10n.string("Extension changes") : ""
        }
    }

    @MainActor
    final class Controller: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let tableView = NSTableView()
        let scrollView = NSScrollView()
        private(set) var rows: [BatchRenameRow] = []
        private static let original = NSUserInterfaceItemIdentifier("original")
        private static let proposed = NSUserInterfaceItemIdentifier("proposed")
        private static let status = NSUserInterfaceItemIdentifier("status")

        override init() {
            super.init()
            for (id, title, width) in [(Self.original, L10n.string("Original"), 200.0), (Self.proposed, L10n.string("New"), 200.0),
                                       (Self.status, L10n.string("Status"), 120.0)] {
                let column = NSTableColumn(identifier: id)
                column.title = title
                column.width = width
                column.minWidth = 60
                tableView.addTableColumn(column)
            }
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            tableView.style = .plain
            tableView.allowsColumnReordering = false
            tableView.selectionHighlightStyle = .none
            tableView.rowHeight = 18
            tableView.dataSource = self
            tableView.delegate = self
            tableView.setAccessibilityIdentifier("macx.batchRename.preview")
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
        }

        func setRows(_ rows: [BatchRenameRow]) {
            guard rows != self.rows else { return }
            self.rows = rows
            tableView.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, row < rows.count else { return nil }
            let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = id
                f.lineBreakMode = .byTruncatingMiddle
                return f
            }()
            let item = rows[row]
            switch id {
            case Self.original:
                field.stringValue = item.original
                field.textColor = .secondaryLabelColor
            case Self.proposed:
                field.stringValue = item.proposed
                field.textColor = item.status == .unchanged ? .tertiaryLabelColor : .labelColor
            default:
                field.stringValue = BatchRenamePreviewTable.statusText(item.status, extensionChanged: item.extensionChanged)
                field.textColor = item.status.blocksApply ? .systemRed : (item.extensionChanged ? .systemYellow : .tertiaryLabelColor)
            }
            return field
        }
    }
}
