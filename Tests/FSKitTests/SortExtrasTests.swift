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
}
