import Darwin
import MacxFS
import XCTest

func makeEntry(_ id: UInt64, kind: Kind = .file, size: Int64 = 0, mtime: Int64 = 0, flags: EntryFlags = []) -> Entry {
    Entry(rowID: id, fileID: id, size: size, allocSize: 0, mtime: mtime, ctime: 0, nameOffset: 0, nameLen: 0,
          kind: kind, flags: flags, typeIndex: kind == .directory ? TypeRegistry.folderIndex : TypeRegistry.dataIndex)
}

func makeBatch(_ items: [(String, Entry)], generation: Generation = .initial, errors: [EntryError] = []) -> Batch {
    var batch = Batch(generation: generation)
    for (name, entry) in items {
        Array(name.utf8).withUnsafeBufferPointer { batch.append(entry, nameBytes: $0) }
    }
    batch.errors = errors
    return batch
}

final class EntryStoreTests: XCTestCase {
    func testBatchAppendRewritesNameOffsets() {
        let batch = makeBatch([("a.txt", makeEntry(1)), ("Résumé", makeEntry(2))])
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.name(at: 0), "a.txt")
        XCTAssertEqual(batch.name(at: 1), "Résumé")
        XCTAssertEqual(batch.entries[1].nameOffset, 5)
        XCTAssertEqual(batch.entries[1].nameLen, UInt16("Résumé".utf8.count))
    }

    func testAppendIsOrderNeutralAndIdentitiesResolve() {
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("b", makeEntry(10)), ("a", makeEntry(11))]))
        store.append(makeBatch([("c", makeEntry(12))], errors: [EntryError(index: 0, code: 13)]))
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.visibleCount, 0, "append never changes order")
        XCTAssertEqual(store.name(2), "c")
        XCTAssertEqual(store.errno(2), 13)
        XCTAssertNil(store.errno(0))
        store.setOrder([1, 0, 2])
        XCTAssertEqual(store.storageIndex(forRow: 0), 1)
        XCTAssertEqual(store.row(ofStorageIndex: 2), 2)
        XCTAssertEqual(store.row(of: .object(10)), 1)
        XCTAssertEqual(store.identity(1), .object(11))
    }

    func testDuplicateIdentitiesNeverTrapFirstWins() {
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("x", makeEntry(5)), ("y", makeEntry(5))]))
        XCTAssertEqual(store.firstIndex(of: .object(5)), 0)
        store.remove([0])
        XCTAssertEqual(store.firstIndex(of: .object(5)), 0, "the survivor takes over the identity")
        XCTAssertEqual(store.name(0), "y")
    }

    func testNameIdentityIsNFCAndCaseFoldedOnCaseInsensitiveVolumes() {
        var store = EntryStore(identityMode: .name(caseSensitive: false))
        store.append(makeBatch([("Cafe\u{301}.TXT", makeEntry(1))]))
        XCTAssertEqual(store.identity(0), .name("caf\u{E9}.txt"))
        XCTAssertEqual(store.firstIndex(of: .name("caf\u{E9}.txt")), 0)
        var sensitive = EntryStore(identityMode: .name(caseSensitive: true))
        sensitive.append(makeBatch([("A", makeEntry(1)), ("a", makeEntry(2))]))
        XCTAssertNotEqual(sensitive.identity(0), sensitive.identity(1))
    }

    func testFirstIndexNamedIncludesHiddenRowsNotInOrder() {
        // Review Focus 2 groundwork: duplicate checks see the whole store, not the visible permutation.
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("visible.txt", makeEntry(1)), (".env", makeEntry(2, flags: .dotName)),
                                ("notes.txt", makeEntry(3, flags: .bsdHidden))]))
        store.setOrder([0])
        XCTAssertEqual(store.firstIndex(named: ".env", caseSensitive: false), 1)
        XCTAssertEqual(store.firstIndex(named: "NOTES.TXT", caseSensitive: false), 2)
        XCTAssertNil(store.firstIndex(named: "NOTES.TXT", caseSensitive: true))
        XCTAssertEqual(store.firstIndex(named: "visible.txt", caseSensitive: true), 0)
    }

    func testUpsertReplacesSameIdentityInPlaceOrAppends() {
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("a", makeEntry(1, size: 1)), ("b", makeEntry(2))]))
        store.setOrder([0, 1])
        let v = store.version
        let replaced = store.upsert(makeEntry(1, size: 99), name: "a-renamed")
        XCTAssertEqual(replaced, 0)
        XCTAssertEqual(store.entry(0).size, 99)
        XCTAssertEqual(store.name(0), "a-renamed")
        XCTAssertEqual(store.row(of: .object(1)), 0, "row kept")
        XCTAssertGreaterThan(store.version, v)
        let appended = store.upsert(makeEntry(3), name: "c")
        XCTAssertEqual(appended, 2)
        XCTAssertNil(store.row(ofStorageIndex: 2), "new entries are not displayed until setOrder")
    }

    func testUpsertClearsTheErrorOfTheReplacedEntry() {
        // The watcher re-stats a row that failed earlier; the successful stat replaces it, error and all.
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("a", makeEntry(1)), ("b", makeEntry(2))], errors: [EntryError(index: 0, code: EACCES)]))
        XCTAssertEqual(store.errno(0), EACCES)
        XCTAssertEqual(store.upsert(makeEntry(1, size: 3), name: "a"), 0)
        XCTAssertNil(store.errno(0))
    }

    func testEntriesWithoutObjectIDNeverShareAnIdentity() {
        // Degraded rows with no file ID (rowID 0) fall back to their exact name on objectID volumes.
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("x", makeEntry(0, flags: .degraded)), ("y", makeEntry(0, flags: .degraded)), ("z", makeEntry(7))]))
        XCTAssertNotEqual(store.identity(0), store.identity(1))
        XCTAssertEqual(store.firstIndex(of: store.identity(1)), 1)
        XCTAssertEqual(store.identity(2), .object(7))
    }

    func testUpsertInNameModeRenameIsANewIdentity() {
        var store = EntryStore(identityMode: .name(caseSensitive: true))
        store.append(makeBatch([("a", makeEntry(1))]))
        XCTAssertEqual(store.upsert(makeEntry(1, size: 5), name: "a"), 0)
        XCTAssertEqual(store.upsert(makeEntry(1), name: "b"), 1)
    }

    func testRemoveCompactsAndRemapsOrderErrorsAndInverse() {
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch((0..<6).map { ("n\($0)", makeEntry(UInt64(100 + $0))) },
                               errors: [EntryError(index: 4, code: 1)]))
        store.setOrder([5, 3, 1, 4])
        store.remove([1, 2])
        XCTAssertEqual(store.count, 4)
        XCTAssertEqual((0..<4).map { store.name(UInt32($0)) }, ["n0", "n3", "n4", "n5"])
        XCTAssertEqual(store.order, [3, 1, 2])
        XCTAssertEqual(store.row(of: .object(105)), 0)
        XCTAssertEqual(store.row(of: .object(103)), 1)
        XCTAssertNil(store.firstIndex(of: .object(101)))
        XCTAssertEqual(store.errno(2), 1)
        XCTAssertNil(store.row(ofStorageIndex: 0))
    }

    func testArenaCompactionKeepsNamesIntact() {
        var store = EntryStore(identityMode: .objectID)
        let long = String(repeating: "x", count: 200)
        store.append(makeBatch((0..<1_000).map { ("\(long)-\($0)", makeEntry(UInt64($0))) }))
        store.remove(Set((0..<900).map(UInt32.init)))   // > 64 KB garbage and > half the arena
        XCTAssertEqual(store.count, 100)
        XCTAssertLessThan(store.names.bytes.count, 30_000)
        XCTAssertEqual(store.name(0), "\(long)-900")
        XCTAssertEqual(store.name(99), "\(long)-999")
    }

    func testCopiesAreIndependent() {
        var a = EntryStore(identityMode: .objectID)
        a.append(makeBatch([("a", makeEntry(1))]))
        var b = a
        b.append(makeBatch([("b", makeEntry(2))]))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 2)
    }

    func testHiddenFlagAndFolderSorting() {
        XCTAssertTrue(EntryFlags.dotName.isHidden)
        XCTAssertTrue(EntryFlags.bsdHidden.isHidden)
        XCTAssertFalse(EntryFlags.locked.isHidden)
        XCTAssertTrue(makeEntry(1, kind: .directory).isFolderForSorting)
        XCTAssertFalse(makeEntry(1, kind: .package).isFolderForSorting)
    }

    func testInvalidUTF8NamesDecodeLossilyWithoutTrapping() {
        // SMB/FAT volumes can deliver bytes that are not UTF-8; rows must still appear.
        var batch = Batch(generation: .initial)
        ([0x62, 0xFF, 0x2E, 0x74] as [UInt8]).withUnsafeBufferPointer { batch.append(makeEntry(1), nameBytes: $0) }
        XCTAssertEqual(batch.name(at: 0), "b\u{FFFD}.t")
        var store = EntryStore(identityMode: .name(caseSensitive: false))
        store.append(batch)
        XCTAssertEqual(store.name(0), "b\u{FFFD}.t")
        XCTAssertEqual(store.identity(0), .name("b\u{FFFD}.t"))
        XCTAssertEqual(store.withNameBytes(0) { Array($0) }, [0x62, 0xFF, 0x2E, 0x74], "raw bytes are kept for operations")
    }

    func testNameNormalizerSameName() {
        XCTAssertTrue(NameNormalizer.sameName("Cafe\u{301}", "Caf\u{E9}", caseSensitive: true))
        XCTAssertTrue(NameNormalizer.sameName("ABC", "abc", caseSensitive: false))
        XCTAssertFalse(NameNormalizer.sameName("ABC", "abc", caseSensitive: true))
        XCTAssertEqual(Array(NameNormalizer.nfc("Cafe\u{301}").unicodeScalars), Array("Caf\u{E9}".unicodeScalars))
    }
}
