import Foundation
import MacxFixtures
import MacxFS
import XCTest

final class ReaderParityTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func assertParity(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        var fallback = ReadOptions()
        fallback.forceFallback = true
        let bulk = try await readAll(dir)
        let slow = try await readAll(dir, options: fallback)
        XCTAssertFalse(bulk.summary.usedFallback, file: file, line: line)
        XCTAssertTrue(slow.summary.usedFallback, file: file, line: line)
        XCTAssertEqual(Set(bulk.entries.keys), Set(slow.entries.keys), file: file, line: line)
        for (name, (a, _)) in bulk.entries {
            var b = try XCTUnwrap(slow.entries[name]?.0, name, file: file, line: line)
            b.nameOffset = a.nameOffset   // arena positions depend on readdir order
            XCTAssertEqual(a, b, name, file: file, line: line)
        }
    }

    func testFallbackMatchesBulkOnGoldenTree() async throws {
        try await assertParity(try FixtureTree.golden(in: sandbox))
    }

    func testFallbackMatchesBulkOnFlatFolderAcrossBatches() async throws {
        try await assertParity(try FixtureTree.flat(in: sandbox, at: "flat", count: 5_000, directoriesEvery: 7))
    }

    func testFallbackMatchesBulkOnHFSImage() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let image = try DiskImage.create(in: sandbox, format: .hfsPlus, sizeMB: 16)
        defer { try? image.detach() }
        _ = try FixtureTree.golden(in: sandbox, at: image.relativeMountPath + "/golden")
        try await assertParity(image.mountPoint.appending(path: "golden"))
    }
}
