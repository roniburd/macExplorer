import Foundation
import Core

/// CommandState (§5.3 enablement inputs) for a target. Pure in-memory: model, clipboard, undo, history.
@MainActor
enum CommandStateBuilder {
    static func state(for target: CommandTarget?, session: BrowserSession, environment: CoreEnvironment) -> CommandState {
        var state = CommandState()
        state.canPaste = environment.clipboard.canPaste
        state.canUndo = environment.undo.canUndo
        state.canRedo = environment.undo.canRedo
        state.canGoBack = session.history.canGoBack
        state.canGoForward = session.history.canGoForward
        state.canGoUp = session.folder.directory.standardizedFileURL.path != "/"
        state.folderIsReadOnly = session.folder.volume?.isReadOnly ?? false
        state.viewMode = session.viewMode
        switch target {
        case .contentSelection(let folder):
            let rows = folder.selection.rows
            state.selectionCount = rows.count
            // 0 or 1 ("a folder is selected"): every rule only asks for > 0, and menu validation runs per item, so a
            // 100k-row Select All must not be scanned in full each time.
            state.selectedFolderCount = rows.contains { $0 < folder.rowCount && folder.entry(atRow: $0).kind == .directory } ? 1 : 0
            if rows.count == 1, let row = rows.first, row < folder.rowCount {
                let entry = folder.entry(atRow: row)
                state.singleFolderSelected = entry.kind == .directory
                state.targetIsPackage = entry.kind == .package
            }
        case .currentFolder:
            state.selectionCount = 0
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
