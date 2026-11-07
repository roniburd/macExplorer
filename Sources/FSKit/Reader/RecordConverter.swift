import CFSKit
import Darwin

/// cfsk_record → Entry (§4.2): kind, flags, type index, identity. Shared by bulk, fallback and item reads.
struct RecordConverter {
    // Finder flags (big-endian on disk; cfsk delivers host order).
    static let kIsAlias: UInt16 = 0x8000
    static let kHasCustomIcon: UInt16 = 0x0400
    static let kIsExtensionHidden: UInt16 = 0x0010
    static let VREG: UInt32 = 1, VDIR: UInt32 = 2, VLNK: UInt32 = 5

    let types: TypeRegistry
    /// st_dev of the directory being read. A child reported on another device (a stat'ed mount point) or with
    /// DIR_MNTSTATUS_MNTPOINT (a listed one) is a mount point: its file ID is the covered folder's in a listing
    /// but the mounted volume's root (2 on every APFS/HFS+ volume) in a per-item read, so it gets no object
    /// identity (rowID 0 → name identity) and two mount points never collide (QA round 1).
    var directoryDevice: Int32?
    private var cache: [String: UInt16] = [:]   // "<d|f><ext>" → index; avoids the registry lock per entry

    init(types: TypeRegistry, directoryFD: Int32? = nil) {
        self.types = types
        var st = stat()
        if let directoryFD, fstat(directoryFD, &st) == 0 { directoryDevice = st.st_dev }
    }

    /// Appends the record to `batch`. Returns false if it has no name (dropped).
    mutating func append(_ r: cfsk_record, to batch: inout Batch, directoriesOnly: Bool) -> (appended: Bool, degraded: Bool) {
        guard r.fields & CFSK_HAS_NAME != 0, let namePtr = r.name, r.name_len > 0 else { return (false, false) }
        let name = UnsafeBufferPointer(start: UnsafeRawPointer(namePtr).assumingMemoryBound(to: UInt8.self), count: Int(r.name_len))
        let has = { (bit: UInt32) in r.fields & bit != 0 }
        let isDir = has(CFSK_HAS_OBJTYPE) && r.obj_type == Self.VDIR
        if directoriesOnly && !isDir { return (false, false) }   // cheap pre-filter; packages dropped below

        var flags: EntryFlags = []
        if name.first == UInt8(ascii: ".") { flags.insert(.dotName) }
        if has(CFSK_HAS_FLAGS) {
            if r.bsd_flags & UInt32(UF_HIDDEN) != 0 { flags.insert(.bsdHidden) }
            if r.bsd_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { flags.insert(.locked) }
            if r.bsd_flags & UInt32(bitPattern: SF_DATALESS) != 0 { flags.insert(.dataless) }
        }
        let finder = has(CFSK_HAS_FNDRINFO) ? r.finder_flags : 0
        if finder & Self.kHasCustomIcon != 0 { flags.insert(.customIcon) }
        if finder & Self.kIsExtensionHidden != 0 { flags.insert(.extensionHidden) }
        if has(CFSK_HAS_ACCESSMASK) {
            if r.access_mask & UInt32(R_OK) != 0 { flags.insert(.readable) }
            if r.access_mask & UInt32(W_OK) != 0 { flags.insert(.writable) }
            if r.access_mask & UInt32(X_OK) != 0 && has(CFSK_HAS_OBJTYPE) && r.obj_type == Self.VREG { flags.insert(.executable) }
        }
        let degraded = r.error != 0 || !has(CFSK_HAS_OBJTYPE) || !has(CFSK_HAS_FILEID)
        if degraded { flags.insert(.degraded) }
        if has(CFSK_HAS_LINKID) && has(CFSK_HAS_FILEID) && r.link_id != r.file_id { flags.insert(.hasHardLinks) }

        var kind: Kind
        var typeIndex: UInt16
        switch has(CFSK_HAS_OBJTYPE) ? r.obj_type : 0 {
        case Self.VDIR:
            typeIndex = typeIndexFor(name, isDirectory: true)
            kind = types.isPackage(typeIndex) ? .package : .directory
        case Self.VLNK:
            kind = .symlink
            typeIndex = TypeRegistry.symlinkIndex
        case Self.VREG:
            kind = finder & Self.kIsAlias != 0 ? .alias : .file
            typeIndex = typeIndexFor(name, isDirectory: false)
        default:
            kind = .other
            typeIndex = TypeRegistry.dataIndex
        }
        if directoriesOnly && kind != .directory { return (false, false) }
        let fileID = has(CFSK_HAS_FILEID) ? r.file_id : 0
        let isMountPoint = (has(CFSK_HAS_MOUNTSTATUS) && r.mount_status & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0)
            || (has(CFSK_HAS_DEVID) && directoryDevice != nil && r.dev_id != directoryDevice)
        if isMountPoint { flags.insert(.mountPoint) }
        let rowID = isMountPoint ? 0 : has(CFSK_HAS_LINKID) && r.link_id != 0 ? r.link_id : fileID
        let size: Int64 = isDir ? Int64(r.entry_count) : (has(CFSK_HAS_DATALENGTH) ? r.data_length : 0)
        let entry = Entry(rowID: rowID, fileID: fileID, size: size,
                          allocSize: has(CFSK_HAS_ALLOCSIZE) ? r.alloc_size : 0,
                          mtime: has(CFSK_HAS_MODTIME) ? r.mtime_ns : 0,
                          ctime: has(CFSK_HAS_CRTIME) ? r.crtime_ns : 0,
                          nameOffset: 0, nameLen: 0, kind: kind, flags: flags, typeIndex: typeIndex)
        batch.append(entry, nameBytes: name)
        if r.error != 0 { batch.errors.append(EntryError(index: UInt32(batch.count - 1), code: Int32(bitPattern: r.error))) }
        return (true, degraded)
    }

    private mutating func typeIndexFor(_ name: UnsafeBufferPointer<UInt8>, isDirectory: Bool) -> UInt16 {
        guard let range = fileExtensionRange(name) else { return isDirectory ? TypeRegistry.folderIndex : TypeRegistry.dataIndex }
        let ext = String(decoding: UnsafeBufferPointer(rebasing: name[range]), as: UTF8.self)
        let key = (isDirectory ? "d" : "f") + ext
        if let hit = cache[key] { return hit }
        let index = types.index(forExtension: Substring(ext), isDirectory: isDirectory)
        cache[key] = index
        return index
    }
}
