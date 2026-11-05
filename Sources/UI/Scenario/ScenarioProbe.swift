import Foundation
import Core
import MacxFS

/// Feature-specific probe values (overview §3.14). The owning tasks install these on
/// `BrowserWindowController.scenarioHooks`: address (P1-27), empty state and banner (P1-33), rename text (P1-34),
/// performDrop (P1-36). An uninstalled hook returns nil / does nothing.
@MainActor struct ScenarioHooks {
    var addressText: (() -> String)?
    var isEditingAddress: (() -> Bool)?
    var renameText: (() -> String?)?
    var emptyStateText: (() -> String?)?
    var bannerText: (() -> String?)?
    var performDrop: (([URL], String, DragModifiers, Bool, DragOperation?) async -> Void)?
    // Phase 2 (plan P2-03). Nil until the owning task installs it; an expectation or step that needs a missing
    // hook fails with a message naming it.
    var visibleColumnIDs: (() -> [String])?                         // P2-16
    var visibleRowNames: (() -> [String])?                          // P2-10 (item rows in the table, headers excluded)
    var groupHeaderTitles: (() -> [String])?                        // P2-10
    var cellText: ((String, String) -> String?)?                    // P2-14/P2-16 (row name, ColumnID raw value)
    var quickLookState: (() -> (visible: Bool, items: [String]))?   // P2-11
    var columnsChain: (() -> (folders: [URL], active: Int))?        // P2-19
    var thumbnailNames: (() -> [String])?                           // P2-17
    var performMiddleClick: ((String) async -> Bool)?               // P2-06 (async: tree: targets load the tree)
    var clickTarget: ((String, [String]) async -> Bool)?            // P2-06 tree:, P2-10 group:, P2-16 header: (target, modifiers)
    var rightClickTarget: ((String) -> Bool)?                       // P2-16 header:
}

/// What the in-process scenario driver (P1-41) reads from a browser window. BrowserWindowController conforms.
@MainActor protocol ScenarioProbe: AnyObject {
    var probeFolderURL: URL { get }
    var probeRowNames: [String] { get }            // display order
    var probeSelectedNames: [String] { get }
    var probeCutNames: [String] { get }
    var probeFolderState: FolderState { get }
    var probeFocus: FocusContext { get }
    var probeViewMode: ViewMode { get }
    var probeAddressText: String { get }
    var probeIsEditingAddress: Bool { get }
    var probeRenameText: String? { get }
    var probeEmptyStateText: String? { get }
    var probeBannerText: String? { get }
    var probeFieldEditorText: String? { get }      // whatever field editor is first responder
    // Phase 2 (plan P2-03)
    var probeTabFolderURLs: [URL] { get }          // each tab's folder, in tab order
    var probeSelectedTabIndex: Int { get }         // index of the tab group's selected window in that order
    var probeSort: MacxFS.SortDescriptor { get }
    var probeGrouping: GroupBy { get }
    var probeIconSize: IconSize { get }
    /// Scenario-only drop entry point (drag sessions can't be synthesized in-process). Runs the same
    /// DropPolicy + DropMenu + job path as a real drop onto `targetName` ("" = current folder).
    func probePerformDrop(sources: [URL], onto targetName: String, modifiers: DragModifiers, secondary: Bool, menuChoice: DragOperation?) async
}
