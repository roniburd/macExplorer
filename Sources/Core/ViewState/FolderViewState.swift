import Foundation
import MacxFS

/// One folder's view (spec §11 Phase 2): mode, columns, sort, icon size, Group by, and whether folder sizes are
/// calculated. Folders without a saved record follow `Settings.defaultFolderViewState()`.
public struct FolderViewState: Sendable, Codable, Equatable {
    public var mode: ViewMode
    public var columns: [ColumnSetting]
    public var sort: MacxFS.SortDescriptor
    public var iconSize: IconSize
    public var groupBy: GroupBy
    public var calculateFolderSizes: Bool

    public init(mode: ViewMode, columns: [ColumnSetting], sort: MacxFS.SortDescriptor, iconSize: IconSize,
                groupBy: GroupBy, calculateFolderSizes: Bool) {
        self.mode = mode
        self.columns = columns
        self.sort = sort
        self.iconSize = iconSize
        self.groupBy = groupBy
        self.calculateFolderSizes = calculateFolderSizes
    }
}

public enum FolderViewKey: Hashable, Sendable, Codable {
    /// An `idStable` volume with a "uuid:" `VolumeID`: survives renames and moves within the volume.
    case object(volumeUUID: String, fileID: UInt64)
    /// NFC; lowercased when the volume is case-insensitive (or unknown).
    case path(String)
}

/// Where a folder is and, when known, what it is. Pure: no file-system calls.
public struct FolderViewLocator: Sendable, Equatable {
    /// Standardized, no trailing slash ("/" stays "/").
    public var path: String
    public var volume: VolumeInfo?
    public var fileID: UInt64?

    public init(url: URL, volume: VolumeInfo?, fileID: UInt64?) {
        var p = url.standardizedFileURL.path(percentEncoded: false)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        self.path = p
        self.volume = volume
        self.fileID = fileID
    }

    public var objectKey: FolderViewKey? {
        guard let volume, volume.capabilities.idStable, volume.id.raw.hasPrefix("uuid:"), let fileID else { return nil }
        let uuid = String(volume.id.raw.dropFirst("uuid:".count))
        guard !uuid.isEmpty else { return nil }
        return .object(volumeUUID: uuid, fileID: fileID)
    }

    public var pathKey: FolderViewKey {
        .path(NameNormalizer.identityName(path, caseSensitive: volume?.capabilities.caseSensitive ?? false))
    }

    public var primaryKey: FolderViewKey { objectKey ?? pathKey }
}
