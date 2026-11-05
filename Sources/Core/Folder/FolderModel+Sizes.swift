import Foundation
import MacxFS

/// Folder-size storage (§11 Phase 2). P2-13 adds the table a `FolderSizeSession` fills; P2-14 adds the enable
/// flag, sorting by size and the selection total.
extension FolderModel {
    /// The recursive size of the folder or package at `row`, once a session computed it (or found it cached).
    public func folderSize(atRow row: Int) -> FolderSize? {
        sizeTable.isEmpty ? nil : sizeTable[identity(atRow: row)]
    }

    /// Stores sizes for rows still in the store and emits `.folderSizes` with those rows.
    public func setFolderSizes(_ sizes: [RowID: FolderSize]) {
        guard !closed else { return }
        var changed = Set<RowID>()
        for (id, size) in sizes where store.firstIndex(of: id) != nil {
            if sizeTable[id] != size { changed.insert(id) }
            sizeTable[id] = size
        }
        if !changed.isEmpty { emit(.folderSizes(changed)) }
    }

    /// After every store replacement or mutation: entries of rows that left the store are dropped.
    func pruneFolderSizes() {
        guard !sizeTable.isEmpty else { return }
        let store = self.store
        sizeTable = sizeTable.filter { store.firstIndex(of: $0.key) != nil }
    }
}
