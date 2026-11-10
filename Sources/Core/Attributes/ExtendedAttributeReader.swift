import Darwin
import Foundation
import MacxFS

/// Synchronous batch read of extended attributes for names in one directory (lane work, P2-15). Stats with
/// `AT_SYMLINK_NOFOLLOW` and reads xattrs with `XATTR_NOFOLLOW`, so a symlink's own attributes are shown and its
/// target is never touched. Names that no longer exist are left out of the result.
public enum ExtendedAttributeReader {
    public static func read(names: [String], in directory: URL, wanted: ExtendedAttributeSet,
                            owners: OwnerNameCache) -> [String: ExtendedAttributes] {
        assertOffMain()
        return withNoMaterialization {
            let dirPath = directory.standardizedFileURL.path(percentEncoded: false)
            let dirfd = open(dirPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard dirfd >= 0 else { return [:] }
            defer { close(dirfd) }
            let base = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
            var out: [String: ExtendedAttributes] = [:]
            out.reserveCapacity(names.count)
            for name in names {
                var st = stat()
                guard !name.contains("/"), fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                var a = ExtendedAttributes(loaded: wanted)
                if wanted.contains(.permissions) { a.mode = UInt16(st.st_mode) }
                if wanted.contains(.owner) { a.ownerID = st.st_uid; a.ownerName = owners.name(for: st.st_uid) }
                let path = base + name
                if wanted.contains(.tags) { a.tags = Xattrs.read(path, FinderMetadata.tagsXattr).map(FinderMetadata.parseTags) ?? [] }
                if wanted.contains(.comments) {
                    a.comment = Xattrs.read(path, FinderMetadata.commentXattr).flatMap(FinderMetadata.parseComment)
                }
                if wanted.contains(.lastOpened) {
                    a.lastOpened = Xattrs.read(path, FinderMetadata.lastUsedXattr).flatMap(FinderMetadata.parseLastUsed)
                }
                out[name] = a
            }
            return out
        }
    }
}
