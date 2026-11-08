import Foundation
import MacxFixtures
@testable import MacxFS
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

    /// A pool whose watchdog never fires within a test (no real-clock stall can poison healthy work), with the
    /// hung volume marked unresponsive by hand, as the watchdog would after poisonCap stalls.
    private func poolWithUnresponsive(_ volume: VolumeID) async -> LanePool {
        let pool = LanePool(config: WatchdogConfig(stallTimeout: .seconds(600), lanesPerClass: 1, poisonCap: 1))
        await pool.markUnresponsive(volume)
        return pool
    }

    func testResolveUnresponsiveVolumeIsNoAccess() async throws {
        let volume = VolumeID(raw: "test-hung")
        let pool = await poolWithUnresponsive(volume)
        let health = await pool.health(of: volume)
        XCTAssertEqual(health, .unresponsive)
        let r = await AddressResolver.resolve("/", current: sandbox.root, home: sandbox.root, lanes: pool, volume: volume)
        XCTAssertEqual(r, .noAccess("/"))
    }
    /// The lane follows the typed path's volume: a hung volume elsewhere doesn't affect local input, and input on
    /// the hung volume never touches (or poisons) the current folder's lanes.
    func testResolveRoutesTheLaneByTheTargetsVolume() async throws {
        try sandbox.createDirectory("local/a")
        try sandbox.createDirectory("share/x")
        let hungID = VolumeID(raw: "test-hung-share"), localID = VolumeID(raw: "test-local")
        let mounts = MountTable([Self.volume(localID, at: URL(filePath: "/", directoryHint: .isDirectory)),
                                 Self.volume(hungID, at: sandbox.url("share"))])
        let pool = await poolWithUnresponsive(hungID)
        let current = sandbox.url("local")
        let onShare = sandbox.url("share/x").path(percentEncoded: false)
        let r = await AddressResolver.resolve(onShare, current: current, home: sandbox.root, lanes: pool, mounts: mounts)
        XCTAssertEqual(r, .noAccess(onShare), "ran on the share's (unresponsive) lane")
        guard case .folder = await AddressResolver.resolve("a", current: current, home: sandbox.root, lanes: pool, mounts: mounts) else {
            return XCTFail("local input runs on the local volume's lane")
        }
        let shareParent = sandbox.url("share").path(percentEncoded: false) + "/"
        let names = await PathCompletion.complete(shareParent, current: current, home: sandbox.root, lanes: pool, mounts: mounts)
        XCTAssertEqual(names, [], "completion under the share runs on its lane")
        let local = await PathCompletion.complete("", current: current, home: sandbox.root, lanes: pool, mounts: mounts)
        XCTAssertEqual(local, [])
        let localNames = await PathCompletion.complete("./", current: current, home: sandbox.root, lanes: pool, mounts: mounts)
        XCTAssertEqual(localNames, ["a"])
        let localHealth = await pool.health(of: localID)
        XCTAssertEqual(localHealth, .healthy)
    }

    private static func volume(_ id: VolumeID, at mountPoint: URL) -> VolumeInfo {
        VolumeInfo(id: id, mountPoint: mountPoint, name: id.raw, format: "APFS", isBoot: false, isInternal: true,
                   isRemovable: false, isEjectable: false, isLocal: true, isReadOnly: false, isBrowsable: true,
                   totalCapacity: nil,
                   capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
    }
}
