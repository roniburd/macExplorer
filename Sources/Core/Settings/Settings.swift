import Foundation
import MacxFS
import Observation

/// App preferences (spec §4.3, §7). Each property is JSON-encoded under its own storage key and written on change;
/// defaults are never written, so a later schema can change them. Values that fail to decode fall back to the default.
@MainActor @Observable
public final class Settings {
    public static let schemaVersion: Int = 3
    public static let schemaVersionKey = "schemaVersion"
    public static let recentLocationsLimit = 20
    public static let lastReportedCrashesLimit = 20
    public static let paletteRecentLimit = 20
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
    /// "Apply to All Folders" (post-merge review): Finder's `.DS_Store` views last written before this moment are
    /// ignored, so the applied view really reaches every folder. nil = every Finder view applies.
    public var finderViewsIgnoredBefore: Date? { didSet { save(finderViewsIgnoredBefore, Key.finderViewsIgnoredBefore) } }
    /// "Apply to All Folders" (review): the built-in rule (application folders open as Large Icons) no longer applies,
    /// so the applied view really reaches every folder. false = the rule applies.
    public var builtInFolderViewsOff: Bool { didSet { save(builtInFolderViewsOff, Key.builtInFolderViewsOff) } }
    /// Columns view column width (the last width the user set).
    public var columnWidth: Double { didSet { save(columnWidth, Key.columnWidth) } }
    /// Show every filename extension, including ones Finder hides and ".app" (design 2026-11-05 §1).
    public var showAllExtensions: Bool { didSet { save(showAllExtensions, Key.showAllExtensions) } }
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
    /// Install Previous Version… "skip until newer": background update checks skip builds ≤ this. nil = no skip.
    public var updateSkipThroughBuild: Int? { didSet { save(updateSkipThroughBuild, Key.updateSkipThroughBuild) } }
    /// A rollback swap in flight across the quit/relaunch; the next launch reconciles and clears it.
    public var pendingRollback: PendingRollback? { didSet { save(pendingRollback, Key.pendingRollback) } }
    public var offerToReportCrashes: Bool { didSet { save(offerToReportCrashes, Key.offerToReportCrashes) } }
    /// Settings › Shortcuts: the user's changes to the key table (sparse; `.empty` = all defaults). Not stored while empty.
    public var keyBindingOverrides: KeyBindingOverrides {
        didSet { save(keyBindingOverrides.commands.isEmpty ? nil : keyBindingOverrides, Key.keyBindings) }
    }
    /// The resolved table for `keyBindingOverrides`.
    public var keyBindings: KeyBindings { KeyBindings(overrides: keyBindingOverrides) }
    /// `.ips` file names already offered (newest first, ≤ 20), so one crash prompts once.
    public private(set) var lastReportedCrashes: [String] { didSet { save(lastReportedCrashes, Key.lastReportedCrashes) } }
    // Phase 3 (schema v3): saved searches, preview pane, search defaults, results columns.
    /// SEARCHES section rows, in display order.
    public var savedSearches: [SavedSearch] { didSet { save(savedSearches, Key.savedSearches) } }
    public var previewPaneVisible: Bool { didSet { save(previewPaneVisible, Key.previewPaneVisible) } }
    public var previewPaneWidth: Double { didSet { save(previewPaneWidth, Key.previewPaneWidth) } }
    /// The user has dragged the pane to a width (otherwise it opens at a share of the window).
    public var hasStoredPreviewPaneWidth: Bool { storage.data(forKey: Key.previewPaneWidth) != nil }
    /// Text, Markdown and reflowed-document zoom in the preview pane (1 = 100%).
    public var previewZoom: Double { didSet { save(previewZoom, Key.previewZoom) } }
    /// The preview pane's Rendered | Source switch for Markdown files: true shows them formatted. On by default.
    public var previewRendersMarkdown: Bool { didSet { save(previewRendersMarkdown, Key.previewRendersMarkdown) } }
    /// The preview pane's Reflowed | Original switch for Word documents: true reflows their text to the pane's
    /// width, false shows Quick Look's page view. On by default.
    public var previewReflowsDocuments: Bool { didSet { save(previewReflowsDocuments, Key.previewReflowsDocuments) } }
    /// The scope and mode a new search starts with (the last ones the user picked).
    public var searchScope: SearchScope { didSet { save(searchScope, Key.searchScope) } }
    public var searchMode: SearchMode { didSet { save(searchMode, Key.searchMode) } }
    /// Subfolders (crawler) search descends into packages (.app, .bundle…). Off by default.
    public var searchIncludesPackages: Bool { didSet { save(searchIncludesPackages, Key.searchIncludesPackages) } }
    /// Details columns for search results (display order); separate from folder columns.
    public var resultsColumns: [ColumnSetting] { didSet { save(resultsColumns, Key.resultsColumns) } }
    public var onboardingCompleted: Bool { didSet { save(onboardingCompleted, Key.onboardingCompleted) } }
    /// Set once the toolbar has been given the Send Feedback item (or already had it). A restored toolbar
    /// configuration never gains new default items; this one-time flag lets the first window of this build add it
    /// without overriding a user who later removes it on purpose (review of Task 10).
    public var toolbarFeedbackItemOffered: Bool { didSet { save(toolbarFeedbackItemOffered, Key.toolbarFeedbackItemOffered) } }
    /// The same one-time offer for the New Tab toolbar button (P2-06).
    public var toolbarNewTabItemOffered: Bool { didSet { save(toolbarNewTabItemOffered, Key.toolbarNewTabItemOffered) } }
    public var lastLocation: URL? { didSet { save(lastLocation, Key.lastLocation) } }
    /// ≤ 20, most recent first. Settable (§3.9; e.g. "clear recents" assigns []); longer lists are clamped.
    public var recentLocations: [String] {
        get { recents }
        set { recents = Array(newValue.prefix(Self.recentLocationsLimit)) }
    }
    private var recents: [String] { didSet { save(recents, Key.recentLocations) } }
    /// The command palette's most recently run rows (P4-03): `PaletteTarget.encoded` strings, ≤ 20, most recent first.
    public var paletteRecent: [String] {
        get { paletteRecents }
        set { paletteRecents = Array(newValue.prefix(Self.paletteRecentLimit)) }
    }
    private var paletteRecents: [String] { didSet { save(paletteRecents, Key.paletteRecent) } }
    /// Settings › General › Icon pack (P4-08): a bookmark of the pack folder; nil = no pack.
    public var iconPackBookmark: Data? { didSet { save(iconPackBookmark, Key.iconPackBookmark) } }
    private var tccOutcomes: [ProtectedLocation: TCCOutcome] { didSet { save(tccOutcomes.map(TCCRecord.init), Key.tccOutcomes) } }

    /// `diagnostic` receives one message per stored value that exists but can't be decoded (key-bindings spec §6);
    /// it defaults to NSLog.
    public init(storage: any SettingsStorage, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                diagnostic: (String) -> Void = { NSLog("%@", $0) }) {
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
        finderViewsIgnoredBefore = Self.load(Date.self, Key.finderViewsIgnoredBefore, from: storage)
        builtInFolderViewsOff = Self.load(Bool.self, Key.builtInFolderViewsOff, from: storage) ?? false
        showAllExtensions = Self.load(Bool.self, Key.showAllExtensions, from: storage) ?? false
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
        savedSearches = Self.load([SavedSearch].self, Key.savedSearches, from: storage) ?? []
        previewPaneVisible = Self.load(Bool.self, Key.previewPaneVisible, from: storage) ?? false
        previewPaneWidth = Self.load(Double.self, Key.previewPaneWidth, from: storage) ?? 320
        previewZoom = Self.load(Double.self, Key.previewZoom, from: storage) ?? 1
        previewRendersMarkdown = Self.load(Bool.self, Key.previewRendersMarkdown, from: storage) ?? true
        previewReflowsDocuments = Self.load(Bool.self, Key.previewReflowsDocuments, from: storage) ?? true
        searchScope = Self.load(SearchScope.self, Key.searchScope, from: storage) ?? .thisFolder
        searchMode = Self.load(SearchMode.self, Key.searchMode, from: storage) ?? .name
        searchIncludesPackages = Self.load(Bool.self, Key.searchIncludesPackages, from: storage) ?? false
        let storedResultsColumns = Self.load([ColumnSetting].self, Key.resultsColumns, from: storage) ?? []
        resultsColumns = storedResultsColumns.isEmpty ? Self.defaultResultsColumns : Self.migrateColumns(storedResultsColumns)
        toolbarFeedbackItemOffered = Self.load(Bool.self, Key.toolbarFeedbackItemOffered, from: storage) ?? false
        toolbarNewTabItemOffered = Self.load(Bool.self, Key.toolbarNewTabItemOffered, from: storage) ?? false
        lastLocation = Self.load(URL.self, Key.lastLocation, from: storage)
        recents = Array((Self.load([String].self, Key.recentLocations, from: storage) ?? []).prefix(Self.recentLocationsLimit))
        paletteRecents = Array((Self.load([String].self, Key.paletteRecent, from: storage) ?? []).prefix(Self.paletteRecentLimit))
        iconPackBookmark = Self.load(Data.self, Key.iconPackBookmark, from: storage)
        let records = Self.load([TCCRecord].self, Key.tccOutcomes, from: storage) ?? []
        tccOutcomes = Dictionary(records.map { ($0.location, $0.outcome) }, uniquingKeysWith: { _, last in last })
        updateChannel = Self.load(UpdateChannel.self, Key.updateChannel, from: storage) ?? .release
        checkForUpdatesAutomatically = Self.load(Bool.self, Key.checkForUpdatesAutomatically, from: storage) ?? true
        offerToReportCrashes = Self.load(Bool.self, Key.offerToReportCrashes, from: storage) ?? true
        updateSkipThroughBuild = Self.load(Int.self, Key.updateSkipThroughBuild, from: storage)
        pendingRollback = Self.load(PendingRollback.self, Key.pendingRollback, from: storage)
        lastReportedCrashes = Array((Self.load([String].self, Key.lastReportedCrashes, from: storage) ?? []).prefix(Self.lastReportedCrashesLimit))
        // Undecodable data: defaults are used and the data is left in place (assigning in init doesn't save).
        if let data = storage.data(forKey: Key.keyBindings) {
            do {
                keyBindingOverrides = try JSONDecoder().decode(KeyBindingOverrides.self, from: data)
            } catch {
                keyBindingOverrides = .empty
                diagnostic("MacExplorer: stored \"\(Key.keyBindings)\" could not be read; using default shortcuts (\(error))")
            }
        } else {
            keyBindingOverrides = .empty
        }
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

    /// Moves `target` to the front of `paletteRecent` (P4-03).
    public func notePaletteUsed(_ target: PaletteTarget) {
        let entry = target.encoded
        paletteRecent = [entry] + paletteRecent.filter { $0 != entry }
    }

    /// `paletteRecent` decoded; entries this version can't read (a newer version's commands) are skipped.
    public var paletteRecentTargets: [PaletteTarget] { paletteRecent.compactMap(PaletteTarget.init(encoded:)) }

    public func markCrashReported(_ fileName: String) {
        lastReportedCrashes = Array(([fileName] + lastReportedCrashes.filter { $0 != fileName }).prefix(Self.lastReportedCrashesLimit))
    }

    public func tccOutcome(for location: ProtectedLocation) -> TCCOutcome? { tccOutcomes[location] }

    public func recordTCCOutcome(_ outcome: TCCOutcome, for location: ProtectedLocation) {
        guard tccOutcomes[location] != outcome else { return }
        tccOutcomes[location] = outcome
    }

    /// Schema v3 results-columns default: Name 260, Path 260, Date Modified 150, Size 80, Kind 140 visible, then every
    /// other ColumnID hidden at its default width.
    public static var defaultResultsColumns: [ColumnSetting] {
        migrateColumns([ColumnSetting(id: .name, width: 260, visible: true), ColumnSetting(id: .path, width: 260, visible: true),
                        ColumnSetting(id: .dateModified, width: 150, visible: true), ColumnSetting(id: .size, width: 80, visible: true),
                        ColumnSetting(id: .kind, width: 140, visible: true)])
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

    public func viewQuery() -> ViewQuery { ViewQuery(sort: sort, showHidden: showHidden, filter: "", showAllExtensions: showAllExtensions) }

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
        static let toolbarNewTabItemOffered = "toolbarNewTabItemOffered"
        static let recentLocations = "recentLocations", tccOutcomes = "tccOutcomes"
        static let showCloudStorageInSidebar = "showCloudStorageInSidebar", showAllExtensions = "showAllExtensions"
        static let updateChannel = "updateChannel", checkForUpdatesAutomatically = "checkForUpdatesAutomatically"
        static let offerToReportCrashes = "offerToReportCrashes", lastReportedCrashes = "lastReportedCrashes"
        static let keyBindings = "keyBindings", finderViewsIgnoredBefore = "finderViewsIgnoredBefore"
        static let builtInFolderViewsOff = "builtInFolderViewsOff"
        static let updateSkipThroughBuild = "updateSkipThroughBuild", pendingRollback = "pendingRollback"
        static let savedSearches = "savedSearches", previewPaneVisible = "previewPaneVisible", previewPaneWidth = "previewPaneWidth"
        static let searchScope = "searchScope", searchMode = "searchMode", searchIncludesPackages = "searchIncludesPackages"
        static let resultsColumns = "resultsColumns", previewRendersMarkdown = "previewRendersMarkdown"
        static let previewReflowsDocuments = "previewReflowsDocuments", previewZoom = "previewZoom"
        static let paletteRecent = "paletteRecent", iconPackBookmark = "iconPackBookmark"
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

// MARK: per-folder view defaults (P2-07, design 2026-11-05 §2)

extension Settings {
    /// The last level of the per-folder resolution chain: what every folder shows for the fields neither it, Finder
    /// nor the built-in rule set. Folder sizes are always per folder (off by default).
    public func defaultFolderViewState() -> FolderViewState {
        FolderViewState(mode: viewMode, columns: columns, sort: sort, iconSize: iconSize, density: density,
                        groupBy: groupBy, calculateFolderSizes: false)
    }

    /// "Use as Default for All Folders" and "Apply to All Folders": `state` becomes the default (mode, columns, sort,
    /// icon size, density, Group by; never sizes). Only changed fields are written.
    public func applyDefaultView(_ state: FolderViewState) {
        if viewMode != state.mode { viewMode = state.mode }
        if columns != state.columns { columns = state.columns }
        if sort != state.sort { sort = state.sort }
        if iconSize != state.iconSize { iconSize = state.iconSize }
        if density != state.density { density = state.density }
        if groupBy != state.groupBy { groupBy = state.groupBy }
    }
}

// MARK: saved searches (P3-07)

extension Settings {
    /// Appends a search named `name`, else its text, else its folder's name (made unique, case-insensitively).
    @discardableResult
    public func addSavedSearch(name: String, spec: SearchSpec) -> SavedSearch {
        let existing = savedSearches.map(\.name)
        let chosen = SavedSearchNaming.uniqueName(name, existing: existing)
            ?? SavedSearchNaming.uniqueName(spec.text, existing: existing)
            ?? SavedSearchNaming.uniqueName(spec.root.lastPathComponent, existing: existing)
            ?? spec.root.path(percentEncoded: false)
        let saved = SavedSearch(name: chosen, spec: spec)
        savedSearches.append(saved)
        return saved
    }

    /// Unique among the other searches. False for a blank name or an unknown id.
    @discardableResult
    public func renameSavedSearch(_ id: UUID, to name: String) -> Bool {
        guard let i = savedSearches.firstIndex(where: { $0.id == id }) else { return false }
        let others = savedSearches.enumerated().filter { $0.offset != i }.map(\.element.name)
        guard let unique = SavedSearchNaming.uniqueName(name, existing: others) else { return false }
        if savedSearches[i].name != unique { savedSearches[i].name = unique }
        return true
    }

    public func removeSavedSearch(_ id: UUID) {
        guard savedSearches.contains(where: { $0.id == id }) else { return }
        savedSearches.removeAll { $0.id == id }
    }

    /// Removes at `from`, then inserts at `min(to, count)`: `to` counts positions after the removal.
    public func moveSavedSearch(from: Int, to: Int) {
        guard savedSearches.indices.contains(from) else { return }
        var list = savedSearches
        let item = list.remove(at: from)
        list.insert(item, at: min(max(0, to), list.count))
        savedSearches = list
    }
}
