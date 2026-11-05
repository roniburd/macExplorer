import AppKit
import Core
import MacxFS

/// How a row asked to open in a new tab (§11 Tabs): a middle-click anywhere a folder row is shown, or ⌘-click on a
/// sidebar or tree row (⌘-click in the content keeps its Phase 1 selection-toggle meaning).
enum NewTabGesture: Equatable { case middleClick, commandClick }

@MainActor
enum MiddleClickRouter {
    static func shouldOpenTab(_ gesture: NewTabGesture, in focus: FocusContext) -> Bool {
        switch focus {
        case .content: return gesture == .middleClick
        case .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot: return true
        case .addressBar, .fieldEditor: return false
        }
    }

    /// The row's URL when it can open as a tab: folders, and links (OpenPlanner resolves those; only a folder target
    /// opens). Files, packages (apps included) and other items never do.
    static func folderTarget(row: Int, in folder: FolderModel) -> URL? {
        guard row >= 0, row < folder.rowCount else { return nil }
        switch folder.entry(atRow: row).kind {
        case .directory, .symlink, .alias: return folder.url(atRow: row)
        case .file, .package, .other: return nil
        }
    }
}

/// Button 2 press and release on the same row (a release over another row or empty space does nothing).
struct MiddleClickTracker {
    private var downRow: Int?

    mutating func mouseDown(row: Int?) { downRow = row }

    /// The row to open, or nil. Each press yields at most one row.
    mutating func mouseUp(row: Int?) -> Int? {
        defer { downRow = nil }
        guard let row, row == downRow else { return nil }
        return row
    }
}
