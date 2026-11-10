import AppKit
import Core

// One responder-chain action per Command.selectorName (generated from Command.allCases; keep in sync).
// CommandActionsTests.testEveryCommandHasAResponderMethod fails when a Command case has no method here.
extension CommandHandlingViewController {
    @objc func macx_open(_ sender: Any?) { run(.open, sender: sender) }
    @objc func macx_openInNewWindow(_ sender: Any?) { run(.openInNewWindow, sender: sender) }
    @objc func macx_showPackageContents(_ sender: Any?) { run(.showPackageContents, sender: sender) }
    @objc func macx_openInTerminal(_ sender: Any?) { run(.openInTerminal, sender: sender) }
    @objc func macx_revealInFinder(_ sender: Any?) { run(.revealInFinder, sender: sender) }
    @objc func cut(_ sender: Any?) { run(.cut, sender: sender) }
    @objc func copy(_ sender: Any?) { run(.copy, sender: sender) }
    @objc func paste(_ sender: Any?) { run(.paste, sender: sender) }
    @objc func macx_moveItemHere(_ sender: Any?) { run(.moveItemHere, sender: sender) }
    @objc override func selectAll(_ sender: Any?) { run(.selectAll, sender: sender) }
    @objc func undo(_ sender: Any?) { run(.undo, sender: sender) }
    @objc func redo(_ sender: Any?) { run(.redo, sender: sender) }
    @objc func macx_selectNone(_ sender: Any?) { run(.selectNone, sender: sender) }
    @objc func macx_invertSelection(_ sender: Any?) { run(.invertSelection, sender: sender) }
    @objc func macx_rename(_ sender: Any?) { run(.rename, sender: sender) }
    @objc func macx_moveToTrash(_ sender: Any?) { run(.moveToTrash, sender: sender) }
    @objc func macx_deletePermanently(_ sender: Any?) { run(.deletePermanently, sender: sender) }
    @objc func macx_duplicate(_ sender: Any?) { run(.duplicate, sender: sender) }
    @objc func macx_makeAlias(_ sender: Any?) { run(.makeAlias, sender: sender) }
    @objc func macx_makeSymlink(_ sender: Any?) { run(.makeSymlink, sender: sender) }
    @objc func macx_newFolder(_ sender: Any?) { run(.newFolder, sender: sender) }
    @objc func macx_newTextFile(_ sender: Any?) { run(.newTextFile, sender: sender) }
    @objc func macx_newEmptyFile(_ sender: Any?) { run(.newEmptyFile, sender: sender) }
    @objc func macx_copyAsPath(_ sender: Any?) { run(.copyAsPath, sender: sender) }
    @objc func macx_properties(_ sender: Any?) { run(.properties, sender: sender) }
    @objc func macx_share(_ sender: Any?) { run(.share, sender: sender) }
    @objc func macx_back(_ sender: Any?) { run(.back, sender: sender) }
    @objc func macx_forward(_ sender: Any?) { run(.forward, sender: sender) }
    @objc func macx_up(_ sender: Any?) { run(.up, sender: sender) }
    @objc func macx_focusAddressBar(_ sender: Any?) { run(.focusAddressBar, sender: sender) }
    @objc func macx_focusSearch(_ sender: Any?) { run(.focusSearch, sender: sender) }
    @objc func macx_cycleFocusForward(_ sender: Any?) { run(.cycleFocusForward, sender: sender) }
    @objc func macx_cycleFocusBackward(_ sender: Any?) { run(.cycleFocusBackward, sender: sender) }
    @objc func macx_refresh(_ sender: Any?) { run(.refresh, sender: sender) }
    @objc func macx_newWindow(_ sender: Any?) { run(.newWindow, sender: sender) }
    @objc func macx_closeWindow(_ sender: Any?) { run(.closeWindow, sender: sender) }
    @objc func macx_showOperations(_ sender: Any?) { run(.showOperations, sender: sender) }
    @objc func macx_viewAsDetails(_ sender: Any?) { run(.viewAsDetails, sender: sender) }
    @objc func macx_viewAsIcons(_ sender: Any?) { run(.viewAsIcons, sender: sender) }
    @objc func macx_iconSizeSmall(_ sender: Any?) { run(.iconSizeSmall, sender: sender) }
    @objc func macx_iconSizeMedium(_ sender: Any?) { run(.iconSizeMedium, sender: sender) }
    @objc func macx_iconSizeLarge(_ sender: Any?) { run(.iconSizeLarge, sender: sender) }
    @objc func macx_densityCompact(_ sender: Any?) { run(.densityCompact, sender: sender) }
    @objc func macx_densityRegular(_ sender: Any?) { run(.densityRegular, sender: sender) }
    @objc func macx_densityComfortable(_ sender: Any?) { run(.densityComfortable, sender: sender) }
    @objc func macx_toggleHidden(_ sender: Any?) { run(.toggleHidden, sender: sender) }
    @objc func macx_toggleCommandBar(_ sender: Any?) { run(.toggleCommandBar, sender: sender) }
    @objc func macx_useViewAsDefault(_ sender: Any?) { run(.useViewAsDefault, sender: sender) }
    @objc func macx_resetFolderView(_ sender: Any?) { run(.resetFolderView, sender: sender) }
    @objc func macx_sortByName(_ sender: Any?) { run(.sortByName, sender: sender) }
    @objc func macx_sortByDateModified(_ sender: Any?) { run(.sortByDateModified, sender: sender) }
    @objc func macx_sortBySize(_ sender: Any?) { run(.sortBySize, sender: sender) }
    @objc func macx_sortByKind(_ sender: Any?) { run(.sortByKind, sender: sender) }
    @objc func macx_sortByDateCreated(_ sender: Any?) { run(.sortByDateCreated, sender: sender) }
    @objc func macx_sortAscending(_ sender: Any?) { run(.sortAscending, sender: sender) }
    @objc func macx_sortDescending(_ sender: Any?) { run(.sortDescending, sender: sender) }
    @objc func macx_eject(_ sender: Any?) { run(.eject, sender: sender) }
    @objc func macx_removeFromFavorites(_ sender: Any?) { run(.removeFromFavorites, sender: sender) }
    @objc override func cancelOperation(_ sender: Any?) { run(.cancelOperation, sender: sender) }
    // Phase 2. The NSWindow tab commands (Command.windowTabCommands) are deliberately absent: NSWindow implements
    // and validates them, and a pane method would intercept them before the window.
    @objc func macx_openInNewTab(_ sender: Any?) { run(.openInNewTab, sender: sender) }
    @objc func macx_quickLook(_ sender: Any?) { run(.quickLook, sender: sender) }
    @objc func macx_viewAsColumns(_ sender: Any?) { run(.viewAsColumns, sender: sender) }
    @objc func macx_groupByNone(_ sender: Any?) { run(.groupByNone, sender: sender) }
    @objc func macx_groupByKind(_ sender: Any?) { run(.groupByKind, sender: sender) }
    @objc func macx_groupByDateModified(_ sender: Any?) { run(.groupByDateModified, sender: sender) }
    @objc func macx_groupBySize(_ sender: Any?) { run(.groupBySize, sender: sender) }
    @objc func macx_groupByName(_ sender: Any?) { run(.groupByName, sender: sender) }
    @objc func macx_toggleFolderSizes(_ sender: Any?) { run(.toggleFolderSizes, sender: sender) }
    @objc func macx_applyViewToAllFolders(_ sender: Any?) { run(.applyViewToAllFolders, sender: sender) }
    @objc func macx_copyPathTilde(_ sender: Any?) { run(.copyPathTilde, sender: sender) }
    @objc func macx_copyPathFileURL(_ sender: Any?) { run(.copyPathFileURL, sender: sender) }
    @objc func macx_copyName(_ sender: Any?) { run(.copyName, sender: sender) }
    @objc func macx_copyPathShellQuoted(_ sender: Any?) { run(.copyPathShellQuoted, sender: sender) }
    // Phase 3
    @objc func macx_togglePreviewPane(_ sender: Any?) { run(.togglePreviewPane, sender: sender) }
    @objc func macx_showInPreview(_ sender: Any?) { run(.showInPreview, sender: sender) }
    @objc func macx_previewZoomIn(_ sender: Any?) { run(.previewZoomIn, sender: sender) }
    @objc func macx_previewZoomOut(_ sender: Any?) { run(.previewZoomOut, sender: sender) }
    @objc func macx_previewActualSize(_ sender: Any?) { run(.previewActualSize, sender: sender) }
    @objc func macx_openContainingFolder(_ sender: Any?) { run(.openContainingFolder, sender: sender) }
    @objc func macx_saveSearch(_ sender: Any?) { run(.saveSearch, sender: sender) }
    @objc func macx_stopSearch(_ sender: Any?) { run(.stopSearch, sender: sender) }
    @objc func macx_searchScopeThisFolder(_ sender: Any?) { run(.searchScopeThisFolder, sender: sender) }
    @objc func macx_searchScopeSubfolders(_ sender: Any?) { run(.searchScopeSubfolders, sender: sender) }
    @objc func macx_searchScopeThisMac(_ sender: Any?) { run(.searchScopeThisMac, sender: sender) }
    @objc func macx_searchModeName(_ sender: Any?) { run(.searchModeName, sender: sender) }
    @objc func macx_searchModeContents(_ sender: Any?) { run(.searchModeContents, sender: sender) }
    @objc func macx_renameSavedSearch(_ sender: Any?) { run(.renameSavedSearch, sender: sender) }
    @objc func macx_removeSavedSearch(_ sender: Any?) { run(.removeSavedSearch, sender: sender) }
    @objc func macx_downloadForPreview(_ sender: Any?) { run(.downloadForPreview, sender: sender) }
    // Phase 4 (disabled until shipped: CommandAvailability.shippedPhase4Commands)
    @objc func macx_showCommandPalette(_ sender: Any?) { run(.showCommandPalette, sender: sender) }
    @objc func macx_compressZip(_ sender: Any?) { run(.compressZip, sender: sender) }
    @objc func macx_compressAppleArchive(_ sender: Any?) { run(.compressAppleArchive, sender: sender) }
    @objc func macx_extractHere(_ sender: Any?) { run(.extractHere, sender: sender) }
    @objc func macx_batchRename(_ sender: Any?) { run(.batchRename, sender: sender) }
    @objc func macx_editTags(_ sender: Any?) { run(.editTags, sender: sender) }
}
