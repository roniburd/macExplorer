import Foundation
import Core
import MacxFS

/// One Favorites row: a default (Home, Desktop…) or a user bookmark, after resolution.
struct SidebarFavorite: Hashable {
    var resolved: ResolvedFavorite
    /// nil = a user favorite (`Settings.favorites`).
    var defaultKind: DefaultFavorite?

    var id: UUID { resolved.favorite.id }
    var name: String { resolved.favorite.displayName }
    var url: URL? { resolved.url }
    var isStale: Bool { resolved.isStale }
}

/// The sidebar outline's node model (§5.4): section headers, favorites, locations and Folders-tree nodes.
/// The outline view gets one stable box object per item (`SidebarViewController.box(_:)`); `item(atRow:) as? SidebarItem`
/// unboxes it.
enum SidebarItem: Hashable {
    case favoritesHeader, locationsHeader, foldersHeader
    case favorite(SidebarFavorite)
    case location(VolumeInfo)
    case iCloudDrive(URL)
    /// A File Provider folder in `~/Library/CloudStorage` (OneDrive, Google Drive…), after iCloud Drive.
    case cloudStorage(CloudStorageFolder)
    /// The user's Trash (`~/.Trash`), last in LOCATIONS.
    case trash(URL)
    case folder(FolderTreeNode)

    static func header(_ section: SidebarSection) -> SidebarItem {
        switch section {
        case .favorites: .favoritesHeader
        case .locations: .locationsHeader
        case .folders: .foldersHeader
        }
    }

    var section: SidebarSection {
        switch self {
        case .favoritesHeader, .favorite: .favorites
        case .locationsHeader, .location, .iCloudDrive, .cloudStorage, .trash: .locations
        case .foldersHeader, .folder: .folders
        }
    }

    var isHeader: Bool {
        switch self {
        case .favoritesHeader, .locationsHeader, .foldersHeader: true
        case .favorite, .location, .iCloudDrive, .cloudStorage, .trash, .folder: false
        }
    }

    /// The folder this row navigates to (nil for headers and stale favorites).
    @MainActor var url: URL? {
        switch self {
        case .favoritesHeader, .locationsHeader, .foldersHeader: nil
        case .favorite(let f): f.url
        case .location(let v): v.mountPoint
        case .iCloudDrive(let url), .trash(let url): url
        case .cloudStorage(let folder): folder.url
        case .folder(let node): node.url
        }
    }

    /// Stable identity across rebuilds (a renamed favorite or a rescanned volume keeps its outline row).
    var identity: String {
        switch self {
        case .favoritesHeader: "header.favorites"
        case .locationsHeader: "header.locations"
        case .foldersHeader: "header.folders"
        case .favorite(let f): "favorite.\(f.id.uuidString)"
        case .location(let v): "location.\(v.id.raw)"
        case .iCloudDrive: "location.iCloudDrive"
        case .cloudStorage(let folder): "location.cloudStorage.\(folder.url.lastPathComponent)"
        case .trash: "location.trash"
        case .folder(let node): "folder.\(ObjectIdentifier(node).hashValue)"
        }
    }

    /// Focus semantics of the row (§5.4 table): volume roots in the tree behave like Locations rows.
    @MainActor var focusContext: FocusContext {
        switch self {
        case .favoritesHeader, .favorite: .sidebarFavorites
        case .locationsHeader, .location, .iCloudDrive, .cloudStorage, .trash: .sidebarLocations
        case .foldersHeader: .sidebarFolders
        case .folder(let node): node.isVolumeRoot ? .sidebarVolumeRoot : .sidebarFolders
        }
    }

    /// What commands act on with this row focused.
    @MainActor var commandTarget: CommandTarget? {
        switch self {
        case .favoritesHeader, .locationsHeader, .foldersHeader: nil
        case .favorite(let f): .favorite(f.resolved)
        case .location(let v): .volume(v)
        case .iCloudDrive(let url), .trash(let url): .location(url)
        case .cloudStorage(let folder): .location(folder.url)
        case .folder(let node): node.isVolumeRoot ? .volume(node.volume) : .folder(node.url)
        }
    }

    static func == (a: SidebarItem, b: SidebarItem) -> Bool {
        switch (a, b) {
        case (.favoritesHeader, .favoritesHeader), (.locationsHeader, .locationsHeader), (.foldersHeader, .foldersHeader): true
        case (.favorite(let x), .favorite(let y)): x == y
        case (.location(let x), .location(let y)): x == y
        case (.iCloudDrive(let x), .iCloudDrive(let y)): x == y
        case (.cloudStorage(let x), .cloudStorage(let y)): x == y
        case (.trash(let x), .trash(let y)): x == y
        case (.folder(let x), .folder(let y)): x === y
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }
}
