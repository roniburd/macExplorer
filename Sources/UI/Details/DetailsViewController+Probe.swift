import AppKit
import Core
import MacxFS

/// Test and scenario probes (ScenarioHooks: visibleRowNames, groupHeaderTitles, visibleColumnIDs, cellText; the
/// header: click target) and the clicks unit tests drive.
extension DetailsViewController {
    /// A plain, ⌘- or ⇧-click on table row `row` (what mouse-down and mouse-up do together): a header toggles its
    /// group, an item row goes to the selection as its model row.
    func clickTableRow(_ row: Int, modifiers: ClickModifiers) {
        guard let source else { return }
        let mapping = self.mapping
        if let group = mapping.groupIndex(forTableRow: row) { toggleGroup(group); return }
        switch SelectionController.click(row: mapping.modelRow(forTableRow: row), clickCount: 1, modifiers: modifiers,
                                         selectedRows: source.selection.rows, hidden: mapping.hiddenModelRows) {
        case .select(let command), .selectOnMouseUp(let command): source.select(command)
        case .open, .nothing: break
        }
        reloadSelectionDrawing()
    }

    /// Scenario hook `groupHeaderTitles`: "<title> (<count>)" per group.
    func groupHeaderTitles() -> [String] {
        groupRuns.map { "\(GroupTitles.title(for: $0.key)) (\($0.rows.count))" }
    }

    /// Scenario hook `visibleRowNames`: the names of the table's item rows, in order.
    func visibleRowNames() -> [String] {
        guard let source else { return [] }
        let mapping = self.mapping
        return (0..<mapping.tableRowCount).compactMap { mapping.modelRow(forTableRow: $0) }.filter { $0 < source.rowCount }
            .map { source.name(atRow: $0) }
    }

    func cellView(row: Int, column: ColumnID) -> NSTableCellView? {
        let index = tableView.column(withIdentifier: DetailsColumns.identifier(column))
        guard index >= 0, row < tableView.numberOfRows else { return nil }
        return tableView.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    /// Scenario hook `visibleColumnIDs` (P2-16): the shown columns' ColumnID raw values, in table order.
    func visibleColumnIDs() -> [String] {
        tableView.tableColumns.filter { !$0.isHidden }.compactMap { DetailsColumns.columnID($0.identifier)?.rawValue }
    }

    /// Scenario click target "header:<id>" (P2-16): the same path as a click on that column's header.
    @discardableResult
    func clickHeader(_ raw: String) -> Bool {
        guard let id = ColumnID(rawValue: raw), source != nil else { return false }
        let index = tableView.column(withIdentifier: DetailsColumns.identifier(id))
        guard index >= 0, !tableView.tableColumns[index].isHidden else { return false }
        tableView(tableView, didClick: tableView.tableColumns[index])
        return true
    }

    /// Scenario hook `cellText` (P2-14): the text the cell of `name`'s row shows in `column` (a ColumnID raw value),
    /// computed with the same formatting the cell uses. nil for an unknown row or column.
    func cellText(rowNamed name: String, column: String) -> String? {
        guard let source, let id = ColumnID(rawValue: column),
              let row = folder.map({ $0.row(named: name) }) ?? (0..<source.rowCount).first(where: { source.name(atRow: $0) == name }),
              row < source.rowCount else {
            return nil
        }
        return text(for: id, row: row)
    }
}
