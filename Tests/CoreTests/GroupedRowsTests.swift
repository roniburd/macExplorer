import XCTest
@testable import Core
import MacxFS

final class GroupedRowsTests: XCTestCase {
    let runs = [GroupRun(key: .date(.today), rows: 0..<2), GroupRun(key: .date(.yesterday), rows: 2..<3), GroupRun(key: .date(.longAgo), rows: 3..<6)]

    func testExpandedMapping() {
        let g = GroupedRows(runs: runs, collapsed: [])
        XCTAssertEqual(g.tableRowCount, 9)
        XCTAssertEqual((0..<9).map(g.row), [.header(0), .item(0), .item(1), .header(1), .item(2), .header(2), .item(3), .item(4), .item(5)])
        XCTAssertEqual(g.tableRow(forModelRow: 4), 7)
        XCTAssertEqual(g.group(containingModelRow: 2), 1)
        XCTAssertNil(g.group(containingModelRow: 6))
        XCTAssertEqual(g.modelRows(forTableRows: IndexSet([0, 1, 3, 4, 8])), IndexSet([0, 2, 5]))
        XCTAssertEqual(g.tableRows(forModelRows: IndexSet([0, 5])), IndexSet([1, 8]))
    }

    func testCollapsedGroupHidesItsRows() {
        let g = GroupedRows(runs: runs, collapsed: [.date(.today)])
        XCTAssertEqual(g.tableRowCount, 7)
        XCTAssertEqual((0..<7).map(g.row), [.header(0), .header(1), .item(2), .header(2), .item(3), .item(4), .item(5)])
        XCTAssertNil(g.tableRow(forModelRow: 1))
        XCTAssertEqual(g.tableRows(forModelRows: IndexSet([0, 1, 2])), IndexSet([2]))
        XCTAssertEqual(g.tableRow(forGroup: 2), 3)
    }

    func testEmptyRuns() {
        let g = GroupedRows(runs: [], collapsed: [])
        XCTAssertEqual(g.tableRowCount, 0)
        XCTAssertNil(g.tableRow(forModelRow: 0))
        XCTAssertEqual(g.modelRows(forTableRows: IndexSet([0, 1])), IndexSet())
    }
}
