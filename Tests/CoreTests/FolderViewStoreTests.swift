import XCTest
import Darwin
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class FolderViewStoreTests: XCTestCase {
    let defaults = FolderViewState(mode: .details, columns: [], sort: .default, iconSize: .medium, density: .regular,
                                   groupBy: .none, calculateFolderSizes: false)
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
                   capacity: Int = FolderViewStore.capacity, legacyJSON: (@Sendable () -> Data?)? = nil,
                   now: @escaping @MainActor () -> Date = { Date() }) -> FolderViewStore {
        FolderViewStore(storage: storage, legacyJSON: legacyJSON, now: now, flushDelay: delay, capacity: capacity)
    }
    /// The folder's own record over `defaults` (the store's part of the resolution chain).
    func state(_ store: FolderViewStore, _ l: FolderViewLocator) -> FolderViewState {
        store.settings(for: l)?.resolved(over: defaults) ?? defaults
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

    func testNoSettingsWithoutRecord() {
        XCTAssertNil(makeStore().settings(for: loc("/a", nil, nil)))
        XCTAssertFalse(makeStore().hasOverride(for: loc("/a", nil, nil)))
    }

    func testStateLookupDoesNotCreateRecords() {
        let store = makeStore()
        _ = state(store, loc("/a", nil, nil))
        _ = state(store, loc("/b", volume(id: "uuid:ABC", idStable: true), 3))
        XCTAssertEqual(store.count, 0)
    }

    func testObjectKeyFollowsRenameAndUpdatesPathIndex() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/Photos", v, 42))
        XCTAssertEqual(state(store, loc("/u/Pictures", v, 42)), icons, "renamed folder keeps its view")
        XCTAssertEqual(state(store, loc("/u/Pictures", v, nil)), icons, "path index now points at the new name")
        XCTAssertEqual(state(store, loc("/u/Photos", v, nil)), defaults, "old name no longer indexed")
    }

    func testNewFolderAtOldPathDoesNotInheritWhenItsIDIsKnown() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/Photos", v, 42))
        XCTAssertEqual(state(store, loc("/u/Photos", v, 99)), defaults)
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
        XCTAssertEqual(state(store, loc("/u/Photos", v, nil)), list, "the edit shows at the path meanwhile")
        XCTAssertEqual(state(store, loc("/u/Pictures", v, 42)), icons, "P keeps its own view")
        store.save(list, for: loc("/u/Photos", v, 99))                      // the probe returned
        XCTAssertEqual(state(store, loc("/u/Photos", v, 99)), list)
        XCTAssertEqual(state(store, loc("/u/Pictures", v, 42)), icons)
        XCTAssertEqual(store.count, 2, "the pending path record became the new folder's object record")
    }

    /// The same edit-before-probe in the folder itself (not renamed): one record, keyed by its object key.
    func testEditBeforeProbeInSameFolderEndsAsOneObjectRecord() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/dev", v, 7))
        var list = defaults; list.mode = .columns
        store.save(list, for: loc("/u/dev", v, nil))
        XCTAssertEqual(state(store, loc("/u/dev", v, nil)), list)
        store.save(list, for: loc("/u/dev", v, 7))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(state(store, loc("/u/dev", v, 7)), list)
        XCTAssertEqual(state(store, loc("/u/dev", v, nil)), list)
    }

    func testPathKeyOnCaseInsensitiveNonStableVolume() {
        let exfat = volume(id: "uuid:USB", idStable: false, caseSensitive: false)
        let store = makeStore()
        store.save(icons, for: loc("/Volumes/USB/Photos", exfat, 5))
        XCTAssertEqual(state(store, loc("/Volumes/USB/photos", exfat, nil)), icons)
        XCTAssertEqual(state(store, loc("/Volumes/USB/Photos\u{0301}", exfat, nil)), defaults, "different name")
    }

    func testPathRecordMigratesToObjectKeyWithoutDuplicating() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/dev", v, nil))
        XCTAssertEqual(state(store, loc("/u/dev", v, 7)), icons, "object miss falls back to the path record")
        var grouped = icons; grouped.groupBy = .kind
        store.save(grouped, for: loc("/u/dev", v, 7))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(state(store, loc("/u/dev", v, 7)), grouped)
        XCTAssertEqual(state(store, loc("/u/dev", v, nil)), grouped)
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
        XCTAssertEqual(state(makeStore(storage), loc("/a", nil, nil)), icons)
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
        XCTAssertEqual(state(reloaded, loc("/u/Photos", v, nil)), icons, "path index survives a reload")
        XCTAssertEqual(state(reloaded, loc("/u/Renamed", v, 42)), icons, "object key survives a reload")
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
        XCTAssertEqual(self.state(reloaded, loc("/Users/someone/Projects/folder-7", v, 1_000_007)), state)
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
        XCTAssertEqual(state(makeStore(storage), loc("/a", nil, nil)), icons)
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
                                    density: .compact, groupBy: .nameFirstLetter, calculateFolderSizes: true)
        for i in 0..<50 {
            state.columns[i % state.columns.count].width += 0.5
            state.columns[(i + 3) % state.columns.count].visible.toggle()
            let l = loc("/r/\(i)", i.isMultiple(of: 2) ? v : nil, i.isMultiple(of: 2) ? UInt64(i) : nil)
            // Partial records too: one field set, or only some (the merge's per-field records).
            let settings: FolderViewSettings = switch i % 5 {
            case 0: FolderViewSettings(groupBy: .kind)
            case 1: FolderViewSettings(viewMode: .icons, density: .comfortable)
            case 2: FolderViewSettings(sort: MacxFS.SortDescriptor(field: .tags, ascending: true), columns: state.columns)
            case 3: FolderViewSettings(calculateFolderSizes: false)
            default: (i == 9 ? defaults : state).settings
            }
            records.append(.init(key: l.primaryKey, pathKey: l.pathKey, settings: settings,
                                 lastUsed: Date(timeIntervalSinceReferenceDate: 1_000_000.25 - Double(i))))
        }
        let data = try XCTUnwrap(FolderViewStore.encode(records))
        XCTAssertEqual(FolderViewStore.decode(data), records)
        XCTAssertNil(FolderViewStore.decode(Data("macx-folder-views\t3\nR\tbad\n".utf8)))
        XCTAssertEqual(FolderViewStore.decode(Data("macx-folder-views\t3\n".utf8)), [])
        XCTAssertNil(FolderViewStore.decode(Data("macx-folder-views\t3\nR\t\t\t\tname\t\t\t\t\t\t\t\t0\t/p\n".utf8)),
                     "a sort field without its direction")
    }

    func testCorruptStorageIsEmptyStore() {
        let storage = InMemorySettingsStorage()
        storage.set(Data("not json".utf8), forKey: FolderViewStore.storageKey)
        let store = makeStore(storage)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(state(store, loc("/a", nil, nil)), defaults)
    }

    func testEvictionKeepsMostRecentlyUsed() {
        var t = Date(timeIntervalSince1970: 0)
        let store = makeStore(now: { t })
        for i in 0...FolderViewStore.capacity {
            t = t.addingTimeInterval(1)
            store.save(icons, for: loc("/f\(i)", nil, nil))
            if i == 1 { t = t.addingTimeInterval(1); _ = state(store, loc("/f0", nil, nil)) }   // /f0 used after /f1
        }
        XCTAssertEqual(store.count, FolderViewStore.capacity)
        XCTAssertFalse(store.hasOverride(for: loc("/f1", nil, nil)), "least recently used is evicted")
        XCTAssertTrue(store.hasOverride(for: loc("/f0", nil, nil)))
        XCTAssertTrue(store.hasOverride(for: loc("/f\(FolderViewStore.capacity)", nil, nil)))
    }

    func testRemoveAllAndApplyDefaultView() {
        let storage = InMemorySettingsStorage()
        let settings = Settings(storage: storage)
        let store = FolderViewStore(storage: storage)
        store.save(icons, for: loc("/a", nil, nil))
        var applied = icons; applied.calculateFolderSizes = true; applied.groupBy = .size
        settings.applyDefaultView(applied)
        store.removeAll()
        XCTAssertEqual(store.count, 0)
        XCTAssertNotNil(storage.data(forKey: FolderViewStore.storageKey), "removeAll writes now")
        XCTAssertEqual(FolderViewStore(storage: storage).count, 0)
        let d = store.settings(for: loc("/b", nil, nil))?.resolved(over: settings.defaultFolderViewState()) ?? settings.defaultFolderViewState()
        XCTAssertEqual(d.mode, .icons); XCTAssertEqual(d.iconSize, .large); XCTAssertEqual(d.groupBy, .size)
        XCTAssertFalse(d.calculateFolderSizes, "folder sizes are always per folder, never a default")
        XCTAssertEqual(settings.viewMode, .icons)
        XCTAssertNil(store.settings(for: loc("/a", nil, nil)), "every folder follows the new defaults")
    }

    func testSandboxedEnvironmentHasFolderViewsOverInMemoryStorage() throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        XCTAssertEqual(env.folderViews.count, 0)
        XCTAssertNil(env.folderViews.settings(for: loc(sandbox.root.path, nil, nil)))
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
    // MARK: per-field records (the merge with design 2026-11-05 §2)

    func testUpdatePersistsOnlyChangedFieldsAndSurvivesReload() {
        let storage = InMemorySettingsStorage()
        let store = makeStore(storage)
        store.update(loc("/tmp/macx-test/a", nil, nil)) { $0.iconSize = .large }
        store.update(loc("/tmp/macx-test/a/", nil, nil)) { $0.viewMode = .icons }
        store.flush()
        let reloaded = makeStore(storage)
        XCTAssertEqual(reloaded.settings(for: loc("/tmp/macx-test/a", nil, nil)), FolderViewSettings(viewMode: .icons, iconSize: .large))
        XCTAssertNil(reloaded.settings(for: loc("/tmp/macx-test/b", nil, nil)))
    }

    func testEmptySettingsRemoveTheEntry() {
        let store = makeStore()
        store.update(loc("/a", nil, nil)) { $0.density = .compact }
        store.update(loc("/a", nil, nil)) { $0.density = nil }
        XCTAssertEqual(store.count, 0)
    }

    func testLeastRecentlyUsedEntriesAreEvicted() {
        final class Clock { var t = 0.0 }
        let clock = Clock()
        let store = makeStore(capacity: 3, now: { Date(timeIntervalSince1970: clock.t) })
        for name in ["a", "b", "c"] {
            clock.t += 1
            store.update(loc("/\(name)", nil, nil)) { $0.viewMode = .icons }
        }
        clock.t += 1
        _ = store.settings(for: loc("/a", nil, nil))            // a is now the most recent
        clock.t += 1
        store.update(loc("/d", nil, nil)) { $0.viewMode = .icons }
        XCTAssertEqual(store.count, 3)
        XCTAssertNil(store.settings(for: loc("/b", nil, nil)))
        XCTAssertNotNil(store.settings(for: loc("/a", nil, nil)))
    }

    /// An edit made while the identity probe was pending (a partial path record) is merged into the folder's object
    /// record when the probe returns: the newer fields win, the object record's other fields stay.
    func testAdoptMergesPendingPathEditIntoObjectRecord() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.update(loc("/u/dev", v, 7)) { $0.viewMode = .icons; $0.iconSize = .large }
        store.update(loc("/u/dev", v, nil)) { $0.iconSize = .small; $0.groupBy = .kind }
        store.adopt(loc("/u/dev", v, 7))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.settings(for: loc("/u/moved", v, 7)), FolderViewSettings(viewMode: .icons, iconSize: .small, groupBy: .kind))
        store.adopt(loc("/u/dev", v, 7))      // nothing pending: no-op
        XCTAssertEqual(store.count, 1)
    }

    func testRemoveForgetsTheFolderOnly() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.update(loc("/u/a", v, 1)) { $0.viewMode = .icons }
        store.update(loc("/u/b", v, 2)) { $0.viewMode = .icons }
        store.remove(loc("/u/renamed-a", v, 1))
        XCTAssertNil(store.settings(for: loc("/u/a", v, 1)))
        XCTAssertNotNil(store.settings(for: loc("/u/b", v, 2)))
        store.update(loc("/x", nil, nil)) { $0.groupBy = .size }
        store.remove(loc("/X", nil, nil))     // case-insensitive path key
        XCTAssertEqual(store.count, 1)
    }

    func testFinderViewsAreCachedPerPathAndNeverPersisted() {
        let storage = InMemorySettingsStorage()
        let store = makeStore(storage)
        XCTAssertNil(store.finderView(for: URL(filePath: "/f")))
        store.setFinderView(FolderViewSettings(viewMode: .icons), for: URL(filePath: "/f/", directoryHint: .isDirectory))
        XCTAssertEqual(store.finderView(for: URL(filePath: "/f")), FolderViewSettings(viewMode: .icons))
        store.flush()
        XCTAssertNil(makeStore(storage).finderView(for: URL(filePath: "/f")))
        XCTAssertEqual(makeStore(storage).count, 0)
    }

    /// Users of the path-keyed JSON store (`folder-views.json`) keep their views: imported once as path records
    /// (the identity probe later moves each to its object key), written in the new format; the file is untouched.
    func testImportsLegacyJSONOnceAsPathRecords() async throws {
        let json = Data("""
        {"folders":{"/Users/u/Photos":{"lastUsed":100,"settings":{"iconSize":"large","viewMode":"icons"}},
                    "/Users/u/Docs":{"lastUsed":200,"settings":{"sort":{"ascending":false,"field":"size"}}},
                    "/Users/u/Empty":{"lastUsed":300,"settings":{}}},"version":1}
        """.utf8)
        let storage = InMemorySettingsStorage()
        let reads = LegacyReads(json)
        let store = makeStore(storage, delay: .zero, legacyJSON: { reads.read() })
        await store.legacyImportFinished()
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(store.count, 2, "empty entries are dropped")
        let v = volume(id: "uuid:ABC", idStable: true)
        XCTAssertEqual(store.settings(for: loc("/Users/u/Photos", v, nil)), FolderViewSettings(viewMode: .icons, iconSize: .large))
        XCTAssertEqual(store.settings(for: loc("/Users/u/Docs", nil, nil))?.sort, MacxFS.SortDescriptor(field: .size, ascending: false))
        store.adopt(loc("/Users/u/Photos", v, 42))
        XCTAssertEqual(store.settings(for: loc("/Users/u/Pictures", v, 42))?.viewMode, .icons, "now keyed by identity")
        store.flush()
        let again = makeStore(storage, legacyJSON: { reads.read() })
        await again.legacyImportFinished()
        XCTAssertEqual(reads.count, 1, "imported once: the new store exists now")
        XCTAssertEqual(again.count, 2)
        XCTAssertEqual(again.settings(for: loc("/users/u/DOCS", v, nil))?.sort, MacxFS.SortDescriptor(field: .size, ascending: false),
                       "case-insensitive volume: matched in any case")
    }

    /// Post-merge review: main's paths keep their case, so a case-sensitive volume finds (and adopts) them, and two
    /// entries that differ only in case stay two records.
    func testLegacyJSONPathsKeepTheirCaseOnCaseSensitiveVolumes() async throws {
        let json = Data("""
        {"folders":{"/Users/u/Photos":{"lastUsed":100,"settings":{"viewMode":"icons"}},
                    "/Users/u/photos":{"lastUsed":200,"settings":{"iconSize":"small"}}},"version":1}
        """.utf8)
        let store = makeStore(legacyJSON: { json })
        await store.legacyImportFinished()
        XCTAssertEqual(store.count, 2)
        let cs = volume(id: "uuid:CS", idStable: true, caseSensitive: true)
        XCTAssertEqual(store.settings(for: loc("/Users/u/Photos", cs, nil)), FolderViewSettings(viewMode: .icons))
        XCTAssertEqual(store.settings(for: loc("/Users/u/photos", cs, nil)), FolderViewSettings(iconSize: .small))
        XCTAssertNil(store.settings(for: loc("/Users/u/PHOTOS", cs, nil)))
        store.adopt(loc("/Users/u/Photos", cs, 7))
        XCTAssertEqual(store.settings(for: loc("/Users/u/Moved", cs, 7)), FolderViewSettings(viewMode: .icons), "adopted")
        XCTAssertEqual(store.count, 2)
    }

    /// Post-merge review: the file is read and decoded off main, and records made meanwhile win.
    func testLegacyImportRunsOffMainAndKeepsNewerRecords() async throws {
        let json = Data(#"{"folders":{"/Users/u/Photos":{"lastUsed":100,"settings":{"viewMode":"icons"}}},"version":1}"#.utf8)
        let gate = LegacyReads(json, blocking: true)
        let store = makeStore(legacyJSON: { gate.read() })
        store.update(loc("/Users/u/Photos", nil, nil)) { $0.iconSize = .small }
        gate.release()
        await store.legacyImportFinished()
        XCTAssertEqual(gate.readOnMain, false)
        XCTAssertEqual(store.settings(for: loc("/Users/u/Photos", nil, nil)), FolderViewSettings(iconSize: .small))
        XCTAssertEqual(store.count, 1)
    }

    /// Post-merge review: nothing to import still writes the new store, so the file is never probed again.
    func testLegacyImportIsNotRetriedWhenNothingWasImported() async throws {
        let storage = InMemorySettingsStorage()
        let reads = LegacyReads(Data("{not json".utf8))
        let store = makeStore(storage, delay: .zero, legacyJSON: { reads.read() })
        await store.legacyImportFinished()
        XCTAssertEqual(store.count, 0)
        try await waitUntil { storage.data(forKey: FolderViewStore.storageKey) != nil }
        let again = makeStore(storage, legacyJSON: { reads.read() })
        await again.legacyImportFinished()
        XCTAssertEqual(reads.count, 1)
    }

    /// A flush (quit) before the background import is done imports synchronously first; "Apply to All" drops it.
    func testFlushBeforeTheImportFinishesKeepsTheLegacyViewsAndRemoveAllDropsThem() async throws {
        let json = Data(#"{"folders":{"/Users/u/Photos":{"lastUsed":100,"settings":{"viewMode":"icons"}}},"version":1}"#.utf8)
        let storage = InMemorySettingsStorage()
        let gate = LegacyReads(json, blocking: true)
        let store = makeStore(storage, legacyJSON: { gate.read() })
        store.flush()
        XCTAssertEqual(store.count, 1)
        gate.release()
        await store.legacyImportFinished()
        XCTAssertEqual(makeStore(storage).settings(for: loc("/Users/u/Photos", nil, nil)), FolderViewSettings(viewMode: .icons))

        let other = InMemorySettingsStorage()
        let gate2 = LegacyReads(json, blocking: true)
        let cleared = makeStore(other, legacyJSON: { gate2.read() })
        cleared.removeAll()
        gate2.release()
        await cleared.legacyImportFinished()
        XCTAssertEqual(cleared.count, 0)
        XCTAssertEqual(makeStore(other).count, 0)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testCorruptLegacyJSONIsIgnored() async {
        let store = makeStore(legacyJSON: { Data("{not json".utf8) })
        await store.legacyImportFinished()
        XCTAssertEqual(store.count, 0)
    }

    /// Phase 2 development builds wrote full records in format 2 under "folderViews.v2": imported, then removed.
    func testImportsVersion2Store() throws {
        let storage = InMemorySettingsStorage()
        let v2 = "macx-folder-views\t2\nC\tname:280.0:1\nR\tABC\t42\ticons\tsize\t0\tlarge\tkind\t1\t0\t1000.0\t/u/photos\n"
        storage.set(Data(v2.utf8), forKey: "folderViews.v2")
        let store = makeStore(storage)
        let v = volume(id: "uuid:ABC", idStable: true)
        XCTAssertEqual(store.settings(for: loc("/u/elsewhere", v, 42)),
                       FolderViewSettings(viewMode: .icons, iconSize: .large, sort: MacxFS.SortDescriptor(field: .size, ascending: false),
                                          columns: [ColumnSetting(id: .name, width: 280, visible: true)], groupBy: .kind,
                                          calculateFolderSizes: true))
        XCTAssertNil(storage.data(forKey: "folderViews.v2"))
    }

    // MARK: resolution chain

    func testResolverOrder() {
        let defaults = FolderViewState(mode: .details, columns: Settings.defaultColumns, sort: .default, iconSize: .medium,
                                       density: .regular, groupBy: .none, calculateFolderSizes: false)
        let finder = FolderViewSettings(viewMode: .details, iconSize: .small, sort: .init(field: .size, ascending: false))
        let builtIn = FolderViewSettings(viewMode: .icons, iconSize: .large)
        let stored = FolderViewSettings(iconSize: .large, groupBy: .kind)
        let view = FolderViewResolver.resolve(stored: stored, finder: finder, builtIn: builtIn, defaults: defaults)
        XCTAssertEqual(view.mode, .details)                              // Finder beats the built-in rule
        XCTAssertEqual(view.iconSize, .large)                            // ours beats Finder
        XCTAssertEqual(view.sort, .init(field: .size, ascending: false))
        XCTAssertEqual(view.density, .regular)                           // nobody set it: global default
        XCTAssertEqual(view.groupBy, .kind)
        XCTAssertFalse(view.calculateFolderSizes)
        let none = FolderViewResolver.resolve(stored: nil, finder: nil, builtIn: builtIn, defaults: defaults)
        XCTAssertEqual(none.mode, .icons)
        XCTAssertEqual(none.iconSize, .large)
    }

    func testBuiltInRuleCoversApplicationFolders() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        for path in ["/Applications", "/Applications/", "/System/Applications", "/Applications/Utilities", "/Users/someone/Applications"] {
            XCTAssertEqual(FolderViewResolver.builtIn(for: URL(filePath: path), home: home).iconSize, .large, path)
        }
        XCTAssertTrue(FolderViewResolver.builtIn(for: URL(filePath: "/Users/someone/Documents"), home: home).isEmpty)
    }

    func testChangesFromAnotherStateAreTheDelta() {
        var next = defaults
        next.iconSize = .small
        next.calculateFolderSizes = true
        XCTAssertEqual(next.changes(from: defaults), FolderViewSettings(iconSize: .small, calculateFolderSizes: true))
        XCTAssertTrue(defaults.changes(from: defaults).isEmpty)
        XCTAssertEqual(defaults.settings.resolved(over: next), defaults)
    }
}

/// The legacy JSON reader for the import tests: counts reads, notes whether the first ran on main, and (blocking)
/// holds the first read until `release()`; later reads (the synchronous import on flush) return at once.
private final class LegacyReads: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private let gate = DispatchSemaphore(value: 0)
    private var blocking: Bool
    private var reads = 0
    private var onMain: Bool?

    init(_ data: Data, blocking: Bool = false) { self.data = data; self.blocking = blocking }

    var count: Int { lock.withLock { reads } }
    var readOnMain: Bool? { lock.withLock { onMain } }

    func read() -> Data? {
        let wait: Bool = lock.withLock {
            reads += 1
            if onMain == nil { onMain = Thread.isMainThread }
            defer { blocking = false }
            return blocking && !Thread.isMainThread
        }
        if wait { gate.wait() }
        return data
    }

    func release() { gate.signal() }
}
