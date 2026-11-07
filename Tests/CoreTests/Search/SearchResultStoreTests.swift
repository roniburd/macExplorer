import XCTest
@testable import Core
@testable import MacxFS
import MacxFixtures

final class SearchResultStoreTests: XCTestCase {
    let types = TypeRegistry()

    func batch(_ parent: String, _ names: [String], dirs: Set<String> = [], flags: EntryFlags = [],
               gen: Generation = .initial.next()) -> SearchBatch {
        var b = Batch(generation: gen)
        for name in names {
            let isDir = dirs.contains(name)
            let ext = (name as NSString).pathExtension
            let e = Entry(rowID: 7, fileID: 7, size: 10, allocSize: 10, mtime: 0, ctime: 0, nameOffset: 0,
                          nameLen: UInt16(name.utf8.count), kind: isDir ? .directory : .file, flags: flags,
                          typeIndex: isDir ? TypeRegistry.folderIndex : types.index(forExtension: Substring(ext), isDirectory: false))
            Array(name.utf8).withUnsafeBufferPointer { b.append(e, nameBytes: $0) }
        }
        return SearchBatch(parent: URL(filePath: parent, directoryHint: .isDirectory), batch: b)
    }

    func testAppendBuildsPathsParentsAndIdentity() {
        var s = SearchResultStore()
        let added = s.append(batch("/r/a", ["x.txt", "y.txt"]))
        s.append(batch("/r/b", ["x.txt"]))
        s.append(batch("/", ["top.txt"]))
        XCTAssertEqual(added, [0, 1])
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.path(0), "/r/a/x.txt")
        XCTAssertEqual(s.path(2), "/r/b/x.txt")
        XCTAssertEqual(s.path(3), "/top.txt")               // no double slash under "/"
        XCTAssertEqual(s.parentPath(1), "/r/a")
        XCTAssertEqual(s.parents, ["/r/a", "/r/b", "/"])
        XCTAssertEqual(s.parentIndex(2), 1)
        XCTAssertEqual(s.identity(2), .name("/r/b/x.txt"))  // same name, different folders → different rows
        XCTAssertEqual(s.index(ofPath: "/r/b/x.txt"), 2)
        XCTAssertEqual(s.url(0), URL(filePath: "/r/a/x.txt"))
        XCTAssertEqual(s.nameKeys.count, 4)
    }

    func testDirectoryURLsAndUnstandardizedParents() {
        var s = SearchResultStore()
        s.append(batch("/r/./a/../b/", ["sub"], dirs: ["sub"]))
        XCTAssertEqual(s.parents, ["/r/b"])
        XCTAssertEqual(s.path(0), "/r/b/sub")
        XCTAssertTrue(s.url(0).hasDirectoryPath)
    }

    func testAppendReplacesExistingPath() {
        var s = SearchResultStore()
        s.append(batch("/r", ["a.txt", "b.txt"]))
        s.setOrder([1, 0])
        let added = s.append(batch("/r", ["a.txt"]))        // Spotlight "updated" event
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(added, [1])
        XCTAssertEqual(s.path(0), "/r/b.txt")
        XCTAssertEqual(s.path(1), "/r/a.txt")
        XCTAssertEqual(s.store.order, [0])                  // b kept its place; the caller merges index 1
        XCTAssertEqual(s.nameKeys.count, 2)
    }

    func testRemoveKeepsColumnsAligned() {
        var s = SearchResultStore()
        s.append(batch("/r/a", ["1", "2", "3"]))
        s.append(batch("/r/b", ["4", "5"]))
        s.setOrder([4, 3, 2, 1, 0])
        XCTAssertEqual(s.remove(paths: ["/r/a/2", "/r/b/4", "/nope"]), 2)
        XCTAssertEqual((0..<UInt32(s.count)).map { s.path($0) }, ["/r/a/1", "/r/a/3", "/r/b/5"])
        XCTAssertEqual(s.store.order.map { s.path($0) }, ["/r/b/5", "/r/a/3", "/r/a/1"])
        XCTAssertNil(s.index(ofPath: "/r/a/2"))
        XCTAssertEqual(s.index(ofPath: "/r/b/5"), 2)
        XCTAssertEqual(s.nameKeys.count, 3)
        let key = s.nameKeys.withKey(2) { Array($0) }
        XCTAssertEqual(key, SortKeys.nameKey("5", isFolder: false))
    }

    func testRenameRetypesAndMovesIdentity() throws {
        var s = SearchResultStore()
        s.append(batch("/r", ["notes.txt", "keep.md"]))
        s.setOrder([0, 1])
        XCTAssertTrue(s.rename(path: "/r/notes.txt", to: "notes.png", types: types))
        XCTAssertFalse(s.rename(path: "/r/missing", to: "x", types: types))
        XCTAssertNil(s.index(ofPath: "/r/notes.txt"))
        let i = try XCTUnwrap(s.index(ofPath: "/r/notes.png"))
        XCTAssertEqual(s.store.name(i), "notes.png")
        XCTAssertTrue(types.type(at: s.store.entry(i).typeIndex).conforms(to: .png))
        XCTAssertEqual(s.store.order.map { s.path($0) }, ["/r/keep.md"])   // caller merges the renamed index
        XCTAssertEqual(s.nameKeys.count, 2)
    }

    func testRenameToDotNameSetsHiddenFlag() throws {
        var s = SearchResultStore()
        s.append(batch("/r", ["visible"]))
        XCTAssertTrue(s.rename(path: "/r/visible", to: ".hidden", types: types))
        let i = try XCTUnwrap(s.index(ofPath: "/r/.hidden"))
        XCTAssertTrue(s.store.entry(i).flags.contains(.dotName))
        XCTAssertTrue(s.rename(path: "/r/.hidden", to: "shown", types: types))
        XCTAssertFalse(s.store.entry(try XCTUnwrap(s.index(ofPath: "/r/shown"))).flags.contains(.dotName))
    }

    func testNameKeysUseFinderDisplayNames() {
        var s = SearchResultStore()
        s.append(batch("/r", ["Report.pdf"], flags: [.extensionHidden]))
        XCTAssertEqual(s.displayName(0, showAllExtensions: false), "Report")
        XCTAssertEqual(s.displayName(0, showAllExtensions: true), "Report.pdf")
        XCTAssertEqual(s.nameKeys.withKey(0) { Array($0) }, SortKeys.nameKey("Report", isFolder: false))
    }

    // Review finding: parents are normalized lexically (no file-system call), keep the caller's /private spelling,
    // and lookups accept either the /private/var/... or the /var/... spelling.
    func testRealPrivateVarParentKeepsSpellingAndMatchesEitherSpelling() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.createDirectory("dir")
        var real = sandbox.url("dir").path(percentEncoded: false)
        if real.hasSuffix("/") { real.removeLast() }
        let privateSpelling = real.hasPrefix("/private/") ? real : "/private" + real
        let varSpelling = String(privateSpelling.dropFirst("/private".count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateSpelling))
        var s = SearchResultStore()
        s.append(batch(privateSpelling + "/", ["a.txt", "b.txt", "c.txt"]))
        XCTAssertEqual(s.parents, [privateSpelling], "the crawler's spelling is kept")
        XCTAssertEqual(s.path(0), privateSpelling + "/a.txt")
        XCTAssertEqual(s.identity(0), .name(privateSpelling + "/a.txt"))
        XCTAssertEqual(s.index(ofPath: varSpelling + "/a.txt"), 0)
        XCTAssertEqual(s.index(ofPath: privateSpelling + "/a.txt"), 0)
        s.append(batch(varSpelling, ["d.txt"]))                  // the same folder in the other spelling
        XCTAssertEqual(s.parents, [privateSpelling])
        XCTAssertEqual(s.remove(paths: [privateSpelling + "/a.txt"]), 1)
        XCTAssertEqual(s.remove(paths: [varSpelling + "/b.txt"]), 1)
        XCTAssertTrue(s.rename(path: varSpelling + "/c.txt", to: "c2.txt", types: types))
        XCTAssertNotNil(s.index(ofPath: privateSpelling + "/c2.txt"))
        XCTAssertEqual(s.count, 2)
    }

    func testMissingParentNormalizesTheSameWay() {
        var s = SearchResultStore()
        s.append(batch("/private/var/macx-missing-\(UUID().uuidString)/./x/../y//", ["n"]))
        XCTAssertTrue(s.parents[0].hasPrefix("/private/var/macx-missing-"))
        XCTAssertTrue(s.parents[0].hasSuffix("/y"))
    }
}
