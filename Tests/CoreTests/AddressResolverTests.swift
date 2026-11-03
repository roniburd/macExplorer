import Foundation
import MacxFixtures
import MacxFS
import XCTest
@testable import Core

final class AddressResolverTests: XCTestCase {
    private var sandbox: Sandbox!
    private var lanes: LanePool!

    override func setUp() async throws {
        sandbox = try Sandbox()
        lanes = LanePool()
    }

    override func tearDown() async throws {
        sandbox.destroy()
        sandbox = nil
        lanes = nil
    }

    private func plain(_ url: URL?) -> String? {
        guard let path = url?.path(percentEncoded: false) else { return nil }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private let current = URL(filePath: "/Users/me/dev/proj", directoryHint: .isDirectory)
    private let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)

    private func parse(_ s: String) -> String? { plain(AddressResolver.parse(s, current: current, home: home)) }

    // MARK: parse (pure)

    func testParseAbsolute() {
        XCTAssertEqual(parse("/usr/local/bin"), "/usr/local/bin")
        XCTAssertEqual(parse("/"), "/")
        XCTAssertEqual(parse("/usr//local/"), "/usr/local")
        XCTAssertEqual(parse("  /tmp \n"), "/tmp", "surrounding whitespace is trimmed")
    }

    func testParseTilde() {
        XCTAssertEqual(parse("~"), "/Users/me")
        XCTAssertEqual(parse("~/"), "/Users/me")
        XCTAssertEqual(parse("~/Documents/x"), "/Users/me/Documents/x")
        XCTAssertEqual(parse("~/../other"), "/Users/other")
        XCTAssertEqual(parse("~notes"), "/Users/me/dev/proj/~notes", "~name is an ordinary relative name")
    }

    func testParseFileURL() {
        XCTAssertEqual(parse("file:///Users/me/My%20Files/"), "/Users/me/My Files")
        XCTAssertEqual(parse("FILE:///tmp"), "/tmp")
        XCTAssertEqual(parse("file://localhost/tmp"), "/tmp")
        XCTAssertNil(parse("file://server/share"), "remote hosts are not local paths")
        XCTAssertNil(parse("http://example.com/x"))
    }

    func testParseRelative() {
        XCTAssertEqual(parse("src"), "/Users/me/dev/proj/src")
        XCTAssertEqual(parse("./src/../lib"), "/Users/me/dev/proj/lib")
        XCTAssertEqual(parse(".."), "/Users/me/dev")
        XCTAssertEqual(parse("../../.."), "/Users")
        XCTAssertEqual(parse("../../../.."), "/")
        XCTAssertEqual(parse("../../../../../.."), "/", ".. never climbs above /")
        XCTAssertEqual(parse("."), "/Users/me/dev/proj")
        XCTAssertEqual(parse("a b/c"), "/Users/me/dev/proj/a b/c")
    }

    func testParseStripsMatchingQuotes() {
        XCTAssertEqual(parse("'/tmp/a b'"), "/tmp/a b")
        XCTAssertEqual(parse("\"~/x\""), "/Users/me/x")
        XCTAssertEqual(parse("'x"), "/Users/me/dev/proj/'x")
    }

    func testParseEmptyIsNil() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   "))
    }

    func testParseResultIsStandardized() throws {
        let url = try XCTUnwrap(AddressResolver.parse("/a/./b/../c", current: current, home: home))
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url, url.standardizedFileURL)
    }

    // MARK: resolve (lane)

    private func resolve(_ s: String, current: URL? = nil) async -> AddressResult {
        await AddressResolver.resolve(s, current: current ?? sandbox.root, home: sandbox.url("home"), lanes: lanes, volume: .unknown)
    }

    func testResolveFolder() async throws {
        try sandbox.createDirectory("a/b")
        guard case .folder(let url) = await resolve("a/b") else { return XCTFail("expected a folder") }
        XCTAssertEqual(plain(url), plain(sandbox.url("a/b")))
        guard case .folder(let abs) = await resolve(sandbox.url("a").path(percentEncoded: false)) else { return XCTFail() }
        XCTAssertEqual(plain(abs), plain(sandbox.url("a")))
        guard case .folder(let up) = await resolve("..", current: sandbox.url("a/b")) else { return XCTFail() }
        XCTAssertEqual(plain(up), plain(sandbox.url("a")))
    }

    func testResolveTildeUsesGivenHome() async throws {
        try sandbox.createDirectory("home/Docs")
        guard case .folder(let url) = await resolve("~/Docs") else { return XCTFail("expected a folder") }
        XCTAssertEqual(plain(url), plain(sandbox.url("home/Docs")))
    }

    func testResolveFileGivesParentAndName() async throws {
        try sandbox.createFile("a/notes.txt")
        guard case .file(let parent, let name) = await resolve("a/notes.txt") else { return XCTFail("expected a file") }
        XCTAssertEqual(plain(parent), plain(sandbox.url("a")))
        XCTAssertEqual(name, "notes.txt")
    }

    func testResolvePackageIsSelectedInParent() async throws {
        try sandbox.createDirectory("Tool.app/Contents")
        guard case .file(let parent, let name) = await resolve("Tool.app") else { return XCTFail("expected the package as an item") }
        XCTAssertEqual(plain(parent), plain(sandbox.root))
        XCTAssertEqual(name, "Tool.app")
        guard case .folder = await resolve("Tool.app/Contents") else { return XCTFail("inside a package is a folder") }
    }

    func testResolveSymlinkToFolderIsFolder() async throws {
        try sandbox.createDirectory("real")
        try sandbox.createSymlink("link", target: "real")
        guard case .folder(let url) = await resolve("link") else { return XCTFail("expected a folder") }
        XCTAssertEqual(plain(url), plain(sandbox.url("link")), "the typed path is kept, not the target")
    }

    func testResolveMissing() async {
        let r1 = await resolve("does-not-exist")
        XCTAssertEqual(r1, .notFound("does-not-exist"))
        let r2 = await resolve("")
        XCTAssertEqual(r2, .notFound(""))
        _ = try? sandbox.createSymlink("broken", target: "nowhere")
        let r3 = await resolve("broken")
        XCTAssertEqual(r3, .notFound("broken"))
    }

    func testResolveNoAccess() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permissions")
        try sandbox.createFile("locked/inner.txt")
        try sandbox.createDirectory("closed")
        try sandbox.setMode("locked", 0o000)
        try sandbox.setMode("closed", 0o000)
        let r1 = await resolve("locked/inner.txt")
        XCTAssertEqual(r1, .noAccess("locked/inner.txt"))
        let r2 = await resolve("closed")
        XCTAssertEqual(r2, .noAccess("closed"), "a folder that can't be listed can't be opened")
        try sandbox.setMode("locked", 0o755)
        try sandbox.setMode("closed", 0o755)
    }

    func testResolveUnresponsiveVolumeIsNoAccess() async throws {
        let pool = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(60), tick: .milliseconds(10), lanesPerClass: 1, poisonCap: 1))
        let volume = VolumeID(raw: "test-hung")
        let gate = DispatchSemaphore(value: 0)
        let hung = Task { try? await pool.perform(on: volume, .read) { _ in _ = gate.wait(timeout: .now() + 3) } }
        defer { gate.signal(); hung.cancel() }
        var health = await pool.health(of: volume)
        for _ in 0..<200 where health != .unresponsive {
            try await Task.sleep(for: .milliseconds(10))
            health = await pool.health(of: volume)
        }
        try XCTSkipIf(health != .unresponsive, "watchdog did not mark the volume unresponsive in time")
        let r = await AddressResolver.resolve("/", current: sandbox.root, home: sandbox.root, lanes: pool, volume: volume)
        XCTAssertEqual(r, .noAccess("/"))
    }
}
