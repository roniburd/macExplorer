import CFSKit
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import XCTest

final class ReaderGoldenTests: XCTestCase {
    private var sandbox: Sandbox!
    private var golden: URL!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        golden = try FixtureTree.golden(in: sandbox)
    }

    private static func ns(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec) }

    /// ATTR_CMNEXT_LINKID straight from getattrlist(2), independent of CFSKit.
    private func linkID(_ url: URL) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_LINKID)
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes {
            getattrlist(url.path(percentEncoded: false), &list, $0.baseAddress, $0.count,
                        UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
        }
        guard rc == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }

    func testEveryFieldMatchesLstatAndGetattrlist() async throws {
        let (entries, summary, _) = try await readAll(golden)
        XCTAssertEqual(Set(entries.keys), Set(GoldenName.all))
        XCTAssertEqual(summary.entryCount, GoldenName.all.count)
        XCTAssertEqual(summary.degradedCount, 0)
        XCTAssertFalse(summary.usedFallback)
        for (name, (e, errno)) in entries {
            let url = golden.appending(path: name)
            var st = stat()
            XCTAssertEqual(lstat(url.path(percentEncoded: false), &st), 0, name)
            XCTAssertNil(errno, name)
            XCTAssertEqual(e.fileID, UInt64(st.st_ino), name)
            XCTAssertEqual(e.rowID, linkID(url), name)
            XCTAssertEqual(e.mtime, Self.ns(st.st_mtimespec), name)
            XCTAssertEqual(e.ctime, Self.ns(st.st_birthtimespec), name)
            XCTAssertEqual(e.flags.contains(.bsdHidden), st.st_flags & UInt32(UF_HIDDEN) != 0, name)
            XCTAssertEqual(e.flags.contains(.locked), st.st_flags & UInt32(UF_IMMUTABLE) != 0, name)
            XCTAssertEqual(e.flags.contains(.dotName), name.hasPrefix("."), name)
            XCTAssertEqual(e.flags.contains(.readable), access(url.path(percentEncoded: false), R_OK) == 0 || (st.st_mode & S_IFMT) == S_IFLNK, name)
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                XCTAssertTrue(e.kind == .directory || e.kind == .package, name)
                if access(url.path(percentEncoded: false), R_OK) == 0 {
                    let children = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
                    XCTAssertEqual(e.size, Int64(children.count), "\(name): directory size = entry count")
                }
            case S_IFLNK:
                XCTAssertEqual(e.kind, .symlink, name)
                XCTAssertEqual(e.typeIndex, TypeRegistry.symlinkIndex, name)
                XCTAssertEqual(e.size, Int64(st.st_size), name)
            default:
                XCTAssertTrue(e.kind == .file || e.kind == .alias, name)
                XCTAssertEqual(e.size, Int64(st.st_size), name)
                XCTAssertEqual(e.allocSize, Int64(st.st_blocks) * 512, name)
            }
        }
        let k = { (n: String) in entries[n]!.0 }
        XCTAssertEqual(k(GoldenName.app).kind, .package)
        XCTAssertEqual(k(GoldenName.rtfd).kind, .package)
        XCTAssertEqual(k(GoldenName.dottedFolder).kind, .directory)
        XCTAssertEqual(k(GoldenName.folder).kind, .directory)
        XCTAssertEqual(k(GoldenName.alias).kind, .alias)
        XCTAssertTrue(k(GoldenName.extensionHidden).flags.contains(.extensionHidden))
        XCTAssertTrue(k(GoldenName.executable).flags.contains(.executable))
        XCTAssertFalse(k(GoldenName.plain).flags.contains(.executable))
        XCTAssertFalse(k(GoldenName.readOnly).flags.contains(.writable))
        XCTAssertFalse(k(GoldenName.noAccessFile).flags.contains(.readable))
        XCTAssertTrue(k(GoldenName.hardLinkA).flags.contains(.hasHardLinks))
        XCTAssertNotEqual(k(GoldenName.hardLinkA).rowID, k(GoldenName.hardLinkB).rowID)
        XCTAssertEqual(k(GoldenName.hardLinkA).fileID, k(GoldenName.hardLinkB).fileID)
        XCTAssertEqual(k(GoldenName.long255).nameLen, 255)
        XCTAssertEqual(k(GoldenName.dated).mtime, 1_012_608_000 * 1_000_000_000)
        XCTAssertEqual(TypeRegistry.shared.type(at: k(GoldenName.plain).typeIndex), .plainText)
        XCTAssertTrue(entries.keys.contains { Array($0.unicodeScalars) == Array(GoldenName.nfd.unicodeScalars) },
                      "NFD bytes are delivered as stored")
    }

    func testDirectoriesOnlyListsFoldersNotPackagesOrLinks() async throws {
        var options = ReadOptions()
        options.directoriesOnly = true
        let names = Set(try await readAll(golden, options: options).entries.keys)
        XCTAssertEqual(names, [GoldenName.folder, GoldenName.dottedFolder, GoldenName.noAccessDir])
    }

    func testNoMaterializationReadGivesSameEntries() async throws {
        var options = ReadOptions()
        options.noMaterialization = true
        let a = try await readAll(golden).entries.mapValues { $0.0 }
        let b = try await readAll(golden, options: options).entries.mapValues { $0.0 }
        XCTAssertEqual(a, b)
    }

    func testDirectoryLevelFailures() async throws {
        let cases: [(URL, Int32)] = [
            (golden.appending(path: "missing"), ENOENT),
            (golden.appending(path: GoldenName.plain), ENOTDIR),
            (golden.appending(path: GoldenName.noAccessDir), EACCES),
        ]
        for (url, code) in cases {
            do {
                _ = try await readAll(url)
                XCTFail("\(url.lastPathComponent) should fail")
            } catch let failure as ReadFailure {
                XCTAssertEqual(failure, ReadFailure(code: code, stage: .open), url.lastPathComponent)
            }
        }
    }

    func testEmptyDirectoryCompletesWithoutBatches() async throws {
        let dir = try sandbox.createDirectory("empty")
        let (entries, summary, batches) = try await readAll(dir)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(summary.entryCount, 0)
        XCTAssertEqual(batches, [])
    }

    func testDegradedRecordKeepsRowAndErrno() {
        var builder = RecordBuilder()
        builder.add(.init(name: "half", error: UInt32(EIO), objType: 1, crtime: nil, mtime: nil, finderFlags: nil,
                          flags: nil, userAccess: nil, fileID: nil, allocSize: nil, dataLength: nil, linkID: nil))
        builder.add(.init(name: "whole"))
        var batch = Batch(generation: .initial)
        var converter = RecordConverter(types: TypeRegistry())
        builder.bytes.withUnsafeBytes { raw in
            var c = cfsk_cursor(); var r = cfsk_record()
            cfsk_cursor_init(&c, raw.baseAddress, raw.count, builder.count)
            while cfsk_cursor_next(&c, &r) == CFSK_NEXT_OK { _ = converter.append(r, to: &batch, directoriesOnly: false) }
        }
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.name(at: 0), "half")
        XCTAssertTrue(batch.entries[0].flags.contains(.degraded))
        XCTAssertEqual(batch.errors, [EntryError(index: 0, code: EIO)])
        XCTAssertFalse(batch.entries[1].flags.contains(.degraded))
    }

    func testDatalessAndCustomIconFlagsFromSyntheticRecords() {
        var builder = RecordBuilder()
        builder.add(.init(name: "cloud.pdf", finderFlags: 0x0400, flags: UInt32(bitPattern: SF_DATALESS)))
        var batch = Batch(generation: .initial)
        var converter = RecordConverter(types: TypeRegistry())
        builder.bytes.withUnsafeBytes { raw in
            var c = cfsk_cursor(); var r = cfsk_record()
            cfsk_cursor_init(&c, raw.baseAddress, raw.count, builder.count)
            XCTAssertEqual(cfsk_cursor_next(&c, &r), CFSK_NEXT_OK)
            _ = converter.append(r, to: &batch, directoriesOnly: false)
        }
        XCTAssertTrue(batch.entries[0].flags.contains(.dataless))
        XCTAssertTrue(batch.entries[0].flags.contains(.customIcon))
    }
}
