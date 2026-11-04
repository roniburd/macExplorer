import XCTest
@testable import macx_bench

final class BenchCLITests: XCTestCase {
    func testDefaults() throws {
        let o = try BenchOptions.parse([])
        XCTAssertEqual(o.sizes, [1_000, 10_000, 100_000])
        XCTAssertEqual(o.warmups, 1)
        XCTAssertEqual(o.iterations, 5)
        XCTAssertNil(o.metrics)
        XCTAssertFalse(o.checkBudgets)
    }

    func testParsesEveryOption() throws {
        let o = try BenchOptions.parse(["--sizes", "300,500", "--warmups", "0", "--iterations", "2", "--metrics", "sort,diff",
                                        "--output", "/tmp/macx-bench-out/b.json", "--compare", "/tmp/macx-bench-out/base.json",
                                        "--check-budgets", "--warn-budgets", "--allow-debug", "--keep-fixtures"])
        XCTAssertEqual(o.sizes, [300, 500])
        XCTAssertEqual(o.warmups, 0)
        XCTAssertEqual(o.iterations, 2)
        XCTAssertEqual(o.metrics, ["sort", "diff"])
        XCTAssertEqual(o.output?.path, "/tmp/macx-bench-out/b.json")
        XCTAssertEqual(o.compare?.lastPathComponent, "base.json")
        XCTAssertTrue(o.checkBudgets && o.warnBudgets && o.allowDebug && o.keepFixtures)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try BenchOptions.parse(["--sizes"])) { XCTAssertEqual($0 as? BenchError, .missingValue("--sizes")) }
        XCTAssertThrowsError(try BenchOptions.parse(["--sizes", "10,x"])) { XCTAssertEqual($0 as? BenchError, .badValue("--sizes", "10,x")) }
        XCTAssertThrowsError(try BenchOptions.parse(["--iterations", "0"])) { XCTAssertEqual($0 as? BenchError, .badValue("--iterations", "0")) }
        XCTAssertThrowsError(try BenchOptions.parse(["--frobnicate"])) { XCTAssertEqual($0 as? BenchError, .unknownOption("--frobnicate")) }
    }

    @MainActor
    func testUsageErrorExits64() async {
        let code = await BenchCLI.run(["--frobnicate"])
        XCTAssertEqual(code, 64)
    }

    #if DEBUG
    @MainActor
    func testCheckBudgetsRefusesDebugBuildsBeforeCreatingFixtures() async {
        let code = await BenchCLI.run(["--check-budgets", "--sizes", "10"])
        XCTAssertEqual(code, 3)
    }
    #endif
}
