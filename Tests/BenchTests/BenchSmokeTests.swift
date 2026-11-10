import XCTest
import MacxFS
import Core
@testable import macx_bench

@MainActor
final class BenchSmokeTests: XCTestCase {
    func testSmallRunProducesEveryMetricAndRemovesItsSandbox() async throws {
        let report = try await Bench.run(BenchOptions(sizes: [300], warmups: 0, iterations: 1))
        var expected: Set<String> = ["enumerate", "firstBatch", "listSorted", "listSorted.busyMain", "sortkeys", "sort", "filter", "modelResort",
                                     "diff", "memory.steady", "pasteboard", "fsevent.incremental", "fsevent.full",
                                     "folderViews.load", "folderViews.flush", "folderViews.save"]
        for field in SortField.entryFields { expected.insert("resort.\(field.rawValue)") }
        expected.formUnion(["resort.tags", "resort.comments"])     // P2-16 review fix: extended columns, distinct values
        expected.formUnion(["memory.extendedSort.tags", "memory.extendedSort.owner"])   // P2-16 review fix: §4.4 memory
        for g in GroupBy.allCases where g != .none { expected.insert("resort.grouped.\(g.rawValue)") }   // P2-20
        expected.insert("resort.grouped.nameFirstLetter.nonASCII")                           // P2-09 review
        expected.formUnion(["folderSize.scan", "extattrs.read"])                            // P2-20, reported only
        expected.formUnion(Self.searchMetrics.keys)                                          // P3-13
        expected.insert("palette.rank")                                                      // P4-03 review fix
        XCTAssertEqual(Set(report.metrics.map(\.name)), expected)
        XCTAssertTrue(report.metrics.allSatisfy { $0.samples.count == 1 })
        let fixedSizes = ["folderSize.scan": 10_000, "extattrs.read": 2_000, "palette.rank": PaletteBench.items().count]
            .merging(Self.searchMetrics) { a, _ in a }
        XCTAssertTrue(report.metrics.allSatisfy {
            $0.size == ($0.name.hasPrefix("folderViews.") ? FolderViewStore.capacity : fixedSizes[$0.name] ?? 300)
        })
        for metric in report.metrics where metric.unit == "ms" {
            XCTAssertGreaterThan(metric.median, 0, metric.key)
        }
        XCTAssertTrue(URL(filePath: report.sandbox).lastPathComponent.hasPrefix("macx-bench-"))
        XCTAssertTrue(report.sandboxRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.sandbox))
    }

    /// P3-13: the search metrics and their fixed sizes (100k store, 10k queries, the 11,700-file crawl tree).
    static let searchMetrics = ["search-filter-100k": 100_000, "search-parse-10k": 10_000, "search-crawl-first-result": 11_700,
                                "search-crawl-complete": 11_700, "search-results-ingest-100k": 100_000]

    /// P3-13: `--metrics search-` runs exactly the five search metrics (and no folder-size metric).
    func testSearchMetricsRunOnTheirOwn() async throws {
        let report = try await Bench.run(BenchOptions(sizes: [50], warmups: 0, iterations: 1, metrics: ["search-"]))
        XCTAssertEqual(Set(report.metrics.map(\.name)), Set(Self.searchMetrics.keys))
        for metric in report.metrics { XCTAssertEqual(metric.size, Self.searchMetrics[metric.name], metric.name) }
        XCTAssertTrue(report.sandboxRemoved)
        let crawl = try await Bench.run(BenchOptions(sizes: [50], warmups: 0, iterations: 1, metrics: ["search-crawl-complete"]))
        XCTAssertEqual(crawl.metrics.map(\.name), ["search-crawl-complete"])
    }

    func testMetricFilterRunsOnlyRequestedFamilies() async throws {
        let report = try await Bench.run(BenchOptions(sizes: [50], warmups: 0, iterations: 1, metrics: ["sort", "resort"]))
        XCTAssertFalse(report.metrics.isEmpty)
        XCTAssertTrue(report.metrics.allSatisfy { $0.name.hasPrefix("sort") || $0.name.hasPrefix("resort") })
    }

    /// P2-20: each Phase 2 family runs on its own when filtered; the grouped re-sort needs the store without "resort".
    func testPhase2FamiliesRunOnTheirOwn() async throws {
        let report = try await Bench.run(BenchOptions(sizes: [50], warmups: 0, iterations: 1,
                                                      metrics: ["resort.grouped", "folderSize", "extattrs"]))
        var expected: Set<String> = ["folderSize.scan", "extattrs.read", "resort.grouped.nameFirstLetter.nonASCII"]
        for g in GroupBy.allCases where g != .none { expected.insert("resort.grouped.\(g.rawValue)") }
        XCTAssertEqual(Set(report.metrics.map(\.name)), expected)
        XCTAssertTrue(report.sandboxRemoved)
    }
}
