import Darwin
import Foundation
import MacxFS
import UniformTypeIdentifiers

/// Reads what the Properties window shows (§4.3, §5.8). All reads run on a read lane under `withNoMaterialization`;
/// mode bits, owner, flags, dates and sizes come from `lstat` (the `Entry` record carries no mode, S1 note 4), so a
/// symlink is described, never followed. Errors: `ReadFailure(code: errno, stage: .read)` or the lane's `LaneError`.
public enum PropertiesLoader {
    public static func load(_ url: URL, lanes: LanePool, volume: VolumeID) async throws -> ItemProperties {
        try await lanes.perform(on: volume, .read) { _ in
            try withNoMaterialization { try read(url) }
        }
    }

    /// Files and folders are counted per selected item (packages count as files); `totalSize` includes each folder's
    /// and package's contents, counted like `FolderCounter` (symlinks never followed).
    public static func loadMany(_ urls: [URL], lanes: LanePool, volume: VolumeID) async throws -> MultiProperties {
        try await lanes.perform(on: volume, .read) { context in
            try withNoMaterialization {
                var files = 0, folders = 0
                var total: Int64 = 0
                var locked: [Bool] = [], hidden: [Bool] = [], extensionHidden: [Bool] = [], customIcon: [Bool] = []
                for url in urls {
                    if context.isCancelled { throw LaneError.cancelled }
                    context.heartbeat()
                    let path = url.path(percentEncoded: false)
                    let st = try lstatOrThrow(path)
                    let fresh = URL(filePath: path)
                    let values = try? fresh.resourceValues(forKeys: [.isPackageKey, .hasHiddenExtensionKey])
                    let kind = kind(of: st, values: values)
                    if kind == .directory { folders += 1 } else { files += 1 }
                    if kind == .directory || kind == .package {
                        total += FolderCounter.walk(path, shouldStop: { context.isCancelled },
                                                    heartbeat: { context.heartbeat() })?.bytes ?? 0
                    } else {
                        total += Int64(st.st_size)
                    }
                    locked.append(isLocked(st))
                    hidden.append(st.st_flags & UInt32(UF_HIDDEN) != 0)
                    extensionHidden.append(values?.hasHiddenExtension ?? false)
                    customIcon.append(hasCustomIcon(path))
                }
                if context.isCancelled { throw LaneError.cancelled }
                return MultiProperties(count: urls.count, files: files, folders: folders, totalSize: total,
                                       locked: .of(locked), hidden: .of(hidden), extensionHidden: .of(extensionHidden),
                                       customIcon: .of(customIcon))
            }
        }
    }

    /// Capacity from the `VolumeInfo` (re-read when it has none), free space from the scanner. Never throws: a failed
    /// or unresponsive read leaves the value nil.
    public static func loadVolume(_ volume: VolumeInfo, scanner: any VolumeScanning, lanes: LanePool) async -> VolumeProperties {
        let mountPoint = volume.mountPoint
        let known = volume.totalCapacity
        let read = try? await lanes.perform(on: volume.id, .read) { _ in
            withNoMaterialization { () -> (Int64?, Int64?) in
                let capacity = known ?? (try? mountPoint.resourceValues(forKeys: [.volumeTotalCapacityKey]))?
                    .volumeTotalCapacity.map(Int64.init)
                return (capacity, scanner.availableCapacity(of: mountPoint))
            }
        }
        return VolumeProperties(volume: volume, capacity: read?.0 ?? known, available: read?.1)
    }

    // MARK: lane work

    private static let keys: Set<URLResourceKey> = [
        .localizedNameKey, .localizedTypeDescriptionKey, .contentTypeKey, .isPackageKey, .isAliasFileKey,
        .hasHiddenExtensionKey, .volumeLocalizedNameKey, .volumeNameKey,
    ]

    static func read(_ url: URL) throws -> ItemProperties {
        assertOffMain()
        let path = url.path(percentEncoded: false)
        let st = try lstatOrThrow(path)
        let fresh = URL(filePath: path)                  // no cached resource values from an earlier load
        let values = try? fresh.resourceValues(forKeys: keys)
        let kind = kind(of: st, values: values)
        let isContainer = kind == .directory || kind == .package
        let name = fresh.lastPathComponent
        let mode = UInt16(st.st_mode & 0o7777)
        return ItemProperties(
            url: url,
            name: name,
            displayName: values?.localizedName ?? name,
            kindDescription: values?.localizedTypeDescription ?? "",
            typeIdentifier: values?.contentType?.identifier ?? fallbackType(kind).identifier,
            kind: kind,
            logicalSize: isContainer ? nil : Int64(st.st_size),
            physicalSize: isContainer ? nil : Int64(st.st_blocks) * 512,
            created: date(st.st_birthtimespec),
            modified: date(st.st_mtimespec),
            lastOpened: Xattrs.lastUsedDate(path),
            isLocked: isLocked(st),
            isHidden: st.st_flags & UInt32(UF_HIDDEN) != 0,
            isExtensionHidden: values?.hasHiddenExtension ?? false,
            mode: mode,
            ownerID: st.st_uid,
            groupID: st.st_gid,
            ownerName: PermissionModel.userName(st.st_uid),
            groupName: PermissionModel.groupName(st.st_gid),
            isOwnedByCurrentUser: st.st_uid == geteuid(),
            aclEntries: aclEntries(path),
            inode: st.st_ino,
            volumeName: values?.volumeLocalizedName ?? values?.volumeName ?? "",
            whereFroms: Xattrs.whereFroms(path),
            quarantine: Xattrs.quarantine(path),
            xattrs: Xattrs.list(path),
            hasCustomIcon: hasCustomIcon(path))
    }

    /// kHasCustomIcon in the item's own FinderInfo (never a symlink's target).
    static func hasCustomIcon(_ path: String) -> Bool {
        WorkspaceIconWriter.finderFlags(path) & WorkspaceIconWriter.customIconBit != 0
    }

    /// Extended ACL entries as `acl_to_text` lines (header dropped), read without following a symlink.
    static func aclEntries(_ path: String) -> [String] {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("!#acl") }
    }

    private static func lstatOrThrow(_ path: String) throws -> stat {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ReadFailure(code: errno, stage: .read) }
        return st
    }

    private static func kind(of st: stat, values: URLResourceValues?) -> Kind {
        switch st.st_mode & S_IFMT {
        case S_IFLNK: .symlink
        case S_IFDIR: values?.isPackage == true ? .package : .directory
        case S_IFREG: values?.isAliasFile == true ? .alias : .file
        default: .other
        }
    }

    private static func fallbackType(_ kind: Kind) -> UTType {
        switch kind {
        case .directory: .folder
        case .package: .package
        case .symlink: .symbolicLink
        case .alias: .aliasFile
        case .file, .other: .data
        }
    }

    private static func isLocked(_ st: stat) -> Bool {
        st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0
    }

    private static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}
