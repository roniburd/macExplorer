// Tests/CoreTests/Search/DateRangesTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class DateRangesTests: XCTestCase {
    // Wednesday 2026-11-04 15:00 UTC; weeks start on Monday.
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 2; return c }()
    let now = ISO8601DateFormatter().date(from: "2026-11-04T15:00:00Z")!
    func day(_ s: String) -> Int64 { DateRanges.ns(ISO8601DateFormatter().date(from: s + "T00:00:00Z")!) }
    func r(_ t: DateToken) -> TimeRange { DateRanges.range(t, now: now, calendar: cal) }

    func testRelativeRanges() {
        XCTAssertEqual(r(.relative(.today)), TimeRange(lower: day("2026-11-04"), upper: day("2026-11-05")))
        XCTAssertEqual(r(.relative(.yesterday)), TimeRange(lower: day("2026-11-03"), upper: day("2026-11-04")))
        XCTAssertEqual(r(.relative(.thisWeek)), TimeRange(lower: day("2026-11-02"), upper: day("2026-11-09")))
        XCTAssertEqual(r(.relative(.lastWeek)), TimeRange(lower: day("2026-10-26"), upper: day("2026-11-02")))
        XCTAssertEqual(r(.relative(.thisMonth)), TimeRange(lower: day("2026-11-01"), upper: day("2026-12-01")))
        XCTAssertEqual(r(.relative(.lastMonth)), TimeRange(lower: day("2026-10-01"), upper: day("2026-11-01")))
        XCTAssertEqual(r(.relative(.thisYear)), TimeRange(lower: day("2026-01-01"), upper: day("2027-01-01")))
        XCTAssertEqual(r(.relative(.lastYear)), TimeRange(lower: day("2025-01-01"), upper: day("2026-01-01")))
        XCTAssertEqual(r(.relative(.last7Days)), TimeRange(lower: day("2026-10-29"), upper: day("2026-11-05")))
    }
    func testDayBounds() {
        let d = DayStamp(year: 2026, month: 1, day: 31)
        XCTAssertEqual(r(.days(lower: DayBound(day: d, inclusive: true), upper: DayBound(day: d, inclusive: true))),
                       TimeRange(lower: day("2026-01-31"), upper: day("2026-02-01")))
        XCTAssertEqual(r(.days(lower: DayBound(day: d, inclusive: false), upper: nil)), TimeRange(lower: day("2026-02-01")))
        XCTAssertEqual(r(.days(lower: nil, upper: DayBound(day: d, inclusive: false))), TimeRange(upper: day("2026-01-31")))
    }
    func testLeapDayValidation() {
        XCTAssertNotNil(DayStamp(parsing: "2028-02-29"))
        XCTAssertNil(DayStamp(parsing: "2026-02-29"))
        XCTAssertNil(DayStamp(parsing: "2026-13-01"))
        XCTAssertNil(DayStamp(parsing: "26-01-01"))
    }

    // Review finding: dates outside Int64 nanoseconds (≈1677…2262) must saturate, never trap.
    func testOutOfRangeYearsSaturateInsteadOfTrapping() {
        let far = DayStamp(year: 9999, month: 1, day: 1), early = DayStamp(year: 1, month: 1, day: 1)
        let future = r(.days(lower: DayBound(day: far, inclusive: true), upper: DayBound(day: far, inclusive: true)))
        XCTAssertEqual(future, TimeRange(lower: .max, upper: .max))
        XCTAssertFalse(future.contains(day("2026-11-04")))
        let past = r(.days(lower: nil, upper: DayBound(day: early, inclusive: false)))
        XCTAssertEqual(past, TimeRange(upper: .min))
        XCTAssertFalse(past.contains(0))
        let sinceEarly = r(.days(lower: DayBound(day: early, inclusive: true), upper: nil))
        XCTAssertTrue(sinceEarly.contains(day("2026-11-04")), "everything is after year 1")
        XCTAssertEqual(DateRanges.ns(Date(timeIntervalSince1970: .infinity)), .max)
        XCTAssertEqual(DateRanges.ns(Date(timeIntervalSince1970: -.infinity)), .min)
        XCTAssertEqual(DateRanges.ns(Date(timeIntervalSince1970: .nan)), 0)
    }
    func testOutOfRangeYearsFromQuerySyntaxDoNotTrap() {
        let cal = self.cal
        for text in ["modified:9999-01-01", "created:<0001-01-01", "modified:2300-01-01..2301-01-01", "created:0000-01-01"] {
            let q = QuerySyntax.parse(text)
            XCTAssertTrue(q.diagnostics.isEmpty, text)
            for token in q.modified + q.created { _ = DateRanges.range(token, now: now, calendar: cal) }
        }
    }
}
