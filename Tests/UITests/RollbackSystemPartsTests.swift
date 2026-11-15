import Security
import XCTest
@testable import UI
import MacxFixtures

/// The real system pieces RollbackService uses (RollbackTests drives the service with fakes): ditto unpacking and
/// the designated-requirement check, each on files made inside the test's own sandbox.
final class RollbackSystemPartsTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        let sandbox = try Sandbox()
        addTeardownBlock { sandbox.destroy() }
        self.sandbox = sandbox
    }

    /// Runs a tool from /usr/bin with `arguments` (paths inside the sandbox only) and returns its exit status.
    @discardableResult
    private func tool(_ name: String, _ arguments: [String]) throws -> Int32 {
        let path = "/usr/bin/\(name)"
        guard FileManager.default.isExecutableFile(atPath: path) else { throw XCTSkip("\(path) unavailable") }
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: DittoUnpacker

    func testDittoUnpackerExtractsAZip() async throws {
        try sandbox.createFile("content/MacExplorer.app/Contents/Info.plist", contents: Data("plist".utf8))
        try sandbox.createFile("content/MacExplorer.app/Contents/MacOS/macExplorer", contents: Data("binary".utf8))
        let archive = sandbox.url("rollback.zip")
        let status = try tool("ditto", ["-c", "-k", "--keepParent", sandbox.url("content/MacExplorer.app").path(percentEncoded: false),
                                        archive.path(percentEncoded: false)])
        XCTAssertEqual(status, 0, "ditto made the fixture zip")
        let out = try sandbox.createDirectory("unpacked")
        try await DittoUnpacker().unzip(archive, into: out)
        XCTAssertEqual(try String(contentsOf: out.appending(path: "MacExplorer.app/Contents/Info.plist"), encoding: .utf8), "plist")
        XCTAssertEqual(try String(contentsOf: out.appending(path: "MacExplorer.app/Contents/MacOS/macExplorer"), encoding: .utf8), "binary")
    }

    func testDittoUnpackerThrowsOnACorruptZip() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto") else { throw XCTSkip("/usr/bin/ditto unavailable") }
        let archive = try sandbox.createFile("corrupt.zip", contents: Data("PK\u{3}\u{4} this is not a zip archive".utf8))
        let out = try sandbox.createDirectory("unpacked")
        do {
            try await DittoUnpacker().unzip(archive, into: out)
            XCTFail("a corrupt archive must not unpack")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "ditto")
            XCTAssertNotEqual(error.code, 0, "ditto's exit status")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path(percentEncoded: false)), [])
    }

    // MARK: DesignatedRequirementCheck

    /// The running test process (its own signature, whatever kind) and the path of its executable.
    private func runningExecutable() throws -> URL {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var path: CFURL?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyPath(meStatic, [], &path) == errSecSuccess, let path else {
            throw XCTSkip("the test process has no static code to compare against")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess else {
            throw XCTSkip("the test process is unsigned (no designated requirement)")
        }
        return path as URL
    }

    func testDesignatedRequirementAcceptsTheRunningCodeAndRejectsATamperedCopy() throws {
        let me = try runningExecutable()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: me.path(percentEncoded: false), isDirectory: &isDirectory),
              !isDirectory.boolValue else { throw XCTSkip("the test host is a bundle, not a single executable: \(me.path)") }
        let copy = sandbox.url("copy/\(me.lastPathComponent)")
        try sandbox.createDirectory("copy")
        // An ad-hoc host's designated requirement is the cdhash of the slice that is running, and the check covers
        // every architecture: keep only the running slice (its embedded signature unchanged) when the host is fat.
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let thinned = FileManager.default.isExecutableFile(atPath: "/usr/bin/lipo")
            && (try? tool("lipo", [me.path(percentEncoded: false), "-thin", arch, "-output", copy.path(percentEncoded: false)])) == 0
        if !thinned { try FileManager.default.copyItem(at: me, to: copy) }
        XCTAssertTrue(DesignatedRequirementCheck().signedLikeRunningApp(copy), "same code, same signature")
        // One changed byte past the header breaks the signature.
        let tampered = sandbox.url("copy/tampered")
        var bytes = try Data(contentsOf: copy)
        bytes[bytes.count / 2] ^= 0xFF
        try sandbox.createFile("copy/tampered", contents: bytes)
        XCTAssertFalse(DesignatedRequirementCheck().signedLikeRunningApp(tampered), "modified code")
    }

    func testDesignatedRequirementRejectsOtherlySignedAndUnsignedCode() throws {
        _ = try runningExecutable()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") else { throw XCTSkip("codesign unavailable") }
        // A tiny bundle with an executable that is not the running code, ad-hoc signed here.
        try sandbox.createFile("Tiny.app/Contents/Info.plist", contents: try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.macexplorer.tests.tiny", "CFBundleExecutable": "tiny"],
            format: .xml, options: 0))
        try sandbox.createDirectory("Tiny.app/Contents/MacOS")
        let exe = sandbox.url("Tiny.app/Contents/MacOS/tiny")
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: exe)
        let app = sandbox.url("Tiny.app")
        XCTAssertEqual(try tool("codesign", ["--force", "--sign", "-", "--deep", app.path(percentEncoded: false)]), 0, "ad-hoc signed")
        XCTAssertFalse(DesignatedRequirementCheck().signedLikeRunningApp(app), "a different ad-hoc signature")
        // Unsigned: the same bundle with its signature removed.
        XCTAssertEqual(try tool("codesign", ["--remove-signature", exe.path(percentEncoded: false)]), 0)
        try sandbox.remove("Tiny.app/Contents/_CodeSignature")
        XCTAssertFalse(DesignatedRequirementCheck().signedLikeRunningApp(app), "unsigned")
        // A bundle that does not exist at all.
        XCTAssertFalse(DesignatedRequirementCheck().signedLikeRunningApp(sandbox.url("Missing.app")))
    }
}
