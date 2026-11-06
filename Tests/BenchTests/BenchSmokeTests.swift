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
        XCTAssertEqual(Set(report.metrics.map(\.name)), expected)
        XCTAssertTrue(report.metrics.allSatisfy { $0.samples.count == 1 })
        XCTAssertTrue(report.metrics.allSatisfy { $0.size == ($0.name.hasPrefix("folderViews.") ? FolderViewStore.capacity : 300) })
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
}
