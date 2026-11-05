import Darwin
import ImageIO
import XCTest
@testable import MacxFixtures

final class FixtureMetadataTests: XCTestCase {
    var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        addTeardownBlock { [sandbox] in sandbox?.destroy() }
    }

    private func read(_ name: String, at relative: String) -> Data? {
        let path = sandbox.url(relative).path(percentEncoded: false)
        let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: n)
        guard getxattr(path, name, &buffer, n, 0, XATTR_NOFOLLOW) == n else { return nil }
        return Data(buffer)
    }

    func testTagsCommentLastUsedRoundTripThroughXattrs() throws {
        try sandbox.createFile("a.txt", contents: Data(count: 3))
        try sandbox.setFinderTags(["Work", "Home"], on: "a.txt")
        try sandbox.setFinderComment("hello", on: "a.txt")
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        try sandbox.setLastUsedDate(date, on: "a.txt")

        let tags = try PropertyListSerialization.propertyList(from: XCTUnwrap(read(Sandbox.finderTagsXattr, at: "a.txt")), format: nil) as? [String]
        XCTAssertEqual(tags, ["Work", "Home"])
        let comment = try PropertyListSerialization.propertyList(from: XCTUnwrap(read(Sandbox.finderCommentXattr, at: "a.txt")), format: nil) as? String
        XCTAssertEqual(comment, "hello")
        let used = try XCTUnwrap(read(Sandbox.lastUsedDateXattr, at: "a.txt"))
        XCTAssertEqual(used.count, 16)
        let secs = used.prefix(8).withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
        let nsec = used.suffix(8).withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
        XCTAssertEqual(secs, 1_800_000_000)
        XCTAssertEqual(Double(nsec), 250_000_000, accuracy: 1_000)
    }

    func testWritePNGAndModificationDate() throws {
        let url = try sandbox.writePNG("img/p.png")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 50)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)

        let noon = Sandbox.noon(daysFromToday: -1)
        try sandbox.setModificationDate(noon, on: "img/p.png")
        let mdate = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
        XCTAssertEqual(try XCTUnwrap(mdate).timeIntervalSince1970, noon.timeIntervalSince1970, accuracy: 1)
    }

    func testNoonIsTwelveOClockLocalNDaysFromToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 0, minute: 30)))
        let yesterday = Sandbox.noon(daysFromToday: -1, calendar: calendar, now: now)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: yesterday),
                       DateComponents(year: 2026, month: 11, day: 4, hour: 12, minute: 0))
        XCTAssertEqual(calendar.component(.day, from: Sandbox.noon(daysFromToday: 0, calendar: calendar, now: now)), 5)
    }

    func testWritersRefuseOutsideSandbox() throws {
        if TrapProbe.value(TrapProbe.environmentKey) != nil { throw XCTSkip("in child") }
        let outside = try Sandbox()
        defer { outside.destroy() }
        try outside.createFile("escape.txt")
        let bundle = Bundle(for: FixtureMetadataTests.self).bundleURL
        let env = ["MACX_SANDBOX": sandbox.root.path(percentEncoded: false),
                   "MACX_OUTSIDE": outside.root.path(percentEncoded: false)]
        for (name, test) in [("tags-dotdot", "testProbeChildTagsDotDot"), ("png-dotdot", "testProbeChildPNGDotDot")] {
            let result = try TrapProbe.run(name: name, testIdentifier: "MacxFixturesTests.FixtureMetadataTrapProbes/\(test)",
                                           bundle: bundle, environment: env)
            XCTAssertTrue(result.trapped, "\(name): status \(result.status)\n\(result.output.suffix(2000))")
        }
        let path = outside.url("escape.txt").path(percentEncoded: false)
        // (The system may add its own xattrs such as com.apple.provenance; only the tag write matters.)
        XCTAssertEqual(getxattr(path, Sandbox.finderTagsXattr, nil, 0, 0, XATTR_NOFOLLOW), -1, "no tag may be written outside the sandbox")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.root.path(percentEncoded: false)), ["escape.txt"])
    }
}

/// Child-process halves of testWritersRefuseOutsideSandbox (the parent owns both sandboxes).
final class FixtureMetadataTrapProbes: XCTestCase {
    private func escapingPath(_ name: String) -> String {
        "../\((TrapProbe.value("MACX_OUTSIDE")! as NSString).lastPathComponent)/\(name)"
    }

    func testProbeChildTagsDotDot() throws {
        guard TrapProbe.isChild("tags-dotdot") else { throw XCTSkip("trap probe child only") }
        let s = try Sandbox(adopting: URL(filePath: TrapProbe.value("MACX_SANDBOX")!))
        try s.setFinderTags(["x"], on: escapingPath("escape.txt"))
        XCTFail("setFinderTags outside the sandbox did not trap")
    }

    func testProbeChildPNGDotDot() throws {
        guard TrapProbe.isChild("png-dotdot") else { throw XCTSkip("trap probe child only") }
        let s = try Sandbox(adopting: URL(filePath: TrapProbe.value("MACX_SANDBOX")!))
        try s.writePNG(escapingPath("escaped.png"))
        XCTFail("writePNG outside the sandbox did not trap")
    }
}
