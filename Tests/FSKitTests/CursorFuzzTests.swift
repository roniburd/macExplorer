import CFSKit
import Darwin
import Foundation
import XCTest

final class CursorFuzzTests: XCTestCase {
    /// Parses every record from an exact-size heap copy (so ASan flags any overread); returns
    /// (ok, dropped, truncated). Never more than `count` + 1 calls.
    private func parseAll(_ bytes: [UInt8], count: UInt32) -> (ok: Int, dropped: Int, truncated: Bool) {
        let size = bytes.count
        let heap = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 1)
        defer { heap.deallocate() }
        bytes.withUnsafeBytes { if size > 0 { heap.copyMemory(from: $0.baseAddress!, byteCount: size) } }
        var cursor = cfsk_cursor()
        cfsk_cursor_init(&cursor, heap, size, count)
        var record = cfsk_record()
        var ok = 0, dropped = 0, calls = 0
        while true {
            calls += 1
            precondition(calls <= Int(count) + 1, "cursor did not terminate")
            switch cfsk_cursor_next(&cursor, &record) {
            case CFSK_NEXT_OK:
                ok += 1
                if record.fields & CFSK_HAS_NAME != 0 {
                    let base = UnsafeRawPointer(heap), start = UnsafeRawPointer(record.name!)
                    precondition(start >= base && start + Int(record.name_len) <= base + size, "name outside buffer")
                    _ = UnsafeRawBufferPointer(start: start, count: Int(record.name_len)).reduce(0, &+)   // touch every byte
                }
            case CFSK_NEXT_DROPPED: dropped += 1
            case CFSK_NEXT_TRUNCATED: return (ok, dropped, true)
            default: return (ok, dropped, false)
            }
        }
    }

    func testWellFormedRecordsParse() {
        var b = RecordBuilder()
        b.add(.init())
        b.add(.init(name: "dir", objType: 2, entryCount: 3, allocSize: nil, dataLength: nil))
        let r = parseAll(b.bytes, count: b.count)
        XCTAssertEqual(r.ok, 2); XCTAssertEqual(r.dropped, 0); XCTAssertFalse(r.truncated)
    }

    func testRandomBuffersNeverCrash() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100_000 {
            let n = Int.random(in: 0...512, using: &rng)
            var bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if n >= 4, Bool.random(using: &rng) {   // plausible length prefix makes the parser go deeper
                let len = UInt32.random(in: 24...UInt32(max(24, n)), using: &rng)
                withUnsafeBytes(of: len) { bytes.replaceSubrange(0..<4, with: $0) }
            }
            _ = parseAll(bytes, count: UInt32.random(in: 0...64, using: &rng))
        }
    }

    func testEveryTruncationOfValidBufferIsSafe() {
        var b = RecordBuilder()
        for i in 0..<20 { b.add(.init(name: "name-\(i)-" + String(repeating: "é", count: i))) }
        for cut in 0...b.bytes.count {
            let r = parseAll(Array(b.bytes.prefix(cut)), count: b.count)
            XCTAssertLessThanOrEqual(r.ok, 20)
        }
    }

    func testByteFlipsOfValidBufferAreSafe() {
        var b = RecordBuilder()
        for i in 0..<8 { b.add(.init(name: "f\(i).txt")) }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100_000 {
            var bytes = b.bytes
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = parseAll(bytes, count: b.count)
        }
    }

    func testNameReferenceOutsideRecordIsDropped() {
        var b = RecordBuilder()
        b.add(.init(name: "a.txt"))
        b.add(.init(name: "b.txt"))
        // name ref of record 0 sits right after length + attribute_set_t (no error field)
        b.patchNameRef(recordStart: 0, refOffsetInRecord: 24, dataOffset: 10_000, length: 6)
        let r = parseAll(b.bytes, count: b.count)
        XCTAssertEqual(r.ok, 1, "the bad record is dropped, the next one still parses")
        XCTAssertEqual(r.dropped, 1)
    }

    func testLengthLargerThanBufferStopsWithTruncated() {
        var b = RecordBuilder()
        b.add(.init())
        var bytes = b.bytes
        withUnsafeBytes(of: UInt32(bytes.count + 100)) { bytes.replaceSubrange(0..<4, with: $0) }
        let r = parseAll(bytes, count: 1)
        XCTAssertEqual(r.ok, 0); XCTAssertTrue(r.truncated)
    }

    func testPerEntryErrorKeepsValidFields() {
        var b = RecordBuilder()
        b.add(.init(name: "broken", error: UInt32(EACCES), objType: 1, crtime: nil, mtime: nil, finderFlags: nil,
                    flags: nil, userAccess: nil, fileID: 77, allocSize: nil, dataLength: nil, linkID: nil))
        b.bytes.withUnsafeBytes { raw in
            var c = cfsk_cursor(); var r = cfsk_record()
            cfsk_cursor_init(&c, raw.baseAddress, raw.count, b.count)
            XCTAssertEqual(cfsk_cursor_next(&c, &r), CFSK_NEXT_OK)
            XCTAssertEqual(r.error, UInt32(EACCES))
            XCTAssertEqual(r.fields, CFSK_HAS_ERROR | CFSK_HAS_NAME | CFSK_HAS_OBJTYPE | CFSK_HAS_FILEID)
            XCTAssertEqual(r.file_id, 77)
            XCTAssertEqual(String(decoding: UnsafeRawBufferPointer(start: r.name, count: Int(r.name_len)), as: UTF8.self), "broken")
        }
    }
}
