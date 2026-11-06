@testable import Core
import Foundation
import MacxFS
import XCTest

/// Pure selection rules (§5.5) over a hand-built row space.
final class SelectionTests: XCTestCase {
    /// Display rows: identities .object(100 + row), names "r<row>".
    fileprivate struct Space {
        var ids: [RowID]
        init(_ count: Int) { ids = (0..<count).map { RowID.object(UInt64(100 + $0)) } }
        var space: SelectionRowSpace {
            let ids = self.ids
            return SelectionRowSpace(count: ids.count, identity: { ids[$0] }, row: { ids.firstIndex(of: $0) },
                                     rowsNamed: { names in
                                         IndexSet(names.compactMap { name in
                                             guard name.hasPrefix("r"), let n = Int(name.dropFirst()), n < ids.count else { return nil }
                                             return n
                                         })
                                     })
        }
    }

    private func id(_ row: Int) -> RowID { .object(UInt64(100 + row)) }

    private func applied(_ commands: [SelectionCommand], _ space: Space = Space(10)) -> Selection {
        var s = Selection.empty
        for c in commands { s.apply(c, in: space.space) }
        return s
    }

    func testEmpty() {
        XCTAssertTrue(Selection.empty.isEmpty)
        XCTAssertEqual(Selection.empty.count, 0)
        XCTAssertEqual(Selection.empty.rows, [])
        XCTAssertNil(Selection.empty.anchor)
        XCTAssertNil(Selection.empty.cursor)
    }

    func testSetSelectsRowsWithCursorAndAnchor() {
        let s = applied([.set(IndexSet([2, 4]), cursor: 4)])
        XCTAssertEqual(s.rows, IndexSet([2, 4]))
        XCTAssertEqual(s.ids, [id(2), id(4)])
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.cursor, id(4))
        XCTAssertEqual(s.anchor, id(4))
    }

    func testSetWithoutCursorUsesFirstRowAndDropsOutOfRangeRows() {
        let s = applied([.set(IndexSet([3, 12, -1]), cursor: nil)])
        XCTAssertEqual(s.rows, IndexSet([3]))
        XCTAssertEqual(s.cursor, id(3))
        XCTAssertEqual(s.anchor, id(3))
        XCTAssertTrue(applied([.set(IndexSet([3]), cursor: 3), .set([], cursor: nil)]).isEmpty)
    }

    func testToggleAddsAndRemovesAndMovesAnchor() {
        var s = applied([.set(IndexSet([1]), cursor: 1), .toggle(5)])
        XCTAssertEqual(s.rows, IndexSet([1, 5]))
        XCTAssertEqual(s.anchor, id(5))
        s.apply(.toggle(1), in: Space(10).space)
        XCTAssertEqual(s.rows, IndexSet([5]))
        XCTAssertEqual(s.cursor, id(1), "the toggled row has keyboard focus even when deselected")
        s.apply(.toggle(42), in: Space(10).space)
        XCTAssertEqual(s.rows, IndexSet([5]), "out-of-range toggle is ignored")
    }

    func testExtendReplacesSelectionWithRangeFromAnchor() {
        var s = applied([.set(IndexSet([4]), cursor: 4), .toggle(8), .toggle(2)])
        XCTAssertEqual(s.anchor, id(2))
        s.apply(.extend(to: 5), in: Space(10).space)
        XCTAssertEqual(s.rows, IndexSet(2...5))
        XCTAssertEqual(s.anchor, id(2), "extend keeps the anchor")
        XCTAssertEqual(s.cursor, id(5))
        s.apply(.extend(to: 0), in: Space(10).space)
        XCTAssertEqual(s.rows, IndexSet(0...2), "extending past the anchor flips the range")
    }

    /// Grouped Details: ⇧-extending across a collapsed group leaves its hidden rows out (P2-10 review).
    func testExtendExcludingLeavesHiddenRowsOut() {
        var s = applied([.set(IndexSet([2]), cursor: 2)])
        s.apply(.extend(to: 7, excluding: IndexSet(3..<7)), in: Space(10).space)
        XCTAssertEqual(s.rows, IndexSet([2, 7]))
        XCTAssertEqual(s.anchor, id(2), "extend keeps the anchor")
        XCTAssertEqual(s.cursor, id(7))
        s.apply(.extend(to: 0, excluding: IndexSet(3..<7)), in: Space(10).space)
        XCTAssertEqual(s.rows, IndexSet(0...2))
    }

    func testExtendWithoutAnchorStartsAtTarget() {
        let s = applied([.extend(to: 3)])
        XCTAssertEqual(s.rows, IndexSet([3]))
        XCTAssertEqual(s.anchor, id(3))
    }

    func testAddUnionsAndKeepsAnchor() {
        let s = applied([.set(IndexSet([1]), cursor: 1), .add(IndexSet([3, 4, 99]))])
        XCTAssertEqual(s.rows, IndexSet([1, 3, 4]))
        XCTAssertEqual(s.anchor, id(1))
    }

    func testAllNoneInvert() {
        XCTAssertEqual(applied([.all]).rows, IndexSet(0..<10))
        XCTAssertEqual(applied([.set(IndexSet([0, 9]), cursor: 0), .invert]).rows, IndexSet(1...8))
        let none = applied([.set(IndexSet([2]), cursor: 2), .none])
        XCTAssertEqual(none, .empty)
        XCTAssertEqual(applied([.all], Space(0)).rows, [])
    }

    /// QA round 2: grouped Details' ⌘A and Invert Selection work over the visible items only.
    func testAllAndInvertLeaveOutExcludedRows() {
        let hidden = IndexSet(3...5)
        XCTAssertEqual(applied([.allVisible(excluding: hidden)]).rows, IndexSet(0..<10).subtracting(hidden))
        let inverted = applied([.set(IndexSet([0, 9]), cursor: 0), .invertVisible(excluding: hidden)])
        XCTAssertEqual(inverted.rows, IndexSet([1, 2, 6, 7, 8]))
        XCTAssertEqual(inverted.cursor, id(0), "the cursor stays where it was, like .invert")
        let hiddenSelected = applied([.set(IndexSet([0, 4]), cursor: 0), .invertVisible(excluding: hidden)])
        XCTAssertFalse(hiddenSelected.rows.contains(4), "an excluded row never ends up selected")
        XCTAssertEqual(applied([.allVisible(excluding: [])]).rows, IndexSet(0..<10))
    }

    func testNamesSelectsPresentNames() {
        let s = applied([.names(["r7", "r2", "missing"])])
        XCTAssertEqual(s.rows, IndexSet([2, 7]))
        XCTAssertEqual(s.cursor, id(2))
    }

    func testReconcileFollowsIdentitiesAndDropsVanished() {
        var space = Space(6)
        var s = Selection.empty
        s.apply(.set(IndexSet([1, 4]), cursor: 4), in: space.space)
        space.ids.reverse()                          // re-sort: id(1) now at row 4, id(4) at row 1
        s.reconcile(in: space.space)
        XCTAssertEqual(s.rows, IndexSet([1, 4]))
        XCTAssertEqual(s.ids, [id(1), id(4)])
        XCTAssertEqual(space.row(of: s.cursor), 1)
        space.ids.removeAll { $0 == id(4) }          // the cursor row disappeared
        s.reconcile(in: space.space)
        XCTAssertEqual(s.ids, [id(1)])
        XCTAssertEqual(s.rows, IndexSet([3]))
        XCTAssertNil(s.cursor)
        XCTAssertNil(s.anchor)
    }

    func testSubstituteMovesIdentityStateToReplacement() {
        var space = Space(3)
        var s = Selection.empty
        s.apply(.set(IndexSet([1]), cursor: 1), in: space.space)
        space.ids[1] = .object(999)                  // atomic save: new identity at the same name
        s.substitute(id(1), with: .object(999))
        s.reconcile(in: space.space)
        XCTAssertEqual(s.ids, [.object(999)])
        XCTAssertEqual(s.rows, IndexSet([1]))
        XCTAssertEqual(s.cursor, .object(999))
        XCTAssertEqual(s.anchor, .object(999))
    }

    func testSummaryEquatable() {
        XCTAssertEqual(SelectionSummary(count: 2, files: 1, folders: 1, bytes: 10),
                       SelectionSummary(count: 2, files: 1, folders: 1, bytes: 10))
    }
}

private extension SelectionTests.Space {
    func row(of id: RowID?) -> Int? { id.flatMap { ids.firstIndex(of: $0) } }
}
