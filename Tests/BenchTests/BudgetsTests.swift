import XCTest
import MacxFS
@testable import macx_bench

final class BudgetsTests: XCTestCase {
    func testOnlyListedSizesAreChecked() {
        let checks = Budgets.evaluate([
            MetricResult(name: "listSorted", size: 1_000, samples: [900]),
            MetricResult(name: "listSorted", size: 100_000, samples: [260]),
        ])
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.size, 100_000)
        XCTAssertEqual(checks.first?.passed, false)
    }

    func testFirstBatchAppliesToEverySize() {
        let checks = Budgets.evaluate([1_000, 10_000, 100_000].map { MetricResult(name: "firstBatch", size: $0, samples: [20]) })
        XCTAssertEqual(checks.map(\.passed), [true, true, true])
    }

    func testEveryResortFieldHasA30msBudgetAt100k() {
        for field in SortField.entryFields {
            let budget = Budgets.table.first { $0.metric == "resort.\(field.rawValue)" }
            XCTAssertEqual(budget?.limit, 30, field.rawValue)
            XCTAssertEqual(budget?.sizes, [100_000], field.rawValue)
        }
    }

    func testMemoryBudgetUsesMegabytes() {
        let checks = Budgets.evaluate([MetricResult(name: "memory.steady", size: 100_000, unit: "MB", samples: [25])])
        XCTAssertEqual(checks.first?.passed, false)
        XCTAssertEqual(checks.first?.unit, "MB")
    }

    func testAnnotationsOnlyForFailures() {
        let checks = Budgets.evaluate([
            MetricResult(name: "pasteboard", size: 100_000, samples: [1_600]),
            MetricResult(name: "firstBatch", size: 1_000, samples: [5]),
        ])
        let lines = Budgets.annotations(checks)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("::warning title=Performance budget::pasteboard @ 100000"), lines[0])
    }

    /// Overview §4.4 pasteboard decision (2026-11-03): ≤10k < 300 ms, 100k < 1.5 s.
    func testPasteboardBudgetsFollowThe2026_11_03Decision() {
        let checks = Budgets.evaluate([
            MetricResult(name: "pasteboard", size: 10_000, samples: [310]),
            MetricResult(name: "pasteboard", size: 100_000, samples: [1_400]),
        ])
        XCTAssertEqual(checks.map(\.limit), [300, 1_500])
        XCTAssertEqual(checks.map(\.passed), [false, true])
    }

    func testBudgetTableCoversEveryHeadlessSpecRow() {
        let names = Set(Budgets.table.map(\.metric))
        for name in ["firstBatch", "listSorted", "modelResort", "fsevent.incremental", "fsevent.full", "memory.steady", "pasteboard",
                     "folderViews.load", "folderViews.flush", "folderViews.save"] {
            XCTAssertTrue(names.contains(name), name)
        }
    }
}
