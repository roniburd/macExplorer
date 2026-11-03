import Darwin
import Foundation
import XCTest
@testable import MacxFixtures

final class DiskImageTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func fsType(_ url: URL) -> String {
        var st = statfs()
        guard statfs(url.path(percentEncoded: false), &st) == 0 else { return "?" }
        return withUnsafeBytes(of: &st.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    func testEachFormatMountsInsideSandboxWithNoBrowse() throws {
        let expected: [DiskImageFormat: String] = [.apfs: "apfs", .apfsCaseSensitive: "apfs", .hfsPlus: "hfs", .exfat: "exfat", .msdos: "msdos"]
        for format in DiskImageFormat.allCases {
            let image = try DiskImage.create(in: sandbox, format: format, sizeMB: 16)
            XCTAssertTrue(sandbox.contains(image.mountPoint))
            XCTAssertEqual(fsType(image.mountPoint), expected[format], "\(format)")
            var st = statfs()
            XCTAssertEqual(statfs(image.mountPoint.path(percentEncoded: false), &st), 0)
            XCTAssertNotEqual(st.f_flags & UInt32(MNT_DONTBROWSE), 0, "\(format) must be mounted -nobrowse")
            try sandbox.createFile(image.relativeMountPath + "/hello.txt")
            try image.detach()
            try image.detach()   // idempotent
            XCTAssertFalse(FileManager.default.fileExists(atPath: image.mountPoint.path(percentEncoded: false) + "/hello.txt"))
        }
    }

    func testReadOnlyImageRejectsWrites() throws {
        let image = try DiskImage.create(in: sandbox, format: .apfs, sizeMB: 16, readOnly: true) { mount in
            try self.sandbox.createFile("\(mount.lastPathComponent)/seed.txt")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.mountPoint.path(percentEncoded: false) + "/seed.txt"))
        XCTAssertThrowsError(try sandbox.createFile(image.relativeMountPath + "/new.txt")) { error in
            XCTAssertEqual((error as NSError).code, Int(EROFS))
        }
    }

    func testDestroyDetachesStillMountedImages() throws {
        let image = try DiskImage.create(in: sandbox, format: .hfsPlus, sizeMB: 16)
        let point = image.mountPoint.path(percentEncoded: false)
        sandbox.destroy()
        XCTAssertFalse(Sandbox.mountPoints(under: (point as NSString).deletingLastPathComponent).contains(point))
        XCTAssertNotEqual(access(sandbox.root.path(percentEncoded: false), F_OK), 0)
    }
}
