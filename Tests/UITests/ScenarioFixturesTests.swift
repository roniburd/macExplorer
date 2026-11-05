import Darwin
import XCTest
import MacxFixtures
@testable import UI

final class ScenarioFixturesTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(prefix: "macx-tests")
        addTeardownBlock { [sandbox] in
            // a mode-000 fixture folder must not block teardown
            if let s = sandbox { chmod(s.url("macx-scenario-root/closed").path, 0o755); s.destroy() }
        }
    }

    private func root() throws -> URL { try sandbox.createDirectory("macx-scenario-root").resolvingSymlinksInPath() }

    func testCreatesFilesDirsHiddenSizesAndModes() throws {
        let r = try root()
        let f = ScenarioFile.Fixture(files: ["a.txt", "dest/b.txt", "closed/c.txt"], dirs: ["empty", "closed"],
                                     hidden: ["flagged.txt"], sizes: ["dest/b.txt": 10], modes: ["closed": "000"])
        try ScenarioFixtures.create(f, in: r)
        var st = stat()
        XCTAssertEqual(lstat(r.appending(path: "dest/b.txt").path, &st), 0)
        XCTAssertEqual(st.st_size, 10)
        XCTAssertEqual(lstat(r.appending(path: "flagged.txt").path, &st), 0)
        XCTAssertNotEqual(st.st_flags & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(lstat(r.appending(path: "closed").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0)
        XCTAssertEqual(ScenarioFixtures.topLevelVisibleNames(f), ["a.txt", "dest", "closed", "empty"])
    }

    func testRefusesRootsThatAreNotEmptyScenarioSandboxes() throws {
        let other = try sandbox.createDirectory("other").resolvingSymlinksInPath()
        XCTAssertThrowsError(try ScenarioFixtures.create(.init(files: ["a"], dirs: []), in: other)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .rootNotScenarioSandbox(other.path))
        }
        let r = try root()
        try sandbox.createFile("macx-scenario-root/existing.txt")
        XCTAssertThrowsError(try ScenarioFixtures.create(.init(files: ["a"], dirs: []), in: r)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .rootNotEmpty(r.path))
        }
    }

    func testFixturesRefuseEscapingPaths() throws {
        let r = try root()
        XCTAssertThrowsError(try ScenarioFixtures.create(.init(files: ["../escape.txt"], dirs: []), in: r)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .unsafePath("../escape.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.root.appending(path: "escape.txt").path))
    }

    private func xattr(_ name: String, _ url: URL) -> Data? {
        let n = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: n)
        return getxattr(url.path, name, &buffer, n, 0, XATTR_NOFOLLOW) == n ? Data(buffer) : nil
    }

    func testPhase2ImagesModesMetadataAndDates() throws {
        let r = try root()
        var f = ScenarioFile.Fixture(files: ["a.txt", "A/b.txt"], dirs: ["A", "E"])
        f.images = ["img/p.png"]
        f.tags = ["a.txt": ["Work", "Home"]]
        f.comments = ["A/b.txt": "note"]
        f.lastOpenedDays = ["a.txt": -3]
        f.mtimeDays = ["a.txt": -1, "A": -2]
        try ScenarioFixtures.create(f, in: r)

        var st = stat()
        for (path, mode) in [("a.txt", 0o644), ("A/b.txt", 0o644), ("img/p.png", 0o644), ("A", 0o755), ("E", 0o755), ("img", 0o755)] {
            XCTAssertEqual(lstat(r.appending(path: path).path, &st), 0, path)
            XCTAssertEqual(Int(st.st_mode & 0o777), mode, path)
        }
        let png = try Data(contentsOf: r.appending(path: "img/p.png"))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let tags = try PropertyListSerialization.propertyList(from: XCTUnwrap(xattr(ScenarioFixtures.finderTagsXattr, r.appending(path: "a.txt"))), format: nil)
        XCTAssertEqual(tags as? [String], ["Work", "Home"])
        let comment = try PropertyListSerialization.propertyList(from: XCTUnwrap(xattr(ScenarioFixtures.finderCommentXattr, r.appending(path: "A/b.txt"))), format: nil)
        XCTAssertEqual(comment as? String, "note")
        let used = try XCTUnwrap(xattr(ScenarioFixtures.lastUsedDateXattr, r.appending(path: "a.txt")))
        XCTAssertEqual(used.count, 16)
        let secs = used.prefix(8).withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
        XCTAssertEqual(Double(secs), ScenarioFixtures.noon(daysFromToday: -3).timeIntervalSince1970, accuracy: 1)
        // mtimes survive the later writes (A got a child after its directory was created).
        for (path, days) in [("a.txt", -1), ("A", -2)] {
            let date = try FileManager.default.attributesOfItem(atPath: r.appending(path: path).path)[.modificationDate] as? Date
            XCTAssertEqual(try XCTUnwrap(date).timeIntervalSince1970, ScenarioFixtures.noon(daysFromToday: days).timeIntervalSince1970,
                           accuracy: 1, path)
        }
        XCTAssertEqual(ScenarioFixtures.topLevelVisibleNames(f), ["a.txt", "A", "E", "img"])
    }

    func testFixtureEncodingsMatchMacxFixtures() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.5)
        XCTAssertEqual(ScenarioFixtures.lastUsedDateValue(date), Sandbox.lastUsedDateValue(date))
        XCTAssertEqual(ScenarioFixtures.finderTagsXattr, Sandbox.finderTagsXattr)
        XCTAssertEqual(ScenarioFixtures.finderCommentXattr, Sandbox.finderCommentXattr)
        XCTAssertEqual(ScenarioFixtures.lastUsedDateXattr, Sandbox.lastUsedDateXattr)
        XCTAssertEqual(ScenarioFixtures.noon(daysFromToday: -2), Sandbox.noon(daysFromToday: -2))
    }

    func testMetadataFixturesRefuseEscapingPaths() throws {
        let r = try root()
        var f = ScenarioFile.Fixture(files: ["a.txt"], dirs: [])
        f.tags = ["../escape.txt": ["x"]]
        XCTAssertThrowsError(try ScenarioFixtures.create(f, in: r)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .unsafePath("../escape.txt"))
        }
    }

    func testWriteZerosCreatesParentsAndReplaces() throws {
        let r = try root()
        let url = r.appending(path: "A/n.bin")
        try ScenarioFixtures.writeZeros(10, at: url)
        XCTAssertEqual(try Data(contentsOf: url), Data(count: 10))
        try ScenarioFixtures.writeZeros(3, at: url)
        XCTAssertEqual(try Data(contentsOf: url).count, 3)
        try sandbox.createSymlink("macx-scenario-root/link", target: "A/n.bin")
        XCTAssertThrowsError(try ScenarioFixtures.writeZeros(1, at: r.appending(path: "link")), "never writes through a symlink")
    }
    /// Review fix: a root-internal symlink pointing outside, followed by components that don't exist yet, must not
    /// let fsWrite/fsTags create anything outside the root (resolvingSymlinksInPath leaves such paths unresolved).
    func testConfinedTargetRefusesSymlinkedAncestorsWithMissingComponents() throws {
        let r = try root()
        let outside = try Sandbox(prefix: "macx-tests")
        defer { outside.destroy() }
        let real = try XCTUnwrap(realpath(r.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        let roots = [r.standardizedFileURL.path, real]  // ScenarioDriver.rootPrefixes: /var/... and /private/var/...
        try sandbox.createSymlink("macx-scenario-root/link", target: outside.root.path(percentEncoded: false))
        for relative in ["link/new/n.bin", "link/new/deeper/n.bin", "link/n.bin"] {
            XCTAssertThrowsError(try ScenarioFixtures.confinedTarget(relative, root: r, roots: roots, createParents: true),
                                 relative)
        }
        try sandbox.createDirectory("macx-scenario-root/A")
        try sandbox.createSymlink("macx-scenario-root/A/dangling", target: outside.root.appending(path: "gone").path)
        XCTAssertThrowsError(try ScenarioFixtures.confinedTarget("A/dangling/n.bin", root: r, roots: roots, createParents: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.root.path), [], "nothing written outside")

        let ok = try ScenarioFixtures.confinedTarget("B/C/n.bin", root: r, roots: roots, createParents: true)
        XCTAssertEqual(ok.path, real + "/B/C/n.bin")
        try ScenarioFixtures.writeZeros(4, at: ok)
        XCTAssertEqual(try Data(contentsOf: ok).count, 4)
        XCTAssertThrowsError(try ScenarioFixtures.confinedTarget("D/n.bin", root: r, roots: roots, createParents: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.appending(path: "D").path))
        XCTAssertThrowsError(try ScenarioFixtures.confinedTarget("../x", root: r, roots: roots, createParents: true))
    }
}
