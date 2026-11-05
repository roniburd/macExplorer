import Foundation
import MacxFS

/// Folder-size storage (§11 Phase 2). P2-13 adds the table a `FolderSizeSession` fills; P2-14 adds the enable
/// flag, sorting by size and the selection total.
extension FolderModel {
    /// The recursive size of the folder or package at `row`, once a session computed it (or found it cached).
    public func folderSize(atRow row: Int) -> FolderSize? {
        sizeTable.isEmpty ? nil : sizeTable[identity(atRow: row)]
    }

    /// "Calculate Folder Sizes" for the view showing this model. Turning it off clears the table, emits
    /// `.folderSizes` for every row that had a size (so cells go back to "--") and, under the size sort, re-sorts
    /// folders back into name order.
    public func setFolderSizesEnabled(_ on: Bool) {
        guard on != folderSizesEnabled, !closed else { return }
        folderSizesEnabled = on
        guard !on else { return }
        sizeResortTask?.cancel()
        sizeResortTask = nil
        let old = Set(sizeTable.keys)
        sizeTable = [:]
        if !old.isEmpty { emit(.folderSizes(old)) }
        if query.sort.field == .size, !old.isEmpty, state == .complete {
            enqueue { [weak self] in await self?.resortNow() }
        }
    }

    /// Stores sizes for rows still in the store and emits `.folderSizes` with those rows. Under the size sort it
    /// schedules a re-sort, coalesced to at most one per `FolderContext.resortCoalescing`.
    public func setFolderSizes(_ sizes: [RowID: FolderSize]) {
        guard !closed else { return }
        var changed = Set<RowID>()
        for (id, size) in sizes where store.firstIndex(of: id) != nil {
            if sizeTable[id] != size { changed.insert(id) }
            sizeTable[id] = size
        }
        guard !changed.isEmpty else { return }
        emit(.folderSizes(changed))
        if query.sort.field == .size { scheduleSizeResort() }
    }

    /// Folder sizes by identity for the worker's size sort (empty unless sorted by size).
    func sortSizes() -> [RowID: Int64] {
        guard query.sort.field == .size, !sizeTable.isEmpty else { return [:] }
        return sizeTable.mapValues(\.bytes)
    }

    /// After every store replacement or mutation: entries of rows that left the store are dropped.
    func pruneFolderSizes() {
        guard !sizeTable.isEmpty else { return }
        let store = self.store
        sizeTable = sizeTable.filter { store.firstIndex(of: $0.key) != nil }
    }

    /// One pending re-sort: it waits `resortCoalescing`, then re-sorts with the sizes known by then. Sizes arriving
    /// meanwhile join it. A folder still loading re-sorts with the sizes when it completes (finishLoad passes them).
    private func scheduleSizeResort() {
        guard sizeResortTask == nil else { return }
        let delay = context.resortCoalescing
        sizeResortTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) } else { await Task.yield() }
            guard let self, !Task.isCancelled else { return }
            self.sizeResortTask = nil
            guard !self.closed, self.state == .complete, self.query.sort.field == .size else { return }
            self.enqueue { [weak self] in await self?.resortNow() }
        }
    }
}
