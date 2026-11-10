import XCTest
@testable import Core

/// P4-03: palette items, ranking, the MRU boost and the stored recents (`Settings.paletteRecent`).
@MainActor
final class PaletteCatalogTests: XCTestCase {
    private func item(_ c: Command, _ t: String) -> PaletteItem { PaletteItem(target: .command(c), title: t, subtitle: nil) }

    func testRankingOrderAndTieBreak() {
        let items = [item(.copy, "Copy"), item(.copyAsPath, "Copy as Path"), item(.compressZip, "Compress to .zip")]
        XCTAssertEqual(PaletteCatalog.rank(items, query: "cp", recent: []).map(\.item.title), ["Copy as Path", "Copy", "Compress to .zip"])
        // Equal scores: the shorter title first, then by title.
        let tied = [item(.sortByName, "Sort Bb"), item(.sortBySize, "Sort Ba"), item(.sortByKind, "Sort B")]
        XCTAssertEqual(PaletteCatalog.rank(tied, query: "sort", recent: []).map(\.item.title), ["Sort B", "Sort Ba", "Sort Bb"])
    }

    func testMRUBoostAndEmptyQuery() {
        let items = [item(.copy, "Copy"), item(.copyAsPath, "Copy as Path"), item(.refresh, "Refresh")]
        XCTAssertEqual(PaletteCatalog.rank(items, query: "", recent: [.command(.refresh)]).map(\.item.title), ["Refresh", "Copy", "Copy as Path"])
        XCTAssertEqual(PaletteCatalog.rank(items, query: "cp", recent: [.command(.copy)]).first?.item.title, "Copy")   // 21 + 30 > 25
        XCTAssertEqual(PaletteCatalog.rank(items, query: "  ", recent: []).map(\.match.score), [0, 0, 0])
        // Only the ten most recent get a boost.
        let old: [PaletteTarget] = Array(repeating: .command(.newFolder), count: 10) + [.command(.copy)]
        XCTAssertEqual(PaletteCatalog.rank(items, query: "cp", recent: old).first?.item.title, "Copy as Path")
    }

    func testLocationsIncluded() {
        let loc = PaletteItem(target: .location(URL(filePath: "/tmp/macx-x/Projects")), title: "Go to Projects", subtitle: "/tmp/macx-x/Projects")
        XCTAssertEqual(PaletteCatalog.rank([loc, item(.properties, "Properties")], query: "proj", recent: []).map(\.item.title), ["Go to Projects"])
    }

    func testTargetEncodingRoundTrips() {
        let targets: [PaletteTarget] = [.command(.newFolder), .location(URL(filePath: "/tmp/macx-x/A b", directoryHint: .isDirectory))]
        XCTAssertEqual(targets.map(\.encoded), ["cmd:newFolder", "loc:/tmp/macx-x/A b"])
        for t in targets { XCTAssertEqual(PaletteTarget(encoded: t.encoded)?.encoded, t.encoded) }
        XCTAssertNil(PaletteTarget(encoded: "cmd:noSuchCommand"))
        XCTAssertNil(PaletteTarget(encoded: "loc:"))
        XCTAssertNil(PaletteTarget(encoded: "garbage"))
    }

    func testNotePaletteUsedKeepsTwentyMostRecentFirstAndPersists() {
        let storage = InMemorySettingsStorage()
        let home = URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory)
        let s = Settings(storage: storage, home: home)
        XCTAssertEqual(s.paletteRecent, [])
        s.notePaletteUsed(.command(.copy))
        s.notePaletteUsed(.location(URL(filePath: "/tmp/macx-x/P")))
        s.notePaletteUsed(.command(.copy))
        XCTAssertEqual(s.paletteRecent, ["cmd:copy", "loc:/tmp/macx-x/P"])
        for c in Command.allCases.prefix(30) { s.notePaletteUsed(.command(c)) }
        XCTAssertEqual(s.paletteRecent.count, Settings.paletteRecentLimit)
        XCTAssertEqual(s.paletteRecent.first, "cmd:\(Command.allCases[29].rawValue)")
        XCTAssertEqual(Settings(storage: storage, home: home).paletteRecent, s.paletteRecent)
        XCTAssertEqual(s.paletteRecentTargets.count, 20)
    }

    /// Every command plus forty locations ranks for typical queries; the < 2 ms budget is macx-bench's
    /// `palette.rank` (unit tests carry no wall-clock budgets on a loaded runner).
    func testRankingEveryCommandPlusFortyLocations() {
        var items = Command.allCases.map { item($0, "\($0.rawValue) command title") }
        for i in 0..<40 {
            let url = URL(filePath: "/tmp/macx-x/Folder \(i)")
            items.append(PaletteItem(target: .location(url), title: "Go to Folder \(i)", subtitle: url.path))
        }
        let recent = items.prefix(20).map(\.target)
        for query in ["n", "nf", "go fo", "sort by name"] {
            let ranked = PaletteCatalog.rank(items, query: query, recent: recent)
            XCTAssertFalse(ranked.isEmpty, query)
            XCTAssertTrue(zip(ranked, ranked.dropFirst()).allSatisfy { $0.match.score >= $1.match.score }, query)
        }
        let folders = PaletteCatalog.rank(items, query: "go fo", recent: recent).filter { $0.item.title.hasPrefix("Go to Folder") }
        XCTAssertEqual(folders.count, 40, "every Go to Folder")
    }
}

extension PaletteCatalogTests {
    func testFolderTargetsAreEqualWithOrWithoutTrailingSlash() {
        let a = PaletteTarget.location(URL(filePath: "/tmp/macx-x/P", directoryHint: .isDirectory))
        let b = PaletteTarget.location(URL(filePath: "/tmp/macx-x/P", directoryHint: .notDirectory))
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        let items = [PaletteItem(target: b, title: "Go to P", subtitle: nil), item(.copy, "Copy")]
        XCTAssertEqual(PaletteCatalog.rank(items, query: "", recent: [a]).first?.item.target, b)
    }
}
