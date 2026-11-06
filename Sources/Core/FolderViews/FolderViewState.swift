import Foundation
import MacxFS

/// The view a folder is shown with, every field resolved (spec §11 Phase 2 + design 2026-11-05 §2): mode, columns,
/// sort, icon size, row density, Group by, and whether folder sizes are calculated. Built field by field by
/// `FolderViewResolver` from the folder's own `FolderViewSettings`, Finder's `.DS_Store`, the built-in rule and
/// `Settings.defaultFolderViewState()`.
public struct FolderViewState: Sendable, Codable, Equatable {
    public var mode: ViewMode
    public var columns: [ColumnSetting]
    public var sort: MacxFS.SortDescriptor
    public var iconSize: IconSize
    public var density: Density
    public var groupBy: GroupBy
    public var calculateFolderSizes: Bool

    public init(mode: ViewMode, columns: [ColumnSetting], sort: MacxFS.SortDescriptor, iconSize: IconSize,
                density: Density, groupBy: GroupBy, calculateFolderSizes: Bool) {
        self.mode = mode
        self.columns = columns
        self.sort = sort
        self.iconSize = iconSize
        self.density = density
        self.groupBy = groupBy
        self.calculateFolderSizes = calculateFolderSizes
    }

    /// The fields of `self` that differ from `old` (what a user change sets for the folder).
    public func changes(from old: FolderViewState) -> FolderViewSettings {
        FolderViewSettings(viewMode: mode == old.mode ? nil : mode, iconSize: iconSize == old.iconSize ? nil : iconSize,
                           density: density == old.density ? nil : density, sort: sort == old.sort ? nil : sort,
                           columns: columns == old.columns ? nil : columns, groupBy: groupBy == old.groupBy ? nil : groupBy,
                           calculateFolderSizes: calculateFolderSizes == old.calculateFolderSizes ? nil : calculateFolderSizes)
    }

    /// Every field set (a full record).
    public var settings: FolderViewSettings {
        FolderViewSettings(viewMode: mode, iconSize: iconSize, density: density, sort: sort, columns: columns,
                           groupBy: groupBy, calculateFolderSizes: calculateFolderSizes)
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
        self.path = Self.standardPath(url)
        self.volume = volume
        self.fileID = fileID
    }

    /// Standardized absolute path without a trailing slash ("/" stays "/").
    public static func standardPath(_ url: URL) -> String {
        var p = url.standardizedFileURL.path(percentEncoded: false)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }

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
