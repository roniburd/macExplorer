import XCTest
@testable import MacxFS

final class SortExtrasTests: XCTestCase {
    func store(_ names: [(String, Kind, Int64)]) -> EntryStore {
        var s = EntryStore(identityMode: .name(caseSensitive: false))
        var b = Batch(generation: .initial)
        for (i, n) in names.enumerated() {
            let e = Entry(rowID: UInt64(i + 1), fileID: UInt64(i + 1), size: n.2, allocSize: n.2, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                          kind: n.1, flags: [], typeIndex: n.1 == .directory ? TypeRegistry.folderIndex : TypeRegistry.dataIndex)
            Array(n.0.utf8).withUnsafeBufferPointer { b.append(e, nameBytes: $0) }
        }
        s.append(b); return s
    }

    func sorted(_ s: EntryStore, _ query: ViewQuery, _ extras: SortExtras) -> [String] {
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        return Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: query, kindRanks: TypeRegistry.shared.kindRanks().ranks, extras: extras)
            .map { s.name($0) }
    }

    func testFolderSizesOrderFoldersUnknownLast() {
        let s = store([("A", .directory, 0), ("B", .directory, 0), ("C", .directory, 0), ("x", .file, 5), ("y", .file, 1)])
        let extras = SortExtras(folderSizes: [0: 300, 2: 100])          // storage indices: A=0, C=2; B unknown
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: true)), extras), ["C", "A", "B", "y", "x"])
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: false)), extras).prefix(3), ["A", "C", "B"])
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: true)), .none).prefix(3), ["A", "B", "C"], "Phase 1 behaviour without sizes")
        XCTAssertEqual(sorted(s, ViewQuery(sort: .default), extras), ["A", "B", "C", "x", "y"], "only the size sort uses folder sizes")
    }

    func testSizedPackagesSortAmongFilesByComputedSize() {
        // X.app's Entry.size is an entry count (3); its computed size is 500 bytes.
        let s = store([("D", .directory, 0), ("X.app", .package, 3), ("Y.app", .package, 2), ("a", .file, 2000), ("b", .file, 10)])
        let extras = SortExtras(folderSizes: [0: 7, 1: 500])            // Y.app not sized yet
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: true)), extras),
                       ["D", "b", "X.app", "a", "Y.app"])
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: false)), extras),
                       ["D", "a", "X.app", "b", "Y.app"], "unknown package size still last when descending")
    }

    func testEqualSizesBreakTiesByNameInBothDirections() {
        let s = store([("b", .directory, 0), ("a", .directory, 0), ("c", .directory, 0), ("d", .directory, 0)])
        let extras = SortExtras(folderSizes: [0: 10, 1: 10, 2: 5])     // d unknown
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: true)), extras), ["c", "a", "b", "d"])
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: false)), extras), ["b", "a", "c", "d"],
                       "descending: equal sizes keep the (descending) name order, unknown still last")
    }

    func testHiddenAndFilteredFoldersStayOut() {
        let s = store([("A", .directory, 0), ("B", .directory, 0), ("x", .file, 1)])
        let extras = SortExtras(folderSizes: [0: 5, 1: 1])
        var query = ViewQuery(sort: SortDescriptor(field: .size, ascending: true))
        query.filter = "a"
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        let names = Sorter.permutation(s, nameKeys: keys, searchKeys: SortKeys.searchKeys(s), query: query,
                                       kindRanks: TypeRegistry.shared.kindRanks().ranks, extras: extras).map { s.name($0) }
        XCTAssertEqual(names, ["A"])
    }

    func testExtendedColumnOrderingKeepsFoldersFirstAndMissingLast() {
        let s = store([("D", .directory, 0), ("E", .directory, 0), ("a", .file, 0), ("b", .file, 0), ("c", .file, 0)])
        let ints: [Int64?] = [nil, 5, 30, nil, 10]                         // by storage index
        let q = ViewQuery(sort: SortDescriptor(field: .dateLastOpened, ascending: true))
        XCTAssertEqual(sorted(s, q, SortExtras(column: .integers(ints))), ["E", "D", "c", "a", "b"])
        let qd = ViewQuery(sort: SortDescriptor(field: .dateLastOpened, ascending: false))
        XCTAssertEqual(sorted(s, qd, SortExtras(column: .integers(ints))), ["E", "D", "a", "c", "b"], "missing stays last descending")
        let keys: [[UInt8]?] = [nil, nil, SortKeys.nameKey("work", isFolder: false), SortKeys.nameKey("Home", isFolder: false), nil]
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)), SortExtras(column: .stringKeys(keys))).suffix(3), ["b", "a", "c"])
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)), .none), ["D", "E", "a", "b", "c"], "no values yet: name order")
        XCTAssertEqual(sorted(s, ViewQuery(sort: .default), SortExtras(column: .integers(ints))), ["D", "E", "a", "b", "c"],
                       "only extended fields use the column")
    }

    /// The worker gets values keyed by identity (P2-13/P2-14 notes) and maps them to its own store's indices.
    func testColumnValuesByIdentityMapToStorageIndices() {
        let s = store([("D", .directory, 0), ("a", .file, 0), ("b", .file, 0)])
        let byID = ExtraColumnValues.integers([s.identity(2): 7, s.identity(0): 3, .name("zzz"): 1])
        guard case .integers(let values)? = SortExtras.make(sizes: [:], column: byID, in: s).column else { return XCTFail("no column") }
        XCTAssertEqual(values, [3, nil, 7])
        let keys = ExtraColumnValues.strings([s.identity(1): [1, 2]])
        guard case .strings(let k)? = SortExtras.make(sizes: [:], column: keys, in: s).column else { return XCTFail("no column") }
        XCTAssertEqual((0..<k.count).map { i in k.withKey(i) { Array($0) } }, [[], [1, 2], []], "empty key = missing")
        XCTAssertTrue(SortExtras.make(sizes: [:], column: nil, in: s).isEmpty)
    }

    /// Review fix (P2-16): string columns go through the Phase 1 Ordering (8-byte primary prefix plus a full-key
    /// compare when longer), not a second comparator sort; keys sharing their first 8+ bytes still order correctly.
    func testStringColumnWithLongSharedPrefixesOrdersByFullKey() {
        let s = store([("D", .directory, 0), ("a", .file, 0), ("b", .file, 0), ("c", .file, 0), ("d", .file, 0), ("e", .file, 0)])
        func key(_ t: String) -> [UInt8] { SortKeys.nameKey(t, isFolder: false) }
        let keys: [[UInt8]?] = [key("x"), key("project-alpha-zz"), nil, key("project-alpha-aa"), key("project-alpha-aa"), key("p")]
        let asc = ViewQuery(sort: SortDescriptor(field: .comments, ascending: true))
        XCTAssertEqual(sorted(s, asc, SortExtras(column: .stringKeys(keys))), ["D", "e", "c", "d", "a", "b"])
        let desc = ViewQuery(sort: SortDescriptor(field: .comments, ascending: false))
        XCTAssertEqual(sorted(s, desc, SortExtras(column: .stringKeys(keys))), ["D", "a", "d", "c", "e", "b"],
                       "descending: equal values in descending name order, missing still last")
    }

    /// Filtered and hidden rows stay out under an extended column too.
    func testExtendedColumnHonoursFilter() {
        let s = store([("ab", .file, 0), ("b", .file, 0), ("ac", .file, 0)])
        var query = ViewQuery(sort: SortDescriptor(field: .dateLastOpened, ascending: true))
        query.filter = "a"
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        let names = Sorter.permutation(s, nameKeys: keys, searchKeys: SortKeys.searchKeys(s), query: query,
                                       kindRanks: TypeRegistry.shared.kindRanks().ranks,
                                       extras: SortExtras(column: .integers([9, 1, 2]))).map { s.name($0) }
        XCTAssertEqual(names, ["ac", "ab"])
    }

    /// Large folders sort in parallel chunks; the column must survive the chunk merge.
    func testExtendedColumnLargeFolderMatchesReference() {
        let n = 40_000
        var s = EntryStore(identityMode: .name(caseSensitive: false))
        var b = Batch(generation: .initial)
        for i in 0..<n {
            let e = Entry(rowID: UInt64(i + 1), fileID: UInt64(i + 1), size: 0, allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                          kind: .file, flags: [], typeIndex: TypeRegistry.dataIndex)
            Array(String(format: "f%06d", i).utf8).withUnsafeBufferPointer { b.append(e, nameBytes: $0) }
        }
        s.append(b)
        let tags: [[UInt8]?] = (0..<n).map { i in i % 7 == 0 ? nil : SortKeys.nameKey("tag-\((i * 7919) % 1000)", isFolder: false) }
        let order = Sorter.permutation(s, nameKeys: SortKeys.nameKeys(s, range: 0..<n), searchKeys: nil,
                                       query: ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)),
                                       kindRanks: TypeRegistry.shared.kindRanks().ranks, extras: SortExtras(column: .stringKeys(tags)))
        let reference = (0..<UInt32(n)).sorted { a, b in
            switch (tags[Int(a)], tags[Int(b)]) {
            case let (x?, y?): return x != y ? x.lexicographicallyPrecedes(y) : a < b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a < b
            }
        }
        XCTAssertEqual(order, reference)
    }
}
