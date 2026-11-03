import Core
import Foundation

/// Applies a ChangeSet to an array of row tokens with NSTableView semantics: structural changes in array order,
/// each relative to the state the preceding changes produced; `reload` uses final indices. Inserted rows become
/// nil. Invalid indices are reported as failures instead of trapping.
struct ChangeSimulator {
    struct Outcome {
        var rows: [Int?]            // old display row of each final row; nil = inserted
        var reloaded: IndexSet      // final indices
        var sawReset: Bool
        var failures: [String]
    }

    static func apply(_ set: ChangeSet, toRowCount count: Int) -> Outcome {
        var rows: [Int?] = Array(0..<count)
        var reloaded = IndexSet()
        var failures: [String] = []
        var sawReset = false
        var sawReload = false
        for change in set.changes {
            switch change {
            case .reset:
                sawReset = true
            case .remove(let set):
                if sawReload { failures.append("structural change after reload") }
                for index in set.reversed() {
                    guard index < rows.count else { failures.append("remove \(index) out of range \(rows.count)"); continue }
                    rows.remove(at: index)
                }
            case .insert(let set):
                if sawReload { failures.append("structural change after reload") }
                for index in set {
                    guard index <= rows.count else { failures.append("insert \(index) out of range \(rows.count)"); continue }
                    rows.insert(nil, at: index)
                }
            case .move(let from, let to):
                if sawReload { failures.append("structural change after reload") }
                guard from < rows.count, to < rows.count else {
                    failures.append("move \(from)>\(to) out of range \(rows.count)")
                    continue
                }
                let token = rows.remove(at: from)
                rows.insert(token, at: to)
            case .reload(let set):
                sawReload = true
                reloaded.formUnion(set)
            }
        }
        if let last = reloaded.last, last >= rows.count { failures.append("reload \(last) out of range \(rows.count)") }
        return Outcome(rows: rows, reloaded: reloaded, sawReset: sawReset, failures: failures)
    }
}
