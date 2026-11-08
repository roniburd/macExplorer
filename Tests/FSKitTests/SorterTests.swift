import Foundation
import MacxFS
import XCTest

final class SorterTests: XCTestCase {
    private let registry = TypeRegistry()

    /// (name, kind, size, mtime, flags)
    private func store(_ rows: [(String, Kind, Int64, Int64, EntryFlags)]) -> EntryStore {
        var s = EntryStore(identityMode: .objectID)
        var batch = Batch(generation: .initial)
        for (i, r) in rows.enumerated() {
            let ext = r.0.split(separator: ".").count > 1 ? r.0.split(separator: ".").last! : ""
            let type = r.1 == .directory ? TypeRegistry.folderIndex : registry.index(forExtension: ext, isDirectory: false)
            let e = Entry(rowID: UInt64(i + 1), fileID: UInt64(i + 1), size: r.2, allocSize: 0, mtime: r.3, ctime: -r.3,
                          nameOffset: 0, nameLen: 0, kind: r.1, flags: r.4, typeIndex: type)
            Array(r.0.utf8).withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
        }
        s.append(batch)
        return s
    }

    private func names(_ s: EntryStore, _ query: ViewQuery) -> [String] {
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        let perm = Sorter.permutation(s, nameKeys: keys, searchKeys: SortKeys.searchKeys(s), query: query, kindRanks: registry.kindRanks().ranks)
        return perm.map { s.name($0) }
    }

    private lazy var sample = store([
        ("b.txt", .file, 30, 300, []), ("A.pdf", .file, 10, 100, []), ("zeta", .directory, 2, 50, []),
        ("alpha", .directory, 9, 900, []), (".hidden", .file, 1, 1, .dotName), ("secret.txt", .file, 5, 5, .bsdHidden),
        ("Tool.app", .package, 0, 400, []), ("c10.txt", .file, 20, 200, []), ("c9.txt", .file, 20, 250, []),
    ])

    /// Until P2-14/P2-16 give them values, every non-entry field (extended columns and .path) orders like .name.
    func testNonEntryFieldsSortLikeName() {
        for field in SortField.allCases where !SortField.entryFields.contains(field) {
            for ascending in [true, false] {
                XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: field, ascending: ascending))),
                               names(sample, ViewQuery(sort: SortDescriptor(field: .name, ascending: ascending))), "\(field)")
            }
        }
    }

    /// 100k-row re-sorts run in concurrent chunks (§4.4 < 30 ms); the result must equal the serial order
    /// (two serial half-runs merged), for every field and direction, with hidden rows and ties. 40k rows is above
    /// the 32,768-row concurrency threshold; each 20k half-run is below it.
    func testParallelSortMatchesSerialOrder() {
        var generator = SystemRandomNumberGenerator()
        let rows: [(String, Kind, Int64, Int64, EntryFlags)] = (0..<40_000).map { i in
            let stem = ["IMG_", "img_", "Report ", "report-", "a", "Ä"][i % 6]
            let name = "\(stem)\(Int.random(in: 0..<5_000, using: &generator))-\(i)" + ["", ".txt", ".JPG", ".tar.gz"][i % 4]
            let kind: Kind = i % 17 == 0 ? .directory : .file
            return (name, kind, Int64(i % 50), Int64(i % 300), i % 23 == 0 ? .dotName : [])
        }
        let s = store(rows)
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        let ext = SortKeys.extensionKeys(s, range: 0..<s.count)
        let ranks = registry.kindRanks().ranks
        for field in SortField.entryFields {
            for ascending in [true, false] {
                for showHidden in [false, true] {
                    let query = ViewQuery(sort: SortDescriptor(field: field, ascending: ascending), showHidden: showHidden)
                    let parallel = Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: query, kindRanks: ranks, extensionKeys: ext)
                    let a = Sorter.sortedRun(s, range: 0..<20_000, nameKeys: keys, searchKeys: nil, query: query, kindRanks: ranks, extensionKeys: ext)
                    let b = Sorter.sortedRun(s, range: 20_000..<40_000, nameKeys: keys, searchKeys: nil, query: query, kindRanks: ranks, extensionKeys: ext)
                    let serial = Sorter.merge(a, b, store: s, nameKeys: keys, query: query, kindRanks: ranks, extensionKeys: ext)
                    XCTAssertEqual(parallel, serial, "\(field) ascending=\(ascending) showHidden=\(showHidden)")
                }
            }
        }
    }

    func testNameAscendingFoldersFirstHiddenExcluded() {
        XCTAssertEqual(names(sample, ViewQuery()), ["alpha", "zeta", "A.pdf", "b.txt", "c9.txt", "c10.txt", "Tool.app"])
    }

    func testShowHiddenIncludesDotAndFlagHidden() {
        XCTAssertEqual(names(sample, ViewQuery(showHidden: true)),
                       ["alpha", "zeta", ".hidden", "A.pdf", "b.txt", "c9.txt", "c10.txt", "secret.txt", "Tool.app"])
    }

    func testDescendingKeepsFoldersFirst() {
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .name, ascending: false))),
                       ["zeta", "alpha", "Tool.app", "c10.txt", "c9.txt", "b.txt", "A.pdf"])
    }

    func testSizeSortOrdersFoldersByName() {
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .size, ascending: true))),
                       ["alpha", "zeta", "Tool.app", "A.pdf", "c9.txt", "c10.txt", "b.txt"])
    }

    func testDateSortsWithNameTieBreak() {
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .dateModified, ascending: true))),
                       ["zeta", "alpha", "A.pdf", "c10.txt", "c9.txt", "b.txt", "Tool.app"])
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .dateCreated, ascending: true))),
                       ["alpha", "zeta", "Tool.app", "b.txt", "c9.txt", "c10.txt", "A.pdf"])
    }

    func testKindSortUsesRanksThenName() {
        let order = names(sample, ViewQuery(sort: SortDescriptor(field: .kind, ascending: true)))
        XCTAssertEqual(Array(order.prefix(2)), ["alpha", "zeta"])
        let txt = order.filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(txt, ["b.txt", "c9.txt", "c10.txt"], "same kind: name order")
        let ranks = registry.kindRanks().ranks
        let ranked = order.dropFirst(2).map { n -> UInt16 in
            let i = (0..<UInt32(sample.count)).first { sample.name($0) == n }!
            return ranks[Int(sample.entry(i).typeIndex)]
        }
        XCTAssertEqual(ranked, ranked.sorted())
    }

    func testExtensionSort() {
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .fileExtension, ascending: true))),
                       ["alpha", "zeta", "Tool.app", "A.pdf", "b.txt", "c9.txt", "c10.txt"])
    }

    func testExtensionSortComparesTheSuppliedExtensionKeys() {
        let s = sample
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        let query = ViewQuery(sort: SortDescriptor(field: .fileExtension, ascending: true))
        let ext = SortKeys.extensionKeys(s, range: 0..<s.count)
        XCTAssertEqual(ext.withKey(1) { Array($0) }, Array("pdf".utf8), "folded extension of A.pdf")
        XCTAssertEqual(ext.withKey(2) { Array($0) }, [], "folders have no extension key")
        XCTAssertEqual(Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: query, kindRanks: [], extensionKeys: ext),
                       Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: query, kindRanks: []))
        var custom = SortKeyColumn()                       // c9.txt first, then everything else by name
        for i in 0..<s.count { (s.name(UInt32(i)) == "c9.txt" ? [1] : [2] as [UInt8]).withUnsafeBytes { custom.append($0) } }
        let perm = Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: query, kindRanks: [], extensionKeys: custom)
        XCTAssertEqual(perm.map { s.name($0) }, ["alpha", "zeta", "c9.txt", "A.pdf", "b.txt", "c10.txt", "Tool.app"])
    }

    func testExtensionSortedRunsMergeWithIncrementalExtensionKeys() {
        var s = EntryStore(identityMode: .objectID)
        var keys = SortKeyColumn(), ext = SortKeyColumn()
        var merged: [UInt32] = []
        let query = ViewQuery(sort: SortDescriptor(field: .fileExtension, ascending: false))
        let exts = ["txt", "TXT", "longextension1", "longextension2", "", "Pdf", "tar.gz", "épub"]
        for b in 0..<4 {
            var batch = Batch(generation: .initial)
            for i in 0..<300 {
                let e = exts[(i * 7 + b) % exts.count]
                let n = "f\((i * 31 + b) % 97)" + (e.isEmpty ? "" : "." + e)
                let entry = Entry(rowID: UInt64(b * 1_000 + i), fileID: 0, size: 0, allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0,
                                  nameLen: 0, kind: i.isMultiple(of: 11) ? .directory : .file, flags: [], typeIndex: 0)
                Array(n.utf8).withUnsafeBufferPointer { batch.append(entry, nameBytes: $0) }
            }
            let start = s.count
            s.append(batch)
            keys.append(contentsOf: SortKeys.nameKeys(batch))
            ext.append(contentsOf: SortKeys.extensionKeys(batch))
            let run = Sorter.sortedRun(s, range: start..<s.count, nameKeys: keys, searchKeys: nil, query: query, kindRanks: [], extensionKeys: ext)
            merged = Sorter.merge(merged, run, store: s, nameKeys: keys, query: query, kindRanks: [], extensionKeys: ext)
        }
        XCTAssertEqual(merged, Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: query, kindRanks: []))
        XCTAssertEqual(SortKeys.extensionKeys(s, range: 0..<s.count).withKey(2) { Array($0) }, ext.withKey(2) { Array($0) })
    }

    func testFilterIsCaseAndDiacriticInsensitiveSubstring() {
        let s = store([("Résumé.pdf", .file, 0, 0, []), ("resume-old", .directory, 0, 0, []), ("notes", .file, 0, 0, [])])
        XCTAssertEqual(names(s, ViewQuery(filter: "RESUME")), ["resume-old", "Résumé.pdf"])
        XCTAssertEqual(names(s, ViewQuery(filter: "sum")), ["resume-old", "Résumé.pdf"])
        XCTAssertEqual(names(s, ViewQuery(filter: "zzz")), [])
    }

    func testFilterWithoutSearchKeysFallsBackToFoldingNames() {
        let s = store([("Résumé.pdf", .file, 0, 0, []), ("notes", .file, 0, 0, [])])
        let perm = Sorter.permutation(s, nameKeys: SortKeys.nameKeys(s, range: 0..<s.count), searchKeys: nil,
                                      query: ViewQuery(filter: "resu"), kindRanks: [])
        XCTAssertEqual(perm.map { s.name($0) }, ["Résumé.pdf"])
    }

    func testMergeOfSortedRunsEqualsFullSort() {
        var s = EntryStore(identityMode: .objectID)
        var keys = SortKeyColumn()
        var merged: [UInt32] = []
        let query = ViewQuery()
        var rng = SystemRandomNumberGenerator()
        for b in 0..<5 {
            var batch = Batch(generation: .initial)
            for i in 0..<400 {
                let n = "item \(Int.random(in: 0..<10_000, using: &rng)) \(b)-\(i)"
                let e = Entry(rowID: UInt64(b * 1_000 + i), fileID: 0, size: 0, allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0,
                              nameLen: 0, kind: i.isMultiple(of: 9) ? .directory : .file, flags: [], typeIndex: 0)
                Array(n.utf8).withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
            }
            let start = s.count
            s.append(batch)
            keys.append(contentsOf: SortKeys.nameKeys(batch))
            let run = Sorter.sortedRun(s, range: start..<s.count, nameKeys: keys, searchKeys: nil, query: query, kindRanks: [])
            merged = Sorter.merge(merged, run, store: s, nameKeys: keys, query: query, kindRanks: [])
        }
        XCTAssertEqual(merged, Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: query, kindRanks: []))
    }

    func testSortKeyColumnRemoveAndReplaceMirrorStore() {
        var column = SortKeyColumn()
        for k in [[1], [2, 2], [3, 3, 3]] as [[UInt8]] { k.withUnsafeBytes { column.append($0) } }
        column.remove([1])
        XCTAssertEqual(column.count, 2)
        XCTAssertEqual(column.withKey(1) { Array($0) }, [3, 3, 3])
        column.replace(0, with: [9])
        XCTAssertEqual(column.withKey(0) { Array($0) }, [9])
    }

    func testParallelKeysEqualSerialKeys() {
        let s = store((0..<5_000).map { ("name \($0 * 7919 % 5_000)", Kind.file, 0, 0, EntryFlags()) })
        let parallel = SortKeys.nameKeys(s, range: 0..<s.count)
        for i in stride(from: 0, to: s.count, by: 97) {
            XCTAssertEqual(parallel.withKey(i) { Array($0) }, SortKeys.nameKey(s.name(UInt32(i)), isFolder: false))
        }
    }

    /// §4.4 smoke: 100k re-sort per field, with a sanity bound (the budget is macx-bench's `resort.*`).
    func testResort100kSmoke() {
        var rows: [(String, Kind, Int64, Int64, EntryFlags)] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let kind: Kind = i.isMultiple(of: 50) ? .directory : .file
            rows.append(("file \(i * 7_919 % 100_000).txt", kind, Int64(i * 31 % 9_973), Int64(i * 17 % 100_003), []))
        }
        let s = store(rows)
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        let ranks = registry.kindRanks().ranks
        // Sanity only (a quadratic sort would take minutes), in debug and release alike: the §4.4 30 ms budget is
        // `macx-bench --check-budgets` (`resort.*`), not a wall-clock assert under swift test --parallel contention.
        let budget = Duration.seconds(10)
        for field in SortField.entryFields {
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                _ = Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: ViewQuery(sort: SortDescriptor(field: field, ascending: true)), kindRanks: ranks)
            }
            print("resort100k \(field): \(elapsed)")
            XCTAssertLessThan(elapsed, budget, "\(field)")
        }
    }
}
