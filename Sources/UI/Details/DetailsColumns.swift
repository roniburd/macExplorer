import AppKit
import Core
import MacxFS

/// Column definitions and the pure rules behind header menus, persistence, sorting and auto-fit (§5.5).
@MainActor
enum DetailsColumns {
    static let defaults: [ColumnSetting] = Settings.defaultColumns
    /// Columns the table shows and the header chooser offers. P2-16 offers the Phase 2 columns.
    static let offered: [ColumnID] = Array(ColumnID.allCases.prefix(6))
    private static let prefix = "macx.column."

    static func identifier(_ id: ColumnID) -> NSUserInterfaceItemIdentifier { .init(prefix + id.rawValue) }

    static func columnID(_ identifier: NSUserInterfaceItemIdentifier) -> ColumnID? {
        guard identifier.rawValue.hasPrefix(prefix) else { return nil }
        return ColumnID(rawValue: String(identifier.rawValue.dropFirst(prefix.count)))
    }

    static func title(_ id: ColumnID) -> String {
        switch id {
        case .name: L10n.string("Name")
        case .dateModified: L10n.string("Date Modified")
        case .size: L10n.string("Size")
        case .kind: L10n.string("Kind")
        case .dateCreated: L10n.string("Date Created")
        case .fileExtension: L10n.string("Extension")
        case .tags: L10n.string("Tags")
        case .dateLastOpened: L10n.string("Date Last Opened")
        case .permissions: L10n.string("Permissions")
        case .owner: L10n.string("Owner")
        case .path: L10n.string("Path")
        case .comments: L10n.string("Comments")
        }
    }

    static func minWidth(_ id: ColumnID) -> Double { id == .name ? 120 : 50 }

    /// Every ColumnID exactly once (stored order first), widths clamped, Name always visible.
    static func normalized(_ columns: [ColumnSetting]) -> [ColumnSetting] {
        var seen = Set<ColumnID>()
        var result: [ColumnSetting] = []
        for column in columns where !seen.contains(column.id) {
            seen.insert(column.id)
            result.append(ColumnSetting(id: column.id, width: max(column.width, minWidth(column.id)),
                                        visible: column.id == .name ? true : column.visible))
        }
        for column in defaults where !seen.contains(column.id) { result.append(column) }
        return result
    }

    static func toggling(_ columns: [ColumnSetting], _ id: ColumnID) -> [ColumnSetting] {
        normalized(columns).map { column in
            column.id == id && id != .name ? ColumnSetting(id: column.id, width: column.width, visible: !column.visible) : column
        }
    }

    static func settings(fromTableColumns columns: [NSTableColumn]) -> [ColumnSetting] {
        normalized(columns.compactMap { column in
            columnID(column.identifier).map { ColumnSetting(id: $0, width: Double(column.width), visible: !column.isHidden) }
        })
    }

    /// Clicking the sorted column reverses it; another column sorts ascending by that field.
    static func nextSort(current: MacxFS.SortDescriptor, clicked: ColumnID) -> MacxFS.SortDescriptor {
        let field = clicked.sortField
        return MacxFS.SortDescriptor(field: field, ascending: current.field == field ? !current.ascending : true)
    }

    /// Auto-fit width (double-click a divider): widest of the given texts plus `extra` (icon, padding).
    static func fitWidth(texts: [String], font: NSFont, extra: Double) -> Double {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widest = texts.reduce(0.0) { max($0, Double(($1 as NSString).size(withAttributes: attributes).width)) }
        return (widest + extra).rounded(.up)
    }

    static func headerMenu(columns: [ColumnSetting], target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: L10n.string("Columns"))
        for column in normalized(columns) where column.id != .name && offered.contains(column.id) {
            let item = NSMenuItem(title: title(column.id), action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = column.id.rawValue
            item.state = column.visible ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}
