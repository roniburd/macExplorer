import Darwin
import XCTest
@testable import Core
import MacxFS
import MacxFixtures

/// P2-15: Finder xattrs, permissions and owner for the extended Details columns. Every file is inside a Sandbox.
final class ExtendedAttributesTests: XCTestCase {
    func plist(_ v: Any) -> Data { try! PropertyListSerialization.data(fromPropertyList: v, format: .binary, options: 0) }

    func testParseTagsRealFinderFormat() {
        XCTAssertEqual(FinderMetadata.parseTags(plist(["Work\n6", "Home", "Red\n6"])), ["Work", "Home", "Red"])
        XCTAssertEqual(FinderMetadata.parseTags(Data("garbage".utf8)), [])
        XCTAssertEqual(FinderMetadata.parseTags(FinderMetadata.encodeTags(["A", "B"])), ["A", "B"])
    }

    func testParseComment() {
        XCTAssertEqual(FinderMetadata.parseComment(plist("hello")), "hello")
        XCTAssertEqual(FinderMetadata.parseComment(Data("raw text".utf8)), "raw text")
        XCTAssertNil(FinderMetadata.parseComment(Data([0xFF, 0xFE, 0x00])))
    }

    func testParseLastUsed() {
        let d = Date(timeIntervalSince1970: 1_800_000_000.5)
        XCTAssertEqual(FinderMetadata.parseLastUsed(FinderMetadata.encodeLastUsed(d))!.timeIntervalSince1970,
                       d.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(FinderMetadata.parseLastUsed(Data(count: 8)))
        var bad = Data()
        withUnsafeBytes(of: Int64(5).littleEndian) { bad.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64(2_000_000_000).littleEndian) { bad.append(contentsOf: $0) }
        XCTAssertNil(FinderMetadata.parseLastUsed(bad), "nsec out of range")
        XCTAssertEqual(FinderMetadata.encodeLastUsed(d), Sandbox.lastUsedDateValue(d), "same encoding as the fixtures")
    }

    func testPermissionsStrings() {
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o755, kind: .directory), "drwxr-xr-x")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o644, kind: .file), "-rw-r--r--")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o4755, kind: .file), "-rwsr-xr-x")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o2644, kind: .file), "-rw-r-Sr--")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o1777, kind: .directory), "drwxrwxrwt")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o755, kind: .symlink), "lrwxr-xr-x")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o700, kind: .package), "drwx------")
    }

    func testOwnerNames() {
        let cache = OwnerNameCache()
        XCTAssertEqual(cache.name(for: getuid()), NSUserName())
        XCTAssertEqual(cache.name(for: 3_999_999), "3999999")
    }

    func testAttributeSetMapping() {
        XCTAssertEqual(ExtendedAttributeSet(sortField: .owner), .owner)
        XCTAssertEqual(ExtendedAttributeSet(sortField: .name), [])
        XCTAssertEqual(ExtendedAttributeSet(column: .tags), .tags)
        XCTAssertEqual(ExtendedAttributeSet(column: .path), [])
    }

    func testReaderReadsOnlyWhatIsAskedAndNeverFollowsLinks() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.createFile("a.txt", contents: Data(count: 1)); try sandbox.setMode("a.txt", 0o644)
        try sandbox.setFinderTags(["Work"], on: "a.txt"); try sandbox.setFinderComment("note", on: "a.txt")
        let opened = Date(timeIntervalSince1970: 1_700_000_000); try sandbox.setLastUsedDate(opened, on: "a.txt")
        try sandbox.createDirectory("d"); try sandbox.setMode("d", 0o755)
        try sandbox.createSymlink("l", target: "a.txt")
        let dir = sandbox.root
        let owners = OwnerNameCache()
        let lanes = LanePool()
        let all = try await lanes.perform(on: .unknown, .read) { _ in
            ExtendedAttributeReader.read(names: ["a.txt", "d", "l", "missing"], in: dir, wanted: .all, owners: owners)
        }
        XCTAssertNil(all["missing"])
        XCTAssertEqual(all["a.txt"]?.tags, ["Work"])
        XCTAssertEqual(all["a.txt"]?.comment, "note")
        XCTAssertEqual(all["a.txt"]!.lastOpened!.timeIntervalSince1970, opened.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(all["a.txt"]?.mode.map { $0 & 0o7777 }, 0o644)
        XCTAssertEqual(all["a.txt"]?.ownerName, NSUserName())
        XCTAssertEqual(all["a.txt"]?.ownerID, getuid())
        XCTAssertEqual(all["d"]?.mode.map { $0 & 0o7777 }, 0o755)
        XCTAssertEqual(all["d"]?.mode.map { $0 & UInt16(S_IFMT) }, UInt16(S_IFDIR))
        XCTAssertEqual(all["l"]?.mode.map { $0 & UInt16(S_IFMT) }, UInt16(S_IFLNK), "the link itself is stat'ed")
        XCTAssertEqual(all["l"]?.tags, [], "the link itself has no tags; its target's are not read")
        XCTAssertNil(all["l"]?.comment)
        let tagsOnly = try await lanes.perform(on: .unknown, .read) { _ in
            ExtendedAttributeReader.read(names: ["a.txt"], in: dir, wanted: .tags, owners: owners)
        }
        XCTAssertEqual(tagsOnly["a.txt"]?.loaded, .tags)
        XCTAssertEqual(tagsOnly["a.txt"]?.tags, ["Work"])
        XCTAssertNil(tagsOnly["a.txt"]?.mode)
        XCTAssertNil(tagsOnly["a.txt"]?.comment)
        XCTAssertNil(tagsOnly["a.txt"]?.ownerName)
    }

    func testMergingKeepsLoadedFieldsAndTakesNewOnes() {
        var tags = ExtendedAttributes(loaded: .tags); tags.tags = ["A"]
        var perms = ExtendedAttributes(loaded: .permissions); perms.mode = 0o644
        let merged = tags.merging(perms)
        XCTAssertEqual(merged.loaded, [.tags, .permissions])
        XCTAssertEqual(merged.tags, ["A"]); XCTAssertEqual(merged.mode, 0o644)
        var newer = ExtendedAttributes(loaded: .tags); newer.tags = []
        XCTAssertEqual(merged.merging(newer).tags, [])
    }

    @MainActor
    func testRequestLoadsOnlyRequestedRowsAndEmitsTheirIdentities() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a.txt", "b.txt", "c.txt"] { try sandbox.createFile(n, contents: Data(count: 1)) }
        try sandbox.setFinderTags(["Work"], on: "b.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in model.close() }
        var emitted = Set<RowID>()
        let token = model.observe { if case .extendedAttributes(let ids) = $0 { emitted.formUnion(ids) } }
        defer { token.cancel() }
        let b = model.row(named: "b.txt")!
        XCTAssertNil(model.extendedAttributes(atRow: b), "nothing is read until asked")
        model.requestExtendedAttributes(rows: IndexSet([b, 99]), .tags)
        let end = Date().addingTimeInterval(5)
        while model.extendedAttributes(atRow: b) == nil && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.extendedAttributes(atRow: b)?.tags, ["Work"])
        XCTAssertEqual(emitted, [model.identity(atRow: b)])
        XCTAssertNil(model.extendedAttributes(atRow: model.row(named: "a.txt")!))
        await model.loadAllExtendedAttributes(.permissions)
        for row in 0..<model.rowCount {
            XCTAssertNotNil(model.extendedAttributes(atRow: row)?.mode, model.name(atRow: row))
        }
        XCTAssertEqual(model.extendedAttributes(atRow: b)?.tags, ["Work"], "earlier fields are kept")
    }

    // Review Focus 2
    @MainActor
    func testXattrOnlyChangeRefreshesExtendedAttributes() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.createFile("a.txt", contents: Data(count: 1)); try sandbox.createFile("b.txt", contents: Data(count: 1))
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in model.close() }
        model.requestExtendedAttributes(rows: IndexSet(integersIn: 0..<model.rowCount), .tags)
        let row = model.row(named: "a.txt")!
        var end = Date().addingTimeInterval(5)
        while model.extendedAttributes(atRow: row) == nil && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.extendedAttributes(atRow: row)?.tags, [])
        var before = stat(); _ = stat(sandbox.url("a.txt").path(percentEncoded: false), &before)
        try sandbox.setFinderTags(["Home"], on: "a.txt")
        var after = stat(); _ = stat(sandbox.url("a.txt").path(percentEncoded: false), &after)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec, "xattr-only change")
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec, "xattr-only change")
        end = Date().addingTimeInterval(10)
        while model.extendedAttributes(atRow: model.row(named: "a.txt")!)?.tags != ["Home"] && Date() < end {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.extendedAttributes(atRow: model.row(named: "a.txt")!)?.tags, ["Home"])
    }

    /// The watcher path in isolation (no FSEvents timing): an item event marks the cached entry stale and the last
    /// request is re-read; the old value stays visible until the new one arrives (no blank flash).
    @MainActor
    func testItemWatchEventRereadsLastRequest() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.createFile("a.txt", contents: Data(count: 1))
        try sandbox.setFinderComment("old", on: "a.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in model.close() }
        let row = model.row(named: "a.txt")!
        model.requestExtendedAttributes(rows: IndexSet([row]), .comments)
        var end = Date().addingTimeInterval(5)
        while model.extendedAttributes(atRow: row)?.comment != "old" && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        try sandbox.setFinderComment("new", on: "a.txt")
        model.handleWatch(.items(["a.txt"]))
        XCTAssertEqual(model.extendedAttributes(atRow: row)?.comment, "old", "kept until the re-read lands")
        end = Date().addingTimeInterval(5)
        while model.extendedAttributes(atRow: row)?.comment != "new" && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.extendedAttributes(atRow: row)?.comment, "new")
        try sandbox.setFinderComment("rescanned", on: "a.txt")
        model.handleWatch(.fullRescan)
        end = Date().addingTimeInterval(5)
        while model.extendedAttributes(atRow: model.row(named: "a.txt")!)?.comment != "rescanned" && Date() < end {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.extendedAttributes(atRow: model.row(named: "a.txt")!)?.comment, "rescanned")
    }
}
