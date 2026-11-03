import Darwin
import Foundation
import XCTest
@testable import MacxFixtures

final class SandboxTests: XCTestCase {
    private var sandbox: Sandbox!
    private var outside: Sandbox!   // a second sandbox: the only "outside" place a broken guard could touch

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        outside = try Sandbox()
        let s = sandbox!, o = outside!
        addTeardownBlock { s.destroy(); o.destroy() }
    }

    func testRootIsFreshResolvedTempDirectory() throws {
        let temp = try Sandbox.resolvedTemporaryDirectory()
        let path = sandbox.root.path(percentEncoded: false)
        XCTAssertTrue(path.hasPrefix(temp + "/macx-tests-"), path)
        XCTAssertTrue(path.hasPrefix("/private/"), "root must be symlink-resolved: \(path)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path), [])
    }

    func testContainsRejectsEscapes() throws {
        try sandbox.createDirectory("d")
        try sandbox.createSymlink("out-link", target: outside.root.path(percentEncoded: false))
        try sandbox.createSymlink("d/up-link", target: "../..")
        try sandbox.createSymlink("dangling-out", target: outside.root.path(percentEncoded: false) + "/new.txt")
        XCTAssertTrue(sandbox.contains(sandbox.root.appending(path: "d/new.txt")))
        XCTAssertTrue(sandbox.contains(sandbox.root.appending(path: "d/../x")))
        XCTAssertFalse(sandbox.contains(sandbox.root.appending(path: "../escape.txt")))
        XCTAssertFalse(sandbox.contains(sandbox.root.appending(path: "out-link/x.txt")))
        XCTAssertFalse(sandbox.contains(sandbox.root.appending(path: "d/up-link/x.txt")))
        XCTAssertFalse(sandbox.contains(sandbox.root.appending(path: "dangling-out")))
        XCTAssertFalse(sandbox.contains(URL(filePath: "/tmp/x")))
        XCTAssertFalse(sandbox.contains(outside.root))
    }

    func testWriteHelpersStayInside() throws {
        let file = try sandbox.createFile("a/b/c.txt", contents: Data("hello".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("hello".utf8))
        try sandbox.createHardLink("a/hard.txt", to: "a/b/c.txt")
        try sandbox.createSymlink("a/link", target: "b/c.txt")
        try sandbox.setFlags("a/b/c.txt", UInt32(UF_IMMUTABLE))
        try sandbox.createSparseFile("sparse.bin", size: 1 << 20)
        var st = stat()
        XCTAssertEqual(lstat(sandbox.url("sparse.bin").path(percentEncoded: false), &st), 0)
        XCTAssertEqual(st.st_size, 1 << 20)
        XCTAssertThrowsError(try sandbox.createFile("a/link"), "createFile must not write through a symlink")
    }

    func testDestroyRemovesLockedAndUnreadableContent() throws {
        try sandbox.createFile("locked.txt")
        try sandbox.setFlags("locked.txt", UInt32(UF_IMMUTABLE))
        try sandbox.createFile("closed/inner.txt")
        try sandbox.setMode("closed", 0)
        let path = sandbox.root.path(percentEncoded: false)
        sandbox.destroy()
        XCTAssertNotEqual(access(path, F_OK), 0)
        sandbox.destroy()   // idempotent
    }

    func testAdoptingRefusesNonSandboxDirectories() throws {
        XCTAssertThrowsError(try Sandbox(adopting: URL(filePath: NSHomeDirectory())))
        XCTAssertThrowsError(try Sandbox(adopting: sandbox.root.appending(path: "nested")))
        let adopted = try Sandbox(adopting: outside.root)
        XCTAssertEqual(adopted.root, outside.root)
    }

    func testOutOfSandboxWritesTrap() throws {
        if TrapProbe.value(TrapProbe.environmentKey) != nil { throw XCTSkip("in child") }
        try sandbox.createSymlink("out", target: outside.root.path(percentEncoded: false))
        let bundle = Bundle(for: SandboxTests.self).bundleURL
        let env = ["MACX_SANDBOX": sandbox.root.path(percentEncoded: false),
                   "MACX_OUTSIDE": outside.root.path(percentEncoded: false)]
        for (name, test) in [("escape", "testProbeChildEscape"), ("dotdot", "testProbeChildDotDot")] {
            let result = try TrapProbe.run(name: name, testIdentifier: "MacxFixturesTests.SandboxTrapProbes/\(test)",
                                           bundle: bundle, environment: env)
            XCTAssertTrue(result.trapped, "\(name): status \(result.status)\n\(result.output.suffix(2000))")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.root.path(percentEncoded: false)), [],
                       "nothing may be written outside the sandbox")
    }
}

/// Child-process halves of testOutOfSandboxWritesTrap. No setUp: the parent owns both sandboxes and the
/// child adopts them, so a trapping child leaks nothing.
final class SandboxTrapProbes: XCTestCase {
    func testProbeChildEscape() throws {
        guard TrapProbe.isChild("escape") else { throw XCTSkip("trap probe child only") }
        let s = try Sandbox(adopting: URL(filePath: TrapProbe.value("MACX_SANDBOX")!))
        _ = try s.createFile("out/escaped.txt")   // "out" links to the other sandbox: must trap before writing
        XCTFail("createFile through an escaping symlink did not trap")
    }

    func testProbeChildDotDot() throws {
        guard TrapProbe.isChild("dotdot") else { throw XCTSkip("trap probe child only") }
        let s = try Sandbox(adopting: URL(filePath: TrapProbe.value("MACX_SANDBOX")!))
        _ = s.url("../\((TrapProbe.value("MACX_OUTSIDE")! as NSString).lastPathComponent)/escaped.txt")
        XCTFail("url(..) did not trap")
    }

}
