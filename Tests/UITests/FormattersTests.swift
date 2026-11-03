import XCTest
@testable import UI
import Core
import MacxFS

@MainActor
final class FormattersTests: XCTestCase {
    private func entry(_ kind: Kind, size: Int64 = 0) -> Entry {
        Entry(rowID: 1, fileID: 1, size: size, allocSize: size, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 1,
              kind: kind, flags: [], typeIndex: TypeRegistry.dataIndex)
    }
    private var gmt: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "GMT")!
        return c
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testFolderAndPackageSizeIsDashes() {
        XCTAssertEqual(Formatters.size(of: entry(.directory, size: 42)), "--")
        XCTAssertEqual(Formatters.size(of: entry(.package, size: 42)), "--")
    }

    func testFileSizeUsesDecimalFileStyle() {
        XCTAssertEqual(Formatters.size(of: entry(.file, size: 1_500_000)),
                       ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file))
        XCTAssertNotEqual(Formatters.bytes(1_500_000),
                          ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .binary))
    }

    func testRelativeTodayAndYesterday() {
        let now = date("2026-11-02T12:00:00Z")
        let en = Locale(identifier: "en_GB")
        XCTAssertEqual(Formatters.date(date("2026-11-02T18:02:00Z"), style: .relative, now: now, calendar: gmt, locale: en),
                       "Today 18:02")
        XCTAssertEqual(Formatters.date(date("2026-11-01T09:15:00Z"), style: .relative, now: now, calendar: gmt, locale: en),
                       "Yesterday 09:15")
    }

    func testOlderDatesAndAbsoluteStyleNeverSayToday() {
        let now = date("2026-11-02T12:00:00Z")
        let en = Locale(identifier: "en_GB")
        let older = Formatters.date(date("2026-10-30T08:00:00Z"), style: .relative, now: now, calendar: gmt, locale: en)
        XCTAssertTrue(older.contains("2026"), older)
        let absolute = Formatters.date(date("2026-11-02T18:02:00Z"), style: .absolute, now: now, calendar: gmt, locale: en)
        XCTAssertFalse(absolute.contains("Today"), absolute)
        XCTAssertTrue(absolute.contains("18:02"), absolute)
    }

    func testExtensionText() {
        XCTAssertEqual(Formatters.extensionText(name: "a.tar.gz", kind: .file), "gz")
        XCTAssertEqual(Formatters.extensionText(name: ".env", kind: .file), "")
        XCTAssertEqual(Formatters.extensionText(name: "name.", kind: .file), "")
        XCTAssertEqual(Formatters.extensionText(name: "My.Folder", kind: .directory), "")
        XCTAssertEqual(Formatters.extensionText(name: "Safari.app", kind: .package), "app")
    }
}
