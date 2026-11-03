import Foundation
import MacxFixtures
import MacxFS
import XCTest
@testable import Core

final class PathCompletionTests: XCTestCase {
    private var sandbox: Sandbox!
    private var lanes: LanePool!

    override func setUp() async throws {
        sandbox = try Sandbox()
        lanes = LanePool()
        for d in ["Documents", "Downloads", "desk", "Music", ".hidden", ".config", "Döcs"] { try sandbox.createDirectory("root/\(d)") }
        for f in ["Doc.txt", "dog.png", ".dotfile"] { try sandbox.createFile("root/\(f)") }
        try sandbox.createDirectory("root/Target")
        try sandbox.createSymlink("root/DocLink", target: "Target")
        try sandbox.createSymlink("root/DocBroken", target: "nowhere")
        try sandbox.createFile("root/Documents/Inner/x.txt")
        try sandbox.createDirectory("home/Desktop")
        try sandbox.createDirectory("home/Developer")
    }

    override func tearDown() async throws {
        sandbox.destroy()
        sandbox = nil
        lanes = nil
    }

    /// Absolute path of the test's current folder, with a trailing slash.
    private var rootPath: String {
        let p = sandbox.url("root").path(percentEncoded: false)
        return p.hasSuffix("/") ? p : p + "/"
    }

    private func complete(_ partial: String) async -> [String] {
        await PathCompletion.complete(partial, current: sandbox.url("root"), home: sandbox.url("home"), lanes: lanes, volume: .unknown)
    }

    func testRelativePrefixIsCaseInsensitiveDirsOnly() async {
        let r = await complete("do")
        XCTAssertEqual(r, ["DocLink", "Documents", "Downloads"], "files and broken links are excluded; sorted")
    }

    func testTrailingSlashListsAllVisibleSubfolders() async {
        let r = await complete(rootPath)
        XCTAssertEqual(r, ["desk", "DocLink", "Döcs", "Documents", "Downloads", "Music", "Target"])
    }

    func testDotPrefixShowsHiddenFolders() async {
        let r = await complete(".")
        XCTAssertEqual(r, [".config", ".hidden"])
    }

    func testAbsoluteAndNestedPartial() async {
        let r = await complete(rootPath + "Documents/in")
        XCTAssertEqual(r, ["Inner"])
        let rel = await complete("./Documents/I")
        XCTAssertEqual(rel, ["Inner"])
    }

    func testTildePartialUsesHome() async {
        let r = await complete("~/De")
        XCTAssertEqual(r, ["Desktop", "Developer"])
        let all = await complete("~/")
        XCTAssertEqual(all, ["Desktop", "Developer"])
    }

    func testDiacriticsMatterButCaseDoesNot() async {
        let r = await complete("DÖ")
        XCTAssertEqual(r, ["Döcs"])
    }

    func testNoMatchesAndMissingParent() async {
        let none = await complete("zzz")
        XCTAssertEqual(none, [])
        let missing = await complete("nope/x")
        XCTAssertEqual(missing, [])
        let empty = await complete("")
        XCTAssertEqual(empty, [])
        let tilde = await complete("~")
        XCTAssertEqual(tilde, [])
    }

    func testCapsAtFifty() async throws {
        for i in 0..<80 { try sandbox.createDirectory("big/sub-\(String(format: "%03d", i))") }
        let r = await PathCompletion.complete("sub", current: sandbox.url("big"), home: sandbox.url("home"), lanes: lanes, volume: .unknown)
        XCTAssertEqual(r.count, PathCompletion.limit)
        XCTAssertEqual(PathCompletion.limit, 50)
        XCTAssertEqual(r.first, "sub-000")
        XCTAssertEqual(r.last, "sub-049")
    }

    // MARK: RecentLocations

    func testRecentLocationsMatching() {
        let recents = ["/Users/me/dev", "/tmp/Dev-stuff", "/Volumes/USB", "/Users/me/Documents"]
        XCTAssertEqual(RecentLocations.matching("", in: recents), recents)
        XCTAssertEqual(RecentLocations.matching("/users/me/d", in: recents), ["/Users/me/dev", "/Users/me/Documents"])
        XCTAssertEqual(RecentLocations.matching("dev", in: recents), ["/Users/me/dev", "/tmp/Dev-stuff"],
                       "substring matches when there is no prefix match")
        XCTAssertEqual(RecentLocations.matching("/tmp", in: recents + ["/x/tmp"]), ["/tmp/Dev-stuff", "/x/tmp"], "prefix matches first")
        XCTAssertEqual(RecentLocations.matching("zzz", in: recents), [])
        XCTAssertEqual(RecentLocations.matching("", in: (0..<30).map { "/p\($0)" }).count, 20)
    }
}
