import Darwin
import Darwin.membership
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

    /// ACL tests (P4-14/P4-18) put "everyone deny delete" entries on sandbox files; teardown must still remove them.
    func testDestroyRemovesContentWithDenyDeleteACLs() throws {
        let child = try sandbox.createFile("d/c.txt").path(percentEncoded: false)
        let dir = sandbox.url("d").path(percentEncoded: false)
        for (path, perms) in [(child, [ACL_DELETE]), (dir, [ACL_DELETE, ACL_DELETE_CHILD])] {
            var acl = acl_init(1)
            var entry: acl_entry_t?
            XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
            XCTAssertEqual(acl_set_tag_type(entry, ACL_EXTENDED_DENY), 0)
            var uuid = [UInt8](repeating: 0, count: 16)
            XCTAssertEqual(mbr_gid_to_uuid(12, &uuid), 0)   // gid 12 = everyone
            XCTAssertEqual(acl_set_qualifier(entry, uuid), 0)
            var set: acl_permset_t?
            XCTAssertEqual(acl_get_permset(entry, &set), 0)
            for p in perms { XCTAssertEqual(acl_add_perm(set, p), 0) }
            XCTAssertEqual(acl_set_permset(entry, set), 0)
            XCTAssertEqual(acl_set_link_np(path, ACL_TYPE_EXTENDED, acl), 0)
            acl_free(UnsafeMutableRawPointer(acl))
        }
        XCTAssertNotEqual(unlink(child), 0, "the deny-delete ACL is in effect")
        let path = sandbox.root.path(percentEncoded: false)
        sandbox.destroy()
        XCTAssertNotEqual(access(path, F_OK), 0, "destroy must strip ACLs before removing")
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
