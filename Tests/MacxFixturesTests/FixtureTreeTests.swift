import Darwin
import Foundation
import XCTest
import MacxFixtures

final class FixtureTreeTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func lstatOf(_ url: URL) -> stat? {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0 ? st : nil
    }

    func testGoldenTreeHasEveryKind() throws {
        let root = try FixtureTree.golden(in: sandbox)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)))
        XCTAssertEqual(names.count, GoldenName.all.count)
        for name in GoldenName.all {
            XCTAssertTrue(names.contains(where: { $0 == name && Array($0.utf8) == Array(name.utf8) }) || names.contains(name),
                          "missing \(name)")
        }
        XCTAssertTrue(names.contains { Array($0.unicodeScalars) == Array(GoldenName.nfd.unicodeScalars) }, "NFD name was normalized")
        XCTAssertEqual(GoldenName.long255.utf8.count, 255)
        XCTAssertEqual(GoldenName.long255Multibyte.utf8.count, 255)

        let flagHidden = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.flagHidden)))
        XCTAssertNotEqual(flagHidden.st_flags & UInt32(UF_HIDDEN), 0)
        let locked = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.locked)))
        XCTAssertNotEqual(locked.st_flags & UInt32(UF_IMMUTABLE), 0)
        let a = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.hardLinkA)))
        let b = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.hardLinkB)))
        XCTAssertEqual(a.st_ino, b.st_ino)
        XCTAssertEqual(a.st_nlink, 2)
        let link = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.brokenSymlink)))
        XCTAssertEqual(link.st_mode & S_IFMT, S_IFLNK)
        let sparse = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.sparse)))
        XCTAssertEqual(sparse.st_size, 8 << 20)
        let alias = try root.appending(path: GoldenName.alias).resourceValues(forKeys: [.isAliasFileKey])
        XCTAssertEqual(alias.isAliasFile, true)
        let ext = try root.appending(path: GoldenName.extensionHidden).resourceValues(forKeys: [.hasHiddenExtensionKey])
        XCTAssertEqual(ext.hasHiddenExtension, true)
        let dated = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.dated)))
        XCTAssertEqual(dated.st_mtimespec.tv_sec, 1_012_608_000)
        XCTAssertEqual(dated.st_birthtimespec.tv_sec, 978_307_200)
    }

    func testFlatCreatesExactlyCountEntries() throws {
        let dir = try FixtureTree.flat(in: sandbox, at: "flat", count: 1_000, directoriesEvery: 10)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        XCTAssertEqual(names.count, 1_000)
        XCTAssertTrue(names.contains("file-000001.txt"))
        XCTAssertTrue(names.contains("file-000010"))   // every 10th is a directory without extension
    }

    func testDeepTreeShape() throws {
        let dir = try FixtureTree.deep(in: sandbox, at: "deep", depth: 3, breadth: 2, filesPerDir: 2)
        let all = FileManager.default.enumerator(atPath: dir.path(percentEncoded: false))!.allObjects as! [String]
        // dirs: 2 + 4 = 6; files: 2 × (1 + 2 + 4) = 14
        XCTAssertEqual(all.count, 20)
    }
}
