import CFSKit
import Darwin
import Foundation
import MacxFixtures
import XCTest

final class CFSKitTests: XCTestCase {
    private var sandbox: Sandbox!
    private var golden: URL!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        golden = try FixtureTree.golden(in: sandbox)
    }

    private func bulkRecords(_ dir: URL) throws -> [String: cfsk_record] {
        let fd = open(dir.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        defer { close(fd) }
        let size = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var result: [String: cfsk_record] = [:]
        while true {
            let n = cfsk_bulk_read(fd, buffer, size)
            XCTAssertGreaterThanOrEqual(n, 0, "errno \(errno)")
            if n <= 0 { break }
            var cursor = cfsk_cursor()
            cfsk_cursor_init(&cursor, buffer, size, UInt32(n))
            var record = cfsk_record()
            while true {
                let rc = cfsk_cursor_next(&cursor, &record)
                if rc == CFSK_NEXT_END || rc == CFSK_NEXT_TRUNCATED { XCTAssertEqual(rc, CFSK_NEXT_END); break }
                XCTAssertEqual(rc, CFSK_NEXT_OK)
                let name = String(decoding: UnsafeRawBufferPointer(start: record.name, count: Int(record.name_len)), as: UTF8.self)
                record.name = nil   // pointer dies with the buffer
                result[name] = record
            }
        }
        return result
    }

    func testBulkReadReturnsEveryEntryWithLstatFields() throws {
        let records = try bulkRecords(golden)
        XCTAssertEqual(Set(records.keys), Set(GoldenName.all))
        for (name, r) in records {
            var st = stat()
            XCTAssertEqual(lstat(golden.appending(path: name).path(percentEncoded: false), &st), 0, name)
            XCTAssertEqual(r.error, 0, name)
            XCTAssertEqual(r.file_id, UInt64(st.st_ino), name)
            XCTAssertEqual(r.bsd_flags, st.st_flags, name)
            XCTAssertEqual(r.mtime_ns, Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), name)
            XCTAssertEqual(r.crtime_ns, Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec), name)
            if (st.st_mode & S_IFMT) == S_IFDIR {
                XCTAssertEqual(r.obj_type, 2, name)       // VDIR
                XCTAssertNotEqual(r.fields & CFSK_HAS_ENTRYCOUNT, 0, name)
                XCTAssertEqual(r.fields & CFSK_HAS_DATALENGTH, 0, name)
            } else {
                XCTAssertEqual(r.data_length, Int64(st.st_size), name)
                XCTAssertEqual(r.alloc_size, Int64(st.st_blocks) * 512, name)
                XCTAssertEqual(r.fields & CFSK_HAS_ENTRYCOUNT, 0, name)
            }
            XCTAssertEqual(r.obj_type == 5, (st.st_mode & S_IFMT) == S_IFLNK, name)   // VLNK
        }
        XCTAssertEqual(records[GoldenName.folder]?.entry_count, 3)
        XCTAssertEqual(records[GoldenName.locked]?.access_mask, UInt32(R_OK), "uchg: read only")
        XCTAssertEqual(records[GoldenName.noAccessFile]?.access_mask, 0)
        XCTAssertEqual(records[GoldenName.executable].map { $0.access_mask & UInt32(X_OK) }, UInt32(X_OK))
        XCTAssertEqual(records[GoldenName.alias].map { $0.finder_flags & 0x8000 }, 0x8000, "kIsAlias")
        XCTAssertEqual(records[GoldenName.alias]?.finder_type, 0x616c_6973, "'alis'")
        XCTAssertEqual(records[GoldenName.extensionHidden].map { $0.finder_flags & 0x0010 }, 0x0010, "kIsExtensionHidden")
        let a = try XCTUnwrap(records[GoldenName.hardLinkA]), b = try XCTUnwrap(records[GoldenName.hardLinkB])
        XCTAssertEqual(a.file_id, b.file_id)
        XCTAssertNotEqual(a.link_id, b.link_id, "ATTR_CMNEXT_LINKID distinguishes hard links")
        XCTAssertEqual(records[GoldenName.plain]?.link_id, records[GoldenName.plain]?.file_id)
    }

    func testStatAtMatchesBulkExceptAbsentFinderInfo() throws {
        let records = try bulkRecords(golden)
        let fd = open(golden.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 2048)
        for (name, bulk) in records {
            var single = cfsk_record()
            let rc = buffer.withUnsafeMutableBytes { cfsk_stat_at(fd, name, $0.baseAddress, $0.count, &single) }
            XCTAssertEqual(rc, 0, "\(name) errno \(errno)")
            // getattrlist omits all-zero Finder info that getattrlistbulk returns as zeros.
            XCTAssertEqual(single.fields | CFSK_HAS_FNDRINFO, bulk.fields | CFSK_HAS_FNDRINFO, name)
            XCTAssertEqual(single.finder_flags, bulk.finder_flags, name)
            XCTAssertEqual(single.file_id, bulk.file_id, name)
            XCTAssertEqual(single.link_id, bulk.link_id, name)
            XCTAssertEqual(single.data_length, bulk.data_length, name)
            XCTAssertEqual(single.alloc_size, bulk.alloc_size, name)
            XCTAssertEqual(single.entry_count, bulk.entry_count, name)
            XCTAssertEqual(single.mtime_ns, bulk.mtime_ns, name)
            XCTAssertEqual(single.access_mask, bulk.access_mask, name)
        }
        var single = cfsk_record()
        let rc = buffer.withUnsafeMutableBytes { cfsk_stat_at(fd, "nope", $0.baseAddress, $0.count, &single) }
        XCTAssertEqual(rc, -1); XCTAssertEqual(errno, ENOENT)
    }

    func testBulkReadOnUnreadableDirectoryFailsAtOpen() {
        let fd = open(golden.appending(path: GoldenName.noAccessDir).path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
        XCTAssertEqual(fd, -1); XCTAssertEqual(errno, EACCES)
    }

    func testMaterializationPolicyIsThreadScopedAndRestored() {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, scope = IOPOL_SCOPE_THREAD
        let before = getiopolicy_np(type, scope)
        var previous: Int32 = -1
        XCTAssertEqual(cfsk_materialize_off(&previous), 0)
        XCTAssertEqual(previous, before)
        XCTAssertEqual(getiopolicy_np(type, scope), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertEqual(cfsk_materialize_restore(previous), 0)
        XCTAssertEqual(getiopolicy_np(type, scope), before)
    }

    func testVolumeCapabilitiesOfTempVolume() {
        var caps = cfsk_volcaps()
        XCTAssertEqual(cfsk_volume_caps(sandbox.root.path(percentEncoded: false), &caps), 0)
        XCTAssertEqual(caps.persistent_ids, 1, "APFS has persistent object IDs")
        XCTAssertEqual(caps.rename_excl, 1)
        XCTAssertEqual(caps.clone, 1)
        XCTAssertEqual(cfsk_volume_caps("/nonexistent-\(UUID().uuidString)", &caps), -1)
    }

    func testVolumeCapabilitiesOfExFATImage() throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let image = try DiskImage.create(in: sandbox, format: .exfat, sizeMB: 16)
        defer { try? image.detach() }
        var caps = cfsk_volcaps()
        XCTAssertEqual(cfsk_volume_caps(image.mountPoint.path(percentEncoded: false), &caps), 0)
        XCTAssertEqual(caps.persistent_ids, 0)
        XCTAssertEqual(caps.clone, 0)
        XCTAssertEqual(caps.case_sensitive, 0)
    }
}
