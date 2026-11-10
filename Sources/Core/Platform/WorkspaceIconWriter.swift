import AppKit
import Darwin
import MacxFS

/// A failure of `WorkspaceIconWriter`, as an errno.
public struct IconWriteError: Error, Sendable, Equatable, ErrnoCarrying {
    public var code: Int32
    public init(code: Int32) { self.code = code }
    var errnoCode: Int32 { code }
}

/// How macOS stores custom icons, which is what this reads back:
/// - files: an `'icns'` resource with ID −16455 in the resource fork (xattr `com.apple.ResourceFork`), plus the
///   `kHasCustomIcon` bit (0x0400) in the Finder flags (bytes 8–9, big-endian, of `com.apple.FinderInfo`);
/// - folders: the hidden file `Icon\r` inside the folder carries the resource fork; the folder's FinderInfo has the bit.
/// Writing goes through `NSWorkspace.setIcon(_:forFile:options:)` (safe off the main thread; nil removes). Reading
/// parses the resource fork, because `NSWorkspace.icon(forFile:)` returns the composed icon, not the stored one.
/// Symbolic links are refused with ENOTSUP (setIcon would write onto the link's target).
public struct WorkspaceIconWriter: CustomIconWriting {
    public init() {}
    static let customIconBit: UInt16 = 0x0400
    static let iconResourceID: Int16 = -16455
    static let folderIconFile = "Icon\r"

    public func currentCustomIcon(_ url: URL) throws -> IconImageData? {
        assertOffMain()
        let path = url.path(percentEncoded: false)
        var st = stat()
        guard lstat(path, &st) == 0 else { throw IconWriteError(code: errno) }
        guard Self.finderFlags(path) & Self.customIconBit != 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let carrier = isDir ? url.appending(path: Self.folderIconFile).path(percentEncoded: false) : path
        guard let fork = Self.xattr(carrier, "com.apple.ResourceFork"),
              let icns = ResourceFork.resource(type: "icns", id: Self.iconResourceID, in: fork) else { return nil }
        return IconImageData(bytes: icns)
    }

    public func setIcon(_ data: IconImageData?, for url: URL) throws {
        assertOffMain()
        let path = url.path(percentEncoded: false)
        var st = stat()
        guard lstat(path, &st) == 0 else { throw IconWriteError(code: errno) }
        // NSWorkspace.setIcon follows symlinks: it would change the link's target (any writable file, maybe outside
        // the selection), and undo, which reads the link itself, could never take it back. Links are refused.
        guard (st.st_mode & S_IFMT) != S_IFLNK else { throw IconWriteError(code: ENOTSUP) }
        var image: NSImage?
        if let data {
            guard data.isDecodableImage, let decoded = NSImage(data: data.bytes) else { throw IconWriteError(code: EINVAL) }
            image = decoded
        }
        guard NSWorkspace.shared.setIcon(image, forFile: path, options: []) else {
            // setIcon reports only Bool; recover the cause the way Finder would hit it.
            if lstat(path, &st) != 0 { throw IconWriteError(code: errno) }
            if st.st_flags & UInt32(UF_IMMUTABLE) != 0 { throw IconWriteError(code: EPERM) }
            throw IconWriteError(code: access(path, W_OK) == 0 ? EIO : EACCES)
        }
    }

    static func finderFlags(_ path: String) -> UInt16 {
        guard let d = xattr(path, "com.apple.FinderInfo"), d.count >= 10 else { return 0 }
        return UInt16(d[d.startIndex + 8]) << 8 | UInt16(d[d.startIndex + 9])
    }

    /// The whole xattr, or nil when it is missing or unreadable. Never follows a symlink.
    static func xattr(_ path: String, _ name: String) -> Data? {
        while true {
            let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard n > 0 else { return nil }
            var b = [UInt8](repeating: 0, count: n)
            let read = getxattr(path, name, &b, n, 0, XATTR_NOFOLLOW)
            if read < 0 && errno == ERANGE { continue }       // grew between the two calls
            return read > 0 ? Data(b.prefix(read)) : nil
        }
    }
}

/// Minimal classic resource-fork reader (Inside Macintosh: More Macintosh Toolbox, "Resource Manager").
/// Every offset is bounds-checked: a truncated or malformed fork yields nil, never a trap.
enum ResourceFork {
    static func resource(type: String, id: Int16, in fork: Data) -> Data? {
        let bytes = [UInt8](fork)
        func u32(_ o: Int) -> Int? {
            o >= 0 && o + 4 <= bytes.count ? Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3]) : nil
        }
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= bytes.count ? Int(bytes[o]) << 8 | Int(bytes[o + 1]) : nil }
        let wanted = Array(type.utf8)
        guard wanted.count == 4, let dataOffset = u32(0), let mapOffset = u32(4),
              let typeListOffset = u16(mapOffset + 24) else { return nil }
        let typeList = mapOffset + typeListOffset
        guard let typeCountMinus1 = u16(typeList), typeCountMinus1 != 0xFFFF else { return nil }
        for t in 0...typeCountMinus1 {
            let entry = typeList + 2 + t * 8
            guard entry + 8 <= bytes.count, let countMinus1 = u16(entry + 4), let refOffset = u16(entry + 6) else { return nil }
            guard Array(bytes[entry..<entry + 4]) == wanted, countMinus1 != 0xFFFF else { continue }
            for r in 0...countMinus1 {
                let ref = typeList + refOffset + r * 12
                guard let rid = u16(ref), let attrsAndOffset = u32(ref + 4) else { return nil }
                guard Int16(truncatingIfNeeded: rid) == id else { continue }
                let start = dataOffset + (attrsAndOffset & 0x00FF_FFFF)
                guard let length = u32(start), start + 4 + length <= bytes.count else { return nil }
                return Data(bytes[(start + 4)..<(start + 4 + length)])
            }
        }
        return nil
    }
}
