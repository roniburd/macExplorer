# macExplorer Phase 2 (Views & Tabs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the spec §11 "Phase 2 — Views & Tabs" features to the working Phase 1 app: native tabs (⌘T, ⌃Tab, ⌘W, middle-click / ⌘-click to open in a new tab, drop a folder on the tab bar), per-folder view state with "Apply to All Folders", Group by (Kind, Date Modified, Size, Name first letter) with collapsible floating group rows, Quick Look on Space, on-demand folder sizes, more columns (Tags, Date Last Opened, Permissions, Owner, Path, Comments), copy-path variants, thumbnails in Icons view, and a Columns (Miller) view, all within the §4.4 budgets.

**Architecture:** Phase 2 only extends Phase 1 layers (`App → UI → Core → MacxFS → CFSKit`) and the Phase 1 Interface Contract (`docs/superpowers/plans/2026-11-01-phase1-00-overview.md` §3). Pure logic (grouping partition, date/size/letter buckets, grouped-row mapping, per-folder view keys, path formatting, xattr parsing, folder-size scanning, subtree event classification, thumbnail scheduling, column chains) lives in `MacxFS`/`Core` or in AppKit-free UI helper types and is unit tested. AppKit and Quick Look glue (`NSWindow` tabbing, `NSTableView` group rows, `QLPreviewPanel`, `QLThumbnailGenerator`, Columns view tables) lives in `UI`. Blocking work runs on I/O lanes, as in Phase 1: folder-size scans and the "load attributes for every row before sorting" step use a new `LaneClass.scan` so they never delay listing.

**Tech Stack:** Swift 6.4 toolchain (Xcode 27.2 at `/Applications/Xcode.app`), swift-tools-version 6.2, Swift 6 language mode, AppKit (`NSWindow` tabbing, `NSTableView` group rows), Quartz (`QLPreviewPanel`, UI target only), QuickLookThumbnailing (`QLThumbnailGenerator`, UI target only), Foundation (`PropertyListSerialization` for Finder xattrs), CoreServices (FSEvents), Darwin (`getxattr`, `fstatat`, `getpwuid_r`), XCTest via `swift test`. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-01-macexplorer-design.md` §11 Phase 2 (source of truth), plus the sections it relies on: §4.2 (lanes, materialization policy, icon tiers), §4.3 (FolderModel, Watcher, Settings), §4.4 (budgets), §5.5 (content views), §5.6 (key routing, clipboard), §8 (accessibility). Phase 1 interface contract: `docs/superpowers/plans/2026-11-01-phase1-00-overview.md` §3. Research: `docs/research/explorer.md` §12, `docs/research/finder.md`, `docs/research/perf.md` §7.

**Prerequisite:** Phase 1 is complete: P1-42's "working" definition holds on the branch this plan starts from. Run it first (Task P2-00). Phase 2 task IDs are `P2-00` … `P2-20` and run in ID order; that order is a valid topological order of the dependency table at the end of this document.

## Global Constraints

Every task implicitly includes all of these, plus every Global Constraint in the Phase 1 overview (which this list repeats where it matters most).

**Safety (HARD RULE, applies to tests, benchmarks, scenario runners, scripts and any manual or automated validation):**
- Tests, benchmarks and any manual or automated validation must ONLY create, modify or delete files inside fresh temporary directories they create themselves (`FileManager.default.temporaryDirectory/macx-tests-<UUID>`, `macx-bench-<UUID>`, `macx-scenario-<UUID>`) or inside disk images they create themselves (created inside such a directory and attached with `-mountpoint <that dir>/mnt-<n> -nobrowse`).
- Never touch, move, rename, trash or delete any pre-existing user file. The app may READ the user's real folders when a human browses, but automated scenarios must point the app at a sandbox dir (`--root <sandbox>` plus `--state-dir <sandbox>/state`).
- All fixture writes, including Phase 2's extended-attribute writes (Finder tags, Finder comments, last-used dates), modification-date changes and generated PNG images, go through `MacxFixtures.Sandbox` (P2-03 adds `FixtureMetadata` helpers to it), which refuses any path outside its root after symlink resolution.
- Quick Look, thumbnail, folder-size and extended-attribute tests and scenarios only reference files inside their own sandbox. No test passes a path under the real home folder to `QLPreviewPanel`, `QLThumbnailGenerator`, `FolderSizeScanner` or `ExtendedAttributeReader`.
- Scenarios never open, middle-click or ⌘-click sidebar Favorites or Locations rows, because those point at real user folders. Tab scenarios use content rows and `tree:` nodes inside the sandbox root. A new tab opened with ⌘T in sandbox mode shows `--root`, never Home (P2-05).
- Tests never use `UserDefaults.standard`, `UserDefaults(suiteName:)`, `NSPasteboard.general`, `SystemTrash()`, the real journal path or real `WorkspaceLaunchServices` writes, as in Phase 1. Per-folder view state in tests uses `InMemorySettingsStorage`, and in scenario runs it uses the `FileSettingsStorage` under `--state-dir`.
- The single manual tab-restoration check (P2-06 Step 9) uses its own bundle id, `com.macexplorer.app.restore-check`. Before launch, the operator verifies that `~/Library/Saved Application State/com.macexplorer.app.restore-check.savedState` and `~/Library/Preferences/com.macexplorer.app.restore-check.plist` do not exist. Only a sandbox directory is browsed during the check. Afterwards the operator deletes exactly those two paths, which the check created, and nothing else.

**Platform and language (from Phase 1, unchanged):**
- macOS 26 minimum, `// swift-tools-version: 6.2`, Swift 6 language mode, `.treatAllWarnings(as: .error)` on every Swift target.
- No `@unchecked Sendable` and no `nonisolated(unsafe)` in `MacxFS` or `Core`. `UI` may wrap a non-Sendable framework value (for example a `CGImage` if the SDK does not mark it Sendable) in a file-private `@unchecked Sendable` box. The box carries a comment explaining the confinement, and the task review calls it out.
- `MacxFS` and `Core` never import AppKit, Quartz or QuickLookThumbnailing (outside `Sources/Core/Platform/`). `scripts/check-layering.sh` (P1-42) is extended in P2-20 to cover Quartz and QuickLookThumbnailing.
- No synchronous file-system calls on the main thread (§4.4), including `lstat`, `getxattr`, `getpwuid`, `resourceValues`, `fileExists` and Quick Look calls that read files. Drop validation on the tab bar is in-memory (`URL.hasDirectoryPath`), and directory-ness is confirmed on a lane only in `performDragOperation`.
- Background reads that must not download iCloud/File Provider content run inside `withNoMaterialization { }`. In Phase 2 that covers folder-size scans, extended-attribute reads for columns, and the identity probe for per-folder view state. Thumbnails are never requested for `EntryFlags.dataless` items (§11).
- All user-visible strings go into `Sources/UI/Resources/Localizable.xcstrings` via `L10n`. Core produces typed values (`GroupKey`, `DateBucket`, `SizeBucket`, `FolderSize`, `ExtendedAttributes`) that UI formats.
- Every new view the scenario runner needs gets an accessibility identifier in `AXID` (P2-03 adds them). Every icon-only control has an accessibility label. Group header rows are announced as "<title>, <count> items, collapsed/expanded".
- Inclusive language. One commit per task minimum, with a conventional prefix, on the working branch. Never push.

**Performance budgets (§4.4, unchanged; Phase 2 must keep every one):**

| Event | Budget |
|---|---|
| Navigate → first rows painted (any size) | < 50 ms |
| 100k entries fully listed + sorted | < 250 ms |
| Re-sort 100k by any column | < 30 ms (Phase 2: includes the Group by partition when grouping is on; for Tags/Last Opened/Permissions/Owner/Comments it applies once their values are loaded) |
| Scroll | 120 fps; cell configure < 0.5 ms (including extended columns, group rows, column-view cells, thumbnail cells) |
| Main-thread hang | none > 100 ms |
| Type icons visible | first frame (thumbnails replace icons later; they never delay first paint) |
| FSEvent → UI updated (incremental path) | < 150 ms (including grouped folders) |
| Memory, 100k-entry folder | < 20 MB steady state, < 40 MB peak, excluding images (the thumbnail `NSCache` has its own 64 MB cost limit) |

Non-gated Phase 2 targets, reported by `macx-bench` and signposts: thumbnails visible < 300 ms after rows are visible for local files (`docs/research/perf.md`); 10k-file folder-size scan; extended attributes for 2,000 rows.

**Testing:** XCTest via `swift test`; `swift test --parallel` must pass. TDD per task: failing test, implementation, green, commit. Every task ends with `swift build 2>&1 | tail -5` showing `Build complete!` with zero warnings, and `swift test --filter <TaskTests> 2>&1 | tail -5` showing `Executed N tests, with 0 failures`. GUI-dependent UI tests call `try requireGUISession()` (P2-03), which throws `XCTSkip` without a window server. Every user-facing feature also gets at least one `Tests/Scenarios/p2-*.json` scenario, which `scripts/ui-scenarios.sh` (P1-41) runs automatically.

**Phase 1 names this plan builds on:** `Sandbox` method names in test code (`Sandbox()`, `.root`, `.write(_:bytes:)`, `.mkdir(_:)`, `.url(_:)`, `.symlink(_:to:)`, `.hardLink(_:to:)`, `.destroy()`) follow P1-02. If P1-02 chose different names for the same operations, use P1-02's names. The semantics are identical, and the guard rule is the same. The same applies to the Phase 1 main-menu titles used in scenario `menu` steps (P1-29). Check `MainMenuBuilder` and use its exact titles.

**P2-00 baseline result (2026-11-05): use the real Phase 1 names in place of the plan's names.** Every later task MUST translate the plan's test code like this:

| Plan writes | Real Phase 1 API (`Sources/MacxFixtures`) |
|---|---|
| `Sandbox()` | `try Sandbox()` (throws; `init(prefix: String = "macx-tests")`, also `init(adopting:)`) |
| `.root`, `.url(_:)`, `.destroy()` | same names |
| `.write(_ rel, bytes: n)` | `.createFile(_ rel, contents: Data(count: n))` (`contents` defaults to `"x"`; returns the URL, discardable) |
| `.mkdir(_ rel)` | `.createDirectory(_ rel)` |
| `.symlink(_ rel, to: target)` | `.createSymlink(_ rel, target: target)` |
| `.hardLink(_ rel, to: existing)` | `.createHardLink(_ rel, to: existing)` |
| `DiskImage.create(in:sizeMB:format:)` | `DiskImage.create(in:format:sizeMB:volumeName:readOnly:populate:)`. `format` comes before `sizeMB`. |

The sandbox also has `createSparseFile`, `createAlias`, `overwrite`, `append`, `setFlags`, `setMode`, `setXattr`, `setHiddenExtension`, `setDates`, `rename` and `remove`. Use them before you add new fixture helpers. Main-menu titles live in `Sources/UI/Menus/MainMenuTitles.swift`, and the top-level menus are MacExplorer, File, Edit, View, Go, Window and Help. Every Phase 1 title the plan uses matches: "Copy as Path", "View › Sort By › Size", "as Details", "as Icons". `Settings.schemaVersionKey` already exists with the value `"schemaVersion"`.

## Review Focus

These are the five inputs that the spec implies but no feature test would naturally exercise, ordered by how likely each is to hurt a user first. Each line names the owning task, which MUST include the listed test.

1. **Pressing Space while type-selecting a name that contains a space** (typing `my f` to reach `my file.txt`). Expected: while the type-select buffer is collecting (last keystroke < 1 s ago), Space is appended to the buffer and does not toggle Quick Look. Once the buffer has timed out, Space toggles Quick Look. Owner P2-11: `testSpaceDuringTypeSelectGoesToTypeSelect` and scenario `p2-quicklook-typeselect.json`.
2. **A tag or comment change made by another app that only touches an xattr** (mtime unchanged, so `StoreDiff` emits no reload). Expected: the FSEvent for that item drops its cached `ExtendedAttributes`, the visible row is re-read, and the Tags/Comments cell updates within 1 s. Owner P2-15: `testXattrOnlyChangeRefreshesExtendedAttributes` and scenario step `fsTags` in `p2-extra-columns.json`.
3. **Folder-size scans over hard links, symlink loops, a mount point inside the tree, an unreadable subfolder and a dataless folder.** Expected: hard links are counted once, symlinks are never followed (so loops terminate), mount points are not crossed, and unreadable or dataless parts mark the result `isPartial`, shown as "≥ 1.2 MB". The scan finishes, and cancelling it stops it within one directory. Owner P2-12: `testScannerHardLinksSymlinkLoopUnreadableDatalessAndMountPoint` (the mount point is a disk image the test attaches inside its sandbox tree).
4. **A conflict or error dialog for a job started from a tab that is no longer selected.** Expected: `InteractionRouter` selects the origin tab before presenting the sheet, so the dialog is never hidden behind another tab. If the origin tab has closed, the dialog goes to the Operations panel (Phase 1 rule). Owner P2-05: `testRouterSelectsOriginTabBeforePresentingSheet` and `testRouterFallsBackToPanelWhenOriginTabClosed`.
5. **Holding ↓ in the Columns view over a column of 50 folders.** Expected: when key repeat stops there is exactly one child column, showing the last folder. Every intermediate child `FolderModel` is closed: its read is cancelled and its watcher stopped. Late batches from closed models never reach the visible columns, and the active column's selection is not disturbed. Owner P2-18: `testRapidSelectionInColumnClosesIntermediateModels`.

---

## 1. File structure (Phase 2)

New files (owning task in brackets) and modified Phase 1 files.

```
Sources/FSKit/Sort/GroupBy.swift                  [P2-01] GroupBy enum (+ isAvailable(in:))
Sources/FSKit/Sort/Grouping.swift                 [P2-09] GroupKey, DateBucket(s), SizeBucket, LetterKey, GroupRun, Grouping.partition
Sources/FSKit/Sort/SortExtras.swift               [P2-14] SortExtras (folder sizes; P2-16 adds the extended column)
Sources/FSKit/Lanes/LanePool.swift                [P2-12 modifies] LaneClass.scan
Sources/FSKit/Sort/ViewQuery.swift                [P2-01 modifies] new SortField cases, SortField.entryFields, isExtended
Sources/FSKit/Sort/Sorter.swift                   [P2-14, P2-16 modify] extras parameter

Sources/MacxFixtures/FixtureMetadata.swift        [P2-03] guarded setxattr / mtime / Finder tags / comment / last-used / PNG writers

Sources/Core/Settings/SettingsTypes.swift         [P2-01 modifies] ViewMode.columns, new ColumnIDs, defaultWidth
Sources/Core/Settings/Settings.swift              [P2-01 modifies] schemaVersion 2, groupBy, showThumbnails, columnWidth, migrateColumns
Sources/Core/Commands/Command.swift               [P2-02 modifies] Phase 2 commands + selector names
Sources/Core/Commands/KeyMap.swift                [P2-02 modifies] ⌘T, ⌃Tab, ⌃⇧Tab, ⌘⇧\, ⌘1/⌘2/⌘3, Space alternate
Sources/Core/Commands/KeyDispatcher.swift         [P2-02 modifies] Space → quickLook (content), ⌃Tab never cycles focus
Sources/Core/Commands/CommandAvailability.swift   [P2-02 modifies] CommandState fields + rules
Sources/Core/Clipboard/PasteboardBackend.swift    [P2-04 modifies] writeString / readString
Sources/Core/Platform/SystemPasteboard.swift      [P2-04 modifies] writeString / readString
Sources/Core/Paths/PathFormatter.swift            [P2-04] PathStyle, PathItem, PathFormatter
Sources/Core/ViewState/FolderViewState.swift      [P2-07] FolderViewState, FolderViewKey, FolderViewLocator
Sources/Core/ViewState/FolderViewStore.swift      [P2-07] persisted LRU store (5,000 records), path index, debounce
Sources/Core/ViewState/FolderIdentityProbe.swift  [P2-07] lstat st_ino of a folder on a read lane
Sources/Core/Folder/GroupedRows.swift             [P2-09] TableRow, GroupedRows (table row ⇄ model row)
Sources/Core/Folder/FolderModel+Grouping.swift    [P2-09] setGrouping, regroup on change / new day
Sources/Core/Sizes/FolderSize.swift               [P2-12] FolderSize, FolderSizeIdentity, FolderSizeKey
Sources/Core/Sizes/FolderSizeScanner.swift        [P2-12] synchronous scan (lane, no materialization)
Sources/Core/Sizes/FolderSizeCache.swift          [P2-13] @MainActor LRU keyed by identity + mtime, ancestor invalidation
Sources/Core/Sizes/FolderSizeService.swift        [P2-13] FolderSizeService + FolderSizeSession (priority queue, cancel, watcher)
Sources/Core/Watch/SubtreeEventClassifier.swift   [P2-13] pure: raw events → affected child names
Sources/Core/Watch/SubtreeWatcher.swift           [P2-13] recursive FSEventStream, directory granularity, 1 s latency
Sources/Core/Support/ChangeBus.swift              [P2-13 modifies] observeAll
Sources/Core/Folder/FolderModel+Sizes.swift       [P2-13 storage, P2-14 enable flag + coalesced re-sort + selection folder bytes]
Sources/Core/Attributes/ExtendedAttributes.swift  [P2-15] ExtendedAttributeSet, ExtendedAttributes
Sources/Core/Attributes/FinderMetadata.swift      [P2-15] xattr names + parsers (tags, comment, last used)
Sources/Core/Attributes/PermissionsFormatter.swift[P2-15] mode → "drwxr-xr-x"
Sources/Core/Attributes/OwnerNameCache.swift      [P2-15] uid → name (getpwuid_r), Mutex cache
Sources/Core/Attributes/ExtendedAttributeReader.swift [P2-15] synchronous batch read (lane, no materialization)
Sources/Core/Folder/FolderModel+Attributes.swift  [P2-15] per-row attribute table, visible fetch, invalidation
Sources/Core/Folder/FolderModel.swift             [P2-09/14/15 modify] FolderEvent cases, FolderContext defaults
Sources/Core/Support/CoreEnvironment.swift        [P2-07/13/15 modify] folderViews, folderSizes, ownerNames

Sources/UI/Support/AXID.swift                     [P2-03 modifies] Phase 2 identifiers
Sources/UI/Scenario/ScenarioFile.swift            [P2-03 modifies] Phase 2 schema fields
Sources/UI/Scenario/ScenarioDriver.swift          [P2-03 modifies] new steps, token substitution, new expectations
Sources/UI/Scenario/ScenarioProbe.swift           [P2-03 modifies] Phase 2 probes + hooks
Sources/UI/Menus/CopyPathMenu.swift               [P2-04] "Copy Path As ▸" submenu builder
Sources/UI/Tabs/TabController.swift               [P2-05] openTab, newWindowForTab, tab titles, tab ordering helpers
Sources/UI/Tabs/TabBarDropOverlay.swift           [P2-06] drop target over the native tab bar (spike-gated)
Sources/UI/Tabs/NewTabToolbarItem.swift           [P2-06] "＋" toolbar item: click = new tab, drop folders = tabs
Sources/UI/Content/MiddleClickRouter.swift        [P2-06] middle-click / ⌘-click → open in new tab
Sources/UI/ViewState/FolderViewCoordinator.swift  [P2-08] apply/save per-folder state, identity correction, Apply to All
Sources/UI/Details/RowMapping.swift               [P2-10] identity vs grouped mapping used everywhere in Details
Sources/UI/Details/GroupHeaderView.swift          [P2-10] disclosure + title + count group row
Sources/UI/QuickLook/QuickLookController.swift    [P2-11] QLPreviewPanel data source/delegate, toggle, arrow forwarding
Sources/UI/Details/ExtendedColumns.swift          [P2-16] column definitions, cell text, chooser rules
Sources/UI/Icons/ThumbnailCache.swift             [P2-17] NSCache (64 MB cost) keyed by ThumbnailKey
Sources/UI/Icons/ThumbnailScheduler.swift         [P2-17] visible-only requests, cancel on scroll-off, max 8 in flight
Sources/UI/Icons/QLThumbnailGeneratorAdapter.swift[P2-17] ThumbnailGenerating over QLThumbnailGenerator
Sources/UI/Columns/ColumnChain.swift              [P2-18] owned FolderModels per column, activate/move/truncate/reroot
Sources/UI/Columns/ColumnsViewController.swift    [P2-19] horizontal stack of columns, FileListView forwarding
Sources/UI/Columns/BrowserColumnController.swift  [P2-19] one NSTableView column over one FolderModel (FileListView)
Sources/UI/Columns/ColumnCellView.swift           [P2-19] icon + name + folder chevron cell
Sources/UI/Window/BrowserSession.swift            [P2-08/18 modify] per-folder state on navigate, columns mode
Sources/UI/Window/BrowserWindowController.swift   [P2-05/11 modify] tabbing, newWindowForTab, QL panel control
Sources/UI/App/WindowManager.swift                [P2-05 modifies] openTab, tab-aware window(for:)
Sources/UI/Operations/InteractionRouter.swift     [P2-05 modifies] select origin tab before sheet
Sources/UI/Details/DetailsViewController.swift    [P2-10/14/16 modify] RowMapping, group rows, sizes, extended columns
Sources/UI/Details/DetailsColumns.swift           [P2-16 modifies] chooser with new columns
Sources/UI/Icons/IconsViewController.swift        [P2-17 modifies] thumbnails
Sources/UI/Menus/MainMenuBuilder.swift            [P2-02/04/05 modify] new menu items
Sources/UI/Menus/ContextMenuBuilder.swift         [P2-04/06/10 modify] Open in New Tab, Copy Path As ▸, Group by ▸
Sources/UI/Menus/KeyRouter.swift                  [P2-11 modifies] Space vs type-select
Sources/UI/Content/TypeSelect.swift               [P2-11 modifies] isCollecting
Sources/UI/Toolbar/ToolbarController.swift        [P2-06/19 modify] Columns segment, new-tab item
Sources/macx-bench/Metrics.swift                  [P2-20 modifies] grouped re-sort, folder size, extended attributes
Sources/macx-bench/Budgets.swift                  [P2-20 modifies] resort-grouped < 30 ms
scripts/check-layering.sh                         [P2-20 modifies] Quartz / QuickLookThumbnailing confined to UI

Tests/FSKitTests/GroupingTests.swift              [P2-09]
Tests/FSKitTests/SortExtrasTests.swift            [P2-14, P2-16]
Tests/CoreTests/SettingsV2Tests.swift             [P2-01]
Tests/CoreTests/Phase2KeyMapTests.swift           [P2-02]
Tests/CoreTests/PathFormatterTests.swift          [P2-04]
Tests/CoreTests/FolderViewStoreTests.swift        [P2-07]
Tests/CoreTests/GroupedRowsTests.swift            [P2-09]
Tests/CoreTests/FolderModelGroupingTests.swift    [P2-09]
Tests/CoreTests/FolderSizeScannerTests.swift      [P2-12]
Tests/CoreTests/FolderSizeServiceTests.swift      [P2-13]
Tests/CoreTests/SubtreeEventClassifierTests.swift [P2-13]
Tests/CoreTests/FolderModelSizesTests.swift       [P2-14]
Tests/CoreTests/ExtendedAttributesTests.swift     [P2-15]
Tests/CoreTests/Support/ModelLoading.swift        [P2-09] loadedModel(_:env:query:) (copy of the UITests helper)
Tests/CoreTests/Support/VolumeInfoFixtures.swift  [P2-12] VolumeInfo builder for mount-table tests
Tests/UITests/Support/ModelLoading.swift          [P2-06] loadedModel(_:env:query:)
Tests/UITests/FolderSizeTextTests.swift           [P2-14; merged into ExtendedColumnsTests by P2-16]
Tests/MacxFixturesTests/FixtureMetadataTests.swift[P2-03]
Tests/UITests/Support/GUI.swift                   [P2-03] requireGUISession()
Tests/UITests/ScenarioSchemaTests.swift           [P2-03]
Tests/UITests/CopyPathMenuTests.swift             [P2-04]
Tests/UITests/TabTests.swift                      [P2-05]
Tests/UITests/MiddleClickTests.swift              [P2-06]
Tests/UITests/FolderViewCoordinatorTests.swift    [P2-08]
Tests/UITests/GroupedDetailsTests.swift           [P2-10]
Tests/UITests/QuickLookControllerTests.swift      [P2-11]
Tests/UITests/ExtendedColumnsTests.swift          [P2-16]
Tests/UITests/ThumbnailSchedulerTests.swift       [P2-17]
Tests/UITests/ColumnChainTests.swift              [P2-18]
Tests/UITests/ColumnsViewTests.swift              [P2-19]
Tests/Scenarios/p2-*.json                         [each feature task]
```

## 2. Phase 2 interface additions

Tasks copy these declarations exactly. Bodies belong to the owning task. Anything not listed is internal. If a task finds a contract bug, it fixes it here in the same commit and notes it in the task. Adding cases to the public enums `FolderEvent`, `Command`, `SortField`, `ColumnID` and `ViewMode` breaks Phase 1's exhaustive `switch` statements. The compiler lists each one, and the owning task updates each of them, with a behaviour stated in that task.

### 2.1 MacxFS

```swift
// Sort/GroupBy.swift (P2-01)
public enum GroupBy: String, Sendable, Codable, CaseIterable { case none, kind, dateModified, size, nameFirstLetter }

// Sort/ViewQuery.swift (P2-01 adds cases; Phase 1 cases keep their raw values)
public enum SortField: String, Sendable, Codable, CaseIterable {
    case name, dateModified, size, kind, dateCreated, fileExtension            // Phase 1
    case tags, dateLastOpened, permissions, owner, comments, path               // Phase 2
    public static let entryFields: [SortField]   // the six Phase 1 cases, in that order
    public var isExtended: Bool { get }          // tags, dateLastOpened, permissions, owner, comments
}

// Sort/Grouping.swift (P2-09)
public enum DateBucket: Int, Sendable, Hashable, CaseIterable {
    case future, today, yesterday, earlierThisWeek, lastWeek, earlierThisMonth, lastMonth, earlierThisYear, longAgo
}
public enum SizeBucket: Int, Sendable, Hashable, CaseIterable {
    case folders, empty, tiny, small, medium, large, huge, gigantic   // Explorer buckets, binary units
}
public enum LetterKey: Hashable, Sendable { case digits, letter(String), other }
public enum GroupKey: Hashable, Sendable {
    case kind(String, isFolder: Bool)    // TypeRegistry.localizedDescription
    case date(DateBucket)
    case size(SizeBucket)
    case letter(LetterKey)
}
public struct GroupRun: Sendable, Equatable {
    public var key: GroupKey
    public var rows: Range<Int>          // model (display-order) rows of this group
    public init(key: GroupKey, rows: Range<Int>)
}
public struct DateBuckets: Sendable, Equatable {
    public init(now: Date, calendar: Calendar)
    public func bucket(forNanoseconds t: Int64) -> DateBucket
    public let nextBoundary: Date        // start of tomorrow: regroup then
}
public enum Grouping {
    public static func sizeBucket(bytes: Int64, isFolder: Bool) -> SizeBucket
    public static func letterKey(_ name: String) -> LetterKey
    public static func groupOrder(_ a: GroupKey, _ b: GroupKey) -> Bool   // strict weak order of groups
    /// Stable partition of an already sorted permutation into contiguous groups (in-group order preserved).
    /// `.none` returns (sorted, []).
    public static func partition(_ sorted: [UInt32], store: EntryStore, by groupBy: GroupBy,
                                 dateBuckets: DateBuckets, types: TypeRegistry) -> (order: [UInt32], runs: [GroupRun])
}

// Sort/SortExtras.swift (P2-14; P2-16 adds `column`)
public enum ExtraSortValues: Sendable {
    case integers([Int64?])                       // by storage index; nil sorts last in both directions
    case strings([[UInt8]?])                      // SortKeys.nameKey(isFolder: false) bytes by storage index; nil last
}
public struct SortExtras: Sendable {
    public var folderSizes: [UInt32: Int64]       // storage index → computed folder size (bytes)
    public var column: ExtraSortValues?           // P2-16: values for query.sort.field when isExtended
    public init(folderSizes: [UInt32: Int64] = [:], column: ExtraSortValues? = nil)
    public static let none: SortExtras
}
extension Sorter {
    /// Phase 1 permutation plus: size sort orders folders by folderSizes (unknown last, name tie-break);
    /// isExtended fields order by `column` (nil last), name tie-break; `.path` orders like `.name`.
    public static func permutation(_ store: EntryStore, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                   query: ViewQuery, kindRanks: [UInt16], extras: SortExtras) -> [UInt32]
}

// Lanes/IOLane.swift (P2-12 adds a case)
public enum LaneClass: Sendable, Hashable { case read, fileOp, scan }   // scan: folder sizes, bulk attribute loads
```

### 2.2 Core

```swift
// Settings/SettingsTypes.swift (P2-01)
public enum ViewMode: String, Sendable, Codable, CaseIterable { case details, icons, columns }
public enum ColumnID: String, Sendable, Codable, CaseIterable {
    case name, dateModified, size, kind, dateCreated, fileExtension            // Phase 1
    case tags, dateLastOpened, permissions, owner, path, comments               // Phase 2
    public var sortField: SortField { get }
    public var defaultWidth: Double { get }   // 280,160,80,150,160,70 (Phase 1's real defaults, P2-01), 120,150,100,90,260,200
}
// Settings/Settings.swift (P2-01): schemaVersion becomes 2
extension Settings {
    public var groupBy: GroupBy               // .none   (default for folders without their own state)
    public var showThumbnails: Bool           // true
    public var columnWidth: Double            // 220 (Columns view, last width the user set)
    public static func migrateColumns(_ stored: [ColumnSetting]) -> [ColumnSetting]   // dedupe + append missing ids, invisible
    public func defaultFolderViewState() -> FolderViewState
    public func applyDefaultView(_ state: FolderViewState)   // sets viewMode, columns, sort, iconSize, groupBy
}

// Commands/Command.swift (P2-02 adds)
//   newTab, nextTab, previousTab, showTabBar, showAllTabs, moveTabToNewWindow, mergeAllWindows, openInNewTab,
//   quickLook, viewAsColumns, groupByNone, groupByKind, groupByDateModified, groupBySize, groupByName,
//   toggleFolderSizes, applyViewToAllFolders, copyPathTilde, copyPathFileURL, copyName, copyPathShellQuoted
// selectorName: newTab "newWindowForTab:", nextTab "selectNextTab:", previousTab "selectPreviousTab:",
//   showTabBar "toggleTabBar:", showAllTabs "toggleTabOverview:", moveTabToNewWindow "moveTabToNewWindow:",
//   mergeAllWindows "mergeAllWindows:"; the rest "macx_<rawValue>:".
// P2-02 addition: public static let windowTabCommands: Set<Command> (the seven NSWindow tab actions above) and
//   public var isWindowTabCommand: Bool. CommandHandlingViewController never implements those selectors, so the
//   panes cannot intercept NSWindow's (or BrowserWindowController's newWindowForTab:) handling.
// P2-02 addition: FocusContext.isSidebar (true for the four sidebar cases).

// Commands/CommandAvailability.swift (P2-02 adds fields, defaulted, appended to the init)
extension CommandState {
    public var selectedFolderCount: Int       // 0
    public var quickLookVisible: Bool         // false
    public var viewMode: ViewMode             // .details
}

// Clipboard/PasteboardBackend.swift (P2-04 adds requirements; InMemoryPasteboard + SystemPasteboard implement)
//   @discardableResult func writeString(_ string: String) -> Int   // plain text only; returns new changeCount
//   func readString() -> String?

// Paths/PathFormatter.swift (P2-04)
public enum PathStyle: String, Sendable, Codable, CaseIterable { case posix, tilde, fileURL, name, shellQuoted }
public struct PathItem: Sendable, Equatable { public var url: URL; public var isDirectory: Bool; public init(url: URL, isDirectory: Bool) }
// As built (P2-04 review fix): PathItem stores `path: String` (not `url`); inits `init(path:isDirectory:)`,
// `init(url:isDirectory:)` and `init(directory:name:isDirectory:)` (raw row names, no NFD). See "P2-04 result (as built)".
public enum PathFormatter {
    /// One item per line ("\n"); shellQuoted joins with a single space.
    public static func format(_ items: [PathItem], style: PathStyle, home: URL) -> String
    public static func one(_ item: PathItem, style: PathStyle, home: URL) -> String
    public static func tilde(_ path: String, home: String) -> String
    public static func shellQuote(_ path: String) -> String
}

// ViewState/FolderViewState.swift (P2-07)
public struct FolderViewState: Sendable, Codable, Equatable {
    public var mode: ViewMode
    public var columns: [ColumnSetting]
    public var sort: SortDescriptor
    public var iconSize: IconSize
    public var groupBy: GroupBy
    public var calculateFolderSizes: Bool
    public init(mode: ViewMode, columns: [ColumnSetting], sort: SortDescriptor, iconSize: IconSize,
                groupBy: GroupBy, calculateFolderSizes: Bool)
}
public enum FolderViewKey: Hashable, Sendable, Codable {
    case object(volumeUUID: String, fileID: UInt64)   // idStable volume with a "uuid:" VolumeID
    case path(String)                                 // NFC; lowercased when the volume is case-insensitive
}
public struct FolderViewLocator: Sendable, Equatable {
    public var path: String                   // standardized, no trailing slash
    public var volume: VolumeInfo?
    public var fileID: UInt64?
    public init(url: URL, volume: VolumeInfo?, fileID: UInt64?)
    public var objectKey: FolderViewKey? { get }
    public var pathKey: FolderViewKey { get }
    public var primaryKey: FolderViewKey { get }      // objectKey ?? pathKey
}
// ViewState/FolderViewStore.swift (P2-07)
@MainActor
public final class FolderViewStore {
    public static let storageKey: String      // "folderViews.v1"
    public static let capacity: Int           // 5_000
    public init(storage: any SettingsStorage, defaults: @escaping @MainActor () -> FolderViewState,
                now: @escaping @MainActor () -> Date = { Date() }, flushDelay: Duration = .seconds(1))
    public func state(for locator: FolderViewLocator) -> FolderViewState   // object key, then path key, then defaults()
    public func hasOverride(for locator: FolderViewLocator) -> Bool
    public func save(_ state: FolderViewState, for locator: FolderViewLocator)
    public func removeAll()
    public func flush()                       // writes now (also called from applicationWillTerminate)
    public var count: Int { get }
}
// ViewState/FolderIdentityProbe.swift (P2-07)
public enum FolderIdentityProbe {
    /// lstat st_ino on a read lane under no-materialization; nil on error.
    public static func fileID(of url: URL, lanes: LanePool, volume: VolumeID) async -> UInt64?
}

// Folder/GroupedRows.swift (P2-09)
public enum TableRow: Sendable, Equatable { case header(Int), item(Int) }   // group index / model row
public struct GroupedRows: Sendable, Equatable {
    public init(runs: [GroupRun], collapsed: Set<GroupKey>)
    public let runs: [GroupRun]
    public let collapsed: Set<GroupKey>
    public let tableRowCount: Int
    public func row(_ tableRow: Int) -> TableRow
    public func tableRow(forGroup group: Int) -> Int
    public func tableRow(forModelRow modelRow: Int) -> Int?          // nil if its group is collapsed
    public func group(containingModelRow modelRow: Int) -> Int?
    public func modelRows(forTableRows rows: IndexSet) -> IndexSet   // headers dropped
    public func tableRows(forModelRows rows: IndexSet) -> IndexSet   // collapsed rows dropped
}

// Folder/FolderModel.swift (P2-09/14/15 add)
// FolderEvent gains:
//   case groups([GroupRun])               // after each regroup, immediately before its .changes(.reset)
//   case folderSizes(Set<RowID>)          // these rows' size cells changed
//   case extendedAttributes(Set<RowID>)   // these rows' extended cells changed
// FolderContext gains (defaulted, appended to the init):
//   public var now: @Sendable () -> Date                 // { Date() }
//   public var calendar: Calendar                        // .autoupdatingCurrent
//   public var resortCoalescing: Duration                // .milliseconds(500); tests pass .zero
//   public var ownerNames: OwnerNameCache                // shared cache
extension FolderModel {
    // P2-09
    public var grouping: GroupBy { get }
    public var groups: [GroupRun] { get }
    public func setGrouping(_ groupBy: GroupBy)
    public func regroupForNewDay()
    // P2-14
    public var folderSizesEnabled: Bool { get }
    public func setFolderSizesEnabled(_ on: Bool)        // off clears the table and emits .folderSizes(all)
    public func folderSize(atRow row: Int) -> FolderSize?
    public func setFolderSizes(_ sizes: [RowID: FolderSize])
    // P2-15
    public func extendedAttributes(atRow row: Int) -> ExtendedAttributes?
    public func requestExtendedAttributes(rows: Range<Int>, _ wanted: ExtendedAttributeSet)
}
// Folder/Selection.swift (P2-14): SelectionSummary gains
//   public var folderBytes: Int64?   // sizes on: sum of selected folders (0 if none selected), nil if any unknown; sizes off: nil

// Sizes (P2-12, P2-13)
public struct FolderSize: Sendable, Equatable, Codable {
    public var bytes: Int64           // logical bytes of every non-directory item, hard links once
    public var allocatedBytes: Int64
    public var files: Int
    public var folders: Int
    public var isPartial: Bool        // unreadable / dataless / degraded parts were skipped
    public init(bytes: Int64 = 0, allocatedBytes: Int64 = 0, files: Int = 0, folders: Int = 0, isPartial: Bool = false)
}
public enum FolderSizeIdentity: Hashable, Sendable { case object(VolumeID, UInt64), path(String) }
public struct FolderSizeKey: Hashable, Sendable {
    public var identity: FolderSizeIdentity
    public var mtime: Int64
    public init(identity: FolderSizeIdentity, mtime: Int64)
}
public enum FolderSizeScanner {
    /// Synchronous; lane only; wraps itself in withNoMaterialization. nil when cancelled.
    public static func scan(_ root: URL, context: LaneContext, mountTable: MountTable,
                            types: TypeRegistry = .shared, onDirectory: ((Int) -> Void)? = nil) -> FolderSize?
}
@MainActor public final class FolderSizeCache {
    public init(capacity: Int = 20_000)
    public func value(for key: FolderSizeKey) -> FolderSize?     // nil when absent or mtime differs
    public func store(_ size: FolderSize, for key: FolderSizeKey, path: String)
    public func invalidate(_ identity: FolderSizeIdentity)
    public func invalidateAncestors(ofDirectory path: String)    // entries whose path == path or is an ancestor of it
    public var count: Int { get }
}
@MainActor public final class FolderSizeService {
    public init(lanes: LanePool, mountTable: MountTableStore, changeBus: ChangeBus,
                makeSubtreeWatcher: @escaping @MainActor (URL, @escaping @Sendable (SubtreeChange) -> Void) -> any ContentWatching,
                maxConcurrentScans: Int = 2)
    public let cache: FolderSizeCache
    public func attach(to model: FolderModel) -> FolderSizeSession
}
@MainActor public final class FolderSizeSession {
    public func setVisibleRows(_ rows: Range<Int>)   // visible folders scan first
    public func stop()                               // cancels scans, stops the subtree watcher
    public var pendingCount: Int { get }
    public var inFlightCount: Int { get }
    public func waitUntilIdle() async                // tests
}
public enum SubtreeChange: Sendable, Equatable { case children(Set<String>), all }
public enum SubtreeEventClassifier {
    public static func classify(_ events: [RawFSEvent], folder: String) -> SubtreeChange?
}
public final class SubtreeWatcher: ContentWatching {
    /// Recursive stream on `directory`, no FileEvents flag (directory granularity), latency 1 s.
    public init(directory: URL, latency: Duration = .seconds(1), handler: @escaping @Sendable (SubtreeChange) -> Void)
    public func start()
    public func stop()
    public var lastEventID: UInt64 { get }
}
// Support/ChangeBus.swift (P2-13 adds)
//   public func observeAll(_ handler: @escaping @MainActor (LocalChange) -> Void) -> ObserverToken

// Attributes (P2-15)
public struct ExtendedAttributeSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let tags, lastOpened, permissions, owner, comments: ExtendedAttributeSet
    public static let all: ExtendedAttributeSet
    public init(sortField: SortField)        // [] for non-extended fields
    public init(column: ColumnID)            // [] for Phase 1 columns and .path
}
public struct ExtendedAttributes: Sendable, Equatable {
    public var loaded: ExtendedAttributeSet
    public var tags: [String]                // [] when none
    public var lastOpened: Date?
    public var mode: UInt16?
    public var ownerID: UInt32?
    public var ownerName: String?
    public var comment: String?
    public init(loaded: ExtendedAttributeSet = [])
    public func merging(_ other: ExtendedAttributes) -> ExtendedAttributes
}
public enum FinderMetadata {
    public static let tagsXattr: String      // "com.apple.metadata:_kMDItemUserTags"
    public static let commentXattr: String   // "com.apple.metadata:kMDItemFinderComment"
    public static let lastUsedXattr: String  // "com.apple.lastuseddate#PS"
    public static func parseTags(_ data: Data) -> [String]
    public static func parseComment(_ data: Data) -> String?
    public static func parseLastUsed(_ data: Data) -> Date?
    public static func encodeTags(_ tags: [String]) -> Data          // fixtures
    public static func encodeComment(_ comment: String) -> Data      // fixtures
    public static func encodeLastUsed(_ date: Date) -> Data          // fixtures
}
public enum PermissionsFormatter { public static func string(mode: UInt16, kind: Kind) -> String }
public final class OwnerNameCache: Sendable { public init(); public func name(for uid: UInt32) -> String }
public enum ExtendedAttributeReader {
    /// Synchronous; lane only; wraps itself in withNoMaterialization. Missing names are absent from the result.
    public static func read(names: [String], in directory: URL, wanted: ExtendedAttributeSet,
                            owners: OwnerNameCache) -> [String: ExtendedAttributes]
}

// Support/CoreEnvironment.swift (P2-07/13/15 add)
//   public let folderViews: FolderViewStore
//   public let folderSizes: FolderSizeService
//   public let ownerNames: OwnerNameCache
```

### 2.3 UI (internal unless used by the App target)

```swift
// Tabs/TabController.swift (P2-05)
@MainActor enum TabController {
    static func configure(_ window: NSWindow)                     // tabbingMode .automatic, identifier "macx.browser"
    static func newTabURL(settings: Settings, options: LaunchOptions, current: URL) -> URL
    static func tabTitle(for url: URL, volumes: Volumes) -> String   // folder display name
    static func orderedTabs(of window: NSWindow) -> [NSWindow]     // tabbedWindows ?? [window]
}
extension WindowManager {
    @discardableResult func openTab(at url: URL, in host: BrowserWindowController,
                                    selecting name: String? = nil, select: Bool) -> BrowserWindowController
}
// Content/MiddleClickRouter.swift (P2-06)
enum NewTabGesture: Equatable { case middleClick, commandClick }
@MainActor enum MiddleClickRouter {
    /// Content rows: only middle-click opens tabs (⌘-click keeps toggling). Sidebar/tree: both gestures.
    static func shouldOpenTab(_ gesture: NewTabGesture, in focus: FocusContext) -> Bool
    static func folderTarget(row: Int, in folder: FolderModel) -> URL?      // directories (and aliases/symlinks resolved later)
}
// ViewState/FolderViewCoordinator.swift (P2-08)
@MainActor final class FolderViewCoordinator {
    init(store: FolderViewStore, settings: Settings, lanes: LanePool, volumes: Volumes)
    func state(for url: URL, fileID: UInt64?) -> (FolderViewState, FolderViewLocator)
    func state(for locator: FolderViewLocator) -> FolderViewState
    func save(_ state: FolderViewState, for locator: FolderViewLocator)
    func refine(_ locator: FolderViewLocator) async -> FolderViewLocator   // adds fileID (lane probe) on idStable volumes
    func applyToAll(_ state: FolderViewState)
}
// Details/RowMapping.swift (P2-10)
enum RowMapping: Equatable {
    case identity(count: Int)
    case grouped(GroupedRows)
    var tableRowCount: Int { get }
    func modelRow(forTableRow row: Int) -> Int?       // nil for headers
    func tableRow(forModelRow row: Int) -> Int?
    func modelRows(forTableRows rows: IndexSet) -> IndexSet
    func tableRows(forModelRows rows: IndexSet) -> IndexSet
}
// QuickLook/QuickLookController.swift (P2-11)
@MainActor protocol QuickLookPanelControlling: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
    func reloadData()
}
@MainActor final class QuickLookController {
    init(panel: @escaping @MainActor () -> any QuickLookPanelControlling)
    func bind(_ folder: FolderModel?)                 // follows the active FolderModel's selection
    func toggle()
    var items: [URL] { get }                          // selected URLs, display order
    var isVisible: Bool { get }
    /// Panel keyDown: arrows are forwarded to `forward` when ≤ 1 item is selected. Returns true if consumed.
    func handlePanelKey(_ chord: KeyChord, forward: (KeyChord) -> Void) -> Bool
}
// Icons (P2-17)
struct ThumbnailKey: Hashable, Sendable { var volume: VolumeID; var id: RowID; var directory: String; var mtime: Int64; var size: Int64; var pixels: Int }
struct ThumbnailCandidate { var key: ThumbnailKey; var url: URL }
struct ThumbnailTicket: Hashable { let raw: UInt64 }
@MainActor protocol ThumbnailGenerating: AnyObject {
    func generate(url: URL, pointSize: CGFloat, scale: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> ThumbnailTicket
    func cancel(_ ticket: ThumbnailTicket)
}
@MainActor final class ThumbnailCache { init(costLimit: Int = 64 << 20); func image(_ key: ThumbnailKey) -> CGImage?; func store(_ image: CGImage, for key: ThumbnailKey) }
@MainActor final class ThumbnailScheduler {
    init(generator: any ThumbnailGenerating, cache: ThumbnailCache, maxInFlight: Int = 8)
    var onThumbnail: ((ThumbnailKey) -> Void)?
    static func isEligible(_ entry: Entry, types: TypeRegistry) -> Bool
    func updateVisible(_ candidates: [ThumbnailCandidate], pointSize: CGFloat, scale: CGFloat)
    func cancelAll()
    var inFlight: Set<ThumbnailKey> { get }
}
// Columns (P2-18, P2-19)
@MainActor final class ColumnChain {
    typealias ModelFactory = @MainActor (URL) -> FolderModel
    init(root: URL, makeModel: @escaping ModelFactory)
    init(adopting model: FolderModel, makeModel: @escaping ModelFactory)
    private(set) var models: [FolderModel]
    private(set) var activeIndex: Int
    var activeModel: FolderModel { get }
    var onChange: (() -> Void)?
    func reroot(_ url: URL, selecting name: String?)
    func activate(_ index: Int)
    @discardableResult func moveRight() -> Bool
    @discardableResult func moveLeft() -> Bool
    func up()                                          // parent column, or reroot to the parent selecting the old root
    func detachActive() -> FolderModel                 // closes all other models; chain becomes empty
    func close()
}
@MainActor final class ColumnsViewController: NSViewController, FileListView { init(context: UIContext); func bindChain(_ chain: ColumnChain?) }
```

### 2.4 Scenario additions (P2-03)

```swift
// ScenarioFile.Fixture gains (all optional):
//   images: [String]?                 // 64×64 PNGs (solid colour) at these paths
//   mtimeDays: [String: Int]?         // path → noon local time, N days from today (0 today, -1 yesterday)
//   tags: [String: [String]]?         // Finder tags xattr
//   comments: [String: String]?       // Finder comment xattr
//   lastOpenedDays: [String: Int]?    // com.apple.lastuseddate#PS at noon N days from today
// Files are created with mode 0644 and dirs with 0755 (explicit chmod, independent of umask).
// ScenarioFile.Step gains action fields (still exactly one action per step):
//   middleClick: String?              // target (see below)
//   selectTab: Int?                   // selects tab index in the key window's tab group
//   answerAlert: String?              // clicks the button with this title in the key window's attached NSAlert sheet
//   fsWrite: FSWrite?                 // {path, bytes}: writes inside --root (guarded), simulating another app
//   fsTags: FSTags?                   // {path, tags}: rewrites the tags xattr inside --root (guarded)
// Click targets (click / doubleClick / rightClick / middleClick): "<row name>" (active list or active column),
//   "tree:<path relative to root>", "group:<group title>", "header:<ColumnID raw value>".
// ScenarioFile.Expectation gains:
//   tabs: [String]?  activeTab: Int?  viewMode: String?  sort: String? ("<field>.<asc|desc>")  iconSize: String?
//   groupBy: String?  groups: [String]? ("Today (2)")  visibleRows: [String]?  visibleColumnsContain: [String]?
//   quickLookVisible: Bool?  quickLookItems: [String]?  cells: [String: [String: String]]? (row → ColumnID → text)
//   columnsChain: [String]? (folders relative to root)  activeColumn: Int?  thumbnailsContain: [String]?
//   pasteboardText: String?
// Every expected string undergoes token substitution: "{root}" = POSIX path of --root as the app holds it
//   (no trailing slash), "{rootURL}" = its file URL (trailing slash), "{user}" = NSUserName().
```

---

## 3. Tasks

### Task P2-00: Baseline check of Phase 1

**Files:** none (verification only).

**Interfaces:** Consumes the whole Phase 1 contract. Produces nothing.

- [ ] **Step 1: Confirm the Phase 1 "working" definition on a clean tree**

Run:
```bash
cd /Users/roniburd/dev/macExplorer && git status --short && swift build 2>&1 | tail -3 && swift test --parallel 2>&1 | tail -3
```
Expected: an empty `git status`, `Build complete!`, and a final line `Executed N tests, with 0 failures` (some `XCTSkip`s are allowed).

- [ ] **Step 2: Run both Phase 1 scenario runners**

Run:
```bash
scripts/run-scenarios.sh 2>&1 | tail -5 && scripts/ui-scenarios.sh 2>&1 | tail -5
```
Expected: each summary reports `0 failed`, and each runner prints that its `macx-scenario-<UUID>` roots are gone after teardown. If either fails, stop. Phase 2 starts from a green Phase 1.

- [ ] **Step 3: Record the Phase 1 names this plan depends on**

Run:
```bash
grep -n "public func\|public init\|public var root" Sources/MacxFixtures/Sandbox.swift | head -30
grep -rn "title:" Sources/UI/Menus/MainMenuBuilder.swift | head -60
```
Expected: the `Sandbox` API and the menu titles. If any name differs from those used in this plan (Global Constraints, "Phase 1 names"), note the mapping at the top of your task log and use the Phase 1 name everywhere this plan uses the other. No commit.

---

### Task P2-01: Phase 2 types and Settings schema v2

**Files:**
- Create: `Sources/FSKit/Sort/GroupBy.swift`
- Modify: `Sources/FSKit/Sort/ViewQuery.swift` (SortField cases)
- Modify: `Sources/Core/Settings/SettingsTypes.swift` (ViewMode, ColumnID)
- Modify: `Sources/Core/Settings/Settings.swift` (schemaVersion 2, new keys, migration)
- Test: `Tests/CoreTests/SettingsV2Tests.swift`

**Interfaces:**
- Consumes: `Settings`, `SettingsStorage`, `InMemorySettingsStorage`, `ColumnSetting`, `SortDescriptor` (Phase 1 §3.9, §3.5).
- Produces: `GroupBy`, the new `SortField`/`ColumnID`/`ViewMode` cases, `SortField.entryFields`, `SortField.isExtended`, `ColumnID.defaultWidth`, `Settings.groupBy/showThumbnails/columnWidth`, `Settings.migrateColumns`, and `Settings.defaultFolderViewState()` / `applyDefaultView(_:)`. The last two compile once P2-07 adds `FolderViewState`, so they are added in P2-07, not here.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/SettingsV2Tests.swift
import XCTest
@testable import Core
import MacxFS

@MainActor
final class SettingsV2Tests: XCTestCase {
    func testSchemaVersionIsTwo() {
        XCTAssertEqual(Settings.schemaVersion, 2)
    }

    func testMigrateColumnsAppendsMissingIDsInvisibleAndKeepsOrder() {
        let stored = [
            ColumnSetting(id: .name, width: 300, visible: true),
            ColumnSetting(id: .size, width: 90, visible: true),
            ColumnSetting(id: .name, width: 10, visible: false),   // duplicate: first wins
        ]
        let migrated = Settings.migrateColumns(stored)
        XCTAssertEqual(migrated.prefix(2).map(\.id), [.name, .size])
        XCTAssertEqual(migrated[0].width, 300)
        XCTAssertEqual(Set(migrated.map(\.id)), Set(ColumnID.allCases))
        XCTAssertEqual(migrated.count, ColumnID.allCases.count)
        for setting in migrated.dropFirst(2) {
            XCTAssertFalse(setting.visible, "\(setting.id) must be appended invisible")
            XCTAssertEqual(setting.width, setting.id.defaultWidth)
        }
    }

    func testVersionOneSettingsLoadWithNewColumnsInvisible() throws {
        let storage = InMemorySettingsStorage()
        let v1 = Settings(storage: storage)
        v1.columns = [ColumnSetting(id: .name, width: 280, visible: true),
                      ColumnSetting(id: .kind, width: 120, visible: true)]
        // Simulate a Phase 1 store: rewrite the version key to 1 (key name from Settings.swift).
        storage.set(try JSONEncoder().encode(1), forKey: Settings.schemaVersionKey)
        let reloaded = Settings(storage: storage)
        XCTAssertEqual(reloaded.columns.filter(\.visible).map(\.id), [.name, .kind])
        XCTAssertTrue(reloaded.columns.contains { $0.id == .tags && !$0.visible })
        XCTAssertEqual(reloaded.groupBy, .none)
        XCTAssertTrue(reloaded.showThumbnails)
        XCTAssertEqual(reloaded.columnWidth, 220)
    }

    func testNewKeysPersist() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage)
        s.groupBy = .dateModified
        s.showThumbnails = false
        s.columnWidth = 300
        let r = Settings(storage: storage)
        XCTAssertEqual(r.groupBy, .dateModified)
        XCTAssertFalse(r.showThumbnails)
        XCTAssertEqual(r.columnWidth, 300)
    }

    func testSortFieldMetadata() {
        XCTAssertEqual(SortField.entryFields, [.name, .dateModified, .size, .kind, .dateCreated, .fileExtension])
        XCTAssertEqual(SortField.allCases.filter(\.isExtended), [.tags, .dateLastOpened, .permissions, .owner, .comments])
        XCTAssertEqual(ColumnID.tags.sortField, .tags)
        XCTAssertEqual(ColumnID.path.sortField, .path)
        XCTAssertEqual(SortField.name.rawValue, "name")   // Phase 1 raw values unchanged
        XCTAssertEqual(ViewMode.allCases, [.details, .icons, .columns])
    }
}
```

If Phase 1 names the schema-version storage key differently, expose it as `static let schemaVersionKey` with its existing value. The key value itself does not change.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CoreTests.SettingsV2Tests 2>&1 | tail -5`
Expected: compile errors such as `type 'Settings' has no member 'migrateColumns'` and `type 'ColumnID' has no member 'tags'`.

- [ ] **Step 3: Implement**

```swift
// Sources/FSKit/Sort/GroupBy.swift
/// Per-folder Group by mode (spec §11). Grouping applies to the Details view only; Icons and Columns ignore it.
public enum GroupBy: String, Sendable, Codable, CaseIterable { case none, kind, dateModified, size, nameFirstLetter }
```

In `ViewQuery.swift`, add the six cases after the Phase 1 ones, and add:
```swift
extension SortField {
    public static let entryFields: [SortField] = [.name, .dateModified, .size, .kind, .dateCreated, .fileExtension]
    public var isExtended: Bool {
        switch self {
        case .tags, .dateLastOpened, .permissions, .owner, .comments: true
        default: false
        }
    }
}
```
`Sorter.permutation` (Phase 1 signature) treats every non-entry field as `.name` until P2-14/P2-16. Make that explicit with a `default:` branch commented `// P2-16 orders extended fields; .path sorts like .name`. Any Phase 1 bench or test that iterates `SortField.allCases` switches to `SortField.entryFields`, so the `resort` metric keeps measuring the same fields. Check with `grep -rn "SortField.allCases" Sources Tests`.

In `SettingsTypes.swift`, add `.columns` to `ViewMode` and the six `ColumnID` cases, then:
```swift
extension ColumnID {
    public var defaultWidth: Double {
        switch self {
        case .name: 260; case .dateModified: 150; case .size: 80; case .kind: 140
        case .dateCreated: 150; case .fileExtension: 70; case .tags: 120; case .dateLastOpened: 150
        case .permissions: 100; case .owner: 90; case .path: 260; case .comments: 200
        }
    }
}
```
Map the new `sortField`s one to one: `tags → .tags`, `dateLastOpened → .dateLastOpened`, `permissions → .permissions`, `owner → .owner`, `path → .path`, `comments → .comments`. If Phase 1 keeps default widths elsewhere (for example in `DetailsColumns`), point that code at `defaultWidth`.

In `Settings.swift`, set `schemaVersion = 2` and add the three stored properties, persisted the way Phase 1 persists the others (the same `didSet` → `storage.set` pattern), with defaults `.none`, `true` and `220`. Add:
```swift
extension Settings {
    public static func migrateColumns(_ stored: [ColumnSetting]) -> [ColumnSetting] {
        var seen = Set<ColumnID>()
        var result = stored.filter { seen.insert($0.id).inserted }
        for id in ColumnID.allCases where !seen.contains(id) {
            result.append(ColumnSetting(id: id, width: id.defaultWidth, visible: false))
        }
        return result
    }
}
```
In `init`, apply `migrateColumns` to the decoded columns on every load. It is idempotent, so a v2 store passes through unchanged. If the stored version is below 2, write version 2 back once. A fresh install's columns are Phase 1's default visible set followed by the new IDs, invisible.

**P2-01 deviations (as built):** `ColumnID.defaultWidth` keeps Phase 1's real default widths for the six Phase 1 columns (280, 160, 80, 150, 160, 70), and `Settings.defaultColumns` / `DetailsColumns.defaults` are now derived from it (every ColumnID, the four Phase 1 visible columns on), so Phase 1 widths do not change. `DetailsColumns.offered` (`ColumnID.allCases.prefix(6)`) limits the table columns and header chooser until P2-16. The toolbar switcher offers `ToolbarController.switcherModes` (`[.details, .icons]`) until P2-19 adds the Columns segment. Phase 1 tests that pinned schema v1 or the six-case enums were updated.

Update every exhaustive `switch` over `ViewMode`, `ColumnID` and `SortField` that the compiler reports. Until P2-19, `.columns` falls back to the Details list (a `case .columns:` branch that behaves like `.details`, commented `// P2-19`). Until P2-16, new `ColumnID`s are not offered in the chooser (`DetailsColumns` filters on `ColumnID.allCases.prefix(6)`, commented `// P2-16`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift build 2>&1 | tail -3 && swift test --filter CoreTests.SettingsV2Tests 2>&1 | tail -5`
Expected: `Build complete!`, then `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Run the full suite (Phase 1 regressions)**

Run: `swift test --parallel 2>&1 | tail -3`
Expected: `0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FSKit/Sort Sources/Core/Settings Tests/CoreTests/SettingsV2Tests.swift
git commit -m "feat: phase 2 view types and settings schema v2"
```

---

### Task P2-02: Phase 2 commands, key map and availability

**Files:**
- Modify: `Sources/Core/Commands/Command.swift`, `KeyMap.swift`, `KeyDispatcher.swift`, `CommandAvailability.swift`
- Modify: `Sources/UI/Menus/MainMenuBuilder.swift` (Window and View menu items; File › New Tab)
- Test: `Tests/CoreTests/Phase2KeyMapTests.swift`, `Tests/UITests/MenuValidationTests.swift` (add cases)

**Interfaces:**
- Consumes: `Command`, `KeyChord(parsing:)`, `KeyMap.primary/alternates/collidesWithTextEditing`, `KeyDispatcher.command(for:in:)`, `CommandAvailability.isEnabled`, `CommandState` (Phase 1 §3.10).
- Produces: the §2.2 Command cases and selector names; the `CommandState` fields `selectedFolderCount`, `quickLookVisible` and `viewMode`; primaries ⌘T (newTab), ⌃Tab (nextTab), ⌃⇧Tab (previousTab), ⌘⇧\ (showAllTabs), ⌘1/⌘2/⌘3 (viewAsDetails/Icons/Columns); the alternate Space → quickLook in `.content`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/Phase2KeyMapTests.swift
import XCTest
@testable import Core

final class Phase2KeyMapTests: XCTestCase {
    func chord(_ s: String) -> KeyChord { KeyChord(parsing: s)! }

    func testPhase2Primaries() {
        XCTAssertEqual(KeyMap.primary(.newTab), chord("cmd+t"))
        XCTAssertEqual(KeyMap.primary(.nextTab), chord("ctrl+tab"))
        XCTAssertEqual(KeyMap.primary(.previousTab), chord("ctrl+shift+tab"))
        XCTAssertEqual(KeyMap.primary(.showAllTabs), KeyChord(.character("\\"), [.command, .shift]))
        XCTAssertEqual(KeyMap.primary(.viewAsDetails), chord("cmd+1"))
        XCTAssertEqual(KeyMap.primary(.viewAsIcons), chord("cmd+2"))
        XCTAssertEqual(KeyMap.primary(.viewAsColumns), chord("cmd+3"))
        XCTAssertNil(KeyMap.primary(.quickLook), "Space is content-only so type-select and text fields keep it")
        XCTAssertEqual(KeyMap.alternates(.quickLook), [KeyChord(.space)])
        XCTAssertNil(KeyMap.primary(.copyPathTilde))
        XCTAssertEqual(KeyMap.primary(.copyAsPath), chord("cmd+shift+c"))   // Phase 1, unchanged
    }

    func testPrimariesAreUnique() {
        var seen: [KeyChord: Command] = [:]
        for c in Command.allCases {
            guard let k = KeyMap.primary(c) else { continue }
            XCTAssertNil(seen[k], "\(k) bound to both \(seen[k].map { "\($0)" } ?? "") and \(c)")
            seen[k] = c
        }
    }

    func testSelectorNames() {
        XCTAssertEqual(Command.newTab.selectorName, "newWindowForTab:")
        XCTAssertEqual(Command.nextTab.selectorName, "selectNextTab:")
        XCTAssertEqual(Command.previousTab.selectorName, "selectPreviousTab:")
        XCTAssertEqual(Command.showTabBar.selectorName, "toggleTabBar:")
        XCTAssertEqual(Command.showAllTabs.selectorName, "toggleTabOverview:")
        XCTAssertEqual(Command.moveTabToNewWindow.selectorName, "moveTabToNewWindow:")
        XCTAssertEqual(Command.mergeAllWindows.selectorName, "mergeAllWindows:")
        XCTAssertEqual(Command.quickLook.selectorName, "macx_quickLook:")
        XCTAssertEqual(Command.copyPathShellQuoted.selectorName, "macx_copyPathShellQuoted:")
    }

    func testDispatcherSpaceAndControlTab() {
        let d = KeyDispatcher(returnKey: .open)
        XCTAssertEqual(d.command(for: KeyChord(.space), in: .content), .quickLook)
        XCTAssertNil(d.command(for: KeyChord(.space), in: .sidebarFolders))
        XCTAssertNil(d.command(for: KeyChord(.space), in: .fieldEditor))
        XCTAssertNil(d.command(for: KeyChord(.tab, [.control]), in: .content), "⌃Tab is the next-tab menu key, never focus cycling")
        XCTAssertNil(d.command(for: KeyChord(.tab, [.control, .shift]), in: .sidebarFolders))
        XCTAssertEqual(d.command(for: KeyChord(.tab), in: .content), .cycleFocusForward)   // Phase 1 unchanged
    }

    func testAvailability() {
        func on(_ c: Command, _ f: FocusContext = .content, _ s: CommandState) -> Bool { CommandAvailability.isEnabled(c, focus: f, state: s) }
        XCTAssertFalse(on(.quickLook, .content, CommandState()))
        XCTAssertTrue(on(.quickLook, .content, CommandState(selectionCount: 1)))
        XCTAssertTrue(on(.quickLook, .content, CommandState(quickLookVisible: true)), "Space closes an open panel with nothing selected")
        XCTAssertFalse(on(.quickLook, .sidebarFolders, CommandState(selectionCount: 1)))
        XCTAssertFalse(on(.openInNewTab, .content, CommandState(selectionCount: 2, selectedFolderCount: 0)))
        XCTAssertTrue(on(.openInNewTab, .content, CommandState(selectionCount: 2, selectedFolderCount: 1)))
        XCTAssertTrue(on(.openInNewTab, .sidebarFavorites, CommandState()))
        XCTAssertTrue(on(.groupByKind, .content, CommandState(viewMode: .details)))
        XCTAssertFalse(on(.groupByKind, .content, CommandState(viewMode: .icons)))
        XCTAssertFalse(on(.toggleFolderSizes, .content, CommandState(viewMode: .columns)))
        XCTAssertTrue(on(.newTab, .sidebarLocations, CommandState()))
        for c in [Command.copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted] {
            XCTAssertEqual(on(c, .content, CommandState(selectionCount: 1)), on(.copyAsPath, .content, CommandState(selectionCount: 1)))
            XCTAssertFalse(on(c, .content, CommandState()))
        }
    }

    func testQuickLookIsNotATextCollision() {
        XCTAssertFalse(KeyMap.collidesWithTextEditing.contains(.quickLook))
        XCTAssertFalse(KeyMap.collidesWithTextEditing.contains(.nextTab))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CoreTests.Phase2KeyMapTests 2>&1 | tail -5`
Expected: compile errors such as `type 'Command' has no member 'newTab'`.

- [ ] **Step 3: Implement**

Add the §2.2 cases to `Command`. In `selectorName`, add the standard-selector cases listed in §2.2 to the Phase 1 switch that maps `cut`/`copy`/…. Everything else keeps `"macx_\(rawValue):"`.

`KeyMap.primary`: add the bindings listed in Produces. ⌘1/⌘2 replace any Phase 1 bindings for `viewAsDetails`/`viewAsIcons`, which the spec did not fix. `KeyMap.alternates(.quickLook) = [KeyChord(.space)]`.

`KeyDispatcher.command(for:in:)`: in `.content`, `KeyChord(.space)` returns `.quickLook`. Any chord with `.control` and `.tab` returns `nil` in every focus. Put that check before the Phase 1 Tab/⇧Tab branch.

`CommandState`: add `selectedFolderCount: Int = 0`, `quickLookVisible: Bool = false` and `viewMode: ViewMode = .details` as stored properties, and append them as defaulted parameters at the end of the init.

`CommandAvailability.isEnabled` adds these rules:
```swift
case .quickLook: return focus == .content && (state.selectionCount > 0 || state.quickLookVisible)
case .openInNewTab:
    switch focus {
    case .content: return state.selectedFolderCount > 0
    case .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot: return true
    default: return false
    }
case .groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName, .toggleFolderSizes:
    return state.viewMode == .details && (focus == .content || focus.isSidebar)
case .newTab, .viewAsColumns, .applyViewToAllFolders,
     .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows:
    return true   // the tab commands are validated again by NSWindow
case .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted:
    return isEnabled(.copyAsPath, focus: focus, state: state)
```
If Phase 1 has no `focus.isSidebar` helper, add `var isSidebar: Bool` to `FocusContext` (true for the four sidebar cases).

`MainMenuBuilder` places the new items as follows:
- File: New Tab (⌘T) after New Window.
- Edit: "Copy Path As ▸" after Copy as Path. The submenu is built in P2-04, so in this task it is an empty submenu placeholder item, hidden until P2-04. (As built: P2-04 replaced the placeholder with `CopyPathMenu.submenuItem()`; the item is visible and populated.)
- View: "as Columns" (⌘3) after "as Icons"; "Group By ▸" (None, Kind, Date Modified, Size, Name) after the Sort By submenu; "Calculate Folder Sizes"; "Apply to All Folders…".
- Window: Show Tab Bar, Show All Tabs (⌘⇧\), Show Previous Tab (⌃⇧Tab), Show Next Tab (⌃Tab), Move Tab to New Window, Merge All Windows.
- File: "Quick Look" with no key equivalent and title `L10n` "Quick Look" (the menu shows no shortcut; Space works in the content view).

Set `NSWindow.allowsAutomaticWindowTabbing = false` in `MainMenuBuilder.build()`, before the menu is installed, so AppKit does not add duplicate tab items. P2-05 verifies that programmatic tabbing still works. Wire every new item through the Phase 1 pattern (`Selector(command.selectorName)`, `target nil`). Items whose handlers arrive in later tasks are disabled by `validateMenuItem`, because no responder implements them yet. That is AppKit's default and is expected until those tasks land.

Add to `Tests/UITests/MenuValidationTests.swift`:
```swift
func testPhase2MenuItemsExistWithKeys() throws {
    let menu = MainMenuBuilder.build()
    func item(_ selector: String) -> NSMenuItem? {
        func walk(_ m: NSMenu) -> NSMenuItem? {
            for i in m.items { if i.action == Selector(selector) { return i }; if let s = i.submenu, let f = walk(s) { return f } }
            return nil
        }
        return walk(menu)
    }
    XCTAssertEqual(item("newWindowForTab:")?.keyEquivalent, "t")
    XCTAssertEqual(item("selectNextTab:")?.keyEquivalent, "\t")
    XCTAssertEqual(item("selectNextTab:")?.keyEquivalentModifierMask, [.control])
    XCTAssertEqual(item("macx_viewAsColumns:")?.keyEquivalent, "3")
    XCTAssertEqual(item("macx_quickLook:")?.keyEquivalent, "")
    XCTAssertNotNil(item("macx_groupByDateModified:"))
    XCTAssertNotNil(item("macx_applyViewToAllFolders:"))
    XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "CoreTests.Phase2KeyMapTests|UITests.MenuValidationTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 5: Run the full suite and the Phase 1 UI scenarios**

Run: `swift test --parallel 2>&1 | tail -3 && scripts/ui-scenarios.sh 2>&1 | tail -3`
Expected: `0 failures`, and all Phase 1 scenarios pass. That includes the colliding-keys scenario: Space typed into the rename field still reaches the field editor, because alternates never fire in text fields.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Commands Sources/UI/Menus Tests/CoreTests/Phase2KeyMapTests.swift Tests/UITests/MenuValidationTests.swift
git commit -m "feat: phase 2 commands, key bindings and menu items"
```

---

### Task P2-03: Scenario runner and fixture extensions

**Files:**
- Create: `Sources/MacxFixtures/FixtureMetadata.swift`, `Tests/MacxFixturesTests/FixtureMetadataTests.swift`, `Tests/UITests/Support/GUI.swift`, `Tests/UITests/ScenarioSchemaTests.swift`
- Modify: `Sources/UI/Scenario/ScenarioFile.swift`, `ScenarioDriver.swift`, `ScenarioProbe.swift`, `Sources/UI/Support/AXID.swift`, `Sources/UI/Window/BrowserWindowController.swift` (probe conformance)

**Interfaces:**
- Consumes: `ScenarioFile`, `ScenarioDriver`, `ScenarioProbe`, `ScenarioHooks`, `Sandbox` (Phase 1 §3.14, P1-02).
- Produces: the §2.4 schema; `FixtureMetadata` (below); probes `probeTabFolderURLs`, `probeSelectedTabIndex`, `probeSort`, `probeGrouping` and `probeIconSize`; hooks installed by later tasks (`visibleColumnIDs`, `visibleRowNames`, `groupHeaderTitles`, `cellText`, `quickLookState`, `columnsChain`, `thumbnailNames`, `performMiddleClick`, `clickTarget`, `rightClickTarget`); `requireGUISession()`; and the AXIDs `groupHeader(_:)`, `columnsView`, `column(_:)`, `newTabItem`, `tabBarDrop`.

FixtureMetadata (pure, fully specified):

```swift
// Sources/MacxFixtures/FixtureMetadata.swift
import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Guarded metadata writers. Every path is resolved through `sandbox.url(_:)`, which traps outside the root.
public extension Sandbox {
    func setXattr(_ name: String, _ data: Data, on relativePath: String) throws {
        let path = url(relativePath).path(percentEncoded: false)
        let rc = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if rc != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func setModificationDate(_ date: Date, on relativePath: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(relativePath).path(percentEncoded: false))
    }
    func setMode(_ mode: UInt16, on relativePath: String) throws {
        if chmod(url(relativePath).path(percentEncoded: false), mode_t(mode)) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    /// Finder stores tags as a binary plist array of "Name\n<colour index>"; colour 0 (none) is written as "Name".
    func setFinderTags(_ tags: [String], on relativePath: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        try setXattr("com.apple.metadata:_kMDItemUserTags", data, on: relativePath)
    }
    func setFinderComment(_ comment: String, on relativePath: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: comment, format: .binary, options: 0)
        try setXattr("com.apple.metadata:kMDItemFinderComment", data, on: relativePath)
    }
    /// 16 bytes: tv_sec (Int64, little endian), tv_nsec (Int64, little endian).
    func setLastUsedDate(_ date: Date, on relativePath: String) throws {
        let secs = Int64(date.timeIntervalSince1970.rounded(.down))
        let nsec = Int64((date.timeIntervalSince1970 - Double(secs)) * 1e9)
        var data = Data()
        withUnsafeBytes(of: secs.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: nsec.littleEndian) { data.append(contentsOf: $0) }
        try setXattr("com.apple.lastuseddate#PS", data, on: relativePath)
    }
    /// Solid-colour PNG, so Quick Look has a real image to thumbnail.
    @discardableResult
    func writePNG(_ relativePath: String, pixels: Int = 64, red: CGFloat = 0.2, green: CGFloat = 0.5, blue: CGFloat = 0.9) throws -> URL {
        let target = url(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw POSIXError(.EIO)
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw POSIXError(.EIO) }
        return target
    }
    /// Noon local time, `days` from today (0 = today, -1 = yesterday).
    static func noon(daysFromToday days: Int, calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) -> Date {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: days, to: start)!
        return calendar.date(byAdding: .hour, value: 12, to: day)!
    }
}
```

`MacxFixtures` currently depends only on `MacxFS`; ImageIO, CoreGraphics and UniformTypeIdentifiers are system frameworks and need no `Package.swift` change. The real-world tag format (`"Name\n6"`) is exercised by the parser tests in P2-15. Fixtures write plain names, which Finder also accepts.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/MacxFixturesTests/FixtureMetadataTests.swift
import XCTest
@testable import MacxFixtures

final class FixtureMetadataTests: XCTestCase {
    var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); addTeardownBlock { [sandbox] in sandbox?.destroy() } }

    func testTagsCommentLastUsedRoundTripThroughXattrs() throws {
        try sandbox.write("a.txt", bytes: 3)
        try sandbox.setFinderTags(["Work", "Home"], on: "a.txt")
        try sandbox.setFinderComment("hello", on: "a.txt")
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        try sandbox.setLastUsedDate(date, on: "a.txt")
        let path = sandbox.url("a.txt").path(percentEncoded: false)
        func read(_ name: String) -> Data? {
            let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW); guard n > 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: n); _ = getxattr(path, name, &buf, n, 0, XATTR_NOFOLLOW); return Data(buf)
        }
        let tags = try PropertyListSerialization.propertyList(from: read("com.apple.metadata:_kMDItemUserTags")!, format: nil) as? [String]
        XCTAssertEqual(tags, ["Work", "Home"])
        XCTAssertEqual(read("com.apple.lastuseddate#PS")?.count, 16)
    }

    func testWritePNGAndModificationDate() throws {
        let url = try sandbox.writePNG("img/p.png")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 50)
        let noon = Sandbox.noon(daysFromToday: -1)
        try sandbox.setModificationDate(noon, on: "img/p.png")
        let mdate = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
        XCTAssertEqual(mdate!.timeIntervalSince1970, noon.timeIntervalSince1970, accuracy: 1)
    }

    func testWritersRefuseOutsideSandbox() throws {
        // Sandbox.url traps (preconditionFailure) outside the root. P1-02 tests trapping in a child process;
        // reuse its helper (expectTrap) here.
        try expectTrap { try self.sandbox.setFinderTags(["x"], on: "../escape.txt") }
    }
}
```

`expectTrap` is the P1-02 child-process trap helper. If P1-02 named it differently, use its name.

```swift
// Tests/UITests/Support/GUI.swift
import XCTest
import CoreGraphics
func requireGUISession() throws {
    guard CGSessionCopyCurrentDictionary() != nil else { throw XCTSkip("needs a window server (GUI login session)") }
}
```

```swift
// Tests/UITests/ScenarioSchemaTests.swift
import XCTest
@testable import UI

final class ScenarioSchemaTests: XCTestCase {
    func testPhase2FieldsDecode() throws {
        let json = """
        {"name":"x","fixture":{"files":["a.txt"],"dirs":["A"],"images":["p.png"],"mtimeDays":{"a.txt":-1},
          "tags":{"a.txt":["Work"]},"comments":{"a.txt":"c"},"lastOpenedDays":{"a.txt":-3}},
         "steps":[{"middleClick":"A"},{"selectTab":1},{"answerAlert":"Apply"},
                  {"fsWrite":{"path":"A/n.bin","bytes":10}},{"fsTags":{"path":"a.txt","tags":["Home"]}},
                  {"expect":{"tabs":["","A"],"activeTab":0,"viewMode":"icons","sort":"name.asc","groups":["Today (1)"],
                   "cells":{"a.txt":{"tags":"Work"}},"columnsChain":[""],"pasteboardText":"{root}/a.txt",
                   "quickLookVisible":false,"thumbnailsContain":["p.png"],"visibleColumnsContain":["tags"]}}]}
        """
        let file = try JSONDecoder().decode(ScenarioFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.fixture.images, ["p.png"])
        XCTAssertEqual(file.steps[0].middleClick, "A")
        XCTAssertEqual(file.steps[3].fsWrite?.bytes, 10)
        XCTAssertEqual(file.steps[5].expect?.cells?["a.txt"]?["tags"], "Work")
        XCTAssertTrue(ScenarioDriver.validateSteps(file.steps).isEmpty)
    }

    func testTwoActionsInOneStepAreRejected() throws {
        let json = #"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"middleClick":"A","selectTab":1}]}"#
        let file = try JSONDecoder().decode(ScenarioFile.self, from: Data(json.utf8))
        XCTAssertEqual(ScenarioDriver.validateSteps(file.steps), [0])
    }

    func testTokenSubstitution() {
        let root = URL(filePath: "/private/var/folders/x/macx-scenario-1", directoryHint: .isDirectory)
        XCTAssertEqual(ScenarioDriver.substitute("{root}/a.txt", root: root), "/private/var/folders/x/macx-scenario-1/a.txt")
        XCTAssertEqual(ScenarioDriver.substitute("{rootURL}a.txt", root: root), "file:///private/var/folders/x/macx-scenario-1/a.txt")
        XCTAssertEqual(ScenarioDriver.substitute("{user}", root: root), NSUserName())
    }

    func testFSStepsRefusePathsOutsideRoot() {
        let root = URL(filePath: "/tmp/macx-scenario-1", directoryHint: .isDirectory)
        XCTAssertNil(ScenarioDriver.guardedURL("../x", root: root))
        XCTAssertNil(ScenarioDriver.guardedURL("/etc/hosts", root: root))
        XCTAssertEqual(ScenarioDriver.guardedURL("A/n.bin", root: root)?.path(percentEncoded: false), "/tmp/macx-scenario-1/A/n.bin")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "MacxFixturesTests.FixtureMetadataTests|UITests.ScenarioSchemaTests" 2>&1 | tail -5`
Expected: compile errors (`value of type 'Sandbox' has no member 'setFinderTags'`, `'ScenarioFile.Fixture' has no member 'images'`).

- [ ] **Step 3: Implement the schema, validation and guards**

Add the §2.4 optional fields to `ScenarioFile.Fixture`, `Step` and `Expectation`, plus:
```swift
struct FSWrite: Codable { var path: String; var bytes: Int }
struct FSTags: Codable { var path: String; var tags: [String] }
```
In `ScenarioDriver`:
```swift
/// Indices of steps that do not have exactly one action field.
static func validateSteps(_ steps: [ScenarioFile.Step]) -> [Int] {
    steps.enumerated().compactMap { i, s in
        let actions: [Any?] = [s.key, s.type, s.menu, s.click, s.doubleClick, s.rightClick, s.chooseMenuItem, s.drop,
                               s.answerConflict, s.waitFor, s.expect, s.sleepMs,
                               s.middleClick, s.selectTab, s.answerAlert, s.fsWrite, s.fsTags]
        return actions.compactMap { $0 }.count == 1 ? nil : i
    }
}
static func substitute(_ s: String, root: URL) -> String {
    var path = root.path(percentEncoded: false)
    if path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return s.replacing("{rootURL}", with: URL(filePath: path, directoryHint: .isDirectory).absoluteString)
            .replacing("{root}", with: path)
            .replacing("{user}", with: NSUserName())
}
/// nil unless `relative` stays inside `root` after standardization (no "..", not absolute).
static func guardedURL(_ relative: String, root: URL) -> URL? {
    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
    let url = root.appending(path: relative).standardizedFileURL
    let rootPath = root.standardizedFileURL.path(percentEncoded: false)
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return url.path(percentEncoded: false).hasPrefix(prefix) ? url : nil
}
```
If Phase 1 validates steps somewhere else, extend that function instead. The list of action fields must include the five new ones. `{rootURL}` is substituted before `{root}`, because `{root}` is a prefix of it.

- [ ] **Step 4: Implement fixture creation, the new steps and expectations**

Fixture creation (driver, before the first step, after the Phase 1 files/dirs/hidden/sizes):
- chmod every created file to `0o644` and every created dir to `0o755`;
- `images` → `writePNG`;
- `mtimeDays` → `setModificationDate(Sandbox.noon(daysFromToday:))`, applied last so later writes don't bump mtimes;
- `tags` → `setFinderTags`, `comments` → `setFinderComment`, `lastOpenedDays` → `setLastUsedDate(noon(...))`.

The driver builds a `Sandbox` over `--root` (Phase 1 does this already) and uses only these writers.

Steps:
- `middleClick: t` → `scenarioHooks.performMiddleClick?(t)`. If the hook returns false, the step fails with "middle-click target not found".
- `selectTab: i` → `TabController.orderedTabs(of: keyWindow)[i].makeKeyAndOrderFront(nil)`.
- `answerAlert: title` → `keyWindow.attachedSheet`'s first `NSButton` whose `title == title` gets `performClick(nil)`. If there is no sheet or no matching button, the step fails.
- `fsWrite` → `guardedURL`, create intermediate dirs, write `bytes` zero bytes. If the path falls outside the root, the step fails with "path outside root".
- `fsTags` → `guardedURL` then `Sandbox.setFinderTags`.
- `click`/`doubleClick`/`rightClick` whose target contains `:` go to `scenarioHooks.clickTarget?(target, modifiers)` or `rightClickTarget?(target)`. Plain row names keep the Phase 1 path. Double-click on a prefixed target is not supported and fails validation.

Probes and hooks, added to `ScenarioProbe`, `ScenarioHooks` and `BrowserWindowController`:
```swift
var probeTabFolderURLs: [URL] { get }        // TabController.orderedTabs(of: window) → each controller's session.folder.directory
var probeSelectedTabIndex: Int { get }       // index of the tab group's selectedWindow in orderedTabs
var probeSort: SortDescriptor { get }        // session.folder.query.sort
var probeGrouping: GroupBy { get }           // session.folder.grouping (P2-09; .none before that)
var probeIconSize: IconSize { get }
// ScenarioHooks gains (nil until the owning task installs it):
var visibleColumnIDs: (() -> [String])?                 // P2-16
var visibleRowNames: (() -> [String])?                  // P2-10 (item rows actually in the table, headers excluded)
var groupHeaderTitles: (() -> [String])?                // P2-10
var cellText: ((String, String) -> String?)?            // P2-14/P2-16 (row name, ColumnID raw value)
var quickLookState: (() -> (visible: Bool, items: [String]))?   // P2-11
var columnsChain: (() -> (folders: [URL], active: Int))?        // P2-19
var thumbnailNames: (() -> [String])?                   // P2-17
var performMiddleClick: ((String) -> Bool)?             // P2-06
var clickTarget: ((String, [String]) -> Bool)?          // P2-06 tree:, P2-10 group:, P2-16 header:
var rightClickTarget: ((String) -> Bool)?               // P2-16 header:
```
The driver targets the key window's controller. Fall back to `windows.first` when there is no key window: the Phase 1 driver used the first window, and with tabs only one tab per group is key.

Expectation checking. Every string is substituted first.
- `tabs`: folders relative to `--root`, with `""` for the root.
- `sort`: `"\(field.rawValue).\(ascending ? "asc" : "desc")"`.
- `groups`, `visibleRows`, `quickLookItems`, `columnsChain`: exact match.
- `visibleColumnsContain`, `thumbnailsContain`: subset.
- `cells`: every listed cell must match.
- `pasteboardText`: `environment.clipboard` backend's `readString()`. It compiles after P2-04; until then that expectation fails with "unsupported until P2-04".

Each Phase 2 expectation whose hook is nil fails with a message naming the hook. It never passes silently.

AXID additions:
```swift
static func groupHeader(_ title: String) -> String { "macx.group.\(title)" }
static let columnsView = "macx.columns"
static func column(_ index: Int) -> String { "macx.column.\(index)" }
static let newTabItem = "macx.newTab"
static let tabBarDrop = "macx.tabBarDrop"
```

- [ ] **Step 5: Run the tests to verify they pass, plus all Phase 1 scenarios**

Run: `swift test --filter "MacxFixturesTests.FixtureMetadataTests|UITests.ScenarioSchemaTests" 2>&1 | tail -5 && scripts/ui-scenarios.sh 2>&1 | tail -3`
Expected: `Executed 7 tests, with 0 failures`; all Phase 1 scenarios still pass.

**P2-03 result (2026-11-05): deviations later tasks must know.**
- `UI` may not link `MacxFixtures` (check-layering rule `fixtures-in-app`), so the in-app driver cannot use `Sandbox`. `ScenarioFixtures` (UI) carries its own guarded writers with the same encodings: `writeZeros(_:at:)`, `setFinderTags(_:at:relative:)`, `lastUsedDateValue(_:)`, `noon(daysFromToday:)`, `pngData(pixels:)` and the xattr-name constants. `ScenarioFixturesTests.testFixtureEncodingsMatchMacxFixtures` keeps the two in step.
- `FixtureMetadata` reuses the Phase 1 `setXattr(_:name:value:)` and `setMode(_:_:)` and does not add the plan's `setXattr(_:_:on:)` / `setMode(_:on:)` overloads. `writePNG` writes through `createFile` (O_EXCL, O_NOFOLLOW), and `noon` uses `bySettingHour` so DST days are handled. `Sandbox.finderTagsXattr`, `finderCommentXattr` and `lastUsedDateXattr` name the xattrs.
- Step validation stays in `ScenarioFile.validate()` (`Step.actions`). `ScenarioDriver.validateSteps` is a thin wrapper around it. `answerAlert` already existed in Phase 1: it searches the modal window and every attached sheet. Validation also rejects `selectTab < 0`, a prefixed `doubleClick`, `tree:` paths outside the root, malformed `sort`/`iconSize`/`groupBy`/`viewMode`, and unsafe fixture or fs-step paths.
- Only the prefixes `tree:`, `group:` and `header:` route to hooks (`ScenarioTarget`). Any other name containing ":" is a plain row. fs steps go through `ScenarioFixtures.confinedTarget(_:root:roots:createParents:)` (review fix): the deepest existing ancestor is realpath'd and must be inside the root, and missing parents (fsWrite only) are created with mkdirat + openat(O_NOFOLLOW), so a link inside the root never leads a write outside it.
- `TabController` does not exist yet, so `BrowserWindowController.orderedTabWindows(of:)` (`tabbedWindows ?? [window]`) backs `probeTabFolderURLs`, `probeSelectedTabIndex` and `selectTab`. P2-05 replaces it with `TabController.orderedTabs(of:)`. `probeGrouping` returns `.none` until P2-09.
- `ScenarioCatalogTests` now asserts at least 29 scenario files instead of an exact count. `Tests/Scenarios/p2-scenario-runner.json` exercises the fixture metadata, the tab/sort/icon-size/group expectations, `selectTab`, `fsWrite` and `fsTags`.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacxFixtures/FixtureMetadata.swift Sources/UI/Scenario Sources/UI/Support/AXID.swift Sources/UI/Window/BrowserWindowController.swift Tests/MacxFixturesTests/FixtureMetadataTests.swift Tests/UITests/Support/GUI.swift Tests/UITests/ScenarioSchemaTests.swift
git commit -m "test: phase 2 scenario schema, probes and guarded metadata fixtures"
```

---

### Task P2-04: Copy-path variants

**Files:**
- Create: `Sources/Core/Paths/PathFormatter.swift`, `Sources/UI/Menus/CopyPathMenu.swift`, `Tests/CoreTests/PathFormatterTests.swift`, `Tests/UITests/CopyPathMenuTests.swift`, `Tests/Scenarios/p2-copy-path.json`
- Modify: `Sources/Core/Clipboard/PasteboardBackend.swift` (+ `InMemoryPasteboard`), `Sources/Core/Platform/SystemPasteboard.swift`, `Sources/UI/Commands/FileCommandController.swift`, `Sources/UI/Menus/ContextMenuBuilder.swift`, `Sources/UI/Menus/MainMenuBuilder.swift`, `Sources/UI/CommandBar/CommandBarView.swift` (⋯ menu)

**Interfaces:**
- Consumes: `Clipboard`, `PasteboardBackend`, `CommandTarget`, `FileCommandController`, `FolderModel.selectedURLs/entry(atRow:)`, `Settings.home`.
- Produces: `PathStyle`, `PathItem`, `PathFormatter`, `PasteboardBackend.writeString/readString`, `CopyPathMenu.make(handler:) -> NSMenu`, and handlers for `copyAsPath` (= `.posix`), `copyPathTilde`, `copyPathFileURL`, `copyName` and `copyPathShellQuoted` on every `CommandTarget`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/PathFormatterTests.swift
import XCTest
@testable import Core

final class PathFormatterTests: XCTestCase {
    let home = URL(filePath: "/Users/roni", directoryHint: .isDirectory)
    func item(_ p: String, dir: Bool = false) -> PathItem { PathItem(url: URL(filePath: p, directoryHint: dir ? .isDirectory : .notDirectory), isDirectory: dir) }

    func testPOSIX() {
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev/a.txt"), style: .posix, home: home), "/Users/roni/dev/a.txt")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev", dir: true), style: .posix, home: home), "/Users/roni/dev")
        XCTAssertEqual(PathFormatter.one(item("/", dir: true), style: .posix, home: home), "/")
    }
    func testTildeIsComponentWise() {
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev/a.txt"), style: .tilde, home: home), "~/dev/a.txt")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni", dir: true), style: .tilde, home: home), "~")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni2/a.txt"), style: .tilde, home: home), "/Users/roni2/a.txt")
        XCTAssertEqual(PathFormatter.one(item("/Volumes/USB/a"), style: .tilde, home: home), "/Volumes/USB/a")
    }
    func testFileURL() {
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/My File.txt"), style: .fileURL, home: home), "file:///Users/roni/My%20File.txt")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev", dir: true), style: .fileURL, home: home), "file:///Users/roni/dev/")
        XCTAssertEqual(PathFormatter.one(item("/tmp/é#?.txt"), style: .fileURL, home: home), "file:///tmp/%C3%A9%23%3F.txt")
    }
    func testName() {
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev", dir: true), style: .name, home: home), "dev")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/.env"), style: .name, home: home), ".env")
        XCTAssertEqual(PathFormatter.one(item("/", dir: true), style: .name, home: home), "/")
    }
    func testShellQuoted() {
        XCTAssertEqual(PathFormatter.one(item("/tmp/it's here.txt"), style: .shellQuoted, home: home), #"'/tmp/it'\''s here.txt'"#)
        XCTAssertEqual(PathFormatter.one(item("/tmp/$HOME `x`"), style: .shellQuoted, home: home), "'/tmp/$HOME `x`'")
    }
    func testMultipleItemsJoin() {
        let items = [item("/a/x y"), item("/a/z")]
        XCTAssertEqual(PathFormatter.format(items, style: .posix, home: home), "/a/x y\n/a/z")
        XCTAssertEqual(PathFormatter.format(items, style: .shellQuoted, home: home), "'/a/x y' '/a/z'")
        XCTAssertEqual(PathFormatter.format([], style: .posix, home: home), "")
    }
    func testDecomposedNamesAreKeptAsIs() {
        let nfd = "/tmp/Cafe\u{301}.txt"
        XCTAssertEqual(PathFormatter.one(item(nfd), style: .posix, home: home).unicodeScalars.count, nfd.unicodeScalars.count)
    }

    @MainActor func testWriteStringReplacesCutState() {
        let pb = InMemoryPasteboard()
        let clipboard = Clipboard(backend: pb)
        clipboard.cut([URL(filePath: "/tmp/a")])
        XCTAssertFalse(clipboard.cutURLs.isEmpty)
        pb.writeString("/tmp/a")
        clipboard.revalidate()
        XCTAssertTrue(clipboard.cutURLs.isEmpty, "a text copy replaces the clipboard, so the cut marker no longer applies")
        XCTAssertEqual(pb.readString(), "/tmp/a")
        XCTAssertFalse(pb.hasFileURLs())
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CoreTests.PathFormatterTests 2>&1 | tail -5`
Expected: `cannot find 'PathFormatter' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/Core/Paths/PathFormatter.swift
import Foundation

public enum PathStyle: String, Sendable, Codable, CaseIterable { case posix, tilde, fileURL, name, shellQuoted }

public struct PathItem: Sendable, Equatable {
    public var url: URL
    public var isDirectory: Bool
    public init(url: URL, isDirectory: Bool) { self.url = url; self.isDirectory = isDirectory }
}

public enum PathFormatter {
    public static func format(_ items: [PathItem], style: PathStyle, home: URL) -> String {
        items.map { one($0, style: style, home: home) }.joined(separator: style == .shellQuoted ? " " : "\n")
    }

    public static func one(_ item: PathItem, style: PathStyle, home: URL) -> String {
        let path = posixPath(item.url)
        switch style {
        case .posix: return path
        case .tilde: return tilde(path, home: posixPath(home))
        case .fileURL: return URL(filePath: path, directoryHint: item.isDirectory ? .isDirectory : .notDirectory).absoluteString
        case .name: return path == "/" ? "/" : String(path.split(separator: "/").last ?? "/")
        case .shellQuoted: return shellQuote(path)
        }
    }

    public static func tilde(_ path: String, home: String) -> String {
        guard home != "/", !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func shellQuote(_ path: String) -> String {
        "'" + path.replacing("'", with: #"'\''"#) + "'"
    }

    static func posixPath(_ url: URL) -> String {
        var p = url.standardizedFileURL.path(percentEncoded: false)
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
```

`URL.absoluteString` percent-encodes `#` and `?` in file paths and leaves `'` alone. The test above pins that. If the SDK encodes differently, fix the expectation only after checking that Finder's ⌥⌘C-pasted URL for the same name matches the new output.

Add to `PasteboardBackend`: `@discardableResult func writeString(_ string: String) -> Int` and `func readString() -> String?`. `InMemoryPasteboard` stores the string, clears its URLs and marker, bumps `changeCount` and returns it. `SystemPasteboard` calls `clearContents()`, then `setString(_:forType: .string)`, and returns `changeCount`. If P1-35 already added a text-writing method for Copy as Path, rename its uses to `writeString` in this commit.

`FileCommandController`: one private helper
```swift
private func copyPaths(_ style: PathStyle, target: CommandTarget) {
    let items = pathItems(for: target)   // contentSelection: selectedURLs + entry kind (.directory/.package → isDirectory);
                                         // currentFolder / folder(URL): that folder; favorite: its resolved URL; volume: mount point
    guard !items.isEmpty else { return }
    context.environment.clipboard.backend.writeString(PathFormatter.format(items, style: style, home: context.environment.settings.home))
    context.environment.clipboard.revalidate()
}
```
Map `copyAsPath → .posix`, `copyPathTilde → .tilde`, `copyPathFileURL → .fileURL`, `copyName → .name` and `copyPathShellQuoted → .shellQuoted`. If Phase 1 exposes the backend under another name on `Clipboard` or `CoreEnvironment`, use that. A stale favorite (no resolved URL) yields no items, so nothing is copied.

`CopyPathMenu.make(handler:)` returns an `NSMenu` titled "Copy Path As" with the items "POSIX Path", "~ Path", "File URL", "Name", "Quoted for Shell". Their actions are the five commands' selectors with `target nil`. Insert it as a submenu after "Copy as Path" in the item context menu, the Edit menu (replacing P2-02's placeholder) and the command bar's ⋯ menu.

```swift
// Tests/UITests/CopyPathMenuTests.swift
import XCTest
@testable import UI
@testable import Core

@MainActor final class CopyPathMenuTests: XCTestCase {
    func testSubmenuItemsAndSelectors() {
        let menu = CopyPathMenu.make()
        XCTAssertEqual(menu.items.map(\.title), ["POSIX Path", "~ Path", "File URL", "Name", "Quoted for Shell"])
        XCTAssertEqual(menu.items.map { $0.action.map(NSStringFromSelector) },
                       ["macx_copyAsPath:", "macx_copyPathTilde:", "macx_copyPathFileURL:", "macx_copyName:", "macx_copyPathShellQuoted:"])
    }
}
```
If `Command.copyAsPath.selectorName` is a standard selector in Phase 1, assert `Command.copyAsPath.selectorName` instead of the literal.

- [ ] **Step 4: Add the scenario**

```json
// Tests/Scenarios/p2-copy-path.json
{"name": "p2-copy-path",
 "fixture": {"files": ["it's here.txt"], "dirs": ["sub"]},
 "steps": [
  {"click": "it's here.txt"},
  {"key": "cmd+shift+c"},
  {"expect": {"pasteboardText": "{root}/it's here.txt"}},
  {"menu": ["Edit", "Copy Path As", "Quoted for Shell"]},
  {"expect": {"pasteboardText": "'{root}/it'\\''s here.txt'"}},
  {"menu": ["Edit", "Copy Path As", "~ Path"]},
  {"expect": {"pasteboardText": "{root}/it's here.txt"}},
  {"menu": ["Edit", "Copy Path As", "File URL"]},
  {"expect": {"pasteboardText": "{rootURL}it's%20here.txt"}},
  {"click": "sub", "modifiers": ["cmd"]},
  {"menu": ["Edit", "Copy Path As", "Name"]},
  {"expect": {"pasteboardText": "sub\nit's here.txt"}}
 ]}
```
(The sandbox root lives under `$TMPDIR`, outside Home, so the `~` style must return the plain path. The last step checks multi-selection in display order: folders first.)

- [ ] **Step 5: Run the tests and the scenario**

Run: `swift test --filter "CoreTests.PathFormatterTests|UITests.CopyPathMenuTests" 2>&1 | tail -5 && scripts/ui-scenarios.sh p2-copy-path 2>&1 | tail -3`
Expected: `Executed 9 tests, with 0 failures`; `p2-copy-path: passed`. If P1-41's `ui-scenarios.sh` takes no name filter, add an optional first argument that limits the run to `Tests/Scenarios/<name>.json`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Paths Sources/Core/Clipboard Sources/Core/Platform/SystemPasteboard.swift Sources/UI/Menus Sources/UI/Commands Sources/UI/CommandBar Tests/CoreTests/PathFormatterTests.swift Tests/UITests/CopyPathMenuTests.swift Tests/Scenarios/p2-copy-path.json scripts/ui-scenarios.sh
git commit -m "feat: copy path variants (POSIX, ~, file URL, name, shell-quoted)"
```

**P2-04 result (as built): deviations later tasks and scenario authors must know.**
- `CopyPathMenu.make(target:handler:) -> NSMenu` replaces `make(handler:)`; both parameters default to nil (nil-targeted items for the main menu and the command bar). With a target and handler, items are bound through `MenuActionBox` (context menus). `CopyPathMenu.submenuItem(target:handler:)` wraps it as the "Copy Path As ▸" item (identifier `CopyPathMenu.submenuID`); it replaced P2-02's hidden placeholder in the Edit menu and is used in the item context menu and the command bar's More menu. The POSIX item is titled "POSIX Path" (`CopyPathMenu.title(_:)`).
- `TextPasteboard` (Phase 1, in `CommandPrompts.swift`) was removed. Every copy-path command writes through `environment.clipboard.backend.writeString(_:)`; tests and the scenario `pasteboardText` probe read `backend.readString()`.
- Sandboxed runs without `--pasteboard` use `InMemoryPasteboard` (`AppBootstrap.makePasteboard(options:)`), so they never touch the user's general pasteboard. `--pasteboard <name>` still selects a named `SystemPasteboard`.
- `Settings.home` is `--root` in sandbox runs (`AppBootstrap`: `home = options.root` when sandboxed), so the "~ Path" style yields `~/…` for items inside the root, not the plain path Step 4 says. `p2-copy-path.json` expects `"~/it's here.txt"`.
- `PathFormatter.fileURL(_:isDirectory:)` percent-encodes the path string by hand (unreserved + RFC 3986 path characters stay; space, `#`, `?`, `%` are encoded) instead of using `URL.absoluteString`, which would re-derive the file-system representation and decompose precomposed characters.
- Review fix: `PathItem` stores `path: String`, not `url`. `FileCommandController.pathItems(for:)` builds content-selection items with `PathItem(directory:name:isDirectory:)` from `FolderModel.name(atRow:)`, so an NFC on-disk name is copied as NFC. `URL.path` decomposes (NFD) on Darwin, so `PathItem(url:isDirectory:)` (current folder, favorites, volumes) and the folder part of a row's path still come out in Foundation's spelling. Packages count as directories (trailing "/" in File URL).
- Review fix (P2-02): `CommandStateBuilder.state(for:session:environment:needsFolderCount:)` scans a content selection for directories only when `needsFolderCount` is true; `FileCommandController.canPerform` passes it for `.openInNewTab` only, so other menu/toolbar validation never walks a large selection. `selectedFolderCount` is 0/1 and counts `.directory` entries only (not packages, not links/aliases to folders). P2-05/P2-06 should keep that rule or change it in both places.
- `scripts/ui-scenarios.sh` takes `--filter <substring>`, not a positional name: run `scripts/ui-scenarios.sh --filter p2-copy-path` (the same applies to every later task's "Run:" line that passes a bare scenario name).

---

### Task P2-05: Native tabs (⌘T, ⌃Tab, ⌘W, titles, dialogs on the right tab)

**Files:**
- Create: `Sources/UI/Tabs/TabController.swift`, `Tests/UITests/TabTests.swift`, `Tests/Scenarios/p2-tabs.json`
- Modify: `Sources/UI/App/WindowManager.swift`, `Sources/UI/Window/BrowserWindowController.swift`, `Sources/UI/Operations/InteractionRouter.swift`, `Sources/UI/Menus/MenuValidation.swift` (Close Tab title)

**Interfaces:**
- Consumes: `WindowManager.openWindow/windows/window(for:)`, `BrowserWindowController` (`origin`, `session`, `navigate`), `InteractionRouter(windows:)`, `Settings.startupFolder`, `LaunchOptions.root`, `Volumes`.
- Produces: `TabController.configure/newTabURL/tabTitle/orderedTabs`, `WindowManager.openTab(at:in:selecting:select:)`, `BrowserWindowController.newWindowForTab(_:)`, and `InteractionRouter.hostWindow(for:) -> NSWindow?`, which selects the origin tab and returns its window, or returns nil when the origin is gone (so the dialog goes to the Operations panel).

Design notes:
- Each tab is its own `BrowserWindowController`/`NSWindow` in one `NSWindowTabGroup`. Sessions, histories, `OriginID`s, undo routing and `moveWindowsHome(onVolume:)` therefore work per tab with no further change. `WindowManager.windows` lists every tab.
- `TabController.configure(_:)` sets `window.tabbingIdentifier = "macx.browser"` and `window.tabbingMode = .automatic`. With `NSWindow.allowsAutomaticWindowTabbing == false` (P2-02), ⌘N creates a separate window, and tabs come only from `openTab` (⌘T, the tab bar's "+" button, which sends `newWindowForTab:`, and the P2-06 gestures).
- New tabs are appended at the end: `orderedTabs(of: host).last!.addTabbedWindow(new, ordered: .above)`. With `select: false` the host stays selected (`host.window?.tabGroup?.selectedWindow = host.window`).
- ⌘T's folder (`newTabURL`) is `options.root` in sandbox mode. Otherwise it follows `Settings.startupFolder`: `.home` → `settings.home`, `.lastLocation` → the current tab's folder, `.custom(u)` → `u`.
- Tab title: `window.tab.title` = the folder's display name (`TabController.tabTitle`), always, even when `showFullPathInTitle` lengthens the window title. `window.tab.toolTip` = the full path. Both update on every `SessionEvent.folderChanged`.
- ⌘W is Phase 1's `closeWindow` (`performClose:`), which AppKit applies to the selected tab only. `MenuValidation` retitles the item "Close Tab" when `window.tabbedWindows?.count ?? 0 > 1`, and "Close Window" otherwise. Closing a tab never cancels jobs (§6.7).
- ⌃Tab / ⌃⇧Tab / ⌘⇧\ / Move Tab to New Window / Merge All Windows are AppKit's own `NSWindow` actions, wired by P2-02's menu items.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/TabTests.swift
import XCTest
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class TabTests: XCTestCase {
    var sandbox: Sandbox!
    var context: UIContext!

    override func setUp() async throws {
        sandbox = try Sandbox()
        addTeardownBlock { [sandbox] in sandbox?.destroy() }
        try sandbox.mkdir("A"); try sandbox.mkdir("state")
        let options = try LaunchOptions.parse(["macExplorer", "--root", sandbox.root.path(percentEncoded: false),
                                               "--state-dir", sandbox.url("state").path(percentEncoded: false)])
        context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root), options: options)
    }
    override func tearDown() async throws {
        for w in context?.windows.windows ?? [] { w.window?.close() }
    }

    func testNewTabURLRules() {
        let home = URL(filePath: "/Users/u", directoryHint: .isDirectory)
        let current = URL(filePath: "/Users/u/dev", directoryHint: .isDirectory)
        let settings = Settings(storage: InMemorySettingsStorage(), home: home)
        XCTAssertEqual(TabController.newTabURL(settings: settings, options: context.options, current: current), sandbox.root,
                       "sandbox mode never opens Home")
        var plain = LaunchOptions()
        plain.root = nil
        settings.startupFolder = .home
        XCTAssertEqual(TabController.newTabURL(settings: settings, options: plain, current: current), home)
        settings.startupFolder = .lastLocation
        XCTAssertEqual(TabController.newTabURL(settings: settings, options: plain, current: current), current)
        settings.startupFolder = .custom(URL(filePath: "/tmp", directoryHint: .isDirectory))
        XCTAssertEqual(TabController.newTabURL(settings: settings, options: plain, current: current).path(percentEncoded: false), "/tmp/")
    }

    func testOpenTabAppendsInBackgroundOrForeground() throws {
        try requireGUISession()
        let host = context.windows.openWindow(at: sandbox.root)
        let a = context.windows.openTab(at: sandbox.url("A"), in: host, select: false)
        XCTAssertEqual(TabController.orderedTabs(of: host.window!).count, 2)
        XCTAssertTrue(host.window!.tabGroup?.selectedWindow === host.window, "background tab keeps the host selected")
        let b = context.windows.openTab(at: sandbox.root, in: host, select: true)
        XCTAssertEqual(TabController.orderedTabs(of: host.window!).map { $0 }, [host.window!, a.window!, b.window!], "appended at the end")
        XCTAssertTrue(host.window!.tabGroup?.selectedWindow === b.window)
        XCTAssertEqual(context.windows.windows.count, 3)
        XCTAssertEqual(a.window!.tab.title, "A")
    }

    func testNewWindowForTabOpensSandboxRootAndCommandNIsSeparateWindow() throws {
        try requireGUISession()
        let host = context.windows.openWindow(at: sandbox.url("A"))
        host.newWindowForTab(nil)
        let tabs = TabController.orderedTabs(of: host.window!)
        XCTAssertEqual(tabs.count, 2)
        let newTab = context.windows.windows.first { $0.window === tabs[1] }!
        XCTAssertEqual(newTab.session.folder.directory.standardizedFileURL, sandbox.root.standardizedFileURL)
        let other = context.windows.openWindow(at: sandbox.root)
        XCTAssertEqual(TabController.orderedTabs(of: other.window!).count, 1, "⌘N must not join the tab group")
    }

    func testClosingATabKeepsTheOthers() throws {
        try requireGUISession()
        let host = context.windows.openWindow(at: sandbox.root)
        let a = context.windows.openTab(at: sandbox.url("A"), in: host, select: true)
        a.window!.performClose(nil)
        XCTAssertEqual(context.windows.windows.count, 1)
        XCTAssertTrue(context.windows.windows.first === host)
    }

    // Review Focus 4
    func testRouterSelectsOriginTabBeforePresentingSheet() throws {
        try requireGUISession()
        let host = context.windows.openWindow(at: sandbox.root)
        let a = context.windows.openTab(at: sandbox.url("A"), in: host, select: false)
        let router = InteractionRouter(windows: context.windows)
        XCTAssertTrue(router.hostWindow(for: a.origin) === a.window)
        XCTAssertTrue(host.window!.tabGroup?.selectedWindow === a.window, "origin tab must be selected before its sheet appears")
    }

    func testRouterFallsBackToPanelWhenOriginTabClosed() throws {
        try requireGUISession()
        let host = context.windows.openWindow(at: sandbox.root)
        let a = context.windows.openTab(at: sandbox.url("A"), in: host, select: true)
        let origin = a.origin
        a.window!.close()
        XCTAssertNil(InteractionRouter(windows: context.windows).hostWindow(for: origin))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UITests.TabTests 2>&1 | tail -5`
Expected: `cannot find 'TabController' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/UI/Tabs/TabController.swift
import AppKit
import Core
import MacxFS

@MainActor
enum TabController {
    static let identifier = "macx.browser"

    static func configure(_ window: NSWindow) {
        window.tabbingIdentifier = identifier
        window.tabbingMode = .automatic
    }

    static func newTabURL(settings: Settings, options: LaunchOptions, current: URL) -> URL {
        if let root = options.root { return root }
        switch settings.startupFolder {
        case .home: return settings.home
        case .lastLocation: return current
        case .custom(let url): return url
        }
    }

    static func tabTitle(for url: URL, volumes: Volumes) -> String {
        if let volume = volumes.volume(for: url), volume.mountPoint.standardizedFileURL == url.standardizedFileURL {
            return volume.name
        }
        let name = url.standardizedFileURL.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    static func orderedTabs(of window: NSWindow) -> [NSWindow] { window.tabbedWindows ?? [window] }
}
```
If Phase 1 sets the window title from `localizedNameKey` (§8, localized system-folder names), use that same string for `tabTitle`. A cached value is fine. Fetching it is never a synchronous resource lookup on main.

`WindowManager.openTab`:
```swift
@discardableResult
func openTab(at url: URL, in host: BrowserWindowController, selecting name: String? = nil, select: Bool) -> BrowserWindowController {
    let controller = makeController(at: url, selecting: name)   // the Phase 1 code path openWindow uses, without showing it
    guard let hostWindow = host.window, let newWindow = controller.window else { return controller }
    TabController.orderedTabs(of: hostWindow).last!.addTabbedWindow(newWindow, ordered: .above)
    if select { newWindow.makeKeyAndOrderFront(nil) } else { hostWindow.tabGroup?.selectedWindow = hostWindow }
    return controller
}
```
Extract `makeController(at:selecting:)` from Phase 1's `openWindow`, which keeps calling it and then shows the window. Call `TabController.configure` in `BrowserWindowController.init` for every window.

`BrowserWindowController`:
```swift
@objc override func newWindowForTab(_ sender: Any?) {
    let url = TabController.newTabURL(settings: context.environment.settings, options: context.options,
                                      current: session.folder.directory)
    context.windows.openTab(at: url, in: self, select: true)
}
```
On `SessionEvent.folderChanged`, set `window?.tab.title` and `window?.tab.toolTip` as described in the design notes.

`InteractionRouter.hostWindow(for origin: OriginID?) -> NSWindow?`: look up `windows.window(for:)`. If the controller is found and its window is visible, set `window.tabGroup?.selectedWindow = window` when that window is not already selected, and return the window. Otherwise return nil. Every Phase 1 path that picked the origin window for a sheet now calls this function. A nil result keeps Phase 1's Operations-panel route.

`MenuValidation`: for `closeWindow`, set `item.title` to `L10n` "Close Tab" or "Close Window" by tab count.

- [ ] **Step 4: Add the scenario**

```json
// Tests/Scenarios/p2-tabs.json
{"name": "p2-tabs",
 "fixture": {"files": ["A/a1.txt", "B/b1.txt"], "dirs": ["A", "B"]},
 "steps": [
  {"key": "cmd+t"},
  {"waitFor": {"tabs": ["", ""], "activeTab": 1}},
  {"doubleClick": "A"},
  {"waitFor": {"tabs": ["", "A"], "rows": ["a1.txt"]}},
  {"key": "ctrl+tab"},
  {"waitFor": {"activeTab": 0, "folder": ""}},
  {"key": "ctrl+shift+tab"},
  {"waitFor": {"activeTab": 1, "folder": "A"}},
  {"selectTab": 0},
  {"key": "cmd+w"},
  {"waitFor": {"tabs": ["A"], "folder": "A"}}
 ]}
```

- [ ] **Step 5: Run the tests and the scenario**

Run: `swift test --filter UITests.TabTests 2>&1 | tail -5 && scripts/ui-scenarios.sh p2-tabs 2>&1 | tail -3`
Expected: `Executed 6 tests, with 0 failures` (on a machine without a GUI session, 5 are skipped). Then `p2-tabs: passed`.

If `testNewWindowForTabOpensSandboxRootAndCommandNIsSeparateWindow` shows ⌘N windows joining the group, a system "Prefer tabs" setting is overriding `.automatic`. In that case set `tabbingMode = .disallowed` in `configure` and switch it to `.automatic` on the new window and the host immediately before `addTabbedWindow`, then rerun.

- [ ] **Step 6: Commit**

```bash
git add Sources/UI/Tabs Sources/UI/App/WindowManager.swift Sources/UI/Window/BrowserWindowController.swift Sources/UI/Operations/InteractionRouter.swift Sources/UI/Menus/MenuValidation.swift Tests/UITests/TabTests.swift Tests/Scenarios/p2-tabs.json
git commit -m "feat: native window tabs with new tab, next/previous tab and per-tab dialogs"
```

**P2-05 result (as built, 2026-11-05):**
- Tests use `ShellHarness` (sandbox `files/` root, `--root` set) instead of a hand-built `UIContext`; GUI tests skip through `ShellHarness.requireWindowServer()`. Added tests: tab title/tooltip follow navigation and ignore `showFullPathInTitle`, the pane never responds to `newWindowForTab:`, Close Tab / Close Window titling, the File-menu retitler, and `route(_:)` keeping a background tab as `.window(origin)` without switching tabs.
- `InteractionRouter`: `route(_:)` uses a non-selecting `candidateWindow(for:)`; only `hostWindow(for:)` (reached through `window(for: DialogHost)` right before presenting, and from "Show") selects the origin tab. `canHostSheet` also accepts a background tab whose group's selected tab is visible (background tabs are ordered out, so `isVisible` is false).
- `TabController.configure` also sets `NSWindow.allowsAutomaticWindowTabbing = false` (idempotent with `MainMenuBuilder.build()`), so windows made without the main menu (tests) never follow "Prefer tabs". `tabTitle` reuses `WindowTitle.title(fullPath: false)`; `tabToolTip(for:)` (added) is `WindowTitle.title(fullPath: true)`. `BrowserWindowController+Probe.orderedTabWindows` was removed in favour of `TabController.orderedTabs`.
- `MenuValidation.closeTitle(for:)` / `updateTitle(of:command:window:)` run from both pane `validateMenuItem`s; a File-menu `CloseItemTitler` delegate retitles the item for windows without panes (Settings, Properties) so a stale "Close Tab" never shows.
- Scenario driver fixes: the pinned key window follows its tab group's selected tab (⌃Tab, ⌃⇧Tab, ⌘W), and `selectTab` sets `tabGroup.selectedWindow` explicitly (an inactive app's `makeKeyAndOrderFront` does not switch tabs). P2-03 fix: `rootPrefixes` also holds the realpath(3) spelling of the root (`/private/var/...`), which `fsWrite`/`fsTags` guards compare against; `p2-scenario-runner` failed its `fsWrite` step without it.

---

### Task P2-06: Open in new tab (middle-click, ⌘-click, context menu, tab-bar drop) and tab restoration

**Files:**
- Create: `Sources/UI/Content/MiddleClickRouter.swift`, `Sources/UI/Tabs/TabBarDropOverlay.swift`, `Sources/UI/Tabs/NewTabToolbarItem.swift`, `Tests/UITests/MiddleClickTests.swift`, `Tests/UITests/Support/ModelLoading.swift`, `Tests/Scenarios/p2-tabs-middle-click.json`
- Modify: the Phase 1 view subclasses that already override `rightMouseDown` for right-drag (find them with `grep -rln "rightMouseDown" Sources/UI`: the Details table, Icons collection view and sidebar outline view); `Sources/UI/Commands/FileCommandController.swift` (`openInNewTab`); `Sources/UI/Menus/ContextMenuBuilder.swift` ("Open in New Tab" after "Open in New Window" for folders, and in sidebar row menus); `Sources/UI/Toolbar/ToolbarController.swift` (new-tab item); `Sources/UI/Window/BrowserWindowController.swift` (overlay install, scenario hooks)

**Interfaces:**
- Consumes: `WindowManager.openTab` (P2-05), `OpenPlanner.plan(_:newWindow:lanes:volumes:)`, `FolderModel.entry(atRow:)/url(atRow:)`, `SidebarItem`, and `FocusContext`.
- Produces: `NewTabGesture`, `MiddleClickRouter.shouldOpenTab/folderTarget`, `TabDropPolicy.candidateFolders(_:)` / `confirmFolders(_:lanes:volumes:) async`, and the scenario hooks `performMiddleClick` and `clickTarget` (`tree:` targets).

Behaviour:
- **Middle-click** (button 2, press and release on the same row) on a folder in the content list or grid, a sidebar Favorites or Locations row, or a tree node opens it in a background tab. It does not change the selection.
  - On a file or an application it does nothing.
  - On an alias or symlink row it goes through `OpenPlanner.plan(newWindow: true)`. A folder target opens a tab; anything else does nothing (a broken link shows Phase 1's broken-link alert).
- **⌘-click** on a sidebar or tree row opens that row's folder in a background tab and leaves the sidebar selection unchanged. ⌘-click in the content view keeps its Phase 1 toggle meaning (§11).
- **Open in New Tab** (context menu, File menu) opens every selected folder. The first new tab is selected. With more than 10 folders, Phase 1's `OpenPlan.needsConfirmation` alert appears first.
- **Tab-bar drop:** dragging a folder onto the tab bar opens it in a new tab and leaves the dragged item untouched (drop operation `.link`, never a move or copy). Validation is in-memory: `URL.hasDirectoryPath` on the pasteboard file URLs. Finder and macExplorer both write directory URLs with a trailing slash. `performDragOperation` confirms directory-ness on a lane and opens one tab per folder.
  - AppKit has no public drop API for the native tab bar, so Step 6 is a timeboxed spike of `TabBarDropOverlay`. It is a transparent view added to the titlebar container over the tab bar's frame. `hitTest` returns nil so clicks reach the tabs, and the view registers for file URLs.
  - If the spike shows that AppKit does not route drags to it, ship the fallback instead: the `NewTabToolbarItem` "＋" button in the default toolbar (click = ⌘T, drop folders = tabs). Record the outcome in the commit message, and add one line under spec §11 Tabs: "Tab-bar drop: via the New Tab toolbar button (native tab bar has no drop API)".

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/Support/ModelLoading.swift (reuse an equivalent Phase 1 helper if one exists)
import XCTest
@testable import Core

@MainActor
func loadedModel(_ url: URL, env: CoreEnvironment, query: ViewQuery? = nil) async throws -> FolderModel {
    let model = env.makeFolderModel(url, query: query)
    let done = XCTestExpectation(description: "complete \(url.lastPathComponent)")
    let token = model.observe { if case .state(.complete) = $0 { done.fulfill() } }
    model.start()
    await XCTWaiter().fulfillment(of: [done], timeout: 5)
    token.cancel()
    return model
}
```

```swift
// Tests/UITests/MiddleClickTests.swift
import XCTest
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class MiddleClickTests: XCTestCase {
    func testGestureRules() {
        XCTAssertTrue(MiddleClickRouter.shouldOpenTab(.middleClick, in: .content))
        XCTAssertFalse(MiddleClickRouter.shouldOpenTab(.commandClick, in: .content), "⌘-click toggles selection in content")
        for f in [FocusContext.sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot] {
            XCTAssertTrue(MiddleClickRouter.shouldOpenTab(.middleClick, in: f))
            XCTAssertTrue(MiddleClickRouter.shouldOpenTab(.commandClick, in: f))
        }
        XCTAssertFalse(MiddleClickRouter.shouldOpenTab(.middleClick, in: .fieldEditor))
        XCTAssertFalse(MiddleClickRouter.shouldOpenTab(.middleClick, in: .addressBar))
    }

    func testFolderTargetByKind() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.mkdir("A"); try sandbox.write("f.txt", bytes: 1)
        try sandbox.mkdir("X.app/Contents")
        try sandbox.symlink("L", to: "A")
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        let model = try await loadedModel(sandbox.root, env: env)
        func target(_ name: String) -> URL? { MiddleClickRouter.folderTarget(row: model.row(named: name)!, in: model) }
        XCTAssertEqual(target("A")?.lastPathComponent, "A")
        XCTAssertNil(target("f.txt"))
        XCTAssertNil(target("X.app"), "applications launch, they never open as tabs")
        XCTAssertEqual(target("L")?.lastPathComponent, "L", "links are candidates; OpenPlanner resolves them")
    }

    func testTabDropPolicyIsInMemoryThenConfirmedOnALane() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.mkdir("A"); try sandbox.write("f.txt", bytes: 1)
        let dir = URL(filePath: sandbox.url("A").path(percentEncoded: false), directoryHint: .isDirectory)
        let fakeDir = URL(filePath: sandbox.url("f.txt").path(percentEncoded: false), directoryHint: .isDirectory) // lies
        let file = sandbox.url("f.txt")
        XCTAssertEqual(TabDropPolicy.candidateFolders([dir, file, fakeDir]), [dir, fakeDir])
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        let confirmed = await TabDropPolicy.confirmFolders([dir, fakeDir], lanes: env.lanes, volumes: env.volumes)
        XCTAssertEqual(confirmed.map(\.lastPathComponent), ["A"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UITests.MiddleClickTests 2>&1 | tail -5`
Expected: `cannot find 'MiddleClickRouter' in scope`.

- [ ] **Step 3: Implement the routing types**

```swift
// Sources/UI/Content/MiddleClickRouter.swift
import AppKit
import Core
import MacxFS

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

    static func folderTarget(row: Int, in folder: FolderModel) -> URL? {
        guard row >= 0, row < folder.rowCount else { return nil }
        switch folder.entry(atRow: row).kind {
        case .directory, .symlink, .alias: return folder.url(atRow: row)
        case .file, .package, .other: return nil
        }
    }
}
```

```swift
// Sources/UI/Tabs/NewTabToolbarItem.swift (TabDropPolicy lives here too)
import AppKit
import Core
import MacxFS

enum TabDropPolicy {
    static func candidateFolders(_ urls: [URL]) -> [URL] { urls.filter(\.hasDirectoryPath) }

    /// stat on a read lane of each URL's volume; keeps existing directories (packages excluded), in order.
    static func confirmFolders(_ urls: [URL], lanes: LanePool, volumes: Volumes) async -> [URL] {
        var result: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            let volume = volumes.volume(for: url)?.id ?? .unknown
            let isDir = (try? await lanes.perform(on: volume, .read) { _ -> Bool in
                var st = stat()
                return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            }) ?? false
            if isDir { result.append(URL(filePath: path, directoryHint: .isDirectory)) }
        }
        return result
    }
}
```
Packages are directories at the POSIX level. Drop the ones the type registry calls packages: `TypeRegistry.shared.isPackage(TypeRegistry.shared.index(forExtension: ext, isDirectory: true))` gives the in-memory answer, so filter `result` with it before returning.

The `NewTabToolbarItem` class is an `NSToolbarItem`, identifier `macx.newTab`. Its view is an `NSButton` with SF Symbol `plus.square.on.square`, accessibility label `L10n` "New Tab", AXID `newTabItem`, and action `newWindowForTab:`. The button subclass registers `.fileURL`. Its drag-and-drop methods:
- `draggingEntered`/`draggingUpdated` return `.link` when `candidateFolders` is non-empty, else `[]`.
- `performDragOperation` reads the URLs (`readObjects(forClasses: [NSURL.self])`), awaits `confirmFolders`, opens each folder with `openTab(select: index == 0)` on the button's window controller, and returns `true`.
- `draggingSourceOperationMask` is not involved (we are the destination).

The item is in the allowed set. It is in the default set only if the Step 6 spike fails.

- [ ] **Step 4: Wire middle-click and ⌘-click in the views**

In each Phase 1 view subclass found by the grep (Details table, Icons collection view, sidebar outline view):
```swift
private var middleDownRow = -1
override func otherMouseDown(with event: NSEvent) {
    guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
    middleDownRow = rowIndex(at: event)          // row(at:) for tables/outlines; FileGridLayout index for the grid
}
override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
    defer { middleDownRow = -1 }
    let row = rowIndex(at: event)
    guard row >= 0, row == middleDownRow else { return }
    onNewTabGesture?(.middleClick, row)          // set by the owning controller
}
```
The Details and Icons controllers handle `onNewTabGesture`. When `MiddleClickRouter.shouldOpenTab(gesture, in: .content)` holds and `folderTarget(row:in:)` returns a URL, they call `FileCommandController.openInNewTab(urls: [url], select: false)`.

In P2-10, `row` is a table row: the Details controller maps it through `RowMapping`, and header rows are ignored. The sidebar subclass also overrides `mouseDown`: if `event.modifierFlags.contains(.command)` and the clicked row is a favorite, location or tree node with a URL, it calls `onNewTabGesture?(.commandClick, row)` and returns without calling `super`, so the selection is unchanged.

`FileCommandController.openInNewTab(urls:select:)`:
1. Builds `OpenItem`s and awaits `OpenPlanner.plan(items, newWindow: true, …)`.
2. Keeps the `.navigate(url)` and `.openInNewWindow(url)` actions.
3. If `needsConfirmation`, shows the Phase 1 confirm alert first.
4. Calls `context.windows.openTab(at:in:select:)` for each, with `select` applied to the first only. `brokenLink` actions show the Phase 1 broken-link alert.

The `Command.openInNewTab` handler calls it with the selected folders (content) or the sidebar row's URL, and `select: true`.

Scenario hooks, installed by `BrowserWindowController`:
- `performMiddleClick(target)`: a plain name → the content row named so. `"tree:<rel>"` → reveal and expand ancestors of `root/<rel>` in the Folders tree, then use that node. Either way, call the same `onNewTabGesture(.middleClick, …)` path. Returns false when the target is not found.
- `clickTarget("tree:<rel>", modifiers)`: the same reveal. With `"cmd"`, use the ⌘-click path; otherwise a plain click.

- [ ] **Step 5: Add the scenario and run the tests**

```json
// Tests/Scenarios/p2-tabs-middle-click.json
{"name": "p2-tabs-middle-click",
 "fixture": {"files": ["A/a.txt"], "dirs": ["A", "B"]},
 "steps": [
  {"middleClick": "A"},
  {"waitFor": {"tabs": ["", "A"], "activeTab": 0, "selection": []}},
  {"click": "tree:B", "modifiers": ["cmd"]},
  {"waitFor": {"tabs": ["", "A", "B"], "activeTab": 0, "folder": ""}},
  {"middleClick": "tree:A"},
  {"waitFor": {"tabs": ["", "A", "B", "A"], "activeTab": 0}},
  {"selectTab": 1},
  {"waitFor": {"folder": "A", "rows": ["a.txt"]}},
  {"selectTab": 0},
  {"rightClick": "B"},
  {"chooseMenuItem": "Open in New Tab"},
  {"waitFor": {"tabs": ["", "A", "B", "A", "B"], "activeTab": 4}}
 ]}
```

Run: `swift test --filter UITests.MiddleClickTests 2>&1 | tail -5 && scripts/ui-scenarios.sh p2-tabs-middle-click 2>&1 | tail -3`
Expected: `Executed 3 tests, with 0 failures`; `p2-tabs-middle-click: passed`.

- [ ] **Step 6: Tab-bar drop spike (timebox 45 minutes)**

1. Implement `TabBarDropOverlay`. It is an `NSView` subclass with AXID `tabBarDrop`, registered for `.fileURL`. `hitTest(_:)` returns nil. `draggingEntered`/`Updated` return `.link` for candidate folders. `performDragOperation` behaves like the toolbar button's.
2. Install it on `SessionEvent.folderChanged` and on `NSWindow.didResizeNotification`, when the window has a tab bar (`tabbedWindows?.count ?? 0 > 1`, or the tab bar is shown). It goes into `window.standardWindowButton(.closeButton)?.superview?.superview` (the titlebar container), sized to the band between the toolbar's bottom and the content layout rect's top.
3. Manual check, sandbox only. Run:
   ```bash
   S="${TMPDIR}macx-scenario-$(uuidgen)"; mkdir -p "$S/state" "$S/A" "$S/B"
   scripts/bundle.sh debug --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app
   .build/macExplorer-scenarios.app/Contents/MacOS/macExplorer --root "$S" --state-dir "$S/state" --sandbox-trash "$S/.trash" \
     --pasteboard "macx-tests-$(uuidgen)" --fake-launch-services --skip-onboarding &
   ```
   Press ⌘T so the tab bar shows. Press ⌘N for a second window, and drag folder `B` from the second window's list onto the first window's tab bar.
   Expected: a new tab "B" appears in the first window. `B` is still in `$S`: run `ls "$S"` and expect `A B state`. Afterwards quit the app and run `rm -rf "$S"`.
4. If the tab appears, keep the overlay, and keep the toolbar item out of the default set. Otherwise, delete the overlay file, add `NewTabToolbarItem` to the default toolbar set, rerun the manual check by dropping onto "＋" (same expectation), and add the spec note from the Behaviour list.

- [ ] **Step 7: Run the full UI suite**

Run: `swift test --filter UITests 2>&1 | tail -3`
Expected: `0 failures`.

- [ ] **Step 8: Commit**

```bash
git add Sources/UI Tests/UITests/MiddleClickTests.swift Tests/UITests/Support/ModelLoading.swift Tests/Scenarios/p2-tabs-middle-click.json docs/superpowers/specs/2026-11-01-macexplorer-design.md
git commit -m "feat: open folders in new tabs by middle-click, cmd-click, menu and tab-bar drop

Tab-bar drop spike: <overlay works | fell back to New Tab toolbar button>"
```

- [ ] **Step 9: Manual tab-restoration check (sandbox only, own bundle id)**

Phase 1 restores windows through AppKit state restoration, which restores tab groups natively when every tab is restorable. Sandbox mode disables restoration, so this one check runs without `--root`, under its own bundle id:
```bash
test ! -e ~/Library/Saved\ Application\ State/com.macexplorer.app.restore-check.savedState && \
test ! -e ~/Library/Preferences/com.macexplorer.app.restore-check.plist && echo CLEAN
S="${TMPDIR}macx-scenario-$(uuidgen)"; mkdir -p "$S/A" "$S/B"; echo "$S"
scripts/bundle.sh debug --bundle-id com.macexplorer.app.restore-check --output .build/macExplorer-restore.app
.build/macExplorer-restore.app/Contents/MacOS/macExplorer --skip-onboarding &
```
Expected: `CLEAN` is printed (otherwise stop and investigate).
1. In the app, press ⌘L and type the printed `$S/A` path, then Return.
2. Press ⌘T, then ⌘L and type `$S/B`, then Return.
3. Quit with ⌘Q and relaunch with the same command.
4. Expected: one window with two tabs, "A" and "B", and "B" selected.
5. Quit, then clean up exactly what the check created:
```bash
rm -rf ~/Library/Saved\ Application\ State/com.macexplorer.app.restore-check.savedState \
       ~/Library/Preferences/com.macexplorer.app.restore-check.plist "$S" .build/macExplorer-restore.app
```
If the tabs come back as separate windows, set `window.isRestorable = true` and `restorationClass` on every tab window in `makeController`, as Phase 1 does for windows it shows. Then repeat the check. Record the result in the release checklist section of the README.

---

### Task P2-07: Per-folder view state store

**Files:**
- Create: `Sources/Core/ViewState/FolderViewState.swift`, `FolderViewStore.swift`, `FolderIdentityProbe.swift`, `Tests/CoreTests/FolderViewStoreTests.swift`
- Modify: `Sources/Core/Settings/Settings.swift` (`defaultFolderViewState`, `applyDefaultView`), `Sources/Core/Support/CoreEnvironment.swift` (`folderViews`)

**Interfaces:**
- Consumes: `SettingsStorage`, `InMemorySettingsStorage`, `VolumeInfo`, `VolumeCapabilities`, `NameNormalizer.identityName`, `LanePool.perform`, `withNoMaterialization`.
- Produces: §2.2 `FolderViewState`, `FolderViewKey`, `FolderViewLocator`, `FolderViewStore`, `FolderIdentityProbe`, `Settings.defaultFolderViewState()/applyDefaultView(_:)`, `CoreEnvironment.folderViews`.

Rules (spec §11):
- Keys: `.object(volumeUUID, fileID)` on `idStable` volumes whose `VolumeID` is `uuid:`; otherwise `.path` (NFC, and lowercased on case-insensitive volumes). Lookup order: object key, then the path index (a record's last known path), then `defaults()`.
- A path hit whose record is object-keyed with a different `fileID` than the locator's is a different folder now living at that path, so it returns `defaults()`.
- Records are created only by `save`. Untouched folders follow the defaults, so "Apply to All Folders" (which changes the defaults and calls `removeAll`) affects them.
- At most 5,000 records. Past that, the least recently used are evicted. Writes are debounced by `flushDelay`, and `flush()` writes immediately.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/FolderViewStoreTests.swift
import XCTest
@testable import Core
import MacxFS

@MainActor
final class FolderViewStoreTests: XCTestCase {
    let defaults = FolderViewState(mode: .details, columns: [], sort: .default, iconSize: .medium, groupBy: .none, calculateFolderSizes: false)
    var icons: FolderViewState { var s = defaults; s.mode = .icons; s.iconSize = .large; return s }

    func volume(id: String, idStable: Bool, caseSensitive: Bool = false) -> VolumeInfo {
        VolumeInfo(id: VolumeID(raw: id), mountPoint: URL(filePath: "/", directoryHint: .isDirectory), name: "V", format: "APFS",
                   isBoot: true, isInternal: true, isRemovable: false, isEjectable: false, isLocal: true, isReadOnly: false,
                   isBrowsable: true, totalCapacity: nil,
                   capabilities: VolumeCapabilities(idStable: idStable, renameExcl: true, clone: true, caseSensitive: caseSensitive))
    }
    func loc(_ path: String, _ v: VolumeInfo?, _ id: UInt64?) -> FolderViewLocator {
        FolderViewLocator(url: URL(filePath: path, directoryHint: .isDirectory), volume: v, fileID: id)
    }
    func makeStore(_ storage: InMemorySettingsStorage = InMemorySettingsStorage(), delay: Duration = .seconds(60),
                   now: @escaping @MainActor () -> Date = { Date() }) -> FolderViewStore {
        FolderViewStore(storage: storage, defaults: { [defaults] in defaults }, now: now, flushDelay: delay)
    }

    func testKeys() {
        let apfs = volume(id: "uuid:ABC", idStable: true)
        XCTAssertEqual(loc("/Users/u/dev/", apfs, 42).primaryKey, .object(volumeUUID: "ABC", fileID: 42))
        XCTAssertEqual(loc("/Users/u/dev", apfs, nil).primaryKey, .path("/users/u/dev"))
        XCTAssertNil(loc("/x", volume(id: "mnt:/Volumes/X", idStable: true), 7).objectKey, "no UUID → path key")
        XCTAssertEqual(loc("/Volumes/CS/Dir", volume(id: "uuid:Q", idStable: false, caseSensitive: true), 7).primaryKey, .path("/Volumes/CS/Dir"))
    }

    func testDefaultsWithoutRecord() {
        XCTAssertEqual(makeStore().state(for: loc("/a", nil, nil)), defaults)
    }

    func testObjectKeyFollowsRenameAndUpdatesPathIndex() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/Photos", v, 42))
        XCTAssertEqual(store.state(for: loc("/u/Pictures", v, 42)), icons, "renamed folder keeps its view")
        XCTAssertEqual(store.state(for: loc("/u/Pictures", v, nil)), icons, "path index now points at the new name")
    }

    func testNewFolderAtOldPathDoesNotInheritWhenItsIDIsKnown() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/Photos", v, 42))
        XCTAssertEqual(store.state(for: loc("/u/Photos", v, 99)), defaults)
    }

    func testPathKeyOnCaseInsensitiveNonStableVolume() {
        let exfat = volume(id: "uuid:USB", idStable: false, caseSensitive: false)
        let store = makeStore()
        store.save(icons, for: loc("/Volumes/USB/Photos", exfat, 5))
        XCTAssertEqual(store.state(for: loc("/Volumes/USB/photos", exfat, nil)), icons)
        XCTAssertEqual(store.state(for: loc("/Volumes/USB/Photos\u{0301}", exfat, nil)), defaults, "different name")
    }

    func testPathRecordMigratesToObjectKeyWithoutDuplicating() {
        let v = volume(id: "uuid:ABC", idStable: true)
        let store = makeStore()
        store.save(icons, for: loc("/u/dev", v, nil))
        XCTAssertEqual(store.state(for: loc("/u/dev", v, 7)), icons, "object miss falls back to the path record")
        var grouped = icons; grouped.groupBy = .kind
        store.save(grouped, for: loc("/u/dev", v, 7))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.state(for: loc("/u/dev", v, 7)), grouped)
    }

    func testPersistenceAndDebounce() async throws {
        let storage = InMemorySettingsStorage()
        let store = makeStore(storage, delay: .milliseconds(50))
        store.save(icons, for: loc("/a", nil, nil))
        XCTAssertNil(storage.data(forKey: FolderViewStore.storageKey), "debounced")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(storage.data(forKey: FolderViewStore.storageKey))
        XCTAssertEqual(makeStore(storage).state(for: loc("/a", nil, nil)), icons)
    }

    func testEvictionKeepsMostRecentlyUsed() {
        var t = Date(timeIntervalSince1970: 0)
        let store = makeStore(now: { t })
        for i in 0...FolderViewStore.capacity {
            t = t.addingTimeInterval(1)
            store.save(icons, for: loc("/f\(i)", nil, nil))
        }
        XCTAssertEqual(store.count, FolderViewStore.capacity)
        XCTAssertFalse(store.hasOverride(for: loc("/f0", nil, nil)))
        XCTAssertTrue(store.hasOverride(for: loc("/f\(FolderViewStore.capacity)", nil, nil)))
    }

    func testRemoveAllAndApplyDefaultView() {
        let storage = InMemorySettingsStorage()
        let settings = Settings(storage: storage)
        let store = FolderViewStore(storage: storage, defaults: { settings.defaultFolderViewState() })
        store.save(icons, for: loc("/a", nil, nil))
        var applied = icons; applied.calculateFolderSizes = true; applied.groupBy = .size
        settings.applyDefaultView(applied)
        store.removeAll()
        XCTAssertEqual(store.count, 0)
        let d = store.state(for: loc("/b", nil, nil))
        XCTAssertEqual(d.mode, .icons); XCTAssertEqual(d.iconSize, .large); XCTAssertEqual(d.groupBy, .size)
        XCTAssertFalse(d.calculateFolderSizes, "folder sizes are always per folder, never a default")
        XCTAssertEqual(settings.viewMode, .icons)
    }

    func testIdentityProbeReadsDirectoryInode() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        let dir = try sandbox.mkdir("d")
        var st = stat(); XCTAssertEqual(stat(dir.path(percentEncoded: false), &st), 0)
        let id = await FolderIdentityProbe.fileID(of: dir, lanes: LanePool(), volume: .unknown)
        XCTAssertEqual(id, UInt64(st.st_ino))
        XCTAssertNil(await FolderIdentityProbe.fileID(of: sandbox.url("missing"), lanes: LanePool(), volume: .unknown))
    }
}
```
(`testIdentityProbeReadsDirectoryInode` needs `import MacxFixtures`; add it to the imports. `stat` on the test thread is fine. Tests are not the main-thread rule's subject, and `XCTestCase` methods annotated `@MainActor` still run off lanes only for the probe itself.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CoreTests.FolderViewStoreTests 2>&1 | tail -5`
Expected: `cannot find type 'FolderViewState' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/Core/ViewState/FolderViewState.swift
import Foundation
import MacxFS

public struct FolderViewState: Sendable, Codable, Equatable {
    public var mode: ViewMode
    public var columns: [ColumnSetting]
    public var sort: SortDescriptor
    public var iconSize: IconSize
    public var groupBy: GroupBy
    public var calculateFolderSizes: Bool
    public init(mode: ViewMode, columns: [ColumnSetting], sort: SortDescriptor, iconSize: IconSize,
                groupBy: GroupBy, calculateFolderSizes: Bool) {
        self.mode = mode; self.columns = columns; self.sort = sort; self.iconSize = iconSize
        self.groupBy = groupBy; self.calculateFolderSizes = calculateFolderSizes
    }
}

public enum FolderViewKey: Hashable, Sendable, Codable {
    case object(volumeUUID: String, fileID: UInt64)
    case path(String)
}

public struct FolderViewLocator: Sendable, Equatable {
    public var path: String
    public var volume: VolumeInfo?
    public var fileID: UInt64?

    public init(url: URL, volume: VolumeInfo?, fileID: UInt64?) {
        var p = url.standardizedFileURL.path(percentEncoded: false)
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        self.path = p; self.volume = volume; self.fileID = fileID
    }
    public var objectKey: FolderViewKey? {
        guard let volume, volume.capabilities.idStable, volume.id.raw.hasPrefix("uuid:"), let fileID else { return nil }
        return .object(volumeUUID: String(volume.id.raw.dropFirst("uuid:".count)), fileID: fileID)
    }
    public var pathKey: FolderViewKey {
        .path(NameNormalizer.identityName(path, caseSensitive: volume?.capabilities.caseSensitive ?? false))
    }
    public var primaryKey: FolderViewKey { objectKey ?? pathKey }
}
```

```swift
// Sources/Core/ViewState/FolderViewStore.swift
import Foundation

@MainActor
public final class FolderViewStore {
    public static let storageKey = "folderViews.v1"
    public static let capacity = 5_000

    struct Record: Codable, Equatable {
        var key: FolderViewKey
        var pathKey: FolderViewKey
        var state: FolderViewState
        var lastUsed: Date
    }

    private let storage: any SettingsStorage
    private let defaults: @MainActor () -> FolderViewState
    private let now: @MainActor () -> Date
    private let flushDelay: Duration
    private var records: [FolderViewKey: Record] = [:]
    private var byPath: [FolderViewKey: FolderViewKey] = [:]
    private var flushTask: Task<Void, Never>?

    public init(storage: any SettingsStorage, defaults: @escaping @MainActor () -> FolderViewState,
                now: @escaping @MainActor () -> Date = { Date() }, flushDelay: Duration = .seconds(1)) {
        self.storage = storage; self.defaults = defaults; self.now = now; self.flushDelay = flushDelay
        if let data = storage.data(forKey: Self.storageKey),
           let list = try? JSONDecoder().decode([Record].self, from: data) {
            for r in list { records[r.key] = r; byPath[r.pathKey] = r.key }
        }
    }

    public var count: Int { records.count }

    public func state(for locator: FolderViewLocator) -> FolderViewState {
        guard var record = lookup(locator) else { return defaults() }
        record.lastUsed = now()
        if record.pathKey != locator.pathKey, case .object = record.key {   // visited under a new name
            if byPath[record.pathKey] == record.key { byPath[record.pathKey] = nil }
            record.pathKey = locator.pathKey
            byPath[locator.pathKey] = record.key
        }
        records[record.key] = record
        return record.state
    }

    public func hasOverride(for locator: FolderViewLocator) -> Bool { lookup(locator) != nil }

    public func save(_ state: FolderViewState, for locator: FolderViewLocator) {
        let key = locator.primaryKey
        if let old = byPath[locator.pathKey], old != key, case .path = old { records[old] = nil }   // path → object migration
        if let existing = records[key], existing.pathKey != locator.pathKey, byPath[existing.pathKey] == key {
            byPath[existing.pathKey] = nil
        }
        records[key] = Record(key: key, pathKey: locator.pathKey, state: state, lastUsed: now())
        byPath[locator.pathKey] = key
        evictIfNeeded()
        scheduleFlush()
    }

    public func removeAll() {
        records.removeAll(); byPath.removeAll()
        flush()
    }

    public func flush() {
        flushTask?.cancel(); flushTask = nil
        let list = records.values.sorted { $0.lastUsed > $1.lastUsed }
        storage.set(try? JSONEncoder().encode(list), forKey: Self.storageKey)
    }

    private func lookup(_ l: FolderViewLocator) -> Record? {
        if let k = l.objectKey, let r = records[k] { return r }
        guard let k = byPath[l.pathKey], let r = records[k] else { return nil }
        if case .object(_, let id) = r.key, let fileID = l.fileID, fileID != id { return nil }
        return r
    }

    private func evictIfNeeded() {
        guard records.count > Self.capacity else { return }
        let victims = records.values.sorted { $0.lastUsed < $1.lastUsed }.prefix(records.count - Self.capacity)
        for v in victims {
            records[v.key] = nil
            if byPath[v.pathKey] == v.key { byPath[v.pathKey] = nil }
        }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let delay = flushDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
```

```swift
// Sources/Core/ViewState/FolderIdentityProbe.swift
import Foundation
import Darwin
import MacxFS

public enum FolderIdentityProbe {
    public static func fileID(of url: URL, lanes: LanePool, volume: VolumeID) async -> UInt64? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let result = try? await lanes.perform(on: volume, .read) { _ -> UInt64? in
            assertOffMain()
            return withNoMaterialization { () -> UInt64? in
                var st = stat()
                return stat(path, &st) == 0 ? UInt64(st.st_ino) : nil
            }
        }
        return result ?? nil
    }
}
```

`Settings`:
```swift
extension Settings {
    public func defaultFolderViewState() -> FolderViewState {
        FolderViewState(mode: viewMode, columns: columns, sort: sort, iconSize: iconSize, groupBy: groupBy, calculateFolderSizes: false)
    }
    public func applyDefaultView(_ state: FolderViewState) {
        viewMode = state.mode; columns = state.columns; sort = state.sort; iconSize = state.iconSize; groupBy = state.groupBy
    }
}
```
`CoreEnvironment.init` builds `folderViews = FolderViewStore(storage: settingsStorage, defaults: { [unowned settings] in settings.defaultFolderViewState() })`, with `settings` captured after it is created. `sandboxed(root:)` gets the same thing over its `InMemorySettingsStorage`. The App target's `applicationWillTerminate` (in `AppLifecycle`, P1-30) calls `environment.folderViews.flush()`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CoreTests.FolderViewStoreTests 2>&1 | tail -5`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ViewState Sources/Core/Settings/Settings.swift Sources/Core/Support/CoreEnvironment.swift Sources/UI/App/AppLifecycle.swift Tests/CoreTests/FolderViewStoreTests.swift
git commit -m "feat: per-folder view state store keyed by volume UUID + fileID or path"
```

**P2-07 result (as built):**
- `FolderViewState.sort` is spelled `MacxFS.SortDescriptor` (Foundation's `SortDescriptor` clashes in Core).
- `FolderIdentityProbe.fileID` uses `stat` (follows a final symlink, so the key is the folder shown) and returns nil
  for non-directories. §2.2's `encodeComment`/`encodeLastUsed` lines sit under `FolderIdentityProbe` by mistake; they
  belong to `FinderMetadata` (P2-15), and P2-07 does not add them.
- Store refinements over the plan code: `save` without a fileID updates the object record already indexed at that
  path (no duplicate path record while the identity probe is pending); a path hit is rejected when the locator's
  object key names another volume/fileID; a renamed visit moves the path index, drops a superseded path record at
  the new path and schedules a flush; eviction takes the single oldest with `min` (no sort per save); a stored list
  is decoded most-recent-first and capped at `capacity`.
- `AppLifecycle.willTerminate()` calls `environment.folderViews.flush()` before `flushSettings()` (so the
  `FileSettingsStorage` write includes it). 14 tests, not 10 (extra: no record on lookup, flush round trip, corrupt
  storage, sandboxed environment wiring).

---

### Task P2-08: Apply per-folder view state when browsing, plus "Apply to All Folders"

**Files:**
- Create: `Sources/UI/ViewState/FolderViewCoordinator.swift`, `Tests/UITests/FolderViewCoordinatorTests.swift`, `Tests/Scenarios/p2-per-folder-view.json`
- Modify: `Sources/UI/Window/BrowserSession.swift`, `Sources/UI/Content/ContentViewController.swift`, `Sources/UI/Details/DetailsColumns.swift`, `Sources/UI/Toolbar/ToolbarController.swift` (view switcher), `Sources/UI/Commands/FileCommandController.swift` (view/sort/icon-size commands, `applyViewToAllFolders`, folder `fileID` on open)

**Interfaces:**
- Consumes: `FolderViewStore`, `FolderViewLocator`, `FolderIdentityProbe` (P2-07), `BrowserSession`, `SessionEvent`, `Volumes.volume(for:)`.
- Produces:
  - `FolderViewCoordinator` (§2.3).
  - `BrowserSession.viewState: FolderViewState` and `BrowserSession.updateViewState(_ mutate: (inout FolderViewState) -> Void)`.
  - `BrowserSession.navigate(to:selecting:recordHistory:folderID:)`, with `folderID` defaulting to nil.
  - `BrowserSession.reloadViewState()`.
  - `SessionEvent.viewStateChanged(FolderViewState)`.

Behaviour:
- **On every navigation** (address bar, sidebar, tree, back/forward, open, up, relocation):
  1. The session looks up the state in memory with the folder's `fileID` when it is known. Opening a `.directory` row passes `entry.fileID`; every other route passes nil.
  2. It builds the `FolderModel` with `ViewQuery(sort: state.sort, showHidden: settings.showHidden)` and sets `viewMode = state.mode`. Until P2-19, `.columns` displays as `.details`. P2-09 adds `state.groupBy` and P2-14 adds `state.calculateFolderSizes`.
  3. It emits `.viewStateChanged`. `ContentViewController` applies the columns (order, widths, visibility) and the icon size.
  4. The first paint never waits for I/O.
- **Identity correction:** when `fileID` was nil and the volume is `idStable`, `refine` probes it on a lane. If the model is still current when it returns, the session stores the refined locator. If `store.state(for: refined)` differs from the applied state, the session applies it, which costs one re-sort reset at most.
- **Saving:** every user change goes through `updateViewState` and is saved for this folder only. That covers the view switcher, ⌘1/⌘2/⌘3, View menu modes, icon size, header-click sort, the Sort menu, column resize, reorder and visibility, Group by (P2-10) and Calculate Folder Sizes (P2-14). These code paths no longer write `Settings.viewMode/sort/iconSize/columns`; find the old writes with `grep -rn "settings\.\(viewMode\|sort\|iconSize\|columns\) =" Sources/UI` and redirect them.
- **Apply to All Folders…:**
  1. A window-modal sheet asks: title "Use this view for all folders?", text "Folders that have their own view settings will be reset to this view.", buttons "Apply" and "Cancel".
  2. Apply calls `coordinator.applyToAll(session.viewState)`, which runs `settings.applyDefaultView` and then `store.removeAll()`.
  3. Every other open window and tab then runs `session.reloadViewState()`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/FolderViewCoordinatorTests.swift
import XCTest
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class FolderViewCoordinatorTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!

    override func setUp() async throws {
        sandbox = try Sandbox(); addTeardownBlock { [sandbox] in sandbox?.destroy() }
        try sandbox.mkdir("sub"); try sandbox.write("sub/x.txt", bytes: 1); try sandbox.write("y.txt", bytes: 1)
        env = CoreEnvironment.sandboxed(root: sandbox.root)
        _ = await env.start()
    }

    func waitFor(_ session: BrowserSession, timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testModeChangeIsSavedForThisFolderOnly() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        session.updateViewState { $0.mode = .icons }
        XCTAssertEqual(session.viewMode, .icons)
        XCTAssertEqual(env.settings.viewMode, .details, "global default untouched")
        session.navigate(to: sandbox.url("sub"))
        XCTAssertEqual(session.viewMode, .details)
        session.goBack()
        XCTAssertEqual(session.viewMode, .icons)
    }

    func testSortIsPerFolderAndDrivesTheQuery() {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        session.updateViewState { $0.sort = SortDescriptor(field: .size, ascending: false) }
        XCTAssertEqual(session.folder.query.sort, SortDescriptor(field: .size, ascending: false))
        session.navigate(to: sandbox.url("sub"))
        XCTAssertEqual(session.folder.query.sort, .default)
    }

    func testIdentityCorrectionAfterExternalRename() async throws {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        let subRow = session.folder.row(named: "sub")
        let fileID: UInt64? = subRow.map { session.folder.entry(atRow: $0).fileID }   // may be nil if still loading; probe below covers it
        session.navigate(to: sandbox.url("sub"), folderID: fileID)
        await waitFor(session) { session.folder.state == .complete }
        session.updateViewState { $0.mode = .icons }
        let volume = env.volumes.volume(for: sandbox.root)
        try XCTSkipUnless(volume?.capabilities.idStable == true && volume?.id.raw.hasPrefix("uuid:") == true, "temp volume lacks stable IDs")
        await waitFor(session) { env.folderViews.hasOverride(for: FolderViewLocator(url: self.sandbox.url("sub"), volume: volume, fileID: nil)) }
        session.navigate(to: sandbox.root)
        XCTAssertEqual(rename(sandbox.url("sub").path(percentEncoded: false), sandbox.url("renamed").path(percentEncoded: false)), 0)
        session.navigate(to: sandbox.url("renamed"))              // no fileID: path miss → defaults first
        await waitFor(session) { session.viewMode == .icons }     // refine() finds the object key
        XCTAssertEqual(session.viewMode, .icons)
    }

    func testApplyToAllMakesDefaultAndClearsOverrides() {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        session.navigate(to: sandbox.url("sub"))
        session.updateViewState { $0.mode = .details; $0.iconSize = .small }
        session.navigate(to: sandbox.root)
        session.updateViewState { $0.mode = .icons; $0.iconSize = .large }
        FolderViewCoordinator(store: env.folderViews, settings: env.settings, lanes: env.lanes, volumes: env.volumes)
            .applyToAll(session.viewState)
        XCTAssertEqual(env.folderViews.count, 0)
        session.navigate(to: sandbox.url("sub"))
        XCTAssertEqual(session.viewMode, .icons, "sub's own override was reset")
        XCTAssertEqual(session.viewState.iconSize, .large)
    }
}
```

The `rename(2)` call operates on the test's own sandbox. `BrowserSession` is the Phase 1 initializer. If Phase 1 requires a `UIContext` instead, build one as `TabTests` does.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UITests.FolderViewCoordinatorTests 2>&1 | tail -5`
Expected: `value of type 'BrowserSession' has no member 'updateViewState'`.

- [ ] **Step 3: Implement**

```swift
// Sources/UI/ViewState/FolderViewCoordinator.swift
import Foundation
import Core
import MacxFS

@MainActor
final class FolderViewCoordinator {
    private let store: FolderViewStore
    private let settings: Settings
    private let lanes: LanePool
    private let volumes: Volumes

    init(store: FolderViewStore, settings: Settings, lanes: LanePool, volumes: Volumes) {
        self.store = store; self.settings = settings; self.lanes = lanes; self.volumes = volumes
    }

    func state(for url: URL, fileID: UInt64?) -> (FolderViewState, FolderViewLocator) {
        let locator = FolderViewLocator(url: url, volume: volumes.volume(for: url), fileID: fileID)
        return (store.state(for: locator), locator)
    }

    func state(for locator: FolderViewLocator) -> FolderViewState { store.state(for: locator) }

    func save(_ state: FolderViewState, for locator: FolderViewLocator) { store.save(state, for: locator) }

    /// Adds the folder's fileID when the volume has stable IDs and the caller didn't know it.
    func refine(_ locator: FolderViewLocator) async -> FolderViewLocator {
        guard locator.fileID == nil, let volume = locator.volume, volume.capabilities.idStable else { return locator }
        let url = URL(filePath: locator.path, directoryHint: .isDirectory)
        guard let id = await FolderIdentityProbe.fileID(of: url, lanes: lanes, volume: volume.id) else { return locator }
        return FolderViewLocator(url: url, volume: volume, fileID: id)
    }

    func applyToAll(_ state: FolderViewState) {
        settings.applyDefaultView(state)
        store.removeAll()
    }
}
```

The `BrowserSession` additions, with names exactly as listed in Produces:
```swift
private(set) var viewState: FolderViewState
private var locator: FolderViewLocator
private let viewStates: FolderViewCoordinator

func navigate(to url: URL, selecting name: String? = nil, recordHistory: Bool = true, folderID: UInt64? = nil) {
    let (state, locator) = viewStates.state(for: url, fileID: folderID)
    self.viewState = state; self.locator = locator
    // Phase 1 body: close previous model, history.visit, then:
    folder = environment.makeFolderModel(url, query: ViewQuery(sort: state.sort, showHidden: environment.settings.showHidden))
    // ... start(), select name, emit .folderChanged
    setDisplayedMode(state.mode)                 // emits .viewModeChanged when it differs
    emit(.viewStateChanged(state))
    let model = folder
    Task { [weak self] in
        guard let self else { return }
        let refined = await self.viewStates.refine(locator)
        guard self.folder === model, refined != self.locator else { return }
        self.locator = refined
        let better = self.viewStates.state(for: refined)
        if better != self.viewState { self.apply(better) }
    }
}

func updateViewState(_ mutate: (inout FolderViewState) -> Void) {
    var next = viewState
    mutate(&next)
    guard next != viewState else { return }
    viewStates.save(next, for: locator)
    apply(next)
}

func reloadViewState() { apply(viewStates.state(for: locator)) }

private func apply(_ state: FolderViewState) {
    let old = viewState
    viewState = state
    if state.sort != old.sort { folder.setQuery(ViewQuery(sort: state.sort, showHidden: folder.query.showHidden, filter: folder.query.filter)) }
    if state.mode != old.mode { setDisplayedMode(state.mode) }
    emit(.viewStateChanged(state))
}
```
Keep the existing `viewMode` property as the displayed mode, set only through `setDisplayedMode`. Phase 1 callers that assigned `viewMode` call `updateViewState { $0.mode = … }` instead. Keep Phase 1's `navigate(to:selecting:recordHistory:)` callers compiling through the defaulted `folderID`.

`ContentViewController` handles `.viewStateChanged(state)`:
- applies `state.columns` to the Details table: order, widths and visibility, by `ColumnID`. `DetailsColumns` exposes `apply(_ columns: [ColumnSetting])` and reports user edits through `onColumnsChanged: ([ColumnSetting]) -> Void`, wired to `session.updateViewState { $0.columns = $1 }`;
- applies `state.iconSize` to the grid.

Every view, sort and icon-size command in `FileCommandController`, and the toolbar switcher, call `updateViewState`. `applyViewToAllFolders` presents the sheet (`NSAlert.beginSheetModal(for:)`, titles via `L10n`). On `.alertFirstButtonReturn` it calls `applyToAll` and then `context.windows.windows.forEach { $0.session.reloadViewState() }`.

For opens: when `OpenPlanner` yields `.navigate(url)` for a single `.directory` row, call `session.navigate(to: url, folderID: entry.fileID)`.

- [ ] **Step 4: Add the scenario**

```json
// Tests/Scenarios/p2-per-folder-view.json
{"name": "p2-per-folder-view",
 "fixture": {"files": ["A/x.txt", "y.txt"], "dirs": ["A"]},
 "steps": [
  {"doubleClick": "A"},
  {"waitFor": {"folder": "A", "viewMode": "details"}},
  {"key": "cmd+2"},
  {"expect": {"viewMode": "icons"}},
  {"key": "cmd+["},
  {"waitFor": {"folder": "", "viewMode": "details"}},
  {"key": "cmd+]"},
  {"waitFor": {"folder": "A", "viewMode": "icons"}},
  {"menu": ["View", "Apply to All Folders…"]},
  {"answerAlert": "Apply"},
  {"key": "cmd+["},
  {"waitFor": {"folder": "", "viewMode": "icons"}},
  {"key": "cmd+1"},
  {"key": "cmd+]"},
  {"waitFor": {"folder": "A", "viewMode": "icons"}},
  {"key": "cmd+["},
  {"waitFor": {"folder": "", "viewMode": "details"}}
 ]}
```

- [ ] **Step 5: Run the tests and the scenario**

Run: `swift test --filter UITests.FolderViewCoordinatorTests 2>&1 | tail -5 && scripts/ui-scenarios.sh p2-per-folder-view 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures` (the rename test may report a skip on a temp volume without stable IDs); `p2-per-folder-view: passed`.

- [ ] **Step 6: Run the Phase 1 scenarios again (view switching and sorting are shared paths)**

Run: `scripts/ui-scenarios.sh 2>&1 | tail -3`
Expected: `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add Sources/UI Tests/UITests/FolderViewCoordinatorTests.swift Tests/Scenarios/p2-per-folder-view.json docs/superpowers/plans/2026-11-01-phase2-views-tabs.md
git commit -m "feat: apply and save view mode, columns, sort and icon size per folder; apply to all folders"
```


**P2-08 result (as built):**
- Tests use `ShellHarness` (session-only tests, no window server) and `ContentTestHarness` (window tests) instead of
  a hand-built `CoreEnvironment.sandboxed`; 13 tests, not 4 (extra: event order, edits made before the identity probe
  returns, reload after new defaults, the open command passing the row's fileID, view/sort/icon-size commands, the
  toolbar switcher, column edits and header sort, and the Apply to All command with Cancel and with Apply across
  windows). `BrowserSession.locator` is `private(set)` (internal) so tests can see the refined fileID.
- Event order on navigation: `.folderChanged`, then `.viewModeChanged` (only when the mode differs), then
  `.viewStateChanged`. `updateViewState`/`reloadViewState` emit `.viewStateChanged` only when the state changed.
- Identity correction refinements: if the user changed the view before the probe returned, that change is saved
  under the refined locator (never overwritten by an older object record); if the refined lookup gives the same
  state and a record exists, it is re-saved so a path record becomes an object record (survives a later rename).
  `FolderViewCoordinator` gained `hasOverride(for:)` for this.
- `DetailsColumns.apply`/`onColumnsChanged` live on `DetailsViewController` (`apply(columns:sort:)`, which rebuilds
  only when the columns differ and also sets the sort indicator; `onColumnsChanged`; plus `onSortChanged` for header
  clicks, falling back to setting the folder query when the table is hosted on its own). Non-offered columns keep
  their stored width/visibility. `IconsViewController.setIconSize(_:)` replaces its `Settings.iconSize` observation.
- Apply to All asks through `CommandPrompts.confirm(.applyViewToAllFolders)` (AppKit: a window-modal `NSAlert`
  sheet with the plan's title, text and buttons) so tests can script it, then reloads every
  `context.windows.windows` session (each tab is a `BrowserWindowController`). `applyViewToAllFolders` left
  `FileCommandController.pendingCommands`.
- ~~Opening one plain folder row passes its `entry.fileID` through `execute(_:folderID:)` and
  `BrowserWindowController.navigate(to:selecting:folderID:)`.~~ Review fix (P2-05..P2-08): removed. For a mount point
  the listing's fileID is the covered folder's while the stat probe used on every other route returns the mounted
  root's, so the folder got two keys. Row opens now probe like every other route; `folderID:` stays on the session API
  for callers that have the probe's value. `ShellCommandHandler`'s sidebar view commands also
  call `updateViewState`. `ContextMenuBuilder.emptySpaceMenu(for:viewState:handler:)` takes its View ▸ checkmarks
  from the folder's state, and the scenario probe `iconSize` reads `session.viewState.iconSize`.
- Phase 1 tests that asserted writes to the global `Settings.viewMode/sort/iconSize/columns` now assert the
  per-folder state (BrowserSessionTests, ToolbarTests, DetailsViewTests, FileCommandTests, IconsViewTests).
- Scenario: adds an initial `waitFor` for the listing and a `waitFor` after ⌘1; the runner filter is
  `scripts/ui-scenarios.sh --filter p2-per-folder-view`.

---

### Task P2-09: Group by: partition, grouped-row mapping, FolderModel grouping

**Files:**
- Create: `Sources/FSKit/Sort/Grouping.swift`, `Sources/Core/Folder/GroupedRows.swift`, `Sources/Core/Folder/FolderModel+Grouping.swift`, `Tests/FSKitTests/GroupingTests.swift`, `Tests/CoreTests/GroupedRowsTests.swift`, `Tests/CoreTests/FolderModelGroupingTests.swift`, `Tests/CoreTests/Support/ModelLoading.swift` (same helper as `Tests/UITests/Support/ModelLoading.swift`)
- Modify: `Sources/Core/Folder/FolderModel.swift` (`FolderEvent.groups`, `FolderContext.now/calendar`), `Sources/Core/Folder/FolderWorker.swift` (`partition`), `Sources/UI/Window/BrowserSession.swift` (apply `groupBy`)

**Interfaces:**
- Consumes: `EntryStore`, `Entry.isFolderForSorting`, `TypeRegistry.localizedDescription/folderIndex`, `FolderModel` and `FolderWorker` (Phase 1 §3.7), `GroupBy` (P2-01), `FolderViewState.groupBy` (P2-07).
- Produces: §2.1 `Grouping`, `DateBuckets`, `GroupKey`, `GroupRun`, `DateBucket`, `SizeBucket`, `LetterKey`; §2.2 `GroupedRows`, `TableRow`, `FolderModel.grouping/groups/setGrouping/regroupForNewDay`, `FolderEvent.groups`, `FolderContext.now/calendar`.

Grouping rules (spec §11; group order is fixed, and the current sort applies inside each group):

| Group by | Groups, in display order | Folders |
|---|---|---|
| Kind | "Folder" first, then kind descriptions by `localizedStandardCompare` | own group |
| Date Modified | In the future, Today, Yesterday, Earlier this week, Last week, Earlier this month, Last month, Earlier this year, A long time ago (first matching boundary in that order wins; empty groups are omitted) | by their mtime, first within the group |
| Size | Folders, Empty (0), Tiny (≤ 16 KiB), Small (≤ 1 MiB), Medium (≤ 128 MiB), Large (≤ 1 GiB), Huge (≤ 4 GiB), Gigantic | own group |
| Name | "0–9", letters (first grapheme after leading dots, folded case/diacritic/width-insensitively, upper-cased; any script) by `localizedStandardCompare`, then "#" (symbols, emoji) | first within the group |

Model behaviour:
- Grouping is applied only while the window displays Details. `BrowserSession` calls `folder.setGrouping(displayedMode == .details ? viewState.groupBy : .none)` on navigate, on mode change and on `updateViewState`.
- While `grouping != .none`, every display-order update goes through one path. The worker produces the sorted permutation as in Phase 1. `FolderWorker.partition` groups it off main (CPU only, no file-system calls). Main sets `store.order` to the grouped order and emits `.groups(runs)` followed by `.changes(.reset)`.
  - This happens for loading frames, re-sorts, Watcher increments, FileOps local changes and `regroupForNewDay`.
  - Incremental `insert/remove/move` change sets are not used while grouped, so a new item always lands in its group. Pure `reload` change sets (same order) are still published as reloads.
  - Every result carries the model's `groupingRevision`. Stale results are dropped.
- Date grouping schedules `regroupForNewDay()` at `DateBuckets.nextBoundary` plus 1 s. The scheduling task is cancelled on `close()` and on any grouping change.
- Selection, scroll anchor and inline-rename state survive regrouping (identity-based, Phase 1).

- [ ] **Step 1: Write the failing FSKit tests**

```swift
// Tests/FSKitTests/GroupingTests.swift
import XCTest
@testable import MacxFS

final class GroupingTests: XCTestCase {
    let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 1; c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    func ns(_ s: String) -> Int64 { Int64(date(s).timeIntervalSince1970) * 1_000_000_000 }

    func testDateBucketsMidMonth() {   // 2026-11-18 is a Wednesday; week starts Sunday 11-15
        let b = DateBuckets(now: date("2026-11-18T15:00:00Z"), calendar: utc)
        let cases: [(String, DateBucket)] = [
            ("2026-11-19T01:00:00Z", .future), ("2026-11-18T00:00:00Z", .today), ("2026-11-17T23:59:59Z", .yesterday),
            ("2026-11-15T00:00:00Z", .earlierThisWeek), ("2026-11-14T12:00:00Z", .lastWeek), ("2026-11-08T00:00:00Z", .lastWeek),
            ("2026-11-07T23:59:59Z", .earlierThisMonth), ("2026-11-01T00:00:00Z", .earlierThisMonth),
            ("2026-10-31T10:00:00Z", .lastMonth), ("2026-10-01T00:00:00Z", .lastMonth),
            ("2026-09-30T10:00:00Z", .earlierThisYear), ("2026-01-01T00:00:00Z", .earlierThisYear),
            ("2025-12-31T23:59:59Z", .longAgo),
        ]
        for (s, expected) in cases { XCTAssertEqual(b.bucket(forNanoseconds: ns(s)), expected, s) }
        XCTAssertEqual(b.nextBoundary, date("2026-11-19T00:00:00Z"))
    }

    func testDateBucketsOnFirstDayOfWeekAndMonth() {   // 2026-11-01 is a Sunday
        let b = DateBuckets(now: date("2026-11-01T10:00:00Z"), calendar: utc)
        XCTAssertEqual(b.bucket(forNanoseconds: ns("2026-10-31T12:00:00Z")), .yesterday, "yesterday wins over last week")
        XCTAssertEqual(b.bucket(forNanoseconds: ns("2026-10-26T12:00:00Z")), .lastWeek)
        XCTAssertEqual(b.bucket(forNanoseconds: ns("2026-10-24T12:00:00Z")), .lastMonth)
    }

    func testSizeBuckets() {
        XCTAssertEqual(Grouping.sizeBucket(bytes: 123, isFolder: true), .folders)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 0, isFolder: false), .empty)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 1, isFolder: false), .tiny)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 16_384, isFolder: false), .tiny)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 16_385, isFolder: false), .small)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 1_048_576, isFolder: false), .small)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 134_217_728, isFolder: false), .medium)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 1_073_741_825, isFolder: false), .huge)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 4_294_967_297, isFolder: false), .gigantic)
    }

    func testLetterKeys() {
        let cases: [(String, LetterKey)] = [
            ("apple", .letter("A")), ("Äpfel", .letter("A")), ("éclair", .letter("E")), (".env", .letter("E")),
            ("Ωmega", .letter("Ω")), ("日本", .letter("日")), ("Ａbc", .letter("A")), ("2024 report", .digits), ("１x", .digits),
            ("_x", .other), ("😀.png", .other), ("", .other), ("...", .other),
        ]
        for (name, key) in cases { XCTAssertEqual(Grouping.letterKey(name), key, name) }
    }

    func testGroupOrder() {
        let keys: [GroupKey] = [.letter(.other), .letter(.letter("b")), .letter(.digits), .letter(.letter("A"))]
        XCTAssertEqual(keys.sorted(by: Grouping.groupOrder), [.letter(.digits), .letter(.letter("A")), .letter(.letter("b")), .letter(.other)])
        let kinds: [GroupKey] = [.kind("PNG image", isFolder: false), .kind("Folder", isFolder: true), .kind("Plain Text Document", isFolder: false)]
        XCTAssertEqual(kinds.sorted(by: Grouping.groupOrder).first, .kind("Folder", isFolder: true))
        XCTAssertEqual(kinds.sorted(by: Grouping.groupOrder)[1], .kind("Plain Text Document", isFolder: false))
    }

    func makeStore(_ items: [(name: String, kind: Kind, size: Int64, mtime: Int64)]) -> EntryStore {
        let types = TypeRegistry.shared
        var store = EntryStore(identityMode: .name(caseSensitive: false))
        var batch = Batch(generation: .initial)
        for (i, it) in items.enumerated() {
            let parts = it.name.split(separator: ".", omittingEmptySubsequences: false)
            let ext = parts.count > 1 ? parts.last! : Substring("")
            let e = Entry(rowID: UInt64(i + 1), fileID: UInt64(i + 1), size: it.size, allocSize: it.size, mtime: it.mtime, ctime: it.mtime,
                          nameOffset: 0, nameLen: 0, kind: it.kind, flags: [],
                          typeIndex: it.kind == .directory ? TypeRegistry.folderIndex : types.index(forExtension: ext, isDirectory: false))
            Array(it.name.utf8).withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
        }
        store.append(batch)
        store.setOrder(Array(0..<UInt32(items.count)))
        return store
    }

    func testPartitionIsStableAndContiguous() {
        let store = makeStore([("sub", .directory, 3, 0), ("a.txt", .file, 10, 0), ("c.png", .file, 20, 0), ("b.txt", .file, 0, 0)])
        let b = DateBuckets(now: Date(timeIntervalSince1970: 0), calendar: utc)
        let (order, runs) = Grouping.partition(store.order, store: store, by: .kind, dateBuckets: b, types: .shared)
        XCTAssertEqual(order.map { store.name($0) }.first, "sub")
        let txt = runs.first { if case .kind(_, false) = $0.key, order[$0.rows.lowerBound] == 1 { return true }; return false }!
        XCTAssertEqual(txt.rows.map { store.name(order[$0]) }, ["a.txt", "b.txt"], "in-group order is the input sort order")
        XCTAssertEqual(runs.map(\.rows.count).reduce(0, +), 4)
        XCTAssertEqual(zip(runs, runs.dropFirst()).allSatisfy { $0.rows.upperBound == $1.rows.lowerBound }, true)
        let (sizeOrder, sizeRuns) = Grouping.partition(store.order, store: store, by: .size, dateBuckets: b, types: .shared)
        XCTAssertEqual(sizeRuns.map(\.key), [.size(.folders), .size(.empty), .size(.tiny)])
        XCTAssertEqual(sizeOrder.map { store.name($0) }, ["sub", "b.txt", "a.txt", "c.png"])
        XCTAssertEqual(Grouping.partition(store.order, store: store, by: .none, dateBuckets: b, types: .shared).runs, [])
    }

    func testPartition100kWithinDebugBudget() {
        let items = (0..<100_000).map { (name: "file \($0 % 977) \($0).\(["txt", "png", "swift", "md"][$0 % 4])", kind: Kind.file, size: Int64($0 * 37), mtime: Int64($0) * 86_400_000_000_000) }
        let store = makeStore(items)
        let b = DateBuckets(now: Date(timeIntervalSince1970: 100_000 * 86_400), calendar: utc)
        for g in [GroupBy.kind, .dateModified, .size, .nameFirstLetter] {
            let start = ContinuousClock.now
            _ = Grouping.partition(store.order, store: store, by: g, dateBuckets: b, types: .shared)
            XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(120), "\(g): 4x the 30 ms re-sort budget in debug")
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FSKitTests.GroupingTests 2>&1 | tail -5`
Expected: `cannot find 'DateBuckets' in scope`.

- [ ] **Step 3: Implement `Grouping.swift`**

```swift
// Sources/FSKit/Sort/Grouping.swift
import Foundation

public enum DateBucket: Int, Sendable, Hashable, CaseIterable {
    case future, today, yesterday, earlierThisWeek, lastWeek, earlierThisMonth, lastMonth, earlierThisYear, longAgo
}
public enum SizeBucket: Int, Sendable, Hashable, CaseIterable { case folders, empty, tiny, small, medium, large, huge, gigantic }
public enum LetterKey: Hashable, Sendable { case digits, letter(String), other }
public enum GroupKey: Hashable, Sendable {
    case kind(String, isFolder: Bool)
    case date(DateBucket)
    case size(SizeBucket)
    case letter(LetterKey)
}
public struct GroupRun: Sendable, Equatable {
    public var key: GroupKey
    public var rows: Range<Int>
    public init(key: GroupKey, rows: Range<Int>) { self.key = key; self.rows = rows }
}

public struct DateBuckets: Sendable, Equatable {
    /// Lower bounds in ns for: future(tomorrow), today, yesterday, this week, last week, this month, last month, this year.
    let starts: [Int64]
    public let nextBoundary: Date
    private static let order: [DateBucket] = [.future, .today, .yesterday, .earlierThisWeek, .lastWeek, .earlierThisMonth, .lastMonth, .earlierThisYear]

    public init(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: week)!
        let month = calendar.dateInterval(of: .month, for: now)!.start
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: month)!
        let year = calendar.dateInterval(of: .year, for: now)!.start
        func ns(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970.rounded(.down)) * 1_000_000_000 }
        starts = [tomorrow, today, yesterday, week, lastWeek, month, lastMonth, year].map(ns)
        nextBoundary = tomorrow
    }

    public func bucket(forNanoseconds t: Int64) -> DateBucket {
        for (i, start) in starts.enumerated() where t >= start { return Self.order[i] }
        return .longAgo
    }
}

public enum Grouping {
    public static func sizeBucket(bytes: Int64, isFolder: Bool) -> SizeBucket {
        if isFolder { return .folders }
        switch bytes {
        case ..<1: return .empty
        case ...16_384: return .tiny
        case ...1_048_576: return .small
        case ...134_217_728: return .medium
        case ...1_073_741_824: return .large
        case ...4_294_967_296: return .huge
        default: return .gigantic
        }
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    public static func letterKey(_ name: String) -> LetterKey {
        guard let first = name.drop(while: { $0 == "." }).first else { return .other }
        if first.unicodeScalars.count == 1, first.unicodeScalars.first!.properties.numericType == .decimal { return .digits }
        guard first.isLetter else { return .other }
        let folded = String(first).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posix)
        return .letter(String(folded.uppercased().prefix(1)))
    }

    public static func groupOrder(_ a: GroupKey, _ b: GroupKey) -> Bool {
        switch (a, b) {
        case let (.kind(da, fa), .kind(db, fb)):
            if fa != fb { return fa }
            let c = da.localizedStandardCompare(db)
            return c == .orderedSame ? da < db : c == .orderedAscending
        case let (.date(x), .date(y)): return x.rawValue < y.rawValue
        case let (.size(x), .size(y)): return x.rawValue < y.rawValue
        case let (.letter(x), .letter(y)): return letterBefore(x, y)
        default: return false
        }
    }

    static func letterBefore(_ a: LetterKey, _ b: LetterKey) -> Bool {
        switch (a, b) {
        case (.digits, .digits), (.other, .other): return false
        case (.digits, _): return true
        case (_, .digits): return false
        case (.other, _): return false
        case (_, .other): return true
        case let (.letter(x), .letter(y)):
            let c = x.localizedStandardCompare(y)
            return c == .orderedSame ? x < y : c == .orderedAscending
        }
    }

    public static func partition(_ sorted: [UInt32], store: EntryStore, by groupBy: GroupBy,
                                 dateBuckets: DateBuckets, types: TypeRegistry) -> (order: [UInt32], runs: [GroupRun]) {
        guard groupBy != .none, !sorted.isEmpty else { return (sorted, []) }
        var kindNames: [UInt16: String] = [:]
        func kindName(_ index: UInt16) -> String {
            if let d = kindNames[index] { return d }
            let d = types.localizedDescription(index); kindNames[index] = d; return d
        }
        var buckets: [GroupKey: [UInt32]] = [:]
        for index in sorted {
            let e = store.entry(index)
            let key: GroupKey
            switch groupBy {
            case .none: return (sorted, [])
            case .kind:
                key = e.isFolderForSorting ? .kind(kindName(TypeRegistry.folderIndex), isFolder: true)
                                           : .kind(kindName(e.typeIndex), isFolder: false)
            case .dateModified: key = .date(dateBuckets.bucket(forNanoseconds: e.mtime))
            case .size: key = .size(sizeBucket(bytes: e.size, isFolder: e.isFolderForSorting))
            case .nameFirstLetter:
                key = .letter(store.withNameBytes(index) { bytes in
                    let start = bytes.firstIndex { $0 != UInt8(ascii: ".") } ?? bytes.endIndex
                    let end = min(bytes.endIndex, start + 32)
                    return letterKey(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self))
                })
            }
            buckets[key, default: []].append(index)
        }
        var order: [UInt32] = []; order.reserveCapacity(sorted.count)
        var runs: [GroupRun] = []
        for key in buckets.keys.sorted(by: groupOrder) {
            let items = buckets[key]!
            runs.append(GroupRun(key: key, rows: order.count ..< order.count + items.count))
            order.append(contentsOf: items)
        }
        return (order, runs)
    }
}
```

- [ ] **Step 4: Run the FSKit tests to verify they pass**

Run: `swift test --filter FSKitTests.GroupingTests 2>&1 | tail -5`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Write the failing Core tests**

```swift
// Tests/CoreTests/GroupedRowsTests.swift
import XCTest
@testable import Core
import MacxFS

final class GroupedRowsTests: XCTestCase {
    let runs = [GroupRun(key: .date(.today), rows: 0..<2), GroupRun(key: .date(.yesterday), rows: 2..<3), GroupRun(key: .date(.longAgo), rows: 3..<6)]

    func testExpandedMapping() {
        let g = GroupedRows(runs: runs, collapsed: [])
        XCTAssertEqual(g.tableRowCount, 9)
        XCTAssertEqual((0..<9).map(g.row), [.header(0), .item(0), .item(1), .header(1), .item(2), .header(2), .item(3), .item(4), .item(5)])
        XCTAssertEqual(g.tableRow(forModelRow: 4), 7)
        XCTAssertEqual(g.group(containingModelRow: 2), 1)
        XCTAssertEqual(g.modelRows(forTableRows: IndexSet([0, 1, 3, 4, 8])), IndexSet([0, 2, 5]))
    }

    func testCollapsedGroupHidesItsRows() {
        let g = GroupedRows(runs: runs, collapsed: [.date(.today)])
        XCTAssertEqual(g.tableRowCount, 7)
        XCTAssertEqual((0..<7).map(g.row), [.header(0), .header(1), .item(2), .header(2), .item(3), .item(4), .item(5)])
        XCTAssertNil(g.tableRow(forModelRow: 1))
        XCTAssertEqual(g.tableRows(forModelRows: IndexSet([0, 1, 2])), IndexSet([2]))
        XCTAssertEqual(g.tableRow(forGroup: 2), 3)
    }

    func testEmptyRuns() {
        let g = GroupedRows(runs: [], collapsed: [])
        XCTAssertEqual(g.tableRowCount, 0)
        XCTAssertNil(g.tableRow(forModelRow: 0))
    }
}
```

```swift
// Tests/CoreTests/FolderModelGroupingTests.swift
import XCTest
import Synchronization
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class FolderModelGroupingTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    override func setUp() async throws {
        sandbox = try Sandbox(); addTeardownBlock { [sandbox] in sandbox?.destroy() }
        env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
    }

    func events(of model: FolderModel) -> (token: ObserverToken, log: () -> [String]) {
        var log: [String] = []
        let token = model.observe { e in
            switch e {
            case .groups(let r): log.append("groups:\(r.count)")
            case .changes(let c): log.append(c.changes == [.reset] ? "reset" : "changes")
            default: break
            }
        }
        return (token, { log })
    }

    func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testKindGroupingPublishesGroupsThenResetAndOrdersFolderFirst() async throws {
        try sandbox.mkdir("sub"); try sandbox.write("a.txt", bytes: 1); try sandbox.write("b.txt", bytes: 1); try sandbox.write("c.png", bytes: 1)
        let model = try await loadedModel(sandbox.root, env: env)
        let (token, log) = events(of: model); defer { token.cancel() }
        model.setGrouping(.kind)
        await waitUntil { !model.groups.isEmpty }
        XCTAssertEqual(log().prefix(2), ["groups:3", "reset"])
        XCTAssertEqual(model.groups.first?.key, .kind(TypeRegistry.shared.localizedDescription(TypeRegistry.folderIndex), isFolder: true))
        XCTAssertEqual(model.name(atRow: 0), "sub")
        let txtRun = model.groups.first { $0.rows.contains(model.row(named: "a.txt")!) }!
        XCTAssertTrue(txtRun.rows.contains(model.row(named: "b.txt")!))
        XCTAssertFalse(txtRun.rows.contains(model.row(named: "c.png")!))
        model.setGrouping(.none)
        await waitUntil { model.groups.isEmpty }
        XCTAssertEqual((0..<model.rowCount).map(model.name(atRow:)), ["sub", "a.txt", "b.txt", "c.png"])
    }

    func testWatcherInsertLandsInItsGroupAndKeepsSelection() async throws {
        try sandbox.write("a.txt", bytes: 1); try sandbox.write("z.png", bytes: 1); try sandbox.write("b.txt", bytes: 1)
        let model = try await loadedModel(sandbox.root, env: env)
        model.setGrouping(.kind)
        await waitUntil { !model.groups.isEmpty }
        model.select(.names(["b.txt"]))
        let (token, log) = events(of: model); defer { token.cancel() }
        try sandbox.write("a2.txt", bytes: 1)                     // sandbox write, picked up by the Watcher
        await waitUntil { model.row(named: "a2.txt") != nil }
        let txtRun = model.groups.first { $0.rows.contains(model.row(named: "a.txt")!) }!
        XCTAssertTrue(txtRun.rows.contains(model.row(named: "a2.txt")!))
        XCTAssertEqual(model.selection.ids, [model.identity(atRow: model.row(named: "b.txt")!)])
        XCTAssertFalse(log().contains("changes"), "grouped models publish resets, never incremental inserts")
    }

    func testDateGroupingUsesInjectedClockAndRegroupsForNewDay() async throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!; cal.firstWeekday = 1
        let clock = Mutex(ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!)
        try sandbox.write("today.txt", bytes: 1); try sandbox.write("yday.txt", bytes: 1)
        try sandbox.setModificationDate(ISO8601DateFormatter().date(from: "2026-11-18T10:00:00Z")!, on: "today.txt")
        try sandbox.setModificationDate(ISO8601DateFormatter().date(from: "2026-11-17T10:00:00Z")!, on: "yday.txt")
        var ctx = env.folderContext()
        ctx.now = { clock.withLock { $0 } }
        ctx.calendar = cal
        let model = FolderModel(directory: sandbox.root, context: ctx, query: ViewQuery())
        model.start()
        await waitUntil { model.state == .complete }
        model.setGrouping(.dateModified)
        await waitUntil { model.groups.count == 2 }
        XCTAssertEqual(model.groups.map(\.key), [.date(.today), .date(.yesterday)])
        clock.withLock { $0 = $0.addingTimeInterval(86_400) }
        model.regroupForNewDay()
        await waitUntil { model.groups.first?.key == .date(.yesterday) }
        XCTAssertEqual(model.groups.map(\.key), [.date(.yesterday), .date(.earlierThisWeek)])
        model.close()
    }
}
```

`Tests/CoreTests/Support/ModelLoading.swift` contains the same `loadedModel` function as `Tests/UITests/Support/ModelLoading.swift` (P2-06), because test targets cannot share sources.

- [ ] **Step 6: Run them to verify they fail**

Run: `swift test --filter "CoreTests.GroupedRowsTests|CoreTests.FolderModelGroupingTests" 2>&1 | tail -5`
Expected: `cannot find 'GroupedRows' in scope`.

- [ ] **Step 7: Implement `GroupedRows` and the model wiring**

```swift
// Sources/Core/Folder/GroupedRows.swift
import Foundation
import MacxFS

public enum TableRow: Sendable, Equatable { case header(Int), item(Int) }

public struct GroupedRows: Sendable, Equatable {
    public let runs: [GroupRun]
    public let collapsed: Set<GroupKey>
    public let tableRowCount: Int
    private let headerRows: [Int]

    public init(runs: [GroupRun], collapsed: Set<GroupKey>) {
        self.runs = runs; self.collapsed = collapsed
        var headers: [Int] = []; headers.reserveCapacity(runs.count)
        var t = 0
        for run in runs { headers.append(t); t += 1 + (collapsed.contains(run.key) ? 0 : run.rows.count) }
        headerRows = headers; tableRowCount = t
    }

    public func row(_ tableRow: Int) -> TableRow {
        precondition(tableRow >= 0 && tableRow < tableRowCount, "table row out of range")
        let g = lastHeader(atOrBefore: tableRow)
        let offset = tableRow - headerRows[g]
        return offset == 0 ? .header(g) : .item(runs[g].rows.lowerBound + offset - 1)
    }

    public func tableRow(forGroup group: Int) -> Int { headerRows[group] }

    public func group(containingModelRow m: Int) -> Int? {
        var lo = 0, hi = runs.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, r = runs[mid].rows
            if m < r.lowerBound { hi = mid - 1 } else if m >= r.upperBound { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    public func tableRow(forModelRow m: Int) -> Int? {
        guard let g = group(containingModelRow: m), !collapsed.contains(runs[g].key) else { return nil }
        return headerRows[g] + 1 + (m - runs[g].rows.lowerBound)
    }

    public func modelRows(forTableRows rows: IndexSet) -> IndexSet {
        var out = IndexSet()
        for t in rows where t >= 0 && t < tableRowCount { if case .item(let m) = row(t) { out.insert(m) } }
        return out
    }

    public func tableRows(forModelRows rows: IndexSet) -> IndexSet {
        var out = IndexSet()
        for m in rows { if let t = tableRow(forModelRow: m) { out.insert(t) } }
        return out
    }

    private func lastHeader(atOrBefore t: Int) -> Int {
        var lo = 0, hi = headerRows.count - 1, answer = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if headerRows[mid] <= t { answer = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return answer
    }
}
```

The model wiring:
1. `FolderContext` gains `now` and `calendar`, defaulted and appended to the init as in §2.2.
2. `FolderEvent` gains `.groups([GroupRun])`. Update every exhaustive switch: views ignore it until P2-10.
3. `FolderWorker` gains
   ```swift
   func partition(_ snapshot: EntryStore, sorted: [UInt32], by groupBy: GroupBy, buckets: DateBuckets, types: TypeRegistry) -> (order: [UInt32], runs: [GroupRun])
   ```
   which calls `Grouping.partition`.
4. `FolderModel+Grouping.swift` holds the private state `grouping`, `groups`, `groupingRevision` and `dayTask`, and the public API from §2.2.
5. Find the single place where `FolderModel` applies a worker-produced order to `store` and publishes it (`grep -n "setOrder(" Sources/Core/Folder/FolderModel*.swift`). Route it through `publishOrder(_ sorted: [UInt32], changes: ChangeSet)`:
   - `grouping == .none`: Phase 1 behaviour, unchanged.
   - Otherwise:
     - bump `groupingRevision`;
     - snapshot the store;
     - `await worker.partition(...)`;
     - drop the result if the revision moved or the generation is stale;
     - `store.setOrder(order)`, restore selection rows from ids (Phase 1 does this after `setOrder`), set `groups`;
     - emit `.groups(runs)`, then `.changes(.reset)`, except that a `ChangeSet` containing only `.reload`s is re-emitted unchanged after mapping (order did not change).
6. Watcher, LocalChange and refresh paths already end in that function.
7. `setGrouping(g)`: if `g == grouping` return; set it, cancel `dayTask`, re-publish from the current sorted order (the worker re-sorts with the current query when the store order is grouped), and, if `.dateModified`, schedule `dayTask = Task { try? await Task.sleep(for: .seconds(max(1, buckets.nextBoundary.timeIntervalSince(context.now()) + 1))); regroupForNewDay() }`.
8. `regroupForNewDay()` rebuilds `DateBuckets(now: context.now(), calendar: context.calendar)` and re-publishes, but only when `grouping == .dateModified`.
9. `close()` cancels `dayTask`.

`BrowserSession`: after building or replacing the model, on `apply(_:)`, and on displayed-mode changes, call `folder.setGrouping(displayedMode == .details ? viewState.groupBy : .none)`.

- [ ] **Step 8: Run all grouping tests and the full Core suite**

Run: `swift test --filter "FSKitTests.GroupingTests|CoreTests.GroupedRowsTests|CoreTests.FolderModelGroupingTests" 2>&1 | tail -5 && swift test --filter CoreTests 2>&1 | tail -3`
Expected: `Executed 13 tests, with 0 failures`, then `0 failures` for CoreTests. The Phase 1 FolderModel and Watcher tests are unchanged, because grouping is off by default.

- [ ] **Step 9: Commit**

```bash
git add Sources/FSKit/Sort/Grouping.swift Sources/Core/Folder Sources/UI/Window/BrowserSession.swift Tests/FSKitTests/GroupingTests.swift Tests/CoreTests
git commit -m "feat: group by kind, date, size and name with stable partition and grouped-row mapping"
```

---

### Task P2-10: Grouped Details view (floating, collapsible group rows)

**Files:**
- Create: `Sources/UI/Details/RowMapping.swift`, `Sources/UI/Details/GroupHeaderView.swift`, `Tests/UITests/GroupedDetailsTests.swift`, `Tests/Scenarios/p2-group-by.json`
- Modify: `Sources/UI/Details/DetailsViewController.swift`, `Sources/UI/Content/SelectionController.swift`, `Sources/UI/Content/TypeSelect.swift` (visible rows), `Sources/UI/Content/InlineRenameController.swift` (expand before rename), `Sources/UI/DragDrop/DragSource.swift` / `DropTarget.swift` (row mapping), `Sources/UI/Menus/ContextMenuBuilder.swift` (Group by ▸ in the empty-space menu, header menu), `Sources/UI/Commands/FileCommandController.swift` (groupBy commands), `Sources/UI/CommandBar/CommandBarView.swift` (View ▾ › Group by)

**Interfaces:**
- Consumes: `GroupedRows`, `TableRow`, `FolderEvent.groups`, `FolderModel.groups` (P2-09), `BrowserSession.updateViewState` (P2-08), `FileListView`, `SelectionController`.
- Produces: `RowMapping` (§2.3, plus `adjacentVisibleModelRow(from:by:) -> Int?`); `GroupTitles.title(for: GroupKey) -> String`; `DetailsViewController.toggleGroup(_ index: Int)`, `collapseAllGroups()`, `expandAllGroups()`; scenario hooks `groupHeaderTitles`, `visibleRowNames`, `clickTarget("group:…")`.

UI rules:
- `tableView(_:isGroupRow:)` is true for header rows, and `floatsGroupRows = true`. Header rows use the same fixed row height as items (density), so the fixed-height fast path of `NSTableView` is kept and no `heightOfRow` delegate is added.
- Header rows are not selectable. A click on a header (or its disclosure button) toggles collapse. ← collapses the group that contains the cursor row; → expands it. Collapse state is per window and folder, keyed by `GroupKey`, and resets on navigation. Keys that disappear after a regroup are dropped.
- ↑/↓/⇧-arrows, click, ⇧-click and type-select work in model rows over visible items only. They skip headers and collapsed groups through `adjacentVisibleModelRow`. ⌘A selects every item, including collapsed ones, because the selection lives in the model.
- Inline rename, `scrollToRow` and new-item rename expand the group that contains the row first. `topVisibleRow()` returns the first item row at or below the top table row.
- Every Phase 1 conversion between table rows and model rows goes through `mapping`. That covers `clickedRow`, `selectedRowIndexes` sync, drag-source rows, drop-on-row, the context-menu row, Tier 1 icon `visibleRows()`, middle-click (P2-06) and `reloadData(forRowIndexes:)`.
- Header context menu: "Collapse All Groups", "Expand All Groups", then the Phase 1 empty-space menu.
- Header accessibility: the disclosure button's label is "Collapse <title>" or "Expand <title>". The row's value is "<title>, <n> items, collapsed|expanded". The row's AXID is `groupHeader(title)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/GroupedDetailsTests.swift
import XCTest
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class GroupedDetailsTests: XCTestCase {
    let runs = [GroupRun(key: .size(.folders), rows: 0..<1), GroupRun(key: .size(.tiny), rows: 1..<3), GroupRun(key: .size(.large), rows: 3..<4)]

    func testRowMappingIdentityAndGrouped() {
        let id = RowMapping.identity(count: 3)
        XCTAssertEqual(id.tableRowCount, 3); XCTAssertEqual(id.modelRow(forTableRow: 2), 2)
        let g = RowMapping.grouped(GroupedRows(runs: runs, collapsed: []))
        XCTAssertEqual(g.tableRowCount, 7)
        XCTAssertNil(g.modelRow(forTableRow: 0))
        XCTAssertEqual(g.modelRow(forTableRow: 3), 1)
        XCTAssertEqual(g.tableRow(forModelRow: 3), 6)
    }

    func testAdjacentVisibleModelRowSkipsHeadersAndCollapsedGroups() {
        let g = RowMapping.grouped(GroupedRows(runs: runs, collapsed: [.size(.tiny)]))
        XCTAssertEqual(g.adjacentVisibleModelRow(from: 0, by: 1), 3, "skips the collapsed Tiny group")
        XCTAssertEqual(g.adjacentVisibleModelRow(from: 3, by: -1), 0)
        XCTAssertNil(g.adjacentVisibleModelRow(from: 3, by: 1))
        XCTAssertEqual(g.adjacentVisibleModelRow(from: 1, by: 1), 3, "a cursor inside a collapsed group moves from its header")
    }

    func testGroupTitles() {
        XCTAssertEqual(GroupTitles.title(for: .date(.today)), "Today")
        XCTAssertEqual(GroupTitles.title(for: .date(.longAgo)), "A long time ago")
        XCTAssertEqual(GroupTitles.title(for: .size(.tiny)), "Tiny (0 – 16 KB)")
        XCTAssertEqual(GroupTitles.title(for: .letter(.digits)), "0–9")
        XCTAssertEqual(GroupTitles.title(for: .letter(.other)), "Other")
        XCTAssertEqual(GroupTitles.title(for: .letter(.letter("Ω"))), "Ω")
        XCTAssertEqual(GroupTitles.title(for: .kind("PNG image", isFolder: false)), "PNG image")
    }

    func testDetailsControllerHeadersSelectionAndCollapse() async throws {
        try requireGUISession()
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.mkdir("sub"); try sandbox.write("a.txt", bytes: 10); try sandbox.write("b.txt", bytes: 20)
        try sandbox.write("big.bin", bytes: 200_000_000)   // sparse is fine; Large bucket by logical size
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        let stateBox = try Sandbox(); defer { stateBox.destroy() }   // state outside the listed folder
        let options = try LaunchOptions.parse(["macExplorer", "--root", sandbox.root.path(percentEncoded: false), "--state-dir", stateBox.root.path(percentEncoded: false)])
        let details = DetailsViewController(context: UIContext(environment: env, options: options))
        _ = details.view
        let model = try await loadedModel(sandbox.root, env: env)
        details.bind(model)
        model.setGrouping(.size)
        let end = Date().addingTimeInterval(3)
        while details.tableView.numberOfRows != 7 && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(details.tableView.numberOfRows, 7)     // 3 headers + 4 items
        XCTAssertTrue(details.tableView(details.tableView, isGroupRow: 0))
        XCTAssertFalse(details.tableView(details.tableView, shouldSelectRow: 0))
        details.clickTableRow(3, modifiers: [])              // second item of the Tiny group = model row 2
        XCTAssertEqual(model.selectedURLs.map(\.lastPathComponent), ["b.txt"])
        details.toggleGroup(1)                               // collapse Tiny
        XCTAssertEqual(details.tableView.numberOfRows, 5)
        XCTAssertEqual(model.selectedURLs.map(\.lastPathComponent), ["b.txt"], "selection survives collapse")
    }
}
```
`clickTableRow(_:modifiers:)` is the internal entry point that the Phase 1 mouse handling calls (`SelectionController`). If P1-33 named it differently, expose it under this name for tests. `tableView` is the controller's `NSTableView` property.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter UITests.GroupedDetailsTests 2>&1 | tail -5`
Expected: `cannot find 'RowMapping' in scope`.

- [ ] **Step 3: Implement `RowMapping` and `GroupTitles`**

```swift
// Sources/UI/Details/RowMapping.swift
import Foundation
import Core

enum RowMapping: Equatable {
    case identity(count: Int)
    case grouped(GroupedRows)

    var tableRowCount: Int {
        switch self { case .identity(let n): n; case .grouped(let g): g.tableRowCount }
    }
    func modelRow(forTableRow row: Int) -> Int? {
        switch self {
        case .identity(let n): return row >= 0 && row < n ? row : nil
        case .grouped(let g):
            guard row >= 0, row < g.tableRowCount, case .item(let m) = g.row(row) else { return nil }
            return m
        }
    }
    func tableRow(forModelRow row: Int) -> Int? {
        switch self { case .identity(let n): row >= 0 && row < n ? row : nil; case .grouped(let g): g.tableRow(forModelRow: row) }
    }
    func modelRows(forTableRows rows: IndexSet) -> IndexSet {
        switch self { case .identity: rows; case .grouped(let g): g.modelRows(forTableRows: rows) }
    }
    func tableRows(forModelRows rows: IndexSet) -> IndexSet {
        switch self { case .identity: rows; case .grouped(let g): g.tableRows(forModelRows: rows) }
    }
    /// Next visible item `delta` steps away (±1), skipping headers and collapsed groups; nil at either end.
    func adjacentVisibleModelRow(from modelRow: Int, by delta: Int) -> Int? {
        switch self {
        case .identity(let n):
            let next = modelRow + delta
            return next >= 0 && next < n ? next : nil
        case .grouped(let g):
            let start: Int
            if let t = g.tableRow(forModelRow: modelRow) { start = t }
            else if let group = g.group(containingModelRow: modelRow) { start = g.tableRow(forGroup: group) }
            else { return nil }
            var t = start + delta
            while t >= 0 && t < g.tableRowCount {
                if case .item(let m) = g.row(t) { return m }
                t += delta
            }
            return nil
        }
    }
}
```

`GroupTitles.title(for:)` lives in `GroupHeaderView.swift`. It maps each `DateBucket`, each `SizeBucket` and the `LetterKey` cases to `L10n` strings: "In the future", "Today", "Yesterday", "Earlier this week", "Last week", "Earlier this month", "Last month", "Earlier this year", "A long time ago"; "Folders", "Empty (0 KB)", "Tiny (0 – 16 KB)", "Small (16 KB – 1 MB)", "Medium (1 – 128 MB)", "Large (128 MB – 1 GB)", "Huge (1 – 4 GB)", "Gigantic (> 4 GB)"; "0–9", the letter itself, "Other". `.kind(d, _)` returns `d` as is.

`GroupHeaderView` is an `NSTableCellView` containing:
- a disclosure `NSButton` (`bezelStyle .disclosure`, `state` reflecting expanded, action → controller `toggleGroup`);
- a bold title label;
- a secondary count label `L10n` "%d items".

- [ ] **Step 4: Wire `DetailsViewController`**

1. Add `private(set) var mapping: RowMapping = .identity(count: 0)` and `private var collapsed: Set<GroupKey> = []`.
2. `bind(_:)` resets `collapsed` and sets `mapping` from `folder.groups`: `.identity(count: rowCount)` when empty, `.grouped(GroupedRows(runs:collapsed:))` otherwise.
3. On `.groups(runs)`: rebuild the mapping (dropping collapsed keys no longer present). The `.changes(.reset)` that follows does `reloadData`.
4. In ungrouped mode, `apply(_:)` keeps Phase 1 behaviour, updating `mapping = .identity(count:)` after the change set. In grouped mode it maps a reload-only change set through `tableRows(forModelRows:)`.
5. Data source:
   - `numberOfRows` = `mapping.tableRowCount`;
   - `viewFor:row:` dispatches on `mapping.modelRow(forTableRow:)`: nil → a `GroupHeaderView` (from `makeView(withIdentifier: "macx.groupHeader")`, configured with title and count); otherwise the Phase 1 cell for that model row;
   - `isGroupRow` and `shouldSelectRow` as in the UI rules.
6. `toggleGroup(i)` flips `collapsed` for `runs[i].key`, rebuilds the mapping, `reloadData`s and re-syncs the table selection from the model.
7. `SelectionController` takes a `RowMapping` (default `.identity`) and uses `adjacentVisibleModelRow` for arrows. Clicks arrive as table rows and are mapped, and clicks on headers toggle the group.
8. Type-select searches visible rows only: model rows for which `mapping.tableRow(forModelRow:) != nil`.
9. Commands `groupByNone/Kind/DateModified/Size/Name` call `session.updateViewState { $0.groupBy = … }`. Menu items show a checkmark for `session.viewState.groupBy`, through `validateMenuItem` setting `state`.
10. Scenario hooks:
    - `groupHeaderTitles` → `runs.map { "\(title) (\($0.rows.count))" }`;
    - `visibleRowNames` → the names of table item rows in order;
    - `clickTarget("group:<title>")` → `toggleGroup` of the run whose title matches.

- [ ] **Step 5: Add the scenario**

```json
// Tests/Scenarios/p2-group-by.json
{"name": "p2-group-by",
 "fixture": {"files": ["a.txt", "b.txt", "c.txt"], "dirs": ["sub"],
             "mtimeDays": {"sub": 0, "a.txt": 0, "b.txt": -1, "c.txt": -400}},
 "steps": [
  {"menu": ["View", "Group By", "Date Modified"]},
  {"waitFor": {"groupBy": "dateModified", "groups": ["Today (2)", "Yesterday (1)", "A long time ago (1)"],
               "visibleRows": ["sub", "a.txt", "b.txt", "c.txt"]}},
  {"click": "group:Today"},
  {"waitFor": {"visibleRows": ["b.txt", "c.txt"], "groups": ["Today (2)", "Yesterday (1)", "A long time ago (1)"]}},
  {"click": "b.txt"},
  {"key": "down"},
  {"expect": {"selection": ["c.txt"]}},
  {"key": "up"},
  {"key": "up"},
  {"expect": {"selection": ["b.txt"]}},
  {"menu": ["View", "Group By", "Size"]},
  {"waitFor": {"groups": ["Folders (1)", "Tiny (0 – 16 KB) (3)"]}},
  {"key": "cmd+2"},
  {"waitFor": {"viewMode": "icons", "rows": ["sub", "a.txt", "b.txt", "c.txt"], "groupBy": "size"}},
  {"key": "cmd+1"},
  {"waitFor": {"groups": ["Folders (1)", "Tiny (0 – 16 KB) (3)"]}}
 ]}
```
(Scenario fixture files contain "x", which is 1 byte, so all three files fall in Tiny. `probeGrouping` reports `session.viewState.groupBy`, the folder's saved choice, so it stays `size` in Icons view while the Icons list is ungrouped.)

- [ ] **Step 6: Run the tests, the scenario and the Phase 1 Details scenarios**

Run: `swift test --filter UITests.GroupedDetailsTests 2>&1 | tail -5 && scripts/ui-scenarios.sh 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`; all scenarios pass, including `p2-group-by`.

- [ ] **Step 7: Commit**

```bash
git add Sources/UI Tests/UITests/GroupedDetailsTests.swift Tests/Scenarios/p2-group-by.json
git commit -m "feat: grouped Details view with floating collapsible group rows"
```

---

### Task P2-11: Quick Look on Space

**Files:**
- Create: `Sources/UI/QuickLook/QuickLookController.swift`, `Tests/UITests/QuickLookControllerTests.swift`, `Tests/Scenarios/p2-quicklook.json`, `Tests/Scenarios/p2-quicklook-typeselect.json`
- Modify: `Sources/UI/Window/BrowserWindowController.swift` (panel control, bridge, tab switch), `Sources/UI/Menus/KeyRouter.swift` (`command(for:focus:returnKey:typeSelectActive:)`), `Sources/UI/Content/TypeSelect.swift` (`isCollecting`, accepts spaces while collecting), `Sources/UI/Content/ContentViewController.swift` (passes `typeSelectActive`), `Sources/UI/Commands/FileCommandController.swift` (`quickLook`), `Sources/UI/Menus/ContextMenuBuilder.swift` ("Quick Look" item after "Open With ▸")

**Interfaces:**
- Consumes: `FolderModel.selectedURLs/observe`, `KeyDispatcher`, `KeyEventTranslator.chord(for:)`, `CommandState.quickLookVisible` (P2-02), `TypeSelect`.
- Produces: `QuickLookPanelControlling`, `QuickLookController` (§2.3), `SystemQuickLookPanel`, `QuickLookPanelBridge`, `KeyRouter.command(for:focus:returnKey:typeSelectActive:) -> Command?` (pure; `handle` calls it), `TypeSelect.isCollecting`, and the scenario hook `quickLookState`.

Behaviour (spec §11):
- Space in the content view toggles the shared `QLPreviewPanel` over the selected items, in display order. With nothing selected, Space does nothing unless the panel is open, in which case it closes the panel.
- With ≤ 1 item selected, arrow keys pressed while the panel is key are forwarded to the active list, so the selection moves and the panel follows. With several items selected, the panel's native ←/→ steps through them.
- Selection changes, navigation and tab switches reload the panel while it is visible. The window controller is the panel's controller (`acceptsPreviewPanelControl` → true). On `windowDidBecomeKey` it calls `QLPreviewPanel.shared().updateController()` when the panel exists and is visible.
- Space while type-select is collecting goes to type-select (Review Focus 1).
- Our process makes no file-system calls for Quick Look. The panel receives URLs from the model. The out-of-process previewer reads the file, which is a user-initiated open, like double-click.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/QuickLookControllerTests.swift
import XCTest
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class FakePanel: QuickLookPanelControlling {
    var isVisible = false
    var reloads = 0
    func show() { isVisible = true }
    func hide() { isVisible = false }
    func reloadData() { reloads += 1 }
}

@MainActor
final class QuickLookControllerTests: XCTestCase {
    var sandbox: Sandbox!
    var model: FolderModel!
    let panel = FakePanel()
    var controller: QuickLookController!

    override func setUp() async throws {
        sandbox = try Sandbox(); addTeardownBlock { [sandbox] in sandbox?.destroy() }
        for n in ["a.txt", "b.txt", "c.txt"] { try sandbox.write(n, bytes: 1) }
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        model = try await loadedModel(sandbox.root, env: env)
        controller = QuickLookController(panel: { [panel] in panel })
        controller.bind(model)
    }

    func testToggleShowsSelectionAndHides() {
        model.select(.names(["b.txt"]))
        controller.toggle()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(controller.items.map(\.lastPathComponent), ["b.txt"])
        controller.toggle()
        XCTAssertFalse(panel.isVisible)
    }

    func testNoSelectionDoesNotOpen() {
        model.select(.none)
        controller.toggle()
        XCTAssertFalse(panel.isVisible)
    }

    func testSelectionChangeReloadsVisiblePanelOnly() {
        model.select(.names(["a.txt"]))
        model.select(.names(["b.txt"]))
        XCTAssertEqual(panel.reloads, 0, "hidden panel is not reloaded")
        controller.toggle()
        model.select(.names(["c.txt"]))
        XCTAssertEqual(panel.reloads, 1)
        XCTAssertEqual(controller.items.map(\.lastPathComponent), ["c.txt"])
    }

    func testArrowsForwardOnlyWithAtMostOneItem() {
        model.select(.names(["a.txt"]))
        controller.toggle()
        var forwarded: [KeyChord] = []
        XCTAssertTrue(controller.handlePanelKey(KeyChord(.down)) { forwarded.append($0) })
        XCTAssertEqual(forwarded, [KeyChord(.down)])
        model.select(.names(["a.txt", "b.txt"]))
        XCTAssertFalse(controller.handlePanelKey(KeyChord(.right)) { forwarded.append($0) }, "panel steps through several items itself")
        XCTAssertFalse(controller.handlePanelKey(KeyChord(.character("x"))) { forwarded.append($0) })
        XCTAssertTrue(controller.handlePanelKey(KeyChord(.space)) { _ in })
        XCTAssertFalse(panel.isVisible, "Space in the panel closes it")
    }

    // Review Focus 1
    func testSpaceDuringTypeSelectGoesToTypeSelect() {
        var now = ContinuousClock.now
        let typeSelect = TypeSelect(timeout: .seconds(1), now: { now })
        _ = typeSelect.keyTyped("m"); _ = typeSelect.keyTyped("y")
        XCTAssertTrue(typeSelect.isCollecting)
        XCTAssertNil(KeyRouter.command(for: KeyChord(.space), focus: .content, returnKey: .open, typeSelectActive: typeSelect.isCollecting))
        XCTAssertEqual(typeSelect.keyTyped(" "), "my ")
        XCTAssertEqual(typeSelect.keyTyped("f"), "my f")
        now = now.advanced(by: .milliseconds(1500))
        XCTAssertFalse(typeSelect.isCollecting)
        XCTAssertEqual(KeyRouter.command(for: KeyChord(.space), focus: .content, returnKey: .open, typeSelectActive: typeSelect.isCollecting), .quickLook)
    }
}
```
If P1-33's `TypeSelect` already has an injectable clock or a different name for "add typed characters and return the buffer", keep P1-33's names and adapt this test to them. The asserted behaviour stays the same.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter UITests.QuickLookControllerTests 2>&1 | tail -5`
Expected: `cannot find type 'QuickLookPanelControlling' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/UI/QuickLook/QuickLookController.swift
import AppKit
import Quartz
import Core
import MacxFS

@MainActor protocol QuickLookPanelControlling: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
    func reloadData()
}

@MainActor
final class SystemQuickLookPanel: QuickLookPanelControlling {
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
    func show() { QLPreviewPanel.shared().makeKeyAndOrderFront(nil) }
    func hide() { if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) } }
    func reloadData() { if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().reloadData() } }
}

@MainActor
final class QuickLookController {
    private let panel: @MainActor () -> any QuickLookPanelControlling
    private weak var folder: FolderModel?
    private var token: ObserverToken?
    private(set) var items: [URL] = []

    init(panel: @escaping @MainActor () -> any QuickLookPanelControlling) { self.panel = panel }

    var isVisible: Bool { panel().isVisible }

    func bind(_ folder: FolderModel?) {
        token?.cancel()
        self.folder = folder
        token = folder?.observe { [weak self] event in
            switch event {
            case .selection, .changes: self?.refresh()
            default: break
            }
        }
        refresh()
    }

    private func refresh() {
        let next = folder?.selectedURLs ?? []
        guard next != items else { return }
        items = next
        if panel().isVisible { panel().reloadData() }
    }

    func toggle() {
        let p = panel()
        if p.isVisible { p.hide(); return }
        items = folder?.selectedURLs ?? []
        guard !items.isEmpty else { return }
        p.show()
    }

    func handlePanelKey(_ chord: KeyChord, forward: (KeyChord) -> Void) -> Bool {
        switch chord.key {
        case .space where chord.modifiers.isEmpty:
            panel().hide(); return true
        case .up, .down, .left, .right where chord.modifiers.isEmpty || chord.modifiers == [.shift]:
            guard items.count <= 1 else { return false }
            forward(chord); return true
        default:
            return false
        }
    }
}

/// QLPreviewPanel data source + delegate. Owned by the window controller.
@MainActor
final class QuickLookPanelBridge: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let controller: QuickLookController
    var forwardKeyEvent: ((NSEvent) -> Void)?
    var sourceFrame: ((URL) -> NSRect?)?
    init(controller: QuickLookController) { self.controller = controller }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { controller.items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let items = controller.items
        return (items.indices.contains(index) ? items[index] : items.first) as NSURL?
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let chord = KeyEventTranslator.chord(for: event) else { return false }
        return controller.handlePanelKey(chord) { [weak self] _ in self?.forwardKeyEvent?(event) }
    }
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = (item as? NSURL) as URL? else { return .zero }
        return sourceFrame?(url) ?? .zero
    }
}
```
If the `case .up, .down, .left, .right where …` pattern with a shared guard does not compile (a `where` clause applies only to the last pattern), split it into a nested `if`. Keep the behaviour unchanged.

In `BrowserWindowController`:
- create `quickLook = QuickLookController(panel: { SystemQuickLookPanel() })` and `qlBridge`;
- call `quickLook.bind(session.folder)` on every `.folderChanged`;
- set `qlBridge.forwardKeyEvent = { [weak self] e in self?.contentList.view.window?.makeFirstResponder(...)? }`, which forwards to the active list's key handler. Call the active `FileListView`'s table/collection `keyDown(with:)` directly; do not change first responder;
- set `qlBridge.sourceFrame`: the row's icon rect converted to screen coordinates, or nil when the row is off-screen;
- add:
```swift
override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = qlBridge; panel.delegate = qlBridge }
override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
```
- in `windowDidBecomeKey`: `if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().updateController() }`.

`FileCommandController.perform(.quickLook)` calls `window.quickLook.toggle()`. `CommandState.quickLookVisible = window.quickLook.isVisible`.

`KeyRouter`:
```swift
static func command(for chord: KeyChord, focus: FocusContext, returnKey: ReturnKeyBehavior, typeSelectActive: Bool) -> Command? {
    if typeSelectActive, chord.key == .space, chord.modifiers.isEmpty { return nil }   // Review Focus 1
    return KeyDispatcher(returnKey: returnKey).command(for: chord, in: focus)
}
```
`handle(_:focus:returnKey:from:typeSelectActive:)` (new defaulted parameter) uses `command(for:…)`. `ContentViewController` passes `typeSelect.isCollecting`. `TypeSelect` gains `isCollecting` (buffer non-empty and the last keystroke within the timeout) and appends spaces only while collecting. A leading space never starts a buffer.

Scenario hook `quickLookState`: `(quickLook.isVisible, quickLook.items.map(\.lastPathComponent))`.

- [ ] **Step 4: Add the scenarios**

```json
// Tests/Scenarios/p2-quicklook.json
{"name": "p2-quicklook",
 "fixture": {"files": ["a.txt", "b.txt", "c.txt"], "dirs": []},
 "steps": [
  {"click": "a.txt"},
  {"key": "space"},
  {"waitFor": {"quickLookVisible": true, "quickLookItems": ["a.txt"]}},
  {"key": "down"},
  {"waitFor": {"selection": ["b.txt"], "quickLookItems": ["b.txt"]}},
  {"key": "space"},
  {"waitFor": {"quickLookVisible": false}},
  {"click": "c.txt", "modifiers": ["shift"]},
  {"key": "space"},
  {"waitFor": {"quickLookVisible": true, "quickLookItems": ["b.txt", "c.txt"]}},
  {"key": "esc"},
  {"waitFor": {"quickLookVisible": false}}
 ]}
```

```json
// Tests/Scenarios/p2-quicklook-typeselect.json
{"name": "p2-quicklook-typeselect",
 "fixture": {"files": ["my file.txt", "my-other.txt", "myz.txt"], "dirs": []},
 "steps": [
  {"click": "myz.txt"},
  {"type": "my f"},
  {"expect": {"selection": ["my file.txt"], "quickLookVisible": false}},
  {"sleepMs": 1500},
  {"key": "space"},
  {"waitFor": {"quickLookVisible": true, "quickLookItems": ["my file.txt"]}},
  {"key": "space"},
  {"waitFor": {"quickLookVisible": false}}
 ]}
```
(If the QL panel does not close on Esc in this SDK, extend `handlePanelKey` so that `.escape` hides the panel, as Finder does, and keep the step.)

- [ ] **Step 5: Run the tests and scenarios**

Run: `swift test --filter UITests.QuickLookControllerTests 2>&1 | tail -5 && scripts/ui-scenarios.sh 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`; all scenarios pass, including both Quick Look ones and Phase 1's colliding-keys scenario.

- [ ] **Step 6: Commit**

```bash
git add Sources/UI Tests/UITests/QuickLookControllerTests.swift Tests/Scenarios/p2-quicklook*.json
git commit -m "feat: Quick Look on Space with arrow navigation and type-select priority"
```

---

### Task P2-12: Folder-size scanner and scan lanes

**Files:**
- Create: `Sources/Core/Sizes/FolderSize.swift`, `Sources/Core/Sizes/FolderSizeScanner.swift`, `Tests/CoreTests/FolderSizeScannerTests.swift`
- Modify: `Sources/FSKit/Lanes/IOLane.swift` (`LaneClass.scan`), `Sources/FSKit/Lanes/LanePool.swift` (pool per class already keyed by `LaneClass`; verify), `Tests/FSKitTests/LaneTests.swift` (scan-class test)

**Interfaces:**
- Consumes: `BulkReader.read`, `ReadOptions`, `Batch`, `EntryFlags` (`.dataless`, `.degraded`, `.hasHardLinks`), `MountTable`, `LaneContext`, `withNoMaterialization`, `assertOffMain`.
- Produces: §2.1 `LaneClass.scan`; §2.2 `FolderSize`, `FolderSizeIdentity`, `FolderSizeKey`, and `FolderSizeScanner.scan(_:context:mountTable:types:onDirectory:)`, where `onDirectory` is called with the number of directories visited so far (tests). Also `FolderSizeScanner.accumulate(_ batch: Batch, in directory: URL, state: inout ScanState)`, internal and testable with synthetic batches.

Rules (spec §11 and §4.2):
- The scanner runs on a `.scan` lane inside `withNoMaterialization`, with an iterative directory stack and one `BulkReader.read` per directory.
- It counts the logical `size` and `allocSize` of every non-directory entry: files, symlinks and aliases (the link itself, never its target). It descends into `.directory` and `.package` entries, so package contents count.
- Hard links (`.hasHardLinks`) are counted once per `fileID` within one scan.
- A directory entry whose path is a mount point of another volume in `mountTable` is not descended into, and the result is not marked partial (Finder parity: other volumes are not part of a folder's size).
- Dataless directories are not read and mark the result `isPartial`. So do degraded entries and `ReadFailure`s for subdirectories (EACCES, ENOENT races).
- The scanner calls `context.heartbeat()` once per directory and checks `context.isCancelled` between directories and batches. A cancelled scan returns nil.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/FolderSizeScannerTests.swift
import XCTest
@testable import Core
import MacxFS
import MacxFixtures

final class FolderSizeScannerTests: XCTestCase {
    var sandbox: Sandbox!
    let lanes = LanePool()
    override func setUpWithError() throws {
        sandbox = try Sandbox()
        addTeardownBlock { [sandbox] in
            if let s = sandbox { _ = chmod(s.url("tree/d/locked").path(percentEncoded: false), 0o755); s.destroy() }
        }
    }

    func scan(_ rel: String, table: MountTable = .empty, onDirectory: (@Sendable (Int) -> Void)? = nil) async throws -> FolderSize? {
        let url = sandbox.url(rel)
        return try await lanes.perform(on: .unknown, .scan) { ctx in
            FolderSizeScanner.scan(url, context: ctx, mountTable: table, onDirectory: onDirectory)
        }
    }

    func testCountsFilesFoldersAndPackageContents() async throws {
        try sandbox.write("tree/a", bytes: 10)
        try sandbox.write("tree/d/b", bytes: 20)
        try sandbox.write("tree/d/e/c", bytes: 30)
        try sandbox.mkdir("tree/d/e/f")
        try sandbox.write("tree/X.app/Contents/MacOS/bin", bytes: 100)
        let size = try await scan("tree")
        XCTAssertEqual(size, FolderSize(bytes: 160, allocatedBytes: size!.allocatedBytes, files: 4, folders: 6, isPartial: false))
        XCTAssertGreaterThanOrEqual(size!.allocatedBytes, 0)
    }

    // Review Focus 3 (dataless part: testDatalessDirectoryIsNotDescendedAndMarksPartial; mount part: testMountPointIsNotCrossed)
    func testScannerHardLinksSymlinkLoopUnreadableDatalessAndMountPoint() async throws {
        try sandbox.write("tree/d/h1", bytes: 1_000)
        try sandbox.hardLink("tree/d/h2", to: "tree/d/h1")
        try sandbox.symlink("tree/d/loop", to: "..")                 // loop back to tree/
        try sandbox.write("outside/big", bytes: 100_000)
        try sandbox.symlink("tree/d/out", to: "../../outside")       // must not be followed
        try sandbox.write("tree/d/locked/secret", bytes: 500)
        XCTAssertEqual(chmod(sandbox.url("tree/d/locked").path(percentEncoded: false), 0o000), 0)
        let size = try await scan("tree")!
        XCTAssertEqual(size.bytes, 1_000 + linkBytes(["tree/d/loop", "tree/d/out"]),
                       "hard link counted once; links counted as links, never followed; locked contents excluded")
        XCTAssertEqual(size.files, 3, "h1 (once) + two symlinks")
        XCTAssertTrue(size.isPartial, "the unreadable folder makes the size partial")
    }

    func testMountPointIsNotCrossed() async throws {
        guard let image = try? DiskImage.create(in: sandbox, sizeMB: 8, format: .apfs) else {   // P1-02 API
            throw XCTSkip("hdiutil unavailable")
        }
        addTeardownBlock { try? image.detach() }
        try Data(count: 1_000_000).write(to: image.mountPoint.appending(path: "inside"))   // inside the test's own image
        try sandbox.write("plain", bytes: 10)
        let table = MountTable([
            VolumeInfoFixtures.volume(id: "uuid:ROOT", mountPoint: URL(filePath: "/", directoryHint: .isDirectory)),
            VolumeInfoFixtures.volume(id: "uuid:IMG", mountPoint: image.mountPoint),
        ])
        let url = sandbox.root
        let size = try await lanes.perform(on: .unknown, .scan) { ctx in
            FolderSizeScanner.scan(url, context: ctx, mountTable: table)
        }!
        XCTAssertLessThan(size.bytes, 1_000_000, "the image mounted inside the sandbox is another volume")
        XCTAssertGreaterThanOrEqual(size.bytes, 10)
    }

    func linkBytes(_ paths: [String]) -> Int64 {
        paths.reduce(0) { total, rel in
            var st = stat(); _ = lstat(sandbox.url(rel).path(percentEncoded: false), &st); return total + Int64(st.st_size)
        }
    }

    func testDatalessDirectoryIsNotDescendedAndMarksPartial() {
        var batch = Batch(generation: .initial)
        let dir = Entry(rowID: 1, fileID: 1, size: 3, allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                        kind: .directory, flags: [.dataless], typeIndex: TypeRegistry.folderIndex)
        let file = Entry(rowID: 2, fileID: 2, size: 42, allocSize: 4096, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                         kind: .file, flags: [.dataless], typeIndex: TypeRegistry.dataIndex)
        Array("cloud".utf8).withUnsafeBufferPointer { batch.append(dir, nameBytes: $0) }
        Array("f".utf8).withUnsafeBufferPointer { batch.append(file, nameBytes: $0) }
        var state = FolderSizeScanner.ScanState(mountPoints: [])
        FolderSizeScanner.accumulate(batch, in: URL(filePath: "/x", directoryHint: .isDirectory), state: &state)
        XCTAssertTrue(state.pending.isEmpty, "dataless folder never read")
        XCTAssertTrue(state.result.isPartial)
        XCTAssertEqual(state.result.bytes, 42, "a dataless file's logical size is metadata and counts")
        XCTAssertEqual(state.result.folders, 1)
    }

    func testCancellationStopsWithinADirectory() async throws {
        for i in 0..<400 { try sandbox.write("many/d\(i)/f", bytes: 1) }
        let url = sandbox.url("many")
        let visited = Mutex(0)
        let task = Task {
            try await lanes.perform(on: .unknown, .scan) { ctx in
                FolderSizeScanner.scan(url, context: ctx, mountTable: .empty, onDirectory: { n in
                    visited.withLock { $0 = n }
                    usleep(2_000)                       // 400 dirs ≈ 0.8 s, so the cancel lands mid-scan
                })
            }
        }
        while visited.withLock({ $0 }) < 10 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        let result = try? await task.value
        XCTAssertNil(result ?? nil, "a cancelled scan returns nil")
        XCTAssertLessThan(visited.withLock { $0 }, 400)
    }

    func testScanLanesAreSeparateFromReadLanes() async throws {
        _ = try await scan("tree0-empty-ok") ?? nil
        let v = VolumeID.unknown
        let reads = await lanes.liveLaneCount(of: v, .read)
        let scans = await lanes.liveLaneCount(of: v, .scan)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(scans, 1)
    }
}
```

Test notes:
- Add `import Synchronization` (for `Mutex`) to the file.
- `VolumeInfoFixtures.volume(id:mountPoint:)` builds a `VolumeInfo` with `idStable` true and every other flag false. Put it in `Tests/CoreTests/Support/VolumeInfoFixtures.swift`; P2-07's test may switch to it.
- `testScanLanesAreSeparateFromReadLanes` first runs `try sandbox.mkdir("tree0-empty-ok")`.
- If P1-02's `DiskImage` API differs (`create(in:sizeMB:format:)`, `mountPoint`, `detach()`), use P1-02's names. The image and its mount point live inside the test's sandbox, and the test writes only inside them.
- Creating a real dataless (iCloud placeholder) folder needs a File Provider, so the dataless rule is pinned with a synthetic `Batch` through `accumulate`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter CoreTests.FolderSizeScannerTests 2>&1 | tail -5`
Expected: `cannot find 'FolderSizeScanner' in scope` / `type 'LaneClass' has no member 'scan'`.

- [ ] **Step 3: Implement**

Add `case scan` to `LaneClass`. `LanePool` keys pools by `(VolumeID, LaneClass)`, so the new class gets its own `lanesPerClass` (2) lanes per volume and shares the per-volume poison cap. If Phase 1 has an exhaustive switch over `LaneClass`, give `.scan` the same watchdog policy as `.read`.

```swift
// Sources/Core/Sizes/FolderSize.swift
import Foundation
import MacxFS

public struct FolderSize: Sendable, Equatable, Codable {
    public var bytes: Int64
    public var allocatedBytes: Int64
    public var files: Int
    public var folders: Int
    public var isPartial: Bool
    public init(bytes: Int64 = 0, allocatedBytes: Int64 = 0, files: Int = 0, folders: Int = 0, isPartial: Bool = false) {
        self.bytes = bytes; self.allocatedBytes = allocatedBytes; self.files = files; self.folders = folders; self.isPartial = isPartial
    }
}
public enum FolderSizeIdentity: Hashable, Sendable { case object(VolumeID, UInt64), path(String) }
public struct FolderSizeKey: Hashable, Sendable {
    public var identity: FolderSizeIdentity
    public var mtime: Int64
    public init(identity: FolderSizeIdentity, mtime: Int64) { self.identity = identity; self.mtime = mtime }
}
```

```swift
// Sources/Core/Sizes/FolderSizeScanner.swift
import Foundation
import MacxFS

public enum FolderSizeScanner {
    struct ScanState {
        var result = FolderSize()
        var pending: [URL] = []
        var seenHardLinks = Set<UInt64>()
        let mountPoints: Set<String>          // other volumes' mount points (standardized, no trailing slash)
        init(mountPoints: Set<String>) { self.mountPoints = mountPoints }
    }

    public static func scan(_ root: URL, context: LaneContext, mountTable: MountTable,
                            types: TypeRegistry = .shared, onDirectory: ((Int) -> Void)? = nil) -> FolderSize? {
        assertOffMain()
        return withNoMaterialization { () -> FolderSize? in
            let rootPath = path(of: root)
            let rootVolume = mountTable.volume(containing: rootPath)?.id
            let others = Set(mountTable.volumes.filter { $0.id != rootVolume }.map { path(of: $0.mountPoint) })
            var state = ScanState(mountPoints: others)
            state.pending = [root]
            var visited = 0
            var options = ReadOptions()
            options.noMaterialization = true
            options.batchSize = 4_096
            while let directory = state.pending.popLast() {
                if context.isCancelled { return nil }
                context.heartbeat()
                do {
                    _ = try BulkReader.read(directory, generation: .initial, options: options, types: types, context: context) { batch in
                        accumulate(batch, in: directory, state: &state)
                        return !context.isCancelled
                    }
                } catch {
                    state.result.isPartial = true   // unreadable or vanished subfolder
                }
                visited += 1
                onDirectory?(visited)
            }
            return context.isCancelled ? nil : state.result
        }
    }

    static func accumulate(_ batch: Batch, in directory: URL, state: inout ScanState) {
        for i in 0..<batch.count {
            let e = batch.entries[i]
            if e.flags.contains(.degraded) { state.result.isPartial = true }
            switch e.kind {
            case .directory, .package:
                state.result.folders += 1
                if e.flags.contains(.dataless) { state.result.isPartial = true; continue }
                let child = directory.appending(path: batch.name(at: i), directoryHint: .isDirectory)
                if state.mountPoints.contains(path(of: child)) { continue }
                state.pending.append(child)
            case .file, .symlink, .alias, .other:
                if e.flags.contains(.hasHardLinks), !state.seenHardLinks.insert(e.fileID).inserted { continue }
                state.result.files += 1
                state.result.bytes += e.size
                state.result.allocatedBytes += e.allocSize
            }
        }
    }

    static func path(of url: URL) -> String {
        var p = url.standardizedFileURL.path(percentEncoded: false)
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
```
`withNoMaterialization`'s closure is synchronous and non-throwing here, and `state` is a local `var`, so the capture is fine (no suspension point, §4.2). If `BulkReader.read`'s typed throws (`throws(ReadFailure)`) makes `catch` exhaustive with a warning, write `catch let failure` and use `failure.code` in a debug log, so warnings-as-errors stays green.

Add to `Tests/FSKitTests/LaneTests.swift`:
```swift
func testScanClassHasItsOwnLanes() async throws {
    let pool = LanePool()
    _ = try await pool.perform(on: .unknown, .scan) { _ in 1 }
    let scan = await pool.liveLaneCount(of: .unknown, .scan)
    let read = await pool.liveLaneCount(of: .unknown, .read)
    XCTAssertEqual(scan, 1); XCTAssertEqual(read, 0)
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter "CoreTests.FolderSizeScannerTests|FSKitTests.LaneTests" 2>&1 | tail -5`
Expected: `0 failures` (the mount-point part may report a skip message if `hdiutil` is unavailable).

- [ ] **Step 5: Commit**

```bash
git add Sources/FSKit/Lanes Sources/Core/Sizes Tests/CoreTests/FolderSizeScannerTests.swift Tests/CoreTests/Support/VolumeInfoFixtures.swift Tests/FSKitTests/LaneTests.swift docs/superpowers/plans/2026-11-01-phase2-views-tabs.md
git commit -m "feat: cancellable recursive folder-size scanner on dedicated scan lanes"
```

---

### Task P2-13: Folder-size cache, sessions and Watcher-based invalidation

**Files:**
- Create: `Sources/Core/Sizes/FolderSizeCache.swift`, `Sources/Core/Sizes/FolderSizeService.swift`, `Sources/Core/Watch/SubtreeEventClassifier.swift`, `Sources/Core/Watch/SubtreeWatcher.swift`, `Sources/Core/Folder/FolderModel+Sizes.swift` (storage part), `Tests/CoreTests/SubtreeEventClassifierTests.swift`, `Tests/CoreTests/FolderSizeServiceTests.swift`
- Modify: `Sources/Core/Support/ChangeBus.swift` (`observeAll`), `Sources/Core/Folder/FolderModel.swift` (`FolderEvent.folderSizes`), `Sources/Core/Support/CoreEnvironment.swift` (`folderSizes`), `Sources/Core/Watch/Watcher.swift` (factor the stream setup so `SubtreeWatcher` reuses it)

**Interfaces:**
- Consumes: `FolderSizeScanner`, `FolderSize`, `FolderSizeIdentity`, `FolderSizeKey`, `LaneClass.scan` (P2-12), `RawFSEvent`, `ContentWatching`, `ChangeBus`, `LocalChange`, `FolderModel` (rows, `entry(atRow:)`, `url(atRow:)`, `identity(atRow:)`, `row(of:)`, `row(named:)`, `store.identityMode`, `volume`, `observe`), `MountTableStore`.
- Produces:
  - §2.2 `FolderSizeCache`, `FolderSizeService`, `FolderSizeSession` (plus the internal `scansStarted: Int` for tests), `SubtreeChange`, `SubtreeEventClassifier`, `SubtreeWatcher`, `ChangeBus.observeAll`, and `CoreEnvironment.folderSizes`.
  - The storage half of the §2.2 `FolderModel` size API: `folderSize(atRow:)` and `setFolderSizes(_:)`, which emits `.folderSizes(Set<RowID>)`. Its `folderSizes` table is keyed by `RowID`, and rows removed from the store are dropped.
  - `setFolderSizesEnabled` and sorting come in P2-14.

Rules (spec §11: "cached by identity (path on non-idStable volumes) and mtime, and invalidated through the Watcher"):
- **Identity of a folder row:** `.object(volumeID, entry.rowID)` when `store.identityMode == .objectID`; otherwise `.path(url(atRow:).path)`. The cache key adds the row's `mtime`.
- **Session start** (the user enabled sizes, or navigated to a folder that has them on):
  1. Every directory or package row whose cache entry matches is set on the model immediately.
  2. Every directory or package row is queued: misses first, then hits, so a hit's value shows at once and is revalidated in the background (deep changes do not change a folder's own mtime).
  3. Visible rows go to the front of the queue.
  4. Up to `maxConcurrentScans` (2) scans run at once, on `.scan` lanes of the folder's volume.
- **During the session:**
  - New rows, and rows whose `mtime` no longer matches their cached key, are queued.
  - Removed rows are cancelled or unqueued.
  - `SubtreeWatcher` events (`children(names)`) invalidate and re-queue those children. `.all` re-queues everything.
  - Each `LocalChange` (FileOps) invalidates cached ancestors of its directory. When the directory is inside a session's folder, the affected child is re-queued at once, without waiting for FSEvents.
- **Failures:** `LaneError.volumeUnresponsive` stops the session's queue, and the cells stay "Calculating…" until the user retries (Refresh). A stalled scan is reported by the lane watchdog like any read.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/SubtreeEventClassifierTests.swift
import XCTest
import CoreServices
@testable import Core

final class SubtreeEventClassifierTests: XCTestCase {
    func ev(_ path: String, _ flags: Int = 0) -> RawFSEvent { RawFSEvent(path: path, flags: UInt32(flags), id: 1) }
    func testChildMapping() {
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/r/A/x"), ev("/r/A/B/"), ev("/r/C")], folder: "/r"), .children(["A", "C"]))
        XCTAssertNil(SubtreeEventClassifier.classify([ev("/r"), ev("/r/")], folder: "/r"), "the folder's own listing changed: no subfolder affected")
        XCTAssertNil(SubtreeEventClassifier.classify([ev("/rr/x"), ev("/other/A")], folder: "/r"), "prefix boundary")
    }
    func testRescanFlags() {
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/r", kFSEventStreamEventFlagMustScanSubDirs)], folder: "/r"), .all)
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/", kFSEventStreamEventFlagUserDropped)], folder: "/r"), .all)
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/r", kFSEventStreamEventFlagRootChanged)], folder: "/r"), .all)
        XCTAssertEqual(SubtreeEventClassifier.classify([ev("/r/A/deep", kFSEventStreamEventFlagMustScanSubDirs)], folder: "/r"), .children(["A"]))
    }
}
```

```swift
// Tests/CoreTests/FolderSizeServiceTests.swift
import XCTest
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class FolderSizeServiceTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    override func setUp() async throws {
        sandbox = try Sandbox(); addTeardownBlock { [sandbox] in sandbox?.destroy() }
        env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
    }
    func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testCacheKeyedByIdentityAndMtime() {
        let cache = FolderSizeCache(capacity: 2)
        let id = FolderSizeIdentity.path("/a")
        cache.store(FolderSize(bytes: 5), for: FolderSizeKey(identity: id, mtime: 1), path: "/a")
        XCTAssertEqual(cache.value(for: FolderSizeKey(identity: id, mtime: 1))?.bytes, 5)
        XCTAssertNil(cache.value(for: FolderSizeKey(identity: id, mtime: 2)))
        cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: .path("/b"), mtime: 0), path: "/b")
        cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: .path("/c"), mtime: 0), path: "/c")
        XCTAssertEqual(cache.count, 2, "LRU capacity")
    }

    func testInvalidateAncestorsIsComponentWise() {
        let cache = FolderSizeCache()
        for p in ["/a", "/a/b", "/a/b/c", "/a/bc", "/x"] {
            cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: .path(p), mtime: 0), path: p)
        }
        cache.invalidateAncestors(ofDirectory: "/a/b")
        XCTAssertNil(cache.value(for: FolderSizeKey(identity: .path("/a"), mtime: 0)))
        XCTAssertNil(cache.value(for: FolderSizeKey(identity: .path("/a/b"), mtime: 0)))
        for p in ["/a/b/c", "/a/bc", "/x"] { XCTAssertNotNil(cache.value(for: FolderSizeKey(identity: .path(p), mtime: 0)), p) }
    }

    func testSessionSizesEveryFolderAndCaches() async throws {
        try sandbox.write("big/a.bin", bytes: 3_000); try sandbox.write("big/deep/b.bin", bytes: 2_000)
        try sandbox.write("small/c.bin", bytes: 1_000); try sandbox.write("file.txt", bytes: 7)
        let model = try await loadedModel(sandbox.root, env: env)
        let session = env.folderSizes.attach(to: model)
        await session.waitUntilIdle()
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "big")!)?.bytes, 5_000)
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "small")!)?.bytes, 1_000)
        XCTAssertNil(model.folderSize(atRow: model.row(named: "file.txt")!))
        XCTAssertEqual(env.folderSizes.cache.count, 2)
        session.stop()
    }

    func testVisibleRowsScanFirst() async throws {
        for i in 0..<30 { try sandbox.write(String(format: "d%02d/f", i), bytes: 1) }
        let service = FolderSizeService(lanes: env.lanes, mountTable: env.volumes.mountTableStore, changeBus: env.changeBus,
                                        makeSubtreeWatcher: { _, _ in NoopWatcher() }, maxConcurrentScans: 1)
        let model = try await loadedModel(sandbox.root, env: env)
        var order: [String] = []
        let token = model.observe { e in
            if case .folderSizes(let ids) = e { for id in ids { if let r = model.row(of: id) { order.append(model.name(atRow: r)) } } }
        }
        defer { token.cancel() }
        let session = service.attach(to: model)
        session.setVisibleRows(25..<30)
        await session.waitUntilIdle()
        XCTAssertEqual(Set(order.dropFirst().prefix(5)), Set((25..<30).map { String(format: "d%02d", $0) }),
                       "after the scan already in flight, visible folders come first")
    }

    func testDeepChangeRescansOnlyThatChild() async throws {
        try sandbox.write("big/a.bin", bytes: 3_000); try sandbox.write("small/c.bin", bytes: 1_000)
        let model = try await loadedModel(sandbox.root, env: env)
        let session = env.folderSizes.attach(to: model)
        await session.waitUntilIdle()
        let before = session.scansStarted
        try sandbox.write("big/deep/new.bin", bytes: 4_000)   // inside the sandbox; FSEvents → SubtreeWatcher
        await waitUntil { model.folderSize(atRow: model.row(named: "big")!)?.bytes == 7_000 }
        XCTAssertEqual(model.folderSize(atRow: model.row(named: "big")!)?.bytes, 7_000)
        await session.waitUntilIdle()
        XCTAssertEqual(session.scansStarted - before, 1, "only big was rescanned")
        session.stop()
    }

    func testStopCancelsEverything() async throws {
        for i in 0..<200 { try sandbox.write("d\(i)/f", bytes: 1) }
        let model = try await loadedModel(sandbox.root, env: env)
        var late = 0
        let session = env.folderSizes.attach(to: model)
        session.stop()
        let token = model.observe { if case .folderSizes = $0 { late += 1 } }
        defer { token.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.pendingCount, 0); XCTAssertEqual(session.inFlightCount, 0)
        XCTAssertEqual(late, 0, "cancelled scans never publish")
    }

    func testLocalChangeInvalidatesCachedAncestors() {
        let big = sandbox.url("big").path(percentEncoded: false)
        env.folderSizes.cache.store(FolderSize(bytes: 1), for: FolderSizeKey(identity: .path(big), mtime: 0), path: big)
        env.changeBus.post([LocalChange(directory: sandbox.url("big/deep"), added: ["n"])])
        XCTAssertNil(env.folderSizes.cache.value(for: FolderSizeKey(identity: .path(big), mtime: 0)))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "CoreTests.SubtreeEventClassifierTests|CoreTests.FolderSizeServiceTests" 2>&1 | tail -5`
Expected: `cannot find 'SubtreeEventClassifier' in scope`.

- [ ] **Step 3: Implement the classifier, watcher and cache**

```swift
// Sources/Core/Watch/SubtreeEventClassifier.swift
import Foundation
import CoreServices

public enum SubtreeChange: Sendable, Equatable { case children(Set<String>), all }

public enum SubtreeEventClassifier {
    static let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs) | UInt32(kFSEventStreamEventFlagUserDropped)
        | UInt32(kFSEventStreamEventFlagKernelDropped) | UInt32(kFSEventStreamEventFlagEventIdsWrapped)
        | UInt32(kFSEventStreamEventFlagRootChanged)

    public static func classify(_ events: [RawFSEvent], folder: String) -> SubtreeChange? {
        let base = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let prefix = base == "/" ? "/" : base + "/"
        var names = Set<String>()
        for e in events {
            let path = e.path.count > 1 && e.path.hasSuffix("/") ? String(e.path.dropLast()) : e.path
            let rescan = e.flags & rescanFlags != 0
            if path == base || prefix.hasPrefix(path == "/" ? "/" : path + "/") {   // the folder itself or an ancestor
                if rescan { return .all }
                continue
            }
            guard path.hasPrefix(prefix) else { continue }
            if let first = path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first {
                names.insert(String(first))
            }
        }
        return names.isEmpty ? nil : .children(names)
    }
}
```

`SubtreeWatcher` uses the same stream plumbing as Phase 1's `Watcher`: factor a small internal `FSEventStreamBox` (create, schedule on a private serial queue, start, stop, invalidate, release, and `lastEventID`) out of `Watcher.swift` without changing `Watcher`'s behaviour. The flags are `kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot`, with no `FileEvents`, so events have directory granularity and a recursive scope. `sinceWhen` is `kFSEventStreamEventIdSinceNow`, and the latency is 1 s. The callback converts paths and flags to `[RawFSEvent]`, classifies them against `directory`, and calls `handler` for non-nil results.

```swift
// Sources/Core/Sizes/FolderSizeCache.swift
import Foundation

@MainActor
public final class FolderSizeCache {
    private struct Slot { var size: FolderSize; var mtime: Int64; var path: String; var used: UInt64 }
    private var slots: [FolderSizeIdentity: Slot] = [:]
    private var clock: UInt64 = 0
    private let capacity: Int

    public init(capacity: Int = 20_000) { self.capacity = capacity }
    public var count: Int { slots.count }

    public func value(for key: FolderSizeKey) -> FolderSize? {
        guard var slot = slots[key.identity], slot.mtime == key.mtime else { return nil }
        clock += 1; slot.used = clock; slots[key.identity] = slot
        return slot.size
    }

    public func store(_ size: FolderSize, for key: FolderSizeKey, path: String) {
        clock += 1
        slots[key.identity] = Slot(size: size, mtime: key.mtime, path: path, used: clock)
        if slots.count > capacity, let victim = slots.min(by: { $0.value.used < $1.value.used })?.key { slots[victim] = nil }
    }

    public func invalidate(_ identity: FolderSizeIdentity) { slots[identity] = nil }

    public func invalidateAncestors(ofDirectory path: String) {
        let dir = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        for (id, slot) in slots where slot.path == dir || dir.hasPrefix(slot.path == "/" ? "/" : slot.path + "/") {
            slots[id] = nil
        }
    }
}
```
(The eviction scan is O(n) and runs only when the cache is over capacity, at most once per stored scan result, which is negligible next to the scan itself.)

- [ ] **Step 4: Implement the service, session and model storage**

`FolderModel+Sizes.swift` (storage part):
```swift
extension FolderModel {
    public func folderSize(atRow row: Int) -> FolderSize? { sizeTable[identity(atRow: row)] }
    public func setFolderSizes(_ sizes: [RowID: FolderSize]) {
        guard !sizes.isEmpty else { return }
        for (id, s) in sizes where row(of: id) != nil { sizeTable[id] = s }
        send(.folderSizes(Set(sizes.keys)))
    }
}
```
`sizeTable: [RowID: FolderSize]` is a stored property on `FolderModel` (extensions cannot add stored properties). Entries of removed rows are dropped in the removal path. `send` is the model's internal event emitter (Phase 1 name may differ). Add `case folderSizes(Set<RowID>)` to `FolderEvent` and update the exhaustive switches; views ignore it until P2-14.

`ChangeBus.observeAll(_:)` delivers every posted `LocalChange` after the per-directory observers.

`FolderSizeService` and `FolderSizeSession`:
```swift
@MainActor
public final class FolderSizeService {
    public let cache = FolderSizeCache()
    let lanes: LanePool
    let mountTable: MountTableStore
    let makeSubtreeWatcher: @MainActor (URL, @escaping @Sendable (SubtreeChange) -> Void) -> any ContentWatching
    let maxConcurrentScans: Int
    private var sessions: [ObjectIdentifier: WeakSession] = [:]
    private var busToken: ObserverToken?
    private struct WeakSession { weak var session: FolderSizeSession? }

    public init(lanes: LanePool, mountTable: MountTableStore, changeBus: ChangeBus,
                makeSubtreeWatcher: @escaping @MainActor (URL, @escaping @Sendable (SubtreeChange) -> Void) -> any ContentWatching,
                maxConcurrentScans: Int = 2) {
        self.lanes = lanes; self.mountTable = mountTable; self.makeSubtreeWatcher = makeSubtreeWatcher
        self.maxConcurrentScans = maxConcurrentScans
        busToken = changeBus.observeAll { [weak self] change in self?.localChange(change) }
    }

    public func attach(to model: FolderModel) -> FolderSizeSession {
        let s = FolderSizeSession(model: model, service: self)
        sessions[ObjectIdentifier(s)] = WeakSession(session: s)
        return s
    }

    private func localChange(_ change: LocalChange) {
        let dir = FolderSizeScanner.path(of: change.directory)
        cache.invalidateAncestors(ofDirectory: dir)
        for entry in sessions.values { entry.session?.localChange(inDirectory: dir) }
        sessions = sessions.filter { $0.value.session != nil }
    }
}
```
`FolderSizeSession` holds:
- `unowned let service`, `weak var model`, the model observer token and the subtree watcher;
- `queue: [RowID]` with `queued: Set<RowID>`, `inFlight: [RowID: Task<Void, Never>]`, `visible: Range<Int>` and `idleWaiters: [CheckedContinuation<Void, Never>]`;
- `private(set) var scansStarted = 0` and `stopped`.

Its behaviour:
- `init` observes the model: `.changes` and `.state(.complete)` call `requeueChangedRows()`. It starts `service.makeSubtreeWatcher(model.directory) { [weak self] change in Task { @MainActor in self?.subtree(change) } }`, then calls `startAll()`.
- `startAll()` publishes the cache hits to the model and queues every folder row as described in Rules, then calls `pump()`.
- `pump()`, while `inFlight.count < service.maxConcurrentScans` and the queue is non-empty:
  1. Pop the first id. Skip it if the row is gone.
  2. Build `url`, `key` and `path`, and increment `scansStarted`.
  3. Start `Task { let size = try? await service.lanes.perform(on: volumeID, .scan) { ctx in FolderSizeScanner.scan(url, context: ctx, mountTable: table) }; self.finish(id, key, path, size ?? nil) }`. `table` is `service.mountTable.current()`.
- `finish` removes the in-flight entry. A non-nil size is stored in the cache and set on the model. An error of type `LaneError.volumeUnresponsive` clears the queue. Then `pump()`; when the session is idle, it resumes the waiters.
- `requeueChangedRows()` queues folder rows that are not known, queued or in flight, and rows whose cache key's `mtime` no longer matches.
- `subtree(.children(names))` invalidates each name's identity in the cache and re-queues it (front if visible). `subtree(.all)` does that for every folder row.
- `localChange(inDirectory:)`: if the directory is strictly inside `model.directory`, take its first path component under the folder and call `subtree(.children([component]))`.
- `setVisibleRows` moves queued visible rows to the front.
- `stop()` cancels every task, stops the watcher, clears the queue, sets `stopped` (later `finish` calls are ignored) and resumes the waiters.
- `waitUntilIdle()` returns at once when nothing is queued or in flight; otherwise it suspends on a continuation.

`CoreEnvironment.folderSizes = FolderSizeService(lanes: lanes, mountTable: volumes.mountTableStore, changeBus: changeBus, makeSubtreeWatcher: { url, h in SubtreeWatcher(directory: url, handler: h) })`, in both `init` and `sandboxed`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "CoreTests.SubtreeEventClassifierTests|CoreTests.FolderSizeServiceTests" 2>&1 | tail -5`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 6: Run the Watcher tests (factored stream setup)**

Run: `swift test --filter CoreTests.WatcherTests 2>&1 | tail -3`
Expected: `0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Core Tests/CoreTests/SubtreeEventClassifierTests.swift Tests/CoreTests/FolderSizeServiceTests.swift
git commit -m "feat: folder-size cache and sessions with subtree watcher and local-change invalidation"
```

---

### Task P2-14: Folder sizes in the list: toggle, Size column, size sort, selection total

**Files:**
- Create: `Sources/FSKit/Sort/SortExtras.swift`, `Tests/FSKitTests/SortExtrasTests.swift`, `Tests/CoreTests/FolderModelSizesTests.swift`, `Tests/Scenarios/p2-folder-sizes.json`
- Modify: `Sources/FSKit/Sort/Sorter.swift` (`extras` overload), `Sources/Core/Folder/FolderWorker.swift` (re-sort takes `SortExtras`), `Sources/Core/Folder/FolderModel+Sizes.swift` (enable flag, coalesced re-sort), `Sources/Core/Folder/Selection.swift` (`SelectionSummary.folderBytes`), `Sources/Core/Folder/FolderModel.swift` (`FolderContext.resortCoalescing`), `Sources/UI/Window/BrowserSession.swift` (attach/stop sessions), `Sources/UI/Details/DetailsViewController.swift` (size cells, visible rows → session), `Sources/UI/StatusBar/StatusBarView.swift`, `Sources/UI/Support/Formatters.swift` (`FolderSizeText`, `SelectionSizeText`), `Sources/UI/Commands/FileCommandController.swift` (`toggleFolderSizes`)

**Interfaces:**
- Consumes: `FolderSizeService.attach`, `FolderSizeSession.setVisibleRows/stop`, `FolderModel.folderSize/setFolderSizes`, `FolderEvent.folderSizes` (P2-13), `BrowserSession.viewState/updateViewState` (P2-08).
- Produces: §2.1 `SortExtras` (`folderSizes` now; `column` declared with this task and honoured in P2-16), `Sorter.permutation(…, extras:)`; §2.2 `FolderModel.folderSizesEnabled/setFolderSizesEnabled`, `SelectionSummary.folderBytes`, `FolderContext.resortCoalescing`; `FolderSizeText.text(_ size: FolderSize?, enabled: Bool) -> String`; `SelectionSizeText.text(_ summary: SelectionSummary, sizesEnabled: Bool) -> String`; the `cellText` scenario hook (Phase 1 columns).

Rules:
- "Calculate Folder Sizes" is a per-folder toggle (`FolderViewState.calculateFolderSizes`). While it is on and the window shows Details, `BrowserSession` keeps one `FolderSizeSession` for the current model. The session stops on navigation, on a mode change away from Details, and when the toggle is turned off.
- **Size cell for folder rows:**

  | State | Cell |
  |---|---|
  | Toggle off | `--` (Phase 1) |
  | Pending | `Calculating…` (secondary colour) |
  | Known | `ByteCountFormatter` `.file` |
  | Partial | `≥ ` prefix; accessibility label "at least <size>" |

  Cells update through `.folderSizes(ids)` (`reloadData(forRowIndexes:columnIndexes:)` on the Size column only).
- **Sort by Size with sizes on:** folders stay first. Within the folders group, known sizes are ordered by the sort direction and unknown sizes come last in both directions, with name order breaking ties. Re-sorts are coalesced so that at most one happens per `resortCoalescing` (500 ms) while sizes stream in. Every later re-sort, including `setQuery`, passes the current extras.
- **Status bar:** the selection total includes the selected folders' sizes once all of them are known. While any is unknown it shows "<files size> + calculating…". With sizes off it is Phase 1's text.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FSKitTests/SortExtrasTests.swift
import XCTest
@testable import MacxFS

final class SortExtrasTests: XCTestCase {
    func store(_ names: [(String, Kind, Int64)]) -> EntryStore {
        var s = EntryStore(identityMode: .name(caseSensitive: false))
        var b = Batch(generation: .initial)
        for (i, n) in names.enumerated() {
            let e = Entry(rowID: UInt64(i + 1), fileID: UInt64(i + 1), size: n.2, allocSize: n.2, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                          kind: n.1, flags: [], typeIndex: n.1 == .directory ? TypeRegistry.folderIndex : TypeRegistry.dataIndex)
            Array(n.0.utf8).withUnsafeBufferPointer { b.append(e, nameBytes: $0) }
        }
        s.append(b); return s
    }
    func sorted(_ s: EntryStore, _ query: ViewQuery, _ extras: SortExtras) -> [String] {
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        return Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: query, kindRanks: TypeRegistry.shared.kindRanks().ranks, extras: extras)
            .map { s.name($0) }
    }

    func testFolderSizesOrderFoldersUnknownLast() {
        let s = store([("A", .directory, 0), ("B", .directory, 0), ("C", .directory, 0), ("x", .file, 5), ("y", .file, 1)])
        let extras = SortExtras(folderSizes: [0: 300, 2: 100])          // storage indices: A=0, C=2; B unknown
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: true)), extras), ["C", "A", "B", "y", "x"])
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: false)), extras).prefix(3), ["A", "C", "B"])
        XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .size, ascending: true)), .none).prefix(3), ["A", "B", "C"], "Phase 1 behaviour without sizes")
        XCTAssertEqual(sorted(s, ViewQuery(sort: .default), extras), ["A", "B", "C", "x", "y"], "only the size sort uses folder sizes")
    }
}
```

```swift
// Tests/CoreTests/FolderModelSizesTests.swift
import XCTest
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class FolderModelSizesTests: XCTestCase {
    func testEnableSortSummaryAndDisable() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.write("big/a", bytes: 5_000); try sandbox.write("small/a", bytes: 10); try sandbox.write("f.txt", bytes: 3)
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        var ctx = env.folderContext(); ctx.resortCoalescing = .zero
        let model = FolderModel(directory: sandbox.root, context: ctx, query: ViewQuery(sort: SortDescriptor(field: .size, ascending: true)))
        model.start()
        let end = Date().addingTimeInterval(3)
        while model.state != .complete && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual((0..<3).map(model.name(atRow:)), ["big", "small", "f.txt"], "Phase 1: folders by name")
        model.setFolderSizesEnabled(true)
        let session = env.folderSizes.attach(to: model)
        await session.waitUntilIdle()
        let end2 = Date().addingTimeInterval(3)
        while model.name(atRow: 0) != "small" && Date() < end2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual((0..<3).map(model.name(atRow:)), ["small", "big", "f.txt"])
        model.select(.names(["big", "f.txt"]))
        XCTAssertEqual(model.selectionSummary.bytes, 3)
        XCTAssertEqual(model.selectionSummary.folderBytes, 5_000)
        model.select(.names(["f.txt"]))
        XCTAssertEqual(model.selectionSummary.folderBytes, 0)
        session.stop()
        model.setFolderSizesEnabled(false)
        XCTAssertNil(model.folderSize(atRow: 0))
        XCTAssertNil(model.selectionSummary.folderBytes)
    }

    func testSizeTexts() {
        XCTAssertEqual(FolderSizeText.text(nil, enabled: false), "--")
        XCTAssertEqual(FolderSizeText.text(nil, enabled: true), "Calculating…")
        XCTAssertEqual(FolderSizeText.text(FolderSize(bytes: 5_000_000), enabled: true), "5 MB")
        XCTAssertEqual(FolderSizeText.text(FolderSize(bytes: 1_200_000, isPartial: true), enabled: true), "≥ 1.2 MB")
    }
}
```
`FolderSizeText` lives in UI (`Formatters.swift`). Move `testSizeTexts` into `Tests/UITests/ExtendedColumnsTests.swift` when that file is created in P2-16. For now, put it in `Tests/UITests/FolderSizeTextTests.swift` with `@testable import UI`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "FSKitTests.SortExtrasTests|CoreTests.FolderModelSizesTests|UITests.FolderSizeTextTests" 2>&1 | tail -5`
Expected: `cannot find 'SortExtras' in scope`.

- [ ] **Step 3: Implement `SortExtras` and the size sort**

```swift
// Sources/FSKit/Sort/SortExtras.swift
public enum ExtraSortValues: Sendable {
    case integers([Int64?])
    case strings([[UInt8]?])
}
public struct SortExtras: Sendable {
    public var folderSizes: [UInt32: Int64]
    public var column: ExtraSortValues?
    public init(folderSizes: [UInt32: Int64] = [:], column: ExtraSortValues? = nil) { self.folderSizes = folderSizes; self.column = column }
    public static let none = SortExtras()
}

extension Sorter {
    public static func permutation(_ store: EntryStore, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                   query: ViewQuery, kindRanks: [UInt16], extras: SortExtras) -> [UInt32] {
        var order = permutation(store, nameKeys: nameKeys, searchKeys: searchKeys, query: query, kindRanks: kindRanks)
        let folderCount = order.prefix { store.entry($0).isFolderForSorting }.count
        if query.sort.field == .size, !extras.folderSizes.isEmpty {
            reorder(&order, range: 0..<folderCount, ascending: query.sort.ascending) { extras.folderSizes[$0] }
        }
        // P2-16 handles extras.column for extended fields here.
        return order
    }

    /// Stable: equal and unknown values keep their incoming (name-ordered) positions; unknown values go last.
    static func reorder<V: Comparable>(_ order: inout [UInt32], range: Range<Int>, ascending: Bool, value: (UInt32) -> V?) {
        guard range.count > 1 else { return }
        let items = order[range].enumerated().map { (pos: $0.offset, idx: $0.element, v: value($0.element)) }
        let sorted = items.sorted { a, b in
            switch (a.v, b.v) {
            case let (x?, y?): return x != y ? (ascending ? x < y : x > y) : a.pos < b.pos
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.pos < b.pos
            }
        }
        order.replaceSubrange(range, with: sorted.map(\.idx))
    }
}
```

- [ ] **Step 4: Implement the model, session wiring and UI**

- **`FolderContext`:** add `resortCoalescing: Duration = .milliseconds(500)` (defaulted, appended).
- **`FolderWorker`:** its re-sort entry point gains `extras: SortExtras = .none` and calls the new `Sorter.permutation` overload.
- **`FolderModel+Sizes`:**
  - `setFolderSizesEnabled(_ on:)`. Turning it off clears `sizeTable`, emits `.folderSizes(Set(old keys))` and re-sorts without extras when the field is `.size`.
  - `currentSortExtras()` maps `sizeTable` to storage indices through `store.firstIndex(of:)`, using bytes.
  - `setFolderSizes` additionally schedules a coalesced re-sort when `query.sort.field == .size`: one pending `Task` sleeps `resortCoalescing` and then re-sorts with `currentSortExtras()`.
  - Every other re-sort call in the model (`setQuery`, refresh) passes `currentSortExtras()` when the size table is non-empty.
- **`SelectionSummary`:** add `public var folderBytes: Int64?` (defaulted nil). `FolderModel.selectionSummary` fills it as in §2.2.
- **`BrowserSession.apply` / navigate / mode change:**
  - `folder.setFolderSizesEnabled(state.calculateFolderSizes && displayedMode == .details)`;
  - when enabled, keep `sizeSession = environment.folderSizes.attach(to: folder)`;
  - otherwise `sizeSession?.stop(); sizeSession = nil`;
  - `navigate` always stops the old session first.
- **`DetailsViewController`:**
  - the size cell for folder rows uses `FolderSizeText.text(folder.folderSize(atRow:), enabled: folder.folderSizesEnabled)`;
  - `.folderSizes(ids)` reloads the Size column for those rows (mapped through `RowMapping`);
  - on scroll (`NSView.boundsDidChangeNotification` of the clip view, coalesced to the next run-loop turn) it calls `session.sizeSession?.setVisibleRows(visible model rows)`.
- **`StatusBarView`:** uses `SelectionSizeText.text(summary, sizesEnabled:)`:
```swift
enum SelectionSizeText {
    static func text(_ s: SelectionSummary, sizesEnabled: Bool) -> String {
        let files = Formatters.size(s.bytes)
        guard sizesEnabled, s.folders > 0 else { return files }
        if let folders = s.folderBytes { return Formatters.size(s.bytes + folders) }
        return L10n.string("\(files) + calculating…")
    }
}
```
  Use the Phase 1 names for the byte formatter and `L10n` format strings; the expression above shows the intended output.
- **`toggleFolderSizes`:** calls `session.updateViewState { $0.calculateFolderSizes.toggle() }`, with a menu checkmark.
- **`cellText` scenario hook:** for the Phase 1 column IDs, returns exactly the string the cell displays. It uses the same formatting functions the cell configuration uses.

- [ ] **Step 5: Add the scenario**

```json
// Tests/Scenarios/p2-folder-sizes.json
{"name": "p2-folder-sizes",
 "fixture": {"files": ["big/a.bin", "big/deep/b.bin", "small/c.bin"], "dirs": ["big", "small"],
             "sizes": {"big/a.bin": 3000000, "big/deep/b.bin": 2000000, "small/c.bin": 1000}},
 "steps": [
  {"expect": {"cells": {"big": {"size": "--"}}}},
  {"menu": ["View", "Calculate Folder Sizes"]},
  {"waitFor": {"cells": {"big": {"size": "5 MB"}, "small": {"size": "1 KB"}}}, "timeoutMs": 5000},
  {"menu": ["View", "Sort By", "Size"]},
  {"waitFor": {"rows": ["small", "big"]}},
  {"fsWrite": {"path": "big/deep/new.bin", "bytes": 4000000}},
  {"waitFor": {"cells": {"big": {"size": "9 MB"}}}, "timeoutMs": 6000},
  {"doubleClick": "small"},
  {"waitFor": {"folder": "small"}},
  {"key": "cmd+["},
  {"waitFor": {"cells": {"big": {"size": "9 MB"}}}, "timeoutMs": 1000}
 ]}
```
(The last step shows the cached value straight away when the folder is shown again, before revalidation finishes. That is the stale-while-revalidate rule.)

- [ ] **Step 6: Run the tests and scenarios**

Run: `swift test --filter "FSKitTests.SortExtrasTests|CoreTests.FolderModelSizesTests|UITests.FolderSizeTextTests|FSKitTests.SorterTests" 2>&1 | tail -5 && scripts/ui-scenarios.sh 2>&1 | tail -3`
Expected: `0 failures` (Phase 1 `SorterTests` unchanged); all scenarios pass, including `p2-folder-sizes`.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests/FSKitTests/SortExtrasTests.swift Tests/CoreTests/FolderModelSizesTests.swift Tests/UITests/FolderSizeTextTests.swift Tests/Scenarios/p2-folder-sizes.json
git commit -m "feat: on-demand folder sizes in the Size column with size sort and selection totals"
```

---

### Task P2-15: Extended attributes for the new columns (Core)

**Files:**
- Create: `Sources/Core/Attributes/ExtendedAttributes.swift`, `FinderMetadata.swift`, `PermissionsFormatter.swift`, `OwnerNameCache.swift`, `ExtendedAttributeReader.swift`, `Sources/Core/Folder/FolderModel+Attributes.swift`, `Tests/CoreTests/ExtendedAttributesTests.swift`
- Modify: `Sources/Core/Folder/FolderModel.swift` (`FolderEvent.extendedAttributes`, `FolderContext.ownerNames`, the attribute table), `Sources/Core/Folder/FolderModel+Watch.swift` (invalidate on `.items` / `.fullRescan`), `Sources/Core/Support/CoreEnvironment.swift` (`ownerNames`)

**Interfaces:**
- Consumes: `LanePool.perform`, `withNoMaterialization`, `assertOffMain`, `WatchEvent`, `FolderModel` rows and identities, `Kind`.
- Produces: §2.2 `ExtendedAttributeSet` (including `init(sortField:)` and `init(column:)`), `ExtendedAttributes`, `FinderMetadata`, `PermissionsFormatter`, `OwnerNameCache`, `ExtendedAttributeReader`, `FolderModel.extendedAttributes(atRow:)/requestExtendedAttributes(rows:_:)`, `FolderEvent.extendedAttributes`; also `FolderModel.loadAllExtendedAttributes(_ wanted: ExtendedAttributeSet) async`, which is internal and used by P2-16's sort.

Sources:

| Column | Source | Notes |
|---|---|---|
| Tags | xattr `com.apple.metadata:_kMDItemUserTags` (binary plist `[String]`, each `"Name\n<colour>"` or `"Name"`) | names only; colour dots are Phase 4 |
| Date Last Opened | xattr `com.apple.lastuseddate#PS` (16 bytes: `tv_sec`, `tv_nsec`, little endian) | absent → `--`; no Spotlight query |
| Permissions | `fstatat(dirfd, name, AT_SYMLINK_NOFOLLOW)` `st_mode` | `drwxr-xr-x` incl. s/S/t/T |
| Owner | `st_uid` → `getpwuid_r` (cached) | unknown uid → its number |
| Comments | xattr `com.apple.metadata:kMDItemFinderComment` (binary plist string; raw UTF-8 fallback) | |

All reads use `XATTR_NOFOLLOW` / `AT_SYMLINK_NOFOLLOW`, run on a lane inside `withNoMaterialization`, and happen only for the rows asked for.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/ExtendedAttributesTests.swift
import XCTest
@testable import Core
import MacxFS
import MacxFixtures

final class ExtendedAttributesTests: XCTestCase {
    func plist(_ v: Any) -> Data { try! PropertyListSerialization.data(fromPropertyList: v, format: .binary, options: 0) }

    func testParseTagsRealFinderFormat() {
        XCTAssertEqual(FinderMetadata.parseTags(plist(["Work\n6", "Home", "Red\n6"])), ["Work", "Home", "Red"])
        XCTAssertEqual(FinderMetadata.parseTags(Data("garbage".utf8)), [])
        XCTAssertEqual(FinderMetadata.parseTags(FinderMetadata.encodeTags(["A", "B"])), ["A", "B"])
    }
    func testParseComment() {
        XCTAssertEqual(FinderMetadata.parseComment(plist("hello")), "hello")
        XCTAssertEqual(FinderMetadata.parseComment(Data("raw text".utf8)), "raw text")
        XCTAssertNil(FinderMetadata.parseComment(Data([0xFF, 0xFE, 0x00])))
    }
    func testParseLastUsed() {
        let d = Date(timeIntervalSince1970: 1_800_000_000.5)
        XCTAssertEqual(FinderMetadata.parseLastUsed(FinderMetadata.encodeLastUsed(d))!.timeIntervalSince1970, d.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(FinderMetadata.parseLastUsed(Data(count: 8)))
        var bad = Data(); withUnsafeBytes(of: Int64(5).littleEndian) { bad.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64(2_000_000_000).littleEndian) { bad.append(contentsOf: $0) }
        XCTAssertNil(FinderMetadata.parseLastUsed(bad), "nsec out of range")
    }
    func testPermissionsStrings() {
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o755, kind: .directory), "drwxr-xr-x")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o644, kind: .file), "-rw-r--r--")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o4755, kind: .file), "-rwsr-xr-x")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o2644, kind: .file), "-rw-r-Sr--")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o1777, kind: .directory), "drwxrwxrwt")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o755, kind: .symlink), "lrwxr-xr-x")
        XCTAssertEqual(PermissionsFormatter.string(mode: 0o700, kind: .package), "drwx------")
    }
    func testOwnerNames() {
        let cache = OwnerNameCache()
        XCTAssertEqual(cache.name(for: getuid()), NSUserName())
        XCTAssertEqual(cache.name(for: 3_999_999), "3999999")
    }
    func testAttributeSetMapping() {
        XCTAssertEqual(ExtendedAttributeSet(sortField: .owner), .owner)
        XCTAssertEqual(ExtendedAttributeSet(sortField: .name), [])
        XCTAssertEqual(ExtendedAttributeSet(column: .tags), .tags)
        XCTAssertEqual(ExtendedAttributeSet(column: .path), [])
    }

    func testReaderReadsOnlyWhatIsAskedAndNeverFollowsLinks() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.write("a.txt", bytes: 1); try sandbox.setMode(0o644, on: "a.txt")
        try sandbox.setFinderTags(["Work"], on: "a.txt"); try sandbox.setFinderComment("note", on: "a.txt")
        let opened = Date(timeIntervalSince1970: 1_700_000_000); try sandbox.setLastUsedDate(opened, on: "a.txt")
        try sandbox.mkdir("d"); try sandbox.setMode(0o755, on: "d")
        try sandbox.symlink("l", to: "a.txt")
        let dir = sandbox.root
        let owners = OwnerNameCache()
        let all = try await LanePool().perform(on: .unknown, .read) { _ in
            ExtendedAttributeReader.read(names: ["a.txt", "d", "l", "missing"], in: dir, wanted: .all, owners: owners)
        }
        XCTAssertNil(all["missing"])
        XCTAssertEqual(all["a.txt"]?.tags, ["Work"])
        XCTAssertEqual(all["a.txt"]?.comment, "note")
        XCTAssertEqual(all["a.txt"]!.lastOpened!.timeIntervalSince1970, opened.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(all["a.txt"]?.mode.map { $0 & 0o7777 }, 0o644)
        XCTAssertEqual(all["a.txt"]?.ownerName, NSUserName())
        XCTAssertEqual(all["d"]?.mode.map { $0 & 0o7777 }, 0o755)
        XCTAssertEqual(all["l"]?.tags, [], "the link itself has no tags; its target's are not read")
        let tagsOnly = try await LanePool().perform(on: .unknown, .read) { _ in
            ExtendedAttributeReader.read(names: ["a.txt"], in: dir, wanted: .tags, owners: owners)
        }
        XCTAssertEqual(tagsOnly["a.txt"]?.loaded, .tags)
        XCTAssertNil(tagsOnly["a.txt"]?.mode)
    }

    // Review Focus 2
    @MainActor
    func testXattrOnlyChangeRefreshesExtendedAttributes() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.write("a.txt", bytes: 1); try sandbox.write("b.txt", bytes: 1)
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        model.requestExtendedAttributes(rows: 0..<model.rowCount, .tags)
        let row = model.row(named: "a.txt")!
        var end = Date().addingTimeInterval(3)
        while model.extendedAttributes(atRow: row) == nil && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.extendedAttributes(atRow: row)?.tags, [])
        var before = stat(); _ = stat(sandbox.url("a.txt").path(percentEncoded: false), &before)
        try sandbox.setFinderTags(["Home"], on: "a.txt")
        var after = stat(); _ = stat(sandbox.url("a.txt").path(percentEncoded: false), &after)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec, "xattr-only change")
        end = Date().addingTimeInterval(3)
        while model.extendedAttributes(atRow: model.row(named: "a.txt")!)?.tags != ["Home"] && Date() < end {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.extendedAttributes(atRow: model.row(named: "a.txt")!)?.tags, ["Home"])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter CoreTests.ExtendedAttributesTests 2>&1 | tail -5`
Expected: `cannot find 'FinderMetadata' in scope`.

- [ ] **Step 3: Implement the pure parts**

```swift
// Sources/Core/Attributes/ExtendedAttributes.swift
import Foundation
import MacxFS

public struct ExtendedAttributeSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let tags = ExtendedAttributeSet(rawValue: 1 << 0)
    public static let lastOpened = ExtendedAttributeSet(rawValue: 1 << 1)
    public static let permissions = ExtendedAttributeSet(rawValue: 1 << 2)
    public static let owner = ExtendedAttributeSet(rawValue: 1 << 3)
    public static let comments = ExtendedAttributeSet(rawValue: 1 << 4)
    public static let all: ExtendedAttributeSet = [.tags, .lastOpened, .permissions, .owner, .comments]
    public init(sortField: SortField) {
        switch sortField {
        case .tags: self = .tags; case .dateLastOpened: self = .lastOpened; case .permissions: self = .permissions
        case .owner: self = .owner; case .comments: self = .comments
        default: self = []
        }
    }
    public init(column: ColumnID) { self.init(sortField: column.sortField) }
}

public struct ExtendedAttributes: Sendable, Equatable {
    public var loaded: ExtendedAttributeSet
    public var tags: [String] = []
    public var lastOpened: Date?
    public var mode: UInt16?
    public var ownerID: UInt32?
    public var ownerName: String?
    public var comment: String?
    public init(loaded: ExtendedAttributeSet = []) { self.loaded = loaded }
    public func merging(_ other: ExtendedAttributes) -> ExtendedAttributes {
        var r = self
        r.loaded.formUnion(other.loaded)
        if other.loaded.contains(.tags) { r.tags = other.tags }
        if other.loaded.contains(.lastOpened) { r.lastOpened = other.lastOpened }
        if other.loaded.contains(.permissions) { r.mode = other.mode }
        if other.loaded.contains(.owner) { r.ownerID = other.ownerID; r.ownerName = other.ownerName }
        if other.loaded.contains(.comments) { r.comment = other.comment }
        return r
    }
}
```

```swift
// Sources/Core/Attributes/FinderMetadata.swift
import Foundation

public enum FinderMetadata {
    public static let tagsXattr = "com.apple.metadata:_kMDItemUserTags"
    public static let commentXattr = "com.apple.metadata:kMDItemFinderComment"
    public static let lastUsedXattr = "com.apple.lastuseddate#PS"

    public static func parseTags(_ data: Data) -> [String] {
        guard let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return [] }
        return list.compactMap { raw in
            let name = raw.firstIndex(of: "\n").map { String(raw[..<$0]) } ?? raw
            return name.isEmpty ? nil : name
        }
    }
    public static func parseComment(_ data: Data) -> String? {
        if let s = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? String { return s }
        return String(data: data, encoding: .utf8)
    }
    public static func parseLastUsed(_ data: Data) -> Date? {
        guard data.count >= 16 else { return nil }
        let (sec, nsec) = data.withUnsafeBytes { raw in
            (Int64(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: Int64.self)),
             Int64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: Int64.self)))
        }
        guard sec > 0, (0..<1_000_000_000).contains(nsec) else { return nil }
        return Date(timeIntervalSince1970: Double(sec) + Double(nsec) / 1e9)
    }
    public static func encodeTags(_ tags: [String]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)) ?? Data()
    }
    public static func encodeComment(_ comment: String) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: comment, format: .binary, options: 0)) ?? Data()
    }
    public static func encodeLastUsed(_ date: Date) -> Data {
        let sec = Int64(date.timeIntervalSince1970.rounded(.down))
        let nsec = Int64(((date.timeIntervalSince1970 - Double(sec)) * 1e9).rounded())
        var d = Data()
        withUnsafeBytes(of: sec.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: min(nsec, 999_999_999).littleEndian) { d.append(contentsOf: $0) }
        return d
    }
}
```

```swift
// Sources/Core/Attributes/PermissionsFormatter.swift
import MacxFS

public enum PermissionsFormatter {
    public static func string(mode: UInt16, kind: Kind) -> String {
        let type: Character = switch kind { case .directory, .package: "d"; case .symlink: "l"; default: "-" }
        var c: [Character] = [type]
        let bits: [(UInt16, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"),
                                           (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
        for (bit, ch) in bits { c.append(mode & bit != 0 ? ch : "-") }
        if mode & 0o4000 != 0 { c[3] = c[3] == "x" ? "s" : "S" }
        if mode & 0o2000 != 0 { c[6] = c[6] == "x" ? "s" : "S" }
        if mode & 0o1000 != 0 { c[9] = c[9] == "x" ? "t" : "T" }
        return String(c)
    }
}
```

```swift
// Sources/Core/Attributes/OwnerNameCache.swift
import Foundation
import Darwin
import Synchronization

public final class OwnerNameCache: Sendable {
    private let names = Mutex<[UInt32: String]>([:])
    public init() {}
    /// Directory-services lookup on first use per uid: call from lane work (ExtendedAttributeReader does).
    public func name(for uid: UInt32) -> String {
        if let n = names.withLock({ $0[uid] }) { return n }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1_024)
        let rc = getpwuid_r(uid_t(uid), &pwd, &buffer, buffer.count, &result)
        let name = (rc == 0 && result != nil) ? String(cString: pwd.pw_name) : String(uid)
        names.withLock { $0[uid] = name }
        return name
    }
}
```

- [ ] **Step 4: Implement the reader and the model integration**

```swift
// Sources/Core/Attributes/ExtendedAttributeReader.swift
import Foundation
import Darwin
import MacxFS

public enum ExtendedAttributeReader {
    public static func read(names: [String], in directory: URL, wanted: ExtendedAttributeSet,
                            owners: OwnerNameCache) -> [String: ExtendedAttributes] {
        assertOffMain()
        return withNoMaterialization {
            let dirPath = directory.standardizedFileURL.path(percentEncoded: false)
            let dirfd = open(dirPath, O_RDONLY | O_DIRECTORY)
            guard dirfd >= 0 else { return [:] }
            defer { close(dirfd) }
            var out: [String: ExtendedAttributes] = [:]
            let base = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
            for name in names {
                var st = stat()
                guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                var a = ExtendedAttributes(loaded: wanted)
                if wanted.contains(.permissions) { a.mode = UInt16(st.st_mode) }
                if wanted.contains(.owner) { a.ownerID = st.st_uid; a.ownerName = owners.name(for: st.st_uid) }
                let path = base + name
                if wanted.contains(.tags) { a.tags = xattr(path, FinderMetadata.tagsXattr).map(FinderMetadata.parseTags) ?? [] }
                if wanted.contains(.comments) { a.comment = xattr(path, FinderMetadata.commentXattr).flatMap(FinderMetadata.parseComment) }
                if wanted.contains(.lastOpened) { a.lastOpened = xattr(path, FinderMetadata.lastUsedXattr).flatMap(FinderMetadata.parseLastUsed) }
                out[name] = a
            }
            return out
        }
    }

    static func xattr(_ path: String, _ name: String) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var n = getxattr(path, name, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        if n < 0, errno == ERANGE {
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            buffer = [UInt8](repeating: 0, count: size)
            n = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        }
        return n >= 0 ? Data(buffer[0..<n]) : nil
    }
}
```

The model integration is `FolderModel+Attributes.swift`. Stored properties go on `FolderModel`: `attributeTable: [RowID: ExtendedAttributes]`, `lastAttributeRequest: (rows: Range<Int>, wanted: ExtendedAttributeSet)?`, and one in-flight attribute `Task` with a pending-request slot that keeps only the latest request.
- `extendedAttributes(atRow:)` returns `attributeTable[identity(atRow:)]`.
- `requestExtendedAttributes(rows:_:)`:
  1. Clamps `rows` to `0..<rowCount` and records it as `lastAttributeRequest`.
  2. Collects names whose entry lacks any wanted bit. Returns if there are none.
  3. Runs `context.lanes.perform(on: volume?.id ?? .unknown, .read) { _ in ExtendedAttributeReader.read(...) }`.
  4. On main: merges each result into the identity of the row with that name (`row(named:)`), skips names that no longer exist, and emits `.extendedAttributes(ids)`.
- `loadAllExtendedAttributes(_:)` does the same for every row: chunks of 2,000 names, on `.scan` lanes, awaiting each chunk.
- Invalidation:
  - Phase 1's removal path drops entries.
  - A `.changes` reload drops the reloaded identities.
  - In `FolderModel+Watch`, `.items(names)` first drops the identities of those names; `.fullRescan` drops all.
  - After invalidation, when `lastAttributeRequest` is set, the model re-requests it. This covers xattr-only changes, which Phase 1's diff does not report (Review Focus 2).
- `FolderContext.ownerNames` (defaulted `OwnerNameCache()`) is shared from `CoreEnvironment.ownerNames`.
- Add `case extendedAttributes(Set<RowID>)` to `FolderEvent` and update the exhaustive switches.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter CoreTests.ExtendedAttributesTests 2>&1 | tail -5`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core Tests/CoreTests/ExtendedAttributesTests.swift
git commit -m "feat: tags, last-opened, permissions, owner and comment attributes for visible rows"
```

---

### Task P2-16: More columns in Details view, and sorting by them

**Files:**
- Create: `Sources/UI/Details/ExtendedColumns.swift`, `Tests/UITests/ExtendedColumnsTests.swift`, `Tests/Scenarios/p2-extra-columns.json`
- Modify: `Sources/UI/Details/DetailsColumns.swift` (chooser, definitions), `Sources/UI/Details/DetailsViewController.swift` (cells, visible-row attribute requests, header sort), `Sources/FSKit/Sort/Sorter.swift` (extended column ordering), `Sources/Core/Folder/FolderModel.swift` (`setQuery` with extended fields), `Tests/FSKitTests/SortExtrasTests.swift` (extended cases)

**Interfaces:**
- Consumes: `ExtendedAttributeSet`, `ExtendedAttributes`, `FolderModel.requestExtendedAttributes/loadAllExtendedAttributes`, `FolderEvent.extendedAttributes` (P2-15), `PermissionsFormatter`, `PathFormatter` (P2-04), `SortExtras.column`, `Sorter.reorder` (P2-14), `ColumnID` (P2-01).
- Produces: `ExtendedColumns.definition(_ id: ColumnID) -> ColumnDefinition` (title, default width, alignment, required attributes), `ExtendedColumns.text(_ id: ColumnID, row: Int, in folder: FolderModel, dateStyle: DateStyle) -> String`, `DetailsColumns.availableColumns(isMultiFolder: Bool) -> [ColumnID]`, the extended-field branch in `Sorter.permutation(…, extras:)`, and the scenario hooks `visibleColumnIDs`, `cellText` (all columns), `clickTarget("header:…")` and `rightClickTarget("header:…")`.

Rules:
- The header right-click chooser offers every `ColumnID` except `.path`. Path is offered only when `isMultiFolder` is true. In Phase 2 every folder listing passes `false`; Phase 3's search results pass `true`. The path cell shows the item's parent folder in `~` form (`PathFormatter.one(_, .tilde)`).
- **Cell text:**

  | Column | Text |
  |---|---|
  | Tags | names joined by ", " |
  | Date Last Opened | Phase 1 date formatter (relative/absolute per Settings), `--` when absent |
  | Permissions | `PermissionsFormatter` |
  | Owner | name |
  | Comments | single line, newlines shown as spaces |

  Cells of rows whose attributes are not loaded yet are empty, never a spinner. Configuring them makes no I/O calls (budget: cell configure < 0.5 ms).
- **Loading:** whenever an extended column is visible, the controller calls `requestExtendedAttributes(rows: visibleModelRows, union of visible columns' sets)` on bind, on scroll (coalesced to the next run-loop turn) and on column changes. `.extendedAttributes(ids)` reloads those rows' extended columns only.
- **Sorting** by an extended column (header click, saved in the per-folder state):
  1. `FolderModel.setQuery` emits `.query` at once, so the header indicator updates.
  2. If any row lacks the needed attribute, it awaits `loadAllExtendedAttributes`.
  3. If the query is still current, it re-sorts with `SortExtras(column:)`: integers for Last Opened (ns) and Permissions (`mode & 0o7777`); `SortKeys.nameKey(_, isFolder: false)` bytes for Tags (first tag), Owner and Comments.
  4. Missing values sort last in both directions. Folders stay first.
  5. Until the load finishes, rows keep their previous order. The load is cancelled when the query changes again.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/FSKitTests/SortExtrasTests.swift`:
```swift
func testExtendedColumnOrderingKeepsFoldersFirstAndMissingLast() {
    let s = store([("D", .directory, 0), ("E", .directory, 0), ("a", .file, 0), ("b", .file, 0), ("c", .file, 0)])
    let ints: [Int64?] = [nil, 5, 30, nil, 10]                         // by storage index
    let q = ViewQuery(sort: SortDescriptor(field: .dateLastOpened, ascending: true))
    XCTAssertEqual(sorted(s, q, SortExtras(column: .integers(ints))), ["E", "D", "c", "a", "b"])
    let qd = ViewQuery(sort: SortDescriptor(field: .dateLastOpened, ascending: false))
    XCTAssertEqual(sorted(s, qd, SortExtras(column: .integers(ints))), ["E", "D", "a", "c", "b"], "missing stays last descending")
    let keys: [[UInt8]?] = [nil, nil, SortKeys.nameKey("work", isFolder: false), SortKeys.nameKey("Home", isFolder: false), nil]
    XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)), SortExtras(column: .strings(keys))).suffix(3), ["b", "a", "c"])
    XCTAssertEqual(sorted(s, ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)), .none), ["D", "E", "a", "b", "c"], "no values yet: name order")
}
```

```swift
// Tests/UITests/ExtendedColumnsTests.swift
import XCTest
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class ExtendedColumnsTests: XCTestCase {
    func testChooserHidesPathOutsideSearchResults() {
        XCTAssertFalse(DetailsColumns.availableColumns(isMultiFolder: false).contains(.path))
        XCTAssertTrue(DetailsColumns.availableColumns(isMultiFolder: true).contains(.path))
        XCTAssertTrue(DetailsColumns.availableColumns(isMultiFolder: false).contains(.tags))
        XCTAssertEqual(ExtendedColumns.definition(.permissions).required, .permissions)
    }

    func testCellTexts() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.write("a.txt", bytes: 1); try sandbox.setMode(0o640, on: "a.txt")
        try sandbox.setFinderTags(["Work", "Home"], on: "a.txt"); try sandbox.setFinderComment("line1\nline2", on: "a.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        let model = try await loadedModel(sandbox.root, env: env)
        let row = model.row(named: "a.txt")!
        XCTAssertEqual(ExtendedColumns.text(.tags, row: row, in: model, dateStyle: .absolute), "", "not loaded yet: empty, no I/O")
        model.requestExtendedAttributes(rows: 0..<model.rowCount, .all)
        let end = Date().addingTimeInterval(3)
        while model.extendedAttributes(atRow: row) == nil && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(ExtendedColumns.text(.tags, row: row, in: model, dateStyle: .absolute), "Work, Home")
        XCTAssertEqual(ExtendedColumns.text(.permissions, row: row, in: model, dateStyle: .absolute), "-rw-r-----")
        XCTAssertEqual(ExtendedColumns.text(.owner, row: row, in: model, dateStyle: .absolute), NSUserName())
        XCTAssertEqual(ExtendedColumns.text(.comments, row: row, in: model, dateStyle: .absolute), "line1 line2")
        XCTAssertEqual(ExtendedColumns.text(.dateLastOpened, row: row, in: model, dateStyle: .absolute), "--")
    }

    func testSortByOwnerLoadsAllAttributesThenSorts() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["b.txt", "a.txt"] { try sandbox.write(n, bytes: 1) }
        try sandbox.setFinderTags(["zeta"], on: "a.txt"); try sandbox.setFinderTags(["alpha"], on: "b.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        let model = try await loadedModel(sandbox.root, env: env)
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)))
        XCTAssertEqual(model.query.sort.field, .tags, "query (header indicator) updates immediately")
        let end = Date().addingTimeInterval(3)
        while model.name(atRow: 0) != "b.txt" && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual((0..<2).map(model.name(atRow:)), ["b.txt", "a.txt"])
    }
}
```
Move P2-14's `testSizeTexts` into this file and delete `Tests/UITests/FolderSizeTextTests.swift`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "FSKitTests.SortExtrasTests|UITests.ExtendedColumnsTests" 2>&1 | tail -5`
Expected: `cannot find 'ExtendedColumns' in scope`, and `testExtendedColumnOrderingKeepsFoldersFirstAndMissingLast` failing (name order returned).

- [ ] **Step 3: Implement the sorter branch**

In `Sorter.permutation(…, extras:)`, replace the P2-14 comment with:
```swift
if query.sort.field.isExtended, let column = extras.column {
    for range in [0..<folderCount, folderCount..<order.count] {
        switch column {
        case .integers(let values):
            reorder(&order, range: range, ascending: query.sort.ascending) { i in Int(i) < values.count ? values[Int(i)] : nil }
        case .strings(let keys):
            reorder(&order, range: range, ascending: query.sort.ascending) { i in
                Int(i) < keys.count ? keys[Int(i)].map(ByteKey.init) : nil
            }
        }
    }
}
```
with
```swift
struct ByteKey: Comparable {
    let bytes: [UInt8]
    static func < (a: ByteKey, b: ByteKey) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }
}
```
In `FolderModel`, build the extras at re-sort time. For an extended field, `currentSortExtras()` adds `column`: it walks `store` storage indices `0..<store.count`, looks up `attributeTable[store.identity(i)]` and maps it per the Rules. `setQuery` with an extended field emits `.query` at once, then runs a `Task`: `await loadAllExtendedAttributes(ExtendedAttributeSet(sortField:))`, check `self.query == query`, then re-sort with `currentSortExtras()`. The task is stored and cancelled by the next `setQuery`.

- [ ] **Step 4: Implement the columns UI**

`ExtendedColumns.swift` holds `struct ColumnDefinition { let id: ColumnID; let title: String; let defaultWidth: Double; let alignment: NSTextAlignment; let required: ExtendedAttributeSet }`, `definition(_:)` for every `ColumnID` (Phase 1 ones return `required: []`), and `text(_:row:in:dateStyle:)` per the Rules. Dates use the Phase 1 formatter for the given `dateStyle`.

`DetailsColumns`:
- `availableColumns(isMultiFolder:)` = `ColumnID.allCases.filter { $0 != .path || isMultiFolder }`;
- the header menu lists `availableColumns`, with checkmarks for visible ones; toggling calls `onColumnsChanged`, which saves per folder (P2-08);
- remove P2-01's `prefix(6)` filter.

`DetailsViewController`:
- builds `NSTableColumn`s for visible `ColumnID`s from `ExtendedColumns.definition`;
- configures extended cells from `ExtendedColumns.text`;
- triggers requests as described in the Rules;
- reloads on `.extendedAttributes(ids)`;
- header click on any column calls `session.updateViewState { $0.sort = SortDescriptor(field: id.sortField, ascending: toggled) }`.

Scenario hooks:
- `visibleColumnIDs` → visible column identifiers, in order;
- `cellText(row, id)` → the displayed string for any column;
- `clickTarget("header:<id>")` → the same path as a header click;
- `rightClickTarget("header:<id>")` → opens the header menu as the current context menu, so `chooseMenuItem` can pick an item.

- [ ] **Step 5: Add the scenario**

```json
// Tests/Scenarios/p2-extra-columns.json
{"name": "p2-extra-columns",
 "fixture": {"files": ["a.txt", "b.txt"], "dirs": [], "tags": {"a.txt": ["Work"]}, "comments": {"b.txt": "hello"},
             "lastOpenedDays": {"b.txt": -400}},
 "steps": [
  {"rightClick": "header:name"}, {"chooseMenuItem": "Tags"},
  {"rightClick": "header:name"}, {"chooseMenuItem": "Comments"},
  {"rightClick": "header:name"}, {"chooseMenuItem": "Permissions"},
  {"rightClick": "header:name"}, {"chooseMenuItem": "Owner"},
  {"expect": {"visibleColumnsContain": ["name", "tags", "comments", "permissions", "owner"]}},
  {"waitFor": {"cells": {"a.txt": {"tags": "Work", "permissions": "-rw-r--r--", "owner": "{user}"},
                         "b.txt": {"comments": "hello", "tags": ""}}}},
  {"fsTags": {"path": "b.txt", "tags": ["Home", "Red"]}},
  {"waitFor": {"cells": {"b.txt": {"tags": "Home, Red"}}}, "timeoutMs": 3000},
  {"click": "header:tags"},
  {"waitFor": {"sort": "tags.asc", "rows": ["b.txt", "a.txt"]}},
  {"click": "header:tags"},
  {"waitFor": {"sort": "tags.desc", "rows": ["a.txt", "b.txt"]}}
 ]}
```
(Fixture files are created with mode 0644, so the permissions text does not depend on umask.)

- [ ] **Step 6: Run the tests and scenarios**

Run: `swift test --filter "FSKitTests.SortExtrasTests|UITests.ExtendedColumnsTests" 2>&1 | tail -5 && scripts/ui-scenarios.sh 2>&1 | tail -3`
Expected: `0 failures`; all scenarios pass, including `p2-extra-columns`.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests/FSKitTests/SortExtrasTests.swift Tests/UITests Tests/Scenarios/p2-extra-columns.json
git commit -m "feat: Tags, Date Last Opened, Permissions, Owner, Path and Comments columns with sorting"
```

---

### Task P2-17: Thumbnails in Icons view

**Files:**
- Create: `Sources/UI/Icons/ThumbnailCache.swift`, `Sources/UI/Icons/ThumbnailScheduler.swift`, `Sources/UI/Icons/QLThumbnailGeneratorAdapter.swift`, `Tests/UITests/ThumbnailSchedulerTests.swift`, `Tests/Scenarios/p2-thumbnails.json`
- Modify: `Sources/UI/Icons/IconsViewController.swift`, `Sources/UI/Icons/IconItem.swift`, `Sources/UI/App/UIContext.swift` (shared cache and adapter), `Sources/FSKit/Support/PerfSignposts.swift` (`thumbnail` interval name), `Sources/UI/Settings/SettingsView.swift` (View › "Show thumbnails")

**Interfaces:**
- Consumes: `Entry` (`kind`, `flags`, `mtime`, `size`), `TypeRegistry.isApplication`, `FolderModel.identity(atRow:)/url(atRow:)/volume`, `FileGridLayout.indexes(in:)`, `IconCache` (tiers 0/1), and `Settings.showThumbnails` (P2-01).
- Produces: §2.3 `ThumbnailKey`, `ThumbnailCandidate`, `ThumbnailTicket`, `ThumbnailGenerating`, `ThumbnailCache`, `ThumbnailScheduler`; `QLThumbnailGeneratorAdapter`; `UIContext.thumbnails: ThumbnailCache`; `PerfSignposts.thumbnail`; the scenario hook `thumbnailNames`.

Rules (spec §11, §4.2 Tier 2):
- **What gets a thumbnail:** only visible grid items that `isEligible` accepts: regular non-empty files and document packages; never dataless items (no iCloud downloads), degraded entries, folders, apps, symlinks or aliases. Requests stop entirely when `showThumbnails` is off.
- **Request lifecycle:**
  - At most 8 requests are in flight, in visible order.
  - Items that scroll off are cancelled (`QLThumbnailGenerator.cancel`), and the visible set is recomputed on the next run-loop turn after a bounds change.
  - A failure (QL returned nil) is not retried for that key in this window.
  - Changing the icon size changes `pixels` and therefore the key.
- **Cache:** an `NSCache` whose cost per image is width × height × 4, limit 64 MB, keyed by (volume, identity, directory, mtime, size, pixels). Identity is a `RowID`; `.name` identities are only unique within their directory, hence the directory field.
- **Display:** the grid shows the Tier 0 type icon in the first frame, then Tier 1, then the thumbnail when it lands. Thumbnails never delay first paint or cell configuration.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/ThumbnailSchedulerTests.swift
import XCTest
@testable import UI
@testable import Core
import MacxFS

@MainActor
final class FakeGenerator: ThumbnailGenerating {
    var started: [URL] = []
    var cancelled: [URL] = []
    private var pending: [ThumbnailTicket: (URL, @MainActor (CGImage?) -> Void)] = [:]
    private var next: UInt64 = 0
    func generate(url: URL, pointSize: CGFloat, scale: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> ThumbnailTicket {
        next += 1; let t = ThumbnailTicket(raw: next); pending[t] = (url, completion); started.append(url); return t
    }
    func cancel(_ ticket: ThumbnailTicket) { if let (u, _) = pending.removeValue(forKey: ticket) { cancelled.append(u) } }
    func complete(_ url: URL, image: CGImage?) {
        guard let (t, (_, c)) = pending.first(where: { $0.value.0 == url }) else { return }
        pending[t] = nil; c(image)
    }
}

@MainActor
final class ThumbnailSchedulerTests: XCTestCase {
    let gen = FakeGenerator()
    var cache = ThumbnailCache()
    lazy var scheduler = ThumbnailScheduler(generator: gen, cache: cache, maxInFlight: 8)
    func cand(_ i: Int, mtime: Int64 = 1) -> ThumbnailCandidate {
        ThumbnailCandidate(key: ThumbnailKey(volume: .unknown, id: .object(UInt64(i)), directory: "/d", mtime: mtime, size: 10, pixels: 128),
                           url: URL(filePath: "/d/\(i).png"))
    }
    func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testVisibleOnlyAndMaxInFlight() {
        scheduler.updateVisible((0..<20).map { cand($0) }, pointSize: 64, scale: 2)
        XCTAssertEqual(gen.started.count, 8)
        XCTAssertEqual(gen.started.first?.lastPathComponent, "0.png")
    }

    func testScrollOffCancelsAndStartsNewlyVisible() {
        scheduler.updateVisible((0..<8).map { cand($0) }, pointSize: 64, scale: 2)
        scheduler.updateVisible((8..<16).map { cand($0) }, pointSize: 64, scale: 2)
        XCTAssertEqual(Set(gen.cancelled.map(\.lastPathComponent)), Set((0..<8).map { "\($0).png" }))
        XCTAssertEqual(gen.started.count, 16)
    }

    func testCompletionCachesNotifiesAndPumpsNext() {
        var notified: [ThumbnailKey] = []
        scheduler.onThumbnail = { notified.append($0) }
        scheduler.updateVisible((0..<9).map { cand($0) }, pointSize: 64, scale: 2)
        gen.complete(URL(filePath: "/d/0.png"), image: image())
        XCTAssertEqual(notified, [cand(0).key])
        XCTAssertNotNil(cache.image(cand(0).key))
        XCTAssertEqual(gen.started.count, 9, "slot freed → the 9th starts")
    }

    func testFailureIsNotRetriedAndCacheHitSkipsRequest() {
        scheduler.updateVisible([cand(0)], pointSize: 64, scale: 2)
        gen.complete(URL(filePath: "/d/0.png"), image: nil)
        scheduler.updateVisible([cand(0)], pointSize: 64, scale: 2)
        XCTAssertEqual(gen.started.count, 1)
        cache.store(image(), for: cand(1).key)
        scheduler.updateVisible([cand(1)], pointSize: 64, scale: 2)
        XCTAssertEqual(gen.started.count, 1)
        scheduler.updateVisible([cand(1, mtime: 2)], pointSize: 64, scale: 2)
        XCTAssertEqual(gen.started.count, 2, "a changed file is a new key")
    }

    func testEligibility() {
        let types = TypeRegistry.shared
        func e(_ kind: Kind, _ flags: EntryFlags = [], size: Int64 = 10, ext: Substring = "png") -> Entry {
            Entry(rowID: 1, fileID: 1, size: size, allocSize: size, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0, kind: kind, flags: flags,
                  typeIndex: types.index(forExtension: ext, isDirectory: kind == .package || kind == .directory))
        }
        XCTAssertTrue(ThumbnailScheduler.isEligible(e(.file), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.file, [.dataless]), types: types), "never download iCloud content")
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.file, [.degraded]), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.file, size: 0), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.directory, ext: ""), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.package, ext: "app"), types: types))
        XCTAssertTrue(ThumbnailScheduler.isEligible(e(.package, ext: "pages"), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.symlink), types: types))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter UITests.ThumbnailSchedulerTests 2>&1 | tail -5`
Expected: `cannot find type 'ThumbnailGenerating' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/UI/Icons/ThumbnailCache.swift
import AppKit
import Core
import MacxFS

struct ThumbnailKey: Hashable, Sendable {
    var volume: VolumeID; var id: RowID; var directory: String; var mtime: Int64; var size: Int64; var pixels: Int
}
struct ThumbnailCandidate { var key: ThumbnailKey; var url: URL }
struct ThumbnailTicket: Hashable { let raw: UInt64 }

@MainActor
final class ThumbnailCache {
    private final class KeyBox: NSObject {
        let key: ThumbnailKey
        init(_ key: ThumbnailKey) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
    }
    private final class ImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }
    private let cache = NSCache<KeyBox, ImageBox>()
    init(costLimit: Int = 64 << 20) { cache.totalCostLimit = costLimit }
    func image(_ key: ThumbnailKey) -> CGImage? { cache.object(forKey: KeyBox(key))?.image }
    func store(_ image: CGImage, for key: ThumbnailKey) { cache.setObject(ImageBox(image), forKey: KeyBox(key), cost: image.width * image.height * 4) }
}
```

```swift
// Sources/UI/Icons/ThumbnailScheduler.swift
import AppKit
import Core
import MacxFS

@MainActor protocol ThumbnailGenerating: AnyObject {
    func generate(url: URL, pointSize: CGFloat, scale: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> ThumbnailTicket
    func cancel(_ ticket: ThumbnailTicket)
}

@MainActor
final class ThumbnailScheduler {
    private let generator: any ThumbnailGenerating
    private let cache: ThumbnailCache
    private let maxInFlight: Int
    private(set) var inFlight: Set<ThumbnailKey> = []
    private var tickets: [ThumbnailKey: ThumbnailTicket] = [:]
    private var failed: Set<ThumbnailKey> = []
    private var wanted: [ThumbnailCandidate] = []
    private var pointSize: CGFloat = 64
    private var scale: CGFloat = 2
    var onThumbnail: ((ThumbnailKey) -> Void)?

    init(generator: any ThumbnailGenerating, cache: ThumbnailCache, maxInFlight: Int = 8) {
        self.generator = generator; self.cache = cache; self.maxInFlight = maxInFlight
    }

    static func isEligible(_ e: Entry, types: TypeRegistry) -> Bool {
        guard !e.flags.contains(.dataless), !e.flags.contains(.degraded) else { return false }
        switch e.kind {
        case .file: return e.size > 0
        case .package: return !types.isApplication(e.typeIndex)
        case .directory, .symlink, .alias, .other: return false
        }
    }

    func updateVisible(_ candidates: [ThumbnailCandidate], pointSize: CGFloat, scale: CGFloat) {
        self.pointSize = pointSize; self.scale = scale
        wanted = candidates
        let keep = Set(candidates.map(\.key))
        for key in inFlight where !keep.contains(key) {
            if let t = tickets.removeValue(forKey: key) { generator.cancel(t) }
            inFlight.remove(key)
        }
        pump()
    }

    func cancelAll() {
        for t in tickets.values { generator.cancel(t) }
        tickets.removeAll(); inFlight.removeAll(); wanted.removeAll()
    }

    private func pump() {
        for c in wanted where inFlight.count < maxInFlight {
            guard !inFlight.contains(c.key), !failed.contains(c.key), cache.image(c.key) == nil else { continue }
            inFlight.insert(c.key)
            let key = c.key
            tickets[key] = generator.generate(url: c.url, pointSize: pointSize, scale: scale) { [weak self] image in
                self?.finish(key, image)
            }
        }
    }

    private func finish(_ key: ThumbnailKey, _ image: CGImage?) {
        guard inFlight.remove(key) != nil else { return }   // cancelled meanwhile
        tickets[key] = nil
        if let image { cache.store(image, for: key); onThumbnail?(key) } else { failed.insert(key) }
        pump()
    }
}
```

```swift
// Sources/UI/Icons/QLThumbnailGeneratorAdapter.swift
import AppKit
import QuickLookThumbnailing
import MacxFS

@MainActor
final class QLThumbnailGeneratorAdapter: ThumbnailGenerating {
    private var requests: [ThumbnailTicket: QLThumbnailGenerator.Request] = [:]
    private var next: UInt64 = 0

    func generate(url: URL, pointSize: CGFloat, scale: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> ThumbnailTicket {
        next += 1
        let ticket = ThumbnailTicket(raw: next)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pointSize, height: pointSize),
                                                   scale: scale, representationTypes: .thumbnail)
        requests[ticket] = request
        let state = PerfSignposts.signposter.beginInterval(PerfSignposts.thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.cgImage
            Task { @MainActor [weak self] in
                PerfSignposts.signposter.endInterval(PerfSignposts.thumbnail, state)
                guard let self, self.requests.removeValue(forKey: ticket) != nil else { return }   // cancelled
                completion(image)
            }
        }
        return ticket
    }

    func cancel(_ ticket: ThumbnailTicket) {
        if let request = requests.removeValue(forKey: ticket) { QLThumbnailGenerator.shared.cancel(request) }
    }
}
```
If the SDK does not treat `CGImage` (or the signpost state) as Sendable when it crosses into the `Task`, wrap it in a file-private `struct SendableImage: @unchecked Sendable { let image: CGImage? }`. Add the header comment "CGImage is immutable; handed once from the QL callback to the main actor". UI is allowed this per the Global Constraints.

In `IconsViewController`:
- own `scheduler = ThumbnailScheduler(generator: QLThumbnailGeneratorAdapter(), cache: context.thumbnails)`;
- on bind, bounds change (coalesced), icon-size change and `.changes`, compute candidates from `layout.indexes(in: visibleRect)` for eligible entries, then call `updateVisible(candidates, pointSize: iconSize.points, scale: window?.backingScaleFactor ?? 2)`. This happens only when `settings.showThumbnails` is on; otherwise call `scheduler.cancelAll()`;
- on unbind, call `cancelAll()`;
- `onThumbnail(key)` finds the item by `folder.row(of: key.id)` and reconfigures only that item;
- `IconItem` shows `context.thumbnails.image(key)` when present, aspect-fit inside the icon square with a 1 pt separator-colour border, and otherwise the Phase 1 tier icon. Cut items keep the 50% dim plus italic name.

Scenario hook `thumbnailNames`: the names of visible items whose cell currently shows a cached thumbnail.

- [ ] **Step 4: Add the scenario**

```json
// Tests/Scenarios/p2-thumbnails.json
{"name": "p2-thumbnails",
 "fixture": {"files": ["t.txt"], "dirs": ["sub"], "images": ["p1.png", "p2.png"]},
 "steps": [
  {"key": "cmd+2"},
  {"waitFor": {"viewMode": "icons", "thumbnailsContain": ["p1.png", "p2.png"]}, "timeoutMs": 5000},
  {"expect": {"rows": ["sub", "p1.png", "p2.png", "t.txt"]}}
 ]}
```

- [ ] **Step 5: Run the tests and the scenario**

Run: `swift test --filter UITests.ThumbnailSchedulerTests 2>&1 | tail -5 && scripts/ui-scenarios.sh p2-thumbnails 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`; `p2-thumbnails: passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/UI Sources/FSKit/Support/PerfSignposts.swift Tests/UITests/ThumbnailSchedulerTests.swift Tests/Scenarios/p2-thumbnails.json
git commit -m "feat: Quick Look thumbnails for visible items in Icons view with cancellation and cache"
```

---

### Task P2-18: Columns view model: column chain and session columns mode

**Files:**
- Create: `Sources/UI/Columns/ColumnChain.swift`, `Tests/UITests/ColumnChainTests.swift`
- Modify: `Sources/UI/Window/BrowserSession.swift` (columns mode, `columnChain`, `SessionEvent.columnsChanged`)

**Interfaces:**
- Consumes: `FolderModel` (`start`, `close`, `select`, `selection`, `rowCount`, `entry(atRow:)`, `url(atRow:)`, `observe`), `CoreEnvironment.makeFolderModel`, and `BrowserSession` (P2-08: `viewState`, `setDisplayedMode`, `navigate`).
- Produces: §2.3 `ColumnChain`; `BrowserSession.columnChain: ColumnChain?`; `SessionEvent.columnsChanged`.

Rules:
- Column 0 is the column root: the folder the window navigated to (address bar, sidebar, tree, back/forward, open from another view). Explicit navigation in columns mode calls `reroot` and records history. Moving between columns does not record history.
- Selecting exactly one `.directory` row in column k opens its contents as column k+1, closing columns after k first. If that column already shows the same folder, it is kept. Any other selection (a file, several items, or none) closes the columns after k. Packages, aliases and symlinks never open columns; Return opens them as in Phase 1.
- `moveRight()` activates column k+1 when it exists, selecting its first row if it has no selection, which may open the next column. `moveLeft()` activates column k−1 and leaves its selection as it is. `up()` activates k−1 when k > 0. At the root it calls `reroot(parent, selecting: oldRootName)`.
- In columns mode, `BrowserSession.folder` is the active column's model, which the chain owns. The address bar, status bar, search filter (cleared on activation change), commands, Quick Look and the paste target all follow it.
- The per-folder view state (`locator`/`viewState`) belongs to the column root, and every column uses the root's sort. Switching from Columns to another mode retargets the state to the active column's folder, then shows that folder in the new mode and saves the new mode for it. This is Finder's behaviour: list view of the deepest active folder.
- Each column model has its own content watcher. In Columns view every column is a visible folder, so this is the per-window "visible folder" stream of §4.3 applied per visible column.
- Closing a column model cancels its read and stops its watcher (Phase 1 `close()`). Late batches can never reach the remaining columns (Review Focus 5).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/ColumnChainTests.swift
import XCTest
import Synchronization
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

final class WatchCounter: Sendable { let started = Mutex(0); let stopped = Mutex(0) }
final class CountingWatcher: ContentWatching {
    let counter: WatchCounter
    init(_ c: WatchCounter) { counter = c }
    func start() { counter.started.withLock { $0 += 1 } }
    func stop() { counter.stopped.withLock { $0 += 1 } }
    var lastEventID: UInt64 { 0 }
}

@MainActor
final class ColumnChainTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    let counter = WatchCounter()
    var created: [FolderModel] = []

    override func setUp() async throws {
        sandbox = try Sandbox(); addTeardownBlock { [sandbox] in sandbox?.destroy() }
        try sandbox.write("A/B/c.txt", bytes: 1); try sandbox.write("A/x.txt", bytes: 1); try sandbox.write("r.txt", bytes: 1)
        env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
    }
    func factory() -> ColumnChain.ModelFactory {
        { [unowned self] url in
            var ctx = env.folderContext()
            ctx.makeWatcher = { [counter] _, _, _ in CountingWatcher(counter) }
            let m = FolderModel(directory: url, context: ctx, query: ViewQuery())
            created.append(m)
            return m
        }
    }
    func settle(_ chain: ColumnChain, _ timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while chain.models.contains(where: { $0.state != .complete }) && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }
    func names(_ chain: ColumnChain) -> [String] { chain.models.map { $0.directory.standardizedFileURL.lastPathComponent } }

    func testSingleFolderSelectionOpensChildAndFileTruncates() async {
        let chain = ColumnChain(root: sandbox.root, makeModel: factory())
        await settle(chain)
        chain.models[0].select(.names(["A"]))
        XCTAssertEqual(names(chain), [sandbox.root.lastPathComponent, "A"])
        await settle(chain)
        chain.models[1].select(.names(["B"]))
        XCTAssertEqual(names(chain).suffix(2), ["A", "B"])
        chain.models[1].select(.names(["x.txt"]))
        XCTAssertEqual(names(chain).count, 2, "file selection closes deeper columns")
        chain.models[0].select(.names(["A", "r.txt"]))
        XCTAssertEqual(chain.models.count, 1, "multi-selection closes deeper columns")
    }

    func testMoveRightLeftAndUp() async {
        let chain = ColumnChain(root: sandbox.url("A"), makeModel: factory())
        await settle(chain)
        chain.models[0].select(.names(["B"]))
        await settle(chain)
        XCTAssertTrue(chain.moveRight())
        XCTAssertEqual(chain.activeIndex, 1)
        XCTAssertEqual(chain.activeModel.selectedURLs.map(\.lastPathComponent), ["c.txt"], "first row selected on entry")
        XCTAssertFalse(chain.moveRight(), "a file opens no further column")
        XCTAssertTrue(chain.moveLeft())
        XCTAssertEqual(chain.activeIndex, 0)
        chain.up()
        await settle(chain)
        XCTAssertEqual(chain.models[0].directory.standardizedFileURL, sandbox.root.standardizedFileURL)
        XCTAssertEqual(chain.models[0].selectedURLs.map(\.lastPathComponent), ["A"])
        XCTAssertEqual(names(chain).last, "A", "old root reopens as column 1")
    }

    func testDetachActiveClosesOthersAndKeepsActive() async {
        let chain = ColumnChain(root: sandbox.root, makeModel: factory())
        await settle(chain)
        chain.models[0].select(.names(["A"]))
        await settle(chain)
        chain.moveRight()
        let active = chain.activeModel
        let kept = chain.detachActive()
        XCTAssertTrue(kept === active)
        XCTAssertTrue(chain.models.isEmpty)
    }

    // Review Focus 5
    func testRapidSelectionInColumnClosesIntermediateModels() async throws {
        for i in 0..<50 { try sandbox.mkdir(String(format: "many/d%02d", i)) }
        let chain = ColumnChain(root: sandbox.url("many"), makeModel: factory())
        await settle(chain)
        for row in 0..<50 { chain.models[0].select(.set(IndexSet(integer: row), cursor: row)) }   // held ↓
        XCTAssertEqual(chain.models.count, 2)
        XCTAssertEqual(names(chain).last, "d49")
        XCTAssertEqual(created.count, 51, "root + one model per visited folder")
        await settle(chain)
        try await Task.sleep(for: .milliseconds(300))           // let any late batches arrive
        XCTAssertEqual(chain.models[0].selectedURLs.map(\.lastPathComponent), ["d49"], "active column untouched")
        XCTAssertEqual(chain.models.count, 2)
        let live = counter.started.withLock { $0 } - counter.stopped.withLock { $0 }
        XCTAssertEqual(live, 2, "only the two visible columns still watch")
    }
}
```

`BrowserSession` columns-mode tests go in the same file:
```swift
extension ColumnChainTests {
    func testSessionColumnsModeAdoptsAndDetachesTheModel() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        let original = session.folder
        session.updateViewState { $0.mode = .columns }
        XCTAssertTrue(session.columnChain?.models.first === original, "entering columns re-reads nothing")
        let end = Date().addingTimeInterval(3)
        while session.folder.state != .complete && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        session.columnChain!.models[0].select(.names(["A"]))
        while session.columnChain!.models.count < 2 && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        session.columnChain!.moveRight()
        XCTAssertEqual(session.folder.directory.lastPathComponent, "A", "session follows the active column")
        session.updateViewState { $0.mode = .details }
        XCTAssertNil(session.columnChain)
        XCTAssertEqual(session.folder.directory.lastPathComponent, "A")
        XCTAssertEqual(session.viewMode, .details)
        session.navigate(to: sandbox.root)
        XCTAssertEqual(session.viewMode, .columns, "the root still remembers Columns")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter UITests.ColumnChainTests 2>&1 | tail -5`
Expected: `cannot find 'ColumnChain' in scope`.

- [ ] **Step 3: Implement `ColumnChain`**

```swift
// Sources/UI/Columns/ColumnChain.swift
import Foundation
import Core
import MacxFS

@MainActor
final class ColumnChain {
    typealias ModelFactory = @MainActor (URL) -> FolderModel
    private let makeModel: ModelFactory
    private(set) var models: [FolderModel] = []
    private(set) var activeIndex = 0
    private var tokens: [ObjectIdentifier: ObserverToken] = [:]
    var onChange: (() -> Void)?

    init(root: URL, makeModel: @escaping ModelFactory) {
        self.makeModel = makeModel
        reroot(root, selecting: nil)
    }

    init(adopting model: FolderModel, makeModel: @escaping ModelFactory) {
        self.makeModel = makeModel
        append(model, start: false)
        selectionDidChange(in: model)
    }

    var activeModel: FolderModel { models[activeIndex] }

    func reroot(_ url: URL, selecting name: String?) {
        truncate(after: -1)
        let m = makeModel(url)
        append(m, start: true)
        activeIndex = 0
        if let name { m.select(.names([name])) }   // Phase 1 applies name selection once the row is present
        onChange?()
    }

    func activate(_ index: Int) {
        guard !models.isEmpty else { return }
        activeIndex = max(0, min(index, models.count - 1))
        onChange?()
    }

    @discardableResult func moveRight() -> Bool {
        guard activeIndex + 1 < models.count else { return false }
        activeIndex += 1
        let m = models[activeIndex]
        if m.selection.isEmpty, m.rowCount > 0 { m.select(.set(IndexSet(integer: 0), cursor: 0)) }
        onChange?()
        return true
    }

    @discardableResult func moveLeft() -> Bool {
        guard activeIndex > 0 else { return false }
        activeIndex -= 1
        onChange?()
        return true
    }

    func up() {
        if activeIndex > 0 { _ = moveLeft(); return }
        let root = models[0].directory.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        guard parent.path(percentEncoded: false) != root.path(percentEncoded: false) else { return }   // already at "/"
        reroot(parent, selecting: root.lastPathComponent)
    }

    func detachActive() -> FolderModel {
        let keep = activeModel
        for m in models where m !== keep { tokens[ObjectIdentifier(m)]?.cancel(); m.close() }
        tokens[ObjectIdentifier(keep)]?.cancel()
        tokens.removeAll(); models.removeAll(); activeIndex = 0
        return keep
    }

    func close() { truncate(after: -1) }

    // MARK: private

    private func append(_ m: FolderModel, start: Bool) {
        models.append(m)
        tokens[ObjectIdentifier(m)] = m.observe { [weak self, weak m] event in
            guard let self, let m, case .selection = event else { return }
            self.selectionDidChange(in: m)
        }
        if start { m.start() }
    }

    private func selectionDidChange(in model: FolderModel) {
        guard let index = models.firstIndex(where: { $0 === model }) else { return }
        let child = singleFolder(model)
        if let child, index + 1 < models.count,
           models[index + 1].directory.standardizedFileURL == child.standardizedFileURL {
            return                                    // same child column: keep it (and its scroll/selection)
        }
        truncate(after: index)
        if let child { append(makeModel(child), start: true) }
        onChange?()
    }

    private func singleFolder(_ m: FolderModel) -> URL? {
        guard m.selection.count == 1, let row = m.selection.rows.first, row < m.rowCount,
              m.entry(atRow: row).kind == .directory else { return nil }
        return m.url(atRow: row)
    }

    private func truncate(after index: Int) {
        while models.count > max(index + 1, 0) {
            let m = models.removeLast()
            tokens.removeValue(forKey: ObjectIdentifier(m))?.cancel()
            m.close()
        }
        if activeIndex >= models.count { activeIndex = max(0, models.count - 1) }
    }
}
```

- [ ] **Step 4: Implement the session columns mode**

In `BrowserSession`:
```swift
private(set) var columnChain: ColumnChain?

private func setDisplayedMode(_ mode: ViewMode) {
    let old = viewMode
    guard mode != old else { return }
    if mode == .columns {
        let chain = ColumnChain(adopting: folder) { [unowned self] url in
            self.environment.makeFolderModel(url, query: ViewQuery(sort: self.viewState.sort, showHidden: self.environment.settings.showHidden))
        }
        chain.onChange = { [weak self] in self?.columnChainChanged() }
        columnChain = chain
    } else if old == .columns, let chain = columnChain {
        folder = chain.detachActive()
        columnChain = nil
        retargetViewState(to: folder.directory)   // locator + viewState of the active folder; `mode` is saved for it by the caller
        emit(.folderChanged(folder))
    }
    viewMode = mode
    folder.setGrouping(mode == .details ? viewState.groupBy : .none)
    emit(.viewModeChanged(mode))
}

private func columnChainChanged() {
    guard let chain = columnChain, !chain.models.isEmpty else { return }
    if chain.activeModel !== folder {
        folder = chain.activeModel                 // borrowed: the chain owns and closes it
        emit(.folderChanged(folder))
    }
    emit(.columnsChanged)
}
```
- **Ownership:** while `columnChain != nil`, the session never closes `folder` itself, because the chain owns it.
- **`navigate(to:selecting:recordHistory:folderID:)` in columns mode:**
  1. Look up the state for `url`.
  2. If its mode is `.columns`, call `columnChain.reroot(url, selecting: name)` and set `folder = chain.activeModel`.
  3. Otherwise, call `chain.close()`, set `columnChain = nil`, and fall through to the Phase 1 path with the new mode.
- **`updateViewState` in columns mode:**
  - when the mutation changes `mode` away from `.columns`, call `setDisplayedMode` first (which retargets to the active folder), then save the new state for the retargeted locator;
  - sort changes apply `setQuery` to every `chain.models`;
  - grouping is never applied in columns mode.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter UITests.ColumnChainTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/UI/Columns/ColumnChain.swift Sources/UI/Window/BrowserSession.swift Tests/UITests/ColumnChainTests.swift
git commit -m "feat: column chain model for the Columns view with session integration"
```

---

### Task P2-19: Columns (Miller) view UI

**Files:**
- Create: `Sources/UI/Columns/ColumnsViewController.swift`, `Sources/UI/Columns/BrowserColumnController.swift`, `Sources/UI/Columns/ColumnCellView.swift`, `Tests/UITests/ColumnsViewTests.swift`, `Tests/Scenarios/p2-columns.json`
- Modify: `Sources/UI/Content/ContentViewController.swift` (`setViewMode(.columns)`, no double-forwarding), `Sources/UI/Toolbar/ToolbarController.swift` (third segment "Columns", SF Symbol `rectangle.split.3x1`, accessibility label "Columns"), `Sources/UI/Commands/FileCommandController.swift` (open/up in columns), `Sources/UI/CommandBar/CommandBarView.swift` (View ▾ › Columns)

**Interfaces:**
- Consumes: `ColumnChain`, `BrowserSession.columnChain`, `SessionEvent.columnsChanged` (P2-18), `FileListView`, `SelectionController`, `TypeSelect`, `KeyRouter`, `InlineRenameController`, `DragSource`/`DropTarget`/`RightDragTracker`, `ContextMenuBuilder`, `IconCache`, `Settings.columnWidth/density`.
- Produces: `ColumnsViewController` (§2.3), `BrowserColumnController: NSViewController, FileListView` (`init(context:model:index:)`, `tableView`), `ColumnCellView`, AXIDs `columnsView` and `column(i)`, and the scenario hook `columnsChain`.

UI rules:
- **Layout:** a horizontal `NSScrollView` whose document view is a horizontal `NSStackView` (spacing 0) of column views. Each column is an `NSScrollView` + single-column view-based `NSTableView` with no header, fixed row height (Density) and alternating rows off. The cell is `ColumnCellView`: a 16 pt Tier 0/1 icon, the name (middle truncation) and a trailing `chevron.right` for directories. Cut rows are dimmed and italic, as in Phase 1.
- **Width:** each column has `Settings.columnWidth` (default 220 pt). A 6 pt resize handle at each column's trailing edge (`NSCursor.resizeLeftRight`) resizes that column, and the last width is saved to `Settings.columnWidth`. Double-click on the handle auto-fits to the widest name among the column's first 2,000 rows (measured with the cell font), clamped to 120…600 pt.
- **Mouse:**
  - A click in column k calls `chain.activate(k)` and goes through `SelectionController` against that column's model (identity mapping), so selection semantics (⌘/⇧-click, ⇧-arrows) are Phase 1's.
  - Double-click on a folder calls `chain.moveRight()` (the child column is already open). Double-click on anything else uses the Phase 1 open path.
  - Middle-click on a folder row opens a tab (P2-06).
- **Keyboard** (active column):
  - ↑/↓ and type-select work within the column; →/← call `moveRight`/`moveLeft`.
  - Return/⌘↓ on the single selected folder calls `moveRight()`; on a file it is the Phase 1 open.
  - ⌘↑ calls `chain.up()`.
  - Every other alternate and primary goes through `KeyRouter` and the menu exactly as in Details.
- **Commands:** every command targets the active column's model (`session.folder`): paste into, new folder (inline rename in that column), rename, trash, Quick Look, Copy Path As. Context menus use the clicked column's model. Drag sources are rows of any column. Drop targets are folder rows (into) or a column's empty area (that column's folder), with `DropPolicy` and spring-loading as in Phase 1.
- **Scrolling:** after each `.columnsChanged`, the stack scrolls horizontally so the active column and the one after it are visible. Each column keeps its own vertical scroll position.
- **Updates:** each `BrowserColumnController` observes its own model (`.changes`, `.selection`, `.state`) and applies changes like Details. `ContentViewController` therefore skips forwarding `.changes` to `activeList` in columns mode. Empty and error states (Phase 1 `EmptyStateView`) appear inside the column that has them.
- **Accessibility:** each table's accessibility label is the folder's display name, and its AXID is `column(i)`. The container's AXID is `columnsView`.
- **Not in Columns view:** Group by and Calculate Folder Sizes are disabled here (`CommandState.viewMode`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/ColumnsViewTests.swift
import XCTest
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class ColumnsViewTests: XCTestCase {
    func makeContext(_ sandbox: Sandbox) throws -> UIContext {
        try sandbox.mkdir("state")
        let options = try LaunchOptions.parse(["macExplorer", "--root", sandbox.root.path(percentEncoded: false),
                                               "--state-dir", sandbox.url("state").path(percentEncoded: false)])
        return UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root), options: options)
    }

    func testOneTablePerColumnAndActiveListForwarding() async throws {
        try requireGUISession()
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.write("A/B/c.txt", bytes: 1)
        let context = try makeContext(sandbox)
        let controller = ColumnsViewController(context: context)
        _ = controller.view
        let chain = ColumnChain(root: sandbox.root) { url in context.environment.makeFolderModel(url) }
        controller.bindChain(chain)
        let end = Date().addingTimeInterval(3)
        while chain.models[0].state != .complete && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        chain.models[0].select(.names(["A"]))
        XCTAssertEqual(controller.columnControllers.count, 2)
        XCTAssertTrue(controller.folder === chain.activeModel)
        chain.moveRight()
        XCTAssertTrue(controller.folder === chain.models[1])
        XCTAssertEqual(controller.columnControllers[1].tableView.accessibilityIdentifier(), AXID.column(1))
    }

    func testKeyboardRightLeftUp() async throws {
        try requireGUISession()
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.write("A/B/c.txt", bytes: 1); try sandbox.write("A/x.txt", bytes: 1)
        let context = try makeContext(sandbox)
        let controller = ColumnsViewController(context: context)
        _ = controller.view
        let chain = ColumnChain(root: sandbox.url("A")) { url in context.environment.makeFolderModel(url) }
        controller.bindChain(chain)
        let end = Date().addingTimeInterval(3)
        while chain.models[0].state != .complete && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        chain.models[0].select(.names(["B"]))
        while chain.models.count < 2 || chain.models[1].state != .complete { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.handleColumnKey(KeyChord(.right)))
        XCTAssertEqual(chain.activeIndex, 1)
        XCTAssertTrue(controller.handleColumnKey(KeyChord(.left)))
        XCTAssertEqual(chain.activeIndex, 0)
        XCTAssertTrue(controller.handleColumnKey(KeyChord(.returnKey)))   // Return on the selected folder → into it
        XCTAssertEqual(chain.activeIndex, 1)
    }
}
```
`handleColumnKey(_:) -> Bool` is the controller's internal key entry point, which the column tables' `keyDown` call after `KeyRouter`. `columnControllers` is the ordered list of `BrowserColumnController`s.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter UITests.ColumnsViewTests 2>&1 | tail -5`
Expected: `cannot find 'ColumnsViewController' in scope`.

- [ ] **Step 3: Implement**

`ColumnsViewController` sketch, with names exactly as listed in Produces:
```swift
@MainActor
final class ColumnsViewController: NSViewController, FileListView {
    private let context: UIContext
    private(set) var columnControllers: [BrowserColumnController] = []
    private weak var chain: ColumnChain?
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    init(context: UIContext) { self.context = context; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        stack.orientation = .horizontal; stack.spacing = 0; stack.alignment = .top
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.documentView = stack
        scroll.setAccessibilityIdentifier(AXID.columnsView)
        view = scroll
    }

    func bindChain(_ chain: ColumnChain?) {
        self.chain = chain
        rebuild()
    }

    /// Called by BrowserSession's .columnsChanged and by bind: diff columnControllers against chain.models by identity.
    func rebuild() {
        let models = chain?.models ?? []
        // keep controllers whose model is still at the same index; drop the rest; append new ones
        var kept: [BrowserColumnController] = []
        for (i, m) in models.enumerated() {
            if i < columnControllers.count, columnControllers[i].model === m { kept.append(columnControllers[i]) }
            else { kept.append(BrowserColumnController(context: context, model: m, index: i, owner: self)) }
        }
        for c in columnControllers where !kept.contains(where: { $0 === c }) { c.unbind(); stack.removeArrangedSubview(c.view); c.view.removeFromSuperview() }
        for c in kept where c.view.superview == nil { stack.addArrangedSubview(c.view) }
        columnControllers = kept
        scrollActiveIntoView()
    }

    func handleColumnKey(_ chord: KeyChord) -> Bool {
        guard let chain, chord.modifiers.isEmpty || chord.modifiers == [.command] else { return false }
        switch (chord.key, chord.modifiers) {
        case (.right, []): return chain.moveRight()
        case (.left, []): return chain.moveLeft()
        case (.up, [.command]): chain.up(); return true
        case (.returnKey, []), (.down, [.command]):
            guard let child = chain.models.indices.contains(chain.activeIndex + 1) ? chain.models[chain.activeIndex + 1] : nil,
                  chain.activeModel.selectedURLs.first?.standardizedFileURL == child.directory.standardizedFileURL else { return false }
            return chain.moveRight()
        default: return false
        }
    }

    // FileListView: forward to the active column
    var folder: FolderModel? { chain?.activeModel }
    private var active: BrowserColumnController? { chain.flatMap { c in columnControllers.indices.contains(c.activeIndex) ? columnControllers[c.activeIndex] : nil } }
    func bind(_ folder: FolderModel?) { }                 // columns bind through bindChain
    func apply(_ changes: ChangeSet) { }                  // columns observe their own models
    func reloadSelectionDrawing() { active?.reloadSelectionDrawing() }
    func beginInlineRename(row: Int) { active?.beginInlineRename(row: row) }
    func scrollToRow(_ row: Int) { active?.scrollToRow(row) }
    func topVisibleRow() -> Int? { active?.topVisibleRow() }
    func visibleRows() -> Range<Int> { active?.visibleRows() ?? 0..<0 }
}
```
`handleColumnKey` returns false for Return when the selection is not the open child folder, which lets Phase 1 open files. `BrowserColumnController` mirrors `DetailsViewController`'s single-column paths: data source, `NameCellView` replaced by `ColumnCellView`, `SelectionController` with `.identity` mapping, `TypeSelect`, `InlineRenameController`, drag/drop, right-drag, context menu and empty state. Its `mouseDown` calls `owner.chain?.activate(index)` first. Its table's `keyDown` order is: `KeyRouter.handle` (alternates), then `owner.handleColumnKey`, then the Phase 1 selection keys.

`ContentViewController.setViewMode(.columns)` installs the columns controller as `activeList` and calls `bindChain(session.columnChain)`. It calls `rebuild()` on `.columnsChanged`, and, while in columns mode, it does not forward `.changes`.

Scenario hook `columnsChain`: `(chain.models.map(\.directory), chain.activeIndex)`. Plain-name click targets resolve in the active column.

- [ ] **Step 4: Add the scenario**

```json
// Tests/Scenarios/p2-columns.json
{"name": "p2-columns",
 "fixture": {"files": ["A/B/c.txt", "A/x.txt", "r.txt"], "dirs": ["A", "A/B"]},
 "steps": [
  {"key": "cmd+3"},
  {"waitFor": {"viewMode": "columns", "columnsChain": [""], "activeColumn": 0}},
  {"click": "A"},
  {"waitFor": {"columnsChain": ["", "A"], "activeColumn": 0, "folder": ""}},
  {"key": "right"},
  {"waitFor": {"columnsChain": ["", "A", "A/B"], "activeColumn": 1, "folder": "A", "selection": ["B"]}},
  {"key": "down"},
  {"waitFor": {"columnsChain": ["", "A"], "selection": ["x.txt"]}},
  {"key": "up"},
  {"key": "right"},
  {"waitFor": {"activeColumn": 2, "folder": "A/B", "selection": ["c.txt"]}},
  {"key": "F2"},
  {"type": "renamed"},
  {"key": "return"},
  {"waitFor": {"rows": ["renamed.txt"], "filesExist": ["A/B/renamed.txt"]}},
  {"key": "cmd+up"},
  {"waitFor": {"activeColumn": 1, "folder": "A"}},
  {"key": "cmd+1"},
  {"waitFor": {"viewMode": "details", "folder": "A", "rows": ["B", "x.txt"]}},
  {"key": "cmd+["},
  {"waitFor": {"folder": "", "viewMode": "columns"}}
 ]}
```
(F2 selects the base name only, so typing replaces "c" and the extension is kept. That is the Phase 1 inline-rename rule. `cmd+[` goes back to the last explicit location, the root, which still remembers Columns.)

- [ ] **Step 5: Run the tests and scenarios**

Run: `swift test --filter "UITests.ColumnsViewTests|UITests.ColumnChainTests" 2>&1 | tail -5 && scripts/ui-scenarios.sh 2>&1 | tail -3`
Expected: `Executed 7 tests, with 0 failures`; all scenarios pass, including `p2-columns`.

- [ ] **Step 6: Manual check of the columns view feel (sandbox only)**

Launch the scenarios bundle with `--root` set to a fresh `macx-scenario-<UUID>` directory, using the P2-06 Step 6 command, after `scripts/make-fixtures.sh` has populated a 10k-entry subfolder inside it (`make-fixtures.sh` prints its own `macx-fixtures-<UUID>` path; pass that as `--root` instead).
Expected:
- ⌘3 shows columns;
- holding ↓ in a column of 10k items scrolls smoothly, with no beachball and no hang over 100 ms (check with `log stream --predicate 'subsystem == "com.macexplorer.app"'` signposts or Instruments › Hangs);
- resizing a column with the handle works, and double-clicking the handle auto-fits.

Quit, and delete only the directory you created.

- [ ] **Step 7: Commit**

```bash
git add Sources/UI Tests/UITests/ColumnsViewTests.swift Tests/Scenarios/p2-columns.json
git commit -m "feat: Columns (Miller) view built on per-column NSTableViews"
```

---

### Task P2-20: Benchmarks, layering, docs and Phase 2 verification

**Files:**
- Modify: `Sources/macx-bench/Metrics.swift`, `Sources/macx-bench/Budgets.swift`, `scripts/check-layering.sh`, `README.md`, `.github/workflows/ci.yml` (nothing new beyond running the new tests, which `swift test` already includes; verify only)

**Interfaces:**
- Consumes: `Grouping.partition`, `Sorter.permutation(…, extras:)`, `FolderSizeScanner`, `ExtendedAttributeReader`, the P1-39 bench harness (warm-up + 5 iterations, median/p90 JSON, `--check-budgets`, `--compare`).
- Produces: bench metrics `resort-grouped-<groupBy>` (100k), `foldersize-scan-10k` and `extattrs-2k`; the budget `resort-grouped-* < 30 ms`; the layering rule for Quartz/QuickLookThumbnailing; README Phase 2 sections; the Phase 2 "working" verification.

- [ ] **Step 1: Add the bench metrics**

In `Metrics.swift`, using the P1-39 fixture helpers (everything inside the bench's own `macx-bench-<UUID>` directory):
- `resort-grouped-kind|dateModified|size|nameFirstLetter`: on the 100k store already built for `resort`, time `Sorter.permutation(…, query: name asc)` followed by `Grouping.partition(…, by: g, dateBuckets: DateBuckets(now: Date(), calendar: .autoupdatingCurrent))`.
- `foldersize-scan-10k`: build 100 directories × 100 files (1 KB each) and time `LanePool.perform(.scan) { FolderSizeScanner.scan(…) }`.
- `extattrs-2k`: 2,000 files, half with Finder tags written through `Sandbox.setFinderTags`. Time `ExtendedAttributeReader.read(names:…, wanted: .all)` on a read lane.

In `Budgets.swift`, add `resort-grouped-*: 30 ms` (median) under `--check-budgets`. The other two are reported with no budget.

Run:
```bash
swift run -c release macx-bench --filter resort-grouped,foldersize,extattrs 2>&1 | tail -20
```
Expected: JSON with `median_ms` and `p90_ms` for each of the 6 metrics. On Apple Silicon every `resort-grouped-*` median is under 30. If one isn't, profile with `xcrun xctrace record --template 'Time Profiler' --launch -- .build/release/macx-bench --filter resort-grouped-kind` and optimize `Grouping.partition`: cache `GroupKey` per `typeIndex` and per first name byte. Do not raise the budget.

- [ ] **Step 2: Extend the layering check**

Append to `scripts/check-layering.sh`:
```bash
if grep -rnE '^\s*import (Quartz|QuickLookThumbnailing|QuickLook|QuickLookUI)\b' Sources/FSKit Sources/Core | grep -v '^Sources/Core/Platform/'; then
  echo "error: Quick Look frameworks are UI-only (Phase 2 rule)"; exit 1
fi
if grep -rnE 'QLPreviewPanel|QLThumbnailGenerator' Tests --include='*.swift' | grep -v 'Tests/UITests/'; then
  echo "error: Quick Look is exercised only from UITests"; exit 1
fi
```
Run: `scripts/check-layering.sh && echo LAYERING-OK`
Expected: `LAYERING-OK`.

- [ ] **Step 3: Update the README**

Add a "Views & Tabs (Phase 2)" section covering:
- **Tabs:** ⌘T, ⌃Tab/⌃⇧Tab, ⌘W, middle-click / ⌘-click (sidebar and tree) to open in a new tab. Tab-bar drop as decided by the P2-06 spike: the native tab bar, or the "＋" New Tab toolbar button.
- **Per-folder views** and "Apply to All Folders".
- **Group by**, **Quick Look** (Space; Space while type-selecting continues the name), **folder sizes**, **more columns**, **Copy Path As**, **thumbnails**, **Columns view**.

Add these to the release checklist:
- the P2-06 Step 9 tab-restoration check (exact commands);
- Quick Look visual check on images, PDFs and text;
- thumbnails on an external disk and an SMB share (they appear without blocking scrolling);
- iCloud Drive placeholders: no thumbnails, and folder sizes don't download (Activity Monitor › Network shows no `bird` downloads);
- VoiceOver announces group headers as "<title>, <n> items, collapsed/expanded";
- Columns view keyboard pass.

- [ ] **Step 4: Full verification run (Phase 2 "working" definition)**

Run, from a clean tree:
```bash
swift build -c release 2>&1 | tail -3
swift test --parallel 2>&1 | tail -3
scripts/bundle.sh release
scripts/run-scenarios.sh 2>&1 | tail -5
scripts/ui-scenarios.sh 2>&1 | tail -15
swift run -c release macx-bench --check-budgets 2>&1 | tail -25
scripts/check-layering.sh && echo LAYERING-OK
ls -d "${TMPDIR}"macx-tests-* "${TMPDIR}"macx-scenario-* "${TMPDIR}"macx-bench-* 2>/dev/null | wc -l
git status --short
```
Expected:
1. `Build complete!` with zero warnings.
2. `Executed N tests, with 0 failures` (some skips are allowed only for missing GUI or `hdiutil`).
3. `.build/macExplorer.app` exists.
4. Core scenarios: `0 failed`.
5. UI scenarios: every Phase 1 scenario plus the 11 `p2-*` scenarios passed, `0 failed`.
6. The bench JSON has every §4.4 metric it measures within budget, including `resort-grouped-*` (on Apple Silicon).
7. `LAYERING-OK`.
8. `0` leftover sandbox directories. Each runner removes its own and prints that it did.
9. An empty `git status`.

- [ ] **Step 5: Commit**

```bash
git add Sources/macx-bench scripts/check-layering.sh README.md
git commit -m "docs: phase 2 benchmarks, layering rule, README and release checklist"
```

---

## 4. Dependency order

| ID | Deliverable | Depends on |
|---|---|---|
| P2-00 | Phase 1 baseline green | Phase 1 (P1-42) |
| P2-01 | Types, Settings v2 | P2-00 |
| P2-02 | Commands, keys, menus | P2-01 |
| P2-03 | Scenario schema/probes, fixture metadata | P2-02 |
| P2-04 | Copy-path variants | P2-03 |
| P2-05 | Native tabs, dialogs on origin tab | P2-03 |
| P2-06 | Open in new tab gestures, tab-bar drop, restoration check | P2-05 |
| P2-07 | Per-folder view store | P2-01 |
| P2-08 | Per-folder view wiring, Apply to All | P2-07, P2-03 |
| P2-09 | Grouping core + FolderModel grouping | P2-08 |
| P2-10 | Grouped Details UI | P2-09 |
| P2-11 | Quick Look | P2-03 |
| P2-12 | Folder-size scanner, scan lanes | P2-01 |
| P2-13 | Size cache/sessions/invalidation | P2-12 |
| P2-14 | Folder sizes in UI, size sort | P2-13, P2-10 |
| P2-15 | Extended attributes (Core) | P2-12 |
| P2-16 | More columns + sorting | P2-15, P2-14, P2-04 |
| P2-17 | Thumbnails | P2-03 |
| P2-18 | Column chain + session columns mode | P2-08, P2-09 |
| P2-19 | Columns view UI | P2-18, P2-06, P2-11 |
| P2-20 | Bench, layering, docs, verification | all |

## 5. Spec coverage (§11 Phase 2 → tasks)

| Spec item | Tasks |
|---|---|
| Native `NSWindow` tabbing, ⌘T, ⌃Tab, ⌘W | P2-02 (keys/menus), P2-05 |
| Drag a folder onto the tab bar to open it | P2-06 (overlay spike, toolbar fallback) |
| Middle-click a folder (content, sidebar, tree) / ⌘-click in sidebar or tree → new tab; ⌘-click in content keeps toggling | P2-06 |
| Per-folder view state (mode, columns, sort, icon size) keyed by volume UUID + fileID on `idStable`, path elsewhere and as fallback; "Apply to all folders" | P2-07, P2-08 |
| Group by Kind / Date Modified (Today, Yesterday, Earlier this week…) / Size buckets / Name first letter; collapsible floating group rows | P2-09, P2-10 |
| Quick Look: Space toggles `QLPreviewPanel`, arrows move through items | P2-11 |
| "Calculate folder sizes" per folder; cancellable recursive `getattrlistbulk` scan on a lane under the materialization policy; cached by identity (path on non-`idStable`) and mtime; invalidated through the Watcher | P2-12, P2-13, P2-14 |
| More columns: Tags, Date Last Opened, Permissions (rwx), Owner, Path (in search results), Comments | P2-15, P2-16 |
| Copy-path variants: POSIX, `~`-relative, file URL, name only, shell-quoted | P2-04 |
| Thumbnails in Icons view: `QLThumbnailGenerator`, visible non-dataless only, cancelled on scroll-off, `NSCache` keyed by (identity, mtime, size) | P2-17 |
| Columns (Miller) view on our own `NSTableView` columns | P2-18, P2-19 |
| §4.4 budgets kept (re-sort incl. grouping, first paint, hangs) | P2-09 (debug smoke), P2-20 (bench gate) |
| Safety rule: tests and validation touch only their own sandboxes and images | Global Constraints; P2-03 guarded writers and `guardedURL`; P2-20 leftover check |
