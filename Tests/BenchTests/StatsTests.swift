import XCTest
@testable import macx_bench

final class StatsTests: XCTestCase {
    func testMedianOddAndEven() {
        XCTAssertEqual(Stats.median([3, 1, 2]), 2)
        XCTAssertEqual(Stats.median([4, 1, 3, 2]), 2.5)
    }

    func testP90IsNearestRank() {
        XCTAssertEqual(Stats.percentile([5, 1, 4, 2, 3], 0.9), 5)
        XCTAssertEqual(Stats.percentile((1...10).map(Double.init), 0.9), 9)
        XCTAssertEqual(Stats.percentile([7], 0.9), 7)
    }

    @MainActor
    func testSampleRunsWarmupsThenReturnsOnlyMeasuredIterations() async {
        var calls = 0
        let samples = await Stats.sample(warmups: 1, iterations: 5) {
            calls += 1
            return Double(calls)
        }
        XCTAssertEqual(calls, 6)
        XCTAssertEqual(samples, [2, 3, 4, 5, 6])
    }

    func testMillisecondsConversion() {
        XCTAssertEqual(Stats.milliseconds(.milliseconds(1500)), 1500, accuracy: 1e-9)
        XCTAssertEqual(Stats.milliseconds(.microseconds(250)), 0.25, accuracy: 1e-9)
    }

    func testMetricResultComputesMedianAndP90() {
        let m = MetricResult(name: "sort", size: 10, samples: [10, 30, 20, 50, 40])
        XCTAssertEqual(m.median, 30)
        XCTAssertEqual(m.p90, 50)
        XCTAssertEqual(m.key, "sort@10")
        XCTAssertEqual(m.unit, "ms")
    }
}
