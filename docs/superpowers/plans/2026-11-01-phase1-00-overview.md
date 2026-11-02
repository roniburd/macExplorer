# macExplorer Phase 1 Implementation Plan: Overview and Interface Contract

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Phase 1 ("Core") of macExplorer: a native macOS 26 file manager with Explorer behaviour (address bar, tree, command bar, Details and Icons views, Explorer keys, cut/paste, right-drag, a crash-safe file-operation engine with undo, Open With, Properties, volumes), within the §4.4 performance budgets, plus benchmarks and end-to-end scenario harnesses that prove it works.

**Architecture:** SwiftPM package with five layers, `App → UI → Core → MacxFS → CFSKit`. `CFSKit` is a small C target (bounds-checked `getattrlistbulk` record parser, I/O policy, volume capabilities). `MacxFS` (the spec's "FSKit") owns I/O lanes with a watchdog, directory reading, the struct-of-arrays `EntryStore`, byte sort keys and the volume table. `Core` owns the main-actor `FolderModel`, Watcher, Settings, Clipboard logic, LaunchServices, Properties, key/command tables and the `FileOpQueue` engine with journal and undo. `UI` is AppKit (SwiftUI only for Properties, Settings, conflict dialog, onboarding). `App` is the `@main` executable. Every blocking file-system call runs on an I/O lane thread, never on the main thread or the cooperative pool.

**Tech Stack:** Swift 6.4 toolchain (Xcode 27.2 at `/Applications/Xcode.app`), swift-tools-version 6.2, Swift 6 language mode, AppKit, SwiftUI (low-volume windows only), Foundation, CoreServices (FSEvents, CFStringFold), UniformTypeIdentifiers, Synchronization (`Mutex`), os (`OSSignposter`), Darwin (`getattrlistbulk`, `copyfile`, `removefile`, `renamex_np`, `fts`), XCTest via `swift test`, `hdiutil` for disk-image tests, `codesign --sign -` for local bundles. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-01-macexplorer-design.md` (source of truth; section numbers like §4.3 below refer to it). Research notes: `docs/research/*.md`.

**Plan set (one file per slice, each written by a different author; all of them copy the Interface Contract below exactly):**

| File | Slice | Tasks |
|---|---|---|
| `docs/superpowers/plans/2026-11-01-phase1-00-overview.md` | this file: constraints, file map, interface contract, task index | none |
| `docs/superpowers/plans/2026-11-01-phase1-s1-fskit.md` | S1 fskit | P1-02 … P1-08 |
| `docs/superpowers/plans/2026-11-01-phase1-s2-core-model.md` | S2 core-model | P1-09 … P1-16 |
| `docs/superpowers/plans/2026-11-01-phase1-s3-fileops.md` | S3 fileops | P1-17 … P1-25 |
| `docs/superpowers/plans/2026-11-01-phase1-s4-ui-shell.md` | S4 ui-shell | P1-01, P1-26 … P1-30 |
| `docs/superpowers/plans/2026-11-01-phase1-s5-ui-content.md` | S5 ui-content | P1-31 … P1-38 |
| `docs/superpowers/plans/2026-11-01-phase1-s6-validation.md` | S6 validation | P1-39 … P1-42 |

Tasks execute in ID order (P1-01, P1-02, …). The ID order is a valid topological order of the dependency graph in §4 of this document. The app is launchable from P1-01 onward.

## Global Constraints

Every task in every slice implicitly includes all of these.

**Safety (HARD RULE, applies to tests, benchmarks, scenario runners, scripts and any manual or automated validation):**
- Tests, benchmarks and any manual/automated validation must ONLY create, modify or delete files inside fresh temporary directories they create themselves (`FileManager.default.temporaryDirectory/macx-tests-<UUID>`, `macx-bench-<UUID>`, `macx-scenario-<UUID>`) or inside disk images they create themselves (created inside such a directory and attached with `-mountpoint <that dir>/mnt-<n> -nobrowse`).
- Never touch, move, rename, trash or delete any pre-existing user file. The app may READ the user's real folders when a human browses, but automated scenarios must point the app at a sandbox dir (`--root <sandbox>` plus `--state-dir <sandbox>/state`).
- All test fixture writes go through `MacxFixtures.Sandbox`, which refuses (preconditionFailure) any path outside its root after symlink resolution. Tests must not call `FileManager` write APIs on paths not obtained from a `Sandbox`.
- Tests never use: `UserDefaults.standard` or any `UserDefaults(suiteName:)` (both write into `~/Library/Preferences`); `NSPasteboard.general` (use `NSPasteboard(name: NSPasteboard.Name("macx-tests-<UUID>"))` and `releaseGlobally()` in teardown); `SystemTrash` (use `SandboxTrash`, or `SystemTrash` only on a test-created disk image, whose Trash lives inside the image); the real journal path; the real `WorkspaceLaunchServices` for `setDefaultApplication`/`open` (use `FakeLaunchServices`); eject of any volume the test did not create.
- `hdiutil` is used only on images inside the test's sandbox. Every attach has a matching `hdiutil detach -force` in teardown (`addTeardownBlock`), and teardown deletes only the sandbox root.
- Scripts in `scripts/` that create data (`make-fixtures.sh`, `ui-scenarios.sh`, `run-scenarios.sh`) take or create a `macx-*-<UUID>` directory under `${TMPDIR}` and refuse any target path that does not start with that directory.
- Scenario and smoke runs use a separately bundled copy, `scripts/bundle.sh debug --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app`, so AppKit's own preference writes never touch a real install's `com.macexplorer.app` domain. In sandbox mode the app sets no `autosaveName`s (columns, split widths and sections persist through `Settings` into `<state-dir>/settings.json`) and passes `-ApplePersistenceIgnoreState YES`.
- The UI scenario runner launches the bundled app by executing `.build/macExplorer-scenarios.app/Contents/MacOS/macExplorer` directly (not `open`, which registers the bundle with LaunchServices) with `--root`, `--state-dir`, `--sandbox-trash`, `--pasteboard`, `--fake-launch-services`, `--skip-onboarding` (§3.12 `LaunchOptions`). With `--root` or `--scenario` present the app refuses to start (exit code 64) unless `--state-dir` is also present, and it disables window state restoration.

**Platform and language:**
- Minimum OS: macOS 26 (`platforms: [.macOS(.v26)]`). `// swift-tools-version: 6.2`.
- Swift 6 language mode (`swiftLanguageModes: [.v6]`), which means complete strict concurrency checking. Every Swift target uses `swiftSettings: [.treatAllWarnings(as: .error)]`; `CFSKit` uses `cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]`. (Verified working with the installed toolchain on 2026-11-01.)
- No `@unchecked Sendable` and no `nonisolated(unsafe)` in `MacxFS` or `Core`. A single exception per file is allowed only with a header comment explaining the confinement (for example a C pointer confined to one lane thread) and must be called out in the task's review.
- Module naming deviation from spec §4.1 (deliberate): the Swift module the spec calls `FSKit` is named **`MacxFS`** (directory `Sources/FSKit`, `path:` in Package.swift) because macOS 26's SDK ships a system `FSKit.framework` and `import FSKit` would be ambiguous. Its test target keeps the name `FSKitTests`. The app executable target is named `macExplorer` (directory `Sources/App`) so the binary is `macExplorer`.
- AppKit deviation from spec §4.1 (deliberate, keeps its intent): `MacxFS` and `Core` never import AppKit, except files under `Sources/Core/Platform/`, which hold every `NSWorkspace`/`NSPasteboard` adapter (LaunchServices, volume notifications, eject, pasteboard) behind Core protocols so tests substitute fakes. A CI grep enforces it (P1-42).
- No third-party dependencies. No XIBs, storyboards or asset catalogs; the icon is a prebuilt `Resources/AppIcon.icns`.
- No synchronous file-system calls on the main thread (§4.4 main-thread rule), including `resourceValues`, `fileExists`, `NSWorkspace.icon(forFile:)`, `urlsForApplications`. Every `MacxFS`/`Core` I/O entry point calls `assertOffMain()` (debug builds).
- Every blocking call runs on an I/O lane (`LanePool.perform`), never on the cooperative pool or a global GCD queue (§4.2).
- Background reads that must not download iCloud/File Provider content run inside `withNoMaterialization { }` (§4.2 list).
- All user-visible strings live in `Sources/UI/Resources/Localizable.xcstrings` and are read through `L10n` (`UIResources.bundle`), never `Bundle.module` (SwiftPM's generated accessor looks in the `.app` root, which breaks code signing). English only in Phase 1. Core never produces user-visible English text; it produces typed values (`JobDescription`, `FileOpErrorKind`, `Reason`) that UI formats.
- Every icon-only control has an accessibility label; every view the scenario runner needs has the accessibility identifier listed in §3.14.
- Inclusive language in code, comments and docs (no master/slave/whitelist/blacklist).
- Commits: one commit per task minimum, conventional prefix (`feat:`, `test:`, `fix:`, `docs:`, `build:`, `ci:`), on the working branch; never push.

**Performance budgets (§4.4, Apple Silicon, local APFS, warm cache; network/File Provider: no budget but never block UI):**

| Event | Budget |
|---|---|
| Navigate → first rows painted (any size) | < 50 ms |
| 100k entries fully listed + sorted | < 250 ms |
| Re-sort 100k by any column | < 30 ms |
| Scroll | 120 fps; cell configure < 0.5 ms |
| Main-thread hang | none > 100 ms |
| Type icons visible | first frame |
| Custom icons (`.app`, custom-icon flag) | < 100 ms after rows are visible |
| FSEvent → UI updated (incremental path) | < 150 ms |
| FSEvent → UI updated (full re-read of 100k) | < 400 ms |
| Memory, 100k-entry folder (entries, arena, sort keys, permutation, identity map) | < 20 MB steady, < 40 MB peak during sort/diff, excluding images |
| Drag or copy of 100k items (pasteboard write) | < 300 ms |
| Cold launch → window with home folder | < 300 ms |

Measured by `macx-bench` (P1-39) and `OSSignposter` intervals (`PerfSignposts`, §3.2). Debug-build unit tests may assert at most 4x these budgets (they are smoke checks, not gates); the gate is `macx-bench --check-budgets` on a release build.

**Testing:**
- XCTest via `swift test` (targets `FSKitTests`, `CoreTests`, `UITests`, plus `MacxFixturesTests`). `swift test --parallel` must pass. Tests needing a GUI session or `hdiutil` check availability and call `XCTSkip` with a reason instead of failing when unavailable.
- TDD per task: failing test first, then implementation, then green, then commit.
- Every slice task ends with: `swift build 2>&1 | tail -5` shows `Build complete!` with zero warnings, and `swift test --filter <TaskTests> 2>&1 | tail -5` shows `Executed N tests, with 0 failures`.

## Review Focus

The five inputs the spec implies but no task's spec-derived tests would naturally exercise, most likely to bite a user first. Each line names the owning task, which MUST include the listed test.

1. **Pasting or Move-Item-Here a folder into itself or one of its descendants (not via drag).** Expected: the job's plan phase refuses that item with a per-item error "can't move/copy a folder into itself" and copies nothing recursively; other items in the same paste proceed. Owner P1-18: `testPlanRefusesCopyAndMoveIntoSelfOrDescendant` (sources `A`, destination `A/sub`, and `A` onto `A`).
2. **Renaming or creating an item whose name is already used by a hidden item that is not displayed** (Show Hidden off, e.g. renaming to `.env` or to `notes.txt` when a `UF_HIDDEN` `notes.txt` exists). Expected: the duplicate check uses the whole `EntryStore`, not the visible permutation, and reports `.duplicate`. Owner P1-10: `testValidateNameSeesHiddenEntries`; P1-34 adds `testInlineRenameRejectsNameOfHiddenItem`.
3. **Rapid navigation while a large folder is still streaming** (holding ⌫/Back, or typing paths fast). Expected: batches, stalls and completions from the previous folder or generation never reach the new `FolderModel`, the old read is cancelled, and selection/scroll of the new folder is not disturbed. Owner P1-10: `testRapidNavigationDropsStaleGenerations` (open a 100k fixture, immediately open a 3-item folder 20 times, final rows equal the 3 items); P1-26 adds `testSessionNavigateCancelsPreviousModel`.
4. **Symlinks to directories and symlink loops inside recursive operations** (copy, cross-volume move, trash/delete plan, Properties folder count, merge). Expected: symlinks are never followed (`FTS_PHYSICAL`, `COPYFILE_NOFOLLOW_SRC`), copied as links, counted once, and recursion terminates. Owner P1-20: `testCopyTreeWithSymlinkLoopCopiesLinksAndTerminates`; P1-16 adds `testFolderCounterDoesNotFollowSymlinkLoop`.
5. **A source file that changes while a cross-volume move is copying it** (a growing log, an editor saving). Expected: verification (item count and byte totals) fails, the partial copy is removed, the source is NOT deleted, and the item reports an error with Retry/Skip. Owner P1-21: `testCrossVolumeMoveKeepsSourceWhenItChangesDuringCopy` (fault hook appends bytes to the source at `FaultPoint.afterPartialCopy`).

---

## 1. Package.swift (exact; P1-01 creates it with stub files for every target)

```swift
// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "macExplorer",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "macExplorer", targets: ["macExplorer"]),
        .executable(name: "macx-bench", targets: ["macx-bench"]),
        .executable(name: "macx-scenarios", targets: ["macx-scenarios"]),
    ],
    targets: [
        .target(
            name: "CFSKit",
            cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]
        ),
        .target(name: "MacxFS", dependencies: ["CFSKit"], path: "Sources/FSKit", swiftSettings: strict),
        .target(name: "Core", dependencies: ["MacxFS"], swiftSettings: strict),
        .target(
            name: "UI",
            dependencies: ["Core", "MacxFS"],
            resources: [.process("Resources")],
            swiftSettings: strict
        ),
        .executableTarget(name: "macExplorer", dependencies: ["UI", "Core"], path: "Sources/App", swiftSettings: strict),
        .target(name: "MacxFixtures", dependencies: ["MacxFS"], swiftSettings: strict),
        .executableTarget(name: "macx-bench", dependencies: ["MacxFS", "Core", "MacxFixtures"], swiftSettings: strict),
        .executableTarget(name: "macx-scenarios", dependencies: ["Core", "MacxFS", "MacxFixtures"], swiftSettings: strict),
        .testTarget(name: "MacxFixturesTests", dependencies: ["MacxFixtures"], swiftSettings: strict),
        .testTarget(name: "FSKitTests", dependencies: ["MacxFS", "CFSKit", "MacxFixtures"], resources: [.copy("Corpus")], swiftSettings: strict),
        .testTarget(name: "CoreTests", dependencies: ["Core", "MacxFS", "MacxFixtures"], swiftSettings: strict),
        .testTarget(name: "UITests", dependencies: ["UI", "Core", "MacxFS", "MacxFixtures"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
```

`FSKitTests` is the only target that reads `Bundle.module` (test bundles are not code-signed app bundles, so the accessor is fine there).

## 2. File structure (Phase 1)

One line of responsibility per file. Owning task in brackets. Keep files under ~300 lines; split by responsibility if one grows.

```
Package.swift                                   [P1-01] package manifest (§1 above)
.gitignore                                      [P1-01] .build/, *.xcodeproj, .swiftpm/, bench-*.json
LICENSE                                         [P1-01] MIT
README.md                                       [P1-42] build/test/bench/run instructions, Finder-replacement non-goal, cut→Finder caveat
Resources/Info.plist                            [P1-01] bundle id com.macexplorer.app, LSMinimumSystemVersion 26.0, NS*UsageDescription keys (§5.9), NSPrincipalClass NSApplication
Resources/macExplorer.entitlements              [P1-01] hardened-runtime entitlements (empty dict in Phase 1, no sandbox)
Resources/AppIcon.icns                          [P1-01] prebuilt icon produced by scripts/make-icon.sh (committed binary)
scripts/bundle.sh                               [P1-01] usage: bundle.sh [debug|release] [--bundle-id ID] [--output PATH]; default .build/macExplorer.app. Locates products with `swift build -c <cfg> --show-bin-path` (with Xcode installed SwiftPM uses .build/out/Products/<Cfg>); copies executable, Info.plist (bundle id substituted), icns, macExplorer_UI.bundle into Contents/Resources; codesign --force --sign - --options runtime
scripts/make-icon.sh                            [P1-01] draws a placeholder icon with a swift script into an .iconset in a temp dir → iconutil → Resources/AppIcon.icns
scripts/make-fixtures.sh                        [P1-02] creates a fixture tree (kinds per §9) under a fresh ${TMPDIR}/macx-fixtures-<UUID>, prints its path
scripts/run-scenarios.sh                        [P1-40] builds and runs macx-scenarios, writes JSON report into a fresh macx-scenario-<UUID> dir
scripts/ui-scenarios.sh                         [P1-41] bundles the app, runs every Tests/Scenarios/*.json through the app in sandboxes, prints a summary, exits non-zero on failure
scripts/ui-ax-smoke.sh                          [P1-41] optional Accessibility/AppleScript smoke (window title, row count); skips with a message if the terminal lacks Accessibility permission
scripts/check-layering.sh                       [P1-42] fails if MacxFS/Core (outside Core/Platform) import AppKit, or if tests reference UserDefaults.standard / NSPasteboard.general / SystemTrash()
.github/workflows/ci.yml                        [P1-42] PR: build, test, bundle, scenarios, bench with relative gate; budgets as warning annotations

Sources/CFSKit/include/CFSKit.h                 [P1-03] public C API (§3.1)
Sources/CFSKit/bulk.c                           [P1-03] attrlist setup, cfsk_bulk_read, cfsk_stat_at
Sources/CFSKit/cursor.c                         [P1-03] bounds-checked record cursor (cfsk_cursor_init/next)
Sources/CFSKit/iopolicy.c                       [P1-03] materialization policy get/set wrappers
Sources/CFSKit/volcaps.c                        [P1-03] getattrlist(ATTR_VOL_CAPABILITIES) wrapper

Sources/FSKit/Support/Observers.swift           [P1-04] ObserverToken, Observers<Event>
Sources/FSKit/Support/MainThread.swift          [P1-04] assertOffMain()
Sources/FSKit/Support/PerfSignposts.swift       [P1-04] shared OSSignposter + interval names
Sources/FSKit/Lanes/IOLane.swift                [P1-04] one dedicated Thread + serial work queue + heartbeat
Sources/FSKit/Lanes/LaneContext.swift           [P1-04] heartbeat/cancellation handle passed to lane work
Sources/FSKit/Lanes/LanePool.swift              [P1-04] per-volume lane pools, perform(), poisoned-lane cap, health
Sources/FSKit/Lanes/Watchdog.swift              [P1-04] stall detection timer, StallPolicy/StallNotice
Sources/FSKit/Lanes/Generation.swift            [P1-04] Generation counter
Sources/FSKit/Lanes/Materialization.swift       [P1-04] withNoMaterialization
Sources/FSKit/Store/Entry.swift                 [P1-05] Entry, Kind, EntryFlags
Sources/FSKit/Store/Batch.swift                 [P1-05] Batch, EntryError
Sources/FSKit/Store/NameArena.swift             [P1-05] UTF-8 name arena
Sources/FSKit/Store/RowID.swift                 [P1-05] RowID, IdentityMode, NameNormalizer
Sources/FSKit/Store/TypeRegistry.swift          [P1-05] interned UTType table, package test, kind ranks
Sources/FSKit/Store/EntryStore.swift            [P1-05] struct-of-arrays store, permutation, identity map
Sources/FSKit/Reader/ReadTypes.swift            [P1-06] ReadOptions, ReadEvent, ReadSummary, ReadFailure
Sources/FSKit/Reader/BulkReader.swift           [P1-06] synchronous getattrlistbulk loop → Batches (runs on a lane)
Sources/FSKit/Reader/FallbackReader.swift       [P1-06] synchronous readdir + fstatat → Batches
Sources/FSKit/Reader/RecordConverter.swift      [P1-06] cfsk_record → Entry (kind, flags, type index, identity)
Sources/FSKit/Reader/ItemReader.swift           [P1-06] stat a list of names in one dir (watcher incremental path)
Sources/FSKit/Reader/DirectoryReader.swift      [P1-06] per-volume actor; streaming (2,000 / 8 ms), stalls, cancel
Sources/FSKit/Reader/DirectoryReaders.swift     [P1-06] registry: one DirectoryReader per volume
Sources/FSKit/Sort/ViewQuery.swift              [P1-07] SortField, SortDescriptor, ViewQuery
Sources/FSKit/Sort/SortKeyColumn.swift          [P1-07] byte-key column (arena + offsets)
Sources/FSKit/Sort/SortKeys.swift               [P1-07] CFStringFold name keys, digit runs, search fold
Sources/FSKit/Sort/Sorter.swift                 [P1-07] permutation by memcmp/integer keys, filter, merge
Sources/FSKit/Volumes/VolumeInfo.swift          [P1-08] VolumeID, VolumeInfo, VolumeCapabilities
Sources/FSKit/Volumes/MountTable.swift          [P1-08] longest-prefix lookup, MountTableStore (Sendable mirror)
Sources/FSKit/Volumes/VolumeScanner.swift       [P1-08] VolumeScanning protocol + SystemVolumeScanner (mountedVolumeURLs on a lane)
Sources/FSKit/Volumes/Volumes.swift             [P1-08] @MainActor registry: list, events, capacity cache, release handlers

Sources/MacxFixtures/Sandbox.swift              [P1-02] guarded temp root; all fixture writes
Sources/MacxFixtures/DiskImage.swift            [P1-02] hdiutil create/attach/detach inside a Sandbox (APFS, HFS+, ExFAT, MS-DOS; size; read-only)
Sources/MacxFixtures/FixtureTree.swift          [P1-02] builders: flat N files, §9 golden tree, deep trees, sparse, xattrs, locked, aliases
Sources/MacxFixtures/SortCorpus.swift           [P1-07] deterministic ~5k-name corpus generator

Sources/Core/Support/CoreEnvironment.swift      [P1-25] DI bundle of every Core service
Sources/Core/Support/StatePaths.swift           [P1-01] app state dir (journal, settings file, recents)
Sources/Core/Support/LaunchOptions.swift        [P1-01] command-line parsing (--root, --state-dir, …)
Sources/Core/Support/ChangeBus.swift            [P1-10] routes LocalChange posts to FolderModels by directory
Sources/Core/Folder/FolderState.swift           [P1-10] FolderState, Reason
Sources/Core/Folder/Change.swift                [P1-09] Change, ChangeSet
Sources/Core/Folder/StoreDiff.swift             [P1-09] identity diff with replacement rule and moves
Sources/Core/Folder/Selection.swift             [P1-10] Selection, SelectionCommand, SelectionSummary
Sources/Core/Folder/NameRules.swift             [P1-10] rename/new-name validation (empty, '/', 255 bytes, NFC/case duplicate, warnings)
Sources/Core/Folder/LocalChange.swift           [P1-10] LocalChange (FileOps → FolderModel)
Sources/Core/Folder/FramePacer.swift            [P1-10] FramePacer protocol + TimerFramePacer
Sources/Core/Folder/FolderWorker.swift          [P1-10] actor: sort keys, sorted merge while loading, re-sort, diff, patching
Sources/Core/Folder/FolderModel.swift           [P1-10] @MainActor facade: state machine, store, selection, events
Sources/Core/Folder/FolderModel+Watch.swift     [P1-11] buffering during read, incremental vs full re-read, relocation
Sources/Core/Watch/WatchTypes.swift             [P1-10] WatchEvent, RawFSEvent, ContentWatching, NoopWatcher (used until P1-11)
Sources/Core/Watch/Watcher.swift                [P1-11] FSEventStream per visible folder (FileEvents|NoDefer|WatchRoot, 100 ms)
Sources/Core/Watch/EventClassifier.swift        [P1-11] pure: raw events → WatchEvent (parent filter, 256 cap, rescan flags)
Sources/Core/Watch/TreeWatcher.swift            [P1-11] vnode DispatchSources for expanded tree nodes (cap 256)
Sources/Core/Settings/SettingsStorage.swift     [P1-12] SettingsStorage protocol + UserDefaults/File/InMemory storages
Sources/Core/Settings/SettingsTypes.swift       [P1-12] ViewMode, IconSize, Density, ColumnID, ColumnSetting, enums of §7
Sources/Core/Settings/Settings.swift            [P1-12] @MainActor @Observable Settings with schemaVersion
Sources/Core/Settings/Favorites.swift           [P1-12] Favorite (bookmark), FavoritesResolver (lane), defaults
Sources/Core/Settings/ProtectedLocations.swift  [P1-12] TCC location classification + recorded outcomes
Sources/Core/Commands/Command.swift             [P1-13] Command enum + selector names
Sources/Core/Commands/KeyChord.swift            [P1-13] Key, KeyModifiers, KeyChord
Sources/Core/Commands/KeyMap.swift              [P1-13] primary + alternate bindings (§5.6 table), text-collision set
Sources/Core/Commands/KeyDispatcher.swift       [P1-13] alternates → Command by FocusContext
Sources/Core/Commands/CommandAvailability.swift [P1-13] enablement rules incl. sidebar section table (§5.4)
Sources/Core/Navigation/NavigationHistory.swift [P1-13] back/forward stacks
Sources/Core/Navigation/AddressResolver.swift   [P1-13] parse /abs, ~, ~/rel, file://, relative; resolve on a lane
Sources/Core/Navigation/PathCompletion.swift    [P1-13] subfolder completion (off-main readdir, dirs only) + RecentLocations
Sources/Core/LaunchServices/LaunchServices.swift[P1-14] AppInfo, LaunchServicesProviding protocol
Sources/Core/LaunchServices/LaunchServicesCache.swift [P1-14] @MainActor caches (per UTType, per file default), invalidate
Sources/Core/LaunchServices/FakeLaunchServices.swift  [P1-14] recording fake for tests and --fake-launch-services
Sources/Core/Open/OpenPlanner.swift             [P1-14] decide navigate/new window/launch/open/broken link; >10 folders confirm
Sources/Core/Volumes/EjectCoordinator.swift     [P1-14] release → eject → busy diagnosis (lsof, timeout) → retry once
Sources/Core/Platform/WorkspaceLaunchServices.swift [P1-14] NSWorkspace impl of LaunchServicesProviding (on lanes)
Sources/Core/Platform/WorkspaceVolumeEvents.swift   [P1-14] NSWorkspace.shared.notificationCenter → VolumeEvent
Sources/Core/Platform/WorkspaceEjector.swift        [P1-14] unmountAndEjectDevice + lsof blocking-process finder
Sources/Core/Clipboard/PasteboardBackend.swift  [P1-15] PasteboardBackend protocol + InMemoryPasteboard
Sources/Core/Clipboard/Clipboard.swift          [P1-15] copy/cut/marker/changeCount/paste planning
Sources/Core/Platform/SystemPasteboard.swift    [P1-15] NSPasteboard impl (file URLs, NSFilenamesPboardType, text, cut marker)
Sources/Core/Drag/DropPolicy.swift              [P1-15] pure in-memory drop validation and operation choice
Sources/Core/Properties/ItemProperties.swift    [P1-16] ItemProperties, MultiProperties, VolumeProperties, Tri
Sources/Core/Properties/PropertiesLoader.swift  [P1-16] load on a lane under no-materialization
Sources/Core/Properties/PermissionModel.swift   [P1-16] PermissionAccess ↔ mode bits, owner/group names
Sources/Core/Properties/Xattrs.swift            [P1-16] listxattr, quarantine, where-froms (MDItem)
Sources/Core/Properties/FolderCounter.swift     [P1-16] cancellable recursive count with progress
Sources/Core/FileOps/JobTypes.swift             [P1-17] JobID, OriginID, JobKind, JobRequest, JobState, JobSnapshot, JobDescription
Sources/Core/FileOps/JobProgress.swift          [P1-17] JobProgress + ThroughputMeter (60 samples, ETA)
Sources/Core/FileOps/FileOpError.swift          [P1-17] FileOpErrorKind (errno mapping, §6.5 actions), FileOpError
Sources/Core/FileOps/Interaction.swift          [P1-17] FileOpInteraction protocol, conflict/error/space types, InteractionProxy, ScriptedInteraction
Sources/Core/FileOps/JobRecord.swift            [P1-17] FileIdentity, ItemAction, AttributeSnapshot, JobRecord, JobOutcome
Sources/Core/FileOps/Journal.swift              [P1-17] crash journal (partials, trashed destinations), atomic writes
Sources/Core/FileOps/LaunchRecovery.swift       [P1-17] launch cleanup from journal → RecoveryReport
Sources/Core/FileOps/TrashService.swift         [P1-17] TrashService protocol, SystemTrash, SandboxTrash
Sources/Core/FileOps/FaultPoint.swift           [P1-17] test fault-injection points
Sources/Core/FileOps/FileOpQueue.swift          [P1-18] app-wide actor: scheduling by volume set, FIFO, events
Sources/Core/FileOps/JobRunner.swift            [P1-18] per-job plan→execute loop, pause/cancel, 10 Hz progress
Sources/Core/FileOps/Planner.swift              [P1-18] fts enumeration, existence, counts/bytes, space estimate, self/descendant refusal
Sources/Core/FileOps/VolumeIdentity.swift       [P1-18] same/cross volume via st_dev of source and destination parent
Sources/Core/FileOps/RenamePrimitive.swift      [P1-19] renamex_np(RENAME_EXCL) + lstat fallback + case-only rename
Sources/Core/FileOps/NameGenerator.swift        [P1-19] "x 2.ext", "name copy", "name copy 2", "New Folder 2"
Sources/Core/FileOps/CreateOps.swift            [P1-19] newItem, rename job execution
Sources/Core/FileOps/CopyEngine.swift           [P1-20] copyfile per item (flags §6.3), directory two-pass metadata, chunk progress
Sources/Core/FileOps/CopyJob.swift              [P1-20] copy and duplicate jobs over the plan
Sources/Core/FileOps/MoveJob.swift              [P1-21] same-volume rename move; cross-volume partial→verify→rename→delete
Sources/Core/FileOps/ConflictExecutor.swift     [P1-22] Replace / Skip / Keep Both / Merge sequences, apply-to-all state
Sources/Core/FileOps/TrashDeleteJobs.swift      [P1-23] trash (no-trash fallback), delete permanently (removefile)
Sources/Core/FileOps/LinkJobs.swift             [P1-23] alias (bookmark file), symlink (relative on same volume)
Sources/Core/FileOps/AttributeJobs.swift        [P1-23] setAttributes, chmodRecursive
Sources/Core/FileOps/UndoPlanner.swift          [P1-24] JobRecord → inverse JobKind.undo actions, identity checks
Sources/Core/FileOps/FileOpUndoStack.swift      [P1-24] @MainActor app-wide UndoManager, redo, field-editor managers
Sources/Core/FileOps/OperationsCenter.swift     [P1-25] @MainActor @Observable job mirror; routes outcomes to undo + ChangeBus
Sources/Core/FileOps/TerminationCoordinator.swift [P1-25] stop-all-and-wait (10 s) for quit

Sources/UI/Resources/Localizable.xcstrings      [P1-01] String Catalog (grows with each UI task)
Sources/UI/Support/UIResources.swift            [P1-01] locate macExplorer_UI.bundle in Contents/Resources (fallback: next to executable)
Sources/UI/Support/L10n.swift                   [P1-01] L10n.string(_:) over UIResources.bundle
Sources/UI/Support/AXID.swift                   [P1-26] accessibility identifiers (§3.14)
Sources/UI/Support/Formatters.swift             [P1-31] size (ByteCountFormatter .file), relative/medium dates, counts
Sources/UI/Support/IconCache.swift              [P1-31] Tier 0 per-UTType CGImages, Tier 1 per-file icons on lanes
Sources/UI/Support/KeyEventTranslator.swift     [P1-29] NSEvent → KeyChord
Sources/UI/App/UIContext.swift                  [P1-26] shared UI services (env, icons, windows, interaction, options)
Sources/UI/App/WindowManager.swift              [P1-26] open/close/restore browser windows, origin lookup, move-to-home on release
Sources/UI/Window/BrowserSession.swift          [P1-26] per-window navigation (current FolderModel, history, view mode)
Sources/UI/Window/BrowserWindowController.swift [P1-26] NSWindow + toolbar + split view; ScenarioProbe conformance
Sources/UI/Window/BrowserSplitViewController.swift [P1-26] sidebar + content split items (inspector slot reserved)
Sources/UI/Window/CommandActions.swift          [P1-26] CommandTarget, CommandHandler, CommandHandlingViewController (@objc action per Command)
Sources/UI/Toolbar/ToolbarController.swift      [P1-27] NSToolbar delegate: nav group, address, search, view switcher
Sources/UI/Toolbar/NavigationButtons.swift      [P1-27] back/forward/up group with history menus
Sources/UI/Toolbar/AddressBarView.swift         [P1-27] breadcrumb ⇄ edit mode container
Sources/UI/Toolbar/BreadcrumbView.swift         [P1-27] segments, › subfolder menus, « overflow, drop targets
Sources/UI/Toolbar/AddressEditField.swift       [P1-27] text field, autocomplete dropdown, recents, inline error
Sources/UI/Toolbar/SearchFieldController.swift  [P1-27] filter-in-folder field → FolderModel.setQuery
Sources/UI/CommandBar/CommandBarView.swift      [P1-29] New/Cut/Copy/Paste/Rename/Share/Delete/Sort/View/⋯/Properties
Sources/UI/StatusBar/StatusBarView.swift        [P1-29] counts, selection size, free space, operations capsule slot
Sources/UI/Menus/MainMenuBuilder.swift          [P1-29] full menu bar from Command + KeyMap primaries
Sources/UI/Menus/MenuValidation.swift           [P1-26] validateMenuItem rules incl. field-editor collisions
Sources/UI/Menus/KeyRouter.swift                [P1-29] keyDown alternates → KeyDispatcher → sendAction
Sources/UI/Sidebar/SidebarItem.swift            [P1-28] node model: section headers, favorites, locations, tree nodes
Sources/UI/Sidebar/SidebarViewController.swift  [P1-28] source-list NSOutlineView, sections, eject buttons, focus target
Sources/UI/Sidebar/FolderTreeController.swift   [P1-28] lazy dirs-only children via DirectoryReader, auto-reveal, TreeWatcher
Sources/UI/Settings/SettingsWindowController.swift [P1-30] hosts SettingsView
Sources/UI/Settings/SettingsView.swift          [P1-30] SwiftUI §7 sections
Sources/UI/Onboarding/OnboardingSheet.swift     [P1-30] SwiftUI FDA + fn-key sheet, deep links
Sources/UI/App/AppLifecycle.swift               [P1-30] terminate-with-jobs, Dock badge, launch recovery notice
Sources/UI/Content/FileListView.swift           [P1-31] protocol shared by Details and Icons
Sources/UI/Content/ContentViewController.swift  [P1-31] command bar + list/grid + empty state + banner + status bar host
Sources/UI/Details/DetailsViewController.swift  [P1-31] NSTableView data source/delegate over FolderModel
Sources/UI/Details/DetailsColumns.swift         [P1-31] column defs, header menu, autosave to Settings, auto-fit
Sources/UI/Details/NameCellView.swift           [P1-31] icon + name cell (cut dim + italic)
Sources/UI/Icons/FileGridLayout.swift           [P1-32] fixed-grid NSCollectionViewLayout (O(1) attributes)
Sources/UI/Icons/IconsViewController.swift      [P1-32] NSCollectionView data source, rubber band, spatial arrows
Sources/UI/Icons/IconItem.swift                 [P1-32] grid item: icon + two-line middle-ellipsis label
Sources/UI/Content/SelectionController.swift    [P1-33] click/⌘/⇧/arrow semantics → SelectionCommand
Sources/UI/Content/TypeSelect.swift             [P1-33] type-select buffer → row
Sources/UI/Content/EmptyStateView.swift         [P1-33] empty/no-match/TCC/POSIX/other/unresponsive/waiting states
Sources/UI/Content/BannerView.swift             [P1-33] non-modal "'X' was moved or deleted" banner
Sources/UI/Content/InlineRenameController.swift [P1-34] F2 field, base-name selection, Tab next, warnings, commit as job
Sources/UI/Commands/FileCommandController.swift [P1-35] CommandHandler impl: executes Commands for a CommandTarget
Sources/UI/Menus/ContextMenuBuilder.swift       [P1-35] item and empty-space context menus
Sources/UI/Menus/OpenWithMenu.swift             [P1-35] menuNeedsUpdate from LaunchServicesCache, "Loading…"
Sources/UI/OpenWith/DefaultAppSheet.swift       [P1-35] Choose Default App sheet (list, Browse…, "Always use")
Sources/UI/DragDrop/DragSource.swift            [P1-36] ≤5 dragging items + full pasteboard in willBeginAt
Sources/UI/DragDrop/DropTarget.swift            [P1-36] shared destination logic: DropPolicy, badges, spring-load, promises
Sources/UI/DragDrop/RightDragTracker.swift      [P1-36] rightMouseDown threshold → drag or context menu
Sources/UI/DragDrop/DropMenu.swift              [P1-36] Copy/Move/Alias/Symlink Here/Cancel menu
Sources/UI/Properties/PropertiesWindowController.swift [P1-37] one window per selection set, focus existing
Sources/UI/Properties/PropertiesViewModel.swift [P1-37] @MainActor @Observable state, edits → setAttributes/rename jobs
Sources/UI/Properties/PropertiesView.swift      [P1-37] SwiftUI General/Permissions/Opens with/Details/multi/volume
Sources/UI/Operations/BasicAlertInteraction.swift [P1-26] minimal NSAlert FileOpInteraction used until P1-38
Sources/UI/Operations/InteractionRouter.swift   [P1-38] FileOpInteraction → sheet on origin window or Operations panel
Sources/UI/Operations/ConflictDialog.swift      [P1-38] SwiftUI Replace/Skip/Keep Both/Compare/Merge + "do this for all (N)"
Sources/UI/Operations/CompareView.swift         [P1-38] side-by-side per-item checkboxes
Sources/UI/Operations/ErrorDialog.swift         [P1-38] §6.5 messages/actions, space shortfall dialog
Sources/UI/Operations/OperationsCapsule.swift   [P1-38] status-bar capsule (icon + overall %)
Sources/UI/Operations/OperationsListView.swift  [P1-38] job rows (title, bar, speed graph, ETA, pause/cancel, details)
Sources/UI/Operations/OperationsPanel.swift     [P1-38] popover + Window › Operations NSPanel
Sources/UI/Scenario/ScenarioProbe.swift         [P1-26] ScenarioProbe protocol + ScenarioHooks (optional closures later tasks install)
Sources/UI/Scenario/ScenarioFile.swift          [P1-41] Codable scenario schema (§3.14)
Sources/UI/Scenario/ScenarioDriver.swift        [P1-41] in-process runner: synthesizes NSEvents, probes, writes result JSON

Sources/App/main.swift                          [P1-01] NSApplication bootstrap, parses LaunchOptions
Sources/App/AppDelegate.swift                   [P1-01] launch → UIContext/WindowManager; app-level commands (grows in P1-26/P1-30)
Sources/App/AppBootstrap.swift                  [P1-26] builds CoreEnvironment.live or sandboxed per LaunchOptions

Sources/macx-bench/main.swift                   [P1-39] argument parsing, run, output
Sources/macx-bench/Metrics.swift                [P1-39] metric definitions (enumerate, sortkeys, sort, resort, diff, pasteboard, firstBatch)
Sources/macx-bench/Stats.swift                  [P1-39] warm-up + 5 iterations, median/p90
Sources/macx-bench/Budgets.swift                [P1-39] §4.4 budget table, --check-budgets
Sources/macx-bench/BaselineCompare.swift        [P1-39] --compare: >20% AND >5 ms slower fails

Sources/macx-scenarios/main.swift               [P1-40] CLI: --list, --filter, --json, --keep-sandbox; crash-helper subcommand
Sources/macx-scenarios/CoreScenario.swift       [P1-40] scenario protocol + assertion helpers
Sources/macx-scenarios/Scenarios/*.swift        [P1-40] browse, ops, conflicts, cross-volume, watcher, clipboard, undo scenarios

Tests/MacxFixturesTests/SandboxTests.swift      [P1-02]
Tests/FSKitTests/Corpus/sort-allowed-divergences.json [P1-01 creates `[]`; P1-07 fills] allowed sort differences with reasons
Tests/FSKitTests/CursorFuzzTests.swift          [P1-03]
Tests/FSKitTests/CFSKitTests.swift              [P1-03]
Tests/FSKitTests/LaneTests.swift                [P1-04]
Tests/FSKitTests/EntryStoreTests.swift          [P1-05]
Tests/FSKitTests/TypeRegistryTests.swift        [P1-05]
Tests/FSKitTests/ReaderGoldenTests.swift        [P1-06] field-by-field vs lstat/getattrlist
Tests/FSKitTests/ReaderParityTests.swift        [P1-06] fallback == bulk
Tests/FSKitTests/DirectoryReaderTests.swift     [P1-06] streaming, stall, cancel, generation
Tests/FSKitTests/SortGoldenTests.swift          [P1-07]
Tests/FSKitTests/SorterTests.swift              [P1-07]
Tests/FSKitTests/VolumesTests.swift             [P1-08]
Tests/CoreTests/StoreDiffTests.swift            [P1-09]
Tests/CoreTests/FolderModelTests.swift          [P1-10]
Tests/CoreTests/NameRulesTests.swift            [P1-10]
Tests/CoreTests/SelectionTests.swift            [P1-10]
Tests/CoreTests/WatcherTests.swift              [P1-11]
Tests/CoreTests/EventClassifierTests.swift      [P1-11]
Tests/CoreTests/SettingsTests.swift             [P1-12]
Tests/CoreTests/KeyMapTests.swift               [P1-13]
Tests/CoreTests/AddressResolverTests.swift      [P1-13]
Tests/CoreTests/LaunchServicesCacheTests.swift  [P1-14]
Tests/CoreTests/OpenPlannerTests.swift          [P1-14]
Tests/CoreTests/ClipboardTests.swift            [P1-15]
Tests/CoreTests/DropPolicyTests.swift           [P1-15]
Tests/CoreTests/PropertiesTests.swift           [P1-16]
Tests/CoreTests/FileOps/JournalTests.swift      [P1-17]
Tests/CoreTests/FileOps/FileOpErrorTests.swift  [P1-17]
Tests/CoreTests/FileOps/QueueTests.swift        [P1-18]
Tests/CoreTests/FileOps/PlannerTests.swift      [P1-18]
Tests/CoreTests/FileOps/RenameTests.swift       [P1-19]
Tests/CoreTests/FileOps/CopyTests.swift         [P1-20]
Tests/CoreTests/FileOps/MoveTests.swift         [P1-21]
Tests/CoreTests/FileOps/CrashRecoveryTests.swift[P1-21]
Tests/CoreTests/FileOps/ConflictTests.swift     [P1-22]
Tests/CoreTests/FileOps/TrashDeleteTests.swift  [P1-23]
Tests/CoreTests/FileOps/ErrorTableTests.swift   [P1-23]
Tests/CoreTests/FileOps/UndoTests.swift         [P1-24]
Tests/CoreTests/OperationsCenterTests.swift     [P1-25]
Tests/CoreTests/LaunchOptionsTests.swift        [P1-01]
Tests/UITests/UIResourcesTests.swift            [P1-01] (UITests = unit tests of UI code via swift test; the spec's XCUITest role is filled by the P1-41 in-process runner)
Tests/UITests/BrowserSessionTests.swift         [P1-26]
Tests/UITests/AddressBarTests.swift             [P1-27]
Tests/UITests/SidebarTests.swift                [P1-28]
Tests/UITests/MenuValidationTests.swift         [P1-29]
Tests/UITests/KeyRouterTests.swift              [P1-29]
Tests/UITests/DetailsViewTests.swift            [P1-31]
Tests/UITests/FileGridLayoutTests.swift         [P1-32]
Tests/UITests/SelectionControllerTests.swift    [P1-33]
Tests/UITests/InlineRenameTests.swift           [P1-34]
Tests/UITests/ContextMenuTests.swift            [P1-35]
Tests/UITests/DragDropTests.swift               [P1-36]
Tests/UITests/PropertiesViewModelTests.swift    [P1-37]
Tests/UITests/InteractionRouterTests.swift      [P1-38]
Tests/Scenarios/*.json                          [P1-41] UI scenario files (§3.14 schema)
```

## 3. Interface contract

Slice authors copy these declarations exactly (names, labels, parameter and return types, isolation, `Sendable`, `throws`). Bodies are the slice's job. Anything not listed is internal to its module and may be shaped freely. If a slice finds a contract bug, it fixes it here in the same commit and notes it in the task.

Conventions: paths cross module boundaries as file `URL`s (`URL(filePath:directoryHint:)`), standardized; byte names stay in arenas; times are nanoseconds since 1970 (`Int64`) inside MacxFS and `Date` in Core's UI-facing types.

### 3.1 CFSKit (C, `Sources/CFSKit/include/CFSKit.h`)

```c
#ifndef CFSKIT_H
#define CFSKIT_H
#include <stdint.h>
#include <stddef.h>

/* Bits of cfsk_record.fields: which attributes the kernel actually returned. */
static const uint32_t CFSK_HAS_NAME       = 1u << 0;
static const uint32_t CFSK_HAS_ERROR      = 1u << 1;
static const uint32_t CFSK_HAS_OBJTYPE    = 1u << 2;
static const uint32_t CFSK_HAS_FILEID     = 1u << 3;
static const uint32_t CFSK_HAS_MODTIME    = 1u << 4;
static const uint32_t CFSK_HAS_CRTIME     = 1u << 5;
static const uint32_t CFSK_HAS_FLAGS      = 1u << 6;
static const uint32_t CFSK_HAS_ACCESSMASK = 1u << 7;
static const uint32_t CFSK_HAS_FNDRINFO   = 1u << 8;
static const uint32_t CFSK_HAS_DATALENGTH = 1u << 9;
static const uint32_t CFSK_HAS_ALLOCSIZE  = 1u << 10;
static const uint32_t CFSK_HAS_ENTRYCOUNT = 1u << 11;
static const uint32_t CFSK_HAS_LINKID     = 1u << 12;

/* Result codes of cfsk_cursor_next. */
static const int CFSK_NEXT_END       = 0;  /* no more records */
static const int CFSK_NEXT_OK        = 1;  /* *out filled */
static const int CFSK_NEXT_DROPPED   = 2;  /* record malformed (bad name ref etc.), skipped; call again */
static const int CFSK_NEXT_TRUNCATED = 3;  /* record length out of bounds; rest of buffer unusable; stop */

typedef struct cfsk_record {
    const char *name;          /* points into the caller's buffer; NOT NUL-terminated by contract; use name_len */
    uint32_t    name_len;      /* bytes, excluding any trailing NUL */
    uint32_t    fields;        /* CFSK_HAS_* */
    uint32_t    error;         /* ATTR_CMN_ERROR (errno) or 0 */
    uint32_t    obj_type;      /* enum vtype: VREG, VDIR, VLNK, ... */
    uint64_t    file_id;
    uint64_t    link_id;
    int64_t     mtime_ns;
    int64_t     crtime_ns;
    uint32_t    bsd_flags;     /* st_flags */
    uint32_t    access_mask;   /* R_OK|W_OK|X_OK for the calling user */
    uint16_t    finder_flags;  /* host-endian FileInfo/FolderInfo finderFlags */
    uint32_t    finder_type;   /* host-endian OSType, e.g. 'alis' */
    int64_t     data_length;
    int64_t     alloc_size;
    uint32_t    entry_count;
} cfsk_record;

typedef struct cfsk_cursor {
    const uint8_t *next;
    const uint8_t *end;
    uint32_t       remaining;  /* record count the kernel reported for this buffer */
} cfsk_cursor;

/* getattrlistbulk with the §4.2 attribute set and FSOPT_ATTR_CMN_EXTENDED (no FSOPT_PACK_INVAL_ATTRS).
   Returns entries in buf (>0), 0 at end of directory, -1 with errno set. */
int  cfsk_bulk_read(int dirfd, void *buf, size_t buflen);

/* Parser: never reads outside [buf, buf+used_len). Safe on arbitrary bytes. */
void cfsk_cursor_init(cfsk_cursor *c, const void *buf, size_t used_len, uint32_t count);
int  cfsk_cursor_next(cfsk_cursor *c, cfsk_record *out);

/* Single item via getattrlistat(dirfd, name, FSOPT_NOFOLLOW) with the same attributes (minus ATTR_CMN_ERROR).
   out->name points into buf. Returns 0, or -1 with errno set. */
int  cfsk_stat_at(int dirfd, const char *name, void *buf, size_t buflen, cfsk_record *out);

/* Materialization policy for the calling thread. */
int  cfsk_materialize_off(int *previous);   /* 0 ok, -1 errno */
int  cfsk_materialize_restore(int previous); /* 0 ok, -1 errno */

typedef struct cfsk_volcaps {
    uint8_t persistent_ids;   /* VOL_CAP_FMT_PERSISTENTOBJECTIDS */
    uint8_t rename_excl;      /* VOL_CAP_INT_RENAME_EXCL */
    uint8_t clone;            /* VOL_CAP_INT_CLONE */
    uint8_t case_sensitive;   /* VOL_CAP_FMT_CASE_SENSITIVE */
} cfsk_volcaps;
int  cfsk_volume_caps(const char *mount_path, cfsk_volcaps *out); /* 0 ok, -1 errno */

#endif
```

### 3.2 MacxFS: support, lanes, generations

```swift
// Support/Observers.swift
public final class ObserverToken: Sendable {
    public init(_ cancel: @escaping @Sendable () -> Void)
    public func cancel()          // idempotent; also called from deinit
}

@MainActor
public final class Observers<Event> {
    public init()
    public func add(_ handler: @escaping @MainActor (Event) -> Void) -> ObserverToken
    public func send(_ event: Event)
    public var isEmpty: Bool { get }
}

// Support/MainThread.swift
/// Debug builds: preconditionFailure if called on the main thread. Release: no-op.
public func assertOffMain(_ function: StaticString = #function, file: StaticString = #fileID, line: UInt = #line)

// Support/PerfSignposts.swift
public enum PerfSignposts {
    public static let signposter: OSSignposter          // subsystem "com.macexplorer.app", category "perf"
    public static let navigate: StaticString            // "navigate"
    public static let enumerate: StaticString           // "enumerate"
    public static let firstBatch: StaticString          // "firstBatch"
    public static let firstPaint: StaticString          // "firstPaint"
    public static let sort: StaticString                // "sort"
    public static let iconFill: StaticString            // "iconFill"
}

// Lanes/Generation.swift
public struct Generation: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public static let initial: Generation               // raw 0
    public func next() -> Generation                    // raw + 1
    public static func < (lhs: Generation, rhs: Generation) -> Bool
}

// Lanes/Materialization.swift
/// Runs body synchronously on the current (lane) thread with dataless materialization off; restores the
/// previous policy afterwards. Never contains a suspension point. Call only from lane work.
public func withNoMaterialization<T>(_ body: () throws -> T) rethrows -> T

// Lanes/LaneContext.swift
public struct LaneContext: Sendable {
    public func heartbeat()                // call at least every 250 ms while making progress
    public var isCancelled: Bool { get }   // true once the awaiting Task was cancelled
    public var laneID: LaneID { get }
}

// Lanes/IOLane.swift
public struct LaneID: Hashable, Sendable, CustomStringConvertible { public let raw: UInt64 }
public enum LaneClass: Sendable, Hashable { case read, fileOp }

// Lanes/Watchdog.swift
public enum StallPolicy: Sendable, Hashable {
    case poison               // default: no heartbeat for stallTimeout → lane poisoned, notice .stalled
    case awaitingPermission   // TCC location without recorded outcome: notice .waitingForPermission, never poison
}
public enum StallNotice: Sendable, Equatable { case stalled, waitingForPermission, resumed }
public struct WatchdogConfig: Sendable, Equatable {
    public var stallTimeout: Duration      // default .seconds(2)
    public var tick: Duration              // default .milliseconds(250)
    public var lanesPerClass: Int          // default 2 (per volume, per LaneClass)
    public var poisonCap: Int              // default 4 (per volume, all classes)
    public static let `default`: WatchdogConfig
    public init(stallTimeout: Duration = .seconds(2), tick: Duration = .milliseconds(250), lanesPerClass: Int = 2, poisonCap: Int = 4)
}

// Lanes/LanePool.swift
public enum VolumeHealth: Sendable, Equatable { case healthy, unresponsive }
public enum LaneError: Error, Sendable, Equatable {
    case volumeUnresponsive(VolumeID)      // poisonCap reached; no reads issued until resetVolume
    case cancelled
}

public actor LanePool {
    public static let shared: LanePool
    public init(config: WatchdogConfig = .default)

    /// Runs `work` on a healthy lane of `volume`/`laneClass` (creating one if fewer than lanesPerClass exist,
    /// otherwise queuing on the least busy). Returns when `work` returns, however late. If the watchdog
    /// poisons the lane meanwhile, `onStall(.stalled)` fires (once), the lane leaves the pool forever, and
    /// `onStall(.resumed)` fires if work later heartbeats or returns.
    public func perform<T: Sendable>(
        on volume: VolumeID,
        _ laneClass: LaneClass = .read,
        stallPolicy: StallPolicy = .poison,
        onStall: (@Sendable (StallNotice) -> Void)? = nil,
        _ work: @escaping @Sendable (LaneContext) throws -> T
    ) async throws -> T

    public func health(of volume: VolumeID) -> VolumeHealth
    public func poisonedCount(of volume: VolumeID) -> Int
    public func liveLaneCount(of volume: VolumeID, _ laneClass: LaneClass) -> Int
    /// Called on remount/reappearance: forget the unresponsive mark and poisoned count.
    public func resetVolume(_ volume: VolumeID)
    public nonisolated var healthChanges: AsyncStream<(VolumeID, VolumeHealth)> { get }
}
```

### 3.3 MacxFS: store types

```swift
// Store/Entry.swift
public enum Kind: UInt8, Sendable, Codable { case file, directory, symlink, package, alias, other }

public struct EntryFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32)
    public static let dotName         = EntryFlags(rawValue: 1 << 0)   // name starts with "."
    public static let bsdHidden       = EntryFlags(rawValue: 1 << 1)   // UF_HIDDEN
    public static let locked          = EntryFlags(rawValue: 1 << 2)   // UF_IMMUTABLE or SF_IMMUTABLE
    public static let dataless        = EntryFlags(rawValue: 1 << 3)   // SF_DATALESS (cloud badge; never opened)
    public static let customIcon      = EntryFlags(rawValue: 1 << 4)   // finder kHasCustomIcon
    public static let degraded        = EntryFlags(rawValue: 1 << 5)   // per-entry ATTR_CMN_ERROR or missing attrs
    public static let extensionHidden = EntryFlags(rawValue: 1 << 6)   // finder kIsExtensionHidden
    public static let executable      = EntryFlags(rawValue: 1 << 7)   // access mask X_OK on a regular file
    public static let readable        = EntryFlags(rawValue: 1 << 8)   // access mask R_OK
    public static let writable        = EntryFlags(rawValue: 1 << 9)   // access mask W_OK
    public static let hasHardLinks    = EntryFlags(rawValue: 1 << 10)  // linkID != fileID
    public var isHidden: Bool { get }                                  // dotName || bsdHidden
}

public struct Entry: Sendable, Equatable {
    public var rowID: UInt64        // ATTR_CMNEXT_LINKID, else fileID
    public var fileID: UInt64       // inode
    public var size: Int64          // logical bytes; for directories: ATTR_DIR_ENTRYCOUNT (UI shows "--")
    public var allocSize: Int64
    public var mtime: Int64         // ns since 1970
    public var ctime: Int64         // creation, ns since 1970
    public var nameOffset: UInt32   // into the owning arena (Batch.names or EntryStore.names)
    public var nameLen: UInt16
    public var kind: Kind
    public var flags: EntryFlags
    public var typeIndex: UInt16    // TypeRegistry index
    public init(rowID: UInt64, fileID: UInt64, size: Int64, allocSize: Int64, mtime: Int64, ctime: Int64,
                nameOffset: UInt32, nameLen: UInt16, kind: Kind, flags: EntryFlags, typeIndex: UInt16)
    public var isFolderForSorting: Bool { get }   // kind == .directory (packages sort as files)
}

// Store/Batch.swift
public struct EntryError: Sendable, Equatable { public var index: UInt32; public var code: Int32 }

public struct Batch: Sendable {
    public var generation: Generation
    public var entries: [Entry]          // nameOffset relative to `names`
    public var names: [UInt8]            // concatenated UTF-8 names
    public var errors: [EntryError]      // index into `entries`
    public init(generation: Generation)
    public var count: Int { get }
    public func name(at index: Int) -> String
    public mutating func append(_ entry: Entry, nameBytes: UnsafeBufferPointer<UInt8>)  // rewrites nameOffset/nameLen
}

// Store/NameArena.swift
public struct NameArena: Sendable {
    public init()
    public private(set) var bytes: [UInt8]
    public mutating func append(_ bytes: some Collection<UInt8>) -> UInt32   // returns offset
    public func string(offset: UInt32, length: UInt16) -> String              // lossy-decoded if invalid UTF-8
    public func withBytes<R>(offset: UInt32, length: UInt16, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R
}

// Store/RowID.swift
public enum IdentityMode: Sendable, Hashable {
    case objectID                         // idStable volume: identity = Entry.rowID
    case name(caseSensitive: Bool)        // other volumes: identity = normalized name
}
public enum RowID: Hashable, Sendable {
    case object(UInt64)
    case name(String)                     // NFC; lowercased (locale-independent) when the volume is case-insensitive
}
public enum NameNormalizer {
    public static func nfc(_ name: String) -> String
    public static func identityName(_ name: String, caseSensitive: Bool) -> String
    /// Same-name test used by rename duplicate checks: NFC always, case-insensitive when !caseSensitive.
    public static func sameName(_ a: String, _ b: String, caseSensitive: Bool) -> Bool
}

// Store/TypeRegistry.swift
public final class TypeRegistry: Sendable {
    public static let shared: TypeRegistry
    public static let folderIndex: UInt16      // 0: public.folder
    public static let dataIndex: UInt16        // 1: public.data (no extension)
    public static let symlinkIndex: UInt16     // 2: public.symlink
    public init()
    /// Interns (lowercased extension, isDirectory). Thread-safe (Mutex). ~O(1) after first sighting.
    public func index(forExtension ext: Substring, isDirectory: Bool) -> UInt16
    public func type(at index: UInt16) -> UTType
    public func isPackage(_ index: UInt16) -> Bool               // directory + conforms to .package
    public func isApplication(_ index: UInt16) -> Bool
    public func localizedDescription(_ index: UInt16) -> String
    /// Rank by localizedDescription (localizedStandardCompare); recomputed when the table grows.
    public func kindRanks() -> (version: Int, ranks: [UInt16])
    public var version: Int { get }
}

// Store/EntryStore.swift
public struct EntryStore: Sendable {
    public init(identityMode: IdentityMode)
    public let identityMode: IdentityMode
    public private(set) var entries: [Entry]      // storage order (append order)
    public private(set) var names: NameArena
    public private(set) var order: [UInt32]       // display permutation: storage indices of visible rows
    public private(set) var version: UInt64       // incremented by every mutation
    public var count: Int { get }                 // entries.count
    public var visibleCount: Int { get }          // order.count

    // storage-index access
    public func entry(_ index: UInt32) -> Entry
    public func name(_ index: UInt32) -> String
    public func withNameBytes<R>(_ index: UInt32, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R
    public func identity(_ index: UInt32) -> RowID
    public func firstIndex(of id: RowID) -> UInt32?          // duplicates tolerated: first wins, never traps
    public func firstIndex(named name: String, caseSensitive: Bool) -> UInt32?   // O(n), NameNormalizer.sameName; hidden rows included
    public func errno(_ index: UInt32) -> Int32?

    // display-row access
    public func storageIndex(forRow row: Int) -> UInt32
    public func row(ofStorageIndex index: UInt32) -> Int?    // O(1) via inverse permutation
    public func row(of id: RowID) -> Int?

    // mutation
    public mutating func append(_ batch: Batch)              // O(batch); leaves `order` unchanged
    public mutating func setOrder(_ order: [UInt32])         // rebuilds inverse permutation
    @discardableResult
    public mutating func upsert(_ entry: Entry, name: String) -> UInt32   // replaces same identity or appends
    public mutating func remove(_ indices: Set<UInt32>)      // compacts storage; remaps order; O(n)
    public mutating func setError(_ code: Int32?, at index: UInt32)
}
```

### 3.4 MacxFS: reading

```swift
// Reader/ReadTypes.swift
public struct ReadOptions: Sendable, Hashable {
    public var directoriesOnly: Bool = false       // tree children
    public var noMaterialization: Bool = false     // background/tree re-reads (§4.2 list)
    public var permissionPending: Bool = false     // → StallPolicy.awaitingPermission
    public var forceFallback: Bool = false         // tests: readdir + fstatat path
    public var batchSize: Int = 2_000
    public var batchInterval: Duration = .milliseconds(8)
    public var bufferSize: Int = 256 * 1024
    public init()
}
public enum ReadEvent: Sendable {
    case batch(Batch)
    case stalled                  // watchdog: no progress for stallTimeout (lane poisoned)
    case waitingForPermission     // stalled while permissionPending
    case resumed                  // a stalled read made progress again
    case completed(ReadSummary)
    case failed(ReadFailure)      // open/read error of the directory itself
}
public struct ReadSummary: Sendable, Equatable {
    public var entryCount: Int
    public var degradedCount: Int
    public var usedFallback: Bool
    public var elapsed: Duration
}
public struct ReadFailure: Error, Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case open, read, unresponsiveVolume }
    public var code: Int32        // errno (ENOENT, ENOTDIR, EACCES, EPERM, ENXIO, ...)
    public var stage: Stage
}

// Reader/BulkReader.swift, FallbackReader.swift (synchronous; call only inside lane work)
public enum BulkReader {
    /// Reads `directory`, calling `emit` per batch (size/interval from options). Throws ReadFailure.
    /// Returns false from `emit` to stop early. Falls back to FallbackReader on ENOTSUP/EINVAL.
    public static func read(_ directory: URL, generation: Generation, options: ReadOptions,
                            types: TypeRegistry, context: LaneContext,
                            emit: (Batch) -> Bool) throws(ReadFailure) -> ReadSummary
}
public enum FallbackReader {
    public static func read(_ directory: URL, generation: Generation, options: ReadOptions,
                            types: TypeRegistry, context: LaneContext,
                            emit: (Batch) -> Bool) throws(ReadFailure) -> ReadSummary
}

// Reader/ItemReader.swift (synchronous; lane only)
public struct ItemReadResult: Sendable {
    public var batch: Batch          // entries for names that exist
    public var missing: [String]     // names that no longer exist
}
public enum ItemReader {
    public static func read(names: [String], in directory: URL, generation: Generation, types: TypeRegistry) -> ItemReadResult
}

// Reader/DirectoryReader.swift
public actor DirectoryReader {
    public init(volume: VolumeID, lanes: LanePool, types: TypeRegistry = .shared)
    public nonisolated let volume: VolumeID
    /// One stream per read; ends after .completed or .failed (or when the consumer cancels iteration,
    /// which cancels the lane work at the next batch boundary).
    public func read(_ directory: URL, generation: Generation, options: ReadOptions = ReadOptions()) -> AsyncStream<ReadEvent>
    /// Single-shot stat of names (watcher incremental path). Runs on a read lane.
    public func readItems(_ names: [String], in directory: URL, generation: Generation) async throws -> ItemReadResult
    /// Volumes.release: cancel in-flight reads, wait ≤ 1 s for their fds to close.
    public func cancelAll() async
}

// Reader/DirectoryReaders.swift
public final class DirectoryReaders: Sendable {
    public init(lanes: LanePool, mountTable: MountTableStore, types: TypeRegistry = .shared)
    public func reader(for directory: URL) -> DirectoryReader          // by MountTable volume, else VolumeID.unknown
    public func reader(for volume: VolumeID) -> DirectoryReader
    public func cancelAll(on volume: VolumeID) async
}
```

### 3.5 MacxFS: sorting

```swift
// Sort/ViewQuery.swift
public enum SortField: String, Sendable, Codable, CaseIterable { case name, dateModified, size, kind, dateCreated, fileExtension }
public struct SortDescriptor: Sendable, Codable, Hashable {
    public var field: SortField
    public var ascending: Bool
    public init(field: SortField, ascending: Bool)
    public static let `default`: SortDescriptor          // name, ascending
}
public struct ViewQuery: Sendable, Hashable {
    public var sort: SortDescriptor
    public var showHidden: Bool
    public var filter: String                             // "" = no filter
    public init(sort: SortDescriptor = .default, showHidden: Bool = false, filter: String = "")
}

// Sort/SortKeyColumn.swift
public struct SortKeyColumn: Sendable {
    public init()
    public var count: Int { get }
    public mutating func append(_ key: UnsafeRawBufferPointer)
    public mutating func append(contentsOf other: SortKeyColumn)
    public func withKey<R>(_ index: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
    public mutating func remove(_ indices: Set<UInt32>)   // mirrors EntryStore.remove compaction
    public mutating func replace(_ index: Int, with key: [UInt8])
}

// Sort/SortKeys.swift
public enum SortKeys {
    /// [kind byte: 0 folder / 1 other] + CFStringFold(case|diacritic|width, fixed en_US_POSIX locale) UTF-8 with
    /// digit runs encoded as [len byte][digits without leading zeros] (tie-break on original run length)
    /// + 0x00 + unfolded NFC bytes.
    public static func nameKey(_ name: String, isFolder: Bool) -> [UInt8]
    /// Same fold, no digit encoding, no kind prefix.
    public static func searchFold(_ text: String) -> [UInt8]
    /// Name keys for storage indices `range` of `store`, using concurrentPerform.
    public static func nameKeys(_ store: EntryStore, range: Range<Int>) -> SortKeyColumn
    public static func nameKeys(_ batch: Batch) -> SortKeyColumn
    public static func searchKeys(_ store: EntryStore) -> SortKeyColumn
}

// Sort/Sorter.swift
public enum Sorter {
    /// Visible storage indices of `store` in display order: hidden rows excluded unless query.showHidden,
    /// rows not matching query.filter (byte substring of searchKeys) excluded, folders first, then the sort
    /// field (name: memcmp of nameKeys; dates/size: integer key, name tie-break; kind: TypeRegistry rank
    /// then name; extension: folded extension then name). Size sort orders folders by name (their size is
    /// "--"). Descending reverses within each folders/files group; folders stay first.
    public static func permutation(_ store: EntryStore, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                   query: ViewQuery, kindRanks: [UInt16]) -> [UInt32]
    /// Loading path: merge an already-sorted run of new indices into a sorted permutation.
    public static func merge(_ sorted: [UInt32], _ run: [UInt32], store: EntryStore, nameKeys: SortKeyColumn,
                             query: ViewQuery, kindRanks: [UInt16]) -> [UInt32]
}
```

### 3.6 MacxFS: volumes

```swift
// Volumes/VolumeInfo.swift
public struct VolumeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String                       // "uuid:<volumeUUIDString>" or "mnt:<mount path>"
    public init(raw: String)
    public static let unknown: VolumeID           // "unknown"
}
public struct VolumeCapabilities: Sendable, Hashable, Codable {
    public var idStable: Bool       // VOL_CAP_FMT_PERSISTENTOBJECTIDS
    public var renameExcl: Bool     // VOL_CAP_INT_RENAME_EXCL
    public var clone: Bool          // VOL_CAP_INT_CLONE
    public var caseSensitive: Bool  // volumeSupportsCaseSensitiveNamesKey (cross-checked with VOL_CAP_FMT_CASE_SENSITIVE)
    public init(idStable: Bool, renameExcl: Bool, clone: Bool, caseSensitive: Bool)
    public var identityMode: IdentityMode { get }  // idStable ? .objectID : .name(caseSensitive:)
}
public struct VolumeInfo: Sendable, Hashable, Identifiable {
    public var id: VolumeID
    public var mountPoint: URL
    public var name: String                  // volumeLocalizedNameKey
    public var format: String                // volumeLocalizedFormatDescriptionKey
    public var isBoot: Bool
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isLocal: Bool
    public var isReadOnly: Bool
    public var isBrowsable: Bool             // shown in sidebar Locations
    public var totalCapacity: Int64?
    public var capabilities: VolumeCapabilities
    public init(id: VolumeID, mountPoint: URL, name: String, format: String, isBoot: Bool, isInternal: Bool,
                isRemovable: Bool, isEjectable: Bool, isLocal: Bool, isReadOnly: Bool, isBrowsable: Bool,
                totalCapacity: Int64?, capabilities: VolumeCapabilities)
}

// Volumes/MountTable.swift
public struct MountTable: Sendable, Equatable {
    public init(_ volumes: [VolumeInfo])
    public static let empty: MountTable
    public var volumes: [VolumeInfo] { get }
    /// Longest-prefix match of the standardized path against mount points (pure, in-memory).
    public func volume(containing path: String) -> VolumeInfo?
    public func isSameVolume(_ a: String, _ b: String) -> Bool
}
public final class MountTableStore: Sendable {          // Mutex-protected mirror for off-main readers
    public init(_ table: MountTable = .empty)
    public func current() -> MountTable
    public func update(_ table: MountTable)
}

// Volumes/VolumeScanner.swift
public protocol VolumeScanning: Sendable {
    /// Synchronous; called inside lane work. Includes hidden volumes (mount table needs them); isBrowsable marks sidebar ones.
    func scan() throws -> [VolumeInfo]
    /// volumeAvailableCapacityForImportantUsageKey, fallback volumeAvailableCapacityKey. Synchronous; lane only.
    func availableCapacity(of mountPoint: URL) -> Int64?
}
public struct SystemVolumeScanner: VolumeScanning { public init() }

public enum VolumeEvent: Sendable, Equatable {
    case didMount(URL), willUnmount(URL), didUnmount(URL), didRename(URL)
}
public protocol VolumeEventSource: Sendable {
    /// Starts delivering events (on the main actor). Implemented in Core/Platform with NSWorkspace.
    @MainActor func start(_ handler: @escaping @MainActor (VolumeEvent) -> Void)
}

// Volumes/Volumes.swift
@MainActor @Observable
public final class Volumes {
    public init(lanes: LanePool, scanner: any VolumeScanning = SystemVolumeScanner(), events: (any VolumeEventSource)?)
    public private(set) var list: [VolumeInfo]          // all mounted
    public var browsable: [VolumeInfo] { get }          // sidebar Locations
    public private(set) var mountTable: MountTable
    public let mountTableStore: MountTableStore
    public func start() async                           // initial scan on a lane + subscribe to events
    public func refresh() async
    public func handle(_ event: VolumeEvent) async      // rescan; willUnmount → release
    public func volume(for url: URL) -> VolumeInfo?     // in-memory
    public func cachedAvailableCapacity(_ volume: VolumeID) -> Int64?
    public func refreshAvailableCapacity(_ volume: VolumeID) async -> Int64?   // lane, then cached
    /// Runs every release handler (cancel reads ≤1 s, stop watchers, pause jobs, move windows home).
    public func release(_ volume: VolumeID) async
    public func addReleaseHandler(_ handler: @escaping @MainActor (VolumeID) async -> Void) -> ObserverToken
    public func observe(_ handler: @escaping @MainActor ([VolumeInfo]) -> Void) -> ObserverToken
}
```

### 3.7 Core: folder model

```swift
// Folder/FolderState.swift
public enum Reason: Sendable, Equatable {
    case notFound, notADirectory, permissionPOSIX, permissionTCC, volumeGone, other(Int32)
    public init(errno: Int32)   // ENOENT→notFound, ENOTDIR→notADirectory, EACCES→permissionPOSIX, EPERM→permissionTCC, ENXIO/ENODEV→volumeGone
}
public enum FolderState: Sendable, Equatable {
    case loading, partial, complete, error(Reason), unresponsive, waitingForPermission
}

// Folder/Change.swift
/// Applied in array order inside one beginUpdates/endUpdates. Each change's indices are relative to the
/// row state produced by the preceding changes (NSTableView semantics). `reload` changes come last and
/// use final indices.
public enum Change: Sendable, Equatable {
    case insert(IndexSet)
    case remove(IndexSet)
    case reload(IndexSet)
    case move(from: Int, to: Int)
    case reset
}
public struct ChangeSet: Sendable, Equatable {
    public var changes: [Change]
    public init(_ changes: [Change])
    public static let reset: ChangeSet
    public var touchedRowCount: Int { get }
    public var requiresReloadData: Bool { get }   // contains .reset or touchedRowCount > 1_000
    public var isEmpty: Bool { get }
}

// Folder/StoreDiff.swift
public struct Replacement: Sendable, Equatable { public var old: RowID; public var new: RowID }
public struct DiffResult: Sendable, Equatable {
    public var changes: ChangeSet
    public var replacements: [Replacement]   // atomic-save replacements (move selection/anchor/rename state)
}
public enum StoreDiff {
    /// Visible-order diff by identity: match identity; within the batch, disappeared identity + new identity
    /// with the same name = replacement → reload; same identity, changed mtime/size/name → reload (+ move if
    /// position changed); rest → remove/insert. Duplicate identities never trap.
    public static func diff(old: EntryStore, new: EntryStore) -> DiffResult
}

// Folder/Selection.swift
public struct Selection: Sendable, Equatable {
    public private(set) var ids: Set<RowID>
    public private(set) var rows: IndexSet          // display rows of `ids` in the current order
    public private(set) var anchor: RowID?          // ⇧ range anchor
    public private(set) var cursor: RowID?          // keyboard focus row
    public var count: Int { get }
    public var isEmpty: Bool { get }
    public static let empty: Selection
}
public enum SelectionCommand: Sendable, Equatable {
    case set(IndexSet, cursor: Int?)                // plain click / arrows
    case toggle(Int)                                // ⌘-click
    case extend(to: Int)                            // ⇧-click / ⇧-arrow from anchor
    case add(IndexSet)                              // additive rubber band
    case all, none, invert
    case names([String])                            // select by name (after paste/new/address "file")
}
public struct SelectionSummary: Sendable, Equatable {
    public var count: Int
    public var files: Int
    public var folders: Int
    public var bytes: Int64                         // files only; folders excluded in Phase 1
}

// Folder/NameRules.swift
public enum NameProblem: Sendable, Equatable { case empty, containsSlash, tooLong, duplicate }
public enum NameWarning: Sendable, Equatable { case extensionChanged(from: String, to: String), becomesHidden }
public enum NameValidation: Sendable, Equatable {
    case ok(warnings: [NameWarning])
    case invalid(NameProblem)
}
public enum NameRules {
    /// `exists` is answered from the full EntryStore (hidden rows included), NameNormalizer.sameName semantics.
    /// `original` nil for new items. A case/normalization-only change of `original` is not a duplicate.
    public static func validate(_ proposed: String, original: String?, caseSensitive: Bool,
                                exists: (String) -> Bool) -> NameValidation
}

// Folder/LocalChange.swift
public struct LocalChange: Sendable, Equatable {
    public struct Rename: Sendable, Equatable { public var from: String; public var to: String }
    public var directory: URL
    public var added: [String]
    public var removed: [String]
    public var renamed: [Rename]
    public var modified: [String]
    public var select: [String]          // select these names once present
    public var beginRename: String?      // enter inline rename on this name once present (new items)
    public init(directory: URL, added: [String] = [], removed: [String] = [], renamed: [Rename] = [],
                modified: [String] = [], select: [String] = [], beginRename: String? = nil)
}

// Support/ChangeBus.swift
@MainActor
public final class ChangeBus {
    public init()
    public func post(_ changes: [LocalChange])
    public func observe(directory: URL, _ handler: @escaping @MainActor (LocalChange) -> Void) -> ObserverToken
}

// Folder/FramePacer.swift
public protocol FramePacer: Sendable { func nextFrame() async }
public struct TimerFramePacer: FramePacer {
    public init(interval: Duration = .milliseconds(8))
    public func nextFrame() async
}

// Folder/FolderModel.swift
public enum RelocationReason: Sendable, Equatable { case movedOrDeleted(name: String), volumeGone }
public enum FolderEvent: Sendable {
    case changes(ChangeSet)
    case state(FolderState)
    case selection(Selection)
    case beginRename(row: Int)
    case relocate(to: URL, reason: RelocationReason)   // window navigates; banner for .movedOrDeleted
    case query(ViewQuery)
}

@MainActor
public struct FolderContext {
    public var readers: DirectoryReaders
    public var lanes: LanePool
    public var volumes: Volumes
    public var changeBus: ChangeBus
    public var types: TypeRegistry
    public var pacer: any FramePacer
    public var makeWatcher: @MainActor (URL, UInt64, @escaping @Sendable (WatchEvent) -> Void) -> any ContentWatching
    public var permissionPending: @MainActor (URL) -> Bool     // Settings TCC outcome lookup
    public var recordPermissionOutcome: @MainActor (URL, Bool) -> Void   // granted true / EPERM false
    public init(readers: DirectoryReaders, lanes: LanePool, volumes: Volumes, changeBus: ChangeBus,
                types: TypeRegistry = .shared, pacer: any FramePacer = TimerFramePacer(),
                makeWatcher: @escaping @MainActor (URL, UInt64, @escaping @Sendable (WatchEvent) -> Void) -> any ContentWatching,
                permissionPending: @escaping @MainActor (URL) -> Bool,
                recordPermissionOutcome: @escaping @MainActor (URL, Bool) -> Void)
}

@MainActor
public final class FolderModel {
    public init(directory: URL, context: FolderContext, query: ViewQuery)
    public let directory: URL
    public private(set) var state: FolderState
    public private(set) var store: EntryStore
    public private(set) var query: ViewQuery
    public private(set) var selection: Selection
    public private(set) var generation: Generation
    public var volume: VolumeInfo? { get }
    public var caseSensitive: Bool { get }

    public func start()                        // capture FSEvents ID, read, then watch
    public func refresh()                      // F5/⌘R: re-read + diff, keeps rows, never → .loading
    public func retry()                        // from .error/.unresponsive: → .loading with new generation
    public func close()                        // cancel read, stop watcher, drop observers

    public var rowCount: Int { get }
    public func entry(atRow row: Int) -> Entry
    public func name(atRow row: Int) -> String
    public func url(atRow row: Int) -> URL
    public func identity(atRow row: Int) -> RowID
    public func row(of id: RowID) -> Int?
    public func row(named name: String) -> Int?
    public func errno(atRow row: Int) -> Int32?

    public func setQuery(_ query: ViewQuery)   // re-sort/filter off main; one .changes(.reset)
    public func select(_ command: SelectionCommand)
    public var selectedURLs: [URL] { get }     // display order
    public var selectionSummary: SelectionSummary { get }

    public var scrollAnchor: RowID?            // views set on scroll; restored after resets
    public var cutNames: Set<String>           // from Clipboard; views dim these rows
    public func isCut(row: Int) -> Bool

    public func validateName(_ proposed: String, renamingRow row: Int?) -> NameValidation
    public func applyLocalChange(_ change: LocalChange)   // also wired automatically through ChangeBus

    public func observe(_ handler: @escaping @MainActor (FolderEvent) -> Void) -> ObserverToken
}
```

### 3.8 Core: watcher

```swift
// Watch/WatchTypes.swift (created by P1-10 so FolderContext compiles; P1-11 adds the rest)
public enum WatchEvent: Sendable, Equatable {
    case items([String])     // ≤256 names directly inside the folder, coalesced
    case fullRescan          // >256, MustScanSubDirs (folder or ancestor), UserDropped, KernelDropped, EventIdsWrapped
    case rootChanged         // RootChanged / ItemRemoved|ItemRenamed on the folder itself
}
public struct RawFSEvent: Sendable, Equatable {
    public var path: String
    public var flags: UInt32       // FSEventStreamEventFlags
    public var id: UInt64
    public init(path: String, flags: UInt32, id: UInt64)
}
public protocol ContentWatching: AnyObject, Sendable {
    func start()
    func stop()
    var lastEventID: UInt64 { get }
}
public final class NoopWatcher: ContentWatching { public init() }   // lastEventID 0; start/stop do nothing

// Watch/EventClassifier.swift
public enum EventClassifier {
    public static let incrementalLimit: Int   // 256
    /// Pure. Drops events whose parent is not exactly `folder` (except rescan/root flags). nil = nothing to do.
    public static func classify(_ events: [RawFSEvent], folder: String) -> WatchEvent?
}

// Watch/Watcher.swift
public final class Watcher: ContentWatching {
    public static func currentEventID() -> UInt64           // FSEventsGetCurrentEventId()
    /// FileEvents|NoDefer|WatchRoot, latency 100 ms, private serial queue. Handler is called on that queue.
    public init(directory: URL, since eventID: UInt64, latency: Duration = .milliseconds(100),
                handler: @escaping @Sendable (WatchEvent) -> Void)
    public func start()
    public func stop()
    public var lastEventID: UInt64 { get }
}

// Watch/TreeWatcher.swift
@MainActor
public final class TreeWatcher {
    public static let sourceCap: Int     // 256
    public init(onChange: @escaping @MainActor (URL) -> Void)
    /// false when over the cap or the volume is not local: caller re-reads on re-expand / window key.
    @discardableResult public func watch(_ directory: URL, isLocalVolume: Bool) -> Bool
    public func unwatch(_ directory: URL)
    public func unwatchAll(under volumeMountPoint: URL)
    public var count: Int { get }
}
```

### 3.9 Core: settings

```swift
// Settings/SettingsStorage.swift
@MainActor public protocol SettingsStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}
@MainActor public final class UserDefaultsStorage: SettingsStorage { public init(_ defaults: UserDefaults = .standard) }  // app only
@MainActor public final class FileSettingsStorage: SettingsStorage { public init(fileURL: URL) }  // --state-dir
@MainActor public final class InMemorySettingsStorage: SettingsStorage { public init() }           // tests

// Settings/SettingsTypes.swift
public enum ViewMode: String, Sendable, Codable, CaseIterable { case details, icons }
public enum IconSize: String, Sendable, Codable, CaseIterable { case small, medium, large; public var points: Double { get } } // 32/64/128
public enum Density: String, Sendable, Codable, CaseIterable { case compact, regular, comfortable; public var rowHeight: Double { get } } // 20/24/30
public enum ColumnID: String, Sendable, Codable, CaseIterable { case name, dateModified, size, kind, dateCreated, fileExtension; public var sortField: SortField { get } }
public struct ColumnSetting: Sendable, Codable, Hashable { public var id: ColumnID; public var width: Double; public var visible: Bool; public init(id: ColumnID, width: Double, visible: Bool) }
public enum StartupFolder: Sendable, Codable, Hashable { case home, lastLocation, custom(URL) }
public enum OpenFoldersIn: String, Sendable, Codable { case sameWindow, newWindow }
public enum ReturnKeyBehavior: String, Sendable, Codable { case open, rename }
public enum DateStyle: String, Sendable, Codable { case relative, absolute }
public enum SidebarSection: String, Sendable, Codable, CaseIterable { case favorites, locations, folders }
public enum DefaultFavorite: String, Sendable, Codable, CaseIterable { case home, desktop, documents, downloads, applications }
public enum TCCOutcome: String, Sendable, Codable { case granted, denied }
public enum ProtectedLocation: Sendable, Codable, Hashable {
    case desktop, documents, downloads, iCloudDrive
    case removableVolume(VolumeID), networkVolume(VolumeID)
}

// Settings/Favorites.swift
public struct Favorite: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var bookmark: Data
    public var displayName: String
    public var lastKnownPath: String
    public init(id: UUID = UUID(), bookmark: Data, displayName: String, lastKnownPath: String)
}
public struct ResolvedFavorite: Sendable, Hashable { public var favorite: Favorite; public var url: URL?; public var isStale: Bool }
/// Each bookmark resolves in its own LanePool.perform on VolumeID.unknown, so one hung network bookmark
/// poisons only its lane and the others still resolve.
public enum FavoritesResolver {
    public static func makeFavorite(for url: URL, lanes: LanePool) async throws -> Favorite
    public static func resolve(_ favorites: [Favorite], lanes: LanePool) async -> [ResolvedFavorite]
    public static func defaultFavoriteURL(_ f: DefaultFavorite, home: URL) -> URL
}

// Settings/ProtectedLocations.swift
public enum ProtectedLocations {
    /// Pure, in-memory: classifies a URL (home-relative Desktop/Documents/Downloads, iCloud Drive, or the volume kind).
    public static func classify(_ url: URL, home: URL, volume: VolumeInfo?) -> ProtectedLocation?
}

// Settings/Settings.swift
@MainActor @Observable
public final class Settings {
    public static let schemaVersion: Int          // 1
    public init(storage: any SettingsStorage, home: URL = FileManager.default.homeDirectoryForCurrentUser)
    public let home: URL
    public var startupFolder: StartupFolder        // .home
    public var openFoldersIn: OpenFoldersIn        // .sameWindow
    public var returnKey: ReturnKeyBehavior        // .open
    public var terminalApp: URL?                   // nil = /System/Applications/Utilities/Terminal.app
    public var viewMode: ViewMode                  // .details
    public var iconSize: IconSize                  // .medium
    public var density: Density                    // .regular
    public var columns: [ColumnSetting]            // array order = display order
    public var sort: SortDescriptor                // .default
    public var showHidden: Bool                    // false
    public var commandBarVisible: Bool             // true
    public var autoRevealInTree: Bool              // true
    public var dateStyle: DateStyle                // .relative
    public var favorites: [Favorite]
    public var hiddenDefaultFavorites: Set<DefaultFavorite>
    public var showICloudInSidebar: Bool           // true
    public var showExternalVolumesInSidebar: Bool  // true
    public var collapsedSections: Set<SidebarSection>
    public var confirmBeforeTrash: Bool            // false
    public var confirmBeforeDelete: Bool { get }   // always true (locked on)
    public var showFullPathInTitle: Bool           // false
    public var onboardingCompleted: Bool           // false
    public var lastLocation: URL?
    public var recentLocations: [String]           // ≤ 20, most recent first
    public func addRecentLocation(_ path: String)
    public func tccOutcome(for location: ProtectedLocation) -> TCCOutcome?
    public func recordTCCOutcome(_ outcome: TCCOutcome, for location: ProtectedLocation)
    public func viewQuery() -> ViewQuery           // sort + showHidden, empty filter
}
```

### 3.10 Core: commands, keys, navigation

```swift
// Commands/Command.swift
public enum Command: String, Sendable, Codable, CaseIterable {
    // open
    case open, openInNewWindow, showPackageContents, openInTerminal, revealInFinder
    // edit / clipboard (responder-chain standard selectors)
    case cut, copy, paste, moveItemHere, selectAll, undo, redo
    // selection
    case selectNone, invertSelection
    // file
    case rename, moveToTrash, deletePermanently, duplicate, makeAlias, makeSymlink
    case newFolder, newTextFile, newEmptyFile, copyAsPath, properties, share
    // navigation / focus
    case back, forward, up, focusAddressBar, focusSearch, cycleFocusForward, cycleFocusBackward, refresh
    // window / app
    case newWindow, closeWindow, showOperations
    // view
    case viewAsDetails, viewAsIcons, iconSizeSmall, iconSizeMedium, iconSizeLarge
    case densityCompact, densityRegular, densityComfortable, toggleHidden, toggleCommandBar
    case sortByName, sortByDateModified, sortBySize, sortByKind, sortByDateCreated, sortAscending, sortDescending
    // sidebar / volumes
    case eject, removeFromFavorites
    // escape: clear cut marks / cancel inline state
    case cancelOperation

    /// "cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:", "cancelOperation:" for the standard ones;
    /// otherwise "macx_<rawValue>:" (e.g. "macx_moveToTrash:").
    public var selectorName: String { get }
}

// Commands/KeyChord.swift
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift   = KeyModifiers(rawValue: 1 << 3)
}
public enum Key: Hashable, Sendable {
    case character(String)        // lowercased base character with no modifiers applied
                                  // (NSEvent.characters(byApplyingModifiers: [])), e.g. "c", "[", "." for ⌘⇧.
    case up, down, left, right
    case returnKey, enter, tab, escape, space
    case backspace                // ⌫ (delete backward)
    case forwardDelete            // Del / fn⌫
    case function(Int)            // F1…F20
}
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public var key: Key
    public var modifiers: KeyModifiers
    public init(_ key: Key, _ modifiers: KeyModifiers = [])
    /// Parses "cmd+shift+n", "F2", "opt+left", "ctrl+c", "fn+delete" (= forwardDelete), "return", "esc".
    public init?(parsing text: String)
}

// Commands/KeyMap.swift
public enum KeyMap {
    public static func primary(_ command: Command) -> KeyChord?          // menu key equivalent (§5.6)
    public static func alternates(_ command: Command) -> [KeyChord]      // content/sidebar only
    /// Commands whose primary is also a text-editing key: open(⌘↓), up(⌘↑), moveToTrash(⌘⌫),
    /// deletePermanently(⌥⌘⌫), back(⌘[), forward(⌘]), rename(F2), duplicate(⌘D).
    public static let collidesWithTextEditing: Set<Command>
}

// Commands/KeyDispatcher.swift
public enum FocusContext: Sendable, Hashable {
    case content, sidebarFavorites, sidebarLocations, sidebarFolders, sidebarVolumeRoot, addressBar, fieldEditor
}
public struct KeyDispatcher: Sendable {
    public init(returnKey: ReturnKeyBehavior)
    /// Alternates only (Return/⌥Return, Del/⇧Del, ⌃X/⌃C/⌃V/⌃Z/⌃A, ⌘Y, ⌫, ⌥←/⌥→/⌥↑, ⌥D, F4, F3, F5, ⌘⇧R,
    /// Tab/⇧Tab, Esc). Always nil for .fieldEditor and .addressBar.
    public func command(for chord: KeyChord, in focus: FocusContext) -> Command?
}

// Commands/CommandAvailability.swift
public struct CommandState: Sendable, Equatable {
    public var selectionCount: Int
    public var singleFolderSelected: Bool
    public var canPaste: Bool
    public var canUndo: Bool
    public var canRedo: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var canGoUp: Bool
    public var targetIsEjectable: Bool
    public var targetIsPackage: Bool
    public var folderIsReadOnly: Bool
    public init(selectionCount: Int = 0, singleFolderSelected: Bool = false, canPaste: Bool = false,
                canUndo: Bool = false, canRedo: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false,
                canGoUp: Bool = false, targetIsEjectable: Bool = false, targetIsPackage: Bool = false,
                folderIsReadOnly: Bool = false)
}
public enum CommandAvailability {
    /// Encodes §5.3 enablement and the §5.4 sidebar table (e.g. Favorites: Del = removeFromFavorites,
    /// ⇧Del/⌘X/⌘D/F2 disabled; Locations: ⌘E eject, Del/⇧Del/⌘X/⌘D/F2 disabled).
    public static func isEnabled(_ command: Command, focus: FocusContext, state: CommandState) -> Bool
    /// Sidebar remaps (Favorites: moveToTrash → removeFromFavorites). Identity elsewhere.
    public static func effectiveCommand(_ command: Command, focus: FocusContext) -> Command?
}

// Navigation/NavigationHistory.swift
public struct NavigationHistory: Sendable, Equatable {
    public init(current: URL)
    public private(set) var current: URL
    public private(set) var backList: [URL]       // most recent last
    public private(set) var forwardList: [URL]    // next first
    public mutating func visit(_ url: URL)        // clears forwardList; ignores visiting current
    public mutating func goBack() -> URL?
    public mutating func goForward() -> URL?
    public mutating func jump(toBackIndex index: Int) -> URL?
    public mutating func jump(toForwardIndex index: Int) -> URL?
    public var canGoBack: Bool { get }
    public var canGoForward: Bool { get }
}

// Navigation/AddressResolver.swift
public enum AddressResult: Sendable, Equatable {
    case folder(URL)
    case file(parent: URL, name: String)
    case notFound(String)       // the input text
    case noAccess(String)
}
public enum AddressResolver {
    /// Pure: /abs, ~, ~/rel, file:// URLs, relative to `current`; standardizes "." and "..".
    public static func parse(_ input: String, current: URL, home: URL) -> URL?
    /// parse + lstat/stat on a read lane.
    public static func resolve(_ input: String, current: URL, home: URL, lanes: LanePool, volume: VolumeID) async -> AddressResult
}

// Navigation/PathCompletion.swift
public enum PathCompletion {
    /// Subfolder names of the parent of `partial` starting with its last component (case-insensitive), ≤ 50.
    public static func complete(_ partial: String, current: URL, home: URL, lanes: LanePool, volume: VolumeID) async -> [String]
}
```

### 3.11 Core: LaunchServices, open, eject, clipboard, drop policy, properties

```swift
// LaunchServices/LaunchServices.swift
public struct AppInfo: Sendable, Hashable, Identifiable {
    public var id: URL { get }           // url
    public var url: URL
    public var name: String
    public var bundleIdentifier: String?
    public init(url: URL, name: String, bundleIdentifier: String?)
}
public protocol LaunchServicesProviding: Sendable {
    func applications(toOpen file: URL) async -> [AppInfo]          // urlsForApplications(toOpen:)
    func defaultApplication(toOpen file: URL) async -> AppInfo?     // urlForApplication(toOpen: fileURL)
    func appInfo(at appURL: URL) async -> AppInfo?
    func open(_ files: [URL]) async throws                          // default apps
    func open(_ files: [URL], withApplicationAt app: URL) async throws
    func setDefaultApplication(_ app: URL, forContentTypeOf file: URL) async throws
    func setDefaultApplication(_ app: URL, forFile file: URL) async throws
    func revealInFinder(_ urls: [URL]) async
}

// LaunchServices/LaunchServicesCache.swift
@MainActor
public final class LaunchServicesCache {
    public init(provider: any LaunchServicesProviding, types: TypeRegistry = .shared)
    public let provider: any LaunchServicesProviding
    /// Cache hit or nil (a miss schedules a background fetch; observers fire when it lands). Never blocks.
    public func cachedApplications(for file: URL, typeIndex: UInt16) -> [AppInfo]?
    public func cachedDefault(for file: URL) -> AppInfo??         // .some(nil) = known "no default"
    public func prefetch(file: URL, typeIndex: UInt16)
    public func invalidate(file: URL)                              // Watcher change / default changed
    public func observe(_ handler: @escaping @MainActor (URL) -> Void) -> ObserverToken
}

// LaunchServices/FakeLaunchServices.swift
public final class FakeLaunchServices: LaunchServicesProviding {   // Mutex-protected state, Sendable
    public init(apps: [AppInfo] = [], defaultApp: AppInfo? = nil)
    public func opened() -> [(files: [URL], app: URL?)]
    public func defaultsSet() -> [(app: URL, file: URL, forType: Bool)]
    // + all LaunchServicesProviding requirements
}

// Platform/WorkspaceLaunchServices.swift (imports AppKit)
public final class WorkspaceLaunchServices: LaunchServicesProviding { public init(lanes: LanePool) }

// Open/OpenPlanner.swift
public struct OpenItem: Sendable, Equatable {
    public var url: URL
    public var kind: Kind
    public var isApplication: Bool
    public init(url: URL, kind: Kind, isApplication: Bool)
}
public enum OpenAction: Sendable, Equatable {
    case navigate(URL)                 // folder in place
    case openInNewWindow(URL)          // ⌘-double-click, or folders of a multi-selection
    case launchApplication(URL)
    case openDocuments([URL])          // default apps
    case brokenLink(URL)               // "The original item can't be found" (Delete / Fix…)
}
public struct OpenPlan: Sendable, Equatable {
    public var actions: [OpenAction]
    public var needsConfirmation: Bool // more than 10 folders would open in new windows
}
public enum OpenPlanner {
    /// Resolves aliases/symlinks on a read lane; packages other than apps are documents.
    @MainActor public static func plan(_ items: [OpenItem], newWindow: Bool, lanes: LanePool, volumes: Volumes) async -> OpenPlan
}

// Volumes/EjectCoordinator.swift
public enum EjectError: Error, Sendable, Equatable {
    case busy(processes: [String])     // names from lsof, excluding our own PID
    case failed(code: Int32, message: String)
}
public protocol Ejecting: Sendable {
    func eject(_ mountPoint: URL) async throws(EjectError)
    func blockingProcesses(_ mountPoint: URL, timeout: Duration) async -> [String]   // ours excluded
    func onlyOwnProcessHolds(_ mountPoint: URL, timeout: Duration) async -> Bool
}
@MainActor
public final class EjectCoordinator {
    public init(volumes: Volumes, ejector: any Ejecting)
    /// release → eject; if busy and only we hold it, release once more and retry once.
    public func eject(_ volume: VolumeInfo) async throws(EjectError)
}
// Platform/WorkspaceEjector.swift
public struct WorkspaceEjector: Ejecting { public init(lanes: LanePool) }
// Platform/WorkspaceVolumeEvents.swift
public struct WorkspaceVolumeEvents: VolumeEventSource { public init() }

// Clipboard/PasteboardBackend.swift
@MainActor public protocol PasteboardBackend: AnyObject {
    var changeCount: Int { get }
    /// One public.file-url item per URL + NSFilenamesPboardType + plain-text paths (+ cut marker). Returns new changeCount.
    @discardableResult func writeFileURLs(_ urls: [URL], cutMarker: Bool) -> Int
    func readFileURLs() -> [URL]
    func hasFileURLs() -> Bool
    func hasCutMarker() -> Bool
}
@MainActor public final class InMemoryPasteboard: PasteboardBackend {
    public init()
    public func simulateExternalCopy(_ urls: [URL])   // bumps changeCount, no marker (tests: "Finder copied")
}
// Platform/SystemPasteboard.swift
@MainActor public final class SystemPasteboard: PasteboardBackend {
    public static let cutMarkerType: String           // "com.macexplorer.cut"
    public init(name: String?)                        // nil = .general (app); tests/scenarios pass a private name
}

// Clipboard/Clipboard.swift
public enum PasteOperation: Sendable, Equatable { case copy, move }
public struct PastePlan: Sendable, Equatable {
    public var sources: [URL]
    public var destination: URL
    public var operation: PasteOperation
    public var isNoOp: Bool                           // cut-paste into the items' own folder: do nothing, clear cut
}
@MainActor
public final class Clipboard {
    public init(backend: any PasteboardBackend)
    public func copy(_ urls: [URL])
    public func cut(_ urls: [URL])
    /// Valid only while backend.changeCount == the count recorded at cut time, in this process.
    public var cutURLs: Set<URL> { get }
    public func cutNames(in directory: URL) -> Set<String>
    public func revalidate()                          // on app activation and after every command
    public func clearCut()                            // Esc: rewrite URLs without the marker
    public var canPaste: Bool { get }
    /// moveItemHere: ⌥⌘V (move whatever file URLs are present). Returns nil when nothing pasteable.
    public func pastePlan(into folder: URL, moveItemHere: Bool) -> PastePlan?
    public func didPaste(_ plan: PastePlan)           // move done → clear cut state
    public func observe(_ handler: @escaping @MainActor () -> Void) -> ObserverToken   // cut set changed
}

// Drag/DropPolicy.swift
public enum DragOperation: Sendable, Equatable { case copy, move, alias, menu, none }
public struct DragModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let option  = DragModifiers(rawValue: 1 << 0)
    public static let command = DragModifiers(rawValue: 1 << 1)
    public static let control = DragModifiers(rawValue: 1 << 2)
}
public enum DropPolicy {
    public static let secondaryDragType: String       // "com.macexplorer.secondary-drag"
    /// Pure, in-memory, no file-system calls. none if any source is the destination or an ancestor of it.
    /// Default: move same volume / copy cross volume; ⌥ copy; ⌘ move; ⌥⌘ alias; ⌃ or secondary drag → menu.
    public static func operation(sources: [String], destination: String, modifiers: DragModifiers,
                                 isSecondaryDrag: Bool, mountTable: MountTable) -> DragOperation
    public static func isSelfOrDescendant(source: String, destination: String) -> Bool
}

// Properties/ItemProperties.swift
public enum Tri: Sendable, Equatable { case on, off, mixed }
public struct XattrInfo: Sendable, Equatable { public var name: String; public var size: Int }
public struct QuarantineInfo: Sendable, Equatable { public var raw: Data; public var agentName: String?; public var date: Date? }
public struct ItemProperties: Sendable, Equatable {
    public var url: URL
    public var name: String
    public var displayName: String
    public var kindDescription: String
    public var typeIdentifier: String
    public var kind: Kind
    public var logicalSize: Int64?
    public var physicalSize: Int64?
    public var created: Date?
    public var modified: Date?
    public var lastOpened: Date?
    public var isLocked: Bool
    public var isHidden: Bool
    public var isExtensionHidden: Bool
    public var mode: UInt16
    public var ownerID: UInt32
    public var groupID: UInt32
    public var ownerName: String
    public var groupName: String
    public var isOwnedByCurrentUser: Bool
    public var aclEntries: [String]
    public var inode: UInt64
    public var volumeName: String
    public var whereFroms: [String]
    public var quarantine: QuarantineInfo?
    public var xattrs: [XattrInfo]
}
public struct MultiProperties: Sendable, Equatable {
    public var count: Int
    public var files: Int
    public var folders: Int
    public var totalSize: Int64
    public var locked: Tri
    public var hidden: Tri
    public var extensionHidden: Tri
}
public struct VolumeProperties: Sendable, Equatable {
    public var volume: VolumeInfo
    public var capacity: Int64?
    public var available: Int64?
    public var used: Int64? { get }
}
public enum PermissionAccess: String, Sendable, CaseIterable { case readWrite, readOnly, writeOnly, noAccess }
public enum PermissionClass: Sendable, CaseIterable { case owner, group, everyone }
public enum PermissionModel {
    public static func access(_ mode: UInt16, _ who: PermissionClass) -> PermissionAccess
    public static func applying(_ access: PermissionAccess, _ who: PermissionClass, to mode: UInt16) -> UInt16
    public static func isExecutable(_ mode: UInt16) -> Bool
}

// Properties/PropertiesLoader.swift (all reads on lanes under withNoMaterialization)
public enum PropertiesLoader {
    public static func load(_ url: URL, lanes: LanePool, volume: VolumeID) async throws -> ItemProperties
    public static func loadMany(_ urls: [URL], lanes: LanePool, volume: VolumeID) async throws -> MultiProperties
    public static func loadVolume(_ volume: VolumeInfo, scanner: any VolumeScanning, lanes: LanePool) async -> VolumeProperties
}

// Properties/FolderCounter.swift
public struct CountProgress: Sendable, Equatable {
    public var files: Int
    public var folders: Int
    public var bytes: Int64
    public var finished: Bool
}
public enum FolderCounter {
    /// fts(FTS_PHYSICAL|FTS_XDEV) under no-materialization on a read lane; ~10 Hz updates; cancel by
    /// ending iteration or cancelling the consuming Task. Never follows symlinks.
    public static func count(_ url: URL, lanes: LanePool, volume: VolumeID) -> AsyncStream<CountProgress>
}
```

### 3.12 Core: support (environment, state, launch options)

```swift
// Support/StatePaths.swift
public struct StatePaths: Sendable, Equatable {
    public var root: URL                       // ~/Library/Application Support/macExplorer, or --state-dir
    public var journal: URL { get }            // root/journal.json
    public var settingsFile: URL { get }       // root/settings.json (FileSettingsStorage, sandbox mode only)
    public init(root: URL)
    public static func standard() -> StatePaths
}

// Support/LaunchOptions.swift
public struct LaunchOptions: Sendable, Equatable {
    public var root: URL?                  // --root <dir>: first window opens here; disables restoration
    public var stateDirectory: URL?        // --state-dir <dir>: journal + settings.json + recents; required with --root/--scenario
    public var sandboxTrash: URL?          // --sandbox-trash <dir>: SandboxTrash instead of SystemTrash
    public var pasteboardName: String?     // --pasteboard <name>: private NSPasteboard
    public var fakeLaunchServices: Bool    // --fake-launch-services
    public var skipOnboarding: Bool        // --skip-onboarding
    public var scenario: URL?              // --scenario <file.json>
    public var scenarioOutput: URL?        // --scenario-output <file.json>
    public var smokeExitAfter: Duration?   // --smoke-exit-after <seconds>: write <state-dir>/smoke.json then exit 0
    public init()
    public var isSandboxed: Bool { get }   // stateDirectory != nil
    public static func parse(_ arguments: [String]) throws(LaunchOptionsError) -> LaunchOptions   // ignores -NS*/-Apple* pairs
}
public enum LaunchOptionsError: Error, Sendable, Equatable {
    case missingValue(String)
    case unknownOption(String)
    case stateDirectoryRequired            // --root or --scenario without --state-dir → exit 64
    case notADirectory(String)
}

// Support/CoreEnvironment.swift
@MainActor
public final class CoreEnvironment {
    public let statePaths: StatePaths
    public let lanes: LanePool
    public let types: TypeRegistry
    public let readers: DirectoryReaders
    public let volumes: Volumes
    public let settings: Settings
    public let changeBus: ChangeBus
    public let clipboard: Clipboard
    public let launchServices: LaunchServicesCache
    public let ejectCoordinator: EjectCoordinator
    public let journal: Journal
    public let trash: any TrashService
    public let interaction: InteractionProxy
    public let fileOps: FileOpQueue
    public let undo: FileOpUndoStack
    public let operations: OperationsCenter
    public let termination: TerminationCoordinator

    public init(statePaths: StatePaths, lanes: LanePool, settingsStorage: any SettingsStorage,
                volumeScanner: any VolumeScanning, volumeEvents: (any VolumeEventSource)?,
                pasteboard: any PasteboardBackend, launchServices: any LaunchServicesProviding,
                ejector: any Ejecting, trash: any TrashService, fileOpTuning: FileOpTuning = FileOpTuning())
    /// Wires readers/volumes/watchers into a FolderContext.
    public func folderContext() -> FolderContext
    public func makeFolderModel(_ directory: URL, query: ViewQuery? = nil) -> FolderModel
    /// Starts volumes, operations consumer, and runs LaunchRecovery from the journal.
    public func start() async -> RecoveryReport
    /// Test/scenario factory: InMemorySettingsStorage, InMemoryPasteboard, FakeLaunchServices,
    /// SandboxTrash(root/.trash), StatePaths(root: root/state), a fresh LanePool, SystemVolumeScanner,
    /// no volume events, an ejector that only ejects images under `root`, and interaction target
    /// ScriptedInteraction() (callers may environment.interaction.setTarget(...)). `root` must be a Sandbox root.
    public static func sandboxed(root: URL) -> CoreEnvironment
}
```

### 3.13 Core: file operations

```swift
// FileOps/JobTypes.swift
public struct JobID: Hashable, Sendable, Codable, CustomStringConvertible { public let raw: UUID; public init() }
public struct OriginID: Hashable, Sendable, Codable { public let raw: Int; public init(raw: Int) }  // NSWindow.windowNumber
public enum NewItemKind: String, Sendable, Codable { case folder, textFile, emptyFile }   // "New Folder", "Untitled.txt", "Untitled"
public struct ModeChange: Sendable, Codable, Equatable {
    public var mode: UInt16                 // permission bits to apply (rwx for u/g/o)
    public var applyToDirectories: Bool
    public var applyToFiles: Bool
    public init(mode: UInt16, applyToDirectories: Bool = true, applyToFiles: Bool = true)
}
public enum AttributeEdit: Sendable, Codable, Equatable {
    case locked(Bool), hidden(Bool), extensionHidden(Bool), permissions(UInt16), removeQuarantine
}
public indirect enum JobKind: Sendable, Equatable {
    case copy(sources: [URL], destination: URL)        // destination == source parent → duplicate naming
    case move(sources: [URL], destination: URL)
    case trash([URL])
    case delete([URL])                                 // permanent; UI confirmed before enqueue
    case duplicate([URL])
    case newItem(NewItemKind, in: URL)
    case rename(URL, to: String)
    case alias(sources: [URL], destination: URL)
    case symlink(sources: [URL], destination: URL)
    case chmodRecursive(URL, ModeChange)
    case setAttributes([URL], AttributeEdit)
    case undo(JobRecord)
    case redo(JobRecord)
}
public struct JobRequest: Sendable {
    public var kind: JobKind
    public var origin: OriginID?
    public var registersUndo: Bool
    public init(_ kind: JobKind, origin: OriginID? = nil, registersUndo: Bool = true)
}
public enum JobState: Sendable, Equatable { case queued, planning, running, paused, waitingForUser, cancelling, finished }
public enum JobVerb: String, Sendable, Codable {
    case copying, moving, trashing, deleting, duplicating, creating, renaming, makingAlias, makingSymlink,
         changingPermissions, changingAttributes, undoing, redoing
}
/// UI formats "Copying 1,204 items from Downloads to Backup".
public struct JobDescription: Sendable, Equatable {
    public var verb: JobVerb
    public var itemCount: Int
    public var firstItemName: String?
    public var sourceFolderName: String?
    public var destinationFolderName: String?
}
public struct JobSnapshot: Sendable, Identifiable, Equatable {
    public var id: JobID
    public var description: JobDescription
    public var state: JobState
    public var progress: JobProgress
    public var origin: OriginID?
    public var startedAt: ContinuousClock.Instant
}

// FileOps/JobProgress.swift
public struct JobProgress: Sendable, Equatable {
    public var itemsDone: Int
    public var itemsTotal: Int?            // nil while planning
    public var bytesDone: Int64
    public var bytesTotal: Int64?
    public var currentItem: String?
    public var throughput: [Double]        // bytes/s samples, oldest first, ≤ 60
    public var estimatedRemaining: Duration?
    public var fraction: Double? { get }
    public static let zero: JobProgress
}

// FileOps/FileOpError.swift
public enum ErrorResolution: Sendable, Equatable { case retry, skip, skipAll, cancel, unlockAndContinue, continueAnyway }
public enum FileOpErrorKind: Sendable, Equatable {
    case permissionDenied                       // EACCES
    case blockedByMacOS                         // EPERM (TCC/SIP)
    case locked                                 // uchg
    case readOnlyVolume                         // EROFS
    case noSpace(needed: Int64?, available: Int64?)  // ENOSPC
    case inUse                                  // EBUSY / ETXTBSY
    case nameTooLong                            // ENAMETOOLONG
    case sourceGone                             // ENOENT on source
    case intoItself                             // copy/move into self or descendant (Review Focus 1)
    case changedDuringMove                      // verification mismatch (Review Focus 5)
    case noTrash                                // volume without trash (UI then offers permanent delete)
    case other(code: Int32, message: String)
    public init(errno: Int32, isLockedItem: Bool)
    /// §6.5 actions; UI maps .blockedByMacOS's "Open Privacy Settings" to a side effect + .retry.
    public var allowedResolutions: [ErrorResolution] { get }
}
public struct FileOpError: Error, Sendable, Equatable {
    public var kind: FileOpErrorKind
    public var url: URL
    public var destination: URL?
    public init(kind: FileOpErrorKind, url: URL, destination: URL? = nil)
}

// FileOps/Interaction.swift
public struct ItemSummary: Sendable, Equatable {
    public var url: URL
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
}
public struct ConflictPair: Sendable, Equatable { public var source: ItemSummary; public var destination: ItemSummary }
public enum ConflictAction: String, Sendable, Codable { case replace, skip, keepBoth, merge }
public struct ConflictInfo: Sendable, Equatable {
    public var pair: ConflictPair
    public var isFolderMerge: Bool               // both directories → Merge / Keep Both / Skip
    public var knownRemaining: Int               // includes this one ("Do this for all remaining conflicts (N)")
    public var pendingPairs: [ConflictPair]      // known top-level conflicts, for Compare
}
public enum ConflictResolution: Sendable, Equatable {
    case one(ConflictAction)
    case all(ConflictAction)                     // this + remaining of the same class (file/file or folder/folder)
    case perItem([URL: ConflictAction])          // Compare; keyed by source URL; missing keys = skip
    case cancelJob
}
public struct SpaceShortfall: Sendable, Equatable { public var needed: Int64; public var available: Int64; public var volumeName: String }

public protocol FileOpInteraction: Sendable {
    func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution
    func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution
    func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool   // Continue Anyway
    func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool
}
/// Forwards to a target set later (app launch sets BasicAlertInteraction, P1-38 swaps InteractionRouter).
/// Calls made with no target suspend until one is set. Target stored in a Mutex (Sendable without @unchecked).
public final class InteractionProxy: FileOpInteraction {
    public init()
    public func setTarget(_ target: any FileOpInteraction)
}
/// Tests and macx-scenarios: answers from queues (defaults when a queue is empty: conflicts .one(.skip),
/// errors .skip, space false, no-trash false) and records every question asked. Mutex-protected.
public final class ScriptedInteraction: FileOpInteraction {
    public init(conflicts: [ConflictResolution] = [], errors: [ErrorResolution] = [],
                space: [Bool] = [], noTrash: [Bool] = [])
    public func askedConflicts() -> [ConflictInfo]
    public func askedErrors() -> [FileOpError]
}

// FileOps/JobRecord.swift
public struct FileIdentity: Sendable, Codable, Hashable {
    public var device: UInt64
    public var inode: UInt64
    public init(device: UInt64, inode: UInt64)
    public static func of(path: String) -> FileIdentity?    // lstat; lane only
}
public struct AttributeSnapshot: Sendable, Codable, Equatable {
    public var locked: Bool?
    public var hidden: Bool?
    public var extensionHidden: Bool?
    public var mode: UInt16?
    public var quarantine: Data?
}
public enum ItemAction: Sendable, Codable, Equatable {
    case created(URL, FileIdentity)
    case createdDirectory(URL, FileIdentity)              // merge/copy-created folder; undo removes once empty
    case moved(from: URL, to: URL, FileIdentity)
    case renamed(from: URL, to: URL, FileIdentity)
    case trashed(original: URL, trashURL: URL, FileIdentity)
    case replaced(original: URL, trashURL: URL, FileIdentity)   // displaced destination now in Trash
    case modeChanged(URL, old: UInt16, new: UInt16)
    case attributesChanged(URL, old: AttributeSnapshot, new: AttributeSnapshot)
    case deleted(URL)                                     // not undoable
}
public struct JobRecord: Sendable, Codable, Equatable {
    public var id: JobID
    public var verb: JobVerb
    public var actions: [ItemAction]                      // in execution order
    public var isUndoable: Bool { get }                   // false if any .deleted or empty
}
public struct SkippedItem: Sendable, Equatable { public var url: URL; public var reason: FileOpErrorKind? }  // nil = conflict skipped
public struct JobOutcome: Sendable, Equatable {
    public var record: JobRecord
    public var skipped: [SkippedItem]
    public var wasCancelled: Bool
    public var created: [URL]                             // final URLs of created/landed items (selection)
    public var localChanges: [LocalChange]
}

// FileOps/TrashService.swift
public protocol TrashService: Sendable {
    /// Synchronous; lane only. Returns the resulting URL. Throws FileOpError(.noTrash) where unsupported.
    func trash(_ url: URL) throws -> URL
}
public struct SystemTrash: TrashService { public init() }                  // FileManager.trashItem
public struct SandboxTrash: TrashService { public init(directory: URL) }   // moves into directory/<UUID>/<name>

// FileOps/Journal.swift
public enum JournalEntry: Sendable, Codable, Equatable {
    case partial(job: JobID, url: URL)
    case trashedDestination(job: JobID, original: URL, trashURL: URL)
    case twoStepRename(job: JobID, temporary: URL, original: URL, target: URL)
    case jobStarted(job: JobID, description: JobDescription)
}
public actor Journal {
    public init(fileURL: URL)                   // writes atomically (temp + rename) on every change
    public func record(_ entry: JournalEntry) throws
    public func clear(_ entry: JournalEntry) throws
    public func finish(job: JobID) throws       // drops all entries of the job
    public func entries() -> [JournalEntry]
}

// FileOps/LaunchRecovery.swift
public struct RecoveryReport: Sendable, Equatable {
    public var removedPartials: [URL]
    public var restoredDestinations: [URL]
    public var restoredRenames: [URL]
    public var incompleteJobs: [JobDescription]
    public var isEmpty: Bool { get }
}
public enum LaunchRecovery {
    public static func run(journal: Journal, lanes: LanePool) async -> RecoveryReport
}

// FileOps/FaultPoint.swift
public enum FaultPoint: String, Sendable, CaseIterable {
    case afterPartialCopy, beforePartialRename, afterTrashDestination, beforeSourceDelete, midCopyChunk, afterFirstItem
}

// FileOps/FileOpQueue.swift
public struct FileOpTuning: Sendable {
    public var progressInterval: Duration          // .milliseconds(100) (10 Hz)
    public var copyChunkBytes: Int                 // 1 MiB progress/pause granularity
    public var faultHook: (@Sendable (FaultPoint, JobID) -> Void)?   // tests only
    public init(progressInterval: Duration = .milliseconds(100), copyChunkBytes: Int = 1 << 20,
                faultHook: (@Sendable (FaultPoint, JobID) -> Void)? = nil)
}
public enum JobEvent: Sendable {
    case added(JobSnapshot)
    case updated(JobSnapshot)                      // ≤ 10 Hz per job
    case finished(JobSnapshot, JobOutcome)
}
public actor FileOpQueue {
    public init(lanes: LanePool, trash: any TrashService, journal: Journal, interaction: any FileOpInteraction,
                tuning: FileOpTuning = FileOpTuning())
    /// Disjoint volume sets run concurrently; the same volume pair runs FIFO.
    @discardableResult public func enqueue(_ request: JobRequest) -> JobID
    public func pause(_ id: JobID)
    public func resume(_ id: JobID)
    public func cancel(_ id: JobID)               // finish current item safely, then stop
    public func cancelAll() async                  // returns when every job reached .finished
    public func snapshots() -> [JobSnapshot]
    public func outcome(of id: JobID) async -> JobOutcome   // waits for completion
    public func waitUntilIdle() async
    public var hasActiveJobs: Bool { get }
    /// Volumes.release: queued jobs touching the volume pause; returns running ones (UI asks cancel/wait).
    public func suspendJobs(touching mountPoint: URL) -> [JobID]
    public nonisolated var events: AsyncStream<JobEvent> { get }    // single consumer: OperationsCenter
}

// FileOps/FileOpUndoStack.swift
@MainActor
public final class FileOpUndoStack {
    public init(queue: FileOpQueue)
    public let undoManager: UndoManager            // returned by every window's windowWillReturnUndoManager
    /// Registers one entry per completed undoable job (also partly completed ones).
    public func register(_ outcome: JobOutcome, actionName: String)
    /// Per-edit manager for field editors; discard when editing ends.
    public func makeFieldEditorUndoManager() -> UndoManager
    public var canUndo: Bool { get }
    public var canRedo: Bool { get }
}

// FileOps/OperationsCenter.swift
@MainActor @Observable
public final class OperationsCenter {
    public init(queue: FileOpQueue, undo: FileOpUndoStack, changeBus: ChangeBus,
                actionName: @escaping @MainActor (JobDescription) -> String)
    public private(set) var jobs: [JobSnapshot]          // all unfinished
    public var visibleJobs: [JobSnapshot] { get }         // running ≥ 1 s or waitingForUser
    public var overallFraction: Double? { get }
    public var hasActiveJobs: Bool { get }
    public func start()                                   // consumes queue.events; posts localChanges; registers undo
    public func perform(_ request: JobRequest) async -> JobOutcome   // enqueue + await (UI convenience)
    public func onFinished(_ handler: @escaping @MainActor (JobSnapshot, JobOutcome) -> Void) -> ObserverToken
}

// FileOps/TerminationCoordinator.swift
@MainActor
public final class TerminationCoordinator {
    public init(queue: FileOpQueue, operations: OperationsCenter)
    public var activeCount: Int { get }
    /// Cancels every job (§6.1 cancel path) and waits; returns false if `timeout` elapsed first.
    public func stopAllAndWait(timeout: Duration = .seconds(10)) async -> Bool
}
```

### 3.14 UI: main controllers, scenario hooks

Types used by the `macExplorer` executable are `public`; the rest are `internal` to `UI` but shared between S4 and S5 with exactly these shapes.

```swift
// App/UIContext.swift
@MainActor
public final class UIContext {
    public init(environment: CoreEnvironment, options: LaunchOptions)
    public let environment: CoreEnvironment
    public let options: LaunchOptions
    public let icons: IconCache
    public let windows: WindowManager
    /// P1-26 installs BasicAlertInteraction; P1-38 installs InteractionRouter. Also sets environment.interaction's target.
    public private(set) var interaction: any FileOpInteraction
    public func installInteraction(_ interaction: any FileOpInteraction)
}

// App/WindowManager.swift
@MainActor
public final class WindowManager {
    public init(context: UIContext)                      // unowned back-reference
    @discardableResult public func openWindow(at url: URL, selecting name: String? = nil) -> BrowserWindowController
    public var windows: [BrowserWindowController] { get }
    public func window(for origin: OriginID) -> BrowserWindowController?
    public func restoreOrOpenInitial() async             // --root wins; else restoration; else Settings.startupFolder
    public func moveWindowsHome(onVolume volume: VolumeID)
}

// Window/BrowserSession.swift
enum SessionEvent { case folderChanged(FolderModel), historyChanged, viewModeChanged(ViewMode), banner(String?) }
@MainActor
final class BrowserSession {
    init(environment: CoreEnvironment, initialURL: URL)
    private(set) var folder: FolderModel
    private(set) var history: NavigationHistory
    var viewMode: ViewMode
    func navigate(to url: URL, selecting name: String? = nil, recordHistory: Bool = true)  // closes previous model
    func goBack()
    func goForward()
    func goUp()
    func reload()
    func observe(_ handler: @escaping @MainActor (SessionEvent) -> Void) -> ObserverToken
}

// Window/BrowserWindowController.swift
@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate, ScenarioProbe {
    init(context: UIContext, initialURL: URL)
    var session: BrowserSession { get }
    public var origin: OriginID { get }                  // window number
    public func navigate(to url: URL, selecting name: String? = nil)
    func focus(_ target: FocusContext)                   // Tab cycle, ⌘L, ⌘F
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager?   // field editor → per-edit manager
    var scenarioHooks: ScenarioHooks                      // see §3.14 ScenarioProbe
}

// Window/CommandActions.swift
enum CommandTarget {
    case contentSelection(FolderModel)                   // content view focus
    case currentFolder(FolderModel)                      // empty-space menu, ⌘V
    case folder(URL)                                     // item-context Paste into one folder, tree node
    case favorite(ResolvedFavorite)
    case volume(VolumeInfo)
}
@MainActor protocol CommandHandler: AnyObject {
    func canPerform(_ command: Command, target: CommandTarget) -> Bool
    func perform(_ command: Command, target: CommandTarget, sender: Any?)
}
/// Base for views that take file commands (content, sidebar). One @objc method per Command.selectorName
/// (e.g. @objc func macx_moveToTrash(_ sender: Any?)), each calling handler.perform(_, target: commandTarget, ...).
/// Also implements validateMenuItem via MenuValidation.
@MainActor class CommandHandlingViewController: NSViewController, NSMenuItemValidation {
    var handler: CommandHandler?
    var focusContext: FocusContext { get }               // overridden
    var commandTarget: CommandTarget? { get }            // overridden
}

// Menus/MenuValidation.swift
@MainActor enum MenuValidation {
    /// false for KeyMap.collidesWithTextEditing commands while a field editor is first responder.
    static func isEnabled(_ command: Command, window: NSWindow?, state: CommandState, focus: FocusContext) -> Bool
}
// Menus/KeyRouter.swift
@MainActor enum KeyRouter {
    /// Content/sidebar keyDown: alternates → NSApp.sendAction(Selector(command.selectorName), to: nil, from: view).
    /// Returns true if handled.
    static func handle(_ event: NSEvent, focus: FocusContext, returnKey: ReturnKeyBehavior, from view: NSView) -> Bool
}
// Support/KeyEventTranslator.swift
enum KeyEventTranslator { static func chord(for event: NSEvent) -> KeyChord? }
// Menus/MainMenuBuilder.swift
@MainActor public enum MainMenuBuilder { public static func build() -> NSMenu }   // App, File, Edit, View, Go, Window, Help

// Content/FileListView.swift
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
@MainActor final class ContentViewController: CommandHandlingViewController {
    init(context: UIContext, session: BrowserSession)
    var activeList: FileListView { get }
    func setViewMode(_ mode: ViewMode)
}
@MainActor final class DetailsViewController: NSViewController, FileListView { init(context: UIContext) }
@MainActor final class IconsViewController: NSViewController, FileListView { init(context: UIContext) }
@MainActor final class FileGridLayout: NSCollectionViewLayout {
    var iconSize: IconSize
    var itemCount: Int
    var columns: Int { get }
    func frame(forItem index: Int) -> NSRect             // O(1)
    func indexes(in rect: NSRect) -> Range<Int>          // O(visible) contiguous rows
    func index(atRow row: Int, column: Int) -> Int?
    func rowColumn(of index: Int) -> (row: Int, column: Int)
}
@MainActor final class SidebarViewController: CommandHandlingViewController { init(context: UIContext, session: BrowserSession) }
@MainActor final class AddressBarView: NSView {
    var onNavigate: ((URL, String?) -> Void)?
    func show(_ url: URL, volume: VolumeInfo?)
    func beginEditing()                                   // ⌘L, ⌥D, F4
    var isEditing: Bool { get }
}
@MainActor final class CommandBarView: NSView { init(); func update(state: CommandState, focus: FocusContext, shiftHeld: Bool) }
@MainActor final class StatusBarView: NSView { func update(itemCount: Int, selection: SelectionSummary, available: Int64?); var operationsSlot: NSView { get } }
@MainActor final class InlineRenameController { init(list: FileListView, folder: FolderModel, environment: CoreEnvironment); func begin(row: Int); func commit(moveToNext: Bool); func cancel(); var isEditing: Bool { get } }
@MainActor final class FileCommandController: CommandHandler { init(context: UIContext, window: BrowserWindowController) }
@MainActor final class ContextMenuBuilder { init(context: UIContext); func itemMenu(for rows: IndexSet, in folder: FolderModel, handler: CommandHandler) -> NSMenu; func emptySpaceMenu(for folder: FolderModel, handler: CommandHandler) -> NSMenu }
@MainActor final class IconCache {
    init(lanes: LanePool, types: TypeRegistry)
    func typeIcon(_ typeIndex: UInt16, points: Double, scale: Double) -> CGImage   // Tier 0, first frame
    func fileIcon(for url: URL, rowID: RowID, points: Double, scale: Double, completion: @escaping @MainActor (CGImage) -> Void)  // Tier 1
    func cancelFileIcons(notIn visible: Set<RowID>)
}
@MainActor final class PropertiesWindowController: NSWindowController { static func show(for urls: [URL], context: UIContext); static func show(volume: VolumeInfo, context: UIContext) }
@MainActor final class DefaultAppSheet { static func present(for file: URL, on window: NSWindow, context: UIContext) async }
@MainActor final class InteractionRouter: FileOpInteraction { init(windows: WindowManager) }   // nonisolated protocol methods hop to main
@MainActor final class BasicAlertInteraction: FileOpInteraction { init() }

// Support/AXID.swift  (accessibility identifiers; the scenario runner relies on these)
enum AXID {
    static let window = "macx.window"
    static let addressBar = "macx.addressBar"
    static let addressField = "macx.addressField"
    static func breadcrumbSegment(_ index: Int) -> String     // "macx.breadcrumb.<index>"
    static let search = "macx.search"
    static let detailsTable = "macx.details"
    static let iconsGrid = "macx.icons"
    static let sidebar = "macx.sidebar"
    static func commandBarItem(_ c: Command) -> String        // "macx.commandBar.<rawValue>"
    static let statusCount = "macx.status.count"
    static let statusSelection = "macx.status.selection"
    static let statusFree = "macx.status.free"
    static let emptyState = "macx.emptyState"
    static let banner = "macx.banner"
    static let renameField = "macx.renameField"
    static let operationsCapsule = "macx.operations"
    static func conflictButton(_ a: ConflictAction) -> String // "macx.conflict.<rawValue>"
    static let propertiesWindow = "macx.properties"
}

// Scenario/ScenarioProbe.swift (P1-26). BrowserWindowController conforms in P1-26. Feature-specific
// values come from `scenarioHooks` closures that the owning tasks install: address (P1-27), empty state and
// banner (P1-33), rename text (P1-34), performDrop (P1-36). An uninstalled hook returns nil / does nothing.
@MainActor struct ScenarioHooks {
    var addressText: (() -> String)?
    var isEditingAddress: (() -> Bool)?
    var renameText: (() -> String?)?
    var emptyStateText: (() -> String?)?
    var bannerText: (() -> String?)?
    var performDrop: (([URL], String, DragModifiers, Bool, DragOperation?) async -> Void)?
}
@MainActor protocol ScenarioProbe: AnyObject {
    var probeFolderURL: URL { get }
    var probeRowNames: [String] { get }            // display order
    var probeSelectedNames: [String] { get }
    var probeCutNames: [String] { get }
    var probeFolderState: FolderState { get }
    var probeFocus: FocusContext { get }
    var probeViewMode: ViewMode { get }
    var probeAddressText: String { get }
    var probeIsEditingAddress: Bool { get }
    var probeRenameText: String? { get }
    var probeEmptyStateText: String? { get }
    var probeBannerText: String? { get }
    var probeFieldEditorText: String? { get }      // whatever field editor is first responder
    /// Scenario-only drop entry point (drag sessions can't be synthesized in-process). Runs the same
    /// DropPolicy + DropMenu + job path as a real drop onto `targetName` ("" = current folder).
    func probePerformDrop(sources: [URL], onto targetName: String, modifiers: DragModifiers, secondary: Bool, menuChoice: DragOperation?) async
}

// Scenario/ScenarioFile.swift (JSON schema; files in Tests/Scenarios/)
struct ScenarioFile: Codable {
    struct Fixture: Codable {
        var files: [String]              // relative paths; parent dirs created; content "x"
        var dirs: [String]
        var hidden: [String]?            // created with UF_HIDDEN
        var sizes: [String: Int]?        // file → byte count
    }
    /// Exactly one action field is non-nil per step (the driver rejects the file otherwise).
    struct Step: Codable {
        var key: String?                 // KeyChord(parsing:), sent through NSApp.sendEvent as keyDown/keyUp
        var type: String?                // characters into the first responder
        var menu: [String]?              // menu title path, e.g. ["Edit", "Cut"]; performs via NSMenu.performActionForItem
        var click: String?               // row name; with `modifiers`
        var doubleClick: String?         // row name
        var rightClick: String?          // row name, "" = empty space; opens the context menu
        var modifiers: [String]?         // "cmd", "shift", "opt", "ctrl" (for click/drop)
        var chooseMenuItem: String?      // title in the currently open context/drop menu
        var drop: Drop?
        var answerConflict: String?      // ConflictAction raw value; with `applyToAll`
        var applyToAll: Bool?
        var waitFor: Expectation?        // polls every 20 ms up to `timeoutMs` (default 3000)
        var timeoutMs: Int?
        var expect: Expectation?         // checked once, immediately
        var sleepMs: Int?
    }
    struct Drop: Codable {
        var sources: [String]            // names in the current folder
        var onto: String                 // row name, "" = current folder, "sidebar:<Favorite name>", "crumb:<index>"
        var secondary: Bool?             // right-drag
        var choose: String?              // drop-menu choice: "copy", "move", "alias", "symlink", "cancel"
    }
    struct Expectation: Codable {
        var rows: [String]?              // exact display order
        var rowsContain: [String]?
        var selection: [String]?
        var cut: [String]?
        var folder: String?              // relative to root; "" = root
        var state: String?               // "complete", "error.permissionPOSIX", ...
        var focus: String?               // FocusContext case name
        var fieldEditorText: String?
        var renameText: String?
        var emptyState: String?
        var banner: String?
        var filesExist: [String]?        // on disk, relative to root
        var filesAbsent: [String]?
    }
    var name: String
    var fixture: Fixture
    var steps: [Step]
}
/// Example Tests/Scenarios/rename-f2.json:
/// {"name": "rename-f2",
///  "fixture": {"files": ["a.txt", "b.txt"], "dirs": ["sub"]},
///  "steps": [{"click": "a.txt"}, {"key": "F2"}, {"expect": {"renameText": "a.txt"}},
///            {"type": "c"}, {"key": "return"},
///            {"waitFor": {"rows": ["sub", "b.txt", "c.txt"]}, "timeoutMs": 2000},
///            {"expect": {"filesExist": ["c.txt"], "filesAbsent": ["a.txt"], "selection": ["c.txt"]}}]}
/// The driver creates the fixture inside --root before the first step, and refuses (result passed=false)
/// unless --root is an empty directory whose last path component starts with "macx-scenario-".
/// Result JSON written to --scenario-output:
/// {"name": String, "passed": Bool, "failedStep": Int?, "message": String?, "durationMs": Int}
@MainActor final class ScenarioDriver { init(context: UIContext, file: URL, output: URL); func run() async -> Bool }
```

## 4. Ordered task list

Format: ID [slice] deliverable (dependencies). Each task ships its own tests and a commit.

| ID | Slice | Deliverable | Depends on |
|---|---|---|---|
| P1-01 | S4 | Package skeleton (§1, stub file per target), `LaunchOptions` + `StatePaths`, `UIResources`/`L10n`, `Info.plist`, entitlements, `make-icon.sh` + `AppIcon.icns`, `bundle.sh`; `macExplorer --root <sandbox> --state-dir <sandbox>/state --smoke-exit-after 1` opens one empty window titled with the root's name, writes `smoke.json`, exits 0 | none |
| P1-02 | S1 | `MacxFixtures`: guarded `Sandbox`, `DiskImage` (APFS/HFS+/ExFAT/MS-DOS, size, read-only, `-nobrowse` mount inside sandbox), `FixtureTree` builders, `make-fixtures.sh`; tests prove out-of-sandbox writes trap | P1-01 |
| P1-03 | S1 | `CFSKit`: bulk read, bounds-checked cursor, `cfsk_stat_at`, materialization, volume caps; fuzz test (random + truncated buffers, 100k iterations) never crashes | P1-01 |
| P1-04 | S1 | Lanes: `IOLane`, `LanePool.perform`, watchdog (poison, `awaitingPermission`, resumed), poison cap → unresponsive, `Generation`, `withNoMaterialization`, `assertOffMain`, `Observers`, `PerfSignposts` | P1-03 |
| P1-05 | S1 | Store: `Entry`, `EntryFlags`, `Batch`, `NameArena`, `RowID`/`IdentityMode`/`NameNormalizer`, `TypeRegistry`, `EntryStore` (append, order, inverse map, upsert, remove) | P1-04 |
| P1-06 | S1 | Reading: `BulkReader`, `FallbackReader`, `RecordConverter`, `ItemReader`, `DirectoryReader` streaming (2,000/8 ms), stall events, cancel, `DirectoryReaders`; golden test vs `lstat`/`getattrlist` on the §9 tree; fallback parity | P1-02, P1-05 |
| P1-07 | S1 | Sorting: `ViewQuery`, `SortKeyColumn`, `SortKeys` (fold, digit runs, NFC tie-break, search fold), `Sorter.permutation/merge`; 5k corpus golden vs `localizedStandardCompare` with listed divergences; 100k re-sort smoke | P1-05 |
| P1-08 | S1 | Volumes: `VolumeInfo`/`VolumeCapabilities`/`MountTable`/`MountTableStore`, `SystemVolumeScanner`, `@MainActor Volumes` (events, capacity cache, release handlers); disk-image mount/unmount test | P1-04, P1-02 |
| P1-09 | S2 | `Change`/`ChangeSet`, `StoreDiff` (identity, replacement rule, reload, moves, duplicate keys); randomized diff-applies-to-equal-order property test | P1-07 |
| P1-10 | S2 | `FolderModel` + `FolderWorker` + `ChangeBus` + `Selection` + `NameRules` + `FramePacer` + `WatchTypes` (with `NoopWatcher`): state machine, loading presentation (sorted first batch, ≤1 reset/frame, final reset), selection by identity, scroll anchor, query/re-sort, retry/unresponsive, generation discard; Review Focus 2 and 3 tests | P1-06, P1-08, P1-09 |
| P1-11 | S2 | `Watcher`, `EventClassifier`, `TreeWatcher`, `FolderModel+Watch` (no-gap capture/buffer, incremental ≤256, single full re-read + one pending, root changed → relocate, volume gone → home); burst/atomic-save/hard-link/exFAT tests | P1-10 |
| P1-12 | S2 | `SettingsStorage` (UserDefaults/File/InMemory), `SettingsTypes`, `Settings` (schemaVersion, §7 keys), `Favorites` + resolver, `ProtectedLocations`, TCC outcomes | P1-08 |
| P1-13 | S2 | `Command`, `KeyChord`, `KeyMap` (full §5.6 table), `KeyDispatcher`, `CommandAvailability` (§5.3/§5.4), `NavigationHistory`, `AddressResolver`, `PathCompletion` | P1-12 |
| P1-14 | S2 | `LaunchServicesProviding`, `LaunchServicesCache`, `FakeLaunchServices`, `WorkspaceLaunchServices`, `OpenPlanner`, `EjectCoordinator` + `WorkspaceEjector` + `WorkspaceVolumeEvents` (eject tested on a sandbox disk image) | P1-08 |
| P1-15 | S2 | `PasteboardBackend`, `InMemoryPasteboard`, `SystemPasteboard` (private named pasteboard in tests, 100k URL write), `Clipboard` (cut marker + changeCount, stale marker pastes as copy, Esc rewrite), `DropPolicy` | P1-08 |
| P1-16 | S2 | Properties: `ItemProperties`/`MultiProperties`/`VolumeProperties`, `PropertiesLoader`, `PermissionModel`, `Xattrs` (quarantine, where-from), `FolderCounter` (symlink-loop test) | P1-04, P1-02 |
| P1-17 | S3 | FileOps foundation: `JobTypes`, `JobProgress` + throughput meter, `FileOpError` (errno → kind → actions), `Interaction` (+ `InteractionProxy`, `ScriptedInteraction`), `JobRecord`, `Journal` (atomic), `LaunchRecovery`, `TrashService` (System/Sandbox), `FaultPoint` | P1-10, P1-02 |
| P1-18 | S3 | `FileOpQueue` + `JobRunner` + `Planner` + `VolumeIdentity`: volume-set scheduling (concurrent disjoint, FIFO same pair), 10 Hz progress, pause/cancel, fts plan, existence re-check, space estimate + shortfall prompt, self/descendant refusal (Review Focus 1) | P1-17 |
| P1-19 | S3 | `RenamePrimitive` (RENAME_EXCL, EXDEV, lstat fallback, case/normalization-only, two-step with journal), `NameGenerator`, rename and newItem jobs; case-only rename on an ExFAT image | P1-18 |
| P1-20 | S3 | `CopyEngine` + copy/duplicate jobs: copyfile flags, clone byte accounting, directory pre/post-order metadata (also on cancel/fail), pause/cancel mid-copy; xattr/ACL/sparse/uchg/mtime preservation; Review Focus 4 | P1-19 |
| P1-21 | S3 | `MoveJob`: same-volume rename move; cross-volume partial → verify → rename → delete source; journal; crash-helper kill tests (during copy, during Replace) + `LaunchRecovery`; Review Focus 5 | P1-20 |
| P1-22 | S3 | `ConflictExecutor`: Replace (copy/cross-volume and same-volume paths, trash + restore on failure), Skip, Keep Both, Merge (recursive, source folders removed only when empty), apply-to-all, per-item (Compare) | P1-21 |
| P1-23 | S3 | Trash (no-trash fallback), delete permanently (removefile progress), alias, symlink (relative same volume), setAttributes, chmodRecursive; §6.5 error table on EROFS / locked / ENOSPC / name-too-long images | P1-22 |
| P1-24 | S3 | `UndoPlanner` + `FileOpUndoStack`: inverse per §6.6 row, identity checks, skipped summary, occupied-path conflicts, partial jobs, redo, field-editor managers | P1-23 |
| P1-25 | S3 | `OperationsCenter`, `TerminationCoordinator`, `CoreEnvironment` (+ `sandboxed(root:)`), `folderContext()`, launch recovery wiring; end-to-end Core test: browse sandbox, paste-copy, see LocalChange in FolderModel, undo | P1-24, P1-11, P1-13, P1-14, P1-15, P1-16 |
| P1-26 | S4 | Window shell: `AppBootstrap`, `UIContext`, `WindowManager`, `BrowserSession`, `BrowserWindowController`, split view, placeholder content (row count), restoration (off in sandbox), ⌘N/⌘W, last-window-keeps-running, `AXID`, `BasicAlertInteraction`, `CommandActions` (`CommandTarget`/`CommandHandler`/`CommandHandlingViewController`), `MenuValidation`, `ScenarioProbe` + `ScenarioHooks` | P1-25 |
| P1-27 | S4 | Toolbar: back/forward/up group with history menus, breadcrumb (segments, › menus, « overflow), edit mode (⌘L, parsing, autocomplete, recents, inline error), search filter field, view switcher | P1-26 |
| P1-28 | S4 | Sidebar: Favorites (bookmarks, defaults, drag add/reorder, remove, stale Locate…), Locations (live volumes, eject button), Folders tree (lazy dirs-only, auto-reveal, ←/→, TreeWatcher), collapsible persisted sections | P1-26 |
| P1-29 | S4 | Command bar, status bar (counts, selection size, free space), `MainMenuBuilder` (every Command, KeyMap primaries), `KeyRouter` + `KeyEventTranslator`, Tab focus cycle, ⇧ turns Delete into Delete Permanently | P1-27, P1-28 |
| P1-30 | S4 | Settings window (SwiftUI, §7), onboarding sheet (FDA, fn-keys, deep links), `AppLifecycle` (quit with jobs → Stop and Quit / Cancel, 10 s, Dock badge, Window › Operations entry, recovery notice) | P1-29 |
| P1-31 | S5 | Details view: `FileListView`, `ContentViewController`, `DetailsViewController`, columns (choose/reorder/resize/auto-fit/persist), header sort, `Formatters`, density, alternating rows, cut dim + italic, `IconCache` tiers 0/1, ChangeSet application, scroll anchor, signposts | P1-29 |
| P1-32 | S5 | Icons view: `FileGridLayout` (O(1) frames, O(visible) rects), `IconsViewController`, `IconItem` (two-line middle ellipsis), sizes S/M/L, rubber band → model, spatial arrows | P1-31 |
| P1-33 | S5 | `SelectionController` (click/⌘/⇧/arrows/⇧-arrows, ⌘A, invert), `TypeSelect`, `EmptyStateView` (all §5.5 states + Open Privacy Settings / Properties / Retry), `BannerView`, filter wiring, status updates | P1-32 |
| P1-34 | S5 | `InlineRenameController`: F2/⌘⇧R/Return-setting, base-name selection, Tab → next, NameRules errors, extension-change and hidden warnings, new-item auto rename, selection carried across rename, per-edit undo manager | P1-33 |
| P1-35 | S5 | `FileCommandController` (every Command for every `CommandTarget`), `ContextMenuBuilder` (item + empty space), `OpenWithMenu` (cache, Loading…), `DefaultAppSheet`, Open/Open in New Window/Show Package Contents/Terminal/Reveal/Share/Services, clipboard UI (cut dimming, Esc, paste targets, Move Item Here) | P1-34, P1-30 |
| P1-36 | S5 | Drag & drop: `DragSource` (≤5 items, full pasteboard, count), `DropTarget` (rows, grid, tree, favorites, breadcrumb; badges; spring-load 0.5 s; autoscroll; promises), `RightDragTracker`, `DropMenu`, ⌃-drop menu, self/descendant refusal | P1-35 |
| P1-37 | S5 | Properties window: `PropertiesWindowController` (one per selection set), `PropertiesViewModel`, `PropertiesView` (General, Permissions, Opens with, Details, multi, volume), edits as undoable jobs, inline error + revert | P1-35 |
| P1-38 | S5 | Progress and dialogs: `InteractionRouter` (origin sheet or Operations panel), `ConflictDialog`, `CompareView`, `ErrorDialog` (§6.5 + space), `OperationsCapsule`, `OperationsListView`, `OperationsPanel`; installs router into `InteractionProxy` | P1-36, P1-37 |
| P1-39 | S6 | `macx-bench`: 1k/10k/100k fixtures in its own temp dir, metrics (enumerate, firstBatch, sortkeys, sort, resort×5 fields, diff, pasteboard 100k on a private pasteboard), warm-up + 5, median/p90 JSON, `--check-budgets`, `--compare` gate | P1-25 |
| P1-40 | S6 | `macx-scenarios`: headless Core scenario runner + catalog (browse, all job kinds, conflicts, cross-volume on images, crash-helper kill + recovery, watcher bursts, clipboard, undo/redo), `run-scenarios.sh` | P1-25 |
| P1-41 | S6 | UI scenario runner: `ScenarioFile`, `ScenarioDriver` (`--scenario`), `ScenarioProbe` wiring, `Tests/Scenarios/*.json` (navigate by address bar, F2 rename, cut/paste, drag-move, right-drag menu, conflict dialog, Properties, undo, colliding keys reach the field editor, hidden toggle, filter, empty/TCC states), `ui-scenarios.sh`, `ui-ax-smoke.sh` | P1-38 |
| P1-42 | S6 | CI `.github/workflows/ci.yml`, `check-layering.sh`, README, release checklist section; full-suite verification run of build, test, bundle, both scenario runners, bench | P1-39, P1-40, P1-41 |

### Slice → task IDs

- **S1 fskit:** P1-02, P1-03, P1-04, P1-05, P1-06, P1-07, P1-08
- **S2 core-model:** P1-09, P1-10, P1-11, P1-12, P1-13, P1-14, P1-15, P1-16
- **S3 fileops:** P1-17, P1-18, P1-19, P1-20, P1-21, P1-22, P1-23, P1-24, P1-25
- **S4 ui-shell:** P1-01, P1-26, P1-27, P1-28, P1-29, P1-30
- **S5 ui-content:** P1-31, P1-32, P1-33, P1-34, P1-35, P1-36, P1-37, P1-38
- **S6 validation:** P1-39, P1-40, P1-41, P1-42

### Phase 1 "working" definition (what P1-42 verifies)

1. `swift build -c release` and `swift test --parallel` pass with zero warnings.
2. `scripts/bundle.sh release` produces `.build/macExplorer.app`; launching it with sandbox arguments opens a window on the sandbox folder.
3. `scripts/run-scenarios.sh` reports every Core scenario passed (including cross-volume and crash-recovery scenarios on disk images).
4. `scripts/ui-scenarios.sh` reports every UI scenario passed.
5. `swift run -c release macx-bench --check-budgets` prints a JSON report; on Apple Silicon every §4.4 metric it measures is within budget.
6. No file outside the test-created sandboxes and disk images was created, modified or deleted (each runner prints the sandbox roots it used and verifies after teardown that they are gone).

## 5. Notes for slice authors

- Write your slice file at the path in the plan-set table, starting with the same header block (Goal/Architecture/Tech Stack/Spec for your slice), a "Global Constraints: see overview, all apply" line plus any slice-specific constraints, and tasks in the writing-plans format (Files, Interfaces with Consumes/Produces copied from §3, checkbox steps with real code, exact commands, expected output, commit).
- Tests for Core and UI that touch the file system create a `Sandbox` in `setUp` and register teardown; disk images come from `DiskImage.create(in: sandbox, ...)`.
- When a task needs a type from a later task, it does not stub it: the ID order already guarantees availability. If a task finds it needs one, move the type to the earlier task here in §3 and in both slice files.
- The Review Focus tests listed above are mandatory in their owning tasks.
