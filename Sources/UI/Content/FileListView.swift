import AppKit
import Core

/// Shared by Details and Icons (§5.5). The content controller is the only FolderModel observer and forwards
/// changes here; views never keep their own selection.
@MainActor protocol FileListView: AnyObject {
    var view: NSView { get }
    var folder: FolderModel? { get }
    func bind(_ folder: FolderModel?)                    // nil = unbind
    func apply(_ changes: ChangeSet)                     // insert/remove/move/reload or reloadData (requiresReloadData)
    func reloadSelectionDrawing()
    func beginInlineRename(row: Int)
    func scrollToRow(_ row: Int)
    func topVisibleRow() -> Int?                          // scroll anchor
    func visibleRows() -> Range<Int>                      // Tier 1 icon requests
}

/// Lists that take keyboard focus (Tab cycle, view switches keep focus on the list).
@MainActor protocol FocusableList: AnyObject {
    var focusView: NSView { get }
}

/// Target of ChangeApplier (NSTableView in production, a recorder in tests).
@MainActor protocol RowUpdateSink {
    func reloadAll()
    func beginRowUpdates()
    func insertRows(_ rows: IndexSet)
    func removeRows(_ rows: IndexSet)
    func moveRow(_ from: Int, _ to: Int)
    func reloadRows(_ rows: IndexSet)
    func endRowUpdates()
}

@MainActor
enum ChangeApplier {
    /// §4.3: a reset or more than ~1,000 touched rows → reloadData with no animation. Otherwise structural changes
    /// in order inside one begin/end pair (NSTableView semantics), then reloads, which use final indices.
    static func apply(_ set: ChangeSet, to sink: some RowUpdateSink) {
        if set.isEmpty { return }
        if set.requiresReloadData { sink.reloadAll(); return }
        var reloads = IndexSet()
        sink.beginRowUpdates()
        for change in set.changes {
            switch change {
            case .insert(let rows): sink.insertRows(rows)
            case .remove(let rows): sink.removeRows(rows)
            case .move(let from, let to): sink.moveRow(from, to)
            case .reload(let rows): reloads.formUnion(rows)
            case .reset: break   // covered by requiresReloadData
            }
        }
        sink.endRowUpdates()
        if !reloads.isEmpty { sink.reloadRows(reloads) }
    }
}

@MainActor
struct TableUpdateSink: RowUpdateSink {
    let tableView: NSTableView
    let animate: Bool
    private var options: NSTableView.AnimationOptions { animate ? .effectFade : [] }
    func reloadAll() { tableView.reloadData() }
    func beginRowUpdates() { tableView.beginUpdates() }
    func insertRows(_ rows: IndexSet) { tableView.insertRows(at: rows, withAnimation: options) }
    func removeRows(_ rows: IndexSet) { tableView.removeRows(at: rows, withAnimation: options) }
    func moveRow(_ from: Int, _ to: Int) { tableView.moveRow(at: from, to: to) }
    func reloadRows(_ rows: IndexSet) {
        let valid = rows.filteredIndexSet { $0 < tableView.numberOfRows }
        tableView.reloadData(forRowIndexes: valid, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }
    func endRowUpdates() { tableView.endUpdates() }
}
