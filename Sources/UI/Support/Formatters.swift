import Foundation
import Core
import MacxFS

/// Display formatting for list cells (§5.5). Main-actor only; formatters are cached.
@MainActor
enum Formatters {
    static let folderSize = "--"

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file      // decimal, as Finder (§5.5)
        return formatter
    }()
    private static var dateFormatters: [String: DateFormatter] = [:]
    private static var timeFormatters: [String: DateFormatter] = [:]

    /// Folders and packages show "--": no folder sizes in Phase 1 (Entry.size of a directory is its entry count).
    static func size(of entry: Entry) -> String {
        entry.kind == .directory || entry.kind == .package ? folderSize : bytes(entry.size)
    }

    static func bytes(_ count: Int64) -> String { byteFormatter.string(fromByteCount: count) }

    static func date(nanoseconds: Int64, style: DateStyle, now: Date = Date(),
                     calendar: Calendar = .current, locale: Locale = .current) -> String {
        date(Date(timeIntervalSince1970: TimeInterval(nanoseconds) / 1_000_000_000),
             style: style, now: now, calendar: calendar, locale: locale)
    }

    /// Relative: "Today 18:02", "Yesterday 09:15", otherwise medium date + short time. Absolute: always the latter.
    static func date(_ date: Date, style: DateStyle, now: Date = Date(),
                     calendar: Calendar = .current, locale: Locale = .current) -> String {
        if style == .relative {
            let time = formatter(&timeFormatters, locale: locale, calendar: calendar, dateStyle: .none).string(from: date)
            if calendar.isDate(date, inSameDayAs: now) { return String(format: L10n.string("Today %@"), time) }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
                return String(format: L10n.string("Yesterday %@"), time)
            }
        }
        return formatter(&dateFormatters, locale: locale, calendar: calendar, dateStyle: .medium).string(from: date)
    }

    /// Extension column: text after the last "." for non-folders; "" for dot-files, trailing dots and folders.
    static func extensionText(name: String, kind: Kind) -> String {
        guard kind != .directory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    private static func formatter(_ cache: inout [String: DateFormatter], locale: Locale, calendar: Calendar,
                                  dateStyle: DateFormatter.Style) -> DateFormatter {
        let key = "\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .short
        cache[key] = formatter
        return formatter
    }
}
