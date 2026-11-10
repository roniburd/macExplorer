import Core

/// Accessibility identifiers (overview §3.14). The scenario runner and the AX smoke script rely on these.
enum AXID {
    static let window = "macx.window"
    static let addressBar = "macx.addressBar"
    static let addressField = "macx.addressField"
    static func breadcrumbSegment(_ index: Int) -> String { "macx.breadcrumb.\(index)" }
    static let search = "macx.search"
    static let detailsTable = "macx.details"
    static let pathCell = "macx.pathCell"
    static let iconsGrid = "macx.icons"
    static let sidebar = "macx.sidebar"
    static func commandBarItem(_ c: Command) -> String { "macx.commandBar.\(c.rawValue)" }
    static let statusCount = "macx.status.count"
    static let statusSelection = "macx.status.selection"
    static let statusFree = "macx.status.free"
    static let emptyState = "macx.emptyState"
    static let banner = "macx.banner"
    static let renameField = "macx.renameField"
    static let operationsCapsule = "macx.operations"
    static let operationsPanel = "macx.operationsPanel"
    static func conflictButton(_ a: ConflictAction) -> String { "macx.conflict.\(a.rawValue)" }
    static let propertiesWindow = "macx.properties"
    static let propertiesIconWell = "macx.properties.iconWell"
    static let iconPackPicker = "macx.settings.iconPack"
    static let propertiesRemoveCustomIcon = "macx.properties.removeCustomIcon"
    static let settingsWindow = "macx.settings"          // additive, P1-30
    static let shortcutsList = "macx.settings.shortcuts.list"            // additive: Settings › Shortcuts
    static let shortcutsRestoreDefaults = "macx.settings.shortcuts.restore"
    static let shortcutsPreset = "macx.settings.shortcuts.preset"          // P4-02
    static let shortcutsImport = "macx.settings.shortcuts.import"
    static let shortcutsExport = "macx.settings.shortcuts.export"
    static let palette = "macx.palette"                                  // P4-03
    static let paletteField = "macx.palette.field"
    static let paletteTable = "macx.palette.table"
    static let shortcutsKeymapStatus = "macx.settings.shortcuts.keymapStatus"
    static let onboardingSheet = "macx.onboarding"       // additive, P1-30
    static let updateBadge = "macx.updateBadge"
    static let feedbackMenu = "macx.feedback"
    static let updateChannel = "macx.settings.updateChannel"
    static let automaticUpdateChecks = "macx.settings.automaticUpdateChecks"
    static let checkForUpdatesNow = "macx.settings.checkForUpdatesNow"
    static let offerCrashReports = "macx.settings.offerCrashReports"
    static let rollbackWindow = "macx.rollback"
    static let rollbackList = "macx.rollback.list"
    static let rollbackInstall = "macx.rollback.install"
    // Phase 2 (plan P2-03)
    static func groupHeader(_ title: String) -> String { "macx.group.\(title)" }
    static let columnsView = "macx.columns"
    static func column(_ index: Int) -> String { "macx.column.\(index)" }
    static let newTabItem = "macx.newTab"
    static let tabBarDrop = "macx.tabBarDrop"
    // Phase 3 search (plan P3-10)
    static let searchScopeBar = "macx.searchScopeBar"
    static let searchScope = "macx.searchScope"
    static let searchMode = "macx.searchMode"
    static let searchFilters = "macx.searchFilters"
    static let searchStop = "macx.searchStop"
    static let searchStatus = "macx.searchStatus"
    static let searchNotice = "macx.searchNotice"
    static let searchSave = "macx.searchSave"
    static let searchResultsTitle = "macx.searchResultsTitle"
    // Phase 3 saved searches (plan P3-11)
    static func sidebarSavedSearch(_ name: String) -> String { "macx.sidebar.search.\(name)" }
    static func sidebarTag(_ name: String) -> String { "macx.sidebar.tag.\(name)" }
    static let namePromptField = "macx.namePromptField"
    // Phase 3 preview pane (plan P3-12)
    static let previewPane = "macx.preview"
    static let previewText = "macx.preview.text"
    static let previewTruncation = "macx.preview.truncation"
    static let previewMode = "macx.preview.mode"
    static let previewZoom = "macx.preview.zoom"
    static let previewExpand = "macx.preview.expand"
    static let previewMessage = "macx.preview.message"
    static let previewDownload = "macx.preview.download"
    static let previewDetails = "macx.preview.details"
    static let previewClose = "macx.preview.close"
}
