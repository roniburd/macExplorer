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
    /// Scenario-only drop entry point (drag sessions can't be synthesized in-process). Runs the same
    /// DropPolicy + DropMenu + job path as a real drop onto `targetName` ("" = current folder).
    func probePerformDrop(sources: [URL], onto targetName: String, modifiers: DragModifiers, secondary: Bool, menuChoice: DragOperation?) async
}
