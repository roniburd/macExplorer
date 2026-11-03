import Darwin
import Foundation

/// Builds getattrlistbulk-format records by hand (for per-entry errors, missing attributes and
/// malformed input that a real volume won't produce). Layout follows the kernel's packing order.
struct RecordBuilder {
    struct Spec {
        var name: String? = "file.txt"
        var error: UInt32? = nil
        var objType: UInt32? = 1                 // VREG
        var crtime: (Int, Int)? = (1_000, 5)
        var mtime: (Int, Int)? = (2_000, 7)
        var finderFlags: UInt16? = 0
        var flags: UInt32? = 0
        var userAccess: UInt32? = 6
        var fileID: UInt64? = 42
        var entryCount: UInt32? = nil            // directories only
        var allocSize: Int64? = 4_096
        var dataLength: Int64? = 10
        var linkID: UInt64? = 42
    }

    private(set) var bytes: [UInt8] = []
    private(set) var count: UInt32 = 0

    mutating func add(_ s: Spec) {
        var common: UInt32 = UInt32(bitPattern: Int32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS))
        var fixed: [UInt8] = []
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { fixed.append(contentsOf: $0) } }
        if let e = s.error { common |= UInt32(ATTR_CMN_ERROR); put(e) }
        let nameRefAt = fixed.count
        if s.name != nil { common |= UInt32(ATTR_CMN_NAME); put(Int32(0)); put(UInt32(0)) }
        if let t = s.objType { common |= UInt32(ATTR_CMN_OBJTYPE); put(t) }
        if let c = s.crtime { common |= UInt32(ATTR_CMN_CRTIME); put(timespec(tv_sec: c.0, tv_nsec: c.1)) }
        if let m = s.mtime { common |= UInt32(ATTR_CMN_MODTIME); put(timespec(tv_sec: m.0, tv_nsec: m.1)) }
        if let f = s.finderFlags {
            common |= UInt32(ATTR_CMN_FNDRINFO)
            var info = [UInt8](repeating: 0, count: 32)
            info[8] = UInt8(f >> 8); info[9] = UInt8(f & 0xFF)
            fixed.append(contentsOf: info)
        }
        if let f = s.flags { common |= UInt32(ATTR_CMN_FLAGS); put(f) }
        if let a = s.userAccess { common |= UInt32(ATTR_CMN_USERACCESS); put(a) }
        if let id = s.fileID { common |= UInt32(ATTR_CMN_FILEID); put(id) }
        var dir: UInt32 = 0, file: UInt32 = 0, fork: UInt32 = 0
        if let n = s.entryCount { dir |= UInt32(ATTR_DIR_ENTRYCOUNT); put(n) }
        if let a = s.allocSize { file |= UInt32(ATTR_FILE_ALLOCSIZE); put(a) }
        if let d = s.dataLength { file |= UInt32(ATTR_FILE_DATALENGTH); put(d) }
        if let l = s.linkID { fork |= UInt32(ATTR_CMNEXT_LINKID); put(l) }

        let header = 4 + 20
        var record: [UInt8] = []
        let nameBytes: [UInt8] = s.name.map { Array($0.utf8) + [0] } ?? []
        let total = (header + fixed.count + nameBytes.count + 3) & ~3
        withUnsafeBytes(of: UInt32(total)) { record.append(contentsOf: $0) }
        let set = attribute_set_t(commonattr: common, volattr: 0, dirattr: dir, fileattr: file, forkattr: fork)
        withUnsafeBytes(of: set) { record.append(contentsOf: $0) }
        if s.name != nil {
            let refOffset = header + nameRefAt
            let dataOffset = Int32(header + fixed.count - refOffset)
            fixed.replaceSubrange(nameRefAt..<nameRefAt + 4, with: withUnsafeBytes(of: dataOffset) { Array($0) })
            fixed.replaceSubrange(nameRefAt + 4..<nameRefAt + 8, with: withUnsafeBytes(of: UInt32(nameBytes.count)) { Array($0) })
        }
        record += fixed + nameBytes
        record += [UInt8](repeating: 0, count: total - record.count)
        bytes += record
        count += 1
    }

    /// Patches the attrreference of the record starting at `recordStart` (tests of bad name refs).
    mutating func patchNameRef(recordStart: Int, refOffsetInRecord: Int, dataOffset: Int32, length: UInt32) {
        let at = recordStart + refOffsetInRecord
        bytes.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: dataOffset) { Array($0) })
        bytes.replaceSubrange(at + 4..<at + 8, with: withUnsafeBytes(of: length) { Array($0) })
    }
}
