import Foundation
import MacxFS

/// Recursive size of a folder (§11 Phase 2). `isPartial` means some part could not be read (unreadable,
/// vanished, degraded or dataless), so the UI shows the value as a lower bound ("≥ 1.2 MB").
public struct FolderSize: Sendable, Equatable, Codable {
    public var bytes: Int64
    public var allocatedBytes: Int64
    public var files: Int
    public var folders: Int
    public var isPartial: Bool
    public init(bytes: Int64 = 0, allocatedBytes: Int64 = 0, files: Int = 0, folders: Int = 0, isPartial: Bool = false) {
        self.bytes = bytes; self.allocatedBytes = allocatedBytes; self.files = files; self.folders = folders; self.isPartial = isPartial
    }
}

public enum FolderSizeIdentity: Hashable, Sendable { case object(VolumeID, UInt64), path(String) }

public struct FolderSizeKey: Hashable, Sendable {
    public var identity: FolderSizeIdentity
    public var mtime: Int64
    public init(identity: FolderSizeIdentity, mtime: Int64) { self.identity = identity; self.mtime = mtime }
}
