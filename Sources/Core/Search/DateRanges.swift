import Foundation
import MacxFS

public enum RelativeDay: String, Sendable, Codable, CaseIterable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear, last7Days, last30Days
}
public struct DayStamp: Sendable, Codable, Hashable {
    public var year: Int, month: Int, day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    /// "YYYY-MM-DD" or "YYYY/MM/DD", proleptic Gregorian validity (leap years included).
    public init?(parsing text: String) {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= DayStamp.daysIn(month: m, year: y) else { return nil }
        self.init(year: y, month: m, day: d)
    }
    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}
public struct DayBound: Sendable, Codable, Hashable {
    public var day: DayStamp
    public var inclusive: Bool
    public init(day: DayStamp, inclusive: Bool) { self.day = day; self.inclusive = inclusive }
}
public enum DateToken: Sendable, Codable, Hashable {
    case relative(RelativeDay)
    case days(lower: DayBound?, upper: DayBound?)
}

public enum DateRanges {
    public static func range(_ token: DateToken, now: Date, calendar: Calendar) -> TimeRange {
        switch token {
        case .relative(let r):
            let (a, b) = interval(r, now: now, calendar: calendar)
            return TimeRange(lower: ns(a), upper: ns(b))
        case .days(let lower, let upper):
            return TimeRange(lower: lower.map { ns(start($0.day, offsetDays: $0.inclusive ? 0 : 1, calendar)) },
                             upper: upper.map { ns(start($0.day, offsetDays: $0.inclusive ? 1 : 0, calendar)) })
        }
    }

    static func ns(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded()) }

    static func start(_ day: DayStamp, offsetDays: Int, _ calendar: Calendar) -> Date {
        let base = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        return calendar.date(byAdding: .day, value: offsetDays, to: calendar.startOfDay(for: base))!
    }

    static func interval(_ r: RelativeDay, now: Date, calendar c: Calendar) -> (Date, Date) {
        let today = c.startOfDay(for: now)
        func add(_ unit: Calendar.Component, _ n: Int, _ d: Date) -> Date { c.date(byAdding: unit, value: n, to: d)! }
        func of(_ unit: Calendar.Component, _ d: Date) -> (Date, Date) {
            let i = c.dateInterval(of: unit, for: d)!
            return (i.start, i.end)
        }
        switch r {
        case .today: return (today, add(.day, 1, today))
        case .yesterday: return (add(.day, -1, today), today)
        case .thisWeek: return of(.weekOfYear, now)
        case .lastWeek: return of(.weekOfYear, add(.day, -7, of(.weekOfYear, now).0))
        case .thisMonth: return of(.month, now)
        case .lastMonth: return of(.month, add(.day, -1, of(.month, now).0))
        case .thisYear: return of(.year, now)
        case .lastYear: return of(.year, add(.day, -1, of(.year, now).0))
        case .last7Days: return (add(.day, -6, today), add(.day, 1, today))
        case .last30Days: return (add(.day, -29, today), add(.day, 1, today))
        }
    }
}
