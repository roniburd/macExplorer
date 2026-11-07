import XCTest
import UniformTypeIdentifiers
@testable import MacxFS

final class CriteriaMatcherTests: XCTestCase {
    let types = TypeRegistry()
    let day: Int64 = 86_400 * 1_000_000_000

    func entry(_ name: String, _ kind: Kind = .file, size: Int64 = 10, mtime: Int64 = 0, ctime: Int64 = 0) -> Entry {
        let ext = (name as NSString).pathExtension
        let isDir = kind == .directory || kind == .package
        return Entry(rowID: 1, fileID: 1, size: size, allocSize: size, mtime: mtime, ctime: ctime,
                     nameOffset: 0, nameLen: UInt16(name.utf8.count), kind: kind,
                     flags: name.hasPrefix(".") ? .dotName : [],
                     typeIndex: kind == .directory ? TypeRegistry.folderIndex
                         : types.index(forExtension: Substring(ext), isDirectory: isDir))
    }
    func matches(_ c: SearchCriteria, _ e: Entry, _ name: String) -> Bool {
        var m = CriteriaMatcher(c, types: types)
        return SortKeys.searchFold(name).withUnsafeBytes { m.matches(e, foldedName: $0) }
    }

    func testMultipleTermsAreANDed() {
        let c = SearchCriteria(nameTerms: [NameTerm("tax"), NameTerm("2025")])
        XCTAssertTrue(matches(c, entry("Tax return 2025.pdf"), "Tax return 2025.pdf"))
        XCTAssertFalse(matches(c, entry("Tax return 2024.pdf"), "Tax return 2024.pdf"))
    }

    func testSizeBoundsAreLowerInclusiveUpperExclusive() {
        let c = SearchCriteria(size: ByteRange(lower: 100, upper: 200))
        XCTAssertTrue(matches(c, entry("a", size: 100), "a"))
        XCTAssertTrue(matches(c, entry("a", size: 199), "a"))
        XCTAssertFalse(matches(c, entry("a", size: 200), "a"))
        XCTAssertFalse(matches(c, entry("a", size: 99), "a"))
    }

    func testSizeFilterNeverMatchesDirectoriesOrPackages() {
        // Entry.size of a directory holds its entry count (Phase 1 §3.3), not bytes.
        let c = SearchCriteria(size: ByteRange(lower: 0))
        XCTAssertFalse(matches(c, entry("Folder", .directory, size: 5), "Folder"))
        XCTAssertFalse(matches(c, entry("X.app", .package, size: 1), "X.app"))
        XCTAssertTrue(matches(c, entry("f.txt", size: 0), "f.txt"))
    }

    func testDateRanges() {
        let c = SearchCriteria(modified: TimeRange(lower: 10 * day, upper: 11 * day),
                               created: TimeRange(upper: 5 * day))
        XCTAssertTrue(matches(c, entry("a", mtime: 10 * day, ctime: 4 * day), "a"))
        XCTAssertFalse(matches(c, entry("a", mtime: 11 * day, ctime: 4 * day), "a"))
        XCTAssertFalse(matches(c, entry("a", mtime: 10 * day, ctime: 5 * day), "a"))
    }

    func testExtensionsAreCaseInsensitiveAndDotfilesHaveNone() {
        let c = SearchCriteria(extensions: ["jpg", "gz"])
        XCTAssertTrue(matches(c, entry("A.JPG"), "A.JPG"))
        XCTAssertTrue(matches(c, entry("archive.tar.gz"), "archive.tar.gz"))
        XCTAssertFalse(matches(c, entry(".jpg"), ".jpg"))        // leading dot is not an extension
        XCTAssertFalse(matches(c, entry("noext"), "noext"))
        XCTAssertFalse(matches(c, entry("trailing."), "trailing."))
        XCTAssertFalse(matches(SearchCriteria(extensions: []), entry("a.jpg"), "a.jpg"))   // empty set = nothing
    }

    func testKindFilters() {
        XCTAssertTrue(matches(SearchCriteria(kinds: [.image]), entry("p.png"), "p.png"))
        XCTAssertFalse(matches(SearchCriteria(kinds: [.image]), entry("p.pdf"), "p.pdf"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.pdf, .image]), entry("p.pdf"), "p.pdf"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.folder]), entry("Docs", .directory), "Docs"))
        XCTAssertFalse(matches(SearchCriteria(kinds: [.folder]), entry("X.app", .package), "X.app"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.application]), entry("X.app", .package), "X.app"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.code]), entry("main.swift"), "main.swift"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.document]), entry("notes.txt"), "notes.txt"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.archive]), entry("a.zip"), "a.zip"))
        XCTAssertFalse(matches(SearchCriteria(kinds: []), entry("a.png"), "a.png"))      // empty set = nothing
        XCTAssertFalse(matches(SearchCriteria(kinds: [.image]), entry("Pics", .directory), "Pics"))
    }

    func testRangeIntersection() {
        let a = ByteRange(lower: 10, upper: 100), b = ByteRange(lower: 50)
        XCTAssertEqual(a.intersection(b), ByteRange(lower: 50, upper: 100))
        XCTAssertEqual(TimeRange(upper: 5).intersection(TimeRange(upper: 3)), TimeRange(upper: 3))
    }

    func testEmptyCriteria() {
        XCTAssertTrue(SearchCriteria().isEmpty)
        XCTAssertFalse(SearchCriteria(kinds: []).isEmpty)
        XCTAssertTrue(matches(SearchCriteria(), entry("anything.bin"), "anything.bin"))
    }

    /// Finder display names hide some extensions (".app", the per-file "hide extension" flag). Name terms match
    /// the display name or the on-disk name; extension filters always use the on-disk name.
    func testHiddenExtensionsStillMatchGlobsAndExtensionFilters() {
        var e = entry("Report.pdf")
        e.flags.insert(.extensionHidden)
        let display = SortKeys.searchFold("Report"), file = SortKeys.searchFold("Report.pdf")
        func check(_ c: SearchCriteria) -> Bool {
            var m = CriteriaMatcher(c, types: types)
            return display.withUnsafeBytes { d in file.withUnsafeBytes { f in m.matches(e, foldedName: d, foldedFileName: f) } }
        }
        XCTAssertTrue(check(SearchCriteria(nameTerms: [NameTerm("*.pdf")])))
        XCTAssertTrue(check(SearchCriteria(nameTerms: [NameTerm("report")])))
        XCTAssertTrue(check(SearchCriteria(extensions: ["pdf"])))
        XCTAssertFalse(check(SearchCriteria(extensions: ["doc"])))
        XCTAssertFalse(check(SearchCriteria(nameTerms: [NameTerm("draft")])))
    }

    private func makeStore(_ items: [(String, Kind)], hideExtensionOf: Set<String> = []) -> EntryStore {
        var batch = Batch(generation: .initial)
        for (name, kind) in items {
            var e = entry(name, kind)
            if name.hasPrefix(".") { e.flags.insert(.dotName) }
            if hideExtensionOf.contains(name) { e.flags.insert(.extensionHidden) }
            let bytes = Array(name.utf8)
            bytes.withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
        }
        var store = EntryStore(identityMode: .name(caseSensitive: false))
        store.append(batch)
        return store
    }

    func testSorterAppliesCriteriaAndStillHidesHiddenRows() {
        let store = makeStore([("b.png", .file), ("Album", .directory), ("a.png", .file), (".c.png", .file), ("d.txt", .file)])
        let keys = SortKeys.nameKeys(store, range: 0..<store.count)
        let search = SortKeys.searchKeys(store)
        let q = ViewQuery(sort: .default, showHidden: false, filter: "", criteria: SearchCriteria(kinds: [.image]))
        let order = Sorter.permutation(store, nameKeys: keys, searchKeys: search, query: q,
                                       kindRanks: types.kindRanks().ranks, types: types)
        XCTAssertEqual(order.map { store.name($0) }, ["a.png", "b.png"])
        var q2 = q; q2.showHidden = true
        let order2 = Sorter.permutation(store, nameKeys: keys, searchKeys: search, query: q2,
                                        kindRanks: types.kindRanks().ranks, types: types)
        XCTAssertEqual(order2.map { store.name($0) }, [".c.png", "a.png", "b.png"])
    }

    /// The loading path sorts batches without search keys: criteria fold names on the fly there.
    func testSorterAppliesCriteriaWithoutSearchKeysAndCombinesWithFilter() {
        let store = makeStore([("photo1.png", .file), ("photo2.jpg", .file), ("other.png", .file), ("Hidden.pdf", .file)],
                              hideExtensionOf: ["Hidden.pdf"])
        let keys = SortKeys.nameKeys(store, range: 0..<store.count)
        let ranks = types.kindRanks().ranks
        let glob = ViewQuery(filter: "photo", criteria: SearchCriteria(nameTerms: [NameTerm("*.png")]))
        XCTAssertEqual(Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: glob, kindRanks: ranks, types: types)
            .map { store.name($0) }, ["photo1.png"])
        let ext = ViewQuery(criteria: SearchCriteria(extensions: ["pdf"]))
        XCTAssertEqual(Sorter.permutation(store, nameKeys: keys, searchKeys: SortKeys.searchKeys(store), query: ext,
                                          kindRanks: ranks, types: types).map { store.name($0) }, ["Hidden.pdf"])
        XCTAssertEqual(Sorter.sortedRun(store, range: 0..<store.count, nameKeys: keys, searchKeys: nil, query: ext,
                                        kindRanks: ranks, types: types).map { store.name($0) }, ["Hidden.pdf"])
    }
}
