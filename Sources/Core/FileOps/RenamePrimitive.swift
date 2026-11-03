import Foundation
import Darwin
import MacxFS

enum RenameOutcome: Sendable, Equatable { case renamed, exists, crossDevice, failed(Int32) }
enum InPlaceRename: Sendable, Equatable { case applied, needsTwoStep, occupied, failed(Int32) }

/// §6.3 rename primitive. Same vs cross volume is decided by callers with st_dev (VolumeIdentity).
enum RenamePrimitive {
    /// renamex_np(RENAME_EXCL); without renameExcl, or on ENOTSUP/EINVAL, lstat check + rename(2)
    /// (the small race against other processes is accepted; per-volume FIFO covers our own jobs).
    static func rename(_ from: String, _ to: String, renameExcl: Bool) -> RenameOutcome {
        assertOffMain()
        if renameExcl {
            if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return .renamed }
            let e = errno
            switch e {
            case EEXIST: return .exists
            case EXDEV: return .crossDevice
            case ENOTSUP, EINVAL: break
            default: return .failed(e)
            }
        }
        if PosixFS.exists(to) { return .exists }
        if Darwin.rename(from, to) == 0 { return .renamed }
        let e = errno
        switch e {
        case EXDEV: return .crossDevice
        case EEXIST, ENOTEMPTY: return .exists
        default: return .failed(e)
        }
    }

    /// The new name designates the same file: normalization-only, or case-only on a case-insensitive volume.
    static func isSameItemRename(_ old: String, _ new: String, caseSensitive: Bool) -> Bool {
        guard Array(old.utf8) != Array(new.utf8) else { return false }
        if NameNormalizer.nfc(old) == NameNormalizer.nfc(new) { return true }
        return !caseSensitive && NameNormalizer.sameName(old, new, caseSensitive: false)
    }

    /// Plain rename(2) (atomic on APFS/HFS+), then read the name back. Volumes that reject it or keep
    /// the old spelling (some SMB, exFAT, FAT) need the journaled two-step rename.
    /// `.occupied`: `to` exists and is not `from` (distinct files on disk), so rename(2) would replace it.
    static func renameInPlace(_ from: String, _ to: String) -> InPlaceRename {
        assertOffMain()
        if let existing = PosixFS.info(to), existing.identity != PosixFS.info(from)?.identity { return .occupied }
        if Darwin.rename(from, to) != 0 {
            let e = errno
            switch e {
            case ENOENT, EACCES, EPERM, EROFS, ENAMETOOLONG: return .failed(e)
            default: return .needsTwoStep
            }
        }
        let dir = (to as NSString).deletingLastPathComponent
        let name = (to as NSString).lastPathComponent
        return directory(dir, containsExactly: name) ? .applied : .needsTwoStep
    }

    /// The name as stored in `dir` for `name`: the entry with exactly its bytes, else the first canonically equal
    /// one (a URL can carry another normalization than the disk). nil = no such entry.
    static func onDiskName(in dir: String, matching name: String) -> String? {
        assertOffMain()
        guard let d = opendir(dir) else { return nil }
        defer { closedir(d) }
        let target = Array(name.utf8)
        var equivalent: String?
        while let ent = readdir(d) {
            let len = Int(ent.pointee.d_namlen)
            let bytes = withUnsafeBytes(of: &ent.pointee.d_name) { Array($0.prefix(len)) }
            if bytes == target { return name }
            if equivalent == nil {
                let s = String(decoding: bytes, as: UTF8.self)
                if s == name { equivalent = s }          // String == is canonical equivalence
            }
        }
        return equivalent
    }

    /// readdir byte comparison (no normalization, no case folding).
    static func directory(_ dir: String, containsExactly name: String) -> Bool {
        assertOffMain()
        guard let d = opendir(dir) else { return false }
        defer { closedir(d) }
        let target = Array(name.utf8)
        while let ent = readdir(d) {
            let len = Int(ent.pointee.d_namlen)
            let match = withUnsafeBytes(of: &ent.pointee.d_name) { raw in
                len == target.count && raw.prefix(len).elementsEqual(target)
            }
            if match { return true }
        }
        return false
    }
}
