import XCTest
@testable import macx_scenarios

final class CatalogTests: XCTestCase {
    func testNamesAreUniqueAndWellFormed() {
        let names = Catalog.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate scenario names")
        for name in names {
            XCTAssertNotNil(name.range(of: #"^[a-z]+\.[A-Za-z0-9]+$"#, options: .regularExpression), name)
        }
        XCTAssertGreaterThanOrEqual(names.count, 45)
    }

    func testEveryFamilyIsPresent() {
        let families = Set(Catalog.all.map { String($0.name.split(separator: ".")[0]) })
        XCTAssertEqual(families, ["browse", "ops", "conflict", "clip", "undo", "watch", "xvol", "crash", "search",
                                  "archive", "batch", "acl", "icon", "keymap"])     // P4-23 (no tags, helper, network, dual pane)
    }

    func testEveryJobKindIsExercised() {
        for needle in ["copy", "move", "trash", "delete", "duplicate", "newItems", "rename", "alias", "symlink", "chmod", "setAttributes",
                       "compress", "extract", "batch", "acl", "customIcon", "keymap"] {
            XCTAssertTrue(Catalog.all.contains { $0.name.lowercased().contains(needle.lowercased()) }, needle)
        }
    }

    /// P3-13: the search family covers the crawler rules, filters, Stop, file operations and saved searches.
    func testSearchFamilyIsComplete() {
        let names = Set(Catalog.select("search.").map(\.name))
        XCTAssertEqual(names, ["search.crawlFindsNested", "search.crawlSkipsPackagesAndHidden", "search.crawlSymlinkLoopTerminates",
                               "search.crawlUnreadableContinues", "search.syntaxAndFilters", "search.cancelStopsCrawl",
                               "search.resultsFollowFileOps", "search.savedSearchRoundTrip", "search.crawlDoesNotCrossImage"])
    }

    /// P4-23: the Phase 4 scenarios (Review Focus 1, 2 and 4 end to end; ACL, custom icon and keymap round trips).
    func testPhase4FamiliesAreComplete() {
        let names = Set(Catalog.all.map(\.name).filter { ["archive.", "batch.", "acl.", "icon.", "keymap."].contains(where: $0.hasPrefix) })
        XCTAssertEqual(names, ["archive.compressExtractRoundTrip", "archive.appleArchiveNextFreeName", "archive.unsafeRefused",
                               "archive.linkChainRefused", "batch.renameSameNameInTwoFolders", "keymap.resetFollowsThePreset",
                               "batch.renameCycleAndUndo", "batch.renameSwapAndChain", "batch.renameCrashRecovery",
                               "acl.editUndo", "icon.setCustomIconUndo", "keymap.importRejectsConflicts", "keymap.exportImportRoundTrip"])
        XCTAssertFalse(Catalog.all.contains { $0.name.lowercased().contains("tag") }, "Phase 4 tags were removed (owner decision)")
    }

    func testFilterSelectsBySubstring() {
        XCTAssertEqual(Catalog.select(nil).count, Catalog.all.count)
        XCTAssertFalse(Catalog.select("clip.").isEmpty)
        XCTAssertTrue(Catalog.select("clip.").allSatisfy { $0.name.hasPrefix("clip.") })
        XCTAssertTrue(Catalog.select("no-such-scenario").isEmpty)
    }

    func testRequirementsAreDeclared() {
        for s in Catalog.all where s.name.hasPrefix("xvol.") { XCTAssertEqual(s.requires, .diskImages, s.name) }
        for s in Catalog.all where s.name.hasPrefix("crash.") { XCTAssertEqual(s.requires, .helperProcess, s.name) }
        XCTAssertEqual(Catalog.all.first { $0.name == "batch.renameCrashRecovery" }?.requires, .helperProcess)
        XCTAssertEqual(Catalog.all.first { $0.name == "search.crawlDoesNotCrossImage" }?.requires, .diskImages)
    }
}
