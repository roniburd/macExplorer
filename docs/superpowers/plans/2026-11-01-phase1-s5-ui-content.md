# macExplorer Phase 1, Slice S5 (UI content) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build everything inside the browser window's content area and the windows it opens: Details and Icons views over `FolderModel`, model-owned selection, type-select, empty states and the moved/deleted banner, inline rename, every file command and context menu, Open With and Choose Default App, drag & drop including right-drag, the Properties window, and the progress capsule, Operations panel, conflict, compare and error dialogs.

**Architecture:** `ContentViewController` (a `CommandHandlingViewController`) hosts the command bar, the active `FileListView` (Details `NSTableView` or Icons `NSCollectionView` with a custom fixed-grid layout), an empty-state overlay, the banner and the status bar. It is the single observer of the current `FolderModel` and forwards `ChangeSet`s and selection to the active list. Every decision is a small pure type with unit tests (`Formatters`, `ChangeApplier`, `DetailsColumns`, `FileGridLayout`, `SelectionController`, `TypeSelect`, `EmptyStateContent`, `BaseNameRange`, `DropRetarget`, `RightDragTracker`, `ConflictDialogModel`, `ErrorDialogModel`, `JobTitle`). The AppKit glue is checked by offscreen-window tests (skipped without a GUI session) and by manual runs of the sandboxed bundle. `FileCommandController` runs every `Command` for every `CommandTarget` through Core (`OperationsCenter.perform`, `Clipboard`, `OpenPlanner`, `LaunchServicesCache`). `InteractionRouter` replaces `BasicAlertInteraction` in `InteractionProxy`.

**Tech Stack:** Swift 6.4 (Swift 6 language mode, strict concurrency, warnings as errors), AppKit (`NSTableView`, `NSCollectionView` + `NSCollectionViewLayout`, `NSMenu`, `NSDraggingSession`, `NSSpringLoadingDestination`, `NSFilePromiseReceiver`, `NSSharingServicePicker`), SwiftUI in `NSHostingController` (Properties, conflict/compare/error dialogs, operations list only), Observation (`withObservationTracking`), `os` (`OSSignposter` via `PerfSignposts`), XCTest via `swift test` (target `UITests`), `jq` (`/usr/bin/jq`) for the string catalog.

**Spec:** `docs/superpowers/specs/2026-11-01-macexplorer-design.md` (source of truth). Overview and binding interface contract: `docs/superpowers/plans/2026-11-01-phase1-00-overview.md` (§3 signatures are copied verbatim below where this slice consumes or produces them). Research: `docs/research/ux.md`, `docs/research/perf.md`, `docs/research/platform.md`.

**Tasks in this slice:** P1-31, P1-32, P1-33, P1-34, P1-35, P1-36, P1-37, P1-38 (run in ID order after S4's P1-30).

## Global Constraints

Every constraint in the overview's "Global Constraints" applies to every task here, especially the **HARD SAFETY RULE**: tests, benchmarks and any manual or automated validation create, modify or delete files **only** inside fresh temp directories they create themselves (`FileManager.default.temporaryDirectory/macx-tests-<UUID>`, `${TMPDIR}/macx-scenario-<UUID>`) or disk images they create there. Never touch, move, rename, trash or delete any pre-existing user file. The app may *read* real folders when a human browses, but every automated or manual validation step in this slice points the app at a sandbox (`--root <sandbox> --state-dir <sandbox>/state`).

Slice-specific constraints (each one line, all mandatory):

- **S5-C1 Test world.** Every UI test builds its world only through `ContentTestHarness` (P1-31 Step 1): `CoreEnvironment.sandboxed(root:)` on a `MacxFixtures.Sandbox`, plus `LaunchOptions` with `stateDirectory`, `sandboxTrash`, `pasteboardName = "macx-tests-<UUID>"` (released in teardown), `fakeLaunchServices = true`, `skipOnboarding = true`. Tests never call `FileManager` write APIs on paths that didn't come from the harness.
- **S5-C2 No external side effects.** S5 code never opens System Settings, Terminal, Finder or any app directly. URLs go through `ExternalURLOpening` (P1-33), which records instead of opening when `options.isSandboxed || options.fakeLaunchServices`. Files and apps go through `LaunchServicesProviding` (`FakeLaunchServices` in sandboxed environments). Plain-text pasteboard writes go through `TextPasteboard` (P1-35), which never touches `NSPasteboard.general` in sandboxed runs.
- **S5-C3 No main-thread file-system calls (§4.4).** Cell configuration reads only `FolderModel`/`EntryStore` data. Icons come from `IconCache` (Tier 0 per type; Tier 1 on lanes). Menus read `LaunchServicesCache`. Drag validation uses `DropPolicy` with `Volumes.mountTable`. Properties uses `PropertiesLoader`/`FolderCounter`, and name checks run on a lane.
- **S5-C4 Model-owned selection (§5.5).** Never read `NSTableView.selectedRowIndexes` or `NSCollectionView.selectionIndexPaths` as truth. The table's highlight is a mirror written from `FolderModel.selection.rows`. The collection view has `isSelectable = false`.
- **S5-C5 Speed.** Cell configure must stay under 0.5 ms; the debug-build unit test asserts an average below 2 ms (4x, per the overview). Grid layout attributes are O(1), and elements in a rect are O(visible).
- **S5-C6 Strings.** Every user-visible string goes through `L10n.string(_:)`, and keys are the English text. Each task adds its keys with `scripts/l10n-add.sh` (created in P1-31). The task lists the exact keys.
- **S5-C7 GUI tests.** Tests that need a window call `try ContentTestHarness.requireWindowServer()` first. Without a GUI session it throws `XCTSkip("needs a GUI login session (window server)")`. Tests never order windows to the front unless they open a `BrowserWindowController` through `WindowManager`.
- **S5-C8 Eject.** No S5 test ejects or unmounts anything.

**Manual run recipe (used by every "Verify in the app" step; sandbox only):**

```bash
cd /Users/roniburd/dev/macExplorer
SANDBOX="$(mktemp -d "${TMPDIR%/}/macx-scenario-XXXXXX")"
mkdir -p "$SANDBOX/root/Sub Folder/Nested" "$SANDBOX/state" "$SANDBOX/trash"
for i in $(seq 1 40); do printf 'x%.0s' $(seq 1 $i) > "$SANDBOX/root/file$i.txt"; done
mkdir -p "$SANDBOX/root/Fake.app/Contents"
scripts/bundle.sh debug --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app
.build/macExplorer-scenarios.app/Contents/MacOS/macExplorer \
  --root "$SANDBOX/root" --state-dir "$SANDBOX/state" --sandbox-trash "$SANDBOX/trash" \
  --pasteboard "macx-manual-$(basename "$SANDBOX")" --fake-launch-services --skip-onboarding
# when done (quit the app first):
rm -rf "$SANDBOX"
```

For a 100k-row check, add this before launching (it writes only inside the sandbox):
`python3 -I -c 'import os,sys; d=sys.argv[1]; os.makedirs(d); [open(os.path.join(d, "f%06d.txt" % i), "w").close() for i in range(100000)]' "$SANDBOX/root/big"`

## Review Focus

These are the five input classes the spec implies for the content area that no spec-derived test would naturally exercise and that are most likely to bite a user, most likely first. Each one names the test its owning task must include. The overview's Review Focus item 2 also lands here (P1-34 `testInlineRenameRejectsNameOfHiddenItem`).

1. **Right-click on an item outside the current selection, versus inside a multi-selection.** Expected: right-clicking outside selects only that item and the menu acts on it. Right-clicking inside keeps the whole selection. "Paste" (into a folder) appears only when exactly one folder is the subject. Owner P1-35: `testRightClickOutsideSelectionSelectsOnlyThatRow`, `testRightClickInsideSelectionKeepsSelection`, `testItemMenuOffersPasteIntoOnlyForSingleFolder`.
2. **Live changes while an inline rename is open** (another app or the Watcher inserts or deletes rows). Expected: the field follows its item by identity to its new row, keeps the typed text, and closes without renaming if the item disappears. Owner P1-34: `testRenameFieldFollowsItemWhenRowsInsertedAbove`, `testRenameCancelsWhenItemDeletedExternally`.
3. **Names that stress text handling** (emoji and combining marks, `archive.tar.gz`, trailing dot `name.`, leading-dot names with an extension `.config.json`, 255-byte names, names with no spaces). Expected: the rename selection ends on a grapheme boundary before the last extension. Icon labels never split a grapheme, keep the extension visible when truncated, and fit two lines. Owner P1-34: `BaseNameRangeTests` (6 cases). Owner P1-32: `testTruncationKeepsGraphemesAndExtension`.
4. **Dropping onto a file, alias or package row, or between rows.** Expected: the drop goes into the displayed folder, never "into" a file. Packages (`.app`) count as files (§5.7), and spring-loading never opens them. Owner P1-36: `testDropOnFileOrPackageRowTargetsCurrentFolder`, `testSpringLoadingOnlyForFolders`.
5. **A job asks a question after its window has closed, or two jobs ask at once.** Expected: the question goes to the Operations panel, questions for the same host are shown one at a time, and none is lost or deadlocks. Owner P1-38: `testQuestionFromClosedOriginGoesToOperationsPanel`, `testConcurrentQuestionsAreSerializedPerHost`.

## File structure (this slice)

Files from the overview's §2 map that S5 owns, plus the files this slice adds (marked **new**), with one line of responsibility each.

```
scripts/l10n-add.sh                               [P1-31] new: add English String Catalog keys (jq)
Sources/UI/Support/Formatters.swift               [P1-31] size (ByteCountFormatter .file, folders "--"), relative/absolute dates, extension
Sources/UI/Support/IconCache.swift                [P1-31] Tier 0 per-UTType CGImages; Tier 1 per-file icons on lanes under no-materialization
Sources/UI/Support/ExternalURLOpener.swift        [P1-33] new: ExternalURLOpening (Workspace / Recording), System Settings links
Sources/UI/Content/FileListView.swift             [P1-31] FileListView protocol, RowUpdateSink, ChangeApplier, FocusableList
Sources/UI/Content/ObservationLoop.swift          [P1-31] new: re-arming withObservationTracking helper
Sources/UI/Content/CommandStateBuilder.swift      [P1-31] new: CommandState from a CommandTarget + session
Sources/UI/Content/ContentViewController.swift    [P1-31] host: command bar, list, empty state, banner, status bar; folder observer
Sources/UI/Content/SelectionController.swift      [P1-33] click/⌘/⇧/arrows/Home/End/Page → SelectionCommand
Sources/UI/Content/TypeSelect.swift               [P1-33] type-select buffer, fold-insensitive search (off main for big folders)
Sources/UI/Content/EmptyStateView.swift           [P1-33] EmptyStateContent (all §5.5 states) + overlay view
Sources/UI/Content/BannerView.swift               [P1-33] non-modal "'X' was moved or deleted" banner
Sources/UI/Content/InlineRenameController.swift   [P1-34] F2 field, base-name selection, Tab/⇧Tab, errors, warnings, relayout
Sources/UI/Details/DetailsColumns.swift           [P1-31] column defs, header menu, persistence, sort toggling, auto-fit
Sources/UI/Details/NameCellView.swift             [P1-31] NameCellView (icon + name), PlainCellView, CellStyle (cut dim + italic)
Sources/UI/Details/DetailsViewController.swift    [P1-31] FileTableView + NSTableView data source/delegate over FolderModel
Sources/UI/Icons/FileGridLayout.swift             [P1-32] GridMetrics + fixed-grid layout (O(1) frames, O(visible) rects)
Sources/UI/Icons/IconsViewController.swift        [P1-32] FileCollectionView, data source, rubber band, GridChangePolicy
Sources/UI/Icons/IconItem.swift                   [P1-32] grid item + LabelTruncation (two-line middle ellipsis)
Sources/UI/Commands/FileCommandController.swift   [P1-35] CommandHandler: dispatch, subjects/destinations, availability
Sources/UI/Commands/FileCommandController+Files.swift [P1-35] new: open, clipboard, trash/delete, new, rename, links, share, eject
Sources/UI/Commands/FileCommandController+View.swift  [P1-35] new: navigation, focus, window and view/sort commands
Sources/UI/Commands/CommandPrompts.swift          [P1-35] new: CommandPrompts protocol + AppKit alerts/panels; TextPasteboard
Sources/UI/Menus/ContextMenuBuilder.swift         [P1-35] item and empty-space menus, MenuActionBox, ClosureMenuItem, titles
Sources/UI/Menus/OpenWithMenu.swift               [P1-35] Open With submenu from LaunchServicesCache, "Loading…" in place
Sources/UI/OpenWith/DefaultAppSheet.swift         [P1-35] Choose Default App sheet + DefaultAppChoice
Sources/UI/DragDrop/DragSource.swift              [P1-36] DragPasteboard, DragImageComposer, DragSourceController (≤5 items)
Sources/UI/DragDrop/DropTarget.swift              [P1-36] DropTarget, DropRetarget, DropDestinationResolver, SpringLoadPolicy, promises
Sources/UI/DragDrop/RightDragTracker.swift        [P1-36] right-button threshold state machine
Sources/UI/DragDrop/DropMenu.swift                [P1-36] DropChoice + Copy/Move/Alias/Symlink Here/Cancel menu
Sources/UI/Properties/PropertiesWindowController.swift [P1-37] one window per selection set; undo-manager routing
Sources/UI/Properties/PropertiesViewModel.swift   [P1-37] @Observable state; edits → jobs; inline error + revert; NameAvailability
Sources/UI/Properties/PropertiesView.swift        [P1-37] SwiftUI General / Permissions / Opens with / Details / multi / volume
Sources/UI/Properties/PropertiesFormat.swift      [P1-37] new: display text, Tri helpers, TriCheckbox (also used by Compare)
Sources/UI/Operations/ErrorText.swift             [P1-34] new: rename-problem text (P1-34) + §6.5 job error text (P1-37)
Sources/UI/Operations/InteractionRouter.swift     [P1-38] FileOpInteraction → host (origin window or Operations panel), SerialGate
Sources/UI/Operations/ConflictDialog.swift        [P1-38] ConflictDialogModel + SwiftUI dialog, SheetHost, AppKitDialogPresenter
Sources/UI/Operations/CompareView.swift           [P1-38] CompareSelection + side-by-side checkboxes
Sources/UI/Operations/ErrorDialog.swift           [P1-38] ErrorDialogModel (§6.5 buttons), space and no-trash prompts
Sources/UI/Operations/OperationsCapsule.swift     [P1-38] CapsuleState + status-bar capsule
Sources/UI/Operations/OperationsListView.swift    [P1-38] JobTitle, JobRowModel, SwiftUI job rows with graph
Sources/UI/Operations/OperationsPanel.swift       [P1-38] Window › Operations NSPanel; OperationsUI (router + panel + list owner)

Tests/UITests/Support/ContentTestHarness.swift    [P1-31] new: sandbox + environment + context + waits + window hosting
Tests/UITests/FormattersTests.swift               [P1-31] new
Tests/UITests/IconCacheTests.swift                [P1-31] new
Tests/UITests/DetailsViewTests.swift              [P1-31]
Tests/UITests/FileGridLayoutTests.swift           [P1-32]
Tests/UITests/IconsViewTests.swift                [P1-32] new
Tests/UITests/SelectionControllerTests.swift      [P1-33]
Tests/UITests/TypeSelectTests.swift               [P1-33] new
Tests/UITests/EmptyStateTests.swift               [P1-33] new
Tests/UITests/InlineRenameTests.swift             [P1-34]
Tests/UITests/BaseNameRangeTests.swift            [P1-34] new
Tests/UITests/ContextMenuTests.swift              [P1-35]
Tests/UITests/FileCommandTests.swift              [P1-35] new
Tests/UITests/DragDropTests.swift                 [P1-36]
Tests/UITests/PropertiesViewModelTests.swift      [P1-37]
Tests/UITests/InteractionRouterTests.swift        [P1-38]
Tests/UITests/OperationsUITests.swift             [P1-38] new
```

Files this slice modifies that earlier slices created: `Sources/UI/App/UIContext.swift` (P1-31 `icons`, P1-38 `operationsUI`, router install, `showOperationsPanel()`), `Sources/UI/Window/BrowserSplitViewController.swift` (P1-31 content item), `Sources/UI/Window/BrowserWindowController.swift` (P1-35 handler install), `Sources/UI/Sidebar/SidebarViewController.swift` and `Sources/UI/Toolbar/BreadcrumbView.swift` plus the code that creates it (P1-36 drop destinations), `Sources/UI/Support/AXID.swift` (P1-38 `operationsPanel`), P1-30's Window › Operations handler in `Sources/UI/App/AppLifecycle.swift` or `Sources/App/AppDelegate.swift` (P1-38), `Sources/UI/Resources/Localizable.xcstrings` (every task).

---

### Task P1-31: Details view, content host, formatters and icon tiers

**Spec coverage:** §5.5 Details view (columns Name/Date Modified/Size/Kind/Date Created/Extension; choose from the header menu, reorder, resize, double-click a divider to auto-fit; header click sorts and a second click reverses; folders first; `ByteCountFormatter .file` with folders as `--`; relative or medium dates; density 20/24/30 pt; alternating rows; cut items at 50% and italic §8). §4.3 loading presentation (resets applied with `reloadData`, scroll anchor restored, stays at top if the user hasn't scrolled). §4.4 cell configure < 0.5 ms, type icons visible on the first frame (Tier 0), custom icons < 100 ms (Tier 1 on lanes under the materialization policy). §4.2 dataless items get a cloud badge. §5.5 status bar counts and free space (fetched on a lane, cached, refreshed on volume change, operation finish and volume events). §9 `OSSignposter` `firstPaint` and `iconFill`.

**Files:**
- Create: `scripts/l10n-add.sh`
- Create: `Sources/UI/Support/Formatters.swift`
- Create: `Sources/UI/Support/IconCache.swift`
- Create: `Sources/UI/Content/FileListView.swift`
- Create: `Sources/UI/Content/ObservationLoop.swift`
- Create: `Sources/UI/Content/CommandStateBuilder.swift`
- Create: `Sources/UI/Content/ContentViewController.swift`
- Create: `Sources/UI/Details/DetailsColumns.swift`
- Create: `Sources/UI/Details/NameCellView.swift`
- Create: `Sources/UI/Details/DetailsViewController.swift`
- Modify: `Sources/UI/App/UIContext.swift` (the `icons` property)
- Modify: `Sources/UI/Window/BrowserSplitViewController.swift` (the content split item)
- Modify: `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/Support/ContentTestHarness.swift`, `Tests/UITests/FormattersTests.swift`, `Tests/UITests/IconCacheTests.swift`, `Tests/UITests/DetailsViewTests.swift`

**Interfaces:**
- Consumes (overview §3, exact):
  - `FolderModel` (§3.7): `rowCount`, `entry(atRow:) -> Entry`, `name(atRow:) -> String`, `url(atRow:) -> URL`, `identity(atRow:) -> RowID`, `row(of: RowID) -> Int?`, `selection: Selection`, `selectionSummary: SelectionSummary`, `query: ViewQuery`, `setQuery(_:)`, `scrollAnchor: RowID?`, `cutNames: Set<String>`, `isCut(row:) -> Bool`, `volume: VolumeInfo?`, `directory: URL`, `applyLocalChange(_:)`, `observe(_:) -> ObserverToken`; `FolderEvent`; `ChangeSet.changes/requiresReloadData/isEmpty`; `Change`.
  - `Settings` (§3.9): `columns: [ColumnSetting]`, `sort`, `density`, `dateStyle`, `commandBarVisible`, `returnKey`; `ColumnID.sortField`; `Density.rowHeight`.
  - `TypeRegistry.type(at:)`, `localizedDescription(_:)`, `isApplication(_:)`; `LanePool.perform(on:_:stallPolicy:onStall:_:)`; `withNoMaterialization(_:)`; `PerfSignposts.signposter`, `.firstPaint`, `.iconFill`.
  - `Volumes.mountTable`, `volume(for:)`, `cachedAvailableCapacity(_:)`, `refreshAvailableCapacity(_:) async -> Int64?`, `observe(_:)`; `OperationsCenter.onFinished(_:)`; `Clipboard.canPaste`; `FileOpUndoStack.canUndo/canRedo`.
  - S4: `UIContext.environment/options/icons`, `BrowserSession.folder/history/viewMode/observe(_:)`, `SessionEvent`, `CommandHandlingViewController` (`focusContext`, `commandTarget`, `handler`), `CommandTarget`, `CommandBarView.update(state:focus:shiftHeld:)`, `StatusBarView.update(itemCount:selection:available:)`, `KeyRouter.handle(_:focus:returnKey:from:)`, `AXID.detailsTable`, `L10n.string(_:)`.
- Produces (overview §3.14, exact):
  - `@MainActor protocol FileListView: AnyObject { var view: NSView { get }; var folder: FolderModel? { get }; func bind(_ folder: FolderModel?); func apply(_ changes: ChangeSet); func reloadSelectionDrawing(); func beginInlineRename(row: Int); func scrollToRow(_ row: Int); func topVisibleRow() -> Int?; func visibleRows() -> Range<Int> }`
  - `@MainActor final class ContentViewController: CommandHandlingViewController { init(context: UIContext, session: BrowserSession); var activeList: FileListView { get }; func setViewMode(_ mode: ViewMode) }`
  - `@MainActor final class DetailsViewController: NSViewController, FileListView { init(context: UIContext) }`
  - `@MainActor final class IconCache { init(lanes: LanePool, types: TypeRegistry); func typeIcon(_ typeIndex: UInt16, points: Double, scale: Double) -> CGImage; func fileIcon(for url: URL, rowID: RowID, points: Double, scale: Double, completion: @escaping @MainActor (CGImage) -> Void); func cancelFileIcons(notIn visible: Set<RowID>) }`
  - Internal, used by later S5 tasks: `Formatters.size(of:)`, `.bytes(_:)`, `.date(nanoseconds:style:now:calendar:locale:)`, `.date(_:style:now:calendar:locale:)`, `.extensionText(name:kind:)`; `IconCache.needsFileIcon(_:name:isVolumeRoot:) -> Bool`, `IconCache.volumeLookup`; `RowUpdateSink`, `ChangeApplier.apply(_:to:)`, `FocusableList.focusView`; `ObservationLoop(_:onChange:)`; `CommandStateBuilder.state(for:session:environment:) -> CommandState`; `CellStyle.apply(isCut:to:container:)`; `DetailsViewController.tableView: FileTableView`, `.scrollRowToTop(_:)`, `.cellView(row:column:)`; `ContentViewController.details`, `.stack`, `.listContainer`, `.statusBar`, `.commandBar`, `.bind(_:)`, `.handle(_: FolderEvent)`, `.updateStatus()`, `.updateCommandBar()`, `.mount(_:)`; `NSViewController.firstDescendant(of:)`.

- [ ] **Step 1: Add the shared test harness**

The harness is the only way S5 tests touch the file system. Fixture files live under `<sandbox>/files`, because `CoreEnvironment.sandboxed(root:)` puts `state/` and `.trash/` directly in the sandbox root, and those must not show up in listings.

```swift
// Tests/UITests/Support/ContentTestHarness.swift
import XCTest
import AppKit
import Darwin
@testable import UI
import Core
import MacxFS
import MacxFixtures

enum HarnessError: Error { case timeout(String), posix(String, Int32) }

/// Global Constraints S5-C1: every S5 test builds its world here, and all writes stay under `sandbox.root`.
@MainActor
final class ContentTestHarness {
    let sandbox: Sandbox
    let filesRoot: URL
    let environment: CoreEnvironment
    let context: UIContext
    let pasteboardName: String
    private var hostedWindows: [NSWindow] = []
    private var models: [FolderModel] = []
    private var lockedPaths: [String] = []
    private var restrictedPaths: [String] = []

    static func make(_ testCase: XCTestCase) async throws -> ContentTestHarness {
        let harness = try ContentTestHarness()
        testCase.addTeardownBlock { @MainActor in await harness.tearDown() }
        _ = await harness.environment.start()
        return harness
    }

    static func requireWindowServer() throws {
        if NSScreen.screens.isEmpty { throw XCTSkip("needs a GUI login session (window server)") }
    }

    private init() throws {
        _ = NSApplication.shared
        // The only calls into the P1-02 Sandbox API (S1 P1-02 Interfaces, exact): Sandbox(prefix:), .root,
        // .createDirectory(_:), .createFile(_:contents:), plus .destroy() in tearDown.
        sandbox = try Sandbox(prefix: "macx-tests")
        filesRoot = try sandbox.createDirectory("files")
        environment = CoreEnvironment.sandboxed(root: sandbox.root)
        pasteboardName = "macx-tests-\(UUID().uuidString)"
        var options = LaunchOptions()
        options.root = filesRoot
        options.stateDirectory = sandbox.root.appending(path: "state", directoryHint: .isDirectory)
        options.sandboxTrash = sandbox.root.appending(path: ".trash", directoryHint: .isDirectory)
        options.pasteboardName = pasteboardName
        options.fakeLaunchServices = true
        options.skipOnboarding = true
        context = UIContext(environment: environment, options: options)
    }

    func url(_ relative: String) -> URL {
        relative.isEmpty ? filesRoot : filesRoot.appending(path: relative)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 1) throws -> URL {
        try sandbox.createFile("files/" + relative, contents: Data(repeating: 0x78, count: bytes))
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        try sandbox.createDirectory("files/" + relative)
    }

    /// chflags on a harness path (UF_HIDDEN, UF_IMMUTABLE). Locked paths are unlocked again in tearDown.
    func setFlags(_ relative: String, _ flags: Int32) throws {
        let path = url(relative).path
        guard chflags(path, UInt32(flags)) == 0 else { throw HarnessError.posix("chflags \(path)", errno) }
        if flags & UF_IMMUTABLE != 0 { lockedPaths.append(path) }
    }

    /// chmod on a harness path; restored to 0755 in tearDown so the sandbox can be removed.
    func setMode(_ relative: String, _ mode: mode_t) throws {
        let path = url(relative).path
        guard chmod(path, mode) == 0 else { throw HarnessError.posix("chmod \(path)", errno) }
        restrictedPaths.append(path)
    }

    func exists(_ relative: String) -> Bool {
        var st = Darwin.stat()
        return lstat(url(relative).path, &st) == 0
    }

    func lstatInfo(_ relative: String) -> Darwin.stat? {
        var st = Darwin.stat()
        return lstat(url(relative).path, &st) == 0 ? st : nil
    }

    func openFolder(_ relative: String = "", query: ViewQuery = ViewQuery()) async throws -> FolderModel {
        let model = environment.makeFolderModel(url(relative), query: query)
        models.append(model)
        model.start()
        try await waitUntil("folder '\(relative)' complete") { model.state == .complete }
        return model
    }

    /// An offscreen window (never ordered front) hosting `controller`.
    @discardableResult
    func host(_ controller: NSViewController, size: NSSize = NSSize(width: 900, height: 600)) throws -> NSWindow {
        try Self.requireWindowServer()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.layoutIfNeeded()
        hostedWindows.append(window)
        return window
    }

    func makeContent(_ relative: String = "", size: NSSize = NSSize(width: 900, height: 600))
        async throws -> (ContentViewController, BrowserSession, NSWindow) {
        try Self.requireWindowServer()
        let session = BrowserSession(environment: environment, initialURL: url(relative))
        let content = ContentViewController(context: context, session: session)
        let window = try host(content, size: size)
        try await waitUntil("session folder complete") { session.folder.state == .complete }
        return (content, session, window)
    }

    /// A real browser window from WindowManager (ordered front by S4 code; closed in tearDown).
    func openBrowserWindow(_ relative: String = "") async throws -> BrowserWindowController {
        try Self.requireWindowServer()
        let controller = context.windows.openWindow(at: url(relative))
        try await waitUntil("window folder complete") { controller.session.folder.state == .complete }
        return controller
    }

    func content(of controller: BrowserWindowController) throws -> ContentViewController {
        try XCTUnwrap(controller.contentViewController?.firstDescendant(of: ContentViewController.self))
    }

    func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw HarnessError.timeout(what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func tearDown() async {
        for controller in context.windows.windows { controller.close() }
        for window in hostedWindows { window.close() }
        for model in models { model.close() }
        await environment.fileOps.waitUntilIdle()
        for path in lockedPaths { _ = chflags(path, 0) }
        for path in restrictedPaths { _ = chmod(path, 0o755) }
        NSPasteboard(name: NSPasteboard.Name(pasteboardName)).releaseGlobally()
        sandbox.destroy()
    }
}
```

- [ ] **Step 2: Write the failing formatter and icon tests**

```swift
// Tests/UITests/FormattersTests.swift
import XCTest
@testable import UI
import Core
import MacxFS

@MainActor
final class FormattersTests: XCTestCase {
    private func entry(_ kind: Kind, size: Int64 = 0) -> Entry {
        Entry(rowID: 1, fileID: 1, size: size, allocSize: size, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 1,
              kind: kind, flags: [], typeIndex: TypeRegistry.dataIndex)
    }
    private var gmt: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "GMT")!
        return c
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testFolderAndPackageSizeIsDashes() {
        XCTAssertEqual(Formatters.size(of: entry(.directory, size: 42)), "--")
        XCTAssertEqual(Formatters.size(of: entry(.package, size: 42)), "--")
    }

    func testFileSizeUsesDecimalFileStyle() {
        XCTAssertEqual(Formatters.size(of: entry(.file, size: 1_500_000)),
                       ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file))
        XCTAssertNotEqual(Formatters.bytes(1_500_000),
                          ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .binary))
    }

    func testRelativeTodayAndYesterday() {
        let now = date("2026-11-02T12:00:00Z")
        let en = Locale(identifier: "en_GB")
        XCTAssertEqual(Formatters.date(date("2026-11-02T18:02:00Z"), style: .relative, now: now, calendar: gmt, locale: en),
                       "Today 18:02")
        XCTAssertEqual(Formatters.date(date("2026-11-01T09:15:00Z"), style: .relative, now: now, calendar: gmt, locale: en),
                       "Yesterday 09:15")
    }

    func testOlderDatesAndAbsoluteStyleNeverSayToday() {
        let now = date("2026-11-02T12:00:00Z")
        let en = Locale(identifier: "en_GB")
        let older = Formatters.date(date("2026-10-30T08:00:00Z"), style: .relative, now: now, calendar: gmt, locale: en)
        XCTAssertTrue(older.contains("2026"), older)
        let absolute = Formatters.date(date("2026-11-02T18:02:00Z"), style: .absolute, now: now, calendar: gmt, locale: en)
        XCTAssertFalse(absolute.contains("Today"), absolute)
        XCTAssertTrue(absolute.contains("18:02"), absolute)
    }

    func testExtensionText() {
        XCTAssertEqual(Formatters.extensionText(name: "a.tar.gz", kind: .file), "gz")
        XCTAssertEqual(Formatters.extensionText(name: ".env", kind: .file), "")
        XCTAssertEqual(Formatters.extensionText(name: "name.", kind: .file), "")
        XCTAssertEqual(Formatters.extensionText(name: "My.Folder", kind: .directory), "")
        XCTAssertEqual(Formatters.extensionText(name: "Safari.app", kind: .package), "app")
    }
}
```

```swift
// Tests/UITests/IconCacheTests.swift
import XCTest
@testable import UI
import Core
import MacxFS

@MainActor
final class IconCacheTests: XCTestCase {
    private func entry(_ kind: Kind, flags: EntryFlags = [], type: UInt16 = TypeRegistry.dataIndex) -> Entry {
        Entry(rowID: 7, fileID: 7, size: 1, allocSize: 1, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 1,
              kind: kind, flags: flags, typeIndex: type)
    }

    func testTypeIconIsCachedAndSizedInPixels() async throws {
        let h = try await ContentTestHarness.make(self)
        let a = h.context.icons.typeIcon(TypeRegistry.folderIndex, points: 32, scale: 2)
        let b = h.context.icons.typeIcon(TypeRegistry.folderIndex, points: 32, scale: 2)
        XCTAssertTrue(a === b, "Tier 0 icons are rasterized once per (type, pixel size)")
        XCTAssertEqual(a.width, 64)
        XCTAssertEqual(h.context.icons.typeIcon(TypeRegistry.folderIndex, points: 16, scale: 1).width, 16)
    }

    func testTier1OnlyForAppsIcnsCustomIconsAndVolumes() async throws {
        let h = try await ContentTestHarness.make(self)
        let icons = h.context.icons
        let app = TypeRegistry.shared.index(forExtension: "app", isDirectory: true)
        XCTAssertTrue(icons.needsFileIcon(entry(.package, type: app), name: "Fake.app", isVolumeRoot: false))
        XCTAssertTrue(icons.needsFileIcon(entry(.file), name: "Icon.ICNS", isVolumeRoot: false))
        XCTAssertTrue(icons.needsFileIcon(entry(.file, flags: .customIcon), name: "a.txt", isVolumeRoot: false))
        XCTAssertTrue(icons.needsFileIcon(entry(.directory), name: "Disk", isVolumeRoot: true))
        XCTAssertFalse(icons.needsFileIcon(entry(.file), name: "a.txt", isVolumeRoot: false))
        XCTAssertFalse(icons.needsFileIcon(entry(.directory), name: "Sub", isVolumeRoot: false))
        XCTAssertFalse(icons.needsFileIcon(entry(.file, flags: [.customIcon, .dataless]), name: "c.txt", isVolumeRoot: false),
                       "dataless items are never probed (§4.2)")
    }

    func testFileIconCompletesForAppBundle() async throws {
        let h = try await ContentTestHarness.make(self)
        let app = try h.dir("Fake.app/Contents").deletingLastPathComponent()
        var image: CGImage?
        h.context.icons.fileIcon(for: app, rowID: .name("Fake.app"), points: 16, scale: 2) { image = $0 }
        try await h.waitUntil("tier 1 icon", timeout: .seconds(3)) { image != nil }
        XCTAssertEqual(image?.width, 32)
    }

    func testCancelledFileIconNeverCallsBack() async throws {
        let h = try await ContentTestHarness.make(self)
        let app = try h.dir("Other.app/Contents").deletingLastPathComponent()
        var called = false
        h.context.icons.fileIcon(for: app, rowID: .name("Other.app"), points: 16, scale: 2) { _ in called = true }
        h.context.icons.cancelFileIcons(notIn: [])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(called)
    }
}
```

- [ ] **Step 3: Write the failing Details view tests**

```swift
// Tests/UITests/DetailsViewTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
private final class RecordingSink: RowUpdateSink {
    var log: [String] = []
    func reloadAll() { log.append("reloadAll") }
    func beginRowUpdates() { log.append("begin") }
    func insertRows(_ rows: IndexSet) { log.append("insert\(Array(rows))") }
    func removeRows(_ rows: IndexSet) { log.append("remove\(Array(rows))") }
    func moveRow(_ from: Int, _ to: Int) { log.append("move\(from)>\(to)") }
    func reloadRows(_ rows: IndexSet) { log.append("reload\(Array(rows))") }
    func endRowUpdates() { log.append("end") }
}

@MainActor
final class DetailsViewTests: XCTestCase {
    // MARK: pure

    func testChangeApplierReloadsForResetAndLargeSets() {
        let sink = RecordingSink()
        ChangeApplier.apply(.reset, to: sink)
        ChangeApplier.apply(ChangeSet([.insert(IndexSet(integersIn: 0..<1_500))]), to: sink)
        XCTAssertEqual(sink.log, ["reloadAll", "reloadAll"])
    }

    func testChangeApplierAppliesSmallSetsInOrderWithReloadsLast() {
        let sink = RecordingSink()
        ChangeApplier.apply(ChangeSet([.reload(IndexSet(integer: 4)), .remove(IndexSet(integer: 1)),
                                       .insert(IndexSet(integer: 2)), .move(from: 0, to: 3)]), to: sink)
        XCTAssertEqual(sink.log, ["begin", "remove[1]", "insert[2]", "move0>3", "end", "reload[4]"])
        let empty = RecordingSink()
        ChangeApplier.apply(ChangeSet([]), to: empty)
        XCTAssertEqual(empty.log, [])
    }

    func testNextSortTogglesAndSwitchesField() {
        let byName = SortDescriptor(field: .name, ascending: true)
        XCTAssertEqual(DetailsColumns.nextSort(current: byName, clicked: .name), SortDescriptor(field: .name, ascending: false))
        XCTAssertEqual(DetailsColumns.nextSort(current: byName, clicked: .size), SortDescriptor(field: .size, ascending: true))
        XCTAssertEqual(DetailsColumns.nextSort(current: SortDescriptor(field: .size, ascending: true), clicked: .size),
                       SortDescriptor(field: .size, ascending: false))
    }

    func testColumnSettingsNormalizeAndToggle() {
        let messy = [ColumnSetting(id: .size, width: 10, visible: true), ColumnSetting(id: .name, width: 300, visible: false),
                     ColumnSetting(id: .size, width: 99, visible: false)]
        let normalized = DetailsColumns.normalized(messy)
        XCTAssertEqual(normalized.map(\.id).count, ColumnID.allCases.count, "every column exactly once")
        XCTAssertEqual(normalized.first?.id, .size, "stored order wins")
        XCTAssertEqual(normalized.first?.width, DetailsColumns.minWidth(.size), "width clamped to the minimum")
        XCTAssertEqual(normalized.first { $0.id == .name }?.visible, true, "Name can't be hidden")
        let toggled = DetailsColumns.toggling(normalized, .kind)
        XCTAssertNotEqual(toggled.first { $0.id == .kind }?.visible, normalized.first { $0.id == .kind }?.visible)
        XCTAssertEqual(DetailsColumns.toggling(normalized, .name).first { $0.id == .name }?.visible, true)
    }

    // MARK: AppKit (offscreen window)

    private func makeDetails(_ h: ContentTestHarness) async throws -> (DetailsViewController, FolderModel) {
        h.environment.settings.columns = DetailsColumns.defaults
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        try h.host(details)
        details.bind(folder)
        return (details, folder)
    }

    func testRowsFollowModelFoldersFirst() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("b.txt", bytes: 1_234); try h.file("a.txt"); try h.dir("zdir")
        let (details, _) = try await makeDetails(h)
        XCTAssertEqual(details.tableView.numberOfRows, 3)
        XCTAssertEqual(details.cellView(row: 0, column: .name)?.textField?.stringValue, "zdir")
        XCTAssertEqual(details.cellView(row: 0, column: .size)?.textField?.stringValue, "--")
        XCTAssertEqual(details.cellView(row: 2, column: .size)?.textField?.stringValue,
                       ByteCountFormatter.string(fromByteCount: 1_234, countStyle: .file))
        XCTAssertTrue(details.tableView.usesAlternatingRowBackgroundColors)
        XCTAssertEqual(details.tableView.accessibilityIdentifier(), AXID.detailsTable)
    }

    func testCutRowsAreDimmedAndItalic() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let (details, folder) = try await makeDetails(h)
        folder.cutNames = ["a.txt"]
        details.reloadSelectionDrawing()
        let row = try XCTUnwrap(folder.row(named: "a.txt"))
        let cut = try XCTUnwrap(details.cellView(row: row, column: .name) as? NameCellView)
        XCTAssertEqual(cut.alphaValue, 0.5, accuracy: 0.001)
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(cut.label.font)).contains(.italicFontMask))
        let other = try XCTUnwrap(details.cellView(row: 1 - row, column: .name) as? NameCellView)
        XCTAssertEqual(other.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(details.cellView(row: row, column: .size)?.alphaValue ?? 0, 0.5, accuracy: 0.001)
    }

    func testDensityChangesRowHeight() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (details, _) = try await makeDetails(h)
        h.environment.settings.density = .compact
        try await h.waitUntil("compact rows") { details.tableView.rowHeight == 20 }
        h.environment.settings.density = .comfortable
        try await h.waitUntil("comfortable rows") { details.tableView.rowHeight == 30 }
    }

    func testHeaderClickSortsAndPersists() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("big.txt", bytes: 3_000); try h.file("small.txt", bytes: 10); try h.file("mid.txt", bytes: 500)
        let (details, folder) = try await makeDetails(h)
        let sizeColumn = try XCTUnwrap(details.tableView.tableColumns.first { DetailsColumns.columnID($0.identifier) == .size })
        details.tableView(details.tableView, didClick: sizeColumn)
        try await h.waitUntil("ascending by size") { (0..<3).map(folder.name(atRow:)) == ["small.txt", "mid.txt", "big.txt"] }
        details.tableView(details.tableView, didClick: sizeColumn)
        try await h.waitUntil("descending by size") { (0..<3).map(folder.name(atRow:)) == ["big.txt", "mid.txt", "small.txt"] }
        XCTAssertEqual(h.environment.settings.sort, SortDescriptor(field: .size, ascending: false))
        XCTAssertNotNil(details.tableView.indicatorImage(in: sizeColumn))
    }

    func testHidingColumnPersistsToSettings() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (details, _) = try await makeDetails(h)
        let item = try XCTUnwrap(details.tableView.headerView?.menu?.items.first { $0.representedObject as? String == ColumnID.kind.rawValue })
        details.toggleColumn(item)
        XCTAssertEqual(h.environment.settings.columns.first { $0.id == .kind }?.visible, false)
        XCTAssertEqual(details.tableView.tableColumns.first { DetailsColumns.columnID($0.identifier) == .kind }?.isHidden, true)
    }

    func testColumnMovePersistsOrder() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (details, _) = try await makeDetails(h)
        let moved = DetailsColumns.columnID(details.tableView.tableColumns[1].identifier)
        details.tableView.moveColumn(1, toColumn: 3)
        XCTAssertEqual(h.environment.settings.columns.map(\.id)[3], moved)
    }

    func testLocalChangeInsertsRowThroughContentController() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let (content, session, _) = try await h.makeContent()
        XCTAssertEqual(content.details.tableView.numberOfRows, 2)
        try h.file("new.txt")
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), added: ["new.txt"]))
        try await h.waitUntil("row inserted") { content.details.tableView.numberOfRows == 3 }
        XCTAssertNotNil(session.folder.row(named: "new.txt"))
    }

    func testScrollAnchorSurvivesResort() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<300 { try h.file(String(format: "f%03d.txt", i)) }
        let (content, session, _) = try await h.makeContent(size: NSSize(width: 800, height: 400))
        let details = content.details
        details.scrollRowToTop(150)
        let anchor = try XCTUnwrap(session.folder.scrollAnchor, "scrolling records the top row's identity")
        XCTAssertEqual(session.folder.row(of: anchor), 150)
        var query = session.folder.query
        query.sort = SortDescriptor(field: .name, ascending: false)
        session.folder.setQuery(query)
        try await h.waitUntil("re-sorted") { session.folder.row(of: anchor) == 149 }
        try await h.waitUntil("anchor row back on top") { details.topVisibleRow() == 149 }
    }

    func testScrollAtTopKeepsNoAnchor() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<100 { try h.file(String(format: "f%03d.txt", i)) }
        let (content, session, _) = try await h.makeContent(size: NSSize(width: 800, height: 300))
        content.details.scrollRowToTop(40)
        XCTAssertNotNil(session.folder.scrollAnchor)
        content.details.scrollRowToTop(0)
        XCTAssertNil(session.folder.scrollAnchor, "at the top there is no anchor, so resets keep the view at the top")
    }

    func testCellConfigureIsFast() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<1_000 { try h.file(String(format: "n%04d.txt", i), bytes: i) }
        let (details, _) = try await makeDetails(h)
        let columns = details.tableView.tableColumns.filter { !$0.isHidden }
        let start = ContinuousClock.now
        for row in 0..<1_000 { for column in columns { _ = details.tableView(details.tableView, viewFor: column, row: row) } }
        let perCell = (ContinuousClock.now - start) / (1_000 * columns.count)
        XCTAssertLessThan(perCell, .milliseconds(2), "budget 0.5 ms (§4.4); debug tests allow 4x")
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `swift test --filter 'UITests\.(FormattersTests|IconCacheTests|DetailsViewTests)' 2>&1 | tail -20`
Expected: compile errors such as `cannot find 'Formatters' in scope`, `cannot find type 'RowUpdateSink' in scope`, `cannot find 'DetailsViewController' in scope`.

- [ ] **Step 5: Add the string-catalog script and this task's keys**

```bash
#!/bin/bash
# scripts/l10n-add.sh: add English String Catalog entries whose key is the English text.
# Usage: scripts/l10n-add.sh "Key one" "Key %@ two" ...
set -euo pipefail
cd "$(dirname "$0")/.."
catalog=Sources/UI/Resources/Localizable.xcstrings
tmp="$(mktemp "${TMPDIR:-/tmp}/macx-xcstrings-XXXXXX")"
jq '.strings += ([$ARGS.positional[] | {(.): {"extractionState": "manual", "localizations": {"en": {"stringUnit": {"state": "translated", "value": .}}}}}] | add // {})' \
  "$catalog" --args "$@" > "$tmp"
mv "$tmp" "$catalog"
```

Run:
```bash
chmod +x scripts/l10n-add.sh
scripts/l10n-add.sh "Name" "Date Modified" "Size" "Kind" "Date Created" "Extension" "Columns" \
  "Today %@" "Yesterday %@" "%@, cut" "In iCloud, not downloaded"
jq -r '.strings | keys | length' Sources/UI/Resources/Localizable.xcstrings
```
Expected: a number at least 11 (plus the keys earlier tasks added).

- [ ] **Step 6: Implement formatters and the icon cache**

```swift
// Sources/UI/Support/Formatters.swift
import Foundation
import Core
import MacxFS

/// Display formatting for list cells (§5.5). Main-actor only; formatters are cached.
@MainActor
enum Formatters {
    static let folderSize = "--"

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file      // decimal, as Finder (§5.5)
        return formatter
    }()
    private static var dateFormatters: [String: DateFormatter] = [:]
    private static var timeFormatters: [String: DateFormatter] = [:]

    /// Folders and packages show "--": no folder sizes in Phase 1 (Entry.size of a directory is its entry count).
    static func size(of entry: Entry) -> String {
        entry.kind == .directory || entry.kind == .package ? folderSize : bytes(entry.size)
    }

    static func bytes(_ count: Int64) -> String { byteFormatter.string(fromByteCount: count) }

    static func date(nanoseconds: Int64, style: DateStyle, now: Date = Date(),
                     calendar: Calendar = .current, locale: Locale = .current) -> String {
        date(Date(timeIntervalSince1970: TimeInterval(nanoseconds) / 1_000_000_000),
             style: style, now: now, calendar: calendar, locale: locale)
    }

    /// Relative: "Today 18:02", "Yesterday 09:15", otherwise medium date + short time. Absolute: always the latter.
    static func date(_ date: Date, style: DateStyle, now: Date = Date(),
                     calendar: Calendar = .current, locale: Locale = .current) -> String {
        if style == .relative {
            let time = formatter(&timeFormatters, locale: locale, calendar: calendar, dateStyle: .none).string(from: date)
            if calendar.isDate(date, inSameDayAs: now) { return String(format: L10n.string("Today %@"), time) }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
                return String(format: L10n.string("Yesterday %@"), time)
            }
        }
        return formatter(&dateFormatters, locale: locale, calendar: calendar, dateStyle: .medium).string(from: date)
    }

    /// Extension column: text after the last "." for non-folders; "" for dot-files, trailing dots and folders.
    static func extensionText(name: String, kind: Kind) -> String {
        guard kind != .directory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    private static func formatter(_ cache: inout [String: DateFormatter], locale: Locale, calendar: Calendar,
                                  dateStyle: DateFormatter.Style) -> DateFormatter {
        let key = "\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .short
        cache[key] = formatter
        return formatter
    }
}
```

```swift
// Sources/UI/Support/IconCache.swift
import AppKit
import UniformTypeIdentifiers
import os
import Core
import MacxFS

/// §4.4 icon tiers. Tier 0: one NSWorkspace type icon per (UTType, pixel size), rasterized once, available on the
/// first frame. Tier 1: per-file icons for apps, volumes, .icns files and custom-icon items, fetched for visible
/// rows only on a read lane under withNoMaterialization. Tier 2 (thumbnails) is Phase 2.
@MainActor
final class IconCache {
    private struct TypeKey: Hashable { let type: UInt16; let pixels: Int }
    private struct FileKey: Hashable { let id: RowID; let path: String; let pixels: Int }

    static let fileCacheLimit = 2_000
    private let lanes: LanePool
    private let types: TypeRegistry
    private var typeImages: [TypeKey: CGImage] = [:]
    private var fileImages: [FileKey: CGImage] = [:]
    private var fileOrder: [FileKey] = []
    private var pending: [FileKey: Task<Void, Never>] = [:]
    private var waiting: [FileKey: [@MainActor (CGImage) -> Void]] = [:]
    private var iconFill: OSSignpostIntervalState?
    /// Volume for a URL's lane (set by ContentViewController from Volumes); VolumeID.unknown when nil.
    var volumeLookup: (@MainActor (URL) -> VolumeID)?

    init(lanes: LanePool, types: TypeRegistry) {
        self.lanes = lanes
        self.types = types
    }

    func typeIcon(_ typeIndex: UInt16, points: Double, scale: Double) -> CGImage {
        let pixels = max(1, Int((points * scale).rounded()))
        let key = TypeKey(type: typeIndex, pixels: pixels)
        if let cached = typeImages[key] { return cached }
        let image = NSWorkspace.shared.icon(for: types.type(at: typeIndex))   // per type, not per path (§4.4 Tier 0)
        let raster = Self.rasterize(image, pixels: pixels) ?? Self.blank(pixels: pixels)
        typeImages[key] = raster
        return raster
    }

    /// Tier 1 eligibility (§4.4): apps, volume roots, .icns files and custom-icon items; never dataless items.
    func needsFileIcon(_ entry: Entry, name: String, isVolumeRoot: Bool) -> Bool {
        if entry.flags.contains(.dataless) { return false }
        if entry.flags.contains(.customIcon) || isVolumeRoot { return true }
        if entry.kind == .package && types.isApplication(entry.typeIndex) { return true }
        return entry.kind == .file && name.lowercased().hasSuffix(".icns")
    }

    func fileIcon(for url: URL, rowID: RowID, points: Double, scale: Double,
                  completion: @escaping @MainActor (CGImage) -> Void) {
        let pixels = max(1, Int((points * scale).rounded()))
        let key = FileKey(id: rowID, path: url.path, pixels: pixels)
        if let cached = fileImages[key] { completion(cached); return }
        if waiting[key] != nil { waiting[key]?.append(completion); return }
        waiting[key] = [completion]
        if pending.isEmpty { iconFill = PerfSignposts.signposter.beginInterval(PerfSignposts.iconFill) }
        let volume = volumeLookup?(url) ?? .unknown
        let lanes = self.lanes
        let path = url.path
        pending[key] = Task { [weak self] in
            let image: CGImage? = try? await lanes.perform(on: volume, .read) { _ in
                withNoMaterialization {
                    IconCache.rasterize(NSWorkspace.shared.icon(forFile: path), pixels: pixels)
                }
            }
            self?.landed(key, image: image)
        }
    }

    func cancelFileIcons(notIn visible: Set<RowID>) {
        for (key, task) in pending where !visible.contains(key.id) {
            task.cancel()
            pending[key] = nil
            waiting[key] = nil
        }
        endIconFillIfIdle()
    }

    private func landed(_ key: FileKey, image: CGImage?) {
        pending[key] = nil
        let callbacks = waiting.removeValue(forKey: key) ?? []
        if let image {
            if fileImages[key] == nil { fileOrder.append(key) }
            fileImages[key] = image
            if fileOrder.count > Self.fileCacheLimit { fileImages[fileOrder.removeFirst()] = nil }
            for callback in callbacks { callback(image) }
        }
        endIconFillIfIdle()
    }

    private func endIconFillIfIdle() {
        guard pending.isEmpty, let state = iconFill else { return }
        PerfSignposts.signposter.endInterval(PerfSignposts.iconFill, state)
        iconFill = nil
    }

    nonisolated static func rasterize(_ image: NSImage, pixels: Int) -> CGImage? {
        let side = max(pixels, 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func blank(pixels: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
```

UIContext: the overview §3.14 assigns `UIContext.icons: IconCache` to this task (P1-26 declares `UIContext` without it, because the type is created here). Run `grep -rn "IconCache" Sources/UI`. If P1-26 nevertheless left a placeholder `IconCache` class or an `icons` property anywhere, delete the placeholder, since this file replaces it. In `Sources/UI/App/UIContext.swift` make sure the class declares `let icons: IconCache` (internal, like the type) and that `init` contains exactly this line (add it after `self.options = options` if it is missing):

```swift
        self.icons = IconCache(lanes: environment.lanes, types: environment.types)
```

- [ ] **Step 7: Implement the list protocol, change application, observation helper and command state**

```swift
// Sources/UI/Content/FileListView.swift
import AppKit
import Core

/// Shared by Details and Icons (§5.5). The content controller is the only FolderModel observer and forwards
/// changes here; views never keep their own selection.
@MainActor protocol FileListView: AnyObject {
    var view: NSView { get }
    var folder: FolderModel? { get }
    func bind(_ folder: FolderModel?)                    // nil = unbind
    func apply(_ changes: ChangeSet)                     // insert/remove/move/reload or reloadData (requiresReloadData)
    func reloadSelectionDrawing()
    func beginInlineRename(row: Int)
    func scrollToRow(_ row: Int)
    func topVisibleRow() -> Int?                          // scroll anchor
    func visibleRows() -> Range<Int>                      // Tier 1 icon requests
}

/// Lists that take keyboard focus (Tab cycle, view switches keep focus on the list).
@MainActor protocol FocusableList: AnyObject {
    var focusView: NSView { get }
}

/// Target of ChangeApplier (NSTableView in production, a recorder in tests).
@MainActor protocol RowUpdateSink {
    func reloadAll()
    func beginRowUpdates()
    func insertRows(_ rows: IndexSet)
    func removeRows(_ rows: IndexSet)
    func moveRow(_ from: Int, _ to: Int)
    func reloadRows(_ rows: IndexSet)
    func endRowUpdates()
}

@MainActor
enum ChangeApplier {
    /// §4.3: a reset or more than ~1,000 touched rows → reloadData with no animation. Otherwise structural changes
    /// in order inside one begin/end pair (NSTableView semantics), then reloads, which use final indices.
    static func apply(_ set: ChangeSet, to sink: some RowUpdateSink) {
        if set.isEmpty { return }
        if set.requiresReloadData { sink.reloadAll(); return }
        var reloads = IndexSet()
        sink.beginRowUpdates()
        for change in set.changes {
            switch change {
            case .insert(let rows): sink.insertRows(rows)
            case .remove(let rows): sink.removeRows(rows)
            case .move(let from, let to): sink.moveRow(from, to)
            case .reload(let rows): reloads.formUnion(rows)
            case .reset: break   // covered by requiresReloadData
            }
        }
        sink.endRowUpdates()
        if !reloads.isEmpty { sink.reloadRows(reloads) }
    }
}

@MainActor
struct TableUpdateSink: RowUpdateSink {
    let tableView: NSTableView
    let animate: Bool
    private var options: NSTableView.AnimationOptions { animate ? .effectFade : [] }
    func reloadAll() { tableView.reloadData() }
    func beginRowUpdates() { tableView.beginUpdates() }
    func insertRows(_ rows: IndexSet) { tableView.insertRows(at: rows, withAnimation: options) }
    func removeRows(_ rows: IndexSet) { tableView.removeRows(at: rows, withAnimation: options) }
    func moveRow(_ from: Int, _ to: Int) { tableView.moveRow(at: from, to: to) }
    func reloadRows(_ rows: IndexSet) {
        let valid = rows.filteredIndexSet { $0 < tableView.numberOfRows }
        tableView.reloadData(forRowIndexes: valid, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }
    func endRowUpdates() { tableView.endUpdates() }
}
```

```swift
// Sources/UI/Content/ObservationLoop.swift
import Observation

/// Runs `read` under withObservationTracking and calls `onChange` on the main actor after every change of a
/// tracked @Observable property (Settings, OperationsCenter), re-arming itself until cancelled or released.
@MainActor
final class ObservationLoop {
    private let read: @MainActor () -> Void
    private let onChange: @MainActor () -> Void
    private var cancelled = false

    init(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        self.read = read
        self.onChange = onChange
        track()
    }

    func cancel() { cancelled = true }

    private func track() {
        guard !cancelled else { return }
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                self.onChange()
                self.track()
            }
        }
    }
}
```

```swift
// Sources/UI/Content/CommandStateBuilder.swift
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
        switch target {
        case .contentSelection(let folder):
            let rows = folder.selection.rows
            state.selectionCount = rows.count
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
        case .favorite(let favorite):
            state.selectionCount = favorite.url == nil ? 0 : 1
            state.singleFolderSelected = favorite.url != nil
        case .volume(let volume):
            state.selectionCount = 1
            state.singleFolderSelected = true
            state.targetIsEjectable = volume.isEjectable
            state.folderIsReadOnly = volume.isReadOnly
        case nil:
            break
        }
        return state
    }
}
```

- [ ] **Step 8: Implement columns and cells**

```swift
// Sources/UI/Details/DetailsColumns.swift
import AppKit
import Core
import MacxFS

/// Column definitions and the pure rules behind header menus, persistence, sorting and auto-fit (§5.5).
@MainActor
enum DetailsColumns {
    static let defaults: [ColumnSetting] = [
        ColumnSetting(id: .name, width: 280, visible: true),
        ColumnSetting(id: .dateModified, width: 160, visible: true),
        ColumnSetting(id: .size, width: 80, visible: true),
        ColumnSetting(id: .kind, width: 150, visible: true),
        ColumnSetting(id: .dateCreated, width: 160, visible: false),
        ColumnSetting(id: .fileExtension, width: 70, visible: false),
    ]
    private static let prefix = "macx.column."

    static func identifier(_ id: ColumnID) -> NSUserInterfaceItemIdentifier { .init(prefix + id.rawValue) }

    static func columnID(_ identifier: NSUserInterfaceItemIdentifier) -> ColumnID? {
        guard identifier.rawValue.hasPrefix(prefix) else { return nil }
        return ColumnID(rawValue: String(identifier.rawValue.dropFirst(prefix.count)))
    }

    static func title(_ id: ColumnID) -> String {
        switch id {
        case .name: L10n.string("Name")
        case .dateModified: L10n.string("Date Modified")
        case .size: L10n.string("Size")
        case .kind: L10n.string("Kind")
        case .dateCreated: L10n.string("Date Created")
        case .fileExtension: L10n.string("Extension")
        }
    }

    static func minWidth(_ id: ColumnID) -> Double { id == .name ? 120 : 50 }

    /// Every ColumnID exactly once (stored order first), widths clamped, Name always visible.
    static func normalized(_ columns: [ColumnSetting]) -> [ColumnSetting] {
        var seen = Set<ColumnID>()
        var result: [ColumnSetting] = []
        for column in columns where !seen.contains(column.id) {
            seen.insert(column.id)
            result.append(ColumnSetting(id: column.id, width: max(column.width, minWidth(column.id)),
                                        visible: column.id == .name ? true : column.visible))
        }
        for column in defaults where !seen.contains(column.id) { result.append(column) }
        return result
    }

    static func toggling(_ columns: [ColumnSetting], _ id: ColumnID) -> [ColumnSetting] {
        normalized(columns).map { column in
            column.id == id && id != .name ? ColumnSetting(id: column.id, width: column.width, visible: !column.visible) : column
        }
    }

    static func settings(fromTableColumns columns: [NSTableColumn]) -> [ColumnSetting] {
        normalized(columns.compactMap { column in
            columnID(column.identifier).map { ColumnSetting(id: $0, width: Double(column.width), visible: !column.isHidden) }
        })
    }

    /// Clicking the sorted column reverses it; another column sorts ascending by that field.
    static func nextSort(current: SortDescriptor, clicked: ColumnID) -> SortDescriptor {
        let field = clicked.sortField
        return SortDescriptor(field: field, ascending: current.field == field ? !current.ascending : true)
    }

    /// Auto-fit width (double-click a divider): widest of the given texts plus `extra` (icon, padding).
    static func fitWidth(texts: [String], font: NSFont, extra: Double) -> Double {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widest = texts.reduce(0.0) { max($0, Double(($1 as NSString).size(withAttributes: attributes).width)) }
        return (widest + extra).rounded(.up)
    }

    static func headerMenu(columns: [ColumnSetting], target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: L10n.string("Columns"))
        for column in normalized(columns) where column.id != .name {
            let item = NSMenuItem(title: title(column.id), action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = column.id.rawValue
            item.state = column.visible ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}
```

```swift
// Sources/UI/Details/NameCellView.swift
import AppKit
import Core
import MacxFS

/// Cut rendering (§5.6, §8): 50% opacity and an italic name, so the state doesn't rely on opacity alone.
@MainActor
enum CellStyle {
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    static let digitsFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let smallFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    static let smallItalicFont = NSFontManager.shared.convert(smallFont, toHaveTrait: .italicFontMask)

    static func apply(isCut: Bool, to label: NSTextField, container: NSView, italicizes: Bool = true) {
        if italicizes { label.font = isCut ? italicFont : font }
        container.alphaValue = isCut ? 0.5 : 1
    }
}

final class NameCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("macx.cell.name")
    let iconView = NSImageView()
    let label = NSTextField(labelWithString: "")
    let cloudBadge = NSImageView()
    private(set) var rowID: RowID?
    private var iconSide: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        for view in [iconView, label, cloudBadge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = CellStyle.font
        cloudBadge.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: L10n.string("In iCloud, not downloaded"))
        cloudBadge.contentTintColor = .secondaryLabelColor
        imageView = iconView
        textField = label
        iconSide = iconView.widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconSide,
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudBadge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            cloudBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            cloudBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudBadge.widthAnchor.constraint(equalToConstant: 14),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("NameCellView is created in code") }

    func configure(name: String, icon: CGImage, iconPoints: Double, isCut: Bool, isDataless: Bool, rowID: RowID) {
        self.rowID = rowID
        label.stringValue = name
        setIcon(icon, points: iconPoints)
        cloudBadge.isHidden = !isDataless
        CellStyle.apply(isCut: isCut, to: label, container: self)
        setAccessibilityLabel(isCut ? String(format: L10n.string("%@, cut"), name) : name)
    }

    func setIcon(_ icon: CGImage, points: Double) {
        iconSide.constant = points
        iconView.image = NSImage(cgImage: icon, size: NSSize(width: points, height: points))
    }
}

final class PlainCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("macx.cell.plain")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("PlainCellView is created in code") }

    func configure(text: String, alignment: NSTextAlignment, monospacedDigits: Bool, isCut: Bool) {
        label.stringValue = text
        label.alignment = alignment
        label.font = monospacedDigits ? CellStyle.digitsFont : CellStyle.font
        CellStyle.apply(isCut: isCut, to: label, container: self, italicizes: false)
    }
}
```

- [ ] **Step 9: Implement the Details view controller**

```swift
// Sources/UI/Details/DetailsViewController.swift
import AppKit
import os
import Core
import MacxFS

/// NSTableView with the routing the content view needs. P1-33 adds mouse and arrow handling, P1-35 context menus,
/// P1-36 drags and right-drag.
final class FileTableView: NSTableView {
    weak var owner: DetailsViewController?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    /// ⌘A goes to the content controller's selectAll: (model selection), not NSTableView's built-in one.
    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(Selector(("selectAll:")), with: sender)
    }
}

@MainActor
final class DetailsViewController: NSViewController, FileListView, FocusableList, NSTableViewDataSource, NSTableViewDelegate {
    let context: UIContext
    let tableView = FileTableView()
    let scrollView = NSScrollView()
    private(set) var folder: FolderModel?
    private var settingsLoop: ObservationLoop?
    private var isRebuildingColumns = false
    private var isSyncingSelection = false
    private var isRestoringScroll = false
    private var didPaintFirstRows = false
    private var lastCutNames: Set<String> = []

    var focusView: NSView { tableView }
    var iconPoints: Double { settings.density == .comfortable ? 20 : 16 }
    private var settings: Settings { context.environment.settings }

    init(context: UIContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("DetailsViewController is created in code") }

    override func loadView() {
        tableView.owner = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false          // TypeSelect (P1-33) folds names off main for big folders
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.headerView = NSTableHeaderView()
        tableView.target = nil                      // double-click goes up the responder chain
        tableView.doubleAction = Selector(Command.open.selectorName)
        tableView.setAccessibilityIdentifier(AXID.detailsTable)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        center.addObserver(self, selector: #selector(columnsChanged(_:)), name: NSTableView.columnDidMoveNotification, object: tableView)
        center.addObserver(self, selector: #selector(columnsChanged(_:)), name: NSTableView.columnDidResizeNotification, object: tableView)
        view = scrollView
        rebuildColumns()
        applyDensity()
        settingsLoop = ObservationLoop { [weak self] in
            guard let self else { return }
            _ = self.settings.density
            _ = self.settings.dateStyle
        } onChange: { [weak self] in
            self?.applyDensity()
            self?.reloadVisibleRows()
        }
    }

    // MARK: FileListView

    func bind(_ folder: FolderModel?) {
        self.folder = folder
        didPaintFirstRows = false
        lastCutNames = folder?.cutNames ?? []
        tableView.reloadData()
        if let folder {
            updateSortIndicator(folder.query.sort)
            restoreScroll(anchor: folder.scrollAnchor)
        }
        reloadSelectionDrawing()
    }

    func apply(_ changes: ChangeSet) {
        guard let folder else { return }
        let anchor = folder.scrollAnchor
        let animate = !changes.requiresReloadData && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ChangeApplier.apply(changes, to: TableUpdateSink(tableView: tableView, animate: animate))
        if changes.requiresReloadData { restoreScroll(anchor: anchor) }
        reloadSelectionDrawing()
        if !didPaintFirstRows, folder.rowCount > 0 {
            didPaintFirstRows = true
            PerfSignposts.signposter.emitEvent(PerfSignposts.firstPaint)
        }
        context.icons.cancelFileIcons(notIn: visibleRowIDs())
    }

    /// Mirrors the model's selection into the table highlight (S5-C4) and redraws cut state when it changed.
    func reloadSelectionDrawing() {
        guard let folder else { return }
        isSyncingSelection = true
        tableView.selectRowIndexes(folder.selection.rows.filteredIndexSet { $0 < tableView.numberOfRows },
                                   byExtendingSelection: false)
        isSyncingSelection = false
        if folder.cutNames != lastCutNames {
            lastCutNames = folder.cutNames
            reloadVisibleRows()
        }
    }

    func beginInlineRename(row: Int) {
        scrollToRow(row)   // P1-34 replaces this body with InlineRenameController
    }

    func scrollToRow(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(row)
    }

    func topVisibleRow() -> Int? {
        let clip = scrollView.contentView
        let row = tableView.row(at: NSPoint(x: 1, y: clip.bounds.minY + clip.contentInsets.top + 1))
        return row >= 0 ? row : nil
    }

    func visibleRows() -> Range<Int> {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return 0..<0 }
        return range.location..<(range.location + range.length)
    }

    // MARK: scrolling and anchor (§4.3)

    func scrollRowToTop(_ row: Int) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y = (row > 0 && row < tableView.numberOfRows ? tableView.rect(ofRow: row).minY : 0) - clip.contentInsets.top
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func restoreScroll(anchor: RowID?) {
        guard let folder else { return }
        isRestoringScroll = true
        defer { isRestoringScroll = false }
        if let anchor, let row = folder.row(of: anchor) { scrollRowToTop(row) } else if anchor == nil { scrollRowToTop(0) }
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        guard !isRestoringScroll, let folder else { return }
        if let top = topVisibleRow(), top > 0 { folder.scrollAnchor = folder.identity(atRow: top) } else { folder.scrollAnchor = nil }
        context.icons.cancelFileIcons(notIn: visibleRowIDs())
    }

    private func visibleRowIDs() -> Set<RowID> {
        guard let folder else { return [] }
        return Set(visibleRows().filter { $0 < folder.rowCount }.map { folder.identity(atRow: $0) })
    }

    // MARK: keys

    func handleKeyDown(_ event: NSEvent) -> Bool {
        KeyRouter.handle(event, focus: .content, returnKey: settings.returnKey, from: tableView)
    }

    // MARK: columns

    func rebuildColumns() {
        isRebuildingColumns = true
        defer { isRebuildingColumns = false }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for setting in DetailsColumns.normalized(settings.columns) {
            let column = NSTableColumn(identifier: DetailsColumns.identifier(setting.id))
            column.title = DetailsColumns.title(setting.id)
            column.minWidth = DetailsColumns.minWidth(setting.id)
            column.width = setting.width
            column.isHidden = !setting.visible
            column.resizingMask = .userResizingMask
            column.headerCell.alignment = setting.id == .size ? .right : .left
            tableView.addTableColumn(column)
        }
        tableView.headerView?.menu = DetailsColumns.headerMenu(columns: settings.columns, target: self,
                                                               action: #selector(toggleColumn(_:)))
        updateSortIndicator(folder?.query.sort ?? settings.sort)
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ColumnID(rawValue: raw) else { return }
        settings.columns = DetailsColumns.toggling(DetailsColumns.settings(fromTableColumns: tableView.tableColumns), id)
        rebuildColumns()
    }

    @objc private func columnsChanged(_ note: Notification) {
        guard !isRebuildingColumns else { return }
        settings.columns = DetailsColumns.settings(fromTableColumns: tableView.tableColumns)
    }

    private func updateSortIndicator(_ sort: SortDescriptor) {
        for column in tableView.tableColumns {
            let sorted = DetailsColumns.columnID(column.identifier)?.sortField == sort.field
            tableView.setIndicatorImage(sorted ? NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil,
                                        in: column)
            if sorted { tableView.highlightedTableColumn = column }
        }
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let folder, let id = DetailsColumns.columnID(tableColumn.identifier) else { return }
        let next = DetailsColumns.nextSort(current: folder.query.sort, clicked: id)
        var query = folder.query
        query.sort = next
        folder.setQuery(query)
        settings.sort = next
        updateSortIndicator(next)
    }

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        let tableColumn = tableView.tableColumns[column]
        guard let folder, let id = DetailsColumns.columnID(tableColumn.identifier) else { return tableColumn.width }
        let texts = visibleRows().filter { $0 < folder.rowCount }.map { text(for: id, row: $0) } + [tableColumn.title]
        let extra = id == .name ? iconPoints + 30 : 14
        return CGFloat(max(DetailsColumns.minWidth(id), DetailsColumns.fitWidth(texts: texts, font: CellStyle.font, extra: extra)))
    }

    // MARK: data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { folder?.rowCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let folder, let tableColumn, let id = DetailsColumns.columnID(tableColumn.identifier), row < folder.rowCount else {
            return nil
        }
        let entry = folder.entry(atRow: row)
        let isCut = folder.isCut(row: row)
        if id == .name {
            let cell = tableView.makeView(withIdentifier: NameCellView.reuseID, owner: nil) as? NameCellView ?? NameCellView()
            let name = folder.name(atRow: row)
            let scale = Double(view.window?.backingScaleFactor ?? 2)
            let rowID = folder.identity(atRow: row)
            cell.configure(name: name, icon: context.icons.typeIcon(entry.typeIndex, points: iconPoints, scale: scale),
                           iconPoints: iconPoints, isCut: isCut, isDataless: entry.flags.contains(.dataless), rowID: rowID)
            requestFileIcon(entry: entry, name: name, row: row, rowID: rowID, cell: cell, scale: scale)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: PlainCellView.reuseID, owner: nil) as? PlainCellView ?? PlainCellView()
        cell.configure(text: text(for: id, row: row), alignment: id == .size ? .right : .left,
                       monospacedDigits: id == .size, isCut: isCut)
        return cell
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        if isSyncingSelection { return proposed }
        folder?.select(.set(proposed, cursor: proposed.last))   // P1-33 replaces this with model-only mouse handling
        return folder?.selection.rows ?? proposed
    }

    // MARK: helpers

    func cellView(row: Int, column: ColumnID) -> NSTableCellView? {
        let index = tableView.column(withIdentifier: DetailsColumns.identifier(column))
        guard index >= 0, row < tableView.numberOfRows else { return nil }
        return tableView.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    private func text(for id: ColumnID, row: Int) -> String {
        guard let folder else { return "" }
        let entry = folder.entry(atRow: row)
        switch id {
        case .name: return folder.name(atRow: row)
        case .dateModified: return Formatters.date(nanoseconds: entry.mtime, style: settings.dateStyle)
        case .dateCreated: return Formatters.date(nanoseconds: entry.ctime, style: settings.dateStyle)
        case .size: return Formatters.size(of: entry)
        case .kind: return context.environment.types.localizedDescription(entry.typeIndex)
        case .fileExtension: return Formatters.extensionText(name: folder.name(atRow: row), kind: entry.kind)
        }
    }

    private func requestFileIcon(entry: Entry, name: String, row: Int, rowID: RowID, cell: NameCellView, scale: Double) {
        guard let folder else { return }
        let url = folder.url(atRow: row)
        let isVolumeRoot = entry.kind == .directory
            && context.environment.volumes.mountTable.volumes.contains { $0.mountPoint.standardizedFileURL == url.standardizedFileURL }
        guard context.icons.needsFileIcon(entry, name: name, isVolumeRoot: isVolumeRoot) else { return }
        let points = iconPoints
        context.icons.fileIcon(for: url, rowID: rowID, points: points, scale: scale) { [weak cell] image in
            guard let cell, cell.rowID == rowID else { return }
            cell.setIcon(image, points: points)
        }
    }

    private func applyDensity() {
        tableView.rowHeight = settings.density.rowHeight
    }

    func reloadVisibleRows() {
        let rows = visibleRows()
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }
}
```

- [ ] **Step 10: Implement the content host and wire it into the split view**

```swift
// Sources/UI/Content/ContentViewController.swift
import AppKit
import Core
import MacxFS

/// Content area of a browser window (§5.3–§5.5): command bar, the active list, empty-state overlay and banner
/// (P1-33), status bar. The only observer of the session's current FolderModel.
@MainActor
final class ContentViewController: CommandHandlingViewController {
    let context: UIContext
    let session: BrowserSession
    let details: DetailsViewController
    let commandBar = CommandBarView()
    let statusBar = StatusBarView()
    let stack = NSStackView()
    let listContainer = NSView()
    private(set) var activeList: FileListView
    private var mountedListView: NSView?
    private var folderToken: ObserverToken?
    private var sessionToken: ObserverToken?
    private var volumesToken: ObserverToken?
    private var finishedToken: ObserverToken?
    private var settingsLoop: ObservationLoop?
    private var lastVolumeID: VolumeID?

    init(context: UIContext, session: BrowserSession) {
        self.context = context
        self.session = session
        self.details = DetailsViewController(context: context)
        self.activeList = details
        super.init(nibName: nil, bundle: nil)
        if context.icons.volumeLookup == nil {
            let volumes = context.environment.volumes
            context.icons.volumeLookup = { volumes.volume(for: $0)?.id ?? .unknown }
        }
    }

    required init?(coder: NSCoder) { fatalError("ContentViewController is created in code") }

    override var focusContext: FocusContext { .content }
    override var commandTarget: CommandTarget? { .contentSelection(session.folder) }

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for part in [commandBar, listContainer, statusBar] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(part)
            part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        commandBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        statusBar.heightAnchor.constraint(equalToConstant: 22).isActive = true
        listContainer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        listContainer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(details)
        sessionToken = session.observe { [weak self] event in self?.handle(event) }
        volumesToken = context.environment.volumes.observe { [weak self] _ in self?.refreshFreeSpace(force: true) }
        finishedToken = context.environment.operations.onFinished { [weak self] _, _ in self?.refreshFreeSpace(force: true) }
        settingsLoop = ObservationLoop { [weak self] in
            _ = self?.context.environment.settings.commandBarVisible
        } onChange: { [weak self] in
            self?.applyCommandBarVisibility()
        }
        applyCommandBarVisibility()
        setViewMode(session.viewMode)
        bind(session.folder)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCommandBar()
    }

    // MARK: session and folder events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .folderChanged(let model): bind(model)
        case .viewModeChanged(let mode): setViewMode(mode)
        case .historyChanged: updateCommandBar()
        case .banner: break   // P1-33 shows the banner
        }
    }

    func bind(_ folder: FolderModel) {
        folderToken = folder.observe { [weak self, weak folder] event in
            guard let self, let folder, folder === self.session.folder else { return }
            self.handle(event)
        }
        activeList.bind(folder)
        refreshFreeSpace(force: false)
        updateStatus()
        updateCommandBar()
    }

    func handle(_ event: FolderEvent) {
        switch event {
        case .changes(let changes): activeList.apply(changes); updateStatus()
        case .selection: activeList.reloadSelectionDrawing(); updateStatus(); updateCommandBar()
        case .state: updateStatus()
        case .beginRename(let row): activeList.beginInlineRename(row: row)
        case .relocate: break   // BrowserSession navigates (P1-26)
        case .query: updateStatus()
        }
    }

    // MARK: view mode

    func setViewMode(_ mode: ViewMode) {
        mount(details)   // P1-32 replaces this body to add the Icons view
    }

    func mount(_ list: FileListView) {
        guard mountedListView !== list.view else { return }
        let hadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: listContainer) ?? false
        mountedListView?.removeFromSuperview()
        let listView = list.view
        listView.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
        ])
        mountedListView = listView
        if hadFocus, let focusable = list as? FocusableList { view.window?.makeFirstResponder(focusable.focusView) }
    }

    // MARK: command bar and status bar

    private func applyCommandBarVisibility() {
        commandBar.isHidden = !context.environment.settings.commandBarVisible
    }

    func updateCommandBar() {
        let state = CommandStateBuilder.state(for: commandTarget, session: session, environment: context.environment)
        commandBar.update(state: state, focus: .content, shiftHeld: NSEvent.modifierFlags.contains(.shift))
    }

    func updateStatus() {
        let folder = session.folder
        let available = lastVolumeID.flatMap { context.environment.volumes.cachedAvailableCapacity($0) }
        statusBar.update(itemCount: folder.rowCount, selection: folder.selectionSummary, available: available)
    }

    /// Free space (§5.5): fetched on a lane, cached; refreshed on navigation to another volume, when an operation
    /// finishes and when volumes change. Navigation within a volume uses the cache.
    private func refreshFreeSpace(force: Bool) {
        guard let volume = session.folder.volume else { updateStatus(); return }
        let changed = volume.id != lastVolumeID
        lastVolumeID = volume.id
        if changed || force || context.environment.volumes.cachedAvailableCapacity(volume.id) == nil {
            Task { [weak self] in
                _ = await self?.context.environment.volumes.refreshAvailableCapacity(volume.id)
                self?.updateStatus()
            }
        }
        updateStatus()
    }
}

extension NSViewController {
    /// Depth-first search of the view-controller tree (split items, children).
    func firstDescendant<T: NSViewController>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for child in children {
            if let match = child.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
```

In `Sources/UI/Window/BrowserSplitViewController.swift`, replace the P1-26 placeholder content controller with the real one. Delete the placeholder type. If P1-29 put a `CommandBarView` or `StatusBarView` into the placeholder, delete those instances too, because `ContentViewController` owns the only ones. The content split item becomes:

```swift
        let content = ContentViewController(context: context, session: session)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 320
        addSplitViewItem(contentItem)
```

- [ ] **Step 11: Run the tests to verify they pass**

Run: `swift test --filter 'UITests\.(FormattersTests|IconCacheTests|DetailsViewTests)' 2>&1 | tail -5`
Expected: `Executed 23 tests, with 0 failures` (with no GUI session: `with 10 tests skipped and 0 failures`).

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` with no warnings.

- [ ] **Step 12: Verify in the app (sandbox only)**

Use the manual run recipe from Global Constraints, then check:
1. The window lists `Sub Folder` and `Fake.app` first, then `file1.txt` … `file40.txt` in natural order (`file2` before `file10`). Sizes are decimal (`40 bytes`), `Sub Folder` shows `--`, dates read `Today HH:MM`.
2. `Fake.app` gets its app icon within a moment (Tier 1). All other icons appear immediately (Tier 0).
3. Right-click the header: unticking `Kind` hides it. Drag `Size` to the first position and resize it. Double-click the divider after `Name` to auto-fit it. Quit, relaunch with the same `--state-dir`, and confirm the columns kept their order, widths and visibility.
4. Click `Size` once to sort ascending and again for descending; folders stay on top.
5. With the 100k fixture, open `big`. Rows appear at once, scrolling is smooth, and Instruments' os_signpost track shows `firstPaint` shortly after `navigate`.

- [ ] **Step 13: Commit**

```bash
git add scripts/l10n-add.sh Sources/UI/Support/Formatters.swift Sources/UI/Support/IconCache.swift \
  Sources/UI/Content Sources/UI/Details Sources/UI/App/UIContext.swift Sources/UI/Window/BrowserSplitViewController.swift \
  Sources/UI/Resources/Localizable.xcstrings Tests/UITests/Support Tests/UITests/FormattersTests.swift \
  Tests/UITests/IconCacheTests.swift Tests/UITests/DetailsViewTests.swift
git commit -m "feat: details view, content host, formatters and icon tiers (P1-31)"
```

---

### Task P1-32: Icons view (fixed-grid layout, rubber band, spatial arrows)

**Spec coverage:** §5.5 Icons view (`NSCollectionView` with a custom fixed-grid `NSCollectionViewLayout`; Small 32 / Medium 64 / Large 128 pt; fixed cell per size with a fixed two-line label area and middle ellipsis; columns from the width; attributes O(1), elements in a rect O(visible), no per-item caching in `prepare()`; rubber-band selection; spatial arrows by row/column arithmetic; sorting comes from the Sort menu only). §5.5 shared selection semantics and cut rendering. §12 risk "NSCollectionView at 100k items" (layout benchmarked by a unit smoke test here, and by `macx-bench` in S6).

**Files:**
- Create: `Sources/UI/Icons/FileGridLayout.swift`
- Create: `Sources/UI/Icons/IconItem.swift`
- Create: `Sources/UI/Icons/IconsViewController.swift`
- Modify: `Sources/UI/Content/ContentViewController.swift` (`setViewMode`, new `icons` property)
- Test: `Tests/UITests/FileGridLayoutTests.swift`, `Tests/UITests/IconsViewTests.swift`

**Interfaces:**
- Consumes: P1-31 `FileListView`, `FocusableList`, `ChangeSet`, `IconCache.typeIcon/fileIcon/needsFileIcon/cancelFileIcons`, `CellStyle`, `ObservationLoop`, `ContentViewController.mount(_:)`; `Settings.iconSize: IconSize`, `IconSize.points`; `FolderModel` row accessors, `select(_:)`, `selection`, `scrollAnchor`; `KeyRouter.handle`; `AXID.iconsGrid`.
- Produces (overview §3.14, exact):
  - `@MainActor final class IconsViewController: NSViewController, FileListView { init(context: UIContext) }`
  - `@MainActor final class FileGridLayout: NSCollectionViewLayout { var iconSize: IconSize; var itemCount: Int; var columns: Int { get }; func frame(forItem index: Int) -> NSRect; func indexes(in rect: NSRect) -> Range<Int>; func index(atRow row: Int, column: Int) -> Int?; func rowColumn(of index: Int) -> (row: Int, column: Int) }`
  - Internal additions: `GridMetrics.forIconSize(_:)`, `FileGridLayout.metrics`, `.fallbackWidth`, `.rowCount`, `.itemIndex(at:) -> Int?`, `.neighbor(of:_:) -> Int?`; `enum GridDirection { case up, down, left, right }`; `GridChangePolicy.plan(_:) -> GridUpdatePlan`; `RubberBand.rect(from:to:)`, `.hits(in:layout:)`, `.selection(base:hits:mode:)`, `RubberBand.Mode`; `LabelTruncation.twoLineMiddle(_:width:font:)`; `IconsViewController.collectionView: FileCollectionView`, `.layout`, `.applyRubberBand(rect:mode:base:)`, `.handleKeyDown(_:)`; `ContentViewController.icons: IconsViewController?`.

- [ ] **Step 1: Write the failing layout tests**

```swift
// Tests/UITests/FileGridLayoutTests.swift
import XCTest
@testable import UI
import Core

@MainActor
final class FileGridLayoutTests: XCTestCase {
    private func layout(_ size: IconSize = .medium, items: Int, width: CGFloat = 600) -> FileGridLayout {
        let layout = FileGridLayout()
        layout.iconSize = size
        layout.itemCount = items
        layout.fallbackWidth = width
        return layout
    }

    func testColumnsPerIconSize() {
        // cell widths 80 / 112 / 176, spacing 8, insets 10+10: usable = 600 - 20 + 8 = 588
        XCTAssertEqual(layout(.small, items: 10).columns, 6)    // 588 / 88
        XCTAssertEqual(layout(.medium, items: 10).columns, 4)   // 588 / 120
        XCTAssertEqual(layout(.large, items: 10).columns, 3)    // 588 / 184
    }

    func testColumnsNeverZeroForNarrowWidths() {
        for width in [0, 1, 50, 100] as [CGFloat] { XCTAssertEqual(layout(.large, items: 5, width: width).columns, 1) }
    }

    func testFrameForItemIsArithmetic() {
        let grid = layout(items: 10)
        // medium: item 112 x 110 (6 + 64 + 4 + 30 + 6), pitch 120 x 118
        XCTAssertEqual(grid.frame(forItem: 0), NSRect(x: 10, y: 10, width: 112, height: 110))
        XCTAssertEqual(grid.frame(forItem: 5), NSRect(x: 130, y: 128, width: 112, height: 110))
    }

    func testRowColumnRoundTrip() {
        let grid = layout(items: 1_000)
        for index in 0..<1_000 {
            let (row, column) = grid.rowColumn(of: index)
            XCTAssertEqual(grid.index(atRow: row, column: column), index)
        }
        XCTAssertNil(grid.index(atRow: 250, column: 0), "past the end")
        XCTAssertNil(grid.index(atRow: 0, column: 4), "past the last column")
        XCTAssertNil(grid.index(atRow: -1, column: 0))
    }

    func testIndexesInRectAreBoundedByVisibleRows() {
        let grid = layout(items: 100_000)
        let visible = grid.indexes(in: NSRect(x: 0, y: 5_000, width: 600, height: 400))
        XCTAssertLessThanOrEqual(visible.count, (Int(400 / 118) + 2) * grid.columns)
        XCTAssertTrue(visible.contains(grid.itemIndex(at: NSPoint(x: 20, y: 5_100)) ?? -1))
        XCTAssertEqual(grid.indexes(in: NSRect(x: 0, y: 0, width: 600, height: 100)), 0..<4)
        XCTAssertEqual(layout(items: 0).indexes(in: NSRect(x: 0, y: 0, width: 600, height: 400)), 0..<0)
    }

    func testLargeGridIsFast() {
        let grid = layout(items: 100_000)
        let start = ContinuousClock.now
        var sum: CGFloat = 0
        for index in 0..<100_000 { sum += grid.frame(forItem: index).minY }
        let attributes = grid.layoutAttributesForElements(in: NSRect(x: 0, y: 1_000_000, width: 600, height: 800))
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(200))
        XCTAssertGreaterThan(sum, 0)
        XCTAssertLessThanOrEqual(attributes.count, 9 * grid.columns)
    }

    func testNeighborNavigation() {
        let grid = layout(items: 10)   // 4 columns: rows [0-3] [4-7] [8-9]
        XCTAssertEqual(grid.neighbor(of: 5, .up), 1)
        XCTAssertNil(grid.neighbor(of: 2, .up))
        XCTAssertEqual(grid.neighbor(of: 1, .down), 5)
        XCTAssertEqual(grid.neighbor(of: 6, .down), 9, "no item below in the partial last row → its last item")
        XCTAssertNil(grid.neighbor(of: 9, .down))
        XCTAssertEqual(grid.neighbor(of: 4, .left), 3, "left wraps to the previous row like Explorer")
        XCTAssertNil(grid.neighbor(of: 0, .left))
        XCTAssertEqual(grid.neighbor(of: 3, .right), 4)
        XCTAssertNil(grid.neighbor(of: 9, .right))
    }

    func testContentSizeAndHitTesting() {
        let grid = layout(items: 10)
        XCTAssertEqual(grid.collectionViewContentSize.height, 10 + 3 * 118 - 8 + 10)
        XCTAssertEqual(grid.itemIndex(at: NSPoint(x: 135, y: 130)), 5)
        XCTAssertNil(grid.itemIndex(at: NSPoint(x: 125, y: 130)), "the spacing between cells is empty space")
        XCTAssertNil(grid.itemIndex(at: NSPoint(x: 135, y: 400)), "below the last row")
    }
}
```

- [ ] **Step 2: Write the failing Icons view tests**

```swift
// Tests/UITests/IconsViewTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class IconsViewTests: XCTestCase {
    func testGridChangePolicy() {
        XCTAssertEqual(GridChangePolicy.plan(ChangeSet([])), .nothing)
        XCTAssertEqual(GridChangePolicy.plan(ChangeSet([.reload(IndexSet([1, 3]))])), .reloadItems(IndexSet([1, 3])))
        XCTAssertEqual(GridChangePolicy.plan(ChangeSet([.reload(IndexSet(integer: 1)), .insert(IndexSet(integer: 0))])), .reloadAll)
        XCTAssertEqual(GridChangePolicy.plan(.reset), .reloadAll)
    }

    func testRubberBandModes() {
        let grid = FileGridLayout()
        grid.itemCount = 10
        grid.fallbackWidth = 600
        let rect = RubberBand.rect(from: NSPoint(x: 260, y: 100), to: NSPoint(x: 20, y: 20))
        XCTAssertEqual(rect, NSRect(x: 20, y: 20, width: 240, height: 80))
        let hits = RubberBand.hits(in: rect, layout: grid)
        XCTAssertEqual(hits, IndexSet([0, 1, 2]))
        XCTAssertEqual(RubberBand.selection(base: IndexSet([2, 7]), hits: hits, mode: .replace), IndexSet([0, 1, 2]))
        XCTAssertEqual(RubberBand.selection(base: IndexSet([2, 7]), hits: hits, mode: .add), IndexSet([0, 1, 2, 7]))
        XCTAssertEqual(RubberBand.selection(base: IndexSet([2, 7]), hits: hits, mode: .toggle), IndexSet([0, 1, 7]))
    }

    func testTruncationLeavesShortNamesAlone() {
        XCTAssertEqual(LabelTruncation.twoLineMiddle("notes.txt", width: 100, font: CellStyle.smallFont), "notes.txt")
    }

    func testTruncationKeepsGraphemesAndExtension() {
        let font = CellStyle.smallFont
        let long = String(repeating: "verylongname_", count: 12) + "final.txt"
        let cut = LabelTruncation.twoLineMiddle(long, width: 72, font: font)
        XCTAssertTrue(cut.contains("…"))
        XCTAssertTrue(cut.hasSuffix(".txt"), cut)
        let twoLines = ("X\nX" as NSString).boundingRect(with: NSSize(width: 72, height: 1_000), options: [.usesLineFragmentOrigin],
                                                         attributes: [.font: font]).height
        let height = (cut as NSString).boundingRect(with: NSSize(width: 72, height: 1_000), options: [.usesLineFragmentOrigin],
                                                    attributes: [.font: font]).height
        XCTAssertLessThanOrEqual(height, twoLines + 0.5)
        let emoji = String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 30) + ".png"
        let cutEmoji = LabelTruncation.twoLineMiddle(emoji, width: 72, font: font)
        XCTAssertTrue(Set(cutEmoji).subtracting(Set(emoji)).subtracting(["…"]).isEmpty, "no split graphemes: \(cutEmoji)")
        XCTAssertTrue(cutEmoji.hasSuffix(".png"))
    }

    func testTruncationIsFast() {
        let names = (0..<200).map { "document-\($0)-" + String(repeating: "x", count: 120) + ".pdf" }
        let start = ContinuousClock.now
        for name in names { _ = LabelTruncation.twoLineMiddle(name, width: 104, font: CellStyle.smallFont) }
        XCTAssertLessThan((ContinuousClock.now - start) / names.count, .milliseconds(2))
    }

    // MARK: AppKit (offscreen window)

    private func makeIcons(_ h: ContentTestHarness, files: Int) async throws -> (IconsViewController, FolderModel) {
        for i in 0..<files { try h.file(String(format: "i%02d.txt", i)) }
        let folder = try await h.openFolder()
        let icons = IconsViewController(context: h.context)
        try h.host(icons, size: NSSize(width: 620, height: 500))
        icons.bind(folder)
        return (icons, folder)
    }

    func testBindShowsItemsAndIconSizeFollowsSettings() async throws {
        let h = try await ContentTestHarness.make(self)
        h.environment.settings.iconSize = .medium
        let (icons, _) = try await makeIcons(h, files: 9)
        XCTAssertEqual(icons.collectionView.numberOfItems(inSection: 0), 9)
        XCTAssertEqual(icons.layout.itemCount, 9)
        XCTAssertEqual(icons.collectionView.accessibilityIdentifier(), AXID.iconsGrid)
        XCTAssertFalse(icons.collectionView.isSelectable, "selection is model-owned (§5.5)")
        h.environment.settings.iconSize = .large
        try await h.waitUntil("large icons") { icons.layout.iconSize == .large }
    }

    func testArrowKeysMoveSpatially() async throws {
        let h = try await ContentTestHarness.make(self)
        h.environment.settings.iconSize = .medium
        let (icons, folder) = try await makeIcons(h, files: 10)
        let columns = icons.layout.columns
        XCTAssertGreaterThan(columns, 1)
        folder.select(.set(IndexSet(integer: 0), cursor: 0))
        XCTAssertTrue(icons.handleKeyDown(try key(.downArrow, window: icons.view.window)))
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: columns))
        XCTAssertTrue(icons.handleKeyDown(try key(.rightArrow, flags: .shift, window: icons.view.window)))
        XCTAssertEqual(folder.selection.rows, IndexSet([columns, columns + 1]))
        _ = icons.handleKeyDown(try key(.downArrow, flags: .command, window: icons.view.window))
        XCTAssertEqual(folder.selection.rows, IndexSet([columns, columns + 1]), "⌘-arrows never change the selection")
    }

    func testSwitchingViewModeKeepsSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["a.txt", "b.txt", "c.txt"] { try h.file(name) }
        let (content, session, _) = try await h.makeContent()
        session.folder.select(.set(IndexSet([0, 2]), cursor: 2))
        content.setViewMode(.icons)
        XCTAssertTrue(content.activeList === content.icons)
        XCTAssertEqual(content.icons?.collectionView.numberOfItems(inSection: 0), 3)
        XCTAssertEqual(session.folder.selection.rows, IndexSet([0, 2]))
        content.setViewMode(.details)
        XCTAssertTrue(content.activeList === content.details)
        XCTAssertEqual(content.details.tableView.selectedRowIndexes, IndexSet([0, 2]))
    }

    func testRubberBandSelectsIntoModel() async throws {
        let h = try await ContentTestHarness.make(self)
        h.environment.settings.iconSize = .medium
        let (icons, folder) = try await makeIcons(h, files: 8)
        icons.applyRubberBand(rect: NSRect(x: 0, y: 0, width: 600, height: 60), mode: .replace, base: [])
        XCTAssertEqual(folder.selection.rows, IndexSet(integersIn: 0..<icons.layout.columns))
        icons.applyRubberBand(rect: NSRect(x: 0, y: 0, width: 60, height: 60), mode: .toggle, base: folder.selection.rows)
        XCTAssertFalse(folder.selection.rows.contains(0))
    }

    private func key(_ special: NSEvent.SpecialKey, flags: NSEvent.ModifierFlags = [], window: NSWindow?) throws -> NSEvent {
        let characters = String(Character(UnicodeScalar(UInt16(special.rawValue))!))
        let codes: [NSEvent.SpecialKey: UInt16] = [.upArrow: 126, .downArrow: 125, .leftArrow: 123, .rightArrow: 124]
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                              windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                              charactersIgnoringModifiers: characters, isARepeat: false,
                                              keyCode: codes[special] ?? 0))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter 'UITests\.(FileGridLayoutTests|IconsViewTests)' 2>&1 | tail -20`
Expected: compile errors such as `cannot find 'FileGridLayout' in scope`, `cannot find 'GridChangePolicy' in scope`.

- [ ] **Step 4: Implement the layout**

```swift
// Sources/UI/Icons/FileGridLayout.swift
import AppKit
import Core

/// Fixed cell geometry per icon size (§5.5): a cell is icon + a two-line label, never measured per item.
struct GridMetrics {
    static let labelHeight: CGFloat = 30   // two lines of the 11 pt small system font
    var itemSize: NSSize
    var spacing: NSSize
    var insets: NSEdgeInsets

    static func forIconSize(_ size: IconSize) -> GridMetrics {
        let points = CGFloat(size.points)
        return GridMetrics(itemSize: NSSize(width: max(points + 48, 80), height: 6 + points + 4 + labelHeight + 6),
                           spacing: NSSize(width: 8, height: 8),
                           insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
    }
}

enum GridDirection: Sendable { case up, down, left, right }

/// Pure-arithmetic grid. frame(forItem:) is O(1), indexes(in:) and layoutAttributesForElements(in:) are
/// O(visible rows), and prepare() keeps no per-item state (§5.5, §12).
@MainActor
final class FileGridLayout: NSCollectionViewLayout {
    var iconSize: IconSize = .medium {
        didSet {
            guard oldValue != iconSize else { return }
            metrics = .forIconSize(iconSize)
            invalidateLayout()
        }
    }
    var itemCount: Int = 0
    private(set) var metrics = GridMetrics.forIconSize(.medium)
    /// Width used when the layout isn't attached to a collection view (unit tests).
    var fallbackWidth: CGFloat = 600
    private var preparedWidth: CGFloat = 0

    var availableWidth: CGFloat {
        guard let collectionView else { return fallbackWidth }
        return collectionView.enclosingScrollView?.contentSize.width ?? collectionView.bounds.width
    }
    private var columnPitch: CGFloat { metrics.itemSize.width + metrics.spacing.width }
    private var rowPitch: CGFloat { metrics.itemSize.height + metrics.spacing.height }

    var columns: Int {
        let usable = availableWidth - metrics.insets.left - metrics.insets.right + metrics.spacing.width
        return max(1, Int((usable / columnPitch).rounded(.down)))
    }
    var rowCount: Int { itemCount == 0 ? 0 : (itemCount + columns - 1) / columns }

    func rowColumn(of index: Int) -> (row: Int, column: Int) {
        let count = columns
        return (index / count, index % count)
    }

    func index(atRow row: Int, column: Int) -> Int? {
        let count = columns
        guard row >= 0, column >= 0, column < count else { return nil }
        let index = row * count + column
        return index < itemCount ? index : nil
    }

    func frame(forItem index: Int) -> NSRect {
        let (row, column) = rowColumn(of: index)
        return NSRect(x: metrics.insets.left + CGFloat(column) * columnPitch, y: metrics.insets.top + CGFloat(row) * rowPitch,
                      width: metrics.itemSize.width, height: metrics.itemSize.height)
    }

    /// Indexes of the rows that intersect `rect` (whole rows, contiguous).
    func indexes(in rect: NSRect) -> Range<Int> {
        guard itemCount > 0, rowCount > 0 else { return 0..<0 }
        let first = max(0, Int(((rect.minY - metrics.insets.top) / rowPitch).rounded(.down)))
        let last = min(rowCount - 1, Int(((rect.maxY - metrics.insets.top) / rowPitch).rounded(.down)))
        guard first <= last else { return 0..<0 }
        let lower = first * columns
        let upper = min(itemCount, (last + 1) * columns)
        return lower < upper ? lower..<upper : 0..<0
    }

    /// The item under a point, or nil over spacing, insets or past the end.
    func itemIndex(at point: NSPoint) -> Int? {
        guard point.x >= metrics.insets.left, point.y >= metrics.insets.top else { return nil }
        let row = Int(((point.y - metrics.insets.top) / rowPitch).rounded(.down))
        let column = Int(((point.x - metrics.insets.left) / columnPitch).rounded(.down))
        guard let index = index(atRow: row, column: column), frame(forItem: index).contains(point) else { return nil }
        return index
    }

    /// Spatial arrows (§5.5). Left and right wrap across rows; Down from a column with nothing below in the partial
    /// last row lands on the last item.
    func neighbor(of index: Int, _ direction: GridDirection) -> Int? {
        guard index >= 0, index < itemCount else { return nil }
        let (row, column) = rowColumn(of: index)
        switch direction {
        case .left: return index > 0 ? index - 1 : nil
        case .right: return index + 1 < itemCount ? index + 1 : nil
        case .up: return row > 0 ? index - columns : nil
        case .down:
            if let below = self.index(atRow: row + 1, column: column) { return below }
            return row + 1 < rowCount ? itemCount - 1 : nil
        }
    }

    // MARK: NSCollectionViewLayout

    override func prepare() {
        super.prepare()
        if let collectionView, collectionView.numberOfSections > 0 { itemCount = collectionView.numberOfItems(inSection: 0) }
        preparedWidth = availableWidth
    }

    override var collectionViewContentSize: NSSize {
        let rows = CGFloat(rowCount)
        let height = metrics.insets.top + metrics.insets.bottom + rows * rowPitch - (rowCount > 0 ? metrics.spacing.height : 0)
        let minimum = collectionView?.enclosingScrollView?.contentSize.height ?? 0
        return NSSize(width: availableWidth, height: max(height, minimum))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        indexes(in: rect).compactMap { index in
            let frame = frame(forItem: index)
            return frame.intersects(rect) ? attributes(index, frame) : nil
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < itemCount else { return nil }
        return attributes(indexPath.item, frame(forItem: indexPath.item))
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }

    private func attributes(_ index: Int, _ frame: NSRect) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frame
        return attributes
    }
}
```

- [ ] **Step 5: Implement the grid item and label truncation**

```swift
// Sources/UI/Icons/IconItem.swift
import AppKit
import Core
import MacxFS

/// Two-line label with a middle ellipsis (§5.5). Works on Characters, so graphemes are never split, and keeps the
/// extension visible. Measured with the same text system the label uses.
@MainActor
enum LabelTruncation {
    private static var twoLineHeights: [NSFont: CGFloat] = [:]

    static func twoLineMiddle(_ name: String, width: CGFloat, font: NSFont) -> String {
        let limit = twoLineHeight(font) + 0.5
        if height(of: name, width: width, font: font) <= limit { return name }
        let characters = Array(name)
        let extensionLength = name.lastIndex(of: ".").map { name.distance(from: $0, to: name.endIndex) } ?? 0
        var low = 0
        var high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if height(of: candidate(characters, keep: mid, extensionLength: extensionLength), width: width, font: font) <= limit {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return candidate(characters, keep: low, extensionLength: extensionLength)
    }

    /// Keeps `keep` characters: half from the start, and from the end at least the extension plus three characters.
    static func candidate(_ characters: [Character], keep: Int, extensionLength: Int) -> String {
        let tail = min(keep, max(keep / 2, min(extensionLength, 12) + 3))
        let head = keep - tail
        return String(characters[0..<head]) + "…" + String(characters[(characters.count - tail)...])
    }

    private static func height(of text: String, width: CGFloat, font: NSFont) -> CGFloat {
        (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
    }

    private static func twoLineHeight(_ font: NSFont) -> CGFloat {
        if let cached = twoLineHeights[font] { return cached }
        let value = height(of: "X\nX", width: 1_000, font: font)
        twoLineHeights[font] = value
        return value
    }
}

final class IconItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("macx.iconItem")
    let iconView = NSImageView()
    let label = NSTextField(wrappingLabelWithString: "")
    let highlight = NSView()
    let cloudBadge = NSImageView()
    private(set) var rowID: RowID?
    private var iconSide: NSLayoutConstraint!
    private var shownName = ""
    private var shownWidth: Double = 0

    override func loadView() {
        let root = NSView()
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        for part in [highlight, iconView, label, cloudBadge] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(part)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.font = CellStyle.smallFont
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        cloudBadge.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: L10n.string("In iCloud, not downloaded"))
        cloudBadge.contentTintColor = .secondaryLabelColor
        iconSide = iconView.widthAnchor.constraint(equalToConstant: 64)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
            highlight.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            highlight.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconSide,
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            label.heightAnchor.constraint(equalToConstant: GridMetrics.labelHeight),
            cloudBadge.trailingAnchor.constraint(equalTo: iconView.trailingAnchor),
            cloudBadge.bottomAnchor.constraint(equalTo: iconView.bottomAnchor),
            cloudBadge.widthAnchor.constraint(equalToConstant: 14),
        ])
        view = root
    }

    func configure(name: String, icon: CGImage, points: Double, labelWidth: Double, isCut: Bool, isSelected: Bool,
                   emphasized: Bool, isDataless: Bool, rowID: RowID) {
        self.rowID = rowID
        setIcon(icon, points: points)
        if name != shownName || labelWidth != shownWidth {
            label.stringValue = LabelTruncation.twoLineMiddle(name, width: CGFloat(labelWidth), font: CellStyle.smallFont)
            shownName = name
            shownWidth = labelWidth
        }
        label.toolTip = name
        cloudBadge.isHidden = !isDataless
        view.setAccessibilityLabel(isCut ? String(format: L10n.string("%@, cut"), name) : name)
        applyState(isCut: isCut, isSelected: isSelected, emphasized: emphasized)
    }

    func setIcon(_ icon: CGImage, points: Double) {
        iconSide.constant = points
        iconView.image = NSImage(cgImage: icon, size: NSSize(width: points, height: points))
    }

    /// Selection is drawn from the model (§5.5); cut items are dimmed and italic (§8).
    func applyState(isCut: Bool, isSelected: Bool, emphasized: Bool) {
        view.alphaValue = isCut ? 0.5 : 1
        label.font = isCut ? CellStyle.smallItalicFont : CellStyle.smallFont
        label.textColor = isSelected && emphasized ? .alternateSelectedControlTextColor : .labelColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor? = isSelected ? (emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor) : nil
            highlight.layer?.backgroundColor = color?.cgColor
        }
    }
}
```

- [ ] **Step 6: Implement the Icons view controller**

```swift
// Sources/UI/Icons/IconsViewController.swift
import AppKit
import Core
import MacxFS

/// NSCollectionView batch updates use separate old and new index spaces, not NSTableView's sequential semantics.
/// So any structural change reloads (O(visible) with FileGridLayout), and pure reloads update in place.
enum GridUpdatePlan: Equatable { case nothing, reloadItems(IndexSet), reloadAll }

enum GridChangePolicy {
    static func plan(_ set: ChangeSet) -> GridUpdatePlan {
        if set.isEmpty { return .nothing }
        var reloads = IndexSet()
        for change in set.changes {
            guard case .reload(let rows) = change else { return .reloadAll }
            reloads.formUnion(rows)
        }
        return .reloadItems(reloads)
    }
}

/// Rubber-band selection (§5.5): plain replaces, ⇧ adds, ⌘ toggles.
@MainActor
enum RubberBand {
    enum Mode: Equatable { case replace, add, toggle }

    static func mode(for flags: NSEvent.ModifierFlags) -> Mode {
        flags.contains(.command) ? .toggle : (flags.contains(.shift) ? .add : .replace)
    }

    static func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func hits(in rect: NSRect, layout: FileGridLayout) -> IndexSet {
        var hits = IndexSet()
        for index in layout.indexes(in: rect) where layout.frame(forItem: index).intersects(rect) { hits.insert(index) }
        return hits
    }

    static func selection(base: IndexSet, hits: IndexSet, mode: Mode) -> IndexSet {
        switch mode {
        case .replace: hits
        case .add: base.union(hits)
        case .toggle: base.symmetricDifference(hits)
        }
    }
}

final class RubberBandView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
    }
    required init?(coder: NSCoder) { fatalError("RubberBandView is created in code") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// NSCollectionView with model-owned selection. P1-33 adds SelectionController clicks and type-select, P1-35
/// context menus, P1-36 drags.
final class FileCollectionView: NSCollectionView {
    weak var owner: IconsViewController?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if owner?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return super.mouseDown(with: event) }
        owner.handleMouseDown(event)
    }

    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(Selector(("selectAll:")), with: sender)
    }
}

@MainActor
final class IconsViewController: NSViewController, FileListView, FocusableList, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let context: UIContext
    let layout = FileGridLayout()
    let collectionView = FileCollectionView()
    let scrollView = NSScrollView()
    private(set) var folder: FolderModel?
    private var settingsLoop: ObservationLoop?
    private var isRestoringScroll = false
    var focusView: NSView { collectionView }
    private var settings: Settings { context.environment.settings }
    private var points: Double { layout.iconSize.points }

    init(context: UIContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("IconsViewController is created in code") }

    override func loadView() {
        layout.iconSize = settings.iconSize
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.owner = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.reuseID)
        collectionView.setAccessibilityIdentifier(AXID.iconsGrid)
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        view = scrollView
        settingsLoop = ObservationLoop { [weak self] in
            _ = self?.settings.iconSize
        } onChange: { [weak self] in
            self?.applyIconSize()
        }
    }

    // MARK: FileListView

    func bind(_ folder: FolderModel?) {
        self.folder = folder
        layout.itemCount = folder?.rowCount ?? 0
        collectionView.reloadData()
        if let folder { restoreScroll(anchor: folder.scrollAnchor) }
        reloadSelectionDrawing()
    }

    func apply(_ changes: ChangeSet) {
        guard let folder else { return }
        layout.itemCount = folder.rowCount
        switch GridChangePolicy.plan(changes) {
        case .nothing: break
        case .reloadItems(let rows):
            collectionView.reloadItems(at: Set(rows.filteredIndexSet { $0 < folder.rowCount }.map { IndexPath(item: $0, section: 0) }))
        case .reloadAll:
            let anchor = folder.scrollAnchor
            collectionView.reloadData()
            restoreScroll(anchor: anchor)
        }
        reloadSelectionDrawing()
        context.icons.cancelFileIcons(notIn: Set(visibleRows().filter { $0 < folder.rowCount }.map { folder.identity(atRow: $0) }))
    }

    func reloadSelectionDrawing() {
        guard let folder else { return }
        let emphasized = isEmphasized
        for case let item as IconItem in collectionView.visibleItems() {
            guard let index = collectionView.indexPath(for: item)?.item, index < folder.rowCount else { continue }
            item.applyState(isCut: folder.isCut(row: index), isSelected: folder.selection.rows.contains(index), emphasized: emphasized)
        }
    }

    func beginInlineRename(row: Int) {
        scrollToRow(row)   // P1-34 replaces this body with InlineRenameController
    }

    func scrollToRow(_ row: Int) {
        guard row >= 0, row < layout.itemCount else { return }
        collectionView.scrollToVisible(layout.frame(forItem: row).insetBy(dx: 0, dy: -layout.metrics.spacing.height))
    }

    func topVisibleRow() -> Int? {
        let range = layout.indexes(in: collectionView.visibleRect)
        return range.isEmpty ? nil : range.lowerBound
    }

    func visibleRows() -> Range<Int> { layout.indexes(in: collectionView.visibleRect) }

    // MARK: scroll anchor (§4.3)

    private func restoreScroll(anchor: RowID?) {
        guard let folder else { return }
        isRestoringScroll = true
        defer { isRestoringScroll = false }
        let row = anchor.flatMap { folder.row(of: $0) } ?? 0
        let y = row > 0 && row < layout.itemCount ? layout.frame(forItem: row).minY - layout.metrics.insets.top : 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y - scrollView.contentView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        guard !isRestoringScroll, let folder else { return }
        if let top = topVisibleRow(), top > 0 { folder.scrollAnchor = folder.identity(atRow: top) } else { folder.scrollAnchor = nil }
    }

    // MARK: input

    private var isEmphasized: Bool {
        (view.window?.isKeyWindow ?? false) && view.window?.firstResponder === collectionView
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if KeyRouter.handle(event, focus: .content, returnKey: settings.returnKey, from: collectionView) { return true }
        guard let folder, let direction = Self.direction(event.specialKey) else { return false }
        if event.modifierFlags.contains(.command) { return true }   // ⌘-arrows never change the selection (§5.5)
        let cursor = folder.selection.cursor.flatMap { folder.row(of: $0) }
        let target: Int? = if let cursor { layout.neighbor(of: cursor, direction) } else { folder.rowCount > 0 ? 0 : nil }
        guard let target else { return true }
        folder.select(event.modifierFlags.contains(.shift) ? .extend(to: target) : .set(IndexSet(integer: target), cursor: target))
        scrollToRow(target)
        return true
    }

    static func direction(_ key: NSEvent.SpecialKey?) -> GridDirection? {
        switch key {
        case .upArrow?: .up
        case .downArrow?: .down
        case .leftArrow?: .left
        case .rightArrow?: .right
        default: nil
        }
    }

    func handleMouseDown(_ event: NSEvent) {
        guard let folder else { return }
        view.window?.makeFirstResponder(collectionView)
        let point = collectionView.convert(event.locationInWindow, from: nil)
        if let index = layout.itemIndex(at: point) {
            if event.clickCount >= 2 {
                NSApp.sendAction(Selector(Command.open.selectorName), to: nil, from: collectionView)
            } else {
                folder.select(.set(IndexSet(integer: index), cursor: index))   // P1-33: SelectionController.click
            }
            return
        }
        trackRubberBand(from: point, event: event)
    }

    private func trackRubberBand(from start: NSPoint, event: NSEvent) {
        guard let folder, let window = collectionView.window else { return }
        let mode = RubberBand.mode(for: event.modifierFlags)
        let base = mode == .replace ? IndexSet() : folder.selection.rows
        if mode == .replace { folder.select(.none) }
        let overlay = RubberBandView(frame: NSRect(origin: start, size: .zero))
        collectionView.addSubview(overlay)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] next, stop in
            guard let self, let next, next.type == .leftMouseDragged else { stop.pointee = true; return }
            self.collectionView.autoscroll(with: next)
            let rect = RubberBand.rect(from: start, to: self.collectionView.convert(next.locationInWindow, from: nil))
            overlay.frame = rect
            self.applyRubberBand(rect: rect, mode: mode, base: base)
        }
        overlay.removeFromSuperview()
    }

    func applyRubberBand(rect: NSRect, mode: RubberBand.Mode, base: IndexSet) {
        guard let folder else { return }
        let hits = RubberBand.hits(in: rect, layout: layout)
        folder.select(.set(RubberBand.selection(base: base, hits: hits, mode: mode), cursor: hits.last))
    }

    private func applyIconSize() {
        guard layout.iconSize != settings.iconSize else { return }
        let anchor = folder?.scrollAnchor
        layout.iconSize = settings.iconSize
        collectionView.reloadData()
        restoreScroll(anchor: anchor)
    }

    // MARK: data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { folder?.rowCount ?? 0 }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.reuseID, for: indexPath) as? IconItem ?? IconItem()
        configure(item, row: indexPath.item)
        return item
    }

    private func configure(_ item: IconItem, row: Int) {
        guard let folder, row < folder.rowCount else { return }
        let entry = folder.entry(atRow: row)
        let name = folder.name(atRow: row)
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        let rowID = folder.identity(atRow: row)
        let points = self.points
        item.configure(name: name, icon: context.icons.typeIcon(entry.typeIndex, points: points, scale: scale), points: points,
                       labelWidth: Double(layout.metrics.itemSize.width - 8), isCut: folder.isCut(row: row),
                       isSelected: folder.selection.rows.contains(row), emphasized: isEmphasized,
                       isDataless: entry.flags.contains(.dataless), rowID: rowID)
        let url = folder.url(atRow: row)
        let isVolumeRoot = entry.kind == .directory
            && context.environment.volumes.mountTable.volumes.contains { $0.mountPoint.standardizedFileURL == url.standardizedFileURL }
        guard context.icons.needsFileIcon(entry, name: name, isVolumeRoot: isVolumeRoot) else { return }
        context.icons.fileIcon(for: url, rowID: rowID, points: points, scale: scale) { [weak item] image in
            guard let item, item.rowID == rowID else { return }
            item.setIcon(image, points: points)
        }
    }
}
```

- [ ] **Step 7: Let the content host switch views**

In `Sources/UI/Content/ContentViewController.swift`, add a stored property next to `details`:

```swift
    private(set) var icons: IconsViewController?
```

Replace the whole `setViewMode(_:)` method with:

```swift
    func setViewMode(_ mode: ViewMode) {
        let list: FileListView
        switch mode {
        case .details: list = details
        case .icons: list = iconsController()
        }
        guard list !== activeList || mountedListView !== list.view else { return }
        if list !== activeList {
            activeList.bind(nil)
            activeList = list
        }
        mount(list)
        list.bind(session.folder)
    }

    private func iconsController() -> IconsViewController {
        if let icons { return icons }
        let created = IconsViewController(context: context)
        addChild(created)
        icons = created
        return created
    }
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter 'UITests\.(FileGridLayoutTests|IconsViewTests|DetailsViewTests)' 2>&1 | tail -5`
Expected: `Executed 31 tests, with 0 failures` (with no GUI session: `with 14 tests skipped and 0 failures`).

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 9: Verify in the app (sandbox only)**

With the manual run recipe, switch to Icons with the toolbar view switcher (P1-27) or View › Icons:
1. The cells form a fixed grid. Widening the window adds columns without any visible jump, and long names (`file40.txt` is short; rename one in Finder **inside the sandbox** to a 120-character name) wrap to two lines with a middle `…` that keeps `.txt`.
2. Drag in empty space and a rubber band selects items. ⇧-drag adds; ⌘-drag toggles.
3. Arrow keys move by row and column, and ⇧-arrows extend. Small/Medium/Large (View menu) resize the cells and keep the first visible item.
4. With the 100k fixture, Icons view scrolls smoothly.

- [ ] **Step 10: Commit**

```bash
git add Sources/UI/Icons Sources/UI/Content/ContentViewController.swift Tests/UITests/FileGridLayoutTests.swift Tests/UITests/IconsViewTests.swift
git commit -m "feat: icons view with fixed-grid layout, rubber band and spatial arrows (P1-32)"
```

---

### Task P1-33: Selection semantics, type-select, empty states, banner, filter and status wiring

**Spec coverage:** §5.5 Selection (click; ⌘-click toggles; ⇧-click range; ⇧+arrow extends from the anchor, spatially in Icons; ⌘+arrow never changes the selection; ⌘A / Invert are model commands; type-select; the canonical selection lives in `FolderModel`, views never use their built-in selection). §5.7 double-click opens and ⌘-double-click opens in a new window. §5.5 Empty states (all eight texts and their buttons: Open Privacy Settings, Properties, Retry; "Waiting for macOS permission…"). §4.3 non-modal "'X' was moved or deleted" banner. §5.2 filter-in-folder ("No items match '…'"). §5.5 status bar `N items` / `M selected (size)` updated incrementally. §5.9 TCC denial shows the empty state, not an alert.

**Files:**
- Create: `Sources/UI/Content/SelectionController.swift`
- Create: `Sources/UI/Content/TypeSelect.swift`
- Create: `Sources/UI/Content/EmptyStateView.swift`
- Create: `Sources/UI/Content/BannerView.swift`
- Create: `Sources/UI/Support/ExternalURLOpener.swift`
- Modify: `Sources/UI/Details/DetailsViewController.swift`, `Sources/UI/Icons/IconsViewController.swift`, `Sources/UI/Content/ContentViewController.swift`, `Tests/UITests/Support/ContentTestHarness.swift`, `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/SelectionControllerTests.swift`, `Tests/UITests/TypeSelectTests.swift`, `Tests/UITests/EmptyStateTests.swift`

**Interfaces:**
- Consumes: `SelectionCommand` (`.set(IndexSet, cursor:)`, `.toggle`, `.extend(to:)`, `.none`), `Selection.rows/cursor`, `FolderModel.select/selection/row(of:)/store/retry()/state/query/rowCount/directory/selectionSummary`, `FolderState`, `Reason`, `EntryStore.visibleCount/storageIndex(forRow:)/name(_:)/version`, `SortKeys.searchFold(_:)`, `SessionEvent.banner(String?)`, `ScenarioHooks.emptyStateText/bannerText`, `BrowserWindowController.scenarioHooks`, `AXID.emptyState/banner/statusSelection`, `LaunchOptions.isSandboxed/fakeLaunchServices`; P1-31/32 list types.
- Produces (internal):
  - `struct ClickModifiers: OptionSet` (`.command`, `.shift`, `init(_ flags: NSEvent.ModifierFlags)`); `enum ClickResolution { case select(SelectionCommand), selectOnMouseUp(SelectionCommand), open(newWindow: Bool), nothing }`; `enum NavKey { case up, down, left, right, home, end, pageUp, pageDown; init?(_ key: NSEvent.SpecialKey?) }`.
  - `enum SelectionController { static func click(row: Int?, clickCount: Int, modifiers: ClickModifiers, selectedRows: IndexSet) -> ClickResolution; static func arrow(_ key: NavKey, extend: Bool, cursorRow: Int?, rowCount: Int, pageSize: Int, navigate: (Int, NavKey) -> Int?) -> SelectionCommand?; static func linearNavigator(rowCount: Int) -> (Int, NavKey) -> Int?; static func gridNavigator(_ layout: FileGridLayout) -> (Int, NavKey) -> Int?; static func targetRow(of: SelectionCommand) -> Int? }`
  - `@MainActor final class ListMouseHandler { func mouseDown(row: Int?, event: NSEvent, folder: FolderModel, from view: NSView); func mouseUp(folder: FolderModel); func cancelPendingForDrag(); var mouseDownWindowPoint: NSPoint?; var mouseDownRow: Int? }`; `@MainActor enum ListKeys { static func handle(_ event: NSEvent, folder: FolderModel, list: FileListView, pageSize: Int, navigate: (Int, NavKey) -> Int?, typeSelect: TypeSelect) -> Bool }`.
  - `struct TypeSelectQuery`; `@MainActor final class TypeSelect { init(timeout:now:); var buffer: String; func append(_:) -> TypeSelectQuery; func reset(); func handle(_:folder:list:); static func accepts(_:bufferEmpty:) -> Bool; static let inlineLimit }`; `enum TypeSelectSearch { static func find(_:in:from:) -> Int? }`.
  - `enum EmptyStateAction { case openPrivacySettings, properties, retry }`; `struct EmptyStateContent { title, detail, action, showsSpinner; static func make(state:folderName:visibleCount:filter:) -> EmptyStateContent? }`; `final class EmptyStateView: NSView { show(_:); content; currentText; onAction; performAction() }`; `final class BannerView: NSView { show(_:); hide(); currentText }`.
  - `@MainActor protocol ExternalURLOpening: AnyObject { func open(_ url: URL) }`, `WorkspaceURLOpener`, `RecordingURLOpener.shared` (`opened`, `reset()`), `ExternalOpeners.opener(for: LaunchOptions)`, `SystemSettingsLinks.privacyAllFiles`.
  - `ContentViewController.emptyState`, `.banner`, `.updateEmptyState()`, `.showBanner(_:)`, `.performEmptyStateAction(_:)`, `.installScenarioHooks()`.

- [ ] **Step 1: Write the failing selection tests**

```swift
// Tests/UITests/SelectionControllerTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class SelectionControllerTests: XCTestCase {
    private let one = IndexSet(integer: 1)

    func testPlainClickSelectsOnly() {
        XCTAssertEqual(SelectionController.click(row: 3, clickCount: 1, modifiers: [], selectedRows: one),
                       .select(.set(IndexSet(integer: 3), cursor: 3)))
    }

    func testModifierClicks() {
        XCTAssertEqual(SelectionController.click(row: 3, clickCount: 1, modifiers: .command, selectedRows: one), .select(.toggle(3)))
        XCTAssertEqual(SelectionController.click(row: 3, clickCount: 1, modifiers: .shift, selectedRows: one), .select(.extend(to: 3)))
        XCTAssertEqual(SelectionController.click(row: 3, clickCount: 1, modifiers: [.command, .shift], selectedRows: one),
                       .select(.extend(to: 3)))
        XCTAssertEqual(SelectionController.click(row: nil, clickCount: 1, modifiers: [], selectedRows: one), .select(.none))
        XCTAssertEqual(SelectionController.click(row: nil, clickCount: 1, modifiers: .command, selectedRows: one), .nothing)
    }

    func testClickInsideMultiSelectionDefersToMouseUp() {
        XCTAssertEqual(SelectionController.click(row: 2, clickCount: 1, modifiers: [], selectedRows: IndexSet([1, 2])),
                       .selectOnMouseUp(.set(IndexSet(integer: 2), cursor: 2)), "keeps the selection so it can be dragged")
    }

    func testDoubleClickOpensAndCommandDoubleClickOpensNewWindow() {
        XCTAssertEqual(SelectionController.click(row: 2, clickCount: 2, modifiers: [], selectedRows: one), .open(newWindow: false))
        XCTAssertEqual(SelectionController.click(row: 2, clickCount: 2, modifiers: .command, selectedRows: one), .open(newWindow: true))
        XCTAssertEqual(SelectionController.click(row: nil, clickCount: 2, modifiers: [], selectedRows: one), .nothing)
    }

    func testArrowsLinear() {
        let nav = SelectionController.linearNavigator(rowCount: 10)
        func arrow(_ key: NavKey, _ cursor: Int?, extend: Bool = false) -> SelectionCommand? {
            SelectionController.arrow(key, extend: extend, cursorRow: cursor, rowCount: 10, pageSize: 4, navigate: nav)
        }
        XCTAssertEqual(arrow(.down, 3), .set(IndexSet(integer: 4), cursor: 4))
        XCTAssertEqual(arrow(.up, 3, extend: true), .extend(to: 2))
        XCTAssertNil(arrow(.up, 0))
        XCTAssertNil(arrow(.down, 9))
        XCTAssertEqual(arrow(.down, nil), .set(IndexSet(integer: 0), cursor: 0), "no cursor: start at the first row")
        XCTAssertEqual(arrow(.end, 3), .set(IndexSet(integer: 9), cursor: 9))
        XCTAssertEqual(arrow(.home, 3, extend: true), .extend(to: 0))
        XCTAssertEqual(arrow(.pageDown, 8), .set(IndexSet(integer: 9), cursor: 9))
        XCTAssertEqual(arrow(.pageUp, 6), .set(IndexSet(integer: 2), cursor: 2))
        XCTAssertNil(SelectionController.arrow(.down, extend: false, cursorRow: nil, rowCount: 0, pageSize: 4, navigate: nav))
    }

    func testLeftRightDoNothingInDetails() {
        let nav = SelectionController.linearNavigator(rowCount: 10)
        XCTAssertNil(nav(3, .left))
        XCTAssertNil(nav(3, .right))
    }

    func testGridNavigatorMapping() {
        let grid = FileGridLayout()
        grid.itemCount = 10
        grid.fallbackWidth = 600
        let nav = SelectionController.gridNavigator(grid)
        XCTAssertEqual(nav(1, .down), 5)
        XCTAssertEqual(nav(4, .left), 3)
        XCTAssertNil(nav(1, .home), "Home/End/Page are handled by SelectionController.arrow, not the navigator")
    }

    // MARK: AppKit

    private func makeDetails(_ h: ContentTestHarness, names: [String]) async throws -> (DetailsViewController, FolderModel, NSWindow) {
        for name in names { try h.file(name) }
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        let window = try h.host(details)
        details.bind(folder)
        window.makeFirstResponder(details.tableView)
        return (details, folder, window)
    }

    private func click(_ details: DetailsViewController, row: Int, flags: NSEvent.ModifierFlags = [], count: Int = 1,
                       type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        let table = details.tableView
        let point = table.convert(NSPoint(x: table.rect(ofRow: row).midX, y: table.rect(ofRow: row).midY), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                                windowNumber: table.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                clickCount: count, pressure: 1))
    }

    func testShiftClickInTableExtendsModelSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder, _) = try await makeDetails(h, names: ["a", "b", "c", "d", "e"])
        details.tableView.mouseDown(with: try click(details, row: 1))
        details.tableView.mouseUp(with: try click(details, row: 1, type: .leftMouseUp))
        details.tableView.mouseDown(with: try click(details, row: 3, flags: .shift))
        XCTAssertEqual(folder.selection.rows, IndexSet(integersIn: 1...3))
        details.tableView.mouseDown(with: try click(details, row: 2, flags: .command))
        XCTAssertEqual(folder.selection.rows, IndexSet([1, 3]))
        XCTAssertEqual(details.tableView.selectedRowIndexes, IndexSet([1, 3]), "highlight mirrors the model")
    }

    func testMouseUpAppliesDeferredSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder, _) = try await makeDetails(h, names: ["a", "b", "c"])
        folder.select(.set(IndexSet([0, 2]), cursor: 2))
        details.tableView.mouseDown(with: try click(details, row: 2))
        XCTAssertEqual(folder.selection.rows, IndexSet([0, 2]), "unchanged until mouse-up")
        details.tableView.mouseUp(with: try click(details, row: 2, type: .leftMouseUp))
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 2))
    }

    func testCommandArrowDoesNotChangeSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder, window) = try await makeDetails(h, names: ["a", "b", "c"])
        folder.select(.set(IndexSet(integer: 1), cursor: 1))
        let down = String(Character(UnicodeScalar(UInt16(NSEvent.SpecialKey.downArrow.rawValue))!))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: down,
                                                   charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125))
        details.tableView.keyDown(with: event)
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 1))
        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: down,
                                                   charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125))
        details.tableView.keyDown(with: plain)
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 2))
    }

    func testBuiltInTableSelectionNeverReachesModel() async throws {
        let h = try await ContentTestHarness.make(self)
        let (details, folder, _) = try await makeDetails(h, names: ["a", "b", "c"])
        folder.select(.set(IndexSet(integer: 0), cursor: 0))
        let result = details.tableView(details.tableView, selectionIndexesForProposedSelection: IndexSet(integer: 2))
        XCTAssertEqual(result, IndexSet(integer: 0))
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 0))
    }
}
```

- [ ] **Step 2: Write the failing type-select and empty-state tests**

```swift
// Tests/UITests/TypeSelectTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class TypeSelectTests: XCTestCase {
    func testBufferResetsAfterTimeout() {
        var time = ContinuousClock.now
        let typeSelect = TypeSelect(timeout: .seconds(1), now: { time })
        XCTAssertEqual(typeSelect.append("a"), TypeSelectQuery(text: "a", cycle: true))
        XCTAssertEqual(typeSelect.append("b"), TypeSelectQuery(text: "ab", cycle: false))
        time = time.advanced(by: .milliseconds(1_500))
        XCTAssertEqual(typeSelect.append("c"), TypeSelectQuery(text: "c", cycle: true))
    }

    func testRepeatedLetterCycles() {
        let typeSelect = TypeSelect()
        _ = typeSelect.append("s")
        XCTAssertEqual(typeSelect.append("s"), TypeSelectQuery(text: "s", cycle: true))
        XCTAssertEqual(typeSelect.append("s"), TypeSelectQuery(text: "s", cycle: true))
    }

    func testFindIsCaseAndDiacriticInsensitive() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["apple.txt", "École.txt", "zeta.txt"] { try h.file(name) }
        let folder = try await h.openFolder()
        let row = TypeSelectSearch.find(TypeSelectQuery(text: "eco", cycle: false), in: folder.store, from: nil)
        XCTAssertEqual(row.map(folder.name(atRow:)), "École.txt")
        XCTAssertNil(TypeSelectSearch.find(TypeSelectQuery(text: "q", cycle: true), in: folder.store, from: nil))
    }

    func testFindWrapsAndCyclesFromCursor() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["sa", "sb", "t", "sc"] { try h.file(name) }
        let folder = try await h.openFolder()   // display order: sa sb sc t
        let s = TypeSelectQuery(text: "s", cycle: true)
        XCTAssertEqual(TypeSelectSearch.find(s, in: folder.store, from: 0), 1, "cycling starts after the cursor")
        XCTAssertEqual(TypeSelectSearch.find(s, in: folder.store, from: 2), 0, "and wraps")
        XCTAssertEqual(TypeSelectSearch.find(TypeSelectQuery(text: "sb", cycle: false), in: folder.store, from: 1), 1,
                       "a longer prefix may stay on the cursor row")
    }

    func testTypingSelectsMatchingRow() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["alpha", "beta", "gamma"] { try h.file(name) }
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        _ = details.view
        details.bind(folder)
        details.typeSelect.handle("g", folder: folder, list: details)
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 2))
    }

    func testLargeFolderSearchRunsOffMainAndApplies() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<2_500 { try h.file(String(format: "a%04d", i)) }
        try h.file("zebra")
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        _ = details.view
        details.bind(folder)
        details.typeSelect.handle("z", folder: folder, list: details)
        XCTAssertTrue(folder.selection.rows.isEmpty, "large folders search off main")
        try await h.waitUntil("type-select applied") { folder.selection.rows == IndexSet(integer: 2_500) }
    }
}
```

```swift
// Tests/UITests/EmptyStateTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class EmptyStateTests: XCTestCase {
    func testContentForEveryState() {
        func make(_ state: FolderState, count: Int = 0, filter: String = "") -> EmptyStateContent? {
            EmptyStateContent.make(state: state, folderName: "Docs", visibleCount: count, filter: filter)
        }
        XCTAssertEqual(make(.complete)?.title, "This folder is empty")
        XCTAssertNil(make(.complete, count: 3))
        XCTAssertEqual(make(.complete, filter: "zz")?.title, "No items match 'zz'")
        XCTAssertNil(make(.loading))
        XCTAssertNil(make(.partial))
        XCTAssertEqual(make(.error(.permissionTCC)), EmptyStateContent(title: "macOS is blocking access to 'Docs'", detail: nil,
                                                                      action: .openPrivacySettings))
        XCTAssertEqual(make(.error(.permissionPOSIX)), EmptyStateContent(title: "You don't have permission to view 'Docs'",
                                                                        detail: nil, action: .properties))
        XCTAssertNil(make(.error(.notFound)), "handled by navigate-to-ancestor (§4.3)")
        XCTAssertNil(make(.error(.volumeGone)))
        let notDir = try? XCTUnwrap(make(.error(.notADirectory)))
        XCTAssertEqual(notDir?.title, "Can't open 'Docs'")
        XCTAssertEqual(notDir?.detail, String(cString: strerror(ENOTDIR)))
        XCTAssertEqual(notDir?.action, .retry)
        XCTAssertEqual(make(.error(.other(EIO)))?.detail, "\(String(cString: strerror(EIO))) (\(EIO))")
        XCTAssertEqual(make(.unresponsive), EmptyStateContent(title: "Location not responding", detail: nil, action: .retry))
        XCTAssertEqual(make(.waitingForPermission),
                       EmptyStateContent(title: "Waiting for macOS permission…", detail: nil, action: nil, showsSpinner: true))
    }

    func testActionTitles() {
        XCTAssertEqual(EmptyStateAction.openPrivacySettings.title, "Open Privacy Settings")
        XCTAssertEqual(EmptyStateAction.properties.title, "Properties")
        XCTAssertEqual(EmptyStateAction.retry.title, "Retry")
    }

    func testEmptyStateOverlayPassesClicksThrough() {
        let view = EmptyStateView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.show(EmptyStateContent(title: "This folder is empty", detail: nil, action: nil))
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.hitTest(NSPoint(x: 5, y: 5)), "right-click on empty space must reach the list")
    }

    func testEmptyFolderShowsMessage() async throws {
        let h = try await ContentTestHarness.make(self)
        let (content, _, _) = try await h.makeContent()
        XCTAssertEqual(content.emptyState.currentText, "This folder is empty")
        XCTAssertEqual(content.emptyState.accessibilityIdentifier(), AXID.emptyState)
    }

    func testFilterWithNoMatchesShowsQuery() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, session, _) = try await h.makeContent()
        XCTAssertNil(content.emptyState.currentText)
        var query = session.folder.query
        query.filter = "zz"
        session.folder.setQuery(query)
        try await h.waitUntil("no-match state") { content.emptyState.currentText == "No items match 'zz'" }
    }

    func testPermissionPOSIXShowsPropertiesButton() async throws {
        try XCTSkipIf(getuid() == 0, "root can read mode-000 folders")
        let h = try await ContentTestHarness.make(self)
        try h.dir("locked")
        try h.setMode("locked", 0)
        let (content, session, _) = try await h.makeContent()
        session.navigate(to: h.url("locked"))
        try await h.waitUntil("POSIX empty state") { content.emptyState.content?.action == .properties }
        XCTAssertEqual(content.emptyState.currentText, "You don't have permission to view 'locked'")
    }

    func testRetryAndPrivacyActions() async throws {
        let h = try await ContentTestHarness.make(self)
        let (content, _, _) = try await h.makeContent()
        content.performEmptyStateAction(.openPrivacySettings)
        XCTAssertEqual(RecordingURLOpener.shared.opened, [SystemSettingsLinks.privacyAllFiles], "recorded, never opened (S5-C2)")
        content.performEmptyStateAction(.retry)
        try await h.waitUntil("retried") { content.session.folder.state == .complete }
    }

    func testBannerShowsAndHides() async throws {
        let h = try await ContentTestHarness.make(self)
        let (content, _, _) = try await h.makeContent()
        XCTAssertNil(content.banner.currentText)
        content.showBanner("'Old' was moved or deleted")
        XCTAssertEqual(content.banner.currentText, "'Old' was moved or deleted")
        XCTAssertEqual(content.banner.accessibilityIdentifier(), AXID.banner)
        content.showBanner(nil)
        XCTAssertNil(content.banner.currentText)
    }

    func testStatusBarReflectsSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt", bytes: 10); try h.file("b.txt", bytes: 20); try h.file("c.txt")
        let (content, session, _) = try await h.makeContent()
        session.folder.select(.set(IndexSet([0, 1]), cursor: 1))
        let label = try XCTUnwrap(Self.find(AXID.statusSelection, in: content.statusBar) as? NSTextField)
        try await h.waitUntil("selection shown") { label.stringValue.contains("2") }
    }

    static func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews { if let match = find(identifier, in: subview) { return match } }
        return nil
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter 'UITests\.(SelectionControllerTests|TypeSelectTests|EmptyStateTests)' 2>&1 | tail -20`
Expected: compile errors such as `cannot find 'SelectionController' in scope`, `cannot find 'EmptyStateContent' in scope`, `value of type 'DetailsViewController' has no member 'typeSelect'`.

- [ ] **Step 4: Add this task's strings**

Run:
```bash
scripts/l10n-add.sh "This folder is empty" "No items match '%@'" "macOS is blocking access to '%@'" \
  "You don't have permission to view '%@'" "Can't open '%@'" "Location not responding" "Waiting for macOS permission…" \
  "Open Privacy Settings" "Properties" "Retry" "Dismiss"
```

- [ ] **Step 5: Implement selection semantics**

```swift
// Sources/UI/Content/SelectionController.swift
import AppKit
import Core

struct ClickModifiers: OptionSet, Sendable {
    let rawValue: UInt8
    static let command = ClickModifiers(rawValue: 1 << 0)
    static let shift = ClickModifiers(rawValue: 1 << 1)
    init(rawValue: UInt8) { self.rawValue = rawValue }
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: ClickModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}

enum ClickResolution: Equatable {
    case select(SelectionCommand)
    case selectOnMouseUp(SelectionCommand)   // mouse-down inside a multi-selection: keep it so it can be dragged
    case open(newWindow: Bool)
    case nothing
}

enum NavKey: Equatable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown
    init?(_ key: NSEvent.SpecialKey?) {
        switch key {
        case .upArrow?: self = .up
        case .downArrow?: self = .down
        case .leftArrow?: self = .left
        case .rightArrow?: self = .right
        case .home?: self = .home
        case .end?: self = .end
        case .pageUp?: self = .pageUp
        case .pageDown?: self = .pageDown
        default: return nil
        }
    }
}

/// Pure mapping from input to SelectionCommand (§5.5). Both lists use it; Icons passes a spatial navigator.
enum SelectionController {
    static func click(row: Int?, clickCount: Int, modifiers: ClickModifiers, selectedRows: IndexSet) -> ClickResolution {
        if clickCount >= 2 { return row == nil ? .nothing : .open(newWindow: modifiers.contains(.command)) }
        guard let row else { return modifiers.isEmpty ? .select(.none) : .nothing }
        if modifiers.contains(.shift) { return .select(.extend(to: row)) }
        if modifiers.contains(.command) { return .select(.toggle(row)) }
        let only = SelectionCommand.set(IndexSet(integer: row), cursor: row)
        return selectedRows.contains(row) && selectedRows.count > 1 ? .selectOnMouseUp(only) : .select(only)
    }

    static func arrow(_ key: NavKey, extend: Bool, cursorRow: Int?, rowCount: Int, pageSize: Int,
                      navigate: (Int, NavKey) -> Int?) -> SelectionCommand? {
        guard rowCount > 0 else { return nil }
        let target: Int?
        switch (key, cursorRow) {
        case (.home, _): target = 0
        case (.end, _): target = rowCount - 1
        case (_, nil): target = 0
        case (.pageUp, let cursor?): target = max(0, cursor - max(pageSize, 1))
        case (.pageDown, let cursor?): target = min(rowCount - 1, cursor + max(pageSize, 1))
        case (_, let cursor?): target = navigate(cursor, key)
        }
        guard let target else { return nil }
        return extend ? .extend(to: target) : .set(IndexSet(integer: target), cursor: target)
    }

    static func linearNavigator(rowCount: Int) -> (Int, NavKey) -> Int? {
        { row, key in
            switch key {
            case .up: row > 0 ? row - 1 : nil
            case .down: row + 1 < rowCount ? row + 1 : nil
            default: nil   // ←/→ do nothing in Details; ⌘←/⌘→ are unbound (§5.5)
            }
        }
    }

    @MainActor
    static func gridNavigator(_ layout: FileGridLayout) -> (Int, NavKey) -> Int? {
        { row, key in
            switch key {
            case .up: layout.neighbor(of: row, .up)
            case .down: layout.neighbor(of: row, .down)
            case .left: layout.neighbor(of: row, .left)
            case .right: layout.neighbor(of: row, .right)
            default: nil
            }
        }
    }

    static func targetRow(of command: SelectionCommand) -> Int? {
        switch command {
        case .set(_, let cursor): cursor
        case .extend(let row): row
        case .toggle(let row): row
        default: nil
        }
    }
}

/// Mouse handling shared by Details and Icons. Built-in selection tracking is bypassed (S5-C4).
@MainActor
final class ListMouseHandler {
    private var pendingMouseUp: SelectionCommand?
    private(set) var mouseDownWindowPoint: NSPoint?
    private(set) var mouseDownRow: Int?

    func mouseDown(row: Int?, event: NSEvent, folder: FolderModel, from view: NSView) {
        mouseDownWindowPoint = event.locationInWindow
        mouseDownRow = row
        pendingMouseUp = nil
        switch SelectionController.click(row: row, clickCount: event.clickCount, modifiers: ClickModifiers(event.modifierFlags),
                                         selectedRows: folder.selection.rows) {
        case .select(let command): folder.select(command)
        case .selectOnMouseUp(let command): pendingMouseUp = command
        case .open(let newWindow):
            NSApp.sendAction(Selector((newWindow ? Command.openInNewWindow : Command.open).selectorName), to: nil, from: view)
        case .nothing: break
        }
    }

    func mouseUp(folder: FolderModel) {
        if let pendingMouseUp { folder.select(pendingMouseUp) }
        pendingMouseUp = nil
        mouseDownWindowPoint = nil
        mouseDownRow = nil
    }

    /// A drag started from the mouse-down (P1-36): keep the multi-selection.
    func cancelPendingForDrag() { pendingMouseUp = nil }
}

/// Navigation keys and type-select for a list (KeyRouter runs first for alternates).
@MainActor
enum ListKeys {
    static func handle(_ event: NSEvent, folder: FolderModel, list: FileListView, pageSize: Int,
                       navigate: (Int, NavKey) -> Int?, typeSelect: TypeSelect) -> Bool {
        if let key = NavKey(event.specialKey) {
            typeSelect.reset()
            if event.modifierFlags.contains(.command) { return true }   // ⌘-arrows never change the selection (§5.5)
            let cursor = folder.selection.cursor.flatMap { folder.row(of: $0) }
            if let command = SelectionController.arrow(key, extend: event.modifierFlags.contains(.shift), cursorRow: cursor,
                                                       rowCount: folder.rowCount, pageSize: pageSize, navigate: navigate) {
                folder.select(command)
                if let row = SelectionController.targetRow(of: command) { list.scrollToRow(row) }
            }
            return true
        }
        if TypeSelect.accepts(event, bufferEmpty: typeSelect.buffer.isEmpty) {
            typeSelect.handle(event.characters ?? "", folder: folder, list: list)
            return true
        }
        return false
    }
}
```

- [ ] **Step 6: Implement type-select**

```swift
// Sources/UI/Content/TypeSelect.swift
import AppKit
import Core
import MacxFS

struct TypeSelectQuery: Equatable, Sendable {
    var text: String
    var cycle: Bool   // one repeated character: move to the next match after the cursor (Explorer)
}

/// Prefix search on display rows, folded like the filter (§4.2 SortKeys rule 5). O(rows) with a bounded fold per
/// name, so big folders run it off main.
enum TypeSelectSearch {
    static func find(_ query: TypeSelectQuery, in store: EntryStore, from cursorRow: Int?) -> Int? {
        let needle = SortKeys.searchFold(query.text)
        let count = store.visibleCount
        guard !needle.isEmpty, count > 0 else { return nil }
        let begin = cursorRow.map { query.cycle ? $0 + 1 : $0 } ?? 0
        let prefixLength = query.text.count + 4
        for step in 0..<count {
            let row = (begin + step) % count
            let name = store.name(store.storageIndex(forRow: row))
            if SortKeys.searchFold(String(name.prefix(prefixLength))).starts(with: needle) { return row }
        }
        return nil
    }
}

@MainActor
final class TypeSelect {
    static let inlineLimit = 2_000
    private(set) var buffer = ""
    private var lastKey: ContinuousClock.Instant?
    private let timeout: Duration
    private let now: () -> ContinuousClock.Instant
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    init(timeout: Duration = .seconds(1), now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.timeout = timeout
        self.now = now
    }

    func reset() {
        buffer = ""
        lastKey = nil
    }

    func append(_ characters: String) -> TypeSelectQuery {
        let time = now()
        if let lastKey, time - lastKey > timeout { buffer = "" }
        lastKey = time
        buffer += characters
        let first = buffer.first.map(String.init) ?? ""
        let repeated = buffer.allSatisfy { String($0) == first }
        return TypeSelectQuery(text: repeated ? first : buffer, cycle: repeated)
    }

    static func accepts(_ event: NSEvent, bufferEmpty: Bool) -> Bool {
        guard event.specialKey == nil, event.modifierFlags.intersection([.command, .control]).isEmpty,
              let characters = event.characters, !characters.isEmpty else { return false }
        if characters == " " { return !bufferEmpty }
        return characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    func handle(_ characters: String, folder: FolderModel, list: FileListView) {
        let query = append(characters)
        let store = folder.store
        let cursor = folder.selection.cursor.flatMap { folder.row(of: $0) }
        generation += 1
        let token = generation
        let version = store.version
        if store.visibleCount <= Self.inlineLimit {
            apply(TypeSelectSearch.find(query, in: store, from: cursor), token: token, version: version, folder: folder, list: list)
            return
        }
        searchTask?.cancel()
        searchTask = Task { [weak self, weak folder, weak list] in
            let row = await Task.detached(priority: .userInitiated) { TypeSelectSearch.find(query, in: store, from: cursor) }.value
            guard let self, let folder, let list else { return }
            self.apply(row, token: token, version: version, folder: folder, list: list)
        }
    }

    private func apply(_ row: Int?, token: Int, version: UInt64, folder: FolderModel, list: FileListView) {
        guard let row, token == generation, folder.store.version == version else { return }
        folder.select(.set(IndexSet(integer: row), cursor: row))
        list.scrollToRow(row)
    }
}
```

- [ ] **Step 7: Implement empty states, banner and the external opener**

```swift
// Sources/UI/Support/ExternalURLOpener.swift
import AppKit
import Core

/// The one place S5 opens non-file URLs (System Settings deep links). Sandboxed runs record instead (S5-C2).
@MainActor protocol ExternalURLOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor final class WorkspaceURLOpener: ExternalURLOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

@MainActor final class RecordingURLOpener: ExternalURLOpening {
    static let shared = RecordingURLOpener()
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
    func reset() { opened = [] }
}

@MainActor enum ExternalOpeners {
    static func opener(for options: LaunchOptions) -> any ExternalURLOpening {
        options.isSandboxed || options.fakeLaunchServices ? RecordingURLOpener.shared : WorkspaceURLOpener()
    }
}

enum SystemSettingsLinks {
    static let privacyAllFiles = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
```

```swift
// Sources/UI/Content/EmptyStateView.swift
import AppKit
import Darwin
import Core

enum EmptyStateAction: Equatable, Sendable {
    case openPrivacySettings, properties, retry

    @MainActor var title: String {
        switch self {
        case .openPrivacySettings: L10n.string("Open Privacy Settings")
        case .properties: L10n.string("Properties")
        case .retry: L10n.string("Retry")
        }
    }
}

/// §5.5 empty states. notFound/volumeGone return nil: the window navigates to the nearest ancestor (§4.3).
struct EmptyStateContent: Equatable {
    var title: String
    var detail: String?
    var action: EmptyStateAction?
    var showsSpinner = false

    @MainActor
    static func make(state: FolderState, folderName: String, visibleCount: Int, filter: String) -> EmptyStateContent? {
        func titled(_ key: String) -> String { String(format: L10n.string(key), folderName) }
        switch state {
        case .loading, .partial:
            return nil
        case .complete:
            guard visibleCount == 0 else { return nil }
            if !filter.isEmpty { return EmptyStateContent(title: String(format: L10n.string("No items match '%@'"), filter)) }
            return EmptyStateContent(title: L10n.string("This folder is empty"))
        case .error(let reason):
            switch reason {
            case .permissionTCC:
                return EmptyStateContent(title: titled("macOS is blocking access to '%@'"), action: .openPrivacySettings)
            case .permissionPOSIX:
                return EmptyStateContent(title: titled("You don't have permission to view '%@'"), action: .properties)
            case .notFound, .volumeGone:
                return nil
            case .notADirectory:
                return EmptyStateContent(title: titled("Can't open '%@'"), detail: String(cString: strerror(ENOTDIR)), action: .retry)
            case .other(let code):
                return EmptyStateContent(title: titled("Can't open '%@'"), detail: "\(String(cString: strerror(code))) (\(code))",
                                         action: .retry)
            }
        case .unresponsive:
            return EmptyStateContent(title: L10n.string("Location not responding"), action: .retry)
        case .waitingForPermission:
            return EmptyStateContent(title: L10n.string("Waiting for macOS permission…"), showsSpinner: true)
        }
    }
}

/// Overlay above the list. Only its button takes clicks; everything else falls through to the list (empty-space
/// context menu, drops).
final class EmptyStateView: NSView {
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private(set) var content: EmptyStateContent?
    var onAction: ((EmptyStateAction) -> Void)?
    var currentText: String? { content?.title }

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(AXID.emptyState)
        spinner.style = .spinning
        spinner.controlSize = .small
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        button.target = self
        button.action = #selector(buttonPressed(_:))
        button.bezelStyle = .push
        let stack = NSStackView(views: [spinner, titleLabel, detailLabel, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("EmptyStateView is created in code") }

    func show(_ content: EmptyStateContent?) {
        self.content = content
        isHidden = content == nil
        guard let content else { spinner.stopAnimation(nil); return }
        titleLabel.stringValue = content.title
        detailLabel.stringValue = content.detail ?? ""
        detailLabel.isHidden = content.detail == nil
        button.title = content.action?.title ?? ""
        button.isHidden = content.action == nil
        spinner.isHidden = !content.showsSpinner
        if content.showsSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func performAction() { buttonPressed(nil) }

    @objc private func buttonPressed(_ sender: Any?) {
        if let action = content?.action { onAction?(action) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, !button.isHidden, hit === button || hit.isDescendant(of: button) else { return nil }
        return hit
    }
}
```

```swift
// Sources/UI/Content/BannerView.swift
import AppKit
import Core

/// Non-modal banner (§4.3) shown above the list, e.g. "'X' was moved or deleted". The text comes from
/// SessionEvent.banner, already localized by BrowserSession.
final class BannerView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dismiss = NSButton()
    var currentText: String? { isHidden ? nil : label.stringValue }

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(AXID.banner)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemYellow
        label.lineBreakMode = .byTruncatingMiddle
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.string("Dismiss"))
        dismiss.setAccessibilityLabel(L10n.string("Dismiss"))
        dismiss.bezelStyle = .accessoryBarAction
        dismiss.isBordered = false
        dismiss.target = self
        dismiss.action = #selector(dismissPressed(_:))
        let stack = NSStackView(views: [icon, label, dismiss])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("BannerView is created in code") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    func show(_ text: String) {
        label.stringValue = text
        isHidden = false
    }

    func hide() { isHidden = true }

    @objc private func dismissPressed(_ sender: Any?) { hide() }
}
```

- [ ] **Step 8: Route the lists' mouse and keys through SelectionController**

In `Sources/UI/Details/DetailsViewController.swift`:

Replace the whole `FileTableView` class with:

```swift
/// NSTableView with the routing the content view needs. P1-35 adds context menus, P1-36 drags and right-drag.
final class FileTableView: NSTableView {
    weak var owner: DetailsViewController?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    /// Model-owned selection (S5-C4): NSTableView's own click tracking never runs.
    override func mouseDown(with event: NSEvent) {
        guard let owner else { return super.mouseDown(with: event) }
        owner.handleMouseDown(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let owner else { return super.mouseUp(with: event) }
        owner.handleMouseUp(event)
    }

    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(Selector(("selectAll:")), with: sender)
    }
}
```

In `loadView()`, replace the two lines `tableView.target = nil` and `tableView.doubleAction = Selector(Command.open.selectorName)` with:

```swift
        tableView.doubleAction = nil                // double-click is handled in handleMouseDown (clickCount 2)
```

Add two stored properties after `private var lastCutNames: Set<String> = []`:

```swift
    let mouse = ListMouseHandler()
    let typeSelect = TypeSelect()
```

Replace `handleKeyDown(_:)` with these three methods:

```swift
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if KeyRouter.handle(event, focus: .content, returnKey: settings.returnKey, from: tableView) {
            typeSelect.reset()
            return true
        }
        guard let folder else { return false }
        return ListKeys.handle(event, folder: folder, list: self, pageSize: max(1, visibleRows().count - 1),
                               navigate: SelectionController.linearNavigator(rowCount: folder.rowCount), typeSelect: typeSelect)
    }

    func handleMouseDown(_ event: NSEvent) {
        view.window?.makeFirstResponder(tableView)
        guard let folder else { return }
        let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
        mouse.mouseDown(row: row >= 0 ? row : nil, event: event, folder: folder, from: tableView)
    }

    func handleMouseUp(_ event: NSEvent) {
        guard let folder else { return }
        mouse.mouseUp(folder: folder)
    }
```

Replace `tableView(_:selectionIndexesForProposedSelection:)` with:

```swift
    /// Only the model's own mirror writes are accepted; built-in proposals never reach the model (S5-C4).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        isSyncingSelection ? proposed : (folder?.selection.rows ?? [])
    }
```

In `Sources/UI/Icons/IconsViewController.swift`:

Add to `FileCollectionView`:

```swift
    override func mouseUp(with event: NSEvent) {
        guard let owner else { return super.mouseUp(with: event) }
        owner.handleMouseUp(event)
    }
```

Add stored properties to `IconsViewController` after `private var isRestoringScroll = false`:

```swift
    let mouse = ListMouseHandler()
    let typeSelect = TypeSelect()
```

Replace `handleKeyDown(_:)` and `handleMouseDown(_:)` with:

```swift
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if KeyRouter.handle(event, focus: .content, returnKey: settings.returnKey, from: collectionView) {
            typeSelect.reset()
            return true
        }
        guard let folder else { return false }
        let page = max(1, visibleRows().count - layout.columns)
        return ListKeys.handle(event, folder: folder, list: self, pageSize: page,
                               navigate: SelectionController.gridNavigator(layout), typeSelect: typeSelect)
    }

    func handleMouseDown(_ event: NSEvent) {
        guard let folder else { return }
        view.window?.makeFirstResponder(collectionView)
        let point = collectionView.convert(event.locationInWindow, from: nil)
        if let index = layout.itemIndex(at: point) {
            mouse.mouseDown(row: index, event: event, folder: folder, from: collectionView)
            return
        }
        if event.clickCount >= 2 { return }
        trackRubberBand(from: point, event: event)
    }

    func handleMouseUp(_ event: NSEvent) {
        guard let folder else { return }
        mouse.mouseUp(folder: folder)
    }
```

Delete the now-unused `static func direction(_:)`. `IconsViewTests.testArrowKeysMoveSpatially` keeps passing because `ListKeys` reproduces the same behaviour.

- [ ] **Step 9: Show empty states, the banner and scenario hooks in the content host**

In `Sources/UI/Content/ContentViewController.swift`, add properties after `let listContainer = NSView()`:

```swift
    let emptyState = EmptyStateView()
    let banner = BannerView()
    private lazy var externalOpener: any ExternalURLOpening = ExternalOpeners.opener(for: context.options)
```

At the end of `loadView()`, before `view = root`, add:

```swift
        stack.insertArrangedSubview(banner, at: 1)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: listContainer.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
        ])
```

(The list view is added with `positioned: .below`, so the overlay stays on top.) In `viewDidLoad()`, after `super.viewDidLoad()`, add:

```swift
        emptyState.onAction = { [weak self] action in self?.performEmptyStateAction(action) }
```

In `handle(_ event: SessionEvent)`, replace `case .banner: break   // P1-33 shows the banner` with:

```swift
        case .banner(let text): showBanner(text)
```

Replace `bind(_:)` and `handle(_ event: FolderEvent)` with:

```swift
    func bind(_ folder: FolderModel) {
        folderToken = folder.observe { [weak self, weak folder] event in
            guard let self, let folder, folder === self.session.folder else { return }
            self.handle(event)
        }
        activeList.bind(folder)
        refreshFreeSpace(force: false)
        updateStatus()
        updateCommandBar()
        updateEmptyState()
    }

    func handle(_ event: FolderEvent) {
        switch event {
        case .changes(let changes): activeList.apply(changes); updateStatus(); updateEmptyState()
        case .selection: activeList.reloadSelectionDrawing(); updateStatus(); updateCommandBar()
        case .state: updateStatus(); updateEmptyState()
        case .beginRename(let row): activeList.beginInlineRename(row: row)
        case .relocate: break   // BrowserSession navigates (P1-26) and emits .banner
        case .query: updateStatus(); updateEmptyState()
        }
    }
```

Add these methods:

```swift
    // MARK: empty state, banner, scenario hooks (P1-33)

    func updateEmptyState() {
        let folder = session.folder
        emptyState.show(EmptyStateContent.make(state: folder.state, folderName: folder.directory.lastPathComponent,
                                               visibleCount: folder.rowCount, filter: folder.query.filter))
    }

    func showBanner(_ text: String?) {
        if let text { banner.show(text) } else { banner.hide() }
    }

    func performEmptyStateAction(_ action: EmptyStateAction) {
        switch action {
        case .retry: session.folder.retry()
        case .openPrivacySettings: externalOpener.open(SystemSettingsLinks.privacyAllFiles)
        case .properties: handler?.perform(.properties, target: .currentFolder(session.folder), sender: emptyState)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installScenarioHooks()
    }

    func installScenarioHooks() {
        guard let controller = view.window?.windowController as? BrowserWindowController else { return }
        controller.scenarioHooks.emptyStateText = { [weak self] in self?.emptyState.currentText }
        controller.scenarioHooks.bannerText = { [weak self] in self?.banner.currentText }
    }
```

In `Tests/UITests/Support/ContentTestHarness.swift` `tearDown()`, add this line before `sandbox.destroy()`:

```swift
        RecordingURLOpener.shared.reset()
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `swift test --filter 'UITests\.(SelectionControllerTests|TypeSelectTests|EmptyStateTests|IconsViewTests|DetailsViewTests)' 2>&1 | tail -5`
Expected: `Executed 49 tests, with 0 failures` (with no GUI session: `with 24 tests skipped and 0 failures`).

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 11: Verify in the app (sandbox only)**

With the manual run recipe:
1. Click a row, then ⇧-click another to get a range; ⌘-click toggles one row. Click empty space to clear. ⇧↓ extends; ⌘↓ never changes the selection.
2. Select three files and press the mouse on one of them without moving: the selection stays until mouse-up, then only that file is selected.
3. Type `fi` quickly and `file1.txt` is selected. Wait a second and type `s` to jump to `Sub Folder`.
4. Type `zz` in the search field: "No items match 'zz'". Clear it, then `mkdir "$SANDBOX/root/Empty"` and open it: "This folder is empty".
5. `chmod 000 "$SANDBOX/root/Sub Folder/Nested"` and open it: "You don't have permission to view 'Nested'" with a Properties button (enabled from P1-37). Afterwards run `chmod 755 "$SANDBOX/root/Sub Folder/Nested"`.
6. While viewing `Sub Folder/Nested`, run `rm -rf "$SANDBOX/root/Sub Folder/Nested"` in Terminal. The window moves to `Sub Folder` and the banner reads "'Nested' was moved or deleted".
7. The status bar shows `N items`, and `M selected (size)` once something is selected.

- [ ] **Step 12: Commit**

```bash
git add Sources/UI/Content Sources/UI/Support/ExternalURLOpener.swift Sources/UI/Details/DetailsViewController.swift \
  Sources/UI/Icons/IconsViewController.swift Sources/UI/Resources/Localizable.xcstrings Tests/UITests/Support \
  Tests/UITests/SelectionControllerTests.swift Tests/UITests/TypeSelectTests.swift Tests/UITests/EmptyStateTests.swift
git commit -m "feat: model-owned selection, type-select, empty states and banner (P1-33)"
```

---

### Task P1-34: Inline rename

**Spec coverage:** §5.6 F2 rename (inline; base name selected without the extension; Tab commits and moves to the next item; the name is checked against the `EntryStore`: not empty, no `/`, ≤ 255 UTF-8 bytes, no duplicate, NFC-insensitive and, on case-insensitive volumes, case-insensitive; "Are you sure you want to change the extension?"; a leading `.` warns that the item will become hidden; the rename runs as a job through the rename primitive §6.3). §6.3 New Folder / New Text File / New Empty File enter inline rename. §4.3 the app's own renames carry selection and inline-rename state, and an in-progress inline rename survives Watcher updates. §6.6 the field editor gets a per-edit `UndoManager`. §5.6 key routing rule 1 (text fields win). Overview Review Focus 2 and slice Review Focus 2 and 3.

**Files:**
- Create: `Sources/UI/Content/InlineRenameController.swift`
- Create: `Sources/UI/Operations/ErrorText.swift`
- Modify: `Sources/UI/Details/DetailsViewController.swift`, `Sources/UI/Icons/IconsViewController.swift`, `Sources/UI/Content/ContentViewController.swift`, `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/BaseNameRangeTests.swift`, `Tests/UITests/InlineRenameTests.swift`

**Interfaces:**
- Consumes: `FolderModel.validateName(_:renamingRow:) -> NameValidation`, `NameValidation`, `NameProblem`, `NameWarning`, `FolderModel.identity/row(of:)/url(atRow:)/name(atRow:)/entry(atRow:)/select/applyLocalChange`, `LocalChange(directory:added:select:beginRename:)`, `FolderEvent.beginRename(row:)`, `OperationsCenter.perform(_:) async -> JobOutcome`, `JobRequest(_:origin:)`, `JobKind.rename(URL, to:)`, `OriginID(raw:)`, `FileOpUndoStack.undoManager`, S4 `BrowserWindowController.windowWillReturnUndoManager(_:)` (returns the per-edit manager while a field editor is first responder), `ScenarioHooks.renameText`, `AXID.renameField`.
- Produces:
  - Overview §3.14, exact: `@MainActor final class InlineRenameController { init(list: FileListView, folder: FolderModel, environment: CoreEnvironment); func begin(row: Int); func commit(moveToNext: Bool); func cancel(); var isEditing: Bool { get } }`
  - Internal: `enum BaseNameRange { static func range(of:isFolder:) -> Range<String.Index>; static func nsRange(of:isFolder:) -> NSRange }`; `enum RenamePrompt { case extensionChanged(from: String, to: String), becomesHidden }`; `enum RenameAdvance { case none, next, previous }`; `InlineRenameController.commit(advance:fromBlur:)`, `.relayout()`, `.field`, `.currentText`, `.errorText`, `.editingID`, `.origin`, `.onEnd`, `.confirm`; `RenamePrompts.present(_:on:)`; `@MainActor protocol InlineRenameHost: AnyObject { var renameContainer: NSView { get }; var renameFont: NSFont { get }; var renameIsMultiline: Bool { get }; var renameController: InlineRenameController? { get }; func renameFieldFrame(forRow row: Int) -> NSRect? }`; `ErrorText.renameProblem(_:name:)`.

- [ ] **Step 1: Write the failing base-name tests (Review Focus 3)**

```swift
// Tests/UITests/BaseNameRangeTests.swift
import XCTest
@testable import UI

final class BaseNameRangeTests: XCTestCase {
    private func selected(_ name: String, folder: Bool = false) -> String {
        String(name[BaseNameRange.range(of: name, isFolder: folder)])
    }

    func testFileSelectsBaseName() {
        XCTAssertEqual(selected("report.pdf"), "report")
        XCTAssertEqual(selected("Safari.app"), "Safari", "packages rename like files (§5.7)")
    }

    func testMultipleDotsSelectUpToLastDot() {
        XCTAssertEqual(selected("archive.tar.gz"), "archive.tar")
    }

    func testFoldersSelectWholeName() {
        XCTAssertEqual(selected("My.Folder", folder: true), "My.Folder")
    }

    func testDotFilesAndTrailingDotSelectWholeName() {
        XCTAssertEqual(selected(".env"), ".env")
        XCTAssertEqual(selected("name."), "name.")
        XCTAssertEqual(selected("README"), "README")
    }

    func testLeadingDotWithExtension() {
        XCTAssertEqual(selected(".config.json"), ".config")
    }

    func testNSRangeCountsUTF16ForEmojiAndCombiningMarks() {
        let name = "👨‍👩‍👧e\u{301}.txt"
        let range = BaseNameRange.nsRange(of: name, isFolder: false)
        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, "👨‍👩‍👧e\u{301}".utf16.count)
        XCTAssertEqual((name as NSString).substring(with: NSRange(location: range.length, length: 1)), ".")
        let long = String(repeating: "é", count: 120) + ".txt"   // 244 UTF-8 bytes
        XCTAssertEqual(BaseNameRange.nsRange(of: long, isFolder: false).length, 120)
    }
}
```

- [ ] **Step 2: Write the failing inline-rename tests**

```swift
// Tests/UITests/InlineRenameTests.swift
import XCTest
import AppKit
import Darwin
@testable import UI
import Core
import MacxFS

@MainActor
final class InlineRenameTests: XCTestCase {
    // MARK: helpers

    private func controller(_ content: ContentViewController) throws -> InlineRenameController {
        try XCTUnwrap((content.activeList as? InlineRenameHost)?.renameController)
    }

    private func editor(_ controller: InlineRenameController) throws -> NSTextView {
        try XCTUnwrap(controller.field?.currentEditor() as? NSTextView)
    }

    private func type(_ text: String, _ controller: InlineRenameController) throws {
        let editor = try editor(controller)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func send(_ selector: Selector, _ controller: InlineRenameController) throws {
        let field = try XCTUnwrap(controller.field)
        _ = controller.control(field, textView: try editor(controller), doCommandBy: selector)
    }

    private func beginRename(_ content: ContentViewController, _ name: String) throws -> InlineRenameController {
        let row = try XCTUnwrap(content.session.folder.row(named: name))
        content.activeList.beginInlineRename(row: row)
        return try controller(content)
    }

    // MARK: pure

    func testRenameProblemTexts() {
        XCTAssertEqual(ErrorText.renameProblem(.empty, name: ""), "A name can't be empty.")
        XCTAssertEqual(ErrorText.renameProblem(.containsSlash, name: "a/b"), "A name can't contain '/'.")
        XCTAssertEqual(ErrorText.renameProblem(.tooLong, name: "x"), "The name is too long.")
        XCTAssertEqual(ErrorText.renameProblem(.duplicate, name: "b.txt"), "The name 'b.txt' is already taken.")
    }

    // MARK: AppKit

    func testF2SelectsBaseNameAndCommitRenames() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let (content, session, _) = try await h.makeContent()
        let rename = try beginRename(content, "a.txt")
        XCTAssertTrue(rename.isEditing)
        XCTAssertEqual(rename.currentText, "a.txt")
        XCTAssertEqual(try editor(rename).selectedRange(), NSRange(location: 0, length: 1))
        XCTAssertEqual(rename.field?.accessibilityIdentifier(), AXID.renameField)
        try type("c.txt", rename)
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("renamed on disk") { h.exists("c.txt") && !h.exists("a.txt") }
        try await h.waitUntil("selection follows the rename") { session.folder.selectedURLs.map(\.lastPathComponent) == ["c.txt"] }
        XCTAssertFalse(rename.isEditing)
    }

    func testTabCommitsAndMovesToNext() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["a.txt", "b.txt", "c.txt"] { try h.file(name) }
        let (content, _, _) = try await h.makeContent()
        let first = try beginRename(content, "a.txt")
        try type("a1.txt", first)
        try send(#selector(NSResponder.insertTab(_:)), first)
        try await h.waitUntil("a renamed") { h.exists("a1.txt") }
        try await h.waitUntil("editing the next item") { (try? self.controller(content))?.currentText == "b.txt" }
        let second = try controller(content)
        try send(#selector(NSResponder.insertBacktab(_:)), second)
        try await h.waitUntil("back to the previous item") { (try? self.controller(content))?.currentText == "a1.txt" }
    }

    func testEscapeCancels() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, _, _) = try await h.makeContent()
        let rename = try beginRename(content, "a.txt")
        try type("zzz.txt", rename)
        try send(#selector(NSResponder.cancelOperation(_:)), rename)
        XCTAssertFalse(rename.isEditing)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(h.exists("a.txt"))
        XCTAssertFalse(h.exists("zzz.txt"))
    }

    func testInvalidNamesKeepEditing() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, _, _) = try await h.makeContent()
        let rename = try beginRename(content, "a.txt")
        for (text, message) in [("", "A name can't be empty."), ("x/y", "A name can't contain '/'."),
                                (String(repeating: "é", count: 128) + ".txt", "The name is too long.")] {
            try type(text, rename)
            try send(#selector(NSResponder.insertNewline(_:)), rename)
            XCTAssertTrue(rename.isEditing, text)
            XCTAssertEqual(rename.errorText, message)
        }
        XCTAssertTrue(h.exists("a.txt"))
    }

    /// Overview Review Focus 2: the duplicate check sees hidden entries even with Show Hidden off.
    func testInlineRenameRejectsNameOfHiddenItem() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("notes.txt"); try h.file(".env")
        try h.setFlags("notes.txt", UF_HIDDEN)
        h.environment.settings.showHidden = false
        let (content, session, _) = try await h.makeContent()
        XCTAssertNil(session.folder.row(named: "notes.txt"), "the hidden item is not displayed")
        let rename = try beginRename(content, "a.txt")
        for taken in ["notes.txt", ".env"] {
            try type(taken, rename)
            try send(#selector(NSResponder.insertNewline(_:)), rename)
            XCTAssertTrue(rename.isEditing)
            XCTAssertEqual(rename.errorText, "The name '\(taken)' is already taken.")
        }
        if !session.folder.caseSensitive {
            try type("NOTES.TXT", rename)
            try send(#selector(NSResponder.insertNewline(_:)), rename)
            XCTAssertEqual(rename.errorText, "The name 'NOTES.TXT' is already taken.")
        }
        XCTAssertTrue(h.exists("a.txt"))
        XCTAssertTrue(h.environment.operations.jobs.isEmpty, "no rename job was enqueued")
    }

    func testExtensionChangeAsksAndRespectsAnswer() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, _, _) = try await h.makeContent()
        let rename = try beginRename(content, "a.txt")
        var asked: [RenamePrompt] = []
        var answer = false
        rename.confirm = { prompt, _ in asked.append(prompt); return answer }
        try type("a.md", rename)
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("asked") { asked == [.extensionChanged(from: "txt", to: "md")] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(rename.isEditing, "declining keeps editing")
        XCTAssertTrue(h.exists("a.txt"))
        answer = true
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("renamed") { h.exists("a.md") }
    }

    func testLeadingDotWarnsHidden() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("b.txt")
        let (content, _, _) = try await h.makeContent()
        let rename = try beginRename(content, "b.txt")
        var asked: [RenamePrompt] = []
        rename.confirm = { prompt, _ in asked.append(prompt); return true }
        try type(".b.txt", rename)
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("renamed to a dot name") { h.exists(".b.txt") }
        XCTAssertEqual(asked, [.becomesHidden])
    }

    func testNewItemBeginsRenameWithWholeNameSelected() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, session, _) = try await h.makeContent()
        try h.dir("New Folder")
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), added: ["New Folder"], select: ["New Folder"],
                                                    beginRename: "New Folder"))
        try await h.waitUntil("rename began") { (try? self.controller(content))?.currentText == "New Folder" }
        XCTAssertEqual(try editor(try controller(content)).selectedRange(), NSRange(location: 0, length: 10))
    }

    /// Slice Review Focus 2: the field follows its item by identity.
    func testRenameFieldFollowsItemWhenRowsInsertedAbove() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("m.txt"); try h.file("x.txt")
        let (content, session, _) = try await h.makeContent()
        let rename = try beginRename(content, "m.txt")
        try type("mm.txt", rename)
        try h.file("a.txt")
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), added: ["a.txt"]))
        try await h.waitUntil("row inserted above") { session.folder.row(named: "m.txt") == 1 }
        let host = try XCTUnwrap(content.activeList as? InlineRenameHost)
        XCTAssertEqual(rename.field?.frame, host.renameFieldFrame(forRow: 1))
        XCTAssertTrue(rename.isEditing)
        XCTAssertEqual(rename.currentText, "mm.txt")
    }

    func testRenameCancelsWhenItemDeletedExternally() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("m.txt"); try h.file("x.txt")
        let (content, session, _) = try await h.makeContent()
        let rename = try beginRename(content, "m.txt")
        try type("mm.txt", rename)
        try FileManager.default.removeItem(at: h.url("m.txt"))
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), removed: ["m.txt"]))
        try await h.waitUntil("rename closed") { !rename.isEditing }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(h.exists("mm.txt"))
    }

    func testFieldEditorGetsPerEditUndoManager() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let browser = try await h.openBrowserWindow()
        let window = try XCTUnwrap(browser.window)
        let content = try h.content(of: browser)
        XCTAssertTrue(window.undoManager === h.environment.undo.undoManager)
        let rename = try beginRename(content, "a.txt")
        XCTAssertFalse(window.undoManager === h.environment.undo.undoManager,
                       "typing undo never mixes with file-operation undo (§6.6)")
        try send(#selector(NSResponder.cancelOperation(_:)), rename)
        XCTAssertTrue(window.undoManager === h.environment.undo.undoManager)
    }

    func testIconsViewRenamesToo() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, _, _) = try await h.makeContent()
        content.setViewMode(.icons)
        let rename = try beginRename(content, "a.txt")
        XCTAssertTrue(rename.field?.superview === content.icons?.collectionView)
        try type("b.txt", rename)
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("renamed from icons") { h.exists("b.txt") }
    }

    func testScenarioRenameTextHook() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let browser = try await h.openBrowserWindow()
        let rename = try beginRename(try h.content(of: browser), "a.txt")
        XCTAssertEqual(browser.probeRenameText, "a.txt")
        try send(#selector(NSResponder.cancelOperation(_:)), rename)
        XCTAssertNil(browser.probeRenameText)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter 'UITests\.(BaseNameRangeTests|InlineRenameTests)' 2>&1 | tail -20`
Expected: compile errors such as `cannot find 'BaseNameRange' in scope`, `cannot find 'InlineRenameHost' in scope`, `cannot find 'ErrorText' in scope`.

- [ ] **Step 4: Add this task's strings**

Run:
```bash
scripts/l10n-add.sh "A name can't be empty." "A name can't contain '/'." "The name is too long." "The name '%@' is already taken." \
  "Are you sure you want to change the extension?" "The file may open in a different app, or not at all." "Use .%@" "Keep .%@" \
  "Names that begin with a dot are hidden." "The item will be hidden unless hidden items are shown." "Use Name" "Cancel"
```

- [ ] **Step 5: Implement rename text and the controller**

```swift
// Sources/UI/Operations/ErrorText.swift
import Foundation
import Core

/// User-facing text for typed Core problems. Core never produces English (overview Global Constraints).
@MainActor
enum ErrorText {
    static func renameProblem(_ problem: NameProblem, name: String) -> String {
        switch problem {
        case .empty: L10n.string("A name can't be empty.")
        case .containsSlash: L10n.string("A name can't contain '/'.")
        case .tooLong: L10n.string("The name is too long.")
        case .duplicate: String(format: L10n.string("The name '%@' is already taken."), name)
        }
    }
}
```

```swift
// Sources/UI/Content/InlineRenameController.swift
import AppKit
import Core
import MacxFS

/// §5.6: files select the base name up to the last ".", while folders, dot-files and names without an extension
/// (or with a trailing dot) select everything. Character-based, so ranges end on grapheme boundaries.
enum BaseNameRange {
    static func range(of name: String, isFolder: Bool) -> Range<String.Index> {
        let whole = name.startIndex..<name.endIndex
        guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return whole
        }
        return name.startIndex..<dot
    }

    static func nsRange(of name: String, isFolder: Bool) -> NSRange {
        NSRange(range(of: name, isFolder: isFolder), in: name)
    }
}

enum RenamePrompt: Equatable, Sendable {
    case extensionChanged(from: String, to: String)
    case becomesHidden
}

enum RenameAdvance: Sendable { case none, next, previous }

/// The list a rename field lives in (Details: the table, Icons: the collection view).
@MainActor protocol InlineRenameHost: AnyObject {
    var renameContainer: NSView { get }
    var renameFont: NSFont { get }
    var renameIsMultiline: Bool { get }
    var renameController: InlineRenameController? { get }
    /// Frame of the name text area of `row` in `renameContainer` coordinates; nil when the row isn't laid out.
    func renameFieldFrame(forRow row: Int) -> NSRect?
}

final class RenameField: NSTextField {
    init(frame: NSRect, multiline: Bool, font: NSFont) {
        super.init(frame: frame)
        self.font = font
        isBezeled = true
        bezelStyle = .squareBezel
        isEditable = true
        isSelectable = true
        focusRingType = .exterior
        usesSingleLineMode = !multiline
        cell?.wraps = multiline
        cell?.isScrollable = !multiline
        alignment = multiline ? .center : .natural
        setAccessibilityIdentifier(AXID.renameField)
    }
    required init?(coder: NSCoder) { fatalError("RenameField is created in code") }
}

@MainActor
enum RenamePrompts {
    static func present(_ prompt: RenamePrompt, on window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        switch prompt {
        case .extensionChanged(let from, let to):
            alert.messageText = L10n.string("Are you sure you want to change the extension?")
            alert.informativeText = L10n.string("The file may open in a different app, or not at all.")
            alert.addButton(withTitle: String(format: L10n.string("Use .%@"), to))
            alert.addButton(withTitle: from.isEmpty ? L10n.string("Cancel") : String(format: L10n.string("Keep .%@"), from))
        case .becomesHidden:
            alert.messageText = L10n.string("Names that begin with a dot are hidden.")
            alert.informativeText = L10n.string("The item will be hidden unless hidden items are shown.")
            alert.addButton(withTitle: L10n.string("Use Name"))
            alert.addButton(withTitle: L10n.string("Cancel"))
        }
        let response: NSApplication.ModalResponse
        if let window { response = await alert.beginSheetModal(for: window) } else { response = alert.runModal() }
        return response == .alertFirstButtonReturn
    }
}

/// F2 / ⌘⇧R / Return-as-rename / new items (§5.6). The field sits over the name, follows its item by identity
/// across live updates (relayout) and commits through a rename job (§6.3).
@MainActor
final class InlineRenameController: NSObject, NSTextFieldDelegate {
    private weak var list: (any FileListView)?
    private let folder: FolderModel
    private let environment: CoreEnvironment
    private(set) var field: RenameField?
    private var errorLabel: NSTextField?
    private(set) var editingID: RowID?
    private var originalName = ""
    private var isCommitting = false
    private var isEnding = false
    var origin: OriginID?
    var onEnd: (() -> Void)?
    /// Seam for tests; the default shows the §5.6 alerts as sheets.
    var confirm: @MainActor (RenamePrompt, NSWindow?) async -> Bool = RenamePrompts.present

    var isEditing: Bool { field != nil }
    var currentText: String? { field?.stringValue }
    var errorText: String? { errorLabel?.stringValue }

    init(list: FileListView, folder: FolderModel, environment: CoreEnvironment) {
        self.list = list
        self.folder = folder
        self.environment = environment
        super.init()
    }

    func begin(row: Int) {
        guard row >= 0, row < folder.rowCount, let host = list as? InlineRenameHost else { return }
        if isEditing { finish(notify: false) }
        list?.scrollToRow(row)
        host.renameContainer.layoutSubtreeIfNeeded()
        guard let frame = host.renameFieldFrame(forRow: row) else { return }
        let name = folder.name(atRow: row)
        editingID = folder.identity(atRow: row)
        originalName = name
        folder.select(.set(IndexSet(integer: row), cursor: row))
        let field = RenameField(frame: frame, multiline: host.renameIsMultiline, font: host.renameFont)
        field.stringValue = name
        field.delegate = self
        host.renameContainer.addSubview(field)
        self.field = field
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = BaseNameRange.nsRange(of: name, isFolder: folder.entry(atRow: row).kind == .directory)
    }

    func commit(moveToNext: Bool) { commit(advance: moveToNext ? .next : .none) }

    func commit(advance: RenameAdvance, fromBlur: Bool = false) {
        guard let field, let id = editingID, !isCommitting else { return }
        guard let row = folder.row(of: id) else { finish(); return }
        let proposed = field.stringValue
        let neighbor = neighborID(of: row, advance)
        if proposed == originalName {
            finish()
            beginNext(neighbor)
            return
        }
        switch folder.validateName(proposed, renamingRow: row) {
        case .invalid(let problem):
            if fromBlur { finish(); return }   // focus moved away: revert, as Explorer does
            showError(ErrorText.renameProblem(problem, name: proposed))
            NSSound.beep()
        case .ok(let warnings):
            isCommitting = true
            let url = folder.url(atRow: row)
            Task { await self.confirmAndRename(url: url, to: proposed, warnings: warnings, neighbor: neighbor) }
        }
    }

    func cancel() { finish() }

    /// After a ChangeSet: move the field to its item's new row, or close it if the item is gone.
    func relayout() {
        guard isEditing, let id = editingID else { return }
        guard let row = folder.row(of: id), let host = list as? InlineRenameHost, let frame = host.renameFieldFrame(forRow: row) else {
            cancel()
            return
        }
        field?.frame = frame
        errorLabel?.frame.origin = NSPoint(x: frame.minX, y: frame.maxY + 2)
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): commit(advance: .none); return true
        case #selector(NSResponder.insertTab(_:)): commit(advance: .next); return true
        case #selector(NSResponder.insertBacktab(_:)): commit(advance: .previous); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        default: return false
        }
    }

    func controlTextDidChange(_ obj: Notification) { hideError() }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing, !isCommitting, !isEnding else { return }
        commit(advance: .none, fromBlur: true)
    }

    // MARK: private

    private func confirmAndRename(url: URL, to name: String, warnings: [NameWarning], neighbor: RowID?) async {
        for warning in warnings {
            let prompt: RenamePrompt = switch warning {
            case .extensionChanged(let from, let to): .extensionChanged(from: from, to: to)
            case .becomesHidden: .becomesHidden
            }
            guard await confirm(prompt, field?.window) else {
                isCommitting = false
                if let field { field.window?.makeFirstResponder(field) }
                return
            }
        }
        finish()
        _ = await environment.operations.perform(JobRequest(.rename(url, to: name), origin: origin))
        beginNext(neighbor)
    }

    private func neighborID(of row: Int, _ advance: RenameAdvance) -> RowID? {
        switch advance {
        case .none: nil
        case .next: row + 1 < folder.rowCount ? folder.identity(atRow: row + 1) : nil
        case .previous: row > 0 ? folder.identity(atRow: row - 1) : nil
        }
    }

    private func beginNext(_ id: RowID?) {
        guard let id, let row = folder.row(of: id) else { return }
        begin(row: row)
    }

    private func showError(_ text: String) {
        guard let field, let container = field.superview else { return }
        let label = errorLabel ?? NSTextField(labelWithString: "")
        label.stringValue = text
        label.textColor = .systemRed
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.drawsBackground = true
        label.backgroundColor = .controlBackgroundColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: field.frame.minX, y: field.frame.maxY + 2)
        if label.superview == nil { container.addSubview(label) }
        errorLabel = label
        NSAccessibility.post(element: label, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func hideError() {
        errorLabel?.removeFromSuperview()
        errorLabel = nil
    }

    private func finish(notify: Bool = true) {
        isEnding = true
        if let field, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        field?.removeFromSuperview()
        hideError()
        field = nil
        editingID = nil
        isCommitting = false
        isEnding = false
        if notify { onEnd?() }
    }
}
```

- [ ] **Step 6: Host rename in both lists**

In `Sources/UI/Details/DetailsViewController.swift`:

Add a stored property after `let typeSelect = TypeSelect()`:

```swift
    private(set) var renameController: InlineRenameController?
```

Replace `beginInlineRename(row:)` with:

```swift
    func beginInlineRename(row: Int) {
        guard let folder else { return }
        renameController?.cancel()
        let controller = InlineRenameController(list: self, folder: folder, environment: context.environment)
        controller.origin = view.window.map { OriginID(raw: $0.windowNumber) }
        controller.onEnd = { [weak self] in
            guard let self, let window = self.view.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self.tableView)
        }
        renameController = controller
        controller.begin(row: row)
    }
```

In `bind(_:)`, add as the first two lines:

```swift
        renameController?.cancel()
        renameController = nil
```

In `apply(_:)`, after the `ChangeApplier.apply(...)` line, add:

```swift
        renameController?.relayout()
```

Append this conformance at the end of the file:

```swift
extension DetailsViewController: InlineRenameHost {
    var renameContainer: NSView { tableView }
    var renameFont: NSFont { CellStyle.font }
    var renameIsMultiline: Bool { false }

    func renameFieldFrame(forRow row: Int) -> NSRect? {
        let column = tableView.column(withIdentifier: DetailsColumns.identifier(.name))
        guard column >= 0, row >= 0, row < tableView.numberOfRows else { return nil }
        let cell = tableView.frameOfCell(atColumn: column, row: row)
        let inset = CGFloat(iconPoints) + 5
        let height: CGFloat = max(20, min(cell.height, 22))
        return NSRect(x: cell.minX + inset, y: cell.midY - height / 2, width: max(cell.width - inset, 60), height: height)
    }
}
```

In `Sources/UI/Icons/IconsViewController.swift`, add the same stored property, the same `bind`/`apply` lines and this `beginInlineRename(row:)`:

```swift
    func beginInlineRename(row: Int) {
        guard let folder else { return }
        renameController?.cancel()
        let controller = InlineRenameController(list: self, folder: folder, environment: context.environment)
        controller.origin = view.window.map { OriginID(raw: $0.windowNumber) }
        controller.onEnd = { [weak self] in
            guard let self, let window = self.view.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self.collectionView)
        }
        renameController = controller
        controller.begin(row: row)
    }
```

and append:

```swift
extension IconsViewController: InlineRenameHost {
    var renameContainer: NSView { collectionView }
    var renameFont: NSFont { CellStyle.smallFont }
    var renameIsMultiline: Bool { true }

    func renameFieldFrame(forRow row: Int) -> NSRect? {
        guard row >= 0, row < layout.itemCount else { return nil }
        let item = layout.frame(forItem: row)
        let top = item.minY + 6 + CGFloat(layout.iconSize.points) + 2
        return NSRect(x: item.minX + 2, y: top, width: item.width - 4, height: GridMetrics.labelHeight + 4)
    }
}
```

In `Sources/UI/Content/ContentViewController.swift` `installScenarioHooks()`, add:

```swift
        controller.scenarioHooks.renameText = { [weak self] in
            (self?.activeList as? InlineRenameHost)?.renameController?.currentText
        }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter 'UITests\.(BaseNameRangeTests|InlineRenameTests|DetailsViewTests|IconsViewTests)' 2>&1 | tail -5`
Expected: `Executed 43 tests, with 0 failures` (with no GUI session: `with 27 tests skipped and 0 failures`).

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 8: Verify in the app (sandbox only)**

F2 reaches the controller through the File › Rename menu item from P1-35. Until then, check the new-item path by creating a folder in Terminal with `mkdir "$SANDBOX/root/Fresh"`. It appears without rename, which is correct, because only the app's own new items enter rename. After P1-35 lands, repeat:
1. Select `file1.txt`, press fn-F2 (or ⌘⇧R). `file1` is selected and `.txt` is not. Type `renamed` and press Return. The row re-sorts and stays selected.
2. F2, then Tab: commits and opens the next item. ⇧Tab goes to the previous one. Esc cancels.
3. F2, type `file2.txt` (a duplicate): red text "The name 'file2.txt' is already taken." and the field stays open.
4. F2, change `.txt` to `.md`: the extension alert appears as a sheet. "Keep .txt" keeps editing.
5. While editing, press ⌥←, ⌘⌫ and ⌘↑. They edit text (the field editor wins) and never trash or navigate.

- [ ] **Step 9: Commit**

```bash
git add Sources/UI/Content/InlineRenameController.swift Sources/UI/Operations/ErrorText.swift Sources/UI/Details/DetailsViewController.swift \
  Sources/UI/Icons/IconsViewController.swift Sources/UI/Content/ContentViewController.swift Sources/UI/Resources/Localizable.xcstrings \
  Tests/UITests/BaseNameRangeTests.swift Tests/UITests/InlineRenameTests.swift
git commit -m "feat: inline rename with name rules, warnings and live relayout (P1-34)"
```

---

### Task P1-35: File commands, context menus, Open With and clipboard UI

**Spec coverage:** §5.3 command-bar and menu items act on the first responder's target. §5.4 sidebar-focus semantics (Favorites Del removes the favorite and never trashes; Locations ⌘E ejects; Folders behave like content), through `CommandAvailability.effectiveCommand/isEnabled`. §5.6 context menus (item menu in spec order; Paste only when one folder is right-clicked; empty-space menu `Paste · New ▸ · View ▸ · Sort by ▸ · Refresh · Open in Terminal · Properties`). Open With ▸ is filled from the `LaunchServicesCache` (Default ✓, recommended apps, Other…, Choose Default App…), shows "Loading…" on a miss and updates in place, never blocking. §5.6 clipboard: cut dims items, Esc clears and rewrites, ⌘V/⌃V/command-bar/empty-space Paste always paste into the current folder, item-menu Paste goes into the right-clicked folder, Move Item Here (⌥⌘V), cut-paste into the same folder is a no-op, revalidation on app activation and after every command. §5.7 Open (folders navigate, ⌘-double-click opens a new window, `.app` launches, other packages are files, aliases/symlinks resolve, a broken link offers Delete / Fix…, more than 10 folders confirms), Open With with an error alert naming the app, Choose Default App… (list + Browse… + "Always use this app to open .ext files" → both `setDefaultApplication` calls, then open), Open in Terminal (configurable app), Reveal in Finder, Share ▸ (`NSSharingServicePicker`), Services ▸. §6.3 delete permanently always confirms ("Permanently delete N items? This can't be undone."). §5.9 Eject (busy error names the processes). Slice Review Focus 1.

**Files:**
- Create: `Sources/UI/Commands/FileCommandController.swift`
- Create: `Sources/UI/Commands/FileCommandController+Files.swift`
- Create: `Sources/UI/Commands/FileCommandController+View.swift`
- Create: `Sources/UI/Commands/CommandPrompts.swift`
- Create: `Sources/UI/Menus/ContextMenuBuilder.swift`
- Create: `Sources/UI/Menus/OpenWithMenu.swift`
- Create: `Sources/UI/OpenWith/DefaultAppSheet.swift`
- Modify: `Sources/UI/Window/BrowserWindowController.swift` (install the handler), `Sources/UI/Details/DetailsViewController.swift`, `Sources/UI/Icons/IconsViewController.swift`, `Sources/UI/Content/ContentViewController.swift`, `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/ContextMenuTests.swift`, `Tests/UITests/FileCommandTests.swift`

**Interfaces:**
- Consumes: `CommandHandler` (`canPerform(_:target:) -> Bool`, `perform(_:target:sender:)`), `CommandTarget` (all six cases; `.location` is iCloud Drive in LOCATIONS), `CommandAvailability.isEnabled(_:focus:state:)` / `effectiveCommand(_:focus:) -> Command?`, `Command` (every case), `Clipboard.copy/cut/cutNames(in:)/revalidate/clearCut/canPaste/pastePlan(into:moveItemHere:)/didPaste/observe/cutURLs`, `PastePlan`, `OpenPlanner.plan(_:newWindow:lanes:volumes:) async -> OpenPlan`, `OpenItem`, `OpenAction`, `LaunchServicesCache.cachedApplications(for:typeIndex:)/cachedDefault(for:)/prefetch(file:typeIndex:)/invalidate(file:)/observe/provider`, `LaunchServicesProviding` (all requirements), `FakeLaunchServices(apps:defaultApp:)/opened()/defaultsSet()`, `AppInfo(url:name:bundleIdentifier:)`, `EjectCoordinator.eject(_:) async throws(EjectError)`, `FavoritesResolver.makeFavorite/resolve`, `Settings` view/sort/terminal/favorites/confirmBeforeTrash, `OperationsCenter.perform`, `JobKind` (copy, move, trash, delete, duplicate, newItem, rename, alias, symlink), `FileOpUndoStack.undoManager`, S4 `BrowserWindowController.session/origin/navigate(to:selecting:)/focus(_:)`, `WindowManager.openWindow(at:selecting:)`, `BrowserSession.goBack/goForward/goUp/reload/viewMode/navigate`, `SidebarViewController`, `CommandHandlingViewController.handler`.
- Produces:
  - Overview §3.14, exact: `@MainActor final class FileCommandController: CommandHandler { init(context: UIContext, window: BrowserWindowController) }`; `@MainActor final class ContextMenuBuilder { init(context: UIContext); func itemMenu(for rows: IndexSet, in folder: FolderModel, handler: CommandHandler) -> NSMenu; func emptySpaceMenu(for folder: FolderModel, handler: CommandHandler) -> NSMenu }`; `@MainActor final class DefaultAppSheet { static func present(for file: URL, on window: NSWindow, context: UIContext) async }`.
  - Internal: `FileCommandController.prompts: any CommandPrompts`, `.beginSidebarRename: ((URL) -> Void)?`, `.subjectURLs(_:)`, `.destinationFolder(_:)`, `.openWith(_:app:)`, `.openWithOther(_:)`, `.chooseDefaultApp(for:)`, `.showProperties(_:)` (P1-37 fills), `.performWindowCommand(_:target:)` (P1-38 fills `.showOperations`), `static let pendingCommands: Set<Command>`; `CommandPrompt`, `BrokenLinkChoice`, `@MainActor protocol CommandPrompts`, `AppKitCommandPrompts`, `TextPasteboard.write(_:options:)`; `MenuActionBox` (`command`, `target`, `handler`), `ClosureMenuItem(title:handler:)`, `ContextMenuTitles.title(_:)`, `ContextMenuBuilder.contextRows(clickedRow:selectedRows:)`; `OpenWithMenu(files:typeIndex:cache:icons:openWith:other:chooseDefault:)` with `.menu`/`.rebuild()`; `DefaultAppSheet.present(for:on:context:alwaysChecked:)`, `DefaultAppChoice.apply(app:file:always:provider:)`; `ContentViewController.contextMenu(forRow:) -> NSMenu?` (also used by S6's scenario driver for `rightClick` steps), `.refreshCutNames()`; `DetailsViewController.contextMenuProvider`, `IconsViewController.contextMenuProvider`.

- [ ] **Step 1: Write the failing context-menu tests (Review Focus 1)**

```swift
// Tests/UITests/ContextMenuTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class ContextMenuTests: XCTestCase {
    private func ids(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).filter { !$0.isSeparatorItem }.compactMap { $0.identifier?.rawValue }
    }

    private func item(_ menu: NSMenu?, _ command: Command) -> NSMenuItem? {
        menu?.items.first { $0.identifier?.rawValue == "macx.menu.\(command.rawValue)" }
    }

    private func box(_ menu: NSMenu?, _ command: Command) -> MenuActionBox? {
        item(menu, command)?.representedObject as? MenuActionBox
    }

    func testContextRowsRule() {
        let outside = ContextMenuBuilder.contextRows(clickedRow: 4, selectedRows: IndexSet([1, 2]))
        XCTAssertEqual(outside.select, .set(IndexSet(integer: 4), cursor: 4))
        XCTAssertEqual(outside.rows, IndexSet(integer: 4))
        let inside = ContextMenuBuilder.contextRows(clickedRow: 2, selectedRows: IndexSet([1, 2]))
        XCTAssertNil(inside.select)
        XCTAssertEqual(inside.rows, IndexSet([1, 2]))
        let empty = ContextMenuBuilder.contextRows(clickedRow: nil, selectedRows: IndexSet([1]))
        XCTAssertNil(empty.select)
        XCTAssertNil(empty.rows, "empty space → empty-space menu, selection kept")
    }

    func testRightClickOutsideSelectionSelectsOnlyThatRow() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["a.txt", "b.txt", "c.txt"] { try h.file(name) }
        let content = try h.content(of: try await h.openBrowserWindow())
        content.session.folder.select(.set(IndexSet([0, 1]), cursor: 1))
        let menu = content.contextMenu(forRow: 2)
        XCTAssertEqual(content.session.folder.selection.rows, IndexSet(integer: 2))
        guard case .contentSelection? = box(menu, .moveToTrash)?.target else { return XCTFail("acts on the selection") }
    }

    func testRightClickInsideSelectionKeepsSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["a.txt", "b.txt", "c.txt"] { try h.file(name) }
        let content = try h.content(of: try await h.openBrowserWindow())
        content.session.folder.select(.set(IndexSet([0, 2]), cursor: 2))
        _ = content.contextMenu(forRow: 0)
        XCTAssertEqual(content.session.folder.selection.rows, IndexSet([0, 2]))
    }

    func testItemMenuOrderForFile() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let content = try h.content(of: try await h.openBrowserWindow())
        XCTAssertEqual(ids(content.contextMenu(forRow: 0)), [
            "macx.menu.open", "macx.menu.openWith", "macx.menu.cut", "macx.menu.copy", "macx.menu.copyAsPath",
            "macx.menu.duplicate", "macx.menu.makeAlias", "macx.menu.makeSymlink", "macx.menu.rename",
            "macx.menu.moveToTrash", "macx.menu.deletePermanently", "macx.menu.new", "macx.menu.revealInFinder",
            "macx.menu.openInTerminal", "macx.menu.share", "macx.menu.properties",
        ])
    }

    func testItemMenuOffersPasteIntoOnlyForSingleFolder() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("sub"); try h.dir("sub2"); try h.file("a.txt")
        let content = try h.content(of: try await h.openBrowserWindow())
        let folder = content.session.folder
        let single = content.contextMenu(forRow: try XCTUnwrap(folder.row(named: "sub")))
        guard case .folder(let url)? = box(single, .paste)?.target else { return XCTFail("Paste into the right-clicked folder") }
        XCTAssertEqual(url.standardizedFileURL, h.url("sub").standardizedFileURL)
        XCTAssertNotNil(item(single, .openInNewWindow))
        folder.select(.set(IndexSet([0, 1]), cursor: 1))
        XCTAssertNil(item(content.contextMenu(forRow: 0), .paste), "two folders: no Paste")
        XCTAssertNil(item(content.contextMenu(forRow: try XCTUnwrap(folder.row(named: "a.txt"))), .paste), "a file: no Paste")
    }

    func testPackageShowsPackageContents() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("Fake.app/Contents")
        let content = try h.content(of: try await h.openBrowserWindow())
        XCTAssertNotNil(item(content.contextMenu(forRow: 0), .showPackageContents))
    }

    func testEmptySpaceMenuItems() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let content = try h.content(of: try await h.openBrowserWindow())
        let menu = content.contextMenu(forRow: nil)
        XCTAssertEqual(ids(menu), ["macx.menu.paste", "macx.menu.new", "macx.menu.view", "macx.menu.sortBy", "macx.menu.refresh",
                                   "macx.menu.openInTerminal", "macx.menu.properties"])
        guard case .currentFolder? = box(menu, .properties)?.target else { return XCTFail("Properties of the current folder") }
        let sortBy = menu?.items.first { $0.identifier?.rawValue == "macx.menu.sortBy" }?.submenu
        XCTAssertEqual(item(sortBy, .sortByName)?.state, .on)
    }

    func testMenuItemsValidateThroughHandler() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let content = try h.content(of: try await h.openBrowserWindow())
        let menu = content.contextMenu(forRow: nil)
        let paste = try XCTUnwrap(item(menu, .paste))
        let pasteBox = try XCTUnwrap(box(menu, .paste))
        XCTAssertFalse(pasteBox.validateMenuItem(paste), "nothing to paste")
        h.environment.clipboard.copy([h.url("a.txt")])
        XCTAssertTrue(pasteBox.validateMenuItem(paste))
    }

    func testOpenWithShowsLoadingThenApps() async throws {
        let h = try await ContentTestHarness.make(self)
        let file = try h.file("a.txt")
        let textEdit = AppInfo(url: URL(filePath: "/System/Applications/TextEdit.app"), name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
        let other = AppInfo(url: URL(filePath: "/Applications/Other.app"), name: "Other", bundleIdentifier: nil)
        let cache = LaunchServicesCache(provider: FakeLaunchServices(apps: [textEdit, other], defaultApp: textEdit))
        var opened: [URL] = []
        let openWith = OpenWithMenu(files: [file], typeIndex: TypeRegistry.shared.index(forExtension: "txt", isDirectory: false),
                                    cache: cache, icons: nil, openWith: { opened.append($0) }, other: {}, chooseDefault: {})
        XCTAssertEqual(openWith.menu.items.first?.title, "Loading…")
        try await h.waitUntil("apps loaded") { openWith.menu.items.first?.title == "TextEdit (default)" }
        let titles = openWith.menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["TextEdit (default)", "Other", "Other…", "Choose Default App…"])
        XCTAssertEqual(openWith.menu.items.first?.state, .on)
        let otherItem = try XCTUnwrap(openWith.menu.items.first { $0.title == "Other" })
        openWith.menu.performActionForItem(at: openWith.menu.index(of: otherItem))
        XCTAssertEqual(opened, [other.url])
    }

    func testDefaultAppChoiceSetsBothDefaultsThenOpens() async throws {
        let h = try await ContentTestHarness.make(self)
        let file = try h.file("a.custom-ext")
        let app = URL(filePath: "/Applications/Other.app")
        let fake = FakeLaunchServices()
        try await DefaultAppChoice.apply(app: app, file: file, always: true, provider: fake)
        XCTAssertEqual(fake.defaultsSet().map(\.forType), [true, false], "content type first, then the per-file override (§5.7)")
        XCTAssertEqual(fake.defaultsSet().map(\.app), [app, app])
        XCTAssertEqual(fake.opened().map(\.files), [[file]])
        XCTAssertEqual(fake.opened().map(\.app), [app])
        let once = FakeLaunchServices()
        try await DefaultAppChoice.apply(app: app, file: file, always: false, provider: once)
        XCTAssertTrue(once.defaultsSet().isEmpty)
        XCTAssertEqual(once.opened().count, 1)
    }
}
```

- [ ] **Step 2: Write the failing command tests**

```swift
// Tests/UITests/FileCommandTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class ScriptedCommandPrompts: CommandPrompts {
    var confirmAnswers: [Bool] = []
    private(set) var asked: [CommandPrompt] = []
    var chosenFile: URL?
    var brokenLinkChoice: BrokenLinkChoice = .cancel
    var name: String?

    func confirm(_ prompt: CommandPrompt, window: NSWindow?) async -> Bool {
        asked.append(prompt)
        return confirmAnswers.isEmpty ? false : confirmAnswers.removeFirst()
    }
    func inform(_ prompt: CommandPrompt, window: NSWindow?) async { asked.append(prompt) }
    func brokenLink(_ name: String, window: NSWindow?) async -> BrokenLinkChoice {
        asked.append(.brokenLink(name))
        return brokenLinkChoice
    }
    func chooseFile(directory: URL?, applicationsOnly: Bool, window: NSWindow?) async -> URL? { chosenFile }
    func askName(current: String, window: NSWindow?) async -> String? { name }
}

@MainActor
final class FileCommandTests: XCTestCase {
    private struct World {
        let h: ContentTestHarness
        let browser: BrowserWindowController
        let content: ContentViewController
        let commands: FileCommandController
        let prompts: ScriptedCommandPrompts
        var folder: FolderModel { browser.session.folder }
        var selection: CommandTarget { .contentSelection(folder) }
        func select(_ names: [String]) { folder.select(.names(names)) }
    }

    private func world(_ setup: (ContentTestHarness) throws -> Void) async throws -> World {
        let h = try await ContentTestHarness.make(self)
        try setup(h)
        let browser = try await h.openBrowserWindow()
        let content = try h.content(of: browser)
        let commands = try XCTUnwrap(content.handler as? FileCommandController, "P1-35 installs FileCommandController")
        let prompts = ScriptedCommandPrompts()
        commands.prompts = prompts
        return World(h: h, browser: browser, content: content, commands: commands, prompts: prompts)
    }

    func testCopyPasteIntoSameFolderMakesFinderStyleCopy() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.select(["a.txt"])
        w.commands.perform(.copy, target: w.selection, sender: nil)
        w.commands.perform(.paste, target: w.selection, sender: nil)
        try await w.h.waitUntil("copy made") { w.h.exists("a copy.txt") }
        XCTAssertTrue(w.h.exists("a.txt"))
    }

    func testCutPasteIntoFolderMovesAndClearsCut() async throws {
        let w = try await world { try $0.file("a.txt"); try $0.dir("sub") }
        w.select(["a.txt"])
        w.commands.perform(.cut, target: w.selection, sender: nil)
        try await w.h.waitUntil("dimmed") { w.folder.row(named: "a.txt").map(w.folder.isCut(row:)) == true }
        w.commands.perform(.paste, target: .folder(w.h.url("sub")), sender: nil)
        try await w.h.waitUntil("moved") { w.h.exists("sub/a.txt") && !w.h.exists("a.txt") }
        try await w.h.waitUntil("cut cleared") { w.h.environment.clipboard.cutURLs.isEmpty }
    }

    func testPasteIgnoresSelectionAndUsesCurrentFolder() async throws {
        let w = try await world { try $0.file("a.txt"); try $0.dir("sub") }
        w.select(["a.txt"])
        w.commands.perform(.copy, target: w.selection, sender: nil)
        w.select(["sub"])
        w.commands.perform(.paste, target: w.selection, sender: nil)
        try await w.h.waitUntil("pasted into the current folder") { w.h.exists("a copy.txt") }
        XCTAssertFalse(w.h.exists("sub/a.txt"), "⌘V never pastes into the selected folder (§5.6)")
    }

    func testCutDimsRowsAndEscapeClears() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.select(["a.txt"])
        w.commands.perform(.cut, target: w.selection, sender: nil)
        try await w.h.waitUntil("dimmed") { w.folder.cutNames == ["a.txt"] }
        w.commands.perform(.cancelOperation, target: w.selection, sender: nil)
        try await w.h.waitUntil("undimmed") { w.folder.cutNames.isEmpty }
    }

    func testMoveItemHereMovesCopiedItems() async throws {
        let w = try await world { try $0.file("sub/b.txt") }
        w.h.environment.clipboard.copy([w.h.url("sub/b.txt")])
        w.commands.perform(.moveItemHere, target: w.selection, sender: nil)
        try await w.h.waitUntil("moved here") { w.h.exists("b.txt") && !w.h.exists("sub/b.txt") }
    }

    func testTrashGoesToSandboxTrashAndUndoRestores() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.select(["a.txt"])
        w.commands.perform(.moveToTrash, target: w.selection, sender: nil)
        try await w.h.waitUntil("trashed") { !w.h.exists("a.txt") }
        let trash = w.h.sandbox.root.appending(path: ".trash")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        try await w.h.waitUntil("undo registered") { w.h.environment.undo.canUndo }
        w.commands.perform(.undo, target: w.selection, sender: nil)
        try await w.h.waitUntil("restored") { w.h.exists("a.txt") }
    }

    func testDeletePermanentlyAsksFirst() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.select(["a.txt"])
        w.prompts.confirmAnswers = [false]
        w.commands.perform(.deletePermanently, target: w.selection, sender: nil)
        try await w.h.waitUntil("asked") { w.prompts.asked == [.confirmDelete(1)] }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(w.h.exists("a.txt"))
        w.prompts.confirmAnswers = [true]
        w.commands.perform(.deletePermanently, target: w.selection, sender: nil)
        try await w.h.waitUntil("deleted") { !w.h.exists("a.txt") }
    }

    func testNewFolderStartsInlineRename() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.commands.perform(.newFolder, target: w.selection, sender: nil)
        try await w.h.waitUntil("created") { w.h.exists("New Folder") }
        try await w.h.waitUntil("renaming") {
            (w.content.activeList as? InlineRenameHost)?.renameController?.currentText == "New Folder"
        }
    }

    func testCopyAsPathWritesTextOnly() async throws {
        let w = try await world { try $0.file("a.txt"); try $0.file("b.txt") }
        w.select(["a.txt", "b.txt"])
        w.commands.perform(.copyAsPath, target: w.selection, sender: nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(w.h.pasteboardName))
        XCTAssertEqual(pasteboard.string(forType: .string), [w.h.url("a.txt").path, w.h.url("b.txt").path].joined(separator: "\n"))
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) ?? false, "a later ⌘V must not paste files")
    }

    func testOpenFolderNavigatesAndDocumentUsesLaunchServices() async throws {
        let w = try await world { try $0.file("sub/doc.txt") }
        w.select(["sub"])
        w.commands.perform(.open, target: w.selection, sender: nil)
        try await w.h.waitUntil("navigated") { w.folder.directory.standardizedFileURL == w.h.url("sub").standardizedFileURL }
        try await w.h.waitUntil("sub listed") { w.folder.state == .complete }
        w.select(["doc.txt"])
        w.commands.perform(.open, target: w.selection, sender: nil)
        let fake = try XCTUnwrap(w.h.environment.launchServices.provider as? FakeLaunchServices)
        try await w.h.waitUntil("opened with the default app") { fake.opened().last?.files.first?.lastPathComponent == "doc.txt" }
        XCTAssertNil(fake.opened().last?.app)
    }

    func testOpenInTerminalUsesConfiguredApp() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.commands.perform(.openInTerminal, target: .currentFolder(w.folder), sender: nil)
        let fake = try XCTUnwrap(w.h.environment.launchServices.provider as? FakeLaunchServices)
        try await w.h.waitUntil("terminal asked") { !fake.opened().isEmpty }
        XCTAssertEqual(fake.opened().last?.app?.path, "/System/Applications/Utilities/Terminal.app")
        XCTAssertEqual(fake.opened().last?.files.first?.standardizedFileURL, w.h.url("").standardizedFileURL)
    }

    func testFavoritesTrashRemovesFavoriteNotFolder() async throws {
        let w = try await world { try $0.dir("fav") }
        let lanes = w.h.environment.lanes
        let favorite = try await FavoritesResolver.makeFavorite(for: w.h.url("fav"), lanes: lanes)
        w.h.environment.settings.favorites = [favorite]
        let resolved = try XCTUnwrap(await FavoritesResolver.resolve([favorite], lanes: lanes).first)
        w.commands.perform(.moveToTrash, target: .favorite(resolved), sender: nil)
        XCTAssertTrue(w.h.environment.settings.favorites.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(w.h.exists("fav"), "never trashes the target (§5.4)")
    }

    func testLocationsDisableTrashAndCut() async throws {
        let w = try await world { try $0.file("a.txt") }
        let volume = try XCTUnwrap(w.h.environment.volumes.volume(for: w.h.url("")))
        XCTAssertFalse(w.commands.canPerform(.moveToTrash, target: .volume(volume)))
        XCTAssertFalse(w.commands.canPerform(.cut, target: .volume(volume)))
        XCTAssertFalse(w.commands.canPerform(.rename, target: .volume(volume)))
    }

    func testSelectAllNoneInvert() async throws {
        let w = try await world { for n in ["a", "b", "c"] { try $0.file(n) } }
        w.commands.perform(.selectAll, target: w.selection, sender: nil)
        XCTAssertEqual(w.folder.selection.rows, IndexSet(integersIn: 0..<3))
        w.select(["a"])
        w.commands.perform(.invertSelection, target: w.selection, sender: nil)
        XCTAssertEqual(w.folder.selection.rows, IndexSet([1, 2]))
        w.commands.perform(.selectNone, target: w.selection, sender: nil)
        XCTAssertTrue(w.folder.selection.isEmpty)
    }

    func testViewAndSortCommandsUpdateSettingsAndModel() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.commands.perform(.viewAsIcons, target: w.selection, sender: nil)
        XCTAssertTrue(w.content.activeList === w.content.icons)
        XCTAssertEqual(w.h.environment.settings.viewMode, .icons)
        w.commands.perform(.sortBySize, target: w.selection, sender: nil)
        XCTAssertEqual(w.folder.query.sort.field, .size)
        XCTAssertEqual(w.h.environment.settings.sort.field, .size)
        let hidden = w.h.environment.settings.showHidden
        w.commands.perform(.toggleHidden, target: w.selection, sender: nil)
        XCTAssertEqual(w.h.environment.settings.showHidden, !hidden)
        XCTAssertEqual(w.folder.query.showHidden, !hidden)
    }

    func testHandlerInstalledInBrowserWindows() async throws {
        let w = try await world { try $0.file("a.txt") }
        XCTAssertTrue(w.content.handler === w.commands)
        let sidebar = try XCTUnwrap(w.browser.contentViewController?.firstDescendant(of: SidebarViewController.self))
        XCTAssertTrue(sidebar.handler === w.commands)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter 'UITests\.(ContextMenuTests|FileCommandTests)' 2>&1 | tail -20`
Expected: compile errors such as `cannot find type 'CommandPrompts' in scope`, `cannot find 'FileCommandController' in scope`, `value of type 'ContentViewController' has no member 'contextMenu'`.

- [ ] **Step 4: Add this task's strings**

Run:
```bash
scripts/l10n-add.sh "Open" "Open With" "Open in New Window" "Show Package Contents" "Cut" "Copy" "Paste" "Copy as Path" \
  "Duplicate" "Make Alias" "Create Symbolic Link" "Rename" "Move to Trash" "Delete Permanently…" "New" "Folder" "Text File" \
  "Empty File" "Reveal in Finder" "Open in Terminal" "Refresh" "View" "Sort by" "Details" "Icons" "Small Icons" "Medium Icons" \
  "Large Icons" "Compact" "Regular" "Comfortable" "Hidden Items" "Command Bar" "Ascending" "Descending" "Loading…" \
  "%@ (default)" "Other…" "Choose Default App…" "Choose an app to open '%@':" "Browse…" \
  "Always use this app to open .%@ files" "Always use this app to open files of this type" "Open %lld windows?" \
  "Move %lld items to the Trash?" "Permanently delete %lld items?" "This can't be undone." "Delete" "OK" \
  "The original item can't be found" "'%@' points to an item that no longer exists." "Fix…" \
  "'%@' couldn't be opened with %@." "'%@' couldn't be opened." "'%@' can't be ejected because it is in use by %@." \
  "'%@' couldn't be ejected." "New name:"
```

- [ ] **Step 5: Implement prompts and the text pasteboard**

```swift
// Sources/UI/Commands/CommandPrompts.swift
import AppKit
import UniformTypeIdentifiers
import Core

enum CommandPrompt: Equatable, Sendable {
    case openManyWindows(Int)
    case confirmTrash(Int)
    case confirmDelete(Int)
    case brokenLink(String)
    case openFailed(file: String, app: String?, message: String)
    case ejectFailed(volume: String, processes: [String], message: String?)
}

enum BrokenLinkChoice: Sendable { case delete, fix, cancel }

/// Alerts and panels used by FileCommandController. A seam: tests install a scripted implementation.
@MainActor protocol CommandPrompts: AnyObject {
    func confirm(_ prompt: CommandPrompt, window: NSWindow?) async -> Bool
    func inform(_ prompt: CommandPrompt, window: NSWindow?) async
    func brokenLink(_ name: String, window: NSWindow?) async -> BrokenLinkChoice
    func chooseFile(directory: URL?, applicationsOnly: Bool, window: NSWindow?) async -> URL?
    func askName(current: String, window: NSWindow?) async -> String?
}

@MainActor
final class AppKitCommandPrompts: CommandPrompts {
    func confirm(_ prompt: CommandPrompt, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        switch prompt {
        case .openManyWindows(let count):
            alert.messageText = String(format: L10n.string("Open %lld windows?"), count)
            alert.addButton(withTitle: L10n.string("Open"))
        case .confirmTrash(let count):
            alert.messageText = String(format: L10n.string("Move %lld items to the Trash?"), count)
            alert.addButton(withTitle: L10n.string("Move to Trash"))
        case .confirmDelete(let count):
            alert.alertStyle = .critical
            alert.messageText = String(format: L10n.string("Permanently delete %lld items?"), count)
            alert.informativeText = L10n.string("This can't be undone.")
            alert.addButton(withTitle: L10n.string("Delete"))
        default:
            alert.messageText = message(for: prompt)
            alert.addButton(withTitle: L10n.string("OK"))
        }
        alert.addButton(withTitle: L10n.string("Cancel"))
        return await run(alert, window) == .alertFirstButtonReturn
    }

    func inform(_ prompt: CommandPrompt, window: NSWindow?) async {
        let alert = NSAlert()
        alert.messageText = message(for: prompt)
        if case .openFailed(_, _, let detail) = prompt { alert.informativeText = detail }
        if case .ejectFailed(_, _, let detail?) = prompt { alert.informativeText = detail }
        alert.addButton(withTitle: L10n.string("OK"))
        _ = await run(alert, window)
    }

    func brokenLink(_ name: String, window: NSWindow?) async -> BrokenLinkChoice {
        let alert = NSAlert()
        alert.messageText = L10n.string("The original item can't be found")
        alert.informativeText = String(format: L10n.string("'%@' points to an item that no longer exists."), name)
        alert.addButton(withTitle: L10n.string("Fix…"))
        alert.addButton(withTitle: L10n.string("Delete"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        switch await run(alert, window) {
        case .alertFirstButtonReturn: return .fix
        case .alertSecondButtonReturn: return .delete
        default: return .cancel
        }
    }

    func chooseFile(directory: URL?, applicationsOnly: Bool, window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.canChooseFiles = true
        panel.canChooseDirectories = !applicationsOnly
        panel.allowsMultipleSelection = false
        if applicationsOnly { panel.allowedContentTypes = [.application] }
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) } else { response = panel.runModal() }
        return response == .OK ? panel.url : nil
    }

    func askName(current: String, window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.string("New name:")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.string("Rename"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.window.initialFirstResponder = field
        return await run(alert, window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func message(for prompt: CommandPrompt) -> String {
        switch prompt {
        case .openFailed(let file, let app?, _): String(format: L10n.string("'%@' couldn't be opened with %@."), file, app)
        case .openFailed(let file, nil, _): String(format: L10n.string("'%@' couldn't be opened."), file)
        case .ejectFailed(let volume, let processes, _) where !processes.isEmpty:
            String(format: L10n.string("'%@' can't be ejected because it is in use by %@."), volume,
                   ListFormatter.localizedString(byJoining: processes))
        case .ejectFailed(let volume, _, _): String(format: L10n.string("'%@' couldn't be ejected."), volume)
        case .brokenLink(let name): String(format: L10n.string("'%@' points to an item that no longer exists."), name)
        case .openManyWindows(let count): String(format: L10n.string("Open %lld windows?"), count)
        case .confirmTrash(let count): String(format: L10n.string("Move %lld items to the Trash?"), count)
        case .confirmDelete(let count): String(format: L10n.string("Permanently delete %lld items?"), count)
        }
    }

    private func run(_ alert: NSAlert, _ window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }
}

/// "Copy as Path" writes plain text only, with no file URLs, so a later ⌘V doesn't paste files (§5.3 ⋯ menu). It
/// uses the private pasteboard named by --pasteboard. A sandboxed run without one keeps the text in memory and never
/// touches NSPasteboard.general (S5-C2).
@MainActor
enum TextPasteboard {
    private(set) static var lastSandboxedText: String?

    static func write(_ text: String, options: LaunchOptions) {
        let pasteboard: NSPasteboard
        if let name = options.pasteboardName {
            pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        } else if options.isSandboxed {
            lastSandboxedText = text
            return
        } else {
            pasteboard = .general
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
```

- [ ] **Step 6: Implement the command controller**

```swift
// Sources/UI/Commands/FileCommandController.swift
import AppKit
import Core
import MacxFS

/// Runs every Command for every CommandTarget (§5.3, §5.4, §5.6, §5.7). The responder-chain @objc actions in
/// CommandHandlingViewController, the command bar, context menus and KeyRouter alternates all end here.
@MainActor
final class FileCommandController: CommandHandler {
    let context: UIContext
    private(set) weak var window: BrowserWindowController?
    var prompts: any CommandPrompts = AppKitCommandPrompts()
    /// Set by SidebarViewController so F2 on a Folders-tree node renames inline there; nil → a name prompt.
    var beginSidebarRename: ((URL) -> Void)?
    /// Commands whose UI arrives in a later task (P1-37 removes .properties, P1-38 removes .showOperations).
    static let pendingCommands: Set<Command> = [.properties, .showOperations]

    var environment: CoreEnvironment { context.environment }
    var session: BrowserSession? { window?.session }

    init(context: UIContext, window: BrowserWindowController) {
        self.context = context
        self.window = window
    }

    static func focus(for target: CommandTarget) -> FocusContext {
        switch target {
        case .contentSelection, .currentFolder: .content
        case .folder: .sidebarFolders
        case .favorite: .sidebarFavorites
        case .volume, .location: .sidebarLocations
        }
    }

    func canPerform(_ command: Command, target: CommandTarget) -> Bool {
        let focus = Self.focus(for: target)
        guard let effective = CommandAvailability.effectiveCommand(command, focus: focus),
              !Self.pendingCommands.contains(effective), let session else { return false }
        let state = CommandStateBuilder.state(for: target, session: session, environment: environment)
        return CommandAvailability.isEnabled(effective, focus: focus, state: state)
    }

    func perform(_ command: Command, target: CommandTarget, sender: Any?) {
        guard let effective = CommandAvailability.effectiveCommand(command, focus: Self.focus(for: target)),
              canPerform(command, target: target) else {
            NSSound.beep()
            return
        }
        defer { environment.clipboard.revalidate() }   // §5.6: after every command
        switch effective {
        case .open: open(target, newWindow: false)
        case .openInNewWindow: open(target, newWindow: true)
        case .showPackageContents: showPackageContents(target)
        case .openInTerminal: openInTerminal(target)
        case .revealInFinder: reveal(target)
        case .cut: environment.clipboard.cut(subjectURLs(target))
        case .copy: environment.clipboard.copy(subjectURLs(target))
        case .paste: paste(target, moveItemHere: false)
        case .moveItemHere: paste(target, moveItemHere: true)
        case .selectAll: select(.all, target)
        case .selectNone: select(.none, target)
        case .invertSelection: select(.invert, target)
        case .undo: environment.undo.undoManager.undo()
        case .redo: environment.undo.undoManager.redo()
        case .rename: rename(target)
        case .moveToTrash: trash(target)
        case .deletePermanently: deletePermanently(target)
        case .duplicate: enqueue(.duplicate(subjectURLs(target)))
        case .makeAlias: enqueue(.alias(sources: subjectURLs(target), destination: containingFolder(target)))
        case .makeSymlink: enqueue(.symlink(sources: subjectURLs(target), destination: containingFolder(target)))
        case .newFolder: enqueue(.newItem(.folder, in: destinationFolder(target)))
        case .newTextFile: enqueue(.newItem(.textFile, in: destinationFolder(target)))
        case .newEmptyFile: enqueue(.newItem(.emptyFile, in: destinationFolder(target)))
        case .copyAsPath: TextPasteboard.write(subjectURLs(target).map(\.path).joined(separator: "\n"), options: context.options)
        case .properties: showProperties(target)
        case .share: share(target, sender: sender)
        case .back, .forward, .up, .refresh, .focusAddressBar, .focusSearch, .cycleFocusForward, .cycleFocusBackward,
             .newWindow, .closeWindow, .showOperations:
            performWindowCommand(effective, target: target)
        case .viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge, .densityCompact, .densityRegular,
             .densityComfortable, .toggleHidden, .toggleCommandBar, .sortByName, .sortByDateModified, .sortBySize, .sortByKind,
             .sortByDateCreated, .sortAscending, .sortDescending:
            performViewCommand(effective)
        case .eject: eject(target)
        case .removeFromFavorites: removeFavorite(target)
        case .cancelOperation: environment.clipboard.clearCut()
        }
    }

    // MARK: subjects and destinations

    /// The items a command acts on: the selection, the current folder, or the sidebar row's target.
    func subjectURLs(_ target: CommandTarget) -> [URL] {
        switch target {
        case .contentSelection(let folder): folder.selectedURLs
        case .currentFolder(let folder): [folder.directory]
        case .folder(let url), .location(let url): [url]
        case .favorite(let favorite): favorite.url.map { [$0] } ?? []
        case .volume(let volume): [volume.mountPoint]
        }
    }

    /// Where Paste and New go (§5.6): the current folder for content targets, whatever is selected.
    func destinationFolder(_ target: CommandTarget) -> URL {
        switch target {
        case .contentSelection(let folder), .currentFolder(let folder): folder.directory
        case .folder(let url), .location(let url): url
        case .favorite(let favorite): favorite.url ?? environment.settings.home
        case .volume(let volume): volume.mountPoint
        }
    }

    /// Where Make Alias / Create Symbolic Link put the new item: next to the subjects.
    func containingFolder(_ target: CommandTarget) -> URL {
        switch target {
        case .contentSelection(let folder), .currentFolder(let folder): folder.directory
        case .folder(let url): url.deletingLastPathComponent()
        case .favorite, .volume, .location: environment.settings.home
        }
    }

    func contentController() -> ContentViewController? {
        window?.contentViewController?.firstDescendant(of: ContentViewController.self)
    }

    @discardableResult
    func enqueue(_ kind: JobKind) -> Task<JobOutcome, Never> {
        let request = JobRequest(kind, origin: window?.origin)
        let operations = environment.operations
        return Task { await operations.perform(request) }
    }

    func run(_ kind: JobKind) async -> JobOutcome {
        await environment.operations.perform(JobRequest(kind, origin: window?.origin))
    }

    private func select(_ command: SelectionCommand, _ target: CommandTarget) {
        if case .contentSelection(let folder) = target { folder.select(command) }
    }

    /// Filled in by P1-37 (Properties window).
    func showProperties(_ target: CommandTarget) {
        NSSound.beep()
    }
}
```

```swift
// Sources/UI/Commands/FileCommandController+Files.swift
import AppKit
import Core
import MacxFS

extension FileCommandController {
    // MARK: open (§5.7)

    func open(_ target: CommandTarget, newWindow: Bool) {
        switch target {
        case .contentSelection(let folder):
            let items = folder.selection.rows.filter { $0 < folder.rowCount }.map { row in
                let entry = folder.entry(atRow: row)
                return OpenItem(url: folder.url(atRow: row), kind: entry.kind, isApplication: environment.types.isApplication(entry.typeIndex))
            }
            guard !items.isEmpty else { return }
            let lanes = environment.lanes
            let volumes = environment.volumes
            Task { await self.execute(await OpenPlanner.plan(items, newWindow: newWindow, lanes: lanes, volumes: volumes)) }
        case .folder, .favorite, .volume, .location:
            guard let url = subjectURLs(target).first else { return }
            if newWindow { context.windows.openWindow(at: url) } else { window?.navigate(to: url) }
        case .currentFolder(let folder):
            if newWindow { context.windows.openWindow(at: folder.directory) }
        }
    }

    func execute(_ plan: OpenPlan) async {
        if plan.needsConfirmation {
            let windows = plan.actions.filter { if case .openInNewWindow = $0 { true } else { false } }.count
            guard await prompts.confirm(.openManyWindows(windows), window: window?.window) else { return }
        }
        for action in plan.actions {
            switch action {
            case .navigate(let url): window?.navigate(to: url)
            case .openInNewWindow(let url): context.windows.openWindow(at: url)
            case .launchApplication(let url): await openWithErrors([url], app: nil)
            case .openDocuments(let urls): await openWithErrors(urls, app: nil)
            case .brokenLink(let url): await handleBrokenLink(url)
            }
        }
    }

    func openWith(_ files: [URL], app: URL) {
        Task { await self.openWithErrors(files, app: app) }
    }

    func openWithOther(_ files: [URL]) {
        Task {
            guard let app = await self.prompts.chooseFile(directory: URL(filePath: "/Applications", directoryHint: .isDirectory),
                                                         applicationsOnly: true, window: self.window?.window) else { return }
            await self.openWithErrors(files, app: app)
        }
    }

    func chooseDefaultApp(for file: URL) {
        guard let hostWindow = window?.window else { return }
        let context = self.context
        Task { await DefaultAppSheet.present(for: file, on: hostWindow, context: context) }
    }

    /// Open With errors are an alert naming the app (§5.7).
    func openWithErrors(_ files: [URL], app: URL?) async {
        let provider = environment.launchServices.provider
        do {
            if let app { try await provider.open(files, withApplicationAt: app) } else { try await provider.open(files) }
        } catch {
            let appName = app.map { $0.deletingPathExtension().lastPathComponent }
            await prompts.inform(.openFailed(file: files.first?.lastPathComponent ?? "", app: appName,
                                             message: error.localizedDescription), window: window?.window)
        }
    }

    func handleBrokenLink(_ url: URL) async {
        switch await prompts.brokenLink(url.lastPathComponent, window: window?.window) {
        case .cancel:
            return
        case .delete:
            _ = await run(.trash([url]))
        case .fix:
            guard let newTarget = await prompts.chooseFile(directory: nil, applicationsOnly: false, window: window?.window) else { return }
            let parent = url.deletingLastPathComponent()
            let folder = session?.folder
            let isSymlink = folder?.row(named: url.lastPathComponent).map { folder?.entry(atRow: $0).kind == .symlink } ?? true
            guard await run(.trash([url])).skipped.isEmpty else { return }
            let made = await run(isSymlink ? .symlink(sources: [newTarget], destination: parent) : .alias(sources: [newTarget], destination: parent))
            if let created = made.created.first, created.lastPathComponent != url.lastPathComponent {
                _ = await run(.rename(created, to: url.lastPathComponent))
            }
        }
    }

    func showPackageContents(_ target: CommandTarget) {
        guard case .contentSelection(let folder) = target, let row = folder.selection.rows.first,
              folder.entry(atRow: row).kind == .package else { return }
        window?.navigate(to: folder.url(atRow: row))
    }

    func openInTerminal(_ target: CommandTarget) {
        let folderURL: URL
        if case .contentSelection(let folder) = target, folder.selection.rows.count == 1, let row = folder.selection.rows.first,
           folder.entry(atRow: row).kind == .directory {
            folderURL = folder.url(atRow: row)
        } else {
            folderURL = destinationFolder(target)
        }
        let terminal = environment.settings.terminalApp
            ?? URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
        openWith([folderURL], app: terminal)
    }

    func reveal(_ target: CommandTarget) {
        var urls = subjectURLs(target)
        if urls.isEmpty, case .contentSelection(let folder) = target { urls = [folder.directory] }
        let provider = environment.launchServices.provider
        Task { await provider.revealInFinder(urls) }
    }

    // MARK: clipboard (§5.6)

    func paste(_ target: CommandTarget, moveItemHere: Bool) {
        let clipboard = environment.clipboard
        guard let plan = clipboard.pastePlan(into: destinationFolder(target), moveItemHere: moveItemHere) else {
            NSSound.beep()
            return
        }
        if plan.isNoOp {
            clipboard.didPaste(plan)   // cut-paste into the items' own folder: nothing moves, the cut state clears
            return
        }
        let kind: JobKind = plan.operation == .move
            ? .move(sources: plan.sources, destination: plan.destination)
            : .copy(sources: plan.sources, destination: plan.destination)
        let job = enqueue(kind)
        Task {
            _ = await job.value
            clipboard.didPaste(plan)
        }
    }

    // MARK: rename, trash, delete

    func rename(_ target: CommandTarget) {
        switch target {
        case .contentSelection(let folder):
            guard let row = folder.selection.cursor.flatMap({ folder.row(of: $0) }) ?? folder.selection.rows.first,
                  let content = contentController() else { return }
            content.activeList.beginInlineRename(row: row)
        case .folder(let url):
            if let beginSidebarRename { beginSidebarRename(url); return }
            Task { await self.renameWithPrompt(url) }
        default:
            break
        }
    }

    private func renameWithPrompt(_ url: URL) async {
        let current = url.lastPathComponent
        guard let proposed = await prompts.askName(current: current, window: window?.window), proposed != current else { return }
        let caseSensitive = environment.volumes.volume(for: url)?.capabilities.caseSensitive ?? false
        // Duplicates are caught by the rename primitive's RENAME_EXCL (conflict dialog); the tree has no EntryStore here.
        guard case .ok = NameRules.validate(proposed, original: current, caseSensitive: caseSensitive, exists: { _ in false }) else {
            NSSound.beep()
            return
        }
        _ = await run(.rename(url, to: proposed))
    }

    func trash(_ target: CommandTarget) {
        let urls = subjectURLs(target)
        guard !urls.isEmpty else { return }
        Task {
            if self.environment.settings.confirmBeforeTrash {
                guard await self.prompts.confirm(.confirmTrash(urls.count), window: self.window?.window) else { return }
            }
            _ = await self.run(.trash(urls))
        }
    }

    func deletePermanently(_ target: CommandTarget) {
        let urls = subjectURLs(target)
        guard !urls.isEmpty else { return }
        Task {
            // Always confirms (§6.3); Settings.confirmBeforeDelete is locked on.
            guard await self.prompts.confirm(.confirmDelete(urls.count), window: self.window?.window) else { return }
            _ = await self.run(.delete(urls))
        }
    }

    // MARK: share, eject, favorites

    func share(_ target: CommandTarget, sender: Any?) {
        let urls = subjectURLs(target)
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let view = sender as? NSView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let content = contentController() {
            picker.show(relativeTo: content.listContainer.bounds, of: content.listContainer, preferredEdge: .minY)
        }
    }

    func eject(_ target: CommandTarget) {
        guard case .volume(let volume) = target else { return }
        let coordinator = environment.ejectCoordinator
        Task {
            do {
                try await coordinator.eject(volume)
            } catch {
                switch error {
                case .busy(let processes):
                    await self.prompts.inform(.ejectFailed(volume: volume.name, processes: processes, message: nil), window: self.window?.window)
                case .failed(_, let message):
                    await self.prompts.inform(.ejectFailed(volume: volume.name, processes: [], message: message), window: self.window?.window)
                }
            }
        }
    }

    func removeFavorite(_ target: CommandTarget) {
        guard case .favorite(let resolved) = target else { return }
        environment.settings.favorites.removeAll { $0.id == resolved.favorite.id }
    }
}
```

```swift
// Sources/UI/Commands/FileCommandController+View.swift
import AppKit
import Core
import MacxFS

extension FileCommandController {
    func performWindowCommand(_ command: Command, target: CommandTarget) {
        guard let window else { return }
        switch command {
        case .back: window.session.goBack()
        case .forward: window.session.goForward()
        case .up: window.session.goUp()
        case .refresh: window.session.reload()
        case .focusAddressBar: window.focus(.addressBar)
        case .focusSearch: focusSearchField()
        case .cycleFocusForward: cycleFocus(from: target, forward: true)
        case .cycleFocusBackward: cycleFocus(from: target, forward: false)
        case .newWindow: context.windows.openWindow(at: window.session.folder.directory)
        case .closeWindow: window.window?.performClose(nil)
        case .showOperations: NSSound.beep()   // P1-38 shows the Operations panel
        default: break
        }
    }

    func performViewCommand(_ command: Command) {
        guard let session else { return }
        let settings = environment.settings
        switch command {
        case .viewAsDetails: setViewMode(.details)
        case .viewAsIcons: setViewMode(.icons)
        case .iconSizeSmall: settings.iconSize = .small; setViewMode(.icons)
        case .iconSizeMedium: settings.iconSize = .medium; setViewMode(.icons)
        case .iconSizeLarge: settings.iconSize = .large; setViewMode(.icons)
        case .densityCompact: settings.density = .compact
        case .densityRegular: settings.density = .regular
        case .densityComfortable: settings.density = .comfortable
        case .toggleHidden:
            settings.showHidden.toggle()
            var query = session.folder.query
            query.showHidden = settings.showHidden
            session.folder.setQuery(query)
        case .toggleCommandBar: settings.commandBarVisible.toggle()
        case .sortByName: setSort(field: .name)
        case .sortByDateModified: setSort(field: .dateModified)
        case .sortBySize: setSort(field: .size)
        case .sortByKind: setSort(field: .kind)
        case .sortByDateCreated: setSort(field: .dateCreated)
        case .sortAscending: setSort(ascending: true)
        case .sortDescending: setSort(ascending: false)
        default: break
        }
    }

    private func setViewMode(_ mode: ViewMode) {
        session?.viewMode = mode
        environment.settings.viewMode = mode
        contentController()?.setViewMode(mode)
    }

    private func setSort(field: SortField? = nil, ascending: Bool? = nil) {
        guard let folder = session?.folder else { return }
        var query = folder.query
        let newField = field ?? query.sort.field
        let keepDirection = newField == query.sort.field
        query.sort = SortDescriptor(field: newField, ascending: ascending ?? (keepDirection ? query.sort.ascending : true))
        folder.setQuery(query)
        environment.settings.sort = query.sort
    }

    /// FocusContext has no search case: find the toolbar search field by its accessibility identifier.
    private func focusSearchField() {
        guard let hostWindow = window?.window else { return }
        for item in hostWindow.toolbar?.items ?? [] {
            if let search = item as? NSSearchToolbarItem { search.beginSearchInteraction(); return }
            if let view = item.view, view.accessibilityIdentifier() == AXID.search { hostWindow.makeFirstResponder(view); return }
        }
    }

    /// Tab order (§5.6): sidebar → address bar → content → sidebar.
    private func cycleFocus(from target: CommandTarget, forward: Bool) {
        let order: [FocusContext] = [.sidebarFavorites, .addressBar, .content]
        let current = switch Self.focus(for: target) {
        case .content: 2
        case .addressBar: 1
        default: 0
        }
        window?.focus(order[(current + (forward ? 1 : order.count - 1)) % order.count])
    }
}
```

- [ ] **Step 7: Implement menus, Open With and the default-app sheet**

```swift
// Sources/UI/Menus/ContextMenuBuilder.swift
import AppKit
import Core
import MacxFS

/// Retains the (command, target) of a context-menu item and validates it through the handler. NSMenuItem.target is
/// weak, so the item's representedObject holds the box.
@MainActor
final class MenuActionBox: NSObject, NSMenuItemValidation {
    let command: Command
    let target: CommandTarget
    weak var handler: (any CommandHandler)?

    init(command: Command, target: CommandTarget, handler: any CommandHandler) {
        self.command = command
        self.target = target
        self.handler = handler
    }

    @objc func run(_ sender: Any?) { handler?.perform(command, target: target, sender: sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { handler?.canPerform(command, target: target) ?? false }
}

final class ClosureMenuItem: NSMenuItem {
    private var handler: (@MainActor () -> Void)?

    convenience init(title: String, handler: @escaping @MainActor () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    @objc private func fire() { handler?() }
}

@MainActor
enum ContextMenuTitles {
    static func title(_ command: Command) -> String {
        switch command {
        case .open: L10n.string("Open")
        case .openInNewWindow: L10n.string("Open in New Window")
        case .showPackageContents: L10n.string("Show Package Contents")
        case .cut: L10n.string("Cut")
        case .copy: L10n.string("Copy")
        case .paste: L10n.string("Paste")
        case .copyAsPath: L10n.string("Copy as Path")
        case .duplicate: L10n.string("Duplicate")
        case .makeAlias: L10n.string("Make Alias")
        case .makeSymlink: L10n.string("Create Symbolic Link")
        case .rename: L10n.string("Rename")
        case .moveToTrash: L10n.string("Move to Trash")
        case .deletePermanently: L10n.string("Delete Permanently…")
        case .revealInFinder: L10n.string("Reveal in Finder")
        case .openInTerminal: L10n.string("Open in Terminal")
        case .properties: L10n.string("Properties")
        case .refresh: L10n.string("Refresh")
        case .newFolder: L10n.string("Folder")
        case .newTextFile: L10n.string("Text File")
        case .newEmptyFile: L10n.string("Empty File")
        case .viewAsDetails: L10n.string("Details")
        case .viewAsIcons: L10n.string("Icons")
        case .iconSizeSmall: L10n.string("Small Icons")
        case .iconSizeMedium: L10n.string("Medium Icons")
        case .iconSizeLarge: L10n.string("Large Icons")
        case .densityCompact: L10n.string("Compact")
        case .densityRegular: L10n.string("Regular")
        case .densityComfortable: L10n.string("Comfortable")
        case .toggleHidden: L10n.string("Hidden Items")
        case .toggleCommandBar: L10n.string("Command Bar")
        case .sortByName: L10n.string("Name")
        case .sortByDateModified: L10n.string("Date Modified")
        case .sortBySize: L10n.string("Size")
        case .sortByKind: L10n.string("Kind")
        case .sortByDateCreated: L10n.string("Date Created")
        case .sortAscending: L10n.string("Ascending")
        case .sortDescending: L10n.string("Descending")
        default: command.rawValue
        }
    }
}

/// Item and empty-space context menus (§5.6). Built from in-memory state only, so building never blocks.
@MainActor
final class ContextMenuBuilder {
    private let context: UIContext

    init(context: UIContext) { self.context = context }

    /// Right-click on an unselected row selects just it; inside the selection keeps it; nil = empty space.
    static func contextRows(clickedRow: Int?, selectedRows: IndexSet) -> (select: SelectionCommand?, rows: IndexSet?) {
        guard let row = clickedRow else { return (nil, nil) }
        if selectedRows.contains(row) { return (nil, selectedRows) }
        return (.set(IndexSet(integer: row), cursor: row), IndexSet(integer: row))
    }

    func itemMenu(for rows: IndexSet, in folder: FolderModel, handler: CommandHandler) -> NSMenu {
        let menu = NSMenu()
        let target = CommandTarget.contentSelection(folder)
        let valid = rows.filteredIndexSet { $0 < folder.rowCount }
        let kinds = valid.map { folder.entry(atRow: $0).kind }
        add(.open, target, handler, to: menu)
        if let openWith = openWithItem(rows: valid, folder: folder, handler: handler) { menu.addItem(openWith) }
        if kinds.contains(.directory) { add(.openInNewWindow, target, handler, to: menu) }
        if kinds.contains(.package) { add(.showPackageContents, target, handler, to: menu) }
        menu.addItem(.separator())
        add(.cut, target, handler, to: menu)
        add(.copy, target, handler, to: menu)
        if valid.count == 1, let row = valid.first, folder.entry(atRow: row).kind == .directory {
            add(.paste, .folder(folder.url(atRow: row)), handler, to: menu)   // only for one right-clicked folder (§5.6)
        }
        add(.copyAsPath, target, handler, to: menu)
        menu.addItem(.separator())
        for command in [Command.duplicate, .makeAlias, .makeSymlink] { add(command, target, handler, to: menu) }
        menu.addItem(.separator())
        for command in [Command.rename, .moveToTrash, .deletePermanently] { add(command, target, handler, to: menu) }
        menu.addItem(.separator())
        menu.addItem(newSubmenu(folder: folder, handler: handler))
        add(.revealInFinder, target, handler, to: menu)
        add(.openInTerminal, target, handler, to: menu)
        menu.addItem(.separator())
        let share = NSSharingServicePicker(items: valid.map { folder.url(atRow: $0) }).standardShareMenuItem
        share.identifier = NSUserInterfaceItemIdentifier("macx.menu.share")
        menu.addItem(share)
        menu.addItem(.separator())
        add(.properties, target, handler, to: menu)
        return menu   // AppKit appends Services ▸ for the list views' NSServicesMenuRequestor when it pops the menu
    }

    func emptySpaceMenu(for folder: FolderModel, handler: CommandHandler) -> NSMenu {
        let menu = NSMenu()
        let target = CommandTarget.currentFolder(folder)
        add(.paste, target, handler, to: menu)
        menu.addItem(newSubmenu(folder: folder, handler: handler))
        menu.addItem(submenu(L10n.string("View"), id: "view", [.viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium,
                                                              .iconSizeLarge, .densityCompact, .densityRegular, .densityComfortable,
                                                              .toggleHidden, .toggleCommandBar], target, handler, folder))
        menu.addItem(submenu(L10n.string("Sort by"), id: "sortBy", [.sortByName, .sortByDateModified, .sortBySize, .sortByKind,
                                                                   .sortByDateCreated, .sortAscending, .sortDescending], target, handler, folder))
        add(.refresh, target, handler, to: menu)
        menu.addItem(.separator())
        add(.openInTerminal, target, handler, to: menu)
        menu.addItem(.separator())
        add(.properties, target, handler, to: menu)
        return menu
    }

    // MARK: private

    @discardableResult
    private func add(_ command: Command, _ target: CommandTarget, _ handler: CommandHandler, to menu: NSMenu) -> NSMenuItem {
        let box = MenuActionBox(command: command, target: target, handler: handler)
        let item = NSMenuItem(title: ContextMenuTitles.title(command), action: #selector(MenuActionBox.run(_:)), keyEquivalent: "")
        item.target = box
        item.representedObject = box
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.\(command.rawValue)")
        menu.addItem(item)
        return item
    }

    private func newSubmenu(folder: FolderModel, handler: CommandHandler) -> NSMenuItem {
        submenu(L10n.string("New"), id: "new", [.newFolder, .newTextFile, .newEmptyFile], .currentFolder(folder), handler, folder)
    }

    private func submenu(_ title: String, id: String, _ commands: [Command], _ target: CommandTarget,
                         _ handler: CommandHandler, _ folder: FolderModel) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.\(id)")
        let submenu = NSMenu(title: title)
        for command in commands { add(command, target, handler, to: submenu).state = state(command, folder: folder) }
        item.submenu = submenu
        return item
    }

    private func state(_ command: Command, folder: FolderModel) -> NSControl.StateValue {
        let settings = context.environment.settings
        let sort = folder.query.sort
        let on: Bool = switch command {
        case .viewAsDetails: settings.viewMode == .details
        case .viewAsIcons: settings.viewMode == .icons
        case .iconSizeSmall: settings.iconSize == .small
        case .iconSizeMedium: settings.iconSize == .medium
        case .iconSizeLarge: settings.iconSize == .large
        case .densityCompact: settings.density == .compact
        case .densityRegular: settings.density == .regular
        case .densityComfortable: settings.density == .comfortable
        case .toggleHidden: folder.query.showHidden
        case .toggleCommandBar: settings.commandBarVisible
        case .sortByName: sort.field == .name
        case .sortByDateModified: sort.field == .dateModified
        case .sortBySize: sort.field == .size
        case .sortByKind: sort.field == .kind
        case .sortByDateCreated: sort.field == .dateCreated
        case .sortAscending: sort.ascending
        case .sortDescending: !sort.ascending
        default: false
        }
        return on ? .on : .off
    }

    private func openWithItem(rows: IndexSet, folder: FolderModel, handler: CommandHandler) -> NSMenuItem? {
        guard let commands = handler as? FileCommandController else { return nil }
        let fileRows = rows.filter { folder.entry(atRow: $0).kind != .directory }
        guard let first = fileRows.first else { return nil }
        let files = fileRows.map { folder.url(atRow: $0) }
        let openWith = OpenWithMenu(files: files, typeIndex: folder.entry(atRow: first).typeIndex,
                                    cache: context.environment.launchServices, icons: context.icons,
                                    openWith: { [weak commands] app in commands?.openWith(files, app: app) },
                                    other: { [weak commands] in commands?.openWithOther(files) },
                                    chooseDefault: { [weak commands] in commands?.chooseDefaultApp(for: files[0]) })
        let item = NSMenuItem(title: L10n.string("Open With"), action: nil, keyEquivalent: "")
        item.submenu = openWith.menu
        item.representedObject = openWith
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.openWith")
        return item
    }
}
```

```swift
// Sources/UI/Menus/OpenWithMenu.swift
import AppKit
import Core
import MacxFS

/// Open With ▸ (§5.6): filled from LaunchServicesCache only. A miss shows "Loading…", and the menu updates in place
/// when the cache observer fires. It never blocks and does no LaunchServices lookups while the menu is built.
@MainActor
final class OpenWithMenu: NSObject, NSMenuDelegate {
    let menu: NSMenu
    private let files: [URL]
    private let typeIndex: UInt16
    private let cache: LaunchServicesCache
    private let icons: IconCache?
    private let openWith: @MainActor (URL) -> Void
    private let other: @MainActor () -> Void
    private let chooseDefault: @MainActor () -> Void
    private var token: ObserverToken?

    init(files: [URL], typeIndex: UInt16, cache: LaunchServicesCache, icons: IconCache?,
         openWith: @escaping @MainActor (URL) -> Void, other: @escaping @MainActor () -> Void,
         chooseDefault: @escaping @MainActor () -> Void) {
        self.menu = NSMenu(title: L10n.string("Open With"))
        self.files = files
        self.typeIndex = typeIndex
        self.cache = cache
        self.icons = icons
        self.openWith = openWith
        self.other = other
        self.chooseDefault = chooseDefault
        super.init()
        menu.delegate = self
        if let file = files.first { cache.prefetch(file: file, typeIndex: typeIndex) }
        token = cache.observe { [weak self] url in
            guard let self, url == self.files.first else { return }
            self.rebuild()
        }
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func rebuild() {
        menu.removeAllItems()
        guard let file = files.first else { return }
        guard let apps = cache.cachedApplications(for: file, typeIndex: typeIndex),
              case .some(let defaultApp) = cache.cachedDefault(for: file) else {
            let loading = NSMenuItem(title: L10n.string("Loading…"), action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
            addFooter()
            return
        }
        if let defaultApp {
            menu.addItem(appItem(defaultApp, isDefault: true))
            menu.addItem(.separator())
        }
        for app in apps where app.url != defaultApp?.url { menu.addItem(appItem(app, isDefault: false)) }
        addFooter()
    }

    private func appItem(_ app: AppInfo, isDefault: Bool) -> NSMenuItem {
        let openWith = self.openWith
        let item = ClosureMenuItem(title: isDefault ? String(format: L10n.string("%@ (default)"), app.name) : app.name) {
            openWith(app.url)
        }
        item.state = isDefault ? .on : .off
        icons?.fileIcon(for: app.url, rowID: .name(app.url.path), points: 16, scale: 2) { [weak item] image in
            item?.image = NSImage(cgImage: image, size: NSSize(width: 16, height: 16))
        }
        return item
    }

    private func addFooter() {
        menu.addItem(.separator())
        let other = self.other
        let chooseDefault = self.chooseDefault
        menu.addItem(ClosureMenuItem(title: L10n.string("Other…")) { other() })
        menu.addItem(ClosureMenuItem(title: L10n.string("Choose Default App…")) { chooseDefault() })
    }
}
```

```swift
// Sources/UI/OpenWith/DefaultAppSheet.swift
import AppKit
import UniformTypeIdentifiers
import Core

/// §5.7: checked → set the content-type default (works for dyn.* types), then the per-file default (so an existing
/// per-file override can't keep winning), then open; unchecked → open once with the app.
enum DefaultAppChoice {
    static func apply(app: URL, file: URL, always: Bool, provider: any LaunchServicesProviding) async throws {
        if always {
            try await provider.setDefaultApplication(app, forContentTypeOf: file)
            try await provider.setDefaultApplication(app, forFile: file)
        }
        try await provider.open([file], withApplicationAt: app)
    }
}

/// Choose Default App… sheet: the apps that can open the file, Browse…, and "Always use this app".
@MainActor
final class DefaultAppSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let file: URL
    private let context: UIContext
    private var apps: [AppInfo] = []
    private let panel: NSPanel
    private let table = NSTableView()
    private let always: NSButton
    private var continuation: CheckedContinuation<AppInfo?, Never>?

    static func present(for file: URL, on window: NSWindow, context: UIContext) async {
        await present(for: file, on: window, context: context, alwaysChecked: false)
    }

    /// Properties' "Change All…" opens the sheet with the checkbox already on (P1-37).
    static func present(for file: URL, on window: NSWindow, context: UIContext, alwaysChecked: Bool) async {
        await DefaultAppSheet(file: file, context: context, alwaysChecked: alwaysChecked).run(on: window)
    }

    private init(file: URL, context: UIContext, alwaysChecked: Bool) {
        self.file = file
        self.context = context
        let ext = file.pathExtension
        always = NSButton(checkboxWithTitle: ext.isEmpty ? L10n.string("Always use this app to open files of this type")
                                                         : String(format: L10n.string("Always use this app to open .%@ files"), ext),
                          target: nil, action: nil)
        always.state = alwaysChecked ? .on : .off
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        buildUI()
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: String(format: L10n.string("Choose an app to open '%@':"), file.lastPathComponent))
        let column = NSTableColumn(identifier: .init("app"))
        column.title = ""
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openPressed(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        let browse = NSButton(title: L10n.string("Browse…"), target: self, action: #selector(browsePressed(_:)))
        let cancel = NSButton(title: L10n.string("Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let open = NSButton(title: L10n.string("Open"), target: self, action: #selector(openPressed(_:)))
        open.keyEquivalent = "\r"
        let buttons = NSStackView(views: [browse, NSView(), cancel, open])
        let stack = NSStackView(views: [title, scroll, always, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scroll, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        panel.contentView = stack
    }

    private func run(on window: NSWindow) async {
        apps = await context.environment.launchServices.provider.applications(toOpen: file)
        table.reloadData()
        if !apps.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let chosen = await withCheckedContinuation { (continuation: CheckedContinuation<AppInfo?, Never>) in
            self.continuation = continuation
            window.beginSheet(panel)
        }
        window.endSheet(panel)
        guard let chosen else { return }
        do {
            try await DefaultAppChoice.apply(app: chosen.url, file: file, always: always.state == .on,
                                             provider: context.environment.launchServices.provider)
            context.environment.launchServices.invalidate(file: file)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(format: L10n.string("'%@' couldn't be opened with %@."), file.lastPathComponent, chosen.name)
            alert.informativeText = error.localizedDescription
            _ = await alert.beginSheetModal(for: window)
        }
    }

    private func finish(_ app: AppInfo?) {
        continuation?.resume(returning: app)
        continuation = nil
    }

    @objc private func openPressed(_ sender: Any?) {
        let row = table.selectedRow
        finish(row >= 0 && row < apps.count ? apps[row] : nil)
    }

    @objc private func cancelPressed(_ sender: Any?) { finish(nil) }

    @objc private func browsePressed(_ sender: Any?) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.application]
        open.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let provider = context.environment.launchServices.provider
        Task {
            guard await open.beginSheetModal(for: self.panel) == .OK, let url = open.url else { return }
            let info = await provider.appInfo(at: url) ?? AppInfo(url: url, name: url.deletingPathExtension().lastPathComponent, bundleIdentifier: nil)
            self.apps.insert(info, at: 0)
            self.table.reloadData()
            self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = tableView.makeView(withIdentifier: .init("appName"), owner: nil) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = .init("appName")
            return field
        }()
        label.stringValue = apps[row].name
        return label
    }
}
```

- [ ] **Step 8: Wire context menus, Services, cut dimming and the handler**

In `Sources/UI/Details/DetailsViewController.swift`, replace the whole `FileTableView` class with:

```swift
/// NSTableView with the routing the content view needs. P1-36 adds drags and right-drag.
final class FileTableView: NSTableView, @MainActor NSServicesMenuRequestor {
    weak var owner: DetailsViewController?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return super.mouseDown(with: event) }
        if event.modifierFlags.contains(.control) {   // ⌃-click opens the context menu immediately (§5.6)
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        owner.handleMouseDown(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let owner else { return super.mouseUp(with: event) }
        owner.handleMouseUp(event)
    }

    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(Selector(("selectAll:")), with: sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return owner?.contextMenuProvider?(row >= 0 ? row : nil)
    }

    // Services ▸ (§5.6): the selection as file URLs.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, sendType == .fileURL || sendType == .string, owner?.folder?.selection.isEmpty == false { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let urls = owner?.folder?.selectedURLs, !urls.isEmpty else { return false }
        pboard.clearContents()
        return pboard.writeObjects(urls.map { $0 as NSURL })
    }
}
```

Add to `DetailsViewController` (stored property, next to `renameController`):

```swift
    var contextMenuProvider: ((Int?) -> NSMenu?)?
```

In `Sources/UI/Icons/IconsViewController.swift`, add the same `contextMenuProvider` property to `IconsViewController`, and add to `FileCollectionView`:

```swift
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        return owner.contextMenuProvider?(owner.layout.itemIndex(at: convert(event.locationInWindow, from: nil)))
    }
```

In `FileCollectionView.mouseDown`, insert the same `⌃`-click branch as in `FileTableView.mouseDown` before `owner.handleMouseDown(event)`.

In `Sources/UI/Content/ContentViewController.swift`, add properties:

```swift
    private lazy var menuBuilder = ContextMenuBuilder(context: context)
    private var clipboardToken: ObserverToken?
```

In `viewDidLoad()`, after `addChild(details)`, add:

```swift
        details.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        clipboardToken = context.environment.clipboard.observe { [weak self] in self?.refreshCutNames() }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
```

In `iconsController()`, after `addChild(created)`, add:

```swift
        created.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
```

In `bind(_:)`, add `refreshCutNames()` right after `activeList.bind(folder)`. Then add these methods:

```swift
    // MARK: context menus and clipboard (P1-35)

    /// Right-click rule (§5.6, Review Focus 1). S6's scenario driver calls this for `rightClick` steps.
    func contextMenu(forRow row: Int?) -> NSMenu? {
        guard let handler else { return nil }
        let folder = session.folder
        let rule = ContextMenuBuilder.contextRows(clickedRow: row, selectedRows: folder.selection.rows)
        if let select = rule.select { folder.select(select) }
        if let rows = rule.rows, !rows.isEmpty { return menuBuilder.itemMenu(for: rows, in: folder, handler: handler) }
        return menuBuilder.emptySpaceMenu(for: folder, handler: handler)
    }

    func refreshCutNames() {
        let folder = session.folder
        folder.cutNames = context.environment.clipboard.cutNames(in: folder.directory)
        activeList.reloadSelectionDrawing()
        updateCommandBar()
    }

    @objc private func applicationDidBecomeActive(_ note: Notification) {
        context.environment.clipboard.revalidate()   // §5.6: poll changeCount on activation
    }
```

In `Sources/UI/Window/BrowserWindowController.swift`, at the end of the initializer (after the split view controller is installed as `contentViewController`), install the shared handler. This replaces any interim handler P1-26 set:

```swift
        let fileCommands = FileCommandController(context: context, window: self)
        contentViewController?.firstDescendant(of: ContentViewController.self)?.handler = fileCommands
        contentViewController?.firstDescendant(of: SidebarViewController.self)?.handler = fileCommands
```

(`CommandHandlingViewController.handler` holds the controller strongly, and the controller holds the window weakly, so there is no cycle.)

- [ ] **Step 9: Run the tests to verify they pass**

Run: `swift test --filter 'UITests\.(ContextMenuTests|FileCommandTests|InlineRenameTests|SelectionControllerTests)' 2>&1 | tail -5`
Expected: `Executed 51 tests, with 0 failures` (with no GUI session: `with 40 tests skipped and 0 failures`).

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 10: Verify in the app (sandbox only)**

With the manual run recipe (`--fake-launch-services` records app launches instead of performing them):
1. Right-click `file3.txt` while `file1.txt` and `file2.txt` are selected: only `file3.txt` becomes selected and the menu follows §5.6 order. Right-click inside a multi-selection keeps it. Right-click `Sub Folder` shows Paste. ⌃-click opens the same menu.
2. Hover Open With: "Loading…" briefly, then the fake's list (empty in fake mode: only Other… and Choose Default App…). Without `--fake-launch-services` (still `--root` at the sandbox), the real list appears with the default ✓. Choose Default App… shows the sheet; **press Cancel** (don't change real defaults during validation).
3. ⌘C `file1.txt`, then ⌘V: `file1 copy.txt`. ⌘X `file2.txt`: the row turns 50% and italic. Esc undims it. ⌘X again, select `Sub Folder`, ⌘V: the file lands in the current folder, not `Sub Folder`. Right-click `Sub Folder` › Paste moves it into the folder.
4. ⌘⌫ trashes into `$SANDBOX/trash` (check with `ls "$SANDBOX/trash"`), and ⌘Z restores it. ⌥⌘⌫ asks "Permanently delete 1 items? This can't be undone." and Cancel keeps the file.
5. ⌘⇧N creates `New Folder` in rename mode. ⌘⇧C then paste into a text editor gives the POSIX path. F2 renames (P1-34 checks).
6. Sidebar: select a Favorite and press Del: the favorite disappears and the folder stays.

- [ ] **Step 11: Commit**

```bash
git add Sources/UI/Commands Sources/UI/Menus/ContextMenuBuilder.swift Sources/UI/Menus/OpenWithMenu.swift Sources/UI/OpenWith \
  Sources/UI/Window/BrowserWindowController.swift Sources/UI/Details/DetailsViewController.swift Sources/UI/Icons/IconsViewController.swift \
  Sources/UI/Content/ContentViewController.swift Sources/UI/Resources/Localizable.xcstrings \
  Tests/UITests/ContextMenuTests.swift Tests/UITests/FileCommandTests.swift
git commit -m "feat: file commands, context menus, Open With and clipboard UI (P1-35)"
```

---

### Task P1-36: Drag & drop, right-drag and drop menus

**Spec coverage:** §5.6 drag sources (at most 5 `NSDraggingItem`s with a composite image of up to 5 icons plus a count badge; in `draggingSession(_:willBeginAt:)` every selected URL is written as its own `public.file-url` item plus `NSFilenamesPboardType`, with no cap; `numberOfValidItemsForDrop` set to the real count; no file promises from us). Destinations (folders in the list and grid, tree nodes, Favorites "onto", address-bar segments, other apps). Validation is purely in memory (`DropPolicy` with the `Volumes` mount table, self/descendant refusal with a "no" cursor, no file-system calls in `draggingUpdated`). Default move on the same volume and copy across volumes; ⌥ copy, ⌘ move, ⌥⌘ alias; the cursor badge follows the operation. Right-drag: `rightMouseDown` records, past about 3 pt it starts a drag marked `com.macexplorer.secondary-drag`, otherwise `rightMouseUp` shows the context menu; ⌃-click opens it immediately; ⌃ at drop (or a secondary drag) gives the menu drop `Copy Here · Move Here · Create Alias Here · Create Symbolic Link Here · Cancel`. Spring-loading after the system delay (`NSSpringLoadingDestination`), autoscroll, and drops of file promises from other apps via `NSFilePromiseReceiver`. Perf budget: drag of 100k items < 300 ms (pasteboard write; the unit smoke test checks 10k, and `macx-bench` checks 100k). Slice Review Focus 4.

**Files:**
- Create: `Sources/UI/DragDrop/DragSource.swift`
- Create: `Sources/UI/DragDrop/DropTarget.swift`
- Create: `Sources/UI/DragDrop/RightDragTracker.swift`
- Create: `Sources/UI/DragDrop/DropMenu.swift`
- Modify: `Sources/UI/Details/DetailsViewController.swift`, `Sources/UI/Icons/IconsViewController.swift`, `Sources/UI/Icons/FileGridLayout.swift`, `Sources/UI/Content/ContentViewController.swift`, `Sources/UI/Sidebar/SidebarViewController.swift`, `Sources/UI/Toolbar/BreadcrumbView.swift` and the code that creates the `BreadcrumbView` (P1-27 `ToolbarController`/`AddressBarView`), `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/DragDropTests.swift`

**Interfaces:**
- Consumes: `DropPolicy.operation(sources:destination:modifiers:isSecondaryDrag:mountTable:) -> DragOperation`, `DropPolicy.secondaryDragType`, `DragOperation`, `DragModifiers`, `Volumes.mountTable`, `JobKind.copy/move/alias/symlink`, `OperationsCenter.perform`, `ChangeBus.post(_:)`, `LocalChange`, `Favorite.displayName/lastKnownPath`, `Settings.favorites`, `ScenarioHooks.performDrop: (([URL], String, DragModifiers, Bool, DragOperation?) async -> Void)?`, `ScenarioProbe.probePerformDrop(sources:onto:modifiers:secondary:menuChoice:)` (S4 forwards to the hook), P1-33 `ListMouseHandler`, P1-35 `ClosureMenuItem`, `contextMenuProvider`.
- Produces (internal):
  - `@MainActor enum DragPasteboard { static let filenamesType; static let secondaryType; static func write(_:secondary:to:); static func readURLs(from:) -> [URL]; static func isSecondary(_:) -> Bool }`; `@MainActor enum DragImageComposer { static func image(icons:count:iconPoints:scale:) -> NSImage }`; `@MainActor final class DragSourceController: NSObject, NSDraggingSource { init(icons:); func begin(event:rows:folder:view:rowFrame:secondary:); var isDragging: Bool }`.
  - `struct RightDragTracker { enum Outcome { case none, beginDrag, showMenu(at: NSPoint) }; static let threshold: CGFloat; static func exceedsThreshold(from:to:) -> Bool; mutating func rightMouseDown(at:); mutating func rightMouseDragged(to:) -> Outcome; mutating func rightMouseUp(at:) -> Outcome }`.
  - `enum DropChoice: String, CaseIterable { case copy, move, alias, symlink, cancel; var title; func jobKind(sources:destination:) -> JobKind?; init?(menuChoice: DragOperation?); init?(operation: DragOperation) }`; `@MainActor enum DropMenu { static func makeMenu(choose:) -> NSMenu; static func run(at:in:) -> DropChoice? }`.
  - `@MainActor final class DropTarget { static let acceptedTypes; init(context: UIContext, originView: NSView?); var presentMenu; func operation(sources:destination:modifiers:secondary:) -> DragOperation; func validate(_:destination:) -> NSDragOperation; func perform(_:destination:in:) -> Bool; func run(_:sources:destination:menuAt:in:) -> Bool; static func dragOperation(_:) -> NSDragOperation }`; `@MainActor final class FolderDropForwarder` (for S4 views); `enum DropRetarget { struct Result; static func destination(row:onRow:folder:) -> Result }`; `enum SpringLoadPolicy { static func opens(_ kind: Kind) -> Bool }`; `@MainActor enum DropDestinationResolver { static func resolve(_:folder:favorites:) -> URL?; static func crumbURL(_:of:volumeRoot:) -> URL? }`; `extension DragModifiers { init(_ flags: NSEvent.ModifierFlags) }`.
  - `ContentViewController.dropTarget`, `.scenarioDrop(sources:onto:modifiers:secondary:choice:) async`.

- [ ] **Step 1: Write the failing drag-and-drop tests**

```swift
// Tests/UITests/DragDropTests.swift
import XCTest
import AppKit
import Darwin
@testable import UI
import Core
import MacxFS

@MainActor
final class DragDropTests: XCTestCase {
    private func pasteboard(_ h: ContentTestHarness) -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name(h.pasteboardName)) }

    func testDragPasteboardWritesEveryURLAndFilenames() async throws {
        let h = try await ContentTestHarness.make(self)
        let urls = try ["a", "b", "c"].map { try h.file($0) }
        let board = pasteboard(h)
        DragPasteboard.write(urls, secondary: false, to: board)
        let read = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(read?.map(\.standardizedFileURL), urls.map(\.standardizedFileURL), "one public.file-url item per URL")
        XCTAssertEqual(board.propertyList(forType: DragPasteboard.filenamesType) as? [String], urls.map(\.path))
        XCTAssertEqual(DragPasteboard.readURLs(from: board).map(\.path), urls.map(\.path))
        XCTAssertFalse(DragPasteboard.isSecondary(board))
    }

    func testDragPasteboardMarksSecondaryDrag() async throws {
        let h = try await ContentTestHarness.make(self)
        let board = pasteboard(h)
        DragPasteboard.write([try h.file("a")], secondary: true, to: board)
        XCTAssertTrue(DragPasteboard.isSecondary(board))
        XCTAssertEqual(DragPasteboard.secondaryType.rawValue, DropPolicy.secondaryDragType)
    }

    func testDragPasteboardWritesTenThousandQuickly() async throws {
        let h = try await ContentTestHarness.make(self)
        let urls = (0..<10_000).map { h.url("f\($0).txt") }   // paths only; nothing is created
        let start = ContinuousClock.now
        DragPasteboard.write(urls, secondary: false, to: pasteboard(h))
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1_200), "budget: 100k in 300 ms release (§4.4)")
        XCTAssertEqual(pasteboard(h).pasteboardItems?.count, 10_000)
    }

    func testDragImageComposerCapsAtFiveIcons() async throws {
        let h = try await ContentTestHarness.make(self)
        let icon = h.context.icons.typeIcon(TypeRegistry.dataIndex, points: 48, scale: 2)
        let one = DragImageComposer.image(icons: [icon], count: 1)
        let two = DragImageComposer.image(icons: [icon, icon], count: 2)
        let five = DragImageComposer.image(icons: Array(repeating: icon, count: 5), count: 5)
        let many = DragImageComposer.image(icons: Array(repeating: icon, count: 10), count: 10_000)
        XCTAssertLessThan(one.size.width, two.size.width)
        XCTAssertEqual(five.size, many.size, "at most 5 icons are drawn")
    }

    func testRightDragTrackerThreshold() {
        var tracker = RightDragTracker()
        tracker.rightMouseDown(at: NSPoint(x: 10, y: 10))
        XCTAssertEqual(tracker.rightMouseDragged(to: NSPoint(x: 12, y: 11)), .none)
        XCTAssertEqual(tracker.rightMouseUp(at: NSPoint(x: 12, y: 11)), .showMenu(at: NSPoint(x: 10, y: 10)), "small wobble → menu")
        tracker.rightMouseDown(at: NSPoint(x: 10, y: 10))
        XCTAssertEqual(tracker.rightMouseDragged(to: NSPoint(x: 14, y: 10)), .beginDrag)
        XCTAssertEqual(tracker.rightMouseDragged(to: NSPoint(x: 30, y: 10)), .none, "only one drag per press")
        XCTAssertEqual(tracker.rightMouseUp(at: NSPoint(x: 30, y: 10)), .none, "no menu after a drag")
        XCTAssertEqual(tracker.rightMouseUp(at: .zero), .none, "up without down")
    }

    /// Slice Review Focus 4.
    func testDropOnFileOrPackageRowTargetsCurrentFolder() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("folder"); try h.file("file.txt"); try h.dir("Fake.app/Contents")
        let folder = try await h.openFolder()
        func destination(_ name: String, onRow: Bool = true) throws -> DropRetarget.Result {
            DropRetarget.destination(row: try XCTUnwrap(folder.row(named: name)), onRow: onRow, folder: folder)
        }
        XCTAssertEqual(try destination("folder"), DropRetarget.Result(url: folder.url(atRow: folder.row(named: "folder")!), retargetToFolder: false))
        XCTAssertEqual(try destination("file.txt"), DropRetarget.Result(url: folder.directory, retargetToFolder: true))
        XCTAssertEqual(try destination("Fake.app"), DropRetarget.Result(url: folder.directory, retargetToFolder: true), "packages are files (§5.7)")
        XCTAssertEqual(try destination("folder", onRow: false), DropRetarget.Result(url: folder.directory, retargetToFolder: true),
                       "between rows → the displayed folder")
        XCTAssertEqual(DropRetarget.destination(row: -1, onRow: true, folder: folder).url, folder.directory)
    }

    func testSpringLoadingOnlyForFolders() {
        XCTAssertTrue(SpringLoadPolicy.opens(.directory))
        for kind in [Kind.package, .file, .symlink, .alias, .other] { XCTAssertFalse(SpringLoadPolicy.opens(kind), "\(kind)") }
    }

    func testDropDestinationResolver() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("sub"); try h.file("a.txt")
        let folder = try await h.openFolder()
        XCTAssertEqual(DropDestinationResolver.resolve("", folder: folder, favorites: []), folder.directory)
        XCTAssertEqual(DropDestinationResolver.resolve("sub", folder: folder, favorites: [])?.lastPathComponent, "sub")
        XCTAssertEqual(DropDestinationResolver.resolve("a.txt", folder: folder, favorites: []), folder.directory)
        XCTAssertNil(DropDestinationResolver.resolve("missing", folder: folder, favorites: []))
        let favorite = Favorite(bookmark: Data(), displayName: "Fav", lastKnownPath: h.url("sub").path)
        XCTAssertEqual(DropDestinationResolver.resolve("sidebar:Fav", folder: folder, favorites: [favorite])?.path, h.url("sub").path)
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        let dir = URL(filePath: "/Users/x/dev", directoryHint: .isDirectory)
        XCTAssertEqual(DropDestinationResolver.crumbURL(0, of: dir, volumeRoot: root)?.path, "/")
        XCTAssertEqual(DropDestinationResolver.crumbURL(2, of: dir, volumeRoot: root)?.path, "/Users/x")
        XCTAssertEqual(DropDestinationResolver.crumbURL(3, of: dir, volumeRoot: root)?.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertNil(DropDestinationResolver.crumbURL(4, of: dir, volumeRoot: root))
    }

    func testDropChoiceMapping() {
        let src = [URL(filePath: "/s/a")]
        let dst = URL(filePath: "/d", directoryHint: .isDirectory)
        XCTAssertEqual(DropChoice.copy.jobKind(sources: src, destination: dst), .copy(sources: src, destination: dst))
        XCTAssertEqual(DropChoice.move.jobKind(sources: src, destination: dst), .move(sources: src, destination: dst))
        XCTAssertEqual(DropChoice.alias.jobKind(sources: src, destination: dst), .alias(sources: src, destination: dst))
        XCTAssertEqual(DropChoice.symlink.jobKind(sources: src, destination: dst), .symlink(sources: src, destination: dst))
        XCTAssertNil(DropChoice.cancel.jobKind(sources: src, destination: dst))
        XCTAssertEqual(DropTarget.dragOperation(.copy), .copy)
        XCTAssertEqual(DropTarget.dragOperation(.move), .move)
        XCTAssertEqual(DropTarget.dragOperation(.alias), .link)
        XCTAssertEqual(DropTarget.dragOperation(.menu), .generic)
        XCTAssertEqual(DropTarget.dragOperation(.none), [])
        XCTAssertNil(DropChoice(menuChoice: DragOperation.none))
        XCTAssertEqual(DropChoice(menuChoice: .alias), .alias)
    }

    func testDropMenuTitles() {
        let menu = DropMenu.makeMenu { _ in }
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "-" : $0.title },
                       ["Copy Here", "Move Here", "Create Alias Here", "Create Symbolic Link Here", "-", "Cancel"])
    }

    func testRunMoveOnSameVolume() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let drops = DropTarget(context: h.context)
        let op = drops.operation(sources: [h.url("a.txt")], destination: h.url("sub"), modifiers: [], secondary: false)
        XCTAssertEqual(op, .move, "same volume moves by default")
        XCTAssertEqual(drops.operation(sources: [h.url("a.txt")], destination: h.url("sub"), modifiers: .option, secondary: false), .copy)
        XCTAssertTrue(drops.run(op, sources: [h.url("a.txt")], destination: h.url("sub"), menuAt: .zero, in: nil))
        try await h.waitUntil("moved") { h.exists("sub/a.txt") && !h.exists("a.txt") }
    }

    func testSelfOrDescendantDropIsRefused() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("A/sub")
        let drops = DropTarget(context: h.context)
        XCTAssertEqual(drops.operation(sources: [h.url("A")], destination: h.url("A/sub"), modifiers: [], secondary: false), .none)
        XCTAssertEqual(drops.operation(sources: [h.url("A")], destination: h.url("A"), modifiers: .option, secondary: false), .none)
        XCTAssertFalse(drops.run(.none, sources: [h.url("A")], destination: h.url("A/sub"), menuAt: .zero, in: nil))
    }

    func testMenuDropRunsChosenSymlink() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let drops = DropTarget(context: h.context)
        drops.presentMenu = { _, _ in .symlink }
        let op = drops.operation(sources: [h.url("a.txt")], destination: h.url("sub"), modifiers: [], secondary: true)
        XCTAssertEqual(op, .menu, "right-drag → drop menu")
        XCTAssertTrue(drops.run(op, sources: [h.url("a.txt")], destination: h.url("sub"), menuAt: .zero, in: NSView()))
        try await h.waitUntil("symlink created") {
            (try? FileManager.default.contentsOfDirectory(atPath: h.url("sub").path))?.isEmpty == false
        }
        let made = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: h.url("sub").path).first)
        let info = try XCTUnwrap(h.lstatInfo("sub/\(made)"))
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        XCTAssertTrue(h.exists("a.txt"), "the source stays")
    }

    func testMenuDropCancelDoesNothing() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let drops = DropTarget(context: h.context)
        drops.presentMenu = { _, _ in nil }
        XCTAssertFalse(drops.run(.menu, sources: [h.url("a.txt")], destination: h.url("sub"), menuAt: .zero, in: NSView()))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(h.exists("a.txt"))
        XCTAssertFalse(h.exists("sub/a.txt"))
    }

    func testScenarioDropHookMovesIntoFolder() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let browser = try await h.openBrowserWindow()
        await browser.probePerformDrop(sources: [h.url("a.txt")], onto: "sub", modifiers: [], secondary: false, menuChoice: nil)
        try await h.waitUntil("moved by the probe") { h.exists("sub/a.txt") && !h.exists("a.txt") }
    }

    func testScenarioDropSecondaryUsesMenuChoice() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let browser = try await h.openBrowserWindow()
        await browser.probePerformDrop(sources: [h.url("a.txt")], onto: "sub", modifiers: [], secondary: true, menuChoice: .copy)
        try await h.waitUntil("copied by the probe") { h.exists("sub/a.txt") }
        XCTAssertTrue(h.exists("a.txt"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'UITests\.DragDropTests' 2>&1 | tail -20`
Expected: compile errors such as `cannot find 'DragPasteboard' in scope`, `cannot find 'RightDragTracker' in scope`, `cannot find 'DropRetarget' in scope`.

- [ ] **Step 3: Add this task's strings**

Run: `scripts/l10n-add.sh "Copy Here" "Move Here" "Create Alias Here" "Create Symbolic Link Here" "Drop"`

- [ ] **Step 4: Implement the source side**

```swift
// Sources/UI/DragDrop/RightDragTracker.swift
import AppKit

/// §5.6 right-drag: rightMouseDown only records the point. Moving more than ~3 pt before rightMouseUp starts a
/// drag (no menu); otherwise rightMouseUp shows the context menu at the original point. Window coordinates.
struct RightDragTracker: Equatable {
    enum Outcome: Equatable { case none, beginDrag, showMenu(at: NSPoint) }
    static let threshold: CGFloat = 3
    private(set) var downPoint: NSPoint?
    private(set) var dragging = false

    static func exceedsThreshold(from a: NSPoint, to b: NSPoint) -> Bool {
        hypot(b.x - a.x, b.y - a.y) > threshold
    }

    mutating func rightMouseDown(at point: NSPoint) {
        downPoint = point
        dragging = false
    }

    mutating func rightMouseDragged(to point: NSPoint) -> Outcome {
        guard let downPoint, !dragging, Self.exceedsThreshold(from: downPoint, to: point) else { return .none }
        dragging = true
        return .beginDrag
    }

    mutating func rightMouseUp(at point: NSPoint) -> Outcome {
        defer { downPoint = nil; dragging = false }
        guard let downPoint, !dragging else { return .none }
        return .showMenu(at: downPoint)
    }
}
```

```swift
// Sources/UI/DragDrop/DragSource.swift
import AppKit
import Core
import MacxFS

/// Drag pasteboard payload (§5.6): every URL as its own public.file-url item, the legacy NSFilenamesPboardType path
/// list (also the fast path for internal drops), and the secondary-drag marker for right-drags.
@MainActor
enum DragPasteboard {
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let secondaryType = NSPasteboard.PasteboardType(DropPolicy.secondaryDragType)

    static func write(_ urls: [URL], secondary: Bool, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboard.setPropertyList(urls.map(\.path), forType: filenamesType)
        if secondary { pasteboard.setData(Data(), forType: secondaryType) }
    }

    static func readURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] { return paths.map { URL(filePath: $0) } }
        return pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func isSecondary(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(secondaryType) ?? false
    }
}

/// Up to 5 fanned icons plus a red count badge when more than one item is dragged.
@MainActor
enum DragImageComposer {
    static func image(icons: [CGImage], count: Int, iconPoints: CGFloat = 48, scale: CGFloat = 2) -> NSImage {
        let shown = Array(icons.prefix(5))
        let step: CGFloat = 6
        let fan = step * CGFloat(max(shown.count - 1, 0))
        let size = NSSize(width: iconPoints + fan + 22, height: iconPoints + fan + 22)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: size)
        }
        context.scaleBy(x: scale, y: scale)
        for (index, icon) in shown.enumerated().reversed() {
            context.draw(icon, in: CGRect(x: CGFloat(index) * step, y: fan - CGFloat(index) * step, width: iconPoints, height: iconPoints))
        }
        if count > 1 {
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let text = count.formatted() as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
            let textSize = text.size(withAttributes: attributes)
            let width = max(textSize.width + 10, 20)
            let badge = NSRect(x: size.width - width, y: size.height - 20, width: width, height: 20)
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 10, yRadius: 10).fill()
            text.draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let image = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: size)
    }
}

/// Starts drags from a list. The session begins with ≤ 5 dragging items, and the full URL list is written in
/// willBeginAt so 100k-item drags stay within budget (§5.6, §4.4).
@MainActor
final class DragSourceController: NSObject, NSDraggingSource {
    private let icons: IconCache
    private var pendingURLs: [URL] = []
    private var pendingSecondary = false
    private(set) var isDragging = false

    init(icons: IconCache) {
        self.icons = icons
        super.init()
    }

    func begin(event: NSEvent, rows: IndexSet, folder: FolderModel, view: NSView, rowFrame: (Int) -> NSRect, secondary: Bool) {
        let valid = rows.filteredIndexSet { $0 < folder.rowCount }
        guard !valid.isEmpty, !isDragging else { return }
        let urls = valid.map { folder.url(atRow: $0) }
        pendingURLs = urls
        pendingSecondary = secondary
        isDragging = true
        let sample = Array(valid.prefix(5))
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        let composite = DragImageComposer.image(icons: sample.map { icons.typeIcon(folder.entry(atRow: $0).typeIndex, points: 48, scale: scale) },
                                                count: urls.count, scale: CGFloat(scale))
        let items: [NSDraggingItem] = sample.enumerated().map { index, row in
            let item = NSDraggingItem(pasteboardWriter: urls[index] as NSURL)
            let origin = rowFrame(row).origin
            if index == 0 {
                item.setDraggingFrame(NSRect(origin: origin, size: composite.size), contents: composite)
            } else {
                item.setDraggingFrame(NSRect(origin: origin, size: NSSize(width: 1, height: 1)), contents: nil)
            }
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        DragPasteboard.write(pendingURLs, secondary: pendingSecondary, to: session.draggingPasteboard)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pendingURLs = []
        isDragging = false
    }
}
```

- [ ] **Step 5: Implement the destination side and the drop menu**

```swift
// Sources/UI/DragDrop/DropMenu.swift
import AppKit
import Core

enum DropChoice: String, CaseIterable, Sendable {
    case copy, move, alias, symlink, cancel

    @MainActor var title: String {
        switch self {
        case .copy: L10n.string("Copy Here")
        case .move: L10n.string("Move Here")
        case .alias: L10n.string("Create Alias Here")
        case .symlink: L10n.string("Create Symbolic Link Here")
        case .cancel: L10n.string("Cancel")
        }
    }

    func jobKind(sources: [URL], destination: URL) -> JobKind? {
        switch self {
        case .copy: .copy(sources: sources, destination: destination)
        case .move: .move(sources: sources, destination: destination)
        case .alias: .alias(sources: sources, destination: destination)
        case .symlink: .symlink(sources: sources, destination: destination)
        case .cancel: nil
        }
    }

    /// The scenario probe's menu choice (DragOperation has no symlink case; see Contract notes).
    init?(menuChoice: DragOperation?) {
        switch menuChoice {
        case .copy?: self = .copy
        case .move?: self = .move
        case .alias?: self = .alias
        default: return nil
        }
    }

    init?(operation: DragOperation) {
        switch operation {
        case .copy: self = .copy
        case .move: self = .move
        case .alias: self = .alias
        case .menu, .none: return nil
        }
    }
}

/// The menu drop (§5.6): shown at the drop point; Cancel does nothing.
@MainActor
enum DropMenu {
    static func makeMenu(choose: @escaping @MainActor (DropChoice) -> Void) -> NSMenu {
        let menu = NSMenu(title: L10n.string("Drop"))
        for choice in DropChoice.allCases {
            if choice == .cancel { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(title: choice.title) { choose(choice) })
        }
        return menu
    }

    static func run(at point: NSPoint, in view: NSView) -> DropChoice? {
        var chosen: DropChoice?
        let menu = makeMenu { chosen = $0 }
        menu.popUp(positioning: nil, at: point, in: view)   // synchronous; the item action fires before it returns
        return chosen == .cancel ? nil : chosen
    }
}
```

```swift
// Sources/UI/DragDrop/DropTarget.swift
import AppKit
import Core
import MacxFS

extension DragModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: DragModifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(rawValue: modifiers.rawValue)
    }
}

/// Only folders spring open; packages are files (§5.7).
enum SpringLoadPolicy {
    static func opens(_ kind: Kind) -> Bool { kind == .directory }
}

/// Which folder a list drop lands in (Review Focus 4): onto a folder row → that folder; anything else (a file,
/// alias, symlink or package row, between rows, empty space) → the displayed folder.
enum DropRetarget {
    struct Result: Equatable { var url: URL; var retargetToFolder: Bool }

    @MainActor
    static func destination(row: Int, onRow: Bool, folder: FolderModel) -> Result {
        if onRow, row >= 0, row < folder.rowCount, folder.entry(atRow: row).kind == .directory {
            return Result(url: folder.url(atRow: row), retargetToFolder: false)
        }
        return Result(url: folder.directory, retargetToFolder: true)
    }
}

/// Scenario `drop.onto` strings (overview §3.14): "" current folder, a row name, "sidebar:<Favorite name>", "crumb:<index>".
@MainActor
enum DropDestinationResolver {
    static func resolve(_ onto: String, folder: FolderModel, favorites: [Favorite]) -> URL? {
        if onto.isEmpty { return folder.directory }
        if onto.hasPrefix("sidebar:") {
            let name = String(onto.dropFirst("sidebar:".count))
            return favorites.first { $0.displayName == name }.map { URL(filePath: $0.lastKnownPath, directoryHint: .isDirectory) }
        }
        if onto.hasPrefix("crumb:"), let index = Int(onto.dropFirst("crumb:".count)) {
            return crumbURL(index, of: folder.directory, volumeRoot: folder.volume?.mountPoint)
        }
        guard let row = folder.row(named: onto) else { return nil }
        return DropRetarget.destination(row: row, onRow: true, folder: folder).url
    }

    /// Breadcrumb segment `index`: 0 is the volume root, then one segment per path component below it (§5.2).
    static func crumbURL(_ index: Int, of directory: URL, volumeRoot: URL?) -> URL? {
        let root = (volumeRoot ?? URL(filePath: "/", directoryHint: .isDirectory)).standardizedFileURL
        let rootComponents = root.pathComponents
        let components = directory.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents), index >= 0, index <= components.count - rootComponents.count else { return nil }
        var url = root
        for component in components[rootComponents.count..<(rootComponents.count + index)] {
            url.append(path: component, directoryHint: .isDirectory)
        }
        return url
    }
}

/// Shared drop destination logic for lists, tree, favorites and breadcrumb segments (§5.6).
/// draggingUpdated is purely in memory: the pasteboard is read once per drag session, and DropPolicy uses the mount table.
@MainActor
final class DropTarget {
    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, DragPasteboard.filenamesType] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let context: UIContext
    private weak var originView: NSView?
    private var cachedSequence: Int?
    private var cachedURLs: [URL] = []
    /// Seam for tests; the default pops DropMenu at the drop point.
    var presentMenu: @MainActor (NSPoint, NSView) -> DropChoice? = DropMenu.run

    init(context: UIContext, originView: NSView? = nil) {
        self.context = context
        self.originView = originView
    }

    var origin: OriginID? { originView?.window.map { OriginID(raw: $0.windowNumber) } }

    func operation(sources: [URL], destination: URL, modifiers: DragModifiers, secondary: Bool) -> DragOperation {
        guard !sources.isEmpty else { return .none }
        return DropPolicy.operation(sources: sources.map { $0.standardizedFileURL.path },
                                    destination: destination.standardizedFileURL.path, modifiers: modifiers,
                                    isSecondaryDrag: secondary, mountTable: context.environment.volumes.mountTable)
    }

    func validate(_ info: any NSDraggingInfo, destination: URL) -> NSDragOperation {
        if Self.isPromiseOnly(info.draggingPasteboard) { return .copy }
        let urls = sources(info)
        let op = operation(sources: urls, destination: destination, modifiers: DragModifiers(NSEvent.modifierFlags),
                           secondary: DragPasteboard.isSecondary(info.draggingPasteboard))
        info.numberOfValidItemsForDrop = op == .none ? 0 : urls.count
        return Self.dragOperation(op)
    }

    func perform(_ info: any NSDraggingInfo, destination: URL, in view: NSView) -> Bool {
        if Self.isPromiseOnly(info.draggingPasteboard) { return receivePromises(info.draggingPasteboard, destination: destination) }
        let urls = sources(info)
        let op = operation(sources: urls, destination: destination, modifiers: DragModifiers(NSEvent.modifierFlags),
                           secondary: DragPasteboard.isSecondary(info.draggingPasteboard))
        return run(op, sources: urls, destination: destination, menuAt: view.convert(info.draggingLocation, from: nil), in: view)
    }

    @discardableResult
    func run(_ op: DragOperation, sources: [URL], destination: URL, menuAt point: NSPoint, in view: NSView?) -> Bool {
        let choice: DropChoice?
        switch op {
        case .none: return false
        case .menu:
            guard let view else { return false }
            choice = presentMenu(point, view)
        default:
            choice = DropChoice(operation: op)
        }
        guard let choice, let kind = choice.jobKind(sources: sources, destination: destination) else { return false }
        let request = JobRequest(kind, origin: origin)
        let operations = context.environment.operations
        Task { _ = await operations.perform(request) }
        return true
    }

    static func dragOperation(_ op: DragOperation) -> NSDragOperation {
        switch op {
        case .copy: .copy
        case .move: .move
        case .alias: .link
        case .menu: .generic
        case .none: []
        }
    }

    static func isPromiseOnly(_ pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])
        let promises = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return !types.contains(.fileURL) && !types.contains(DragPasteboard.filenamesType) && !types.isDisjoint(with: promises)
    }

    private func sources(_ info: any NSDraggingInfo) -> [URL] {
        if cachedSequence != info.draggingSequenceNumber {
            cachedSequence = info.draggingSequenceNumber
            cachedURLs = DragPasteboard.readURLs(from: info.draggingPasteboard)
        }
        return cachedURLs
    }

    /// Drops from apps that use file promises (§5.6): the source app writes into `destination`.
    private func receivePromises(_ pasteboard: NSPasteboard, destination: URL) -> Bool {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        guard !receivers.isEmpty else { return false }
        let bus = context.environment.changeBus
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: Self.promiseQueue) { url, error in
                guard error == nil else { return }
                let name = url.lastPathComponent
                Task { @MainActor in bus.post([LocalChange(directory: destination, added: [name])]) }
            }
        }
        return true
    }
}

/// Glue for S4-owned destination views (breadcrumb segments): call from their NSDraggingDestination overrides.
@MainActor
final class FolderDropForwarder {
    let target: DropTarget
    let destination: @MainActor () -> URL?

    init(target: DropTarget, destination: @escaping @MainActor () -> URL?) {
        self.target = target
        self.destination = destination
    }

    func validate(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let url = destination() else { return [] }
        return target.validate(info, destination: url)
    }

    func perform(_ info: any NSDraggingInfo, in view: NSView) -> Bool {
        guard let url = destination() else { return false }
        return target.perform(info, destination: url, in: view)
    }
}
```

- [ ] **Step 6: Make the lists drag sources and drop destinations**

In `Sources/UI/Icons/FileGridLayout.swift`, add after `layoutAttributesForItem(at:)`:

```swift
    override func layoutAttributesForDropTarget(at pointInCollectionView: NSPoint) -> NSCollectionViewLayoutAttributes? {
        guard let index = itemIndex(at: pointInCollectionView) else { return nil }
        return attributes(index, frame(forItem: index))
    }
```

In `Sources/UI/Details/DetailsViewController.swift`, add these members to `FileTableView` and make it conform to `NSSpringLoadingDestination` (the class declaration becomes `final class FileTableView: NSTableView, @MainActor NSServicesMenuRequestor, NSSpringLoadingDestination`):

```swift
    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return super.mouseDragged(with: event) }
        owner.handleMouseDragged(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let owner else { return super.rightMouseDown(with: event) }
        owner.handleRightMouseDown(event)   // no menu yet (§5.6)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let owner else { return super.rightMouseDragged(with: event) }
        owner.handleRightMouseDragged(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let owner else { return super.rightMouseUp(with: event) }
        owner.handleRightMouseUp(event)
    }

    func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        owner?.springLoadTarget(draggingInfo) == nil ? .disabled : .enabled
    }

    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        owner?.springLoadTarget(draggingInfo) == nil ? .disabled : .enabled
    }

    func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        if activated, let url = owner?.springLoadTarget(draggingInfo) { owner?.onSpringLoad?(url) }
    }

    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {}
```

Add to `DetailsViewController` (stored properties next to `contextMenuProvider`):

```swift
    var dropTarget: DropTarget?
    var onSpringLoad: ((URL) -> Void)?
    private lazy var dragSource = DragSourceController(icons: context.icons)
    private var rightDrag = RightDragTracker()
    private var rightDownEvent: NSEvent?
```

At the end of `loadView()`, before `view = scrollView`:

```swift
        tableView.registerForDraggedTypes(DropTarget.acceptedTypes)
        tableView.draggingDestinationFeedbackStyle = .regular
```

and these methods:

```swift
    // MARK: drag & drop (P1-36)

    func handleMouseDragged(_ event: NSEvent) {
        guard let folder, let start = mouse.mouseDownWindowPoint, let row = mouse.mouseDownRow, !dragSource.isDragging,
              RightDragTracker.exceedsThreshold(from: start, to: event.locationInWindow) else { return }
        mouse.cancelPendingForDrag()
        let rows = folder.selection.rows.contains(row) ? folder.selection.rows : IndexSet(integer: row)
        dragSource.begin(event: event, rows: rows, folder: folder, view: tableView, rowFrame: { [tableView] in tableView.rect(ofRow: $0) },
                         secondary: false)
    }

    func handleRightMouseDown(_ event: NSEvent) {
        rightDrag.rightMouseDown(at: event.locationInWindow)
        rightDownEvent = event
    }

    func handleRightMouseDragged(_ event: NSEvent) {
        guard rightDrag.rightMouseDragged(to: event.locationInWindow) == .beginDrag, let folder, let down = rightDownEvent else { return }
        let row = tableView.row(at: tableView.convert(down.locationInWindow, from: nil))
        guard row >= 0 else { return }
        if !folder.selection.rows.contains(row) { folder.select(.set(IndexSet(integer: row), cursor: row)) }
        dragSource.begin(event: event, rows: folder.selection.rows, folder: folder, view: tableView,
                         rowFrame: { [tableView] in tableView.rect(ofRow: $0) }, secondary: true)
    }

    func handleRightMouseUp(_ event: NSEvent) {
        if case .showMenu = rightDrag.rightMouseUp(at: event.locationInWindow), let down = rightDownEvent,
           let menu = tableView.menu(for: down) {
            NSMenu.popUpContextMenu(menu, with: event, for: tableView)
        }
        rightDownEvent = nil
    }

    func springLoadTarget(_ info: any NSDraggingInfo) -> URL? {
        guard let folder else { return nil }
        let row = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
        guard row >= 0, row < folder.rowCount, SpringLoadPolicy.opens(folder.entry(atRow: row).kind) else { return nil }
        return folder.url(atRow: row)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let folder, let dropTarget else { return [] }
        let result = DropRetarget.destination(row: row, onRow: dropOperation == .on, folder: folder)
        if result.retargetToFolder { tableView.setDropRow(-1, dropOperation: .on) }   // highlight the whole list
        return dropTarget.validate(info, destination: result.url)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let folder, let dropTarget else { return false }
        return dropTarget.perform(info, destination: DropRetarget.destination(row: row, onRow: dropOperation == .on, folder: folder).url,
                                  in: tableView)
    }
```

In `Sources/UI/Icons/IconsViewController.swift`, give `FileCollectionView` the same `mouseDragged`/`rightMouse*` overrides and the same `NSSpringLoadingDestination` methods (forwarding to `IconsViewController` methods of the same names). Add the same five stored properties to `IconsViewController`, then in `loadView()` add `collectionView.registerForDraggedTypes(DropTarget.acceptedTypes)` and `collectionView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)`, and add:

```swift
    // MARK: drag & drop (P1-36)

    func handleMouseDragged(_ event: NSEvent) {
        guard let folder, let start = mouse.mouseDownWindowPoint, let row = mouse.mouseDownRow, !dragSource.isDragging,
              RightDragTracker.exceedsThreshold(from: start, to: event.locationInWindow) else { return }
        mouse.cancelPendingForDrag()
        let rows = folder.selection.rows.contains(row) ? folder.selection.rows : IndexSet(integer: row)
        dragSource.begin(event: event, rows: rows, folder: folder, view: collectionView, rowFrame: { [layout] in layout.frame(forItem: $0) },
                         secondary: false)
    }

    func handleRightMouseDown(_ event: NSEvent) {
        rightDrag.rightMouseDown(at: event.locationInWindow)
        rightDownEvent = event
    }

    func handleRightMouseDragged(_ event: NSEvent) {
        guard rightDrag.rightMouseDragged(to: event.locationInWindow) == .beginDrag, let folder, let down = rightDownEvent,
              let row = layout.itemIndex(at: collectionView.convert(down.locationInWindow, from: nil)) else { return }
        if !folder.selection.rows.contains(row) { folder.select(.set(IndexSet(integer: row), cursor: row)) }
        dragSource.begin(event: event, rows: folder.selection.rows, folder: folder, view: collectionView,
                         rowFrame: { [layout] in layout.frame(forItem: $0) }, secondary: true)
    }

    func handleRightMouseUp(_ event: NSEvent) {
        if case .showMenu = rightDrag.rightMouseUp(at: event.locationInWindow), let down = rightDownEvent,
           let menu = collectionView.menu(for: down) {
            NSMenu.popUpContextMenu(menu, with: event, for: collectionView)
        }
        rightDownEvent = nil
    }

    func springLoadTarget(_ info: any NSDraggingInfo) -> URL? {
        guard let folder, let row = layout.itemIndex(at: collectionView.convert(info.draggingLocation, from: nil)),
              row < folder.rowCount, SpringLoadPolicy.opens(folder.entry(atRow: row).kind) else { return nil }
        return folder.url(atRow: row)
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let folder, let dropTarget else { return [] }
        let result = DropRetarget.destination(row: proposedDropIndexPath.pointee.item, onRow: proposedDropOperation.pointee == .on, folder: folder)
        if result.retargetToFolder { proposedDropOperation.pointee = .before }
        return dropTarget.validate(draggingInfo, destination: result.url)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let folder, let dropTarget else { return false }
        let result = DropRetarget.destination(row: indexPath.item, onRow: dropOperation == .on, folder: folder)
        return dropTarget.perform(draggingInfo, destination: result.url, in: collectionView)
    }
```

Both scroll views autoscroll during drags (built into NSTableView and NSCollectionView destination tracking), so autoscroll needs no extra code.

- [ ] **Step 7: Wire the content host, sidebar and breadcrumb**

In `Sources/UI/Content/ContentViewController.swift`, add:

```swift
    private(set) lazy var dropTarget = DropTarget(context: context, originView: view)
```

In `viewDidLoad()` after `details.contextMenuProvider = …`:

```swift
        details.dropTarget = dropTarget
        details.onSpringLoad = { [weak self] url in self?.session.navigate(to: url) }
```

In `iconsController()` after `created.contextMenuProvider = …`:

```swift
        created.dropTarget = dropTarget
        created.onSpringLoad = { [weak self] url in self?.session.navigate(to: url) }
```

In `installScenarioHooks()`, add:

```swift
        controller.scenarioHooks.performDrop = { [weak self] sources, onto, modifiers, secondary, choice in
            await self?.scenarioDrop(sources: sources, onto: onto, modifiers: modifiers, secondary: secondary, choice: choice)
        }
```

and add the method. It runs the same DropPolicy → DropMenu choice → job path as a real drop:

```swift
    /// Scenario drop entry point (overview §3.14 ScenarioProbe.probePerformDrop). Drag sessions can't be synthesized
    /// in-process, so this runs the same DropPolicy → menu choice → job path as a real drop.
    func scenarioDrop(sources: [URL], onto: String, modifiers: DragModifiers, secondary: Bool, choice: DragOperation?) async {
        let folder = session.folder
        guard let destination = DropDestinationResolver.resolve(onto, folder: folder, favorites: context.environment.settings.favorites) else {
            return
        }
        let op = dropTarget.operation(sources: sources, destination: destination, modifiers: modifiers, secondary: secondary)
        let picked: DropChoice? = op == .menu ? DropChoice(menuChoice: choice) : DropChoice(operation: op)
        guard let picked, let kind = picked.jobKind(sources: sources, destination: destination) else { return }
        _ = await context.environment.operations.perform(JobRequest(kind, origin: dropTarget.origin))
    }
```

In `Sources/UI/Sidebar/SidebarViewController.swift` (S4, P1-28), make Folders-tree nodes and Favorites rows accept drops *onto* them. Keep P1-28's Favorites add/reorder handling for drops *between* favorites, and run that branch first:

```swift
    // P1-36 (§5.4, §5.6): drops onto a tree node, favorite or volume row go through DropTarget.
    private lazy var fileDropTarget = DropTarget(context: context, originView: outlineView)

    // In outlineView(_:validateDrop:proposedItem:proposedChildIndex:), after P1-28's "between favorites" branch:
    //     if index == NSOutlineViewDropOnItemIndex, let url = folderURL(forDropOnto: item) {
    //         return fileDropTarget.validate(info, destination: url)
    //     }
    // In outlineView(_:acceptDrop:item:childIndex:), likewise:
    //     if index == NSOutlineViewDropOnItemIndex, let url = folderURL(forDropOnto: item) {
    //         return fileDropTarget.perform(info, destination: url, in: outlineView)
    //     }
```

Add `func folderURL(forDropOnto item: Any?) -> URL?` to `SidebarViewController`. It returns the row's folder URL from P1-28's `SidebarItem`: the tree node's URL, the resolved favorite URL (nil when stale), or the volume's `mountPoint`, and nil for section headers. Also register `DropTarget.acceptedTypes` on the outline view in addition to P1-28's types. If P1-28 doesn't already expand tree nodes on hover during a drag, implement `NSSpringLoadingDestination` on the outline view, as for `FileTableView`, expanding the hovered node in `springLoadingActivated` (§5.4 "springs it open").

In `Sources/UI/Toolbar/BreadcrumbView.swift`, add a `var dropForwarder: FolderDropForwarder?` to the per-segment view class. Register `DropTarget.acceptedTypes` in its initializer, and add:

```swift
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropForwarder?.validate(sender) ?? [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropForwarder?.validate(sender) ?? [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropForwarder?.perform(sender, in: self) ?? false }
```

When the breadcrumb builds a segment for folder URL `segmentURL` (P1-27), set:

```swift
        segment.dropForwarder = FolderDropForwarder(target: dropTarget, destination: { segmentURL })
```

where `dropTarget` is a `DropTarget(context: context, originView: self)` that the breadcrumb gets once from whoever creates it (the toolbar code that has the `UIContext`).

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter 'UITests\.(DragDropTests|SelectionControllerTests|ContextMenuTests|IconsViewTests)' 2>&1 | tail -5`
Expected: `Executed 46 tests, with 0 failures` (with no GUI session: `with 17 tests skipped and 0 failures`).

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 9: Verify in the app (sandbox only)**

With the manual run recipe, also create a second sandbox folder for Finder (it stays inside `$SANDBOX`): `mkdir "$SANDBOX/finder-side" && open "$SANDBOX/finder-side"` (Finder shows that folder only).
1. Drag `file1.txt` onto `Sub Folder`: it moves (same volume). ⌥-drag copies, ⌘-drag moves, ⌥⌘-drag makes an alias. The cursor badge changes with the keys.
2. Drag `Sub Folder` onto itself or into `Sub Folder/Nested`: "no" cursor, nothing happens.
3. Drop onto `file2.txt` or `Fake.app`: the whole list highlights and the item lands in the current folder.
4. Hover a dragged item over `Sub Folder` and it springs open after the system delay.
5. Right-drag `file3.txt` onto `Sub Folder`: the drop menu appears; choose Create Symbolic Link Here and check `ls -l "$SANDBOX/root/Sub Folder"`. Right-click without moving shows the context menu. ⌃-drag also gives the menu.
6. Select 20 files and drag them into the Finder window on `$SANDBOX/finder-side`: Finder copies all 20 (the badge says 20). Drag a file from that Finder window into the app: it copies (cross-app default).
7. Drop onto a breadcrumb segment and onto a Folders-tree node; both accept.

- [ ] **Step 10: Commit**

```bash
git add Sources/UI/DragDrop Sources/UI/Details/DetailsViewController.swift Sources/UI/Icons Sources/UI/Content/ContentViewController.swift \
  Sources/UI/Sidebar/SidebarViewController.swift Sources/UI/Toolbar Sources/UI/Resources/Localizable.xcstrings Tests/UITests/DragDropTests.swift
git commit -m "feat: drag and drop with right-drag menus, spring-loading and promises (P1-36)"
```

---

### Task P1-37: Properties window

**Spec coverage:** §5.8 in full. One non-modal window per selection set, opened with ⌘I / ⌥Return; a second invocation on the same set focuses the existing window. **General:** 64 pt icon (Tier 0 at once, Tier 1 custom icon on a lane), editable name with the §5.6 rules (empty, `/`, 255 bytes, duplicates including hidden items, extension-change and leading-dot warnings), Kind, Location with Reveal, Size (human-readable plus exact bytes) and size on disk, Contains for folders (live, cancellable `FolderCounter`), Created / Modified / Last opened, and the Locked / Hidden / Hide extension checkboxes. **Permissions:** Owner, Group and Everyone popups (Read & Write / Read only / Write only / No access), editable only when the current user owns the item (otherwise a note), "Apply to enclosed items…" for folders as a confirmed `chmodRecursive` job, read-only ACL entries, "Executable" for files. **Opens with:** the per-file default app with Change… (this file) and Change All… (every file of the type, `setDefaultApplication(_:forContentTypeOf:)` then `forFile:`). **Details:** UTType identifier, full path, inode, volume, Where from, quarantine with Remove, extended attributes (name and size, read-only). **Multiple selection:** "N items (X files, Y folders)", total size, tri-state attributes; no name and no Opens with. **Volume:** format, capacity, used and free with a usage bar, mount point, Eject. Every edit is a `setAttributes` / `rename` / `chmodRecursive` job, undoable through the app-wide `FileOpUndoStack` (§6.6: the Properties window returns it from `windowWillReturnUndoManager(_:)`, and a per-edit manager while the name field is editing). A failed edit shows an inline error and reverts the control. S5-C3: every read runs on a lane (`PropertiesLoader`, `FolderCounter`, `NameAvailability`).

**Files:**
- Create: `Sources/UI/Properties/PropertiesFormat.swift` (new; display text, `Tri` helpers, `TriCheckbox`)
- Create: `Sources/UI/Properties/PropertiesViewModel.swift`
- Create: `Sources/UI/Properties/PropertiesView.swift`
- Create: `Sources/UI/Properties/PropertiesWindowController.swift`
- Modify: `Sources/UI/Operations/ErrorText.swift` (the §6.5 job error text)
- Modify: `Sources/UI/Commands/FileCommandController.swift` (`showProperties`, `propertiesSubject`, `pendingCommands`)
- Modify: `Sources/UI/OpenWith/DefaultAppSheet.swift` (a change-the-default mode that doesn't open the file)
- Modify: `Tests/UITests/Support/ContentTestHarness.swift` (scripted interaction, Properties windows closed in teardown)
- Modify: `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/PropertiesViewModelTests.swift`

**Interfaces:**
- Consumes (overview §3, exact):
  - `public struct ItemProperties: Sendable, Equatable` (all fields: `url`, `name`, `displayName`, `kindDescription`, `typeIdentifier`, `kind`, `logicalSize: Int64?`, `physicalSize: Int64?`, `created/modified/lastOpened: Date?`, `isLocked`, `isHidden`, `isExtensionHidden`, `mode: UInt16`, `ownerID`, `groupID`, `ownerName`, `groupName`, `isOwnedByCurrentUser`, `aclEntries: [String]`, `inode: UInt64`, `volumeName`, `whereFroms: [String]`, `quarantine: QuarantineInfo?`, `xattrs: [XattrInfo]`), `MultiProperties` (`count`, `files`, `folders`, `totalSize`, `locked/hidden/extensionHidden: Tri`), `VolumeProperties` (`volume`, `capacity`, `available`, `used`), `public enum Tri: Sendable, Equatable { case on, off, mixed }`, `QuarantineInfo` (`agentName`, `date`), `XattrInfo` (`name`, `size`).
  - `PropertiesLoader.load(_ url: URL, lanes: LanePool, volume: VolumeID) async throws -> ItemProperties`, `.loadMany(_ urls: [URL], lanes: LanePool, volume: VolumeID) async throws -> MultiProperties`, `.loadVolume(_ volume: VolumeInfo, scanner: any VolumeScanning, lanes: LanePool) async -> VolumeProperties`; `FolderCounter.count(_ url: URL, lanes: LanePool, volume: VolumeID) -> AsyncStream<CountProgress>`, `CountProgress` (`files`, `folders`, `bytes`, `finished`).
  - `PermissionAccess` (`readWrite`, `readOnly`, `writeOnly`, `noAccess`), `PermissionClass` (`owner`, `group`, `everyone`), `PermissionModel.access(_:_:) -> PermissionAccess`, `.applying(_:_:to:) -> UInt16`, `.isExecutable(_:) -> Bool`.
  - `JobKind.setAttributes([URL], AttributeEdit)`, `.rename(URL, to: String)`, `.chmodRecursive(URL, ModeChange)`; `AttributeEdit` (`locked`, `hidden`, `extensionHidden`, `permissions`, `removeQuarantine`); `ModeChange(mode:applyToDirectories:applyToFiles:)`; `JobRequest(_:origin:registersUndo:)`; `OriginID(raw:)`; `JobOutcome` (`record`, `skipped`, `wasCancelled`); `SkippedItem` (`url`, `reason: FileOpErrorKind?`); `ItemAction` (`renamed`, `moved`, `attributesChanged`, `modeChanged`); `FileOpErrorKind` (every case); `JobVerb`.
  - `OperationsCenter.perform(_:) async -> JobOutcome`, `.onFinished(_:) -> ObserverToken`; `FileOpUndoStack.undoManager`, `.makeFieldEditorUndoManager()`, `.canUndo`; `EjectCoordinator.eject(_:) async throws(EjectError)`; `LaunchServicesProviding.defaultApplication(toOpen:)`, `.setDefaultApplication(_:forContentTypeOf:)`, `.setDefaultApplication(_:forFile:)`, `FakeLaunchServices.defaultsSet()/opened()`; `NameRules.validate(_:original:caseSensitive:exists:) -> NameValidation`; `Volumes.volume(for:)`; `VolumeInfo.capabilities.caseSensitive`; `SystemVolumeScanner()`; `TypeRegistry.index(forExtension:isDirectory:)`.
  - S4: `UIContext.environment/options/icons/windows`, `WindowManager.openWindow(at:selecting:)`, `AXID.propertiesWindow`, `L10n.string(_:)`. Earlier S5: `Formatters.bytes(_:)`, `.date(_:style:now:calendar:locale:)`, `Formatters.folderSize`, `IconCache.typeIcon(_:points:scale:)`, `.fileIcon(for:rowID:points:scale:completion:)`, `ErrorText.renameProblem(_:name:)`, `RenamePrompt`, `RenamePrompts.present(_:on:) async -> Bool`, `DefaultAppSheet.present(for:on:context:alwaysChecked:)`, `DefaultAppChoice`, `FileCommandController.showProperties(_:)`, `.pendingCommands`.
- Produces:
  - Overview §3.14, exact: `@MainActor final class PropertiesWindowController: NSWindowController { static func show(for urls: [URL], context: UIContext); static func show(volume: VolumeInfo, context: UIContext) }`.
  - Internal: `enum PropertiesSubject: Hashable { case items([URL]), volume(VolumeInfo) }`; `enum PropertiesConfirmation { case applyToEnclosed(name: String), rename(RenamePrompt) }`; `enum NameAvailability { static func validate(_:original:in:caseSensitive:lanes:volume:) async -> NameValidation }`; `@MainActor @Observable final class PropertiesViewModel` (`init(subject:environment:)`, `subject`, `urls`, `content: Content` with `.loading/.item/.items/.volume/.failed`, `folderCount`, `defaultApp`, `nameDraft`, `nameProblem`, `inlineError`, `isApplying`, `icon`, `title`, `canEditPermissions`, `showsOpensWith`, `origin`, `confirm`, `perform`, `onSubjectChanged`, `load()`, `reloadDefaultApp()`, `commitName() -> Bool`, `revertName()`, `setLocked/setHidden/setExtensionHidden(_:)`, `setAccess(_:for:)`, `applyPermissionsToEnclosed()`, `removeQuarantine()`, `eject() -> Bool`, `close()`, `static permissionsNote(isOwner:)`); `PropertiesView`, `PropertiesActions`; `PropertiesFormat` (`size`, `contains`, `items`, `date`, `access`, `who`, `usage`, `quarantine`, `grouped`); `extension Tri { init(_ on: Bool); var afterClick: Bool }`; `struct TriCheckbox: NSViewRepresentable` (reused by P1-38's Compare view); `PropertiesWindowController.controller(for:context:activate:)`, `.openControllers(for:)`, `.closeAll(for:)`, `.answersErrorsInline(_:)` (P1-38's router uses it), `.model`, `.loadContent()`; `ErrorText.jobError(_:name:verb:)`; `FileCommandController.propertiesSubject(for:volumes:)`; `DefaultAppSheet.present(for:on:context:alwaysChecked:opensFile:)`, `DefaultAppChoice.setDefault(app:file:allOfType:provider:)`; `ContentTestHarness.interaction: ScriptedInteraction`.

- [ ] **Step 1: Route test interaction to a script and close Properties windows in the harness**

Until P1-38 installs the real router, `UIContext` points `environment.interaction` at P1-26's `BasicAlertInteraction`, whose modal alerts would hang a test that hits a job error. Tests get a `ScriptedInteraction` instead (answers: conflicts `.one(.skip)`, errors `.skip`; S3 P1-17). Tests that need the router install it explicitly (P1-38).

In `Tests/UITests/Support/ContentTestHarness.swift`, add a stored property after `let pasteboardName: String`:

```swift
    /// environment.interaction's target in every UI test (S5-C1): never a modal alert.
    let interaction = ScriptedInteraction()
```

At the end of `private init()`, after `context = UIContext(environment: environment, options: options)`, add:

```swift
        environment.interaction.setTarget(interaction)
```

In `tearDown()`, add as the first line:

```swift
        PropertiesWindowController.closeAll(for: context)
```

- [ ] **Step 2: Write the failing Properties tests**

```swift
// Tests/UITests/PropertiesViewModelTests.swift
import XCTest
import AppKit
import Darwin
@testable import UI
import Core
import MacxFS

/// Collects values from escaping main-actor closures (a captured `var` can't be mutated from them).
@MainActor
private final class Recorder<Value> {
    var values: [Value] = []
}

@MainActor
final class PropertiesViewModelTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func model(_ h: ContentTestHarness, _ relatives: [String]) -> PropertiesViewModel {
        PropertiesViewModel(subject: .items(relatives.map { h.url($0).standardizedFileURL }), environment: h.environment)
    }

    private func item(_ m: PropertiesViewModel) -> ItemProperties? {
        if case .item(let item) = m.content { item } else { nil }
    }

    private func multi(_ m: PropertiesViewModel) -> MultiProperties? {
        if case .items(let multi) = m.content { multi } else { nil }
    }

    private func flags(_ h: ContentTestHarness, _ relative: String) -> UInt32? { h.lstatInfo(relative)?.st_flags }
    private func mode(_ h: ContentTestHarness, _ relative: String) -> UInt16? { h.lstatInfo(relative).map { UInt16($0.st_mode) & 0o777 } }

    func testSingleFileLoadsNameSizeAndTitle() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt", bytes: 1_234)
        let m = model(h, ["a.txt"])
        await m.load()
        let p = try XCTUnwrap(item(m))
        XCTAssertEqual(p.name, "a.txt")
        XCTAssertEqual(p.logicalSize, 1_234)
        XCTAssertEqual(m.nameDraft, "a.txt")
        XCTAssertEqual(m.title, "a.txt Properties")
        XCTAssertTrue(m.canEditPermissions, "the test user owns its sandbox files")
        XCTAssertTrue(m.showsOpensWith)
        XCTAssertNil(m.folderCount, "files are not counted")
    }

    func testFolderShowsLiveCountThatFinishes() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("F/a.txt", bytes: 10)
        try h.file("F/b.txt", bytes: 20)
        try h.file("F/sub/c.txt", bytes: 30)
        let m = model(h, ["F"])
        await m.load()
        XCTAssertFalse(m.showsOpensWith, "folders have no Opens with tab")
        try await h.waitUntil("count finished") { m.folderCount?.finished == true }
        // P1-16 counts the folder's contents, not the folder itself.
        XCTAssertEqual(m.folderCount?.files, 3)
        XCTAssertEqual(m.folderCount?.folders, 1)
        XCTAssertGreaterThanOrEqual(m.folderCount?.bytes ?? 0, 60, "logical or allocated bytes, at least the 60 written")
        m.close()
    }

    func testLockToggleRunsUndoableJobAndUndoRestores() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let path = h.url("a.txt").path
        addTeardownBlock { _ = chflags(path, 0) }   // never leave a locked file behind if an assertion fails
        let m = model(h, ["a.txt"])
        await m.load()
        await m.setLocked(true)
        XCTAssertNil(m.inlineError)
        XCTAssertEqual(flags(h, "a.txt").map { $0 & UInt32(UF_IMMUTABLE) != 0 }, true)
        XCTAssertEqual(item(m)?.isLocked, true)
        try await h.waitUntil("undo registered") { h.environment.undo.canUndo }
        h.environment.undo.undoManager.undo()
        try await h.waitUntil("unlocked on disk") { self.flags(h, "a.txt").map { $0 & UInt32(UF_IMMUTABLE) == 0 } == true }
        try await h.waitUntil("window follows the undo") { self.item(m)?.isLocked == false }
    }

    func testFailedEditShowsInlineErrorAndRevertsControl() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.setMode("a.txt", 0o644)
        try h.setFlags("a.txt", UF_IMMUTABLE)          // chmod on a locked file fails with EPERM
        let m = model(h, ["a.txt"])
        await m.load()
        await m.setAccess(.noAccess, for: .everyone)
        XCTAssertEqual(m.inlineError, "'a.txt' is locked.")
        XCTAssertEqual(item(m).map { $0.mode & 0o777 }, 0o644, "the popup reverts to the value on disk")
        XCTAssertEqual(mode(h, "a.txt"), 0o644)
        XCTAssertEqual(h.interaction.askedErrors().map(\.kind), [.locked])
        await m.setAccess(.readWrite, for: .owner)      // unchanged value: no job, error stays until the next edit
        XCTAssertEqual(h.interaction.askedErrors().count, 1)
    }

    func testRenameValidatesOnLaneIncludingHiddenNames() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.file("b.txt")
        try h.setFlags("b.txt", UF_HIDDEN)              // Review Focus 2: hidden names still count
        let m = model(h, ["a.txt"])
        await m.load()
        let renamed = Recorder<PropertiesSubject>()
        m.onSubjectChanged = { renamed.values.append($0) }
        m.nameDraft = "b.txt"
        let duplicate = await m.commitName()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(m.nameProblem, "The name 'b.txt' is already taken.")
        m.nameDraft = "a/b"
        let slash = await m.commitName()
        XCTAssertFalse(slash)
        XCTAssertEqual(m.nameProblem, "A name can't contain '/'.")
        XCTAssertTrue(h.exists("a.txt"))
        m.nameDraft = "c.txt"
        let ok = await m.commitName()
        XCTAssertTrue(ok)
        XCTAssertNil(m.nameProblem)
        XCTAssertTrue(h.exists("c.txt"))
        XCTAssertFalse(h.exists("a.txt"))
        let newURL = h.url("c.txt").standardizedFileURL
        try await h.waitUntil("subject follows the rename") { m.urls == [newURL] }
        XCTAssertEqual(renamed.values.last, .items([newURL]))
        XCTAssertEqual(m.title, "c.txt Properties")
        XCTAssertEqual(item(m)?.name, "c.txt")
    }

    func testExtensionChangeAsksBeforeRenaming() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let m = model(h, ["a.txt"])
        await m.load()
        let asked = Recorder<String>()
        m.confirm = { confirmation in
            if case .rename(.extensionChanged(let from, let to)) = confirmation { asked.values.append("\(from)>\(to)") }
            return false
        }
        m.nameDraft = "a.md"
        let ok = await m.commitName()
        XCTAssertFalse(ok)
        XCTAssertEqual(asked.values, ["txt>md"])
        XCTAssertEqual(m.nameDraft, "a.txt", "declining reverts the field")
        XCTAssertTrue(h.exists("a.txt"))
    }

    func testMultipleSelectionUsesTriStateAttributes() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt", bytes: 3)
        try h.file("b.txt", bytes: 4)
        try h.setFlags("b.txt", UF_HIDDEN)
        let m = model(h, ["a.txt", "b.txt"])
        await m.load()
        let before = try XCTUnwrap(multi(m))
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before.files, 2)
        XCTAssertEqual(before.folders, 0)
        XCTAssertEqual(before.hidden, .mixed)
        XCTAssertEqual(before.locked, .off)
        XCTAssertEqual(m.title, "2 Items Properties")
        XCTAssertFalse(m.showsOpensWith, "§5.8: no Opens with for a multiple selection")
        await m.setHidden(before.hidden.afterClick)
        XCTAssertEqual(flags(h, "a.txt").map { $0 & UInt32(UF_HIDDEN) != 0 }, true)
        XCTAssertEqual(flags(h, "b.txt").map { $0 & UInt32(UF_HIDDEN) != 0 }, true)
        XCTAssertEqual(multi(m)?.hidden, .on)
    }

    func testPermissionPopupsWriteModeBits() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.setMode("a.txt", 0o644)
        let m = model(h, ["a.txt"])
        await m.load()
        await m.setAccess(.noAccess, for: .everyone)
        XCTAssertEqual(mode(h, "a.txt"), 0o640)
        await m.setAccess(.readWrite, for: .group)
        XCTAssertEqual(mode(h, "a.txt"), 0o660)
        XCTAssertEqual(item(m).map { PermissionModel.access($0.mode, .group) }, .readWrite)
        XCTAssertNil(m.inlineError)
    }

    func testApplyToEnclosedConfirmsThenRunsChmodRecursive() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("F/sub")
        try h.setMode("F", 0o750)
        try h.setMode("F/sub", 0o755)
        let m = model(h, ["F"])
        await m.load()
        let asked = Recorder<String>()
        m.confirm = { confirmation in
            if case .applyToEnclosed(let name) = confirmation { asked.values.append(name) }
            return false
        }
        await m.applyPermissionsToEnclosed()
        XCTAssertEqual(asked.values, ["F"])
        XCTAssertEqual(mode(h, "F/sub"), 0o755, "declined: nothing changes")
        m.confirm = { _ in true }
        await m.applyPermissionsToEnclosed()
        XCTAssertEqual(mode(h, "F/sub"), 0o750)
        try await h.waitUntil("undoable") { h.environment.undo.canUndo }
        m.close()
    }

    func testRemoveQuarantineDeletesTheXattr() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("q.txt")
        try h.sandbox.setXattr("files/q.txt", name: "com.apple.quarantine", value: Data("0081;65f0c3a1;Safari;".utf8))
        let m = model(h, ["q.txt"])
        await m.load()
        XCTAssertNotNil(item(m)?.quarantine)
        await m.removeQuarantine()
        XCTAssertEqual(getxattr(h.url("q.txt").path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), -1)
        XCTAssertNil(item(m)?.quarantine)
        XCTAssertNil(m.inlineError)
    }

    func testVolumeSubjectShowsCapacityAndUsage() async throws {
        let h = try await ContentTestHarness.make(self)
        let volume = try XCTUnwrap(h.environment.volumes.volume(for: h.filesRoot))
        let m = PropertiesViewModel(subject: .volume(volume), environment: h.environment)
        await m.load()                                   // reads capacity only; S5-C8: nothing is ejected
        guard case .volume(let properties) = m.content else { return XCTFail("volume content expected") }
        XCTAssertEqual(properties.volume.id, volume.id)
        XCTAssertGreaterThan(properties.capacity ?? 0, 0)
        let usage = try XCTUnwrap(PropertiesFormat.usage(capacity: properties.capacity, available: properties.available))
        XCTAssertTrue((0...1).contains(usage))
        XCTAssertEqual(m.title, "\(volume.name) Properties")
        XCTAssertFalse(m.showsOpensWith)
    }

    func testChangeDefaultSetsDefaultsWithoutOpening() async throws {
        let h = try await ContentTestHarness.make(self)
        let fake = FakeLaunchServices()
        let app = h.url("Fake.app")                      // URLs only: the fake records, nothing is touched
        let file = h.url("x.txt")
        try await DefaultAppChoice.setDefault(app: app, file: file, allOfType: false, provider: fake)
        XCTAssertEqual(fake.defaultsSet().map(\.forType), [false], "Change…: this file only")
        try await DefaultAppChoice.setDefault(app: app, file: file, allOfType: true, provider: fake)
        XCTAssertEqual(fake.defaultsSet().map(\.forType), [false, true, false], "Change All…: type, then the per-file override")
        XCTAssertTrue(fake.opened().isEmpty, "Properties never opens the file")
    }

    func testPropertiesSubjectForEveryCommandTarget() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.file("b.txt")
        let folder = try await h.openFolder()
        let volume = try XCTUnwrap(h.environment.volumes.volume(for: h.filesRoot))
        let volumes = h.environment.volumes.list
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .contentSelection(folder), volumes: volumes),
                       .items([folder.directory]), "nothing selected: the current folder")
        folder.select(.names(["a.txt", "b.txt"]))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .contentSelection(folder), volumes: volumes),
                       .items(folder.selectedURLs))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .currentFolder(folder), volumes: volumes), .items([folder.directory]))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .folder(h.url("a.txt")), volumes: volumes), .items([h.url("a.txt")]))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .volume(volume), volumes: volumes), .volume(volume))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .folder(volume.mountPoint), volumes: volumes), .volume(volume),
                       "a volume root shows volume properties")
        XCTAssertFalse(FileCommandController.pendingCommands.contains(.properties))
    }

    func testJobErrorTextCoversTheErrorTable() {
        XCTAssertEqual(ErrorText.jobError(.permissionDenied, name: "a.txt", verb: .copying), "You don't have permission to copy 'a.txt'.")
        XCTAssertEqual(ErrorText.jobError(.permissionDenied, name: "a.txt"), "You don't have permission to change 'a.txt'.")
        XCTAssertEqual(ErrorText.jobError(.blockedByMacOS, name: "a.txt"), "macOS is blocking access to 'a.txt'.")
        XCTAssertEqual(ErrorText.jobError(.locked, name: "a.txt"), "'a.txt' is locked.")
        XCTAssertEqual(ErrorText.jobError(.readOnlyVolume, name: "a.txt"), "The destination is read-only.")
        XCTAssertEqual(ErrorText.jobError(.noSpace(needed: 2_000_000, available: 1_000_000), name: "a.txt"),
                       "Not enough space (needs 2 MB, 1 MB available).")
        XCTAssertEqual(ErrorText.jobError(.noSpace(needed: nil, available: nil), name: "a.txt"), "Not enough space on the destination.")
        XCTAssertEqual(ErrorText.jobError(.inUse, name: "a.txt"), "'a.txt' is in use by another app.")
        XCTAssertEqual(ErrorText.jobError(.nameTooLong, name: "a.txt"), "The name 'a.txt' is too long for the destination.")
        XCTAssertEqual(ErrorText.jobError(.sourceGone, name: "a.txt"), "'a.txt' no longer exists.")
        XCTAssertEqual(ErrorText.jobError(.intoItself, name: "A"), "'A' can't be moved or copied into itself.")
        XCTAssertEqual(ErrorText.jobError(.noTrash, name: "a.txt"), "'a.txt' can't be moved to the Trash.")
        XCTAssertEqual(ErrorText.jobError(.other(code: 5, message: "Input/output error"), name: "a.txt"),
                       "An error occurred with 'a.txt': Input/output error (error 5).")
    }

    func testFormattingAndTriStateClicks() {
        XCTAssertEqual(PropertiesFormat.size(1_234_567, locale: en), "1.2 MB (1,234,567 bytes)")
        XCTAssertEqual(PropertiesFormat.size(nil, locale: en), "--")
        XCTAssertEqual(PropertiesFormat.contains(files: 1_204, folders: 3, finished: false, locale: en), "Counting… 1,204 files, 3 folders")
        XCTAssertEqual(PropertiesFormat.contains(files: 1_204, folders: 3, finished: true, locale: en), "1,204 files, 3 folders")
        XCTAssertEqual(PropertiesFormat.items(count: 3, files: 2, folders: 1, locale: en), "3 items (2 files, 1 folders)")
        XCTAssertEqual(PropertiesFormat.access(.readWrite), "Read & Write")
        XCTAssertEqual(PropertiesFormat.who(.owner, owner: "me", group: "staff"), "Owner (me)")
        XCTAssertEqual(PropertiesFormat.usage(capacity: 100, available: 25), 0.75)
        XCTAssertNil(PropertiesFormat.usage(capacity: nil, available: 25))
        XCTAssertTrue(Tri.mixed.afterClick)
        XCTAssertTrue(Tri.off.afterClick)
        XCTAssertFalse(Tri.on.afterClick)
        XCTAssertEqual(Tri(true), .on)
        XCTAssertNil(PropertiesViewModel.permissionsNote(isOwner: true))
        XCTAssertEqual(PropertiesViewModel.permissionsNote(isOwner: false), "You can't change permissions because you aren't the owner.")
    }

    func testOneWindowPerSelectionSetAndUndoRouting() async throws {
        try ContentTestHarness.requireWindowServer()
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.file("b.txt")
        let a = h.url("a.txt"), b = h.url("b.txt")
        let one = try XCTUnwrap(PropertiesWindowController.controller(for: .items([a]), context: h.context, activate: false))
        let again = PropertiesWindowController.controller(for: .items([a]), context: h.context, activate: false)
        XCTAssertTrue(one === again, "§5.8: a second invocation focuses the existing window")
        let pair = PropertiesWindowController.controller(for: .items([a, b]), context: h.context, activate: false)
        let pairReversed = PropertiesWindowController.controller(for: .items([b, a]), context: h.context, activate: false)
        XCTAssertTrue(pair === pairReversed, "the selection set, not its order, identifies the window")
        XCTAssertFalse(pair === one)
        XCTAssertEqual(PropertiesWindowController.openControllers(for: h.context).count, 2)
        let window = try XCTUnwrap(one.window)
        XCTAssertEqual(window.identifier?.rawValue, AXID.propertiesWindow)
        XCTAssertFalse(window.isVisible, "tests never order Properties windows front (S5-C7)")
        XCTAssertTrue(one.windowWillReturnUndoManager(window) === h.environment.undo.undoManager, "§6.6: one app-wide stack")
        XCTAssertTrue(PropertiesWindowController.answersErrorsInline(OriginID(raw: window.windowNumber)))
        try await h.waitUntil("loaded") { one.model.content != .loading }
        one.close()
        XCTAssertEqual(PropertiesWindowController.openControllers(for: h.context).count, 1)
        XCTAssertFalse(PropertiesWindowController.answersErrorsInline(OriginID(raw: window.windowNumber)))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter 'UITests\.PropertiesViewModelTests' 2>&1 | tail -20`
Expected: compile errors such as `cannot find 'PropertiesViewModel' in scope`, `cannot find 'PropertiesFormat' in scope`, `type 'ErrorText' has no member 'jobError'`, `type 'FileCommandController' has no member 'propertiesSubject'`.

- [ ] **Step 4: Add this task's strings**

Run:
```bash
scripts/l10n-add.sh "%@ Properties" "%lld Items Properties" "General" "Permissions" "Opens with" "Details" "Name" "Kind" \
  "Location" "Reveal" "Size" "Size on disk" "Contains" "Counting…" "%@ files, %@ folders" "Counting… %@" "Created" "Modified" \
  "Last opened" "Attributes" "Read-only (Locked)" "Hidden" "Hide extension" "Owner (%@)" "Group (%@)" "Everyone" \
  "Read & Write" "Read only" "Write only" "No access" "Executable" "Yes" "No" \
  "You can't change permissions because you aren't the owner." "Apply to enclosed items…" "Access control list" \
  "No default app" "Change…" "Change All…" "Type identifier" "Path" "Inode" "Volume" "Where from" "Quarantine" "Remove" \
  "Quarantined" "Extended attributes" "Selection" "%@ items (%@ files, %@ folders)" "Total size" "Format" "Capacity" "Used" \
  "Free" "Used space" "Mount point" "Eject" "Apply these permissions to all items inside '%@'?" \
  "You can undo this with Edit › Undo." "Apply" "Cancel" "'%@' couldn't be read." "The default app for '%@' couldn't be changed." \
  "%@ (%@ bytes)" "'%@' can't be ejected because it is in use by %@." "'%@' couldn't be ejected."
scripts/l10n-add.sh "You don't have permission to copy '%@'." "You don't have permission to move '%@'." \
  "You don't have permission to move '%@' to the Trash." "You don't have permission to delete '%@'." \
  "You don't have permission to duplicate '%@'." "You don't have permission to create '%@'." \
  "You don't have permission to rename '%@'." "You don't have permission to make a link to '%@'." \
  "You don't have permission to change '%@'." "macOS is blocking access to '%@'." "'%@' is locked." \
  "The destination is read-only." "Not enough space (needs %@, %@ available)." "Not enough space on the destination." \
  "'%@' is in use by another app." "The name '%@' is too long for the destination." "'%@' no longer exists." \
  "'%@' can't be moved or copied into itself." "'%@' changed while it was being moved, so it was left in place." \
  "'%@' can't be moved to the Trash." "An error occurred with '%@': %@ (error %lld)."
jq -r '.strings | has("%@ Properties") and has("An error occurred with '"'"'%@'"'"': %@ (error %lld).")' Sources/UI/Resources/Localizable.xcstrings
```
Expected: `true`. (Keys earlier tasks already added, such as "Name", "Cancel" or the eject texts, are simply rewritten with the same value.)

- [ ] **Step 5: Add the job error text and the display helpers**

Append to `Sources/UI/Operations/ErrorText.swift`:

```swift
extension ErrorText {
    /// §6.5 "Message (plain)" for one item of a job. Used inline by Properties (P1-37) and as the error dialog's title
    /// (P1-38). `verb` picks the wording of permission errors.
    static func jobError(_ kind: FileOpErrorKind, name: String, verb: JobVerb? = nil) -> String {
        switch kind {
        case .permissionDenied: String(format: L10n.string(permissionKey(verb)), name)
        case .blockedByMacOS: String(format: L10n.string("macOS is blocking access to '%@'."), name)
        case .locked: String(format: L10n.string("'%@' is locked."), name)
        case .readOnlyVolume: L10n.string("The destination is read-only.")
        case .noSpace(let needed?, let available?):
            String(format: L10n.string("Not enough space (needs %@, %@ available)."), Formatters.bytes(needed), Formatters.bytes(available))
        case .noSpace: L10n.string("Not enough space on the destination.")
        case .inUse: String(format: L10n.string("'%@' is in use by another app."), name)
        case .nameTooLong: String(format: L10n.string("The name '%@' is too long for the destination."), name)
        case .sourceGone: String(format: L10n.string("'%@' no longer exists."), name)
        case .intoItself: String(format: L10n.string("'%@' can't be moved or copied into itself."), name)
        case .changedDuringMove: String(format: L10n.string("'%@' changed while it was being moved, so it was left in place."), name)
        case .noTrash: String(format: L10n.string("'%@' can't be moved to the Trash."), name)
        case .other(let code, let message):
            String(format: L10n.string("An error occurred with '%@': %@ (error %lld)."), name, message, Int64(code))
        }
    }

    private static func permissionKey(_ verb: JobVerb?) -> String {
        switch verb {
        case .copying?: "You don't have permission to copy '%@'."
        case .moving?: "You don't have permission to move '%@'."
        case .trashing?: "You don't have permission to move '%@' to the Trash."
        case .deleting?: "You don't have permission to delete '%@'."
        case .duplicating?: "You don't have permission to duplicate '%@'."
        case .creating?: "You don't have permission to create '%@'."
        case .renaming?: "You don't have permission to rename '%@'."
        case .makingAlias?, .makingSymlink?: "You don't have permission to make a link to '%@'."
        case .changingPermissions?, .changingAttributes?, .undoing?, .redoing?, nil: "You don't have permission to change '%@'."
        }
    }
}
```

```swift
// Sources/UI/Properties/PropertiesFormat.swift
import AppKit
import SwiftUI
import Core
import MacxFS

/// Display text for the Properties window (§5.8). Inputs are plain values, so tests need no Core initializers.
@MainActor
enum PropertiesFormat {
    static func grouped(_ value: Int64, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    /// "1.2 MB (1,234,567 bytes)"; unknown sizes show "--".
    static func size(_ bytes: Int64?, locale: Locale = .current) -> String {
        guard let bytes else { return Formatters.folderSize }
        return String(format: L10n.string("%@ (%@ bytes)"), Formatters.bytes(bytes), grouped(bytes, locale: locale))
    }

    /// "1,204 files, 3 folders", prefixed with "Counting…" until the background count finishes.
    static func contains(files: Int, folders: Int, finished: Bool, locale: Locale = .current) -> String {
        let text = String(format: L10n.string("%@ files, %@ folders"),
                          grouped(Int64(files), locale: locale), grouped(Int64(folders), locale: locale))
        return finished ? text : String(format: L10n.string("Counting… %@"), text)
    }

    /// Multiple selection header: "3 items (2 files, 1 folders)".
    static func items(count: Int, files: Int, folders: Int, locale: Locale = .current) -> String {
        String(format: L10n.string("%@ items (%@ files, %@ folders)"), grouped(Int64(count), locale: locale),
               grouped(Int64(files), locale: locale), grouped(Int64(folders), locale: locale))
    }

    static func date(_ date: Date?) -> String {
        date.map { Formatters.date($0, style: .absolute) } ?? Formatters.folderSize
    }

    static func access(_ access: PermissionAccess) -> String {
        switch access {
        case .readWrite: L10n.string("Read & Write")
        case .readOnly: L10n.string("Read only")
        case .writeOnly: L10n.string("Write only")
        case .noAccess: L10n.string("No access")
        }
    }

    static func who(_ who: PermissionClass, owner: String, group: String) -> String {
        switch who {
        case .owner: String(format: L10n.string("Owner (%@)"), owner)
        case .group: String(format: L10n.string("Group (%@)"), group)
        case .everyone: L10n.string("Everyone")
        }
    }

    /// Used fraction for the volume usage bar; nil when the capacity is unknown.
    static func usage(capacity: Int64?, available: Int64?) -> Double? {
        guard let capacity, capacity > 0, let available else { return nil }
        return min(1, max(0, Double(capacity - available) / Double(capacity)))
    }

    static func quarantine(agent: String?, date: Date?) -> String {
        let parts = [agent, date.map { Formatters.date($0, style: .absolute) }].compactMap { $0 }
        return parts.isEmpty ? L10n.string("Quarantined") : parts.joined(separator: ", ")
    }
}

extension Tri {
    init(_ on: Bool) { self = on ? .on : .off }

    /// A click on an unchecked or mixed box checks it (applies to every item); a click on a checked box unchecks it.
    var afterClick: Bool { self != .on }
}

/// AppKit checkbox with a real mixed state (§5.8 multiple selection; P1-38's Compare headers). The model owns the
/// state: a click reports the new value and the box shows whatever the model says next.
struct TriCheckbox: NSViewRepresentable {
    let title: String
    let state: Tri
    var isEnabled = true
    let onToggle: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        context.coordinator.state = state
        button.title = title
        button.isEnabled = isEnabled
        button.state = switch state {
        case .on: .on
        case .off: .off
        case .mixed: .mixed
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onToggle: (Bool) -> Void
        var state: Tri = .off

        init(onToggle: @escaping (Bool) -> Void) { self.onToggle = onToggle }

        @objc func clicked(_ sender: NSButton) {
            let on = state.afterClick
            sender.state = on ? .on : .off     // AppKit would cycle into mixed; the model decides instead
            onToggle(on)
        }
    }
}
```

- [ ] **Step 6: Implement the view model**

```swift
// Sources/UI/Properties/PropertiesViewModel.swift
import Foundation
import CoreGraphics
import Darwin
import UniformTypeIdentifiers
import Core
import MacxFS

/// What a Properties window shows (§5.8): one or more items, or a volume.
enum PropertiesSubject: Hashable {
    case items([URL])
    case volume(VolumeInfo)
}

/// Questions the view model asks its window before acting.
enum PropertiesConfirmation {
    case applyToEnclosed(name: String)
    case rename(RenamePrompt)
}

/// Name checks for the Properties name field (§5.6 rules). The duplicate test asks the file system on a read lane
/// (S5-C3), so hidden items count too (Review Focus 2).
enum NameAvailability {
    static func validate(_ proposed: String, original: String, in directory: URL, caseSensitive: Bool,
                         lanes: LanePool, volume: VolumeID) async -> NameValidation {
        let result = try? await lanes.perform(on: volume) { _ in
            NameRules.validate(proposed, original: original, caseSensitive: caseSensitive) { name in
                var st = Darwin.stat()
                return lstat(directory.appending(path: name).path, &st) == 0
            }
        }
        // An unresponsive lane can't answer: let the rename job report the real outcome.
        return result ?? .ok(warnings: [])
    }
}

/// State of one Properties window. Every read runs on a lane; every edit is a job (undoable, §6.6) whose failure
/// shows `inlineError` and reverts the control by reloading what is on disk.
@MainActor @Observable
final class PropertiesViewModel {
    enum Content: Equatable {
        case loading
        case item(ItemProperties)
        case items(MultiProperties)
        case volume(VolumeProperties)
        case failed(String)
    }

    private(set) var subject: PropertiesSubject
    private(set) var content: Content = .loading
    private(set) var folderCount: CountProgress?
    private(set) var defaultApp: AppInfo?
    var nameDraft = ""
    private(set) var nameProblem: String?
    private(set) var inlineError: String?
    private(set) var isApplying = false
    var icon: CGImage?

    let environment: CoreEnvironment
    /// The window's number; jobs carry it so P1-38's router answers their errors inline.
    @ObservationIgnored var origin: OriginID?
    @ObservationIgnored var confirm: @MainActor (PropertiesConfirmation) async -> Bool = { _ in false }
    @ObservationIgnored var perform: @MainActor (JobRequest) async -> JobOutcome
    /// A rename (also by undo or another window) moved our items: the window updates its key and title.
    @ObservationIgnored var onSubjectChanged: (@MainActor (PropertiesSubject) -> Void)?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var finishedToken: ObserverToken?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadedName: String?

    init(subject: PropertiesSubject, environment: CoreEnvironment) {
        self.subject = subject
        self.environment = environment
        let operations = environment.operations
        perform = { request in await operations.perform(request) }
        finishedToken = operations.onFinished { [weak self] _, outcome in self?.jobFinished(outcome) }
    }

    var urls: [URL] {
        if case .items(let urls) = subject { urls } else { [] }
    }

    var title: String {
        switch subject {
        case .volume(let volume): String(format: L10n.string("%@ Properties"), volume.name)
        case .items(let urls) where urls.count == 1: String(format: L10n.string("%@ Properties"), urls[0].lastPathComponent)
        case .items(let urls): String(format: L10n.string("%lld Items Properties"), urls.count)
        }
    }

    var canEditPermissions: Bool {
        if case .item(let item) = content { item.isOwnedByCurrentUser } else { false }
    }

    /// §5.8: single documents only; folders and applications have no Opens with.
    var showsOpensWith: Bool {
        guard case .item(let item) = content, item.kind != .directory else { return false }
        return !(UTType(item.typeIdentifier)?.conforms(to: .application) ?? false)
    }

    static func permissionsNote(isOwner: Bool) -> String? {
        isOwner ? nil : L10n.string("You can't change permissions because you aren't the owner.")
    }

    // MARK: loading

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let lanes = environment.lanes
        let loaded: Content
        switch subject {
        case .volume(let info):
            loaded = .volume(await PropertiesLoader.loadVolume(info, scanner: SystemVolumeScanner(), lanes: lanes))
        case .items(let urls) where urls.count == 1:
            do { loaded = .item(try await PropertiesLoader.load(urls[0], lanes: lanes, volume: volumeID(urls[0]))) }
            catch { loaded = .failed(Self.loadError(error, name: urls[0].lastPathComponent)) }
        case .items(let urls):
            guard let first = urls.first else { return }
            do { loaded = .items(try await PropertiesLoader.loadMany(urls, lanes: lanes, volume: volumeID(first))) }
            catch { loaded = .failed(Self.loadError(error, name: first.lastPathComponent)) }
        }
        guard generation == loadGeneration else { return }     // a newer load won
        content = loaded
        guard case .item(let item) = loaded else { return }
        if nameDraft == (loadedName ?? "") { nameDraft = item.name }   // don't clobber a name being typed
        loadedName = item.name
        if item.kind == .directory {
            if folderCount == nil { startCount(item.url) }
        } else if showsOpensWith {
            await reloadDefaultApp()
        }
    }

    func reloadDefaultApp() async {
        guard case .item(let item) = content else { return }
        defaultApp = await environment.launchServices.provider.defaultApplication(toOpen: item.url)
    }

    private func startCount(_ url: URL) {
        countTask?.cancel()
        let stream = FolderCounter.count(url, lanes: environment.lanes, volume: volumeID(url))
        countTask = Task { [weak self] in
            for await progress in stream {
                guard let self, !Task.isCancelled else { return }
                self.folderCount = progress
            }
        }
    }

    private func volumeID(_ url: URL) -> VolumeID {
        environment.volumes.volume(for: url)?.id ?? .unknown
    }

    static func loadError(_ error: any Error, name: String) -> String {
        let code: Int32 = if let failure = error as? ReadFailure { failure.code }
            else if (error as NSError).domain == NSPOSIXErrorDomain { Int32((error as NSError).code) }
            else { 0 }
        return code == ENOENT ? ErrorText.jobError(.sourceGone, name: name) : String(format: L10n.string("'%@' couldn't be read."), name)
    }

    /// Follows renames and moves of our items (inline, from another window, or by undo) and reloads when a finished
    /// job touched them, so the controls always show what is on disk.
    private func jobFinished(_ outcome: JobOutcome) {
        guard case .items(let current) = subject else { return }
        var mapped = current
        var touched = false
        for action in outcome.record.actions {
            switch action {
            case .renamed(let from, let to, _), .moved(let from, let to, _):
                if let index = mapped.firstIndex(of: from.standardizedFileURL) {
                    mapped[index] = to.standardizedFileURL
                    touched = true
                }
            case .attributesChanged(let url, _, _), .modeChanged(let url, _, _):
                if mapped.contains(url.standardizedFileURL) { touched = true }
            default:
                break
            }
        }
        if mapped != current {
            subject = .items(mapped)
            onSubjectChanged?(subject)
        }
        if touched { Task { await self.load() } }
    }

    // MARK: edits (§5.8: apply immediately, undoable, inline error + revert)

    func setLocked(_ on: Bool) async {
        await applyAttribute(.locked(on), item: { $0.isLocked = on }, multi: { $0.locked = Tri(on) })
    }

    func setHidden(_ on: Bool) async {
        await applyAttribute(.hidden(on), item: { $0.isHidden = on }, multi: { $0.hidden = Tri(on) })
    }

    func setExtensionHidden(_ on: Bool) async {
        await applyAttribute(.extensionHidden(on), item: { $0.isExtensionHidden = on }, multi: { $0.extensionHidden = Tri(on) })
    }

    func removeQuarantine() async {
        await applyAttribute(.removeQuarantine, item: { $0.quarantine = nil }, multi: { _ in })
    }

    func setAccess(_ access: PermissionAccess, for who: PermissionClass) async {
        guard case .item(var item) = content, item.isOwnedByCurrentUser else { return }
        let mode = PermissionModel.applying(access, who, to: item.mode)
        guard mode != item.mode else { return }
        let before = content
        item.mode = mode
        content = .item(item)
        await run(.setAttributes(urls, .permissions(mode & 0o7777)), revertTo: before)
    }

    /// Folders: confirmed, then one chmodRecursive job with the folder's rwx bits (undo restores each item's mode).
    func applyPermissionsToEnclosed() async {
        guard case .item(let item) = content, item.kind == .directory, item.isOwnedByCurrentUser,
              await confirm(.applyToEnclosed(name: item.name)) else { return }
        await run(.chmodRecursive(item.url, ModeChange(mode: item.mode & 0o777)), revertTo: content)
    }

    /// Return in the name field. False when the name is refused (problem shown under the field) or declined.
    @discardableResult
    func commitName() async -> Bool {
        guard case .item(let item) = content else { return false }
        let proposed = nameDraft
        guard proposed != item.name else { nameProblem = nil; return true }
        let caseSensitive = environment.volumes.volume(for: item.url)?.capabilities.caseSensitive ?? false
        let validation = await NameAvailability.validate(proposed, original: item.name, in: item.url.deletingLastPathComponent(),
                                                         caseSensitive: caseSensitive, lanes: environment.lanes,
                                                         volume: volumeID(item.url))
        switch validation {
        case .invalid(let problem):
            nameProblem = ErrorText.renameProblem(problem, name: proposed)
            return false
        case .ok(let warnings):
            nameProblem = nil
            for warning in warnings {
                let prompt: RenamePrompt = switch warning {
                case .extensionChanged(let from, let to): .extensionChanged(from: from, to: to)
                case .becomesHidden: .becomesHidden
                }
                guard await confirm(.rename(prompt)) else { nameDraft = item.name; return false }
            }
        }
        return await run(.rename(item.url, to: proposed), revertTo: content) { [weak self] in self?.nameDraft = item.name }
    }

    /// Esc in the name field.
    func revertName() {
        guard case .item(let item) = content else { return }
        nameDraft = item.name
        nameProblem = nil
    }

    func eject() async -> Bool {
        guard case .volume(let info) = subject else { return false }
        do throws(EjectError) {
            try await environment.ejectCoordinator.eject(info)
            return true
        } catch {
            switch error {
            case .busy(let processes) where !processes.isEmpty:
                inlineError = String(format: L10n.string("'%@' can't be ejected because it is in use by %@."), info.name,
                                     ListFormatter.localizedString(byJoining: processes))
            default:
                inlineError = String(format: L10n.string("'%@' couldn't be ejected."), info.name)
            }
            return false
        }
    }

    func close() {
        countTask?.cancel()
        countTask = nil
        finishedToken?.cancel()
        finishedToken = nil
    }

    // MARK: private

    private func applyAttribute(_ edit: AttributeEdit, item change: (inout ItemProperties) -> Void,
                                multi changeAll: (inout MultiProperties) -> Void) async {
        let before = content
        switch content {
        case .item(var item): change(&item); content = .item(item)
        case .items(var multi): changeAll(&multi); content = .items(multi)
        default: return
        }
        await run(.setAttributes(urls, edit), revertTo: before)
    }

    /// Runs one job for the window. A skipped item with a reason (the router answers Properties errors with Skip,
    /// P1-38) becomes the inline error; the control reverts and the window reloads from disk either way.
    @discardableResult
    private func run(_ kind: JobKind, revertTo before: Content, onFailure: (() -> Void)? = nil) async -> Bool {
        isApplying = true
        inlineError = nil
        defer { isApplying = false }
        let outcome = await perform(JobRequest(kind, origin: origin))
        var succeeded = !outcome.wasCancelled
        if let failed = outcome.skipped.first(where: { $0.reason != nil }), let reason = failed.reason {
            inlineError = ErrorText.jobError(reason, name: failed.url.lastPathComponent, verb: outcome.record.verb)
            succeeded = false
        }
        if !succeeded {
            content = before
            onFailure?()
        }
        await load()
        return succeeded
    }
}
```

- [ ] **Step 7: Implement the SwiftUI view**

```swift
// Sources/UI/Properties/PropertiesView.swift
import SwiftUI
import AppKit
import Core
import MacxFS

/// Window-level actions the view can't do itself.
struct PropertiesActions {
    var reveal: @MainActor (URL) -> Void
    var changeDefaultApp: @MainActor (_ allOfType: Bool) -> Void
    var eject: @MainActor () -> Void
}

/// §5.8 layout: tabs for one item, a single form for several items or a volume. Error text sits under the content.
struct PropertiesView: View {
    @Bindable var model: PropertiesViewModel
    let actions: PropertiesActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.content {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            case .failed(let text):
                Text(verbatim: text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            case .item(let item):
                TabView {
                    GeneralTab(model: model, item: item, actions: actions).tabItem { Text(verbatim: L10n.string("General")) }
                    PermissionsTab(model: model, item: item).tabItem { Text(verbatim: L10n.string("Permissions")) }
                    if model.showsOpensWith {
                        OpensWithTab(model: model, actions: actions).tabItem { Text(verbatim: L10n.string("Opens with")) }
                    }
                    DetailsTab(model: model, item: item).tabItem { Text(verbatim: L10n.string("Details")) }
                }
            case .items(let multi):
                MultiItemsForm(model: model, multi: multi)
            case .volume(let volume):
                VolumeForm(volume: volume, actions: actions)
            }
            if let error = model.inlineError {
                Text(verbatim: error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("macx.properties.error")
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

private struct GeneralTab: View {
    @Bindable var model: PropertiesViewModel
    let item: ItemProperties
    let actions: PropertiesActions

    var body: some View {
        Form {
            HStack(alignment: .top, spacing: 12) {
                if let icon = model.icon {
                    Image(decorative: icon, scale: 2).resizable().frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L10n.string("Name"), text: $model.nameDraft)
                        .onSubmit { Task { await model.commitName() } }
                        .onExitCommand { model.revertName() }
                        .accessibilityIdentifier("macx.properties.name")
                    if let problem = model.nameProblem {
                        Text(verbatim: problem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            LabeledContent(L10n.string("Kind"), value: item.kindDescription)
            LabeledContent(L10n.string("Location")) {
                HStack {
                    Text(verbatim: item.url.deletingLastPathComponent().path)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Button(L10n.string("Reveal")) { actions.reveal(item.url) }
                }
            }
            if item.kind == .directory {
                LabeledContent(L10n.string("Size"), value: model.folderCount.map { PropertiesFormat.size($0.bytes) } ?? L10n.string("Counting…"))
                LabeledContent(L10n.string("Contains"), value: model.folderCount.map {
                    PropertiesFormat.contains(files: $0.files, folders: $0.folders, finished: $0.finished)
                } ?? L10n.string("Counting…"))
            } else {
                LabeledContent(L10n.string("Size"), value: PropertiesFormat.size(item.logicalSize))
                LabeledContent(L10n.string("Size on disk"), value: PropertiesFormat.size(item.physicalSize))
            }
            LabeledContent(L10n.string("Created"), value: PropertiesFormat.date(item.created))
            LabeledContent(L10n.string("Modified"), value: PropertiesFormat.date(item.modified))
            LabeledContent(L10n.string("Last opened"), value: PropertiesFormat.date(item.lastOpened))
            LabeledContent(L10n.string("Attributes")) {
                VStack(alignment: .leading, spacing: 4) {
                    TriCheckbox(title: L10n.string("Read-only (Locked)"), state: Tri(item.isLocked)) { on in Task { await model.setLocked(on) } }
                    TriCheckbox(title: L10n.string("Hidden"), state: Tri(item.isHidden)) { on in Task { await model.setHidden(on) } }
                    TriCheckbox(title: L10n.string("Hide extension"), state: Tri(item.isExtensionHidden)) { on in
                        Task { await model.setExtensionHidden(on) }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(8)
    }
}

private struct PermissionsTab: View {
    let model: PropertiesViewModel
    let item: ItemProperties

    var body: some View {
        Form {
            ForEach(PermissionClass.allCases, id: \.self) { who in
                Picker(PropertiesFormat.who(who, owner: item.ownerName, group: item.groupName), selection: Binding(
                    get: { PermissionModel.access(item.mode, who) },
                    set: { access in Task { await model.setAccess(access, for: who) } })) {
                    ForEach(PermissionAccess.allCases, id: \.self) { access in
                        Text(verbatim: PropertiesFormat.access(access)).tag(access)
                    }
                }
                .disabled(!model.canEditPermissions)
            }
            if item.kind == .file {
                LabeledContent(L10n.string("Executable"),
                               value: PermissionModel.isExecutable(item.mode) ? L10n.string("Yes") : L10n.string("No"))
            }
            if let note = PropertiesViewModel.permissionsNote(isOwner: item.isOwnedByCurrentUser) {
                Text(verbatim: note).font(.caption).foregroundStyle(.secondary)
            }
            if item.kind == .directory {
                Button(L10n.string("Apply to enclosed items…")) { Task { await model.applyPermissionsToEnclosed() } }
                    .disabled(!model.canEditPermissions)
            }
            if !item.aclEntries.isEmpty {
                Section(L10n.string("Access control list")) {
                    ForEach(item.aclEntries, id: \.self) { entry in
                        Text(verbatim: entry).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(8)
    }
}

private struct OpensWithTab: View {
    let model: PropertiesViewModel
    let actions: PropertiesActions

    var body: some View {
        Form {
            LabeledContent(L10n.string("Opens with"), value: model.defaultApp?.name ?? L10n.string("No default app"))
            HStack {
                Button(L10n.string("Change…")) { actions.changeDefaultApp(false) }
                Button(L10n.string("Change All…")) { actions.changeDefaultApp(true) }
            }
        }
        .formStyle(.columns)
        .padding(8)
    }
}

private struct DetailsTab: View {
    let model: PropertiesViewModel
    let item: ItemProperties

    var body: some View {
        Form {
            LabeledContent(L10n.string("Type identifier"), value: item.typeIdentifier)
            LabeledContent(L10n.string("Path")) { Text(verbatim: item.url.path).textSelection(.enabled).lineLimit(3) }
            LabeledContent(L10n.string("Inode"), value: String(item.inode))
            LabeledContent(L10n.string("Volume"), value: item.volumeName)
            if !item.whereFroms.isEmpty {
                LabeledContent(L10n.string("Where from")) {
                    VStack(alignment: .leading) {
                        ForEach(item.whereFroms, id: \.self) { url in
                            Text(verbatim: url).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
            }
            if let quarantine = item.quarantine {
                LabeledContent(L10n.string("Quarantine")) {
                    HStack {
                        Text(verbatim: PropertiesFormat.quarantine(agent: quarantine.agentName, date: quarantine.date))
                        Button(L10n.string("Remove")) { Task { await model.removeQuarantine() } }
                    }
                }
            }
            if !item.xattrs.isEmpty {
                LabeledContent(L10n.string("Extended attributes")) {
                    VStack(alignment: .leading) {
                        ForEach(item.xattrs, id: \.name) { xattr in
                            Text(verbatim: "\(xattr.name) (\(Formatters.bytes(Int64(xattr.size))))").font(.caption.monospaced())
                        }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(8)
    }
}

private struct MultiItemsForm: View {
    let model: PropertiesViewModel
    let multi: MultiProperties

    var body: some View {
        Form {
            LabeledContent(L10n.string("Selection"), value: PropertiesFormat.items(count: multi.count, files: multi.files, folders: multi.folders))
            LabeledContent(L10n.string("Total size"), value: PropertiesFormat.size(multi.totalSize))
            LabeledContent(L10n.string("Attributes")) {
                VStack(alignment: .leading, spacing: 4) {
                    TriCheckbox(title: L10n.string("Read-only (Locked)"), state: multi.locked) { on in Task { await model.setLocked(on) } }
                    TriCheckbox(title: L10n.string("Hidden"), state: multi.hidden) { on in Task { await model.setHidden(on) } }
                    TriCheckbox(title: L10n.string("Hide extension"), state: multi.extensionHidden) { on in
                        Task { await model.setExtensionHidden(on) }
                    }
                }
            }
        }
        .formStyle(.columns)
    }
}

private struct VolumeForm: View {
    let volume: VolumeProperties
    let actions: PropertiesActions

    var body: some View {
        Form {
            LabeledContent(L10n.string("Format"), value: volume.volume.format)
            LabeledContent(L10n.string("Capacity"), value: PropertiesFormat.size(volume.capacity))
            LabeledContent(L10n.string("Used"), value: PropertiesFormat.size(volume.used))
            LabeledContent(L10n.string("Free"), value: PropertiesFormat.size(volume.available))
            if let usage = PropertiesFormat.usage(capacity: volume.capacity, available: volume.available) {
                ProgressView(value: usage).accessibilityLabel(L10n.string("Used space"))
            }
            LabeledContent(L10n.string("Mount point")) { Text(verbatim: volume.volume.mountPoint.path).textSelection(.enabled) }
            if volume.volume.isEjectable {
                Button(L10n.string("Eject")) { actions.eject() }
            }
        }
        .formStyle(.columns)
    }
}
```

- [ ] **Step 8: Implement the window controller and wire ⌘I, ⌥Return and Change…**

```swift
// Sources/UI/Properties/PropertiesWindowController.swift
import AppKit
import SwiftUI
import Core
import MacxFS

/// Non-modal Properties window (§5.8). One per selection set (a second ⌘I on the same set focuses it), undo through
/// the app-wide FileOpUndoStack (§6.6), edits as jobs whose errors are shown inline.
@MainActor
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private struct Key: Hashable {
        enum Subject: Hashable { case items(Set<URL>), volume(VolumeID) }
        let context: ObjectIdentifier
        let subject: Subject
    }

    private static var registry: [Key: PropertiesWindowController] = [:]
    private static var cascadePoint = NSPoint.zero

    let context: UIContext
    let model: PropertiesViewModel
    private var key: Key
    private var fieldEditorUndo: UndoManager?

    static func show(for urls: [URL], context: UIContext) {
        controller(for: .items(urls), context: context, activate: true)
    }

    static func show(volume: VolumeInfo, context: UIContext) {
        controller(for: .volume(volume), context: context, activate: true)
    }

    /// The window for `subject`, created and loaded on first use. `activate: false` never orders it front (tests, S5-C7).
    @discardableResult
    static func controller(for subject: PropertiesSubject, context: UIContext, activate: Bool) -> PropertiesWindowController? {
        let subject = normalized(subject)
        guard let key = key(for: subject, context: context) else { return nil }
        let controller: PropertiesWindowController
        if let existing = registry[key] {
            controller = existing
        } else {
            controller = PropertiesWindowController(subject: subject, context: context, key: key)
            registry[key] = controller
            Task { await controller.loadContent() }
        }
        if activate {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    static func openControllers(for context: UIContext) -> [PropertiesWindowController] {
        registry.filter { $0.key.context == ObjectIdentifier(context) }.map(\.value)
    }

    static func closeAll(for context: UIContext) {
        for controller in openControllers(for: context) { controller.close() }
    }

    /// P1-38's router answers job errors from these windows with Skip; the window shows them inline (§5.8).
    static func answersErrorsInline(_ origin: OriginID) -> Bool {
        registry.values.contains { $0.model.origin == origin }
    }

    private static func normalized(_ subject: PropertiesSubject) -> PropertiesSubject {
        switch subject {
        case .items(let urls): .items(urls.map(\.standardizedFileURL))
        case .volume: subject
        }
    }

    private static func key(for subject: PropertiesSubject, context: UIContext) -> Key? {
        switch subject {
        case .items(let urls) where urls.isEmpty: nil
        case .items(let urls): Key(context: ObjectIdentifier(context), subject: .items(Set(urls)))
        case .volume(let volume): Key(context: ObjectIdentifier(context), subject: .volume(volume.id))
        }
    }

    private init(subject: PropertiesSubject, context: UIContext, key: Key) {
        self.context = context
        self.key = key
        model = PropertiesViewModel(subject: subject, environment: context.environment)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(AXID.propertiesWindow)
        window.setAccessibilityIdentifier(AXID.propertiesWindow)
        window.title = model.title
        super.init(window: window)
        window.delegate = self
        model.origin = OriginID(raw: window.windowNumber)
        model.confirm = { [weak self] confirmation in await self?.confirm(confirmation) ?? false }
        model.onSubjectChanged = { [weak self] subject in self?.subjectChanged(subject) }
        let hosting = NSHostingController(rootView: PropertiesView(model: model, actions: makeActions()))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.center()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
    }

    required init?(coder: NSCoder) { fatalError("PropertiesWindowController is created in code") }

    func loadContent() async {
        await model.load()
        updateIcon()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model.close()
        if Self.registry[key] === self { Self.registry[key] = nil }
    }

    /// §6.6: the app-wide stack, or a per-edit manager while the name field is being edited.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            if fieldEditorUndo == nil { fieldEditorUndo = context.environment.undo.makeFieldEditorUndoManager() }
            return fieldEditorUndo
        }
        fieldEditorUndo = nil
        return context.environment.undo.undoManager
    }

    /// ⌘W while a Properties window is key (the browser's handler isn't in this window's responder chain).
    @objc func macx_closeWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    // MARK: private

    private func subjectChanged(_ subject: PropertiesSubject) {
        if Self.registry[key] === self { Self.registry[key] = nil }
        if let newKey = Self.key(for: subject, context: context) {
            key = newKey
            Self.registry[newKey] = self
        }
        window?.title = model.title
        updateIcon()
    }

    /// Tier 0 type icon at once, then the per-file icon from a lane (S5-C3).
    private func updateIcon() {
        guard case .item(let item) = model.content else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        let index = context.environment.types.index(forExtension: Substring(item.url.pathExtension),
                                                    isDirectory: item.kind == .directory || item.kind == .package)
        model.icon = context.icons.typeIcon(index, points: 64, scale: scale)
        context.icons.fileIcon(for: item.url, rowID: .name(item.url.path), points: 64, scale: scale) { [weak self] image in
            self?.model.icon = image
        }
    }

    private func makeActions() -> PropertiesActions {
        PropertiesActions(
            reveal: { [weak self] url in
                _ = self?.context.windows.openWindow(at: url.deletingLastPathComponent(), selecting: url.lastPathComponent)
            },
            changeDefaultApp: { [weak self] allOfType in self?.changeDefaultApp(allOfType: allOfType) },
            eject: { [weak self] in self?.eject() })
    }

    private func changeDefaultApp(allOfType: Bool) {
        guard case .item(let item) = model.content, let window else { return }
        Task {
            await DefaultAppSheet.present(for: item.url, on: window, context: context, alwaysChecked: allOfType, opensFile: false)
            await model.reloadDefaultApp()
        }
    }

    private func eject() {
        Task {
            if await model.eject() { close() }
        }
    }

    private func confirm(_ confirmation: PropertiesConfirmation) async -> Bool {
        switch confirmation {
        case .rename(let prompt):
            return await RenamePrompts.present(prompt, on: window)
        case .applyToEnclosed(let name):
            let alert = NSAlert()
            alert.messageText = String(format: L10n.string("Apply these permissions to all items inside '%@'?"), name)
            alert.informativeText = L10n.string("You can undo this with Edit › Undo.")
            alert.addButton(withTitle: L10n.string("Apply"))
            alert.addButton(withTitle: L10n.string("Cancel"))
            guard let window else { return alert.runModal() == .alertFirstButtonReturn }
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
    }
}
```

In `Sources/UI/Commands/FileCommandController.swift`:

Change the pending set (P1-38 empties it):

```swift
    /// Commands whose UI arrives in a later task (P1-38 removes .showOperations).
    static let pendingCommands: Set<Command> = [.showOperations]
```

Replace the P1-35 placeholder `showProperties(_:)` with:

```swift
    /// ⌘I / ⌥Return / command bar / context menus / the empty state's Properties button (§5.8).
    func showProperties(_ target: CommandTarget) {
        switch Self.propertiesSubject(for: target, volumes: environment.volumes.list) {
        case .items(let urls)?: PropertiesWindowController.show(for: urls, context: context)
        case .volume(let volume)?: PropertiesWindowController.show(volume: volume, context: context)
        case nil: NSSound.beep()
        }
    }

    /// The selection (or, with nothing selected, the current folder); sidebar rows give their folder or volume.
    /// A single item that is a volume's mount point shows volume properties.
    static func propertiesSubject(for target: CommandTarget, volumes: [VolumeInfo]) -> PropertiesSubject? {
        let urls: [URL]
        switch target {
        case .volume(let volume): return .volume(volume)
        case .contentSelection(let folder): urls = folder.selectedURLs.isEmpty ? [folder.directory] : folder.selectedURLs
        case .currentFolder(let folder): urls = [folder.directory]
        case .folder(let url), .location(let url): urls = [url]
        case .favorite(let favorite):
            guard let url = favorite.url else { return nil }
            urls = [url]
        }
        if urls.count == 1, let volume = volumes.first(where: { $0.mountPoint.standardizedFileURL.path == urls[0].standardizedFileURL.path }) {
            return .volume(volume)
        }
        return .items(urls)
    }
```

In `Sources/UI/OpenWith/DefaultAppSheet.swift`:

Add a stored property after `private let always: NSButton`:

```swift
    private let opensFile: Bool
```

Replace both `present` functions and the first line of `init` with:

```swift
    static func present(for file: URL, on window: NSWindow, context: UIContext) async {
        await present(for: file, on: window, context: context, alwaysChecked: false, opensFile: true)
    }

    /// Properties' Change All… opens the sheet with the checkbox already on (P1-37).
    static func present(for file: URL, on window: NSWindow, context: UIContext, alwaysChecked: Bool) async {
        await present(for: file, on: window, context: context, alwaysChecked: alwaysChecked, opensFile: true)
    }

    /// `opensFile: false` (Properties' Change… / Change All…): set the default only; the checkbox means "all files
    /// of this type" (§5.8).
    static func present(for file: URL, on window: NSWindow, context: UIContext, alwaysChecked: Bool, opensFile: Bool) async {
        await DefaultAppSheet(file: file, context: context, alwaysChecked: alwaysChecked, opensFile: opensFile).run(on: window)
    }

    private init(file: URL, context: UIContext, alwaysChecked: Bool, opensFile: Bool) {
        self.opensFile = opensFile
```

(the rest of `init` stays). In `run(on:)`, replace the `do { … } catch { … }` block with:

```swift
        let provider = context.environment.launchServices.provider
        do {
            if opensFile {
                try await DefaultAppChoice.apply(app: chosen.url, file: file, always: always.state == .on, provider: provider)
            } else {
                try await DefaultAppChoice.setDefault(app: chosen.url, file: file, allOfType: always.state == .on, provider: provider)
            }
            context.environment.launchServices.invalidate(file: file)
        } catch {
            let alert = NSAlert()
            alert.messageText = opensFile
                ? String(format: L10n.string("'%@' couldn't be opened with %@."), file.lastPathComponent, chosen.name)
                : String(format: L10n.string("The default app for '%@' couldn't be changed."), file.lastPathComponent)
            alert.informativeText = error.localizedDescription
            _ = await alert.beginSheetModal(for: window)
        }
```

Add to `enum DefaultAppChoice`:

```swift
    /// Properties (§5.8): the per-file default, or with `allOfType` the content-type default first, then the per-file
    /// one (so an older per-file override can't keep winning). Opens nothing.
    static func setDefault(app: URL, file: URL, allOfType: Bool, provider: any LaunchServicesProviding) async throws {
        if allOfType { try await provider.setDefaultApplication(app, forContentTypeOf: file) }
        try await provider.setDefaultApplication(app, forFile: file)
    }
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `swift test --filter 'UITests\.PropertiesViewModelTests' 2>&1 | tail -5`
Expected: `Executed 16 tests, with 0 failures` (with no GUI session: `with 1 test skipped and 0 failures`).

Run: `swift test --filter 'UITests\.(FileCommandTests|ContextMenuTests|EmptyStateTests)' 2>&1 | tail -3`
Expected: `with 0 failures` (the harness change keeps every earlier test green).

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` with no warnings.

- [ ] **Step 10: Verify in the app (sandbox only)**

With the manual run recipe, before launching also run `chflags uchg "$SANDBOX/root/file5.txt"` and `xattr -w com.apple.quarantine "0081;65f0c3a1;Safari;" "$SANDBOX/root/file3.txt"` (both inside the sandbox). Before the recipe's `rm -rf`, run `chflags -R nouchg "$SANDBOX"`.
1. Select `file1.txt` and press ⌘I: a Properties window opens with the icon, name, Kind, Location, `1 byte (1 bytes)`, dates and the three checkboxes. Press ⌘I again with the same selection: the same window comes to the front (no second window).
2. Type `renamed.txt` in the name field and press Return: the list shows `renamed.txt` and the title follows. Type `file2.txt` and press Return: "The name 'file2.txt' is already taken." appears under the field. Press Esc: the field reverts.
3. Tick Hidden: the row disappears from the list (Show Hidden off). Press ⌘Z with the Properties window key: the file is visible again and the box unticks.
4. Select `file5.txt` (locked), open Properties, and change Everyone to No access: "'file5.txt' is locked." appears in red and the popup snaps back. No dialog appears.
5. Select `Sub Folder` and press ⌥Return: Contains counts up and settles on `0 files, 1 folders`. Permissions › Apply to enclosed items… asks first.
6. Select `file3.txt`, open the Details tab: Quarantine shows Safari and a date; Remove clears it (`xattr -l "$SANDBOX/root/file3.txt"` prints nothing).
7. Select `file1.txt`…`file4.txt` and press ⌘I: "4 items (4 files, 0 folders)", the total size, and no Name field or Opens with tab.
8. Right-click the boot volume under Locations › Properties: format, capacity, used and free with a bar, and no Eject button. Never eject anything here.

- [ ] **Step 11: Commit**

```bash
git add Sources/UI/Properties Sources/UI/Operations/ErrorText.swift Sources/UI/Commands/FileCommandController.swift \
  Sources/UI/OpenWith/DefaultAppSheet.swift Sources/UI/Resources/Localizable.xcstrings \
  Tests/UITests/Support/ContentTestHarness.swift Tests/UITests/PropertiesViewModelTests.swift
git commit -m "feat: properties window with inline-error edits as undoable jobs (P1-37)"
```

---

### Task P1-38: Progress and dialogs (router, conflict, compare, error, capsule, Operations panel)

**Spec coverage:** §6.2 in full: jobs under 1 s show nothing; otherwise the status-bar capsule (icon + overall %) opens a popover listing the jobs, each with its title ("Copying 1,204 items from Downloads to Backup"), a progress bar and "x of y", speed, a 60-sample throughput graph, the time remaining, Pause/Resume, Cancel and "More details" with the current file. A job waiting on a question shows a badge, and its dialog is a sheet on the window that started it, or in the Operations panel if that window has closed. §6.4 conflict dialog ("The destination already has a file named 'x'", Replace · Skip · Keep Both · Compare…, "Do this for all remaining conflicts (N)"; folder onto folder: "Merge folders?" with Merge · Keep Both · Skip) and the Compare panel (icon, size, modified date and path side by side with per-item checkboxes, as in Explorer). §6.5 error dialogs (the table's message and exactly its actions, in order; EPERM's "Open Privacy Settings" opens the pane through `ExternalURLOpening` and then retries; the free-space prompt "needs X, Y available" with Continue Anyway / Cancel) and §6.3's "Delete permanently?" fallback for volumes without a Trash. §6.7 Window › Operations opens a standalone `NSPanel` with the same list that stays up when the app is inactive or has no windows. `InteractionRouter` replaces `BasicAlertInteraction` in `InteractionProxy`. Slice Review Focus 5 (closed origin → Operations panel; questions for one host shown one at a time, none lost). Phase 2 compatibility: every "which window shows this sheet" decision goes through `InteractionRouter.hostWindow(for:)`, which P2-05 extends to select the origin tab.

**Files:**
- Create: `Sources/UI/Operations/InteractionRouter.swift`
- Create: `Sources/UI/Operations/ConflictDialog.swift`
- Create: `Sources/UI/Operations/CompareView.swift`
- Create: `Sources/UI/Operations/ErrorDialog.swift`
- Create: `Sources/UI/Operations/OperationsCapsule.swift`
- Create: `Sources/UI/Operations/OperationsListView.swift`
- Create: `Sources/UI/Operations/OperationsPanel.swift`
- Modify: `Sources/UI/App/UIContext.swift` (own `OperationsUI`, install the router, `showOperationsPanel()`)
- Modify: `Sources/UI/Content/ContentViewController.swift` (capsule in the status bar's `operationsSlot`)
- Modify: `Sources/UI/Commands/FileCommandController.swift`, `Sources/UI/Commands/FileCommandController+View.swift` (`.showOperations`)
- Modify: the Window › Operations handler P1-30 added (`Sources/UI/App/AppLifecycle.swift` or `Sources/App/AppDelegate.swift`)
- Modify: `Sources/UI/Support/AXID.swift` (`operationsPanel`)
- Modify: `Tests/UITests/Support/ContentTestHarness.swift` (close the panel in teardown)
- Modify: `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/InteractionRouterTests.swift`, `Tests/UITests/OperationsUITests.swift`

**Interfaces:**
- Consumes (overview §3, exact):
  - `public protocol FileOpInteraction: Sendable { func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution; func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution; func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool; func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool }`; `InteractionProxy.setTarget(_:)`.
  - `ConflictInfo` (`pair`, `isFolderMerge`, `knownRemaining`, `pendingPairs`), `ConflictPair` (`source`, `destination`), `ItemSummary` (`url`, `isDirectory`, `size`, `modified`), `ConflictAction` (`replace`, `skip`, `keepBoth`, `merge`), `ConflictResolution` (`one`, `all`, `perItem([URL: ConflictAction])`, `cancelJob`), `FileOpError` (`kind`, `url`, `destination`), `FileOpErrorKind.allowedResolutions`, `ErrorResolution` (all six), `SpaceShortfall` (`needed`, `available`, `volumeName`).
  - `JobSnapshot` (`id`, `description`, `state`, `progress`, `origin`, `startedAt`), `JobDescription` (`verb`, `itemCount`, `firstItemName`, `sourceFolderName`, `destinationFolderName`), `JobVerb`, `JobState`, `JobProgress` (`itemsDone`, `itemsTotal`, `bytesDone`, `bytesTotal`, `currentItem`, `throughput`, `estimatedRemaining`, `fraction`), `JobID`, `OriginID(raw:)`. S3 P1-17's additive public initializers of `JobSnapshot`, `JobDescription`, `JobProgress`, `ItemSummary`, `ConflictPair`, `ConflictInfo` and `SpaceShortfall` (tests only).
  - `OperationsCenter.jobs`, `.visibleJobs`, `.overallFraction`, `.perform(_:)`; `FileOpQueue.pause(_:)`, `.resume(_:)`, `.cancel(_:)`; `FileOpUndoStack.undoManager`.
  - S4: `UIContext.installInteraction(_:)`, `.interaction`, `.environment`, `.options`, `.icons`, `.windows`; `WindowManager.window(for:) -> BrowserWindowController?`; `BrowserWindowController.origin`, `.window`; `StatusBarView.operationsSlot: NSView`; `AXID.operationsCapsule`, `AXID.conflictButton(_:)`, `AXID.propertiesWindow`; the P1-30 Window › Operations menu entry (`Command.showOperations`).
  - Earlier S5: `ExternalURLOpening`, `ExternalOpeners.opener(for:)`, `RecordingURLOpener.shared`, `SystemSettingsLinks.privacyAllFiles`; `ObservationLoop(_:onChange:)`; `Formatters.bytes(_:)`, `.date(_:style:now:calendar:locale:)`; `IconCache.typeIcon(_:points:scale:)`; `ErrorText.jobError(_:name:verb:)`; `TriCheckbox`; `PropertiesWindowController.answersErrorsInline(_:)`; `FileCommandController.pendingCommands`, `.performWindowCommand(_:target:)`.
- Produces:
  - Overview §3.14, exact: `@MainActor final class InteractionRouter: FileOpInteraction { init(windows: WindowManager) }` (the protocol methods are `nonisolated` and hop to the main actor).
  - Internal: `enum InteractionQuestion: Sendable, Equatable { case conflict(ConflictInfo), error(FileOpError), space(SpaceShortfall), noTrash([URL]); var fallback: InteractionAnswer }`; `enum InteractionAnswer: Sendable, Equatable { case conflict(ConflictResolution), error(ErrorResolution), confirm(Bool) }`; `enum DialogHost: Hashable, Sendable { case window(OriginID), operationsPanel }`; `@MainActor protocol DialogPresenting: AnyObject { func present(_:job:on:) async -> InteractionAnswer? }`; `@MainActor final class SerialGate { enter() async; leave(); waitingCount }`; `InteractionRouter.init(windows:presenter:resolveHost:)`, `.presenter`, `.panelWindow`, `.answersInline`, `.route(_:) -> DialogHost`, `.hostWindow(for:) -> NSWindow?` (P2-05 extends it), `.window(for:)`, `.pendingHosts`, `.revealQuestion(for:)`, `.stopAnswering()` and `.isStopping` (Stop and Quit, Contract note 12).
  - `struct ConflictDialogModel { enum Choice; title; message; choices; applyToAllTitle; defaultAction; init(_:); resolution(_:applyToAll:); static title(_:) }`, `ConflictDialogView`, `@MainActor final class SheetHost { run(_:on:) async -> InteractionAnswer?; finish(_:) }`, `@MainActor final class AppKitDialogPresenter: DialogPresenting { init(icons:opener:types:); handle(_:) -> InteractionAnswer; icon(for:) }`.
  - `struct CompareSelection { struct Row; rows; init(_:); canContinue; allSources; allDestinations; setAllSources(_:); setAllDestinations(_:); resolution; static action(keepSource:keepDestination:isFolderPair:) }`, `CompareView`.
  - `struct DialogButton { title; answer; role; isDefault; sideEffect }`, `struct ErrorDialogModel { context; title; detail; buttons; static error(_:job:locale:); static space(_:job:locale:); static noTrash(_:job:locale:) }`, `ErrorDialogView`.
  - `struct CapsuleState { isVisible; percentText; fraction; isWaiting; accessibilityLabel; static make(visible:overallFraction:) }`, `@MainActor final class OperationsCapsule: NSView { init(context:); button; state; refresh() }`.
  - `enum JobTitle { static title(_:locale:); static subject(_:locale:) }`, `struct JobRowModel` (+ `static eta(_:locale:)`), `enum ThroughputGraph { normalized(_:); points(_:in:); path(_:in:) }`, `struct JobActions`, `OperationsListView`, `JobRowView`.
  - `@MainActor final class OperationsPanelController: NSWindowController { init(context:content:); showPanel(); windowForDialogs() -> NSWindow? }`; `@MainActor final class OperationsUI { init(context:); router; panel; showPanel(); closePanel(); listView() }`.
  - `UIContext.operationsUI`, `public func showOperationsPanel()`; `ContentViewController.operationsCapsule`; `AXID.operationsPanel = "macx.operationsPanel"`.

- [ ] **Step 1: Write the failing router tests (slice Review Focus 5)**

```swift
// Tests/UITests/InteractionRouterTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

/// Stands in for the AppKit dialogs: records what would be shown and lets the test answer.
@MainActor
private final class RecordingPresenter: DialogPresenting {
    struct Shown {
        let question: InteractionQuestion
        let job: JobID
        let window: NSWindow?
    }

    private(set) var shown: [Shown] = []
    private var open: [(id: Int, continuation: CheckedContinuation<InteractionAnswer?, Never>)] = []
    private var nextID = 0
    var openCount: Int { open.count }

    func present(_ question: InteractionQuestion, job: JobSnapshot, on window: NSWindow?) async -> InteractionAnswer? {
        shown.append(Shown(question: question, job: job.id, window: window))
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in open.append((id: id, continuation: continuation)) }
        } onCancel: {
            Task { @MainActor in self.finish(id, nil) }
        }
    }

    /// Answers the oldest open dialog; nil = it went away without an answer.
    func answerOldest(_ answer: InteractionAnswer?) {
        if let first = open.first { finish(first.id, answer) }
    }

    private func finish(_ id: Int, _ answer: InteractionAnswer?) {
        guard let index = open.firstIndex(where: { $0.id == id }) else { return }
        open.remove(at: index).continuation.resume(returning: answer)
    }
}

/// Which fake origins count as open windows.
@MainActor
private final class OpenOrigins {
    var raw: Set<Int> = []
}

@MainActor
final class InteractionRouterTests: XCTestCase {
    private func job(_ origin: OriginID?) -> JobSnapshot {
        JobSnapshot(id: JobID(), description: JobDescription(verb: .copying, itemCount: 2, firstItemName: "a.txt",
                                                             sourceFolderName: "src", destinationFolderName: "dst"),
                    state: .waitingForUser, progress: .zero, origin: origin, startedAt: .now)
    }

    private func conflict(_ h: ContentTestHarness) -> ConflictInfo {
        let pair = ConflictPair(source: ItemSummary(url: h.url("src/a.txt"), isDirectory: false, size: 1, modified: Date()),
                                destination: ItemSummary(url: h.url("dst/a.txt"), isDirectory: false, size: 2, modified: Date()))
        return ConflictInfo(pair: pair, isFolderMerge: false, knownRemaining: 1, pendingPairs: [pair])
    }

    private func error(_ h: ContentTestHarness, _ kind: FileOpErrorKind) -> FileOpError {
        FileOpError(kind: kind, url: h.url("a.txt"))   // a value only; nothing is created
    }

    /// A router whose hosts are fake: an origin is an open window unless `open` says otherwise.
    private func router(_ h: ContentTestHarness, _ presenter: RecordingPresenter, open: OpenOrigins? = nil) -> InteractionRouter {
        let router = InteractionRouter(windows: h.context.windows, presenter: presenter, resolveHost: { origin in
            guard let origin, open.map({ $0.raw.contains(origin.raw) }) ?? true else { return .operationsPanel }
            return .window(origin)
        })
        router.answersInline = { _ in false }
        return router
    }

    func testConcurrentQuestionsAreSerializedPerHost() async throws {   // slice Review Focus 5
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        let origin = OriginID(raw: 7)
        let inUse = error(h, .inUse), gone = error(h, .sourceGone)
        let jobA = job(origin), jobB = job(origin)
        let first = Task { await r.resolveError(inUse, job: jobA) }
        let second = Task { await r.resolveError(gone, job: jobB) }
        try await h.waitUntil("one dialog") { presenter.shown.count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(presenter.shown.count, 1, "the second question waits: one dialog per host at a time")
        let firstAsked = presenter.shown[0].question
        presenter.answerOldest(.error(.retry))
        try await h.waitUntil("second dialog") { presenter.shown.count == 2 }
        presenter.answerOldest(.error(.skip))
        let answerA = await first.value
        let answerB = await second.value
        let inAskOrder = firstAsked == .error(inUse) ? [answerA, answerB] : [answerB, answerA]
        XCTAssertEqual(inAskOrder, [.retry, .skip], "no answer lost or swapped")
        XCTAssertTrue(r.pendingHosts.isEmpty)
    }

    func testQuestionsForDifferentHostsAreShownTogether() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        let e = error(h, .inUse)
        let job1 = job(OriginID(raw: 1)), job2 = job(OriginID(raw: 2))
        let a = Task { await r.resolveError(e, job: job1) }
        let b = Task { await r.resolveError(e, job: job2) }
        try await h.waitUntil("both dialogs") { presenter.shown.count == 2 }
        XCTAssertEqual(Set(r.pendingHosts.values), [.window(OriginID(raw: 1)), .window(OriginID(raw: 2))])
        presenter.answerOldest(.error(.skip))
        presenter.answerOldest(.error(.cancel))
        let answers = [await a.value, await b.value]
        XCTAssertEqual(answers.sorted { "\($0)" < "\($1)" }, [.cancel, .skip])
    }

    func testQuestionWithoutOriginGoesToOperationsPanel() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = InteractionRouter(windows: h.context.windows, presenter: presenter)   // the real host rules
        r.panelWindow = { nil }
        XCTAssertEqual(r.route(nil), .operationsPanel)
        XCTAssertEqual(r.route(OriginID(raw: 987_654)), .operationsPanel, "no such window")
        let info = conflict(h)
        let j = job(nil)
        let task = Task { await r.resolveConflict(info, job: j) }
        try await h.waitUntil("asked") { presenter.shown.count == 1 }
        XCTAssertEqual(r.pendingHosts[j.id], .operationsPanel)
        presenter.answerOldest(.conflict(.one(.keepBoth)))
        let answer = await task.value
        XCTAssertEqual(answer, .one(.keepBoth))
    }

    func testQuestionFromClosedOriginGoesToOperationsPanel() async throws {   // slice Review Focus 5
        try ContentTestHarness.requireWindowServer()
        let h = try await ContentTestHarness.make(self)
        let browser = try await h.openBrowserWindow()
        let origin = browser.origin
        let presenter = RecordingPresenter()
        let r = InteractionRouter(windows: h.context.windows, presenter: presenter)
        r.panelWindow = { nil }
        XCTAssertEqual(r.route(origin), .window(origin))
        XCTAssertTrue(r.hostWindow(for: origin) === browser.window)
        browser.close()
        try await h.waitUntil("window gone") { h.context.windows.window(for: origin) == nil }
        XCTAssertEqual(r.route(origin), .operationsPanel)
        let info = conflict(h)
        let j = job(origin)
        let task = Task { await r.resolveConflict(info, job: j) }
        try await h.waitUntil("asked") { presenter.shown.count == 1 }
        XCTAssertEqual(r.pendingHosts[j.id], .operationsPanel, "§6.2: closing the window never loses its job's question")
        XCTAssertNil(presenter.shown[0].window)
        presenter.answerOldest(.conflict(.all(.skip)))
        let answer = await task.value
        XCTAssertEqual(answer, .all(.skip))
    }

    func testWindowClosedDuringQuestionMovesItToOperationsPanel() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let open = OpenOrigins()
        open.raw = [3]
        let r = router(h, presenter, open: open)
        let e = error(h, .inUse)
        let j = job(OriginID(raw: 3))
        let task = Task { await r.resolveError(e, job: j) }
        try await h.waitUntil("on the window") { presenter.shown.count == 1 }
        XCTAssertEqual(r.pendingHosts[j.id], .window(OriginID(raw: 3)))
        open.raw = []                          // the window closes and takes its sheet with it, unanswered
        presenter.answerOldest(nil)
        try await h.waitUntil("asked again in the panel") { presenter.shown.count == 2 }
        XCTAssertEqual(r.pendingHosts[j.id], .operationsPanel)
        XCTAssertEqual(presenter.shown[1].question, .error(e))
        presenter.answerOldest(.error(.retry))
        let answer = await task.value
        XCTAssertEqual(answer, .retry)
    }

    func testCancelledQuestionReleasesHost() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        let info = conflict(h)
        let origin = OriginID(raw: 4)
        let jobA = job(origin), jobB = job(origin)
        let first = Task { await r.resolveConflict(info, job: jobA) }
        try await h.waitUntil("shown") { presenter.openCount == 1 }
        first.cancel()                          // what S6's ScenarioInteraction does after answering itself
        let cancelled = await first.value
        XCTAssertEqual(cancelled, .cancelJob, "a dialog that goes away unanswered stops the job safely")
        let second = Task { await r.resolveConflict(info, job: jobB) }
        try await h.waitUntil("the host is free again") { presenter.shown.count == 2 && presenter.openCount == 1 }
        presenter.answerOldest(.conflict(.one(.replace)))
        let answer = await second.value
        XCTAssertEqual(answer, .one(.replace))
    }

    /// Stop and Quit (§6.7, S3 Contract note 18): a job suspended on an unanswered dialog can't finish its cancel,
    /// so the router ends open dialogs and answers waiting and later questions with the safe fallback.
    func testStopAnsweringEndsOpenDialogsAndAnswersLaterQuestionsSafely() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        let info = conflict(h)
        let e = error(h, .inUse)
        let origin = OriginID(raw: 8)
        let jobA = job(origin), jobB = job(origin)
        let open = Task { await r.resolveConflict(info, job: jobA) }
        let waiting = Task { await r.resolveError(e, job: jobB) }
        try await h.waitUntil("one dialog open, one waiting") { presenter.openCount == 1 }
        r.stopAnswering()
        let openAnswer = await open.value
        let waitingAnswer = await waiting.value
        XCTAssertEqual(openAnswer, .cancelJob, "the open dialog closes unanswered and the job stops safely")
        XCTAssertEqual(waitingAnswer, .cancel, "the waiting question never shows")
        let later = await r.confirmInsufficientSpace(SpaceShortfall(needed: 2, available: 1, volumeName: "V"), job: job(origin))
        XCTAssertFalse(later, "questions asked after Stop and Quit get the fallback at once")
        XCTAssertEqual(presenter.shown.count, 1)
        XCTAssertEqual(presenter.openCount, 0)
        XCTAssertTrue(r.pendingHosts.isEmpty)
    }

    func testErrorsFromInlineOriginsAreSkippedWithoutDialog() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        r.answersInline = { $0.raw == 9 }
        let e = error(h, .locked)
        let j = job(OriginID(raw: 9))
        let answer = await r.resolveError(e, job: j)
        XCTAssertEqual(answer, .skip, "Properties shows the error inline (§5.8)")
        XCTAssertTrue(presenter.shown.isEmpty)
        let info = conflict(h)
        let task = Task { await r.resolveConflict(info, job: j) }
        try await h.waitUntil("conflicts still ask") { presenter.shown.count == 1 }
        presenter.answerOldest(.conflict(.one(.skip)))
        _ = await task.value
    }

    func testUIContextInstallsRouterIntoProxy() async throws {
        let h = try await ContentTestHarness.make(self)
        XCTAssertTrue(h.context.interaction as AnyObject === h.context.operationsUI.router, "P1-38 replaces BasicAlertInteraction")
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        h.context.installInteraction(r)
        let proxy = h.environment.interaction
        let e = error(h, .inUse)
        let j = job(OriginID(raw: 5))
        let task = Task { await proxy.resolveError(e, job: j) }
        try await h.waitUntil("the proxy forwards to the router") { presenter.shown.count == 1 }
        presenter.answerOldest(.error(.skip))
        let answer = await task.value
        XCTAssertEqual(answer, .skip)
    }

    func testConflictFromRealCopyJobReachesRouter() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("src/a.txt", bytes: 3)
        try h.file("dst/a.txt", bytes: 5)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        h.environment.interaction.setTarget(r)
        let request = JobRequest(.copy(sources: [h.url("src/a.txt")], destination: h.url("dst")), origin: OriginID(raw: 6))
        let operations = h.environment.operations
        let running = Task { await operations.perform(request) }
        try await h.waitUntil("conflict asked") { presenter.shown.count == 1 }
        guard case .conflict(let info) = presenter.shown[0].question else { return XCTFail("a conflict question") }
        XCTAssertEqual(info.pair.destination.url.lastPathComponent, "a.txt")
        XCTAssertFalse(info.isFolderMerge)
        presenter.answerOldest(.conflict(.one(.keepBoth)))
        let outcome = await running.value
        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertTrue(h.exists("dst/a 2.txt"))
        XCTAssertEqual(h.lstatInfo("dst/a.txt")?.st_size, 5, "Keep Both never touches the existing item")
    }
}
```

- [ ] **Step 2: Write the failing dialog, list and capsule tests**

```swift
// Tests/UITests/OperationsUITests.swift
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
        XCTAssertTrue(FileCommandController.pendingCommands.isEmpty)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter 'UITests\.(InteractionRouterTests|OperationsUITests)' 2>&1 | tail -20`
Expected: compile errors such as `cannot find type 'DialogPresenting' in scope`, `cannot find 'ConflictDialogModel' in scope`, `cannot find 'JobTitle' in scope`, `value of type 'UIContext' has no member 'operationsUI'`.

- [ ] **Step 4: Add this task's strings**

Run:
```bash
scripts/l10n-add.sh "Merge folders?" "The destination already has a folder named '%@'. Merging adds the items of both folders to it." \
  "The destination already has a file named '%@'" "The destination already has a folder named '%@'" \
  "Replace it with the item you're copying or moving, skip this item, or keep both." \
  "Do this for all remaining conflicts (%lld)" "Replace" "Skip" "Keep Both" "Merge" "Compare…" "Cancel" \
  "Which items do you want to keep?" "If you keep both, the copied item gets a number added to its name." \
  "From source" "At destination" "Folder" "Back" "Continue" "Open Privacy Settings" "Retry" "Skip All" \
  "Unlock and Continue" "Continue Anyway" "Allow macExplorer in System Settings › Privacy & Security, then try again." \
  "Unlocking removes the Locked attribute so the operation can continue." "Free up space on the destination, then try again." \
  "Not enough space on '%@'" "This operation needs %@, but only %@ is available." "%lld items can't be moved to the Trash." \
  "Do you want to delete it permanently? This can't be undone." "Do you want to delete them permanently? This can't be undone." \
  "Delete"
scripts/l10n-add.sh "Copying %@" "Copying %@ to %@" "Copying %@ from %@ to %@" "Moving %@" "Moving %@ to %@" \
  "Moving %@ from %@ to %@" "Duplicating %@" "Moving %@ to the Trash" "Deleting %@" "Creating %@" "Creating %@ in %@" \
  "Renaming %@" "Making an alias of %@" "Making a symbolic link to %@" "Changing permissions of %@" "Changing attributes of %@" \
  "Undoing changes to %@" "Redoing changes to %@" "'%@'" "1 item" "%@ items" "%@ of %@" "%@/s" "About %@ remaining" \
  "Waiting to start…" "Preparing…" "Paused" "Waiting for your answer" "Cancelling…" "Pause" "Resume" "Show" "More details" \
  "No operations" "Operations" "1 operation in progress" "%lld operations in progress" "waiting for your answer" "%lld%%"
jq -r '.strings | has("Merge folders?") and has("%lld%%") and has("Copying %@ from %@ to %@")' Sources/UI/Resources/Localizable.xcstrings
```
Expected: `true`.

- [ ] **Step 5: Implement the router**

```swift
// Sources/UI/Operations/InteractionRouter.swift
import AppKit
import Core

/// One question a job asks through FileOpInteraction, in a form presenters and tests can compare.
enum InteractionQuestion: Sendable, Equatable {
    case conflict(ConflictInfo)
    case error(FileOpError)
    case space(SpaceShortfall)
    case noTrash([URL])

    /// The answer when a dialog goes away without one (Task cancelled, sheet ended from outside): stop safely.
    var fallback: InteractionAnswer {
        switch self {
        case .conflict: .conflict(.cancelJob)
        case .error: .error(.cancel)
        case .space, .noTrash: .confirm(false)
        }
    }
}

enum InteractionAnswer: Sendable, Equatable {
    case conflict(ConflictResolution)
    case error(ErrorResolution)
    case confirm(Bool)
}

/// Where a question appears (§6.2): a sheet on the window that started the job, or the Operations panel.
enum DialogHost: Hashable, Sendable {
    case window(OriginID)
    case operationsPanel
}

@MainActor
protocol DialogPresenting: AnyObject {
    /// Shows `question` as a sheet on `window` (a standalone panel when nil) and returns the answer, or nil when the
    /// dialog went away without one: its window closed, the calling Task was cancelled, or the sheet was ended outside.
    func present(_ question: InteractionQuestion, job: JobSnapshot, on window: NSWindow?) async -> InteractionAnswer?
}

/// FIFO async mutex on the main actor: one dialog per host at a time, in arrival order (slice Review Focus 5).
@MainActor
final class SerialGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { waiters.count }

    func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate to the oldest waiter, or frees it.
    func leave() {
        if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
    }
}

/// Answers every FileOpInteraction question with a dialog (§6.2, §6.4, §6.5): a sheet on the window that started the
/// job, or the Operations panel when that window has closed (also while the question was waiting or showing).
/// Questions for one host are shown one at a time; errors from Properties windows are answered Skip and shown there.
@MainActor
final class InteractionRouter: FileOpInteraction {
    private let windows: WindowManager
    var presenter: any DialogPresenting
    /// The Operations panel's window, shown on demand (OperationsUI sets it).
    var panelWindow: (@MainActor () -> NSWindow?)?
    /// Origins whose job errors are answered .skip without a dialog; the window shows them inline (§5.8).
    var answersInline: @MainActor (OriginID) -> Bool = { PropertiesWindowController.answersErrorsInline($0) }
    private let resolveHost: (@MainActor (OriginID?) -> DialogHost)?
    private var gates: [DialogHost: SerialGate] = [:]
    /// Where each waiting job's question is showing (Operations list "Show", tests).
    private(set) var pendingHosts: [JobID: DialogHost] = [:]
    /// The presenting Task of each open dialog, so Stop and Quit can end them.
    private var openDialogs: [JobID: Task<InteractionAnswer?, Never>] = [:]
    /// Set by stopAnswering(): every question from then on gets its fallback without a dialog.
    private(set) var isStopping = false

    /// §3.14. Presents with a URL opener that only records; OperationsUI swaps in the real presenter.
    convenience init(windows: WindowManager) {
        self.init(windows: windows, presenter: AppKitDialogPresenter(icons: nil, opener: RecordingURLOpener.shared))
    }

    /// Tests inject a presenter and, optionally, fake host rules.
    init(windows: WindowManager, presenter: any DialogPresenting, resolveHost: (@MainActor (OriginID?) -> DialogHost)? = nil) {
        self.windows = windows
        self.presenter = presenter
        self.resolveHost = resolveHost
    }

    // MARK: FileOpInteraction (called from the FileOpQueue actor; hop to main)

    nonisolated func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
        if case .conflict(let resolution) = await ask(.conflict(conflict), job: job) { return resolution }
        return .cancelJob
    }

    nonisolated func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        if case .error(let resolution) = await ask(.error(error), job: job) { return resolution }
        return .cancel
    }

    nonisolated func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        if case .confirm(let ok) = await ask(.space(shortfall), job: job) { return ok }
        return false
    }

    nonisolated func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        if case .confirm(let ok) = await ask(.noTrash(urls), job: job) { return ok }
        return false
    }

    // MARK: hosts

    /// The window that shows sheets for `origin`: an open browser window, or an open Properties window. nil means the
    /// Operations panel. P2-05 extends this to select the origin tab first.
    func hostWindow(for origin: OriginID?) -> NSWindow? {
        guard let origin else { return nil }
        if let window = windows.window(for: origin)?.window, Self.canHostSheet(window) { return window }
        if let window = NSApp.window(withWindowNumber: origin.raw), window.identifier?.rawValue == AXID.propertiesWindow,
           Self.canHostSheet(window) {
            return window
        }
        return nil
    }

    func route(_ origin: OriginID?) -> DialogHost {
        if let resolveHost { return resolveHost(origin) }
        guard let origin, hostWindow(for: origin) != nil else { return .operationsPanel }
        return .window(origin)
    }

    func window(for host: DialogHost) -> NSWindow? {
        switch host {
        case .window(let origin): hostWindow(for: origin)
        case .operationsPanel: panelWindow?()
        }
    }

    /// Operations list "Show": bring the window holding this job's question to the front.
    func revealQuestion(for job: JobID) {
        guard let host = pendingHosts[job], let window = window(for: host) else { return }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Stop and Quit

    /// Called by the Stop and Quit flow (P1-30's AppLifecycle) right before `termination.stopAllAndWait()` (§6.7,
    /// S3 Contract note 18): closes every open dialog unanswered and answers every waiting or later question with
    /// its fallback (.cancelJob / .cancel / false), so the cancelled jobs finish their cancel path (partials removed,
    /// journal updated) before the 10 s timeout. Not reversible: the app is quitting.
    func stopAnswering() {
        isStopping = true
        for task in openDialogs.values { task.cancel() }
    }

    // MARK: asking

    func ask(_ question: InteractionQuestion, job: JobSnapshot) async -> InteractionAnswer {
        if isStopping { return question.fallback }
        if case .error = question, let origin = job.origin, answersInline(origin) { return .error(.skip) }
        var host = route(job.origin)
        while true {
            let gate = gate(for: host)
            await gate.enter()
            if Task.isCancelled || isStopping {
                gate.leave()
                return question.fallback
            }
            if case .window(let origin) = host, route(origin) != host {   // closed while this question waited
                gate.leave()
                host = .operationsPanel
                continue
            }
            pendingHosts[job.id] = host
            let hostWindow = window(for: host)
            // A child Task, so stopAnswering() can cancel it; the presenter treats cancellation as "went away".
            let presenting = Task { @MainActor [self] in await self.presenter.present(question, job: job, on: hostWindow) }
            openDialogs[job.id] = presenting
            let answer = await withTaskCancellationHandler {
                await presenting.value
            } onCancel: {
                presenting.cancel()
            }
            openDialogs[job.id] = nil
            pendingHosts[job.id] = nil
            gate.leave()
            if isStopping { return question.fallback }
            if let answer { return answer }
            if Task.isCancelled { return question.fallback }
            if case .window(let origin) = host, route(origin) != host {   // the window closed under its sheet
                host = .operationsPanel
                continue
            }
            return question.fallback
        }
    }

    private func gate(for host: DialogHost) -> SerialGate {
        if let gate = gates[host] { return gate }
        let gate = SerialGate()
        gates[host] = gate
        return gate
    }

    private static func canHostSheet(_ window: NSWindow) -> Bool {
        window.isVisible || window.isMiniaturized
    }
}
```

- [ ] **Step 6: Implement the conflict dialog, Compare and the AppKit presenter**

```swift
// Sources/UI/Operations/ConflictDialog.swift
import AppKit
import SwiftUI
import Core
import MacxFS

/// §6.4 conflict dialog content, decided from ConflictInfo alone.
struct ConflictDialogModel: Equatable {
    enum Choice: Hashable {
        case action(ConflictAction)
        case compare
        case cancel
    }

    let title: String
    let message: String
    let choices: [Choice]
    let applyToAllTitle: String?          // only when more than one conflict is known
    let defaultAction: ConflictAction     // Return: never Replace

    @MainActor
    init(_ info: ConflictInfo) {
        let name = info.pair.destination.url.lastPathComponent
        if info.isFolderMerge {
            title = L10n.string("Merge folders?")
            message = String(format: L10n.string("The destination already has a folder named '%@'. Merging adds the items of both folders to it."), name)
            choices = [.action(.merge), .action(.keepBoth), .action(.skip), .cancel]
            defaultAction = .merge
        } else {
            title = info.pair.destination.isDirectory
                ? String(format: L10n.string("The destination already has a folder named '%@'"), name)
                : String(format: L10n.string("The destination already has a file named '%@'"), name)
            message = L10n.string("Replace it with the item you're copying or moving, skip this item, or keep both.")
            choices = [.action(.replace), .action(.skip), .action(.keepBoth), .compare, .cancel]
            defaultAction = .keepBoth
        }
        applyToAllTitle = info.knownRemaining > 1
            ? String(format: L10n.string("Do this for all remaining conflicts (%lld)"), info.knownRemaining) : nil
    }

    func resolution(_ action: ConflictAction, applyToAll: Bool) -> ConflictResolution {
        applyToAll && applyToAllTitle != nil ? .all(action) : .one(action)
    }

    @MainActor
    static func title(_ choice: Choice) -> String {
        switch choice {
        case .action(.replace): L10n.string("Replace")
        case .action(.skip): L10n.string("Skip")
        case .action(.keepBoth): L10n.string("Keep Both")
        case .action(.merge): L10n.string("Merge")
        case .compare: L10n.string("Compare…")
        case .cancel: L10n.string("Cancel")
        }
    }
}

struct ConflictDialogView: View {
    let model: ConflictDialogModel
    let jobTitle: String
    let icon: @MainActor (ItemSummary) -> NSImage?
    let answer: @MainActor (ConflictResolution) -> Void
    @State private var compare: CompareSelection
    @State private var applyToAll = false
    @State private var isComparing = false

    init(model: ConflictDialogModel, jobTitle: String, compare: CompareSelection,
         icon: @escaping @MainActor (ItemSummary) -> NSImage?, answer: @escaping @MainActor (ConflictResolution) -> Void) {
        self.model = model
        self.jobTitle = jobTitle
        self.icon = icon
        self.answer = answer
        _compare = State(initialValue: compare)
    }

    var body: some View {
        if isComparing {
            CompareView(selection: $compare, icon: icon, onContinue: { answer(compare.resolution) }, onBack: { isComparing = false })
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: jobTitle).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: model.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: model.message).fixedSize(horizontal: false, vertical: true)
                if let toAll = model.applyToAllTitle {
                    Toggle(toAll, isOn: $applyToAll).accessibilityIdentifier("macx.conflict.applyToAll")
                }
                HStack {
                    Spacer()
                    ForEach(model.choices, id: \.self) { choice in button(for: choice) }
                }
            }
            .padding(20)
            .frame(width: 520, alignment: .leading)
        }
    }

    @ViewBuilder
    private func button(for choice: ConflictDialogModel.Choice) -> some View {
        let title = ConflictDialogModel.title(choice)
        switch choice {
        case .action(let action):
            Button(title) { answer(model.resolution(action, applyToAll: applyToAll)) }
                .keyboardShortcut(action == model.defaultAction ? .defaultAction : nil)
                .accessibilityIdentifier(AXID.conflictButton(action))
        case .compare:
            Button(title) { isComparing = true }.accessibilityIdentifier("macx.conflict.compare")
        case .cancel:
            Button(title, role: .cancel) { answer(.cancelJob) }.keyboardShortcut(.cancelAction)
        }
    }
}

/// Runs one dialog as a sheet on a window (a centred panel when there is none) and resumes exactly once: with the
/// button's answer, or nil when the sheet is ended from outside, its window closes, or the Task is cancelled.
@MainActor
final class SheetHost {
    let panel: NSPanel
    private var continuation: CheckedContinuation<InteractionAnswer?, Never>?
    private var answer: InteractionAnswer?
    private var isDone = false
    private weak var parent: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
    }

    func run(_ content: AnyView, on window: NSWindow?) async -> InteractionAnswer? {
        guard !isDone else { return answer }
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if let window {
                parent = window
                closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish(nil) }
                }
                window.beginSheet(panel) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resume() }
                }
            } else {
                panel.center()
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// A button's answer, or nil to dismiss. Idempotent: only the first call counts.
    func finish(_ value: InteractionAnswer?) {
        guard !isDone else { return }
        isDone = true
        answer = value
        if let parent, panel.sheetParent === parent {
            parent.endSheet(panel)              // the completion handler resumes
        } else {
            panel.orderOut(nil)
            resume()
        }
    }

    private func resume() {
        isDone = true
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

/// The real presenter: SwiftUI dialogs in sheets. Side effects go through ExternalURLOpening (S5-C2).
@MainActor
final class AppKitDialogPresenter: DialogPresenting {
    private let icons: IconCache?
    private let opener: any ExternalURLOpening
    private let types: TypeRegistry

    init(icons: IconCache?, opener: any ExternalURLOpening, types: TypeRegistry = .shared) {
        self.icons = icons
        self.opener = opener
        self.types = types
    }

    func present(_ question: InteractionQuestion, job: JobSnapshot, on window: NSWindow?) async -> InteractionAnswer? {
        let sheet = SheetHost()
        let view = content(for: question, job: job) { [weak sheet] answer in sheet?.finish(answer) }
        return await withTaskCancellationHandler {
            await sheet.run(view, on: window)
        } onCancel: {
            Task { @MainActor in sheet.finish(nil) }
        }
    }

    func content(for question: InteractionQuestion, job: JobSnapshot,
                 answer: @escaping @MainActor (InteractionAnswer) -> Void) -> AnyView {
        let press: @MainActor (DialogButton) -> Void = { [weak self] button in
            guard let self else { return }
            answer(self.handle(button))
        }
        switch question {
        case .conflict(let info):
            return AnyView(ConflictDialogView(model: ConflictDialogModel(info), jobTitle: JobTitle.title(job.description),
                                              compare: CompareSelection(info), icon: { [weak self] in self?.icon(for: $0) },
                                              answer: { answer(.conflict($0)) }))
        case .error(let error):
            return AnyView(ErrorDialogView(model: .error(error, job: job), press: press))
        case .space(let shortfall):
            return AnyView(ErrorDialogView(model: .space(shortfall, job: job), press: press))
        case .noTrash(let urls):
            return AnyView(ErrorDialogView(model: .noTrash(urls, job: job), press: press))
        }
    }

    /// Runs a button's side effect, then returns its answer (§3.13: Open Privacy Settings opens the pane and retries).
    func handle(_ button: DialogButton) -> InteractionAnswer {
        if button.sideEffect == .openPrivacySettings { opener.open(SystemSettingsLinks.privacyAllFiles) }
        return button.answer
    }

    /// Tier 0 type icon (no file-system call, S5-C3).
    func icon(for item: ItemSummary) -> NSImage? {
        guard let icons else { return nil }
        let index = types.index(forExtension: Substring(item.url.pathExtension), isDirectory: item.isDirectory)
        return NSImage(cgImage: icons.typeIcon(index, points: 32, scale: 2), size: NSSize(width: 32, height: 32))
    }
}
```

```swift
// Sources/UI/Operations/CompareView.swift
import AppKit
import SwiftUI
import Core

/// §6.4 Compare: per-item "keep source" / "keep destination" checkboxes, as in Explorer. Both → Keep Both; source
/// only → Replace (Merge for folder pairs); destination only → Skip.
struct CompareSelection: Equatable {
    struct Row: Equatable, Identifiable {
        let pair: ConflictPair
        var keepSource = false
        var keepDestination = false

        var id: URL { pair.source.url }
        var isFolderPair: Bool { pair.source.isDirectory && pair.destination.isDirectory }
        var action: ConflictAction? {
            CompareSelection.action(keepSource: keepSource, keepDestination: keepDestination, isFolderPair: isFolderPair)
        }
    }

    var rows: [Row]

    /// The current pair first, then the other known top-level conflicts, without duplicates.
    init(_ info: ConflictInfo) {
        var seen = Set<URL>()
        rows = ([info.pair] + info.pendingPairs).compactMap { pair in
            seen.insert(pair.source.url).inserted ? Row(pair: pair) : nil
        }
    }

    static func action(keepSource: Bool, keepDestination: Bool, isFolderPair: Bool) -> ConflictAction? {
        switch (keepSource, keepDestination) {
        case (true, true): .keepBoth
        case (true, false): isFolderPair ? .merge : .replace
        case (false, true): .skip
        case (false, false): nil
        }
    }

    var canContinue: Bool { rows.allSatisfy { $0.action != nil } }
    var allSources: Tri { Self.tri(rows.map(\.keepSource)) }
    var allDestinations: Tri { Self.tri(rows.map(\.keepDestination)) }

    mutating func setAllSources(_ on: Bool) {
        for index in rows.indices { rows[index].keepSource = on }
    }

    mutating func setAllDestinations(_ on: Bool) {
        for index in rows.indices { rows[index].keepDestination = on }
    }

    /// One action per source URL (rows without a choice skip; Continue is disabled until there are none).
    var resolution: ConflictResolution {
        .perItem(Dictionary(rows.map { ($0.pair.source.url, $0.action ?? .skip) }, uniquingKeysWith: { first, _ in first }))
    }

    private static func tri(_ values: [Bool]) -> Tri {
        values.allSatisfy { $0 } ? .on : values.contains(true) ? .mixed : .off
    }
}

struct CompareView: View {
    @Binding var selection: CompareSelection
    let icon: @MainActor (ItemSummary) -> NSImage?
    let onContinue: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: L10n.string("Which items do you want to keep?")).font(.headline)
            Text(verbatim: L10n.string("If you keep both, the copied item gets a number added to its name."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TriCheckbox(title: L10n.string("From source"), state: selection.allSources) { selection.setAllSources($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                TriCheckbox(title: L10n.string("At destination"), state: selection.allDestinations) { selection.setAllDestinations($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($selection.rows) { $row in
                        HStack(alignment: .top, spacing: 12) {
                            CompareSide(item: row.pair.source, icon: icon(row.pair.source), isOn: $row.keepSource)
                            CompareSide(item: row.pair.destination, icon: icon(row.pair.destination), isOn: $row.keepDestination)
                        }
                        Divider()
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 320)
            HStack {
                Button(L10n.string("Back"), action: onBack)
                Spacer()
                Button(L10n.string("Continue"), action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!selection.canContinue)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

/// One side of a Compare row: checkbox, icon, name, size, modified date and folder path.
private struct CompareSide: View {
    let item: ItemSummary
    let icon: NSImage?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 8) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: item.isDirectory ? L10n.string("Folder") : Formatters.bytes(item.size)).font(.caption)
                    Text(verbatim: Formatters.date(item.modified, style: .absolute)).font(.caption)
                    Text(verbatim: item.url.deletingLastPathComponent().path)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 7: Implement the error dialog**

```swift
// Sources/UI/Operations/ErrorDialog.swift
import SwiftUI
import Core
import MacxFS

struct DialogButton: Equatable, Identifiable {
    enum Role: Equatable { case normal, destructive, cancel }
    enum SideEffect: Equatable { case openPrivacySettings }

    let title: String
    let answer: InteractionAnswer
    var role: Role = .normal
    var isDefault = false
    var sideEffect: SideEffect?

    var id: String { title }
}

/// §6.5 dialogs: the table's message as the title and exactly its actions, in order; plus the free-space and
/// "no Trash" prompts. `context` is the job's title.
struct ErrorDialogModel: Equatable {
    let context: String
    let title: String
    let detail: String?
    let buttons: [DialogButton]

    @MainActor
    static func error(_ error: FileOpError, job: JobSnapshot, locale: Locale = .current) -> ErrorDialogModel {
        ErrorDialogModel(context: JobTitle.title(job.description, locale: locale),
                         title: ErrorText.jobError(error.kind, name: error.url.lastPathComponent, verb: job.description.verb),
                         detail: detail(error.kind),
                         buttons: error.kind.allowedResolutions.map { button(for: $0, kind: error.kind) })
    }

    @MainActor
    static func space(_ shortfall: SpaceShortfall, job: JobSnapshot, locale: Locale = .current) -> ErrorDialogModel {
        ErrorDialogModel(context: JobTitle.title(job.description, locale: locale),
                         title: String(format: L10n.string("Not enough space on '%@'"), shortfall.volumeName),
                         detail: String(format: L10n.string("This operation needs %@, but only %@ is available."),
                                        Formatters.bytes(shortfall.needed), Formatters.bytes(shortfall.available)),
                         buttons: [DialogButton(title: L10n.string("Continue Anyway"), answer: .confirm(true)),
                                   DialogButton(title: L10n.string("Cancel"), answer: .confirm(false), role: .cancel, isDefault: true)])
    }

    /// §6.3: volumes without a Trash fall back to "Delete permanently?" with confirmation.
    @MainActor
    static func noTrash(_ urls: [URL], job: JobSnapshot, locale: Locale = .current) -> ErrorDialogModel {
        let single = urls.count == 1
        return ErrorDialogModel(
            context: JobTitle.title(job.description, locale: locale),
            title: single ? String(format: L10n.string("'%@' can't be moved to the Trash."), urls[0].lastPathComponent)
                          : String(format: L10n.string("%lld items can't be moved to the Trash."), urls.count),
            detail: single ? L10n.string("Do you want to delete it permanently? This can't be undone.")
                           : L10n.string("Do you want to delete them permanently? This can't be undone."),
            buttons: [DialogButton(title: L10n.string("Delete"), answer: .confirm(true), role: .destructive),
                      DialogButton(title: L10n.string("Cancel"), answer: .confirm(false), role: .cancel, isDefault: true)])
    }

    @MainActor
    static func button(for resolution: ErrorResolution, kind: FileOpErrorKind) -> DialogButton {
        switch resolution {
        case .retry where kind == .blockedByMacOS:
            DialogButton(title: L10n.string("Open Privacy Settings"), answer: .error(.retry), isDefault: true, sideEffect: .openPrivacySettings)
        case .retry: DialogButton(title: L10n.string("Retry"), answer: .error(.retry), isDefault: true)
        case .skip: DialogButton(title: L10n.string("Skip"), answer: .error(.skip))
        case .skipAll: DialogButton(title: L10n.string("Skip All"), answer: .error(.skipAll))
        case .cancel: DialogButton(title: L10n.string("Cancel"), answer: .error(.cancel), role: .cancel)
        case .unlockAndContinue: DialogButton(title: L10n.string("Unlock and Continue"), answer: .error(.unlockAndContinue), isDefault: true)
        case .continueAnyway: DialogButton(title: L10n.string("Continue Anyway"), answer: .error(.continueAnyway))
        }
    }

    @MainActor
    private static func detail(_ kind: FileOpErrorKind) -> String? {
        switch kind {
        case .blockedByMacOS: L10n.string("Allow macExplorer in System Settings › Privacy & Security, then try again.")
        case .locked: L10n.string("Unlocking removes the Locked attribute so the operation can continue.")
        case .noSpace: L10n.string("Free up space on the destination, then try again.")
        default: nil
        }
    }
}

struct ErrorDialogView: View {
    let model: ErrorDialogModel
    let press: @MainActor (DialogButton) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30)).foregroundStyle(.yellow).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: model.context).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: model.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let detail = model.detail { Text(verbatim: detail).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    ForEach(model.buttons) { button in
                        Button(button.title, role: role(button)) { press(button) }
                            .keyboardShortcut(shortcut(button))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
    }

    private func role(_ button: DialogButton) -> ButtonRole? {
        switch button.role {
        case .normal: nil
        case .destructive: .destructive
        case .cancel: .cancel
        }
    }

    private func shortcut(_ button: DialogButton) -> KeyboardShortcut? {
        if button.isDefault { return .defaultAction }
        return button.role == .cancel ? .cancelAction : nil
    }
}
```

- [ ] **Step 8: Implement job titles, the job list and the capsule**

```swift
// Sources/UI/Operations/OperationsListView.swift
import SwiftUI
import Core

/// §6.2 job titles from Core's typed JobDescription: "Copying 1,204 items from Downloads to Backup".
@MainActor
enum JobTitle {
    static func title(_ description: JobDescription, locale: Locale = .current) -> String {
        let what = subject(description, locale: locale)
        let from = description.sourceFolderName, to = description.destinationFolderName
        switch description.verb {
        case .copying:
            return route(L10n.string("Copying %@"), L10n.string("Copying %@ to %@"), L10n.string("Copying %@ from %@ to %@"), what, from, to)
        case .moving:
            return route(L10n.string("Moving %@"), L10n.string("Moving %@ to %@"), L10n.string("Moving %@ from %@ to %@"), what, from, to)
        case .duplicating: return String(format: L10n.string("Duplicating %@"), what)
        case .trashing: return String(format: L10n.string("Moving %@ to the Trash"), what)
        case .deleting: return String(format: L10n.string("Deleting %@"), what)
        case .creating:
            return to.map { String(format: L10n.string("Creating %@ in %@"), what, $0) } ?? String(format: L10n.string("Creating %@"), what)
        case .renaming: return String(format: L10n.string("Renaming %@"), what)
        case .makingAlias: return String(format: L10n.string("Making an alias of %@"), what)
        case .makingSymlink: return String(format: L10n.string("Making a symbolic link to %@"), what)
        case .changingPermissions: return String(format: L10n.string("Changing permissions of %@"), what)
        case .changingAttributes: return String(format: L10n.string("Changing attributes of %@"), what)
        case .undoing: return String(format: L10n.string("Undoing changes to %@"), what)
        case .redoing: return String(format: L10n.string("Redoing changes to %@"), what)
        }
    }

    /// "'a.txt'" for one named item, otherwise "1,204 items".
    static func subject(_ description: JobDescription, locale: Locale = .current) -> String {
        if description.itemCount == 1, let name = description.firstItemName { return String(format: L10n.string("'%@'"), name) }
        if description.itemCount == 1 { return L10n.string("1 item") }
        return String(format: L10n.string("%@ items"), description.itemCount.formatted(.number.locale(locale)))
    }

    private static func route(_ plain: String, _ toOnly: String, _ fromTo: String, _ what: String, _ from: String?, _ to: String?) -> String {
        switch (from, to) {
        case (let from?, let to?): String(format: fromTo, what, from, to)
        case (nil, let to?): String(format: toOnly, what, to)
        default: String(format: plain, what)
        }
    }
}

/// Everything one job row shows (§6.2), computed from a snapshot.
struct JobRowModel: Equatable, Identifiable {
    let id: JobID
    let title: String
    let fraction: Double?
    let countText: String?          // "12 of 1,204"
    let bytesText: String?          // "1.2 MB of 3 GB"
    let speedText: String?          // "12 MB/s", running only
    let etaText: String?            // "About 2 minutes remaining", running only
    let statusText: String?         // Preparing…, Paused, Waiting for your answer, …
    let currentItem: String?
    let graph: [Double]             // 0…1, oldest first
    let isWaiting: Bool
    let canPause: Bool
    let canResume: Bool
    let canCancel: Bool

    @MainActor
    init(_ job: JobSnapshot, locale: Locale = .current) {
        let progress = job.progress
        let running = job.state == .running
        id = job.id
        title = JobTitle.title(job.description, locale: locale)
        fraction = progress.fraction
        countText = progress.itemsTotal.map {
            String(format: L10n.string("%@ of %@"), progress.itemsDone.formatted(.number.locale(locale)), $0.formatted(.number.locale(locale)))
        }
        bytesText = progress.bytesTotal.flatMap { total in
            total > 0 ? String(format: L10n.string("%@ of %@"), Formatters.bytes(progress.bytesDone), Formatters.bytes(total)) : nil
        }
        speedText = running ? progress.throughput.last.flatMap { $0 > 0 ? String(format: L10n.string("%@/s"), Formatters.bytes(Int64($0))) : nil } : nil
        etaText = running ? progress.estimatedRemaining.map { Self.eta($0, locale: locale) } : nil
        statusText = switch job.state {
        case .queued: L10n.string("Waiting to start…")
        case .planning: L10n.string("Preparing…")
        case .paused: L10n.string("Paused")
        case .waitingForUser: L10n.string("Waiting for your answer")
        case .cancelling: L10n.string("Cancelling…")
        case .running, .finished: nil
        }
        currentItem = progress.currentItem
        graph = ThroughputGraph.normalized(progress.throughput)
        isWaiting = job.state == .waitingForUser
        canPause = job.state == .queued || job.state == .planning || job.state == .running
        canResume = job.state == .paused
        canCancel = job.state != .cancelling && job.state != .finished
    }

    @MainActor
    static func eta(_ remaining: Duration, locale: Locale = .current) -> String {
        let seconds = max(1, Int(remaining.components.seconds))
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        return String(format: L10n.string("About %@ remaining"), formatter.string(from: TimeInterval(seconds)) ?? "")
    }
}

/// The 60-sample throughput graph (§6.2).
enum ThroughputGraph {
    static func normalized(_ samples: [Double]) -> [Double] {
        guard let peak = samples.max(), peak > 0 else { return samples.map { _ in 0 } }
        return samples.map { max(0, $0) / peak }
    }

    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(value)))
        }
    }

    static func path(_ values: [Double], in size: CGSize) -> Path {
        var path = Path()
        path.addLines(points(values, in: size))
        return path
    }
}

struct JobActions {
    var pause: @MainActor (JobID) -> Void
    var resume: @MainActor (JobID) -> Void
    var cancel: @MainActor (JobID) -> Void
    var showQuestion: @MainActor (JobID) -> Void
}

/// The job list shared by the capsule's popover and Window › Operations (§6.2, §6.7). `visibleJobs` hides jobs
/// younger than 1 s; the timeline re-evaluates it as time passes.
struct OperationsListView: View {
    let operations: OperationsCenter
    let actions: JobActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let jobs = operations.visibleJobs
            if jobs.isEmpty {
                Text(verbatim: L10n.string("No operations"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(jobs) { job in
                            JobRowView(model: JobRowModel(job), actions: actions)
                            if job.id != jobs.last?.id { Divider() }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 80, idealHeight: 260)
    }
}

struct JobRowView: View {
    let model: JobRowModel
    let actions: JobActions
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.isWaiting {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .accessibilityLabel(L10n.string("Waiting for your answer"))
                }
                Text(verbatim: model.title).lineLimit(2)
                Spacer()
                if model.canPause {
                    Button { actions.pause(model.id) } label: { Image(systemName: "pause.fill") }
                        .buttonStyle(.borderless).accessibilityLabel(L10n.string("Pause"))
                }
                if model.canResume {
                    Button { actions.resume(model.id) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).accessibilityLabel(L10n.string("Resume"))
                }
                if model.canCancel {
                    Button { actions.cancel(model.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).accessibilityLabel(L10n.string("Cancel"))
                }
            }
            if let fraction = model.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(verbatim: model.statusText ?? model.countText ?? "")
                Spacer()
                if let speed = model.speedText { Text(verbatim: speed) }
                if let eta = model.etaText { Text(verbatim: eta) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.isWaiting {
                Button(L10n.string("Show")) { actions.showQuestion(model.id) }.controlSize(.small)
            }
            if model.graph.count > 1 {
                GeometryReader { geometry in
                    ThroughputGraph.path(model.graph, in: geometry.size).stroke(Color.accentColor, lineWidth: 1)
                }
                .frame(height: 28)
                .accessibilityHidden(true)
            }
            DisclosureGroup(L10n.string("More details"), isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 2) {
                    if let item = model.currentItem { Text(verbatim: item).lineLimit(1).truncationMode(.middle) }
                    if let count = model.countText { Text(verbatim: count) }
                    if let bytes = model.bytesText { Text(verbatim: bytes) }
                }
                .font(.caption)
            }
        }
    }
}
```

```swift
// Sources/UI/Operations/OperationsCapsule.swift
import AppKit
import SwiftUI
import Core

/// What the status-bar capsule shows (§6.2): hidden without visible jobs (those running ≥ 1 s or waiting).
struct CapsuleState: Equatable {
    var isVisible = false
    var percentText = ""
    var fraction: Double?
    var isWaiting = false
    var accessibilityLabel = ""

    @MainActor
    static func make(visible jobs: [JobSnapshot], overallFraction: Double?) -> CapsuleState {
        guard !jobs.isEmpty else { return CapsuleState() }
        var state = CapsuleState()
        state.isVisible = true
        state.fraction = overallFraction
        // Rounded down: never 100% before the last job finishes.
        state.percentText = overallFraction.map { String(format: L10n.string("%lld%%"), Int64(($0 * 100).rounded(.down))) } ?? ""
        state.isWaiting = jobs.contains { $0.state == .waitingForUser }
        var parts = [jobs.count == 1 ? L10n.string("1 operation in progress")
                                     : String(format: L10n.string("%lld operations in progress"), jobs.count)]
        if !state.percentText.isEmpty { parts.append(state.percentText) }
        if state.isWaiting { parts.append(L10n.string("waiting for your answer")) }
        state.accessibilityLabel = parts.joined(separator: ", ")
        return state
    }
}

/// Status-bar capsule (icon + overall %). Click: popover with the job list. One per window; all show the app's jobs.
@MainActor
final class OperationsCapsule: NSView {
    private let context: UIContext
    let button = NSButton(title: "", target: nil, action: nil)
    private(set) var state = CapsuleState()
    private var loop: ObservationLoop?
    private var ticker: Task<Void, Never>?
    private var popover: NSPopover?

    init(context: UIContext) {
        self.context = context
        super.init(frame: .zero)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.setAccessibilityIdentifier(AXID.operationsCapsule)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: button.heightAnchor),
        ])
        loop = ObservationLoop { [weak self] in
            _ = self?.context.environment.operations.jobs
        } onChange: { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("OperationsCapsule is created in code") }

    func refresh() {
        let operations = context.environment.operations
        state = CapsuleState.make(visible: operations.visibleJobs, overallFraction: operations.overallFraction)
        isHidden = !state.isVisible
        button.title = state.percentText
        button.image = NSImage(systemSymbolName: state.isWaiting ? "exclamationmark.circle.fill" : "arrow.triangle.2.circlepath",
                               accessibilityDescription: nil)
        button.contentTintColor = state.isWaiting ? .systemOrange : nil
        button.setAccessibilityLabel(state.accessibilityLabel)
        button.toolTip = state.accessibilityLabel
        // visibleJobs depends on time (the 1 s rule), so poll while any job exists.
        if operations.jobs.isEmpty {
            ticker?.cancel()
            ticker = nil
            popover?.performClose(nil)
        } else if ticker == nil, window != nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    self.refresh()
                }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ticker?.cancel()
            ticker = nil
        } else {
            refresh()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: context.operationsUI.listView())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        self.popover = popover
    }
}
```

- [ ] **Step 9: Implement the Operations panel and the app-wide owner, then wire everything**

```swift
// Sources/UI/Operations/OperationsPanel.swift
import AppKit
import SwiftUI
import Core

/// Window › Operations (§6.7): a standalone panel with the popover's job list. It stays up while the app is
/// inactive or has no browser windows, and hosts the dialogs of jobs whose window has closed (§6.2).
@MainActor
final class OperationsPanelController: NSWindowController, NSWindowDelegate {
    private let context: UIContext

    init(context: UIContext, content: OperationsListView) {
        self.context = context
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        panel.title = L10n.string("Operations")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.identifier = NSUserInterfaceItemIdentifier(AXID.operationsPanel)
        panel.setAccessibilityIdentifier(AXID.operationsPanel)
        super.init(window: panel)
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: content)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("OperationsPanelController is created in code") }

    func showPanel() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Dialog host for questions whose window has closed: shows the panel and returns it.
    func windowForDialogs() -> NSWindow? {
        showPanel()
        return window
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        context.environment.undo.undoManager
    }
}

/// App-wide progress and dialog UI, owned by UIContext: the interaction router, the Operations panel and the job
/// list the capsules' popovers and the panel share.
@MainActor
final class OperationsUI {
    private unowned let context: UIContext
    let router: InteractionRouter
    private var panelController: OperationsPanelController?

    init(context: UIContext) {
        self.context = context
        router = InteractionRouter(windows: context.windows)
        router.presenter = AppKitDialogPresenter(icons: context.icons, opener: ExternalOpeners.opener(for: context.options))
        router.panelWindow = { [unowned self] in self.panel.windowForDialogs() }
    }

    /// Created on first use (Window › Operations, or the first question without a window).
    var panel: OperationsPanelController {
        if let panelController { return panelController }
        let created = OperationsPanelController(context: context, content: listView())
        panelController = created
        return created
    }

    func showPanel() { panel.showPanel() }

    /// Closes the panel if it was ever created (test teardown).
    func closePanel() { panelController?.close() }

    func listView() -> OperationsListView {
        let queue = context.environment.fileOps
        let router = router
        return OperationsListView(operations: context.environment.operations, actions: JobActions(
            pause: { id in Task { await queue.pause(id) } },
            resume: { id in Task { await queue.resume(id) } },
            cancel: { id in Task { await queue.cancel(id) } },
            showQuestion: { [weak router] id in router?.revealQuestion(for: id) }))
    }
}
```

In `Sources/UI/App/UIContext.swift`, add a stored property and a public entry point:

```swift
    /// P1-38: interaction router, Operations panel and job list (§6.2, §6.7).
    private(set) lazy var operationsUI = OperationsUI(context: self)

    /// Window › Operations; the app delegate calls it when no browser window is open.
    public func showOperationsPanel() { operationsUI.showPanel() }
```

and replace P1-26's `installInteraction(BasicAlertInteraction())` (the last statement of `init`, or wherever P1-26 put it, such as `AppBootstrap`) with:

```swift
        installInteraction(operationsUI.router)   // P1-38: InteractionRouter replaces BasicAlertInteraction
```

`installInteraction(_:)` already forwards the target to `environment.interaction` (§3.14). `BasicAlertInteraction.swift` stays in the tree, unused, because it is part of the §3.14 contract.

In `Sources/UI/Support/AXID.swift`, add after `operationsCapsule`:

```swift
    static let operationsPanel = "macx.operationsPanel"
```

In `Sources/UI/Content/ContentViewController.swift`, add a property after `let listContainer = NSView()`:

```swift
    private(set) var operationsCapsule: OperationsCapsule?
```

and append to `viewDidLoad()`:

```swift
        let capsule = OperationsCapsule(context: context)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        let slot = statusBar.operationsSlot
        slot.addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            capsule.topAnchor.constraint(equalTo: slot.topAnchor),
            capsule.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
        ])
        operationsCapsule = capsule
```

In `Sources/UI/Commands/FileCommandController.swift`:

```swift
    /// Every command has its UI now.
    static let pendingCommands: Set<Command> = []
```

In `Sources/UI/Commands/FileCommandController+View.swift`, replace the `.showOperations` line of `performWindowCommand(_:target:)` with:

```swift
        case .showOperations: context.showOperationsPanel()
```

Window › Operations with no browser window open: the menu item's `macx_showOperations:` action then reaches the app delegate. Find the handler P1-30 added with AppLifecycle's Window › Operations entry and make its body call `showOperationsPanel()` on the delegate's `UIContext`. If P1-30 added none, add this to the app delegate class in `Sources/App/AppDelegate.swift` (using the delegate's stored `UIContext`, named `context` here):

```swift
    @objc func macx_showOperations(_ sender: Any?) {
        context.showOperationsPanel()
    }
```

Stop and Quit (§6.7, S3 Contract note 18; consistency pass): find P1-30's Stop and Quit handler in `Sources/UI/App/AppLifecycle.swift` (the code that calls `environment.termination.stopAllAndWait(...)`) and add this line immediately before that call, so a job waiting on an open dialog can finish its cancel path within the 10 s timeout:

```swift
        context.operationsUI.router.stopAnswering()
```

In `Tests/UITests/Support/ContentTestHarness.swift`, add to `tearDown()` after the `PropertiesWindowController.closeAll(for: context)` line:

```swift
        context.operationsUI.closePanel()
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `swift test --filter 'UITests\.(InteractionRouterTests|OperationsUITests)' 2>&1 | tail -5`
Expected: `Executed 24 tests, with 0 failures` (with no GUI session: `with 4 tests skipped and 0 failures`).

Run: `swift test --filter UITests 2>&1 | tail -3`
Expected: `with 0 failures` (every S4/S5 UI test, with the router installed by `UIContext` and the harness's scripted interaction as the proxy target).

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` with no warnings.

- [ ] **Step 11: Verify in the app (sandbox only)**

With the manual run recipe, before launching also create, all inside the sandbox:

```bash
hdiutil create -size 600m -fs HFS+ -volname MACXTEST "$SANDBOX/img.dmg"
mkdir "$SANDBOX/mnt" && hdiutil attach -nobrowse -mountpoint "$SANDBOX/mnt" "$SANDBOX/img.dmg"
dd if=/dev/urandom of="$SANDBOX/root/big.bin" bs=1m count=400
cp "$SANDBOX/root/file2.txt" "$SANDBOX/mnt/file2.txt"
```

When done, quit the app and run `hdiutil detach -force "$SANDBOX/mnt"` before the recipe's `rm -rf "$SANDBOX"`.
1. Copy `file1.txt` (⌘C), open `Sub Folder`, press ⌘V twice. The second paste shows the conflict sheet on this window: "The destination already has a file named 'file1.txt'", Replace · Skip · Keep Both · Compare… · Cancel, no "for all" checkbox. Keep Both lands `file1 2.txt`.
2. Select `file1.txt`…`file3.txt` in the root, ⌘C, then ⌘V in `Sub Folder` twice. The second paste offers "Do this for all remaining conflicts (3)". Compare… lists the conflicts with icons, sizes, dates and paths. Continue stays disabled until each row has a tick. Ticking both sides of a row gives `file2 2.txt`.
3. Copy `Sub Folder` and paste it into `$SANDBOX/root` twice (type the path into the address bar): the second paste asks "Merge folders?" with Merge · Keep Both · Skip.
4. Select `big.bin`, ⌘C, enter `$SANDBOX/mnt` in the address bar and press ⌘V. After about 1 s the status bar shows the capsule with a %. Click it: the popover shows "Copying 'big.bin' from root to mnt", the bar, "x of y", speed, the graph and the time remaining. Pause shows "Paused", Resume continues, and More details shows the file name. Window › Operations opens the panel with the same row.
5. In the root, select `big.bin` and `file2.txt`, ⌘C, ⌘N, navigate the new window to `$SANDBOX/mnt`, press ⌘V, and close that window (⌘W) while `big.bin` copies. When `file2.txt` conflicts, the dialog appears in the Operations panel, which opens by itself. Answer Skip.
6. `chmod 000 "$SANDBOX/root/file4.txt"`, copy it and paste into `Sub Folder`: "You don't have permission to copy 'file4.txt'." with Retry · Skip · Skip All · Cancel. Skip finishes the job. Afterwards run `chmod 644 "$SANDBOX/root/file4.txt"`.
7. Make room for the test, then fill the image: `rm "$SANDBOX/mnt/big.bin"` and `dd if=/dev/zero of="$SANDBOX/mnt/fill.bin" bs=1m count=520` (both inside the sandbox). Paste `big.bin` into `$SANDBOX/mnt` again: before anything is copied, "Not enough space on 'MACXTEST'" appears with Continue Anyway · Cancel, and Cancel is the default.

- [ ] **Step 12: Commit**

```bash
# Sources/App and Sources/UI/App: UIContext plus whichever file holds the Window › Operations handler
git add Sources/UI/Operations Sources/UI/App Sources/App Sources/UI/Content/ContentViewController.swift \
  Sources/UI/Commands Sources/UI/Support/AXID.swift Sources/UI/Resources/Localizable.xcstrings \
  Tests/UITests/Support/ContentTestHarness.swift Tests/UITests/InteractionRouterTests.swift Tests/UITests/OperationsUITests.swift
git commit -m "feat: interaction router, conflict/compare/error dialogs, operations capsule and panel (P1-38)"
```

---

## Contract notes

Gaps and additive members found while writing this slice. The overview was not edited (task instruction); the architect should apply these. The P1-37 and P1-38 code (sources and tests) was typechecked on 2026-11-02 with Swift 6.4.2 (Xcode 27.2) in a throwaway package under `$TMPDIR`, against stubs of the overview §3 declarations it uses, with Swift 6 language mode and warnings as errors: `Build complete!`. The code was not run there; the steps above are the real verification.

1. **MacxFixtures names.** `ContentTestHarness` (P1-31 Step 1) uses S1 P1-02's `Sandbox(prefix:)`, `.root`, `.createDirectory(_:)`, `.createFile(_:contents:)`, `.setXattr(_:name:value:)` (P1-37) and `.destroy()`, exactly as S1's Interfaces block and its Contract note 1 define them.
2. **`DragOperation` has no symlink case** (referenced from P1-36 `DropChoice.init(menuChoice:)`). The scenario-only `probePerformDrop(…menuChoice:)` therefore can't choose Create Symbolic Link Here. Real right-drags use `DropChoice` directly and are unaffected. S6 Contract note C5 reaches the same conclusion. Adding `case symlink` to `DragOperation` (§3.11) would close it.
3. **Test interaction target.** From P1-37 on, `ContentTestHarness` sets `environment.interaction`'s target to a `ScriptedInteraction` (errors answer Skip, conflicts `.one(.skip)`), because `UIContext` installs a dialog-showing interaction (`BasicAlertInteraction` until P1-38, then `InteractionRouter`) that would block a test. Tests that exercise the router install it explicitly.
4. **Properties edits report errors inline.** Properties jobs carry the Properties window's `windowNumber` as `OriginID` (§3.13 already defines `OriginID` as a window number). `InteractionRouter` answers `.skip` to `resolveError` for those origins (`PropertiesWindowController.answersErrorsInline(_:)`), and the window shows `ErrorText.jobError` for the skipped item and reverts the control (§5.8). Conflicts from those origins still show a dialog, as a sheet on the Properties window: `hostWindow(for:)` also accepts a visible window whose identifier is `AXID.propertiesWindow`.
5. **`InteractionRouter.hostWindow(for:) -> NSWindow?` is defined in P1-38**, and every Phase 1 decision about where a sheet goes goes through it. Phase 2's P2-05 lists it under Produces; it should modify it instead (select the origin tab, then return the window), as its own text describes.
6. **Additive UI members** outside §3.14: `UIContext.operationsUI` (internal) and `public func showOperationsPanel()` (the app delegate's Window › Operations calls it when no browser window is open); `AXID.operationsPanel = "macx.operationsPanel"`; `InteractionRouter.init(windows:presenter:resolveHost:)` beside the contract's `init(windows:)`; `DefaultAppSheet.present(for:on:context:alwaysChecked:opensFile:)` and `DefaultAppChoice.setDefault(app:file:allOfType:provider:)`. Properties' Change…/Change All… set the default without opening the file.
7. **S3 initializers in UI tests.** The router and dialog tests build `JobSnapshot`, `JobDescription`, `JobProgress()`, `ItemSummary`, `ConflictPair`, `ConflictInfo` and `SpaceShortfall` with the public initializers that S3 P1-17 adds (marked *additive* there). S6 Contract note C7 assumes none exist; with S3's additions, S6 could use them too.
8. **Window › Operations handler.** The S4 plan wasn't available while this was written. P1-38 Step 9 tells the implementer to point P1-30's handler (AppLifecycle's Window › Operations entry) at `UIContext.showOperationsPanel()`, or to add `macx_showOperations(_:)` to the app delegate if P1-30 added none.
9. **"Apply to enclosed items…" and execute bits.** S3's `chmodRecursive` applies one set of rwx bits to directories and files (`ModeChange.mode`). With a folder's mode (for example 0755), enclosed files become executable. Finder keeps file x bits. A later Core addition (for example `ModeChange.preservesFileExecuteBits`) would let P1-37 match Finder. P1-37 sends one job, as §5.8 says, and its test asserts only the enclosed folder's mode.
10. **`FolderCounter` counts the folder's contents, not the folder itself.** `PropertiesViewModelTests.testFolderShowsLiveCountThatFinishes` pins `files == 3, folders == 1` for `F/{a,b,sub/c}`, and asserts only `bytes >= 60` (logical or allocated). If S2 P1-16 counts the root, change that test's expectation, not the UI.
11. **Jobs younger than 1 s.** `OperationsCenter.visibleJobs` depends on the clock, so observation alone doesn't re-evaluate it at the 1 s mark. The capsule polls every 250 ms while `jobs` is non-empty, and the job list sits inside a `TimelineView(.periodic(by: 0.5))`.
12. **Stop and Quit with a dialog open (consistency pass, from S3 Contract note 18).** `InteractionRouter.stopAnswering()` closes every open dialog unanswered and answers every waiting or later question with its fallback (`.cancelJob` / `.cancel` / `false`). P1-38 Step 9 makes P1-30's Stop and Quit handler call `context.operationsUI.router.stopAnswering()` right before `environment.termination.stopAllAndWait()`, so a job suspended on a dialog finishes its cancel path inside the 10 s timeout. Each dialog now runs in a child `Task` that the router can cancel; presenters already treat cancellation as "went away". Pinned by `testStopAnsweringEndsOpenDialogsAndAnswersLaterQuestionsSafely` (P1-38 now has 24 tests in its filter).
