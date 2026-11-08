import XCTest
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class SettingsV3Tests: XCTestCase {
    let root = URL(filePath: "/tmp/macx-tests-s/root", directoryHint: .isDirectory)

    func testSchemaVersionIsThreeAndDefaults() {
        XCTAssertEqual(Settings.schemaVersion, 3)
        let s = Settings(storage: InMemorySettingsStorage())
        XCTAssertEqual(s.savedSearches, [])
        XCTAssertFalse(s.previewPaneVisible)
        XCTAssertEqual(s.previewPaneWidth, 320)
        XCTAssertEqual(s.searchScope, .thisFolder)
        XCTAssertEqual(s.searchMode, .name)
        XCTAssertFalse(s.searchIncludesPackages)
        XCTAssertEqual(s.resultsColumns.filter(\.visible).map(\.id), [.name, .path, .dateModified, .size, .kind])
        XCTAssertEqual(s.resultsColumns.prefix(5).map(\.width), [260, 260, 150, 80, 140])
        XCTAssertEqual(Set(s.resultsColumns.map(\.id)), Set(ColumnID.allCases))
        XCTAssertEqual(s.resultsColumns.count, ColumnID.allCases.count)
        XCTAssertTrue(SidebarSection.allCases.contains(.searches))
        XCTAssertEqual(SidebarSection.allCases, [.favorites, .searches, .locations, .folders])
    }

    func testVersionTwoStoreMigrates() throws {
        let storage = InMemorySettingsStorage()
        let v2 = Settings(storage: storage)
        v2.columns = [ColumnSetting(id: .name, width: 280, visible: true)]
        storage.set(try JSONEncoder().encode(2), forKey: Settings.schemaVersionKey)
        let r = Settings(storage: storage)
        XCTAssertEqual(r.columns.filter(\.visible).map(\.id), [.name])      // untouched
        XCTAssertEqual(r.savedSearches, [])
        XCTAssertEqual(r.previewPaneWidth, 320)
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: XCTUnwrap(storage.data(forKey: Settings.schemaVersionKey))), 3)
    }

    func testStoredResultsColumnsAreMigrated() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage)
        s.resultsColumns = [ColumnSetting(id: .path, width: 300, visible: true), ColumnSetting(id: .path, width: 10, visible: false)]
        let r = Settings(storage: storage)
        XCTAssertEqual(r.resultsColumns.first, ColumnSetting(id: .path, width: 300, visible: true))
        XCTAssertEqual(r.resultsColumns.filter(\.visible).map(\.id), [.path])
        XCTAssertEqual(r.resultsColumns.count, ColumnID.allCases.count)
    }

    func testNewKeysPersist() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage)
        s.previewPaneVisible = true
        s.previewPaneWidth = 410
        s.searchScope = .subfolders
        s.searchMode = .contents
        s.searchIncludesPackages = true
        s.collapsedSections.insert(.searches)
        let spec = SearchSpec(text: "tax kind:pdf", scope: .subfolders, filters: SearchFilters(modified: .relative(.thisYear)), root: root)
        let saved = s.addSavedSearch(name: "Taxes", spec: spec)
        let r = Settings(storage: storage)
        XCTAssertTrue(r.previewPaneVisible)
        XCTAssertEqual(r.previewPaneWidth, 410)
        XCTAssertEqual(r.searchScope, .subfolders)
        XCTAssertEqual(r.searchMode, .contents)
        XCTAssertTrue(r.searchIncludesPackages)
        XCTAssertTrue(r.collapsedSections.contains(.searches))
        XCTAssertEqual(r.savedSearches, [saved])
        XCTAssertEqual(r.savedSearches.first?.spec, spec)
    }

    func testSavedSearchMutators() {
        let s = Settings(storage: InMemorySettingsStorage())
        let spec = SearchSpec(text: "tax", scope: .subfolders, root: root)
        let a = s.addSavedSearch(name: "Tax", spec: spec)
        let b = s.addSavedSearch(name: " tax ", spec: spec)
        let c = s.addSavedSearch(name: "  ", spec: SearchSpec(text: "invoices", scope: .thisMac, root: root))
        XCTAssertEqual([a, b, c].map(\.name), ["Tax", "tax 2", "invoices"])
        XCTAssertTrue(s.renameSavedSearch(c.id, to: "Tax"))
        XCTAssertEqual(s.savedSearches.map(\.name), ["Tax", "tax 2", "Tax 3"])
        XCTAssertFalse(s.renameSavedSearch(c.id, to: "   "))
        XCTAssertFalse(s.renameSavedSearch(UUID(), to: "x"))
        XCTAssertTrue(s.renameSavedSearch(a.id, to: "TAX"))                 // case-only rename of itself is fine
        XCTAssertEqual(s.savedSearches[0].name, "TAX")
        s.moveSavedSearch(from: 0, to: 2)
        XCTAssertEqual(s.savedSearches.map(\.id), [b.id, c.id, a.id])
        s.moveSavedSearch(from: 2, to: 0)
        XCTAssertEqual(s.savedSearches.map(\.id), [a.id, b.id, c.id])
        s.moveSavedSearch(from: 0, to: 99)                                  // clamped to the end
        XCTAssertEqual(s.savedSearches.map(\.id), [b.id, c.id, a.id])
        s.moveSavedSearch(from: 7, to: 0)                                   // unknown index: no change
        XCTAssertEqual(s.savedSearches.map(\.id), [b.id, c.id, a.id])
        s.removeSavedSearch(c.id)
        XCTAssertEqual(s.savedSearches.map(\.id), [b.id, a.id])
    }

    func testAddSavedSearchFallsBackToTheFolderName() {
        let s = Settings(storage: InMemorySettingsStorage())
        let saved = s.addSavedSearch(name: "", spec: SearchSpec(text: "  ", scope: .subfolders, filters: SearchFilters(kinds: [.pdf]), root: root))
        XCTAssertEqual(saved.name, "root")
    }

    func testMutatorsPersist() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage)
        let a = s.addSavedSearch(name: "A", spec: SearchSpec(text: "a", scope: .subfolders, root: root))
        let b = s.addSavedSearch(name: "B", spec: SearchSpec(text: "b", scope: .subfolders, root: root))
        XCTAssertTrue(s.renameSavedSearch(a.id, to: "Alpha"))
        s.moveSavedSearch(from: 1, to: 0)
        XCTAssertEqual(Settings(storage: storage).savedSearches.map(\.name), ["B", "Alpha"])
        s.removeSavedSearch(b.id)
        XCTAssertEqual(Settings(storage: storage).savedSearches.map(\.id), [a.id])
    }

    func testUniqueName() {
        XCTAssertNil(SavedSearchNaming.uniqueName(" \n ", existing: []))
        XCTAssertEqual(SavedSearchNaming.uniqueName(" Photos ", existing: ["Docs"]), "Photos")
        XCTAssertEqual(SavedSearchNaming.uniqueName("photos", existing: ["Photos", "photos 2"]), "photos 3")
    }

    func testCrawlerHonoursIncludePackagesSetting() async throws {
        let sandbox = try Sandbox()
        addTeardownBlock { sandbox.destroy() }
        try sandbox.createFile("X.app/Contents/needle.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        let spec = SearchSpec(text: "needle", scope: .subfolders, root: sandbox.root)
        func count() async throws -> Int {
            let plan = await env.planSearch(spec)
            let m = env.makeSearchResults(spec, plan: plan)
            defer { m.close() }
            m.start()
            let end = ContinuousClock.now + .seconds(30)   // generous for a loaded runner; the crawl has no time budget
            while ContinuousClock.now < end { if case .complete = m.state { break }; try await Task.sleep(for: .milliseconds(10)) }
            guard case .complete = m.state else { XCTFail("crawl did not complete"); return -1 }
            return m.rowCount
        }
        let skipped = try await count()
        XCTAssertEqual(skipped, 0, "packages are skipped by default")
        env.settings.searchIncludesPackages = true
        let included = try await count()
        XCTAssertEqual(included, 1)
    }
}
