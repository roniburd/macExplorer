@testable import Core
import Foundation
@testable import MacxFS
import XCTest

/// Display names drive sort, filter and localized-name patches (design 2026-11-05 §1).
final class DisplayNameSortTests: XCTestCase {
    private let types = TypeRegistry()

    private func names(_ store: EntryStore, all: Bool = false) -> [String] {
        store.order.map { store.displayName($0, showAllExtensions: all) }
    }

    private func appsStore() -> EntryStore {
        var store = EntryStore(identityMode: .objectID)
        store.append(TestBatch.make(.initial, [
            TestBatch.Item(name: "Safari Technology Preview.app", id: 1, kind: .package),
            TestBatch.Item(name: "Safari.app", id: 2, kind: .package),
            TestBatch.Item(name: "Notes.app", id: 3, kind: .package),
        ]))
        return store
    }

    func testAppsSortByTheirDisplayNames() async {
        let store = appsStore()
        let worker = FolderWorker(types: types)
        var sorted = store
        sorted.setOrder(await worker.resort(store, tag: 99, query: ViewQuery()))
        XCTAssertEqual(names(sorted), ["Notes", "Safari", "Safari Technology Preview"])
    }

    func testShowAllExtensionsRebuildsKeys() async {
        let store = appsStore()
        let worker = FolderWorker(types: types)
        _ = await worker.resort(store, tag: 99, query: ViewQuery())
        var sorted = store
        sorted.setOrder(await worker.resort(store, tag: 99, query: ViewQuery(showAllExtensions: true)))
        // "." (0x2E) sorts after " " (0x20): with extensions shown the longer name comes first, as in a raw listing.
        XCTAssertEqual(names(sorted, all: true), ["Notes.app", "Safari Technology Preview.app", "Safari.app"])
    }

    func testFilterMatchesDisplayNames() async {
        let store = appsStore()
        let worker = FolderWorker(types: types)
        let hiddenExtensions = await worker.resort(store, tag: 99, query: ViewQuery(filter: ".app"))
        let shownExtensions = await worker.resort(store, tag: 99, query: ViewQuery(filter: ".app", showAllExtensions: true))
        XCTAssertEqual(hiddenExtensions.count, 0)
        XCTAssertEqual(shownExtensions.count, 3)
    }

    func testLocalizedStemsResortAndReloadTheirRows() async throws {
        var store = appsStore()
        let worker = FolderWorker(types: types)
        store.setOrder(await worker.resort(store, tag: 99, query: ViewQuery()))
        let notes = try XCTUnwrap(store.firstIndex(of: .object(3)))
        let applied = await worker.applyLocalizedStems(store, tag: 99, stems: [.object(3): "Zettel"], query: ViewQuery())
        let result = try XCTUnwrap(applied)
        XCTAssertEqual(names(result.store), ["Safari", "Safari Technology Preview", "Zettel"])
        XCTAssertEqual(result.store.localizedStem(notes), "Zettel")
        XCTAssertFalse(result.diff.changes.isEmpty)
        DiffChecker.check(old: store, new: result.store, result: result.diff)
        // Applying the same stems again changes nothing.
        let again = await worker.applyLocalizedStems(result.store, tag: result.tag, stems: [.object(3): "Zettel"], query: ViewQuery())
        XCTAssertNil(again)
    }

    func testStoreSideTableFollowsRemoveAndUpsert() throws {
        var store = appsStore()
        store.setLocalizedStem("Vorschau", at: 2)
        store.remove([0])
        XCTAssertEqual(store.localizedStem(1), "Vorschau")
        XCTAssertEqual(store.displayName(1, showAllExtensions: false), "Vorschau")
        let entry = store.entry(1)
        store.upsert(entry, name: "Notes.app")
        XCTAssertNil(store.localizedStem(1))
    }

    func testLocalizedStemRule() {
        XCTAssertEqual(FolderModel.localizedStem(realName: "System Settings.app", localized: "Ajustes del Sistema"), "Ajustes del Sistema")
        XCTAssertEqual(FolderModel.localizedStem(realName: "System Settings.app", localized: "Ajustes del Sistema.app"), "Ajustes del Sistema")
        XCTAssertEqual(FolderModel.localizedStem(realName: "Safari.app", localized: "Safari"), "")
        XCTAssertEqual(FolderModel.localizedStem(realName: "Safari.app", localized: "Safari.app"), "")
        XCTAssertEqual(FolderModel.localizedStem(realName: "Applications", localized: "Aplicaciones"), "Aplicaciones")
        XCTAssertEqual(FolderModel.localizedStem(realName: "Projects.localized", localized: "Projects"), "Projects")
        XCTAssertEqual(FolderModel.localizedStem(realName: "Projects.localized", localized: ""), "Projects")
    }

    func testLocalizedSubfolderLocations() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        XCTAssertTrue(FolderModel.localizesSubfolders(URL(filePath: "/"), home: home))
        XCTAssertTrue(FolderModel.localizesSubfolders(URL(filePath: "/Users/someone/"), home: home))
        XCTAssertTrue(FolderModel.localizesSubfolders(URL(filePath: "/Users/someone/Library"), home: home))
        XCTAssertFalse(FolderModel.localizesSubfolders(URL(filePath: "/Users/someone/dev"), home: home))
    }
}
