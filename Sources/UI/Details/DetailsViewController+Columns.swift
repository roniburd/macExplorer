import AppKit
import Core
import MacxFS

/// Columns: building them from the view state, the header's chooser, fitting the pane, sorting by a header click.
extension DetailsViewController {
    func rebuildColumns() {
        isRebuildingColumns = true
        defer { isRebuildingColumns = false }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        let available = Set(DetailsColumns.availableColumns(isMultiFolder: isMultiFolder))
        for setting in columns where available.contains(setting.id) {
            let definition = ExtendedColumns.definition(setting.id)
            let column = NSTableColumn(identifier: DetailsColumns.identifier(setting.id))
            column.title = definition.title
            column.minWidth = DetailsColumns.minWidth(setting.id)
            column.width = setting.width
            column.isHidden = !setting.visible
            column.resizingMask = .userResizingMask
            column.headerCell.alignment = definition.alignment
            tableView.addTableColumn(column)
        }
        tableView.headerView?.menu = headerMenu()
        updateSortIndicator(source?.sortDescriptor ?? settings.sort)
        requestVisibleAttributes()
        fittedWidths = [:]              // the columns carry their stored widths again
        isRebuildingColumns = false
        fitColumnsToWidth()
    }

    /// The header's column chooser (right-click on the header).
    func headerMenu() -> NSMenu {
        DetailsColumns.headerMenu(columns: columns, isMultiFolder: isMultiFolder, target: self, action: #selector(toggleColumn(_:)))
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ColumnID(rawValue: raw) else { return }
        setColumns(DetailsColumns.toggling(merged(shownColumnSettings()), id))
        rebuildColumns()
    }

    @objc func columnsChanged(_ note: Notification) {
        guard !isRebuildingColumns else { return }
        let next = merged(shownColumnSettings())
        if next != columns { setColumns(next) }
        fitColumnsToWidth()
    }

    /// The column the user is dragging the edge of, if any.
    private var userResizedColumn: NSTableColumn? {
        let index = tableView.headerView?.resizedColumn ?? -1
        return index >= 0 && index < tableView.tableColumns.count ? tableView.tableColumns[index] : nil
    }

    /// Shrinks visible columns, the rightmost first and each down to its minimum, so they fit the visible width, and
    /// gives them their stored widths back as room returns. Display only: the folder keeps its stored widths (a narrow
    /// pane, e.g. with the preview pane open, no longer pushes Size and Kind off the edge behind a scroller). A column
    /// the user is dragging keeps the width they give it.
    func fitColumnsToWidth() {
        guard !isRebuildingColumns else { return }
        let available = scrollView.contentView.bounds.width
        guard available > 0 else { return }
        let visible = tableView.tableColumns.filter { !$0.isHidden }
        let dragged = userResizedColumn
        let ids = visible.map { DetailsColumns.columnID($0.identifier) }
        let stored = zip(visible, ids).map { column, id in
            column === dragged ? column.width : (id.flatMap { fittedWidths[$0] } ?? column.width)
        }
        var targets = stored
        // What the table adds around its columns (gaps, the full-width style's padding), measured, not assumed.
        tableView.tile()
        // (the last column's right edge: the table's frame also stretches to fill a wider pane).
        guard let lastIndex = tableView.tableColumns.lastIndex(where: { !$0.isHidden }) else { return }
        let overhead = max(0, tableView.rect(ofColumn: lastIndex).maxX - visible.reduce(CGFloat(0)) { $0 + $1.width })
        var overflow = stored.reduce(0, +) + overhead - available
        for index in visible.indices.reversed() where overflow > 0.5 && visible[index] !== dragged {
            let give = min(overflow, max(0, targets[index] - visible[index].minWidth))
            targets[index] -= give
            overflow -= give
        }
        var fitted: [ColumnID: CGFloat] = [:]
        for (index, id) in ids.enumerated() {
            targets[index] = max(visible[index].minWidth, targets[index].rounded(.down))
            if let id, targets[index] < stored[index] { fitted[id] = stored[index] }
        }
        fittedWidths = fitted
        isRebuildingColumns = true
        defer { isRebuildingColumns = false }
        for (column, target) in zip(visible, targets) where abs(column.width - target) >= 0.5 { column.width = target }
    }

    /// The table's columns as settings, with the columns `fitColumnsToWidth` shrank at their stored widths (except the
    /// one the user is dragging: its new width is the one to store).
    private func shownColumnSettings() -> [ColumnSetting] {
        if let dragged = userResizedColumn, let id = DetailsColumns.columnID(dragged.identifier) { fittedWidths[id] = nil }
        let shown = DetailsColumns.settings(fromTableColumns: tableView.tableColumns)
        guard !fittedWidths.isEmpty else { return shown }
        return shown.map { setting in
            fittedWidths[setting.id].map { ColumnSetting(id: setting.id, width: Double($0), visible: setting.visible) } ?? setting
        }
    }

    /// The table only holds the available columns: the others (Path in a folder listing) keep their stored width
    /// and visibility.
    private func merged(_ shown: [ColumnSetting]) -> [ColumnSetting] {
        let offered = Set(DetailsColumns.availableColumns(isMultiFolder: isMultiFolder))
        let stored = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return DetailsColumns.normalized(shown.map { offered.contains($0.id) ? $0 : (stored[$0.id] ?? $0) })
    }

    func updateSortIndicator(_ sort: MacxFS.SortDescriptor) {
        tableView.highlightedTableColumn = nil
        for column in tableView.tableColumns {
            let sorted = DetailsColumns.columnID(column.identifier)?.sortField == sort.field
            tableView.setIndicatorImage(sorted ? NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil,
                                        in: column)
            if sorted { tableView.highlightedTableColumn = column }
        }
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let id = DetailsColumns.columnID(tableColumn.identifier) else { return }
        sort(by: id)
    }

    /// A header click on `column`: the sorted column reverses, another sorts ascending. A folder's sort is saved in
    /// its view state (the session sets the query); search results sort themselves (`.path` included).
    func sort(by column: ColumnID) {
        guard let source else { return }
        let next = DetailsColumns.nextSort(current: source.sortDescriptor, clicked: column)
        if folder != nil, let onSortChanged {
            onSortChanged(next)          // saved for this folder; the session sets the query
        } else {
            source.setSortDescriptor(next)
        }
        updateSortIndicator(next)
    }

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        let tableColumn = tableView.tableColumns[column]
        guard let source, let id = DetailsColumns.columnID(tableColumn.identifier) else { return tableColumn.width }
        let texts = visibleRows().filter { $0 < source.rowCount }.map { text(for: id, row: $0) } + [tableColumn.title]
        let extra = id == .name ? iconPoints + 30 : 14
        return CGFloat(max(DetailsColumns.minWidth(id), DetailsColumns.fitWidth(texts: texts, font: CellStyle.font, extra: extra)))
    }
}
