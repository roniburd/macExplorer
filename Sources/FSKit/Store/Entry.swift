public enum Kind: UInt8, Sendable, Codable { case file, directory, symlink, package, alias, other }

public struct EntryFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let dotName         = EntryFlags(rawValue: 1 << 0)   // name starts with "."
    public static let bsdHidden       = EntryFlags(rawValue: 1 << 1)   // UF_HIDDEN
    public static let locked          = EntryFlags(rawValue: 1 << 2)   // UF_IMMUTABLE or SF_IMMUTABLE
    public static let dataless        = EntryFlags(rawValue: 1 << 3)   // SF_DATALESS (cloud badge; never opened)
    public static let customIcon      = EntryFlags(rawValue: 1 << 4)   // finder kHasCustomIcon
    public static let degraded        = EntryFlags(rawValue: 1 << 5)   // per-entry ATTR_CMN_ERROR or missing attrs
    public static let extensionHidden = EntryFlags(rawValue: 1 << 6)   // finder kIsExtensionHidden
    public static let executable      = EntryFlags(rawValue: 1 << 7)   // access mask X_OK on a regular file
    public static let readable        = EntryFlags(rawValue: 1 << 8)   // access mask R_OK
    public static let writable        = EntryFlags(rawValue: 1 << 9)   // access mask W_OK
    public static let hasHardLinks    = EntryFlags(rawValue: 1 << 10)  // linkID != fileID
    public var isHidden: Bool { !isDisjoint(with: [.dotName, .bsdHidden]) }
}

public struct Entry: Sendable, Equatable {
    public var rowID: UInt64        // ATTR_CMNEXT_LINKID, else fileID
    public var fileID: UInt64       // inode
    public var size: Int64          // logical bytes; for directories: ATTR_DIR_ENTRYCOUNT (UI shows "--")
    public var allocSize: Int64
    public var mtime: Int64         // ns since 1970
    public var ctime: Int64         // creation, ns since 1970
    public var nameOffset: UInt32   // into the owning arena (Batch.names or EntryStore.names)
    public var nameLen: UInt16
    public var kind: Kind
    public var flags: EntryFlags
    public var typeIndex: UInt16    // TypeRegistry index
    public init(rowID: UInt64, fileID: UInt64, size: Int64, allocSize: Int64, mtime: Int64, ctime: Int64,
                nameOffset: UInt32, nameLen: UInt16, kind: Kind, flags: EntryFlags, typeIndex: UInt16) {
        self.rowID = rowID
        self.fileID = fileID
        self.size = size
        self.allocSize = allocSize
        self.mtime = mtime
        self.ctime = ctime
        self.nameOffset = nameOffset
        self.nameLen = nameLen
        self.kind = kind
        self.flags = flags
        self.typeIndex = typeIndex
    }
    public var isFolderForSorting: Bool { kind == .directory }   // packages sort as files
}
