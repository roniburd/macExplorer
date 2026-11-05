import XCTest
import Darwin
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class FolderViewStoreTests: XCTestCase {
    let defaults = FolderViewState(mode: .details, columns: [], sort: .default, iconSize: .medium, groupBy: .none, calculateFolderSizes: false)
    var icons: FolderViewState { var s = defaults; s.mode = .icons; s.iconSize = .large; return s }

    func volume(id: String, idStable: Bool, caseSensitive: Bool = false) -> VolumeInfo {
        VolumeInfo(id: VolumeID(raw: id), mountPoint: URL(filePath: "/", directoryHint: .isDirectory), name: "V", format: "APFS",
                   isBoot: true, isInternal: true, isRemovable: false, isEjectable: false, isLocal: true, isReadOnly: false,
                   isBrowsable: true, totalCapacity: nil,
                   capabilities: VolumeCapabilities(idStable: idStable, renameExcl: true, clone: true, caseSensitive: caseSensitive))
    }
    func loc(_ path: String, _ v: VolumeInfo?, _ id: UInt64?) -> FolderViewLocator {
        FolderViewLocator(url: URL(filePath: path, directoryHint: .isDirectory), volume: v, fileID: id)
    }
    func makeStore(_ storage: InMemorySettingsStorage = InMemorySettingsStorage(), delay: Duration = .seconds(60),
                   now: @escaping @MainActor () -> Date = { Date() }) -> FolderViewStore {
        FolderViewStore(storage: storage, defaults: { [defaults] in defaults }, now: now, flushDelay: delay)
    }

    func testKeys() {
        let apfs = volume(id: "uuid:ABC", idStable: true)
        XCTAssertEqual(loc("/Users/u/dev/", apfs, 42).primaryKey, .object(volumeUUID: "ABC", fileID: 42))
        XCTAssertEqual(loc("/Users/u/dev", apfs, nil).primaryKey, .path("/users/u/dev"))
        XCTAssertNil(loc("/x", volume(id: "mnt:/Volumes/X", idStable: true), 7).objectKey, "no UUID → path key")
        XCTAssertEqual(loc("/Volumes/CS/Dir", volume(id: "uuid:Q", idStable: false, caseSensitive: true), 7).primaryKey, .path("/Volumes/CS/Dir"))
        XCTAssertEqual(loc("/Users/u/dev/", apfs, nil).path, "/Users/u/dev", "no trailing slash")
        XCTAssertEqual(loc("/", nil, nil).path, "/")
        XCTAssertEqual(loc("/A/Cafe\u{0301}", nil, nil).pathKey, .path("/a/caf\u{00E9}"), "NFC + lowercased")
    }

    func testDefaultsWithoutRecord() {
        XCTAssertEqual(makeStore().state(for: loc("/a", nil, nil)), defaults)
        XCTAssertFalse(makeStore().hasOverride(for: loc("/a", nil, nil)))
    }

    func testStateLookupDoesNotCreateRecords() {
        let store = makeStore()
        _ = store.state(for: loc("/a", nil, nil))
        _ = store.state(for: loc("/b", volume(id: "uuid:ABC", idStable: true), 3))
        XCTAssertEqual(store.count, 0)
    }

    func testObjectKeyFollowsRenameAndUpdatesPathIndex() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/Photos", v, 42))
        XCTAssertEqual(store.state(for: loc("/u/Pictures", v, 42)), icons, "renamed folder keeps its view")
        XCTAssertEqual(store.state(for: loc("/u/Pictures", v, nil)), icons, "path index now points at the new name")
        XCTAssertEqual(store.state(for: loc("/u/Photos", v, nil)), defaults, "old name no longer indexed")
    }

    func testNewFolderAtOldPathDoesNotInheritWhenItsIDIsKnown() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/Photos", v, 42))
        XCTAssertEqual(store.state(for: loc("/u/Photos", v, 99)), defaults)
        XCTAssertFalse(store.hasOverride(for: loc("/u/Photos", v, 99)))
    }

    /// Review fix: P (fileID 42) was renamed away by another app and a new folder created at its old path. An edit
    /// made there before the identity probe returns must not overwrite P's record; once the probe returns, the edit
    /// moves to the new folder's own object record.
    func testEditBeforeProbeAtOldPathOfRenamedFolderKeepsItsRecord() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/Photos", v, 42))
        var list = defaults; list.mode = .columns
        store.save(list, for: loc("/u/Photos", v, nil))                     // edit before the probe returns
        XCTAssertEqual(store.state(for: loc("/u/Photos", v, nil)), list, "the edit shows at the path meanwhile")
        XCTAssertEqual(store.state(for: loc("/u/Pictures", v, 42)), icons, "P keeps its own view")
        store.save(list, for: loc("/u/Photos", v, 99))                      // the probe returned
        XCTAssertEqual(store.state(for: loc("/u/Photos", v, 99)), list)
        XCTAssertEqual(store.state(for: loc("/u/Pictures", v, 42)), icons)
        XCTAssertEqual(store.count, 2, "the pending path record became the new folder's object record")
    }

    /// The same edit-before-probe in the folder itself (not renamed): one record, keyed by its object key.
    func testEditBeforeProbeInSameFolderEndsAsOneObjectRecord() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/dev", v, 7))
        var list = defaults; list.mode = .columns
        store.save(list, for: loc("/u/dev", v, nil))
        XCTAssertEqual(store.state(for: loc("/u/dev", v, nil)), list)
        store.save(list, for: loc("/u/dev", v, 7))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.state(for: loc("/u/dev", v, 7)), list)
        XCTAssertEqual(store.state(for: loc("/u/dev", v, nil)), list)
    }

    func testPathKeyOnCaseInsensitiveNonStableVolume() {
        let exfat = volume(id: "uuid:USB", idStable: false, caseSensitive: false)
        let store = makeStore()
        store.save(icons, for: loc("/Volumes/USB/Photos", exfat, 5))
        XCTAssertEqual(store.state(for: loc("/Volumes/USB/photos", exfat, nil)), icons)
        XCTAssertEqual(store.state(for: loc("/Volumes/USB/Photos\u{0301}", exfat, nil)), defaults, "different name")
    }

    func testPathRecordMigratesToObjectKeyWithoutDuplicating() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/dev", v, nil))
        XCTAssertEqual(store.state(for: loc("/u/dev", v, 7)), icons, "object miss falls back to the path record")
        var grouped = icons; grouped.groupBy = .kind
        store.save(grouped, for: loc("/u/dev", v, 7))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.state(for: loc("/u/dev", v, 7)), grouped)
        XCTAssertEqual(store.state(for: loc("/u/dev", v, nil)), grouped)
    }

    func testPersistenceAndDebounce() async throws {
        let storage = InMemorySettingsStorage()
        let store = makeStore(storage, delay: .milliseconds(50))
        store.save(icons, for: loc("/a", nil, nil))
        XCTAssertNil(storage.data(forKey: FolderViewStore.storageKey), "debounced")
        let deadline = Date().addingTimeInterval(30)
        while storage.data(forKey: FolderViewStore.storageKey) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(storage.data(forKey: FolderViewStore.storageKey))
        XCTAssertEqual(makeStore(storage).state(for: loc("/a", nil, nil)), icons)
    }

    func testFlushWritesImmediatelyAndRoundTripsObjectKeys() {
        let storage = InMemorySettingsStorage()
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore(storage)
        store.save(icons, for: loc("/u/Photos", v, 42))
        store.flush()
        XCTAssertNotNil(storage.data(forKey: FolderViewStore.storageKey))
        let reloaded = makeStore(storage)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.state(for: loc("/u/Photos", v, nil)), icons, "path index survives a reload")
        XCTAssertEqual(reloaded.state(for: loc("/u/Renamed", v, 42)), icons, "object key survives a reload")
    }

    /// Review fix (P2-07 perf): a full store stays small. Every record carries all 12 columns (as saved from the
    /// defaults); the shared column list is written once, not once per record.
    func testFullStoreIsCompact() {
        let storage = InMemorySettingsStorage()
        let store = makeStore(storage)
        let v = volume(id: "uuid:0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", idStable: true)
        var state = icons; state.columns = Settings.defaultColumns
        for i in 0..<FolderViewStore.capacity {
            store.save(state, for: loc("/Users/someone/Projects/folder-\(i)", v, UInt64(1_000_000 + i)))
        }
        store.flush()
        let bytes = storage.data(forKey: FolderViewStore.storageKey)?.count ?? 0
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThan(bytes, FolderViewStore.capacity * 200, "\(bytes) bytes for \(FolderViewStore.capacity) records")
        let reloaded = makeStore(storage)
        XCTAssertEqual(reloaded.count, FolderViewStore.capacity)
        XCTAssertEqual(reloaded.state(for: loc("/Users/someone/Projects/folder-7", v, 1_000_007)), state)
    }

    /// Review fix (P2-07 perf): the debounced write sorts and encodes off the main thread; only `storage.set` runs
    /// on main.
    func testDebouncedFlushEncodesOffMain() async throws {
        let storage = InMemorySettingsStorage()
        let store = makeStore(storage, delay: .milliseconds(10))
        store.save(icons, for: loc("/a", nil, nil))
        let deadline = Date().addingTimeInterval(30)
        while storage.data(forKey: FolderViewStore.storageKey) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(storage.data(forKey: FolderViewStore.storageKey))
        XCTAssertEqual(store.backgroundEncodeCount, 1)
        XCTAssertFalse(store.lastEncodeWasOnMain)
        XCTAssertEqual(makeStore(storage).state(for: loc("/a", nil, nil)), icons)
    }

    /// A background encode that finishes after a newer synchronous write (removeAll, termination flush) is dropped.
    func testStaleBackgroundEncodeNeverOverwritesANewerWrite() async throws {
        let storage = InMemorySettingsStorage()
        let store = makeStore(storage, delay: .zero)
        store.save(icons, for: loc("/a", nil, nil))
        try await Task.sleep(for: .milliseconds(1))     // the debounced encode may now be in flight
        store.removeAll()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(makeStore(storage).count, 0)
    }

    /// The text format escapes the separators: a folder name may hold a tab, newline, CR LF or backslash.
    func testPersistedPathsWithSeparatorCharactersRoundTrip() {
        let storage = InMemorySettingsStorage()
        let v = volume(id: "uuid:ABC", idStable: true, caseSensitive: true)
        let store = makeStore(storage)
        let weird = ["/u/tab\there", "/u/new\nline", "/u/cr\r\nlf", "/u/back\\slash\\t", "/u/caf\u{00E9} \u{1F600}"]
        for (i, path) in weird.enumerated() { store.save(icons, for: loc(path, v, UInt64(100 + i))) }
        store.save(icons, for: loc("/plain/path\tkey", nil, nil))
        store.flush()
        let reloaded = makeStore(storage)
        XCTAssertEqual(reloaded.count, weird.count + 1)
        for (i, path) in weird.enumerated() {
            XCTAssertTrue(reloaded.hasOverride(for: loc(path, v, nil)), path)
            XCTAssertTrue(reloaded.hasOverride(for: loc("/moved", v, UInt64(100 + i))), path)
        }
        XCTAssertTrue(reloaded.hasOverride(for: loc("/plain/path\tkey", nil, nil)))
    }

    /// Distinct column lists per record (the bench's worst case) and an empty list both round-trip exactly.
    func testEncodeDecodeRoundTripsEveryField() throws {
        let v = volume(id: "uuid:ABC", idStable: true)
        var records: [FolderViewStore.Record] = []
        var state = FolderViewState(mode: .columns, columns: Settings.defaultColumns,
                                    sort: MacxFS.SortDescriptor(field: .dateModified, ascending: false), iconSize: .small,
                                    groupBy: .nameFirstLetter, calculateFolderSizes: true)
        for i in 0..<50 {
            state.columns[i % state.columns.count].width += 0.5
            state.columns[(i + 3) % state.columns.count].visible.toggle()
            let l = loc("/r/\(i)", i.isMultiple(of: 2) ? v : nil, i.isMultiple(of: 2) ? UInt64(i) : nil)
            records.append(.init(key: l.primaryKey, pathKey: l.pathKey, state: i == 7 ? defaults : state,
                                 lastUsed: Date(timeIntervalSinceReferenceDate: 1_000_000.25 - Double(i))))
        }
        let data = try XCTUnwrap(FolderViewStore.encode(records))
        XCTAssertEqual(FolderViewStore.decode(data), records)
        XCTAssertNil(FolderViewStore.decode(Data("macx-folder-views\t2\nR\tbad\n".utf8)))
        XCTAssertEqual(FolderViewStore.decode(Data("macx-folder-views\t2\n".utf8)), [])
    }

    func testCorruptStorageIsEmptyStore() {
        let storage = InMemorySettingsStorage()
        storage.set(Data("not json".utf8), forKey: FolderViewStore.storageKey)
        let store = makeStore(storage)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.state(for: loc("/a", nil, nil)), defaults)
    }

    func testEvictionKeepsMostRecentlyUsed() {
        var t = Date(timeIntervalSince1970: 0)
        let store = makeStore(now: { t })
        for i in 0...FolderViewStore.capacity {
            t = t.addingTimeInterval(1)
            store.save(icons, for: loc("/f\(i)", nil, nil))
            if i == 1 { t = t.addingTimeInterval(1); _ = store.state(for: loc("/f0", nil, nil)) }   // /f0 used after /f1
        }
        XCTAssertEqual(store.count, FolderViewStore.capacity)
        XCTAssertFalse(store.hasOverride(for: loc("/f1", nil, nil)), "least recently used is evicted")
        XCTAssertTrue(store.hasOverride(for: loc("/f0", nil, nil)))
        XCTAssertTrue(store.hasOverride(for: loc("/f\(FolderViewStore.capacity)", nil, nil)))
    }

    func testRemoveAllAndApplyDefaultView() {
        let storage = InMemorySettingsStorage()
        let settings = Settings(storage: storage)
        let store = FolderViewStore(storage: storage, defaults: { settings.defaultFolderViewState() })
        store.save(icons, for: loc("/a", nil, nil))
        var applied = icons; applied.calculateFolderSizes = true; applied.groupBy = .size
        settings.applyDefaultView(applied)
        store.removeAll()
        XCTAssertEqual(store.count, 0)
        XCTAssertNotNil(storage.data(forKey: FolderViewStore.storageKey), "removeAll writes now")
        XCTAssertEqual(FolderViewStore(storage: storage, defaults: { settings.defaultFolderViewState() }).count, 0)
        let d = store.state(for: loc("/b", nil, nil))
        XCTAssertEqual(d.mode, .icons); XCTAssertEqual(d.iconSize, .large); XCTAssertEqual(d.groupBy, .size)
        XCTAssertFalse(d.calculateFolderSizes, "folder sizes are always per folder, never a default")
        XCTAssertEqual(settings.viewMode, .icons)
        XCTAssertEqual(store.state(for: loc("/a", nil, nil)), d, "untouched folders follow the new defaults")
    }

    func testSandboxedEnvironmentHasFolderViewsOverInMemoryStorage() throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        XCTAssertEqual(env.folderViews.count, 0)
        XCTAssertEqual(env.folderViews.state(for: loc(sandbox.root.path, nil, nil)), env.settings.defaultFolderViewState())
        env.settings.viewMode = .icons
        XCTAssertEqual(env.folderViews.state(for: loc(sandbox.root.path, nil, nil)).mode, .icons, "defaults are live")
    }

    func testIdentityProbeReadsDirectoryInode() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        let dir = try sandbox.createDirectory("d")
        var st = stat(); XCTAssertEqual(lstat(dir.path(percentEncoded: false), &st), 0)
        let lanes = LanePool()
        let id = await FolderIdentityProbe.fileID(of: dir, lanes: lanes, volume: .unknown)
        XCTAssertEqual(id, UInt64(st.st_ino))
        let missing = await FolderIdentityProbe.fileID(of: sandbox.url("missing"), lanes: lanes, volume: .unknown)
        XCTAssertNil(missing)
    }
}
