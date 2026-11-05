import Foundation
import Core

/// Table row ⇄ model row mapping of the Details list (P2-10). Ungrouped folders use the identity; grouped ones add
/// one header row per group and hide the rows of collapsed groups. Every conversion between `NSTableView` rows and
/// FolderModel rows in Details goes through this.
enum RowMapping: Equatable, Sendable {
    case identity(count: Int)
    case grouped(GroupedRows)

    var tableRowCount: Int {
        switch self {
        case .identity(let n): n
        case .grouped(let g): g.tableRowCount
        }
    }

    var isGrouped: Bool { if case .grouped = self { true } else { false } }

    /// nil for headers and rows out of range.
    func modelRow(forTableRow row: Int) -> Int? {
        switch self {
        case .identity(let n): return row >= 0 && row < n ? row : nil
        case .grouped(let g):
            guard row >= 0, row < g.tableRowCount, case .item(let m) = g.row(row) else { return nil }
            return m
        }
    }

    /// nil if the row's group is collapsed (or the row is out of range).
    func tableRow(forModelRow row: Int) -> Int? {
        switch self {
        case .identity(let n): row >= 0 && row < n ? row : nil
        case .grouped(let g): g.tableRow(forModelRow: row)
        }
    }

    func modelRows(forTableRows rows: IndexSet) -> IndexSet {
        switch self {
        case .identity(let n): rows.filteredIndexSet { $0 >= 0 && $0 < n }
        case .grouped(let g): g.modelRows(forTableRows: rows)
        }
    }

    func tableRows(forModelRows rows: IndexSet) -> IndexSet {
        switch self {
        case .identity(let n): rows.filteredIndexSet { $0 >= 0 && $0 < n }
        case .grouped(let g): g.tableRows(forModelRows: rows)
        }
    }

    /// The group whose header is `row`; nil for item rows, out-of-range rows and ungrouped lists.
    func groupIndex(forTableRow row: Int) -> Int? {
        guard case .grouped(let g) = self, row >= 0, row < g.tableRowCount, case .header(let group) = g.row(row) else { return nil }
        return group
    }

    /// Next visible item `delta` steps away (±1), skipping headers and collapsed groups; nil at either end.
    /// A model row inside a collapsed group starts from its group's header.
    func adjacentVisibleModelRow(from modelRow: Int, by delta: Int) -> Int? {
        switch self {
        case .identity(let n):
            let next = modelRow + delta
            return next >= 0 && next < n ? next : nil
        case .grouped(let g):
            guard let start = anchorTableRow(forModelRow: modelRow, in: g) else { return nil }
            return firstItem(in: g, from: start + delta, step: delta)
        }
    }

    /// The first (last) item a user can see; nil when every group is collapsed or the list is empty.
    var firstVisibleModelRow: Int? {
        switch self {
        case .identity(let n): n > 0 ? 0 : nil
        case .grouped(let g): firstItem(in: g, from: 0, step: 1)
        }
    }

    var lastVisibleModelRow: Int? {
        switch self {
        case .identity(let n): n > 0 ? n - 1 : nil
        case .grouped(let g): firstItem(in: g, from: g.tableRowCount - 1, step: -1)
        }
    }

    /// The visible item nearest to table row `row`: at or after it in `direction`, else on the other side.
    func nearestVisibleModelRow(toTableRow row: Int, direction: Int) -> Int? {
        switch self {
        case .identity(let n):
            return n > 0 ? min(max(row, 0), n - 1) : nil
        case .grouped(let g):
            let step = direction < 0 ? -1 : 1
            let clamped = min(max(row, 0), max(g.tableRowCount - 1, 0))
            return firstItem(in: g, from: clamped, step: step) ?? firstItem(in: g, from: clamped, step: -step)
        }
    }

    /// Table row a model row's navigation starts from: its own row, or its collapsed group's header.
    func anchorTableRow(forModelRow modelRow: Int) -> Int? {
        switch self {
        case .identity(let n): modelRow >= 0 && modelRow < n ? modelRow : nil
        case .grouped(let g): anchorTableRow(forModelRow: modelRow, in: g)
        }
    }

    private func anchorTableRow(forModelRow modelRow: Int, in g: GroupedRows) -> Int? {
        if let t = g.tableRow(forModelRow: modelRow) { return t }
        if let group = g.group(containingModelRow: modelRow) { return g.tableRow(forGroup: group) }
        return nil
    }

    private func firstItem(in g: GroupedRows, from start: Int, step: Int) -> Int? {
        var t = start
        while t >= 0 && t < g.tableRowCount {
            if case .item(let m) = g.row(t) { return m }
            t += step
        }
        return nil
    }
}
