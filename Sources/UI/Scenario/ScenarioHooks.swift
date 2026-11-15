import AppKit
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
    var iconsVisibleNames: (() -> [String])?                        // QA round 2: Icons items in the visible rect
    var performMiddleClick: ((String) async -> Bool)?               // P2-06 (async: tree: targets load the tree)
    var clickTarget: ((String, [String]) async -> Bool)?            // P2-06 tree:, P2-10 group:, P2-16 header: (target, modifiers)
    var rightClickTarget: ((String) -> NSMenu?)?                    // P2-16 header: (the menu a right-click opens)
}
