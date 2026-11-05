import Foundation
import MacxFS

/// The canonical selection of a folder view (§5.5): identities, plus their display rows in the current order.
public struct Selection: Sendable, Equatable {
    public private(set) var ids: Set<RowID> = []
    public private(set) var rows = IndexSet()           // display rows of `ids` in the current order
    public private(set) var anchor: RowID?              // ⇧ range anchor
    public private(set) var cursor: RowID?              // keyboard focus row

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }
    public static let empty = Selection()

    private init() {}
}

public enum SelectionCommand: Sendable, Equatable {
    case set(IndexSet, cursor: Int?)                // plain click / arrows
    case toggle(Int)                                // ⌘-click
    /// ⇧-click / ⇧-arrow from the anchor. `excluding`: rows the user cannot see (collapsed groups, P2-10), left out.
    case extend(to: Int, excluding: IndexSet = [])
    case add(IndexSet)                              // additive rubber band
    case all, none, invert
    case names([String])                            // select by name (after paste/new/address "file")
}

public struct SelectionSummary: Sendable, Equatable {
    public var count: Int
    public var files: Int
    public var folders: Int
    public var bytes: Int64                         // files only; folders excluded in Phase 1
    /// Folder sizes on (P2-14): the selected folders' and packages' computed sizes (0 if none is selected), nil while
    /// any of them is unknown. Folder sizes off: nil.
    public var folderBytes: Int64?
    public init(count: Int, files: Int, folders: Int, bytes: Int64, folderBytes: Int64? = nil) {
        self.count = count
        self.files = files
        self.folders = folders
        self.bytes = bytes
        self.folderBytes = folderBytes
    }
}

/// Row space a Selection is applied against. Closures are called synchronously and never stored.
struct SelectionRowSpace {
    let count: Int
    let identity: (Int) -> RowID
    let row: (RowID) -> Int?
    /// Display rows of the given names, resolved in one pass over the store (names not displayed are left out).
    let rowsNamed: ([String]) -> IndexSet
}

extension Selection {
    mutating func apply(_ command: SelectionCommand, in space: SelectionRowSpace) {
        let valid = { (rows: IndexSet) in rows.filteredIndexSet { $0 >= 0 && $0 < space.count } }
        switch command {
        case .set(let rows, let cursorRow):
            let r = valid(rows)
            setRows(r, in: space)
            let c = cursorRow.flatMap { $0 >= 0 && $0 < space.count ? $0 : nil } ?? r.first
            cursor = c.map(space.identity)
            anchor = cursor
        case .toggle(let row):
            guard row >= 0, row < space.count else { return }
            var r = rows
            if r.contains(row) { r.remove(row) } else { r.insert(row) }
            setRows(r, in: space)
            cursor = space.identity(row)
            anchor = cursor
        case .extend(let row, let hidden):
            guard row >= 0, row < space.count else { return }
            let a = anchor.flatMap(space.row) ?? row
            setRows(IndexSet(integersIn: min(a, row)...max(a, row)).subtracting(hidden), in: space)
            cursor = space.identity(row)
            if anchor.flatMap(space.row) == nil { anchor = cursor }
        case .add(let rows):
            setRows(self.rows.union(valid(rows)), in: space)
        case .all:
            setRows(IndexSet(integersIn: 0..<space.count), in: space)
        case .none:
            setRows([], in: space)
            anchor = nil
            cursor = nil
        case .invert:
            setRows(IndexSet(integersIn: 0..<space.count).subtracting(rows), in: space)
        case .names(let names):
            let r = space.rowsNamed(names)
            setRows(r, in: space)
            cursor = r.first.map(space.identity)
            anchor = cursor
        }
    }

    /// After the order changed: rows from ids; ids that vanished are dropped.
    mutating func reconcile(in space: SelectionRowSpace) {
        var kept = Set<RowID>(), r = IndexSet()
        for id in ids {
            if let row = space.row(id) { kept.insert(id); r.insert(row) }
        }
        ids = kept
        rows = r
        if let a = anchor, space.row(a) == nil { anchor = nil }
        if let c = cursor, space.row(c) == nil { cursor = nil }
    }

    /// Moves identity-keyed state from `old` to `new` (atomic-save replacement, rename on a name-identity volume).
    /// `rows` is refreshed by the next reconcile.
    mutating func substitute(_ old: RowID, with new: RowID) {
        if ids.remove(old) != nil { ids.insert(new) }
        if anchor == old { anchor = new }
        if cursor == old { cursor = new }
    }

    private mutating func setRows(_ r: IndexSet, in space: SelectionRowSpace) {
        rows = r
        ids = Set(r.map(space.identity))
    }
}
