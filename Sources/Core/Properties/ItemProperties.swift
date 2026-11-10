import Foundation
import MacxFS

/// A checkbox state shared by several items (§5.8 multiple selection).
public enum Tri: Sendable, Equatable {
    case on, off, mixed

    /// `.on` when every value is true, `.off` when none is (or there are none), `.mixed` otherwise.
    static func of(_ values: [Bool]) -> Tri {
        values.isEmpty || !values.contains(true) ? .off : values.allSatisfy { $0 } ? .on : .mixed
    }
}

public struct XattrInfo: Sendable, Equatable {
    public var name: String
    public var size: Int
    public init(name: String, size: Int) { self.name = name; self.size = size }
}

/// `com.apple.quarantine`: "flags;hex seconds since 1970;agent;uuid". `raw` is kept so undo can rewrite it.
public struct QuarantineInfo: Sendable, Equatable {
    public var raw: Data
    public var agentName: String?
    public var date: Date?
    public init(raw: Data, agentName: String?, date: Date?) { self.raw = raw; self.agentName = agentName; self.date = date }
}

/// One item as shown by the Properties window. Read by `PropertiesLoader` on a lane; never follows a symlink.
public struct ItemProperties: Sendable, Equatable {
    public var url: URL
    public var name: String
    public var displayName: String
    public var kindDescription: String
    public var typeIdentifier: String
    public var kind: Kind
    public var logicalSize: Int64?          // nil for folders and packages (FolderCounter counts them)
    public var physicalSize: Int64?
    public var created: Date?
    public var modified: Date?
    public var lastOpened: Date?
    public var isLocked: Bool               // UF_IMMUTABLE or SF_IMMUTABLE
    public var isHidden: Bool               // UF_HIDDEN
    public var isExtensionHidden: Bool
    public var mode: UInt16                 // lstat st_mode & 0o7777 (no file-type bits)
    public var ownerID: UInt32
    public var groupID: UInt32
    public var ownerName: String
    public var groupName: String
    public var isOwnedByCurrentUser: Bool
    public var aclEntries: [String]
    public var inode: UInt64
    public var volumeName: String
    public var whereFroms: [String]
    public var quarantine: QuarantineInfo?
    public var xattrs: [XattrInfo]
    /// The Finder flags' kHasCustomIcon bit (P4-08): Properties offers "Remove Custom Icon".
    public var hasCustomIcon: Bool

    public init(url: URL, name: String, displayName: String, kindDescription: String, typeIdentifier: String, kind: Kind,
                logicalSize: Int64?, physicalSize: Int64?, created: Date?, modified: Date?, lastOpened: Date?,
                isLocked: Bool, isHidden: Bool, isExtensionHidden: Bool, mode: UInt16, ownerID: UInt32, groupID: UInt32,
                ownerName: String, groupName: String, isOwnedByCurrentUser: Bool, aclEntries: [String], inode: UInt64,
                volumeName: String, whereFroms: [String], quarantine: QuarantineInfo?, xattrs: [XattrInfo],
                hasCustomIcon: Bool = false) {
        self.url = url
        self.name = name
        self.displayName = displayName
        self.kindDescription = kindDescription
        self.typeIdentifier = typeIdentifier
        self.kind = kind
        self.logicalSize = logicalSize
        self.physicalSize = physicalSize
        self.created = created
        self.modified = modified
        self.lastOpened = lastOpened
        self.isLocked = isLocked
        self.isHidden = isHidden
        self.isExtensionHidden = isExtensionHidden
        self.mode = mode
        self.ownerID = ownerID
        self.groupID = groupID
        self.ownerName = ownerName
        self.groupName = groupName
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
        self.aclEntries = aclEntries
        self.inode = inode
        self.volumeName = volumeName
        self.whereFroms = whereFroms
        self.quarantine = quarantine
        self.xattrs = xattrs
        self.hasCustomIcon = hasCustomIcon
    }
}

/// A multiple selection (§5.8): "N items (X files, Y folders)", total size, tri-state attributes.
public struct MultiProperties: Sendable, Equatable {
    public var count: Int
    public var files: Int                   // everything that is not a plain folder (packages count as files)
    public var folders: Int
    public var totalSize: Int64             // logical bytes, folders' contents included
    public var locked: Tri
    public var hidden: Tri
    public var extensionHidden: Tri
    /// Which items have a custom icon (P4-08).
    public var customIcon: Tri
    /// How many selected items are symbolic links (the icon well refuses a selection with any: setting an icon
    /// would change the link's target).
    public var symlinks: Int

    public init(count: Int, files: Int, folders: Int, totalSize: Int64, locked: Tri, hidden: Tri, extensionHidden: Tri,
                customIcon: Tri = .off, symlinks: Int = 0) {
        self.count = count
        self.files = files
        self.folders = folders
        self.totalSize = totalSize
        self.locked = locked
        self.hidden = hidden
        self.extensionHidden = extensionHidden
        self.customIcon = customIcon
        self.symlinks = symlinks
    }
}

public struct VolumeProperties: Sendable, Equatable {
    public var volume: VolumeInfo
    public var capacity: Int64?
    public var available: Int64?
    public var used: Int64? {
        guard let capacity, let available else { return nil }
        return max(0, capacity - available)
    }

    public init(volume: VolumeInfo, capacity: Int64?, available: Int64?) {
        self.volume = volume
        self.capacity = capacity
        self.available = available
    }
}
