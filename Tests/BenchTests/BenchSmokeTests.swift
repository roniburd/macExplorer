import XCTest
import MacxFS
@testable import macx_bench

@MainActor
final class BenchSmokeTests: XCTestCase {
    func testSmallRunProducesEveryMetricAndRemovesItsSandbox() async throws {
        let report = try await Bench.run(BenchOptions(sizes: [300], warmups: 0, iterations: 1))
        var expected: Set<String> = ["enumerate", "firstBatch", "listSorted", "listSorted.busyMain", "sortkeys", "sort", "filter", "modelResort",
                                     "diff", "memory.steady", "pasteboard", "fsevent.incremental", "fsevent.full"]
        for field in SortField.allCases { expected.insert("resort.\(field.rawValue)") }
        XCTAssertEqual(Set(report.metrics.map(\.name)), expected)
        XCTAssertTrue(report.metrics.allSatisfy { $0.size == 300 && $0.samples.count == 1 })
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
