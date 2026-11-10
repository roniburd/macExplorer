import XCTest
@testable import Core

final class CommandAvailabilityTests: XCTestCase {
    private func enabled(_ c: Command, _ focus: FocusContext = .content, _ state: CommandState = CommandState()) -> Bool {
        CommandAvailability.isEnabled(c, focus: focus, state: state)
    }

    private let oneFile = CommandState(selectionCount: 1)
    private let oneFolder = CommandState(selectionCount: 1, singleFolderSelected: true)

    func testAlwaysAvailableCommands() {
        let always: [Command] = [.focusAddressBar, .focusSearch, .cycleFocusForward, .cycleFocusBackward, .refresh,
                                 .newWindow, .closeWindow, .showOperations, .viewAsDetails, .viewAsIcons, .iconSizeSmall,
                                 .iconSizeMedium, .iconSizeLarge, .densityCompact, .densityRegular, .densityComfortable,
                                 .toggleHidden, .toggleCommandBar, .sortByName, .sortByDateModified, .sortBySize,
                                 .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending, .cancelOperation,
                                 .newFolder, .newTextFile, .newEmptyFile, .openInTerminal, .revealInFinder, .properties,
                                 .selectAll, .invertSelection]
        for c in always { XCTAssertTrue(enabled(c), "\(c)") }
    }

    func testSelectionDependentCommands() {
        let needsSelection: [Command] = [.open, .cut, .copy, .moveToTrash, .deletePermanently, .duplicate, .makeAlias,
                                         .makeSymlink, .copyAsPath, .share, .rename, .selectNone]
        for c in needsSelection {
            XCTAssertFalse(enabled(c), "\(c) with nothing selected")
            XCTAssertTrue(enabled(c, .content, oneFile), "\(c) with one item")
        }
    }

    /// P4-12: Rename (F2) on several items opens the batch rename sheet, so it is enabled there in the content view
    /// and search results; elsewhere (sidebar trees) it still needs exactly one item.
    func testRenameWithMultiSelectionMapsToBatchRename() {
        XCTAssertTrue(enabled(.rename, .content, CommandState(selectionCount: 2)))
        XCTAssertTrue(enabled(.rename, .searchResults, CommandState(selectionCount: 2)))
        XCTAssertFalse(enabled(.rename, .content, CommandState(selectionCount: 2, folderIsReadOnly: true)))
        XCTAssertFalse(enabled(.rename, .sidebarFolders, CommandState(selectionCount: 2)))
        XCTAssertTrue(enabled(.batchRename, .content, CommandState(selectionCount: 2)))
        XCTAssertFalse(enabled(.batchRename, .content, CommandState(selectionCount: 1)))
        XCTAssertTrue(enabled(.moveToTrash, .content, CommandState(selectionCount: 2)))
    }

    func testFolderAndPackageCommands() {
        XCTAssertFalse(enabled(.openInNewWindow, .content, oneFile))
        XCTAssertTrue(enabled(.openInNewWindow, .content, oneFolder))
        XCTAssertFalse(enabled(.showPackageContents, .content, oneFile))
        XCTAssertTrue(enabled(.showPackageContents, .content, CommandState(selectionCount: 1, targetIsPackage: true)))
    }

    func testClipboardUndoAndHistoryFlags() {
        XCTAssertFalse(enabled(.paste))
        XCTAssertTrue(enabled(.paste, .content, CommandState(canPaste: true)))
        XCTAssertFalse(enabled(.moveItemHere))
        XCTAssertTrue(enabled(.moveItemHere, .content, CommandState(canPaste: true)))
        XCTAssertFalse(enabled(.undo))
        XCTAssertTrue(enabled(.undo, .content, CommandState(canUndo: true)))
        XCTAssertFalse(enabled(.redo))
        XCTAssertTrue(enabled(.redo, .content, CommandState(canRedo: true)))
        XCTAssertFalse(enabled(.back))
        XCTAssertTrue(enabled(.back, .content, CommandState(canGoBack: true)))
        XCTAssertFalse(enabled(.forward))
        XCTAssertTrue(enabled(.forward, .content, CommandState(canGoForward: true)))
        XCTAssertFalse(enabled(.up))
        XCTAssertTrue(enabled(.up, .content, CommandState(canGoUp: true)))
    }

    func testReadOnlyFolderDisablesMutations() {
        let ro = CommandState(selectionCount: 1, canPaste: true, folderIsReadOnly: true)
        for c: Command in [.cut, .paste, .moveItemHere, .rename, .moveToTrash, .deletePermanently, .duplicate, .makeAlias,
                           .makeSymlink, .newFolder, .newTextFile, .newEmptyFile] {
            XCTAssertFalse(enabled(c, .content, ro), "\(c)")
        }
        for c: Command in [.copy, .copyAsPath, .open, .properties, .share] { XCTAssertTrue(enabled(c, .content, ro), "\(c)") }
    }

    func testEjectOnlyForEjectableSidebarVolumes() {
        let ejectable = CommandState(selectionCount: 1, singleFolderSelected: true, targetIsEjectable: true)
        XCTAssertTrue(enabled(.eject, .sidebarLocations, ejectable))
        XCTAssertTrue(enabled(.eject, .sidebarVolumeRoot, ejectable))
        XCTAssertFalse(enabled(.eject, .sidebarLocations, oneFolder))
        XCTAssertFalse(enabled(.eject, .content, ejectable))
        XCTAssertFalse(enabled(.eject, .sidebarFavorites, ejectable))
        XCTAssertFalse(enabled(.eject, .sidebarFolders, ejectable))
    }

    // MARK: §5.4 sidebar table

    func testFavoritesSection() {
        let s = CommandState(selectionCount: 1, singleFolderSelected: true, canPaste: true)
        XCTAssertEqual(CommandAvailability.effectiveCommand(.moveToTrash, focus: .sidebarFavorites), .removeFromFavorites)
        XCTAssertTrue(enabled(.removeFromFavorites, .sidebarFavorites, s))
        XCTAssertTrue(enabled(.removeFromFavorites, .sidebarFavorites, CommandState()), "stale favorites can be removed")
        for c: Command in [.open, .copy, .paste, .properties, .openInNewWindow] {
            XCTAssertTrue(enabled(c, .sidebarFavorites, s), "\(c)")
        }
        for c: Command in [.deletePermanently, .cut, .duplicate, .rename, .moveToTrash, .eject] {
            XCTAssertFalse(enabled(c, .sidebarFavorites, s), "\(c)")
        }
    }

    func testLocationsSection() {
        let s = CommandState(selectionCount: 1, singleFolderSelected: true, canPaste: true, targetIsEjectable: true)
        for focus: FocusContext in [.sidebarLocations, .sidebarVolumeRoot] {
            XCTAssertEqual(CommandAvailability.effectiveCommand(.moveToTrash, focus: focus), .moveToTrash)
            for c: Command in [.open, .eject, .paste, .properties, .openInNewWindow] {
                XCTAssertTrue(enabled(c, focus, s), "\(c) \(focus)")
            }
            for c: Command in [.moveToTrash, .deletePermanently, .cut, .duplicate, .rename, .removeFromFavorites] {
                XCTAssertFalse(enabled(c, focus, s), "\(c) \(focus)")
            }
        }
    }

    func testFoldersSectionBehavesLikeContent() {
        let s = CommandState(selectionCount: 1, singleFolderSelected: true, canPaste: true)
        XCTAssertEqual(CommandAvailability.effectiveCommand(.moveToTrash, focus: .sidebarFolders), .moveToTrash)
        for c: Command in [.moveToTrash, .deletePermanently, .rename, .cut, .copy, .paste, .duplicate, .properties] {
            XCTAssertTrue(enabled(c, .sidebarFolders, s), "\(c)")
        }
        XCTAssertFalse(enabled(.removeFromFavorites, .sidebarFolders, s))
        XCTAssertFalse(enabled(.removeFromFavorites, .content, s))
    }

    func testEffectiveCommandIsIdentityElsewhereAndIdempotent() {
        for focus: FocusContext in [.content, .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot,
                                    .addressBar, .fieldEditor] {
            for c in Command.allCases {
                let e = CommandAvailability.effectiveCommand(c, focus: focus)
                XCTAssertNotNil(e)
                if !(focus == .sidebarFavorites && c == .moveToTrash) { XCTAssertEqual(e, c, "\(c) \(focus)") }
                XCTAssertEqual(e.flatMap { CommandAvailability.effectiveCommand($0, focus: focus) }, e, "idempotent")
            }
        }
    }

    func testFieldEditorDisablesCollidingCommands() {
        let s = CommandState(selectionCount: 1, singleFolderSelected: true, canGoBack: true, canGoForward: true, canGoUp: true)
        for c in KeyBindings.defaults.collidesWithTextEditing {
            XCTAssertFalse(enabled(c, .fieldEditor, s), "\(c)")
            XCTAssertTrue(enabled(c, .content, s), "\(c)")
        }
        for c: Command in [.cut, .copy, .paste, .selectAll, .undo, .redo] {
            XCTAssertTrue(enabled(c, .fieldEditor, CommandState()), "the field editor validates \(c) itself")
        }
        XCTAssertTrue(enabled(.newWindow, .fieldEditor))
    }
}
