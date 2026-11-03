import Foundation
import MacxFS

/// One row of a hand-built EntryStore for diff tests.
struct Row: Equatable {
    var id: UInt64
    var name: String
    var mtime: Int64 = 0
    var size: Int64 = 0
    var hidden = false

    init(_ id: UInt64, _ name: String, mtime: Int64 = 0, size: Int64 = 0, hidden: Bool = false) {
        self.id = id
        self.name = name
        self.mtime = mtime
        self.size = size
        self.hidden = hidden
    }
}

enum StoreBuilder {
    /// Rows in storage order. `order` lists storage indices of displayed rows; nil = every non-hidden row in
    /// storage order.
    static func store(_ rows: [Row], order: [UInt32]? = nil, mode: IdentityMode = .objectID) -> EntryStore {
        var store = EntryStore(identityMode: mode)
        var batch = Batch(generation: .initial)
        for r in rows {
            let e = Entry(rowID: r.id, fileID: r.id, size: r.size, allocSize: 0, mtime: r.mtime, ctime: 0,
                          nameOffset: 0, nameLen: 0, kind: .file, flags: r.hidden ? .bsdHidden : [], typeIndex: 0)
            Array(r.name.utf8).withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
        }
        store.append(batch)
        store.setOrder(order ?? rows.indices.filter { !rows[$0].hidden }.map { UInt32($0) })
        return store
    }

    /// Displayed rows' identities in display order.
    static func visibleIDs(_ store: EntryStore) -> [RowID] {
        (0..<store.visibleCount).map { store.identity(store.storageIndex(forRow: $0)) }
    }

    static func visibleNames(_ store: EntryStore) -> [String] {
        (0..<store.visibleCount).map { store.name(store.storageIndex(forRow: $0)) }
    }
}
