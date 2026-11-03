import Core
import Foundation
import XCTest

final class ChangeSetTests: XCTestCase {
    func testResetRequiresReloadData() {
        XCTAssertEqual(ChangeSet.reset.changes, [.reset])
        XCTAssertTrue(ChangeSet.reset.requiresReloadData)
        XCTAssertFalse(ChangeSet.reset.isEmpty)
        XCTAssertTrue(ChangeSet([.reload(IndexSet(integer: 1)), .reset]).requiresReloadData)
    }

    func testTouchedRowCountSumsIndexSetsAndMoves() {
        let set = ChangeSet([.remove(IndexSet([1, 2, 3])), .move(from: 0, to: 4), .insert(IndexSet(integer: 0)),
                             .reload(IndexSet(integersIn: 5..<10))])
        XCTAssertEqual(set.touchedRowCount, 3 + 1 + 1 + 5)
        XCTAssertFalse(set.requiresReloadData)
        XCTAssertEqual(ChangeSet.reset.touchedRowCount, 0)
    }

    func testMoreThanOneThousandTouchedRowsRequiresReloadData() {
        XCTAssertFalse(ChangeSet([.insert(IndexSet(integersIn: 0..<1_000))]).requiresReloadData)
        XCTAssertTrue(ChangeSet([.insert(IndexSet(integersIn: 0..<1_001))]).requiresReloadData)
        XCTAssertTrue(ChangeSet([.insert(IndexSet(integersIn: 0..<600)), .reload(IndexSet(integersIn: 0..<401))]).requiresReloadData)
        XCTAssertTrue(ChangeSet([.insert(IndexSet(integersIn: 0..<1_500))]).requiresReloadData)
    }

    func testIsEmpty() {
        XCTAssertTrue(ChangeSet([]).isEmpty)
        XCTAssertTrue(ChangeSet([.insert(IndexSet()), .reload(IndexSet())]).isEmpty, "empty index sets change nothing")
        XCTAssertFalse(ChangeSet([.reload(IndexSet(integer: 0))]).isEmpty)
        XCTAssertFalse(ChangeSet([.move(from: 1, to: 0)]).isEmpty)
        XCTAssertFalse(ChangeSet([]).requiresReloadData)
    }

    func testEquatableAndInit() {
        XCTAssertEqual(ChangeSet([.insert(IndexSet([1]))]), ChangeSet([.insert(IndexSet([1]))]))
        XCTAssertNotEqual(ChangeSet([.insert(IndexSet([1]))]), ChangeSet([.remove(IndexSet([1]))]))
        var set = ChangeSet([])
        set.changes.append(.reset)
        XCTAssertEqual(set, .reset)
    }
}
