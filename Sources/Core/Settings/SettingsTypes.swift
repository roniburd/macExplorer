import Foundation
import MacxFS

public enum ViewMode: String, Sendable, Codable, CaseIterable { case details, icons }

public enum IconSize: String, Sendable, Codable, CaseIterable {
    case small, medium, large
    public var points: Double {
        switch self {
        case .small: 32
        case .medium: 64
        case .large: 128
        }
    }
}

public enum Density: String, Sendable, Codable, CaseIterable {
    case compact, regular, comfortable
    public var rowHeight: Double {
        switch self {
        case .compact: 20
        case .regular: 24
        case .comfortable: 30
        }
    }
}

public enum ColumnID: String, Sendable, Codable, CaseIterable {
    case name, dateModified, size, kind, dateCreated, fileExtension
    public var sortField: SortField {
        switch self {
        case .name: .name
        case .dateModified: .dateModified
        case .size: .size
        case .kind: .kind
        case .dateCreated: .dateCreated
        case .fileExtension: .fileExtension
        }
    }
}

public struct ColumnSetting: Sendable, Codable, Hashable {
    public var id: ColumnID
    public var width: Double
    public var visible: Bool
    public init(id: ColumnID, width: Double, visible: Bool) {
        self.id = id
        self.width = width
        self.visible = visible
    }
}

public enum StartupFolder: Sendable, Codable, Hashable { case home, lastLocation, custom(URL) }
public enum OpenFoldersIn: String, Sendable, Codable { case sameWindow, newWindow }
public enum ReturnKeyBehavior: String, Sendable, Codable { case open, rename }
public enum DateStyle: String, Sendable, Codable { case relative, absolute }
public enum SidebarSection: String, Sendable, Codable, CaseIterable { case favorites, locations, folders }
public enum DefaultFavorite: String, Sendable, Codable, CaseIterable { case home, desktop, documents, downloads, applications }
public enum TCCOutcome: String, Sendable, Codable { case granted, denied }

/// A location whose first access may block on a macOS (TCC) consent prompt (spec §4.2).
public enum ProtectedLocation: Sendable, Codable, Hashable {
    case desktop, documents, downloads, iCloudDrive
    case removableVolume(VolumeID), networkVolume(VolumeID)
}
