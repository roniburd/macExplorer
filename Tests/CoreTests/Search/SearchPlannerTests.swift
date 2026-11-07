// Tests/CoreTests/Search/SearchPlannerTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class SearchPlannerTests: XCTestCase {
    let root = URL(filePath: "/tmp/macx-tests-plan/root", directoryHint: .isDirectory)
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func plan(_ text: String, _ scope: SearchScope, _ mode: SearchMode = .name, root rootIdx: IndexingStatus = .enabled,
              boot: IndexingStatus = .enabled, local: Bool = true, filters: SearchFilters = SearchFilters()) -> SearchPlan {
        let spec = SearchSpec(text: text, scope: scope, mode: mode, filters: filters, root: root)
        return SearchPlanner.plan(spec, resolved: SearchResolver.resolve(spec, now: now, calendar: cal),
                                  inputs: PlanInputs(rootIndexing: rootIdx, bootIndexing: boot, rootIsLocal: local, rootVolumeName: "Data"))
    }
    let tax = SearchCriteria(nameTerms: [NameTerm("tax")])

    func testThisFolder() {
        XCTAssertEqual(plan("tax", .thisFolder).engine, .folderFilter(tax))
        XCTAssertEqual(plan("tax", .thisFolder, .contents).engine,
                       .spotlight(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["tax"], scope: .folders([root]), directChildrenOf: root)))
        let fallback = plan("tax", .thisFolder, .contents, root: .disabled)
        XCTAssertEqual(fallback.engine, .folderFilter(tax))
        XCTAssertEqual(fallback.notices, [.contentsNotIndexed(volumeName: "Data")])
    }

    func testSubfolders() {
        XCTAssertEqual(plan("tax", .subfolders).engine, .crawler(root: root, criteria: tax))
        XCTAssertEqual(plan("tax", .subfolders, .contents).engine,
                       .spotlight(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["tax"], scope: .folders([root]), within: root)))
        let fallback = plan("tax", .subfolders, .contents, root: .disabled)
        XCTAssertEqual(fallback.engine, .crawler(root: root, criteria: tax))
        XCTAssertEqual(fallback.notices, [.contentsNotIndexed(volumeName: "Data")])
        XCTAssertEqual(plan("tax", .subfolders, .contents, root: .unknown, local: true).engine,
                       .spotlight(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["tax"], scope: .folders([root]), within: root)))
        XCTAssertEqual(plan("tax", .subfolders, .contents, root: .unknown, local: false).engine, .crawler(root: root, criteria: tax))
        // Contents mode with only filters uses the name engines.
        XCTAssertEqual(plan("kind:pdf", .subfolders, .contents, root: .disabled).engine,
                       .crawler(root: root, criteria: SearchCriteria(kinds: [.pdf])))
    }

    func testThisMac() {
        XCTAssertEqual(plan("tax", .thisMac).engine, .spotlight(SpotlightRequest(criteria: tax, contentTerms: [], scope: .localComputer)))
        XCTAssertEqual(plan("tax", .thisMac, .contents).engine,
                       .spotlight(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["tax"], scope: .localComputer)))
        let off = plan("tax", .thisMac, boot: .disabled)
        XCTAssertEqual(off.engine, .none)
        XCTAssertEqual(off.notices, [.spotlightOff])
    }

    func testEmptyAndDiagnostics() {
        XCTAssertEqual(plan("   ", .subfolders).engine, .none)
        let p = plan("size:big", .subfolders)
        XCTAssertEqual(p.engine, .none)
        XCTAssertEqual(p.diagnostics, [SyntaxDiagnostic(token: "size:big", problem: .badSize)])
        XCTAssertEqual(plan("tax size:big", .subfolders).diagnostics.count, 1)
    }

    func testNeedsIndexStatus() {
        XCTAssertFalse(SearchPlanner.needsIndexStatus(SearchSpec(text: "a", scope: .subfolders, root: root)))
        XCTAssertTrue(SearchPlanner.needsIndexStatus(SearchSpec(text: "a", scope: .subfolders, mode: .contents, root: root)))
        XCTAssertTrue(SearchPlanner.needsIndexStatus(SearchSpec(text: "a", scope: .thisMac, root: root)))
        XCTAssertFalse(SearchPlanner.needsIndexStatus(SearchSpec(text: "", scope: .thisMac, root: root)))
    }

    func testCrawlPermissionsFromTCCOutcomes() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let p = CrawlPermissions.make(home: home) { $0 == .documents ? .granted : nil }
        XCTAssertTrue(p.isBlocked("/Users/someone/Desktop/a"))
        XCTAssertFalse(p.isBlocked("/Users/someone/Documents/a"))
        XCTAssertTrue(p.isBlocked("/Users/someone/Library/Mobile Documents/x"))
        XCTAssertTrue(p.isBlocked("/Users/someone/Library/Containers/com.x/Data"))
        XCTAssertFalse(p.isBlocked("/Users/someone/dev/project"))
    }
}
