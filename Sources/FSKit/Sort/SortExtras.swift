import Foundation

/// Values for an extended sort column (P2-16), by storage index; nil sorts last in both directions.
public enum ExtraSortValues: Sendable {
    case integers([Int64?])
    case strings([[UInt8]?])                      // SortKeys.nameKey(isFolder: false) bytes
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
}

extension Sorter {
    /// Phase 1 permutation plus: the size sort orders the folders group by `extras.folderSizes` (unknown sizes last
    /// in both directions, name order breaking ties). Folders stay first. Other fields ignore the extras until P2-16.
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
        }
        // P2-16 handles extras.column for extended fields here.
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
