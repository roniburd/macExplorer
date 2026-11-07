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

    /// Review fix (P2-16): extended columns with distinct values are held to the same re-sort budget.
    func testExtendedResortMetricsHaveA30msBudgetAt100k() {
        for name in ["resort.tags", "resort.comments"] {
            let budget = Budgets.table.first { $0.metric == name }
            XCTAssertEqual(budget?.limit, 30, name)
            XCTAssertEqual(budget?.sizes, [100_000], name)
        }
    }

    /// Review fix (P2-16, §4.4 memory): sorting a 100k folder by Tags or Owner has a memory budget.
    func testExtendedSortMemoryHasAn8MBBudgetAt100k() {
        for name in ["memory.extendedSort.tags", "memory.extendedSort.owner"] {
            let budget = Budgets.table.first { $0.metric == name }
            XCTAssertEqual(budget?.limit, 8, name)
            XCTAssertEqual(budget?.unit, "MB", name)
            XCTAssertEqual(budget?.sizes, [100_000], name)
        }
        let checks = Budgets.evaluate([MetricResult(name: "memory.extendedSort.owner", size: 100_000, unit: "MB", samples: [42])])
        XCTAssertEqual(checks.first?.passed, false)
    }

    /// P2-20: re-sorting 100k with Group by on includes the partition, under the same 30 ms budget (§4.4).
    func testGroupedResortHasA30msBudgetAt100kForEveryGroupBy() {
        for g in GroupBy.allCases where g != .none {
            let budget = Budgets.table.first { $0.metric == "resort.grouped.\(g.rawValue)" }
            XCTAssertEqual(budget?.limit, 30, g.rawValue)
            XCTAssertEqual(budget?.unit, "ms", g.rawValue)
            XCTAssertEqual(budget?.sizes, [100_000], g.rawValue)
        }
        let checks = Budgets.evaluate([MetricResult(name: "resort.grouped.kind", size: 100_000, samples: [31])])
        XCTAssertEqual(checks.map(\.passed), [false])
    }

    /// P2-20: the folder-size scan and extended-attribute read are reported, not gated.
    func testFolderSizeScanAndExtattrsAreReportedWithoutABudget() {
        let checks = Budgets.evaluate([MetricResult(name: "folderSize.scan", size: 10_000, samples: [900]),
                                       MetricResult(name: "extattrs.read", size: 2_000, samples: [900])])
        XCTAssertTrue(checks.isEmpty)
    }

    /// P3-13: the This folder search filter is gated at 30 ms for 100k; the other search metrics are reported only.
    func testSearchFilterBudget() {
        let checks = Budgets.evaluate([MetricResult(name: "search-filter-100k", size: 100_000, samples: [31]),
                                       MetricResult(name: "search-parse-10k", size: 10_000, samples: [900]),
                                       MetricResult(name: "search-crawl-complete", size: 11_700, samples: [900]),
                                       MetricResult(name: "search-results-ingest-100k", size: 100_000, samples: [900])])
        XCTAssertEqual(checks.map(\.metric), ["search-filter-100k"])
        XCTAssertEqual(checks.map(\.passed), [false])
        XCTAssertEqual(checks.first?.limit, 30)
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
