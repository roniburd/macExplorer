import XCTest
@testable import macx_bench

final class BaselineCompareTests: XCTestCase {
    private func base(_ name: String, _ size: Int, _ median: Double) -> BaselineMetric {
        BaselineMetric(name: name, size: size, median: median, unit: "ms")
    }

    func testFailsOnlyWhenBothRelativeAndAbsoluteThresholdsAreExceeded() {
        XCTAssertTrue(BaselineCompare.isRegression(baseline: 100, current: 121, unit: "ms"))
        XCTAssertFalse(BaselineCompare.isRegression(baseline: 100, current: 119, unit: "ms"))   // < 20 %
        XCTAssertFalse(BaselineCompare.isRegression(baseline: 10, current: 14, unit: "ms"))     // 40 % but only 4 ms
        XCTAssertTrue(BaselineCompare.isRegression(baseline: 10, current: 15.5, unit: "ms"))
        XCTAssertFalse(BaselineCompare.isRegression(baseline: 5, current: 6.5, unit: "MB"))     // MB uses a 2 MB floor
    }

    func testNewAndMissingMetricsNeverFail() {
        let comparisons = BaselineCompare.compare(
            current: [MetricResult(name: "sort", size: 1_000, samples: [5]), MetricResult(name: "diff", size: 1_000, samples: [9])],
            baseline: [base("sort", 1_000, 5), base("gone", 1_000, 1)])
        let byKey = Dictionary(uniqueKeysWithValues: comparisons.map { ($0.key, $0.status) })
        XCTAssertEqual(byKey, ["sort@1000": .ok, "diff@1000": .new, "gone@1000": .missing])
    }

    func testRegressionAndImprovementAreClassified() {
        let comparisons = BaselineCompare.compare(
            current: [MetricResult(name: "a", size: 1, samples: [200]), MetricResult(name: "b", size: 1, samples: [50])],
            baseline: [base("a", 1, 100), base("b", 1, 100)])
        XCTAssertEqual(comparisons.map(\.status), [.regressed, .improved])
        XCTAssertTrue(BaselineCompare.render(comparisons).contains("REGRESSED a@1"))
    }

    func testLenientDecodingOfOlderBaselines() throws {
        let json = #"{"metrics":[{"name":"sort","size":100000,"median":12.5},{"name":"sort","size":100000,"median":99}],"extra":true}"#
        let metrics = try BaselineCompare.decodeBaseline(Data(json.utf8))
        XCTAssertEqual(metrics.count, 2)
        let comparisons = BaselineCompare.compare(current: [MetricResult(name: "sort", size: 100_000, samples: [12])], baseline: metrics)
        XCTAssertEqual(comparisons.first?.status, .ok)   // duplicate keys: first wins, never traps
    }

    func testOwnReportFormatIsAValidBaseline() throws {
        let report = BenchReport(
            machine: MachineInfo(cpu: "test", appleSilicon: true, os: "26", cores: 12),
            configuration: "release", warmups: 1, iterations: 5,
            metrics: [MetricResult(name: "sort", size: 10, samples: [1, 2, 3])],
            budgets: nil, sandbox: "/tmp/macx-bench-x", sandboxRemoved: true)
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try BaselineCompare.decodeBaseline(data).first?.median, 2)
    }
}
