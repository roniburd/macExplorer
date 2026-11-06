import Foundation
import Core
import MacxFS

/// The Columns (Miller) view's model (spec §11 Phase 2): one owned `FolderModel` per visible column. Column 0 is
/// the column root; selecting exactly one folder in column k opens it as column k+1 (closing deeper columns first),
/// any other selection closes the columns after k. Packages, aliases and symlinks never open columns.
/// Every model the chain drops is closed: its read is cancelled and its watcher stopped, so late batches of an
/// intermediate column (held ↓ over many folders) never reach the visible columns (Review Focus 5).
@MainActor
final class ColumnChain {
    typealias ModelFactory = @MainActor (URL) -> FolderModel
    private let makeModel: ModelFactory
    private(set) var models: [FolderModel] = []
    private(set) var activeIndex = 0
    private var tokens: [ObjectIdentifier: ObserverToken] = [:]
    /// A name to select in the root column once it is listed (`reroot(_:selecting:)`, `up()`). Dropped when the
    /// listing completes without it and on any other selection change.
    private var pendingRootSelection: String?
    /// A column entered with `moveRight()` before it was listed: its first row is selected once it is (P2-19: holding
    /// → or pressing → right after a folder was selected). Dropped on any selection in it and when it closes.
    private weak var pendingFirstRow: FolderModel?
    var onChange: (() -> Void)?

    init(root: URL, makeModel: @escaping ModelFactory) {
        self.makeModel = makeModel
        reroot(root, selecting: nil)
    }

    /// Entering Columns from another mode: the current model becomes column 0 as it is (no re-read).
    init(adopting model: FolderModel, makeModel: @escaping ModelFactory) {
        self.makeModel = makeModel
        append(model, start: false)
        selectionDidChange(in: model)
    }

    var activeModel: FolderModel { models[activeIndex] }

    /// Replaces every column with a new root column for `url`; `name` is selected once it is listed.
    func reroot(_ url: URL, selecting name: String?) {
        pendingRootSelection = nil
        truncate(after: -1)
        let m = makeModel(url)
        append(m, start: true)
        activeIndex = 0
        pendingRootSelection = name
        applyPendingRootSelection()
        onChange?()
    }

    func activate(_ index: Int) {
        guard !models.isEmpty else { return }
        let clamped = max(0, min(index, models.count - 1))
        guard clamped != activeIndex else { return }
        pendingFirstRow = nil
        activeIndex = clamped
        onChange?()
    }

    /// Activates column k+1, selecting its first row when it has no selection (which may open the next column).
    @discardableResult func moveRight() -> Bool {
        guard activeIndex + 1 < models.count else { return false }
        activeIndex += 1
        let m = models[activeIndex]
        if m.selection.isEmpty {
            if m.rowCount > 0 { m.select(.set(IndexSet(integer: 0), cursor: 0)) } else { pendingFirstRow = m }
        }
        onChange?()
        return true
    }

    /// Open (Return, ⌘↓, double-click) in column k on the single selected folder that column k+1 already shows:
    /// activates that column (as `moveRight()` from k). false when the selection is anything else, so the Phase 1
    /// open runs (files, packages, links).
    @discardableResult func enterSelectedFolder(of model: FolderModel) -> Bool {
        guard let index = models.firstIndex(where: { $0 === model }), index + 1 < models.count,
              model.selection.count == 1, let url = model.selectedURLs.first,
              url.standardizedFileURL == models[index + 1].directory.standardizedFileURL else { return false }
        activeIndex = index
        return moveRight()
    }

    /// Activates column k−1; its selection stays as it is.
    @discardableResult func moveLeft() -> Bool {
        guard activeIndex > 0 else { return false }
        pendingFirstRow = nil
        activeIndex -= 1
        onChange?()
        return true
    }

    /// The parent column, or (at the root) a new root for the parent folder that selects the old root.
    func up() {
        guard !models.isEmpty else { return }
        if activeIndex > 0 { _ = moveLeft(); return }
        let root = models[0].directory
        let path = root.standardizedFileURL.path(percentEncoded: false)
        guard path != "/", !path.isEmpty else { return }       // already at "/"
        reroot(root.deletingLastPathComponent(), selecting: root.lastPathComponent)
    }

    /// Leaving Columns: closes every other model and hands the active one to the caller. The chain becomes empty.
    func detachActive() -> FolderModel {
        let keep = activeModel
        for m in models where m !== keep { m.close() }
        tokens.values.forEach { $0.cancel() }
        tokens.removeAll()
        models.removeAll()
        activeIndex = 0
        pendingRootSelection = nil
        return keep
    }

    /// Closes every column.
    func close() {
        pendingRootSelection = nil
        truncate(after: -1)
    }

    // MARK: private

    private func append(_ m: FolderModel, start: Bool) {
        models.append(m)
        tokens[ObjectIdentifier(m)] = m.observe { [weak self, weak m] event in
            guard let self, let m else { return }
            switch event {
            case .selection:
                if m === self.models.first { self.pendingRootSelection = nil }
                if m === self.pendingFirstRow { self.pendingFirstRow = nil }
                self.selectionDidChange(in: m)
            case .changes, .state:
                if m === self.models.first { self.applyPendingRootSelection() }
                if m === self.pendingFirstRow { self.applyPendingFirstRow(m) }
            case .beginRename, .relocate, .query, .groups, .folderSizes, .extendedAttributes:
                break
            }
        }
        if start { m.start() }
    }

    private func applyPendingRootSelection() {
        guard let name = pendingRootSelection, let root = models.first else { return }
        guard root.row(named: name) != nil else {
            switch root.state {
            case .complete, .error: pendingRootSelection = nil
            case .loading, .partial, .unresponsive, .waitingForPermission: break
            }
            return
        }
        pendingRootSelection = nil
        root.select(.names([name]))
    }

    private func applyPendingFirstRow(_ m: FolderModel) {
        guard m.selection.isEmpty else { pendingFirstRow = nil; return }
        if m.rowCount > 0 {
            pendingFirstRow = nil
            m.select(.set(IndexSet(integer: 0), cursor: 0))
            return
        }
        switch m.state {
        case .complete, .error: pendingFirstRow = nil
        case .loading, .partial, .unresponsive, .waitingForPermission: break
        }
    }

    private func selectionDidChange(in model: FolderModel) {
        guard let index = models.firstIndex(where: { $0 === model }) else { return }
        let child = singleFolder(model)
        if let child, index + 1 < models.count,
           models[index + 1].directory.standardizedFileURL == child.standardizedFileURL {
            return                                    // same child column: keep it (and its scroll/selection)
        }
        guard child != nil || index + 1 < models.count else { return }   // nothing opens, nothing to close
        truncate(after: index)
        if let child { append(makeModel(child), start: true) }
        onChange?()
    }

    /// The folder to open as the next column: exactly one selected row, and it is a real directory.
    private func singleFolder(_ m: FolderModel) -> URL? {
        guard m.selection.count == 1, let row = m.selection.rows.first, row < m.rowCount,
              m.entry(atRow: row).kind == .directory else { return nil }
        return m.url(atRow: row)
    }

    private func truncate(after index: Int) {
        while models.count > max(index + 1, 0) {
            let m = models.removeLast()
            tokens.removeValue(forKey: ObjectIdentifier(m))?.cancel()
            m.close()
        }
        if activeIndex >= models.count { activeIndex = max(0, models.count - 1) }
    }
}
