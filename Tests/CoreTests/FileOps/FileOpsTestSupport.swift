import XCTest
import Foundation
import Darwin
@testable import Core
import MacxFS
import MacxFixtures

/// Base class for every FileOps test. Every path a test touches comes from `sandbox`.
/// Teardown blocks (image detach) run first, then `tearDown` unlocks and deletes ONLY the sandbox root.
class FileOpsTestCase: XCTestCase {
    private(set) var sandbox: Sandbox!
    var root: URL { sandbox.root }
    var trashDir: URL { root.appending(path: ".trash", directoryHint: .isDirectory) }
    var journalURL: URL { root.appending(path: "state/journal.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = try Sandbox(prefix: "macx-tests")
        try sandbox.createDirectory("state")
        try sandbox.createDirectory(".trash")
    }

    override func tearDownWithError() throws {
        if let sandbox {
            Self.unlockTree(sandbox.root)
            sandbox.destroy()
        }
        sandbox = nil
        try super.tearDownWithError()
    }

    /// Clears uchg and restores u+rwx under the sandbox so it can be removed. Refuses anything else.
    static func unlockTree(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(tmp + "/"), url.lastPathComponent.hasPrefix("macx-tests-") else {
            preconditionFailure("unlockTree refused \(path)")
        }
        for (tool, args) in [("/usr/bin/chflags", ["-R", "nouchg", path]), ("/bin/chmod", ["-R", "u+rwx", path])] {
            let p = Process()
            p.executableURL = URL(filePath: tool)
            p.arguments = args
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    // MARK: fixtures (all through Sandbox)

    @discardableResult func file(_ rel: String, _ text: String = "x") throws -> URL {
        try sandbox.createFile(rel, contents: Data(text.utf8))
    }
    @discardableResult func bigFile(_ rel: String, bytes: Int) throws -> URL {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<bytes { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }   // incompressible enough, not sparse
        }
        return try sandbox.createFile(rel, contents: data)
    }
    @discardableResult func dir(_ rel: String) throws -> URL { try sandbox.createDirectory(rel) }
    func url(_ rel: String) -> URL { sandbox.url(rel) }

    /// A disk image inside the sandbox; detached in a teardown block. Skips the test when hdiutil is unavailable.
    func image(_ format: DiskImageFormat = .hfsPlus, sizeMB: Int = 64, readOnly: Bool = false) throws -> URL {
        guard DiskImage.isAvailable else { throw XCTSkip("hdiutil unavailable") }
        let image = try DiskImage.create(in: sandbox, format: format, sizeMB: sizeMB, readOnly: readOnly)
        addTeardownBlock { try? image.detach() }
        return image.mountPoint
    }

    // MARK: queue — makeQueue/run(_:on:) are added with FileOpQueue in P1-18.

    // MARK: inspection (read-only)

    func text(_ u: URL) -> String? { (try? Data(contentsOf: u)).map { String(decoding: $0, as: UTF8.self) } }
    func names(_ u: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }
    func exists(_ u: URL) -> Bool { var st = stat(); return lstat(u.path, &st) == 0 }
    func lst(_ u: URL) -> stat { var st = stat(); _ = lstat(u.path, &st); return st }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: @escaping @Sendable () async -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout)", file: file, line: line)
    }
}
