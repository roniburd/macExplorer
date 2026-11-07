# macExplorer Phase 3 (Preview & Search) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Preview pane (inspector split item, ⌥P) and full search: scope chips (This folder / Subfolders / This Mac), a Name / Contents toggle, Spotlight (`NSMetadataQuery`) plus our own parallel crawler, kind/date/size/extension filters, Explorer-style query syntax, results in the Details view with a Path column and "Open Containing Folder", and saved searches in a sidebar SEARCHES section (spec §11, Phase 3).

**Architecture:** Pure matching lives in `MacxFS` (`SearchCriteria`, `NamePattern`, `CriteriaMatcher`, wired into `Sorter` through a new `ViewQuery.criteria`), so "This folder" search stays the instant in-memory filter from Phase 1. `Core/Search` owns the query syntax parser, the engine router (`SearchPlanner`), the crawler (`SubtreeCrawler`, directory reads on read lanes under `withNoMaterialization`), the Spotlight adapter (`NSMetadataQuery` confined to its own `OperationQueue`, behind the `MetadataQuerying` protocol so tests use a fake), and the `@MainActor SearchResultsModel`. Both `FolderModel` and `SearchResultsModel` conform to a new `RowSource` protocol, which the Details and Icons views bind to instead of `FolderModel`. `Core/Preview` decides what to preview and loads text, metadata and cloud-download state on lanes. `UI/Preview` hosts `QLPreviewView` or a fast text view in the window's inspector split item.

**Tech Stack:** Swift 6.4 toolchain (Xcode 27.2), Swift 6 language mode, AppKit, QuickLookUI (`QLPreviewView`, UI target only), Foundation (`NSMetadataQuery`, `Process` for `mdutil -s`), CoreServices (`MDItem`), ImageIO, AVFoundation (duration fallback), UniformTypeIdentifiers, Synchronization (`Mutex`), XCTest via `swift test`. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-01-macexplorer-design.md` (§11 "Phase 3 — Preview & Search" is the feature list; §4.2 materialization policy, §4.3 FolderModel, §4.4 main-thread rule, §5.1 inspector slot, §5.2 search field, §5.6 key routing, §9 testing all apply). Phase 1 interface contract: `docs/superpowers/plans/2026-11-01-phase1-00-overview.md` §3 (types extended here by name).

## Prerequisites

- Phase 1 is complete: P1-42's "working" definition holds (`swift build -c release`, `swift test --parallel`, both scenario runners and `macx-bench` pass).
- Phase 2 is complete (`docs/superpowers/plans/2026-11-01-phase2-views-tabs.md`). This plan consumes from Phase 2: `ColumnID.path` and `SortField.path` (P2-01; in folders `.path` orders like `.name`), `SortField.isExtended`, `Settings.schemaVersion == 2`, native tabs (one `BrowserSession` per tab), Quick Look on Space (P2-11), `PathFormatter.tilde(_:home:)` (P2-04) and `LaneClass.scan` (P2-12). If `ColumnID.path`/`SortField.path` are missing when P3-03 starts, P3-03 adds `case path` to both (`ColumnID.path.sortField == .path`, default width 260, hidden by default in folders) and fixes the exhaustive switches the compiler lists.
- Phase 4 (`2026-11-01-phase4-power.md`, sidebar TAGS) looks for `func showResults` in `Sources/UI`; P3-10 provides `BrowserSession.showResults(_ model: SearchResultsModel, recordHistory: Bool)` and P3-06 provides `SearchResultsModel.init(title:events:context:)` for externally built result streams.
- Phase 1 helper names used below are P1-02's real `MacxFixtures` API (S1 plan, P1-02 Interfaces): `let sandbox = try Sandbox()` (prefix `macx-tests`), `sandbox.root`, `sandbox.url(_ relative:)`, `try sandbox.createFile(_ relative:, contents: Data)` (creates parent directories), `try sandbox.createDirectory(_:)`, `try sandbox.createSymlink(_ relative:, target:)`, `try sandbox.setMode(_:_:)`, `try sandbox.setFlags(_:_:)` (e.g. `UInt32(UF_HIDDEN)`), `try sandbox.setDates(_:modified:created:)`, `DiskImage.create(in:format:sizeMB:volumeName:)`, `sandbox.destroy()` in `addTeardownBlock` (it unlocks and removes the tree, detaching images first). Phase 2's `Sandbox.writePNG(_:)` (P2-03 `FixtureMetadata`) and `requireGUISession()` (P2-03 `Tests/UITests/Support/GUI.swift`) are also used.

## Global Constraints

Every constraint in the Phase 1 overview's "Global Constraints" section applies unchanged (platform, Swift 6 strict concurrency, warnings as errors, no `@unchecked Sendable`/`nonisolated(unsafe)` in `MacxFS`/`Core` except one documented confinement per file, layering `App → UI → Core → MacxFS → CFSKit`, AppKit only in `UI`, `App` and `Core/Platform`, `L10n` strings, accessibility labels and identifiers, inclusive language, one commit per task with a conventional prefix, never push). In addition:

**Safety (HARD RULE, applies to tests, benchmarks, scenario runners, scripts and any manual or automated validation):**
- Tests, benchmarks and any manual/automated validation must ONLY create/modify/delete files inside fresh temp directories they create themselves (e.g. `FileManager.default.temporaryDirectory/macx-tests-<UUID>`, `macx-bench-<UUID>`, `macx-scenario-<UUID>`) or disk images they create (inside such a directory, attached with `-mountpoint <that dir>/mnt-<n> -nobrowse`).
- Never touch, move, rename, trash or delete any pre-existing user file. The app may READ the user's real folders when browsing, but automated scenarios must point the app at a sandbox dir (`--root <sandbox> --state-dir <sandbox>/state`).
- Search-specific: automated tests may run **read-only** Spotlight queries against system locations (`/System/Applications`) to prove `NSMetadataQuery` integration; they never write anywhere outside their sandbox. Never run `mdimport`, `mdutil -i`, `mdutil -E`, `mdutil -X` or anything that changes Spotlight index state; the only Spotlight CLI the app or tests may run is `/usr/bin/mdutil -s <mount point>` (status, read-only).
- Preview-specific: automated tests never call `startDownloadingUbiquitousItem` on any real file (use `FakeUbiquitousDownloader`); clicking "Download" on a real iCloud placeholder is a **human-only** release-checklist item, because it changes that file's local state.
- Crawler tests and scenarios crawl only sandbox roots. The crawler is never pointed at `~`, `/` or any real folder by an automated test.

**Phase 3 behaviour constraints (copied from spec §11 and §4.2):**
- Preview pane: "The inspector split item (toggle with ⌥P, like Explorer) shows a `QLPreviewView` of the selection. Text and code use a fast text preview of the first 256 KB." Underneath: "a details summary (size, dates, dimensions or duration from `MDItem`)". "Previews never load from dataless iCloud files unless the user clicks 'Download'."
- Search: scope chips "This folder / Subfolders / This Mac" and a "Name / Contents toggle". "**This Mac** and **Contents** use `NSMetadataQuery`, Spotlight's API, with results streamed in." "**Subfolders, by name** uses our own parallel crawler (`getattrlistbulk` on lanes under the materialization policy, one task per subtree, skipping packages by default)". "Results appear in the Details view with a Path column. 'Open containing folder' is available, and searching is cancellable." Filters: "kind, date modified/created ranges, size ranges, extension". "Saved searches appear in a sidebar SEARCHES section." Syntax: "`name:`, `kind:`, `ext:`, `size:>10MB` and `modified:today`, close to Explorer's Advanced Query Syntax."
- The crawler runs every directory read inside `withNoMaterialization { }` (spec §4.2 lists "the Phase 3 crawler"); preview metadata (`MDItem`, ImageIO) and text/sniff reads also run under it.
- No synchronous file-system call on the main thread (§4.4), including inside `QLPreviewView` setup decisions: the main thread only sets `previewItem` after a lane has confirmed the item exists and is not dataless.
- `NSMetadataQuery` objects never touch the main thread: each lives on its own serial `OperationQueue` (the documented confinement exception in `Core/Search/SystemMetadataQuery.swift`).
- Units: sizes in the query syntax are decimal (`KB` = 1,000 bytes), matching the `ByteCountFormatter.CountStyle.file` sizes the app displays; `KiB`/`MiB`/`GiB`/`TiB` are binary.
- Result cap: at most `SearchResultsModel.resultLimit` = 100,000 results per search; past it the search stops and shows "Showing the first 100,000 results. Refine your search."

**Testing:** XCTest via `swift test`; TDD per task (failing test, implement, green, commit). Every task ends with `swift build 2>&1 | tail -5` showing `Build complete!` with zero warnings and `swift test --filter <TaskTests> 2>&1 | tail -5` showing `Executed N tests, with 0 failures`. Tests that need a GUI session, Spotlight or `hdiutil` check availability and `XCTSkip` with a reason.

## Review Focus

The five inputs the spec implies but no spec-derived test naturally exercises, most likely to bite a user first. Each line names the owning task, which MUST include the listed test.

1. **Explorer wildcard habits: `*.pdf`, `report?.doc`, `IMG_*`.** Expected: a term containing `*` or `?` is a whole-name glob (case- and diacritic-insensitive, `?` = exactly one character even if multi-byte), in every engine (in-folder filter, crawler, Spotlight). Owner P3-01: `testGlobTermsMatchWholeName` and `testQuestionMarkMatchesOneMultibyteCharacter`; P3-05 adds `testGlobTermBecomesLikePatternWithoutExtraStars`.
2. **Typing ⌥P while a text field has focus** (search field, address bar, inline rename: ⌥P types "π" on US layouts). Expected: the character is typed and the preview pane does not toggle (spec §5.6 rule 3). Owner P3-07: `testTogglePreviewPaneCollidesWithTextEditing`; P3-12 adds `testOptionPReachesFieldEditorWhileEditing` and the UI scenario `preview-optp-in-field.json`.
3. **Acting on search results with file operations** (trash, rename, move a result, then look at the list). Expected: the trashed/moved item disappears from the results and a renamed one shows its new name, without re-running the search; opening a stale row never happens. Owner P3-06: `testLocalChangesRemoveAndRenameResults`; P3-13 adds UI scenario `search-results-trash.json`.
4. **Crawling trees with symlink loops, mounted volumes, packages, unreadable folders and protected folders.** Expected: symlinks are never followed, mount points are not crossed, packages are skipped unless enabled, unreadable folders are counted as skipped (search continues), protected locations without a recorded TCC grant are skipped without triggering a macOS prompt, and the crawl always terminates. Owner P3-04: `testCrawlerDoesNotFollowSymlinkLoops`, `testCrawlerDoesNotCrossMountPoints`, `testCrawlerSkipsUnreadableAndContinues`, `testCrawlerSkipsBlockedPrefixesBelowRoot`.
5. **Retyping or switching scope while a large crawl is still running.** Expected: the previous search is cancelled (its lane work stops at the next directory boundary), its late batches never appear in the new results, and the new search shows only its own matches. Owner P3-06: `testRestartDropsStaleGenerationBatches` and `testCloseStopsEngineAndEmitsNothing`; P3-10 adds `testRetypingReplacesResultsModelAndHistoryEntry`.

---

## Phase 3 task index

| ID | Deliverable | Depends on |
|---|---|---|
| P3-01 | `MacxFS/Search`: `SearchCriteria`, `KindFilter`, `ByteRange`, `TimeRange`, `NameTerm`, `NamePattern` (substring + glob), `CriteriaMatcher`; `ViewQuery.criteria`; `Sorter` + `FolderWorker` apply it | Phase 2 |
| P3-02 | `Core/Search`: `QuerySyntax` (AQS-style parser with diagnostics), `DateToken`/`DateRanges`, `SearchFilters`, `SearchSpec` (+ URL encoding), `SearchResolver` | P3-01 |
| P3-03 | `RowSource` protocol (+ `FolderModel` conformance), `SearchResultStore`, `ChangeBus.observeAll`, `NavigationHistory.replaceCurrent` | P3-02 |
| P3-04 | `SubtreeCrawler` (BFS, ≤2 concurrent directory reads per volume, no-materialization, packages/hidden/mount/symlink/permission rules, stall skip, cancel) | P3-03 |
| P3-05 | Spotlight: `SpotlightRequest`, `SpotlightPredicate`, `MetadataQuerying` + `SystemMetadataQuery` + `FakeMetadataQuery`, `SpotlightSearch` adapter, `IndexStatusProviding` (`mdutil -s`) | P3-03 |
| P3-06 | `SearchPlanner` (engine routing table), `SearchContext`, `SearchResultsModel` (streaming, sort incl. Path, selection, stop/rerun/close, generations, local changes, notices), `CoreEnvironment` wiring | P3-04, P3-05 |
| P3-07 | Settings schema v3 (saved searches, preview pane, search defaults, results columns), `SavedSearch`, new `Command`s, `KeyMap` (⌥P, ⌥⌘R), `FocusContext` additions, `CommandAvailability` | P3-06 |
| P3-08 | `Core/Preview`: `PreviewPlanner` (classify, lane resolve), `TextPreviewLoader` (256 KB, encodings, binary sniff), `PreviewMetadata` (MDItem + ImageIO + AVFoundation fallback), `UbiquitousDownloading` + `DownloadWatcher` | P3-07 |
| P3-09 | UI: Details/Icons bind to `RowSource`; Path column; `ContentViewController` hosts results; `InlineRenameController` on `RowSource`; results empty states | P3-07 |
| P3-10 | UI: search field syntax + debounce + diagnostics, `SearchScopeBar` (chips, Name/Contents, progress, Stop, notices, Save), `SearchFiltersView`, `BrowserSession` search locations and history, address bar search display, Open Containing Folder, context menus | P3-09 |
| P3-11 | UI: sidebar SEARCHES section (save, open, rename, remove, reorder, Del never deletes files) | P3-10 |
| P3-12 | UI: preview pane (inspector item, ⌥P, `QuickLookHosting`, text view, folder/multiple/cloud/broken/unavailable states, details grid, debounce, Download button) | P3-08, P3-09 |
| P3-13 | Validation: `LaunchOptions --index-status`, scenario schema additions (incl. fake Spotlight items), UI scenarios, Core scenarios, `macx-bench` search metrics, README, full-suite run and sandbox-leak check | P3-10, P3-11, P3-12 |

### Phase 3 "working" definition (what P3-13 verifies)

1. `swift build -c release` and `swift test --parallel` pass with zero warnings.
2. `scripts/run-scenarios.sh` and `scripts/ui-scenarios.sh` report every Phase 1, 2 and 3 scenario passed.
3. In a sandboxed app run: typing in the search field filters the folder instantly (This folder); switching to Subfolders streams crawler results with a Path column; double-clicking a folder result opens it and ⌘[ returns to the results; Open Containing Folder selects the item in its folder; filters and syntax narrow results; Stop cancels; a saved search appears under SEARCHES and re-runs on click; ⌥P shows text previews of the first 256 KB, Quick Look for other types and a details summary.
4. Read-only live Spotlight tests pass (or skip with "Spotlight indexing is disabled on /").
5. `swift run -c release macx-bench --filter search-` prints the search metrics JSON (`--filter` is the metric-selection flag Phase 2 P2-20 uses).
6. No file outside test-created sandboxes and disk images was created, modified or deleted.

## File structure (Phase 3)

One line of responsibility per file, owning task in brackets. "Modify" lines extend Phase 1/2 files.

```
Sources/FSKit/Search/SearchCriteria.swift          [P3-01] SearchCriteria, NameTerm, KindFilter, ByteRange, TimeRange
Sources/FSKit/Search/NamePattern.swift             [P3-01] folded substring / whole-name glob matcher on UTF-8 bytes
Sources/FSKit/Search/CriteriaMatcher.swift         [P3-01] Entry + folded name → Bool (size, dates, ext, kind cache)
Sources/FSKit/Sort/ViewQuery.swift                 [P3-01 modify] + criteria: SearchCriteria?
Sources/FSKit/Sort/Sorter.swift                    [P3-01 modify] applies criteria; + types parameter (default .shared)
Sources/Core/Folder/FolderWorker.swift             [P3-01 modify] builds search keys when criteria != nil

Sources/Core/Search/QuerySyntax.swift              [P3-02] tokenizer + parser → ParsedQuery, SyntaxDiagnostic, SizeWord
Sources/Core/Search/DateRanges.swift               [P3-02] RelativeDay, DayStamp, DayBound, DateToken → TimeRange
Sources/Core/Search/SearchSpec.swift               [P3-02] SearchScope, SearchMode, SearchFilters, SearchSpec (+ URL form)
Sources/Core/Search/SearchResolver.swift           [P3-02] SearchSpec → ResolvedSearch (criteria, content terms, diagnostics)

Sources/Core/Folder/RowSource.swift                [P3-03] RowSource protocol, RowSourceEvent
Sources/Core/Folder/FolderModel+RowSource.swift    [P3-03] FolderModel conformance
Sources/Core/Folder/Selection.swift                [P3-03 modify] shared internal mutators used by both models
Sources/Core/Search/SearchTypes.swift              [P3-03] SearchBatch, SearchEvent, SearchProgress, SearchSummary, SkippedLocation, SearchFailure, SearchNotice
Sources/Core/Search/SearchResultStore.swift        [P3-03] EntryStore + parent column + path lookup; path identity
Sources/Core/Support/ChangeBus.swift               [P3-03 modify] + observeAll (already added by Phase 2 P2-13; P3-03 only verifies it)
Sources/Core/Navigation/NavigationHistory.swift    [P3-03 modify] + replaceCurrent

Sources/Core/Search/ResumeOnce.swift               [P3-04] one-shot continuation resume (Mutex)
Sources/Core/Search/CrawlTypes.swift               [P3-04] CrawlOptions, CrawlPermissions
Sources/Core/Search/SubtreeCrawler.swift           [P3-04] parallel BFS crawler on read lanes

Sources/Core/Search/SpotlightRequest.swift         [P3-05] MetadataScope, SpotlightRequest
Sources/Core/Search/SpotlightPredicate.swift       [P3-05] SpotlightRequest → NSPredicate
Sources/Core/Search/MetadataQuerying.swift         [P3-05] MetadataItem, MetadataQueryEvent, MetadataQuerying, FakeMetadataQuery
Sources/Core/Search/SystemMetadataQuery.swift      [P3-05] NSMetadataQuery on a private OperationQueue (confinement exception)
Sources/Core/Search/SpotlightSearch.swift          [P3-05] MetadataQueryEvent → SearchEvent (entries, post-filter, scope checks)
Sources/Core/Search/IndexStatus.swift              [P3-05] IndexingStatus, IndexStatusProviding, MdutilIndexStatus, FixedIndexStatus

Sources/Core/Search/SearchPlanner.swift            [P3-06] PlanInputs, SearchEngine, SearchPlan, routing table
Sources/Core/Search/SearchContext.swift            [P3-06] SearchContext, SearchServices, CrawlPermissions.make
Sources/Core/Search/ResultSorter.swift             [P3-06] permutation/merge incl. Path sort
Sources/Core/Search/SearchResultsModel.swift       [P3-06] @MainActor results model (RowSource)
Sources/Core/Support/CoreEnvironment.swift         [P3-06 modify] + searchServices, searchContext(), planSearch(_:), makeSearchResults(_:plan:)

Sources/Core/Settings/SettingsTypes.swift          [P3-07 modify] SidebarSection.searches
Sources/Core/Settings/SavedSearch.swift            [P3-07] SavedSearch, SavedSearchNaming
Sources/Core/Settings/Settings.swift               [P3-07 modify] schemaVersion 3 (from Phase 2's 2) + migration; new keys
Sources/Core/Commands/Command.swift                [P3-07 modify] new commands
Sources/Core/Commands/KeyMap.swift                 [P3-07 modify] ⌥P, ⌥⌘R, collision set
Sources/Core/Commands/KeyDispatcher.swift          [P3-07 modify] FocusContext .searchResults, .sidebarSavedSearch
Sources/Core/Commands/CommandAvailability.swift    [P3-07 modify] rules for new commands/focus contexts

Sources/Core/Preview/PreviewTypes.swift            [P3-08] PreviewSubject, PreviewContent, PreviewClass
Sources/Core/Preview/PreviewPlanner.swift          [P3-08] classify (pure) + resolve (lane: lstat, links, dataless, sniff)
Sources/Core/Preview/TextPreviewLoader.swift       [P3-08] 256 KB read + decode (UTF-8/16, CP1252, binary)
Sources/Core/Preview/PreviewMetadata.swift         [P3-08] PreviewDetails via lstat + MDItem + ImageIO + AVFoundation
Sources/Core/Preview/Ubiquitous.swift              [P3-06 creates: UbiquitousDownloading, SystemUbiquitousDownloader, FakeUbiquitousDownloader (SearchServices needs them); P3-08 adds DownloadWatcher]

Sources/UI/Content/FileListView.swift              [P3-09 modify] bind(_ source: (any RowSource)?)
Sources/UI/Details/DetailsViewController.swift     [P3-09 modify] RowSource; Path column cell; results column set
Sources/UI/Details/PathCellView.swift              [P3-09] ~-abbreviated parent path, middle truncation, tooltip
Sources/UI/Icons/IconsViewController.swift         [P3-09 modify] RowSource
Sources/UI/Content/ContentViewController.swift     [P3-09 modify] folder vs results source; results empty states
Sources/UI/Content/InlineRenameController.swift    [P3-09 modify] init(list:source:environment:)
Sources/UI/Content/EmptyStateView.swift            [P3-09 modify] searching / no results / root gone / Spotlight off states

Sources/UI/Search/SearchController.swift           [P3-10] field text + chips + filters → SearchSpec, debounce, session calls
Sources/UI/Search/SearchScopeBar.swift             [P3-10] chips, Name/Contents, Filters ▾, progress, Stop, notice line, Save Search…
Sources/UI/Search/SearchFiltersView.swift          [P3-10] kind / modified / created / size / extension controls
Sources/UI/Search/SearchStrings.swift              [P3-10] L10n formatting of notices, diagnostics, progress, summaries
Sources/UI/Toolbar/SearchFieldController.swift     [P3-10 modify] delegates to SearchController
Sources/UI/Toolbar/AddressBarView.swift            [P3-10 modify] search display "Search Results in 'X'"
Sources/UI/Window/BrowserSession.swift             [P3-10 modify] search locations, results model, history
Sources/UI/Commands/FileCommandController.swift    [P3-10 modify] openContainingFolder, stopSearch, rerun, scope/mode commands
Sources/UI/Menus/ContextMenuBuilder.swift          [P3-10 modify] results item menu, no empty-space Paste in results
Sources/UI/Menus/MainMenuBuilder.swift             [P3-10 modify] File › Save Search…, View › Preview Pane, Go › Open Containing Folder, View › Search Scope

Sources/UI/Sidebar/SidebarItem.swift               [P3-11 modify] .searchesHeader, .savedSearch(SavedSearch)
Sources/UI/Sidebar/SidebarViewController.swift     [P3-11 modify] SEARCHES section, menu, Del, reorder
Sources/UI/Search/NamePrompt.swift                 [P3-11] sheet with a text field (Save Search…, Rename…)

Sources/UI/Preview/PreviewPaneController.swift     [P3-12] inspector VC: debounce, generation, state views
Sources/UI/Preview/QuickLookHost.swift             [P3-12] QuickLookHosting protocol, QLPreviewViewHost, FakeQuickLookHost
Sources/UI/Preview/TextPreviewView.swift           [P3-12] read-only NSTextView in a scroll view, truncation footer
Sources/UI/Preview/PreviewDetailsView.swift        [P3-12] NSGridView summary (size, dates, dimensions, duration, pages)
Sources/UI/Preview/PreviewMessageView.swift        [P3-12] icon + title + optional button (cloud Download, broken link, etc.)
Sources/UI/Window/BrowserSplitViewController.swift [P3-12 modify] inspector split item, collapse state, width persistence

Sources/Core/Support/LaunchOptions.swift           [P3-13 modify] --index-status enabled|disabled|unknown
Sources/App/AppBootstrap.swift                     [P3-13 modify] wires fixture/fake search services in sandbox mode
Sources/UI/Scenario/ScenarioFile.swift             [P3-13 modify] fixture contents/bulk/binary, clickSidebar, search/preview expectations
Sources/UI/Scenario/ScenarioDriver.swift           [P3-13 modify] new steps and expectations
Sources/UI/Scenario/ScenarioProbe.swift            [P3-13 modify] probeSearchState, probePreviewState, probeSidebarSearches, probeRowPaths
Sources/macx-scenarios/Scenarios/SearchScenarios.swift [P3-13] crawl, filters, saved searches, cancel
Sources/macx-bench/SearchMetrics.swift             [P3-13] filter100k, crawlFirstResult, crawlComplete, parse
Tests/Scenarios/search-*.json, preview-*.json      [P3-13]
README.md                                          [P3-13 modify] Search & Preview section, Spotlight notes

Tests/FSKitTests/CriteriaMatcherTests.swift        [P3-01]
Tests/FSKitTests/NamePatternTests.swift            [P3-01]
Tests/CoreTests/Search/QuerySyntaxTests.swift      [P3-02]
Tests/CoreTests/Search/DateRangesTests.swift       [P3-02]
Tests/CoreTests/Search/SearchSpecTests.swift       [P3-02]
Tests/CoreTests/Search/SearchResultStoreTests.swift[P3-03]
Tests/CoreTests/Search/RowSourceTests.swift        [P3-03]
Tests/CoreTests/Search/SubtreeCrawlerTests.swift   [P3-04]
Tests/CoreTests/Search/SpotlightPredicateTests.swift [P3-05]
Tests/CoreTests/Search/SpotlightSearchTests.swift  [P3-05]
Tests/CoreTests/Search/LiveSpotlightTests.swift    [P3-05] read-only, skips when indexing is off
Tests/CoreTests/Search/IndexStatusTests.swift      [P3-05]
Tests/CoreTests/Search/SearchPlannerTests.swift    [P3-06]
Tests/CoreTests/Search/SearchResultsModelTests.swift [P3-06]
Tests/CoreTests/SettingsV3Tests.swift              [P3-07] (Phase 2 already owns SettingsV2Tests.swift)
Tests/CoreTests/KeyMapPhase3Tests.swift            [P3-07]
Tests/CoreTests/Preview/PreviewPlannerTests.swift  [P3-08]
Tests/CoreTests/Preview/TextPreviewLoaderTests.swift [P3-08]
Tests/CoreTests/Preview/PreviewMetadataTests.swift [P3-08]
Tests/CoreTests/Preview/DownloadWatcherTests.swift [P3-08]
Tests/UITests/RowSourceBindingTests.swift          [P3-09]
Tests/UITests/SearchControllerTests.swift          [P3-10]
Tests/UITests/BrowserSessionSearchTests.swift      [P3-10]
Tests/UITests/SidebarSearchesTests.swift           [P3-11]
Tests/UITests/PreviewPaneTests.swift               [P3-12]
```

## Interface additions (contract for every Phase 3 task)

Every task copies these names, labels, types, isolation and `Sendable`-ness exactly. Phase 1 types are referenced by their §3 names.

```swift
// ===== MacxFS (P3-01) =====
public enum KindFilter: String, Sendable, Codable, CaseIterable, Hashable {
    case folder, document, text, pdf, image, movie, audio, archive, application, code
    public var typeIdentifiers: [String] { get }   // Spotlight kMDItemContentTypeTree values and UTType conformance roots
    public var utTypes: [UTType] { get }
}
public struct ByteRange: Sendable, Codable, Hashable {          // lower inclusive, upper exclusive
    public var lower: Int64?; public var upper: Int64?
    public init(lower: Int64? = nil, upper: Int64? = nil)
    public func contains(_ value: Int64) -> Bool
    public func intersection(_ other: ByteRange) -> ByteRange
}
public struct TimeRange: Sendable, Codable, Hashable {          // ns since 1970; lower inclusive, upper exclusive
    public var lower: Int64?; public var upper: Int64?
    public init(lower: Int64? = nil, upper: Int64? = nil)
    public func contains(_ value: Int64) -> Bool
    public func intersection(_ other: TimeRange) -> TimeRange
}
public struct NameTerm: Sendable, Codable, Hashable { public var text: String; public init(_ text: String); public var isGlob: Bool { get } }
public struct SearchCriteria: Sendable, Codable, Hashable {
    public var nameTerms: [NameTerm]          // AND
    public var kinds: Set<KindFilter>?        // nil = any; empty set = matches nothing
    public var extensions: Set<String>?       // lowercased, no dot; nil = any; empty = nothing
    public var size: ByteRange?               // files only: directories and packages never match a size filter
    public var modified: TimeRange?
    public var created: TimeRange?
    public init(nameTerms: [NameTerm] = [], kinds: Set<KindFilter>? = nil, extensions: Set<String>? = nil,
                size: ByteRange? = nil, modified: TimeRange? = nil, created: TimeRange? = nil)
    public var isEmpty: Bool { get }
}
public struct NamePattern: Sendable, Hashable {
    public init(_ term: String)
    public let isGlob: Bool
    public func matches(_ foldedName: UnsafeRawBufferPointer) -> Bool
}
public struct CriteriaMatcher: Sendable {
    public init(_ criteria: SearchCriteria, types: TypeRegistry)
    public mutating func matches(_ entry: Entry, foldedName: UnsafeRawBufferPointer) -> Bool
}
// ViewQuery gains:  public var criteria: SearchCriteria?   and   init(sort:showHidden:filter:criteria: = nil)
// Sorter.permutation/merge (and Phase 2's permutation(…extras:)) gain a trailing `types: TypeRegistry = .shared` parameter.

// ===== Core/Search syntax and spec (P3-02) =====
public enum SizeWord: String, Sendable, CaseIterable { case empty, tiny, small, medium, large, huge, gigantic; public var range: ByteRange { get } }
public struct SyntaxDiagnostic: Sendable, Codable, Equatable {
    public enum Problem: String, Sendable, Codable { case badSize, badDate, badKind, emptyValue }
    public var token: String; public var problem: Problem
    public init(token: String, problem: Problem)
}
public struct ParsedQuery: Sendable, Equatable {
    public var freeTerms: [String]; public var nameTerms: [String]
    public var kinds: Set<KindFilter>; public var extensions: Set<String>
    public var size: ByteRange?; public var modified: [DateToken]; public var created: [DateToken]
    public var diagnostics: [SyntaxDiagnostic]
    public init()
}
public enum QuerySyntax { public static func parse(_ text: String) -> ParsedQuery }
public enum RelativeDay: String, Sendable, Codable, CaseIterable { case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear, last7Days, last30Days }
public struct DayStamp: Sendable, Codable, Hashable { public var year: Int; public var month: Int; public var day: Int; public init(year: Int, month: Int, day: Int) }
public struct DayBound: Sendable, Codable, Hashable { public var day: DayStamp; public var inclusive: Bool; public init(day: DayStamp, inclusive: Bool) }
public enum DateToken: Sendable, Codable, Hashable { case relative(RelativeDay); case days(lower: DayBound?, upper: DayBound?) }
public enum DateRanges { public static func range(_ token: DateToken, now: Date, calendar: Calendar) -> TimeRange }
public enum SearchScope: String, Sendable, Codable, CaseIterable { case thisFolder, subfolders, thisMac }
public enum SearchMode: String, Sendable, Codable, CaseIterable { case name, contents }
public struct SearchFilters: Sendable, Codable, Hashable {
    public var kinds: Set<KindFilter>; public var extensions: Set<String>
    public var size: ByteRange?; public var modified: DateToken?; public var created: DateToken?
    public init(kinds: Set<KindFilter> = [], extensions: Set<String> = [], size: ByteRange? = nil, modified: DateToken? = nil, created: DateToken? = nil)
    public var isEmpty: Bool { get }
}
public struct SearchSpec: Sendable, Codable, Hashable {
    public var text: String; public var scope: SearchScope; public var mode: SearchMode
    public var filters: SearchFilters; public var root: URL
    public init(text: String, scope: SearchScope, mode: SearchMode = .name, filters: SearchFilters = SearchFilters(), root: URL)
    public static let urlScheme: String        // "x-macexplorer-search"
    public var url: URL { get }
    public init?(url: URL)
    public var isEmptyQuery: Bool { get }      // trimmed text empty && filters.isEmpty
}
public struct ResolvedSearch: Sendable, Equatable {
    public var criteria: SearchCriteria; public var contentTerms: [String]; public var diagnostics: [SyntaxDiagnostic]
    public var isEmpty: Bool { get }
}
public enum SearchResolver { public static func resolve(_ spec: SearchSpec, now: Date, calendar: Calendar) -> ResolvedSearch }

// ===== Core rows and results (P3-03) =====
public enum RowSourceEvent: Sendable { case changes(ChangeSet), selection(Selection), beginRename(row: Int) }
@MainActor public protocol RowSource: AnyObject {
    var rowCount: Int { get }
    func entry(atRow row: Int) -> Entry
    func name(atRow row: Int) -> String
    func url(atRow row: Int) -> URL
    func parentURL(atRow row: Int) -> URL
    func identity(atRow row: Int) -> RowID
    func row(of id: RowID) -> Int?
    var selection: Selection { get }
    func select(_ command: SelectionCommand)
    var selectedURLs: [URL] { get }
    var selectionSummary: SelectionSummary { get }
    var scrollAnchor: RowID? { get set }
    func isCut(row: Int) -> Bool
    var sortDescriptor: SortDescriptor { get }  // FolderModel: query.sort; results: their own (SortField.path supported)
    func setSortDescriptor(_ sort: SortDescriptor)
    var showsPathColumn: Bool { get }           // FolderModel false, SearchResultsModel true
    var caseSensitive: Bool { get }
    func validateName(_ proposed: String, renamingRow row: Int?) -> NameValidation
    func observeRows(_ handler: @escaping @MainActor (RowSourceEvent) -> Void) -> ObserverToken
}
public struct SearchBatch: Sendable { public var parent: URL; public var batch: Batch; public init(parent: URL, batch: Batch) }
public struct SearchProgress: Sendable, Equatable {
    public var directoriesScanned: Int; public var resultCount: Int; public var currentPath: String?
    public init(directoriesScanned: Int = 0, resultCount: Int = 0, currentPath: String? = nil)
}
public enum SkipReason: Sendable, Equatable { case permission(Int32), protectedLocation, unresponsive }
public struct SkippedLocation: Sendable, Equatable { public var path: String; public var reason: SkipReason; public init(path: String, reason: SkipReason) }
public struct SearchSummary: Sendable, Equatable {
    public var resultCount: Int; public var directoriesScanned: Int
    public var skipped: [SkippedLocation]      // first 50
    public var skippedTotal: Int; public var truncated: Bool; public var elapsed: Duration
    public init(resultCount: Int = 0, directoriesScanned: Int = 0, skipped: [SkippedLocation] = [], skippedTotal: Int = 0,
                truncated: Bool = false, elapsed: Duration = .zero)
}
public enum SearchFailure: Error, Sendable, Equatable { case rootUnreadable(Reason), volumeUnresponsive, spotlightFailed }
public enum SearchNotice: Sendable, Equatable {
    case contentsNotIndexed(volumeName: String)   // fell back to name search
    case spotlightOff                             // This Mac unavailable
    case truncated(limit: Int)
    case skippedLocations(count: Int)
    case mayNotBeIndexed                          // folder-scoped Spotlight search finished with 0 results
}
public enum SearchEvent: Sendable {
    case batch(SearchBatch), removed([String]), progress(SearchProgress), notice(SearchNotice)
    case completed(SearchSummary), failed(SearchFailure)
}
public struct SearchResultStore: Sendable {
    public init()
    public private(set) var store: EntryStore            // identityMode .objectID; identity NOT used
    public private(set) var nameKeys: SortKeyColumn      // SortKeys.nameKey per storage index, kept aligned by append/remove/rename
    public var count: Int { get }
    public func path(_ index: UInt32) -> String
    public func url(_ index: UInt32) -> URL
    public func parentPath(_ index: UInt32) -> String
    public func parentIndex(_ index: UInt32) -> UInt32
    public var parents: [String] { get }
    public func identity(_ index: UInt32) -> RowID       // .name(<standardized full path>)
    public func index(ofPath path: String) -> UInt32?
    @discardableResult public mutating func append(_ batch: SearchBatch) -> [UInt32]   // replaces existing paths
    @discardableResult public mutating func remove(paths: [String]) -> Int
    public mutating func rename(path: String, to newName: String, types: TypeRegistry) -> Bool
    public mutating func setOrder(_ order: [UInt32])
}
// ChangeBus gains:          public func observeAll(_ handler: @escaping @MainActor (LocalChange) -> Void) -> ObserverToken
// NavigationHistory gains:  public mutating func replaceCurrent(_ url: URL)   // drops a trailing back entry equal to url

// ===== Crawler (P3-04) =====
public struct CrawlOptions: Sendable, Hashable {
    public var includePackages: Bool = false; public var includeHidden: Bool = false
    public var maxResults: Int = 100_000; public var maxConcurrentReads: Int = 2
    public var progressInterval: Duration = .milliseconds(100)
    public init()
}
public struct CrawlPermissions: Sendable, Hashable {
    public var blockedPrefixes: [String]
    public init(blockedPrefixes: [String])
    public static let none: CrawlPermissions
    public func relevant(forRoot root: String) -> CrawlPermissions   // drops prefixes equal to or above root
    public func isBlocked(_ path: String) -> Bool
}
public enum SubtreeCrawler {
    public static func crawl(root: URL, criteria: SearchCriteria, options: CrawlOptions, permissions: CrawlPermissions,
                             generation: Generation, lanes: LanePool, mountTable: MountTableStore,
                             types: TypeRegistry = .shared) -> AsyncStream<SearchEvent>
}

// ===== Spotlight (P3-05) =====
public enum MetadataScope: Sendable, Hashable { case localComputer, folders([URL]) }
public struct SpotlightRequest: Sendable, Hashable {
    public var criteria: SearchCriteria; public var contentTerms: [String]; public var scope: MetadataScope
    public var within: URL?; public var directChildrenOf: URL?
    public init(criteria: SearchCriteria, contentTerms: [String], scope: MetadataScope, within: URL? = nil, directChildrenOf: URL? = nil)
}
public enum SpotlightPredicate { public static func make(_ request: SpotlightRequest) -> NSPredicate }
public struct MetadataItem: Sendable, Equatable, Codable {
    public var path: String; public var name: String; public var size: Int64?
    public var modified: Date?; public var created: Date?; public var contentTypeTree: [String]; public var isInvisible: Bool
    public init(path: String, name: String, size: Int64?, modified: Date?, created: Date?, contentTypeTree: [String], isInvisible: Bool)
}
public enum MetadataQueryEvent: Sendable, Equatable { case added([MetadataItem]), updated([MetadataItem]), removed([String]), gatheringFinished, failed }
public protocol MetadataQuerying: Sendable { func run(_ request: SpotlightRequest) -> AsyncStream<MetadataQueryEvent> }
public final class SystemMetadataQuery: MetadataQuerying { public init() }
public final class FakeMetadataQuery: MetadataQuerying {
    public struct Step: Sendable { public var delay: Duration; public var event: MetadataQueryEvent; public init(delay: Duration = .zero, _ event: MetadataQueryEvent) }
    public init(runs: [[Step]])            // run N uses runs[min(N, runs.count-1)]; runs: [] → immediate .gatheringFinished
    public init(items: [MetadataItem])     // every run: .added(items) then .gatheringFinished
    public func setRuns(_ runs: [[Step]])  // scenario driver installs fixture results at runtime
    public func requests() -> [SpotlightRequest]
}
public enum SpotlightSearch {
    public static let resultLimit: Int     // 100_000
    public static func events(_ request: SpotlightRequest, query: any MetadataQuerying, includeHidden: Bool,
                              generation: Generation, types: TypeRegistry = .shared) -> AsyncStream<SearchEvent>
    public static func entry(for item: MetadataItem, types: TypeRegistry) -> (entry: Entry, name: String)
}
public enum IndexingStatus: String, Sendable, Codable { case enabled, disabled, unknown }
public protocol IndexStatusProviding: Sendable { func status(ofVolumeAt mountPoint: URL) async -> IndexingStatus }
public final class MdutilIndexStatus: IndexStatusProviding {
    public init(lanes: LanePool, timeout: Duration = .seconds(2), cacheLifetime: Duration = .seconds(60))
    public static func parse(_ output: String) -> IndexingStatus
}
public struct FixedIndexStatus: IndexStatusProviding { public init(_ status: IndexingStatus) }

// ===== Planner, context, results model (P3-06) =====
public struct PlanInputs: Sendable, Equatable {
    public var rootIndexing: IndexingStatus; public var bootIndexing: IndexingStatus
    public var rootIsLocal: Bool; public var rootVolumeName: String
    public init(rootIndexing: IndexingStatus, bootIndexing: IndexingStatus, rootIsLocal: Bool, rootVolumeName: String)
}
public enum SearchEngine: Sendable, Equatable {
    case none
    case folderFilter(SearchCriteria)
    case crawler(root: URL, criteria: SearchCriteria)
    case spotlight(SpotlightRequest)
}
public struct SearchPlan: Sendable, Equatable { public var engine: SearchEngine; public var notices: [SearchNotice]; public var diagnostics: [SyntaxDiagnostic] }
public enum SearchPlanner {
    public static func needsIndexStatus(_ spec: SearchSpec) -> Bool
    public static func plan(_ spec: SearchSpec, resolved: ResolvedSearch, inputs: PlanInputs) -> SearchPlan
}
public struct SearchServices: Sendable {
    public var metadataQuery: any MetadataQuerying; public var indexStatus: any IndexStatusProviding
    public var downloader: any UbiquitousDownloading
    public init(metadataQuery: any MetadataQuerying, indexStatus: any IndexStatusProviding, downloader: any UbiquitousDownloading)
    public static func system(lanes: LanePool) -> SearchServices
    public static func fake(items: [MetadataItem] = [], indexing: IndexingStatus = .disabled) -> SearchServices
}
@MainActor public struct SearchContext {
    public var lanes: LanePool; public var volumes: Volumes; public var types: TypeRegistry
    public var changeBus: ChangeBus; public var settings: Settings; public var pacer: any FramePacer
    public var services: SearchServices
    public var now: @Sendable () -> Date; public var calendar: Calendar
    public init(lanes: LanePool, volumes: Volumes, types: TypeRegistry, changeBus: ChangeBus, settings: Settings,
                pacer: any FramePacer, services: SearchServices,
                now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current)
    public func plan(_ spec: SearchSpec) async -> SearchPlan
    public func crawlPermissions() -> CrawlPermissions
}
public enum SearchState: Sendable, Equatable { case searching(SearchProgress), complete(SearchSummary), stopped(SearchSummary), failed(SearchFailure) }
public enum SearchModelEvent: Sendable { case rows(RowSourceEvent), state(SearchState), notices([SearchNotice]) }
@MainActor public final class SearchResultsModel: RowSource {
    public static let resultLimit: Int                 // 100_000
    public init(spec: SearchSpec, plan: SearchPlan, context: SearchContext)   // plan.engine must be .crawler or .spotlight
    /// Externally built stream (Phase 4 TAGS); `events` is called once per start/rerun with the new generation.
    public init(title: String, events: @escaping @MainActor (Generation) -> AsyncStream<SearchEvent>, context: SearchContext)
    public let title: String                           // spec-based: the query text
    public let spec: SearchSpec?; public let plan: SearchPlan?
    public private(set) var state: SearchState
    public private(set) var notices: [SearchNotice]
    public private(set) var generation: Generation
    public private(set) var results: SearchResultStore
    public var cutURLs: Set<URL>
    public func start(); public func stop(); public func rerun(); public func close()
    public func observe(_ handler: @escaping @MainActor (SearchModelEvent) -> Void) -> ObserverToken
}
// CoreEnvironment gains: public let searchServices: SearchServices (init param `searchServices: SearchServices? = nil`,
// nil = .system(lanes:); sandboxed(root:) uses .fake()), public func searchContext() -> SearchContext,
// public func planSearch(_ spec: SearchSpec) async -> SearchPlan,
// public func makeSearchResults(_ spec: SearchSpec, plan: SearchPlan) -> SearchResultsModel.
// CrawlPermissions gains (SearchContext.swift): public static func make(home: URL, outcome: (ProtectedLocation) -> TCCOutcome?) -> CrawlPermissions
// UbiquitousDownloading / SystemUbiquitousDownloader / FakeUbiquitousDownloader (declared under Preview below) are created by P3-06.

// ===== Settings, commands (P3-07) =====
public struct SavedSearch: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID; public var name: String; public var spec: SearchSpec
    public init(id: UUID = UUID(), name: String, spec: SearchSpec)
}
public enum SavedSearchNaming { public static func uniqueName(_ proposed: String, existing: [String]) -> String? }  // nil if blank
// SidebarSection gains .searches. Settings.schemaVersion becomes 3 (Phase 2 left it at 2) and gains:
//   savedSearches: [SavedSearch] = [], previewPaneVisible: Bool = false, previewPaneWidth: Double = 320,
//   searchScope: SearchScope = .thisFolder, searchMode: SearchMode = .name, searchIncludesPackages: Bool = false,
//   resultsColumns: [ColumnSetting] (name, path, dateModified, size, kind visible)
//   func addSavedSearch(name:spec:) -> SavedSearch, func renameSavedSearch(_ id: UUID, to name: String) -> Bool,
//   func removeSavedSearch(_ id: UUID), func moveSavedSearch(from: Int, to: Int)
// Command gains: togglePreviewPane, openContainingFolder, saveSearch, stopSearch,
//   searchScopeThisFolder, searchScopeSubfolders, searchScopeThisMac, searchModeName, searchModeContents,
//   renameSavedSearch, removeSavedSearch, downloadForPreview
// FocusContext gains: searchResults, sidebarSavedSearch
// CommandState gains (defaulted, appended to the init): isSearching: Bool = false, hasSearchQuery: Bool = false,
//   showingResults: Bool = false, previewPaneVisible: Bool = false
// KeyMap.primary: togglePreviewPane = opt+p, openContainingFolder = cmd+opt+r; collidesWithTextEditing += togglePreviewPane

// ===== Preview (P3-08) =====
public struct PreviewSubject: Sendable, Equatable {
    public var url: URL; public var kind: Kind; public var typeIndex: UInt16; public var flags: EntryFlags; public var size: Int64
    public init(url: URL, kind: Kind, typeIndex: UInt16, flags: EntryFlags, size: Int64)
}
public enum PreviewContent: Sendable, Equatable {
    case nothingSelected, multiple(count: Int, bytes: Int64)
    case folder(URL), text(URL), quickLook(URL)
    case cloudPlaceholder(URL), brokenLink(URL), unavailable(URL, code: Int32)
}
public enum PreviewClass: Sendable, Equatable { case text, quickLook, sniff }
public enum PreviewPlanner {
    public static func classify(_ type: UTType) -> PreviewClass
    public static func resolve(_ subject: PreviewSubject, lanes: LanePool, volume: VolumeID, types: TypeRegistry) async -> PreviewContent
}
public enum TextEncodingGuess: String, Sendable, Equatable { case utf8, utf16LE, utf16BE, windows1252, latin1 }
public struct TextPreview: Sendable, Equatable { public var text: String; public var truncated: Bool; public var encoding: TextEncodingGuess }
public enum TextPreviewError: Error, Sendable, Equatable { case binary, posix(Int32) }
public enum TextPreviewLoader {
    public static let limit: Int                   // 262_144
    public static func decode(_ bytes: [UInt8], truncated: Bool) -> TextPreview?   // nil = binary
    public static func load(_ url: URL, lanes: LanePool, volume: VolumeID) async throws(TextPreviewError) -> TextPreview
}
public struct PreviewDetails: Sendable, Equatable {
    public var size: Int64?; public var created: Date?; public var modified: Date?
    public var pixelWidth: Int?; public var pixelHeight: Int?; public var duration: Double?; public var pageCount: Int?
    public var kindDescription: String
}
public enum PreviewMetadata { public static func load(_ url: URL, typeIndex: UInt16, types: TypeRegistry, lanes: LanePool, volume: VolumeID) async -> PreviewDetails }
public protocol UbiquitousDownloading: Sendable {
    func startDownloading(_ url: URL) async throws
    func isDataless(_ url: URL) async -> Bool
}
public struct SystemUbiquitousDownloader: UbiquitousDownloading { public init(lanes: LanePool) }
public final class FakeUbiquitousDownloader: UbiquitousDownloading {
    public init(datalessPolls: Int = 2, failStart: Bool = false); public func started() -> [URL]
}
public enum DownloadState: Sendable, Equatable { case downloading, done, failed, timedOut }
public enum DownloadWatcher {
    public static func download(_ url: URL, using downloader: any UbiquitousDownloading,
                                pollInterval: Duration = .milliseconds(500), timeout: Duration = .seconds(600)) -> AsyncStream<DownloadState>
}

// ===== UI (internal to the UI module; P3-09 … P3-12) =====
// FileListView (P3-09): `var folder: FolderModel?` and `bind(_ folder: FolderModel?)` are replaced by
//   var source: (any RowSource)? { get };  func bind(_ source: (any RowSource)?)
//   plus a protocol extension `var folder: FolderModel? { source as? FolderModel }` for Phase 1/2 folder-only paths.
// ContentViewController (P3-09): func display(_ source: any RowSource)   // folder model or results model
// EmptyStateContent (P3-09): static func make(search: SearchState, notices: [SearchNotice], rowCount: Int, query: String) -> EmptyStateContent?
//   EmptyStateAction gains .searchSubfolders, .searchAgain
// InlineRenameController (P3-09): init(list: FileListView, source: any RowSource, environment: CoreEnvironment)
// CommandTarget (P3-10) gains: case resultsSelection(SearchResultsModel)
// SessionEvent (P3-10) gains: case resultsChanged(SearchResultsModel?), searchTextChanged(String)
// BrowserSession (P3-10) gains:
//   private(set) var results: SearchResultsModel?        // non-nil while the window shows results
//   private(set) var searchSpec: SearchSpec?             // the spec being shown (folder filter or results)
//   func search(_ spec: SearchSpec) async                 // plans and shows; replaces the current search entry
//   func clearSearch()                                    // back to the folder, no new history entry
//   func showResults(_ model: SearchResultsModel, recordHistory: Bool)
//   func openContainingFolder(of url: URL)
// ScenarioProbe (P3-13) gains: probeSearchState: String?, probePreviewState: String?, probeSidebarSearches: [String], probeRowPaths: [String]
```

---
### Task P3-01: Search criteria and matching in MacxFS

**Files:**
- Create: `Sources/FSKit/Search/SearchCriteria.swift`, `Sources/FSKit/Search/NamePattern.swift`, `Sources/FSKit/Search/CriteriaMatcher.swift`
- Modify: `Sources/FSKit/Sort/ViewQuery.swift` (add `criteria`), `Sources/FSKit/Sort/Sorter.swift` (apply criteria; trailing `types:` parameter), `Sources/Core/Folder/FolderWorker.swift` (search keys when `criteria != nil`)
- Test: `Tests/FSKitTests/NamePatternTests.swift`, `Tests/FSKitTests/CriteriaMatcherTests.swift`

**Interfaces:**
- Consumes: `Entry`, `Kind`, `EntryFlags`, `Batch`, `EntryStore`, `TypeRegistry`, `SortKeys.searchFold(_:)`, `SortKeys.searchKeys(_:)`, `SortKeys.nameKeys(_:range:)`, `Sorter.permutation(...)`, `ViewQuery` (Phase 1 §3.3/§3.5).
- Produces: `KindFilter`, `ByteRange`, `TimeRange`, `NameTerm`, `SearchCriteria`, `NamePattern`, `CriteriaMatcher` (exact shapes in "Interface additions"); `ViewQuery.criteria`; `Sorter.permutation(_:nameKeys:searchKeys:query:kindRanks:types:)`.

- [ ] **Step 1: Write the failing pattern tests**

```swift
// Tests/FSKitTests/NamePatternTests.swift
import XCTest
@testable import MacxFS

final class NamePatternTests: XCTestCase {
    private func m(_ pattern: String, _ name: String) -> Bool {
        let folded = SortKeys.searchFold(name)
        return folded.withUnsafeBytes { NamePattern(pattern).matches($0) }
    }

    func testSubstringIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(m("resume", "Résumé Final.PDF"))
        XCTAssertTrue(m("FINAL", "Résumé Final.PDF"))
        XCTAssertTrue(m("é", "cafe.txt"))            // the pattern is folded too
        XCTAssertFalse(m("draft", "Résumé Final.PDF"))
        XCTAssertTrue(m("", "anything"))             // empty term matches everything
    }

    // Review Focus 1
    func testGlobTermsMatchWholeName() {
        XCTAssertTrue(m("*.pdf", "a.PDF"))
        XCTAssertFalse(m("*.pdf", "a.pdf.zip"))      // glob is anchored at both ends
        XCTAssertTrue(m("report?.doc", "report1.doc"))
        XCTAssertTrue(m("report?.doc", "reporté.doc"))
        XCTAssertFalse(m("report?.doc", "report12.doc"))
        XCTAssertTrue(m("IMG_*", "img_0001.HEIC"))
        XCTAssertTrue(m("*", "x"))
        XCTAssertTrue(m("*", ""))
        XCTAssertTrue(m("a*b*c", "aXXbYYc"))
        XCTAssertTrue(m("a*b*c", "abc"))
        XCTAssertFalse(m("a*b*c", "acb"))
        XCTAssertTrue(m("**x", "x"))                 // repeated stars collapse
        XCTAssertTrue(NamePattern("*.pdf").isGlob)
        XCTAssertFalse(NamePattern("pdf").isGlob)
    }

    func testQuestionMarkMatchesOneMultibyteCharacter() {
        XCTAssertTrue(m("?.txt", "日.txt"))
        XCTAssertFalse(m("?.txt", "日本.txt"))
        XCTAssertTrue(m("??.txt", "日本.txt"))
        XCTAssertTrue(m("?", "😀"))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FSKitTests.NamePatternTests 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'NamePattern' in scope`.

- [ ] **Step 3: Implement `NamePattern`**

```swift
// Sources/FSKit/Search/NamePattern.swift
import Foundation

/// A folded name term. Without `*`/`?` it is a substring test; with them it is an anchored whole-name glob
/// where `*` matches any run of bytes and `?` exactly one UTF-8 scalar. Literal pieces are folded with
/// `SortKeys.searchFold`, the same fold the names are matched in.
public struct NamePattern: Sendable, Hashable {
    enum Token: Sendable, Hashable { case literal([UInt8]), star, one }
    let tokens: [Token]
    public let isGlob: Bool

    public init(_ term: String) {
        var tokens: [Token] = []
        var piece = ""
        var glob = false
        func flush() {
            if !piece.isEmpty { tokens.append(.literal(SortKeys.searchFold(piece))); piece = "" }
        }
        for ch in term {
            switch ch {
            case "*":
                flush(); glob = true
                if tokens.last != .star { tokens.append(.star) }
            case "?":
                flush(); glob = true
                tokens.append(.one)
            default:
                piece.append(ch)
            }
        }
        flush()
        self.tokens = tokens
        self.isGlob = glob
    }

    public func matches(_ foldedName: UnsafeRawBufferPointer) -> Bool {
        if !isGlob {
            guard case .literal(let needle)? = tokens.first else { return true }
            return Self.contains(foldedName, needle)
        }
        return Self.glob(tokens, foldedName)
    }

    static func contains(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        let n = hay.count, m = needle.count
        if m == 0 { return true }
        if m > n { return false }
        let first = needle[0]
        var i = 0
        while i <= n - m {
            if hay[i] == first {
                var j = 1
                while j < m && hay[i + j] == needle[j] { j += 1 }
                if j == m { return true }
            }
            i += 1
        }
        return false
    }

    static func hasPrefix(_ hay: UnsafeRawBufferPointer, at i: Int, _ lit: [UInt8]) -> Bool {
        if hay.count - i < lit.count { return false }
        for k in 0..<lit.count where hay[i + k] != lit[k] { return false }
        return true
    }

    static func nextScalar(_ s: UnsafeRawBufferPointer, _ i: Int) -> Int {
        var j = i + 1
        while j < s.count && (s[j] & 0xC0) == 0x80 { j += 1 }
        return j
    }

    /// Classic single-backtrack wildcard match over tokens.
    static func glob(_ tokens: [Token], _ s: UnsafeRawBufferPointer) -> Bool {
        var ti = 0, si = 0
        var starTi = -1, starSi = 0
        let n = s.count
        while true {
            if ti < tokens.count {
                switch tokens[ti] {
                case .star:
                    starTi = ti; starSi = si; ti += 1
                    continue
                case .one:
                    if si < n { si = nextScalar(s, si); ti += 1; continue }
                case .literal(let lit):
                    if hasPrefix(s, at: si, lit) { si += lit.count; ti += 1; continue }
                }
            } else if si == n {
                return true
            }
            if starTi < 0 || starSi >= n { return false }
            starSi = nextScalar(s, starSi)
            si = starSi
            ti = starTi + 1
        }
    }
}
```

- [ ] **Step 4: Run the pattern tests**

Run: `swift test --filter FSKitTests.NamePatternTests 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Write the failing criteria tests**

```swift
// Tests/FSKitTests/CriteriaMatcherTests.swift
import XCTest
import UniformTypeIdentifiers
@testable import MacxFS

final class CriteriaMatcherTests: XCTestCase {
    let types = TypeRegistry()
    let day: Int64 = 86_400 * 1_000_000_000

    func entry(_ name: String, _ kind: Kind = .file, size: Int64 = 10, mtime: Int64 = 0, ctime: Int64 = 0) -> Entry {
        let ext = (name as NSString).pathExtension
        let isDir = kind == .directory || kind == .package
        return Entry(rowID: 1, fileID: 1, size: size, allocSize: size, mtime: mtime, ctime: ctime,
                     nameOffset: 0, nameLen: UInt16(name.utf8.count), kind: kind,
                     flags: name.hasPrefix(".") ? .dotName : [],
                     typeIndex: kind == .directory ? TypeRegistry.folderIndex
                         : types.index(forExtension: Substring(ext), isDirectory: isDir))
    }
    func matches(_ c: SearchCriteria, _ e: Entry, _ name: String) -> Bool {
        var m = CriteriaMatcher(c, types: types)
        return SortKeys.searchFold(name).withUnsafeBytes { m.matches(e, foldedName: $0) }
    }

    func testMultipleTermsAreANDed() {
        let c = SearchCriteria(nameTerms: [NameTerm("tax"), NameTerm("2025")])
        XCTAssertTrue(matches(c, entry("Tax return 2025.pdf"), "Tax return 2025.pdf"))
        XCTAssertFalse(matches(c, entry("Tax return 2024.pdf"), "Tax return 2024.pdf"))
    }

    func testSizeBoundsAreLowerInclusiveUpperExclusive() {
        let c = SearchCriteria(size: ByteRange(lower: 100, upper: 200))
        XCTAssertTrue(matches(c, entry("a", size: 100), "a"))
        XCTAssertTrue(matches(c, entry("a", size: 199), "a"))
        XCTAssertFalse(matches(c, entry("a", size: 200), "a"))
        XCTAssertFalse(matches(c, entry("a", size: 99), "a"))
    }

    func testSizeFilterNeverMatchesDirectoriesOrPackages() {
        // Entry.size of a directory holds its entry count (Phase 1 §3.3), not bytes.
        let c = SearchCriteria(size: ByteRange(lower: 0))
        XCTAssertFalse(matches(c, entry("Folder", .directory, size: 5), "Folder"))
        XCTAssertFalse(matches(c, entry("X.app", .package, size: 1), "X.app"))
        XCTAssertTrue(matches(c, entry("f.txt", size: 0), "f.txt"))
    }

    func testDateRanges() {
        let c = SearchCriteria(modified: TimeRange(lower: 10 * day, upper: 11 * day),
                               created: TimeRange(upper: 5 * day))
        XCTAssertTrue(matches(c, entry("a", mtime: 10 * day, ctime: 4 * day), "a"))
        XCTAssertFalse(matches(c, entry("a", mtime: 11 * day, ctime: 4 * day), "a"))
        XCTAssertFalse(matches(c, entry("a", mtime: 10 * day, ctime: 5 * day), "a"))
    }

    func testExtensionsAreCaseInsensitiveAndDotfilesHaveNone() {
        let c = SearchCriteria(extensions: ["jpg", "gz"])
        XCTAssertTrue(matches(c, entry("A.JPG"), "A.JPG"))
        XCTAssertTrue(matches(c, entry("archive.tar.gz"), "archive.tar.gz"))
        XCTAssertFalse(matches(c, entry(".jpg"), ".jpg"))        // leading dot is not an extension
        XCTAssertFalse(matches(c, entry("noext"), "noext"))
        XCTAssertFalse(matches(c, entry("trailing."), "trailing."))
        XCTAssertFalse(matches(SearchCriteria(extensions: []), entry("a.jpg"), "a.jpg"))   // empty set = nothing
    }

    func testKindFilters() {
        XCTAssertTrue(matches(SearchCriteria(kinds: [.image]), entry("p.png"), "p.png"))
        XCTAssertFalse(matches(SearchCriteria(kinds: [.image]), entry("p.pdf"), "p.pdf"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.pdf, .image]), entry("p.pdf"), "p.pdf"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.folder]), entry("Docs", .directory), "Docs"))
        XCTAssertFalse(matches(SearchCriteria(kinds: [.folder]), entry("X.app", .package), "X.app"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.application]), entry("X.app", .package), "X.app"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.code]), entry("main.swift"), "main.swift"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.document]), entry("notes.txt"), "notes.txt"))
        XCTAssertTrue(matches(SearchCriteria(kinds: [.archive]), entry("a.zip"), "a.zip"))
        XCTAssertFalse(matches(SearchCriteria(kinds: []), entry("a.png"), "a.png"))      // empty set = nothing
        XCTAssertFalse(matches(SearchCriteria(kinds: [.image]), entry("Pics", .directory), "Pics"))
    }

    func testRangeIntersection() {
        let a = ByteRange(lower: 10, upper: 100), b = ByteRange(lower: 50)
        XCTAssertEqual(a.intersection(b), ByteRange(lower: 50, upper: 100))
        XCTAssertEqual(TimeRange(upper: 5).intersection(TimeRange(upper: 3)), TimeRange(upper: 3))
    }

    func testSorterAppliesCriteriaAndStillHidesHiddenRows() {
        var batch = Batch(generation: .initial)
        for (name, kind) in [("b.png", Kind.file), ("Album", .directory), ("a.png", .file), (".c.png", .file), ("d.txt", .file)] {
            var e = entry(name, kind)
            if name.hasPrefix(".") { e.flags.insert(.dotName) }
            let bytes = Array(name.utf8)
            bytes.withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
        }
        var store = EntryStore(identityMode: .name(caseSensitive: false))
        store.append(batch)
        let keys = SortKeys.nameKeys(store, range: 0..<store.count)
        let search = SortKeys.searchKeys(store)
        let q = ViewQuery(sort: .default, showHidden: false, filter: "", criteria: SearchCriteria(kinds: [.image]))
        let order = Sorter.permutation(store, nameKeys: keys, searchKeys: search, query: q,
                                       kindRanks: types.kindRanks().ranks, types: types)
        XCTAssertEqual(order.map { store.name($0) }, ["a.png", "b.png"])
        var q2 = q; q2.showHidden = true
        let order2 = Sorter.permutation(store, nameKeys: keys, searchKeys: search, query: q2,
                                        kindRanks: types.kindRanks().ranks, types: types)
        XCTAssertEqual(order2.map { store.name($0) }, [".c.png", "a.png", "b.png"])
    }
}
```

- [ ] **Step 6: Run them to verify they fail**

Run: `swift test --filter FSKitTests.CriteriaMatcherTests 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'SearchCriteria' in scope`.

- [ ] **Step 7: Implement `SearchCriteria`**

```swift
// Sources/FSKit/Search/SearchCriteria.swift
import Foundation
import UniformTypeIdentifiers

public enum KindFilter: String, Sendable, Codable, CaseIterable, Hashable {
    case folder, document, text, pdf, image, movie, audio, archive, application, code

    /// Shared by the in-memory matcher (UTType conformance) and Spotlight (kMDItemContentTypeTree).
    public var typeIdentifiers: [String] {
        switch self {
        case .folder: return ["public.folder"]
        case .document: return ["public.text", "com.adobe.pdf", "public.presentation", "public.spreadsheet",
                                "public.rtf", "com.apple.rtfd", "public.composite-content", "org.idpf.epub-container",
                                "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc"]
        case .text: return ["public.text"]
        case .pdf: return ["com.adobe.pdf"]
        case .image: return ["public.image"]
        case .movie: return ["public.movie"]
        case .audio: return ["public.audio"]
        case .archive: return ["public.archive"]
        case .application: return ["com.apple.application"]
        case .code: return ["public.source-code", "public.script"]
        }
    }
    public var utTypes: [UTType] { typeIdentifiers.compactMap { UTType($0) } }
}

public struct ByteRange: Sendable, Codable, Hashable {
    public var lower: Int64?
    public var upper: Int64?
    public init(lower: Int64? = nil, upper: Int64? = nil) { self.lower = lower; self.upper = upper }
    public func contains(_ value: Int64) -> Bool {
        if let lower, value < lower { return false }
        if let upper, value >= upper { return false }
        return true
    }
    public func intersection(_ other: ByteRange) -> ByteRange {
        ByteRange(lower: [lower, other.lower].compactMap { $0 }.max(), upper: [upper, other.upper].compactMap { $0 }.min())
    }
}

public struct TimeRange: Sendable, Codable, Hashable {
    public var lower: Int64?
    public var upper: Int64?
    public init(lower: Int64? = nil, upper: Int64? = nil) { self.lower = lower; self.upper = upper }
    public func contains(_ value: Int64) -> Bool {
        if let lower, value < lower { return false }
        if let upper, value >= upper { return false }
        return true
    }
    public func intersection(_ other: TimeRange) -> TimeRange {
        TimeRange(lower: [lower, other.lower].compactMap { $0 }.max(), upper: [upper, other.upper].compactMap { $0 }.min())
    }
}

public struct NameTerm: Sendable, Codable, Hashable {
    public var text: String
    public init(_ text: String) { self.text = text }
    public var isGlob: Bool { text.contains("*") || text.contains("?") }
}

public struct SearchCriteria: Sendable, Codable, Hashable {
    public var nameTerms: [NameTerm]
    public var kinds: Set<KindFilter>?
    public var extensions: Set<String>?
    public var size: ByteRange?
    public var modified: TimeRange?
    public var created: TimeRange?
    public init(nameTerms: [NameTerm] = [], kinds: Set<KindFilter>? = nil, extensions: Set<String>? = nil,
                size: ByteRange? = nil, modified: TimeRange? = nil, created: TimeRange? = nil) {
        self.nameTerms = nameTerms; self.kinds = kinds; self.extensions = extensions
        self.size = size; self.modified = modified; self.created = created
    }
    public var isEmpty: Bool {
        nameTerms.isEmpty && kinds == nil && extensions == nil && size == nil && modified == nil && created == nil
    }
}
```

- [ ] **Step 8: Implement `CriteriaMatcher`**

```swift
// Sources/FSKit/Search/CriteriaMatcher.swift
import Foundation
import UniformTypeIdentifiers

/// Pure, allocation-free per entry after the first sighting of each (typeIndex, kind). Not shared across
/// threads: each permutation / crawler read creates its own (it is a value type with a small cache).
public struct CriteriaMatcher: Sendable {
    private let criteria: SearchCriteria
    private let patterns: [NamePattern]
    private let extensions: [[UInt8]]?
    private let kinds: [(KindFilter, [UTType])]?
    private let types: TypeRegistry
    private var kindCache: [UInt32: Bool] = [:]

    public init(_ criteria: SearchCriteria, types: TypeRegistry) {
        self.criteria = criteria
        self.types = types
        self.patterns = criteria.nameTerms.map { NamePattern($0.text) }
        self.extensions = criteria.extensions.map { set in set.sorted().map { SortKeys.searchFold($0) } }
        self.kinds = criteria.kinds.map { set in set.sorted { $0.rawValue < $1.rawValue }.map { ($0, $0.utTypes) } }
    }

    public mutating func matches(_ entry: Entry, foldedName: UnsafeRawBufferPointer) -> Bool {
        for pattern in patterns where !pattern.matches(foldedName) { return false }
        if let range = criteria.size {
            if entry.kind == .directory || entry.kind == .package { return false }
            if !range.contains(entry.size) { return false }
        }
        if let range = criteria.modified, !range.contains(entry.mtime) { return false }
        if let range = criteria.created, !range.contains(entry.ctime) { return false }
        if let extensions {
            guard let ext = Self.foldedExtension(foldedName),
                  extensions.contains(where: { $0.elementsEqual(ext) }) else { return false }
        }
        if let kinds, !kindMatches(entry, kinds) { return false }
        return true
    }

    private mutating func kindMatches(_ entry: Entry, _ kinds: [(KindFilter, [UTType])]) -> Bool {
        let key = UInt32(entry.typeIndex) << 8 | UInt32(entry.kind.rawValue)
        if let hit = kindCache[key] { return hit }
        let type = types.type(at: entry.typeIndex)
        let result = kinds.contains { filter, roots in
            switch filter {
            case .folder: return entry.kind == .directory
            default: return entry.kind != .directory && roots.contains { type.conforms(to: $0) }
            }
        }
        kindCache[key] = result
        return result
    }

    /// Bytes after the last "." of a folded name; nil when there is none, it is the first byte, or it is last.
    static func foldedExtension(_ folded: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer? {
        guard let dot = folded.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < folded.count - 1 else { return nil }
        return UnsafeRawBufferPointer(rebasing: folded[(dot + 1)...])
    }
}
```

- [ ] **Step 9: Wire criteria into `ViewQuery`, `Sorter` and `FolderWorker`**

In `Sources/FSKit/Sort/ViewQuery.swift` add the stored property and extend the initializer (existing call sites keep compiling because of the default):

```swift
public struct ViewQuery: Sendable, Hashable {
    public var sort: SortDescriptor
    public var showHidden: Bool
    public var filter: String                             // "" = no filter (Phase 1 substring filter)
    public var criteria: SearchCriteria?                  // Phase 3: nil = none; applied after `filter`
    public init(sort: SortDescriptor = .default, showHidden: Bool = false, filter: String = "", criteria: SearchCriteria? = nil) {
        self.sort = sort; self.showHidden = showHidden; self.filter = filter; self.criteria = criteria
    }
}
```

In `Sources/FSKit/Sort/Sorter.swift`, add `types: TypeRegistry = .shared` as the last parameter of `permutation`, `merge` and Phase 2's `permutation(…, extras:)`, and in the visibility pass (where Phase 1 tests hidden rows and `query.filter`) add:

```swift
var matcher = query.criteria.map { CriteriaMatcher($0, types: types) }
// inside the per-index visibility loop, after the hidden and `filter` checks:
if matcher != nil {
    guard let searchKeys else { preconditionFailure("criteria requires searchKeys") }
    let ok = searchKeys.withKey(Int(index)) { matcher!.matches(store.entry(index), foldedName: $0) }
    if !ok { continue }
}
```

In `Sources/Core/Folder/FolderWorker.swift`, change the condition that builds `SortKeys.searchKeys(store)` from `!query.filter.isEmpty` to `!query.filter.isEmpty || query.criteria != nil`, and pass `types: context.types` through to `Sorter`.

- [ ] **Step 10: Run the MacxFS and FolderModel tests**

Run: `swift test --filter "FSKitTests.CriteriaMatcherTests|FSKitTests.NamePatternTests|FSKitTests.SorterTests|CoreTests.FolderModelTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures` (Phase 1 `SorterTests`/`FolderModelTests` unchanged and green).

- [ ] **Step 11: Build with zero warnings and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`, no warnings.

```bash
git add Sources/FSKit/Search Sources/FSKit/Sort/ViewQuery.swift Sources/FSKit/Sort/Sorter.swift Sources/Core/Folder/FolderWorker.swift Tests/FSKitTests/NamePatternTests.swift Tests/FSKitTests/CriteriaMatcherTests.swift
git commit -m "feat: search criteria, name globs and criteria matching in Sorter"
```

---

### Task P3-02: Query syntax, date ranges, search spec

**Files:**
- Create: `Sources/Core/Search/QuerySyntax.swift`, `Sources/Core/Search/DateRanges.swift`, `Sources/Core/Search/SearchSpec.swift`, `Sources/Core/Search/SearchResolver.swift`
- Test: `Tests/CoreTests/Search/QuerySyntaxTests.swift`, `Tests/CoreTests/Search/DateRangesTests.swift`, `Tests/CoreTests/Search/SearchSpecTests.swift`

**Interfaces:**
- Consumes: `SearchCriteria`, `NameTerm`, `KindFilter`, `ByteRange`, `TimeRange` (P3-01).
- Produces: `QuerySyntax.parse(_:) -> ParsedQuery`, `SyntaxDiagnostic`, `SizeWord`, `RelativeDay`, `DayStamp`, `DayBound`, `DateToken`, `DateRanges.range(_:now:calendar:)`, `SearchScope`, `SearchMode`, `SearchFilters`, `SearchSpec` (+ `url`, `init?(url:)`), `ResolvedSearch`, `SearchResolver.resolve(_:now:calendar:)`.

**Syntax (documented in README by P3-13):**

| Token | Meaning |
|---|---|
| `word`, `"two words"` | name term (Name mode) or content term (Contents mode); terms are ANDed; `*`/`?` make it a whole-name glob |
| `name:x`, `name:"a b"` | name term in both modes |
| `kind:` / `type:` + `folder(s) directory document(s) doc(s) text pdf image(s) picture(s) photo(s) movie(s) video(s) audio music sound archive(s) zip app(s) application(s) program(s) code source`, comma-separated | OR within one token and across repeated `kind:` tokens |
| `ext:` / `extension:` + `pdf`, `.pdf`, `*.pdf`, `jpg,png` | OR, lowercased |
| `size:` + `>10MB` `>=1.5GB` `<1KB` `<=100` `=0` `1MB..10MB` (inclusive) `10MB` (±0.5 unit) `empty tiny small medium large huge gigantic` | repeated `size:` tokens intersect |
| `modified:` / `datemodified:` / `date:`, `created:` / `datecreated:` + `today yesterday thisweek "this week" lastweek thismonth lastmonth thisyear lastyear last7days last30days`, `2026-01-31`, `>2026-01-31`, `>=`, `<`, `<=`, `2026-01-01..2026-01-31` | repeated tokens intersect |
| unknown key (`foo:bar`), quoted `"kind:image"` | literal term |
| known key with bad value (`size:big`, `kind:spaceship`, `modified:2026-02-30`) or empty value (`kind:`) | ignored plus a `SyntaxDiagnostic` (UI shows "Didn't understand 'size:big'") |

Size words (decimal, matching displayed sizes): empty `[0,1)`, tiny `[1,16 KB)`, small `[16 KB,1 MB)`, medium `[1 MB,128 MB)`, large `[128 MB,1 GB)`, huge `[1 GB,4 GB)`, gigantic `[4 GB,∞)`. Units: `B`/none 1, `K`/`KB` 10³, `M`/`MB` 10⁶, `G`/`GB` 10⁹, `T`/`TB` 10¹², `KiB` 2¹⁰, `MiB` 2²⁰, `GiB` 2³⁰, `TiB` 2⁴⁰ (case-insensitive).

- [ ] **Step 1: Write the failing syntax tests**

```swift
// Tests/CoreTests/Search/QuerySyntaxTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class QuerySyntaxTests: XCTestCase {
    func testFreeTermsAndQuotes() {
        let q = QuerySyntax.parse(#"  budget "Q3 final"  *.xlsx "#)
        XCTAssertEqual(q.freeTerms, ["budget", "Q3 final", "*.xlsx"])
        XCTAssertTrue(q.diagnostics.isEmpty)
    }
    func testNameKindExt() {
        let q = QuerySyntax.parse(#"name:"tax return" kind:pdf,image type:folders ext:.JPG,*.png"#)
        XCTAssertEqual(q.nameTerms, ["tax return"])
        XCTAssertEqual(q.kinds, [.pdf, .image, .folder])
        XCTAssertEqual(q.extensions, ["jpg", "png"])
    }
    func testKeysAreCaseInsensitiveAndUnknownKeysAreLiteral() {
        let q = QuerySyntax.parse("KIND:Image foo:bar \"ext:pdf\" :x")
        XCTAssertEqual(q.kinds, [.image])
        XCTAssertEqual(q.freeTerms, ["foo:bar", "ext:pdf", ":x"])
        XCTAssertTrue(q.extensions.isEmpty)
    }
    func testSizes() {
        XCTAssertEqual(QuerySyntax.parse("size:>10MB").size, ByteRange(lower: 10_000_001))
        XCTAssertEqual(QuerySyntax.parse("size:>=1.5gb").size, ByteRange(lower: 1_500_000_000))
        XCTAssertEqual(QuerySyntax.parse("size:<1KB").size, ByteRange(upper: 1_000))
        XCTAssertEqual(QuerySyntax.parse("size:<=100").size, ByteRange(upper: 101))
        XCTAssertEqual(QuerySyntax.parse("size:=0").size, ByteRange(lower: 0, upper: 1))
        XCTAssertEqual(QuerySyntax.parse("size:1MB..10MB").size, ByteRange(lower: 1_000_000, upper: 10_000_001))
        XCTAssertEqual(QuerySyntax.parse("size:10MB").size, ByteRange(lower: 9_500_000, upper: 10_500_000))
        XCTAssertEqual(QuerySyntax.parse("size:1KiB").size, ByteRange(lower: 512, upper: 1_536))
        XCTAssertEqual(QuerySyntax.parse("size:empty").size, ByteRange(lower: 0, upper: 1))
        XCTAssertEqual(QuerySyntax.parse("size:gigantic").size, ByteRange(lower: 4_000_000_000))
        XCTAssertEqual(QuerySyntax.parse("size:>1MB size:<5MB").size, ByteRange(lower: 1_000_001, upper: 5_000_000))
    }
    func testDates() {
        XCTAssertEqual(QuerySyntax.parse("modified:today").modified, [.relative(.today)])
        XCTAssertEqual(QuerySyntax.parse(#"date:"this week""#).modified, [.relative(.thisWeek)])
        XCTAssertEqual(QuerySyntax.parse("created:LastMonth").created, [.relative(.lastMonth)])
        let d = DayStamp(year: 2026, month: 1, day: 31)
        XCTAssertEqual(QuerySyntax.parse("modified:2026-01-31").modified,
                       [.days(lower: DayBound(day: d, inclusive: true), upper: DayBound(day: d, inclusive: true))])
        XCTAssertEqual(QuerySyntax.parse("modified:>2026-01-31").modified, [.days(lower: DayBound(day: d, inclusive: false), upper: nil)])
        XCTAssertEqual(QuerySyntax.parse("modified:<=2026/01/31").modified, [.days(lower: nil, upper: DayBound(day: d, inclusive: true))])
        let a = DayStamp(year: 2026, month: 1, day: 1)
        XCTAssertEqual(QuerySyntax.parse("modified:2026-01-01..2026-01-31").modified,
                       [.days(lower: DayBound(day: a, inclusive: true), upper: DayBound(day: d, inclusive: true))])
    }
    func testDiagnostics() {
        let q = QuerySyntax.parse("size:big kind:spaceship,image modified:2026-02-30 ext: report")
        XCTAssertEqual(q.diagnostics, [
            SyntaxDiagnostic(token: "size:big", problem: .badSize),
            SyntaxDiagnostic(token: "kind:spaceship,image", problem: .badKind),
            SyntaxDiagnostic(token: "modified:2026-02-30", problem: .badDate),
            SyntaxDiagnostic(token: "ext:", problem: .emptyValue),
        ])
        XCTAssertEqual(q.kinds, [.image])            // known words in a partly bad token still apply
        XCTAssertEqual(q.freeTerms, ["report"])
        XCTAssertNil(q.size)
        XCTAssertTrue(q.modified.isEmpty)
    }
    func testUnbalancedQuoteTakesRestOfText() {
        XCTAssertEqual(QuerySyntax.parse(#"a "b c"#).freeTerms, ["a", "b c"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CoreTests.QuerySyntaxTests 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'QuerySyntax' in scope`.

- [ ] **Step 3: Implement `DateRanges` types (needed by the parser) and `QuerySyntax`**

```swift
// Sources/Core/Search/DateRanges.swift
import Foundation
import MacxFS

public enum RelativeDay: String, Sendable, Codable, CaseIterable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear, last7Days, last30Days
}
public struct DayStamp: Sendable, Codable, Hashable {
    public var year: Int, month: Int, day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    /// "YYYY-MM-DD" or "YYYY/MM/DD", proleptic Gregorian validity (leap years included).
    public init?(parsing text: String) {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= DayStamp.daysIn(month: m, year: y) else { return nil }
        self.init(year: y, month: m, day: d)
    }
    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}
public struct DayBound: Sendable, Codable, Hashable {
    public var day: DayStamp
    public var inclusive: Bool
    public init(day: DayStamp, inclusive: Bool) { self.day = day; self.inclusive = inclusive }
}
public enum DateToken: Sendable, Codable, Hashable {
    case relative(RelativeDay)
    case days(lower: DayBound?, upper: DayBound?)
}

public enum DateRanges {
    public static func range(_ token: DateToken, now: Date, calendar: Calendar) -> TimeRange {
        switch token {
        case .relative(let r):
            let (a, b) = interval(r, now: now, calendar: calendar)
            return TimeRange(lower: ns(a), upper: ns(b))
        case .days(let lower, let upper):
            return TimeRange(lower: lower.map { ns(start($0.day, offsetDays: $0.inclusive ? 0 : 1, calendar)) },
                             upper: upper.map { ns(start($0.day, offsetDays: $0.inclusive ? 1 : 0, calendar)) })
        }
    }

    static func ns(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded()) }

    static func start(_ day: DayStamp, offsetDays: Int, _ calendar: Calendar) -> Date {
        let base = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        return calendar.date(byAdding: .day, value: offsetDays, to: calendar.startOfDay(for: base))!
    }

    static func interval(_ r: RelativeDay, now: Date, calendar c: Calendar) -> (Date, Date) {
        let today = c.startOfDay(for: now)
        func add(_ unit: Calendar.Component, _ n: Int, _ d: Date) -> Date { c.date(byAdding: unit, value: n, to: d)! }
        func of(_ unit: Calendar.Component, _ d: Date) -> (Date, Date) {
            let i = c.dateInterval(of: unit, for: d)!
            return (i.start, i.end)
        }
        switch r {
        case .today: return (today, add(.day, 1, today))
        case .yesterday: return (add(.day, -1, today), today)
        case .thisWeek: return of(.weekOfYear, now)
        case .lastWeek: return of(.weekOfYear, add(.day, -7, of(.weekOfYear, now).0))
        case .thisMonth: return of(.month, now)
        case .lastMonth: return of(.month, add(.day, -1, of(.month, now).0))
        case .thisYear: return of(.year, now)
        case .lastYear: return of(.year, add(.day, -1, of(.year, now).0))
        case .last7Days: return (add(.day, -6, today), add(.day, 1, today))
        case .last30Days: return (add(.day, -29, today), add(.day, 1, today))
        }
    }
}
```

```swift
// Sources/Core/Search/QuerySyntax.swift
import Foundation
import MacxFS

public enum SizeWord: String, Sendable, CaseIterable {
    case empty, tiny, small, medium, large, huge, gigantic
    public var range: ByteRange {
        switch self {
        case .empty: return ByteRange(lower: 0, upper: 1)
        case .tiny: return ByteRange(lower: 1, upper: 16_000)
        case .small: return ByteRange(lower: 16_000, upper: 1_000_000)
        case .medium: return ByteRange(lower: 1_000_000, upper: 128_000_000)
        case .large: return ByteRange(lower: 128_000_000, upper: 1_000_000_000)
        case .huge: return ByteRange(lower: 1_000_000_000, upper: 4_000_000_000)
        case .gigantic: return ByteRange(lower: 4_000_000_000)
        }
    }
}

public struct SyntaxDiagnostic: Sendable, Codable, Equatable {
    public enum Problem: String, Sendable, Codable { case badSize, badDate, badKind, emptyValue }
    public var token: String
    public var problem: Problem
    public init(token: String, problem: Problem) { self.token = token; self.problem = problem }
}

public struct ParsedQuery: Sendable, Equatable {
    public var freeTerms: [String] = []
    public var nameTerms: [String] = []
    public var kinds: Set<KindFilter> = []
    public var extensions: Set<String> = []
    public var size: ByteRange? = nil
    public var modified: [DateToken] = []
    public var created: [DateToken] = []
    public var diagnostics: [SyntaxDiagnostic] = []
    public init() {}
}

public enum QuerySyntax {
    struct RawToken: Equatable { var text: String; var quoted: Bool }

    enum Key { case name, kind, ext, size, modified, created
        init?(_ raw: String) {
            switch raw.lowercased() {
            case "name": self = .name
            case "kind", "type": self = .kind
            case "ext", "extension": self = .ext
            case "size": self = .size
            case "modified", "datemodified", "date": self = .modified
            case "created", "datecreated": self = .created
            default: return nil
            }
        }
    }

    static let kindWords: [String: KindFilter] = [
        "folder": .folder, "folders": .folder, "directory": .folder,
        "document": .document, "documents": .document, "doc": .document, "docs": .document,
        "text": .text, "pdf": .pdf,
        "image": .image, "images": .image, "picture": .image, "pictures": .image, "photo": .image, "photos": .image,
        "movie": .movie, "movies": .movie, "video": .movie, "videos": .movie,
        "audio": .audio, "music": .audio, "sound": .audio,
        "archive": .archive, "archives": .archive, "zip": .archive,
        "app": .application, "apps": .application, "application": .application, "applications": .application,
        "program": .application, "programs": .application,
        "code": .code, "source": .code,
    ]

    static let relativeWords: [String: RelativeDay] = [
        "today": .today, "yesterday": .yesterday, "thisweek": .thisWeek, "lastweek": .lastWeek,
        "thismonth": .thisMonth, "lastmonth": .lastMonth, "thisyear": .thisYear, "lastyear": .lastYear,
        "last7days": .last7Days, "last30days": .last30Days,
    ]

    public static func parse(_ text: String) -> ParsedQuery {
        var q = ParsedQuery()
        for token in tokenize(text) where !token.text.isEmpty {
            guard !token.quoted, let colon = token.text.firstIndex(of: ":"), colon != token.text.startIndex,
                  let key = Key(String(token.text[..<colon])) else {
                q.freeTerms.append(token.text); continue
            }
            let value = String(token.text[token.text.index(after: colon)...])
            if value.isEmpty { q.diagnostics.append(.init(token: token.text, problem: .emptyValue)); continue }
            switch key {
            case .name:
                q.nameTerms.append(value)
            case .kind:
                var bad = false
                for word in value.lowercased().split(separator: ",") {
                    if let k = kindWords[String(word)] { q.kinds.insert(k) } else { bad = true }
                }
                if bad { q.diagnostics.append(.init(token: token.text, problem: .badKind)) }
            case .ext:
                for raw in value.lowercased().split(separator: ",") {
                    var e = Substring(raw)
                    if e.hasPrefix("*.") { e = e.dropFirst(2) } else if e.hasPrefix(".") { e = e.dropFirst() }
                    if !e.isEmpty { q.extensions.insert(String(e)) }
                }
            case .size:
                if let r = parseSize(value) { q.size = q.size.map { $0.intersection(r) } ?? r }
                else { q.diagnostics.append(.init(token: token.text, problem: .badSize)) }
            case .modified, .created:
                guard let d = parseDate(value) else { q.diagnostics.append(.init(token: token.text, problem: .badDate)); continue }
                if key == .modified { q.modified.append(d) } else { q.created.append(d) }
            }
        }
        return q
    }

    static func tokenize(_ s: String) -> [RawToken] {
        var out: [RawToken] = []
        var cur = "", inQuote = false, startedQuoted = false, hasContent = false
        for ch in s {
            if ch == "\"" {
                if !inQuote && !hasContent { startedQuoted = true }
                inQuote.toggle(); hasContent = true
                continue
            }
            if ch.isWhitespace && !inQuote {
                if hasContent { out.append(RawToken(text: cur, quoted: startedQuoted)) }
                cur = ""; hasContent = false; startedQuoted = false
                continue
            }
            cur.append(ch); hasContent = true
        }
        if hasContent { out.append(RawToken(text: cur, quoted: startedQuoted)) }
        return out
    }

    static func unit(_ suffix: String) -> Double? {
        switch suffix {
        case "", "b", "byte", "bytes": return 1
        case "k", "kb": return 1e3
        case "m", "mb": return 1e6
        case "g", "gb": return 1e9
        case "t", "tb": return 1e12
        case "kib": return 1024
        case "mib": return 1_048_576
        case "gib": return 1_073_741_824
        case "tib": return 1_099_511_627_776
        default: return nil
        }
    }

    /// Returns (bytes, unitSize) for "1.5MB", "100", "1KiB".
    static func numberWithUnit(_ s: String) -> (bytes: Int64, unit: Double)? {
        let digits = s.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let value = Double(digits), value >= 0,
              let u = unit(String(s.dropFirst(digits.count))) else { return nil }
        return (Int64((value * u).rounded()), u)
    }

    static func parseSize(_ raw: String) -> ByteRange? {
        let s = raw.lowercased()
        if let w = SizeWord(rawValue: s) { return w.range }
        if let dots = s.range(of: "..") {
            guard let a = numberWithUnit(String(s[..<dots.lowerBound])), let b = numberWithUnit(String(s[dots.upperBound...])),
                  a.bytes <= b.bytes else { return nil }
            return ByteRange(lower: a.bytes, upper: b.bytes + 1)
        }
        for op in [">=", "<=", ">", "<", "="] where s.hasPrefix(op) {
            guard let v = numberWithUnit(String(s.dropFirst(op.count)))?.bytes else { return nil }
            switch op {
            case ">=": return ByteRange(lower: v)
            case "<=": return ByteRange(upper: v + 1)
            case ">": return ByteRange(lower: v + 1)
            case "<": return ByteRange(upper: v)
            default: return ByteRange(lower: v, upper: v + 1)
            }
        }
        guard let (v, u) = numberWithUnit(s) else { return nil }
        if u == 1 { return ByteRange(lower: v, upper: v + 1) }
        let half = Int64((u / 2).rounded())
        return ByteRange(lower: max(0, v - half), upper: v + half)
    }

    static func parseDate(_ raw: String) -> DateToken? {
        let lowered = raw.lowercased()
        let word = lowered.filter { $0 != " " && $0 != "-" && $0 != "_" }
        if let r = relativeWords[word] { return .relative(r) }
        if let dots = lowered.range(of: "..") {
            guard let a = DayStamp(parsing: String(lowered[..<dots.lowerBound])),
                  let b = DayStamp(parsing: String(lowered[dots.upperBound...])) else { return nil }
            return .days(lower: DayBound(day: a, inclusive: true), upper: DayBound(day: b, inclusive: true))
        }
        for op in [">=", "<=", ">", "<"] where lowered.hasPrefix(op) {
            guard let d = DayStamp(parsing: String(lowered.dropFirst(op.count))) else { return nil }
            switch op {
            case ">=": return .days(lower: DayBound(day: d, inclusive: true), upper: nil)
            case ">": return .days(lower: DayBound(day: d, inclusive: false), upper: nil)
            case "<=": return .days(lower: nil, upper: DayBound(day: d, inclusive: true))
            default: return .days(lower: nil, upper: DayBound(day: d, inclusive: false))
            }
        }
        guard let d = DayStamp(parsing: lowered) else { return nil }
        return .days(lower: DayBound(day: d, inclusive: true), upper: DayBound(day: d, inclusive: true))
    }
}
```

- [ ] **Step 4: Run the syntax tests**

Run: `swift test --filter CoreTests.QuerySyntaxTests 2>&1 | tail -5`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Write the failing date-range and spec tests**

```swift
// Tests/CoreTests/Search/DateRangesTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class DateRangesTests: XCTestCase {
    // Wednesday 2026-11-04 15:00 UTC; weeks start on Monday.
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 2; return c }()
    let now = ISO8601DateFormatter().date(from: "2026-11-04T15:00:00Z")!
    func day(_ s: String) -> Int64 { DateRanges.ns(ISO8601DateFormatter().date(from: s + "T00:00:00Z")!) }
    func r(_ t: DateToken) -> TimeRange { DateRanges.range(t, now: now, calendar: cal) }

    func testRelativeRanges() {
        XCTAssertEqual(r(.relative(.today)), TimeRange(lower: day("2026-11-04"), upper: day("2026-11-05")))
        XCTAssertEqual(r(.relative(.yesterday)), TimeRange(lower: day("2026-11-03"), upper: day("2026-11-04")))
        XCTAssertEqual(r(.relative(.thisWeek)), TimeRange(lower: day("2026-11-02"), upper: day("2026-11-09")))
        XCTAssertEqual(r(.relative(.lastWeek)), TimeRange(lower: day("2026-10-26"), upper: day("2026-11-02")))
        XCTAssertEqual(r(.relative(.thisMonth)), TimeRange(lower: day("2026-11-01"), upper: day("2026-12-01")))
        XCTAssertEqual(r(.relative(.lastMonth)), TimeRange(lower: day("2026-10-01"), upper: day("2026-11-01")))
        XCTAssertEqual(r(.relative(.thisYear)), TimeRange(lower: day("2026-01-01"), upper: day("2027-01-01")))
        XCTAssertEqual(r(.relative(.lastYear)), TimeRange(lower: day("2025-01-01"), upper: day("2026-01-01")))
        XCTAssertEqual(r(.relative(.last7Days)), TimeRange(lower: day("2026-10-29"), upper: day("2026-11-05")))
    }
    func testDayBounds() {
        let d = DayStamp(year: 2026, month: 1, day: 31)
        XCTAssertEqual(r(.days(lower: DayBound(day: d, inclusive: true), upper: DayBound(day: d, inclusive: true))),
                       TimeRange(lower: day("2026-01-31"), upper: day("2026-02-01")))
        XCTAssertEqual(r(.days(lower: DayBound(day: d, inclusive: false), upper: nil)), TimeRange(lower: day("2026-02-01")))
        XCTAssertEqual(r(.days(lower: nil, upper: DayBound(day: d, inclusive: false))), TimeRange(upper: day("2026-01-31")))
    }
    func testLeapDayValidation() {
        XCTAssertNotNil(DayStamp(parsing: "2028-02-29"))
        XCTAssertNil(DayStamp(parsing: "2026-02-29"))
        XCTAssertNil(DayStamp(parsing: "2026-13-01"))
        XCTAssertNil(DayStamp(parsing: "26-01-01"))
    }
}
```

```swift
// Tests/CoreTests/Search/SearchSpecTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class SearchSpecTests: XCTestCase {
    let root = URL(filePath: "/tmp/macx-tests-x/root", directoryHint: .isDirectory)
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    let now = ISO8601DateFormatter().date(from: "2026-11-04T15:00:00Z")!

    func testURLRoundTripIsLosslessAndDeterministic() {
        let spec = SearchSpec(text: #"report "Q3" size:>1MB"#, scope: .subfolders, mode: .contents,
                              filters: SearchFilters(kinds: [.pdf, .image], extensions: ["pdf"], size: ByteRange(lower: 5),
                                                     modified: .relative(.thisWeek), created: nil), root: root)
        let url = spec.url
        XCTAssertEqual(url.scheme, SearchSpec.urlScheme)
        XCTAssertEqual(SearchSpec(url: url), spec)
        XCTAssertEqual(spec.url, url)                      // sorted keys → same URL every time
        XCTAssertNil(SearchSpec(url: URL(string: "x-macexplorer-search:?v=1&q=%%%")!))
        XCTAssertNil(SearchSpec(url: URL(filePath: "/tmp")))
    }

    func testResolveNameModeMergesSyntaxAndFilters() {
        let spec = SearchSpec(text: "tax kind:pdf,image size:>1KB modified:thismonth", scope: .thisFolder,
                              filters: SearchFilters(kinds: [.pdf], size: ByteRange(upper: 1_000_000), modified: .relative(.today)),
                              root: root)
        let r = SearchResolver.resolve(spec, now: now, calendar: cal)
        XCTAssertEqual(r.criteria.nameTerms, [NameTerm("tax")])
        XCTAssertEqual(r.criteria.kinds, [.pdf])                                // intersection
        XCTAssertEqual(r.criteria.size, ByteRange(lower: 1_001, upper: 1_000_000))
        XCTAssertEqual(r.criteria.modified, DateRanges.range(.relative(.today), now: now, calendar: cal))  // today ⊂ this month
        XCTAssertTrue(r.contentTerms.isEmpty)
        XCTAssertFalse(r.isEmpty)
    }

    func testResolveContentsModeKeepsFreeTermsForContent() {
        let r = SearchResolver.resolve(SearchSpec(text: "invoice name:2025", scope: .subfolders, mode: .contents, root: root),
                                       now: now, calendar: cal)
        XCTAssertEqual(r.contentTerms, ["invoice"])
        XCTAssertEqual(r.criteria.nameTerms, [NameTerm("2025")])
    }

    func testDisjointKindsMatchNothingRatherThanEverything() {
        let r = SearchResolver.resolve(SearchSpec(text: "kind:image", scope: .thisFolder, filters: SearchFilters(kinds: [.pdf]), root: root),
                                       now: now, calendar: cal)
        XCTAssertEqual(r.criteria.kinds, [])
    }

    func testEmptyQuery() {
        XCTAssertTrue(SearchSpec(text: "   ", scope: .subfolders, root: root).isEmptyQuery)
        XCTAssertTrue(SearchResolver.resolve(SearchSpec(text: "kind:", scope: .thisFolder, root: root), now: now, calendar: cal).isEmpty)
        XCTAssertFalse(SearchSpec(text: "", scope: .subfolders, filters: SearchFilters(kinds: [.image]), root: root).isEmptyQuery)
    }
}
```

- [ ] **Step 6: Run to verify failure**

Run: `swift test --filter "CoreTests.DateRangesTests|CoreTests.SearchSpecTests" 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'SearchSpec' in scope` (DateRanges tests compile already).

- [ ] **Step 7: Implement `SearchSpec` and `SearchResolver`**

```swift
// Sources/Core/Search/SearchSpec.swift
import Foundation
import MacxFS

public enum SearchScope: String, Sendable, Codable, CaseIterable { case thisFolder, subfolders, thisMac }
public enum SearchMode: String, Sendable, Codable, CaseIterable { case name, contents }

public struct SearchFilters: Sendable, Codable, Hashable {
    public var kinds: Set<KindFilter>
    public var extensions: Set<String>
    public var size: ByteRange?
    public var modified: DateToken?
    public var created: DateToken?
    public init(kinds: Set<KindFilter> = [], extensions: Set<String> = [], size: ByteRange? = nil,
                modified: DateToken? = nil, created: DateToken? = nil) {
        self.kinds = kinds; self.extensions = extensions; self.size = size; self.modified = modified; self.created = created
    }
    public var isEmpty: Bool { kinds.isEmpty && extensions.isEmpty && size == nil && modified == nil && created == nil }
}

public struct SearchSpec: Sendable, Codable, Hashable {
    public var text: String
    public var scope: SearchScope
    public var mode: SearchMode
    public var filters: SearchFilters
    public var root: URL
    public init(text: String, scope: SearchScope, mode: SearchMode = .name, filters: SearchFilters = SearchFilters(), root: URL) {
        self.text = text; self.scope = scope; self.mode = mode; self.filters = filters; self.root = root
    }

    public static let urlScheme = "x-macexplorer-search"

    /// Internal history/saved-search URL; never handed to NSWorkspace. "x-macexplorer-search:?v=1&q=<base64url JSON>".
    public var url: URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(Self.urlScheme):?v=1&q=\(b64)")!
    }

    public init?(url: URL) {
        guard url.scheme == Self.urlScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "v" })?.value == "1",
              var b64 = items.first(where: { $0.name == "q" })?.value else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let spec = try? JSONDecoder().decode(SearchSpec.self, from: data) else { return nil }
        self = spec
    }

    public var isEmptyQuery: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && filters.isEmpty }
}
```

```swift
// Sources/Core/Search/SearchResolver.swift
import Foundation
import MacxFS

public struct ResolvedSearch: Sendable, Equatable {
    public var criteria: SearchCriteria
    public var contentTerms: [String]
    public var diagnostics: [SyntaxDiagnostic]
    public var isEmpty: Bool { criteria.isEmpty && contentTerms.isEmpty }
}

public enum SearchResolver {
    public static func resolve(_ spec: SearchSpec, now: Date, calendar: Calendar) -> ResolvedSearch {
        let p = QuerySyntax.parse(spec.text)
        let nameTerms = spec.mode == .contents ? p.nameTerms : p.freeTerms + p.nameTerms
        let contentTerms = spec.mode == .contents ? p.freeTerms : []
        var size = p.size
        if let f = spec.filters.size { size = size.map { $0.intersection(f) } ?? f }
        func dates(_ tokens: [DateToken]) -> TimeRange? {
            tokens.map { DateRanges.range($0, now: now, calendar: calendar) }.reduce(nil) { acc, r in acc.map { $0.intersection(r) } ?? r }
        }
        let criteria = SearchCriteria(
            nameTerms: nameTerms.map(NameTerm.init),
            kinds: merge(p.kinds, spec.filters.kinds),
            extensions: merge(p.extensions, Set(spec.filters.extensions.map { $0.lowercased() })),
            size: size,
            modified: dates(p.modified + [spec.filters.modified].compactMap { $0 }),
            created: dates(p.created + [spec.filters.created].compactMap { $0 }))
        return ResolvedSearch(criteria: criteria, contentTerms: contentTerms, diagnostics: p.diagnostics)
    }

    /// Empty = unconstrained. Both constrained → intersection (possibly empty = match nothing).
    static func merge<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Set<T>? {
        switch (a.isEmpty, b.isEmpty) {
        case (true, true): return nil
        case (false, true): return a
        case (true, false): return b
        case (false, false): return a.intersection(b)
        }
    }
}
```

- [ ] **Step 8: Run the P3-02 tests**

Run: `swift test --filter "CoreTests.QuerySyntaxTests|CoreTests.DateRangesTests|CoreTests.SearchSpecTests" 2>&1 | tail -5`
Expected: `Executed 15 tests, with 0 failures`.

- [ ] **Step 9: Build and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`.

```bash
git add Sources/Core/Search/QuerySyntax.swift Sources/Core/Search/DateRanges.swift Sources/Core/Search/SearchSpec.swift Sources/Core/Search/SearchResolver.swift Tests/CoreTests/Search
git commit -m "feat: Explorer-style search syntax, date ranges and search spec"
```

---

### Task P3-03: Row sources, search result store, history replacement

**Files:**
- Create: `Sources/Core/Folder/RowSource.swift`, `Sources/Core/Folder/FolderModel+RowSource.swift`, `Sources/Core/Search/SearchTypes.swift`, `Sources/Core/Search/SearchResultStore.swift`
- Modify: `Sources/Core/Folder/Selection.swift` (shared mutators), `Sources/Core/Folder/FolderModel.swift` (call the shared mutators), `Sources/Core/Navigation/NavigationHistory.swift` (`replaceCurrent`), `Sources/Core/Support/ChangeBus.swift` (only if `observeAll` is missing)
- Test: `Tests/CoreTests/Search/SearchResultStoreTests.swift`, `Tests/CoreTests/Search/RowSourceTests.swift`

**Interfaces:**
- Consumes: `FolderModel`, `FolderEvent`, `Selection`, `SelectionCommand`, `SelectionSummary`, `NameValidation`, `NameRules`, `ObserverToken`, `Observers`, `ChangeSet`, `ChangeBus`, `LocalChange`, `NavigationHistory` (Phase 1 §3.7/§3.10); `EntryStore`, `Batch`, `Entry`, `RowID`, `TypeRegistry`, `SortKeys.nameKeys(_:range:)`, `SortKeyColumn` (§3.3/§3.5); `SortDescriptor`, `ViewQuery`; Phase 2's `SelectionSummary.folderBytes` and `FolderEvent.groups/folderSizes/extendedAttributes`.
- Produces: `RowSource`, `RowSourceEvent`, `FolderModel: RowSource`; `SearchBatch`, `SearchProgress`, `SkipReason`, `SkippedLocation`, `SearchSummary`, `SearchFailure`, `SearchNotice`, `SearchEvent`; `SearchResultStore`; `NavigationHistory.replaceCurrent(_:)`; internal `SelectionRowSpace` and `Selection.apply(_:in:)` / `Selection.reconcile(in:)` (used by `FolderModel` and, from P3-06, `SearchResultsModel`).

**Design notes:**
- `SearchResultStore` wraps an `EntryStore(identityMode: .objectID)` whose identity map is never consulted (inode numbers repeat across volumes). Identity is the standardized full path, `RowID.name(path)`, kept in `pathIndex: [String: UInt32]`. Each entry has a parent index into `parents: [String]` (deduplicated with `parentLookup`).
- `nameKeys` is computed in `append` with `SortKeys.nameKeys(store, range:)`, which uses `concurrentPerform`; a 2,000-name batch costs about 1 ms on the main actor. Removal mirrors `EntryStore.remove` with `SortKeyColumn.remove`. Both compactions keep survivors in their relative order, which `testRemoveKeepsColumnsAligned` pins.
- `append` replaces an existing path: it removes the old index first (compaction; `EntryStore.remove` remaps `order`), then appends the whole batch. The returned indices are the appended storage indices, contiguous at the end.
- `rename(path:to:types:)` is remove + append of a re-typed entry (new name, new `typeIndex` from the new extension). The caller (P3-06) merges the new index into the order.
- `ChangeBus.observeAll` already exists after Phase 2 P2-13. This task only adds a test for it. If `grep -n "func observeAll" Sources/Core/Support/ChangeBus.swift` finds nothing, add it: every `post` delivers each `LocalChange` to every `observeAll` handler after the per-directory handlers.
- `NavigationHistory.replaceCurrent(url)`: `current = url`; if `backList.last == url` it is dropped (clearing a search returns to the folder without a duplicate back entry); `forwardList` is unchanged.

- [ ] **Step 1: Write the failing store tests**

```swift
// Tests/CoreTests/Search/SearchResultStoreTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class SearchResultStoreTests: XCTestCase {
    let types = TypeRegistry()

    func batch(_ parent: String, _ names: [String], dirs: Set<String> = [], gen: Generation = .initial.next()) -> SearchBatch {
        var b = Batch(generation: gen)
        for name in names {
            let isDir = dirs.contains(name)
            let ext = (name as NSString).pathExtension
            let e = Entry(rowID: 7, fileID: 7, size: 10, allocSize: 10, mtime: 0, ctime: 0, nameOffset: 0,
                          nameLen: UInt16(name.utf8.count), kind: isDir ? .directory : .file, flags: [],
                          typeIndex: isDir ? TypeRegistry.folderIndex : types.index(forExtension: Substring(ext), isDirectory: false))
            Array(name.utf8).withUnsafeBufferPointer { b.append(e, nameBytes: $0) }
        }
        return SearchBatch(parent: URL(filePath: parent, directoryHint: .isDirectory), batch: b)
    }

    func testAppendBuildsPathsParentsAndIdentity() {
        var s = SearchResultStore()
        let added = s.append(batch("/r/a", ["x.txt", "y.txt"]))
        s.append(batch("/r/b", ["x.txt"]))
        s.append(batch("/", ["top.txt"]))
        XCTAssertEqual(added, [0, 1])
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.path(0), "/r/a/x.txt")
        XCTAssertEqual(s.path(2), "/r/b/x.txt")
        XCTAssertEqual(s.path(3), "/top.txt")               // no double slash under "/"
        XCTAssertEqual(s.parentPath(1), "/r/a")
        XCTAssertEqual(s.parents, ["/r/a", "/r/b", "/"])
        XCTAssertEqual(s.parentIndex(2), 1)
        XCTAssertEqual(s.identity(2), .name("/r/b/x.txt"))  // same name, different folders → different rows
        XCTAssertEqual(s.index(ofPath: "/r/b/x.txt"), 2)
        XCTAssertEqual(s.url(0), URL(filePath: "/r/a/x.txt"))
        XCTAssertEqual(s.nameKeys.count, 4)
    }

    func testAppendReplacesExistingPath() {
        var s = SearchResultStore()
        s.append(batch("/r", ["a.txt", "b.txt"]))
        s.setOrder([1, 0])
        let added = s.append(batch("/r", ["a.txt"]))        // Spotlight "updated" event
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(added, [1])
        XCTAssertEqual(s.path(0), "/r/b.txt")
        XCTAssertEqual(s.path(1), "/r/a.txt")
        XCTAssertEqual(s.store.order, [0])                  // b kept its place; the caller merges index 1
    }

    func testRemoveKeepsColumnsAligned() {
        var s = SearchResultStore()
        s.append(batch("/r/a", ["1", "2", "3"]))
        s.append(batch("/r/b", ["4", "5"]))
        s.setOrder([4, 3, 2, 1, 0])
        XCTAssertEqual(s.remove(paths: ["/r/a/2", "/r/b/4", "/nope"]), 2)
        XCTAssertEqual((0..<UInt32(s.count)).map { s.path($0) }, ["/r/a/1", "/r/a/3", "/r/b/5"])
        XCTAssertEqual(s.store.order.map { s.path($0) }, ["/r/b/5", "/r/a/3", "/r/a/1"])
        XCTAssertNil(s.index(ofPath: "/r/a/2"))
        XCTAssertEqual(s.index(ofPath: "/r/b/5"), 2)
        XCTAssertEqual(s.nameKeys.count, 3)
        let key = s.nameKeys.withKey(2) { Array($0) }
        XCTAssertEqual(key, SortKeys.nameKey("5", isFolder: false))
    }

    func testRenameRetypesAndMovesIdentity() throws {
        var s = SearchResultStore()
        s.append(batch("/r", ["notes.txt", "keep.md"]))
        s.setOrder([0, 1])
        XCTAssertTrue(s.rename(path: "/r/notes.txt", to: "notes.png", types: types))
        XCTAssertFalse(s.rename(path: "/r/missing", to: "x", types: types))
        XCTAssertNil(s.index(ofPath: "/r/notes.txt"))
        let i = try XCTUnwrap(s.index(ofPath: "/r/notes.png"))
        XCTAssertEqual(s.store.name(i), "notes.png")
        XCTAssertTrue(types.type(at: s.store.entry(i).typeIndex).conforms(to: .png))
        XCTAssertEqual(s.store.order.map { s.path($0) }, ["/r/keep.md"])   // caller merges the renamed index
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter CoreTests.SearchResultStoreTests 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'SearchResultStore' in scope`.

- [ ] **Step 3: Implement the search types and the store**

```swift
// Sources/Core/Search/SearchTypes.swift
import Foundation
import MacxFS

/// Matches found in one directory (crawler) or one parent (Spotlight). `batch.generation` is the search generation.
public struct SearchBatch: Sendable {
    public var parent: URL
    public var batch: Batch
    public init(parent: URL, batch: Batch) { self.parent = parent; self.batch = batch }
}
public struct SearchProgress: Sendable, Equatable {
    public var directoriesScanned: Int
    public var resultCount: Int
    public var currentPath: String?
    public init(directoriesScanned: Int = 0, resultCount: Int = 0, currentPath: String? = nil) {
        self.directoriesScanned = directoriesScanned; self.resultCount = resultCount; self.currentPath = currentPath
    }
}
public enum SkipReason: Sendable, Equatable { case permission(Int32), protectedLocation, unresponsive }
public struct SkippedLocation: Sendable, Equatable {
    public var path: String
    public var reason: SkipReason
    public init(path: String, reason: SkipReason) { self.path = path; self.reason = reason }
}
public struct SearchSummary: Sendable, Equatable {
    public var resultCount: Int
    public var directoriesScanned: Int
    public var skipped: [SkippedLocation]
    public var skippedTotal: Int
    public var truncated: Bool
    public var elapsed: Duration
    public init(resultCount: Int = 0, directoriesScanned: Int = 0, skipped: [SkippedLocation] = [], skippedTotal: Int = 0,
                truncated: Bool = false, elapsed: Duration = .zero) {
        self.resultCount = resultCount; self.directoriesScanned = directoriesScanned; self.skipped = skipped
        self.skippedTotal = skippedTotal; self.truncated = truncated; self.elapsed = elapsed
    }
}
public enum SearchFailure: Error, Sendable, Equatable { case rootUnreadable(Reason), volumeUnresponsive, spotlightFailed }
public enum SearchNotice: Sendable, Equatable {
    case contentsNotIndexed(volumeName: String)
    case spotlightOff
    case truncated(limit: Int)
    case skippedLocations(count: Int)
    case mayNotBeIndexed
}
public enum SearchEvent: Sendable {
    case batch(SearchBatch), removed([String]), progress(SearchProgress), notice(SearchNotice)
    case completed(SearchSummary), failed(SearchFailure)
}
```

```swift
// Sources/Core/Search/SearchResultStore.swift
import Foundation
import MacxFS

/// Results of one search: entries from many folders. Identity is the full path (`RowID.name`), never the inode.
public struct SearchResultStore: Sendable {
    public private(set) var store = EntryStore(identityMode: .objectID)
    public private(set) var nameKeys = SortKeyColumn()
    public private(set) var parents: [String] = []
    private var parentLookup: [String: UInt32] = [:]
    private var parentOf: [UInt32] = []                 // by storage index
    private var pathIndex: [String: UInt32] = [:]

    public init() {}

    public var count: Int { store.count }

    public func parentIndex(_ index: UInt32) -> UInt32 { parentOf[Int(index)] }
    public func parentPath(_ index: UInt32) -> String { parents[Int(parentOf[Int(index)])] }
    public func path(_ index: UInt32) -> String { Self.join(parentPath(index), store.name(index)) }
    public func url(_ index: UInt32) -> URL {
        URL(filePath: path(index), directoryHint: store.entry(index).kind == .directory ? .isDirectory : .notDirectory)
    }
    public func identity(_ index: UInt32) -> RowID { .name(path(index)) }
    public func index(ofPath path: String) -> UInt32? { pathIndex[path] }

    static func join(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }
    static func standardizedParent(_ url: URL) -> String {
        let p = url.standardizedFileURL.path(percentEncoded: false)
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    @discardableResult
    public mutating func append(_ batch: SearchBatch) -> [UInt32] {
        let parent = Self.standardizedParent(batch.parent)
        let paths = (0..<batch.batch.count).map { Self.join(parent, batch.batch.name(at: $0)) }
        let replaced = paths.compactMap { pathIndex[$0] }
        if !replaced.isEmpty { removeIndices(Set(replaced)) }
        let p: UInt32
        if let known = parentLookup[parent] { p = known } else {
            p = UInt32(parents.count); parents.append(parent); parentLookup[parent] = p
        }
        let start = store.count
        store.append(batch.batch)
        nameKeys.append(contentsOf: SortKeys.nameKeys(store, range: start..<store.count))
        for (offset, path) in paths.enumerated() {
            let index = UInt32(start + offset)
            parentOf.append(p)
            pathIndex[path] = index
        }
        return (start..<store.count).map(UInt32.init)
    }

    @discardableResult
    public mutating func remove(paths: [String]) -> Int {
        let indices = Set(paths.compactMap { pathIndex[$0] })
        removeIndices(indices)
        return indices.count
    }

    public mutating func rename(path: String, to newName: String, types: TypeRegistry) -> Bool {
        guard let index = pathIndex[path] else { return false }
        var entry = store.entry(index)
        let parentURL = URL(filePath: parentPath(index), directoryHint: .isDirectory)
        let isDir = entry.kind == .directory || entry.kind == .package
        if entry.kind != .directory {
            entry.typeIndex = types.index(forExtension: Substring((newName as NSString).pathExtension), isDirectory: isDir)
        }
        entry.flags.remove(.dotName)
        if newName.hasPrefix(".") { entry.flags.insert(.dotName) }
        var batch = Batch(generation: .initial)
        Array(newName.utf8).withUnsafeBufferPointer { batch.append(entry, nameBytes: $0) }
        removeIndices([index])
        append(SearchBatch(parent: parentURL, batch: batch))
        return true
    }

    public mutating func setOrder(_ order: [UInt32]) { store.setOrder(order) }

    private mutating func removeIndices(_ indices: Set<UInt32>) {
        guard !indices.isEmpty else { return }
        store.remove(indices)                   // stable compaction; remaps order
        nameKeys.remove(indices)
        parentOf = parentOf.enumerated().filter { !indices.contains(UInt32($0.offset)) }.map(\.element)
        pathIndex.removeAll(keepingCapacity: true)
        for i in 0..<UInt32(store.count) { pathIndex[path(i)] = i }
    }
}
```

- [ ] **Step 4: Run the store tests**

Run: `swift test --filter CoreTests.SearchResultStoreTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`. If `testRemoveKeepsColumnsAligned` fails on the order line, `EntryStore.remove` is not a stable compaction: fix it there (Phase 1 §3.3 says it "compacts storage; remaps order"; survivors keep relative order) rather than working around it here.

- [ ] **Step 5: Write the failing row-source, selection and history tests**

```swift
// Tests/CoreTests/Search/RowSourceTests.swift
import XCTest
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class RowSourceTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        env = CoreEnvironment.sandboxed(root: sandbox.root)
    }

    func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testFolderModelConformsAndMapsEvents() async throws {
        try sandbox.createDirectory("dir")
        for n in ["b.txt", "a.txt", "c.txt"] { try sandbox.createFile("dir/\(n)") }
        let model = env.makeFolderModel(sandbox.url("dir"))
        let source: any RowSource = model
        var events: [String] = []
        let token = source.observeRows { e in
            switch e { case .changes: events.append("changes"); case .selection: events.append("selection"); case .beginRename: events.append("rename") }
        }
        defer { token.cancel(); model.close() }
        model.start()
        await waitUntil { model.state == .complete && source.rowCount == 3 }
        XCTAssertEqual((0..<3).map { source.name(atRow: $0) }, ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(source.parentURL(atRow: 0).standardizedFileURL, sandbox.url("dir").standardizedFileURL)
        XCTAssertFalse(source.showsPathColumn)
        XCTAssertEqual(source.sortDescriptor, model.query.sort)
        source.select(.set([1], cursor: 1))
        XCTAssertEqual(source.selectedURLs.map(\.lastPathComponent), ["b.txt"])
        source.setSortDescriptor(SortDescriptor(field: .name, ascending: false))
        await waitUntil { source.name(atRow: 0) == "c.txt" }
        XCTAssertEqual(model.query.sort, SortDescriptor(field: .name, ascending: false))
        XCTAssertEqual(source.selectedURLs.map(\.lastPathComponent), ["b.txt"])   // selection follows identity
        XCTAssertTrue(events.contains("changes"))
        XCTAssertTrue(events.contains("selection"))
    }

    func testSelectionApplyAndReconcileOnAnArbitraryRowSpace() {
        var ids = ["/a", "/b", "/c", "/d"]
        func space() -> SelectionRowSpace {
            let current = ids
            return SelectionRowSpace(count: current.count, identity: { .name(current[$0]) },
                                     row: { id in if case .name(let p) = id { current.firstIndex(of: p) } else { nil } },
                                     rowNamed: { n in current.firstIndex { ($0 as NSString).lastPathComponent == n } })
        }
        var sel = Selection.empty
        sel.apply(.set([1], cursor: 1), in: space())
        sel.apply(.extend(to: 3), in: space())
        XCTAssertEqual(sel.rows, IndexSet(1...3))
        sel.apply(.toggle(2), in: space())
        XCTAssertEqual(sel.ids, [.name("/b"), .name("/d")])
        ids = ["/d", "/a", "/b"]                       // re-sorted and /c removed
        sel.reconcile(in: space())
        XCTAssertEqual(sel.rows, IndexSet([0, 2]))
        sel.apply(.names(["a"]), in: space())
        XCTAssertEqual(sel.ids, [.name("/a")])
        sel.apply(.invert, in: space())
        XCTAssertEqual(sel.rows, IndexSet([0, 2]))
    }

    func testReplaceCurrentDropsMatchingBackEntry() {
        let folder = URL(filePath: "/tmp/macx-tests-x/f", directoryHint: .isDirectory)
        let s1 = URL(string: "x-macexplorer-search:?v=1&q=AAA")!
        let s2 = URL(string: "x-macexplorer-search:?v=1&q=BBB")!
        var h = NavigationHistory(current: folder)
        h.visit(s1)
        h.replaceCurrent(s2)                           // retyping
        XCTAssertEqual(h.current, s2)
        XCTAssertEqual(h.backList, [folder])
        h.replaceCurrent(folder)                       // clearing the search
        XCTAssertEqual(h.current, folder)
        XCTAssertEqual(h.backList, [])
        XCTAssertFalse(h.canGoBack)
    }

    func testObserveAllSeesEveryDirectory() {
        let bus = ChangeBus()
        var seen: [String] = []
        let token = bus.observeAll { seen.append($0.directory.lastPathComponent) }
        defer { token.cancel() }
        bus.post([LocalChange(directory: URL(filePath: "/x/one"), removed: ["a"]),
                  LocalChange(directory: URL(filePath: "/x/two"), added: ["b"])])
        XCTAssertEqual(seen, ["one", "two"])
    }
}
```

- [ ] **Step 6: Run to verify failure**

Run: `swift test --filter CoreTests.RowSourceTests 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find type 'RowSource' in scope` (and `SelectionRowSpace`, `replaceCurrent`).

- [ ] **Step 7: Implement the protocol, shared selection mutators and the conformance**

```swift
// Sources/Core/Folder/RowSource.swift
import Foundation
import MacxFS

public enum RowSourceEvent: Sendable { case changes(ChangeSet), selection(Selection), beginRename(row: Int) }

/// What the Details and Icons views draw: a folder (FolderModel) or search results (SearchResultsModel).
@MainActor public protocol RowSource: AnyObject {
    var rowCount: Int { get }
    func entry(atRow row: Int) -> Entry
    func name(atRow row: Int) -> String
    func url(atRow row: Int) -> URL
    func parentURL(atRow row: Int) -> URL
    func identity(atRow row: Int) -> RowID
    func row(of id: RowID) -> Int?
    var selection: Selection { get }
    func select(_ command: SelectionCommand)
    var selectedURLs: [URL] { get }
    var selectionSummary: SelectionSummary { get }
    var scrollAnchor: RowID? { get set }
    func isCut(row: Int) -> Bool
    var sortDescriptor: SortDescriptor { get }
    func setSortDescriptor(_ sort: SortDescriptor)
    var showsPathColumn: Bool { get }
    var caseSensitive: Bool { get }
    func validateName(_ proposed: String, renamingRow row: Int?) -> NameValidation
    func observeRows(_ handler: @escaping @MainActor (RowSourceEvent) -> Void) -> ObserverToken
}
```

In `Sources/Core/Folder/Selection.swift`, add (same file, so the `private(set)` fields are writable). Then replace the body of `FolderModel.select(_:)` and the code that recomputes `selection.rows` after a reset with calls to `apply`/`reconcile` over a `SelectionRowSpace` built from the model (`count: rowCount`, `identity: identity(atRow:)`, `row: row(of:)`, `rowNamed: row(named:)`). `SelectionTests` and `FolderModelTests` from Phase 1 must stay green unchanged; if the Phase 1 logic differs from the rules below in any case those tests pin, keep the Phase 1 behaviour and adjust this code.

```swift
/// Row space a Selection is applied against. Closures are called synchronously and never stored.
struct SelectionRowSpace {
    let count: Int
    let identity: (Int) -> RowID
    let row: (RowID) -> Int?
    let rowNamed: (String) -> Int?
}

extension Selection {
    init(ids: Set<RowID>, rows: IndexSet, anchor: RowID?, cursor: RowID?) {
        self = .empty
        self.ids = ids; self.rows = rows; self.anchor = anchor; self.cursor = cursor
    }

    mutating func apply(_ command: SelectionCommand, in space: SelectionRowSpace) {
        let valid = { (rows: IndexSet) in rows.filteredIndexSet { $0 >= 0 && $0 < space.count } }
        switch command {
        case .set(let rows, let cursorRow):
            let r = valid(rows)
            setRows(r, in: space)
            let c = cursorRow.flatMap { $0 < space.count ? $0 : nil } ?? r.first
            cursor = c.map(space.identity); anchor = cursor
        case .toggle(let row):
            guard row >= 0, row < space.count else { return }
            var r = rows
            if r.contains(row) { r.remove(row) } else { r.insert(row) }
            setRows(r, in: space)
            cursor = space.identity(row); anchor = cursor
        case .extend(let row):
            guard row >= 0, row < space.count else { return }
            let a = anchor.flatMap(space.row) ?? row
            setRows(IndexSet(integersIn: min(a, row)...max(a, row)), in: space)
            cursor = space.identity(row)
            if anchor == nil { anchor = cursor }
        case .add(let rows):
            setRows(self.rows.union(valid(rows)), in: space)
        case .all:
            setRows(IndexSet(integersIn: 0..<space.count), in: space)
        case .none:
            setRows([], in: space); anchor = nil; cursor = nil
        case .invert:
            setRows(IndexSet(integersIn: 0..<space.count).subtracting(rows), in: space)
        case .names(let names):
            let r = IndexSet(names.compactMap(space.rowNamed))
            setRows(r, in: space)
            cursor = r.first.map(space.identity); anchor = cursor
        }
    }

    /// After the order changed: rows from ids; ids that vanished are dropped.
    mutating func reconcile(in space: SelectionRowSpace) {
        var kept = Set<RowID>(), r = IndexSet()
        for id in ids { if let row = space.row(id) { kept.insert(id); r.insert(row) } }
        ids = kept; rows = r
        if let a = anchor, space.row(a) == nil { anchor = nil }
        if let c = cursor, space.row(c) == nil { cursor = nil }
    }

    private mutating func setRows(_ r: IndexSet, in space: SelectionRowSpace) {
        rows = r
        ids = Set(r.map(space.identity))
    }
}
```

```swift
// Sources/Core/Folder/FolderModel+RowSource.swift
import Foundation
import MacxFS

extension FolderModel: RowSource {
    public func parentURL(atRow row: Int) -> URL { directory }
    public var sortDescriptor: SortDescriptor { query.sort }
    public func setSortDescriptor(_ sort: SortDescriptor) {
        var q = query
        q.sort = sort
        setQuery(q)
    }
    public var showsPathColumn: Bool { false }
    public func observeRows(_ handler: @escaping @MainActor (RowSourceEvent) -> Void) -> ObserverToken {
        observe { event in
            switch event {
            case .changes(let c): handler(.changes(c))
            case .selection(let s): handler(.selection(s))
            case .beginRename(let row): handler(.beginRename(row: row))
            default: break     // state, relocate, query, Phase 2 groups/sizes/attributes stay FolderModel-specific
            }
        }
    }
}
```

`default:` is acceptable here (the switch maps a subset on purpose; the Phase 4 "no default in exhaustive switches" rule covers commands and jobs, not event projections).

In `NavigationHistory.swift` add:

```swift
    /// Replaces the current entry without growing history (retyped search, cleared search).
    /// Drops a trailing back entry equal to `url`, so returning from a search does not leave a duplicate.
    public mutating func replaceCurrent(_ url: URL) {
        if backList.last == url { backList.removeLast() }
        current = url
    }
```

- [ ] **Step 8: Run the P3-03 tests and the Phase 1 selection/folder tests**

Run: `swift test --filter "CoreTests.RowSourceTests|CoreTests.SearchResultStoreTests|CoreTests.SelectionTests|CoreTests.FolderModelTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 9: Build and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`, no warnings.

```bash
git add Sources/Core/Folder Sources/Core/Search/SearchTypes.swift Sources/Core/Search/SearchResultStore.swift Sources/Core/Navigation/NavigationHistory.swift Sources/Core/Support/ChangeBus.swift Tests/CoreTests/Search
git commit -m "feat: RowSource protocol, search result store and history replacement"
```

---

### Task P3-04: Subtree crawler

**Files:**
- Create: `Sources/Core/Search/ResumeOnce.swift`, `Sources/Core/Search/CrawlTypes.swift`, `Sources/Core/Search/SubtreeCrawler.swift`
- Test: `Tests/CoreTests/Search/SubtreeCrawlerTests.swift`

**Interfaces:**
- Consumes: `LanePool.perform(on:_:stallPolicy:onStall:_:)`, `LaneClass.scan` (P2-12), `LaneContext`, `LaneError`, `StallNotice`, `WatchdogConfig`, `withNoMaterialization`, `BulkReader.read`, `ReadOptions`, `ReadFailure`, `ReadSummary`, `Batch`, `Entry`, `MountTableStore`, `MountTable.volume(containing:)`, `TypeRegistry`, `SortKeys.searchFold`, `Generation`, `Reason(errno:)` (Phase 1 §3.2–§3.7); `SearchCriteria`, `CriteriaMatcher` (P3-01); `SearchEvent`, `SearchBatch`, `SearchProgress`, `SearchSummary`, `SkippedLocation`, `SkipReason`, `SearchFailure` (P3-03).
- Produces: `CrawlOptions`, `CrawlPermissions` (`none`, `relevant(forRoot:)`, `isBlocked(_:)`), `SubtreeCrawler.crawl(...)`; internal `ResumeOnce<T>`, `SubtreeCrawler.DirectoryRead`, `SubtreeCrawler.defaultRead` and the test overload `crawl(…, read:)`.

**Rules (each has a test):**
- Breadth-first over directories. At most `maxConcurrentReads` (2) directory reads in flight, all on the root volume's `.scan` lanes (so a crawl never starves browsing reads on `.read` lanes). Every read runs inside `withNoMaterialization { }` with `ReadOptions.noMaterialization = true`.
- Only `Kind.directory` entries are descended (and `Kind.package` when `includePackages`). Symlinks and aliases are never followed. Each directory's `fileID` is visited at most once, as a second guard against loops.
- Hidden entries (`EntryFlags.isHidden`) are neither results nor descended unless `includeHidden`. Dataless directories are not descended (descending would need materialization).
- A child that is a mount point, or whose `MountTable` volume differs from the root's, is not descended and not reported.
- A child under a `CrawlPermissions` blocked prefix is skipped without any read (so no TCC prompt) and reported as `.protectedLocation`. `relevant(forRoot:)` keeps only prefixes strictly below the root, because the user is already looking inside the root.
- A directory that fails to open is skipped as `.permission(errno)` and the crawl continues. A read the watchdog reports `.stalled` is skipped as `.unresponsive` immediately (`ResumeOnce` stops waiting; the lane work returns whenever it returns and is ignored). `LaneError.volumeUnresponsive` ends the crawl with `.failed(.volumeUnresponsive)`. A failing root ends it with `.failed(.rootUnreadable(Reason(errno:)))`.
- Results cap at `maxResults`: the batch that crosses the cap is cut, then `.completed(summary)` with `truncated == true`, and no more reads start.
- `.progress` is emitted at most every `progressInterval`. `.completed` carries at most 50 `SkippedLocation`s plus `skippedTotal`.
- Cancelling iteration (or the consuming Task) cancels the coordinator; in-flight lane work sees `LaneContext.isCancelled` at its next batch boundary and stops.

- [ ] **Step 1: Write the failing crawler tests**

```swift
// Tests/CoreTests/Search/SubtreeCrawlerTests.swift
import XCTest
import Darwin
@testable import Core
@testable import MacxFS
import MacxFixtures

final class SubtreeCrawlerTests: XCTestCase {
    var sandbox: Sandbox!
    let types = TypeRegistry()

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    struct Collected { var paths: [String] = []; var summary: SearchSummary?; var failure: SearchFailure?; var progress = 0 }

    func collect(_ stream: AsyncStream<SearchEvent>) async -> Collected {
        var c = Collected()
        for await e in stream {
            switch e {
            case .batch(let b):
                let parent = b.parent.standardizedFileURL.path(percentEncoded: false).trimmingSuffixSlash
                for i in 0..<b.batch.count { c.paths.append(parent + "/" + b.batch.name(at: i)) }
            case .completed(let s): c.summary = s
            case .failed(let f): c.failure = f
            case .progress: c.progress += 1
            default: break
            }
        }
        return c
    }

    func rel(_ paths: [String]) -> Set<String> {
        let root = sandbox.root.path(percentEncoded: false).trimmingSuffixSlash + "/"
        return Set(paths.map { String($0.dropFirst(root.count)) })
    }

    func crawl(_ term: String, options: CrawlOptions = CrawlOptions(), permissions: CrawlPermissions = .none,
               mountTable: MountTableStore = MountTableStore(), lanes: LanePool = LanePool(),
               read: SubtreeCrawler.DirectoryRead? = nil) -> AsyncStream<SearchEvent> {
        let criteria = SearchCriteria(nameTerms: [NameTerm(term)])
        if let read {
            return SubtreeCrawler.crawl(root: sandbox.root, criteria: criteria, options: options, permissions: permissions,
                                        generation: .initial.next(), lanes: lanes, mountTable: mountTable, types: types, read: read)
        }
        return SubtreeCrawler.crawl(root: sandbox.root, criteria: criteria, options: options, permissions: permissions,
                                    generation: .initial.next(), lanes: lanes, mountTable: mountTable, types: types)
    }

    func testFindsNestedMatchesBreadthFirst() async throws {
        try sandbox.createFile("needle-top.txt")
        try sandbox.createFile("a/b/c/needle-deep.txt")
        try sandbox.createFile("a/needle-mid.txt")
        try sandbox.createFile("a/b/other.txt")
        try sandbox.createDirectory("Needles")                     // folders match too
        let c = await collect(crawl("needle"))
        XCTAssertEqual(rel(c.paths), ["needle-top.txt", "a/needle-mid.txt", "a/b/c/needle-deep.txt", "Needles"])
        XCTAssertEqual(c.paths.last.map { ($0 as NSString).lastPathComponent }, "needle-deep.txt")   // deepest last
        XCTAssertEqual(c.summary?.resultCount, 4)
        XCTAssertEqual(c.summary?.directoriesScanned, 5)            // root, a, a/b, a/b/c, Needles
        XCTAssertNil(c.failure)
    }

    func testGlobAndFiltersApply() async throws {
        try sandbox.createFile("x/report1.doc")
        try sandbox.createFile("x/report12.doc")
        try sandbox.createFile("x/report1.doc.zip")
        let c = await collect(crawl("report?.doc"))
        XCTAssertEqual(rel(c.paths), ["x/report1.doc"])
    }

    // Review Focus 4
    func testCrawlerDoesNotFollowSymlinkLoops() async throws {
        try sandbox.createFile("tree/a/needle.txt")
        try sandbox.createSymlink("tree/a/loop", target: "..")
        try sandbox.createSymlink("tree/self", target: ".")
        try sandbox.createSymlink("tree/a/needle-link", target: "needle.txt")
        let c = await collect(crawl("needle"))
        XCTAssertEqual(rel(c.paths), ["tree/a/needle.txt", "tree/a/needle-link"])   // the link matches by name, once
        XCTAssertNotNil(c.summary)
    }

    // Review Focus 4
    func testCrawlerDoesNotCrossMountPoints() async throws {
        try sandbox.createFile("mnt/needle-inside.txt")
        try sandbox.createFile("needle-outside.txt")
        let mnt = sandbox.url("mnt")
        let fake = VolumeInfo(id: VolumeID(raw: "mnt:\(mnt.path(percentEncoded: false))"), mountPoint: mnt, name: "Fake",
                              format: "APFS", isBoot: false, isInternal: false, isRemovable: true, isEjectable: true,
                              isLocal: true, isReadOnly: false, isBrowsable: true, totalCapacity: nil,
                              capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
        let c = await collect(crawl("needle", mountTable: MountTableStore(MountTable([fake]))))
        XCTAssertEqual(rel(c.paths), ["needle-outside.txt"])
    }

    func testCrawlerDoesNotCrossRealDiskImage() async throws {
        guard DiskImage.isAvailable else { throw XCTSkip("hdiutil unavailable") }
        let image = try DiskImage.create(in: sandbox, format: .apfs, sizeMB: 16, volumeName: "MACXCRAWL")
        try sandbox.createFile(image.relativeMountPath + "/needle-in-image.txt")
        try sandbox.createFile("needle-here.txt")
        let lanes = LanePool()
        let volumes = try await lanes.perform(on: .unknown) { _ in try SystemVolumeScanner().scan() }
        let c = await collect(crawl("needle", mountTable: MountTableStore(MountTable(volumes)), lanes: lanes))
        XCTAssertEqual(rel(c.paths), ["needle-here.txt"])
    }

    // Review Focus 4
    func testCrawlerSkipsUnreadableAndContinues() async throws {
        try sandbox.createFile("locked/needle-hidden-by-mode.txt")
        try sandbox.createFile("open/needle.txt")
        try sandbox.setMode("locked", 0o000)
        let c = await collect(crawl("needle"))
        XCTAssertEqual(rel(c.paths), ["open/needle.txt"])
        let skipped = try XCTUnwrap(c.summary?.skipped)
        XCTAssertEqual(skipped.map { ($0.path as NSString).lastPathComponent }, ["locked"])
        XCTAssertEqual(skipped.first?.reason, .permission(EACCES))
        XCTAssertEqual(c.summary?.skippedTotal, 1)
    }

    // Review Focus 4
    func testCrawlerSkipsBlockedPrefixesBelowRoot() async throws {
        try sandbox.createFile("Protected/needle.txt")
        try sandbox.createFile("Free/needle.txt")
        let root = sandbox.root.path(percentEncoded: false).trimmingSuffixSlash
        var reads: [String] = []
        let lock = NSLock()
        let spy: SubtreeCrawler.DirectoryRead = { url, g, o, t, ctx, emit in
            lock.withLock { reads.append(url.path(percentEncoded: false).trimmingSuffixSlash) }
            return SubtreeCrawler.defaultRead(url, g, o, t, ctx, emit)
        }
        let perms = CrawlPermissions(blockedPrefixes: [root + "/Protected", root])   // root itself is dropped as relevant
        let c = await collect(crawl("needle", permissions: perms, read: spy))
        XCTAssertEqual(rel(c.paths), ["Free/needle.txt"])
        XCTAssertEqual(c.summary?.skipped, [SkippedLocation(path: root + "/Protected", reason: .protectedLocation)])
        XCTAssertFalse(lock.withLock { reads }.contains(root + "/Protected"), "a blocked folder must never be opened")
        XCTAssertEqual(perms.relevant(forRoot: root).blockedPrefixes, [root + "/Protected"])
        XCTAssertTrue(perms.isBlocked(root + "/Protected/x/y"))
        XCTAssertFalse(perms.isBlocked(root + "/ProtectedNot"))
    }

    func testPackagesAndHiddenAreSkippedUnlessEnabled() async throws {
        try sandbox.createFile("Thing.app/Contents/needle-pkg.txt")
        try sandbox.createFile(".hidden/needle-dot.txt")
        try sandbox.createFile(".needle-file")
        let plain = await collect(crawl("needle"))
        XCTAssertEqual(rel(plain.paths), [])
        var options = CrawlOptions()
        options.includePackages = true
        options.includeHidden = true
        let all = await collect(crawl("needle", options: options))
        XCTAssertEqual(rel(all.paths), ["Thing.app/Contents/needle-pkg.txt", ".hidden/needle-dot.txt", ".needle-file"])
        let app = await collect(crawl("*.app"))
        XCTAssertEqual(rel(app.paths), ["Thing.app"])           // the package itself is a result
    }

    func testResultCapTruncates() async throws {
        try FixtureTree.flat(in: sandbox, at: "many", count: 300, prefix: "hit-")
        var options = CrawlOptions()
        options.maxResults = 100
        let c = await collect(crawl("hit", options: options))
        XCTAssertEqual(c.paths.count, 100)
        XCTAssertEqual(c.summary?.truncated, true)
        XCTAssertEqual(c.summary?.resultCount, 100)
    }

    func testStalledDirectoryIsSkippedWithoutWaiting() async throws {
        try sandbox.createFile("slow/needle-slow.txt")
        try sandbox.createFile("fast/needle-fast.txt")
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(200), tick: .milliseconds(50)))
        let stalling: SubtreeCrawler.DirectoryRead = { url, g, o, t, ctx, emit in
            if url.lastPathComponent == "slow" { Thread.sleep(forTimeInterval: 1.5) }      // no heartbeat
            return SubtreeCrawler.defaultRead(url, g, o, t, ctx, emit)
        }
        let start = ContinuousClock.now
        let c = await collect(crawl("needle", lanes: lanes, read: stalling))
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1_200), "the crawl must not wait for the stalled read")
        XCTAssertEqual(rel(c.paths), ["fast/needle-fast.txt"])
        XCTAssertEqual(c.summary?.skipped.first?.reason, .unresponsive)
    }

    func testUnreadableRootFails() async throws {
        try sandbox.createDirectory("r")
        try sandbox.setMode("r", 0o000)
        let stream = SubtreeCrawler.crawl(root: sandbox.url("r"), criteria: SearchCriteria(nameTerms: [NameTerm("x")]),
                                          options: CrawlOptions(), permissions: .none, generation: .initial.next(),
                                          lanes: LanePool(), mountTable: MountTableStore(), types: types)
        let c = await collect(stream)
        XCTAssertEqual(c.failure, .rootUnreadable(.permissionPOSIX))
        XCTAssertNil(c.summary)
    }

    func testCancellingIterationStopsTheCrawl() async throws {
        try FixtureTree.deep(in: sandbox, at: "deep", depth: 6, breadth: 4, filesPerDir: 20)
        var reads = 0
        let lock = NSLock()
        let counting: SubtreeCrawler.DirectoryRead = { url, g, o, t, ctx, emit in
            lock.withLock { reads += 1 }
            return SubtreeCrawler.defaultRead(url, g, o, t, ctx, emit)
        }
        let stream = crawl("", read: counting)            // empty term matches everything
        let consumer = Task {
            for await e in stream { if case .batch = e { break } }
        }
        await consumer.value
        try await Task.sleep(for: .milliseconds(300))
        let afterCancel = lock.withLock { reads }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(lock.withLock { reads }, afterCancel, "no directory reads start after the consumer stopped")
        XCTAssertLessThan(afterCancel, 4 * 4 * 4 * 4, "the crawl stopped early")
    }

    func testBatchesCarryTheGeneration() async throws {
        try sandbox.createFile("needle.txt")
        let gen = Generation.initial.next().next()
        let stream = SubtreeCrawler.crawl(root: sandbox.root, criteria: SearchCriteria(nameTerms: [NameTerm("needle")]),
                                          options: CrawlOptions(), permissions: .none, generation: gen,
                                          lanes: LanePool(), mountTable: MountTableStore(), types: types)
        for await e in stream { if case .batch(let b) = e { XCTAssertEqual(b.batch.generation, gen) } }
    }
}

private extension String {
    var trimmingSuffixSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter CoreTests.SubtreeCrawlerTests 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'SubtreeCrawler' in scope`.

- [ ] **Step 3: Implement `ResumeOnce` and the crawl types**

```swift
// Sources/Core/Search/ResumeOnce.swift
import Synchronization

/// One-shot result box: the first `resume` wins, later ones are ignored; `value()` suspends until a value exists.
/// The crawler uses it to stop waiting for a stalled lane read. `value()` may be awaited once.
final class ResumeOnce<T: Sendable>: Sendable {
    private enum State { case idle, waiting(CheckedContinuation<T, Never>), done(T) }
    private let state = Mutex<State>(.idle)

    init() {}

    @discardableResult
    func resume(_ value: T) -> Bool {
        let (waiter, won): (CheckedContinuation<T, Never>?, Bool) = state.withLock { s in
            switch s {
            case .idle: s = .done(value); return (nil, true)
            case .waiting(let c): s = .done(value); return (c, true)
            case .done: return (nil, false)
            }
        }
        waiter?.resume(returning: value)
        return won
    }

    func value() async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            let ready: T? = state.withLock { s in
                switch s {
                case .done(let v): return v
                case .idle: s = .waiting(c); return nil
                case .waiting: preconditionFailure("ResumeOnce.value() awaited twice")
                }
            }
            if let ready { c.resume(returning: ready) }
        }
    }
}
```

```swift
// Sources/Core/Search/CrawlTypes.swift
import Foundation

public struct CrawlOptions: Sendable, Hashable {
    public var includePackages: Bool = false
    public var includeHidden: Bool = false
    public var maxResults: Int = 100_000
    public var maxConcurrentReads: Int = 2
    public var progressInterval: Duration = .milliseconds(100)
    public init() {}
}

/// Folders the crawler must not open (TCC-protected without a recorded grant). Paths are standardized, no trailing "/".
public struct CrawlPermissions: Sendable, Hashable {
    public var blockedPrefixes: [String]
    public init(blockedPrefixes: [String]) { self.blockedPrefixes = blockedPrefixes.map(Self.trim) }
    public static let none = CrawlPermissions(blockedPrefixes: [])

    public func relevant(forRoot root: String) -> CrawlPermissions {
        let r = Self.trim(root)
        let below = r == "/" ? "/" : r + "/"
        return CrawlPermissions(blockedPrefixes: blockedPrefixes.filter { $0 != r && $0.hasPrefix(below) })
    }

    public func isBlocked(_ path: String) -> Bool {
        let p = Self.trim(path)
        return blockedPrefixes.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    static func trim(_ s: String) -> String { s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s }
}
```

- [ ] **Step 4: Implement the crawler**

```swift
// Sources/Core/Search/SubtreeCrawler.swift
import Foundation
import MacxFS

public enum SubtreeCrawler {
    /// Synchronous directory read (lane only). Returns a Result: typed-throws closures must not cross
    /// `LanePool.perform` (S1 Contract note 7).
    typealias DirectoryRead = @Sendable (URL, Generation, ReadOptions, TypeRegistry, LaneContext, (Batch) -> Bool)
        -> Result<ReadSummary, ReadFailure>

    static let defaultRead: DirectoryRead = { url, generation, options, types, context, emit in
        do {
            return .success(try BulkReader.read(url, generation: generation, options: options, types: types,
                                                context: context, emit: emit))
        } catch {
            return .failure(error)
        }
    }

    public static func crawl(root: URL, criteria: SearchCriteria, options: CrawlOptions, permissions: CrawlPermissions,
                             generation: Generation, lanes: LanePool, mountTable: MountTableStore,
                             types: TypeRegistry = .shared) -> AsyncStream<SearchEvent> {
        crawl(root: root, criteria: criteria, options: options, permissions: permissions, generation: generation,
              lanes: lanes, mountTable: mountTable, types: types, read: defaultRead)
    }

    static func crawl(root: URL, criteria: SearchCriteria, options: CrawlOptions, permissions: CrawlPermissions,
                      generation: Generation, lanes: LanePool, mountTable: MountTableStore,
                      types: TypeRegistry, read: @escaping DirectoryRead) -> AsyncStream<SearchEvent> {
        let (stream, continuation) = AsyncStream<SearchEvent>.makeStream(bufferingPolicy: .unbounded)
        let run = CrawlRun(root: root, criteria: criteria, options: options, permissions: permissions,
                           generation: generation, lanes: lanes, mountTable: mountTable, types: types, read: read)
        let task = Task {
            await run.run(continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

struct DirectoryOutcome: Sendable {
    enum Status: Sendable { case read, failed(ReadFailure), stalled, volumeUnresponsive, cancelled }
    var status: Status
    var matches: [Batch] = []
    var children: [Child] = []
    struct Child: Sendable { var name: String; var fileID: UInt64 }
    static let stalled = DirectoryOutcome(status: .stalled)
    static let cancelled = DirectoryOutcome(status: .cancelled)
}

struct CrawlRun: Sendable {
    let root: URL
    let criteria: SearchCriteria
    let options: CrawlOptions
    let permissions: CrawlPermissions
    let generation: Generation
    let lanes: LanePool
    let mountTable: MountTableStore
    let types: TypeRegistry
    let read: SubtreeCrawler.DirectoryRead

    static func standardized(_ url: URL) -> String { CrawlPermissions.trim(url.standardizedFileURL.path(percentEncoded: false)) }
    static func join(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }

    func run(_ out: AsyncStream<SearchEvent>.Continuation) async {
        let clock = ContinuousClock()
        let start = clock.now
        let rootPath = Self.standardized(root)
        let table = mountTable.current()
        let rootVolume = table.volume(containing: rootPath)
        let volume = rootVolume?.id ?? .unknown
        let perms = permissions.relevant(forRoot: rootPath)

        var queue = [rootPath], head = 0
        var visited = Set<UInt64>()
        var scanned = 0, results = 0, skippedTotal = 0
        var skipped: [SkippedLocation] = []
        var truncated = false
        var lastProgress = start
        func skip(_ path: String, _ reason: SkipReason) {
            skippedTotal += 1
            if skipped.count < 50 { skipped.append(SkippedLocation(path: path, reason: reason)) }
        }

        let finished: Bool = await withTaskGroup(of: (String, DirectoryOutcome).self) { group in
            var inFlight = 0
            while true {
                while inFlight < max(1, options.maxConcurrentReads), head < queue.count, !truncated {
                    let path = queue[head]
                    head += 1
                    inFlight += 1
                    group.addTask { (path, await self.readOne(path, volume: volume)) }
                }
                guard inFlight > 0, let next = await group.next() else { return true }
                let (path, outcome) = next
                inFlight -= 1
                if truncated { continue }                       // draining reads cancelled by the cap
                if Task.isCancelled { group.cancelAll(); return false }
                switch outcome.status {
                case .cancelled:
                    group.cancelAll(); return false
                case .volumeUnresponsive:
                    out.yield(.failed(.volumeUnresponsive)); group.cancelAll(); return false
                case .failed(let f):
                    if f.stage == .unresponsiveVolume { out.yield(.failed(.volumeUnresponsive)); group.cancelAll(); return false }
                    if path == rootPath { out.yield(.failed(.rootUnreadable(Reason(errno: f.code)))); group.cancelAll(); return false }
                    skip(path, .permission(f.code))
                case .stalled:
                    if path == rootPath { out.yield(.failed(.volumeUnresponsive)); group.cancelAll(); return false }
                    skip(path, .unresponsive)
                case .read:
                    scanned += 1
                    let parentURL = URL(filePath: path, directoryHint: .isDirectory)
                    for batch in outcome.matches where !truncated {
                        var b = batch
                        let room = options.maxResults - results
                        if b.count > room { b = Self.prefix(b, room); truncated = true }
                        if b.count > 0 { out.yield(.batch(SearchBatch(parent: parentURL, batch: b))); results += b.count }
                        if results >= options.maxResults { truncated = true }
                    }
                    for child in outcome.children {
                        let childPath = Self.join(path, child.name)
                        if perms.isBlocked(childPath) { skip(childPath, .protectedLocation); continue }
                        if let v = table.volume(containing: childPath),
                           v.id != rootVolume?.id || Self.standardized(v.mountPoint) == childPath { continue }
                        if child.fileID != 0, !visited.insert(child.fileID).inserted { continue }
                        queue.append(childPath)
                    }
                }
                if clock.now - lastProgress >= options.progressInterval {
                    lastProgress = clock.now
                    out.yield(.progress(SearchProgress(directoriesScanned: scanned, resultCount: results, currentPath: path)))
                }
                if truncated { group.cancelAll() }
            }
        }
        guard finished, !Task.isCancelled else { return }
        out.yield(.completed(SearchSummary(resultCount: results, directoriesScanned: scanned, skipped: skipped,
                                           skippedTotal: skippedTotal, truncated: truncated, elapsed: clock.now - start)))
    }

    static func prefix(_ batch: Batch, _ n: Int) -> Batch {
        var out = Batch(generation: batch.generation)
        batch.names.withUnsafeBufferPointer { names in
            for e in batch.entries.prefix(max(0, n)) {
                let o = Int(e.nameOffset)
                out.append(e, nameBytes: UnsafeBufferPointer(rebasing: names[o..<(o + Int(e.nameLen))]))
            }
        }
        return out
    }

    /// One directory on a scan lane. A watchdog stall resolves the wait immediately as `.stalled`.
    func readOne(_ path: String, volume: VolumeID) async -> DirectoryOutcome {
        let box = ResumeOnce<DirectoryOutcome>()
        let run = self
        let inner = Task {
            do {
                let outcome = try await run.lanes.perform(on: volume, .scan, onStall: { notice in
                    if notice == .stalled { box.resume(.stalled) }
                }) { context in
                    run.readDirectory(path, context: context)
                }
                box.resume(outcome)
            } catch LaneError.volumeUnresponsive(_) {
                box.resume(DirectoryOutcome(status: .volumeUnresponsive))
            } catch {
                box.resume(.cancelled)
            }
        }
        return await withTaskCancellationHandler {
            await box.value()
        } onCancel: {
            inner.cancel()
            box.resume(.cancelled)
        }
    }

    /// Lane work: read, match, collect descendable children. Synchronous; no suspension points.
    func readDirectory(_ path: String, context: LaneContext) -> DirectoryOutcome {
        var outcome = DirectoryOutcome(status: .read)
        var matcher = CriteriaMatcher(criteria, types: types)
        var readOptions = ReadOptions()
        readOptions.noMaterialization = true
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let result = withNoMaterialization {
            read(url, generation, readOptions, types, context) { batch in
                var hits = Batch(generation: generation)
                batch.names.withUnsafeBufferPointer { names in
                    for e in batch.entries {
                        if e.flags.isHidden && !options.includeHidden { continue }
                        let o = Int(e.nameOffset)
                        let bytes = UnsafeBufferPointer(rebasing: names[o..<(o + Int(e.nameLen))])
                        let name = String(decoding: bytes, as: UTF8.self)
                        let descend = e.kind == .directory || (e.kind == .package && options.includePackages)
                        if descend && !e.flags.contains(.dataless) {
                            outcome.children.append(.init(name: name, fileID: e.fileID))
                        }
                        let folded = SortKeys.searchFold(name)
                        if folded.withUnsafeBytes({ matcher.matches(e, foldedName: $0) }) { hits.append(e, nameBytes: bytes) }
                    }
                }
                if hits.count > 0 { outcome.matches.append(hits) }
                context.heartbeat()
                return !context.isCancelled
            }
        }
        if case .failure(let failure) = result { outcome.status = .failed(failure) }
        if context.isCancelled { outcome.status = .cancelled }
        return outcome
    }
}
```

Notes for the implementer:
- `Batch.entries`/`names` are the §3.3 public fields; the `nameOffset` of an entry is relative to its batch's `names`.
- Names that are not valid UTF-8 decode lossily, so a directory with such a name cannot be re-opened by path; it is still a result (by its lossy name) but is not descended. This matches Phase 1, which also shows lossy names.
- If `LanePool.perform` has no `.scan` class in this tree (Phase 2 P2-12 missing), use `.read` and note it in the commit message.

- [ ] **Step 5: Run the crawler tests**

Run: `swift test --filter CoreTests.SubtreeCrawlerTests 2>&1 | tail -5`
Expected: `Executed 13 tests, with 0 failures` (`testCrawlerDoesNotCrossRealDiskImage` may report as skipped where `hdiutil` is unavailable).

- [ ] **Step 6: Run under Thread Sanitizer once**

Run: `swift test --sanitize=thread --filter CoreTests.SubtreeCrawlerTests 2>&1 | tail -5`
Expected: `0 failures` and no `ThreadSanitizer` report.

- [ ] **Step 7: Build and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`.

```bash
git add Sources/Core/Search/ResumeOnce.swift Sources/Core/Search/CrawlTypes.swift Sources/Core/Search/SubtreeCrawler.swift Tests/CoreTests/Search/SubtreeCrawlerTests.swift
git commit -m "feat: parallel no-materialization subtree crawler for Subfolders search"
```

---

### Task P3-05: Spotlight adapter and index status

**Files:**
- Create: `Sources/Core/Search/SpotlightRequest.swift`, `Sources/Core/Search/SpotlightPredicate.swift`, `Sources/Core/Search/MetadataQuerying.swift`, `Sources/Core/Search/SystemMetadataQuery.swift`, `Sources/Core/Search/SpotlightSearch.swift`, `Sources/Core/Search/IndexStatus.swift`
- Test: `Tests/CoreTests/Search/SpotlightPredicateTests.swift`, `Tests/CoreTests/Search/SpotlightSearchTests.swift`, `Tests/CoreTests/Search/LiveSpotlightTests.swift`, `Tests/CoreTests/Search/IndexStatusTests.swift`

**Interfaces:**
- Consumes: `SearchCriteria`, `NameTerm`, `KindFilter.typeIdentifiers`, `CriteriaMatcher`, `ByteRange`, `TimeRange` (P3-01); `SearchEvent`, `SearchBatch`, `SearchSummary`, `SearchFailure` (P3-03); `Entry`, `Batch`, `Kind`, `EntryFlags`, `TypeRegistry`, `SortKeys.searchFold`, `Generation`, `LanePool`, `LaneContext`, `VolumeID.unknown` (Phase 1).
- Produces: `MetadataScope`, `SpotlightRequest`, `SpotlightPredicate.make`, `MetadataItem`, `MetadataQueryEvent`, `MetadataQuerying`, `SystemMetadataQuery`, `FakeMetadataQuery`, `SpotlightSearch` (`resultLimit`, `events`, `entry(for:types:)`), `IndexingStatus`, `IndexStatusProviding`, `MdutilIndexStatus` (`parse`), `FixedIndexStatus`. Internal: `SpotlightSearch.events(…, limit:)`.

**Design notes:**
- The predicate narrows what Spotlight returns. Correctness comes from the post-filter in `SpotlightSearch`, which runs every item through the same `CriteriaMatcher` as the folder filter and the crawler (Review Focus 1: one glob semantics everywhere), applies `within` (path strictly below) and `directChildrenOf` (parent equals), and drops hidden items unless `includeHidden`.
- Name terms become `kMDItemFSName LIKE[cd]`: a glob term is passed as-is (repeated `*` collapsed, `\` escaped); a plain term becomes `*term*`. Content terms become `kMDItemTextContent CONTAINS[cd]`. Kinds are an OR over `kMDItemContentTypeTree == <id>` (folder: `kMDItemContentType == "public.folder"`); extensions an OR over `kMDItemFSName LIKE[c] "*.<ext>"`; an empty kind or extension set is `FALSEPREDICATE`. Size uses `kMDItemFSSize`, modified `kMDItemFSContentChangeDate`, created `kMDItemFSCreationDate` (lower `>=`, upper `<`). Clauses are ANDed in this order: names, contents, kinds, extensions, size, modified, created. No clause at all gives `kMDItemFSName LIKE "*"`.
- `SystemMetadataQuery` keeps every `NSMetadataQuery` on its own serial `OperationQueue`: the query is created there, its `operationQueue` is that queue, its notifications are observed on that queue, and `stop()` runs there. `QueryRun` is this file's single documented `@unchecked Sendable` confinement exception. During gathering, new results are read on each `NSMetadataQueryGatheringProgress` (between `disableUpdates`/`enableUpdates`) and streamed as `.added`. After `didFinishGathering`, `NSMetadataQueryDidUpdate` user-info keys become `.added`/`.updated`/`.removed`. Removed items are reported by the path recorded when they were added.
- `SpotlightSearch.events` emits `.completed` at `.gatheringFinished` and then keeps forwarding live updates until the consumer cancels. Updated items that no longer pass the post-filter become `.removed`. After `resultLimit` results it emits `.completed(truncated: true)` and ends.
- `MdutilIndexStatus` runs `/usr/bin/mdutil -s <mount point>` (status only, read-only; the one Spotlight CLI the safety rules allow) on a lane with a 2 s timeout, heart-beating while it waits, and caches the answer per mount point for 60 s.

- [ ] **Step 1: Write the failing predicate and adapter tests**

```swift
// Tests/CoreTests/Search/SpotlightPredicateTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class SpotlightPredicateTests: XCTestCase {
    func format(_ c: SearchCriteria, contents: [String] = []) -> String {
        SpotlightPredicate.make(SpotlightRequest(criteria: c, contentTerms: contents, scope: .localComputer)).predicateFormat
    }
    func expected(_ format: String, _ args: CVarArg...) -> String { NSPredicate(format: format, argumentArray: args).predicateFormat }

    // Review Focus 1
    func testGlobTermBecomesLikePatternWithoutExtraStars() {
        XCTAssertEqual(format(SearchCriteria(nameTerms: [NameTerm("*.pdf")])), expected("kMDItemFSName LIKE[cd] %@", "*.pdf"))
        XCTAssertEqual(format(SearchCriteria(nameTerms: [NameTerm("report?.doc")])), expected("kMDItemFSName LIKE[cd] %@", "report?.doc"))
        XCTAssertEqual(format(SearchCriteria(nameTerms: [NameTerm("IMG_**")])), expected("kMDItemFSName LIKE[cd] %@", "IMG_*"))
        XCTAssertEqual(format(SearchCriteria(nameTerms: [NameTerm("tax")])), expected("kMDItemFSName LIKE[cd] %@", "*tax*"))
    }

    func testClausesAreANDedInOrder() {
        let c = SearchCriteria(nameTerms: [NameTerm("a")], kinds: [.pdf], extensions: ["pdf"], size: ByteRange(lower: 10, upper: 20))
        XCTAssertEqual(format(c, contents: ["invoice"]),
                       expected("kMDItemFSName LIKE[cd] %@ AND kMDItemTextContent CONTAINS[cd] %@ AND kMDItemContentTypeTree == %@ AND kMDItemFSName LIKE[c] %@ AND kMDItemFSSize >= %@ AND kMDItemFSSize < %@",
                                "*a*", "invoice", "com.adobe.pdf", "*.pdf", NSNumber(value: 10), NSNumber(value: 20)))
    }

    func testKindsAndExtensionsAreORed() {
        let f = format(SearchCriteria(kinds: [.folder, .image], extensions: ["jpg", "png"]))
        XCTAssertEqual(f, expected("(kMDItemContentType == %@ OR kMDItemContentTypeTree == %@) AND (kMDItemFSName LIKE[c] %@ OR kMDItemFSName LIKE[c] %@)",
                                   "public.folder", "public.image", "*.jpg", "*.png"))
    }

    func testEmptySetsMatchNothingAndEmptyRequestMatchesAll() {
        XCTAssertEqual(format(SearchCriteria(kinds: [])), NSPredicate(value: false).predicateFormat)
        XCTAssertEqual(format(SearchCriteria()), expected("kMDItemFSName LIKE %@", "*"))
    }

    func testDatesUseContentChangeAndCreation() {
        let day: Int64 = 86_400_000_000_000
        let p = SpotlightPredicate.make(SpotlightRequest(criteria: SearchCriteria(modified: TimeRange(lower: day), created: TimeRange(upper: 2 * day)),
                                                         contentTerms: [], scope: .localComputer))
        let want = NSPredicate(format: "kMDItemFSContentChangeDate >= %@ AND kMDItemFSCreationDate < %@",
                               Date(timeIntervalSince1970: 86_400) as NSDate, Date(timeIntervalSince1970: 172_800) as NSDate)
        XCTAssertEqual(p.predicateFormat, want.predicateFormat)
    }
}
```

```swift
// Tests/CoreTests/Search/SpotlightSearchTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class SpotlightSearchTests: XCTestCase {
    let types = TypeRegistry()
    let gen = Generation.initial.next()

    func item(_ path: String, size: Int64 = 5, tree: [String] = ["public.data", "public.item"], invisible: Bool = false) -> MetadataItem {
        MetadataItem(path: path, name: (path as NSString).lastPathComponent, size: size,
                     modified: Date(timeIntervalSince1970: 1_000), created: Date(timeIntervalSince1970: 500),
                     contentTypeTree: tree, isInvisible: invisible)
    }

    struct Seen { var batches: [(String, [String])] = []; var removed: [[String]] = []; var summary: SearchSummary?; var failure: SearchFailure? }

    func run(_ request: SpotlightRequest, _ fake: FakeMetadataQuery, hidden: Bool = false, limit: Int = SpotlightSearch.resultLimit) async -> Seen {
        var seen = Seen()
        for await e in SpotlightSearch.events(request, query: fake, includeHidden: hidden, generation: gen, types: types, limit: limit) {
            switch e {
            case .batch(let b):
                XCTAssertEqual(b.batch.generation, gen)
                seen.batches.append((b.parent.path(percentEncoded: false), (0..<b.batch.count).map { b.batch.name(at: $0) }))
            case .removed(let p): seen.removed.append(p)
            case .completed(let s): seen.summary = s
            case .failed(let f): seen.failure = f
            default: break
            }
        }
        return seen
    }

    func testGroupsByParentAndPostFiltersLikeTheCrawler() async {
        let fake = FakeMetadataQuery(items: [
            item("/r/a/x.pdf"), item("/r/a/y.PDF"), item("/r/b/z.pdf"),
            item("/r/a/x.pdf.zip"),                         // Spotlight LIKE would not return it; the post-filter rejects it anyway
            item("/r/.hid/q.pdf"), item("/r/b/.dot.pdf"), item("/r/b/inv.pdf", invisible: true),
            item("/rx/outside.pdf"),
        ])
        let root = URL(filePath: "/r", directoryHint: .isDirectory)
        let request = SpotlightRequest(criteria: SearchCriteria(nameTerms: [NameTerm("*.pdf")]), contentTerms: [],
                                       scope: .folders([root]), within: root)
        let seen = await run(request, fake)
        XCTAssertEqual(seen.batches.map(\.0), ["/r/a", "/r/b"])
        XCTAssertEqual(seen.batches.map(\.1), [["x.pdf", "y.PDF"], ["z.pdf"]])
        XCTAssertEqual(seen.summary?.resultCount, 3)
        XCTAssertEqual(fake.requests(), [request])
        let shown = await run(request, fake, hidden: true)
        XCTAssertEqual(shown.summary?.resultCount, 6)        // hidden ones too; /rx is still outside `within`
    }

    func testDirectChildrenOnly() async {
        let fake = FakeMetadataQuery(items: [item("/r/a.txt"), item("/r/sub/b.txt")])
        let root = URL(filePath: "/r", directoryHint: .isDirectory)
        let seen = await run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["invoice"], scope: .folders([root]),
                                              directChildrenOf: root), fake)
        XCTAssertEqual(seen.batches.flatMap(\.1), ["a.txt"])
    }

    func testUpdatesAndRemovalsAreForwardedAfterCompletion() async {
        let renamed = MetadataItem(path: "/r/a.doc", name: "a.doc", size: 1, modified: nil, created: nil, contentTypeTree: [], isInvisible: false)
        let fake = FakeMetadataQuery(runs: [[
            .init(.added([item("/r/a.pdf"), item("/r/b.pdf")])), .init(.gatheringFinished),
            .init(.updated([item("/r/b.pdf", size: 99)])),
            .init(.updated([renamed])),                       // no longer matches *.pdf → removed
            .init(.removed(["/r/a.pdf"])),
        ]])
        let seen = await run(SpotlightRequest(criteria: SearchCriteria(nameTerms: [NameTerm("*.pdf")]), contentTerms: [], scope: .localComputer), fake)
        XCTAssertEqual(seen.summary?.resultCount, 2)
        XCTAssertEqual(seen.batches.map(\.1), [["a.pdf", "b.pdf"], ["b.pdf"]])
        XCTAssertEqual(seen.removed, [["/r/a.doc"], ["/r/a.pdf"]])
    }

    func testFailureAndLimit() async {
        let failing = await run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["x"], scope: .localComputer),
                                FakeMetadataQuery(runs: [[.init(.failed)]]))
        XCTAssertEqual(failing.failure, .spotlightFailed)
        let many = FakeMetadataQuery(items: (0..<5).map { item("/r/f\($0).txt") })
        let limited = await run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["x"], scope: .localComputer), many, limit: 3)
        XCTAssertEqual(limited.batches.flatMap(\.1).count, 3)
        XCTAssertEqual(limited.summary?.truncated, true)
    }

    func testEntryConversion() {
        let folder = SpotlightSearch.entry(for: item("/r/Docs", tree: ["public.folder", "public.directory", "public.item"]), types: types)
        XCTAssertEqual(folder.entry.kind, .directory)
        XCTAssertEqual(folder.entry.typeIndex, TypeRegistry.folderIndex)
        XCTAssertEqual(folder.entry.size, 0)
        let app = SpotlightSearch.entry(for: item("/Applications/X.app", tree: ["com.apple.application-bundle", "com.apple.package", "public.directory"]), types: types)
        XCTAssertEqual(app.entry.kind, .package)
        XCTAssertTrue(types.isApplication(app.entry.typeIndex))
        let file = SpotlightSearch.entry(for: item("/r/n.txt", size: 42), types: types)
        XCTAssertEqual(file.name, "n.txt")
        XCTAssertEqual(file.entry.kind, .file)
        XCTAssertEqual(file.entry.size, 42)
        XCTAssertEqual(file.entry.mtime, 1_000_000_000_000)
        XCTAssertEqual(file.entry.ctime, 500_000_000_000)
        XCTAssertNotEqual(file.entry.rowID, SpotlightSearch.entry(for: item("/r/m.txt"), types: types).entry.rowID)
    }

    func testFakeCyclesRunsAndInstallsAtRuntime() async {
        let fake = FakeMetadataQuery(runs: [])
        var events: [MetadataQueryEvent] = []
        for await e in fake.run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: [], scope: .localComputer)) { events.append(e) }
        XCTAssertEqual(events, [.gatheringFinished])
        fake.setRuns([[.init(.added([item("/r/a")])), .init(.gatheringFinished)]])
        events = []
        for await e in fake.run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: [], scope: .localComputer)) { events.append(e) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(fake.requests().count, 2)
    }
}
```

```swift
// Tests/CoreTests/Search/IndexStatusTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class IndexStatusTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(MdutilIndexStatus.parse("/:\n\tIndexing enabled. \n"), .enabled)
        XCTAssertEqual(MdutilIndexStatus.parse("/Volumes/X:\n\tIndexing disabled.\n"), .disabled)
        XCTAssertEqual(MdutilIndexStatus.parse("/Volumes/X:\n\tIndexing and searching disabled.\n"), .disabled)
        XCTAssertEqual(MdutilIndexStatus.parse("/Volumes/X:\n\tError: unable to perform operation.  (-400)\n"), .unknown)
        XCTAssertEqual(MdutilIndexStatus.parse(""), .unknown)
    }

    func testFixed() async {
        let fixed = FixedIndexStatus(.disabled)
        let status = await fixed.status(ofVolumeAt: URL(filePath: "/"))
        XCTAssertEqual(status, .disabled)
    }

    /// Read-only: `mdutil -s /` only reports status.
    func testLiveStatusOfRootIsCached() async {
        let provider = MdutilIndexStatus(lanes: LanePool())
        let first = await provider.status(ofVolumeAt: URL(filePath: "/"))
        let start = ContinuousClock.now
        let second = await provider.status(ofVolumeAt: URL(filePath: "/"))
        XCTAssertEqual(first, second)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(20), "second answer comes from the cache")
    }
}
```

```swift
// Tests/CoreTests/Search/LiveSpotlightTests.swift
import XCTest
@testable import Core
@testable import MacxFS

/// Read-only Spotlight queries against /System/Applications. Writes nothing anywhere.
final class LiveSpotlightTests: XCTestCase {
    let request = SpotlightRequest(criteria: SearchCriteria(nameTerms: [NameTerm("Calculator")], kinds: [.application]),
                                   contentTerms: [],
                                   scope: .folders([URL(filePath: "/System/Applications", directoryHint: .isDirectory)]))

    override func setUp() async throws {
        let status = await MdutilIndexStatus(lanes: LanePool()).status(ofVolumeAt: URL(filePath: "/"))
        guard status == .enabled else { throw XCTSkip("Spotlight indexing is disabled on /") }
    }

    func collectPaths(_ stream: AsyncStream<SearchEvent>) async -> [String] {
        let collector = Task {
            var paths: [String] = []
            for await e in stream {
                if case .batch(let b) = e {
                    paths += (0..<b.batch.count).map { b.parent.appending(path: b.batch.name(at: $0)).path(percentEncoded: false) }
                }
                if case .completed = e { break }
                if case .failed = e { break }
            }
            return paths
        }
        let timer = Task { try await Task.sleep(for: .seconds(20)); collector.cancel() }
        defer { timer.cancel() }
        return await collector.value
    }

    func testSystemQueryStreamsCalculator() async {
        let collector = Task {
            var paths: [String] = []
            for await e in SystemMetadataQuery().run(request) {
                if case .added(let items) = e { paths += items.map(\.path) }
                if e == .gatheringFinished || e == .failed { break }
            }
            return paths
        }
        let timer = Task { try await Task.sleep(for: .seconds(20)); collector.cancel() }
        let found = await collector.value
        timer.cancel()
        XCTAssertTrue(found.contains("/System/Applications/Calculator.app"), "\(found)")
    }

    func testSpotlightSearchOverSystemQuery() async {
        let paths = await collectPaths(SpotlightSearch.events(request, query: SystemMetadataQuery(), includeHidden: false,
                                                              generation: .initial.next()))
        XCTAssertEqual(paths.map { URL(filePath: $0).lastPathComponent }, ["Calculator.app"])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "CoreTests.SpotlightPredicateTests|CoreTests.SpotlightSearchTests|CoreTests.IndexStatusTests|CoreTests.LiveSpotlightTests" 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'SpotlightPredicate' in scope`.

- [ ] **Step 3: Implement request, predicate and query protocol**

```swift
// Sources/Core/Search/SpotlightRequest.swift
import Foundation
import MacxFS

public enum MetadataScope: Sendable, Hashable { case localComputer, folders([URL]) }

public struct SpotlightRequest: Sendable, Hashable {
    public var criteria: SearchCriteria
    public var contentTerms: [String]
    public var scope: MetadataScope
    public var within: URL?               // post-filter: path strictly below this folder
    public var directChildrenOf: URL?     // post-filter: parent equals this folder (This folder + Contents)
    public init(criteria: SearchCriteria, contentTerms: [String], scope: MetadataScope, within: URL? = nil, directChildrenOf: URL? = nil) {
        self.criteria = criteria; self.contentTerms = contentTerms; self.scope = scope
        self.within = within; self.directChildrenOf = directChildrenOf
    }
}
```

```swift
// Sources/Core/Search/SpotlightPredicate.swift
import Foundation
import MacxFS

public enum SpotlightPredicate {
    public static func make(_ request: SpotlightRequest) -> NSPredicate {
        let c = request.criteria
        var clauses: [NSPredicate] = []
        for term in c.nameTerms {
            clauses.append(NSPredicate(format: "%K LIKE[cd] %@", "kMDItemFSName", likePattern(term)))
        }
        for term in request.contentTerms {
            clauses.append(NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", term))
        }
        if let kinds = c.kinds {
            var ors: [NSPredicate] = []
            for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                if kind == .folder { ors.append(NSPredicate(format: "%K == %@", "kMDItemContentType", "public.folder")); continue }
                for id in kind.typeIdentifiers { ors.append(NSPredicate(format: "%K == %@", "kMDItemContentTypeTree", id)) }
            }
            clauses.append(or(ors))
        }
        if let exts = c.extensions {
            clauses.append(or(exts.sorted().map { NSPredicate(format: "%K LIKE[c] %@", "kMDItemFSName", "*." + escape($0)) }))
        }
        if let size = c.size {
            if let l = size.lower { clauses.append(NSPredicate(format: "%K >= %@", "kMDItemFSSize", NSNumber(value: l))) }
            if let u = size.upper { clauses.append(NSPredicate(format: "%K < %@", "kMDItemFSSize", NSNumber(value: u))) }
        }
        dates(c.modified, "kMDItemFSContentChangeDate", into: &clauses)
        dates(c.created, "kMDItemFSCreationDate", into: &clauses)
        if clauses.isEmpty { return NSPredicate(format: "%K LIKE %@", "kMDItemFSName", "*") }
        return clauses.count == 1 ? clauses[0] : NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
    }

    static func likePattern(_ term: NameTerm) -> String {
        let text = escape(term.text)
        guard term.isGlob else { return "*" + text + "*" }
        var out = "", lastStar = false
        for ch in text {
            if ch == "*" { if !lastStar { out.append(ch) }; lastStar = true } else { out.append(ch); lastStar = false }
        }
        return out
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\") }

    static func or(_ ps: [NSPredicate]) -> NSPredicate {
        switch ps.count {
        case 0: return NSPredicate(value: false)
        case 1: return ps[0]
        default: return NSCompoundPredicate(orPredicateWithSubpredicates: ps)
        }
    }

    static func dates(_ range: TimeRange?, _ key: String, into clauses: inout [NSPredicate]) {
        guard let range else { return }
        func date(_ ns: Int64) -> NSDate { Date(timeIntervalSince1970: Double(ns) / 1e9) as NSDate }
        if let l = range.lower { clauses.append(NSPredicate(format: "%K >= %@", key, date(l))) }
        if let u = range.upper { clauses.append(NSPredicate(format: "%K < %@", key, date(u))) }
    }
}
```

```swift
// Sources/Core/Search/MetadataQuerying.swift
import Foundation
import Synchronization

public struct MetadataItem: Sendable, Equatable, Codable {
    public var path: String
    public var name: String
    public var size: Int64?
    public var modified: Date?
    public var created: Date?
    public var contentTypeTree: [String]
    public var isInvisible: Bool
    public init(path: String, name: String, size: Int64?, modified: Date?, created: Date?, contentTypeTree: [String], isInvisible: Bool) {
        self.path = path; self.name = name; self.size = size; self.modified = modified; self.created = created
        self.contentTypeTree = contentTypeTree; self.isInvisible = isInvisible
    }
}

public enum MetadataQueryEvent: Sendable, Equatable { case added([MetadataItem]), updated([MetadataItem]), removed([String]), gatheringFinished, failed }

public protocol MetadataQuerying: Sendable {
    /// One live query per call; cancelling iteration stops it.
    func run(_ request: SpotlightRequest) -> AsyncStream<MetadataQueryEvent>
}

/// Scripted Spotlight for tests and sandboxed app runs (no index access at all).
public final class FakeMetadataQuery: MetadataQuerying {
    public struct Step: Sendable {
        public var delay: Duration
        public var event: MetadataQueryEvent
        public init(delay: Duration = .zero, _ event: MetadataQueryEvent) { self.delay = delay; self.event = event }
    }
    private struct State { var runs: [[Step]]; var count = 0; var requests: [SpotlightRequest] = [] }
    private let state: Mutex<State>

    public init(runs: [[Step]]) { state = Mutex(State(runs: runs)) }
    public convenience init(items: [MetadataItem]) { self.init(runs: [[Step(.added(items)), Step(.gatheringFinished)]]) }

    public func setRuns(_ runs: [[Step]]) { state.withLock { $0.runs = runs; $0.count = 0 } }
    public func requests() -> [SpotlightRequest] { state.withLock { $0.requests } }

    public func run(_ request: SpotlightRequest) -> AsyncStream<MetadataQueryEvent> {
        let steps: [Step] = state.withLock { s in
            s.requests.append(request)
            defer { s.count += 1 }
            return s.runs.isEmpty ? [Step(.gatheringFinished)] : s.runs[min(s.count, s.runs.count - 1)]
        }
        let (stream, continuation) = AsyncStream.makeStream(of: MetadataQueryEvent.self, bufferingPolicy: .unbounded)
        let task = Task {
            for step in steps {
                if step.delay > .zero { try? await Task.sleep(for: step.delay) }
                if Task.isCancelled { break }
                continuation.yield(step.event)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
```

- [ ] **Step 4: Implement `SystemMetadataQuery` (confinement exception)**

```swift
// Sources/Core/Search/SystemMetadataQuery.swift
//
// CONFINEMENT EXCEPTION (Phase 1 Global Constraints): `QueryRun` is `@unchecked Sendable`. Its NSMetadataQuery,
// notification observers and bookkeeping are created, read, mutated and torn down only on `queue`, a private
// serial OperationQueue that is also the query's `operationQueue` and the observers' delivery queue. Callers only
// call `start()`/`stop()`, which enqueue onto `queue`. Nothing else in this file is unchecked, and NSMetadataQuery
// never touches the main thread.
import Foundation

public final class SystemMetadataQuery: MetadataQuerying {
    public init() {}

    public func run(_ request: SpotlightRequest) -> AsyncStream<MetadataQueryEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MetadataQueryEvent.self, bufferingPolicy: .unbounded)
        let run = QueryRun(request: request, continuation: continuation)
        continuation.onTermination = { _ in run.stop() }
        run.start()
        return stream
    }
}

final class QueryRun: @unchecked Sendable {
    private let queue = OperationQueue()
    private let request: SpotlightRequest
    private let continuation: AsyncStream<MetadataQueryEvent>.Continuation
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var delivered = 0
    private var paths: [ObjectIdentifier: String] = [:]
    private var stopped = false

    init(request: SpotlightRequest, continuation: AsyncStream<MetadataQueryEvent>.Continuation) {
        self.request = request
        self.continuation = continuation
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "com.macexplorer.spotlight"
    }

    func start() { queue.addOperation { self.begin() } }
    func stop() { queue.addOperation { self.end() } }

    private func begin() {
        guard !stopped else { return }
        let q = NSMetadataQuery()
        q.operationQueue = queue
        q.predicate = SpotlightPredicate.make(request)
        switch request.scope {
        case .localComputer: q.searchScopes = [NSMetadataQueryLocalComputerScope]
        case .folders(let urls): q.searchScopes = urls
        }
        q.notificationBatchingInterval = 0.1
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: q, queue: queue) { _ in self.drainGathered() },
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: queue) { _ in
                self.drainGathered()
                self.continuation.yield(.gatheringFinished)
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: queue) { note in self.update(note.userInfo) },
        ]
        query = q
        if !q.start() {
            continuation.yield(.failed)
            continuation.finish()
            end()
        }
    }

    private func drainGathered() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        let count = q.resultCount
        guard count > delivered else { return }
        var items: [MetadataItem] = []
        for i in delivered..<count {
            guard let raw = q.result(at: i) as? NSMetadataItem, let item = Self.convert(raw) else { continue }
            paths[ObjectIdentifier(raw)] = item.path
            items.append(item)
        }
        delivered = count
        if !items.isEmpty { continuation.yield(.added(items)) }
    }

    private func update(_ info: [AnyHashable: Any]?) {
        func items(_ key: String) -> [NSMetadataItem] { info?[key] as? [NSMetadataItem] ?? [] }
        let added = items(NSMetadataQueryUpdateAddedItemsKey).compactMap { raw -> MetadataItem? in
            guard let item = Self.convert(raw) else { return nil }
            paths[ObjectIdentifier(raw)] = item.path
            return item
        }
        let changed = items(NSMetadataQueryUpdateChangedItemsKey).compactMap { raw -> MetadataItem? in
            guard let item = Self.convert(raw) else { return nil }
            paths[ObjectIdentifier(raw)] = item.path
            return item
        }
        let removed = items(NSMetadataQueryUpdateRemovedItemsKey).compactMap { raw -> String? in
            paths.removeValue(forKey: ObjectIdentifier(raw)) ?? (raw.value(forAttribute: NSMetadataItemPathKey) as? String)
        }
        if !added.isEmpty { continuation.yield(.added(added)) }
        if !changed.isEmpty { continuation.yield(.updated(changed)) }
        if !removed.isEmpty { continuation.yield(.removed(removed)) }
    }

    private func end() {
        stopped = true
        query?.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        query = nil
    }

    static func convert(_ item: NSMetadataItem) -> MetadataItem? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent
        return MetadataItem(path: path, name: name,
                            size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
                            modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                            created: item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date,
                            contentTypeTree: item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? [],
                            isInvisible: item.value(forAttribute: "kMDItemFSInvisible") as? Bool ?? false)
    }
}
```

If the live test shows results reordering during gathering (indices delivered twice or skipped), switch `drainGathered` to deliver only at `didFinishGathering` and record that in the commit message. Streaming then happens per update batch only.

- [ ] **Step 5: Implement the adapter and index status**

```swift
// Sources/Core/Search/SpotlightSearch.swift
import Foundation
import MacxFS

public enum SpotlightSearch {
    public static let resultLimit = 100_000

    public static func events(_ request: SpotlightRequest, query: any MetadataQuerying, includeHidden: Bool,
                              generation: Generation, types: TypeRegistry = .shared) -> AsyncStream<SearchEvent> {
        events(request, query: query, includeHidden: includeHidden, generation: generation, types: types, limit: resultLimit)
    }

    static func events(_ request: SpotlightRequest, query: any MetadataQuerying, includeHidden: Bool,
                       generation: Generation, types: TypeRegistry, limit: Int) -> AsyncStream<SearchEvent> {
        let (stream, out) = AsyncStream.makeStream(of: SearchEvent.self, bufferingPolicy: .unbounded)
        let task = Task {
            let clock = ContinuousClock()
            let start = clock.now
            var filter = PostFilter(request: request, includeHidden: includeHidden, types: types)
            var count = 0, completed = false
            loop: for await event in query.run(request) {
                if Task.isCancelled { break }
                switch event {
                case .added(var items):
                    items = items.filter { filter.accepts($0) }
                    var truncated = false
                    if items.count > limit - count { items = Array(items.prefix(limit - count)); truncated = true }
                    for b in batches(items, generation: generation, types: types) { out.yield(.batch(b)) }
                    count += items.count
                    if truncated {
                        out.yield(.completed(SearchSummary(resultCount: count, truncated: true, elapsed: clock.now - start)))
                        break loop
                    }
                case .updated(let items):
                    let (keep, drop) = items.reduce(into: ([MetadataItem](), [String]())) { acc, item in
                        if filter.accepts(item) { acc.0.append(item) } else { acc.1.append(item.path) }
                    }
                    for b in batches(keep, generation: generation, types: types) { out.yield(.batch(b)) }
                    if !drop.isEmpty { out.yield(.removed(drop)) }
                case .removed(let paths):
                    out.yield(.removed(paths))
                case .gatheringFinished:
                    if !completed {
                        completed = true
                        out.yield(.completed(SearchSummary(resultCount: count, elapsed: clock.now - start)))
                    }
                case .failed:
                    out.yield(.failed(.spotlightFailed))
                    break loop
                }
            }
            out.finish()
        }
        out.onTermination = { _ in task.cancel() }
        return stream
    }

    struct PostFilter {
        let request: SpotlightRequest
        let includeHidden: Bool
        let types: TypeRegistry
        var matcher: CriteriaMatcher
        let within: String?
        let parent: String?
        init(request: SpotlightRequest, includeHidden: Bool, types: TypeRegistry) {
            self.request = request; self.includeHidden = includeHidden; self.types = types
            matcher = CriteriaMatcher(request.criteria, types: types)
            within = request.within.map { CrawlRun.standardized($0) }
            parent = request.directChildrenOf.map { CrawlRun.standardized($0) }
        }
        mutating func accepts(_ item: MetadataItem) -> Bool {
            if !includeHidden && (item.isInvisible || item.path.split(separator: "/").contains { $0.hasPrefix(".") }) { return false }
            if let within, !item.path.hasPrefix(within == "/" ? "/" : within + "/") { return false }
            if let parent, (item.path as NSString).deletingLastPathComponent != parent { return false }
            let (entry, name) = SpotlightSearch.entry(for: item, types: types)
            return SortKeys.searchFold(name).withUnsafeBytes { matcher.matches(entry, foldedName: $0) }
        }
    }

    static func batches(_ items: [MetadataItem], generation: Generation, types: TypeRegistry) -> [SearchBatch] {
        var order: [String] = []
        var byParent: [String: Batch] = [:]
        for item in items {
            let parent = (item.path as NSString).deletingLastPathComponent
            if byParent[parent] == nil { order.append(parent); byParent[parent] = Batch(generation: generation) }
            let (entry, name) = entry(for: item, types: types)
            Array(name.utf8).withUnsafeBufferPointer { byParent[parent]!.append(entry, nameBytes: $0) }
        }
        return order.map { SearchBatch(parent: URL(filePath: $0, directoryHint: .isDirectory), batch: byParent[$0]!) }
    }

    public static func entry(for item: MetadataItem, types: TypeRegistry) -> (entry: Entry, name: String) {
        let name = item.name
        let tree = item.contentTypeTree
        let isDir = tree.contains("public.directory") || tree.contains("public.folder")
        let ext = Substring((name as NSString).pathExtension)
        var kind: Kind = tree.contains("public.symlink") ? .symlink : .file
        var typeIndex = types.index(forExtension: ext, isDirectory: isDir)
        if isDir {
            if types.isPackage(typeIndex) { kind = .package } else { kind = .directory; typeIndex = TypeRegistry.folderIndex }
        }
        var flags: EntryFlags = [.readable]
        if name.hasPrefix(".") { flags.insert(.dotName) } else if item.isInvisible { flags.insert(.bsdHidden) }
        func ns(_ d: Date?) -> Int64 { d.map { Int64(($0.timeIntervalSince1970 * 1e9).rounded()) } ?? 0 }
        let id = fnv1a(item.path)
        let entry = Entry(rowID: id, fileID: id, size: isDir && kind == .directory ? 0 : (item.size ?? 0),
                          allocSize: item.size ?? 0, mtime: ns(item.modified), ctime: ns(item.created),
                          nameOffset: 0, nameLen: UInt16(min(name.utf8.count, Int(UInt16.max))), kind: kind,
                          flags: flags, typeIndex: typeIndex)
        return (entry, name)
    }

    /// Stable synthetic row id (results identity is the path; IconCache only needs a stable value).
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h &*= 0x0000_0100_0000_01B3 }
        return h
    }
}
```

```swift
// Sources/Core/Search/IndexStatus.swift
import Foundation
import Synchronization
import MacxFS

public enum IndexingStatus: String, Sendable, Codable { case enabled, disabled, unknown }

public protocol IndexStatusProviding: Sendable {
    func status(ofVolumeAt mountPoint: URL) async -> IndexingStatus
}

public struct FixedIndexStatus: IndexStatusProviding {
    let value: IndexingStatus
    public init(_ status: IndexingStatus) { value = status }
    public func status(ofVolumeAt mountPoint: URL) async -> IndexingStatus { value }
}

/// `/usr/bin/mdutil -s` (status only; never -i/-E/-X) on a lane, with timeout and a per-mount-point cache.
public final class MdutilIndexStatus: IndexStatusProviding {
    private let lanes: LanePool
    private let timeout: Duration
    private let cacheLifetime: Duration
    private let cache = Mutex<[String: CacheEntry]>([:])
    private struct CacheEntry: Sendable { var status: IndexingStatus; var at: ContinuousClock.Instant }

    public init(lanes: LanePool, timeout: Duration = .seconds(2), cacheLifetime: Duration = .seconds(60)) {
        self.lanes = lanes; self.timeout = timeout; self.cacheLifetime = cacheLifetime
    }

    public func status(ofVolumeAt mountPoint: URL) async -> IndexingStatus {
        let key = CrawlPermissions.trim(mountPoint.standardizedFileURL.path(percentEncoded: false))
        let lifetime = cacheLifetime
        if let hit = cache.withLock({ $0[key] }), ContinuousClock.now - hit.at < lifetime { return hit.status }
        let timeout = self.timeout
        let status = (try? await lanes.perform(on: .unknown) { context in
            Self.runMdutil(key, timeout: timeout, context: context)
        }) ?? .unknown
        cache.withLock { $0[key] = CacheEntry(status: status, at: ContinuousClock.now) }
        return status
    }

    static func runMdutil(_ path: String, timeout: Duration, context: LaneContext) -> IndexingStatus {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/mdutil")
        process.arguments = ["-s", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return .unknown }
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now >= deadline { process.terminate(); return .unknown }
            context.heartbeat()
            usleep(20_000)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ output: String) -> IndexingStatus {
        let text = output.lowercased()
        if text.contains("indexing enabled") { return .enabled }
        if text.contains("disabled") { return .disabled }
        return .unknown
    }
}
```

`MdutilIndexStatus` only has `let` properties of Sendable types (`LanePool`, `Duration`, `Mutex`), so it is `Sendable` without `@unchecked`.

- [ ] **Step 6: Run the P3-05 tests**

Run: `swift test --filter "CoreTests.SpotlightPredicateTests|CoreTests.SpotlightSearchTests|CoreTests.IndexStatusTests|CoreTests.LiveSpotlightTests" 2>&1 | tail -5`
Expected: `Executed 16 tests, with 0 failures` (on a Mac with Spotlight off, the two live tests report `skipped`).

If `testClausesAreANDedInOrder` or `testKindsAndExtensionsAreORed` differ only in parenthesization, the expected string must still be built the same way: change the expectation to `NSCompoundPredicate` built from the same subpredicates instead of a format string, not the implementation's clause order.

- [ ] **Step 7: Build and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`.

```bash
git add Sources/Core/Search/SpotlightRequest.swift Sources/Core/Search/SpotlightPredicate.swift Sources/Core/Search/MetadataQuerying.swift Sources/Core/Search/SystemMetadataQuery.swift Sources/Core/Search/SpotlightSearch.swift Sources/Core/Search/IndexStatus.swift Tests/CoreTests/Search
git commit -m "feat: Spotlight search adapter on a private queue, post-filter and index status"
```

---

### Task P3-06: Search planner, context and results model

**Files:**
- Create: `Sources/Core/Search/SearchPlanner.swift`, `Sources/Core/Search/SearchContext.swift`, `Sources/Core/Search/ResultSorter.swift`, `Sources/Core/Search/SearchResultsModel.swift`, `Sources/Core/Preview/Ubiquitous.swift` (protocol and the two implementations only; P3-08 adds `DownloadWatcher`)
- Modify: `Sources/Core/Support/CoreEnvironment.swift` (`searchServices`, `searchContext()`, `planSearch(_:)`, `makeSearchResults(_:plan:)`)
- Test: `Tests/CoreTests/Search/SearchPlannerTests.swift`, `Tests/CoreTests/Search/SearchResultsModelTests.swift`

**Interfaces:**
- Consumes: `SearchSpec`, `SearchResolver`, `ResolvedSearch`, `SyntaxDiagnostic` (P3-02); `RowSource`, `RowSourceEvent`, `SelectionRowSpace`, `Selection.apply/reconcile`, `SearchResultStore`, `SearchEvent` and friends, `ChangeBus.observeAll` (P3-03); `SubtreeCrawler`, `CrawlOptions`, `CrawlPermissions`, `CrawlRun.prefix/standardized` (P3-04); `SpotlightSearch`, `SpotlightRequest`, `MetadataQuerying`, `FakeMetadataQuery`, `SystemMetadataQuery`, `IndexStatusProviding`, `MdutilIndexStatus`, `FixedIndexStatus` (P3-05); `LanePool`, `Volumes`, `TypeRegistry`, `ChangeBus`, `Settings` (`home`, `showHidden`, `tccOutcome(for:)`), `ProtectedLocation`, `TCCOutcome`, `FramePacer`, `TimerFramePacer`, `NameRules`, `Observers`, `CoreEnvironment` (Phase 1).
- Produces: `PlanInputs`, `SearchEngine`, `SearchPlan`, `SearchPlanner`, `SearchServices` (`system`, `fake`), `SearchContext` (`plan`, `crawlPermissions`), `CrawlPermissions.make(home:outcome:)`, `SearchState`, `SearchModelEvent`, `SearchResultsModel` (both initializers, `start/stop/rerun/close/observe`, `RowSource`), `UbiquitousDownloading`, `SystemUbiquitousDownloader`, `FakeUbiquitousDownloader`, `CoreEnvironment.searchServices/searchContext()/planSearch(_:)/makeSearchResults(_:plan:)`; internal `ResultSorter`.

**Routing table (`SearchPlanner.plan`).** "Indexed" means `rootIndexing == .enabled`, or `.unknown` on a local volume. "Fallback criteria" means the criteria with the content terms appended as name terms.

| Scope | Mode / content terms | Condition | Engine | Notices |
|---|---|---|---|---|
| any | empty spec or empty resolved search | | `.none` | |
| This folder | Name, or Contents without free terms | | `.folderFilter(criteria)` | |
| This folder | Contents with terms | indexed | `.spotlight(scope: .folders([root]), directChildrenOf: root)` | |
| This folder | Contents with terms | not indexed | `.folderFilter(fallback)` | `.contentsNotIndexed(volumeName)` |
| Subfolders | Name, or Contents without free terms | | `.crawler(root, criteria)` | |
| Subfolders | Contents with terms | indexed | `.spotlight(scope: .folders([root]), within: root)` | |
| Subfolders | Contents with terms | not indexed | `.crawler(root, fallback)` | `.contentsNotIndexed(volumeName)` |
| This Mac | either | `bootIndexing == .disabled` | `.none` | `.spotlightOff` |
| This Mac | either | otherwise | `.spotlight(scope: .localComputer)` (content terms only in Contents mode) | |

Diagnostics always pass through to `SearchPlan.diagnostics`. `needsIndexStatus(spec)` is `!spec.isEmptyQuery && (spec.scope == .thisMac || spec.mode == .contents)`. Only then does `SearchContext.plan` ask the index-status provider: about the boot volume for This Mac, otherwise about the root's volume.

**Results model behaviour:**
- `start()` bumps `generation`, sets `.searching`, and consumes the engine stream in a main-actor Task. Batches whose `batch.generation` is not the current generation are dropped (Review Focus 5).
- Rows are applied by a single pump that runs at most once per `pacer.nextFrame()`. It applies queued ops (batch, removed paths, rename, removed folder prefix) to `results`. New indices are merged into the current order with `ResultSorter.merge` (O(n + k log k) on main). A sort change instead runs `ResultSorter.permutationOffMain` (`@concurrent`) on a snapshot; no op touches `results` while that runs, because ops are applied only at the top of the pump loop. Each round emits one `.changes(.reset)` and, if it changed, `.selection`. Selection is reconciled by identity (path).
- `.completed` is applied after the pump has flushed the batches before it. Then: `.truncated(limit:)` if the summary is truncated; `.skippedLocations(count:)` if `skippedTotal > 0`; `.mayNotBeIndexed` if the engine was a folder-scoped Spotlight query and there are 0 results. After completion, Spotlight live updates keep changing rows; the state stays `.complete`.
- The cap is enforced again in the model: past `resultLimit` rows it cancels the engine and completes with `truncated == true`.
- Local changes (`ChangeBus.observeAll`, Review Focus 3): a removed name drops its row and every result under it (folder trashed or moved); a renamed item is re-keyed to its new name and re-sorted; results under a renamed folder are dropped (their paths are stale, and opening a stale row must never happen). Added and modified names do not join the results.
- `stop()` cancels the engine and moves to `.stopped(summary)`; batches already received are still shown. `rerun()` clears rows, selection and notices back to the plan's, then `start()`s with a new generation. `close()` cancels the engine and the bus observer, and afterwards emits nothing.
- `validateName` checks only listed siblings. Unlisted siblings are caught by the rename job's `RENAME_EXCL`, which reports `EEXIST` through the normal error dialog.

- [ ] **Step 1: Write the failing planner tests**

```swift
// Tests/CoreTests/Search/SearchPlannerTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class SearchPlannerTests: XCTestCase {
    let root = URL(filePath: "/tmp/macx-tests-plan/root", directoryHint: .isDirectory)
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func plan(_ text: String, _ scope: SearchScope, _ mode: SearchMode = .name, root rootIdx: IndexingStatus = .enabled,
              boot: IndexingStatus = .enabled, local: Bool = true, filters: SearchFilters = SearchFilters()) -> SearchPlan {
        let spec = SearchSpec(text: text, scope: scope, mode: mode, filters: filters, root: root)
        return SearchPlanner.plan(spec, resolved: SearchResolver.resolve(spec, now: now, calendar: cal),
                                  inputs: PlanInputs(rootIndexing: rootIdx, bootIndexing: boot, rootIsLocal: local, rootVolumeName: "Data"))
    }
    let tax = SearchCriteria(nameTerms: [NameTerm("tax")])

    func testThisFolder() {
        XCTAssertEqual(plan("tax", .thisFolder).engine, .folderFilter(tax))
        XCTAssertEqual(plan("tax", .thisFolder, .contents).engine,
                       .spotlight(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["tax"], scope: .folders([root]), directChildrenOf: root)))
        let fallback = plan("tax", .thisFolder, .contents, root: .disabled)
        XCTAssertEqual(fallback.engine, .folderFilter(tax))
        XCTAssertEqual(fallback.notices, [.contentsNotIndexed(volumeName: "Data")])
    }

    func testSubfolders() {
        XCTAssertEqual(plan("tax", .subfolders).engine, .crawler(root: root, criteria: tax))
        XCTAssertEqual(plan("tax", .subfolders, .contents).engine,
                       .spotlight(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["tax"], scope: .folders([root]), within: root)))
        let fallback = plan("tax", .subfolders, .contents, root: .disabled)
        XCTAssertEqual(fallback.engine, .crawler(root: root, criteria: tax))
        XCTAssertEqual(fallback.notices, [.contentsNotIndexed(volumeName: "Data")])
        XCTAssertEqual(plan("tax", .subfolders, .contents, root: .unknown, local: true).engine,
                       .spotlight(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["tax"], scope: .folders([root]), within: root)))
        XCTAssertEqual(plan("tax", .subfolders, .contents, root: .unknown, local: false).engine, .crawler(root: root, criteria: tax))
        // Contents mode with only filters uses the name engines.
        XCTAssertEqual(plan("kind:pdf", .subfolders, .contents, root: .disabled).engine,
                       .crawler(root: root, criteria: SearchCriteria(kinds: [.pdf])))
    }

    func testThisMac() {
        XCTAssertEqual(plan("tax", .thisMac).engine, .spotlight(SpotlightRequest(criteria: tax, contentTerms: [], scope: .localComputer)))
        XCTAssertEqual(plan("tax", .thisMac, .contents).engine,
                       .spotlight(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["tax"], scope: .localComputer)))
        let off = plan("tax", .thisMac, boot: .disabled)
        XCTAssertEqual(off.engine, .none)
        XCTAssertEqual(off.notices, [.spotlightOff])
    }

    func testEmptyAndDiagnostics() {
        XCTAssertEqual(plan("   ", .subfolders).engine, .none)
        let p = plan("size:big", .subfolders)
        XCTAssertEqual(p.engine, .none)
        XCTAssertEqual(p.diagnostics, [SyntaxDiagnostic(token: "size:big", problem: .badSize)])
        XCTAssertEqual(plan("tax size:big", .subfolders).diagnostics.count, 1)
    }

    func testNeedsIndexStatus() {
        XCTAssertFalse(SearchPlanner.needsIndexStatus(SearchSpec(text: "a", scope: .subfolders, root: root)))
        XCTAssertTrue(SearchPlanner.needsIndexStatus(SearchSpec(text: "a", scope: .subfolders, mode: .contents, root: root)))
        XCTAssertTrue(SearchPlanner.needsIndexStatus(SearchSpec(text: "a", scope: .thisMac, root: root)))
        XCTAssertFalse(SearchPlanner.needsIndexStatus(SearchSpec(text: "", scope: .thisMac, root: root)))
    }

    func testCrawlPermissionsFromTCCOutcomes() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let p = CrawlPermissions.make(home: home) { $0 == .documents ? .granted : nil }
        XCTAssertTrue(p.isBlocked("/Users/someone/Desktop/a"))
        XCTAssertFalse(p.isBlocked("/Users/someone/Documents/a"))
        XCTAssertTrue(p.isBlocked("/Users/someone/Library/Mobile Documents/x"))
        XCTAssertTrue(p.isBlocked("/Users/someone/Library/Containers/com.x/Data"))
        XCTAssertFalse(p.isBlocked("/Users/someone/dev/project"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CoreTests.SearchPlannerTests 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'SearchPlanner' in scope`.

- [ ] **Step 3: Implement the planner, services, context and downloader protocol**

```swift
// Sources/Core/Search/SearchPlanner.swift
import Foundation
import MacxFS

public struct PlanInputs: Sendable, Equatable {
    public var rootIndexing: IndexingStatus
    public var bootIndexing: IndexingStatus
    public var rootIsLocal: Bool
    public var rootVolumeName: String
    public init(rootIndexing: IndexingStatus, bootIndexing: IndexingStatus, rootIsLocal: Bool, rootVolumeName: String) {
        self.rootIndexing = rootIndexing; self.bootIndexing = bootIndexing
        self.rootIsLocal = rootIsLocal; self.rootVolumeName = rootVolumeName
    }
}

public enum SearchEngine: Sendable, Equatable {
    case none
    case folderFilter(SearchCriteria)
    case crawler(root: URL, criteria: SearchCriteria)
    case spotlight(SpotlightRequest)
}

public struct SearchPlan: Sendable, Equatable {
    public var engine: SearchEngine
    public var notices: [SearchNotice]
    public var diagnostics: [SyntaxDiagnostic]
    public init(engine: SearchEngine, notices: [SearchNotice] = [], diagnostics: [SyntaxDiagnostic] = []) {
        self.engine = engine; self.notices = notices; self.diagnostics = diagnostics
    }
}

public enum SearchPlanner {
    public static func needsIndexStatus(_ spec: SearchSpec) -> Bool {
        !spec.isEmptyQuery && (spec.scope == .thisMac || spec.mode == .contents)
    }

    public static func plan(_ spec: SearchSpec, resolved: ResolvedSearch, inputs: PlanInputs) -> SearchPlan {
        let d = resolved.diagnostics
        guard !spec.isEmptyQuery, !resolved.isEmpty else { return SearchPlan(engine: .none, diagnostics: d) }
        let root = spec.root.standardizedFileURL
        let criteria = resolved.criteria
        let terms = resolved.contentTerms
        let indexed = inputs.rootIndexing == .enabled || (inputs.rootIndexing == .unknown && inputs.rootIsLocal)
        var fallback = criteria
        fallback.nameTerms += terms.map(NameTerm.init)
        let notIndexed: [SearchNotice] = [.contentsNotIndexed(volumeName: inputs.rootVolumeName)]
        switch spec.scope {
        case .thisFolder:
            if terms.isEmpty { return SearchPlan(engine: .folderFilter(criteria), diagnostics: d) }
            if indexed {
                return SearchPlan(engine: .spotlight(SpotlightRequest(criteria: criteria, contentTerms: terms,
                                                                      scope: .folders([root]), directChildrenOf: root)), diagnostics: d)
            }
            return SearchPlan(engine: .folderFilter(fallback), notices: notIndexed, diagnostics: d)
        case .subfolders:
            if terms.isEmpty { return SearchPlan(engine: .crawler(root: root, criteria: criteria), diagnostics: d) }
            if indexed {
                return SearchPlan(engine: .spotlight(SpotlightRequest(criteria: criteria, contentTerms: terms,
                                                                      scope: .folders([root]), within: root)), diagnostics: d)
            }
            return SearchPlan(engine: .crawler(root: root, criteria: fallback), notices: notIndexed, diagnostics: d)
        case .thisMac:
            if inputs.bootIndexing == .disabled { return SearchPlan(engine: .none, notices: [.spotlightOff], diagnostics: d) }
            return SearchPlan(engine: .spotlight(SpotlightRequest(criteria: criteria, contentTerms: terms, scope: .localComputer)),
                              diagnostics: d)
        }
    }
}
```

```swift
// Sources/Core/Preview/Ubiquitous.swift
import Foundation
import Darwin
import Synchronization
import MacxFS

public protocol UbiquitousDownloading: Sendable {
    func startDownloading(_ url: URL) async throws
    func isDataless(_ url: URL) async -> Bool
}

/// Real iCloud/File Provider download. Tests never use it on real files (Phase 3 safety rule).
public struct SystemUbiquitousDownloader: UbiquitousDownloading {
    let lanes: LanePool
    public init(lanes: LanePool) { self.lanes = lanes }
    public func startDownloading(_ url: URL) async throws {
        try await lanes.perform(on: .unknown) { _ in try FileManager.default.startDownloadingUbiquitousItem(at: url) }
    }
    /// lstat only: reading SF_DATALESS never materializes.
    public func isDataless(_ url: URL) async -> Bool {
        (try? await lanes.perform(on: .unknown) { _ in
            var st = stat()
            guard lstat(url.path(percentEncoded: false), &st) == 0 else { return false }
            return st.st_flags & UInt32(SF_DATALESS) != 0
        }) ?? false
    }
}

/// Before `startDownloading(url)` every poll is dataless; afterwards the first `datalessPolls` polls still are.
public final class FakeUbiquitousDownloader: UbiquitousDownloading {
    private struct State { var started: [URL] = []; var polls: [URL: Int] = [:] }
    private let state = Mutex(State())
    private let datalessPolls: Int
    private let failStart: Bool
    public init(datalessPolls: Int = 2, failStart: Bool = false) { self.datalessPolls = datalessPolls; self.failStart = failStart }
    public func started() -> [URL] { state.withLock { $0.started } }
    public func startDownloading(_ url: URL) async throws {
        state.withLock { $0.started.append(url) }
        if failStart { throw CocoaError(.ubiquitousFileUnavailable) }
        state.withLock { $0.polls[url] = 0 }
    }
    public func isDataless(_ url: URL) async -> Bool {
        state.withLock { s in
            guard let n = s.polls[url] else { return true }
            s.polls[url] = n + 1
            return n < datalessPolls
        }
    }
}
```

```swift
// Sources/Core/Search/SearchContext.swift
import Foundation
import MacxFS

public struct SearchServices: Sendable {
    public var metadataQuery: any MetadataQuerying
    public var indexStatus: any IndexStatusProviding
    public var downloader: any UbiquitousDownloading
    public init(metadataQuery: any MetadataQuerying, indexStatus: any IndexStatusProviding, downloader: any UbiquitousDownloading) {
        self.metadataQuery = metadataQuery; self.indexStatus = indexStatus; self.downloader = downloader
    }
    public static func system(lanes: LanePool) -> SearchServices {
        SearchServices(metadataQuery: SystemMetadataQuery(), indexStatus: MdutilIndexStatus(lanes: lanes),
                       downloader: SystemUbiquitousDownloader(lanes: lanes))
    }
    /// Sandboxed runs and tests: no Spotlight index access, no real downloads.
    public static func fake(items: [MetadataItem] = [], indexing: IndexingStatus = .disabled) -> SearchServices {
        SearchServices(metadataQuery: FakeMetadataQuery(items: items), indexStatus: FixedIndexStatus(indexing),
                       downloader: FakeUbiquitousDownloader())
    }
}

@MainActor
public struct SearchContext {
    public var lanes: LanePool
    public var volumes: Volumes
    public var types: TypeRegistry
    public var changeBus: ChangeBus
    public var settings: Settings
    public var pacer: any FramePacer
    public var services: SearchServices
    public var now: @Sendable () -> Date
    public var calendar: Calendar

    public init(lanes: LanePool, volumes: Volumes, types: TypeRegistry, changeBus: ChangeBus, settings: Settings,
                pacer: any FramePacer, services: SearchServices,
                now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.lanes = lanes; self.volumes = volumes; self.types = types; self.changeBus = changeBus
        self.settings = settings; self.pacer = pacer; self.services = services; self.now = now; self.calendar = calendar
    }

    public func plan(_ spec: SearchSpec) async -> SearchPlan {
        let resolved = SearchResolver.resolve(spec, now: now(), calendar: calendar)
        let volume = volumes.volume(for: spec.root)
        var rootStatus = IndexingStatus.unknown, bootStatus = IndexingStatus.unknown
        if SearchPlanner.needsIndexStatus(spec) {
            if spec.scope == .thisMac {
                let boot = volumes.list.first(where: \.isBoot)?.mountPoint ?? URL(filePath: "/", directoryHint: .isDirectory)
                bootStatus = await services.indexStatus.status(ofVolumeAt: boot)
            } else {
                rootStatus = await services.indexStatus.status(ofVolumeAt: volume?.mountPoint ?? URL(filePath: "/", directoryHint: .isDirectory))
            }
        }
        let inputs = PlanInputs(rootIndexing: rootStatus, bootIndexing: bootStatus, rootIsLocal: volume?.isLocal ?? true,
                                rootVolumeName: volume?.name ?? spec.root.lastPathComponent)
        return SearchPlanner.plan(spec, resolved: resolved, inputs: inputs)
    }

    public func crawlPermissions() -> CrawlPermissions {
        var known: [ProtectedLocation: TCCOutcome] = [:]
        for location in [ProtectedLocation.desktop, .documents, .downloads, .iCloudDrive] {
            if let o = settings.tccOutcome(for: location) { known[location] = o }
        }
        return CrawlPermissions.make(home: settings.home) { known[$0] }
    }
}

extension CrawlPermissions {
    /// Folders whose opening could raise a TCC prompt. Desktop/Documents/Downloads/iCloud Drive are blocked
    /// unless a grant was recorded (Phase 1 records outcomes when the user browses them); app-data locations always.
    static let alwaysBlocked = [
        "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/Cookies", "Library/HomeKit", "Library/Calendars", "Library/Reminders", "Library/Biome",
        "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/com.apple.TCC", "Library/Suggestions", "Library/Metadata/CoreSpotlight", ".Trash",
    ]

    public static func make(home: URL, outcome: (ProtectedLocation) -> TCCOutcome?) -> CrawlPermissions {
        let h = trim(home.standardizedFileURL.path(percentEncoded: false))
        var blocked: [String] = []
        let protected: [(ProtectedLocation, String)] = [(.desktop, "Desktop"), (.documents, "Documents"),
                                                        (.downloads, "Downloads"), (.iCloudDrive, "Library/Mobile Documents")]
        for (location, relative) in protected where outcome(location) != .granted { blocked.append(h + "/" + relative) }
        blocked += alwaysBlocked.map { h + "/" + $0 }
        return CrawlPermissions(blockedPrefixes: blocked)
    }
}
```

In `CoreEnvironment.swift`:
- Add `public let searchServices: SearchServices`. Add the init parameter `searchServices: SearchServices? = nil` (last, after `fileOpTuning`) and assign `self.searchServices = searchServices ?? .system(lanes: lanes)`.
- `sandboxed(root:)` passes `searchServices: .fake()`.
- Add:

```swift
    public func searchContext() -> SearchContext {
        SearchContext(lanes: lanes, volumes: volumes, types: types, changeBus: changeBus, settings: settings,
                      pacer: TimerFramePacer(), services: searchServices)
    }
    public func planSearch(_ spec: SearchSpec) async -> SearchPlan { await searchContext().plan(spec) }
```

`makeSearchResults(_:plan:)` is added in Step 8, once `SearchResultsModel` exists.

- [ ] **Step 4: Run the planner tests**

Run: `swift test --filter CoreTests.SearchPlannerTests 2>&1 | tail -5`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Write the failing results-model tests**

```swift
// Tests/CoreTests/Search/SearchResultsModelTests.swift
import XCTest
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class Script {
    var continuations: [Generation: AsyncStream<SearchEvent>.Continuation] = [:]
    var terminated: [Generation] = []
    lazy var factory: @MainActor (Generation) -> AsyncStream<SearchEvent> = { [unowned self] gen in
        let (stream, c) = AsyncStream.makeStream(of: SearchEvent.self)
        c.onTermination = { _ in Task { @MainActor in self.terminated.append(gen) } }
        self.continuations[gen] = c
        return stream
    }
}

@MainActor
final class SearchResultsModelTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    let types = TypeRegistry.shared

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        env = CoreEnvironment.sandboxed(root: sandbox.root)
    }

    var rootPath: String { let p = sandbox.root.path(percentEncoded: false); return p.hasSuffix("/") ? String(p.dropLast()) : p }

    func batch(_ parent: String, _ names: [String], dirs: Set<String> = [], gen: Generation) -> SearchEvent {
        var b = Batch(generation: gen)
        for name in names {
            let isDir = dirs.contains(name)
            let e = Entry(rowID: 1, fileID: 1, size: Int64(name.count), allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0,
                          nameLen: UInt16(name.utf8.count), kind: isDir ? .directory : .file, flags: [],
                          typeIndex: isDir ? TypeRegistry.folderIndex
                              : types.index(forExtension: Substring((name as NSString).pathExtension), isDirectory: false))
            Array(name.utf8).withUnsafeBufferPointer { b.append(e, nameBytes: $0) }
        }
        return .batch(SearchBatch(parent: URL(filePath: rootPath + parent, directoryHint: .isDirectory), batch: b))
    }

    func names(_ m: SearchResultsModel) -> [String] { (0..<m.rowCount).map { m.name(atRow: $0) } }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    func makeModel(_ script: Script) -> SearchResultsModel {
        let m = SearchResultsModel(title: "test", events: script.factory, context: env.searchContext())
        addTeardownBlock { @MainActor in m.close() }
        return m
    }

    func testStreamsSortsFoldersFirstAndCompletes() async {
        let script = Script()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/b", ["zeta.txt", "Alpha.txt"], gen: gen))
        script.continuations[gen]!.yield(batch("/a", ["middle.txt", "Folder"], dirs: ["Folder"], gen: gen))
        script.continuations[gen]!.yield(.completed(SearchSummary(resultCount: 4, directoriesScanned: 3)))
        await waitUntil("complete") { if case .complete = m.state { true } else { false } }
        XCTAssertEqual(names(m), ["Folder", "Alpha.txt", "middle.txt", "zeta.txt"])
        XCTAssertEqual(m.parentURL(atRow: 2).lastPathComponent, "a")
        XCTAssertTrue(m.showsPathColumn)
        if case .complete(let s) = m.state { XCTAssertEqual(s.resultCount, 4) }
    }

    func testPathSort() async {
        let script = Script()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/b", ["a.txt"], gen: gen))
        script.continuations[gen]!.yield(batch("/a", ["z.txt", "b.txt"], gen: gen))
        await waitUntil("rows") { m.rowCount == 3 }
        m.setSortDescriptor(SortDescriptor(field: .path, ascending: true))
        await waitUntil("path order") { (0..<3).map { m.url(atRow: $0).path(percentEncoded: false) }.map { String($0.suffix(7)) } == ["a/b.txt", "a/z.txt", "b/a.txt"] }
        m.setSortDescriptor(SortDescriptor(field: .path, ascending: false))
        await waitUntil("descending") { m.name(atRow: 0) == "a.txt" }
    }

    // Review Focus 5
    func testRestartDropsStaleGenerationBatches() async {
        let script = Script()
        let m = makeModel(script)
        m.start()
        let old = m.generation
        script.continuations[old]!.yield(batch("/", ["old-1.txt"], gen: old))
        await waitUntil("first rows") { m.rowCount == 1 }
        m.rerun()
        let new = m.generation
        XCTAssertGreaterThan(new, old)
        script.continuations[old]!.yield(batch("/", ["old-late.txt"], gen: old))       // late batch from the old engine
        script.continuations[new]!.yield(batch("/", ["stamped-old.txt"], gen: old))    // wrong generation on the new stream
        script.continuations[new]!.yield(batch("/", ["new.txt"], gen: new))
        await waitUntil("new rows") { m.rowCount >= 1 && m.name(atRow: 0) == "new.txt" }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(names(m), ["new.txt"])
        await waitUntil("old engine stopped") { script.terminated.contains(old) }
    }

    // Review Focus 5
    func testCloseStopsEngineAndEmitsNothing() async {
        let script = Script()
        let m = makeModel(script)
        var events = 0
        let token = m.observe { _ in events += 1 }
        defer { token.cancel() }
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/", ["a.txt"], gen: gen))
        await waitUntil("row") { m.rowCount == 1 }
        m.close()
        let before = events
        script.continuations[gen]!.yield(batch("/", ["b.txt"], gen: gen))
        script.continuations[gen]!.yield(.completed(SearchSummary()))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events, before)
        XCTAssertEqual(names(m), ["a.txt"])
        await waitUntil("engine terminated") { script.terminated.contains(gen) }
    }

    // Review Focus 3
    func testLocalChangesRemoveAndRenameResults() async throws {
        let script = Script()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/dir", ["a.txt", "b.txt", "sub"], dirs: ["sub"], gen: gen))
        script.continuations[gen]!.yield(batch("/dir/sub", ["c.txt"], gen: gen))
        script.continuations[gen]!.yield(.completed(SearchSummary(resultCount: 4)))
        await waitUntil("rows") { m.rowCount == 4 }
        let dir = URL(filePath: rootPath + "/dir", directoryHint: .isDirectory)
        env.changeBus.post([LocalChange(directory: dir, removed: ["a.txt"], renamed: [LocalChange.Rename(from: "b.txt", to: "z.txt")])])
        await waitUntil("trash + rename applied") { Set(self.names(m)) == ["sub", "c.txt", "z.txt"] }
        let z = try XCTUnwrap((0..<m.rowCount).first { m.name(atRow: $0) == "z.txt" })
        XCTAssertEqual(m.url(atRow: z).path(percentEncoded: false), rootPath + "/dir/z.txt")
        env.changeBus.post([LocalChange(directory: dir, removed: ["sub"])])           // folder trashed: its results go too
        await waitUntil("folder removal") { self.names(m) == ["z.txt"] }
        if case .complete = m.state {} else { XCTFail("state stays complete: \(m.state)") }
    }

    func testSelectionFollowsIdentityAcrossBatches() async {
        let script = Script()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/", ["m.txt", "z.txt"], gen: gen))
        await waitUntil("rows") { m.rowCount == 2 }
        m.select(.set([1], cursor: 1))
        XCTAssertEqual(m.selectedURLs.map(\.lastPathComponent), ["z.txt"])
        script.continuations[gen]!.yield(batch("/", ["a.txt"], gen: gen))
        await waitUntil("merged") { m.rowCount == 3 }
        XCTAssertEqual(m.selection.rows, [2])
        XCTAssertEqual(m.selectedURLs.map(\.lastPathComponent), ["z.txt"])
        XCTAssertEqual(m.selectionSummary.count, 1)
    }

    func testStopKeepsResultsAndCutDims() async {
        let script = Script()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/", ["a.txt"], gen: gen))
        await waitUntil("row") { m.rowCount == 1 }
        m.stop()
        if case .stopped(let s) = m.state { XCTAssertEqual(s.resultCount, 1) } else { XCTFail("\(m.state)") }
        await waitUntil("engine stopped") { script.terminated.contains(gen) }
        m.cutURLs = [m.url(atRow: 0)]
        XCTAssertTrue(m.isCut(row: 0))
    }

    func testResultLimitStopsAndNotifies() async {
        let script = Script()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        let names = (0...SearchResultsModel.resultLimit).map { "f\($0)" }
        script.continuations[gen]!.yield(batch("/", names, gen: gen))
        await waitUntil("capped", timeout: 20) { if case .complete = m.state { true } else { false } }
        XCTAssertEqual(m.rowCount, SearchResultsModel.resultLimit)
        XCTAssertTrue(m.notices.contains(.truncated(limit: SearchResultsModel.resultLimit)))
        if case .complete(let s) = m.state { XCTAssertTrue(s.truncated) }
        await waitUntil("engine stopped") { script.terminated.contains(gen) }
    }

    func testSpecModelCrawlsTheSandbox() async throws {
        try sandbox.createFile("work/tax-2025.pdf")
        try sandbox.createFile("work/deep/er/tax-old.pdf")
        try sandbox.createFile("work/notes.txt")
        let spec = SearchSpec(text: "tax", scope: .subfolders, root: sandbox.url("work"))
        let plan = await env.planSearch(spec)
        XCTAssertEqual(plan.engine, .crawler(root: sandbox.url("work").standardizedFileURL, criteria: SearchCriteria(nameTerms: [NameTerm("tax")])))
        let m = env.makeSearchResults(spec, plan: plan)
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        await waitUntil("crawl complete") { if case .complete = m.state { true } else { false } }
        XCTAssertEqual(names(m), ["tax-2025.pdf", "tax-old.pdf"])
        XCTAssertEqual(m.title, "tax")
    }

    func testMayNotBeIndexedNoticeForEmptyFolderScopedSpotlight() async throws {
        var context = env.searchContext()
        context.services = .fake(items: [], indexing: .enabled)
        let spec = SearchSpec(text: "invoice", scope: .subfolders, mode: .contents, root: sandbox.root)
        let plan = await context.plan(spec)
        guard case .spotlight = plan.engine else { return XCTFail("\(plan.engine)") }
        let m = SearchResultsModel(spec: spec, plan: plan, context: context)
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        await waitUntil("complete") { if case .complete = m.state { true } else { false } }
        XCTAssertEqual(m.notices, [.mayNotBeIndexed])
    }

    func testSandboxedEnvironmentUsesFakeSearchServices() {
        XCTAssertTrue(env.searchServices.metadataQuery is FakeMetadataQuery)
        XCTAssertTrue(env.searchServices.downloader is FakeUbiquitousDownloader)
    }
}
```

`rootPath` is the sandbox root without a trailing slash. The paths these tests stream never need to exist (except in `testSpecModelCrawlsTheSandbox`): the model never touches the file system.

- [ ] **Step 6: Run to verify failure**

Run: `swift test --filter CoreTests.SearchResultsModelTests 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'SearchResultsModel' in scope`.

- [ ] **Step 7: Implement `ResultSorter`**

```swift
// Sources/Core/Search/ResultSorter.swift
import Foundation
import MacxFS

/// Display order of search results. Same rules as Sorter (folders first, field, name tie-break, descending
/// reverses within the folder/file groups) plus `.path`: parent path, then name, with no folder grouping.
/// Extended Phase 2 fields are not offered for results and sort like `.name`.
enum ResultSorter {
    static func less(_ r: SearchResultStore, _ sort: SortDescriptor, kindRanks: [UInt16]) -> (UInt32, UInt32) -> Bool {
        let store = r.store
        let keys = r.nameKeys
        let asc = sort.ascending
        func cmpKeys(_ col: SortKeyColumn, _ a: Int, _ b: Int) -> Int {
            col.withKey(a) { ka in col.withKey(b) { kb in
                let n = min(ka.count, kb.count)
                let c = n == 0 ? 0 : Int(memcmp(ka.baseAddress!, kb.baseAddress!, n))
                return c != 0 ? c : ka.count - kb.count
            } }
        }
        func name(_ a: UInt32, _ b: UInt32) -> Int { cmpKeys(keys, Int(a), Int(b)) }
        if sort.field == .path {
            var parentKeys = SortKeyColumn()
            for p in r.parents { SortKeys.nameKey(p, isFolder: false).withUnsafeBytes { parentKeys.append($0) } }
            return { a, b in
                let pa = Int(r.parentIndex(a)), pb = Int(r.parentIndex(b))
                var c = pa == pb ? 0 : cmpKeys(parentKeys, pa, pb)
                if c == 0 { c = name(a, b) }
                return asc ? c < 0 : c > 0
            }
        }
        func ext(_ i: UInt32) -> [UInt8] {
            store.withNameBytes(i) { bytes in
                guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return [] }
                return bytes[(dot + 1)...].map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            }
        }
        return { a, b in
            let ea = store.entry(a), eb = store.entry(b)
            let fa = ea.isFolderForSorting, fb = eb.isFolderForSorting
            if fa != fb { return fa }
            var c: Int
            switch sort.field {
            case .dateModified: c = ea.mtime == eb.mtime ? 0 : (ea.mtime < eb.mtime ? -1 : 1)
            case .dateCreated: c = ea.ctime == eb.ctime ? 0 : (ea.ctime < eb.ctime ? -1 : 1)
            case .size: c = fa ? 0 : (ea.size == eb.size ? 0 : (ea.size < eb.size ? -1 : 1))
            case .kind:
                let ra = kindRanks.indices.contains(Int(ea.typeIndex)) ? kindRanks[Int(ea.typeIndex)] : .max
                let rb = kindRanks.indices.contains(Int(eb.typeIndex)) ? kindRanks[Int(eb.typeIndex)] : .max
                c = ra == rb ? 0 : (ra < rb ? -1 : 1)
            case .fileExtension:
                let xa = ext(a), xb = ext(b)
                c = xa == xb ? 0 : (xa.lexicographicallyPrecedes(xb) ? -1 : 1)
            default: c = 0
            }
            if c == 0 { c = name(a, b) }
            return asc ? c < 0 : c > 0
        }
    }

    static func permutation(_ r: SearchResultStore, sort: SortDescriptor, kindRanks: [UInt16]) -> [UInt32] {
        let less = less(r, sort, kindRanks: kindRanks)
        return (0..<UInt32(r.count)).sorted(by: less)
    }

    @concurrent
    static func permutationOffMain(_ r: SearchResultStore, sort: SortDescriptor, kindRanks: [UInt16]) async -> [UInt32] {
        permutation(r, sort: sort, kindRanks: kindRanks)
    }

    /// `sorted` is a valid order; `fresh` are new storage indices not in it.
    static func merge(_ sorted: [UInt32], _ fresh: [UInt32], results r: SearchResultStore, sort: SortDescriptor,
                      kindRanks: [UInt16]) -> [UInt32] {
        guard !fresh.isEmpty else { return sorted }
        let less = less(r, sort, kindRanks: kindRanks)
        let run = fresh.sorted(by: less)
        var out: [UInt32] = []
        out.reserveCapacity(sorted.count + run.count)
        var i = 0, j = 0
        while i < sorted.count && j < run.count {
            if less(run[j], sorted[i]) { out.append(run[j]); j += 1 } else { out.append(sorted[i]); i += 1 }
        }
        out.append(contentsOf: sorted[i...])
        out.append(contentsOf: run[j...])
        return out
    }
}
```

- [ ] **Step 8: Implement `SearchResultsModel`**

```swift
// Sources/Core/Search/SearchResultsModel.swift
import Foundation
import MacxFS

public enum SearchState: Sendable, Equatable {
    case searching(SearchProgress), complete(SearchSummary), stopped(SearchSummary), failed(SearchFailure)
}
public enum SearchModelEvent: Sendable { case rows(RowSourceEvent), state(SearchState), notices([SearchNotice]) }

@MainActor
public final class SearchResultsModel: RowSource {
    public static let resultLimit = 100_000

    public let title: String
    public let spec: SearchSpec?
    public let plan: SearchPlan?
    public private(set) var state: SearchState = .searching(SearchProgress())
    public private(set) var notices: [SearchNotice]
    public private(set) var generation: Generation = .initial
    public private(set) var results = SearchResultStore()
    public private(set) var selection: Selection = .empty
    public private(set) var sortDescriptor: SortDescriptor = .default
    public var scrollAnchor: RowID?
    public var cutURLs: Set<URL> = [] {
        didSet { if cutURLs != oldValue, rowCount > 0 { emitRows(.changes(ChangeSet([.reload(IndexSet(integersIn: 0..<rowCount))]))) } }
    }

    private enum Op { case batch(SearchBatch), removed([String]), renamed(from: String, to: String), removedUnder(String) }

    private let context: SearchContext
    private let makeEvents: @MainActor (Generation) -> AsyncStream<SearchEvent>
    private let baseNotices: [SearchNotice]
    private var engineTask: Task<Void, Never>?
    private var pending: [Op] = []
    private var needsFullSort = false
    private var pumping = false
    private var pendingCompletion: SearchSummary?
    private var closed = false
    private var startedAt = ContinuousClock.now
    private var directoriesScanned = 0
    private let rowObservers = Observers<RowSourceEvent>()
    private let observers = Observers<SearchModelEvent>()
    private var changeToken: ObserverToken?

    public init(spec: SearchSpec, plan: SearchPlan, context: SearchContext) {
        switch plan.engine {
        case .crawler, .spotlight: break
        case .none, .folderFilter: preconditionFailure("SearchResultsModel needs a crawler or Spotlight plan")
        }
        title = spec.text.trimmingCharacters(in: .whitespaces)
        self.spec = spec
        self.plan = plan
        self.context = context
        notices = plan.notices
        baseNotices = plan.notices
        let engine = plan.engine
        makeEvents = { gen in SearchResultsModel.engineEvents(engine, generation: gen, context: context) }
        observeLocalChanges()
    }

    public init(title: String, events: @escaping @MainActor (Generation) -> AsyncStream<SearchEvent>, context: SearchContext) {
        self.title = title
        spec = nil
        plan = nil
        self.context = context
        notices = []
        baseNotices = []
        makeEvents = events
        observeLocalChanges()
    }

    static func engineEvents(_ engine: SearchEngine, generation: Generation, context: SearchContext) -> AsyncStream<SearchEvent> {
        switch engine {
        case .crawler(let root, let criteria):
            var options = CrawlOptions()
            options.includeHidden = context.settings.showHidden
            options.maxResults = resultLimit
            return SubtreeCrawler.crawl(root: root, criteria: criteria, options: options, permissions: context.crawlPermissions(),
                                        generation: generation, lanes: context.lanes, mountTable: context.volumes.mountTableStore,
                                        types: context.types)
        case .spotlight(let request):
            return SpotlightSearch.events(request, query: context.services.metadataQuery, includeHidden: context.settings.showHidden,
                                          generation: generation, types: context.types)
        case .none, .folderFilter:
            preconditionFailure("not a streaming engine")
        }
    }

    // MARK: lifecycle

    public func start() {
        guard !closed else { return }
        engineTask?.cancel()
        generation = generation.next()
        let gen = generation
        startedAt = .now
        directoriesScanned = 0
        setState(.searching(SearchProgress()))
        let stream = makeEvents(gen)
        engineTask = Task { [weak self] in
            for await event in stream {
                guard let self, !self.closed, self.generation == gen else { return }
                self.handle(event, generation: gen)
            }
        }
    }

    public func stop() {
        guard case .searching = state, !closed else { return }
        engineTask?.cancel()
        engineTask = nil
        pendingCompletion = nil
        setState(.stopped(SearchSummary(resultCount: results.count + pendingResultCount, directoriesScanned: directoriesScanned,
                                        elapsed: .now - startedAt)))
    }

    public func rerun() {
        guard !closed else { return }
        engineTask?.cancel()
        engineTask = nil
        pending = []
        pendingCompletion = nil
        needsFullSort = false
        results = SearchResultStore()
        selection = .empty
        scrollAnchor = nil
        notices = baseNotices
        emit(.notices(notices))
        emitRows(.changes(.reset))
        emitRows(.selection(selection))
        start()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        engineTask?.cancel()
        engineTask = nil
        changeToken?.cancel()
        changeToken = nil
        pending = []
    }

    public func observe(_ handler: @escaping @MainActor (SearchModelEvent) -> Void) -> ObserverToken { observers.add(handler) }

    // MARK: engine events

    private func handle(_ event: SearchEvent, generation gen: Generation) {
        if case .stopped = state { return }
        switch event {
        case .batch(let b):
            guard b.batch.generation == gen else { return }
            enqueue(.batch(b))
        case .removed(let paths):
            enqueue(.removed(paths))
        case .progress(let p):
            directoriesScanned = p.directoriesScanned
            if case .searching = state {
                setState(.searching(SearchProgress(directoriesScanned: p.directoriesScanned,
                                                   resultCount: results.count + pendingResultCount, currentPath: p.currentPath)))
            }
        case .notice(let n):
            addNotice(n)
        case .completed(let summary):
            guard case .searching = state else { return }
            pendingCompletion = summary
            schedulePump()
        case .failed(let failure):
            setState(.failed(failure))
        }
    }

    private var pendingResultCount: Int {
        pending.reduce(0) { if case .batch(let b) = $1 { $0 + b.batch.count } else { $0 } }
    }

    private func finish(_ summary: SearchSummary) {
        var s = summary
        s.resultCount = results.count
        if s.directoriesScanned == 0 { s.directoriesScanned = directoriesScanned }
        if s.elapsed == .zero { s.elapsed = .now - startedAt }
        if s.truncated { addNotice(.truncated(limit: Self.resultLimit)) }
        if s.skippedTotal > 0 { addNotice(.skippedLocations(count: s.skippedTotal)) }
        if results.count == 0, case .spotlight(let request)? = plan?.engine, case .folders = request.scope { addNotice(.mayNotBeIndexed) }
        setState(.complete(s))
    }

    private func hitLimit() {
        engineTask?.cancel()
        engineTask = nil
        if case .searching = state {
            pendingCompletion = SearchSummary(resultCount: results.count, directoriesScanned: directoriesScanned, truncated: true)
        }
    }

    // MARK: local changes (Review Focus 3)

    private func observeLocalChanges() {
        changeToken = context.changeBus.observeAll { [weak self] change in self?.apply(change) }
    }

    private func apply(_ change: LocalChange) {
        guard !closed else { return }
        let dir = CrawlRun.standardized(change.directory)
        func hasDescendants(_ p: String) -> Bool { results.parents.contains { $0 == p || $0.hasPrefix(p + "/") } }
        var exact: [String] = []
        for name in change.removed {
            let p = CrawlRun.join(dir, name)
            if results.index(ofPath: p) != nil { exact.append(p) }
            if hasDescendants(p) { enqueue(.removedUnder(p)) }
        }
        if !exact.isEmpty { enqueue(.removed(exact)) }
        for rename in change.renamed {
            let from = CrawlRun.join(dir, rename.from)
            if results.index(ofPath: from) != nil { enqueue(.renamed(from: from, to: rename.to)) }
            if hasDescendants(from) { enqueue(.removedUnder(from)) }
        }
    }

    // MARK: pump

    private func enqueue(_ op: Op) {
        pending.append(op)
        schedulePump()
    }

    private func schedulePump() {
        guard !pumping, !closed else { return }
        pumping = true
        Task { [weak self] in await self?.pump() }
    }

    private func pump() async {
        while !closed {
            await context.pacer.nextFrame()
            if closed { break }
            if pending.isEmpty && !needsFullSort {
                if let s = pendingCompletion { pendingCompletion = nil; finish(s) }
                break
            }
            let gen = generation
            let before = selection
            let ops = pending
            pending = []
            applyOps(ops)
            if needsFullSort {
                needsFullSort = false
                let sort = sortDescriptor
                let order = await ResultSorter.permutationOffMain(results, sort: sort, kindRanks: context.types.kindRanks().ranks)
                if closed || gen != generation { continue }
                if sort != sortDescriptor { needsFullSort = true; continue }
                results.setOrder(order)
            }
            selection.reconcile(in: rowSpace())
            emitRows(.changes(.reset))
            if selection != before { emitRows(.selection(selection)) }
            if case .searching(var p) = state { p.resultCount = results.count; setState(.searching(p)) }
        }
        pumping = false
    }

    private func applyOps(_ ops: [Op]) {
        let ranks = context.types.kindRanks().ranks
        var fresh: [UInt32] = []
        func flushFresh() {
            guard !fresh.isEmpty else { return }
            if !needsFullSort {
                results.setOrder(ResultSorter.merge(results.store.order, fresh, results: results, sort: sortDescriptor, kindRanks: ranks))
            }
            fresh = []
        }
        for op in ops {
            switch op {
            case .batch(var b):
                let room = Self.resultLimit - results.count          // `fresh` rows are already in `results`
                if room <= 0 { hitLimit(); continue }
                if b.batch.count > room { b.batch = CrawlRun.prefix(b.batch, room) }
                let parent = CrawlRun.standardized(b.parent)
                let replaces = (0..<b.batch.count).contains { results.index(ofPath: CrawlRun.join(parent, b.batch.name(at: $0))) != nil }
                if replaces { flushFresh() }
                fresh += results.append(b)
                if results.count >= Self.resultLimit { hitLimit() }
            case .removed(let paths):
                flushFresh()
                results.remove(paths: paths)
            case .renamed(let from, let to):
                flushFresh()
                let target = CrawlRun.join((from as NSString).deletingLastPathComponent, to)
                if results.rename(path: from, to: to, types: context.types), let i = results.index(ofPath: target) { fresh.append(i) }
            case .removedUnder(let dir):
                flushFresh()
                let prefix = dir + "/"
                results.remove(paths: (0..<UInt32(results.count)).map { results.path($0) }.filter { $0.hasPrefix(prefix) })
            }
        }
        flushFresh()
    }

    // MARK: RowSource

    public var rowCount: Int { results.store.visibleCount }
    private func index(_ row: Int) -> UInt32 { results.store.storageIndex(forRow: row) }
    public func entry(atRow row: Int) -> Entry { results.store.entry(index(row)) }
    public func name(atRow row: Int) -> String { results.store.name(index(row)) }
    public func url(atRow row: Int) -> URL { results.url(index(row)) }
    public func parentURL(atRow row: Int) -> URL { URL(filePath: results.parentPath(index(row)), directoryHint: .isDirectory) }
    public func identity(atRow row: Int) -> RowID { results.identity(index(row)) }
    public func row(of id: RowID) -> Int? {
        guard case .name(let path) = id, let i = results.index(ofPath: path) else { return nil }
        return results.store.row(ofStorageIndex: i)
    }

    private func rowSpace() -> SelectionRowSpace {
        SelectionRowSpace(count: rowCount, identity: { self.identity(atRow: $0) }, row: { self.row(of: $0) },
                          rowNamed: { n in (0..<self.rowCount).first { self.name(atRow: $0) == n } })
    }

    public func select(_ command: SelectionCommand) {
        let before = selection
        selection.apply(command, in: rowSpace())
        if selection != before { emitRows(.selection(selection)) }
    }
    public var selectedURLs: [URL] { selection.rows.map { url(atRow: $0) } }
    public var selectionSummary: SelectionSummary {
        var files = 0, folders = 0
        var bytes: Int64 = 0
        for row in selection.rows {
            let e = entry(atRow: row)
            if e.kind == .directory { folders += 1 } else { files += 1; bytes += e.size }
        }
        return SelectionSummary(count: selection.count, files: files, folders: folders, bytes: bytes, folderBytes: nil)
    }
    public func isCut(row: Int) -> Bool { !cutURLs.isEmpty && cutURLs.contains(url(atRow: row)) }
    public func setSortDescriptor(_ sort: SortDescriptor) {
        guard sort != sortDescriptor else { return }
        sortDescriptor = sort
        needsFullSort = true
        schedulePump()
    }
    public var showsPathColumn: Bool { true }
    public var caseSensitive: Bool { spec.flatMap { context.volumes.volume(for: $0.root) }?.capabilities.caseSensitive ?? false }
    public func validateName(_ proposed: String, renamingRow row: Int?) -> NameValidation {
        let parent = row.map { results.parentPath(index($0)) }
        return NameRules.validate(proposed, original: row.map { name(atRow: $0) }, caseSensitive: caseSensitive) { candidate in
            guard let parent else { return false }
            return self.results.index(ofPath: CrawlRun.join(parent, candidate)) != nil
        }
    }
    public func observeRows(_ handler: @escaping @MainActor (RowSourceEvent) -> Void) -> ObserverToken { rowObservers.add(handler) }

    // MARK: emit

    private func setState(_ s: SearchState) { state = s; emit(.state(s)) }
    private func addNotice(_ n: SearchNotice) {
        guard !notices.contains(n) else { return }
        notices.append(n)
        emit(.notices(notices))
    }
    private func emit(_ e: SearchModelEvent) { if !closed { observers.send(e) } }
    private func emitRows(_ e: RowSourceEvent) {
        guard !closed else { return }
        rowObservers.send(e)
        observers.send(.rows(e))
    }
}
```

Notes for the implementer:
- If Phase 2's `SelectionSummary` has no `folderBytes`, drop that argument. If its memberwise initializer is not visible here, build the summary the way `FolderModel.selectionSummary` does.
- `Selection` equality drives the `.selection` emission; `Selection` is `Equatable` (§3.7).
- Crawl option `includePackages` is wired from Settings in P3-07 (the setting does not exist yet).

Then add to `CoreEnvironment`:

```swift
    public func makeSearchResults(_ spec: SearchSpec, plan: SearchPlan) -> SearchResultsModel {
        SearchResultsModel(spec: spec, plan: plan, context: searchContext())
    }
```

- [ ] **Step 9: Run the P3-06 tests**

Run: `swift test --filter "CoreTests.SearchPlannerTests|CoreTests.SearchResultsModelTests" 2>&1 | tail -5`
Expected: `Executed 17 tests, with 0 failures`.

- [ ] **Step 10: Full Core suite (CoreEnvironment changed)**

Run: `swift test --filter CoreTests 2>&1 | tail -3`
Expected: `0 failures`.

- [ ] **Step 11: Build and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`.

```bash
git add Sources/Core/Search Sources/Core/Preview/Ubiquitous.swift Sources/Core/Support/CoreEnvironment.swift Tests/CoreTests/Search
git commit -m "feat: search planner, streaming results model with generations and local-change tracking"
```

---

### Task P3-07: Settings schema v3, saved searches, commands and keys

**Files:**
- Create: `Sources/Core/Settings/SavedSearch.swift`
- Modify: `Sources/Core/Settings/SettingsTypes.swift` (`SidebarSection.searches`), `Sources/Core/Settings/Settings.swift` (schema 3, keys, migration, saved-search mutators), `Sources/Core/Commands/Command.swift`, `Sources/Core/Commands/KeyMap.swift`, `Sources/Core/Commands/KeyDispatcher.swift`, `Sources/Core/Commands/CommandAvailability.swift`, `Sources/Core/Search/SearchResultsModel.swift` (`includePackages` from Settings), and every exhaustive `switch` the compiler reports (UI: `MainMenuBuilder`, `FileCommandController`, `MenuValidation`, `KeyRouter`)
- Test: `Tests/CoreTests/SettingsV3Tests.swift`, `Tests/CoreTests/KeyMapPhase3Tests.swift`

**Interfaces:**
- Consumes: `Settings`, `SettingsStorage`, `InMemorySettingsStorage`, `Settings.schemaVersionKey`, `Settings.migrateColumns` (P2-01), `ColumnSetting`, `ColumnID.defaultWidth` (P2-01), `SidebarSection`, `Command`, `KeyChord`, `KeyMap`, `KeyDispatcher`, `FocusContext`, `CommandState`, `CommandAvailability` (Phase 1 §3.9/§3.10, Phase 2 §2.2); `SearchSpec`, `SearchScope`, `SearchMode` (P3-02).
- Produces: `SavedSearch`, `SavedSearchNaming.uniqueName(_:existing:)`; `SidebarSection.searches`; `Settings.schemaVersion == 3` and `savedSearches`, `previewPaneVisible`, `previewPaneWidth`, `searchScope`, `searchMode`, `searchIncludesPackages`, `resultsColumns`, `addSavedSearch(name:spec:)`, `renameSavedSearch(_:to:)`, `removeSavedSearch(_:)`, `moveSavedSearch(from:to:)`, `Settings.defaultResultsColumns`; the 12 new `Command`s; `KeyMap` primaries ⌥P and ⌥⌘R; `KeyMap.collidesWithTextEditing ∋ .togglePreviewPane`; `FocusContext.searchResults`, `.sidebarSavedSearch`; `CommandState.isSearching/hasSearchQuery/showingResults/previewPaneVisible`; the availability and remap rules below.

**Rules:**
- `SavedSearchNaming.uniqueName(proposed, existing)` trims whitespace and returns nil when the result is blank. On a case-insensitive collision it appends " 2", " 3", … (first free).
- `addSavedSearch(name:spec:)` names the search `uniqueName(name) ?? uniqueName(spec.text) ?? uniqueName(spec.root.lastPathComponent)` and appends it. `renameSavedSearch` makes the name unique among the other searches and returns false for a blank name or an unknown id. `moveSavedSearch(from:to:)` removes at `from` and inserts at `min(to, count)`, so `to` counts positions after the removal.
- `resultsColumns` default: name 260, path 260, dateModified 150, size 80, kind 140 (all visible), followed by every other `ColumnID` invisible (`migrateColumns`).
- Commands: `togglePreviewPane` (⌥P), `openContainingFolder` (⌥⌘R), `saveSearch`, `stopSearch`, `searchScopeThisFolder`, `searchScopeSubfolders`, `searchScopeThisMac`, `searchModeName`, `searchModeContents`, `renameSavedSearch`, `removeSavedSearch`, `downloadForPreview`. All selectors are `macx_<rawValue>:`. ⌥P types "π" on US layouts, so it joins `collidesWithTextEditing`: `MenuValidation` disables the menu item while a field editor is first responder, and the character reaches the field (Review Focus 2).
- `KeyDispatcher`: `.searchResults` uses the `.content` alternates (Return opens, Del trashes, ⌫ goes back, …). `.sidebarSavedSearch` uses the `.sidebarFavorites` alternates.
- `CommandAvailability.effectiveCommand` in `.sidebarSavedSearch`: `moveToTrash → removeSavedSearch`, `rename → renameSavedSearch`, `deletePermanently → nil`. Del never deletes files from the SEARCHES section.
- `CommandAvailability.isEnabled`:
  - `togglePreviewPane` and the five scope/mode commands: always enabled.
  - `openContainingFolder`: `showingResults && selectionCount >= 1`, in `.searchResults` or `.content`.
  - `saveSearch`: `hasSearchQuery`.
  - `stopSearch`: `isSearching`.
  - `renameSavedSearch` / `removeSavedSearch`: only in `.sidebarSavedSearch`.
  - `downloadForPreview`: `previewPaneVisible && selectionCount == 1`.
  - In `.searchResults`: `paste`, `moveItemHere`, `newFolder`, `newTextFile`, `newEmptyFile` and `viewAsColumns` are disabled (there is no single destination folder, and Columns view cannot show results). Everything else follows `.content`.
  - In `.sidebarSavedSearch`: `open`, `openInNewWindow`, `openInNewTab` and the two saved-search commands are enabled. Every item-level file command (`cut`, `copy`, `paste`, `moveItemHere`, `duplicate`, `makeAlias`, `makeSymlink`, `deletePermanently`, `eject`, `removeFromFavorites`, `showPackageContents`, `openInTerminal`, `revealInFinder`, `copyAsPath`, `properties`, `share`, `newFolder`, `newTextFile`, `newEmptyFile`, the Phase 2 copy-path variants) is disabled. The rest follows `.sidebarFavorites`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/SettingsV3Tests.swift
import XCTest
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class SettingsV3Tests: XCTestCase {
    let root = URL(filePath: "/tmp/macx-tests-s/root", directoryHint: .isDirectory)

    func testSchemaVersionIsThreeAndDefaults() {
        XCTAssertEqual(Settings.schemaVersion, 3)
        let s = Settings(storage: InMemorySettingsStorage())
        XCTAssertEqual(s.savedSearches, [])
        XCTAssertFalse(s.previewPaneVisible)
        XCTAssertEqual(s.previewPaneWidth, 320)
        XCTAssertEqual(s.searchScope, .thisFolder)
        XCTAssertEqual(s.searchMode, .name)
        XCTAssertFalse(s.searchIncludesPackages)
        XCTAssertEqual(s.resultsColumns.filter(\.visible).map(\.id), [.name, .path, .dateModified, .size, .kind])
        XCTAssertEqual(Set(s.resultsColumns.map(\.id)), Set(ColumnID.allCases))
        XCTAssertTrue(SidebarSection.allCases.contains(.searches))
    }

    func testVersionTwoStoreMigrates() throws {
        let storage = InMemorySettingsStorage()
        let v2 = Settings(storage: storage)
        v2.columns = [ColumnSetting(id: .name, width: 280, visible: true)]
        storage.set(try JSONEncoder().encode(2), forKey: Settings.schemaVersionKey)
        let r = Settings(storage: storage)
        XCTAssertEqual(r.columns.filter(\.visible).map(\.id), [.name])      // untouched
        XCTAssertEqual(r.savedSearches, [])
        XCTAssertEqual(r.previewPaneWidth, 320)
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: XCTUnwrap(storage.data(forKey: Settings.schemaVersionKey))), 3)
    }

    func testNewKeysPersist() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage)
        s.previewPaneVisible = true
        s.previewPaneWidth = 410
        s.searchScope = .subfolders
        s.searchMode = .contents
        s.searchIncludesPackages = true
        s.collapsedSections.insert(.searches)
        let spec = SearchSpec(text: "tax kind:pdf", scope: .subfolders, filters: SearchFilters(modified: .relative(.thisYear)), root: root)
        let saved = s.addSavedSearch(name: "Taxes", spec: spec)
        let r = Settings(storage: storage)
        XCTAssertTrue(r.previewPaneVisible)
        XCTAssertEqual(r.previewPaneWidth, 410)
        XCTAssertEqual(r.searchScope, .subfolders)
        XCTAssertEqual(r.searchMode, .contents)
        XCTAssertTrue(r.searchIncludesPackages)
        XCTAssertTrue(r.collapsedSections.contains(.searches))
        XCTAssertEqual(r.savedSearches, [saved])
        XCTAssertEqual(r.savedSearches.first?.spec, spec)
    }

    func testSavedSearchMutators() {
        let s = Settings(storage: InMemorySettingsStorage())
        let spec = SearchSpec(text: "tax", scope: .subfolders, root: root)
        let a = s.addSavedSearch(name: "Tax", spec: spec)
        let b = s.addSavedSearch(name: " tax ", spec: spec)
        let c = s.addSavedSearch(name: "  ", spec: SearchSpec(text: "invoices", scope: .thisMac, root: root))
        XCTAssertEqual([a, b, c].map(\.name), ["Tax", "tax 2", "invoices"])
        XCTAssertTrue(s.renameSavedSearch(c.id, to: "Tax"))
        XCTAssertEqual(s.savedSearches.map(\.name), ["Tax", "tax 2", "Tax 3"])
        XCTAssertFalse(s.renameSavedSearch(c.id, to: "   "))
        XCTAssertFalse(s.renameSavedSearch(UUID(), to: "x"))
        XCTAssertTrue(s.renameSavedSearch(a.id, to: "TAX"))                 // case-only rename of itself is fine
        XCTAssertEqual(s.savedSearches[0].name, "TAX")
        s.moveSavedSearch(from: 0, to: 2)
        XCTAssertEqual(s.savedSearches.map(\.id), [b.id, c.id, a.id])
        s.moveSavedSearch(from: 2, to: 0)
        XCTAssertEqual(s.savedSearches.map(\.id), [a.id, b.id, c.id])
        s.removeSavedSearch(b.id)
        XCTAssertEqual(s.savedSearches.map(\.id), [a.id, c.id])
    }

    func testUniqueName() {
        XCTAssertNil(SavedSearchNaming.uniqueName(" \n ", existing: []))
        XCTAssertEqual(SavedSearchNaming.uniqueName(" Photos ", existing: ["Docs"]), "Photos")
        XCTAssertEqual(SavedSearchNaming.uniqueName("photos", existing: ["Photos", "photos 2"]), "photos 3")
    }

    func testCrawlerHonoursIncludePackagesSetting() async throws {
        let sandbox = try Sandbox()
        addTeardownBlock { sandbox.destroy() }
        try sandbox.createFile("X.app/Contents/needle.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        env.settings.searchIncludesPackages = true
        let spec = SearchSpec(text: "needle", scope: .subfolders, root: sandbox.root)
        let plan = await env.planSearch(spec)
        let m = env.makeSearchResults(spec, plan: plan)
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        let end = Date().addingTimeInterval(5)
        while Date() < end { if case .complete = m.state { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.rowCount, 1)
    }
}
```

```swift
// Tests/CoreTests/KeyMapPhase3Tests.swift
import XCTest
@testable import Core

final class KeyMapPhase3Tests: XCTestCase {
    func chord(_ s: String) -> KeyChord { KeyChord(parsing: s)! }

    func testPrimaries() {
        XCTAssertEqual(KeyMap.primary(.togglePreviewPane), chord("opt+p"))
        XCTAssertEqual(KeyMap.primary(.openContainingFolder), chord("cmd+opt+r"))
        for c: Command in [.saveSearch, .stopSearch, .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac,
                           .searchModeName, .searchModeContents, .renameSavedSearch, .removeSavedSearch, .downloadForPreview] {
            XCTAssertNil(KeyMap.primary(c), "\(c)")
        }
    }

    func testPrimariesStayUnique() {
        var seen: [KeyChord: Command] = [:]
        for c in Command.allCases {
            guard let k = KeyMap.primary(c) else { continue }
            XCTAssertNil(seen[k], "\(k) bound to both \(String(describing: seen[k])) and \(c)")
            seen[k] = c
        }
    }

    func testSelectorNames() {
        XCTAssertEqual(Command.togglePreviewPane.selectorName, "macx_togglePreviewPane:")
        XCTAssertEqual(Command.openContainingFolder.selectorName, "macx_openContainingFolder:")
        XCTAssertEqual(Command.removeSavedSearch.selectorName, "macx_removeSavedSearch:")
    }

    // Review Focus 2
    func testTogglePreviewPaneCollidesWithTextEditing() {
        XCTAssertTrue(KeyMap.collidesWithTextEditing.contains(.togglePreviewPane))
        XCTAssertFalse(KeyMap.collidesWithTextEditing.contains(.openContainingFolder))
        let d = KeyDispatcher(returnKey: .open)
        XCTAssertNil(d.command(for: chord("opt+p"), in: .fieldEditor))
        XCTAssertNil(d.command(for: chord("opt+p"), in: .addressBar))
    }

    func testDispatcherInNewFocusContexts() {
        let d = KeyDispatcher(returnKey: .open)
        for (key, cmd) in [("return", Command.open), ("fn+delete", .moveToTrash), ("delete", .back), ("shift+fn+delete", .deletePermanently)] {
            XCTAssertEqual(d.command(for: chord(key), in: .searchResults), d.command(for: chord(key), in: .content), key)
            XCTAssertEqual(d.command(for: chord(key), in: .searchResults), cmd, key)
        }
        XCTAssertEqual(d.command(for: chord("fn+delete"), in: .sidebarSavedSearch),
                       d.command(for: chord("fn+delete"), in: .sidebarFavorites))
    }

    // "Del never deletes files" in SEARCHES
    func testSavedSearchRemaps() {
        XCTAssertEqual(CommandAvailability.effectiveCommand(.moveToTrash, focus: .sidebarSavedSearch), .removeSavedSearch)
        XCTAssertEqual(CommandAvailability.effectiveCommand(.rename, focus: .sidebarSavedSearch), .renameSavedSearch)
        XCTAssertNil(CommandAvailability.effectiveCommand(.deletePermanently, focus: .sidebarSavedSearch))
        XCTAssertEqual(CommandAvailability.effectiveCommand(.moveToTrash, focus: .searchResults), .moveToTrash)
    }

    func testAvailability() {
        let results = CommandState(selectionCount: 1, canPaste: true, showingResults: true)
        XCTAssertTrue(CommandAvailability.isEnabled(.openContainingFolder, focus: .searchResults, state: results))
        XCTAssertFalse(CommandAvailability.isEnabled(.openContainingFolder, focus: .searchResults, state: CommandState(showingResults: true)))
        XCTAssertFalse(CommandAvailability.isEnabled(.openContainingFolder, focus: .content, state: CommandState(selectionCount: 1)))
        for c: Command in [.paste, .moveItemHere, .newFolder, .newTextFile, .newEmptyFile, .viewAsColumns] {
            XCTAssertFalse(CommandAvailability.isEnabled(c, focus: .searchResults, state: results), "\(c)")
        }
        XCTAssertTrue(CommandAvailability.isEnabled(.moveToTrash, focus: .searchResults, state: results))
        XCTAssertTrue(CommandAvailability.isEnabled(.copy, focus: .searchResults, state: results))
        XCTAssertTrue(CommandAvailability.isEnabled(.togglePreviewPane, focus: .content, state: CommandState()))
        XCTAssertTrue(CommandAvailability.isEnabled(.stopSearch, focus: .content, state: CommandState(isSearching: true)))
        XCTAssertFalse(CommandAvailability.isEnabled(.stopSearch, focus: .content, state: CommandState()))
        XCTAssertTrue(CommandAvailability.isEnabled(.saveSearch, focus: .content, state: CommandState(hasSearchQuery: true)))
        XCTAssertFalse(CommandAvailability.isEnabled(.saveSearch, focus: .content, state: CommandState()))
        XCTAssertTrue(CommandAvailability.isEnabled(.downloadForPreview, focus: .content, state: CommandState(selectionCount: 1, previewPaneVisible: true)))
        let sidebar = CommandState(selectionCount: 1)
        for c: Command in [.open, .renameSavedSearch, .removeSavedSearch] {
            XCTAssertTrue(CommandAvailability.isEnabled(c, focus: .sidebarSavedSearch, state: sidebar), "\(c)")
        }
        for c: Command in [.cut, .copy, .duplicate, .deletePermanently, .properties, .copyAsPath, .eject] {
            XCTAssertFalse(CommandAvailability.isEnabled(c, focus: .sidebarSavedSearch, state: sidebar), "\(c)")
        }
        XCTAssertFalse(CommandAvailability.isEnabled(.removeSavedSearch, focus: .content, state: sidebar))
    }
}
```

`CommandState(…)` labels follow the init order: Phase 1 fields, Phase 2's `selectedFolderCount/quickLookVisible/viewMode`, then this task's four. Omitted ones take their defaults, so the calls above compile as long as the relative order matches.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "CoreTests.SettingsV3Tests|CoreTests.KeyMapPhase3Tests" 2>&1 | tail -5`
Expected: build FAIL with `type 'Settings' has no member 'savedSearches'` and `type 'Command' has no member 'togglePreviewPane'`.

- [ ] **Step 3: Implement saved searches and Settings v3**

```swift
// Sources/Core/Settings/SavedSearch.swift
import Foundation

public struct SavedSearch: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var spec: SearchSpec
    public init(id: UUID = UUID(), name: String, spec: SearchSpec) { self.id = id; self.name = name; self.spec = spec }
}

public enum SavedSearchNaming {
    public static func uniqueName(_ proposed: String, existing: [String]) -> String? {
        let base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
```

In `SettingsTypes.swift`: `public enum SidebarSection: String, Sendable, Codable, CaseIterable { case favorites, searches, locations, folders }` (declaration order is the sidebar order; raw values of the existing cases unchanged).

In `Settings.swift`:
- `schemaVersion = 3`. If the stored version is below 3, write 3 back once (P2-01 did the same for 2). Nothing else changes meaning, so a v2 store loads unchanged.
- Add stored properties, persisted with the existing `didSet → storage.set` pattern under the keys `savedSearches`, `previewPaneVisible`, `previewPaneWidth`, `searchScope`, `searchMode`, `searchIncludesPackages`, `resultsColumns`, with defaults `[]`, `false`, `320`, `.thisFolder`, `.name`, `false`, `Settings.defaultResultsColumns`. `resultsColumns` goes through `Settings.migrateColumns` on load, like `columns`.
- Add:

```swift
extension Settings {
    public static var defaultResultsColumns: [ColumnSetting] {
        migrateColumns([ColumnSetting(id: .name, width: 260, visible: true), ColumnSetting(id: .path, width: 260, visible: true),
                        ColumnSetting(id: .dateModified, width: 150, visible: true), ColumnSetting(id: .size, width: 80, visible: true),
                        ColumnSetting(id: .kind, width: 140, visible: true)])
    }

    @discardableResult
    public func addSavedSearch(name: String, spec: SearchSpec) -> SavedSearch {
        let existing = savedSearches.map(\.name)
        let chosen = SavedSearchNaming.uniqueName(name, existing: existing)
            ?? SavedSearchNaming.uniqueName(spec.text, existing: existing)
            ?? SavedSearchNaming.uniqueName(spec.root.lastPathComponent, existing: existing)
            ?? spec.root.path(percentEncoded: false)
        let saved = SavedSearch(name: chosen, spec: spec)
        savedSearches.append(saved)
        return saved
    }

    public func renameSavedSearch(_ id: UUID, to name: String) -> Bool {
        guard let i = savedSearches.firstIndex(where: { $0.id == id }) else { return false }
        let others = savedSearches.enumerated().filter { $0.offset != i }.map(\.element.name)
        guard let unique = SavedSearchNaming.uniqueName(name, existing: others) else { return false }
        savedSearches[i].name = unique
        return true
    }

    public func removeSavedSearch(_ id: UUID) { savedSearches.removeAll { $0.id == id } }

    public func moveSavedSearch(from: Int, to: Int) {
        guard savedSearches.indices.contains(from) else { return }
        let item = savedSearches.remove(at: from)
        savedSearches.insert(item, at: min(max(0, to), savedSearches.count))
    }
}
```

(`savedSearches[i].name = unique` and `append` trigger the property's `didSet`, so every mutator persists.)

- [ ] **Step 4: Implement commands, keys, focus contexts and availability**

`Command.swift`: append a `// Phase 3` group with the 12 cases in the order listed in Rules. `selectorName` already falls through to `"macx_\(rawValue):"`.

`KeyMap.swift`: in `primary(_:)` add `case .togglePreviewPane: KeyChord(.character("p"), [.option])` and `case .openContainingFolder: KeyChord(.character("r"), [.command, .option])`; the other ten return nil. Add `.togglePreviewPane` to `collidesWithTextEditing`. `alternates` returns `[]` for all twelve.

`KeyDispatcher.swift`: add the two `FocusContext` cases. At the top of `command(for:in:)`:

```swift
        let focus: FocusContext = switch focus {
        case .searchResults: .content
        case .sidebarSavedSearch: .sidebarFavorites
        default: focus
        }
```

`CommandState`: append `isSearching`, `hasSearchQuery`, `showingResults`, `previewPaneVisible` (all `Bool = false`) to the stored properties and as the last init parameters.

`CommandAvailability.swift`: at the top of `isEnabled`:

```swift
        switch command {
        case .togglePreviewPane, .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac, .searchModeName, .searchModeContents:
            return true
        case .openContainingFolder:
            return state.showingResults && state.selectionCount >= 1 && (focus == .searchResults || focus == .content)
        case .saveSearch: return state.hasSearchQuery
        case .stopSearch: return state.isSearching
        case .renameSavedSearch, .removeSavedSearch: return focus == .sidebarSavedSearch
        case .downloadForPreview: return state.previewPaneVisible && state.selectionCount == 1
        default: break
        }
        switch focus {
        case .searchResults:
            if [.paste, .moveItemHere, .newFolder, .newTextFile, .newEmptyFile, .viewAsColumns].contains(command) { return false }
            return isEnabled(command, focus: .content, state: state)
        case .sidebarSavedSearch:
            if [.open, .openInNewWindow, .openInNewTab].contains(command) { return state.selectionCount >= 1 }
            if Self.savedSearchDenied.contains(command) { return false }
            return isEnabled(command, focus: .sidebarFavorites, state: state)
        default: break
        }
```

with

```swift
    static let savedSearchDenied: Set<Command> = [
        .cut, .copy, .paste, .moveItemHere, .duplicate, .makeAlias, .makeSymlink, .moveToTrash, .deletePermanently, .rename,
        .eject, .removeFromFavorites, .showPackageContents, .openInTerminal, .revealInFinder, .copyAsPath, .properties, .share,
        .newFolder, .newTextFile, .newEmptyFile, .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted,
    ]
```

In `effectiveCommand`:

```swift
        if focus == .sidebarSavedSearch {
            switch command {
            case .moveToTrash: return .removeSavedSearch
            case .rename: return .renameSavedSearch
            case .deletePermanently: return nil
            default: return command
            }
        }
        if focus == .searchResults { return effectiveCommand(command, focus: .content) }
```

`default:` branches above are projections over a few commands, not dispatch; the exhaustive dispatch switches stay default-free. In those switches (the compiler lists them):
- `MainMenuBuilder`: no items yet. P3-10/P3-12 add them; add the cases to its "not in a menu" list with a `// P3-10` comment.
- `FileCommandController.perform/canPerform`: the 12 cases do nothing and are disabled (`// P3-10 / P3-11 / P3-12`).
- `MenuValidation` and `KeyRouter`: map `.searchResults` like `.content` and `.sidebarSavedSearch` like `.sidebarFavorites`.
- Phase 2 tables keyed by `Command` (if any, for example a Phase 2 keymap test that iterates `allCases` expecting a primary): update them.

In `SearchResultsModel.engineEvents`, after `options.includeHidden`: `options.includePackages = context.settings.searchIncludesPackages`.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter "CoreTests.SettingsV3Tests|CoreTests.KeyMapPhase3Tests|CoreTests.SettingsV2Tests|CoreTests.KeyMapTests|CoreTests.SettingsTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`. If Phase 2's `testSchemaVersionIsTwo` fails, change it to assert `>= 2`: schema versions only move forward. Note that in the commit message.

- [ ] **Step 6: Build (UI switches) and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!` with zero warnings, then `swift test --filter UITests 2>&1 | tail -3` → `0 failures`.

```bash
git add Sources/Core/Settings Sources/Core/Commands Sources/Core/Search/SearchResultsModel.swift Sources/UI Tests/CoreTests/SettingsV3Tests.swift Tests/CoreTests/KeyMapPhase3Tests.swift
git commit -m "feat: settings v3, saved searches, preview and search commands, key bindings"
```

---

### Task P3-08: Preview decisions, text loading, metadata and cloud downloads (Core)

**Files:**
- Create: `Sources/Core/Preview/PreviewTypes.swift`, `Sources/Core/Preview/PreviewPlanner.swift`, `Sources/Core/Preview/TextPreviewLoader.swift`, `Sources/Core/Preview/PreviewMetadata.swift`
- Modify: `Sources/Core/Preview/Ubiquitous.swift` (add `DownloadState`, `DownloadWatcher`)
- Test: `Tests/CoreTests/Preview/PreviewPlannerTests.swift`, `Tests/CoreTests/Preview/TextPreviewLoaderTests.swift`, `Tests/CoreTests/Preview/PreviewMetadataTests.swift`, `Tests/CoreTests/Preview/DownloadWatcherTests.swift`

**Interfaces:**
- Consumes: `LanePool.perform`, `withNoMaterialization`, `VolumeID`, `Kind`, `EntryFlags`, `TypeRegistry` (`type(at:)`, `index(forExtension:isDirectory:)`, `localizedDescription`) (Phase 1); `UbiquitousDownloading`, `FakeUbiquitousDownloader` (P3-06); `Sandbox.writePNG` (P2-03) in tests.
- Produces: `PreviewSubject`, `PreviewContent`, `PreviewClass`, `PreviewPlanner.classify/resolve`, `TextEncodingGuess`, `TextPreview`, `TextPreviewError`, `TextPreviewLoader` (`limit`, `decode`, `load`), `PreviewDetails` (plus a public memberwise `init` with defaults, see Contract notes), `PreviewMetadata.load`, `DownloadState`, `DownloadWatcher.download`. Internal: `PreviewProbe` (stat/read hooks used by tests to simulate dataless files).

**Rules:**
- `classify(type)`:
  - `.quickLook` for rich documents: RTF, RTFD, flat RTFD, PDF.
  - `.sniff` for property lists (often binary), for `public.data`, `public.item` and dynamic (`dyn.*`) types, and for Unix executables without an extension.
  - `.text` for anything conforming to `public.text`, `public.source-code`, `public.script`, `public.json`, `public.xml` or `public.yaml`. HTML is shown as source, so no web content is loaded.
  - `.quickLook` for everything else (images, movies, audio, Office documents, archives, packages).
- `resolve(subject, …)` runs on a read lane inside `withNoMaterialization`:
  - `lstat` fails → `.unavailable(url, code:)`.
  - Symlink: `stat` (following) fails → `.brokenLink(url)`; otherwise continue with the target's mode and flags, and classify by the target's extension.
  - Alias: resolve with `[.withoutUI, .withoutMounting]`; failure → `.brokenLink(url)`.
  - Directory → `.folder(url)`; package → `.quickLook(url)`.
  - `SF_DATALESS` → `.cloudPlaceholder(url)`, decided before any read: a dataless file is never opened.
  - Then by class. `.sniff` reads the first 4 KB: open error → `.unavailable`; empty → `.text`; decodable → `.text`; otherwise `.quickLook`.
- `TextPreviewLoader.load` reads at most `limit + 1` bytes (262,145) on a read lane under no-materialization. `truncated = bytes > limit`. Decoding order:
  - BOM: UTF-8, UTF-16LE, UTF-16BE.
  - NUL bytes: UTF-16 without BOM if one byte parity is > 40% zeros and the other < 5%; otherwise binary.
  - Valid UTF-8 (after trimming a sequence cut off at the limit).
  - More than 10% control bytes (other than tab, LF, CR, FF, ESC) → binary.
  - Windows-1252, else Latin-1 (always succeeds).
- `PreviewMetadata.load` reads on a lane under no-materialization: `lstat` (size for non-directories, birth and modification times), then `MDItem` (`kMDItemPixelWidth/Height`, `kMDItemDurationSeconds`, `kMDItemNumberOfPages`). For non-dataless files only, missing values fall back to ImageIO (images), `CGPDFDocument` (PDF), and, after the lane returns, `AVURLAsset.load(.duration)` (audiovisual).
- `DownloadWatcher.download` yields `.downloading`, calls `startDownloading` (a throw yields `.failed`), then polls `isDataless` every `pollInterval` until false (`.done`) or until `timeout` (`.timedOut`). Ending iteration cancels polling.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/Preview/TextPreviewLoaderTests.swift
import XCTest
import Darwin
@testable import Core
@testable import MacxFS
import MacxFixtures

final class TextPreviewLoaderTests: XCTestCase {
    var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    func testUTF8AndBOMs() {
        XCTAssertEqual(TextPreviewLoader.decode(Array("héllo\n".utf8), truncated: false),
                       TextPreview(text: "héllo\n", truncated: false, encoding: .utf8))
        XCTAssertEqual(TextPreviewLoader.decode([0xEF, 0xBB, 0xBF] + Array("a".utf8), truncated: false)?.text, "a")
        XCTAssertEqual(TextPreviewLoader.decode([0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00], truncated: false),
                       TextPreview(text: "AB", truncated: false, encoding: .utf16LE))
        XCTAssertEqual(TextPreviewLoader.decode([0xFE, 0xFF, 0x00, 0x41], truncated: false)?.encoding, .utf16BE)
    }

    func testUTF16WithoutBOM() {
        let le = Array("plain ascii text".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertEqual(TextPreviewLoader.decode(le, truncated: false)?.encoding, .utf16LE)
        XCTAssertEqual(TextPreviewLoader.decode(le, truncated: false)?.text, "plain ascii text")
    }

    func testLegacyEncodings() {
        XCTAssertEqual(TextPreviewLoader.decode([0x63, 0x61, 0x66, 0xE9, 0x20, 0x80], truncated: false),
                       TextPreview(text: "café €", truncated: false, encoding: .windows1252))
        XCTAssertEqual(TextPreviewLoader.decode([0x61, 0x81], truncated: false)?.encoding, .latin1)   // 0x81 undefined in CP1252
    }

    func testBinaryIsNil() {
        XCTAssertNil(TextPreviewLoader.decode([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D], truncated: false))
        XCTAssertNil(TextPreviewLoader.decode((0..<200).map { UInt8(($0 * 7) % 32) | 0x01 }, truncated: false))
    }

    func testTruncatedMidCharacterIsTrimmedNotReplaced() {
        let bytes = Array("abé".utf8).dropLast()                        // "ab" + first byte of é
        let p = TextPreviewLoader.decode(Array(bytes), truncated: true)
        XCTAssertEqual(p?.text, "ab")
        XCTAssertEqual(p?.encoding, .utf8)
    }

    func testLoadTruncatesAtLimit() async throws {
        try sandbox.createFile("big.txt", contents: Data(repeating: UInt8(ascii: "a"), count: 300_000))
        let p = try await TextPreviewLoader.load(sandbox.url("big.txt"), lanes: LanePool(), volume: .unknown)
        XCTAssertEqual(TextPreviewLoader.limit, 262_144)
        XCTAssertEqual(p.text.utf8.count, 262_144)
        XCTAssertTrue(p.truncated)
        try sandbox.createFile("exact.txt", contents: Data(repeating: UInt8(ascii: "b"), count: 262_144))
        let exact = try await TextPreviewLoader.load(sandbox.url("exact.txt"), lanes: LanePool(), volume: .unknown)
        XCTAssertFalse(exact.truncated)
    }

    func testLoadErrors() async throws {
        try sandbox.createFile("bin.dat", contents: Data([0x00, 0x01, 0x02, 0x00, 0xFF, 0x00, 0x13, 0x00, 0x00, 0x7F]))
        do { _ = try await TextPreviewLoader.load(sandbox.url("bin.dat"), lanes: LanePool(), volume: .unknown); XCTFail() }
        catch { XCTAssertEqual(error, .binary) }
        do { _ = try await TextPreviewLoader.load(sandbox.url("missing.txt"), lanes: LanePool(), volume: .unknown); XCTFail() }
        catch { XCTAssertEqual(error, .posix(ENOENT)) }
    }
}
```

```swift
// Tests/CoreTests/Preview/PreviewPlannerTests.swift
import XCTest
import Darwin
import Synchronization
import UniformTypeIdentifiers
@testable import Core
@testable import MacxFS
import MacxFixtures

final class PreviewPlannerTests: XCTestCase {
    var sandbox: Sandbox!
    let types = TypeRegistry()
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    func subject(_ rel: String, _ kind: Kind = .file) -> PreviewSubject {
        let ext = Substring((rel as NSString).pathExtension)
        let isDir = kind == .directory || kind == .package
        let index: UInt16 = switch kind {
        case .directory: TypeRegistry.folderIndex
        case .symlink: TypeRegistry.symlinkIndex
        default: types.index(forExtension: ext, isDirectory: isDir)
        }
        return PreviewSubject(url: sandbox.url(rel), kind: kind, typeIndex: index, flags: [], size: 0)
    }
    func resolve(_ s: PreviewSubject) async -> PreviewContent {
        await PreviewPlanner.resolve(s, lanes: LanePool(), volume: .unknown, types: types)
    }

    func testClassify() {
        XCTAssertEqual(PreviewPlanner.classify(.plainText), .text)
        XCTAssertEqual(PreviewPlanner.classify(.swiftSource), .text)
        XCTAssertEqual(PreviewPlanner.classify(.json), .text)
        XCTAssertEqual(PreviewPlanner.classify(.html), .text)
        XCTAssertEqual(PreviewPlanner.classify(UTType("public.yaml")!), .text)
        XCTAssertEqual(PreviewPlanner.classify(.shellScript), .text)
        XCTAssertEqual(PreviewPlanner.classify(.rtf), .quickLook)
        XCTAssertEqual(PreviewPlanner.classify(.pdf), .quickLook)
        XCTAssertEqual(PreviewPlanner.classify(.png), .quickLook)
        XCTAssertEqual(PreviewPlanner.classify(.mpeg4Movie), .quickLook)
        XCTAssertEqual(PreviewPlanner.classify(.propertyList), .sniff)
        XCTAssertEqual(PreviewPlanner.classify(.data), .sniff)
        XCTAssertEqual(PreviewPlanner.classify(UTType(filenameExtension: "zzqq")!), .sniff)
    }

    func testResolveRealFiles() async throws {
        try sandbox.createFile("a.txt", contents: Data("hi".utf8))
        try sandbox.writePNG("p.png")
        try sandbox.createDirectory("dir")
        try sandbox.createDirectory("X.app/Contents")
        try sandbox.createSymlink("broken", target: "nowhere.txt")
        try sandbox.createSymlink("link.txt", target: "a.txt")
        try sandbox.createFile("notes.zzqq", contents: Data("plain words".utf8))
        try sandbox.createFile("blob.zzqq", contents: Data([0, 1, 2, 3, 0, 0, 255, 254, 0, 9]))
        try sandbox.createFile("empty.zzqq", contents: Data())
        try sandbox.createFile("locked.zzqq", contents: Data("x".utf8))
        try sandbox.setMode("locked.zzqq", 0o000)

        let res1 = await resolve(subject("a.txt"));             XCTAssertEqual(res1, .text(sandbox.url("a.txt")))
        let res2 = await resolve(subject("p.png"));             XCTAssertEqual(res2, .quickLook(sandbox.url("p.png")))
        let res3 = await resolve(subject("dir", .directory));   XCTAssertEqual(res3, .folder(sandbox.url("dir")))
        let res4 = await resolve(subject("X.app", .package));   XCTAssertEqual(res4, .quickLook(sandbox.url("X.app")))
        let res5 = await resolve(subject("broken", .symlink));  XCTAssertEqual(res5, .brokenLink(sandbox.url("broken")))
        let res6 = await resolve(subject("link.txt", .symlink)); XCTAssertEqual(res6, .text(sandbox.url("link.txt")))
        let res7 = await resolve(subject("notes.zzqq"));        XCTAssertEqual(res7, .text(sandbox.url("notes.zzqq")))
        let res8 = await resolve(subject("blob.zzqq"));         XCTAssertEqual(res8, .quickLook(sandbox.url("blob.zzqq")))
        let res9 = await resolve(subject("empty.zzqq"));        XCTAssertEqual(res9, .text(sandbox.url("empty.zzqq")))
        let res10 = await resolve(subject("locked.zzqq"));      XCTAssertEqual(res10, .unavailable(sandbox.url("locked.zzqq"), code: EACCES))
        let res11 = await resolve(subject("gone.txt"));         XCTAssertEqual(res11, .unavailable(sandbox.url("gone.txt"), code: ENOENT))
    }

    func testDatalessIsCloudPlaceholderAndNeverRead() async {
        let reads = LockedCounter()
        let probe = PreviewProbe(
            stat: { _, _ in .success(ProbeStat(mode: S_IFREG | 0o644, flags: UInt32(SF_DATALESS))) },
            readPrefix: { _, _ in reads.increment(); return .success([]) })
        let s = PreviewSubject(url: URL(filePath: "/tmp/macx-tests-none/cloud.zzqq"), kind: .file,
                               typeIndex: types.index(forExtension: "zzqq", isDirectory: false), flags: [.dataless], size: 10)
        let content = await PreviewPlanner.resolve(s, lanes: LanePool(), volume: .unknown, types: types, probe: probe)
        XCTAssertEqual(content, .cloudPlaceholder(s.url))
        XCTAssertEqual(reads.value, 0)
    }
}

final class LockedCounter: Sendable {
    private let state = Mutex(0)
    func increment() { state.withLock { $0 += 1 } }
    var value: Int { state.withLock { $0 } }
}
```

```swift
// Tests/CoreTests/Preview/PreviewMetadataTests.swift
import XCTest
import CoreGraphics
@testable import Core
@testable import MacxFS
import MacxFixtures

final class PreviewMetadataTests: XCTestCase {
    var sandbox: Sandbox!
    let types = TypeRegistry()
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    func load(_ rel: String, isDirectory: Bool = false) async -> PreviewDetails {
        let index = isDirectory ? TypeRegistry.folderIndex
            : types.index(forExtension: Substring((rel as NSString).pathExtension), isDirectory: false)
        return await PreviewMetadata.load(sandbox.url(rel), typeIndex: index, types: types, lanes: LanePool(), volume: .unknown)
    }

    /// 1 s of 8 kHz mono 16-bit silence.
    func wav() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + 16_000); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(16_000); d.append(Data(count: 16_000))
        return d
    }

    func testSizesDatesAndKind() async throws {
        try sandbox.createFile("t.txt", contents: Data("12345".utf8))
        try sandbox.createDirectory("d")
        let t = await load("t.txt")
        XCTAssertEqual(t.size, 5)
        XCTAssertNotNil(t.created)
        XCTAssertNotNil(t.modified)
        XCTAssertFalse(t.kindDescription.isEmpty)
        let d = await load("d", isDirectory: true)
        XCTAssertNil(d.size)
        XCTAssertNotNil(d.modified)
    }

    func testImageDimensions() async throws {
        try sandbox.writePNG("p.png", pixels: 64)
        let p = await load("p.png")
        XCTAssertEqual(p.pixelWidth, 64)
        XCTAssertEqual(p.pixelHeight, 64)
    }

    func testAudioDuration() async throws {
        try sandbox.createFile("tone.wav", contents: wav())
        let a = await load("tone.wav")
        XCTAssertEqual(try XCTUnwrap(a.duration), 1.0, accuracy: 0.02)
    }

    func testPDFPageCount() async throws {
        let url = sandbox.url("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        let p = await load("doc.pdf")
        XCTAssertEqual(p.pageCount, 2)
    }
}
```

```swift
// Tests/CoreTests/Preview/DownloadWatcherTests.swift
import XCTest
@testable import Core

final class DownloadWatcherTests: XCTestCase {
    let url = URL(filePath: "/tmp/macx-tests-none/cloud.txt")   // never touched: the fake downloader has no file access

    func states(_ d: FakeUbiquitousDownloader, timeout: Duration = .seconds(5)) async -> [DownloadState] {
        var out: [DownloadState] = []
        for await s in DownloadWatcher.download(url, using: d, pollInterval: .milliseconds(10), timeout: timeout) { out.append(s) }
        return out
    }

    func testDownloadsThenDone() async {
        let fake = FakeUbiquitousDownloader(datalessPolls: 2)
        let result = await states(fake)
        XCTAssertEqual(result, [.downloading, .done])
        XCTAssertEqual(fake.started(), [url])
    }

    func testStartFailure() async {
        let result = await states(FakeUbiquitousDownloader(failStart: true))
        XCTAssertEqual(result, [.downloading, .failed])
    }

    func testTimeout() async {
        let result = await states(FakeUbiquitousDownloader(datalessPolls: .max), timeout: .milliseconds(60))
        XCTAssertEqual(result, [.downloading, .timedOut])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "CoreTests.TextPreviewLoaderTests|CoreTests.PreviewPlannerTests|CoreTests.PreviewMetadataTests|CoreTests.DownloadWatcherTests" 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'TextPreviewLoader' in scope`.

- [ ] **Step 3: Implement the types and the text loader**

```swift
// Sources/Core/Preview/PreviewTypes.swift
import Foundation
import MacxFS

public struct PreviewSubject: Sendable, Equatable {
    public var url: URL
    public var kind: Kind
    public var typeIndex: UInt16
    public var flags: EntryFlags
    public var size: Int64
    public init(url: URL, kind: Kind, typeIndex: UInt16, flags: EntryFlags, size: Int64) {
        self.url = url; self.kind = kind; self.typeIndex = typeIndex; self.flags = flags; self.size = size
    }
}

public enum PreviewContent: Sendable, Equatable {
    case nothingSelected, multiple(count: Int, bytes: Int64)
    case folder(URL), text(URL), quickLook(URL)
    case cloudPlaceholder(URL), brokenLink(URL), unavailable(URL, code: Int32)
}

public enum PreviewClass: Sendable, Equatable { case text, quickLook, sniff }
```

```swift
// Sources/Core/Preview/TextPreviewLoader.swift
import Foundation
import Darwin
import MacxFS

public enum TextEncodingGuess: String, Sendable, Equatable { case utf8, utf16LE, utf16BE, windows1252, latin1 }
public struct TextPreview: Sendable, Equatable {
    public var text: String
    public var truncated: Bool
    public var encoding: TextEncodingGuess
    public init(text: String, truncated: Bool, encoding: TextEncodingGuess) { self.text = text; self.truncated = truncated; self.encoding = encoding }
}
public enum TextPreviewError: Error, Sendable, Equatable { case binary, posix(Int32) }

public enum TextPreviewLoader {
    public static let limit = 262_144

    public static func decode(_ bytes: [UInt8], truncated: Bool) -> TextPreview? {
        func preview(_ s: String, _ e: TextEncodingGuess) -> TextPreview { TextPreview(text: s, truncated: truncated, encoding: e) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return preview(String(decoding: trimPartialUTF8(bytes.dropFirst(3), truncated), as: UTF8.self), .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) { return preview(utf16(bytes.dropFirst(2), littleEndian: true), .utf16LE) }
        if bytes.starts(with: [0xFE, 0xFF]) { return preview(utf16(bytes.dropFirst(2), littleEndian: false), .utf16BE) }
        if bytes.contains(0) {
            guard let le = utf16Parity(bytes) else { return nil }
            return preview(utf16(bytes[...], littleEndian: le), le ? .utf16LE : .utf16BE)
        }
        let body = trimPartialUTF8(bytes[...], truncated)
        if let s = String(validating: body, as: UTF8.self) { return preview(s, .utf8) }
        let controls = body.reduce(0) { $1 < 0x20 && ![0x09, 0x0A, 0x0D, 0x0C, 0x1B].contains($1) ? $0 + 1 : $0 }
        if controls * 10 > max(body.count, 1) { return nil }
        if let s = String(bytes: body, encoding: .windowsCP1252) { return preview(s, .windows1252) }
        return preview(String(bytes: body, encoding: .isoLatin1) ?? "", .latin1)
    }

    /// true = little endian, false = big endian, nil = not UTF-16.
    static func utf16Parity(_ bytes: [UInt8]) -> Bool? {
        let sample = bytes.prefix(4_096)
        let pairs = sample.count / 2
        guard pairs >= 2 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (i, b) in sample.enumerated() where b == 0 { if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 } }
        let even = Double(evenZeros) / Double(pairs), odd = Double(oddZeros) / Double(pairs)
        if odd > 0.4 && even < 0.05 { return true }
        if even > 0.4 && odd < 0.05 { return false }
        return nil
    }

    static func utf16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
            units.append(littleEndian ? a | b << 8 : a << 8 | b)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Drops a UTF-8 sequence cut off by the read limit (only when truncated).
    static func trimPartialUTF8(_ bytes: ArraySlice<UInt8>, _ truncated: Bool) -> ArraySlice<UInt8> {
        guard truncated, !bytes.isEmpty else { return bytes }
        var i = bytes.endIndex - 1
        var back = 0
        while i > bytes.startIndex && (bytes[i] & 0xC0) == 0x80 && back < 3 { i -= 1; back += 1 }
        let lead = bytes[i]
        let need = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return bytes.endIndex - i < need ? bytes[..<i] : bytes
    }

    public static func load(_ url: URL, lanes: LanePool, volume: VolumeID) async throws(TextPreviewError) -> TextPreview {
        let path = url.path(percentEncoded: false)
        let result: Result<[UInt8], ProbeError>
        do {
            result = try await lanes.perform(on: volume) { _ in withNoMaterialization { PreviewProbe.read(path, count: limit + 1) } }
        } catch {
            throw .posix(ETIMEDOUT)
        }
        switch result {
        case .failure(let e): throw .posix(e.code)
        case .success(let bytes):
            let truncated = bytes.count > limit
            guard let preview = decode(Array(bytes.prefix(limit)), truncated: truncated) else { throw .binary }
            return preview
        }
    }
}
```

- [ ] **Step 4: Implement the planner with its probe**

```swift
// Sources/Core/Preview/PreviewPlanner.swift
import Foundation
import Darwin
import UniformTypeIdentifiers
import MacxFS

struct ProbeStat: Sendable, Equatable { var mode: mode_t; var flags: UInt32 }
struct ProbeError: Error, Sendable, Equatable { var code: Int32 }

/// File-system calls used by `PreviewPlanner.resolve`. Tests substitute `stat` to simulate dataless files.
struct PreviewProbe: Sendable {
    var stat: @Sendable (_ path: String, _ follow: Bool) -> Result<ProbeStat, ProbeError>
    var readPrefix: @Sendable (_ path: String, _ count: Int) -> Result<[UInt8], ProbeError>

    static let system = PreviewProbe(
        stat: { path, follow in
            var st = Darwin.stat()
            let rc = follow ? Darwin.stat(path, &st) : lstat(path, &st)
            return rc == 0 ? .success(ProbeStat(mode: st.st_mode, flags: st.st_flags)) : .failure(ProbeError(code: errno))
        },
        readPrefix: { path, count in PreviewProbe.read(path, count: count) })

    /// Reads up to `count` bytes. Lane only; callers wrap it in withNoMaterialization.
    static func read(_ path: String, count: Int) -> Result<[UInt8], ProbeError> {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(ProbeError(code: errno)) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + filled, count - filled) }
            if n < 0 { if errno == EINTR { continue }; return .failure(ProbeError(code: errno)) }
            if n == 0 { break }
            filled += n
        }
        return .success(Array(buffer.prefix(filled)))
    }
}

public enum PreviewPlanner {
    static let sniffSize = 4_096

    public static func classify(_ type: UTType) -> PreviewClass {
        if [UTType.rtf, .rtfd, .flatRTFD, .pdf].contains(where: { type.conforms(to: $0) }) { return .quickLook }
        if type.conforms(to: .propertyList) { return .sniff }
        let textRoots: [UTType] = [.text, .sourceCode, .script, .json, .xml] + [UTType("public.yaml")].compactMap { $0 }
        if textRoots.contains(where: { type.conforms(to: $0) }) { return .text }
        if type == .data || type == .item || type.isDynamic || type.identifier.hasPrefix("dyn.") || type == .unixExecutable { return .sniff }
        return .quickLook
    }

    public static func resolve(_ subject: PreviewSubject, lanes: LanePool, volume: VolumeID, types: TypeRegistry) async -> PreviewContent {
        await resolve(subject, lanes: lanes, volume: volume, types: types, probe: .system)
    }

    static func resolve(_ subject: PreviewSubject, lanes: LanePool, volume: VolumeID, types: TypeRegistry,
                        probe: PreviewProbe) async -> PreviewContent {
        let url = subject.url
        do {
            return try await lanes.perform(on: volume) { _ in
                withNoMaterialization { decide(subject, types: types, probe: probe) }
            }
        } catch {
            return .unavailable(url, code: ETIMEDOUT)
        }
    }

    static func decide(_ subject: PreviewSubject, types: TypeRegistry, probe: PreviewProbe) -> PreviewContent {
        let url = subject.url
        let path = url.path(percentEncoded: false)
        var st: ProbeStat
        switch probe.stat(path, false) {
        case .failure(let e): return .unavailable(url, code: e.code)
        case .success(let s): st = s
        }
        var typeIndex = subject.typeIndex
        var readPath = path
        if (st.mode & S_IFMT) == S_IFLNK {
            guard case .success(let target) = probe.stat(path, true) else { return .brokenLink(url) }
            st = target
            let resolved = url.resolvingSymlinksInPath()
            readPath = resolved.path(percentEncoded: false)
            typeIndex = types.index(forExtension: Substring(resolved.pathExtension), isDirectory: (st.mode & S_IFMT) == S_IFDIR)
        } else if subject.kind == .alias {
            guard let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
                  case .success(let target) = probe.stat(resolved.path(percentEncoded: false), true) else { return .brokenLink(url) }
            st = target
            readPath = resolved.path(percentEncoded: false)
            typeIndex = types.index(forExtension: Substring(resolved.pathExtension), isDirectory: (st.mode & S_IFMT) == S_IFDIR)
        }
        if (st.mode & S_IFMT) == S_IFDIR {
            return subject.kind == .package || types.isPackage(typeIndex) ? .quickLook(url) : .folder(url)
        }
        if st.flags & UInt32(SF_DATALESS) != 0 { return .cloudPlaceholder(url) }
        switch classify(types.type(at: typeIndex)) {
        case .text: return .text(url)
        case .quickLook: return .quickLook(url)
        case .sniff:
            switch probe.readPrefix(readPath, sniffSize) {
            case .failure(let e): return .unavailable(url, code: e.code)
            case .success(let bytes):
                if bytes.isEmpty { return .text(url) }
                return TextPreviewLoader.decode(bytes, truncated: bytes.count == sniffSize) != nil ? .text(url) : .quickLook(url)
            }
        }
    }
}
```

`PreviewPlannerTests` builds a `PreviewProbe` with `stat`/`readPrefix` closures. The memberwise initializer is internal, which `@testable import Core` allows.

- [ ] **Step 5: Implement metadata and the download watcher**

```swift
// Sources/Core/Preview/PreviewMetadata.swift
import Foundation
import Darwin
import CoreServices
import ImageIO
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers
import MacxFS

public struct PreviewDetails: Sendable, Equatable {
    public var size: Int64?
    public var created: Date?
    public var modified: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var pageCount: Int?
    public var kindDescription: String
    public init(size: Int64? = nil, created: Date? = nil, modified: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
                duration: Double? = nil, pageCount: Int? = nil, kindDescription: String) {
        self.size = size; self.created = created; self.modified = modified; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.duration = duration; self.pageCount = pageCount; self.kindDescription = kindDescription
    }
}

public enum PreviewMetadata {
    struct Gathered: Sendable { var details: PreviewDetails; var dataless: Bool; var isDirectory: Bool }

    public static func load(_ url: URL, typeIndex: UInt16, types: TypeRegistry, lanes: LanePool, volume: VolumeID) async -> PreviewDetails {
        let type = types.type(at: typeIndex)
        let kind = types.localizedDescription(typeIndex)
        let path = url.path(percentEncoded: false)
        let gathered: Gathered
        do {
            gathered = try await lanes.perform(on: volume) { _ in
                withNoMaterialization { gather(path, type: type, kindDescription: kind) }
            }
        } catch {
            return PreviewDetails(kindDescription: kind)
        }
        var details = gathered.details
        if details.duration == nil, !gathered.dataless, !gathered.isDirectory, type.conforms(to: .audiovisualContent),
           let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric {
            details.duration = time.seconds
        }
        return details
    }

    static func gather(_ path: String, type: UTType, kindDescription: String) -> Gathered {
        var details = PreviewDetails(kindDescription: kindDescription)
        var st = stat()
        guard lstat(path, &st) == 0 else { return Gathered(details: details, dataless: false, isDirectory: false) }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let dataless = st.st_flags & UInt32(SF_DATALESS) != 0
        func date(_ t: timespec) -> Date { Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9) }
        details.size = isDir ? nil : Int64(st.st_size)
        details.created = date(st.st_birthtimespec)
        details.modified = date(st.st_mtimespec)
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString) {
            func number(_ key: CFString) -> NSNumber? { MDItemCopyAttribute(item, key) as? NSNumber }
            details.pixelWidth = number(kMDItemPixelWidth)?.intValue
            details.pixelHeight = number(kMDItemPixelHeight)?.intValue
            details.duration = number(kMDItemDurationSeconds)?.doubleValue
            details.pageCount = number(kMDItemNumberOfPages)?.intValue
        }
        if !dataless && !isDir {
            let fileURL = URL(filePath: path) as CFURL
            if details.pixelWidth == nil, type.conforms(to: .image) {
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                if let source = CGImageSourceCreateWithURL(fileURL, options),
                   let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] {
                    details.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
                    details.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
                }
            }
            if details.pageCount == nil, type.conforms(to: .pdf), let doc = CGPDFDocument(fileURL) {
                details.pageCount = doc.numberOfPages
            }
        }
        return Gathered(details: details, dataless: dataless, isDirectory: isDir)
    }
}
```

Append to `Sources/Core/Preview/Ubiquitous.swift`:

```swift
public enum DownloadState: Sendable, Equatable { case downloading, done, failed, timedOut }

public enum DownloadWatcher {
    public static func download(_ url: URL, using downloader: any UbiquitousDownloading,
                                pollInterval: Duration = .milliseconds(500), timeout: Duration = .seconds(600)) -> AsyncStream<DownloadState> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.downloading)
                do { try await downloader.startDownloading(url) } catch {
                    continuation.yield(.failed)
                    continuation.finish()
                    return
                }
                let deadline = ContinuousClock.now + timeout
                while !Task.isCancelled {
                    if !(await downloader.isDataless(url)) { continuation.yield(.done); break }
                    if ContinuousClock.now >= deadline { continuation.yield(.timedOut); break }
                    try? await Task.sleep(for: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

`Core` may import AVFoundation, ImageIO, CoreGraphics and CoreServices: they are not AppKit. QuickLookUI stays in `UI` (Phase 2 layering rule).

- [ ] **Step 6: Run the P3-08 tests**

Run: `swift test --filter "CoreTests.TextPreviewLoaderTests|CoreTests.PreviewPlannerTests|CoreTests.PreviewMetadataTests|CoreTests.DownloadWatcherTests" 2>&1 | tail -5`
Expected: `Executed 17 tests, with 0 failures`.

- [ ] **Step 7: Build and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`, and `scripts/check-layering.sh && echo LAYERING-OK` → `LAYERING-OK`.

```bash
git add Sources/Core/Preview Tests/CoreTests/Preview
git commit -m "feat: preview planner, 256 KB text loader, preview metadata and download watcher"
```

---

### Task P3-09: Views bind to row sources; Path column; results in the content area

**Files:**
- Create: `Sources/UI/Details/PathCellView.swift`
- Modify: `Sources/UI/Content/FileListView.swift`, `Sources/UI/Details/DetailsViewController.swift`, `Sources/UI/Details/DetailsColumns.swift`, `Sources/UI/Icons/IconsViewController.swift`, `Sources/UI/Columns/ColumnsViewController.swift` (Phase 2: protocol rename only), `Sources/UI/Content/ContentViewController.swift`, `Sources/UI/Content/InlineRenameController.swift`, `Sources/UI/Content/EmptyStateView.swift`, `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/RowSourceBindingTests.swift`

**Interfaces:**
- Consumes: `RowSource`, `RowSourceEvent` (P3-03); `SearchResultsModel`, `SearchState`, `SearchModelEvent`, `SearchNotice`, `SearchFailure` (P3-06); `Settings.resultsColumns` (P3-07); `FileListView`, `DetailsViewController`, `IconsViewController`, `ContentViewController`, `InlineRenameController`, `EmptyStateContent`/`EmptyStateView`, `DetailsColumns`, `IconCache`, `L10n`, `AXID` (Phase 1 §3.14, S5); `RowMapping` (P2-10), `ColumnsViewController` (P2-19), `PathFormatter.tilde(_:home:)` (P2-04), `requireGUISession()` (P2-03).
- Produces: `FileListView.source` / `bind(_ source:)` (plus the `folder` protocol extension), `PathCellView`, `ContentViewController.display(_:)`, `EmptyStateContent.make(search:notices:rowCount:query:)`, `EmptyStateAction.searchSubfolders/.searchAgain`, `InlineRenameController.init(list:source:environment:)`, `DetailsViewController.sort(by:)` (the header-click entry point, also used by tests), `AXID.pathCell`.

**Behaviour:**
- Both lists draw any `RowSource`. Folder-only features (Phase 2 grouping, folder sizes, extended attributes, per-folder view state) are reached through `folder` (`source as? FolderModel`). For results: `RowMapping.identity`, folder sizes off, extended cells empty.
- Details columns: `source.showsPathColumn ? settings.resultsColumns : <Phase 2 folder view-state columns>`. Column moves and resizes persist back to that same list, so results columns never change a folder's columns.
- Path cell: the parent folder, `~`-abbreviated, truncated in the middle, with the full path as tooltip and accessibility value.
- Header click: for a folder, the Phase 2 path (`BrowserSession.updateViewState`); for results, `source.setSortDescriptor`. `.path` is sortable for results.
- `ContentViewController.display(_:)` binds the active list. A `SearchResultsModel` in Columns mode is shown in Details (Columns cannot show results), without changing the stored view mode. It observes `SearchModelEvent` to refresh the empty state and status bar. `focusContext` is `.searchResults` while results are shown.
- Results empty states (only when `rowCount == 0`):
  - `.searching` → "Searching…" with spinner.
  - `.complete` / `.stopped` with `.spotlightOff` → "Spotlight is turned off" / "This Mac can't be searched. Search Subfolders instead." (`.searchSubfolders`).
  - Other `.complete` → "No results for “q”"; with `.mayNotBeIndexed` the detail adds "This folder may not be indexed by Spotlight." (`.searchSubfolders`).
  - `.stopped` → "Search stopped" (`.searchAgain`).
  - `.failed(.rootUnreadable(.notFound|.volumeGone))` → "“X” is no longer available".
  - Other `.rootUnreadable` → "You don't have permission to search “X”".
  - `.failed(.volumeUnresponsive)` → "The disk isn't responding" (`.searchAgain`).
  - `.failed(.spotlightFailed)` → "Spotlight couldn't complete the search" (`.searchAgain`).
- Inline rename works on results: validation through `source.validateName`; commit enqueues `.rename(source.url(atRow:), to:)`. `OperationsCenter` posts the `LocalChange`, the results model re-keys the row, and the controller re-selects it by its new path identity.

- [ ] **Step 1: Write the failing UI tests**

```swift
// Tests/UITests/RowSourceBindingTests.swift
import XCTest
import AppKit
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class RowSourceBindingTests: XCTestCase {
    var sandbox: Sandbox!
    var context: UIContext!
    var env: CoreEnvironment { context.environment }

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = sandbox.url("state")
        context = UIContext(environment: env, options: options)
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    /// A results model fed from a fixed list of (parent, names); completes at once.
    func p(_ relative: String) -> String { sandbox.root.appending(path: relative).path(percentEncoded: false) }

    func results(_ items: [(String, [String])], query: String = "q") -> SearchResultsModel {
        let types = env.types
        let model = SearchResultsModel(title: query, events: { g in
            AsyncStream { c in
                for (parent, names) in items {
                    var b = Batch(generation: g)
                    for n in names {
                        let e = Entry(rowID: 1, fileID: 1, size: 3, allocSize: 3, mtime: 0, ctime: 0, nameOffset: 0,
                                      nameLen: UInt16(n.utf8.count), kind: .file, flags: [.readable],
                                      typeIndex: types.index(forExtension: Substring((n as NSString).pathExtension), isDirectory: false))
                        Array(n.utf8).withUnsafeBufferPointer { b.append(e, nameBytes: $0) }
                    }
                    c.yield(.batch(SearchBatch(parent: URL(filePath: parent, directoryHint: .isDirectory), batch: b)))
                }
                c.yield(.completed(SearchSummary(resultCount: items.reduce(0) { $0 + $1.1.count })))
                c.finish()
            }
        }, context: env.searchContext())
        addTeardownBlock { @MainActor in model.close() }
        return model
    }

    func testPathCellAbbreviatesHomeAndTruncatesInTheMiddle() {
        let cell = PathCellView()
        cell.configure(parent: URL(filePath: "/Users/someone/dev/project", directoryHint: .isDirectory),
                       home: URL(filePath: "/Users/someone", directoryHint: .isDirectory))
        XCTAssertEqual(cell.textField?.stringValue, "~/dev/project")
        XCTAssertEqual(cell.toolTip, "/Users/someone/dev/project")
        XCTAssertEqual(cell.textField?.lineBreakMode, .byTruncatingMiddle)
        cell.configure(parent: URL(filePath: "/Volumes/Data", directoryHint: .isDirectory), home: URL(filePath: "/Users/someone"))
        XCTAssertEqual(cell.textField?.stringValue, "/Volumes/Data")
    }

    func testDetailsShowsResultsWithPathColumn() async {
        let model = results([(p("b"), ["z.txt"]), (p("a"), ["y.txt", "x.txt"])])
        let details = DetailsViewController(context: context)
        _ = details.view
        details.bind(model)
        model.start()
        await waitUntil("rows") { details.tableView.numberOfRows == 3 }
        let visible = details.tableView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
        XCTAssertEqual(visible, env.settings.resultsColumns.filter(\.visible).map { DetailsColumns.identifier($0.id).rawValue })
        XCTAssertTrue(visible.contains(DetailsColumns.identifier(.path).rawValue))
        let pathColumn = details.tableView.column(withIdentifier: DetailsColumns.identifier(.path))
        let cell = details.tableView(details.tableView, viewFor: details.tableView.tableColumns[pathColumn], row: 0) as? PathCellView
        XCTAssertEqual(cell?.toolTip, p("a"))
        XCTAssertTrue(details.source === model)
        XCTAssertNil(details.folder)
    }

    func testFolderSourceKeepsFolderColumns() async throws {
        try sandbox.createFile("f/a.txt")
        let folder = env.makeFolderModel(sandbox.url("f"))
        addTeardownBlock { @MainActor in folder.close() }
        let details = DetailsViewController(context: context)
        _ = details.view
        details.bind(folder)
        folder.start()
        await waitUntil("rows") { details.tableView.numberOfRows == 1 }
        let pathColumn = details.tableView.tableColumns.first { $0.identifier == DetailsColumns.identifier(.path) }
        XCTAssertTrue(pathColumn?.isHidden ?? true)
        XCTAssertTrue(details.folder === folder)
    }

    func testHeaderSortAndColumnWidthsPersistToResultsColumns() async {
        let model = results([(p("b"), ["a.txt"]), (p("a"), ["z.txt"])])
        let details = DetailsViewController(context: context)
        _ = details.view
        details.bind(model)
        model.start()
        await waitUntil("rows") { details.tableView.numberOfRows == 2 }
        let folderColumns = env.settings.columns
        details.sort(by: .path)
        await waitUntil("path sort") { model.sortDescriptor.field == .path && model.name(atRow: 0) == "z.txt" }
        let column = details.tableView.tableColumns[details.tableView.column(withIdentifier: DetailsColumns.identifier(.path))]
        column.width = 333
        NotificationCenter.default.post(name: NSTableView.columnDidResizeNotification, object: details.tableView)
        XCTAssertEqual(env.settings.resultsColumns.first { $0.id == .path }?.width, 333)
        XCTAssertEqual(env.settings.columns, folderColumns)
    }

    func testIconsBindResults() async {
        let model = results([(p("a"), ["one.txt", "two.txt"])])
        let icons = IconsViewController(context: context)
        _ = icons.view
        icons.bind(model)
        model.start()
        await waitUntil("items") { icons.collectionView.numberOfItems(inSection: 0) == 2 }
    }

    func testResultsEmptyStates() {
        let searching = EmptyStateContent.make(search: .searching(SearchProgress()), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(searching?.showsSpinner, true)
        let none = EmptyStateContent.make(search: .complete(SearchSummary()), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(none?.title, String(format: L10n.string("search.empty.noResults"), "tax"))
        let off = EmptyStateContent.make(search: .complete(SearchSummary()), notices: [.spotlightOff], rowCount: 0, query: "tax")
        XCTAssertEqual(off?.action, .searchSubfolders)
        let gone = EmptyStateContent.make(search: .failed(.rootUnreadable(.notFound)), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(gone?.action, .searchAgain)
        XCTAssertNil(EmptyStateContent.make(search: .complete(SearchSummary()), notices: [], rowCount: 3, query: "tax"))
    }

    func testContentShowsResultsInDetailsEvenInColumnsMode() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        let content = ContentViewController(context: context, session: session)
        _ = content.view
        content.setViewMode(.columns)
        let model = results([(p("a"), ["one.txt"])])
        content.display(model)
        model.start()
        XCTAssertTrue(content.activeList is DetailsViewController)
        XCTAssertEqual(content.focusContext, .searchResults)
        await waitUntil("status") { content.activeList.source?.rowCount == 1 }
        content.display(session.folder)
        XCTAssertEqual(content.focusContext, .content)
    }

    func testInlineRenameOfAResultRenamesTheFileAndTheRow() async throws {
        try requireGUISession()
        try sandbox.createFile("work/sub/old-name.txt")
        let spec = SearchSpec(text: "old-name", scope: .subfolders, root: sandbox.url("work"))
        let plan = await env.planSearch(spec)
        let model = env.makeSearchResults(spec, plan: plan)
        addTeardownBlock { @MainActor in model.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let details = DetailsViewController(context: context)
        window.contentView = details.view
        details.bind(model)
        model.start()
        await waitUntil("result") { model.rowCount == 1 }
        let rename = InlineRenameController(list: details, source: model, environment: env)
        rename.begin(row: 0)
        XCTAssertTrue(rename.isEditing)
        (window.firstResponder as? NSTextView)?.string = "new-name.txt"
        rename.commit(moveToNext: false)
        await waitUntil("renamed on disk") { FileManager.default.fileExists(atPath: self.sandbox.url("work/sub/new-name.txt").path(percentEncoded: false)) }
        await waitUntil("row re-keyed") { model.rowCount == 1 && model.name(atRow: 0) == "new-name.txt" }
        XCTAssertEqual(model.url(atRow: 0).lastPathComponent, "new-name.txt")
        XCTAssertEqual(model.selectedURLs.map(\.lastPathComponent), ["new-name.txt"])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter UITests.RowSourceBindingTests 2>&1 | tail -5`
Expected: build FAIL with `error: cannot find 'PathCellView' in scope` and `value of type 'DetailsViewController' has no member 'source'`.

- [ ] **Step 3: Generalize `FileListView` and the lists**

```swift
// Sources/UI/Content/FileListView.swift (protocol part)
@MainActor protocol FileListView: AnyObject {
    var view: NSView { get }
    var source: (any RowSource)? { get }
    func bind(_ source: (any RowSource)?)                 // nil = unbind
    func apply(_ changes: ChangeSet)
    func reloadSelectionDrawing()
    func beginInlineRename(row: Int)
    func scrollToRow(_ row: Int)
    func topVisibleRow() -> Int?
    func visibleRows() -> Range<Int>
}

extension FileListView {
    /// Folder-only features (grouping, folder sizes, extended attributes, view state) use this.
    var folder: FolderModel? { source as? FolderModel }
}
```

In `DetailsViewController` and `IconsViewController`:
- Replace the stored `private(set) var folder: FolderModel?` with `private(set) var source: (any RowSource)?`. Rename `bind(_ folder: FolderModel?)` to `bind(_ source: (any RowSource)?)`.
- Every row-level call (`rowCount`, `entry/name/url/identity(atRow:)`, `row(of:)`, `selection`, `select`, `scrollAnchor`, `isCut(row:)`) goes through `source`. Group/size/attribute code keeps using `folder` and is skipped when it is nil.
- Cut-state redraw: Phase 1 compares `folder.cutNames`; compare instead a `cutSignature` (`folder?.cutNames.hashValue ?? (source as? SearchResultsModel)?.cutURLs.hashValue`).
- Thumbnails (P2-17) build `ThumbnailKey.directory` from `source.parentURL(atRow:)`.
- In Details, `RowMapping` is `folder.map { .grouped(...) } ?? .identity(count: source?.rowCount ?? 0)` (keep the Phase 2 expression for folders).

`ColumnsViewController` (Phase 2): adopt the renamed requirement. `bind(_ source:)` forwards `source as? FolderModel` to its existing folder path; a non-folder source unbinds (ContentViewController never routes results there).

Fix the remaining call sites the compiler lists (`bind(folder)` → `bind(folder)` still compiles because `FolderModel` is a `RowSource`; `bind(nil)` is unambiguous now that there is one overload).

- [ ] **Step 4: Path column, results column set, header sort**

```swift
// Sources/UI/Details/PathCellView.swift
import AppKit
import Core

/// Parent folder of a result, "~"-abbreviated, middle-truncated; full path in tooltip and accessibility value.
@MainActor
final class PathCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(AXID.pathCell)

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("PathCellView is created in code") }

    func configure(parent: URL, home: URL) {
        var full = parent.path(percentEncoded: false)
        if full.count > 1 && full.hasSuffix("/") { full.removeLast() }
        var homePath = home.path(percentEncoded: false)
        if homePath.count > 1 && homePath.hasSuffix("/") { homePath.removeLast() }
        textField?.stringValue = PathFormatter.tilde(full, home: homePath)
        toolTip = full
        setAccessibilityValue(full)
    }
}
```

Add `static let pathCell = "macx.pathCell"` to `AXID`.

In `DetailsViewController`:
- `private var columnSettings: [ColumnSetting]` returns `settings.resultsColumns` when `source?.showsPathColumn == true`, else the Phase 2 view-state columns. `rebuildColumns()` reads it; `bind(_:)` calls `rebuildColumns()` when `showsPathColumn` changed since the last bind.
- `columnsChanged(_:)` writes the new order/widths/visibility back through `setColumnSettings(_:)`, which assigns `settings.resultsColumns` for results and keeps the Phase 2 path for folders.
- `tableView(_:viewFor:row:)`: for `ColumnID.path` dequeue (or create) a `PathCellView` and `configure(parent: source.parentURL(atRow: modelRow), home: settings.home)`. Extended Phase 2 columns render empty when `folder == nil`.
- Move the header-click body into:

```swift
    func sort(by column: ColumnID) {
        guard let source else { return }
        let field = column.sortField
        let current = source.sortDescriptor
        let next = SortDescriptor(field: field, ascending: current.field == field ? !current.ascending : true)
        if folder != nil {
            sortFolder(next)                       // the Phase 2 path (BrowserSession.updateViewState)
        } else {
            source.setSortDescriptor(next)
        }
        updateSortIndicator(next)
    }
```

`DetailsColumns`: the column chooser offers `.path` only when `showsPathColumn` (folders hide it by default as Phase 2 does). For results it offers every column except the Phase 2 extended ones.

- [ ] **Step 5: Content host, empty states, inline rename**

`ContentViewController`:

```swift
    private(set) var displayedSource: (any RowSource)?
    private var resultsToken: ObserverToken?
    private var rowsToken: ObserverToken?

    func display(_ source: any RowSource) {
        resultsToken?.cancel(); resultsToken = nil
        rowsToken?.cancel()
        displayedSource = source
        let results = source as? SearchResultsModel
        // Columns view cannot show results: use Details for them without changing the stored mode.
        installList(for: results != nil && session.viewMode == .columns ? .details : session.viewMode)
        activeList.bind(source)
        rowsToken = source.observeRows { [weak self] event in self?.handleRowEvent(event) }
        if let results {
            resultsToken = results.observe { [weak self] event in
                switch event {
                case .state, .notices: self?.refreshEmptyState(); self?.refreshStatus()
                case .rows: break
                }
            }
        }
        refreshEmptyState()
        refreshStatus()
    }

    override var focusContext: FocusContext { displayedSource is SearchResultsModel ? .searchResults : .content }
```

`installList(for:)` is the Phase 1/2 code that swaps the list for a view mode, extracted. `handleRowEvent` is the Phase 1 handler for `.changes`/`.selection`/`.beginRename`, retargeted from `FolderEvent` to `RowSourceEvent`. `FolderEvent.state/relocate` keep their existing folder observer. Every place that bound `session.folder` now calls `display(session.folder)`. P3-10 calls `display(results)` on `SessionEvent.resultsChanged`.

`refreshEmptyState()`: for results, `EmptyStateContent.make(search: results.state, notices: results.notices, rowCount: results.rowCount, query: results.title)`; for folders, the Phase 1 call. The status bar shows `rowCount` and the selection summary for both. Free space is shown only for folders.

`EmptyStateView.swift` additions:

```swift
// EmptyStateAction gains:  case searchSubfolders, searchAgain
extension EmptyStateContent {
    static func make(search state: SearchState, notices: [SearchNotice], rowCount: Int, query: String) -> EmptyStateContent? {
        guard rowCount == 0 else { return nil }
        func content(_ titleKey: String, _ arg: String? = nil, detail: String? = nil, action: EmptyStateAction? = nil,
                     spinner: Bool = false) -> EmptyStateContent {
            let title = arg.map { String(format: L10n.string(titleKey), $0) } ?? L10n.string(titleKey)
            return EmptyStateContent(title: title, detail: detail.map(L10n.string), action: action, showsSpinner: spinner)
        }
        switch state {
        case .searching:
            return content("search.empty.searching", spinner: true)
        case .complete, .stopped:
            if notices.contains(.spotlightOff) {
                return content("search.empty.spotlightOff", detail: "search.empty.spotlightOff.detail", action: .searchSubfolders)
            }
            if case .stopped = state { return content("search.empty.stopped", action: .searchAgain) }
            if notices.contains(.mayNotBeIndexed) {
                return content("search.empty.noResults", query, detail: "search.empty.mayNotBeIndexed", action: .searchSubfolders)
            }
            return content("search.empty.noResults", query)
        case .failed(.rootUnreadable(let reason)):
            switch reason {
            case .notFound, .volumeGone: return content("search.empty.rootGone", query, action: .searchAgain)
            default: return content("search.empty.noPermission", query, action: .searchAgain)
            }
        case .failed(.volumeUnresponsive):
            return content("search.empty.unresponsive", action: .searchAgain)
        case .failed(.spotlightFailed):
            return content("search.empty.spotlightFailed", action: .searchAgain)
        }
    }
}
```

The `query` argument for `rootGone`/`noPermission` is the root folder's display name, passed by `ContentViewController` as `results.spec?.root.lastPathComponent ?? results.title`; for `noResults` it is the query title. Add the keys to `Localizable.xcstrings` with the English texts from "Behaviour" above (`%@` for the argument). `EmptyStateView.performAction()` routes `.searchSubfolders` and `.searchAgain` through `onAction`. P3-10 handles them (switch the scope to Subfolders; `results.rerun()`). Until then they are no-ops.

`InlineRenameController`: change the stored `folder: FolderModel` to `source: any RowSource` and the init to `init(list: FileListView, source: any RowSource, environment: CoreEnvironment)`. Replace `folder.validateName`, `folder.url(atRow:)`, `folder.name(atRow:)` and `folder.select` with the `source` equivalents. After the rename job's outcome:
- folder source: keep the Phase 1 behaviour (`LocalChange.select` carries the selection);
- otherwise: compute `newPath = parent + "/" + newName`, and once `source.row(of: .name(newPath))` is non-nil (check immediately, then on each `observeRows` event, for at most 2 s), `source.select(.set([row], cursor: row))`.

Update the Phase 1/2 call sites (`InlineRenameController(list: self, folder: folder, …)` → `source: source`).

- [ ] **Step 6: Run the tests**

Run: `swift test --filter "UITests.RowSourceBindingTests|UITests.DetailsViewTests|UITests.InlineRenameTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures` (`testInlineRenameOfAResultRenamesTheFileAndTheRow` skips without a GUI session).

- [ ] **Step 7: Full UI suite, build, commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`; `swift test --filter UITests 2>&1 | tail -3` → `0 failures`.

```bash
git add Sources/UI Tests/UITests/RowSourceBindingTests.swift
git commit -m "feat: lists bind to row sources; Path column, results empty states and inline rename on results"
```

---

### Task P3-10: Search UI: field, scope bar, filters, session search, Open Containing Folder

**Files:**
- Create: `Sources/UI/Search/SearchController.swift`, `Sources/UI/Search/SearchScopeBar.swift`, `Sources/UI/Search/SearchFiltersView.swift`, `Sources/UI/Search/SearchStrings.swift`
- Modify: `Sources/UI/Window/BrowserSession.swift`, `Sources/UI/Window/CommandActions.swift` (`CommandTarget.resultsSelection`), `Sources/UI/Window/BrowserWindowController.swift` (owns the `SearchController`, scope bar placement, title), `Sources/UI/Toolbar/SearchFieldController.swift`, `Sources/UI/Toolbar/AddressBarView.swift`, `Sources/UI/Content/ContentViewController.swift` (`resultsChanged` → `display`, scope bar host, empty-state actions), `Sources/UI/Commands/FileCommandController.swift`, `Sources/UI/Menus/ContextMenuBuilder.swift`, `Sources/UI/Menus/MainMenuBuilder.swift`, `Sources/UI/Menus/MenuValidation.swift` (checkmarks), `Sources/UI/Support/AXID.swift`, `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/SearchControllerTests.swift`, `Tests/UITests/BrowserSessionSearchTests.swift`

**Interfaces:**
- Consumes: everything from P3-02 … P3-09; `BrowserSession` (`navigate(to:selecting:recordHistory:)`, `goBack/goForward/goUp/reload`, `observe`, `SessionEvent`), `NavigationHistory.replaceCurrent`, `FolderModel.setQuery`, `ViewQuery.criteria`, `CommandHandler`, `CommandTarget`, `ContextMenuBuilder`, `MainMenuBuilder`, `MenuValidation`, `AddressBarView`, `ScenarioHooks.addressText`, `KeyMap.primary` (Phase 1/2).
- Produces: the BrowserSession additions in "Interface additions → UI" (`results`, `searchSpec`, `search(_:)`, `clearSearch()`, `showResults(_:recordHistory:)`, `openContainingFolder(of:)`), plus `private(set) var lastPlan: SearchPlan?`; `SessionEvent.resultsChanged/searchTextChanged`; `CommandTarget.resultsSelection`; `SearchController`; `SearchScopeBar`; `SearchFiltersView`; `SearchStrings`; `AddressBarView.showSearch(title:)`; `ContextMenuBuilder.itemMenu(for:in results:handler:)` and `emptySpaceMenu(for results:handler:)`; AXIDs `searchScopeBar`, `searchScope`, `searchMode`, `searchFilters`, `searchStop`, `searchStatus`, `searchNotice`, `searchSave`.

**Session rules:**
- `search(spec)` plans through `environment.planSearch`. A newer `search`/`clearSearch` call supersedes a pending plan (token check). By engine:
  - `.none` with `.spotlightOff`: shows a results model (`init(title:events:)`) whose stream is `.notice(.spotlightOff)`, `.completed`, so the content shows the "Spotlight is turned off" state.
  - `.none` otherwise: `clearSearch()`.
  - `.folderFilter(c)`: leaves any results (as `clearSearch` does), then `folder.setQuery(query with criteria = c, filter = "")`. No history entry.
  - `.crawler` / `.spotlight`: `showResults(model, recordHistory: results == nil)`. The first search from a folder adds one history entry; retyping replaces it (`replaceCurrent`) and closes the old model (Review Focus 5).
- `showResults(model, recordHistory:)`: the history URL is `model.spec?.url`, or for external models (Phase 4 TAGS) `x-macexplorer-results:<UUID>`. Starts the model and emits `.resultsChanged(model)` and `.historyChanged`.
- Navigating to a folder while results show parks the results model under its history URL (stopping it if still searching). The session keeps at most 5 parked models (LRU) and closes evicted ones. `goBack`/`goForward` onto a search URL reuse the parked model when present (same rows, selection and scroll). Otherwise a spec URL re-runs its spec, and an external URL with no parked model falls back to the folder (`replaceCurrent(folder.directory)`).
- Folder navigation clears the search (spec §5.2): `searchSpec = nil`, `.searchTextChanged("")`.
- `clearSearch()` closes the shown results, `history.replaceCurrent(root)` (which drops the duplicate back entry), returns to the search root, removes folder criteria, and emits `.resultsChanged(nil)`.
- `goUp()` with results showing navigates to the search root. `reload()` with results showing calls `results.rerun()`.
- `openContainingFolder(of: url)` = `navigate(to: parent, selecting: name)`. Back returns to the parked results.

**Field rules (`SearchController`):**
- The root is `session.results?.spec?.root ?? session.folder.directory`, so retyping inside results keeps searching the same folder.
- This folder + Name runs on every keystroke with no debounce (the Phase 1 instant filter, now with criteria). Every other combination is debounced (default 250 ms). Return runs immediately. Empty text and empty filters call `clearSearch()` at once.
- Scope and mode changes persist to `Settings.searchScope/searchMode` and re-run immediately. Filter changes are debounced.
- `diagnostics` comes from `QuerySyntax.parse(text).diagnostics` on each change. The scope bar shows "Didn't understand 'size:big'".
- `adopt(spec)` (history, saved search, `.searchTextChanged`) updates text, scope, mode and filters without running.

- [ ] **Step 1: Write the failing session tests**

```swift
// Tests/UITests/BrowserSessionSearchTests.swift
import XCTest
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class BrowserSessionSearchTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    var session: BrowserSession!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        try sandbox.createFile("work/tax-2025.pdf")
        try sandbox.createFile("work/Taxes/tax-old.pdf")
        try sandbox.createFile("work/notes.txt")
        env = CoreEnvironment.sandboxed(root: sandbox.root)
        session = BrowserSession(environment: env, initialURL: sandbox.url("work"))
    }

    var work: URL { sandbox.url("work").standardizedFileURL }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }
    func complete(_ m: SearchResultsModel?) -> Bool { if case .complete? = m?.state { true } else { false } }
    func spec(_ text: String, _ scope: SearchScope = .subfolders, _ mode: SearchMode = .name) -> SearchSpec {
        SearchSpec(text: text, scope: scope, mode: mode, root: work)
    }
    func names(_ m: SearchResultsModel) -> [String] { (0..<m.rowCount).map { m.name(atRow: $0) } }

    func testSubfoldersSearchShowsResultsWithOneHistoryEntry() async throws {
        await session.search(spec("tax"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        XCTAssertEqual(names(results), ["Taxes", "tax-2025.pdf", "tax-old.pdf"])
        XCTAssertEqual(session.history.current, spec("tax").url)
        XCTAssertEqual(session.history.backList.map(\.standardizedFileURL), [work])
        XCTAssertEqual(session.searchSpec, spec("tax"))
    }

    // Review Focus 5
    func testRetypingReplacesResultsModelAndHistoryEntry() async throws {
        await session.search(spec("ta"))
        let first = try XCTUnwrap(session.results)
        var lateEvents = 0
        await session.search(spec("tax"))
        let token = first.observe { _ in lateEvents += 1 }
        defer { token.cancel() }
        let second = try XCTUnwrap(session.results)
        XCTAssertFalse(first === second)
        XCTAssertEqual(session.history.current, spec("tax").url)
        XCTAssertEqual(session.history.backList.count, 1, "retyping must not grow history")
        await waitUntil("second complete") { complete(second) }
        XCTAssertEqual(lateEvents, 0, "the replaced model is closed")
    }

    func testClearSearchReturnsToTheFolderWithoutAHistoryEntry() async throws {
        await session.search(spec("tax"))
        session.clearSearch()
        XCTAssertNil(session.results)
        XCTAssertNil(session.searchSpec)
        XCTAssertEqual(session.history.current.standardizedFileURL, work)
        XCTAssertFalse(session.history.canGoBack)
    }

    func testThisFolderFilterUsesCriteriaAndNoHistory() async throws {
        await session.search(spec("tax", .thisFolder))
        XCTAssertNil(session.results)
        XCTAssertEqual(session.folder.query.criteria, SearchCriteria(nameTerms: [NameTerm("tax")]))
        XCTAssertFalse(session.history.canGoBack)
        session.navigate(to: sandbox.url("work/Taxes"))
        XCTAssertNil(session.folder.query.criteria, "navigation clears the search")
        XCTAssertNil(session.searchSpec)
    }

    func testOpeningAFolderResultThenBackRestoresTheSameModel() async throws {
        await session.search(spec("tax"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        results.select(.set([1], cursor: 1))
        session.navigate(to: sandbox.url("work/Taxes"))
        XCTAssertNil(session.results)
        session.goBack()
        await waitUntil("restored") { session.results != nil }
        XCTAssertTrue(session.results === results)
        XCTAssertEqual(results.selectedURLs.map(\.lastPathComponent), ["tax-2025.pdf"])
    }

    func testOpenContainingFolderSelectsTheItem() async throws {
        await session.search(spec("tax-old"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) && results.rowCount == 1 }
        session.openContainingFolder(of: results.url(atRow: 0))
        XCTAssertEqual(session.folder.directory.standardizedFileURL, sandbox.url("work/Taxes").standardizedFileURL)
        await waitUntil("selected") { session.folder.selectedURLs.map(\.lastPathComponent) == ["tax-old.pdf"] }
        XCTAssertTrue(session.history.canGoBack)
    }

    func testUpAndReloadWhileShowingResults() async throws {
        await session.search(spec("tax"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        let gen = results.generation
        session.reload()
        XCTAssertGreaterThan(results.generation, gen)
        session.goUp()
        XCTAssertNil(session.results)
        XCTAssertEqual(session.folder.directory.standardizedFileURL, work)
    }

    func testThisMacWithSpotlightOffShowsTheNotice() async throws {
        await session.search(spec("tax", .thisMac))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        XCTAssertEqual(results.notices, [.spotlightOff])
        XCTAssertEqual(results.rowCount, 0)
    }

    func testContentsFallbackNoticeOnFolderFilter() async throws {
        await session.search(spec("tax", .thisFolder, .contents))   // sandboxed services report indexing disabled
        XCTAssertNil(session.results)
        XCTAssertEqual(session.lastPlan?.notices, [.contentsNotIndexed(volumeName: env.volumes.volume(for: work)?.name ?? "work")])
    }

    func testExternalResultsParkAndRestore() async throws {
        let model = SearchResultsModel(title: "Red", events: { _ in AsyncStream { $0.yield(.completed(SearchSummary())); $0.finish() } },
                                       context: env.searchContext())
        session.showResults(model, recordHistory: true)
        XCTAssertEqual(session.history.current.scheme, "x-macexplorer-results")
        session.navigate(to: sandbox.url("work/Taxes"))
        session.goBack()
        XCTAssertTrue(session.results === model)
    }
}
```

- [ ] **Step 2: Write the failing controller tests**

```swift
// Tests/UITests/SearchControllerTests.swift
import XCTest
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class SearchControllerTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    var session: BrowserSession!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        try sandbox.createFile("work/tax.pdf")
        try sandbox.createFile("work/deep/tax-2.pdf")
        env = CoreEnvironment.sandboxed(root: sandbox.root)
        session = BrowserSession(environment: env, initialURL: sandbox.url("work"))
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    func testThisFolderNameIsInstant() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .seconds(10))
        c.scope = .thisFolder
        c.textDidChange("tax")
        await waitUntil("criteria applied") { session.folder.query.criteria != nil }
        XCTAssertNil(session.results)
    }

    func testSubfoldersDebouncesToOneSearch() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(80))
        c.scope = .subfolders
        var shown: [String] = []
        let token = session.observe { if case .resultsChanged(let m?) = $0 { shown.append(m.title) } }
        defer { token.cancel() }
        for prefix in ["t", "ta", "tax"] { c.textDidChange(prefix) }
        await waitUntil("one search") { !shown.isEmpty }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(shown, ["tax"])
        XCTAssertEqual(env.settings.searchScope, .subfolders)
    }

    func testReturnRunsImmediately() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .seconds(10))
        c.scope = .subfolders
        c.textDidChange("tax")
        c.commit()
        await waitUntil("results") { session.results != nil }
    }

    func testDiagnosticsAndClear() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(10))
        c.scope = .subfolders
        c.textDidChange("tax size:big")
        XCTAssertEqual(c.diagnostics, [SyntaxDiagnostic(token: "size:big", problem: .badSize)])
        c.commit()
        await waitUntil("results") { session.results != nil }
        c.clear()
        XCTAssertEqual(c.text, "")
        XCTAssertNil(session.results)
        XCTAssertTrue(c.diagnostics.isEmpty)
    }

    func testScopeChangeRerunsAndAdoptDoesNot() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(10))
        c.scope = .thisFolder
        c.textDidChange("tax")
        c.scope = .subfolders
        await waitUntil("results after scope change") { session.results != nil }
        let model = session.results
        c.adopt(SearchSpec(text: "other", scope: .thisMac, mode: .contents, root: sandbox.url("work")))
        XCTAssertEqual(c.text, "other")
        XCTAssertEqual(c.scope, .thisMac)
        XCTAssertEqual(c.mode, .contents)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(session.results === model, "adopt must not run a search")
    }

    func testRetypingInsideResultsKeepsTheRoot() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(10))
        c.scope = .subfolders
        c.textDidChange("tax")
        c.commit()
        await waitUntil("results") { session.results != nil }
        c.textDidChange("tax-2")
        c.commit()
        await waitUntil("second") { session.results?.title == "tax-2" }
        XCTAssertEqual(session.results?.spec?.root.standardizedFileURL, sandbox.url("work").standardizedFileURL)
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter "UITests.BrowserSessionSearchTests|UITests.SearchControllerTests" 2>&1 | tail -5`
Expected: build FAIL with `value of type 'BrowserSession' has no member 'search'` and `cannot find 'SearchController' in scope`.

- [ ] **Step 4: Implement the session additions**

In `Sources/UI/Window/BrowserSession.swift` (add to `SessionEvent`: `case resultsChanged(SearchResultsModel?)`, `case searchTextChanged(String)`):

```swift
    // MARK: Phase 3 search

    static let resultsScheme = "x-macexplorer-results"
    private(set) var results: SearchResultsModel?
    private(set) var searchSpec: SearchSpec?
    private(set) var lastPlan: SearchPlan?
    private var searchToken = 0
    private var parked: [(url: URL, model: SearchResultsModel)] = []     // most recent last, ≤ 5
    private var externalURLs: [ObjectIdentifier: URL] = [:]

    func search(_ spec: SearchSpec) async {
        searchToken &+= 1
        let token = searchToken
        let plan = await environment.planSearch(spec)
        guard token == searchToken else { return }
        lastPlan = plan
        switch plan.engine {
        case .none:
            guard plan.notices.contains(.spotlightOff) else { clearSearch(); return }
            let off = SearchResultsModel(title: spec.text, events: { _ in
                AsyncStream { c in c.yield(.notice(.spotlightOff)); c.yield(.completed(SearchSummary())); c.finish() }
            }, context: environment.searchContext())
            searchSpec = spec
            show(off, url: spec.url, recordHistory: results == nil)
        case .folderFilter(let criteria):
            leaveResultsForRoot()
            searchSpec = spec
            var q = folder.query
            q.filter = ""
            q.criteria = criteria
            folder.setQuery(q)
            emit(.resultsChanged(nil))
        case .crawler, .spotlight:
            clearFolderCriteria()
            searchSpec = spec
            show(environment.makeSearchResults(spec, plan: plan), url: spec.url, recordHistory: results == nil)
        }
    }

    func showResults(_ model: SearchResultsModel, recordHistory: Bool) {
        let url = model.spec?.url ?? externalURL(for: model)
        searchSpec = model.spec
        show(model, url: url, recordHistory: recordHistory)
    }

    func clearSearch() {
        searchToken &+= 1
        lastPlan = nil
        searchSpec = nil
        clearFolderCriteria()
        leaveResultsForRoot()
        emit(.resultsChanged(nil))
    }

    func openContainingFolder(of url: URL) {
        navigate(to: url.deletingLastPathComponent(), selecting: url.lastPathComponent)
    }

    private func show(_ model: SearchResultsModel, url: URL, recordHistory: Bool) {
        if let current = results, current !== model { current.close() }    // replaced, not parked
        results = model
        if recordHistory { history.visit(url) } else { history.replaceCurrent(url) }
        if case .searching = model.state, model.generation == .initial { model.start() }
        emit(.resultsChanged(model))
        emit(.historyChanged)
    }

    /// Results → the search root, replacing the results history entry.
    private func leaveResultsForRoot() {
        guard let current = results else { return }
        let root = current.spec?.root ?? folder.directory
        current.close()
        results = nil
        history.replaceCurrent(root)
        if root.standardizedFileURL != folder.directory.standardizedFileURL { replaceFolder(with: root, selecting: nil) }
        emit(.historyChanged)
    }

    private func clearFolderCriteria() {
        guard folder.query.criteria != nil else { return }
        var q = folder.query
        q.criteria = nil
        folder.setQuery(q)
    }

    /// Called at the top of folder navigation (navigate/goUp/goBack onto a folder URL).
    private func parkResults() {
        guard let current = results else { return }
        if case .searching = current.state { current.stop() }
        parked.removeAll { $0.model === current }
        parked.append((history.current, current))
        while parked.count > 5 { parked.removeFirst().model.close() }
        results = nil
        emit(.resultsChanged(nil))
    }

    private func externalURL(for model: SearchResultsModel) -> URL {
        if let url = externalURLs[ObjectIdentifier(model)] { return url }
        let url = URL(string: "\(Self.resultsScheme):\(UUID().uuidString)")!
        externalURLs[ObjectIdentifier(model)] = url
        return url
    }

    /// Back/forward landed on a search or results URL (history.current is already `url`).
    private func showHistoryEntry(_ url: URL) {
        if let i = parked.firstIndex(where: { $0.url == url }) {
            let model = parked.remove(at: i).model
            results = model
            searchSpec = model.spec
            emit(.resultsChanged(model))
            if let spec = model.spec { emit(.searchTextChanged(spec.text)) }
            return
        }
        if let spec = SearchSpec(url: url) {
            searchSpec = spec                       // set before the event: the field adopts session.searchSpec
            emit(.searchTextChanged(spec.text))
            Task { await search(spec) }
            return
        }
        history.replaceCurrent(folder.directory)
        emit(.historyChanged)
    }
```

Then change the existing methods:
- `navigate(to:selecting:recordHistory:)` (and the Phase 2 overload with `folderID:`):
  - If `url.scheme == SearchSpec.urlScheme || url.scheme == Self.resultsScheme`, call `showHistoryEntry(url)` and return.
  - Otherwise call `parkResults()` first, then clear the search: `searchSpec = nil; lastPlan = nil; emit(.searchTextChanged(""))`.
  - When `url` equals the current folder's directory and results were showing, skip the reload (just park) and apply `selecting`.
  - Then run the existing body. `replaceFolder(with:selecting:)` is that existing body's model-swap part, extracted for `leaveResultsForRoot`.
- `goBack()` / `goForward()` already route through `navigate(…, recordHistory: false)` with the history's URL, so search URLs reach `showHistoryEntry`. Check that they do; if they swap the model directly, route them through `navigate`.
- `goUp()`: `if let root = results?.spec?.root { navigate(to: root); return }`.
- `reload()`: `if let results { results.rerun(); return }`.
- Closing the session (window close) closes `results` and every parked model.

- [ ] **Step 5: Implement `SearchController` and `SearchStrings`**

```swift
// Sources/UI/Search/SearchController.swift
import Foundation
import Core
import MacxFS

/// Field text + scope + mode + filters → SearchSpec → BrowserSession.search, with debounce.
@MainActor
final class SearchController {
    private unowned let session: BrowserSession
    private let settings: Settings
    private let debounce: Duration
    private var pending: Task<Void, Never>?
    private var adopting = false

    private(set) var text = ""
    private(set) var diagnostics: [SyntaxDiagnostic] = []
    var scope: SearchScope { didSet { guard !adopting, scope != oldValue else { return }; settings.searchScope = scope; run(now: true) } }
    var mode: SearchMode { didSet { guard !adopting, mode != oldValue else { return }; settings.searchMode = mode; run(now: true) } }
    var filters = SearchFilters() { didSet { guard !adopting, filters != oldValue else { return }; run(now: false) } }
    var onChange: (() -> Void)?

    init(session: BrowserSession, settings: Settings, debounce: Duration = .milliseconds(250)) {
        self.session = session
        self.settings = settings
        self.debounce = debounce
        scope = settings.searchScope
        mode = settings.searchMode
    }

    var root: URL { session.results?.spec?.root ?? session.folder.directory }

    func spec() -> SearchSpec? {
        let s = SearchSpec(text: text, scope: scope, mode: mode, filters: filters, root: root)
        return s.isEmptyQuery ? nil : s
    }

    func textDidChange(_ newText: String) {
        text = newText
        diagnostics = QuerySyntax.parse(newText).diagnostics
        onChange?()
        run(now: scope == .thisFolder && mode == .name)
    }

    func commit() { run(now: true) }

    func clear() {
        pending?.cancel()
        text = ""
        diagnostics = []
        filters = SearchFilters()
        session.clearSearch()
        onChange?()
    }

    /// Mirrors a spec the session is showing (history, saved search) without running anything.
    func adopt(_ spec: SearchSpec?) {
        pending?.cancel()
        adopting = true
        defer { adopting = false; onChange?() }
        guard let spec else { text = ""; diagnostics = []; filters = SearchFilters(); return }
        text = spec.text
        diagnostics = QuerySyntax.parse(spec.text).diagnostics
        scope = spec.scope
        mode = spec.mode
        filters = spec.filters
    }

    private func run(now: Bool) {
        pending?.cancel()
        guard let spec = spec() else { session.clearSearch(); return }
        let wait = now ? Duration.zero : debounce
        pending = Task { [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
            await self?.session.search(spec)
        }
    }
}
```

`Sources/UI/Search/SearchStrings.swift` is an `enum SearchStrings` of `static func`s returning `L10n` strings. The keys, English text and the argument each takes:

| Function | Key | English |
|---|---|---|
| `diagnostic(_ d)` | `search.diagnostic` | `Didn't understand '%@'` (d.token) |
| `notice(.contentsNotIndexed(v))` | `search.notice.contentsNotIndexed` | `“%@” isn't indexed by Spotlight, so names were searched instead.` |
| `notice(.spotlightOff)` | `search.notice.spotlightOff` | `Spotlight is turned off, so This Mac can't be searched.` |
| `notice(.truncated(n))` | `search.notice.truncated` | `Showing the first %@ results. Refine your search.` (n formatted with a grouping `NumberFormatter`) |
| `notice(.skippedLocations(n))` | `search.notice.skipped` | `%@ folders were skipped because they couldn't be read.` |
| `notice(.mayNotBeIndexed)` | `search.notice.mayNotBeIndexed` | `This folder may not be indexed by Spotlight.` |
| `progress(p)` | `search.progress` | `Searching… %@ results in %@ folders` |
| `summary(s)` | `search.summary` | `%@ results` (`search.summary.one`: `1 result`) |
| `stopped(s)` | `search.stopped` | `Stopped. %@ results` |
| `resultsTitle(rootName)` | `search.resultsTitle` | `Search Results in “%@”` |
| `fieldPlaceholder(folderName)` | `search.placeholder` | `Search “%@”` |
| scope chips | `search.scope.thisFolder/subfolders/thisMac` | `This Folder`, `Subfolders`, `This Mac` |
| mode toggle | `search.mode.name/contents` | `Name`, `Contents` |
| buttons | `search.filters`, `search.stop`, `search.save` | `Filters`, `Stop`, `Save Search…` |

- [ ] **Step 6: Scope bar, filters popover, field, address bar**

`SearchScopeBar` (`NSView`, AXID `searchScopeBar`) is a horizontal `NSStackView`:
- an `NSSegmentedControl` for the three scopes (`.selectOne`, AXID `searchScope`);
- an `NSSegmentedControl` for Name/Contents (AXID `searchMode`);
- a "Filters" pull-down button (AXID `searchFilters`) that shows a dot badge when `filters` is non-empty and opens an `NSPopover` with `SearchFiltersView`;
- a small spinning `NSProgressIndicator` and a status label (AXID `searchStatus`: `SearchStrings.progress/summary/stopped`);
- a "Stop" button (AXID `searchStop`, visible only while `.searching`);
- a trailing "Save Search…" button (AXID `searchSave`, enabled when `CommandAvailability.isEnabled(.saveSearch, …)`).

Under it, a one-line, secondary-colour notice label (AXID `searchNotice`) shows diagnostics first, then plan/model notices joined by "  ·  ", and is hidden when empty. `update(controller:session:)` refreshes it all. The bar is visible while the field has text, while results show, or while the field is first responder. It is installed by `ContentViewController` above the command bar, and hiding it collapses its height to 0 (no layout jump of the list's scroll position: the anchor is restored as on any reset).

`SearchFiltersView` (`NSViewController` with an `NSGridView`):
- Kind: one checkbox per `KindFilter.allCases` (titles `search.kind.<raw>`).
- Modified and Created: pop-ups with Any, the ten `RelativeDay`s (`search.date.<raw>`) and Custom… The last reveals two `NSDatePicker`s that produce `.days(lower: DayBound(…, inclusive: true), upper: DayBound(…, inclusive: true))`.
- Size: a pop-up with Any, the seven `SizeWord`s (`search.size.<raw>`, with ranges in the title, e.g. "Small (16 KB – 1 MB)") and Custom…, which reveals min/max fields parsed with `QuerySyntax.numberWithUnit`.
- Extension: a text field, comma-separated, normalised like `ext:`.
- A "Clear Filters" button.

Every control change calls `onChange(SearchFilters)`; `SearchController.filters` receives it. All controls have accessibility labels.

`SearchFieldController` (Phase 1: filter field → `FolderModel.setQuery(filter:)`):
- `controlTextDidChange` → `searchController.textDidChange(field.stringValue)`.
- `control(_:textView:doCommandBy:)`: `insertNewline:` → `commit()`; `cancelOperation:` → if text non-empty, `clear()`; else return focus to the content (Phase 1 Esc behaviour).
- The placeholder is `SearchStrings.fieldPlaceholder(folder display name)`.
- On `SessionEvent.searchTextChanged(t)`: `field.stringValue = t` and `searchController.adopt(session.searchSpec)`. On `.folderChanged`, update the placeholder. The Phase 1 substring filter path is removed: This folder + Name criteria do the same thing, now with globs.

`AddressBarView.showSearch(title:)` replaces the breadcrumb with one non-navigating segment (magnifying-glass symbol + `SearchStrings.resultsTitle(root name)`). Clicking it, ⌘L, ⌥D or F4 enter edit mode with the root's POSIX path. `show(_:volume:)` restores the breadcrumb. `BrowserWindowController` calls it on `.resultsChanged(model?)`; the scenario hook `addressText` returns the title while it is shown. The window title becomes the same string.

`ContentViewController`:
- On `.resultsChanged(model)` → `display(model ?? session.folder)`.
- Empty-state actions: `.searchSubfolders` → `searchController.scope = .subfolders`; `.searchAgain` → `session.results?.rerun()`.
- `commandTarget` returns `.resultsSelection(results)` while results show.

- [ ] **Step 7: Commands, menus and context menus**

`CommandTarget` gains `case resultsSelection(SearchResultsModel)`. In `FileCommandController`:
- `.resultsSelection(m)` maps to `m.selectedURLs` and reuses the URL-based helpers of `.contentSelection` for: `open`, `openInNewWindow`, `openInNewTab`, `showPackageContents`, `openInTerminal`, `revealInFinder`, `cut`, `copy`, `copyAsPath` and the Phase 2 copy-path variants, `moveToTrash`, `deletePermanently`, `duplicate`, `properties`, `share`, `quickLook`, `selectAll`/`selectNone`/`invertSelection` (via `m.select`) and `rename` (inline, via the list).
- `makeAlias`/`makeSymlink` are enabled only when every selected item has the same parent, which becomes the destination.
- `paste`/`moveItemHere`/`new*` are disabled.
- Cut marks: after `cut`/`copy`/`revalidate`, set `m.cutURLs = environment.clipboard.cutURLs`.
- `openContainingFolder` → `session.openContainingFolder(of: first selected URL)`.
- `stopSearch` → `session.results?.stop()`.
- `refresh` → `session.reload()` (reruns).
- `saveSearch` → `environment.settings.addSavedSearch(name: spec.text, spec: spec)` for `session.searchSpec` (P3-11 inserts the name prompt).
- `searchScope*`/`searchMode*` → set `searchController.scope/mode`.
- `togglePreviewPane`, `downloadForPreview` (P3-12) and `renameSavedSearch`/`removeSavedSearch` (P3-11) stay no-ops here.
- `CommandState` for results: `selectionCount`, `showingResults: true`, `isSearching` (state is `.searching`), `hasSearchQuery: session.searchSpec != nil`, `canPaste: false`.

`ContextMenuBuilder`:
- `itemMenu(for rows: IndexSet, in results: SearchResultsModel, handler:)`: Open, Open Containing Folder (second, always for results), Open in New Tab, Open With ▸ (Phase 1 `OpenWithMenu`), Quick Look, —, Cut, Copy, Copy as Path ▸, —, Rename, Move to Trash, —, Get Info.
- `emptySpaceMenu(for results:, handler:)`: Sort By ▸, View ▸, —, Search Again, Save Search…. It has no Paste and no New Folder.

`MainMenuBuilder`:
- File › Save Search… (`saveSearch`).
- View › Search ▸ This Folder / Subfolders / This Mac / — / Name / Contents / — / Stop Search, plus View › Show Preview Pane (`togglePreviewPane`, ⌥P; the action lands in P3-12).
- Go › Open Containing Folder (⌥⌘R).

`MenuValidation` sets `.on` state for the active scope/mode items and titles the preview item "Show/Hide Preview Pane" from `settings.previewPaneVisible`.

- [ ] **Step 8: Run the tests**

Run: `swift test --filter "UITests.BrowserSessionSearchTests|UITests.SearchControllerTests|UITests.BrowserSessionTests|UITests.ContextMenuTests|UITests.MenuValidationTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 9: Manual check in a sandbox (no real folders)**

```bash
SBX=$(mktemp -d "${TMPDIR}macx-scenario-XXXXXX") && mkdir -p "$SBX/root/a/b" "$SBX/state" && touch "$SBX/root/a/b/tax-2025.pdf" "$SBX/root/tax.txt"
scripts/bundle.sh debug --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app
.build/macExplorer-scenarios.app/Contents/MacOS/macExplorer --root "$SBX/root" --state-dir "$SBX/state" --sandbox-trash "$SBX/trash" --skip-onboarding
```
Expected:
- ⌘F, type `tax`: the folder filters instantly.
- Click "Subfolders": the results show with a Path column (`…/root/a/b`) and the address bar reads `Search Results in “root”`.
- Select `tax-2025.pdf` and press ⌥⌘R: the folder `b` opens with the file selected; ⌘[ returns to the same results.
- Type `size:big`: "Didn't understand 'size:big'".

Quit, then `rm -rf "$SBX"` (only the directory this step created).

- [ ] **Step 10: Build and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`; `swift test --filter UITests 2>&1 | tail -3` → `0 failures`.

```bash
git add Sources/UI Tests/UITests/BrowserSessionSearchTests.swift Tests/UITests/SearchControllerTests.swift
git commit -m "feat: search field with scopes, filters and syntax; results navigation and Open Containing Folder"
```

---

### Task P3-11: Sidebar SEARCHES section

**Files:**
- Create: `Sources/UI/Search/NamePrompt.swift`
- Modify: `Sources/UI/Sidebar/SidebarItem.swift`, `Sources/UI/Sidebar/SidebarViewController.swift`, `Sources/UI/Window/BrowserSession.swift` (`openSavedSearch`), `Sources/UI/Window/CommandActions.swift` (`CommandTarget.savedSearch`), `Sources/UI/Commands/FileCommandController.swift` (save/rename/remove/open), `Sources/UI/App/UIContext.swift` (`namePrompter`), `Sources/UI/Search/SearchStrings.swift`, `Sources/UI/Support/AXID.swift`, `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/SidebarSearchesTests.swift`

**Interfaces:**
- Consumes: `SavedSearch`, `SavedSearchNaming`, `Settings.savedSearches/addSavedSearch/renameSavedSearch/removeSavedSearch/moveSavedSearch/collapsedSections`, `SidebarSection.searches`, `FocusContext.sidebarSavedSearch`, `CommandAvailability.effectiveCommand` (P3-07); `BrowserSession.search`, `SessionEvent.searchTextChanged`, `SearchController.adopt` (P3-10); `SidebarItem`, `SidebarViewController`, `WindowManager.openTab(at:in:selecting:select:)` (P2-05), `ObservationLoop` (S5), `FileOpQueue.snapshots()` (Phase 1).
- Produces: `SidebarItem.searchesHeader`, `SidebarItem.savedSearch(SavedSearch)`; `CommandTarget.savedSearch(SavedSearch)`; `BrowserSession.openSavedSearch(_:)`; `@MainActor protocol NamePrompting { func promptForName(title: String, initial: String, on window: NSWindow?) async -> String? }`, `SheetNamePrompter`; `UIContext.namePrompter` (default `SheetNamePrompter()`); `SidebarViewController.moveSavedSearch(id:to:)` (drop entry point); AXIDs `sidebarSavedSearch(_ name:)` (`macx.sidebar.search.<name>`) and `namePromptField`.

**Rules:**
- Section order: FAVORITES, SEARCHES, LOCATIONS, FOLDERS. SEARCHES is absent while `savedSearches` is empty and appears when the first one is saved. It is collapsible, and the state persists in `collapsedSections`.
- Row: SF Symbol `magnifyingglass` + name. Tooltip `SearchStrings.savedSearchTooltip(spec)`, e.g. "tax kind:pdf — Subfolders of “work”" (scope titles from P3-10). Accessibility label "Saved search, <name>".
- Click or Return → `session.openSavedSearch(saved)`:
  - for This folder specs, first navigate to `spec.root` (when it is not the current folder);
  - then set `searchSpec` and emit `.searchTextChanged(spec.text)` (the field and chips adopt it);
  - then `await search(spec)`.
  - A missing root shows the P3-09 "no longer available" empty state.
- ⌘-click or middle-click → open in a new tab, which then runs `openSavedSearch`.
- Del (`moveToTrash` remapped) → `removeSavedSearch`. ⇧Del does nothing. F2 or the "Rename…" menu → `NamePrompt`, then `renameSavedSearch` (made unique). No file-system call and no `FileOpQueue` job ever happens for a saved-search row.
- Drag within SEARCHES reorders (`moveSavedSearch`). Pasteboard type `com.macexplorer.saved-search` carries the UUID string. Drops from other sections or from Finder are refused there.
- Context menu: Open, Open in New Tab, —, Rename…, Remove from Sidebar.
- "Save Search…" (`saveSearch`, P3-10 button and menu) now asks for a name with `namePrompter` (initial value: the query text) before calling `addSavedSearch`. Cancel saves nothing.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/SidebarSearchesTests.swift
import XCTest
import AppKit
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class FakePrompter: NamePrompting {
    var answers: [String?]
    var asked: [String] = []
    init(_ answers: [String?]) { self.answers = answers }
    func promptForName(title: String, initial: String, on window: NSWindow?) async -> String? {
        asked.append(initial)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

@MainActor
final class SidebarSearchesTests: XCTestCase {
    var sandbox: Sandbox!
    var context: UIContext!
    var session: BrowserSession!
    var sidebar: SidebarViewController!
    var env: CoreEnvironment { context.environment }

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        try sandbox.createFile("work/tax.pdf")
        try sandbox.createFile("work/sub/tax-2.pdf")
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = sandbox.url("state")
        context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root), options: options)
        session = BrowserSession(environment: env, initialURL: sandbox.url("work"))
        sidebar = SidebarViewController(context: context, session: session)
        _ = sidebar.view
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    func savedRows() -> [String] {
        (0..<sidebar.outlineView.numberOfRows).compactMap {
            if case .savedSearch(let s)? = sidebar.outlineView.item(atRow: $0) as? SidebarItem { s.name } else { nil }
        }
    }
    func row(of name: String) -> Int {
        (0..<sidebar.outlineView.numberOfRows).first {
            if case .savedSearch(let s)? = sidebar.outlineView.item(atRow: $0) as? SidebarItem { s.name == name } else { false }
        } ?? -1
    }
    var spec: SearchSpec { SearchSpec(text: "tax", scope: .subfolders, root: sandbox.url("work")) }

    func testSectionAppearsOnlyWithSavedSearches() async {
        XCTAssertFalse(sidebar.sectionHeaders.contains(.searches))
        env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("section") { self.savedRows() == ["Taxes"] }
        XCTAssertEqual(sidebar.sectionHeaders, [.favorites, .searches, .locations, .folders].filter { sidebar.sectionHeaders.contains($0) })
        env.settings.collapsedSections.insert(.searches)
        await waitUntil("collapsed") { self.savedRows().isEmpty }
        XCTAssertTrue(sidebar.sectionHeaders.contains(.searches))
    }

    func testClickRunsTheSearchAndFillsTheField() async {
        env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("row") { self.row(of: "Taxes") >= 0 }
        var texts: [String] = []
        let token = session.observe { if case .searchTextChanged(let t) = $0 { texts.append(t) } }
        defer { token.cancel() }
        sidebar.activateRow(row(of: "Taxes"), newTab: false)
        await waitUntil("results") { self.session.results != nil }
        XCTAssertEqual(session.searchSpec, spec)
        XCTAssertEqual(texts.last, "tax")
        XCTAssertEqual(sidebar.focusContext, .sidebarSavedSearch)
    }

    func testThisFolderSavedSearchNavigatesToItsRoot() async {
        let s = SearchSpec(text: "tax", scope: .thisFolder, root: sandbox.url("work/sub"))
        env.settings.addSavedSearch(name: "Sub", spec: s)
        await waitUntil("row") { self.row(of: "Sub") >= 0 }
        sidebar.activateRow(row(of: "Sub"), newTab: false)
        await waitUntil("filter applied in root") {
            self.session.folder.directory.standardizedFileURL == self.sandbox.url("work/sub").standardizedFileURL
                && self.session.folder.query.criteria != nil
        }
    }

    func testDelRemovesTheSavedSearchAndNeverTouchesFiles() async {
        let saved = env.settings.addSavedSearch(name: "Taxes", spec: spec)
        await waitUntil("row") { self.row(of: "Taxes") >= 0 }
        sidebar.outlineView.selectRowIndexes([row(of: "Taxes")], byExtendingSelection: false)
        XCTAssertEqual(sidebar.focusContext, .sidebarSavedSearch)
        let effective = CommandAvailability.effectiveCommand(.moveToTrash, focus: sidebar.focusContext)
        XCTAssertEqual(effective, .removeSavedSearch)
        sidebar.handler?.perform(effective!, target: .savedSearch(saved), sender: nil)
        await waitUntil("removed") { self.env.settings.savedSearches.isEmpty }
        XCTAssertNil(CommandAvailability.effectiveCommand(.deletePermanently, focus: .sidebarSavedSearch))
        let jobs = await env.fileOps.snapshots()
        XCTAssertTrue(jobs.isEmpty, "no file operation for a saved-search row")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.url("work/tax.pdf").path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.url("work").path(percentEncoded: false)))
    }

    func testRenameAndSaveUseThePrompt() async throws {
        try requireGUISession()
        let prompter = FakePrompter(["Taxes", "Taxes", nil])
        context.namePrompter = prompter
        let window = BrowserWindowController(context: context, initialURL: sandbox.url("work"))
        let controller = FileCommandController(context: context, window: window)
        await window.session.search(spec)
        controller.perform(.saveSearch, target: .currentFolder(window.session.folder), sender: nil)
        await waitUntil("saved") { self.env.settings.savedSearches.map(\.name) == ["Taxes"] }
        controller.perform(.saveSearch, target: .currentFolder(window.session.folder), sender: nil)
        await waitUntil("second saved unique") { self.env.settings.savedSearches.map(\.name) == ["Taxes", "Taxes 2"] }
        controller.perform(.saveSearch, target: .currentFolder(window.session.folder), sender: nil)   // cancelled
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(env.settings.savedSearches.count, 2)
        XCTAssertEqual(prompter.asked, ["tax", "tax", "tax"])
        let second = env.settings.savedSearches[1]
        prompter.answers = ["Old taxes"]
        controller.perform(.renameSavedSearch, target: .savedSearch(second), sender: nil)
        await waitUntil("renamed") { self.env.settings.savedSearches.map(\.name) == ["Taxes", "Old taxes"] }
    }

    func testReorderByDrop() async {
        let a = env.settings.addSavedSearch(name: "A", spec: spec)
        env.settings.addSavedSearch(name: "B", spec: spec)
        env.settings.addSavedSearch(name: "C", spec: spec)
        await waitUntil("rows") { self.savedRows() == ["A", "B", "C"] }
        XCTAssertTrue(sidebar.moveSavedSearch(id: a.id, to: 2))
        await waitUntil("reordered") { self.savedRows() == ["B", "C", "A"] }
        XCTAssertFalse(sidebar.moveSavedSearch(id: UUID(), to: 0))
    }
}
```

`sidebar.sectionHeaders: [SidebarSection]` (headers currently in the outline, in order) and `sidebar.activateRow(_:newTab:)` (the click/Return entry point) are small internal helpers added here for tests; the Phase 1 sidebar already has an equivalent activation path that they wrap.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter UITests.SidebarSearchesTests 2>&1 | tail -5`
Expected: build FAIL with `cannot find type 'NamePrompting' in scope` and `type 'SidebarItem' has no member 'savedSearch'`.

- [ ] **Step 3: Implement the prompt**

```swift
// Sources/UI/Search/NamePrompt.swift
import AppKit
import Core

@MainActor protocol NamePrompting: AnyObject {
    func promptForName(title: String, initial: String, on window: NSWindow?) async -> String?
}

/// Sheet with one text field (Save Search…, Rename…). Returns nil on Cancel or a blank name.
@MainActor final class SheetNamePrompter: NamePrompting {
    func promptForName(title: String, initial: String, on window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityIdentifier(AXID.namePromptField)
        field.setAccessibilityLabel(title)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
```

Keys: `search.save.title` ("Save Search"), `search.rename.title` ("Rename Saved Search"); reuse the Phase 1 `common.ok`/`common.cancel` keys (add them if Phase 1 named them differently). The scenario driver's P2-03 `answerAlert` step clicks the buttons of this sheet, and `type` fills its field.

`UIContext` gains `var namePrompter: any NamePrompting = SheetNamePrompter()` (internal).

- [ ] **Step 4: Sidebar items, section and actions**

`SidebarItem`: add `case searchesHeader` and `case savedSearch(SavedSearch)`, with identity by `SavedSearch.id` (equality/hash use the id so renames keep the outline row). `SidebarSection` mapping: both belong to `.searches`.

`SidebarViewController`:
- Build the SEARCHES section from `settings.savedSearches` in the same `ObservationLoop` that observes favorites. Read `savedSearches` and `collapsedSections` there, and reload only that section.
- `viewFor` a `.savedSearch` row: an image + text cell with symbol `magnifyingglass`, the name, the tooltip and the accessibility identifier `AXID.sidebarSavedSearch(name)`.
- `focusContext`: `.sidebarSavedSearch` when the selected item is a saved search. `commandTarget`: `.savedSearch(saved)`.
- `activateRow(_:newTab:)` (click, Return, ⌘-click/middle-click through Phase 2's `MiddleClickRouter.shouldOpenTab`):
  - same tab: `Task { await session.openSavedSearch(saved) }`;
  - new tab: `context.windows.openTab(at: saved.spec.root, in: host, select: true)`, then that tab's session `openSavedSearch`.
- Context menu for saved-search rows: Open, Open in New Tab, —, Rename…, Remove from Sidebar (`removeSavedSearch`).
- Drag and drop:
  - `pasteboardWriterForItem` for saved searches writes `com.macexplorer.saved-search` = UUID string.
  - `validateDrop` accepts that type only when the proposed parent is the SEARCHES header (index ≥ 0), and refuses file URLs there.
  - `acceptDrop` calls `moveSavedSearch(id:to:)`.

```swift
    @discardableResult
    func moveSavedSearch(id: UUID, to index: Int) -> Bool {
        let settings = context.environment.settings
        guard let from = settings.savedSearches.firstIndex(where: { $0.id == id }) else { return false }
        settings.moveSavedSearch(from: from, to: index)
        return true
    }
```

`moveSavedSearch(id:to:)` takes the final position (`to` counts after the removal, as in `Settings.moveSavedSearch`). `acceptDrop` converts the outline's child index with `childIndex > from ? childIndex - 1 : childIndex`, so a drop below the last row lands last.

`BrowserSession.openSavedSearch(_ saved: SavedSearch) async`:

```swift
    func openSavedSearch(_ saved: SavedSearch) async {
        let spec = saved.spec
        if spec.scope == .thisFolder, spec.root.standardizedFileURL != folder.directory.standardizedFileURL {
            navigate(to: spec.root)
        }
        searchSpec = spec
        emit(.searchTextChanged(spec.text))
        await search(spec)
    }
```

`FileCommandController`:
- `.savedSearch(s)` target: `open` → `openSavedSearch`; `openInNewTab` → new tab as above.
- `renameSavedSearch` → `namePrompter.promptForName(title: L10n.string("search.rename.title"), initial: s.name, on: window.window)`, then `settings.renameSavedSearch(s.id, to:)`.
- `removeSavedSearch` → `settings.removeSavedSearch(s.id)`.
- Every other command is disabled for this target (`CommandAvailability` already says so). The handler's switch lists them explicitly, with no `default:`.
- `saveSearch` (any target, `session.searchSpec != nil`): `if let name = await namePrompter.promptForName(title: L10n.string("search.save.title"), initial: spec.text, on: window.window) { settings.addSavedSearch(name: name, spec: spec) }`.

`SearchStrings.savedSearchTooltip(_ spec: SearchSpec) -> String`: `"%@ — %@"` (query text or "(filters only)", scope phrase: `search.scopePhrase.thisFolder` "in “%@”", `.subfolders` "Subfolders of “%@”", `.thisMac` "This Mac").

- [ ] **Step 5: Run the tests**

Run: `swift test --filter "UITests.SidebarSearchesTests|UITests.SidebarTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures` (`testRenameAndSaveUseThePrompt` skips without a GUI session).

- [ ] **Step 6: Build and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`; `swift test --filter UITests 2>&1 | tail -3` → `0 failures`.

```bash
git add Sources/UI Tests/UITests/SidebarSearchesTests.swift
git commit -m "feat: SEARCHES sidebar section with saved searches (open, rename, remove, reorder)"
```

---

### Task P3-12: Preview pane

**Files:**
- Create: `Sources/UI/Preview/PreviewPaneController.swift`, `Sources/UI/Preview/QuickLookHost.swift`, `Sources/UI/Preview/TextPreviewView.swift`, `Sources/UI/Preview/PreviewDetailsView.swift`, `Sources/UI/Preview/PreviewMessageView.swift`
- Modify: `Sources/UI/Window/BrowserSplitViewController.swift` (inspector item), `Sources/UI/Window/BrowserWindowController.swift` (bind the pane to the displayed source), `Sources/UI/Commands/FileCommandController.swift` (`togglePreviewPane`, `downloadForPreview`), `Sources/UI/Support/AXID.swift`, `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/PreviewPaneTests.swift`

**Interfaces:**
- Consumes: `PreviewSubject`, `PreviewContent`, `PreviewPlanner.resolve`, `TextPreviewLoader.load`, `TextPreviewError`, `PreviewMetadata.load`, `PreviewDetails`, `DownloadWatcher`, `DownloadState`, `UbiquitousDownloading`, `FakeUbiquitousDownloader` (P3-08/P3-06); `RowSource`, `RowSourceEvent` (P3-03); `Settings.previewPaneVisible/previewPaneWidth`, `Command.togglePreviewPane/downloadForPreview`, `KeyMap.collidesWithTextEditing` (P3-07); `ContentViewController.display` (P3-09); `BrowserSplitViewController`, `MenuValidation`, `MainMenuBuilder`, `IconCache.typeIcon`, `Formatters` (Phase 1); `CoreEnvironment.searchServices.downloader`, `Volumes.volume(for:)`.
- Produces: `PreviewPaneController` (`init(context:makeHost:debounce:resolve:)`, `bind(_:)`, `isActive`, `displayState`, `details`, `performDownload()`), `PreviewPaneController.DisplayState`, `@MainActor protocol QuickLookHosting`, `QLPreviewViewHost`, `FakeQuickLookHost`, `TextPreviewView`, `PreviewDetailsView`, `PreviewMessageView`, `BrowserSplitViewController.togglePreviewPane()` / `previewPane`; AXIDs `previewPane`, `previewText`, `previewTruncation`, `previewMessage`, `previewDownload`, `previewDetails`.

**Rules:**
- The pane is the split view's inspector item (`NSSplitViewItem(inspectorWithViewController:)`, thickness 220…600, initial width `Settings.previewPaneWidth`, collapsed unless `previewPaneVisible`). ⌥P / View › Show Preview Pane toggles it with animation and persists `previewPaneVisible`. Width changes persist `previewPaneWidth` when not collapsed. No `autosaveName` is set (sandbox rule; Settings persists it).
- While collapsed, `isActive == false`: no resolve, no load, the Quick Look host shows nothing, and the source observer is dropped.
- Selection or row changes are debounced (120 ms) and stamped with a generation; a stale result is dropped. 0 selected → `.nothing` ("No item selected"); > 1 → `.multiple(count, bytes)` ("3 items, 12 KB"); 1 → `PreviewPlanner.resolve` on lanes (the main thread only sets `previewItem` after that check):
  - `.text` → `TextPreviewLoader.load` → `TextPreviewView` with a "Showing the first 256 KB" footer when truncated. `.binary` falls back to Quick Look; `.posix(code)` → `.unavailable`.
  - `.quickLook` → `host.show(url)`.
  - `.folder` → message with the folder icon and name.
  - `.cloudPlaceholder` → message "This item is in iCloud" plus a "Download" button. It is never loaded until Download is clicked; then `DownloadWatcher` drives "Downloading…", re-resolves on `.done`, and shows "Couldn't download" + "Try Again" on `.failed`/`.timedOut`.
  - `.brokenLink` → "The original item can't be found".
  - `.unavailable` → "Preview unavailable" + the reason (`POSIXErrorCode` text).
- Under every single-item state except `.nothing`/`.multiple`, the details grid shows Kind, Size (files), Created, Modified, Dimensions, Duration and Pages from `PreviewMetadata.load`, hiding absent rows.
- ⌥P while a text field is first responder types "π" (Review Focus 2): `MenuValidation` disables the item because `togglePreviewPane ∈ collidesWithTextEditing`, so the key equivalent is not consumed.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/PreviewPaneTests.swift
import XCTest
import AppKit
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class PreviewPaneTests: XCTestCase {
    var sandbox: Sandbox!
    var context: UIContext!
    var env: CoreEnvironment { context.environment }
    var host: FakeQuickLookHost!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = sandbox.url("state")
        context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root), options: options)
        host = FakeQuickLookHost()
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    func pane(resolve: PreviewPaneController.Resolver? = nil) -> PreviewPaneController {
        let host = self.host!
        let p = PreviewPaneController(context: context, makeHost: { host }, debounce: .milliseconds(20),
                                      resolve: resolve ?? PreviewPaneController.defaultResolve(context.environment))
        _ = p.view
        p.isActive = true
        return p
    }

    func folder(_ rel: String) async -> FolderModel {
        let m = env.makeFolderModel(sandbox.url(rel))
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        await waitUntil("loaded") { m.state == .complete }
        return m
    }
    func select(_ m: FolderModel, _ names: [String]) { m.select(.names(names)) }

    func testNothingTextAndTruncation() async throws {
        try sandbox.createFile("d/big.txt", contents: Data(repeating: UInt8(ascii: "a"), count: 300_000))
        try sandbox.createFile("d/small.txt", contents: Data("hello".utf8))
        let m = await folder("d")
        let p = pane()
        p.bind(m)
        await waitUntil("nothing") { p.displayState == .nothing }
        select(m, ["big.txt"])
        await waitUntil("text") { if case .text(_, true) = p.displayState { true } else { false } }
        if case .text(let text, _) = p.displayState { XCTAssertEqual(text.utf8.count, 262_144) }
        XCTAssertFalse(p.truncationFooterHidden)
        select(m, ["small.txt"])
        await waitUntil("small") { p.displayState == .text("hello", truncated: false) }
        XCTAssertTrue(p.truncationFooterHidden)
        XCTAssertNil(host.shownURL)
    }

    func testQuickLookFolderMultipleAndBrokenLink() async throws {
        try sandbox.writePNG("d/p.png")
        try sandbox.createDirectory("d/sub")
        try sandbox.createFile("d/a.txt", contents: Data("12".utf8))
        try sandbox.createSymlink("d/broken", target: "nowhere")
        let m = await folder("d")
        let p = pane()
        p.bind(m)
        select(m, ["p.png"])
        await waitUntil("quick look") { p.displayState == .quickLook(self.sandbox.url("d/p.png")) }
        XCTAssertEqual(host.shownURL?.lastPathComponent, "p.png")
        await waitUntil("details") { p.details?.pixelWidth == 64 }
        select(m, ["sub"])
        await waitUntil("folder") { if case .folder = p.displayState { true } else { false } }
        XCTAssertNil(host.shownURL, "Quick Look is cleared when not used")
        select(m, ["a.txt", "p.png"])
        await waitUntil("multiple") { if case .multiple(2, _) = p.displayState { true } else { false } }
        XCTAssertNil(p.details)
        select(m, ["broken"])
        await waitUntil("broken") { if case .broken = p.displayState { true } else { false } }
    }

    func testRapidSelectionResolvesOnlyTheLast() async throws {
        for n in ["1.txt", "2.txt", "3.txt", "4.txt"] { try sandbox.createFile("d/\(n)") }
        let m = await folder("d")
        var resolved: [String] = []
        let base = PreviewPaneController.defaultResolve(env)
        let p = pane(resolve: { subject in resolved.append(subject.url.lastPathComponent); return await base(subject) })
        p.bind(m)
        for n in ["1.txt", "2.txt", "3.txt", "4.txt"] { select(m, [n]) }
        await waitUntil("last shown") { if case .text = p.displayState { true } else { false } }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(resolved, ["4.txt"])
    }

    func testCloudPlaceholderLoadsNothingUntilDownload() async throws {
        try sandbox.createFile("d/cloud.txt", contents: Data("now local".utf8))
        let m = await folder("d")
        var downloaded = false
        let base = PreviewPaneController.defaultResolve(env)
        let p = pane(resolve: { subject in downloaded ? await base(subject) : .cloudPlaceholder(subject.url) })
        let fake = FakeUbiquitousDownloader(datalessPolls: 1)
        p.downloader = fake
        p.downloadPollInterval = .milliseconds(10)
        p.bind(m)
        select(m, ["cloud.txt"])
        await waitUntil("cloud") { p.displayState == .cloud(self.sandbox.url("d/cloud.txt")) }
        XCTAssertNil(host.shownURL)
        XCTAssertEqual(p.textLoads, 0, "a dataless item is never read")
        XCTAssertEqual(fake.started(), [])
        downloaded = true
        p.performDownload()
        await waitUntil("downloaded and shown") { p.displayState == .text("now local", truncated: false) }
        XCTAssertEqual(fake.started(), [sandbox.url("d/cloud.txt")])
    }

    func testInactivePaneDoesNoWork() async throws {
        try sandbox.createFile("d/a.txt")
        let m = await folder("d")
        var calls = 0
        let p = pane(resolve: { _ in calls += 1; return .nothingSelected })
        p.isActive = false
        p.bind(m)
        select(m, ["a.txt"])
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(p.displayState, .hidden)
        p.isActive = true
        await waitUntil("works when shown") { calls == 1 }
    }

    func testTogglePersistsVisibilityAndWidth() async throws {
        try requireGUISession()
        let window = BrowserWindowController(context: context, initialURL: sandbox.root)
        window.showWindow(nil)
        defer { window.close() }
        let split = try XCTUnwrap(window.splitController)
        XCTAssertTrue(split.previewItem.isCollapsed)
        split.togglePreviewPane()
        await waitUntil("shown") { !split.previewItem.isCollapsed }
        XCTAssertTrue(env.settings.previewPaneVisible)
        XCTAssertTrue(split.previewPane.isActive)
        split.setPreviewWidth(400)
        await waitUntil("width persisted") { abs(self.env.settings.previewPaneWidth - 400) < 2 }
        split.togglePreviewPane()
        await waitUntil("hidden") { split.previewItem.isCollapsed }
        XCTAssertFalse(env.settings.previewPaneVisible)
        XCTAssertFalse(split.previewPane.isActive)
    }

    // Review Focus 2
    func testOptionPReachesFieldEditorWhileEditing() async throws {
        try requireGUISession()
        NSApp.mainMenu = MainMenuBuilder.build()
        let window = BrowserWindowController(context: context, initialURL: sandbox.root)
        window.showWindow(nil)
        defer { window.close() }
        window.focus(.addressBar)
        await waitUntil("editing") { window.window?.firstResponder is NSTextView }
        let editor = try XCTUnwrap(window.window?.firstResponder as? NSTextView)
        editor.string = ""
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
                                                   windowNumber: window.window!.windowNumber, context: nil,
                                                   characters: "π", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        NSApp.sendEvent(event)
        await waitUntil("typed") { editor.string == "π" }
        XCTAssertFalse(env.settings.previewPaneVisible, "⌥P must not toggle the pane while typing")
    }
}
```

The test-only members (`truncationFooterHidden`, `textLoads`, `downloader`, `downloadPollInterval`, `BrowserWindowController.splitController`, `BrowserSplitViewController.previewItem/setPreviewWidth(_:)`) are internal and listed in Step 3.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter UITests.PreviewPaneTests 2>&1 | tail -5`
Expected: build FAIL with `cannot find 'PreviewPaneController' in scope`.

- [ ] **Step 3: Implement the hosts and the pane controller**

```swift
// Sources/UI/Preview/QuickLookHost.swift
import AppKit
import QuickLookUI

@MainActor protocol QuickLookHosting: AnyObject {
    var view: NSView { get }
    var shownURL: URL? { get }
    func show(_ url: URL?)
    func close()
}

@MainActor final class QLPreviewViewHost: QuickLookHosting {
    private let preview: QLPreviewView
    private(set) var shownURL: URL?
    var view: NSView { preview }
    init() {
        preview = QLPreviewView(frame: .zero, style: .normal)!
        preview.shouldCloseWithWindow = false
        preview.autostarts = true
    }
    /// Only called after PreviewPlanner confirmed the item exists and is not dataless.
    func show(_ url: URL?) {
        guard url != shownURL else { return }
        shownURL = url
        preview.previewItem = url as NSURL?
    }
    func close() { preview.close() }
}

@MainActor final class FakeQuickLookHost: QuickLookHosting {
    let view = NSView()
    private(set) var shownURL: URL?
    private(set) var history: [URL?] = []
    func show(_ url: URL?) { shownURL = url; history.append(url) }
    func close() {}
}
```

```swift
// Sources/UI/Preview/PreviewPaneController.swift
import AppKit
import Core
import MacxFS

@MainActor
final class PreviewPaneController: NSViewController {
    typealias Resolver = @MainActor (PreviewSubject) async -> PreviewContent

    enum DisplayState: Equatable {
        case hidden, nothing, loading
        case multiple(Int, Int64)
        case text(String, truncated: Bool)
        case quickLook(URL), folder(URL), cloud(URL), downloading(URL), downloadFailed(URL), broken(URL)
        case unavailable(URL, Int32)
    }

    static func defaultResolve(_ env: CoreEnvironment) -> Resolver {
        { subject in
            let volume = env.volumes.volume(for: subject.url)?.id ?? .unknown
            return await PreviewPlanner.resolve(subject, lanes: env.lanes, volume: volume, types: env.types)
        }
    }

    private let context: UIContext
    private let makeHost: @MainActor () -> any QuickLookHosting
    private let debounce: Duration
    private let resolve: Resolver
    private lazy var host = makeHost()
    private let textView = TextPreviewView()
    private let messageView = PreviewMessageView()
    private let detailsView = PreviewDetailsView()
    private let stack = NSStackView()
    private var source: (any RowSource)?
    private var sourceToken: ObserverToken?
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var downloadTask: Task<Void, Never>?

    private(set) var displayState: DisplayState = .hidden
    private(set) var details: PreviewDetails?
    private(set) var textLoads = 0
    var downloader: (any UbiquitousDownloading)?
    var downloadPollInterval: Duration = .milliseconds(500)
    var truncationFooterHidden: Bool { textView.footerHidden }
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { observeSource(); scheduleUpdate(immediate: true) } else { deactivate() }
        }
    }

    init(context: UIContext, makeHost: @escaping @MainActor () -> any QuickLookHosting = { QLPreviewViewHost() },
         debounce: Duration = .milliseconds(120), resolve: Resolver? = nil) {
        self.context = context
        self.makeHost = makeHost
        self.debounce = debounce
        self.resolve = resolve ?? Self.defaultResolve(context.environment)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("PreviewPaneController is created in code") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for v in [host.view, textView, messageView, detailsView] { stack.addArrangedSubview(v); v.isHidden = true }
        host.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.setAccessibilityIdentifier(AXID.previewPane)
        stack.setAccessibilityLabel(L10n.string("preview.pane"))
        messageView.onButton = { [weak self] in self?.performDownload() }
        view = stack
    }

    func bind(_ source: (any RowSource)?) {
        self.source = source
        sourceToken?.cancel()
        sourceToken = nil
        if isActive { observeSource(); scheduleUpdate(immediate: true) }
    }

    private func observeSource() {
        sourceToken?.cancel()
        sourceToken = source?.observeRows { [weak self] event in
            switch event {
            case .selection, .changes: self?.scheduleUpdate(immediate: false)
            case .beginRename: break
            }
        }
    }

    private func deactivate() {
        pending?.cancel()
        downloadTask?.cancel()
        sourceToken?.cancel()
        sourceToken = nil
        generation += 1
        host.show(nil)
        details = nil
        render(.hidden)
    }

    private func scheduleUpdate(immediate: Bool) {
        guard isActive else { return }
        pending?.cancel()
        generation += 1
        let gen = generation
        let wait = immediate ? Duration.zero : debounce
        pending = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            await self?.update(gen)
        }
    }

    private func update(_ gen: Int) async {
        guard let source, isActive else { render(.nothing); return }
        let rows = source.selection.rows
        if rows.isEmpty { host.show(nil); details = nil; render(.nothing); return }
        if rows.count > 1 {
            host.show(nil); details = nil
            render(.multiple(rows.count, source.selectionSummary.bytes))
            return
        }
        let row = rows.first!
        let e = source.entry(atRow: row)
        let subject = PreviewSubject(url: source.url(atRow: row), kind: e.kind, typeIndex: e.typeIndex, flags: e.flags, size: e.size)
        render(.loading)
        let content = await resolve(subject)
        guard gen == generation else { return }
        await show(content, subject: subject, gen: gen)
        loadDetails(subject, content: content, gen: gen)
    }

    private func show(_ content: PreviewContent, subject: PreviewSubject, gen: Int) async {
        let env = context.environment
        switch content {
        case .nothingSelected: host.show(nil); render(.nothing)
        case .multiple(let n, let bytes): host.show(nil); render(.multiple(n, bytes))
        case .folder(let url): host.show(nil); render(.folder(url))
        case .quickLook(let url): host.show(url); render(.quickLook(url))
        case .cloudPlaceholder(let url): host.show(nil); render(.cloud(url))
        case .brokenLink(let url): host.show(nil); render(.broken(url))
        case .unavailable(let url, let code): host.show(nil); render(.unavailable(url, code))
        case .text(let url):
            textLoads += 1
            let volume = env.volumes.volume(for: url)?.id ?? .unknown
            do {
                let preview = try await TextPreviewLoader.load(url, lanes: env.lanes, volume: volume)
                guard gen == generation else { return }
                host.show(nil)
                render(.text(preview.text, truncated: preview.truncated))
            } catch .binary {
                guard gen == generation else { return }
                host.show(url); render(.quickLook(url))
            } catch .posix(let code) {
                guard gen == generation else { return }
                host.show(nil); render(.unavailable(url, code))
            }
        }
    }

    private func loadDetails(_ subject: PreviewSubject, content: PreviewContent, gen: Int) {
        switch content {
        case .nothingSelected, .multiple, .brokenLink, .unavailable: details = nil; detailsView.isHidden = true; return
        default: break
        }
        let env = context.environment
        Task { [weak self] in
            let volume = env.volumes.volume(for: subject.url)?.id ?? .unknown
            let d = await PreviewMetadata.load(subject.url, typeIndex: subject.typeIndex, types: env.types, lanes: env.lanes, volume: volume)
            guard let self, gen == self.generation else { return }
            self.details = d
            self.detailsView.show(d)
            self.detailsView.isHidden = false
        }
    }

    func performDownload() {
        let url: URL
        switch displayState {
        case .cloud(let u), .downloadFailed(let u): url = u
        default: return
        }
        let downloader = self.downloader ?? context.environment.searchServices.downloader
        let interval = downloadPollInterval
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            for await state in DownloadWatcher.download(url, using: downloader, pollInterval: interval) {
                guard let self else { return }
                switch state {
                case .downloading: self.render(.downloading(url))
                case .done: self.scheduleUpdate(immediate: true)
                case .failed, .timedOut: self.render(.downloadFailed(url))
                }
            }
        }
    }

    private func render(_ state: DisplayState) {
        displayState = state
        host.view.isHidden = { if case .quickLook = state { false } else { true } }()
        textView.isHidden = true
        messageView.isHidden = true
        switch state {
        case .hidden, .loading, .quickLook: break
        case .text(let text, let truncated): textView.show(text, truncated: truncated); textView.isHidden = false
        case .nothing: messageView.show(symbol: "eye.slash", title: L10n.string("preview.nothing")); messageView.isHidden = false
        case .multiple(let n, let bytes):
            messageView.show(symbol: "square.stack", title: String(format: L10n.string("preview.multiple"), Formatters.count(n), Formatters.size(bytes)))
            messageView.isHidden = false
        case .folder(let url): messageView.show(symbol: "folder", title: url.lastPathComponent); messageView.isHidden = false
        case .cloud: messageView.show(symbol: "icloud.and.arrow.down", title: L10n.string("preview.cloud"), button: L10n.string("preview.download")); messageView.isHidden = false
        case .downloading: messageView.show(symbol: "icloud.and.arrow.down", title: L10n.string("preview.downloading"), spinner: true); messageView.isHidden = false
        case .downloadFailed: messageView.show(symbol: "exclamationmark.icloud", title: L10n.string("preview.downloadFailed"), button: L10n.string("preview.tryAgain")); messageView.isHidden = false
        case .broken: messageView.show(symbol: "link.badge.plus", title: L10n.string("preview.broken")); messageView.isHidden = false
        case .unavailable(_, let code):
            messageView.show(symbol: "eye.trianglebadge.exclamationmark", title: L10n.string("preview.unavailable"),
                             detail: POSIXErrorCode(rawValue: code).map { POSIXError($0).localizedDescription })
            messageView.isHidden = false
        }
        if case .hidden = state { detailsView.isHidden = true }
    }

    /// Scenario probe text: "nothing", "multiple:2", "text", "quickLook", "folder", "cloud", "downloading", "broken", "unavailable", "hidden".
    var probeState: String {
        switch displayState {
        case .hidden: "hidden"
        case .nothing: "nothing"
        case .loading: "loading"
        case .multiple(let n, _): "multiple:\(n)"
        case .text: "text"
        case .quickLook: "quickLook"
        case .folder: "folder"
        case .cloud: "cloud"
        case .downloading: "downloading"
        case .downloadFailed: "downloadFailed"
        case .broken: "broken"
        case .unavailable: "unavailable"
        }
    }
    var probeText: String? { if case .text(let t, _) = displayState { String(t.prefix(200)) } else { nil } }
}
```

`Formatters.count`/`Formatters.size` are the Phase 1 helpers (S5 P1-31); use their real names if they differ. The typed `catch .binary`/`.posix` patterns work because `TextPreviewLoader.load` throws `TextPreviewError`.

- [ ] **Step 4: Implement the three views**

- `TextPreviewView` (`NSView`):
  - an `NSScrollView` with a read-only, selectable `NSTextView` (`isEditable = false`, `isRichText = false`, `usesFindBar = true`, `NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)`, `textContainerInset` 6 pt, line wrapping on, `allowsUndo = false`);
  - below it a footer label (AXID `previewTruncation`, text `L10n.string("preview.truncated")` = "Showing the first 256 KB");
  - `show(_ text:truncated:)` sets `textView.string`, scrolls to the top and toggles the footer; `footerHidden` exposes it. The text view has AXID `previewText`.
- `PreviewMessageView` (`NSView`, AXID `previewMessage`): a vertical stack with an SF Symbol image (48 pt), a wrapping centred title, an optional secondary detail, an optional `NSProgressIndicator` (spinner) and an optional push button (AXID `previewDownload`) that calls `onButton`. `show(symbol:title:detail:button:spinner:)` configures it, and every image has an accessibility description equal to the title.
- `PreviewDetailsView` (`NSView`, AXID `previewDetails`): an `NSGridView` of label/value rows. `show(_ d: PreviewDetails)` fills Kind (`kindDescription`), Size (`Formatters.size`, files only), Created/Modified (`Formatters` medium date + time), Dimensions (`"%d × %d"`), Duration (`DateComponentsFormatter`, positional, `.pad`), Pages. Rows whose value is nil are hidden. Values are selectable labels.

Localizable keys: `preview.pane` "Preview", `preview.nothing` "No item selected", `preview.multiple` "%@ items, %@", `preview.cloud` "This item is stored in iCloud", `preview.download` "Download", `preview.downloading` "Downloading…", `preview.downloadFailed` "Couldn't download this item", `preview.tryAgain` "Try Again", `preview.broken` "The original item can't be found", `preview.unavailable` "Preview unavailable", `preview.truncated` "Showing the first 256 KB", plus the detail labels `preview.details.kind/size/created/modified/dimensions/duration/pages`.

- [ ] **Step 5: Split item, wiring and commands**

`BrowserSplitViewController`:

```swift
    private(set) lazy var previewPane = PreviewPaneController(context: context)
    private(set) var previewItem: NSSplitViewItem!

    func installPreviewItem() {          // called from viewDidLoad after the sidebar and content items
        let item = NSSplitViewItem(inspectorWithViewController: previewPane)
        item.minimumThickness = 220
        item.maximumThickness = 600
        item.canCollapse = true
        item.isCollapsed = !settings.previewPaneVisible
        addSplitViewItem(item)
        previewItem = item
        previewPane.isActive = !item.isCollapsed
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !previewItem.isCollapsed { setPreviewWidth(settings.previewPaneWidth) }
    }

    func setPreviewWidth(_ width: Double) {
        let index = splitViewItems.count - 2
        splitView.setPosition(splitView.bounds.width - CGFloat(width) - splitView.dividerThickness, ofDividerAt: index)
    }

    func togglePreviewPane() {
        let show = previewItem.isCollapsed
        NSAnimationContext.runAnimationGroup { _ in previewItem.animator().isCollapsed = !show }
        settings.previewPaneVisible = show
        previewPane.isActive = show
        if show { setPreviewWidth(settings.previewPaneWidth) }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard let item = previewItem, !item.isCollapsed else { return }
        let width = Double(item.viewController.view.frame.width)
        if width >= 220, abs(width - settings.previewPaneWidth) >= 1 { settings.previewPaneWidth = width }
    }
```

`settings` is `context.environment.settings`. The Phase 1 file reserved the inspector slot; remove that placeholder.

`BrowserWindowController`: expose `var splitController: BrowserSplitViewController? { contentViewController as? BrowserSplitViewController }`. Whenever `ContentViewController.display(_:)` runs (folder changed, `.resultsChanged`), call `splitController?.previewPane.bind(source)`.

`FileCommandController`: `togglePreviewPane` → `window.splitController?.togglePreviewPane()`; `downloadForPreview` → `window.splitController?.previewPane.performDownload()`. `CommandState.previewPaneVisible = settings.previewPaneVisible`.

`MainMenuBuilder`'s View › Show Preview Pane item (P3-10) now does something. `MenuValidation` already disables it while a field editor is first responder (`collidesWithTextEditing`), which `testOptionPReachesFieldEditorWhileEditing` proves end to end.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter "UITests.PreviewPaneTests|UITests.MenuValidationTests|UITests.BrowserSessionTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures` (the two window tests skip without a GUI session).

- [ ] **Step 7: Manual visual check (sandbox only)**

Using the Step 9 sandbox recipe from P3-10, add a 300 KB text file, a PNG and a folder to `$SBX/root`. Then:
- press ⌥P: the pane appears;
- select the text file: the text shows with the 256 KB footer;
- select the PNG: Quick Look renders it and the grid shows its dimensions;
- select the folder: the folder message shows;
- select two items: "2 items, …";
- ⌘L then ⌥P: types "π" and the pane stays.

Quit and `rm -rf "$SBX"`.

- [ ] **Step 8: Build and commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`; `scripts/check-layering.sh && echo LAYERING-OK` → `LAYERING-OK` (QuickLookUI imported only in `Sources/UI`).

```bash
git add Sources/UI Tests/UITests/PreviewPaneTests.swift
git commit -m "feat: preview pane with Quick Look, 256 KB text preview, details and cloud download"
```

---

### Task P3-13: Validation: launch options, scenarios, benchmarks, docs, full run

**Files:**
- Modify: `Sources/Core/Support/LaunchOptions.swift` (`--index-status`), `Sources/Core/Support/CoreEnvironment.swift` (`sandboxed(root:searchServices:)`), `Sources/App/AppBootstrap.swift`, `Sources/UI/Scenario/ScenarioFile.swift`, `Sources/UI/Scenario/ScenarioDriver.swift`, `Sources/UI/Scenario/ScenarioProbe.swift`, `Sources/UI/Window/BrowserWindowController.swift` (probe conformance), `scripts/ui-scenarios.sh` (per-file `indexStatus`), `scripts/check-layering.sh`, `Sources/macx-scenarios/Scenarios/Catalog.swift` (register the family), `Tests/ScenarioRunnerTests/CatalogTests.swift` (families), `Sources/macx-bench/Metrics.swift` (register), `Sources/macx-bench/Budgets.swift`, `README.md`
- Create: `Sources/macx-scenarios/Scenarios/SearchScenarios.swift`, `Sources/macx-bench/SearchMetrics.swift`, `Tests/Scenarios/search-*.json` and `Tests/Scenarios/preview-*.json` (listed in Step 5)
- Test: `Tests/CoreTests/LaunchOptionsTests.swift` (extend), `Tests/UITests/ScenarioSchemaTests.swift` (extend, P2-03 file), `Tests/ScenarioRunnerTests/CatalogTests.swift`

**Interfaces:**
- Consumes: everything in Phase 3; `LaunchOptions`, `LaunchOptionsError`, `CoreEnvironment.sandboxed`, `ScenarioFile`, `ScenarioDriver`, `ScenarioProbe`, `ScenarioHooks`, `CoreScenario`, `ScenarioContext`, `Catalog`, `BenchOptions`, `MetricResult`, `Budgets` (Phase 1 S6, Phase 2 P2-03/P2-20); `FixtureTree.flat/deep`, `Sandbox`, `DiskImage` (P1-02).
- Produces: `LaunchOptions.indexStatus: IndexingStatus?`, `LaunchOptionsError.invalidValue(option: String, value: String)`, `CoreEnvironment.sandboxed(root:searchServices:)`; scenario schema additions (below); probes `probeSearchState`, `probePreviewState`, `probeSidebarSearches`, `probeRowPaths`; the `search.*` Core scenario family; bench metrics `search-filter-100k`, `search-parse-10k`, `search-crawl-first-result`, `search-crawl-complete`, `search-results-ingest-100k` and the budget `search-filter-100k < 30 ms`; README "Search & Preview"; the Phase 3 "working" verification.

**Scenario schema additions (all optional):**

```swift
// ScenarioFile gains (top level):
//   indexStatus: String?            // "enabled" | "disabled" | "unknown"; ui-scenarios.sh passes it as --index-status (default disabled)
// ScenarioFile.Fixture gains:
//   contents: [String: String]?     // file → UTF-8 text (created, parents made)
//   binary: [String: Int]?          // file → N deterministic bytes (SplitMix64 seed 0x6D6163), never valid text
//   bulk: [String: Int]?            // dir → N files "file-000001.txt"… via FixtureTree.flat
//   spotlight: [SpotlightFixture]?  // items the fake Spotlight returns for every query (driver calls FakeMetadataQuery.setRuns)
struct SpotlightFixture: Codable { var path: String; var kind: String?; var size: Int? }   // path relative to root; kind "file"|"folder"|"app"
// ScenarioFile.Step gains (still exactly one action per step):
//   clickSidebar: String?           // "<section>:<name>", e.g. "searches:Taxes", "favorites:Home"
//   setSearchScope: String?         // "thisFolder" | "subfolders" | "thisMac" (same as the View › Search menu)
// ScenarioFile.Expectation gains:
//   searchState: String?            // "none" | "searching" | "complete" | "stopped" | "failed"
//   resultCount: Int?
//   rowPaths: [String]?             // per row, parent folder relative to root ("" = root), display order
//   notices: [String]?              // exact list: "contentsNotIndexed", "spotlightOff", "truncated", "skippedLocations",
//                                   //   "mayNotBeIndexed", "diagnostic:<token>"
//   previewState: String?           // PreviewPaneController.probeState; "hidden" = pane collapsed (probe returns nil)
//   previewTextPrefix: String?
//   sidebarSearches: [String]?
```

Probes (`ScenarioProbe` additions, implemented by `BrowserWindowController`):
- `probeSearchState: String?`: nil without results, else the state name.
- `probePreviewState: String?`: nil when the pane is collapsed.
- `probeSidebarSearches: [String]`.
- `probeRowPaths: [String]`.
- Existing `probeRowNames` work for results unchanged (they read the active `RowSource`), and `addressText` shows "Search Results in “root”".

- [ ] **Step 1: Write the failing launch-option and schema tests**

Append to `Tests/CoreTests/LaunchOptionsTests.swift`:

```swift
    func testIndexStatusOption() throws {
        let o = try LaunchOptions.parse(["macExplorer", "--root", "/tmp/macx-scenario-x", "--state-dir", "/tmp/macx-scenario-x/state",
                                         "--index-status", "enabled"])
        XCTAssertEqual(o.indexStatus, .enabled)
        XCTAssertNil(try LaunchOptions.parse(["macExplorer"]).indexStatus)
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--index-status", "maybe"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .invalidValue(option: "--index-status", value: "maybe"))
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--index-status"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .missingValue("--index-status"))
        }
    }
```

(Use the argument-vector convention the existing `LaunchOptionsTests` use: if `parse` expects arguments without the executable name, drop the first element.)

Append to `Tests/UITests/ScenarioSchemaTests.swift`:

```swift
    func testPhase3SchemaDecodes() throws {
        let json = #"""
        {"name": "x", "indexStatus": "enabled",
         "fixture": {"files": [], "dirs": [], "contents": {"a.txt": "hi"}, "binary": {"b.bin": 64}, "bulk": {"many": 10},
                     "spotlight": [{"path": "a.txt"}, {"path": "Apps/X.app", "kind": "app"}]},
         "steps": [{"clickSidebar": "searches:Taxes"}, {"setSearchScope": "subfolders"},
                   {"expect": {"searchState": "complete", "resultCount": 2, "rowPaths": ["", "sub"], "notices": ["spotlightOff"],
                               "previewState": "text", "previewTextPrefix": "hi", "sidebarSearches": ["Taxes"]}}]}
        """#
        let file = try JSONDecoder().decode(ScenarioFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.indexStatus, "enabled")
        XCTAssertEqual(file.fixture.spotlight?.count, 2)
        XCTAssertEqual(file.steps[0].clickSidebar, "searches:Taxes")
        XCTAssertEqual(file.steps[2].expect?.rowPaths, ["", "sub"])
        XCTAssertNoThrow(try ScenarioDriver.validate(file))      // exactly one action per step (P1-41 validator)
    }

    func testEveryPhase3ScenarioFileExists() throws {
        let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Scenarios")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)))
        for n in ["search-this-folder-instant", "search-subfolders-crawl", "search-syntax-filters", "search-open-containing-folder",
                  "search-folder-result-back", "search-stop", "search-saved-sidebar", "search-saved-del-keeps-files",
                  "search-results-trash", "search-contents-not-indexed", "search-this-mac-fake-spotlight",
                  "preview-text", "preview-folder-multiple", "preview-optp-in-field"] {
            XCTAssertTrue(names.contains(n + ".json"), n)
        }
    }
```

If P1-41 named its "exactly one action" validator differently, call that one.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "CoreTests.LaunchOptionsTests|UITests.ScenarioSchemaTests" 2>&1 | tail -5`
Expected: build FAIL with `value of type 'LaunchOptions' has no member 'indexStatus'`.

- [ ] **Step 3: Launch option, sandboxed services, bootstrap**

- `LaunchOptions`: `public var indexStatus: IndexingStatus? = nil`. `parse` handles `--index-status <v>`: missing → `.missingValue`; not an `IndexingStatus` raw value → `.invalidValue(option:value:)`. `main.swift` prints the new error like the others (usage, exit 64).
- `CoreEnvironment.sandboxed(root:)` becomes `sandboxed(root: URL, searchServices: SearchServices = .fake())`; existing calls compile unchanged.
- `AppBootstrap`: in sandbox mode (`options.isSandboxed`), `searchServices: .fake(indexing: options.indexStatus ?? .disabled)`. A sandboxed app run never queries the real Spotlight index or downloads anything. Outside sandbox mode, `.system(lanes:)`.
- `scripts/ui-scenarios.sh`: for each scenario file, `status=$(/usr/bin/plutil -extract indexStatus raw -o - "$file" 2>/dev/null || echo disabled)` and add `--index-status "$status"` to the launch arguments.

- [ ] **Step 4: Driver steps, fixture kinds and probes**

`ScenarioFile` gets the fields above (all optional, so Phase 1/2 files decode unchanged). `ScenarioDriver`:
- Fixture creation (inside `--root`, through the guarded writer the driver already uses):
  - `contents` → files with that text;
  - `binary` → deterministic bytes, generated as `(0..<n).map { UInt8(truncatingIfNeeded: splitmix(&seed)) | 0x80 }` with byte 0 forced to 0x00 (so the result is never text);
  - `bulk` → `FixtureTree.flat(in: sandbox, at: dir, count: n)`;
  - `spotlight` → `MetadataItem`s with absolute paths under `--root`, `contentTypeTree` per kind (file: `public.data` + the extension's UTType identifier and its supertypes; folder: `public.folder`, `public.directory`; app: `com.apple.application-bundle`, `com.apple.package`, `public.directory`), `size` (default 1), `modified`/`created` = now. Install them with `(context.environment.searchServices.metadataQuery as? FakeMetadataQuery)?.setRuns([[.init(.added(items)), .init(.gatheringFinished)]])`. Refuse the file (passed=false, message) if the app is not using the fake.
- `clickSidebar` → `SidebarViewController.activateRow(row(for: section, name), newTab: false)` after selecting the row (P3-11 helper); unknown section or name fails the step.
- `setSearchScope` → `performMenu(["View", "Search", <title>])` (`This Folder`/`Subfolders`/`This Mac`), so it exercises the real menu path.
- Expectations: compare each new field with its probe. `notices` are rendered as the kind names listed above, in this order: diagnostics first, then plan/model notices.
- `ScenarioProbe` gains the four probes. `BrowserWindowController` implements them from `session.results`, `splitController?.previewPane`, the sidebar and the active list's `source.parentURL(atRow:)` (relative to the root via `ScenarioDriver.relativePath(_:roots:)`).

- [ ] **Step 5: UI scenario files**

Create these files in `Tests/Scenarios/`. Each uses only its own fixture inside the runner's `macx-scenario-*` root:

| File | What it proves |
|---|---|
| `search-this-folder-instant.json` | ⌘F, type `tax`: rows filter at once to the matching names; `*.pdf` glob filters; Esc clears and every row returns |
| `search-subfolders-crawl.json` | type `needle`, `setSearchScope: subfolders`: `rowsContain` nested matches, `rowPaths` show their folders, `searchState: complete`, address text "Search Results in “<root>”" |
| `search-syntax-filters.json` | `kind:pdf size:>1KB` on a fixture with `sizes`; then `size:big` → `notices: ["diagnostic:size:big"]` |
| `search-open-containing-folder.json` | select a nested result, ⌥⌘R → `folder: "a/b"`, `selection: [the file]`; ⌘[ → results again with the same `rows` |
| `search-folder-result-back.json` | double-click a folder result → `folder` is that folder; ⌘[ → `searchState: complete`, same rows |
| `search-stop.json` | `bulk` 20 dirs × 1,000 files, search `file` in Subfolders, View › Search › Stop Search right away → `searchState: stopped` |
| `search-saved-sidebar.json` | File › Save Search…, `type: "Needles"`, `answerAlert: "OK"` → `sidebarSearches: ["Needles"]`; navigate away; `clickSidebar: "searches:Needles"` → results again |
| `search-saved-del-keeps-files.json` | select the saved search in the sidebar, press `fn+delete` → `sidebarSearches: []` and `filesExist` lists every fixture file |
| `search-results-trash.json` | Review Focus 3, full file below |
| `search-contents-not-indexed.json` | (`indexStatus` disabled) View › Search › Contents, type `invoice` in Subfolders → `notices: ["contentsNotIndexed"]` and name matches shown |
| `search-this-mac-fake-spotlight.json` | `indexStatus: "enabled"`, `spotlight` fixture items; This Mac search `report` → exactly the fixture items matching `report` (post-filter applied), `rowPaths` correct |
| `preview-text.json` | `contents` file + 300 KB `sizes` file; ⌥P → `previewState: "nothing"`; click small → `previewState: "text"`, `previewTextPrefix`; click big → `text`; ⌥P again → `previewState: "hidden"` |
| `preview-folder-multiple.json` | ⌥P; click a folder → `folder`; ⌘-click two files → `multiple:2`; click a `binary` file with unknown extension → `quickLook` |
| `preview-optp-in-field.json` | Review Focus 2, full file below |

```json
{"name": "search-results-trash",
 "fixture": {"files": ["a/needle-1.txt", "b/needle-2.txt", "b/needle-3.txt", "keep.txt"], "dirs": []},
 "steps": [
   {"key": "cmd+f"}, {"type": "needle"}, {"setSearchScope": "subfolders"},
   {"waitFor": {"searchState": "complete", "resultCount": 3}, "timeoutMs": 5000},
   {"click": "needle-2.txt"}, {"key": "cmd+delete"},
   {"waitFor": {"rows": ["needle-1.txt", "needle-3.txt"]}, "timeoutMs": 3000},
   {"expect": {"filesAbsent": ["b/needle-2.txt"], "filesExist": ["a/needle-1.txt", "b/needle-3.txt", "keep.txt"], "searchState": "complete"}},
   {"click": "needle-3.txt"}, {"key": "F2"}, {"type": "renamed-3.txt"}, {"key": "return"},
   {"waitFor": {"rows": ["needle-1.txt", "renamed-3.txt"]}, "timeoutMs": 3000},
   {"expect": {"filesExist": ["b/renamed-3.txt"], "rowPaths": ["a", "b"], "selection": ["renamed-3.txt"]}}
 ]}
```

```json
{"name": "preview-optp-in-field",
 "fixture": {"files": ["a.txt"], "dirs": []},
 "steps": [
   {"expect": {"previewState": "hidden"}},
   {"key": "cmd+l"}, {"waitFor": {"focus": "addressBar"}},
   {"key": "opt+p"},
   {"expect": {"fieldEditorText": "π"}},
   {"expect": {"previewState": "hidden"}},
   {"key": "esc"}, {"click": "a.txt"}, {"key": "opt+p"},
   {"waitFor": {"previewState": "text"}, "timeoutMs": 2000}
 ]}
```

The ⌘L + `opt+p` step sends a real ⌥P keyDown with characters "π" (the driver's key synthesis from P1-41/P2-03 applies the option modifier to the character), so the field editor receives the character exactly as on a US keyboard.

- [ ] **Step 6: Core scenario family `search.*`**

```swift
// Sources/macx-scenarios/Scenarios/SearchScenarios.swift
import Darwin
import Foundation
import Core
import MacxFS

enum SearchScenarios {
    @MainActor
    static func run(_ ctx: ScenarioContext, _ spec: SearchSpec, timeout: Duration = .seconds(30)) async throws -> SearchResultsModel {
        let plan = await ctx.env.planSearch(spec)
        let model = ctx.env.makeSearchResults(spec, plan: plan)
        model.start()
        try await ctx.waitUntil("search finishes", timeout: timeout) {
            switch model.state { case .searching: false; default: true }
        }
        return model
    }
    @MainActor static func names(_ m: SearchResultsModel) -> Set<String> { Set((0..<m.rowCount).map { m.name(atRow: $0) }) }

    static let all: [CoreScenario] = [
        CoreScenario("search.crawlFindsNested") { ctx in
            ctx.file("needle-top.txt"); ctx.file("a/b/c/needle-deep.txt"); ctx.file("a/other.txt")
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            try ctx.expectEqual(names(m), ["needle-top.txt", "needle-deep.txt"], "nested matches")
        },
        CoreScenario("search.crawlSkipsPackagesAndHidden") { ctx in
            ctx.file("X.app/Contents/needle-pkg.txt"); ctx.file(".hidden/needle-dot.txt"); ctx.file("needle.txt")
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            try ctx.expectEqual(names(m), ["needle.txt"], "packages and hidden folders are skipped by default")
            ctx.env.settings.searchIncludesPackages = true
            m.rerun()
            try await ctx.waitUntil("rerun") { if case .complete = m.state { m.rowCount == 2 } else { false } }
        },
        CoreScenario("search.crawlSymlinkLoopTerminates") { ctx in
            ctx.file("t/a/needle.txt")
            try ctx.symlink("t/a/loop", to: "..")
            try ctx.symlink("t/self", to: ".")
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work), timeout: .seconds(10))
            defer { m.close() }
            try ctx.expectEqual(m.rowCount, 1, "one match, crawl terminated")
        },
        CoreScenario("search.crawlUnreadableContinues") { ctx in
            ctx.file("locked/needle-a.txt"); ctx.file("open/needle-b.txt")
            try ctx.setMode(ctx.path("locked"), 0o000)
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            try ctx.setMode(ctx.path("locked"), 0o755)
            try ctx.expectEqual(names(m), ["needle-b.txt"], "unreadable folder skipped")
            try ctx.expectEqual(m.notices, [.skippedLocations(count: 1)], "skipped notice")
        },
        CoreScenario("search.syntaxAndFilters") { ctx in
            ctx.file("big.pdf", bytes: 5_000); ctx.file("small.pdf", bytes: 10); ctx.file("big.txt", bytes: 5_000)
            try ctx.setModificationDate(ctx.file("old.pdf", bytes: 5_000), Date(timeIntervalSinceNow: -400 * 86_400))
            let m = try await run(ctx, SearchSpec(text: "kind:pdf size:>1KB modified:thisyear", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            try ctx.expectEqual(names(m), ["big.pdf"], "kind, size and date filters")
        },
        CoreScenario("search.cancelStopsCrawl") { ctx in
            for i in 0..<20 { ctx.flat("bulk/d\(i)", count: 1_000) }
            let spec = SearchSpec(text: "file", scope: .subfolders, root: ctx.work)
            let plan = await ctx.env.planSearch(spec)
            let m = ctx.env.makeSearchResults(spec, plan: plan)
            defer { m.close() }
            m.start()
            try await ctx.waitUntil("first rows") { m.rowCount > 0 }
            m.stop()
            let count = m.rowCount
            try await Task.sleep(for: .milliseconds(300))
            guard case .stopped = m.state else { throw ScenarioFailure("state \(m.state)") }
            try ctx.expectEqual(m.rowCount <= count + 2_000, true, "at most one in-flight batch lands after Stop")
        },
        CoreScenario("search.resultsFollowFileOps") { ctx in
            ctx.file("a/needle-1.txt"); ctx.file("b/needle-2.txt"); ctx.file("b/needle-3.txt")
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            _ = await ctx.env.operations.perform(JobRequest(.trash([ctx.path("b/needle-2.txt")])))
            _ = await ctx.env.operations.perform(JobRequest(.rename(ctx.path("b/needle-3.txt"), to: "renamed-3.txt")))
            try await ctx.waitUntil("results follow") { names(m) == ["needle-1.txt", "renamed-3.txt"] }
            try ctx.expectEqual(ctx.exists(ctx.path("b/renamed-3.txt")), true, "renamed on disk")
        },
        CoreScenario("search.savedSearchRoundTrip") { ctx in
            let storage = FileSettingsStorage(fileURL: ctx.path("settings.json"))
            let s = Settings(storage: storage)
            let spec = SearchSpec(text: "tax kind:pdf", scope: .subfolders, filters: SearchFilters(modified: .relative(.lastMonth)), root: ctx.work)
            s.addSavedSearch(name: "Taxes", spec: spec)
            let reloaded = Settings(storage: FileSettingsStorage(fileURL: ctx.path("settings.json")))
            try ctx.expectEqual(reloaded.savedSearches.map(\.spec), [spec], "saved search survives a reload")
            try ctx.expectEqual(SearchSpec(url: spec.url), spec, "history URL round-trip")
        },
        CoreScenario("search.crawlDoesNotCrossImage", requires: .diskImages) { ctx in
            let image = try ctx.image(.apfs, sizeMB: 16)
            ctx.file(at: image.mountPoint.appending(path: "needle-in-image.txt"))
            ctx.file("needle-here.txt")
            await ctx.env.volumes.refresh()
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            try ctx.expectEqual(names(m), ["needle-here.txt"], "mount points are not crossed")
        },
    ]
}
```

Notes:
- `ctx.image(_:sizeMB:)` is the P1-40 disk-image helper (it mounts inside the scenario sandbox). If the image's mount point is not under `ctx.work`, create it there with that helper's path argument, or point the search root at the sandbox root instead.
- If `ScenarioContext` does not start `env.operations`, call `await ctx.env.start()` once at the top of `search.resultsFollowFileOps`.
- Register `SearchScenarios.all` in `Catalog.all`.
- In `CatalogTests.testEveryFamilyIsPresent`, add `"search"` to the expected set.

- [ ] **Step 7: Bench metrics**

```swift
// Sources/macx-bench/SearchMetrics.swift
import Foundation
import Core
import MacxFS
import MacxFixtures

/// Phase 3 search metrics. Everything lives in the bench's own macx-bench-<UUID> sandbox.
@MainActor
enum SearchMetrics {
    static func run(_ options: BenchOptions, sandbox: Sandbox, store100k: EntryStore, log: (String) -> Void) async throws -> [MetricResult] {
        var out: [MetricResult] = []
        let types = TypeRegistry.shared
        let keys = SortKeys.nameKeys(store100k, range: 0..<store100k.count)
        let search = SortKeys.searchKeys(store100k)
        let query = ViewQuery(criteria: SearchCriteria(nameTerms: [NameTerm("*7*.txt")], size: ByteRange(lower: 0)))
        out.append(try Stats.measure("search-filter-100k", size: 100_000, options) {
            _ = Sorter.permutation(store100k, nameKeys: keys, searchKeys: search, query: query,
                                   kindRanks: types.kindRanks().ranks, types: types)
        })
        let queries = (0..<10_000).map { i in "report\(i) kind:pdf,image ext:jpg size:>\(i)KB modified:2026-01-\(1 + i % 28) \"two words\"" }
        out.append(try Stats.measure("search-parse-10k", size: 10_000, options) { for q in queries { _ = QuerySyntax.parse(q) } })

        let tree = try FixtureTree.deep(in: sandbox, at: "search-tree", depth: 4, breadth: 8, filesPerDir: 20)
        let lanes = LanePool()
        let mounts = MountTableStore()
        out.append(try await Stats.measureAsync("search-crawl-first-result", size: 90_000, options) {
            for await e in SubtreeCrawler.crawl(root: tree, criteria: SearchCriteria(nameTerms: [NameTerm("file")]), options: CrawlOptions(),
                                                permissions: .none, generation: .initial.next(), lanes: lanes, mountTable: mounts) {
                if case .batch = e { break }
            }
        })
        out.append(try await Stats.measureAsync("search-crawl-complete", size: 90_000, options) {
            for await e in SubtreeCrawler.crawl(root: tree, criteria: SearchCriteria(nameTerms: [NameTerm("zzz-no-match")]), options: CrawlOptions(),
                                                permissions: .none, generation: .initial.next(), lanes: lanes, mountTable: mounts) {
                if case .completed = e { break }
            }
        })
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        out.append(try await Stats.measureAsync("search-results-ingest-100k", size: 100_000, options) {
            let model = SearchResultsModel(title: "bench", events: { g in batches(store100k, g) }, context: {
                var c = env.searchContext(); c.pacer = ImmediatePacer(); return c }())
            model.start()
            while true { if case .complete = model.state { break }; await Task.yield() }
            model.close()
        })
        return out
    }

    /// 50 batches of 2,000 from the 100k store, all under one fake parent (never touched).
    static func batches(_ store: EntryStore, _ g: Generation) -> AsyncStream<SearchEvent> {
        AsyncStream { c in
            var b = Batch(generation: g)
            for i in 0..<UInt32(store.count) {
                store.withNameBytes(i) { b.append(store.entry(i), nameBytes: $0) }
                if b.count == 2_000 {
                    c.yield(.batch(SearchBatch(parent: URL(filePath: "/macx-bench-virtual", directoryHint: .isDirectory), batch: b)))
                    b = Batch(generation: g)
                }
            }
            if b.count > 0 { c.yield(.batch(SearchBatch(parent: URL(filePath: "/macx-bench-virtual", directoryHint: .isDirectory), batch: b))) }
            c.yield(.completed(SearchSummary(resultCount: store.count)))
            c.finish()
        }
    }
}

struct ImmediatePacer: FramePacer { func nextFrame() async { await Task.yield() } }
```

`Stats.measure`/`measureAsync` stand for the P1-39 warm-up + 5-iteration helpers (use their real names; add an `async` variant beside the sync one if P1-39 has only sync). `store100k` is the 100k store the `resort` metric already builds. Register the five metrics under the `search-` prefix so `--filter search-` selects them. In `Budgets.swift`, add `search-filter-100k: 30 ms` (median, `--check-budgets`); the others are reported only.

Run:
```bash
swift run -c release macx-bench --filter search- 2>&1 | tail -20
```
Expected: JSON with `median_ms`/`p90_ms` for the five metrics, `search-filter-100k` under 30 on Apple Silicon. If it isn't, profile `CriteriaMatcher.matches` (`xcrun xctrace record --template 'Time Profiler' --launch -- .build/release/macx-bench --filter search-filter-100k`); the usual fix is hoisting the glob's first literal into a `memchr` pre-check. Do not raise the budget.

- [ ] **Step 8: Layering and safety checks**

Append to `scripts/check-layering.sh`:

```bash
if grep -rn 'NSMetadataQuery\b' Sources --include='*.swift' | grep -v '^Sources/Core/Search/SystemMetadataQuery.swift:'; then
  echo "error: NSMetadataQuery only in Core/Search/SystemMetadataQuery.swift (private OperationQueue)"; exit 1
fi
if grep -rn 'startDownloadingUbiquitousItem' Sources Tests --include='*.swift' | grep -v '^Sources/Core/Preview/Ubiquitous.swift:'; then
  echo "error: real iCloud downloads only through SystemUbiquitousDownloader"; exit 1
fi
if grep -rn 'SystemUbiquitousDownloader\|SystemMetadataQuery' Tests --include='*.swift' | grep -v '^Tests/CoreTests/Search/LiveSpotlightTests.swift:'; then
  echo "error: tests use the fakes (LiveSpotlightTests is the only read-only exception)"; exit 1
fi
if grep -rnE 'mdimport|mdutil[^"]*-(i|E|X)\b|"-(i|E|X)"' Sources Tests scripts --include='*.swift' --include='*.sh' | grep -i mdutil; then
  echo "error: never change Spotlight index state (only mdutil -s)"; exit 1
fi
if grep -rnE '^\s*import (QuickLookUI|Quartz)\b' Sources/FSKit Sources/Core; then
  echo "error: QuickLookUI is UI-only"; exit 1
fi
```

Run: `scripts/check-layering.sh && echo LAYERING-OK`
Expected: `LAYERING-OK`.

- [ ] **Step 9: README**

Add a "Search & Preview (Phase 3)" section:
- the scope chips and Name/Contents, with which engine runs when (the P3-06 routing table in prose);
- the syntax table from P3-02 (with decimal size units and the `KiB` family);
- filters and saved searches (sidebar SEARCHES; Del removes only the saved search);
- Open Containing Folder ⌥⌘R; Stop; the 100,000-result cap;
- the preview pane ⌥P, the 256 KB text preview, the details grid and the iCloud "Download" button.
- Spotlight notes: Contents and This Mac need Spotlight indexing (`mdutil -s /` shows the state). Volumes that aren't indexed fall back to name search with a notice. Protected folders (Desktop, Documents, Downloads, iCloud Drive without a recorded grant, app data under `~/Library`) are skipped by Subfolders search without prompting, and are counted in "N folders were skipped".

Add to the release checklist (human-only items):
- In a real iCloud Drive folder with an evicted file, select it with the pane open: the pane shows "Download" and Activity Monitor › Network shows no download until you click it; clicking downloads and then previews it. (Automated tests never do this.)
- A This Mac search against the real index finds a known app and a known document by content.
- Quick Look renders an image, a PDF, a movie and a Pages file in the pane.
- VoiceOver reads the scope chips, the Name/Contents toggle, Stop, the notices, and the pane's states.
- Subfolders search of `~` shows the skipped-locations notice and no TCC prompt appears.

- [ ] **Step 10: Full verification run (Phase 3 "working" definition)**

```bash
ls -d "${TMPDIR}"macx-* 2>/dev/null | sort > /tmp/macx-before.txt || true
swift build -c release 2>&1 | tail -3
swift test --parallel 2>&1 | tail -3
scripts/check-layering.sh && echo LAYERING-OK
scripts/run-scenarios.sh 2>&1 | tail -5
scripts/ui-scenarios.sh 2>&1 | tail -5
swift run -c release macx-bench --filter search- --check-budgets 2>&1 | tail -8
ls -d "${TMPDIR}"macx-* 2>/dev/null | sort > /tmp/macx-after.txt || true
comm -13 /tmp/macx-before.txt /tmp/macx-after.txt
git status --short
```

Expected:
- `Build complete!`; `0 failures` (live Spotlight tests may be `skipped`); `LAYERING-OK`.
- Both scenario runners report every Phase 1, 2 and 3 scenario passed, `search.*` included.
- Bench JSON within budget.
- `comm` prints nothing: no sandbox left behind. The `/tmp/macx-before.txt`/`after.txt` lists are the only files this step writes outside a sandbox; delete them afterwards with `rm /tmp/macx-before.txt /tmp/macx-after.txt`.
- `git status` shows only intended source changes.

Then the manual pass of working-definition item 3 in a sandboxed app run (P3-10 Step 9 recipe): instant filter, Subfolders with Path column, folder result + ⌘[, Open Containing Folder, filters and syntax, Stop, saved search under SEARCHES, ⌥P previews.

- [ ] **Step 11: Commit**

```bash
git add Sources/Core/Support Sources/App/AppBootstrap.swift Sources/UI/Scenario Sources/UI/Window/BrowserWindowController.swift Sources/macx-scenarios Sources/macx-bench scripts README.md Tests/Scenarios Tests/CoreTests/LaunchOptionsTests.swift Tests/UITests/ScenarioSchemaTests.swift Tests/ScenarioRunnerTests/CatalogTests.swift
git commit -m "test: phase 3 scenarios, search benchmarks, layering checks and docs"
```

---

## Spec coverage (§11 Phase 3 → tasks)

| Spec item | Tasks |
|---|---|
| Inspector split item, toggle ⌥P | P3-07 (command, key, collision), P3-12 (split item, persistence), P3-13 (`preview-optp-in-field`) |
| `QLPreviewView` of the selection | P3-08 (`PreviewPlanner`), P3-12 (`QLPreviewViewHost`) |
| Fast text preview of the first 256 KB | P3-08 (`TextPreviewLoader`), P3-12 (`TextPreviewView`, footer) |
| Details summary (size, dates, dimensions/duration from `MDItem`) | P3-08 (`PreviewMetadata`), P3-12 (`PreviewDetailsView`) |
| No preview from dataless iCloud files unless "Download" | P3-08 (resolve before read, `DownloadWatcher`), P3-12 (button), P3-13 (human checklist, layering guard) |
| Scope chips This folder / Subfolders / This Mac; Name / Contents toggle | P3-02 (`SearchSpec`), P3-06 (routing), P3-10 (`SearchScopeBar`, menus) |
| This Mac and Contents use `NSMetadataQuery`, streamed | P3-05 (`SystemMetadataQuery`, `SpotlightSearch`), P3-06 |
| Subfolders by name: own parallel crawler, materialization policy, packages skipped | P3-04, P3-07 (`searchIncludesPackages`) |
| Results in Details with a Path column | P3-09 |
| Open containing folder; cancellable | P3-07 (⌥⌘R), P3-10 (session, menus, Stop), P3-06 (`stop`) |
| Filters: kind, modified/created ranges, size ranges, extension | P3-01 (matching), P3-02 (`SearchFilters`), P3-10 (`SearchFiltersView`) |
| Saved searches in a sidebar SEARCHES section | P3-07 (Settings), P3-11 |
| Syntax `name:`, `kind:`, `ext:`, `size:>10MB`, `modified:today` | P3-02 |

## Contract notes

Gaps or deviations found while writing P3-03 … P3-13. The interface block above already includes the additive ones; the rest need the architect's attention.

1. **`MacxFixtures` spellings.** The Prerequisites line now uses P1-02's real API (`Sandbox()`, `createFile(_:contents:)`, `createDirectory`, `createSymlink(_:target:)`, `setMode`, `destroy()`), not the guessed `Sandbox.create/writeFile/remove`.
2. **Public inits added:** `SearchProgress`, `SearchSummary`, `SkippedLocation`, `SearchPlan` (`init(engine:notices:diagnostics:)`), `PreviewDetails` (memberwise with defaults), `TextPreview`. Without them, Core types could not be built from other modules (UITests, `macx-bench`).
3. **`SearchResultStore.nameKeys`** (public, read-only) is added: the results model needs aligned sort keys, and keeping them inside the store is the only way to stay aligned through compaction.
4. **`UbiquitousDownloading` and its two implementations move from P3-08 to P3-06**, because `SearchServices` (P3-06) stores a downloader. P3-08 only adds `DownloadWatcher` (overview §5 rule: move types to the earlier task).
5. **`ChangeBus.observeAll` already exists** (Phase 2 P2-13). P3-03 only tests it.
6. **Test file name clash:** Phase 2 owns `Tests/CoreTests/SettingsV2Tests.swift`, so P3-07 uses `SettingsV3Tests.swift`. Phase 2's `testSchemaVersionIsTwo` must become `>= 2`.
7. **New Core API beyond the interface block:** `CoreEnvironment.planSearch(_:)`, `CoreEnvironment.sandboxed(root:searchServices:)` (default `.fake()`, source-compatible), `CrawlPermissions.make(home:outcome:)`, `LaunchOptions.indexStatus`, `LaunchOptionsError.invalidValue(option:value:)` (a new case: update `main.swift`'s error printing), `Settings.defaultResultsColumns`.
8. **New UI API beyond the interface block:** `BrowserSession.lastPlan`, `BrowserSession.openSavedSearch(_:)`, `CommandTarget.savedSearch(SavedSearch)`, `NamePrompting`/`SheetNamePrompter`/`UIContext.namePrompter`, `PreviewPaneController.DisplayState`/`probeState`, `BrowserSplitViewController.togglePreviewPane()`/`previewPane`/`previewItem`, `DetailsViewController.sort(by:)`, `SidebarViewController.activateRow(_:newTab:)`/`moveSavedSearch(id:to:)`/`sectionHeaders`.
9. **Bench flag:** the working definition now says `--filter search-` (Phase 2 P2-20's flag) instead of `--only search`. If P1-39 named the flag differently, use that.
10. **Sandboxed app runs never touch the real Spotlight index or iCloud.** `AppBootstrap` uses `SearchServices.fake(indexing: --index-status)` whenever `--state-dir` is present. Scenario Spotlight results come from the fixture (`FakeMetadataQuery.setRuns`), so This Mac and Contents are proven in UI scenarios with the fake, and against the real index only by read-only `LiveSpotlightTests` and the human checklist.
11. **Phase 1 Search field filter is replaced** by This folder + Name criteria (`ViewQuery.criteria`). `ViewQuery.filter` stays for compatibility but the UI no longer sets it. Phase 1 UI scenarios that type into the search field still pass, because substring semantics are identical.
12. **Results rows never live-follow new files.** Local `added`/`modified` names do not join results (Explorer behaviour); removals and renames do (Review Focus 3). Results under a renamed folder are dropped, not re-pathed.
13. **`SidebarSection` gains `.searches` between `.favorites` and `.locations`.** The raw values of existing cases are unchanged, so stored `collapsedSections` still decode.
14. **Scenario schema:** the task index's "clickSidebar" exists as a step. P2-03's click-target grammar (`tree:`/`group:`/`header:`) is not reused for the sidebar, to keep that grammar list-only.
15. **Search result path forms (P3-01..04 review).** `SearchResultStore` normalizes lexically only (never `standardizedFileURL`, which stats the path and drops `/private` only when it exists). `SearchBatch.parent`, `remove(paths:)`, `rename(path:)` and `index(ofPath:)` accept either `/private/var/…` or `/var/…` (and `.`/`..`/trailing-slash variants); lookups compare `MountTable.standardize` keys, while shown paths, URLs and `RowID.name` identities keep the first batch's spelling for each folder. P3-05/P3-06 may pass paths in whatever spelling their source (crawler root, Spotlight, `ChangeBus`) uses.
16. **Crawler name matching vs the in-folder filter.** `SubtreeCrawler` matches name terms against the on-disk name and the Finder display name (hidden extension per file flag or `.app`, controlled by the new `CrawlOptions.showAllExtensions`, which P3-06 sets from Settings), like `Sorter.matches`. Localized folder names are not available without materializing metadata, so a term that only matches a localized name finds the folder under This folder but not under Subfolders: an accepted engine difference that P3-06/P3-10 tests must not assume away.
17. **`SkipReason.unreadable(Int32)`** is added: `.permission` is EACCES/EPERM only; other read errors (EIO, …) are `.unreadable`; ENOENT/ENOTDIR (folder deleted mid-crawl) are not reported. Matches delivered before a mid-read failure are kept. P3-10's skipped-locations UI shows the new case.
18. **`CrawlPermissions` compares case- and normalization-insensitively** (and folds `/private`), so a root typed in another case still hits a TCC-protected prefix; on case-sensitive volumes this can only over-block. `blockedPrefixes` is now `let`.
19. **`DateRanges.ns` saturates** to `Int64.min/.max` outside ≈1677…2262 (DayStamp accepts years 0000…9999), so `modified:9999-01-01` matches nothing and never traps.
20. **New `EntryFlags.mountPoint`** (bit 11), set by `RecordConverter` with the existing rowID-0 rule (DIR_MNTSTATUS_MNTPOINT or another st_dev). `SubtreeCrawler` never queues a flagged child, so an empty or stale `MountTableStore` cannot lead it onto another volume; the mount table stays a second guard. Its fileID dedupe runs only when the root volume is `idStable` (hard-link guard); the BFS queue is compacted; a stalled read is cancelled once resolved as `.stalled`. `NavigationHistory` keys file URLs with `LexicalPath.standardize` (no stat on the main actor; folds `/private/var|tmp|etc`).
