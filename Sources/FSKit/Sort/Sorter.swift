import Darwin

public enum Sorter {
    /// Visible storage indices of `store` in display order: hidden rows excluded unless query.showHidden,
    /// rows not matching query.filter (byte substring of searchKeys) excluded, folders first, then the sort
    /// field (name: memcmp of nameKeys; dates/size: integer key, name tie-break; kind: TypeRegistry rank
    /// then name; extension: folded extension then name). Size sort orders folders by name (their size is
    /// "--"). Descending reverses within each folders/files group; folders stay first.
    public static func permutation(_ store: EntryStore, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                   query: ViewQuery, kindRanks: [UInt16]) -> [UInt32] {
        sortedRun(store, range: 0..<store.count, nameKeys: nameKeys, searchKeys: searchKeys, query: query, kindRanks: kindRanks)
    }

    /// Like `permutation`, restricted to storage indices in `range` (the loading path sorts each new batch
    /// with this, then `merge`s it). Addition to the §3.5 contract.
    public static func sortedRun(_ store: EntryStore, range: Range<Int>, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                 query: ViewQuery, kindRanks: [UInt16]) -> [UInt32] {
        precondition(nameKeys.count >= range.upperBound, "Sorter: nameKeys must cover every storage index")
        let filter = query.filter.isEmpty ? nil : SortKeys.searchFold(query.filter)
        var items: [Item] = []
        items.reserveCapacity(range.count)
        let ordering = Ordering(store: store, nameKeys: nameKeys, query: query, kindRanks: kindRanks)
        for i in range {
            let index = UInt32(i)
            let entry = store.entry(index)
            if !query.showHidden && entry.flags.isHidden { continue }
            if let filter, !matches(index, store: store, searchKeys: searchKeys, filter: filter) { continue }
            items.append(ordering.item(index))
        }
        ordering.sort(&items)
        return items.map(\.index)
    }

    /// Loading path: merge an already-sorted run of new indices into a sorted permutation.
    public static func merge(_ sorted: [UInt32], _ run: [UInt32], store: EntryStore, nameKeys: SortKeyColumn,
                             query: ViewQuery, kindRanks: [UInt16]) -> [UInt32] {
        if run.isEmpty { return sorted }
        if sorted.isEmpty { return run }
        let ordering = Ordering(store: store, nameKeys: nameKeys, query: query, kindRanks: kindRanks)
        let a = sorted.map(ordering.item), b = run.map(ordering.item)
        var out: [UInt32] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        ordering.withLess { less in
            while i < a.count && j < b.count {
                if less(b[j], a[i]) { out.append(b[j].index); j += 1 } else { out.append(a[i].index); i += 1 }
            }
        }
        while i < a.count { out.append(a[i].index); i += 1 }
        while j < b.count { out.append(b[j].index); j += 1 }
        return out
    }

    static func matches(_ index: UInt32, store: EntryStore, searchKeys: SortKeyColumn?, filter: [UInt8]) -> Bool {
        if filter.isEmpty { return true }
        if let searchKeys, Int(index) < searchKeys.count {
            return searchKeys.withKey(Int(index)) { contains($0, filter) }
        }
        let folded = SortKeys.searchFold(store.name(index))
        return folded.withUnsafeBytes { contains($0, filter) }
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in memmem(haystack.baseAddress, haystack.count, n.baseAddress, n.count) != nil }
    }
}

/// Sort item: group (folders 0 / files 1) | primary integer key | first 8 name-key bytes | storage index.
struct Item {
    var group: UInt8
    var primary: UInt64
    var prefix: UInt64
    var index: UInt32
}

struct Ordering {
    let store: EntryStore
    let nameKeys: SortKeyColumn
    let field: SortField
    let ascending: Bool
    let kindRanks: [UInt16]
    /// fileExtension sort: rank of each storage index's folded extension among the distinct extensions.
    private let extensionRanks: [UInt32]

    init(store: EntryStore, nameKeys: SortKeyColumn, query: ViewQuery, kindRanks: [UInt16]) {
        self.store = store
        self.nameKeys = nameKeys
        self.field = query.sort.field
        self.ascending = query.sort.ascending
        self.kindRanks = kindRanks
        guard query.sort.field == .fileExtension else { extensionRanks = []; return }
        var folded = [[UInt8]](repeating: [], count: store.count)
        var distinct = Set<[UInt8]>()
        for i in 0..<store.count {
            let ext = store.withNameBytes(UInt32(i)) { name -> [UInt8] in
                guard store.entry(UInt32(i)).kind != .directory, let r = fileExtensionRange(name) else { return [] }
                return SortKeys.searchFold(String(decoding: UnsafeBufferPointer(rebasing: name[r]), as: UTF8.self))
            }
            folded[i] = ext
            distinct.insert(ext)
        }
        let rank = Dictionary(uniqueKeysWithValues: distinct.sorted { $0.lexicographicallyPrecedes($1) }.enumerated().map { ($1, UInt32($0)) })
        extensionRanks = folded.map { rank[$0]! }
    }

    func item(_ index: UInt32) -> Item {
        let e = store.entry(index)
        let folder = e.isFolderForSorting
        let primary: UInt64
        switch field {
        case .name: primary = 0
        case .fileExtension: primary = UInt64(extensionRanks[Int(index)])
        case .dateModified: primary = UInt64(bitPattern: e.mtime) ^ (1 << 63)
        case .dateCreated: primary = UInt64(bitPattern: e.ctime) ^ (1 << 63)
        case .size: primary = folder ? 0 : UInt64(bitPattern: e.size) ^ (1 << 63)
        case .kind: primary = Int(e.typeIndex) < kindRanks.count ? UInt64(kindRanks[Int(e.typeIndex)]) : UInt64(UInt16.max)
        }
        let prefix = nameKeys.withKey(Int(index)) { key -> UInt64 in
            var p: UInt64 = 0
            for k in 0..<8 { p = (p << 8) | UInt64(k < key.count ? key[k] : 0) }
            return p
        }
        return Item(group: folder ? 0 : 1, primary: primary, prefix: prefix, index: index)
    }

    /// Calls `body` with a strict-weak-order `less` (total: the storage index breaks remaining ties).
    /// The key arena is opened once, so each comparison is integer compares plus at most one memcmp.
    func withLess<R>(_ body: ((Item, Item) -> Bool) -> R) -> R {
        nameKeys.withStorage { bytes, starts, lengths in
            let base = bytes.baseAddress
            let ascending = self.ascending
            func ordered(_ a: Item, _ b: Item) -> Bool {
                if a.primary != b.primary { return a.primary < b.primary }
                if a.prefix != b.prefix { return a.prefix < b.prefix }
                let la = Int(lengths[Int(a.index)]), lb = Int(lengths[Int(b.index)])
                let c = memcmp(base! + Int(starts[Int(a.index)]), base! + Int(starts[Int(b.index)]), min(la, lb))
                if c != 0 { return c < 0 }
                if la != lb { return la < lb }
                return a.index < b.index
            }
            return body { a, b in
                if a.group != b.group { return a.group < b.group }
                return ascending ? ordered(a, b) : ordered(b, a)
            }
        }
    }

    func sort(_ items: inout [Item]) {
        guard items.count > 1 else { return }
        withLess { less in items.sort(by: less) }
    }
}
