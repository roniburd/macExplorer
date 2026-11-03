import XCTest
@testable import Core

final class NavigationHistoryTests: XCTestCase {
    private func u(_ path: String) -> URL { URL(filePath: path, directoryHint: .isDirectory) }

    func testStartsEmpty() {
        let h = NavigationHistory(current: u("/a"))
        XCTAssertEqual(h.current, u("/a"))
        XCTAssertEqual(h.backList, [])
        XCTAssertEqual(h.forwardList, [])
        XCTAssertFalse(h.canGoBack)
        XCTAssertFalse(h.canGoForward)
    }

    func testVisitBackForward() {
        var h = NavigationHistory(current: u("/a"))
        h.visit(u("/b"))
        h.visit(u("/c"))
        XCTAssertEqual(h.backList, [u("/a"), u("/b")])
        XCTAssertEqual(h.goBack(), u("/b"))
        XCTAssertEqual(h.current, u("/b"))
        XCTAssertEqual(h.forwardList, [u("/c")])
        XCTAssertEqual(h.goBack(), u("/a"))
        XCTAssertEqual(h.forwardList, [u("/b"), u("/c")])
        XCTAssertNil(h.goBack())
        XCTAssertEqual(h.current, u("/a"))
        XCTAssertEqual(h.goForward(), u("/b"))
        XCTAssertEqual(h.goForward(), u("/c"))
        XCTAssertNil(h.goForward())
        XCTAssertEqual(h.current, u("/c"))
        XCTAssertEqual(h.backList, [u("/a"), u("/b")])
    }

    func testVisitClearsForward() {
        var h = NavigationHistory(current: u("/a"))
        h.visit(u("/b"))
        _ = h.goBack()
        h.visit(u("/x"))
        XCTAssertEqual(h.forwardList, [])
        XCTAssertEqual(h.backList, [u("/a")])
        XCTAssertEqual(h.current, u("/x"))
    }

    func testVisitingCurrentIsIgnored() {
        var h = NavigationHistory(current: u("/a"))
        h.visit(u("/b"))
        _ = h.goBack()
        h.visit(u("/a"))
        h.visit(URL(filePath: "/a", directoryHint: .notDirectory))
        XCTAssertEqual(h.backList, [])
        XCTAssertEqual(h.forwardList, [u("/b")], "ignored visit keeps the forward list")
    }

    func testJumpToBackIndex() {
        var h = NavigationHistory(current: u("/a"))
        for p in ["/b", "/c", "/d"] { h.visit(u(p)) }
        XCTAssertEqual(h.jump(toBackIndex: 1), u("/b"))
        XCTAssertEqual(h.current, u("/b"))
        XCTAssertEqual(h.backList, [u("/a")])
        XCTAssertEqual(h.forwardList, [u("/c"), u("/d")])
        XCTAssertNil(h.jump(toBackIndex: 5))
        XCTAssertNil(h.jump(toBackIndex: -1))
        XCTAssertEqual(h.current, u("/b"))
    }

    func testJumpToForwardIndex() {
        var h = NavigationHistory(current: u("/a"))
        for p in ["/b", "/c", "/d"] { h.visit(u(p)) }
        _ = h.jump(toBackIndex: 0)
        XCTAssertEqual(h.forwardList, [u("/b"), u("/c"), u("/d")])
        XCTAssertEqual(h.jump(toForwardIndex: 1), u("/c"))
        XCTAssertEqual(h.backList, [u("/a"), u("/b")])
        XCTAssertEqual(h.forwardList, [u("/d")])
        XCTAssertNil(h.jump(toForwardIndex: 1))
        XCTAssertEqual(h.current, u("/c"))
    }

    func testBackListIsBounded() {
        var h = NavigationHistory(current: u("/0"))
        for i in 1...(NavigationHistory.limit + 50) { h.visit(u("/\(i)")) }
        XCTAssertEqual(h.backList.count, NavigationHistory.limit)
        XCTAssertEqual(h.backList.last, u("/\(NavigationHistory.limit + 49)"))
    }

    func testEquatable() {
        var a = NavigationHistory(current: u("/a"))
        var b = NavigationHistory(current: u("/a"))
        a.visit(u("/b"))
        b.visit(u("/b"))
        XCTAssertEqual(a, b)
        _ = b.goBack()
        XCTAssertNotEqual(a, b)
    }
}
