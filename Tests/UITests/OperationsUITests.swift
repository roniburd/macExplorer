import XCTest
import AppKit
import SwiftUI
@testable import UI
import Core
import MacxFS

@MainActor
final class OperationsUITests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    /// Values only: these paths are never created or touched.
    private func summary(_ path: String, directory: Bool = false) -> ItemSummary {
        ItemSummary(url: URL(filePath: "/nonexistent/macx/\(path)"), isDirectory: directory, size: 10, modified: Date(timeIntervalSince1970: 0))
    }

    private func info(_ source: ItemSummary, _ destination: ItemSummary, folderMerge: Bool = false, remaining: Int = 1,
                      pending: [ConflictPair] = []) -> ConflictInfo {
        ConflictInfo(pair: ConflictPair(source: source, destination: destination), isFolderMerge: folderMerge,
                     knownRemaining: remaining, pendingPairs: pending)
    }

    private func job(_ verb: JobVerb = .copying, state: JobState = .running, progress: JobProgress = .zero) -> JobSnapshot {
        JobSnapshot(id: JobID(), description: JobDescription(verb: verb, itemCount: 1_204, firstItemName: "a.txt",
                                                             sourceFolderName: "Downloads", destinationFolderName: "Backup"),
                    state: state, progress: progress, origin: nil, startedAt: .now)
    }

    private func fileError(_ kind: FileOpErrorKind) -> FileOpError {
        FileOpError(kind: kind, url: URL(filePath: "/nonexistent/macx/a.txt"))
    }

    func testConflictDialogModelForFiles() {
        let model = ConflictDialogModel(info(summary("src/a.txt"), summary("dst/a.txt"), remaining: 3))
        XCTAssertEqual(model.title, "The destination already has a file named 'a.txt'")
        XCTAssertEqual(model.choices, [.action(.replace), .action(.skip), .action(.keepBoth), .compare, .cancel])
        XCTAssertEqual(model.applyToAllTitle, "Do this for all remaining conflicts (3)")
        XCTAssertEqual(model.resolution(.replace, applyToAll: false), .one(.replace))
        XCTAssertEqual(model.resolution(.keepBoth, applyToAll: true), .all(.keepBoth))
        XCTAssertEqual(model.defaultAction, .keepBoth, "Return never replaces")
        let single = ConflictDialogModel(info(summary("src/a.txt"), summary("dst/a.txt"), remaining: 1))
        XCTAssertNil(single.applyToAllTitle, "no 'for all' with a single known conflict")
        XCTAssertEqual(single.resolution(.skip, applyToAll: true), .one(.skip))
        let ontoFolder = ConflictDialogModel(info(summary("src/x"), summary("dst/x", directory: true)))
        XCTAssertEqual(ontoFolder.title, "The destination already has a folder named 'x'")
        XCTAssertFalse(ontoFolder.choices.contains(.action(.merge)), "only folder onto folder merges")
        XCTAssertEqual(ConflictDialogModel.title(.action(.keepBoth)), "Keep Both")
        XCTAssertEqual(ConflictDialogModel.title(.compare), "Compare…")
        XCTAssertEqual(ConflictDialogModel.title(.cancel), "Cancel")
    }

    func testConflictDialogModelForFolders() {
        let model = ConflictDialogModel(info(summary("src/F", directory: true), summary("dst/F", directory: true),
                                             folderMerge: true, remaining: 2))
        XCTAssertEqual(model.title, "Merge folders?")
        XCTAssertEqual(model.message, "The destination already has a folder named 'F'. Merging adds the items of both folders to it.")
        XCTAssertEqual(model.choices, [.action(.merge), .action(.keepBoth), .action(.skip), .cancel], "§6.4: Merge / Keep Both / Skip")
        XCTAssertEqual(model.defaultAction, .merge)
        XCTAssertEqual(model.resolution(.merge, applyToAll: true), .all(.merge))
    }

    func testCompareSelectionMapsCheckboxesToActions() {
        let a = ConflictPair(source: summary("src/a.txt"), destination: summary("dst/a.txt"))
        let b = ConflictPair(source: summary("src/b.txt"), destination: summary("dst/b.txt"))
        let f = ConflictPair(source: summary("src/F", directory: true), destination: summary("dst/F", directory: true))
        var selection = CompareSelection(info(a.source, a.destination, remaining: 3, pending: [a, b, f]))
        XCTAssertEqual(selection.rows.map(\.pair), [a, b, f], "the current pair first, no duplicates")
        XCTAssertFalse(selection.canContinue, "every row needs a choice (Explorer)")
        XCTAssertEqual(selection.allSources, .off)
        selection.rows[0].keepSource = true                  // a: source only → replace
        selection.rows[1].keepSource = true                  // b: both → keep both
        selection.rows[1].keepDestination = true
        selection.rows[2].keepSource = true                  // F: folder pair, source only → merge
        XCTAssertTrue(selection.canContinue)
        XCTAssertEqual(selection.allSources, .on)
        XCTAssertEqual(selection.allDestinations, .mixed)
        XCTAssertEqual(selection.resolution, .perItem([a.source.url: .replace, b.source.url: .keepBoth, f.source.url: .merge]))
        selection.setAllSources(false)
        selection.setAllDestinations(true)
        XCTAssertEqual(selection.resolution, .perItem([a.source.url: .skip, b.source.url: .skip, f.source.url: .skip]))
        XCTAssertNil(CompareSelection.action(keepSource: false, keepDestination: false, isFolderPair: false))
    }

    func testErrorDialogButtonsFollowTheErrorTable() {
        let kinds: [FileOpErrorKind] = [.permissionDenied, .blockedByMacOS, .locked, .readOnlyVolume,
                                        .noSpace(needed: 2_000_000, available: 1_000_000), .inUse, .nameTooLong, .sourceGone,
                                        .intoItself, .changedDuringMove, .noTrash, .other(code: 5, message: "Input/output error")]
        for kind in kinds {
            let model = ErrorDialogModel.error(fileError(kind), job: job(), locale: en)
            XCTAssertEqual(model.buttons.map(\.answer), kind.allowedResolutions.map { InteractionAnswer.error($0) },
                           "\(kind): one button per §6.5 action, in order")
            XCTAssertEqual(model.title, ErrorText.jobError(kind, name: "a.txt", verb: .copying))
            XCTAssertEqual(model.context, "Copying 1,204 items from Downloads to Backup")
        }
        func titles(_ kind: FileOpErrorKind) -> [String] {
            ErrorDialogModel.error(fileError(kind), job: job(), locale: en).buttons.map(\.title)
        }
        XCTAssertEqual(titles(.permissionDenied), ["Retry", "Skip", "Skip All", "Cancel"])
        XCTAssertEqual(titles(.blockedByMacOS), ["Open Privacy Settings", "Skip", "Cancel"])
        XCTAssertEqual(titles(.locked), ["Unlock and Continue", "Skip", "Cancel"])
        XCTAssertEqual(titles(.readOnlyVolume), ["Cancel"])
        XCTAssertEqual(titles(.noSpace(needed: nil, available: nil)), ["Retry", "Cancel"])
        XCTAssertEqual(titles(.inUse), ["Retry", "Skip", "Cancel"])
        XCTAssertEqual(titles(.nameTooLong), ["Skip", "Cancel"])
        XCTAssertEqual(titles(.sourceGone), ["Skip", "Cancel"])
    }

    func testSpaceAndNoTrashPrompts() {
        let space = ErrorDialogModel.space(SpaceShortfall(needed: 2_000_000, available: 1_000_000, volumeName: "Backup"), job: job(), locale: en)
        XCTAssertEqual(space.title, "Not enough space on 'Backup'")
        XCTAssertEqual(space.detail, "This operation needs 2 MB, but only 1 MB is available.")
        XCTAssertEqual(space.buttons.map(\.title), ["Continue Anyway", "Cancel"])
        XCTAssertEqual(space.buttons.map(\.answer), [.confirm(true), .confirm(false)])
        XCTAssertEqual(space.buttons.first(where: \.isDefault)?.title, "Cancel", "Return never overfills the disk")
        let one = ErrorDialogModel.noTrash([URL(filePath: "/nonexistent/macx/a.txt")], job: job(.trashing), locale: en)
        XCTAssertEqual(one.title, "'a.txt' can't be moved to the Trash.")
        XCTAssertEqual(one.detail, "Do you want to delete it permanently? This can't be undone.")
        XCTAssertEqual(one.buttons.map(\.title), ["Delete", "Cancel"])
        XCTAssertEqual(one.buttons[0].role, .destructive)
        let many = ErrorDialogModel.noTrash([URL(filePath: "/nonexistent/macx/a"), URL(filePath: "/nonexistent/macx/b")],
                                            job: job(.trashing), locale: en)
        XCTAssertEqual(many.title, "2 items can't be moved to the Trash.")
        XCTAssertEqual(many.detail, "Do you want to delete them permanently? This can't be undone.")
    }

    func testOpenPrivacySettingsIsRecordedThenRetries() async throws {
        let h = try await ContentTestHarness.make(self)
        RecordingURLOpener.shared.reset()
        let presenter = AppKitDialogPresenter(icons: h.context.icons, opener: ExternalOpeners.opener(for: h.context.options))
        let model = ErrorDialogModel.error(fileError(.blockedByMacOS), job: job(), locale: en)
        let button = try XCTUnwrap(model.buttons.first)
        XCTAssertEqual(button.sideEffect, .openPrivacySettings)
        XCTAssertEqual(presenter.handle(button), .error(.retry), "§3.13: the side effect, then Retry")
        XCTAssertEqual(RecordingURLOpener.shared.opened, [SystemSettingsLinks.privacyAllFiles], "recorded, never opened (S5-C2)")
        XCTAssertEqual(presenter.handle(model.buttons[1]), .error(.skip))
        XCTAssertEqual(RecordingURLOpener.shared.opened.count, 1)
    }

    func testJobTitles() {
        func title(_ verb: JobVerb, _ count: Int, _ name: String?, _ from: String?, _ to: String?) -> String {
            JobTitle.title(JobDescription(verb: verb, itemCount: count, firstItemName: name, sourceFolderName: from,
                                          destinationFolderName: to), locale: en)
        }
        XCTAssertEqual(title(.copying, 1_204, "a.txt", "Downloads", "Backup"), "Copying 1,204 items from Downloads to Backup")
        XCTAssertEqual(title(.moving, 1, "a.txt", "Downloads", "Backup"), "Moving 'a.txt' from Downloads to Backup")
        XCTAssertEqual(title(.copying, 2, nil, nil, "Backup"), "Copying 2 items to Backup")
        XCTAssertEqual(title(.trashing, 3, "a", "Downloads", nil), "Moving 3 items to the Trash")
        XCTAssertEqual(title(.deleting, 1, "a.txt", nil, nil), "Deleting 'a.txt'")
        XCTAssertEqual(title(.creating, 1, "New Folder", nil, "Docs"), "Creating 'New Folder' in Docs")
        XCTAssertEqual(title(.changingPermissions, 1, nil, nil, nil), "Changing permissions of 1 item")
        XCTAssertEqual(title(.undoing, 4, "x", nil, nil), "Undoing changes to 4 items")
    }

    func testJobRowModelStates() {
        var progress = JobProgress()
        progress.itemsDone = 12
        progress.itemsTotal = 1_204
        progress.bytesDone = 1_200_000
        progress.bytesTotal = 3_000_000_000
        progress.throughput = [0, 6_000_000, 12_000_000]
        progress.estimatedRemaining = .seconds(120)
        progress.currentItem = "photo.jpg"
        let running = JobRowModel(job(state: .running, progress: progress), locale: en)
        XCTAssertEqual(running.title, "Copying 1,204 items from Downloads to Backup")
        XCTAssertEqual(running.countText, "12 of 1,204")
        XCTAssertEqual(running.bytesText, "1.2 MB of 3 GB")
        XCTAssertEqual(running.speedText, "12 MB/s")
        XCTAssertEqual(running.etaText, "About 2 minutes remaining")
        XCTAssertNil(running.statusText)
        XCTAssertEqual(running.graph, [0, 0.5, 1])
        XCTAssertEqual(running.currentItem, "photo.jpg")
        XCTAssertTrue(running.canPause)
        XCTAssertFalse(running.canResume)
        XCTAssertTrue(running.canCancel)
        let paused = JobRowModel(job(state: .paused, progress: progress), locale: en)
        XCTAssertEqual(paused.statusText, "Paused")
        XCTAssertTrue(paused.canResume)
        XCTAssertFalse(paused.canPause)
        XCTAssertNil(paused.speedText, "no speed or ETA while paused")
        XCTAssertNil(paused.etaText)
        let planning = JobRowModel(job(state: .planning), locale: en)
        XCTAssertEqual(planning.statusText, "Preparing…")
        XCTAssertNil(planning.countText)
        XCTAssertNil(planning.fraction)
        let waiting = JobRowModel(job(state: .waitingForUser, progress: progress), locale: en)
        XCTAssertTrue(waiting.isWaiting)
        XCTAssertEqual(waiting.statusText, "Waiting for your answer")
        XCTAssertFalse(JobRowModel(job(state: .cancelling), locale: en).canCancel)
        XCTAssertEqual(JobRowModel.eta(.seconds(45), locale: en), "About 45 seconds remaining")
    }

    func testThroughputGraph() {
        XCTAssertEqual(ThroughputGraph.normalized([]), [])
        XCTAssertEqual(ThroughputGraph.normalized([0, 0]), [0, 0])
        XCTAssertEqual(ThroughputGraph.normalized([2, 4, -1]), [0.5, 1, 0])
        XCTAssertEqual(ThroughputGraph.points([0, 1], in: CGSize(width: 100, height: 20)), [CGPoint(x: 0, y: 20), CGPoint(x: 100, y: 0)])
        XCTAssertTrue(ThroughputGraph.points([1], in: CGSize(width: 100, height: 20)).isEmpty)
    }

    func testCapsuleState() {
        XCTAssertFalse(CapsuleState.make(visible: [], overallFraction: nil).isVisible, "§6.2: nothing for jobs under 1 s")
        let one = CapsuleState.make(visible: [job()], overallFraction: 0.42)
        XCTAssertTrue(one.isVisible)
        XCTAssertEqual(one.percentText, "42%")
        XCTAssertFalse(one.isWaiting)
        XCTAssertEqual(one.accessibilityLabel, "1 operation in progress, 42%")
        let two = CapsuleState.make(visible: [job(), job(state: .waitingForUser)], overallFraction: nil)
        XCTAssertEqual(two.percentText, "")
        XCTAssertTrue(two.isWaiting)
        XCTAssertEqual(two.accessibilityLabel, "2 operations in progress, waiting for your answer")
        XCTAssertEqual(CapsuleState.make(visible: [job()], overallFraction: 0.999).percentText, "99%", "never 100% before the end")
    }

    func testSheetHostResumesOnceAndWhenEndedFromOutside() async throws {
        try ContentTestHarness.requireWindowServer()
        let h = try await ContentTestHarness.make(self)
        let browser = try await h.openBrowserWindow()
        let window = try XCTUnwrap(browser.window)
        let answered = SheetHost()
        let first = Task { await answered.run(AnyView(Text(verbatim: "first")), on: window) }
        try await h.waitUntil("sheet shown") { window.attachedSheet != nil }
        answered.finish(.confirm(true))
        answered.finish(.confirm(false))                        // ignored: resumes exactly once
        let a = await first.value
        XCTAssertEqual(a, .confirm(true))
        try await h.waitUntil("sheet gone") { window.attachedSheet == nil }
        let external = SheetHost()
        let second = Task { await external.run(AnyView(Text(verbatim: "second")), on: window) }
        try await h.waitUntil("sheet shown again") { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet))   // what S6's scenario driver does
        let b = await second.value
        XCTAssertNil(b, "ended from outside: no answer, and never a hang")
    }

    func testCapsuleLivesInStatusBarSlotAndHidesWhenIdle() async throws {
        try ContentTestHarness.requireWindowServer()
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, _, _) = try await h.makeContent()
        let capsule = try XCTUnwrap(content.operationsCapsule)
        XCTAssertTrue(capsule.superview === content.statusBar.operationsSlot)
        XCTAssertTrue(capsule.isHidden, "no jobs: no capsule")
        XCTAssertEqual(capsule.button.accessibilityIdentifier(), AXID.operationsCapsule)
    }

    func testOperationsPanelOutlivesWindowsAndDeactivation() async throws {
        try ContentTestHarness.requireWindowServer()
        let h = try await ContentTestHarness.make(self)
        let controller = h.context.operationsUI.panel                // created, never shown here (S5-C7)
        let panel = try XCTUnwrap(controller.window as? NSPanel)
        XCTAssertFalse(panel.hidesOnDeactivate, "§6.7: the panel stays when the app has no windows or is inactive")
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.identifier?.rawValue, AXID.operationsPanel)
        XCTAssertTrue(controller.windowWillReturnUndoManager(panel) === h.environment.undo.undoManager)
    }

    func testShowOperationsIsNoLongerPending() {
        XCTAssertFalse(FileCommandController.pendingCommands.contains(.showOperations))
        // Only Phase 2 commands whose UI lands in a later task may still be pending; every Phase 1 command has its UI.
        let phase2: Set<Command> = Command.windowTabCommands.union([
            .openInNewTab, .quickLook, .viewAsColumns, .groupByNone, .groupByKind, .groupByDateModified, .groupBySize,
            .groupByName, .toggleFolderSizes, .applyViewToAllFolders,
            .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted,
        ])
        XCTAssertTrue(FileCommandController.pendingCommands.isSubset(of: phase2))
    }
}
