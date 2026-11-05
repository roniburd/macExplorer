import Foundation
import MacxFS
import Observation

/// App preferences (spec §4.3, §7). Each property is JSON-encoded under its own storage key and written on change;
/// defaults are never written, so a later schema can change them. Values that fail to decode fall back to the default.
@MainActor @Observable
public final class Settings {
    public static let schemaVersion: Int = 2
    public static let schemaVersionKey = "schemaVersion"
    public static let recentLocationsLimit = 20
    public static let lastReportedCrashesLimit = 20
    /// Column defaults (display order): every ColumnID at its `defaultWidth`; Phase 1's Name, Date Modified, Size
    /// and Kind visible, everything else hidden. `DetailsColumns.defaults` is this list.
    public static let defaultColumns: [ColumnSetting] = ColumnID.allCases.map {
        ColumnSetting(id: $0, width: $0.defaultWidth, visible: [.name, .dateModified, .size, .kind].contains($0))
    }

    @ObservationIgnored private let storage: any SettingsStorage
    public let home: URL

    public var startupFolder: StartupFolder { didSet { save(startupFolder, Key.startupFolder) } }
    public var openFoldersIn: OpenFoldersIn { didSet { save(openFoldersIn, Key.openFoldersIn) } }
    public var returnKey: ReturnKeyBehavior { didSet { save(returnKey, Key.returnKey) } }
    /// nil = /System/Applications/Utilities/Terminal.app
    public var terminalApp: URL? { didSet { save(terminalApp, Key.terminalApp) } }
    public var viewMode: ViewMode { didSet { save(viewMode, Key.viewMode) } }
    public var iconSize: IconSize { didSet { save(iconSize, Key.iconSize) } }
    public var density: Density { didSet { save(density, Key.density) } }
    /// Array order = display order.
    public var columns: [ColumnSetting] { didSet { save(columns, Key.columns) } }
    public var sort: MacxFS.SortDescriptor { didSet { save(sort, Key.sort) } }
    public var showHidden: Bool { didSet { save(showHidden, Key.showHidden) } }
    /// Group by for folders without their own view state (Details view only).
    public var groupBy: GroupBy { didSet { save(groupBy, Key.groupBy) } }
    /// Icons view shows Quick Look thumbnails in place of type icons.
    public var showThumbnails: Bool { didSet { save(showThumbnails, Key.showThumbnails) } }
    /// Columns view column width (the last width the user set).
    public var columnWidth: Double { didSet { save(columnWidth, Key.columnWidth) } }
    public var commandBarVisible: Bool { didSet { save(commandBarVisible, Key.commandBarVisible) } }
    public var autoRevealInTree: Bool { didSet { save(autoRevealInTree, Key.autoRevealInTree) } }
    public var dateStyle: DateStyle { didSet { save(dateStyle, Key.dateStyle) } }
    public var favorites: [Favorite] { didSet { save(favorites, Key.favorites) } }
    public var hiddenDefaultFavorites: Set<DefaultFavorite> { didSet { save(hiddenDefaultFavorites, Key.hiddenDefaultFavorites) } }
    public var showICloudInSidebar: Bool { didSet { save(showICloudInSidebar, Key.showICloudInSidebar) } }
    /// OneDrive, Google Drive, Dropbox… (the folders in `~/Library/CloudStorage`) in LOCATIONS.
    public var showCloudStorageInSidebar: Bool { didSet { save(showCloudStorageInSidebar, Key.showCloudStorageInSidebar) } }
    public var showExternalVolumesInSidebar: Bool { didSet { save(showExternalVolumesInSidebar, Key.showExternalVolumesInSidebar) } }
    public var collapsedSections: Set<SidebarSection> { didSet { save(collapsedSections, Key.collapsedSections) } }
    public var confirmBeforeTrash: Bool { didSet { save(confirmBeforeTrash, Key.confirmBeforeTrash) } }
    /// Always true (locked on, spec §7).
    public var confirmBeforeDelete: Bool { true }
    public var showFullPathInTitle: Bool { didSet { save(showFullPathInTitle, Key.showFullPathInTitle) } }
    public var updateChannel: UpdateChannel { didSet { save(updateChannel, Key.updateChannel) } }
    public var checkForUpdatesAutomatically: Bool { didSet { save(checkForUpdatesAutomatically, Key.checkForUpdatesAutomatically) } }
    public var offerToReportCrashes: Bool { didSet { save(offerToReportCrashes, Key.offerToReportCrashes) } }
    /// `.ips` file names already offered (newest first, ≤ 20), so one crash prompts once.
    public private(set) var lastReportedCrashes: [String] { didSet { save(lastReportedCrashes, Key.lastReportedCrashes) } }
    public var onboardingCompleted: Bool { didSet { save(onboardingCompleted, Key.onboardingCompleted) } }
    /// Set once the toolbar has been given the Send Feedback item (or already had it). A restored toolbar
    /// configuration never gains new default items; this one-time flag lets the first window of this build add it
    /// without overriding a user who later removes it on purpose (review of Task 10).
    public var toolbarFeedbackItemOffered: Bool { didSet { save(toolbarFeedbackItemOffered, Key.toolbarFeedbackItemOffered) } }
    public var lastLocation: URL? { didSet { save(lastLocation, Key.lastLocation) } }
    /// ≤ 20, most recent first. Settable (§3.9; e.g. "clear recents" assigns []); longer lists are clamped.
    public var recentLocations: [String] {
        get { recents }
        set { recents = Array(newValue.prefix(Self.recentLocationsLimit)) }
    }
    private var recents: [String] { didSet { save(recents, Key.recentLocations) } }
    private var tccOutcomes: [ProtectedLocation: TCCOutcome] { didSet { save(tccOutcomes.map(TCCRecord.init), Key.tccOutcomes) } }

    public init(storage: any SettingsStorage, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.storage = storage
        self.home = home
        let stored = Self.load(Int.self, Self.schemaVersionKey, from: storage)
        startupFolder = Self.load(StartupFolder.self, Key.startupFolder, from: storage) ?? .home
        openFoldersIn = Self.load(OpenFoldersIn.self, Key.openFoldersIn, from: storage) ?? .sameWindow
        returnKey = Self.load(ReturnKeyBehavior.self, Key.returnKey, from: storage) ?? .open
        terminalApp = Self.load(URL.self, Key.terminalApp, from: storage)
        viewMode = Self.load(ViewMode.self, Key.viewMode, from: storage) ?? .details
        iconSize = Self.load(IconSize.self, Key.iconSize, from: storage) ?? .medium
        density = Self.load(Density.self, Key.density, from: storage) ?? .regular
        let storedColumns = Self.load([ColumnSetting].self, Key.columns, from: storage) ?? []
        columns = storedColumns.isEmpty ? Self.defaultColumns : Self.migrateColumns(storedColumns)
        sort = Self.load(MacxFS.SortDescriptor.self, Key.sort, from: storage) ?? .default
        showHidden = Self.load(Bool.self, Key.showHidden, from: storage) ?? false
        groupBy = Self.load(GroupBy.self, Key.groupBy, from: storage) ?? .none
        showThumbnails = Self.load(Bool.self, Key.showThumbnails, from: storage) ?? true
        columnWidth = Self.load(Double.self, Key.columnWidth, from: storage) ?? 220
        commandBarVisible = Self.load(Bool.self, Key.commandBarVisible, from: storage) ?? true
        autoRevealInTree = Self.load(Bool.self, Key.autoRevealInTree, from: storage) ?? true
        dateStyle = Self.load(DateStyle.self, Key.dateStyle, from: storage) ?? .relative
        favorites = Self.load([Favorite].self, Key.favorites, from: storage) ?? []
        hiddenDefaultFavorites = Self.load(Set<DefaultFavorite>.self, Key.hiddenDefaultFavorites, from: storage) ?? []
        showICloudInSidebar = Self.load(Bool.self, Key.showICloudInSidebar, from: storage) ?? true
        showCloudStorageInSidebar = Self.load(Bool.self, Key.showCloudStorageInSidebar, from: storage) ?? true
        showExternalVolumesInSidebar = Self.load(Bool.self, Key.showExternalVolumesInSidebar, from: storage) ?? true
        collapsedSections = Self.load(Set<SidebarSection>.self, Key.collapsedSections, from: storage) ?? []
        confirmBeforeTrash = Self.load(Bool.self, Key.confirmBeforeTrash, from: storage) ?? false
        showFullPathInTitle = Self.load(Bool.self, Key.showFullPathInTitle, from: storage) ?? false
        onboardingCompleted = Self.load(Bool.self, Key.onboardingCompleted, from: storage) ?? false
        toolbarFeedbackItemOffered = Self.load(Bool.self, Key.toolbarFeedbackItemOffered, from: storage) ?? false
        lastLocation = Self.load(URL.self, Key.lastLocation, from: storage)
        recents = Array((Self.load([String].self, Key.recentLocations, from: storage) ?? []).prefix(Self.recentLocationsLimit))
        let records = Self.load([TCCRecord].self, Key.tccOutcomes, from: storage) ?? []
        tccOutcomes = Dictionary(records.map { ($0.location, $0.outcome) }, uniquingKeysWith: { _, last in last })
        updateChannel = Self.load(UpdateChannel.self, Key.updateChannel, from: storage) ?? .release
        checkForUpdatesAutomatically = Self.load(Bool.self, Key.checkForUpdatesAutomatically, from: storage) ?? true
        offerToReportCrashes = Self.load(Bool.self, Key.offerToReportCrashes, from: storage) ?? true
        lastReportedCrashes = Array((Self.load([String].self, Key.lastReportedCrashes, from: storage) ?? []).prefix(Self.lastReportedCrashesLimit))
        if (stored ?? 0) < Self.schemaVersion {
            storage.set(try? JSONEncoder().encode(Self.schemaVersion), forKey: Self.schemaVersionKey)
        }
    }

    public func addRecentLocation(_ path: String) {
        guard !path.isEmpty else { return }
        var list = recentLocations.filter { $0 != path }
        list.insert(path, at: 0)
        recentLocations = list
    }

    public func markCrashReported(_ fileName: String) {
        lastReportedCrashes = Array(([fileName] + lastReportedCrashes.filter { $0 != fileName }).prefix(Self.lastReportedCrashesLimit))
    }

    public func tccOutcome(for location: ProtectedLocation) -> TCCOutcome? { tccOutcomes[location] }

    public func recordTCCOutcome(_ outcome: TCCOutcome, for location: ProtectedLocation) {
        guard tccOutcomes[location] != outcome else { return }
        tccOutcomes[location] = outcome
    }

    /// Schema v2 column migration, applied on every load (idempotent): duplicates dropped (first wins), then every
    /// missing ColumnID appended invisible at its default width, so a Phase 1 store gains the Phase 2 columns hidden.
    public static func migrateColumns(_ stored: [ColumnSetting]) -> [ColumnSetting] {
        var seen = Set<ColumnID>()
        var result = stored.filter { seen.insert($0.id).inserted }
        for id in ColumnID.allCases where !seen.contains(id) {
            result.append(ColumnSetting(id: id, width: id.defaultWidth, visible: false))
        }
        return result
    }

    public func viewQuery() -> ViewQuery { ViewQuery(sort: sort, showHidden: showHidden, filter: "") }

    // MARK: Persistence

    private enum Key {
        static let startupFolder = "startupFolder", openFoldersIn = "openFoldersIn", returnKey = "returnKey"
        static let terminalApp = "terminalApp", viewMode = "viewMode", iconSize = "iconSize", density = "density"
        static let columns = "columns", sort = "sort", showHidden = "showHidden", commandBarVisible = "commandBarVisible"
        static let groupBy = "groupBy", showThumbnails = "showThumbnails", columnWidth = "columnWidth"
        static let autoRevealInTree = "autoRevealInTree", dateStyle = "dateStyle", favorites = "favorites"
        static let hiddenDefaultFavorites = "hiddenDefaultFavorites", showICloudInSidebar = "showICloudInSidebar"
        static let showExternalVolumesInSidebar = "showExternalVolumesInSidebar", collapsedSections = "collapsedSections"
        static let confirmBeforeTrash = "confirmBeforeTrash", showFullPathInTitle = "showFullPathInTitle"
        static let onboardingCompleted = "onboardingCompleted", lastLocation = "lastLocation"
        static let toolbarFeedbackItemOffered = "toolbarFeedbackItemOffered"
        static let recentLocations = "recentLocations", tccOutcomes = "tccOutcomes"
        static let showCloudStorageInSidebar = "showCloudStorageInSidebar"
        static let updateChannel = "updateChannel", checkForUpdatesAutomatically = "checkForUpdatesAutomatically"
        static let offerToReportCrashes = "offerToReportCrashes", lastReportedCrashes = "lastReportedCrashes"
    }

    private struct TCCRecord: Codable {
        var location: ProtectedLocation
        var outcome: TCCOutcome
        init(_ pair: (key: ProtectedLocation, value: TCCOutcome)) { location = pair.key; outcome = pair.value }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from storage: any SettingsStorage) -> T? {
        guard let data = storage.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Optionals are removed from storage when nil.
    private func save<T: Encodable>(_ value: T?, _ key: String) {
        guard let value else { storage.set(nil, forKey: key); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        storage.set(try? encoder.encode(value), forKey: key)
    }
}
