import Foundation

/// Values for an extended sort column (P2-16), by storage index; missing values sort last in both directions.
/// Both forms are contiguous columns the Phase 1 `Ordering` sorts on directly (one sort, §4.4 re-sort budget).
public enum ExtraSortValues: Sendable {
    case integers([Int64?])
    /// One `SortKeys.nameKey(isFolder: false)` key per storage index in one arena; an empty key is a missing value.
    case strings(SortKeyColumn)

    /// `.strings` from one optional key per storage index (nil or empty = missing).
    public static func stringKeys(_ keys: [[UInt8]?]) -> ExtraSortValues {
        var column = SortKeyColumn()
        column.reserve(keys: keys.count, bytes: keys.reduce(0) { $0 + ($1?.count ?? 0) })
        for key in keys { column.append(key ?? []) }
        return .strings(column)
    }

    var count: Int {
        switch self {
        case .integers(let values): values.count
        case .strings(let keys): keys.count
        }
    }
}

/// An extended column's values keyed by identity: what main hands the folder worker, which maps them to the
/// storage indices of the store it sorts (`SortExtras.make`), since main cannot know them for a store the worker
/// builds (P2-13/P2-14 notes). Missing identities sort last.
public enum ExtraColumnValues: Sendable {
    case integers([RowID: Int64])
    case strings([RowID: [UInt8]])                // SortKeys.nameKey(isFolder: false) bytes
}

/// Sort inputs that are not in the EntryStore (§11 Phase 2): computed folder sizes now, extended-column values
/// from P2-16.
public struct SortExtras: Sendable {
    /// Storage index → computed folder size (bytes). Used only by the size sort.
    public var folderSizes: [UInt32: Int64]
    /// P2-16: values for `query.sort.field` when it is an extended field.
    public var column: ExtraSortValues?

    public init(folderSizes: [UInt32: Int64] = [:], column: ExtraSortValues? = nil) {
        self.folderSizes = folderSizes
        self.column = column
    }

    public static let none = SortExtras()

    public var isEmpty: Bool { folderSizes.isEmpty && column == nil }

    /// `sizes` (by identity) mapped to storage indices of `store`; identities not in the store are left out.
    public static func folderSizes(_ sizes: [RowID: Int64], in store: EntryStore) -> SortExtras {
        guard !sizes.isEmpty else { return .none }
        var byIndex: [UInt32: Int64] = [:]
        byIndex.reserveCapacity(sizes.count)
        for (id, bytes) in sizes { if let index = store.firstIndex(of: id) { byIndex[index] = bytes } }
        return SortExtras(folderSizes: byIndex)
    }

    /// `sizes` and `column` (by identity) mapped to storage indices of `store`; identities not in it are left out.
    public static func make(sizes: [RowID: Int64], column: ExtraColumnValues?, in store: EntryStore) -> SortExtras {
        var extras = folderSizes(sizes, in: store)
        // One hash lookup per value (the store's identity index), never an identity built per storage index (on
        // name-identity volumes that normalizes every name).
        switch column {
        case .integers(let byID)?:
            var values = [Int64?](repeating: nil, count: store.count)
            for (id, value) in byID { if let index = store.firstIndex(of: id) { values[Int(index)] = value } }
            extras.column = .integers(values)
        case .strings(let byID)?:
            var keys = [[UInt8]?](repeating: nil, count: store.count)
            for (id, key) in byID { if let index = store.firstIndex(of: id) { keys[Int(index)] = key } }
            extras.column = .stringKeys(keys)
        case nil: break
        }
        return extras
    }
}

extension Sorter {
    /// Phase 1 permutation plus: the size sort orders the folders group by `extras.folderSizes` (unknown sizes last
    /// in both directions, name order breaking ties), and sized packages among the files by theirs. Folders stay
    /// first. Extended fields (P2-16) order each of the two groups by `extras.column`, missing values last in both
    /// directions, name order breaking ties: the column is the primary key of the one Phase 1 sort.
    public static func permutation(_ store: EntryStore, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                   query: ViewQuery, kindRanks: [UInt16], extensionKeys: SortKeyColumn? = nil,
                                   extras: SortExtras) -> [UInt32] {
        let column = query.sort.field.isExtended ? extras.column : nil
        var order = sortedRun(store, range: 0..<store.count, nameKeys: nameKeys, searchKeys: searchKeys, query: query,
                              kindRanks: kindRanks, extensionKeys: extensionKeys, column: column)
        applyExtras(&order, store: store, query: query, extras: extras)
        return order
    }

    /// Reorders an already sorted permutation for the size sort's `extras.folderSizes` (the worker's loading paths
    /// sort first). Extended columns are not handled here: they sort with `permutation(…, extras:)`.
    public static func applyExtras(_ order: inout [UInt32], store: EntryStore, query: ViewQuery, extras: SortExtras) {
        if query.sort.field == .size, !extras.folderSizes.isEmpty {
            let folderCount = order.prefix { store.entry($0).isFolderForSorting }.count
            reorder(&order, range: 0..<folderCount, ascending: query.sort.ascending) { extras.folderSizes[$0] }
            // Packages sort among files but show a computed size: order them by it (an unsized package's
            // `Entry.size` is not bytes, so it goes last like an unsized folder).
            if extras.folderSizes.keys.contains(where: { store.entry($0).kind == .package }) {
                reorder(&order, range: folderCount..<order.count, ascending: query.sort.ascending) { idx in
                    let entry = store.entry(idx)
                    return entry.kind == .package ? extras.folderSizes[idx] : entry.size
                }
            }
        }
    }

    /// Stable: equal and unknown values keep their incoming (name-ordered) positions; unknown values go last.
    static func reorder<V: Comparable>(_ order: inout [UInt32], range: Range<Int>, ascending: Bool, value: (UInt32) -> V?) {
        guard range.count > 1 else { return }
        let items = order[range].enumerated().map { (pos: $0.offset, idx: $0.element, v: value($0.element)) }
        let sorted = items.sorted { a, b in
            switch (a.v, b.v) {
            case let (x?, y?): return x != y ? (ascending ? x < y : x > y) : a.pos < b.pos
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.pos < b.pos
            }
        }
        order.replaceSubrange(range, with: sorted.map(\.idx))
    }
}
