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
///
/// Compact (review fix, §4.4 memory: a 100k folder sorted by Tags or Owner): one 8-byte value per identity, in
/// two tables so object identities take 8-byte keys, and string keys interned in one arena (no array per row). An
/// identity can be loaded with no value (no tag, no comment): it is `contains` but has no `integer`/`key`.
public struct ExtraColumnValues: Sendable {
    public enum Kind: Sendable, Equatable { case integers, strings }
    public let kind: Kind
    private var objects: [UInt64: Int64] = [:]
    private var names: [String: Int64] = [:]
    /// `.strings`: slot → key. Slots of replaced values stay until `compact`.
    private var keys = SortKeyColumn()
    private var interned: [[UInt8]: Int64] = [:]
    private static let noValue = Int64.min
    /// Distinct keys interned at most (owners and tags repeat; distinct comments just take arena slots).
    private static let internLimit = 4_096

    public init(kind: Kind) { self.kind = kind }

    public static func integers(_ values: [RowID: Int64]) -> ExtraColumnValues {
        var column = ExtraColumnValues(kind: .integers)
        for (id, value) in values { column.set(id, integer: value) }
        return column
    }

    public static func strings(_ values: [RowID: [UInt8]]) -> ExtraColumnValues {
        var column = ExtraColumnValues(kind: .strings)
        for (id, key) in values { column.set(id, key: key) }
        return column
    }

    /// Loaded identities (with or without a value).
    public var count: Int { objects.count + names.count }
    public var isEmpty: Bool { objects.isEmpty && names.isEmpty }

    public func contains(_ id: RowID) -> Bool { raw(id) != nil }

    /// `.integers`: the value of `id`, nil when it has none or is not loaded.
    public func integer(_ id: RowID) -> Int64? {
        guard kind == .integers, let value = raw(id), value != Self.noValue else { return nil }
        return value
    }

    /// `.strings`: the key of `id`, nil when it has none or is not loaded.
    public func key(_ id: RowID) -> [UInt8]? {
        guard kind == .strings, let slot = raw(id), slot != Self.noValue else { return nil }
        return keys.withKey(Int(slot)) { Array($0) }
    }

    /// Records `id` as loaded with `value` (nil: no value). Returns whether what it sorts by changed.
    @discardableResult
    public mutating func set(_ id: RowID, integer value: Int64?) -> Bool {
        let new = value ?? Self.noValue
        let old = raw(id)
        guard old != new else { return false }
        setRaw(id, new)
        return old.flatMap { $0 == Self.noValue ? nil : $0 } != value
    }

    /// Records `id` as loaded with `key` (nil or empty: no value). Returns whether what it sorts by changed.
    @discardableResult
    public mutating func set(_ id: RowID, key: [UInt8]?) -> Bool {
        let key = key.flatMap { $0.isEmpty ? nil : $0 }
        let old = raw(id)
        let oldKey = old.flatMap { $0 == Self.noValue ? nil : keys.withKey(Int($0)) { Array($0) } }
        if old != nil, oldKey == key { return false }
        guard let key else { setRaw(id, Self.noValue); return oldKey != nil }
        let slot: Int64
        if let existing = interned[key] {
            slot = existing
        } else {
            if keys.count > 2 * count + 1_024 { compact() }
            slot = Int64(keys.count)
            keys.append(key)
            if interned.count < Self.internLimit { interned[key] = slot }
        }
        setRaw(id, slot)
        return oldKey != key
    }

    public mutating func remove(_ id: RowID) {
        switch id {
        case .object(let object): objects[object] = nil
        case .name(let name): names[name] = nil
        }
    }

    /// Every loaded identity (O(count)).
    public func forEachIdentity(_ body: (RowID) throws -> Void) rethrows {
        for object in objects.keys { try body(.object(object)) }
        for name in names.keys { try body(.name(name)) }
    }

    /// One value per storage index of `store` (identities not in it are left out): one hash lookup per loaded
    /// identity, never an identity built per storage index (on name-identity volumes that normalizes every name).
    func sortValues(in store: EntryStore) -> ExtraSortValues {
        var slots = [Int64](repeating: Self.noValue, count: store.count)
        for (object, value) in objects { if let index = store.firstIndex(of: .object(object)) { slots[Int(index)] = value } }
        for (name, value) in names { if let index = store.firstIndex(of: .name(name)) { slots[Int(index)] = value } }
        switch kind {
        case .integers:
            return .integers(slots.map { $0 == Self.noValue ? nil : $0 })
        case .strings:
            var column = SortKeyColumn()
            var bytes = 0
            for slot in slots where slot != Self.noValue { bytes += keys.length(Int(slot)) }
            column.reserve(keys: slots.count, bytes: bytes)
            for slot in slots {
                if slot == Self.noValue { column.append([UInt8]()) } else { keys.withKey(Int(slot)) { column.append($0) } }
            }
            return .strings(column)
        }
    }

    // MARK: Private

    private func raw(_ id: RowID) -> Int64? {
        switch id {
        case .object(let object): objects[object]
        case .name(let name): names[name]
        }
    }

    private mutating func setRaw(_ id: RowID, _ value: Int64) {
        switch id {
        case .object(let object): objects[object] = value
        case .name(let name): names[name] = value
        }
    }

    /// Drops arena slots no identity uses any more (replaced values).
    private mutating func compact() {
        let old = keys
        var fresh = SortKeyColumn()
        var moved: [Int64: Int64] = [:]
        var freshInterned: [[UInt8]: Int64] = [:]
        func move(_ slot: Int64) -> Int64 {
            guard slot != Self.noValue else { return slot }
            if let done = moved[slot] { return done }
            let key = old.withKey(Int(slot)) { Array($0) }
            let target = freshInterned[key] ?? {
                let next = Int64(fresh.count)
                fresh.append(key)
                if freshInterned.count < Self.internLimit { freshInterned[key] = next }
                return next
            }()
            moved[slot] = target
            return target
        }
        objects = objects.mapValues(move)
        names = names.mapValues(move)
        keys = fresh
        interned = freshInterned
    }
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
        if let column { extras.column = column.sortValues(in: store) }
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
