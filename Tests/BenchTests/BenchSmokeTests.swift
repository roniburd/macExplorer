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
        expected.formUnion(["folderSize.scan", "extattrs.read"])                            // P2-20, reported only
        XCTAssertEqual(Set(report.metrics.map(\.name)), expected)
        XCTAssertTrue(report.metrics.allSatisfy { $0.samples.count == 1 })
        let fixedSizes = ["folderSize.scan": 10_000, "extattrs.read": 2_000]
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

    func testMetricFilterRunsOnlyRequestedFamilies() async throws {
        let report = try await Bench.run(BenchOptions(sizes: [50], warmups: 0, iterations: 1, metrics: ["sort", "resort"]))
        XCTAssertFalse(report.metrics.isEmpty)
        XCTAssertTrue(report.metrics.allSatisfy { $0.name.hasPrefix("sort") || $0.name.hasPrefix("resort") })
    }

    /// P2-20: each Phase 2 family runs on its own when filtered; the grouped re-sort needs the store without "resort".
    func testPhase2FamiliesRunOnTheirOwn() async throws {
        let report = try await Bench.run(BenchOptions(sizes: [50], warmups: 0, iterations: 1,
                                                      metrics: ["resort.grouped", "folderSize", "extattrs"]))
        var expected: Set<String> = ["folderSize.scan", "extattrs.read"]
        for g in GroupBy.allCases where g != .none { expected.insert("resort.grouped.\(g.rawValue)") }
        XCTAssertEqual(Set(report.metrics.map(\.name)), expected)
        XCTAssertTrue(report.sandboxRemoved)
    }
}
