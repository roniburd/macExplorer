import Foundation
import MacxFS

/// One row of a grouped table: a group header (group index) or an item (model row).
public enum TableRow: Sendable, Equatable { case header(Int), item(Int) }

/// Table row ⇄ model row mapping of a grouped folder (P2-09): one header row per group, followed by the group's
/// model rows unless the group is collapsed. Lookups are O(log groups).
public struct GroupedRows: Sendable, Equatable {
    public let runs: [GroupRun]
    public let collapsed: Set<GroupKey>
    public let tableRowCount: Int
    /// Table row of each group's header.
    private let headerRows: [Int]

    public init(runs: [GroupRun], collapsed: Set<GroupKey>) {
        self.runs = runs
        self.collapsed = collapsed
        var headers: [Int] = []
        headers.reserveCapacity(runs.count)
        var t = 0
        for run in runs {
            headers.append(t)
            t += 1 + (collapsed.contains(run.key) ? 0 : run.rows.count)
        }
        headerRows = headers
        tableRowCount = t
    }

    public func row(_ tableRow: Int) -> TableRow {
        precondition(tableRow >= 0 && tableRow < tableRowCount, "table row out of range")
        let g = lastHeader(atOrBefore: tableRow)
        let offset = tableRow - headerRows[g]
        return offset == 0 ? .header(g) : .item(runs[g].rows.lowerBound + offset - 1)
    }

    public func tableRow(forGroup group: Int) -> Int { headerRows[group] }

    public func group(containingModelRow m: Int) -> Int? {
        var lo = 0, hi = runs.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, r = runs[mid].rows
            if m < r.lowerBound { hi = mid - 1 } else if m >= r.upperBound { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    /// nil if the model row's group is collapsed (or the row is not in any group).
    public func tableRow(forModelRow m: Int) -> Int? {
        guard let g = group(containingModelRow: m), !collapsed.contains(runs[g].key) else { return nil }
        return headerRows[g] + 1 + (m - runs[g].rows.lowerBound)
    }

    /// Headers (and rows out of range) are dropped.
    public func modelRows(forTableRows rows: IndexSet) -> IndexSet {
        var out = IndexSet()
        for t in rows where t >= 0 && t < tableRowCount {
            if case .item(let m) = row(t) { out.insert(m) }
        }
        return out
    }

    /// Rows of collapsed groups are dropped.
    public func tableRows(forModelRows rows: IndexSet) -> IndexSet {
        var out = IndexSet()
        for m in rows {
            if let t = tableRow(forModelRow: m) { out.insert(t) }
        }
        return out
    }

    private func lastHeader(atOrBefore t: Int) -> Int {
        var lo = 0, hi = headerRows.count - 1, answer = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if headerRows[mid] <= t { answer = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return answer
    }
}
