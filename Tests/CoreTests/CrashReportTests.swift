import Foundation
import MacxFixtures
import XCTest
@testable import Core

final class CrashReportTests: XCTestCase {
    private var sandbox: Sandbox!
    private var dir: URL!
    override func setUpWithError() throws { sandbox = try Sandbox(); dir = try sandbox.createDirectory("DiagnosticReports") }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private func locator() -> CrashReportLocator { CrashReportLocator(directory: dir, bundleID: "com.macexplorer.app") }
    private func plant(_ name: String, _ text: String) throws { _ = try sandbox.createFile("DiagnosticReports/\(name)", contents: Data(text.utf8)) }
    /// 2026-11-04 10:11:12 -0800
    private let crashTime = Date(timeIntervalSince1970: 1_793_815_872)

    func testFindsNewestMatchingReport() throws {
        try plant("macExplorer-2026-11-04-101112.ips", IPSFixture.make())
        try plant("macExplorer-2026-11-04-111112.ips", IPSFixture.make(timestamp: "2026-11-04 11:11:12.00 -0800"))
        let found = try XCTUnwrap(locator().newest(after: nil, excluding: []))
        XCTAssertEqual(found.fileName, "macExplorer-2026-11-04-111112.ips")
    }

    func testOlderThanLaunchIsIgnored() throws {
        try plant("macExplorer-a.ips", IPSFixture.make())
        XCTAssertNil(locator().newest(after: crashTime.addingTimeInterval(60), excluding: []))
        XCTAssertNotNil(locator().newest(after: crashTime.addingTimeInterval(-60), excluding: []))
    }

    func testAlreadyReportedIsIgnored() throws {
        try plant("macExplorer-a.ips", IPSFixture.make())
        XCTAssertNil(locator().newest(after: nil, excluding: ["macExplorer-a.ips"]))
    }

    func testOtherBundleIDIsIgnored() throws {
        try plant("macExplorer-a.ips", IPSFixture.make(bundleID: "com.macexplorer.app.scenarios"))
        try plant("macExplorer-b.ips", IPSFixture.make(bugType: "288"))   // a hang/spin report, not a crash
        try plant("Finder-c.ips", IPSFixture.make())                      // wrong file name prefix
        XCTAssertNil(locator().newest(after: nil, excluding: []))
    }

    func testGarbageAndTruncatedFilesAreSkipped() throws {
        try plant("macExplorer-a.ips", "not json at all")
        try plant("macExplorer-b.ips", String(IPSFixture.make().prefix(40)))
        _ = try sandbox.createFile("DiagnosticReports/macExplorer-c.ips", contents: Data([0xFF, 0xFE, 0x00, 0x81]))
        try plant("macExplorer-d.ips", IPSFixture.make())
        XCTAssertEqual(locator().newest(after: nil, excluding: [])?.fileName, "macExplorer-d.ips")
    }

    func testOversizedFileIsSkipped() throws {
        let big = IPSFixture.make() + String(repeating: " ", count: CrashReportLocator.maxFileSize)
        try plant("macExplorer-big.ips", big)
        XCTAssertNil(locator().newest(after: nil, excluding: []))
    }

    func testMissingDirectoryFindsNothing() {
        XCTAssertNil(CrashReportLocator(directory: sandbox.url("nope"), bundleID: "com.macexplorer.app").newest(after: nil, excluding: []))
    }

    func testExcerptParsesAndRedacts() throws {
        let e = try XCTUnwrap(CrashExcerpt.parse(IPSFixture.make(home: "/Users/tester"), home: "/Users/tester"))
        XCTAssertEqual(e.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(e.signal, "SIGSEGV")
        XCTAssertEqual(e.terminationReason, "Segmentation fault: 11")
        XCTAssertEqual(e.frames.count, CrashExcerpt.maxFrames)
        XCTAssertEqual(e.frames[0], "0  macExplorer  Core.Thing.method0() + 0")
        XCTAssertEqual(e.frames[2], "2  libsystem_kernel.dylib  + 0x1002")
        XCTAssertEqual(e.title, "Crash: EXC_BAD_ACCESS (SIGSEGV) in 0.4.0")
        XCTAssertFalse(e.text.contains("/Users/tester"))
        XCTAssertTrue(e.text.contains("0.4.0 (812)"))
    }

    /// `.ips` bodies escape "/" as "\/" (as JSONSerialization does), so redaction must apply to the decoded values.
    func testExcerptRedactsHomeInsideEscapedJSONFields() throws {
        let header = #"{"app_version":"0.4.0","build_version":"812","bug_type":"309","bundleID":"com.macexplorer.app"}"#
        let body = #"{"termination":{"indicator":"Abort at \/Users\/tester\/x.swift"},"faultingThread":0,"#
            + #""threads":[{"frames":[{"imageIndex":0,"symbol":"closure in \/Users\/tester\/Code\/a.swift","symbolLocation":4}]}],"#
            + #""usedImages":[{"name":"macExplorer"}]}"#
        let e = try XCTUnwrap(CrashExcerpt.parse(header + "\n" + body, home: "/Users/tester"))
        XCTAssertEqual(e.terminationReason, "Abort at ~/x.swift")
        XCTAssertEqual(e.frames, ["0  macExplorer  closure in ~/Code/a.swift + 4"])
        XCTAssertFalse(e.text.contains("/Users/tester"))
    }

    func testRedactReplacesEveryHomeOccurrence() {
        XCTAssertEqual(CrashExcerpt.redact("/Users/tester/a and /Users/tester/b /Users/testerX", home: "/Users/tester"),
                       "~/a and ~/b /Users/testerX")
    }

    /// The full `.ips` text goes to the clipboard (Task 11), and `.ips` files write "/" as "\/".
    func testRedactHandlesJSONEscapedHomeInRawIPSText() {
        let raw = IPSFixture.make(home: "/Users/tester")
        XCTAssertTrue(raw.contains(#"\/Users\/tester\/Applications"#), "fixture should escape slashes like real .ips files")
        let redacted = CrashExcerpt.redact(raw, home: "/Users/tester")
        XCTAssertFalse(redacted.contains("/Users/tester"))
        XCTAssertFalse(redacted.contains(#"\/Users\/tester"#))
        XCTAssertTrue(redacted.contains(#""procPath":"~\/Applications\/MacExplorer.app"#))
        XCTAssertEqual(CrashExcerpt.redact(#"{"a":"\/Users\/testerX\/y","b":"\/Users\/tester","c":"/Users/tester"}"#,
                                           home: "/Users/tester/"),
                       #"{"a":"\/Users\/testerX\/y","b":"~","c":"~"}"#)
        XCTAssertEqual(CrashExcerpt.redact(#"\/Users\/tester"#, home: "/Users/tester"), "~")
        XCTAssertEqual(CrashExcerpt.redact("/Users/testerX \\/Users\\/testerX", home: "/Users/tester"),
                       "/Users/testerX \\/Users\\/testerX")
    }

    /// Branch review: any character that can't continue the user name ends the home path.
    func testRedactTreatsEveryNonNameCharacterAsABoundary() {
        let home = "/Users/tester"
        XCTAssertEqual(CrashExcerpt.redact("cwd /Users/tester\nnext", home: home), "cwd ~\nnext")
        XCTAssertEqual(CrashExcerpt.redact("at /Users/tester then", home: home), "at ~ then")
        XCTAssertEqual(CrashExcerpt.redact("(/Users/tester)", home: home), "(~)")
        XCTAssertEqual(CrashExcerpt.redact("/Users/tester: denied, /Users/tester'", home: home), "~: denied, ~'")
        XCTAssertEqual(CrashExcerpt.redact(#"{"m":"cd \/Users\/tester\n"}"#, home: home), #"{"m":"cd ~\n"}"#)
        XCTAssertEqual(CrashExcerpt.redact(#"{"m":"cd /Users/tester\t"}"#, home: home), #"{"m":"cd ~\t"}"#)
        // Still never inside a longer name.
        for longer in ["/Users/testerX", "/Users/tester.old", "/Users/tester_2", "/Users/tester-b", "/Users/tester9",
                       "/Users/testeré", #"\/Users\/testeré"#, #"\/Users\/testerX"#] {
            XCTAssertEqual(CrashExcerpt.redact(longer, home: home), longer)
        }
    }

    func testCandidatesAreNewestFirst() throws {
        try plant("macExplorer-a.ips", IPSFixture.make())
        try plant("macExplorer-c.ips", IPSFixture.make(timestamp: "2026-11-04 12:11:12.00 -0800"))
        try plant("macExplorer-b.ips", IPSFixture.make(timestamp: "2026-11-04 11:11:12.00 -0800"))
        try plant("macExplorer-x.ips", "garbage")
        XCTAssertEqual(locator().candidates(after: nil, excluding: ["macExplorer-b.ips"]).map(\.fileName),
                       ["macExplorer-c.ips", "macExplorer-a.ips"])
        XCTAssertEqual(locator().newest(after: nil, excluding: [])?.fileName, "macExplorer-c.ips")
    }

    func testParseNeverTrapsOnTruncations() {
        let full = IPSFixture.make()
        for cut in stride(from: 0, to: full.count, by: 97) {
            _ = CrashExcerpt.parse(String(full.prefix(cut)), home: "/Users/tester")
        }
        XCTAssertNil(CrashExcerpt.parse("", home: "/Users/tester"))
    }
}
