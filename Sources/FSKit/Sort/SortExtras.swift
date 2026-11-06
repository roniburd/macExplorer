import Foundation

/// Values for an extended sort column (P2-16), by storage index; nil sorts last in both directions.
public enum ExtraSortValues: Sendable {
    case integers([Int64?])
    case strings([[UInt8]?])                      // SortKeys.nameKey(isFolder: false) bytes
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
        switch column {
        case .integers(let byID)?:
            extras.column = .integers((0..<UInt32(store.count)).map { byID[store.identity($0)] })
        case .strings(let byID)?:
            extras.column = .strings((0..<UInt32(store.count)).map { byID[store.identity($0)] })
        case nil: break
        }
        return extras
    }
}

/// Byte-wise order of `SortKeys.nameKey` bytes.
struct ByteKey: Comparable {
    let bytes: [UInt8]
    static func < (a: ByteKey, b: ByteKey) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }
}

extension Sorter {
    /// Phase 1 permutation plus: the size sort orders the folders group by `extras.folderSizes` (unknown sizes last
    /// in both directions, name order breaking ties), and sized packages among the files by theirs. Folders stay first. Extended fields (P2-16) order
    /// each of the two groups by `extras.column`, missing values last in both directions.
    public static func permutation(_ store: EntryStore, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                   query: ViewQuery, kindRanks: [UInt16], extensionKeys: SortKeyColumn? = nil,
                                   extras: SortExtras) -> [UInt32] {
        var order = permutation(store, nameKeys: nameKeys, searchKeys: searchKeys, query: query, kindRanks: kindRanks,
                                extensionKeys: extensionKeys)
        applyExtras(&order, store: store, query: query, extras: extras)
        return order
    }

    /// Reorders an already sorted permutation for `extras` (the worker's patch and re-read paths sort first).
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
        if query.sort.field.isExtended, let column = extras.column {
            // Folders stay first; each group is ordered by the column, missing values last, name order breaking ties.
            let folderCount = order.prefix { store.entry($0).isFolderForSorting }.count
            for range in [0..<folderCount, folderCount..<order.count] {
                switch column {
                case .integers(let values):
                    reorder(&order, range: range, ascending: query.sort.ascending) { i in Int(i) < values.count ? values[Int(i)] : nil }
                case .strings(let keys):
                    reorder(&order, range: range, ascending: query.sort.ascending) { i in
                        Int(i) < keys.count ? keys[Int(i)].map(ByteKey.init) : nil
                    }
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
