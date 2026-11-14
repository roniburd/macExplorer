@testable import Core
import XCTest

final class RemoteCommandAvailabilityTests: XCTestCase {
    private func state(_ selected: Int = 1) -> CommandState {
        var s = CommandState(selectionCount: selected, canPaste: true, canGoUp: true, folderIsReadOnly: true)
        s.isRemote = true
        s.canGoBack = true   // .back needs history
        return s
    }

    func testMutatingAndLocalOnlyCommandsAreOff() {
        let off: [Command] = [.cut, .paste, .moveItemHere, .rename, .moveToTrash, .deletePermanently, .duplicate, .makeAlias,
                              .makeSymlink, .newFolder, .newTextFile, .newEmptyFile, .toggleFolderSizes, .properties,
                              .openInTerminal, .revealInFinder, .showPackageContents, .searchScopeSubfolders,
                              .searchScopeThisMac, .searchModeContents, .eject, .share, .compressZip, .compressAppleArchive,
                              .extractHere, .batchRename, .copyPathTilde, .copyPathFileURL, .copyPathShellQuoted]
        for c in off { XCTAssertFalse(CommandAvailability.isEnabled(c, focus: .content, state: state(2)), "\(c)") }
        XCTAssertEqual(CommandAvailability.remoteDenied, Set(off))
    }

    func testReadingCommandsStayOn() {
        for c: Command in [.open, .copy, .copyAsPath, .copyName, .quickLook, .selectAll, .refresh, .up, .back,
                           .searchScopeThisFolder, .sortByName, .viewAsIcons] {
            XCTAssertTrue(CommandAvailability.isEnabled(c, focus: .content, state: state()), "\(c)")
        }
    }

    func testGateAppliesInFieldEditorAndAddressBar() {
        for focus: FocusContext in [.fieldEditor, .addressBar, .searchResults] {
            for c in CommandAvailability.remoteDenied where !(focus == .fieldEditor && [.cut, .paste].contains(c)) {
                XCTAssertFalse(CommandAvailability.isEnabled(c, focus: focus, state: state(2)), "\(c) in \(focus)")
            }
        }
        XCTAssertTrue(CommandAvailability.isEnabled(.cut, focus: .fieldEditor, state: state()), "text editing in the search field")
        XCTAssertTrue(CommandAvailability.isEnabled(.paste, focus: .fieldEditor, state: state()), "text editing in the search field")
    }

    func testLocalFoldersUnaffected() {
        var s = state(); s.isRemote = false; s.folderIsReadOnly = false
        XCTAssertTrue(CommandAvailability.isEnabled(.rename, focus: .content, state: s))
        XCTAssertTrue(CommandAvailability.isEnabled(.openInTerminal, focus: .content, state: s))
    }

    func testRemoteSidebarRowIsGatedEvenInALocalWindow() {
        // A REPOSITORIES row or remote favorite focused while the window shows a local folder.
        var s = CommandState(selectionCount: 1, singleFolderSelected: true, canPaste: true, folderIsReadOnly: true)
        s.targetIsRemote = true
        for focus: FocusContext in [.sidebarLocations, .sidebarFavorites] {
            for c in CommandAvailability.remoteDenied {
                XCTAssertFalse(CommandAvailability.isEnabled(c, focus: focus, state: s), "\(c) in \(focus)")
            }
            for c: Command in [.open, .openInNewWindow, .openInNewTab, .copy, .copyAsPath, .copyName] {
                XCTAssertTrue(CommandAvailability.isEnabled(c, focus: focus, state: s), "\(c) in \(focus)")
            }
        }
        XCTAssertTrue(CommandAvailability.isEnabled(.removeFromFavorites, focus: .sidebarFavorites, state: s))
    }

    func testRemoteSessionDoesNotGateALocalSidebarRow() {
        var s = CommandState(selectionCount: 1, singleFolderSelected: true, canPaste: true)
        s.isRemote = true   // the window shows a repository; the focused row is a local folder
        XCTAssertTrue(CommandAvailability.isEnabled(.paste, focus: .sidebarFolders, state: s))
        XCTAssertTrue(CommandAvailability.isEnabled(.openInTerminal, focus: .sidebarLocations, state: s))
    }
}
