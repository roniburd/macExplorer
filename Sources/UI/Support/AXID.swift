import Core

/// Accessibility identifiers (overview §3.14). The scenario runner and the AX smoke script rely on these.
enum AXID {
    static let window = "macx.window"
    static let addressBar = "macx.addressBar"
    static let addressField = "macx.addressField"
    static func breadcrumbSegment(_ index: Int) -> String { "macx.breadcrumb.\(index)" }
    static let search = "macx.search"
    static let detailsTable = "macx.details"
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
    static let settingsWindow = "macx.settings"          // additive, P1-30
    static let shortcutsList = "macx.settings.shortcuts.list"            // additive: Settings › Shortcuts
    static let shortcutsRestoreDefaults = "macx.settings.shortcuts.restore"
    static let onboardingSheet = "macx.onboarding"       // additive, P1-30
    static let updateBadge = "macx.updateBadge"
    static let feedbackMenu = "macx.feedback"
    static let updateChannel = "macx.settings.updateChannel"
    static let automaticUpdateChecks = "macx.settings.automaticUpdateChecks"
    static let checkForUpdatesNow = "macx.settings.checkForUpdatesNow"
    static let offerCrashReports = "macx.settings.offerCrashReports"
    // Phase 2 (plan P2-03)
    static func groupHeader(_ title: String) -> String { "macx.group.\(title)" }
    static let columnsView = "macx.columns"
    static func column(_ index: Int) -> String { "macx.column.\(index)" }
    static let newTabItem = "macx.newTab"
    static let tabBarDrop = "macx.tabBarDrop"
}
