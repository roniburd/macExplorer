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

    func testLocalFoldersUnaffected() {
        var s = state(); s.isRemote = false; s.folderIsReadOnly = false
        XCTAssertTrue(CommandAvailability.isEnabled(.rename, focus: .content, state: s))
        XCTAssertTrue(CommandAvailability.isEnabled(.openInTerminal, focus: .content, state: s))
    }
}
