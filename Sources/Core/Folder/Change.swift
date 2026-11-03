import Foundation

/// Applied in array order inside one beginUpdates/endUpdates. Each change's indices are relative to the
/// row state produced by the preceding changes (NSTableView semantics). `reload` changes come last and
/// use final indices.
public enum Change: Sendable, Equatable {
    case insert(IndexSet)
    case remove(IndexSet)
    case reload(IndexSet)
    case move(from: Int, to: Int)
    case reset
}

/// One update for a folder view (§4.3). A reset, or more than ~1,000 touched rows, is applied with
/// reloadData and no animation.
public struct ChangeSet: Sendable, Equatable {
    public static let reloadDataThreshold = 1_000

    public var changes: [Change]

    public init(_ changes: [Change]) { self.changes = changes }

    public static let reset = ChangeSet([.reset])

    /// Rows named by insert/remove/reload index sets, plus one per move. A reset contributes 0
    /// (`requiresReloadData` covers it).
    public var touchedRowCount: Int {
        changes.reduce(0) { total, change in
            switch change {
            case .insert(let rows), .remove(let rows), .reload(let rows): total + rows.count
            case .move: total + 1
            case .reset: total
            }
        }
    }

    /// Contains `.reset` or touchedRowCount > 1_000.
    public var requiresReloadData: Bool {
        changes.contains(.reset) || touchedRowCount > Self.reloadDataThreshold
    }

    /// True when applying the set changes nothing (no changes, or only empty index sets).
    public var isEmpty: Bool {
        changes.allSatisfy { change in
            switch change {
            case .insert(let rows), .remove(let rows), .reload(let rows): rows.isEmpty
            case .move, .reset: false
            }
        }
    }
}
