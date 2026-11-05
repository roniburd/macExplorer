import Foundation
import MacxFixtures
import MacxFS
import XCTest
@testable import Core

@MainActor
final class SettingsTypesTests: XCTestCase {
    func testIconSizePointsAndDensityRowHeights() {
        XCTAssertEqual(IconSize.allCases.map(\.points), [32, 64, 128])
        XCTAssertEqual(Density.allCases.map(\.rowHeight), [20, 24, 30])
    }

    func testColumnSortFieldsMapOneToOne() {
        for id in ColumnID.allCases { XCTAssertEqual(id.sortField.rawValue, id.rawValue) }
        XCTAssertEqual(ColumnID.allCases, [.name, .dateModified, .size, .kind, .dateCreated, .fileExtension])
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(ViewMode.allCases.map(\.rawValue), ["details", "icons"])
        XCTAssertEqual(DefaultFavorite.allCases.map(\.rawValue), ["home", "desktop", "documents", "downloads", "applications"])
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue), ["favorites", "locations", "folders"])
        XCTAssertEqual(TCCOutcome.granted.rawValue, "granted")
    }

    func testCodableRoundTripOfAssociatedValueEnums() throws {
        let values: [StartupFolder] = [.home, .lastLocation, .custom(URL(filePath: "/tmp/x", directoryHint: .isDirectory))]
        XCTAssertEqual(try JSONDecoder().decode([StartupFolder].self, from: JSONEncoder().encode(values)), values)
        let locations: [ProtectedLocation] = [.desktop, .documents, .downloads, .iCloudDrive,
                                              .removableVolume(VolumeID(raw: "uuid:A")), .networkVolume(VolumeID(raw: "mnt:/Volumes/S"))]
        XCTAssertEqual(try JSONDecoder().decode([ProtectedLocation].self, from: JSONEncoder().encode(locations)), locations)
    }
}

@MainActor
final class SettingsStorageTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUp() async throws {
        sandbox = try Sandbox()
    }

    override func tearDown() async throws {
        sandbox.destroy()
        sandbox = nil
    }

    func testInMemoryStorageSetGetAndRemove() {
        let s = InMemorySettingsStorage()
        XCTAssertNil(s.data(forKey: "a"))
        s.set(Data([1, 2]), forKey: "a")
        XCTAssertEqual(s.data(forKey: "a"), Data([1, 2]))
        s.set(nil, forKey: "a")
        XCTAssertNil(s.data(forKey: "a"))
    }

    func testFileStoragePersistsAcrossInstances() throws {
        let file = sandbox.url("state/settings.json")
        let a = FileSettingsStorage(fileURL: file)
        XCTAssertNil(a.data(forKey: "k"), "a missing file is an empty store")
        a.set(Data("v1".utf8), forKey: "k")
        a.set(Data("w".utf8), forKey: "other")
        a.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), "creates the parent directory")
        let b = FileSettingsStorage(fileURL: file)
        XCTAssertEqual(b.data(forKey: "k"), Data("v1".utf8))
        b.set(nil, forKey: "k")
        b.flush()
        let c = FileSettingsStorage(fileURL: file)
        XCTAssertNil(c.data(forKey: "k"))
        XCTAssertEqual(c.data(forKey: "other"), Data("w".utf8))
    }

    func testFileStorageIgnoresCorruptFile() throws {
        try sandbox.createFile("settings.json", contents: Data("not json".utf8))
        let s = FileSettingsStorage(fileURL: sandbox.url("settings.json"))
        XCTAssertNil(s.data(forKey: "k"))
        s.set(Data("v".utf8), forKey: "k")
        s.flush()
        XCTAssertEqual(FileSettingsStorage(fileURL: sandbox.url("settings.json")).data(forKey: "k"), Data("v".utf8))
    }

    func testFileStorageLeavesNoTemporaryFiles() throws {
        let s = FileSettingsStorage(fileURL: sandbox.url("settings.json"))
        for i in 0..<5 { s.set(Data([UInt8(i)]), forKey: "k\(i)") }
        s.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path(percentEncoded: false))
        XCTAssertEqual(names, ["settings.json"])
    }

    /// §4.4: a set never writes on main; writes are coalesced and land off main after the debounce.
    func testFileStorageCoalescesWritesOffMain() async throws {
        let file = sandbox.url("settings.json")
        let s = FileSettingsStorage(fileURL: file, debounce: .milliseconds(100))
        for i in 0..<200 { s.set(Data([UInt8(i % 256)]), forKey: "width") }      // a column-resize drag
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), "set does no file I/O")
        let deadline = ContinuousClock.now + .seconds(5)
        while s.writeCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(s.writeCount, 1, "one write for the whole drag")
        XCTAssertEqual(FileSettingsStorage(fileURL: file).data(forKey: "width"), Data([199]))
        XCTAssertFalse(s.lastWriteWasOnMain)
    }

    func testFileStorageFlushWritesNowAndDeinitFlushesPending() throws {
        let file = sandbox.url("settings.json")
        let s = FileSettingsStorage(fileURL: file, debounce: .seconds(60))
        s.set(Data("now".utf8), forKey: "k")
        s.flush()
        XCTAssertEqual(FileSettingsStorage(fileURL: file).data(forKey: "k"), Data("now".utf8))
        s.flush()
        XCTAssertEqual(s.writeCount, 1, "nothing pending → no write")
        do {
            let t = FileSettingsStorage(fileURL: file, debounce: .seconds(60))
            t.set(Data("late".utf8), forKey: "k")
        }
        XCTAssertEqual(FileSettingsStorage(fileURL: file).data(forKey: "k"), Data("late".utf8), "a released store writes what it held")
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    private let home = URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory)

    func testSchemaVersionIsOne() {
        XCTAssertEqual(Settings.schemaVersion, 1)
        XCTAssertFalse(Settings.schemaVersionKey.isEmpty)
    }

    func testDefaults() {
        let s = Settings(storage: InMemorySettingsStorage(), home: home)
        XCTAssertEqual(s.home, home, "home is stored as given")
        XCTAssertEqual(s.startupFolder, .home)
        XCTAssertEqual(s.openFoldersIn, .sameWindow)
        XCTAssertEqual(s.returnKey, .open)
        XCTAssertNil(s.terminalApp)
        XCTAssertEqual(s.viewMode, .details)
        XCTAssertEqual(s.iconSize, .medium)
        XCTAssertEqual(s.density, .regular)
        XCTAssertEqual(s.columns.map(\.id), ColumnID.allCases)
        XCTAssertEqual(s.columns.filter(\.visible).map(\.id), [.name, .dateModified, .size, .kind])
        XCTAssertEqual(s.sort, .default)
        XCTAssertFalse(s.showHidden)
        XCTAssertTrue(s.commandBarVisible)
        XCTAssertTrue(s.autoRevealInTree)
        XCTAssertEqual(s.dateStyle, .relative)
        XCTAssertEqual(s.favorites, [])
        XCTAssertEqual(s.hiddenDefaultFavorites, [])
        XCTAssertTrue(s.showICloudInSidebar)
        XCTAssertTrue(s.showCloudStorageInSidebar)
        XCTAssertTrue(s.showExternalVolumesInSidebar)
        XCTAssertEqual(s.collapsedSections, [])
        XCTAssertFalse(s.confirmBeforeTrash)
        XCTAssertTrue(s.confirmBeforeDelete, "locked on")
        XCTAssertFalse(s.showFullPathInTitle)
        XCTAssertFalse(s.onboardingCompleted)
        XCTAssertFalse(s.toolbarFeedbackItemOffered)
        XCTAssertNil(s.lastLocation)
        XCTAssertEqual(s.recentLocations, [])
        XCTAssertNil(s.tccOutcome(for: .desktop))
    }

    func testDefaultHomeIsTheUserHome() {
        XCTAssertEqual(Settings(storage: InMemorySettingsStorage()).home, FileManager.default.homeDirectoryForCurrentUser)
    }

    func testFreshStoreRecordsSchemaVersionButNoDefaults() throws {
        let storage = InMemorySettingsStorage()
        _ = Settings(storage: storage, home: home)
        let version = try XCTUnwrap(storage.data(forKey: Settings.schemaVersionKey))
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: version), 1)
        XCTAssertEqual(storage.keys, [Settings.schemaVersionKey], "defaults are not written, so later versions can change them")
    }

    func testEveryKeyPersists() throws {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        let custom = URL(filePath: "/tmp/macx-tests-custom", directoryHint: .isDirectory)
        let favorite = Favorite(bookmark: Data([9, 9]), displayName: "Fav", lastKnownPath: "/tmp/fav")
        s.startupFolder = .custom(custom)
        s.openFoldersIn = .newWindow
        s.returnKey = .rename
        s.terminalApp = URL(filePath: "/Applications/iTerm.app", directoryHint: .isDirectory)
        s.viewMode = .icons
        s.iconSize = .large
        s.density = .compact
        s.columns = [ColumnSetting(id: .size, width: 99, visible: true), ColumnSetting(id: .name, width: 300, visible: true)]
        s.sort = SortDescriptor(field: .size, ascending: false)
        s.showHidden = true
        s.commandBarVisible = false
        s.autoRevealInTree = false
        s.dateStyle = .absolute
        s.favorites = [favorite]
        s.hiddenDefaultFavorites = [.applications, .downloads]
        s.showICloudInSidebar = false
        s.showCloudStorageInSidebar = false
        s.showExternalVolumesInSidebar = false
        s.collapsedSections = [.folders]
        s.confirmBeforeTrash = true
        s.showFullPathInTitle = true
        s.onboardingCompleted = true
        s.toolbarFeedbackItemOffered = true
        s.lastLocation = custom
        s.addRecentLocation("/tmp/a")
        s.recordTCCOutcome(.denied, for: .documents)
        s.recordTCCOutcome(.granted, for: .removableVolume(VolumeID(raw: "uuid:X")))

        let r = Settings(storage: storage, home: home)
        XCTAssertEqual(r.startupFolder, .custom(custom))
        XCTAssertEqual(r.openFoldersIn, .newWindow)
        XCTAssertEqual(r.returnKey, .rename)
        XCTAssertEqual(r.terminalApp?.path, "/Applications/iTerm.app")
        XCTAssertEqual(r.viewMode, .icons)
        XCTAssertEqual(r.iconSize, .large)
        XCTAssertEqual(r.density, .compact)
        XCTAssertEqual(r.columns.map(\.id), [.size, .name], "array order is display order")
        XCTAssertEqual(r.columns.first?.width, 99)
        XCTAssertEqual(r.sort, SortDescriptor(field: .size, ascending: false))
        XCTAssertTrue(r.showHidden)
        XCTAssertFalse(r.commandBarVisible)
        XCTAssertFalse(r.autoRevealInTree)
        XCTAssertEqual(r.dateStyle, .absolute)
        XCTAssertEqual(r.favorites, [favorite])
        XCTAssertEqual(r.hiddenDefaultFavorites, [.applications, .downloads])
        XCTAssertFalse(r.showICloudInSidebar)
        XCTAssertFalse(r.showCloudStorageInSidebar)
        XCTAssertFalse(r.showExternalVolumesInSidebar)
        XCTAssertEqual(r.collapsedSections, [.folders])
        XCTAssertTrue(r.confirmBeforeTrash)
        XCTAssertTrue(r.showFullPathInTitle)
        XCTAssertTrue(r.onboardingCompleted)
        XCTAssertTrue(r.toolbarFeedbackItemOffered)
        XCTAssertEqual(r.lastLocation, custom)
        XCTAssertEqual(r.recentLocations, ["/tmp/a"])
        XCTAssertEqual(r.tccOutcome(for: .documents), .denied)
        XCTAssertEqual(r.tccOutcome(for: .removableVolume(VolumeID(raw: "uuid:X"))), .granted)
        XCTAssertNil(r.tccOutcome(for: .removableVolume(VolumeID(raw: "uuid:Y"))))

        s.terminalApp = nil
        s.lastLocation = nil
        let cleared = Settings(storage: storage, home: home)
        XCTAssertNil(cleared.terminalApp)
        XCTAssertNil(cleared.lastLocation)
    }

    func testPersistsThroughFileStorage() throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let file = sandbox.url("state/settings.json")
        let storage = FileSettingsStorage(fileURL: file)
        let s = Settings(storage: storage, home: sandbox.root)
        s.density = .comfortable
        s.recordTCCOutcome(.granted, for: .desktop)
        storage.flush()
        let r = Settings(storage: FileSettingsStorage(fileURL: file), home: sandbox.root)
        XCTAssertEqual(r.density, .comfortable)
        XCTAssertEqual(r.tccOutcome(for: .desktop), .granted)
    }

    func testUndecodableValueFallsBackToDefault() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        s.density = .compact
        s.viewMode = .icons
        for key in storage.keys where key != Settings.schemaVersionKey {
            storage.set(Data("garbage".utf8), forKey: key)
        }
        let r = Settings(storage: storage, home: home)
        XCTAssertEqual(r.density, .regular)
        XCTAssertEqual(r.viewMode, .details)
    }

    func testEmptyStoredColumnsFallBackToDefaults() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        s.columns = []
        XCTAssertEqual(Settings(storage: storage, home: home).columns, Settings.defaultColumns)
    }

    func testRecentLocationsMostRecentFirstDedupedAndCapped() {
        let s = Settings(storage: InMemorySettingsStorage(), home: home)
        s.addRecentLocation("/a")
        s.addRecentLocation("/b")
        s.addRecentLocation("/a")
        XCTAssertEqual(s.recentLocations, ["/a", "/b"])
        s.addRecentLocation("")
        XCTAssertEqual(s.recentLocations, ["/a", "/b"], "empty paths are ignored")
        for i in 0..<30 { s.addRecentLocation("/p\(i)") }
        XCTAssertEqual(s.recentLocations.count, Settings.recentLocationsLimit)
        XCTAssertEqual(Settings.recentLocationsLimit, 20)
        XCTAssertEqual(s.recentLocations.first, "/p29")
        XCTAssertEqual(s.recentLocations.last, "/p10")
    }

    /// §3.9: settable (P1-27 recents, P1-30 "clear recents"), clamped to the limit and persisted.
    func testRecentLocationsAreSettableAndClamped() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        s.recentLocations = (0..<25).map { "/r\($0)" }
        XCTAssertEqual(s.recentLocations.count, Settings.recentLocationsLimit)
        XCTAssertEqual(s.recentLocations.first, "/r0")
        XCTAssertEqual(Settings(storage: storage, home: home).recentLocations.count, Settings.recentLocationsLimit)
        s.recentLocations = []
        XCTAssertEqual(Settings(storage: storage, home: home).recentLocations, [], "clear recents")
    }

    func testRecordingAnOutcomeOverwritesThePreviousOne() {
        let s = Settings(storage: InMemorySettingsStorage(), home: home)
        s.recordTCCOutcome(.denied, for: .downloads)
        s.recordTCCOutcome(.granted, for: .downloads)
        XCTAssertEqual(s.tccOutcome(for: .downloads), .granted)
        XCTAssertNil(s.tccOutcome(for: .desktop))
    }

    func testViewQueryUsesSortAndShowHiddenWithEmptyFilter() {
        let s = Settings(storage: InMemorySettingsStorage(), home: home)
        XCTAssertEqual(s.viewQuery(), ViewQuery())
        s.sort = SortDescriptor(field: .kind, ascending: false)
        s.showHidden = true
        XCTAssertEqual(s.viewQuery(), ViewQuery(sort: SortDescriptor(field: .kind, ascending: false), showHidden: true, filter: ""))
    }

    func testOlderStoredVersionIsRewrittenAndNewerIsKept() throws {
        let storage = InMemorySettingsStorage()
        storage.set(try JSONEncoder().encode(0), forKey: Settings.schemaVersionKey)
        _ = Settings(storage: storage, home: home)
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: XCTUnwrap(storage.data(forKey: Settings.schemaVersionKey))), 1)
        storage.set(try JSONEncoder().encode(7), forKey: Settings.schemaVersionKey)
        _ = Settings(storage: storage, home: home)
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: XCTUnwrap(storage.data(forKey: Settings.schemaVersionKey))), 7,
                       "a newer store is never downgraded")
    }

    func testChangesAreObservable() async {
        let s = Settings(storage: InMemorySettingsStorage(), home: home)
        let fired = expectation(description: "observed")
        withObservationTracking { _ = s.density } onChange: { fired.fulfill() }
        s.density = .compact
        await fulfillment(of: [fired], timeout: 1)
    }
}
