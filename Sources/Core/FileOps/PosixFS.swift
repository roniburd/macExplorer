import Foundation
import Darwin
import MacxFS

/// Lane-only POSIX helpers. Every function calls assertOffMain(). Symlinks are never followed.
enum PosixFS {
    struct Info: Sendable, Equatable {
        var isDirectory: Bool
        var isSymlink: Bool
        var isRegular: Bool
        var size: Int64
        var allocSize: Int64
        var mode: UInt16
        var flags: UInt32
        var mtime: Date
        var identity: FileIdentity
        var isLocked: Bool { flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 }
        var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
    }

    static func info(_ path: String) -> Info? {
        assertOffMain()
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        return Info(isDirectory: type == S_IFDIR, isSymlink: type == S_IFLNK, isRegular: type == S_IFREG,
                    size: Int64(st.st_size), allocSize: Int64(st.st_blocks) * 512, mode: UInt16(st.st_mode & 0o7777),
                    flags: st.st_flags,
                    mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9),
                    identity: FileIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino))
    }

    static func exists(_ path: String) -> Bool { info(path) != nil }

    /// 0 or errno.
    static func rename(_ from: String, _ to: String) -> Int32 {
        assertOffMain()
        return Darwin.rename(from, to) == 0 ? 0 : errno
    }

    /// Clears UF_IMMUTABLE on `path` and (when a directory) everything under it, without following links.
    static func clearImmutable(_ path: String, recursive: Bool = true) {
        assertOffMain()
        guard recursive, let i = info(path), i.isDirectory else {
            if let i = info(path), i.flags & UInt32(UF_IMMUTABLE) != 0 { _ = lchflags(path, i.flags & ~UInt32(UF_IMMUTABLE)) }
            return
        }
        walk(path) { p, _ in
            if let i = info(p), i.flags & UInt32(UF_IMMUTABLE) != 0 { _ = lchflags(p, i.flags & ~UInt32(UF_IMMUTABLE)) }
            if let i = info(p), i.isDirectory, i.mode & 0o700 != 0o700 { _ = chmod(p, mode_t(i.mode | 0o700)) }
            return true
        }
    }

    /// chmod that never follows a symlink (a link's own mode changes, never its target's). 0 or errno.
    static func setMode(_ path: String, _ mode: UInt16) -> Int32 {
        assertOffMain()
        return fchmodat(AT_FDCWD, path, mode_t(mode & 0o7777), AT_SYMLINK_NOFOLLOW) == 0 ? 0 : errno
    }

    /// Recursive delete of a file or tree (removefile). `unlock` first clears uchg. 0 or errno.
    static func removeTree(_ path: String, unlock: Bool = false) -> Int32 {
        assertOffMain()
        if unlock { clearImmutable(path) }
        return removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 ? 0 : errno
    }

    /// Mount point (f_mntonname) of the volume holding `path`.
    static func mountPoint(of path: String) -> String? {
        assertOffMain()
        var sfs = statfs()
        guard statfs(path, &sfs) == 0 else { return nil }
        return withUnsafeBytes(of: &sfs.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Pre-order fts walk (FTS_PHYSICAL | FTS_NOCHDIR), siblings in byte order of their names (deterministic plans).
    /// `body(path, entry)` returns false to skip a directory's contents.
    static func walk(_ root: String, _ body: (String, UnsafeMutablePointer<FTSENT>) -> Bool) {
        assertOffMain()
        guard let cRoot = strdup(root) else { return }
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, byName) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_DP { continue }
            let path = String(cString: ent.pointee.fts_path)
            if !body(path, ent), info == FTS_D { fts_set(fts, ent, FTS_SKIP) }
        }
    }

    /// fts_name is a flexible array member, so it is read in place through its offset, never copied.
    private static let byName: @convention(c) (UnsafeMutablePointer<UnsafePointer<FTSENT>?>?,
                                                UnsafeMutablePointer<UnsafePointer<FTSENT>?>?) -> Int32 = { a, b in
        guard let a = a?.pointee, let b = b?.pointee, let off = MemoryLayout<FTSENT>.offset(of: \.fts_name) else { return 0 }
        return strcmp((UnsafeRawPointer(a) + off).assumingMemoryBound(to: CChar.self),
                      (UnsafeRawPointer(b) + off).assumingMemoryBound(to: CChar.self))
    }

    /// Item count (every entry, links counted once) and total logical bytes of regular files. Used by move verification.
    static func treeStats(_ root: String) -> (items: Int, bytes: Int64) {
        var items = 0
        var bytes: Int64 = 0
        walk(root) { _, ent in
            items += 1
            if Int32(ent.pointee.fts_info) == FTS_F { bytes += Int64(ent.pointee.fts_statp.pointee.st_size) }
            return true
        }
        return (items, bytes)
    }
}
