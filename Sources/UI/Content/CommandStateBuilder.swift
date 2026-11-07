import Foundation
import Core

/// CommandState (§5.3 enablement inputs) for a target. Pure in-memory: model, clipboard, undo, history.
@MainActor
enum CommandStateBuilder {
    /// `needsFolderCount`: scan a content selection for folders (CommandState.selectedFolderCount). Only Open in New
    /// Tab reads it, and validation runs once per menu item / toolbar item / command-bar button, so callers ask for
    /// it only when validating that command; otherwise a content selection reports 0.
    static func state(for target: CommandTarget?, session: BrowserSession, environment: CoreEnvironment,
                      needsFolderCount: Bool = false) -> CommandState {
        var state = CommandState()
        state.canPaste = environment.clipboard.canPaste
        state.canUndo = environment.undo.canUndo
        state.canRedo = environment.undo.canRedo
        state.canGoBack = session.history.canGoBack
        state.canGoForward = session.history.canGoForward
        state.canGoUp = session.folder.directory.standardizedFileURL.path != "/"
        state.folderIsReadOnly = session.folder.volume?.isReadOnly ?? false
        state.viewMode = session.viewMode
        // Search (P3-10): Save Search… and Stop Search work from any focus in the window.
        state.hasSearchQuery = session.searchSpec != nil
        state.showingResults = session.results != nil
        state.previewPaneVisible = environment.settings.previewPaneVisible       // Download for Preview (P3-12)
        if case .searching? = session.results?.state { state.isSearching = true }
        switch target {
        case .contentSelection(let folder):
            let rows = folder.selection.rows
            state.selectionCount = rows.count
            // 0 or 1 ("a folder is selected"): every rule only asks for > 0. Directories only (packages and links to
            // folders don't count; resolving links would need I/O). Scanned only on request (see needsFolderCount).
            if needsFolderCount {
                state.selectedFolderCount = rows.contains { $0 < folder.rowCount && folder.entry(atRow: $0).kind == .directory } ? 1 : 0
            }
            if rows.count == 1, let row = rows.first, row < folder.rowCount {
                let entry = folder.entry(atRow: row)
                state.singleFolderSelected = entry.kind == .directory
                state.targetIsPackage = entry.kind == .package
            }
        case .resultsSelection(let results):
            let rows = results.selection.rows.filter { $0 < results.rowCount }
            state.selectionCount = rows.count
            state.canPaste = false                      // results have no single destination folder
            state.folderIsReadOnly = false              // the file operations report read-only items themselves
            if needsFolderCount {
                state.selectedFolderCount = rows.contains { results.entry(atRow: $0).kind == .directory } ? 1 : 0
            }
            if rows.count == 1, let row = rows.first {
                let entry = results.entry(atRow: row)
                state.singleFolderSelected = entry.kind == .directory
                state.targetIsPackage = entry.kind == .package
            }
        case .currentFolder:
            state.selectionCount = 0
        case .savedSearch:
            state.selectionCount = 1                    // the row itself (Open, Rename, Remove)
        case .folder, .location:
            state.selectionCount = 1
            state.singleFolderSelected = true
            state.selectedFolderCount = 1
        case .favorite(let favorite):
            state.selectionCount = favorite.url == nil ? 0 : 1
            state.singleFolderSelected = favorite.url != nil
            state.selectedFolderCount = state.selectionCount
        case .volume(let volume):
            state.selectionCount = 1
            state.singleFolderSelected = true
            state.selectedFolderCount = 1
            state.targetIsEjectable = volume.isEjectable
            state.folderIsReadOnly = volume.isReadOnly
        case nil:
            break
        }
        return state
    }
}
