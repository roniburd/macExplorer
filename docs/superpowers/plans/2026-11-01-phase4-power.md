# macExplorer Phase 4 ("Power") and Release Track Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the spec §11 Phase 4 power features to macExplorer: custom icons and icon packs, tag editing with a sidebar TAGS section, compress and extract, batch rename, dual-pane mode, Authenticate… through a privileged helper, ACL editing, Connect to Server and Bonjour SMB browsing, Sparkle 2 auto-update, a command palette and keymap customization. Also finish the spec §10 release track: universal Developer ID build, notarization, GitHub Releases, appcast, and a Homebrew tap cask.

**Architecture:** Each feature extends the Phase 1 layers (`App → UI → Core → MacxFS → CFSKit`) along the seams Phase 1 already has. File-changing features are new `JobKind` cases that run on `FileOpQueue`, so they get progress, conflicts, the journal and one undo entry each. Commands are new `Command` cases. Bindings move from the static `KeyMap` into data (`KeymapPreset`, `KeymapProfile`, `ResolvedKeymap`); the menu builder, `KeyDispatcher`, menu validation and the command palette all read that data. Privileged work goes through a new root helper (`macx-helper`, registered with `SMAppService`, reached over XPC, gated by a code-signing requirement and an Authorization Services right, audited to a log). The helper only does single-item primitives; recursion stays in the Phase 1 planner. Sparkle lives only in the `App` target. The release track is a set of shell scripts under `scripts/release/` plus a tag-triggered GitHub Actions workflow. Each script also has a local `--dry-run` mode that does ad-hoc signing and never notarizes or uploads.

**Tech Stack:** Swift 6.4 / swift-tools-version 6.2, Swift 6 language mode, AppKit, SwiftUI (sheets, Settings panes), Foundation (`NSMetadataQuery`, `PropertyListSerialization`), AppleArchive + System (`FilePath`), NetFS (`NetFSMountURLAsync`), Network (`NWBrowser`, `NWConnection`), ServiceManagement (`SMAppService`), Security (Authorization Services, `SecCode`), Darwin (`getxattr`/`setxattr`, `acl_*`, `mbr_*`, `renamex_np`, `openat`), ImageIO, CryptoKit (Ed25519 appcast signatures), `/usr/bin/ditto`, `/usr/bin/tar` (bsdtar 3.5), `/usr/bin/gzip`, `/usr/bin/aa`, Sparkle 2 (the only third-party dependency), `xcrun notarytool`, `xcrun stapler`, `hdiutil`, GitHub Actions (`macos-26` runner), Homebrew cask DSL.

**Spec:** `docs/superpowers/specs/2026-11-01-macexplorer-design.md`: §11 "Phase 4 — Power" (every bullet), §10 "Build & release", §6.5 (Authenticate… in the `EACCES` row), §5.3/§5.6 (commands and keys), §9 (testing). Interface baseline: `docs/superpowers/plans/2026-11-01-phase1-00-overview.md` §3 (the Phase 1 Interface Contract). This plan extends those types by name.

**Preconditions (check before starting P4-01):**

| Needs | Provided by | Check command | If missing |
|---|---|---|---|
| Phase 1 complete (P1-42 "working" definition green) | Phase 1 plans | `swift build 2>&1 \| tail -1` prints `Build complete!` and `scripts/ui-scenarios.sh` exits 0 | stop; Phase 4 builds on every Phase 1 type |
| `ColumnID.tags` and a per-row tag read for the Details view | Phase 2 ("More columns: Tags") | `grep -n "case .*tags" Sources/Core/Settings/SettingsTypes.swift` | P4-05 Step 1b adds `case tags` and the cell itself |
| A way to show a stream of result URLs in the content area with a Path column | Phase 3 ("Results appear in the Details view with a Path column") | `grep -rn "func showResults" Sources/UI` | P4-06 ships Steps 1–4 (queries, TAGS rows, drop-to-tag) and defers Step 5 (click a tag → results) until Phase 3 lands; record that in the task's commit message |
| Native window tabs | Phase 2 | not required | dual-pane works per window; each tab is a window |

## Global Constraints

Every Phase 1 Global Constraint (overview §"Global Constraints") still applies unchanged. Every task here implicitly includes all of them plus the lines below.

**Safety (HARD RULE; applies to tests, benchmarks, scenario runners, scripts, release dry-runs and any manual or automated validation):**
- Tests, benchmarks and any manual or automated validation must ONLY create, modify or delete files inside fresh temp directories they create themselves (for example `FileManager.default.temporaryDirectory/macx-tests-<UUID>`, `macx-scenario-<UUID>`, `macx-release-<UUID>`) or inside disk images they create themselves. Never touch, move, rename, trash or delete any pre-existing user file. The app may READ the user's real folders while a human browses, but automated scenarios must point the app at a sandbox dir (`--root <sandbox> --state-dir <sandbox>/state`).
- Phase 4 additions to that rule:
  - Tag, custom-icon, ACL, batch-rename, compress and extract tests run only on files inside a `Sandbox`.
  - Extraction tests with crafted archives also assert that a sibling directory outside the extraction target is byte-for-byte unchanged.
  - Keymap import/export tests read and write only sandbox files. Tests never show `NSOpenPanel`/`NSSavePanel`.
  - Tests never run as root and never call `sudo`, `launchctl`, `SMAppService.register()`/`unregister()` or `AuthorizationCopyRights` with interaction allowed.
  - The helper's logic is tested in-process as the current user, and its XPC layer over `NSXPCListener.anonymous()`. Installing the real daemon is a manual release-checklist step on a signed build, run against files the tester creates for that purpose.
  - Automated tests never mount real network shares and never open network connections. `NetworkMounting` and `NetworkHostBrowsing` use fakes; NetFS and `NWBrowser` are exercised only in the manual checklist.
  - Sparkle never starts in tests, in `--root`/`--state-dir` sandbox mode, or when `SUFeedURL` is absent (`UpdaterPolicy`, P4-20).
  - Release scripts run locally only with `--dry-run`. That mode builds into a fresh `${TMPDIR}/macx-release-<UUID>`, signs ad-hoc (`--identity -`), creates DMGs only inside that dir, and never runs `notarytool`, `stapler`, `security` keychain commands, `gh release` or `git push`. Those run only in the tag workflow on a GitHub runner, with a keychain created under `$RUNNER_TEMP`.
  - The Spotlight-backed tag query is never pointed at real user folders by tests. Tests use `CrawlTagQuery` scoped to the sandbox.
- No listening sockets anywhere. The helper is reachable only through its launchd Mach service. It accepts a connection only if the peer satisfies the code-signing requirement passed by its launchd plist, and each request only if it carries a valid Authorization Services right.

**Dependencies and layering:**
- Sparkle 2 (`https://github.com/sparkle-project/Sparkle`, `from: "2.7.0"`, exact resolved version pinned in `Package.resolved`) is the only third-party dependency. Only the `macExplorer` (App) target imports it. `scripts/check-layering.sh` (P1-42) is extended to enforce that.
- Only files under `Sources/Core/Platform/` may import AppKit or ServiceManagement inside `Core` (Phase 1 rule, extended to ServiceManagement). NetFS, Network, AppleArchive, Security and ImageIO may be imported anywhere in `Core`.
- New targets: `MacxHelperShared` (Foundation only: XPC protocol and Codable request/response types), `MacxHelperCore` (Darwin + Foundation: policy, single-item operations, audit log), `macx-helper` (executable: listener, authorization check), and test target `HelperTests`. None of them import AppKit.
- New user-visible strings go in `Sources/UI/Resources/Localizable.xcstrings` through `L10n`. Core still produces typed values only (`BatchRenameStatus`, `MountError`, `KeymapIssue`, …).
- Settings additions are additive: an absent key decodes to its default and `Settings.schemaVersion` keeps the value it had before Phase 4 (`1` after Phase 1, `2` once Phase 2's P2-01 has landed). No Phase 4 task bumps it or changes the meaning of an existing key.
- New `JobKind`, `JobVerb`, `ItemAction`, `AttributeEdit`, `FileOpErrorKind`, `ErrorResolution` and `Command` cases must be handled in every exhaustive `switch` in Phase 1 code: `JobRunner` dispatch, `JobDescription` building, `UndoPlanner`, `FileOpErrorKind.allowedResolutions`, `Command.selectorName`, `CommandAvailability`, `MainMenuBuilder`, `FileCommandController` and `KeymapPreset`. Never add a `default:` branch to these switches. The compiler is how missing handling gets found.
- Test file-system access uses the P1-02 `MacxFixtures` API exactly (S1 P1-02 Interfaces, Contract notes 1): `let sandbox = try Sandbox()` (prefix `macx-tests`), `sandbox.root`, `try sandbox.createFile("a.txt", contents: Data("x".utf8)) -> URL`, `try sandbox.createDirectory("d") -> URL`, `try sandbox.createSymlink("l", target: "a.txt") -> URL`, `sandbox.url("rel") -> URL`, `sandbox.contains(_:)`, and `sandbox.destroy()` in teardown. FileOps job tests subclass S3's `FileOpsTestCase` (`file(_:_:)`, `dir(_:)`, `url(_:)`, `makeQueue(...)`, `run(_:on:)`), and UI tests use S5's `ContentTestHarness` (`make(self)`, `file`, `dir`, `url`, `openBrowserWindow`, `waitUntil`); both wrap `Sandbox`. Never add a write path that bypasses `Sandbox`.
- Every task ends with `swift build 2>&1 | tail -5` showing `Build complete!` with zero warnings and `swift test --filter <TaskTests> 2>&1 | tail -5` showing `Executed N tests, with 0 failures`. P4-23 runs the full suite.
- Commits: one per task minimum, conventional prefix, on the working branch; never push.

**Performance (spec §4.4 still binds):**
- Menus, the command palette, the Tags submenu and the Open With submenu never do file-system I/O while being built. They read caches (`TagCache`, `LaunchServicesCache`) and update in place.
- Batch-rename preview for 10,000 names finishes in < 100 ms off the main thread (asserted at 4x in debug, P4-11).
- Palette ranking over every command plus 20 favorites plus 20 recents finishes in < 2 ms (P4-03).
- Icon-pack images are rasterized on a lane when the pack loads, so they are available in the first frame afterwards (P4-08).

## Review Focus

These are the five inputs the spec implies but no feature-derived test would naturally cover, ordered by how likely they are to bite a real user. Each one names the task that MUST contain the listed test.

1. **Batch rename whose targets are other selected items' current names** (swap `a.txt`↔`b.txt`, chain `1.txt→2.txt→3.txt→4.txt`, a 3-cycle, and case-only renames `A.txt→a.txt` on a case-insensitive volume). Expected: every item ends at its target, nothing is overwritten or lost, an interrupted run is restored by launch recovery, and one undo restores all the original names. Owner P4-11: `testBatchRenameSwapChainCycleAndCaseOnly`, `testBatchRenameRecoveryRestoresOriginals`, `testBatchRenameUndoRestoresAll`.
2. **Archives with unsafe entries** (`../escape.txt`, `/abs.txt`, or a symlink entry `link -> ../outside` followed by `link/evil.txt`). Expected: Extract Here refuses with `.unsafeArchive` before writing anything, the partial directory is removed, and a sibling directory outside the target is unchanged. Owner P4-10: `testExtractRefusesTraversalAbsoluteAndSymlinkEscape`.
3. **Imported or edited keymaps that collide**: two commands on one chord, a text-editing chord (`opt+left`, `cmd+backspace`) as a primary, a system-reserved chord (`cmd+q`, `cmd+tab`, `ctrl+up`), or a command name from a newer version. Expected: conflicts and reserved chords are rejected with the offending pairs listed, unknown commands are skipped with a warning, and a text-editing primary is accepted but disabled while a field editor has focus. Owners: P4-01 `testImportRejectsConflictsAndReservedSkipsUnknown`; P4-02 `testCustomPrimaryCollidingWithTextEditingIsDisabledInFieldEditor`.
4. **Compress or extract when the output name is taken, or cancelled midway.** Expected: `Archive.zip` → `Archive 2.zip`, an existing folder `photos` → `photos 2`, and cancel leaves no `.macx-partial-*` or staging directory and an empty journal. Owners: P4-09 `testCompressNamesNextFreeAndCancelLeavesNothing`; P4-10 `testExtractNextFreeFolderName`.
5. **Dual-pane F5/F6 when both panes show the same folder, or the other pane is inside a selected folder.** Expected: F5 into the same folder makes Finder-style `name copy` duplicates; F6 into the same folder does nothing (no job, no conflict dialog); F6 into a descendant reports a per-item `.intoItself` error and moves the other items. Owner P4-13: `testOtherPaneSameFolderAndDescendant`.

---

## 1. Package.swift after Phase 4 (P4-15, P4-16 and P4-20 make these edits; the final state is exact)

Additions to the Phase 1 manifest (overview §1). Everything not shown is unchanged.

```swift
let package = Package(
    name: "macExplorer",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "macExplorer", targets: ["macExplorer"]),
        .executable(name: "macx-bench", targets: ["macx-bench"]),
        .executable(name: "macx-scenarios", targets: ["macx-scenarios"]),
        .executable(name: "macx-helper", targets: ["macx-helper"]),                       // P4-16
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),       // P4-20
    ],
    targets: [
        // ... Phase 1 targets unchanged except:
        .target(name: "MacxHelperShared", swiftSettings: strict),                            // P4-15
        .target(name: "MacxHelperCore", dependencies: ["MacxHelperShared"], swiftSettings: strict), // P4-15
        .executableTarget(name: "macx-helper", dependencies: ["MacxHelperShared", "MacxHelperCore"],
                          swiftSettings: strict),                                            // P4-16
        .target(name: "Core", dependencies: ["MacxFS", "MacxHelperShared", "MacxHelperCore"],
                swiftSettings: strict),                                                      // P4-15 adds the two deps
        .executableTarget(
            name: "macExplorer",
            dependencies: ["UI", "Core", .product(name: "Sparkle", package: "Sparkle")],     // P4-20
            path: "Sources/App",
            swiftSettings: strict,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] // P4-20
        ),
        .testTarget(name: "HelperTests", dependencies: ["MacxHelperCore", "MacxHelperShared", "MacxFixtures", "macx-helper"],
                    swiftSettings: strict),                                                  // P4-15; P4-16 adds "macx-helper"
    ],
    swiftLanguageModes: [.v6]
)
```

## 2. File structure (Phase 4 additions and modifications)

One line of responsibility per file. Owning task in brackets. `M` = modifies a Phase 1 (or earlier Phase 4) file.

```
Sources/Core/Commands/Command.swift                    M [P4-01] + Phase 4 cases (§3.1)
Sources/Core/Commands/CommandAvailability.swift        M [P4-01] Phase 4 rows; CommandState fields
Sources/Core/Commands/KeyMap.swift                     M [P4-01] becomes a facade over KeymapPreset.explorer
Sources/Core/Commands/KeyChord.swift                   M [P4-01] + `serialized`
Sources/Core/Commands/KeyDispatcher.swift              M [P4-02] init(keymap: ResolvedKeymap)
Sources/Core/Commands/Keymap/KeyBinding.swift          [P4-01] KeyBinding, ScopedChord, BindingScope
Sources/Core/Commands/Keymap/KeymapPreset.swift        [P4-01] explorer + finder tables (exhaustive switch)
Sources/Core/Commands/Keymap/KeymapProfile.swift       [P4-01] base preset + overrides
Sources/Core/Commands/Keymap/ResolvedKeymap.swift      [P4-01] lookup tables per (profile, returnKey, dualPane)
Sources/Core/Commands/Keymap/SpecialChords.swift       [P4-01] text-editing and system-reserved chord sets
Sources/Core/Commands/Keymap/KeymapValidator.swift     [P4-01] conflicts / reserved / issues
Sources/Core/Commands/Keymap/KeymapDocument.swift      [P4-01] JSON import/export format v1
Sources/Core/Commands/Keymap/KeymapStore.swift         [P4-02] @MainActor @Observable: Settings.keymap → ResolvedKeymap
Sources/Core/Palette/FuzzyMatcher.swift                [P4-03] subsequence scorer
Sources/Core/Palette/PaletteCatalog.swift              [P4-03] items (commands, favorites, recents), ranking, MRU
Sources/Core/Tags/FileTag.swift                        [P4-04] TagColor, FileTag (+ standard tags)
Sources/Core/Tags/TagIO.swift                          [P4-04] xattr read/write (lane only)
Sources/Core/Tags/TagCache.swift                       [P4-05] @MainActor per-URL tag cache filled on lanes
Sources/Core/Tags/TagQuery.swift                       [P4-06] TagQuerying, SpotlightTagQuery, CrawlTagQuery
Sources/Core/FileOps/TagJobs.swift                     [P4-04] setTags execution
Sources/Core/Icons/IconImageData.swift                 [P4-07] image bytes + validation
Sources/Core/Icons/IconPack.swift                      [P4-08] IconPack, IconPackLoader
Sources/Core/Platform/WorkspaceIconWriter.swift        [P4-07] CustomIconWriting via NSWorkspace.setIcon (lane)
Sources/Core/FileOps/IconJobs.swift                    [P4-07] setCustomIcon execution
Sources/Core/Archive/ArchiveFormat.swift               [P4-09] formats, detection (magic + extension), naming
Sources/Core/Archive/ProcessRunner.swift               [P4-09] run /usr/bin tools on a lane: heartbeat, cancel (SIGTERM), pause (SIGSTOP/SIGCONT)
Sources/Core/Archive/CompressJob.swift                 [P4-09] stage → ditto/AppleArchive → partial → final
Sources/Core/Archive/ArchiveLister.swift               [P4-10] entry list (tar -tf + tar -tvf; AppleArchive headers)
Sources/Core/Archive/ArchiveSafety.swift               [P4-10] traversal / absolute / through-symlink rules
Sources/Core/Archive/ExtractJob.swift                  [P4-10] validate → extract into partial → post-check → place
Sources/Core/Rename/BatchRenameRules.swift             [P4-11] rules + pure name transform
Sources/Core/Rename/RegexTemplate.swift                [P4-11] $0–$9 template expansion
Sources/Core/Rename/BatchRenamePlanner.swift           [P4-11] preview rows + statuses
Sources/Core/FileOps/BatchRenameJob.swift              [P4-11] cycle-safe two-phase executor
Sources/Core/ACL/ACLEntry.swift                        [P4-14] ACLEntry, Principal, permission/inheritance sets
Sources/Core/ACL/ACLIO.swift                           [P4-14] acl_* read/write, text form (lane only)
Sources/Core/ACL/PrincipalDirectory.swift              [P4-14] users/groups listing and name ↔ UUID (lane)
Sources/Core/Privileged/PrivilegedFileOperating.swift  [P4-17] protocol + PrivilegeError + FailedStep
Sources/Core/Privileged/PrivilegedRetryPlanner.swift   [P4-17] FailedStep → [HelperOperation]
Sources/Core/Privileged/EmulatedPrivilegedOperator.swift [P4-17] test/--fake-helper operator (HelperCore as user + parent chmod)
Sources/Core/Platform/HelperClient.swift               [P4-16] XPC client + SMAppService registration + availability
Sources/Core/Platform/AuthorizationClient.swift        [P4-16] AuthorizationCopyRights (prompt) → external form
Sources/Core/Network/ServerAddress.swift               [P4-19] parse smb/afp/nfs/cifs/UNC, display, strip password
Sources/Core/Network/NetworkMounting.swift             [P4-19] protocol, MountError, FakeNetworkMounter
Sources/Core/Network/NetFSMounter.swift                [P4-19] NetFSMountURLAsync + cancel
Sources/Core/Network/HostBrowser.swift                 [P4-19] NetworkHostBrowsing, BonjourSMBBrowser, FakeHostBrowser, endpoint resolve
Sources/Core/Support/UpdaterPolicy.swift               [P4-20] pure "may Sparkle start?" decision
Sources/Core/FileOps/JobTypes.swift                    M [P4-04,07,09,10,11,17] new JobKind/JobVerb cases; JobRequest.elevated
Sources/Core/FileOps/JobRecord.swift                   M [P4-04,07,14,17] new ItemAction cases; AttributeSnapshot.acl; JobRecord.elevated
Sources/Core/FileOps/FileOpError.swift                 M [P4-10,17] .unsafeArchive/.unsupportedArchive; .authenticate; failedStep
Sources/Core/FileOps/JobRunner.swift                   M [P4-04,07,09,10,11,17] dispatch + privileged retry
Sources/Core/FileOps/UndoPlanner.swift                 M [P4-04,07,11,14] inverses for new actions
Sources/Core/FileOps/AttributeJobs.swift               M [P4-14] .acl edit
Sources/Core/Settings/Settings.swift                   M [P4-02,03,04,06,08,13,19] new keys (§3.9)
Sources/Core/Settings/SettingsTypes.swift              M [P4-06] SidebarSection.tags
Sources/Core/Support/LaunchOptions.swift               M [P4-02,17,19] --keymap, --fake-helper, --fake-network
Sources/Core/Support/CoreEnvironment.swift             M [P4-02,05,17,19] keymapStore, tagCache, privileged, network
Sources/FSKit/Store/TypeRegistry.swift                 M [P4-08] extensionString(at:)
Sources/Core/Tags/TagSearchEvents.swift                [P4-06] TagQueryUpdate stream → Phase 3 SearchEvent stream (Step 5; needs Phase 3)
Sources/Core/FileOps/FaultPoint.swift                  M [P4-09,11] + archiveToolStarted, batchRenameStaged
Sources/Core/FileOps/FileOpQueue.swift                 M [P4-07,09,17] init gains iconWriter:, privileged:; internal toolOverride knob
Sources/Core/FileOps/Journal.swift                     M [P4-11] JournalEntry.batchRename(job:steps:), BatchRenameStep
Sources/Core/FileOps/LaunchRecovery.swift              M [P4-11] batch-rename roll-back
Sources/Core/Properties/ItemProperties.swift           M [P4-08] hasCustomIcon
Sources/Core/Properties/PropertiesLoader.swift         M [P4-08] fills hasCustomIcon from FinderInfo
Sources/UI/Toolbar/AddressBarView.swift                M [P4-19] UNC / smb:// input → mount → navigate
Sources/UI/Properties/PropertiesView.swift             M [P4-05,08,18] Tags row, icon well, ACL section + padlock
Sources/UI/Properties/PropertiesViewModel.swift        M [P4-05,08,18] tag/icon/ACL edits → jobs; unlock state
Sources/UI/Menus/ContextMenuBuilder.swift              M [P4-05,09,10,12] Tags ▸, Compress, Extract Here, Rename N Items…
Sources/UI/Commands/FileCommandController.swift        M [P4-05,09,10,12,13,19] Phase 4 command handlers
Sources/UI/Operations/ErrorText.swift                  M [P4-10,17] texts for .unsafeArchive, .unsupportedArchive, Authenticate…
Sources/UI/Settings/GeneralSettingsView.swift          M [P4-08,13] icon pack chooser; "Open new windows in dual pane"
Sources/macx-scenarios/Scenarios/Catalog.swift         M [P4-23] + Phase4Scenarios.all
Tests/CoreTests/FileOps/CrashHelper.swift              M [P4-11] CrashSpec mode "batchRename"
Tests/ScenarioRunnerTests/CatalogTests.swift           M [P4-23] Phase 4 families
scripts/release/selftest.sh                            [P4-21,22] guard and golden tests for the release scripts
packaging/homebrew/tests/expected-cask.rb              [P4-22] golden rendered cask
scripts/verify-phase4.sh                               [P4-23] full verification run (one macx-verify-<UUID> dir)

Sources/MacxHelperShared/HelperProtocol.swift          [P4-15] @objc MacxHelperXPC, HelperOperation, HelperRequest/Reply/Result
Sources/MacxHelperShared/HelperConstants.swift         [P4-15] mach service name, right name, plist name
Sources/MacxHelperCore/HelperPolicy.swift              [P4-15] path validation, denied prefixes
Sources/MacxHelperCore/SafePath.swift                  [P4-15] openat walk with O_NOFOLLOW → (parent fd, leaf)
Sources/MacxHelperCore/HelperCore.swift                [P4-15] executes one HelperOperation
Sources/MacxHelperCore/HelperAudit.swift               [P4-15] JSON-lines audit log, rotation
Sources/macx-helper/main.swift                         [P4-16] NSXPCListener(machServiceName:) + run loop
Sources/macx-helper/HelperService.swift                [P4-16] listener delegate: code-sign requirement, authorization check, dispatch
Sources/macx-helper/HelperAuthorizer.swift             [P4-16] HelperAuthorizing + AuthorizationServicesAuthorizer + right setup

Sources/UI/Settings/KeyboardSettingsView.swift         [P4-02] table, recorder, presets, import/export
Sources/UI/Settings/KeyRecorderView.swift              [P4-02] NSViewRepresentable chord capture
Sources/UI/Menus/MenuKeyEquivalent.swift               [P4-02] KeyChord → NSMenuItem keyEquivalent/modifiers
Sources/UI/Menus/MainMenuBuilder.swift                 M [P4-02] build(keymap:), applyKeyEquivalents
Sources/UI/Menus/KeyRouter.swift                       M [P4-02] handle(_:focus:keymap:from:)
Sources/UI/Menus/MenuValidation.swift                  M [P4-02] collision set from ResolvedKeymap
Sources/UI/Palette/CommandPaletteController.swift      [P4-03] key-capable panel, search field, results table
Sources/UI/Palette/CommandTitles.swift                 [P4-03] Command → localized title (shared with menus)
Sources/UI/Tags/TagEditorView.swift                    [P4-05] SwiftUI token field + colour dots
Sources/UI/Tags/TagMenu.swift                          [P4-05] context-menu Tags ▸ submenu
Sources/UI/Tags/TagDotsView.swift                      [P4-05] colour dots (Tags column, sidebar)
Sources/UI/Sidebar/SidebarTagsSection.swift            [P4-06] TAGS rows, drop-to-tag, menu
Sources/UI/Properties/IconWell.swift                   [P4-08] drop/paste target for the 64 pt icon
docs/icon-packs.md                                     [P4-08] icon pack folder format (a few lines)
Sources/UI/Support/IconCache.swift                     M [P4-07,08] invalidate(rowID:), icon pack lookup
Sources/UI/Rename/BatchRenameSheet.swift               [P4-12] SwiftUI rule controls
Sources/UI/Rename/BatchRenamePreviewTable.swift        [P4-12] NSTableView preview (NSViewRepresentable)
Sources/UI/Window/PaneController.swift                 [P4-13] session + content + pane header for one pane
Sources/UI/Window/PaneHeaderView.swift                 [P4-13] per-pane address bar + active indicator
Sources/UI/Window/BrowserWindowController.swift        M [P4-13] panes, active pane, dual toggle, Tab cycle
Sources/UI/Properties/ACLEditorView.swift              [P4-18] ACL table + entry sheet
Sources/UI/Properties/PermissionsLock.swift            [P4-18] padlock → authorize → editable
Sources/UI/Operations/ErrorDialog.swift                M [P4-17] Authenticate… button
Sources/UI/Network/ConnectToServerView.swift           [P4-19] address, recents, favorites, Nearby, Connect/Cancel
Sources/UI/Network/ConnectToServerWindowController.swift [P4-19] ⌘K window
Sources/UI/Scenario/ScenarioFile.swift                 M [P4-13,23] paneCount/activePane/otherPane* expectations; sheet steps
Sources/App/Updater.swift                              [P4-20] SPUStandardUpdaterController wrapper

Resources/Info.plist                                   M [P4-19,20] NSLocalNetworkUsageDescription, NSBonjourServices, SU* keys (templated)
Resources/LaunchDaemons/com.macexplorer.app.helper.plist [P4-16] template (BundleProgram, MachServices, requirement arg)
scripts/bundle.sh                                      M [P4-16,20,21] helper + daemon plist, Sparkle.framework, version, --universal
scripts/check-layering.sh                              M [P4-20] Sparkle only in Sources/App; no AppKit in helper targets
scripts/release/common.sh                              [P4-21] safety guards (temp-dir check, dry-run switches)
scripts/release/build-universal.sh                     [P4-21] swift build --arch arm64 --arch x86_64 + bundle
scripts/release/sign.sh                                [P4-21] inside-out codesign (Sparkle parts, helper, app)
scripts/release/notarize.sh                            [P4-21] notarytool submit --wait + stapler (CI only)
scripts/release/package.sh                             [P4-21] zip (ditto) + DMG (hdiutil UDZO)
scripts/release/make-appcast.swift                     [P4-21] appcast.xml with Ed25519 signature (CryptoKit)
scripts/release/verify-bundle.sh                       [P4-21] lipo, codesign --verify, plist, (spctl/stapler when notarized)
scripts/release/dry-run.sh                             [P4-21] whole pipeline locally, ad-hoc, in macx-release-<UUID>
scripts/release/entitlements.plist                     [P4-21] app entitlements (empty dict; hardened runtime only)
scripts/release/tests/                                 [P4-21] test-only Ed25519 key pair + expected-appcast.xml golden
scripts/release/render-cask.sh                         [P4-22] cask from template with version/sha256/repo
packaging/homebrew/macexplorer.rb.template             [P4-22] cask template
packaging/homebrew-tap/README.md                       [P4-22] tap repo bootstrap contents
packaging/homebrew-tap/.github/workflows/audit.yml     [P4-22] brew audit/style in the tap repo
.github/workflows/release.yml                          [P4-21,22] tag → build, sign, notarize, release, appcast, cask
docs/release/checklist.md                              [P4-21,23] per-release manual checklist (incl. helper, SMB, Sparkle)
docs/release/homebrew-cask-submission.md               [P4-22] criteria + steps for homebrew/homebrew-cask

Tests/CoreTests/Keymap/KeymapPresetTests.swift         [P4-01]
Tests/CoreTests/Keymap/KeymapDocumentTests.swift       [P4-01]
Tests/CoreTests/Keymap/KeymapStoreTests.swift          [P4-02]
Tests/CoreTests/Palette/FuzzyMatcherTests.swift        [P4-03]
Tests/CoreTests/Palette/PaletteCatalogTests.swift      [P4-03]
Tests/CoreTests/Tags/TagIOTests.swift                  [P4-04]
Tests/CoreTests/Tags/TagJobTests.swift                 [P4-04]
Tests/CoreTests/Tags/TagQueryTests.swift               [P4-06]
Tests/CoreTests/Icons/CustomIconTests.swift            [P4-07]
Tests/CoreTests/Icons/IconPackTests.swift              [P4-08]
Tests/CoreTests/Archive/CompressTests.swift            [P4-09]
Tests/CoreTests/Archive/ExtractTests.swift             [P4-10]
Tests/CoreTests/Archive/CraftedArchives.swift          [P4-10] in-test zip/tar byte writers
Tests/CoreTests/Rename/BatchRenameRulesTests.swift     [P4-11]
Tests/CoreTests/Rename/BatchRenameJobTests.swift       [P4-11]
Tests/CoreTests/ACL/ACLTests.swift                     [P4-14]
Tests/HelperTests/HelperPolicyTests.swift              [P4-15]
Tests/HelperTests/HelperCoreTests.swift                [P4-15]
Tests/HelperTests/HelperXPCTests.swift                 [P4-16]
Tests/CoreTests/Privileged/AuthenticateTests.swift     [P4-17]
Tests/CoreTests/Network/ServerAddressTests.swift       [P4-19]
Tests/CoreTests/Network/NetworkFlowTests.swift         [P4-19]
Tests/CoreTests/UpdaterPolicyTests.swift               [P4-20]
Tests/UITests/KeyboardSettingsTests.swift              [P4-02]
Tests/UITests/CommandPaletteTests.swift                [P4-03]
Tests/UITests/TagUITests.swift                         [P4-05]
Tests/UITests/SidebarTagsTests.swift                   [P4-06]
Tests/UITests/IconWellTests.swift                      [P4-08]
Tests/UITests/BatchRenameSheetTests.swift              [P4-12]
Tests/UITests/DualPaneTests.swift                      [P4-13]
Tests/UITests/ACLEditorTests.swift                     [P4-18]
Tests/UITests/ConnectToServerTests.swift               [P4-19]
Tests/Scenarios/p4-*.json                              [P4-23] UI scenarios (list in P4-23)
Sources/macx-scenarios/Scenarios/Phase4Scenarios.swift [P4-23] Core scenarios
```

## 3. Interface contract additions

Copy these declarations exactly (names, labels, types, isolation, `Sendable`, `throws`). Bodies belong to the owning task. Anything not listed is internal.

### 3.1 Commands and keymap (P4-01, P4-02)

```swift
// Command.swift: appended cases (selectorName "macx_<rawValue>:")
case toggleDualPane, copyToOtherPane, moveToOtherPane          // P4-13
case showCommandPalette                                        // P4-03
case connectToServer                                           // P4-19
case compressZip, compressAppleArchive, extractHere            // P4-09, P4-10
case batchRename                                               // P4-12
case editTags                                                  // P4-05
case checkForUpdates                                           // P4-20

// CommandAvailability.swift: CommandState gains (all defaulted, appended to init):
public var dualPaneActive: Bool          // default false
public var selectionIsArchive: Bool      // exactly one selected item whose ArchiveFormat.detect(byName:) != nil
public var updaterAvailable: Bool        // UpdaterPolicy said yes and Sparkle started
// CommandAvailability gains:
public static let shippedPhase4Commands: Set<Command>   // P4-01: []; each owning task adds its commands to the literal
// isEnabled(...) returns false for a Phase 4 command not in shippedPhase4Commands.

// Keymap/KeyBinding.swift
public enum BindingScope: String, Sendable, Codable, Hashable { case always, singlePane, dualPane }
public struct ScopedChord: Sendable, Codable, Hashable {
    public var chord: KeyChord
    public var scope: BindingScope
    public init(_ chord: KeyChord, _ scope: BindingScope = .always)
    public init?(parsing text: String)            // "F5", "F5@dualPane", "ctrl+c@always"
    public var serialized: String { get }         // scope .always omitted
}
public struct KeyBinding: Sendable, Codable, Hashable {
    public var primary: KeyChord?                 // menu key equivalent (global)
    public var alternates: [ScopedChord]          // content/sidebar keyDown only
    public init(primary: KeyChord?, alternates: [ScopedChord] = [])
    public static let none: KeyBinding
}

// Keymap/KeymapPreset.swift
public enum KeymapPreset: String, Sendable, Codable, CaseIterable {
    case explorer, finder
    public func binding(for command: Command) -> KeyBinding   // exhaustive switch, no default
}

// Keymap/KeymapProfile.swift
public struct KeymapProfile: Sendable, Codable, Equatable {
    public var base: KeymapPreset
    public var overrides: [String: KeyBinding]    // Command.rawValue → binding (String keys: JSON object)
    public init(base: KeymapPreset = .explorer, overrides: [String: KeyBinding] = [:])
    public func binding(for command: Command) -> KeyBinding
    public static let explorerDefault: KeymapProfile
    /// Sets `command`'s primary. stealing: removes `chord` from every other command's primary/alternates first.
    public func assigningPrimary(_ chord: KeyChord?, to command: Command, stealing: Bool) -> KeymapProfile
    public func settingAlternates(_ alternates: [ScopedChord], for command: Command) -> KeymapProfile
    /// Commands (other than `command`) whose primary or overlapping-scope alternate equals `chord`.
    public func users(of chord: KeyChord, scope: BindingScope, excluding command: Command?) -> [Command]
}

// Keymap/SpecialChords.swift
public enum SpecialChords {
    public static let textEditing: Set<KeyChord>  // chords a field editor uses (list in P4-01)
    public static let reserved: Set<KeyChord>     // system/app chords that can't be bound (list in P4-01)
}

// Keymap/KeymapValidator.swift
public enum KeymapIssue: Sendable, Equatable {
    case conflict(chord: KeyChord, commands: [Command])   // sorted by rawValue
    case reserved(chord: KeyChord, command: Command)
}
public enum KeymapValidator {
    public static func issues(_ profile: KeymapProfile) -> [KeymapIssue]   // sorted: conflicts by chord.serialized, then reserved
}

// Keymap/ResolvedKeymap.swift
public struct ResolvedKeymap: Sendable, Equatable {
    public init(profile: KeymapProfile, returnKey: ReturnKeyBehavior, dualPane: Bool)
    public func primary(_ command: Command) -> KeyChord?
    public func alternates(_ command: Command) -> [KeyChord]          // active in this context only
    public func command(forAlternate chord: KeyChord) -> Command?     // Return → open/rename per returnKey
    public var collidesWithTextEditing: Set<Command> { get }          // primary ∈ SpecialChords.textEditing
    public static let phase1Default: ResolvedKeymap                   // explorerDefault, .open, single pane
}

// Keymap/KeymapDocument.swift
public enum KeymapWarning: Sendable, Equatable { case unknownCommand(String) }
public enum KeymapImportError: Error, Sendable, Equatable {
    case notAKeymap, unsupportedVersion(Int), unknownBase(String)
    case invalidChord(command: String, text: String)
    case issues([KeymapIssue])
}
public enum KeymapDocument {
    public static let format: String        // "macexplorer-keymap"
    public static let version: Int          // 1
    public static func export(_ profile: KeymapProfile) -> Data                       // sorted keys, pretty
    public static func `import`(_ data: Data) throws(KeymapImportError) -> (KeymapProfile, [KeymapWarning])
}

// KeyChord.swift addition
extension KeyChord { public var serialized: String { get } }   // round-trips through init?(parsing:)

// KeyMap.swift (Phase 1 API kept as a facade)
// KeyMap.primary(c) == KeymapPreset.explorer.binding(for: c).primary
// KeyMap.alternates(c) == alternates with scope .always or .singlePane
// KeyMap.collidesWithTextEditing == ResolvedKeymap.phase1Default.collidesWithTextEditing

// KeyDispatcher.swift (P4-02 replaces init(returnKey:))
public struct KeyDispatcher: Sendable {
    public init(keymap: ResolvedKeymap)
    public func command(for chord: KeyChord, in focus: FocusContext) -> Command?   // nil for .fieldEditor/.addressBar
}

// Keymap/KeymapStore.swift (P4-02)
@MainActor @Observable
public final class KeymapStore {
    public init(settings: Settings)
    public private(set) var profile: KeymapProfile
    public func resolved(dualPane: Bool) -> ResolvedKeymap
    public func apply(_ profile: KeymapProfile) throws(KeymapImportError)          // validates, saves to Settings
    public func reset(to preset: KeymapPreset)
    public func observe(_ handler: @escaping @MainActor () -> Void) -> ObserverToken
}
```

### 3.2 Palette (P4-03)

```swift
public struct FuzzyMatch: Sendable, Equatable { public var score: Int; public var matchedIndices: [Int] }
public enum FuzzyMatcher {
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch?
}
public enum PaletteTarget: Sendable, Hashable { case command(Command), location(URL) }
public struct PaletteItem: Sendable, Hashable, Identifiable {
    public var id: PaletteTarget { get }
    public var target: PaletteTarget
    public var title: String               // localized by UI before handing in
    public var subtitle: String?           // path for locations, key binding for commands
    public init(target: PaletteTarget, title: String, subtitle: String?)
}
public struct RankedPaletteItem: Sendable, Equatable { public var item: PaletteItem; public var match: FuzzyMatch }
public enum PaletteCatalog {
    /// Empty query: MRU first (most recent first), then alphabetical by title. Otherwise by score
    /// (+ MRU boost: 30 − 3 × rank for the 10 most recent), ties shorter title, then title.
    public static func rank(_ items: [PaletteItem], query: String, recent: [PaletteTarget]) -> [RankedPaletteItem]
}
```

### 3.3 Tags (P4-04 … P4-06)

```swift
public enum TagColor: Int, Sendable, Codable, CaseIterable { case none = 0, gray, green, purple, blue, yellow, red, orange }
public struct FileTag: Sendable, Codable, Hashable {
    public var name: String
    public var color: TagColor
    public init(name: String, color: TagColor = .none)
    public static let standard: [FileTag]      // Red 6, Orange 7, Yellow 5, Green 2, Blue 4, Purple 3, Gray 1
}
public struct TagIOError: Error, Sendable, Equatable { public var code: Int32 }
public enum TagIO {
    public static let xattrName: String         // "com.apple.metadata:_kMDItemUserTags"
    public static func decode(_ data: Data) -> [FileTag]
    public static func encode(_ tags: [FileTag]) throws -> Data
    public static func normalize(_ tags: [FileTag]) -> [FileTag]   // trim, drop empty/"\n", dedupe case-insensitively (first wins)
    public static func read(_ url: URL) throws(TagIOError) -> [FileTag]          // lane only; ENOATTR → []
    public static func write(_ tags: [FileTag], to url: URL) throws(TagIOError)  // lane only; [] removes the xattr
}
public enum TagEdit: Sendable, Codable, Equatable { case set([FileTag]), add(FileTag), remove(String), toggle(FileTag) }
// JobKind: case setTags([URL], TagEdit)          JobVerb: case tagging
// ItemAction: case tagsChanged(URL, old: [FileTag], new: [FileTag])

@MainActor public final class TagCache {
    public init(lanes: LanePool, mountTable: MountTableStore)
    public func cachedTags(for url: URL) -> [FileTag]?      // nil = unknown (fetch scheduled)
    public func prefetch(_ urls: [URL])                     // ≤ 500 per call; lane reads under no-materialization
    public func invalidate(_ url: URL)
    public func observe(_ handler: @escaping @MainActor ([URL]) -> Void) -> ObserverToken
}

public enum TagScope: Sendable, Equatable { case thisMac, directory(URL) }
public enum TagQueryUpdate: Sendable, Equatable { case results([URL]), finished }   // results are cumulative
public protocol TagQuerying: Sendable {
    func results(for tagName: String, scope: TagScope) -> AsyncStream<TagQueryUpdate>
}
public struct SpotlightTagQuery: TagQuerying { public init() }                       // NSMetadataQuery on main
public struct CrawlTagQuery: TagQuerying { public init(lanes: LanePool) }           // fts + TagIO.read, .directory only

// Settings additions
public var knownTags: [FileTag]            // default FileTag.standard; ≤ 200; most recently used first
public var sidebarTags: [String]           // default the 7 standard names
public func noteTagUsed(_ tag: FileTag)
// SidebarSection: case tags
```

### 3.4 Custom icons (P4-07, P4-08)

```swift
public struct IconImageData: Sendable, Codable, Equatable {
    public var bytes: Data                    // PNG, TIFF, JPEG, HEIC or ICNS
    public init(bytes: Data)
    public static let maxBytes: Int           // 10 MiB
    public var isDecodableImage: Bool { get } // CGImageSourceCreateWithData + count > 0
}
public protocol CustomIconWriting: Sendable {
    func currentCustomIcon(_ url: URL) throws -> IconImageData?   // lane; nil when no custom-icon flag
    func setIcon(_ data: IconImageData?, for url: URL) throws     // lane; nil removes
}
public struct WorkspaceIconWriter: CustomIconWriting { public init() }   // Core/Platform
// JobKind: case setCustomIcon([URL], IconImageData?)   JobVerb: case changingIcon
// ItemAction: case customIconChanged(URL, previous: IconImageData?, new: IconImageData?)

public struct IconPack: Sendable, Equatable {
    public var folder: URL
    public var byExtension: [String: URL]     // lowercased extension → image file
    public var folderIcon: URL?               // "folder.<fmt>"
    public static let formatPriority: [String] // ["icns", "png", "pdf", "tiff", "jpg"]
}
public enum IconPackLoader { public static func load(_ folder: URL, lanes: LanePool) async throws -> IconPack }
// TypeRegistry: public func extensionString(at index: UInt16) -> String?   // nil for folder/data/symlink
// IconCache: func invalidate(rowID: RowID); func setIconPack(_ pack: IconPack?) async
// Settings: public var iconPackBookmark: Data?
```

### 3.5 Archives (P4-09, P4-10)

```swift
public enum ArchiveFormat: String, Sendable, Codable, CaseIterable {
    case zip, appleArchive, tar, tarGzip, tarBzip2, tarXz, gzip
    public var canCreate: Bool { get }                      // zip, appleArchive
    public static func detect(byName name: String) -> ArchiveFormat?          // pure, extension-based
    public static func detect(magic: Data, name: String) -> ArchiveFormat?    // first 512 bytes win over name
    public static func baseName(stripping name: String) -> String             // "a.tar.gz" → "a"
}
public enum ProcessOutput: Sendable, Equatable { case discard, capture, file(URL) }   // file: created O_EXCL
public struct ProcessResult: Sendable, Equatable { public var status: Int32; public var stdout: Data; public var stderrTail: String }
public enum ProcessRunner {
    /// Lane only. Polls every 50 ms: heartbeat, cancel → SIGTERM (SIGKILL after 2 s) then throws LaneError.cancelled,
    /// pause → SIGSTOP/SIGCONT. `capture` keeps at most 64 MiB of stdout. stderrTail = last 4 KiB.
    public static func run(_ tool: String, _ arguments: [String], output: ProcessOutput = .discard, context: LaneContext,
                           isPaused: @escaping @Sendable () -> Bool,
                           onStderrLine: @escaping @Sendable (String) -> Void) throws -> ProcessResult
}
public struct ArchiveEntry: Sendable, Equatable {
    public enum EntryType: Sendable, Equatable { case file, directory, symlink(target: String), other }
    public var path: String
    public var type: EntryType
}
public enum ArchiveSafetyProblem: Sendable, Equatable { case absolutePath(String), parentTraversal(String), throughSymlink(String), unlistable }
public enum ArchiveSafety {
    public static func problems(_ entries: [ArchiveEntry]) -> [ArchiveSafetyProblem]   // in entry order
    /// Incremental form for streaming extractors (AppleArchive filter).
    public struct Tracker: Sendable { public init(); public mutating func check(_ entry: ArchiveEntry) -> ArchiveSafetyProblem? }
}
// JobKind: case compress([URL], ArchiveFormat), extract(URL)     JobVerb: case compressing, extracting
// FileOpErrorKind: case unsafeArchive, unsupportedArchive        (allowedResolutions [.skip, .cancel])
```

### 3.6 Batch rename (P4-11, P4-12)

```swift
public struct BatchRenameRules: Sendable, Codable, Equatable {
    public enum Scope: String, Sendable, Codable { case baseName, wholeName, extensionOnly }
    public enum CaseChange: String, Sendable, Codable { case none, lower, upper, title, sentence }
    public struct Numbering: Sendable, Codable, Equatable {
        public enum Position: String, Sendable, Codable { case prefix, suffix, replaceName }
        public var start: Int = 1
        public var step: Int = 1
        public var minDigits: Int = 1
        public var position: Position = .suffix
        public var separator: String = " "
        public var baseName: String = ""      // .replaceName: "Trip" → "Trip (1)", "Trip (2)" (Explorer style)
        public init()
    }
    public var find: String = ""
    public var replace: String = ""
    public var useRegex = false
    public var caseSensitive = false
    public var prefix = ""
    public var suffix = ""
    public var caseChange: CaseChange = .none
    public var numbering: Numbering? = nil
    public var scope: Scope = .baseName
    public init()
    /// Pure. index = position in the selection's display order.
    public func apply(to name: String, index: Int) throws(BatchRenameRuleError) -> String
}
public enum BatchRenameRuleError: Error, Sendable, Equatable { case invalidPattern(String) }
public enum BatchRenameStatus: Sendable, Equatable {
    case ok, unchanged, invalid(NameProblem), duplicateInBatch, collidesWithExisting(String), invalidPattern(String)
    public var blocksApply: Bool { get }      // invalid, duplicateInBatch, collidesWithExisting, invalidPattern
}
public struct BatchRenameRow: Sendable, Equatable { public var url: URL; public var original: String; public var proposed: String; public var status: BatchRenameStatus; public var extensionChanged: Bool }
public struct BatchRenamePreview: Sendable, Equatable { public var rows: [BatchRenameRow]; public var canApply: Bool }
public struct BatchRenamePair: Sendable, Codable, Equatable { public var url: URL; public var newName: String; public init(url: URL, newName: String) }
public enum BatchRenamePlanner {
    /// existingNames: every name in the folder (hidden included, from EntryStore), NameNormalizer semantics.
    public static func preview(_ urls: [URL], rules: BatchRenameRules, caseSensitive: Bool, existingNames: [String]) -> BatchRenamePreview
    public static func pairs(_ preview: BatchRenamePreview) -> [BatchRenamePair]   // rows with status .ok
}
// JobKind: case batchRename([BatchRenamePair])     JobVerb: case batchRenaming
```

### 3.7 ACL (P4-14)

```swift
public struct ACLPermissions: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32)
    // read_data/list, write_data/add_file, execute/search, delete, append_data/add_subdirectory,
    // delete_child, readattr, writeattr, readextattr, writeextattr, readsecurity, writesecurity, chown
    public static let readData, writeData, execute, delete, appendData, deleteChild, readAttributes,
                      writeAttributes, readExtAttributes, writeExtAttributes, readSecurity, writeSecurity, changeOwner: ACLPermissions
    public static let readOnlyPreset, readWritePreset, fullControlPreset: ACLPermissions
}
public struct ACLInheritance: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let fileInherit, directoryInherit, limitInherit, onlyInherit: ACLInheritance
}
public enum ACLPrincipal: Sendable, Codable, Hashable { case user(name: String, uuid: UUID), group(name: String, uuid: UUID) }
public struct ACLEntry: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable { case allow, deny }
    public var kind: Kind
    public var principal: ACLPrincipal
    public var permissions: ACLPermissions
    public var inheritance: ACLInheritance
    public var isInherited: Bool                   // ACL_ENTRY_INHERITED; read-only in the editor
    public init(kind: Kind, principal: ACLPrincipal, permissions: ACLPermissions, inheritance: ACLInheritance = [], isInherited: Bool = false)
}
public struct ACLIOError: Error, Sendable, Equatable { public var code: Int32 }
public enum ACLIO {
    public static func read(_ url: URL) throws(ACLIOError) -> [ACLEntry]             // lane; no ACL → []
    /// Writes `explicit` (isInherited ignored) followed by the item's current inherited entries.
    public static func write(explicit: [ACLEntry], to url: URL) throws(ACLIOError)
    public static func text(_ url: URL) throws(ACLIOError) -> String                 // acl_to_text; "" when none
    public static func restore(text: String, to url: URL) throws(ACLIOError)         // "" removes the ACL
    public static func canonicalOrder(_ entries: [ACLEntry]) -> [ACLEntry]           // explicit deny, explicit allow, inherited
}
public enum PrincipalDirectory {
    public static let everyone: ACLPrincipal         // group "everyone", ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C
    public static func resolve(user name: String) -> ACLPrincipal?    // lane
    public static func resolve(group name: String) -> ACLPrincipal?   // lane
    public static func all(lanes: LanePool) async -> [ACLPrincipal]   // users with uid ≥ 500 + groups, sorted
}
// AttributeEdit: case acl([ACLEntry])
// AttributeSnapshot: public var acl: String?       // acl_to_text form for undo
```

### 3.8 Privileged helper (P4-15 … P4-17)

```swift
// MacxHelperShared/HelperConstants.swift
public enum HelperConstants {
    public static let machServiceName = "com.macexplorer.app.helper"
    public static let daemonPlistName = "com.macexplorer.app.helper.plist"
    public static let rightName = "com.macexplorer.app.privileged-file-operation"
    public static let protocolVersion = 1
}
// MacxHelperShared/HelperProtocol.swift
public enum HelperOperation: Sendable, Codable, Equatable {
    case makeDirectory(path: String, mode: UInt16)
    case createFile(path: String, mode: UInt16)
    case rename(from: String, to: String, exclusive: Bool)
    case copyItem(from: String, to: String)            // one item, Phase 1 §6.3 copyfile flags, no recursion
    case copyMetadata(from: String, to: String)        // COPYFILE_METADATA (directory post-order)
    case remove(path: String)                          // unlink or rmdir of one item
    case removeTree(path: String)                      // removefile(REMOVEFILE_RECURSIVE), never follows links
    case moveToTrash(path: String, uid: UInt32)        // → user's Trash on that volume; returns resulting path
    case setMode(path: String, mode: UInt16)
    case setFlags(path: String, flags: UInt32, mask: UInt32)
    case setACL(path: String, text: String)            // "" removes
    case setXattr(path: String, name: String, value: Data?)   // nil removes (tags)
}
public struct HelperRequest: Sendable, Codable, Equatable {
    public var id: UUID
    public var protocolVersion: Int
    public var authorization: Data                     // AuthorizationExternalForm (32 bytes)
    public var operation: HelperOperation
    public var jobID: String
    public init(id: UUID = UUID(), authorization: Data, operation: HelperOperation, jobID: String)
}
public enum HelperResult: Sendable, Codable, Equatable {
    case ok(resultPath: String?)
    case failed(errno: Int32)
    case refused(HelperRefusal)
}
public enum HelperRefusal: String, Sendable, Codable { case badPath, deniedLocation, symlinkInPath, notAuthorized, versionMismatch, malformed }
@objc public protocol MacxHelperXPC {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)   // JSON HelperRequest → JSON HelperResult
    func ping(reply: @escaping @Sendable (Int) -> Void)                        // protocolVersion
}

// MacxHelperCore
public struct ClientInfo: Sendable, Equatable { public var pid: Int32; public var uid: UInt32; public init(pid: Int32, uid: UInt32) }
public struct HelperEnvironment: Sendable {
    public var auditLog: URL                       // /Library/Logs/macExplorer/helper-audit.log (tests: sandbox)
    public var trashDirectory: @Sendable (_ path: String, _ uid: UInt32) -> String?   // tests: sandbox trash
    public var deniedPrefixes: [String]            // HelperPolicy.defaultDeniedPrefixes
    public init(auditLog: URL, trashDirectory: @escaping @Sendable (String, UInt32) -> String?, deniedPrefixes: [String] = HelperPolicy.defaultDeniedPrefixes)
    public static func production() -> HelperEnvironment
}
public enum HelperPolicy {
    public static let defaultDeniedPrefixes: [String]
    public static func validate(_ op: HelperOperation, deniedPrefixes: [String]) -> HelperRefusal?
}
public struct HelperCore: Sendable {
    public init(environment: HelperEnvironment)
    public func perform(_ op: HelperOperation, client: ClientInfo, jobID: String) -> HelperResult   // audits every call
}

// Core/Privileged/PrivilegedFileOperating.swift
public enum PrivilegeAvailability: Sendable, Equatable {
    case available
    case unavailable(Reason)
    public enum Reason: Sendable, Equatable { case unsignedBuild, needsApproval, notRegistered, failed(String) }
}
public enum PrivilegeError: Error, Sendable, Equatable { case cancelledByUser, unavailable(PrivilegeAvailability.Reason), refused(HelperRefusal), failed(errno: Int32), connection(String) }
public protocol PrivilegedFileOperating: Sendable {
    func availability() async -> PrivilegeAvailability
    func authorize() async throws(PrivilegeError)                 // may prompt; cached ≤ right timeout
    func perform(_ op: HelperOperation, jobID: JobID) async throws(PrivilegeError) -> String?
}
public enum FailedStep: Sendable, Codable, Equatable {
    case makeDirectory(URL, mode: UInt16), createFile(URL, mode: UInt16), rename(from: URL, to: URL, exclusive: Bool)
    case copyItem(from: URL, to: URL), copyMetadata(from: URL, to: URL), remove(URL), removeTree(URL), trash(URL)
    case setMode(URL, UInt16), setFlags(URL, flags: UInt32, mask: UInt32), setACL(URL, text: String), setXattr(URL, name: String, value: Data?)
}
public enum PrivilegedRetryPlanner { public static func operation(for step: FailedStep, uid: UInt32) -> HelperOperation }
public final class EmulatedPrivilegedOperator: PrivilegedFileOperating { public init(root: URL) }   // refuses paths outside root
// HelperClient (Core/Platform): public final class HelperClient: PrivilegedFileOperating { public init() }
// ErrorResolution: case authenticate
// FileOpErrorKind: public func allowedResolutions(privilegedAvailable: Bool) -> [ErrorResolution]
//   (Phase 1 `allowedResolutions` property == allowedResolutions(privilegedAvailable: false))
// FileOpError: public var failedStep: FailedStep?   (init gains `failedStep: FailedStep? = nil`)
// FileOpError: public var offersAuthenticate: Bool  (set by JobContext.askError; UI shows kind.allowedResolutions(privilegedAvailable: offersAuthenticate))
// JobRequest: public var elevated: Bool (init gains `elevated: Bool = false`)
// JobRecord:  public var elevated: Bool (decodes as false when absent)
// FileOpQueue.init gains `privileged: (any PrivilegedFileOperating)? = nil`
```

### 3.9 Network (P4-19)

```swift
public struct ServerAddress: Sendable, Hashable, Codable {
    public enum Scheme: String, Sendable, Codable { case smb, afp, nfs }
    public var scheme: Scheme
    public var host: String                 // lowercased; IPv6 without brackets
    public var port: Int?
    public var user: String?
    public var password: String?            // never persisted
    public var path: String                 // "" or "/share/sub"
    public init?(parsing text: String)      // smb://, cifs:// (→ smb), afp://, nfs://, \\host\share, //host/share, bare host (→ smb)
    public var url: URL { get }             // with password, for NetFS only
    public var displayString: String { get }// no password
    public var withoutPassword: ServerAddress { get }
}
public enum MountError: Error, Sendable, Equatable { case cancelled, unsupportedScheme, authenticationFailed, hostNotFound, failed(Int32) }
public protocol NetworkMounting: Sendable {
    func mount(_ address: ServerAddress, allowUI: Bool) async throws(MountError) -> [URL]   // mount points
}
public struct FakeNetworkMounter: NetworkMounting { public init(root: URL) }   // returns root/<host>/<first path component>, creating nothing
public final class NetFSMounter: NetworkMounting { public init() }
public struct DiscoveredHost: Sendable, Hashable, Identifiable { public var id: String { get }; public var name: String }
public protocol NetworkHostBrowsing: AnyObject, Sendable {
    func start(_ handler: @escaping @MainActor ([DiscoveredHost]) -> Void)
    func stop()
    func resolve(_ host: DiscoveredHost) async -> ServerAddress?
}
public final class BonjourSMBBrowser: NetworkHostBrowsing { public init() }   // _smb._tcp; started only by the Connect window
public final class FakeHostBrowser: NetworkHostBrowsing { public init(hosts: [DiscoveredHost]) }
// Settings: public var recentServers: [String] (≤ 10, displayString form); public var favoriteServers: [String]; public func noteServerUsed(_ a: ServerAddress)
```

### 3.10 Updates, windows, launch options (P4-13, P4-20, P4-02/17/19)

```swift
public enum UpdaterPolicy {
    /// false when sandboxed, when SUFeedURL or SUPublicEDKey is missing/empty, or when the feed is not https.
    public static func shouldStart(options: LaunchOptions, infoDictionary: [String: Any]) -> Bool
}
// LaunchOptions additions: keymapFile: URL? (--keymap), fakeHelper: Bool (--fake-helper), fakeNetworkRoot: URL? (--fake-network <dir>)
// Settings additions: keymap: KeymapProfile, paletteRecent: [String] (≤ 20), openNewWindowsInDualPane: Bool (false)
// CoreEnvironment additions: keymapStore: KeymapStore, tagCache: TagCache, privileged: (any PrivilegedFileOperating)?,
//   mounter: any NetworkMounting, hostBrowser: @MainActor () -> any NetworkHostBrowsing, iconWriter: any CustomIconWriting
// sandboxed(root:) uses EmulatedPrivilegedOperator(root:), FakeNetworkMounter(root: root/net), FakeHostBrowser([]), WorkspaceIconWriter()

// UI (internal): BrowserWindowController additions
var panes: [PaneController] { get }        // 1 or 2
var activePane: PaneController { get }
func setDualPane(_ on: Bool)
func activatePane(_ index: Int)
// ScenarioProbe additions
var probePaneCount: Int { get }
var probeActivePaneIndex: Int { get }
var probeOtherPaneRowNames: [String]? { get }
var probeOtherPaneFolderURL: URL? { get }
var probeSheetTitle: String? { get }       // title of an attached sheet (batch rename, conflict, …)
```

## 4. Ordered task list

| ID | Deliverable | Depends on |
|---|---|---|
| P4-01 | Phase 4 `Command` cases; keymap model (`KeyBinding`, `KeymapPreset` explorer/finder, `KeymapProfile`, `ResolvedKeymap`, `SpecialChords`, `KeymapValidator`, `KeymapDocument` JSON); `KeyMap` facade; Review Focus 3 (model half) | Phase 1 |
| P4-02 | Keymap integration: `KeymapStore`, `KeyDispatcher(keymap:)`, `MenuKeyEquivalent`, menus rebuilt live, `MenuValidation` collisions, Settings › Keyboard (table, recorder, presets, import/export), `--keymap`; Review Focus 3 (UI half) | P4-01 |
| P4-03 | Command palette: `FuzzyMatcher`, `PaletteCatalog`, `CommandTitles`, palette panel (⌘⇧P), MRU | P4-02 |
| P4-04 | Tags core: `FileTag`, `TagIO`, `setTags` job + undo, Settings `knownTags`/`sidebarTags` | P4-01 |
| P4-05 | Tags UI: `TagCache`, Properties tags editor, context-menu Tags ▸ + Tags…, Tags column dots | P4-04 |
| P4-06 | Tag queries: `SpotlightTagQuery`, `CrawlTagQuery`; sidebar TAGS section (show results, drop to tag, colours) | P4-05 |
| P4-07 | Custom icons core: `IconImageData`, `WorkspaceIconWriter`, `setCustomIcon` job + undo, Tier 1 invalidation | P4-01 |
| P4-08 | Custom icons UI (Properties icon well: drop, paste, Remove) + icon packs (`IconPackLoader`, `IconCache` lookup, Settings) | P4-07 |
| P4-09 | Compress: `ArchiveFormat`, `ProcessRunner`, `compress` job (staging, ditto zip, AppleArchive aar, partial, naming, cancel/pause); Review Focus 4 (compress) | P4-01 |
| P4-10 | Extract: `ArchiveLister`, `ArchiveSafety`, `extract` job (zip, tar family, gz, aar; single-top-level rule); menus; Review Focus 2 and 4 (extract) | P4-09 |
| P4-11 | Batch rename engine: rules, regex template, planner preview, cycle-safe job, undo, recovery; Review Focus 1 | P4-01 |
| P4-12 | Batch rename UI: sheet, live preview table, multi-selection F2 / Rename N Items… | P4-11 |
| P4-13 | Dual pane: `PaneController`, per-pane address bars, active pane, ⌘⇧E, F5/F6 to other pane, Tab cycle, restoration, probes; Review Focus 5 | P4-02 |
| P4-14 | ACL core: `ACLEntry`, `ACLIO`, `PrincipalDirectory`, `.acl` attribute edit + undo | P4-01 |
| P4-15 | Helper core: `MacxHelperShared`, `MacxHelperCore` (policy, `SafePath`, operations, audit) | P4-14 |
| P4-16 | Helper transport and packaging: `macx-helper` listener, code-sign requirement, `HelperAuthorizer`, launchd plist, `bundle.sh` embedding, `HelperClient` + `AuthorizationClient` + `SMAppService` | P4-15 |
| P4-17 | Authenticate… in FileOps: `ErrorResolution.authenticate`, `FailedStep` at Phase 1 failure sites, privileged retry, elevated jobs and undo, `EmulatedPrivilegedOperator`, ErrorDialog button | P4-16 |
| P4-18 | ACL editor and unlockable permissions in Properties › Permissions | P4-17 |
| P4-19 | Network: `ServerAddress`, `NetFSMounter`, `FakeNetworkMounter`, Bonjour browser, Connect to Server (⌘K), UNC paths in the address bar, Locations › Network row, Info.plist keys | P4-02 |
| P4-20 | Sparkle 2: dependency, `UpdaterPolicy`, `Updater`, Check for Updates…, framework embedding + signing in `bundle.sh`, layering check | P4-16 |
| P4-21 | Release pipeline: `scripts/release/*`, `make-appcast.swift`, `release.yml`, `dry-run.sh`, release checklist | P4-20 |
| P4-22 | Homebrew: cask template, `render-cask.sh`, tap bootstrap files, tap update job, homebrew-cask submission doc | P4-21 |
| P4-23 | Phase 4 validation: UI + Core scenarios for every feature, full-suite run, sandbox-clean check, "working" definition | all |

### Phase 4 "working" definition (what P4-23 verifies)

1. `swift build -c release` and `swift test --parallel` pass with zero warnings (all Phase 1 tests still pass).
2. `scripts/run-scenarios.sh` and `scripts/ui-scenarios.sh` pass, including every `p4-*` scenario.
3. `scripts/release/dry-run.sh` produces a universal (`arm64 x86_64`), ad-hoc signed `macExplorer.app` with embedded `Sparkle.framework` and `macx-helper`, a zip, a DMG, a signed `appcast.xml` whose signature verifies, and a rendered cask whose `sha256` matches the DMG, all inside one `macx-release-<UUID>` dir that it then deletes.
4. `scripts/check-layering.sh` passes.
5. No file outside test-created sandboxes and images was created, modified or deleted. Each runner prints its sandbox roots and confirms they are gone after teardown.

---

## 5. Tasks

### Task P4-01: Phase 4 commands and the keymap model

**Files:**
- Modify: `Sources/Core/Commands/Command.swift` (append the §3.1 cases)
- Modify: `Sources/Core/Commands/CommandAvailability.swift` (CommandState fields, `shippedPhase4Commands`, Phase 4 rows)
- Modify: `Sources/Core/Commands/KeyChord.swift` (`serialized`, `Codable`, parser aliases `fwddelete`, `backspace`, `plus`)
- Modify: `Sources/Core/Commands/KeyMap.swift` (facade over `KeymapPreset.explorer`)
- Create: `Sources/Core/Commands/Keymap/KeyBinding.swift`, `KeymapPreset.swift`, `KeymapProfile.swift`, `ResolvedKeymap.swift`, `SpecialChords.swift`, `KeymapValidator.swift`, `KeymapDocument.swift`
- Create: `Tests/CoreTests/Keymap/KeymapPresetTests.swift`, `Tests/CoreTests/Keymap/KeymapDocumentTests.swift`, `Tests/CoreTests/Keymap/Fixtures/phase1-keymap.json` (golden, generated in Step 1)

**Interfaces:**
- Consumes: `Command`, `KeyChord`, `Key`, `KeyModifiers`, `KeyMap`, `ReturnKeyBehavior`, `FocusContext`, `CommandState`, `CommandAvailability` (overview §3.10).
- Produces: everything in §3.1 except `KeymapStore` and `KeyDispatcher(keymap:)` (P4-02).

- [ ] **Step 1: Capture the pre-refactor KeyMap as a golden file**

Write a throwaway test, `testDumpPhase1KeyMap`, that serializes the current static tables and writes them under the test's own sandbox. Copy the output into the fixture, then delete the test. At this point the KeyMap still includes whatever Phase 2/3 added.

```swift
func testDumpPhase1KeyMap() throws {
    let sandbox = try Sandbox(); defer { sandbox.destroy() }
    var out: [String: [String: [String]]] = [:]
    for c in Command.allCases {
        out[c.rawValue] = ["primary": KeyMap.primary(c).map { [$0.description] } ?? [],
                           "alternates": KeyMap.alternates(c).map(\.description)]
    }
    let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted])
    let url = try sandbox.createFile("phase1-keymap.json", contents: data)
    print("GOLDEN:", url.path)
}
```

Run: `swift test --filter CoreTests.KeymapPresetTests/testDumpPhase1KeyMap 2>&1 | grep GOLDEN`. Then `cp "<printed path>" Tests/CoreTests/Keymap/Fixtures/phase1-keymap.json`. Delete the test function. Add `resources: [.copy("Keymap/Fixtures")]` to the `CoreTests` target if it has no resources yet; otherwise append the entry.

- [ ] **Step 2: Write the failing preset and resolution tests**

```swift
import XCTest
@testable import Core

final class KeymapPresetTests: XCTestCase {
    private func chord(_ s: String) -> KeyChord { KeyChord(parsing: s)! }

    func testExplorerPresetEqualsPhase1KeyMap() throws {
        let url = Bundle.module.url(forResource: "phase1-keymap", withExtension: "json", subdirectory: "Fixtures")!
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: [String: [String]]]
        for (name, entry) in golden {
            let c = try XCTUnwrap(Command(rawValue: name))
            let b = KeymapPreset.explorer.binding(for: c)
            XCTAssertEqual(b.primary.map { [$0.description] } ?? [], entry["primary"], name)
            // Phase 1 F5 (refresh) becomes singlePane-scoped; description ignores scope
            XCTAssertEqual(b.alternates.map(\.chord.description), entry["alternates"], name)
        }
    }
    func testFacadeMatchesPresetAndCollisionSetUnchanged() {
        XCTAssertEqual(KeyMap.collidesWithTextEditing,
                       [.open, .up, .moveToTrash, .deletePermanently, .back, .forward, .rename, .duplicate])
        XCTAssertEqual(ResolvedKeymap.phase1Default.collidesWithTextEditing, KeyMap.collidesWithTextEditing)
        for c in Command.allCases { XCTAssertEqual(KeyMap.primary(c), KeymapPreset.explorer.binding(for: c).primary) }
    }
    func testPhase4Bindings() {
        XCTAssertEqual(KeymapPreset.explorer.binding(for: .toggleDualPane).primary, chord("cmd+shift+e"))
        XCTAssertEqual(KeymapPreset.explorer.binding(for: .showCommandPalette).primary, chord("cmd+shift+p"))
        XCTAssertEqual(KeymapPreset.explorer.binding(for: .connectToServer).primary, chord("cmd+k"))
        XCTAssertEqual(KeymapPreset.explorer.binding(for: .copyToOtherPane).alternates, [ScopedChord(chord("F5"), .dualPane)])
        XCTAssertEqual(KeymapPreset.explorer.binding(for: .moveToOtherPane).alternates, [ScopedChord(chord("F6"), .dualPane)])
        XCTAssertEqual(KeymapPreset.explorer.binding(for: .refresh).alternates, [ScopedChord(chord("F5"), .singlePane)])
    }
    func testF5DependsOnDualPaneAndF3StaysSearch() {
        let single = ResolvedKeymap(profile: .explorerDefault, returnKey: .open, dualPane: false)
        let dual = ResolvedKeymap(profile: .explorerDefault, returnKey: .open, dualPane: true)
        XCTAssertEqual(single.command(forAlternate: chord("F5")), .refresh)
        XCTAssertEqual(dual.command(forAlternate: chord("F5")), .copyToOtherPane)
        XCTAssertEqual(dual.command(forAlternate: chord("F6")), .moveToOtherPane)
        XCTAssertNil(single.command(forAlternate: chord("F6")))
        XCTAssertEqual(dual.command(forAlternate: chord("F3")), .focusSearch)
        XCTAssertEqual(dual.primary(.refresh), chord("cmd+r"))
    }
    func testReturnFollowsReturnKeySetting() {
        XCTAssertEqual(ResolvedKeymap(profile: .explorerDefault, returnKey: .open, dualPane: false)
                        .command(forAlternate: KeyChord(.returnKey)), .open)
        XCTAssertEqual(ResolvedKeymap(profile: .explorerDefault, returnKey: .rename, dualPane: false)
                        .command(forAlternate: KeyChord(.returnKey)), .rename)
    }
    func testFinderPreset() {
        let f = KeymapPreset.finder
        XCTAssertEqual(f.binding(for: .open).primary, chord("cmd+o"))
        XCTAssertEqual(f.binding(for: .focusAddressBar).primary, chord("cmd+shift+g"))
        XCTAssertEqual(f.binding(for: .copyAsPath).primary, chord("cmd+opt+c"))
        XCTAssertNil(f.binding(for: .rename).primary)
        XCTAssertTrue(f.binding(for: .moveToTrash).alternates.isEmpty)   // no Del alternate in Finder
        XCTAssertTrue(KeymapValidator.issues(KeymapProfile(base: .finder)).isEmpty)
    }
    func testBothPresetsAreConflictFree() {
        XCTAssertEqual(KeymapValidator.issues(.explorerDefault), [])
        XCTAssertEqual(KeymapValidator.issues(KeymapProfile(base: .finder)), [])
    }
    func testSerializedRoundTripsForEveryPresetChord() {
        for p in KeymapPreset.allCases { for c in Command.allCases {
            let b = p.binding(for: c)
            for k in ([b.primary].compactMap { $0 } + b.alternates.map(\.chord)) {
                XCTAssertEqual(KeyChord(parsing: k.serialized), k, "\(p) \(c) \(k.serialized)")
            }
        } }
        XCTAssertEqual(chord("shift+fwddelete").serialized, "shift+fwddelete")
        XCTAssertEqual(chord("cmd+shift+.").serialized, "cmd+shift+.")
    }
    func testPhase4CommandsDisabledUntilShipped() {
        let phase4: [Command] = [.toggleDualPane, .copyToOtherPane, .moveToOtherPane, .showCommandPalette, .connectToServer,
                                 .compressZip, .compressAppleArchive, .extractHere, .batchRename, .editTags, .checkForUpdates]
        let state = CommandState(selectionCount: 3, dualPaneActive: true, selectionIsArchive: true, updaterAvailable: true)
        for c in phase4 where !CommandAvailability.shippedPhase4Commands.contains(c) {
            XCTAssertFalse(CommandAvailability.isEnabled(c, focus: .content, state: state), "\(c)")
        }
    }
    func testAssigningPrimaryStealsWhenAsked() {
        let p = KeymapProfile.explorerDefault.assigningPrimary(chord("cmd+l"), to: .newFolder, stealing: true)
        XCTAssertEqual(p.binding(for: .newFolder).primary, chord("cmd+l"))
        XCTAssertNil(p.binding(for: .focusAddressBar).primary)
        XCTAssertEqual(KeymapValidator.issues(p), [])
        let q = KeymapProfile.explorerDefault.assigningPrimary(chord("cmd+l"), to: .newFolder, stealing: false)
        XCTAssertEqual(KeymapValidator.issues(q), [.conflict(chord: chord("cmd+l"), commands: [.focusAddressBar, .newFolder])])
        XCTAssertEqual(KeymapProfile.explorerDefault.users(of: chord("F5"), scope: .dualPane, excluding: nil), [.copyToOtherPane])
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter CoreTests.KeymapPresetTests 2>&1 | tail -5`
Expected: build failure, with errors such as `cannot find 'KeymapPreset' in scope` and `type 'Command' has no member 'toggleDualPane'`.

- [ ] **Step 4: Implement**

`Command.swift`: append the cases from §3.1. `selectorName` already derives `"macx_<rawValue>:"`; confirm that none of the new cases is in its standard-selector list.

`KeyChord.swift`. Serialization order is `cmd`, `opt`, `ctrl`, `shift`, then the key. Key tokens are: the character itself, with `+` written as `plus`; `up`/`down`/`left`/`right`; `return`, `enter`, `tab`, `esc`, `space`, `backspace`, `fwddelete`; and `F<n>`. Extend `init?(parsing:)` so it also accepts `fwddelete`, `backspace` and `plus`, keeping every Phase 1 spelling (`fn+delete` stays an alias of `fwddelete`).

```swift
extension KeyChord: Codable {
    public var serialized: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.shift) { parts.append("shift") }
        switch key {
        case .character(let s): parts.append(s == "+" ? "plus" : s)
        case .up: parts.append("up"); case .down: parts.append("down")
        case .left: parts.append("left"); case .right: parts.append("right")
        case .returnKey: parts.append("return"); case .enter: parts.append("enter")
        case .tab: parts.append("tab"); case .escape: parts.append("esc"); case .space: parts.append("space")
        case .backspace: parts.append("backspace"); case .forwardDelete: parts.append("fwddelete")
        case .function(let n): parts.append("F\(n)")
        }
        return parts.joined(separator: "+")
    }
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let c = KeyChord(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad chord \(text)"))
        }
        self = c
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(serialized) }
}
```

`KeyBinding.swift`:

```swift
public enum BindingScope: String, Sendable, Codable, Hashable { case always, singlePane, dualPane
    func overlaps(_ other: BindingScope) -> Bool { self == .always || other == .always || self == other }
}
public struct ScopedChord: Sendable, Codable, Hashable {
    public var chord: KeyChord
    public var scope: BindingScope
    public init(_ chord: KeyChord, _ scope: BindingScope = .always) { self.chord = chord; self.scope = scope }
    public init?(parsing text: String) {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        guard let c = KeyChord(parsing: parts[0]) else { return nil }
        if parts.count == 2 { guard let s = BindingScope(rawValue: parts[1]) else { return nil }; self.init(c, s) }
        else { self.init(c) }
    }
    public var serialized: String { scope == .always ? chord.serialized : "\(chord.serialized)@\(scope.rawValue)" }
    public init(from decoder: Decoder) throws {
        let t = try decoder.singleValueContainer().decode(String.self)
        guard let s = ScopedChord(parsing: t) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad chord \(t)"))
        }
        self = s
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(serialized) }
}
public struct KeyBinding: Sendable, Codable, Hashable {
    public var primary: KeyChord?
    public var alternates: [ScopedChord]
    public init(primary: KeyChord?, alternates: [ScopedChord] = []) { self.primary = primary; self.alternates = alternates }
    public static let none = KeyBinding(primary: nil)
    // Codable: {"primary": "cmd+l" | null, "alternates": ["opt+d", "F4"]}
}
```

`KeymapPreset.swift`: the Explorer table is spec §5.6 plus the Phase 2/3 bindings captured in the golden. Write every case explicitly. For Phase 2/3 commands, copy their entries from `phase1-keymap.json`. Return is never listed, because `ResolvedKeymap` derives it from `Settings.returnKey`.

```swift
extension KeymapPreset {
    public func binding(for command: Command) -> KeyBinding {
        switch self { case .explorer: Self.explorer(command); case .finder: Self.finder(command) }
    }
    private static func k(_ s: String) -> KeyChord { KeyChord(parsing: s)! }
    private static func b(_ primary: String?, _ alternates: String...) -> KeyBinding {
        KeyBinding(primary: primary.map(k), alternates: alternates.map { ScopedChord(parsing: $0)! })
    }
    static func explorer(_ c: Command) -> KeyBinding {
        switch c {
        case .open: b("cmd+down")
        case .rename: b("F2", "cmd+shift+r")
        case .moveToTrash: b("cmd+backspace", "fwddelete")
        case .deletePermanently: b("cmd+opt+backspace", "shift+fwddelete")
        case .cut: b("cmd+x", "ctrl+x")
        case .copy: b("cmd+c", "ctrl+c")
        case .paste: b("cmd+v", "ctrl+v")
        case .moveItemHere: b("cmd+opt+v")
        case .undo: b("cmd+z", "ctrl+z")
        case .redo: b("cmd+shift+z", "cmd+y")
        case .back: b("cmd+[", "backspace", "opt+left")
        case .forward: b("cmd+]", "opt+right")
        case .up: b("cmd+up", "opt+up")
        case .focusAddressBar: b("cmd+l", "opt+d", "F4")
        case .focusSearch: b("cmd+f", "F3")
        case .newFolder: b("cmd+shift+n")
        case .newWindow: b("cmd+n")
        case .closeWindow: b("cmd+w")
        case .properties: b("cmd+i", "opt+return")
        case .refresh: b("cmd+r", "F5@singlePane")
        case .copyAsPath: b("cmd+shift+c")
        case .toggleHidden: b("cmd+shift+.")
        case .selectAll: b("cmd+a", "ctrl+a")
        case .duplicate: b("cmd+d")
        case .eject: b("cmd+e")
        case .cycleFocusForward: b(nil, "tab")
        case .cycleFocusBackward: b(nil, "shift+tab")
        case .cancelOperation: b(nil, "esc")
        case .toggleDualPane: b("cmd+shift+e")
        case .copyToOtherPane: b(nil, "F5@dualPane")
        case .moveToOtherPane: b(nil, "F6@dualPane")
        case .showCommandPalette: b("cmd+shift+p")
        case .connectToServer: b("cmd+k")
        case .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder, .selectNone, .invertSelection,
             .makeAlias, .makeSymlink, .newTextFile, .newEmptyFile, .share, .showOperations,
             .viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .densityCompact, .densityRegular, .densityComfortable, .toggleCommandBar,
             .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending,
             .removeFromFavorites, .compressZip, .compressAppleArchive, .extractHere, .batchRename, .editTags, .checkForUpdates:
            .none
        // + one explicit case per Phase 2/3 command, with the binding from phase1-keymap.json
        }
    }
    static func finder(_ c: Command) -> KeyBinding {
        switch c {
        case .open: b("cmd+o", "cmd+down")
        case .rename: .none                          // Finder users: P4-02's preset switch also sets Return = Rename
        case .moveToTrash: b("cmd+backspace")
        case .deletePermanently: b("cmd+opt+backspace")
        case .cut: b("cmd+x"); case .copy: b("cmd+c"); case .paste: b("cmd+v")
        case .undo: b("cmd+z"); case .redo: b("cmd+shift+z"); case .selectAll: b("cmd+a")
        case .back: b("cmd+["); case .forward: b("cmd+]"); case .up: b("cmd+up")
        case .focusAddressBar: b("cmd+shift+g")
        case .focusSearch: b("cmd+f")
        case .copyAsPath: b("cmd+opt+c")
        case .makeAlias: b("cmd+ctrl+a")
        case .viewAsIcons: b("cmd+1"); case .viewAsDetails: b("cmd+2")
        case .properties: b("cmd+i")
        case .refresh: .none
        case .moveItemHere, .newFolder, .newWindow, .closeWindow, .toggleHidden, .duplicate, .eject,
             .cycleFocusForward, .cycleFocusBackward, .cancelOperation, .toggleDualPane, .copyToOtherPane,
             .moveToOtherPane, .showCommandPalette, .connectToServer,
             .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder, .selectNone, .invertSelection,
             .makeSymlink, .newTextFile, .newEmptyFile, .share, .showOperations,
             .iconSizeSmall, .iconSizeMedium, .iconSizeLarge, .densityCompact, .densityRegular, .densityComfortable,
             .toggleCommandBar, .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated,
             .sortAscending, .sortDescending, .removeFromFavorites, .compressZip, .compressAppleArchive, .extractHere,
             .batchRename, .editTags, .checkForUpdates:
            explorer(c)
        // + Phase 2/3 commands listed explicitly in this explorer(c) group
        }
    }
}
```

If the golden shows Phase 1 bound `viewAsDetails`/`viewAsIcons` (for example to `cmd+1`/`cmd+2`), the Explorer cases above take the golden values. The golden test is the arbiter.

`SpecialChords.swift`:

```swift
public enum SpecialChords {
    private static func k(_ s: String) -> KeyChord { KeyChord(parsing: s)! }
    public static let textEditing: Set<KeyChord> = {
        var s: Set<KeyChord> = []
        for arrow in ["up", "down", "left", "right"] {
            for m in ["", "shift+", "opt+", "opt+shift+", "cmd+", "cmd+shift+"] { s.insert(k(m + arrow)) }
        }
        for m in ["", "opt+", "cmd+", "cmd+opt+"] { s.insert(k(m + "backspace")) }
        for m in ["", "opt+"] { s.insert(k(m + "fwddelete")) }
        ["return", "enter", "tab", "shift+tab", "esc", "cmd+[", "cmd+]", "F2", "cmd+d",
         "ctrl+a", "ctrl+e", "ctrl+k", "ctrl+h", "ctrl+d", "ctrl+f", "ctrl+b", "ctrl+n", "ctrl+p", "ctrl+t", "ctrl+y"]
            .forEach { s.insert(k($0)) }
        return s
    }()
    public static let reserved: Set<KeyChord> = Set([
        "cmd+q", "cmd+h", "cmd+opt+h", "cmd+m", "cmd+tab", "cmd+shift+tab", "cmd+space", "ctrl+space", "cmd+`",
        "ctrl+up", "ctrl+down", "ctrl+left", "ctrl+right", "cmd+shift+3", "cmd+shift+4", "cmd+shift+5",
        "cmd+ctrl+q", "cmd+ctrl+f", "cmd+,", "cmd+opt+esc",
        "return",            // owned by Settings › Return key
    ].map(k))
}
```

The Phase 1 collision set includes `ctrl+a`, which is the `selectAll` alternate. Alternates never fire in text fields (P1-13), so they are exempt: `collidesWithTextEditing` looks only at primaries.

`KeymapProfile.swift`:

```swift
public struct KeymapProfile: Sendable, Codable, Equatable {
    public var base: KeymapPreset
    public var overrides: [String: KeyBinding]
    public init(base: KeymapPreset = .explorer, overrides: [String: KeyBinding] = [:]) { self.base = base; self.overrides = overrides }
    public static let explorerDefault = KeymapProfile()
    public func binding(for command: Command) -> KeyBinding { overrides[command.rawValue] ?? base.binding(for: command) }
    private func with(_ command: Command, _ binding: KeyBinding) -> KeymapProfile {
        var p = self
        p.overrides[command.rawValue] = binding == base.binding(for: command) ? nil : binding
        return p
    }
    public func users(of chord: KeyChord, scope: BindingScope, excluding command: Command?) -> [Command] {
        Command.allCases.filter { c in
            guard c != command else { return false }
            let b = binding(for: c)
            return b.primary == chord || b.alternates.contains { $0.chord == chord && $0.scope.overlaps(scope) }
        }.sorted { $0.rawValue < $1.rawValue }
    }
    public func assigningPrimary(_ chord: KeyChord?, to command: Command, stealing: Bool) -> KeymapProfile {
        var p = self
        if let chord, stealing {
            for other in users(of: chord, scope: .always, excluding: command) {
                var b = p.binding(for: other)
                if b.primary == chord { b.primary = nil }
                b.alternates.removeAll { $0.chord == chord }
                p = p.with(other, b)
            }
        }
        var b = p.binding(for: command); b.primary = chord
        return p.with(command, b)
    }
    public func settingAlternates(_ alternates: [ScopedChord], for command: Command) -> KeymapProfile {
        var b = binding(for: command); b.alternates = alternates
        return with(command, b)
    }
}
```

`KeymapValidator.swift`: walk every pair of commands. A conflict exists when (a) their primaries are equal, (b) one's primary equals an alternate of the other in any scope, or (c) two of their alternates are equal with overlapping scopes. Group the conflicting commands per chord (sorted by `rawValue`, deduplicated). A chord in `SpecialChords.reserved` used anywhere is `.reserved(chord:, command:)`. Output order: conflicts sorted by `chord.serialized`, then reserved sorted by `(command.rawValue)`.

`ResolvedKeymap.swift`:

```swift
public struct ResolvedKeymap: Sendable, Equatable {
    private var primaries: [Command: KeyChord] = [:]
    private var alternateTable: [KeyChord: Command] = [:]
    private var alternatesByCommand: [Command: [KeyChord]] = [:]
    public private(set) var collidesWithTextEditing: Set<Command> = []
    public init(profile: KeymapProfile, returnKey: ReturnKeyBehavior, dualPane: Bool) {
        let active: BindingScope = dualPane ? .dualPane : .singlePane
        for c in Command.allCases {
            let b = profile.binding(for: c)
            if let p = b.primary {
                primaries[c] = p
                if SpecialChords.textEditing.contains(p) { collidesWithTextEditing.insert(c) }
            }
            for s in b.alternates where s.scope == .always || s.scope == active {
                guard alternateTable[s.chord] == nil else { continue }    // validator prevents this; first wins
                alternateTable[s.chord] = c
                alternatesByCommand[c, default: []].append(s.chord)
            }
        }
        let ret = KeyChord(.returnKey)
        let retCommand: Command = returnKey == .rename ? .rename : .open
        alternateTable[ret] = retCommand
        alternatesByCommand[retCommand, default: []].append(ret)
    }
    public func primary(_ c: Command) -> KeyChord? { primaries[c] }
    public func alternates(_ c: Command) -> [KeyChord] { alternatesByCommand[c] ?? [] }
    public func command(forAlternate chord: KeyChord) -> Command? { alternateTable[chord] }
    public static let phase1Default = ResolvedKeymap(profile: .explorerDefault, returnKey: .open, dualPane: false)
}
```

`KeyMap.swift` becomes a facade. `primary(c)` returns `KeymapPreset.explorer.binding(for: c).primary`. `alternates(c)` returns the chords whose scope is `.always` or `.singlePane`, which equals Phase 1 behaviour. `collidesWithTextEditing` returns `ResolvedKeymap.phase1Default.collidesWithTextEditing`. Delete the old tables, since they now live in `explorer(_:)`.

`CommandAvailability.swift`: add the three `CommandState` fields, appended to the memberwise init with defaults so every Phase 1 call site still compiles. Add `public static let shippedPhase4Commands: Set<Command> = []` and the Phase 4 rows, which apply only when the command is shipped:

| Command | Enabled when (and shipped) |
|---|---|
| toggleDualPane, showCommandPalette, connectToServer | always |
| copyToOtherPane, moveToOtherPane | `dualPaneActive && selectionCount > 0 && focus == .content` |
| compressZip, compressAppleArchive | `selectionCount > 0 && !folderIsReadOnly && focus ∈ {.content, .sidebarFolders}` |
| extractHere | `selectionIsArchive && !folderIsReadOnly && focus == .content` |
| batchRename | `selectionCount > 1 && focus == .content` |
| editTags | `selectionCount > 0 && focus ∈ {.content, .sidebarFolders}` |
| checkForUpdates | `updaterAvailable` |

- [ ] **Step 5: Write the failing JSON document tests (Review Focus 3, model half)**

```swift
final class KeymapDocumentTests: XCTestCase {
    private func doc(_ bindings: String, base: String = "explorer", version: Int = 1) -> Data {
        Data(#"{"format":"macexplorer-keymap","version":\#(version),"base":"\#(base)","bindings":\#(bindings)}"#.utf8)
    }
    private func k(_ s: String) -> KeyChord { KeyChord(parsing: s)! }

    func testExportImportRoundTrip() throws {
        let p = KeymapProfile.explorerDefault.assigningPrimary(k("cmd+opt+c"), to: .copyAsPath, stealing: false)
            .settingAlternates([ScopedChord(k("ctrl+r"))], for: .refresh)
        let (q, warnings) = try KeymapDocument.import(KeymapDocument.export(p))
        XCTAssertEqual(q, p); XCTAssertEqual(warnings, [])
    }
    func testExportContainsOnlyOverridesSorted() throws {
        let p = KeymapProfile.explorerDefault.assigningPrimary(nil, to: .duplicate, stealing: false)
        let json = String(decoding: KeymapDocument.export(p), as: UTF8.self)
        XCTAssertTrue(json.contains(#""duplicate""#)); XCTAssertTrue(json.contains(#""primary" : null"#))
        XCTAssertFalse(json.contains(#""rename""#))
    }
    func testImportRejectsConflictsAndReservedSkipsUnknown() throws {
        XCTAssertThrowsError(try KeymapDocument.import(doc(#"{"newFolder":{"primary":"cmd+l","alternates":[]}}"#))) {
            XCTAssertEqual($0 as? KeymapImportError,
                           .issues([.conflict(chord: self.k("cmd+l"), commands: [.focusAddressBar, .newFolder])]))
        }
        XCTAssertThrowsError(try KeymapDocument.import(doc(#"{"refresh":{"primary":"cmd+q","alternates":[]}}"#))) {
            XCTAssertEqual($0 as? KeymapImportError, .issues([.reserved(chord: self.k("cmd+q"), command: .refresh)]))
        }
        XCTAssertThrowsError(try KeymapDocument.import(doc(#"{"refresh":{"primary":"cmd+r","alternates":["ctrl+up"]}}"#)))
        let (p, w) = try KeymapDocument.import(doc(#"{"teleport":{"primary":"cmd+opt+t","alternates":[]}}"#))
        XCTAssertEqual(p, .explorerDefault); XCTAssertEqual(w, [.unknownCommand("teleport")])
    }
    func testTextEditingPrimaryIsAcceptedAndMarkedColliding() throws {
        let (p, _) = try KeymapDocument.import(doc(#"{"newFolder":{"primary":"cmd+shift+left","alternates":[]}}"#))
        XCTAssertTrue(ResolvedKeymap(profile: p, returnKey: .open, dualPane: false).collidesWithTextEditing.contains(.newFolder))
    }
    func testImportErrors() {
        XCTAssertThrowsError(try KeymapDocument.import(Data("[]".utf8))) { XCTAssertEqual($0 as? KeymapImportError, .notAKeymap) }
        XCTAssertThrowsError(try KeymapDocument.import(doc("{}", version: 2))) { XCTAssertEqual($0 as? KeymapImportError, .unsupportedVersion(2)) }
        XCTAssertThrowsError(try KeymapDocument.import(doc("{}", base: "vim"))) { XCTAssertEqual($0 as? KeymapImportError, .unknownBase("vim")) }
        XCTAssertThrowsError(try KeymapDocument.import(doc(#"{"refresh":{"primary":"hyper+r","alternates":[]}}"#))) {
            XCTAssertEqual($0 as? KeymapImportError, .invalidChord(command: "refresh", text: "hyper+r"))
        }
    }
}
```

- [ ] **Step 6: Run to verify they fail, implement `KeymapDocument`, run to verify they pass**

Run: `swift test --filter CoreTests.KeymapDocumentTests 2>&1 | tail -5`. Expected first: FAIL (`cannot find 'KeymapDocument'`).

Implementation:
- `export` encodes `{"format","version","base","bindings": overrides}` with a `JSONEncoder` using `[.sortedKeys, .prettyPrinted]`. A `KeyBinding` with `primary == nil` encodes `"primary": null` explicitly; implement `encode(to:)` with `encodeNil` for this.
- `import` decodes with `JSONSerialization` first, so that unknown commands can produce warnings instead of decoding errors. Check `format`, then `version`, then `base`. Then, for each binding key in sorted order: an unknown command adds a warning; otherwise parse `primary` (`NSNull` → nil) and the `alternates` strings, throwing `.invalidChord`. Finally run `KeymapValidator.issues` and throw `.issues` if any are found.

Run: `swift test --filter CoreTests.Keymap 2>&1 | tail -5` and `swift test --filter CoreTests.KeyMapTests 2>&1 | tail -5` (the Phase 1 tests are unchanged).
Expected: `Executed N tests, with 0 failures` for both.

- [ ] **Step 7: Build, then commit**

Run: `swift build 2>&1 | tail -5` → `Build complete!`, no warnings.

```bash
git add Sources/Core/Commands Tests/CoreTests/Keymap Package.swift
git commit -m "feat: phase 4 commands and data-driven keymap model with presets and JSON format"
```

### Task P4-02: Keymap integration and Settings › Keyboard

**Files:**
- Create: `Sources/Core/Commands/Keymap/KeymapStore.swift`, `Sources/UI/Menus/MenuKeyEquivalent.swift`, `Sources/UI/Settings/KeyboardSettingsView.swift`, `Sources/UI/Settings/KeyRecorderView.swift`
- Modify: `Sources/Core/Commands/KeyDispatcher.swift`, `Sources/Core/Settings/Settings.swift` (`keymap`), `Sources/Core/Support/LaunchOptions.swift` (`--keymap`), `Sources/Core/Support/CoreEnvironment.swift` (`keymapStore`), `Sources/UI/Menus/MainMenuBuilder.swift`, `Sources/UI/Menus/KeyRouter.swift`, `Sources/UI/Menus/MenuValidation.swift`, `Sources/UI/Settings/SettingsView.swift` (Keyboard tab), `Sources/App/AppDelegate.swift` (rebuild key equivalents on change), every `KeyRouter.handle(…returnKey:…)` call site (content and sidebar controllers), `Sources/UI/Scenario/ScenarioFile.swift` (`launchArguments`), `scripts/ui-scenarios.sh`
- Test: `Tests/CoreTests/Keymap/KeymapStoreTests.swift`, `Tests/UITests/KeyboardSettingsTests.swift`; update Phase 1 call sites in `Tests/CoreTests/KeyMapTests.swift` and `Tests/UITests/KeyRouterTests.swift` (`KeyDispatcher(returnKey: x)` → `KeyDispatcher(keymap: ResolvedKeymap(profile: .explorerDefault, returnKey: x, dualPane: false))`)

**Interfaces:**
- Consumes: §3.1 from P4-01; `Settings`, `MainMenuBuilder`, `KeyRouter`, `MenuValidation`, `KeyEventTranslator`, `LaunchOptions`.
- Produces:
  - `KeymapStore` (§3.1) and `KeyDispatcher(keymap:)`.
  - `MenuKeyEquivalent.equivalent(for: KeyChord) -> (key: String, modifiers: NSEvent.ModifierFlags)?`, `MainMenuBuilder.build(keymap: ResolvedKeymap) -> NSMenu` (the old `build()` calls this with `.phase1Default`) and `MainMenuBuilder.applyKeyEquivalents(_ menu: NSMenu, keymap: ResolvedKeymap)`. Every command menu item has `identifier == "macx.menu.<rawValue>"`.
  - `KeyRouter.handle(_ event: NSEvent, focus: FocusContext, keymap: ResolvedKeymap, from view: NSView) -> Bool`.
  - `MenuValidation.isEnabled(_:window:state:focus:keymap:)`.
  - `Settings.keymap: KeymapProfile` (default `.explorerDefault`), `LaunchOptions.keymapFile`.
  - `ScenarioFile.launchArguments: [String]?` (paths relative to the scenario file's directory are resolved by `ui-scenarios.sh`).

- [ ] **Step 1: Write the failing Core tests**

```swift
@MainActor final class KeymapStoreTests: XCTestCase {
    func testResolvedFollowsProfileAndReturnKey() throws {
        let settings = Settings(storage: InMemorySettingsStorage())
        let store = KeymapStore(settings: settings)
        XCTAssertEqual(store.resolved(dualPane: false).command(forAlternate: KeyChord(.returnKey)), .open)
        settings.returnKey = .rename
        XCTAssertEqual(store.resolved(dualPane: false).command(forAlternate: KeyChord(.returnKey)), .rename)
        try store.apply(store.profile.settingAlternates([ScopedChord(KeyChord(parsing: "ctrl+r")!)], for: .refresh))
        XCTAssertEqual(settings.keymap.overrides["refresh"]?.alternates.first?.serialized, "ctrl+r")
        XCTAssertEqual(KeyDispatcher(keymap: store.resolved(dualPane: false)).command(for: KeyChord(parsing: "ctrl+r")!, in: .content), .refresh)
        XCTAssertNil(KeyDispatcher(keymap: store.resolved(dualPane: false)).command(for: KeyChord(parsing: "ctrl+r")!, in: .fieldEditor))
    }
    func testApplyRejectsIssuesAndKeepsPreviousProfile() {
        let store = KeymapStore(settings: Settings(storage: InMemorySettingsStorage()))
        let bad = store.profile.assigningPrimary(KeyChord(parsing: "cmd+l")!, to: .newFolder, stealing: false)
        XCTAssertThrowsError(try store.apply(bad))
        XCTAssertEqual(store.profile, .explorerDefault)
    }
    func testResetToFinderPreset() {
        let settings = Settings(storage: InMemorySettingsStorage())
        let store = KeymapStore(settings: settings)
        store.reset(to: .finder)
        XCTAssertEqual(store.profile, KeymapProfile(base: .finder))
        XCTAssertEqual(settings.returnKey, .rename)    // Finder preset implies Return = Rename
    }
    func testObserversFireOnChange() throws {
        let store = KeymapStore(settings: Settings(storage: InMemorySettingsStorage()))
        var fired = 0
        let token = store.observe { fired += 1 }
        store.reset(to: .finder)
        XCTAssertEqual(fired, 1); token.cancel()
    }
    func testLaunchOptionKeymapParses() throws {
        let o = try LaunchOptions.parse(["macExplorer", "--root", "/tmp/macx-scenario-x", "--state-dir", "/tmp/macx-scenario-x/state", "--keymap", "/tmp/macx-scenario-x/k.json"])
        XCTAssertEqual(o.keymapFile?.lastPathComponent, "k.json")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.KeymapStoreTests 2>&1 | tail -5`
Expected: FAIL (`cannot find 'KeymapStore'`).

- [ ] **Step 3: Implement the Core pieces**

`KeymapStore`:
- Hold `settings`, `profile` (initialized from `settings.keymap`) and a cache `[Bool: ResolvedKeymap]`.
- In `init`, call `track()`. It uses `withObservationTracking({ _ = settings.returnKey; _ = settings.keymap }, onChange: { Task { @MainActor [weak self] in self?.reload(); self?.track() } })`.
- `reload()` clears the cache, refreshes `profile` and sends to the `Observers<Void>`.
- `apply(_:)`: if `KeymapValidator.issues(p)` is non-empty, `throw .issues(...)`. Otherwise set `settings.keymap = p` and reload synchronously, so callers and tests see the change at once.
- `reset(to:)` sets `KeymapProfile(base: preset)`. For `.finder` it also sets `settings.returnKey = .rename`.

`KeyDispatcher(keymap:)` keeps P1-13's focus rules: it returns nil for `.fieldEditor`/`.addressBar` and applies the sidebar remaps through `CommandAvailability.effectiveCommand`. Only the chord→command lookup changes, to `keymap.command(forAlternate:)`.

`Settings.keymap` is persisted as JSON under the key `"keymap"`, following P1-12's per-key pattern; an absent key gives `.explorerDefault`.

`LaunchOptions.keymapFile`: `--keymap <path>` is accepted only together with `--state-dir`; otherwise it fails with `stateDirectoryRequired`.

`CoreEnvironment` gains `keymapStore`. `sandboxed(root:)` builds it from its in-memory settings. In `AppBootstrap`, when `options.keymapFile` is set, read that file (it lives in the sandbox), `KeymapDocument.import` it, and call `keymapStore.apply`. On error, print the error to stderr and `exit(65)`.

Run: `swift test --filter CoreTests.KeymapStoreTests 2>&1 | tail -5` → `Executed 5 tests, with 0 failures`.

- [ ] **Step 4: Write the failing UI tests (Review Focus 3, UI half)**

```swift
@MainActor final class KeyboardSettingsTests: XCTestCase {
    func testMenuKeyEquivalentMapping() {
        XCTAssertEqual(MenuKeyEquivalent.equivalent(for: KeyChord(parsing: "cmd+opt+c")!)?.key, "c")
        XCTAssertEqual(MenuKeyEquivalent.equivalent(for: KeyChord(parsing: "cmd+opt+c")!)?.modifiers, [.command, .option])
        XCTAssertEqual(MenuKeyEquivalent.equivalent(for: KeyChord(parsing: "F2")!)?.key, String(Character(UnicodeScalar(UInt32(NSF2FunctionKey))!)))
        XCTAssertEqual(MenuKeyEquivalent.equivalent(for: KeyChord(parsing: "cmd+backspace")!)?.key, "\u{8}")
        XCTAssertEqual(MenuKeyEquivalent.equivalent(for: KeyChord(parsing: "cmd+down")!)?.key, String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)))
    }
    func testPhase1MenuKeyEquivalentsUnchanged() {
        // golden: every Phase 1 primary renders exactly as P1-29 rendered it
        let menu = MainMenuBuilder.build(keymap: .phase1Default)
        for c in Command.allCases {
            guard let item = Self.find(c, in: menu), let chord = KeyMap.primary(c) else { continue }
            let expected = MenuKeyEquivalent.equivalent(for: chord)!
            XCTAssertEqual(item.keyEquivalent, expected.key, "\(c)")
            XCTAssertEqual(item.keyEquivalentModifierMask, expected.modifiers, "\(c)")
        }
    }
    func testMenuFollowsCustomProfileLive() throws {
        let menu = MainMenuBuilder.build(keymap: .phase1Default)
        let p = KeymapProfile.explorerDefault.assigningPrimary(KeyChord(parsing: "cmd+opt+c")!, to: .copyAsPath, stealing: false)
        MainMenuBuilder.applyKeyEquivalents(menu, keymap: ResolvedKeymap(profile: p, returnKey: .open, dualPane: false))
        let item = try XCTUnwrap(Self.find(.copyAsPath, in: menu))
        XCTAssertEqual(item.keyEquivalent, "c"); XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        let cleared = KeymapProfile.explorerDefault.assigningPrimary(nil, to: .duplicate, stealing: false)
        MainMenuBuilder.applyKeyEquivalents(menu, keymap: ResolvedKeymap(profile: cleared, returnKey: .open, dualPane: false))
        XCTAssertEqual(Self.find(.duplicate, in: menu)?.keyEquivalent, "")
    }
    func testCustomPrimaryCollidingWithTextEditingIsDisabledInFieldEditor() throws {
        try XCTSkipUnless(NSApplication.shared.isRunning || NSScreen.main != nil, "needs a window server")
        let p = KeymapProfile.explorerDefault.assigningPrimary(KeyChord(parsing: "cmd+shift+left")!, to: .newFolder, stealing: false)
        let keymap = ResolvedKeymap(profile: p, returnKey: .open, dualPane: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        window.contentView!.addSubview(field); window.makeFirstResponder(field)
        XCTAssertFalse(MenuValidation.isEnabled(.newFolder, window: window, state: CommandState(), focus: .fieldEditor, keymap: keymap))
        window.makeFirstResponder(nil)
        XCTAssertTrue(MenuValidation.isEnabled(.newFolder, window: window, state: CommandState(), focus: .content, keymap: keymap))
    }
    func testSettingsModelConflictPromptAndSteal() throws {
        let settings = Settings(storage: InMemorySettingsStorage())
        let model = KeyboardSettingsModel(store: KeymapStore(settings: settings))
        let result = model.record(KeyChord(parsing: "cmd+l")!, asPrimaryFor: .newFolder)
        XCTAssertEqual(result, .needsConfirmation(usedBy: [.focusAddressBar]))
        try model.confirmSteal(KeyChord(parsing: "cmd+l")!, asPrimaryFor: .newFolder)
        XCTAssertEqual(settings.keymap.binding(for: .newFolder).primary, KeyChord(parsing: "cmd+l"))
        XCTAssertEqual(model.record(KeyChord(parsing: "cmd+q")!, asPrimaryFor: .refresh), .rejectedReserved)
    }
    func testImportExportThroughSandboxFiles() throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        let model = KeyboardSettingsModel(store: KeymapStore(settings: Settings(storage: InMemorySettingsStorage())))
        try model.confirmSteal(KeyChord(parsing: "cmd+opt+c")!, asPrimaryFor: .copyAsPath)
        let url = sandbox.url("k.json")
        try model.export(to: url)
        let other = KeyboardSettingsModel(store: KeymapStore(settings: Settings(storage: InMemorySettingsStorage())))
        XCTAssertEqual(try other.import(from: url), [])
        XCTAssertEqual(other.store.profile, model.store.profile)
    }
    static func find(_ c: Command, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == "macx.menu.\(c.rawValue)" { return item }
            if let sub = item.submenu, let f = find(c, in: sub) { return f }
        }
        return nil
    }
}
```

`model.export(to:)` / `import(from:)` take a URL. The real UI gets it from `NSSavePanel`/`NSOpenPanel`; tests pass sandbox URLs. File reading and writing goes through a lane (`LanePool.perform(on: .unknown, .fileOp)`), so these methods are `async`. In the test, wrap them in `await` and mark the test `async`. The synchronous form above is shorthand.

- [ ] **Step 5: Run to verify they fail**

Run: `swift test --filter UITests.KeyboardSettingsTests 2>&1 | tail -5`
Expected: FAIL (`cannot find 'MenuKeyEquivalent'`, `'KeyboardSettingsModel'`).

- [ ] **Step 6: Implement the UI pieces**

`MenuKeyEquivalent.swift`:

```swift
import AppKit
import Core

@MainActor enum MenuKeyEquivalent {
    private static func fn(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
    static func equivalent(for chord: KeyChord) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var m: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.command) { m.insert(.command) }
        if chord.modifiers.contains(.option) { m.insert(.option) }
        if chord.modifiers.contains(.control) { m.insert(.control) }
        if chord.modifiers.contains(.shift) { m.insert(.shift) }
        let key: String
        switch chord.key {
        case .character(let s): key = s
        case .up: key = fn(NSUpArrowFunctionKey)
        case .down: key = fn(NSDownArrowFunctionKey)
        case .left: key = fn(NSLeftArrowFunctionKey)
        case .right: key = fn(NSRightArrowFunctionKey)
        case .returnKey: key = "\r"
        case .enter: key = "\u{3}"
        case .tab: key = "\t"
        case .escape: key = "\u{1b}"
        case .space: key = " "
        case .backspace: key = "\u{8}"
        case .forwardDelete: key = fn(NSDeleteFunctionKey)
        case .function(let n):
            guard (1...20).contains(n) else { return nil }
            key = fn(NSF1FunctionKey + n - 1)
        }
        return (key, m)
    }
}
```

If P1-29 rendered shifted punctuation differently (for example `⌘⇧.` as key `">"` with `[.command]`), `testPhase1MenuKeyEquivalentsUnchanged` fails. In that case, copy P1-29's special case into `equivalent(for:)` so the golden passes.

`MainMenuBuilder`:
- `build(keymap:)` builds exactly the Phase 1 menu tree.
- Phase 4 commands are placed as follows:
  - View: Dual Pane (⌘⇧E).
  - File: Compress ▸ (.zip / .aar), Extract Here, Rename N Items…, Tags…, Connect to Server….
  - Go: Command Palette….
  - App menu: Check for Updates….
- Every item gets the `macx.menu.<raw>` identifier and is then passed through `applyKeyEquivalents`.
- `applyKeyEquivalents` walks the tree recursively and sets `keyEquivalent`/`keyEquivalentModifierMask` from `keymap.primary(cmd)`, or `""`/`[]` when the command has no primary.

`AppDelegate`: subscribe to `environment.keymapStore.observe { applyKeyEquivalents(NSApp.mainMenu!, keymap: store.resolved(dualPane: false)) }`. Primaries never depend on dual-pane.

`KeyRouter.handle(_:focus:keymap:from:)` replaces the `returnKey:` variant, using `KeyDispatcher(keymap:)`. Call sites pass `context.environment.keymapStore.resolved(dualPane: window.isDualPane)`; until P4-13, `isDualPane` is `false`.

`MenuValidation`: the collision check uses `keymap.collidesWithTextEditing`. The old 4-argument function calls the new one with `.phase1Default`.

`KeyboardSettingsModel` (in `KeyboardSettingsView.swift`, `@MainActor @Observable`):
- `rows: [Row]`, where a Row is (command, title, primary, alternates).
- `record(_:asPrimaryFor:) -> RecordResult`, where `enum RecordResult: Equatable { case applied, needsConfirmation(usedBy: [Command]), rejectedReserved }`. It uses `profile.users(of:scope:.always, excluding:)`.
- `confirmSteal`, `setAlternates`, `resetToPreset`, `export(to:)`, `import(from:) -> [KeymapWarning]`.

`KeyboardSettingsView` (SwiftUI):
- A `Table` with columns Command | Shortcut (`KeyRecorderView`) | Alternates (text such as "⌃C, F5 (single pane)" plus an Edit… sheet with a list of recorders and scope pickers).
- A preset `Picker` (Explorer / Finder) that confirms with "Replace your shortcuts with the Finder preset?".
- Restore Defaults, Import…, Export… buttons.
- A red issues list when `apply` throws.
- A footer: "Shortcuts set in System Settings › Keyboard › App Shortcuts override these."

`KeyRecorderView` (`NSViewRepresentable` over `KeyRecorderField: NSView`):
- `acceptsFirstResponder` is true.
- `performKeyEquivalent(with:)` captures the chord while the field is first responder and returns true, so menus don't fire.
- `keyDown` uses `KeyEventTranslator.chord(for:)` → `onChord`.
- Esc cancels recording and ⌫ with no modifiers clears the binding.
- The accessibility label is "Shortcut for <command>".

`ScenarioFile.launchArguments` is optional. `ui-scenarios.sh` reads it with `plutil -extract launchArguments json -o - "$f" 2>/dev/null`. It copies any argument ending in `.json` into the scenario's own sandbox and rewrites the argument to the copied path, so the app only ever reads files inside the sandbox.

- [ ] **Step 7: Run all keymap-related tests**

Run: `swift test --filter "UITests.KeyboardSettingsTests|UITests.KeyRouterTests|UITests.MenuValidationTests|CoreTests.KeyMapTests|CoreTests.Keymap" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 8: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests scripts/ui-scenarios.sh
git commit -m "feat: keymap store, live menu key equivalents, Settings Keyboard pane with presets and import/export"
```

### Task P4-03: Command palette (⌘⇧P)

**Files:**
- Create: `Sources/Core/Palette/FuzzyMatcher.swift`, `Sources/Core/Palette/PaletteCatalog.swift`, `Sources/UI/Palette/CommandPaletteController.swift`, `Sources/UI/Palette/CommandTitles.swift`
- Modify: `Sources/Core/Settings/Settings.swift` (`paletteRecent`, `notePaletteUsed`), `Sources/Core/Commands/CommandAvailability.swift` (add `.showCommandPalette` to `shippedPhase4Commands`), `Sources/UI/Menus/MainMenuBuilder.swift` (titles come from `CommandTitles`), `Sources/UI/Commands/FileCommandController.swift` and `Sources/App/AppDelegate.swift` (`macx_showCommandPalette:`)
- Test: `Tests/CoreTests/Palette/FuzzyMatcherTests.swift`, `Tests/CoreTests/Palette/PaletteCatalogTests.swift`, `Tests/UITests/CommandPaletteTests.swift`

**Interfaces:**
- Consumes: `Command`, `CommandAvailability`, `CommandState`, `FocusContext`, `ResolvedKeymap` (P4-01/02), `Settings.favorites`/`recentLocations`, `FavoritesResolver` results already held by the sidebar, `MenuKeyEquivalent`.
- Produces: §3.2. Also `CommandTitles.title(_ c: Command) -> String` (L10n; the main menu and the palette share it), `CommandPaletteController.show(over window: NSWindow, context: UIContext)`, `Settings.paletteRecent: [String]` (`PaletteTarget` encoded as `"cmd:<raw>"` / `"loc:<path>"`, ≤ 20, most recent first) and `Settings.notePaletteUsed(_ t: PaletteTarget)`.

- [ ] **Step 1: Write the failing matcher and ranking tests**

```swift
final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceAndIndices() {
        XCTAssertEqual(FuzzyMatcher.match("nf", in: "New Folder")?.matchedIndices, [0, 4])
        XCTAssertNotNil(FuzzyMatcher.match("nwfldr", in: "New Folder"))
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "New Folder"))
        XCTAssertNil(FuzzyMatcher.match("folders", in: "Folder"))
        XCTAssertEqual(FuzzyMatcher.match("", in: "Anything")?.score, 0)
    }
    func testCaseDiacriticWidthInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.match("CAFE", in: "Café"))
        XCTAssertNotNil(FuzzyMatcher.match("ｃｏｐｙ", in: "Copy"))
    }
    func testScoresPreferWordStartsAndAcronyms() {
        // c(0)=21; "cp" best second char: Copy p@2 → 21; Copy as Path P@8 word start → 25; Compress p@3 → 20
        XCTAssertEqual(FuzzyMatcher.match("cp", in: "Copy")?.score, 21)
        XCTAssertEqual(FuzzyMatcher.match("cp", in: "Copy as Path")?.score, 25)
        XCTAssertEqual(FuzzyMatcher.match("cp", in: "Compress to .zip")?.score, 20)
        XCTAssertGreaterThan(FuzzyMatcher.match("new", in: "New Folder")!.score, FuzzyMatcher.match("new", in: "Show Package Contents in a New Window")!.score)
    }
    func testPerformanceUnderTwoMillisecondsForCatalog() {
        let titles = (0..<200).map { "Command number \($0) with some words" }
        let clock = ContinuousClock()
        let elapsed = clock.measure { for t in titles { _ = FuzzyMatcher.match("cnw", in: t) } }
        XCTAssertLessThan(elapsed, .milliseconds(8))     // 2 ms budget × 4 in debug
    }
}

final class PaletteCatalogTests: XCTestCase {
    private func item(_ c: Command, _ t: String) -> PaletteItem { PaletteItem(target: .command(c), title: t, subtitle: nil) }
    func testRankingOrderAndTieBreak() {
        let items = [item(.copy, "Copy"), item(.copyAsPath, "Copy as Path"), item(.compressZip, "Compress to .zip")]
        XCTAssertEqual(PaletteCatalog.rank(items, query: "cp", recent: []).map(\.item.title), ["Copy as Path", "Copy", "Compress to .zip"])
    }
    func testMRUBoostAndEmptyQuery() {
        let items = [item(.copy, "Copy"), item(.copyAsPath, "Copy as Path"), item(.refresh, "Refresh")]
        XCTAssertEqual(PaletteCatalog.rank(items, query: "", recent: [.command(.refresh)]).map(\.item.title), ["Refresh", "Copy", "Copy as Path"])
        XCTAssertEqual(PaletteCatalog.rank(items, query: "cp", recent: [.command(.copy)]).first?.item.title, "Copy")   // 21 + 30 > 25
    }
    func testLocationsIncluded() {
        let loc = PaletteItem(target: .location(URL(filePath: "/tmp/macx-x/Projects")), title: "Go to Projects", subtitle: "/tmp/macx-x/Projects")
        XCTAssertEqual(PaletteCatalog.rank([loc, item(.properties, "Properties")], query: "proj", recent: []).map(\.item.title), ["Go to Projects"])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.FuzzyMatcherTests 2>&1 | tail -5`
Expected: FAIL (`cannot find 'FuzzyMatcher'`).

- [ ] **Step 3: Implement**

```swift
public struct FuzzyMatch: Sendable, Equatable { public var score: Int; public var matchedIndices: [Int] }

public enum FuzzyMatcher {
    static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")))
    }
    /// Scoring: +1 per matched char; +20 at index 0, +10 after a non-alphanumeric; +15 when consecutive;
    /// −1 per skipped char between matches; −min(firstIndex, 10) leading penalty. Best path by DP.
    /// Indices refer to the folded candidate (equal to the original when folding preserves length).
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let q = fold(query).filter { !$0.isWhitespace }
        if q.isEmpty { return FuzzyMatch(score: 0, matchedIndices: []) }
        let c = fold(candidate)
        let n = q.count, m = c.count
        guard n <= m else { return nil }
        let neg = Int.min / 4
        func bonus(_ j: Int) -> Int { j == 0 ? 20 : ((c[j - 1].isLetter || c[j - 1].isNumber) ? 0 : 10) }
        var dp = [[Int]](repeating: [Int](repeating: neg, count: m), count: n)
        var from = [[Int]](repeating: [Int](repeating: -1, count: m), count: n)
        for j in 0..<m where c[j] == q[0] { dp[0][j] = 1 + bonus(j) - min(j, 10) }
        if n > 1 {
            for i in 1..<n {
                var best = neg, bestK = -1                     // max over k < j of dp[i-1][k] + k
                for j in i..<m {
                    let k = j - 1
                    if dp[i - 1][k] > neg, dp[i - 1][k] + k > best { best = dp[i - 1][k] + k; bestK = k }
                    guard c[j] == q[i] else { continue }
                    var s = neg, f = -1
                    if dp[i - 1][j - 1] > neg { s = dp[i - 1][j - 1] + 1 + 15 + bonus(j); f = j - 1 }
                    if bestK >= 0 {
                        let g = best - j + 1 + 1 + bonus(j)     // dp[k] − (j − k − 1) + 1 + bonus
                        if g > s { s = g; f = bestK }
                    }
                    dp[i][j] = s; from[i][j] = f
                }
            }
        }
        var endJ = -1, endScore = neg
        for j in 0..<m where dp[n - 1][j] > endScore { endScore = dp[n - 1][j]; endJ = j }
        guard endJ >= 0 else { return nil }
        var indices = [Int](repeating: 0, count: n)
        var j = endJ
        for i in stride(from: n - 1, through: 0, by: -1) { indices[i] = j; j = from[i][j] }
        return FuzzyMatch(score: endScore, matchedIndices: indices)
    }
}
```

`PaletteCatalog.rank`:
- If `query.trimmingCharacters(in: .whitespaces).isEmpty`, list the items present in `recent` (in recent order), then the rest sorted by `title.localizedStandardCompare`, all with `FuzzyMatch(score: 0, matchedIndices: [])`.
- Otherwise match each item. For a match, add the MRU boost: if the item's target is at position r < 10 in `recent`, add `30 − 3 × r`. Sort by score descending, then `title.count` ascending, then `localizedStandardCompare`.

`CommandTitles.title(_:)` uses an exhaustive `switch` with `L10n.string("command.<raw>")`. Add every key to the String Catalog. `MainMenuBuilder` switches to `CommandTitles`, so the menu and palette never disagree.

`CommandPaletteController` (`@MainActor final class`, an `NSPanel` subclass `PalettePanel` with `canBecomeKey == true` and `styleMask [.titled, .fullSizeContentView]` with a hidden title):
- `show(over:context:)` remembers `targetWindow` and that window's `firstResponder`. It computes `CommandState` and `FocusContext` from the target window's current command target, using the same function the command bar uses (P1-29).
- Items: every `Command` where `CommandAvailability.isEnabled(c, focus:, state:)` holds, except `.showCommandPalette` itself. The subtitle is the primary chord rendered as menu glyphs (`⌘⇧N`). Also one "Go to <name>" per resolved favorite with a URL, and per recent location (≤ 20).
- The search field's `controlTextDidChange` re-ranks synchronously, which is fine at < 2 ms for about 200 items.
- ↑/↓ move the table selection, Return runs, Esc and resign-key close.
- Run: close the panel, `targetWindow.makeKeyAndOrderFront(nil)`, restore its first responder, then for a `.command`, `NSApp.sendAction(Selector(c.selectorName), to: nil, from: self)`; for a `.location`, `windowController.navigate(to:)`. Then call `settings.notePaletteUsed`.
- Matched characters are highlighted in bold when the folded and original lengths match.
- Accessibility identifiers: `macx.palette`, `macx.palette.field`, `macx.palette.table`.

Add `.showCommandPalette` to `shippedPhase4Commands`. Implement `@objc func macx_showCommandPalette(_:)` in the browser window controller, so it works from any focus.

- [ ] **Step 4: Write the failing UI test**

```swift
@MainActor final class CommandPaletteTests: XCTestCase {
    func testPaletteRunsCommandThroughResponderChainOfTargetWindow() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)            // S5 P1-31 harness: sandbox + sandboxed env + context
        try ui.file("a.txt")
        let window = try await ui.openBrowserWindow()
        let palette = CommandPaletteController.show(over: window.window!, context: ui.context)
        palette.setQuery("new folder")
        XCTAssertEqual(palette.visibleTitles.first, CommandTitles.title(.newFolder))
        palette.runSelected()
        try await ui.waitUntil("New Folder row") { window.probeRowNames.contains("New Folder") }
        XCTAssertEqual(ui.context.environment.settings.paletteRecent.first, "cmd:newFolder")
    }
    func testDisabledCommandsAreNotListed() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)
        let window = try await ui.openBrowserWindow()                // empty folder, nothing selected
        let palette = CommandPaletteController.show(over: window.window!, context: ui.context)
        palette.setQuery("rename")
        XCTAssertFalse(palette.visibleTitles.contains(CommandTitles.title(.rename)))
    }
}
```

`ContentTestHarness` is S5's UITests helper (`Tests/UITests/Support/ContentTestHarness.swift`, P1-31): it owns the `Sandbox`, builds `CoreEnvironment.sandboxed(root:)` and a `UIContext`, and `openBrowserWindow()` opens a real `BrowserWindowController` on `<sandbox>/files`. `setQuery`, `visibleTitles` and `runSelected` are internal test seams on the controller.

- [ ] **Step 5: Run all palette tests**

Run: `swift test --filter "CoreTests.FuzzyMatcherTests|CoreTests.PaletteCatalogTests|UITests.CommandPaletteTests" 2>&1 | tail -5`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 6: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests
git commit -m "feat: command palette with fuzzy matching, MRU and responder-chain execution"
```

### Task P4-04: Tags core (`FileTag`, `TagIO`, `setTags` job, known tags)

**Files:**
- Create: `Sources/Core/Tags/FileTag.swift`, `Sources/Core/Tags/TagIO.swift`, `Sources/Core/FileOps/TagJobs.swift`
- Modify: `Sources/Core/FileOps/JobTypes.swift` (`JobKind.setTags`, `JobVerb.tagging`, `TagEdit`, `allURLs`, `jobDescription`), `Sources/Core/FileOps/JobRecord.swift` (`ItemAction.tagsChanged`), `Sources/Core/FileOps/JobRunner.swift` (dispatch), `Sources/Core/FileOps/UndoPlanner.swift` (`UndoStep.restoreTags`), `Sources/Core/Settings/Settings.swift` (`knownTags`, `sidebarTags`, `noteTagUsed`), `Sources/UI/Support/L10n` action names (`"undo.tagging"` → "Tag")
- Test: `Tests/CoreTests/Tags/TagIOTests.swift`, `Tests/CoreTests/Tags/TagJobTests.swift`

**Interfaces:**
- Consumes: `FileOpsTestCase` (S3), `JobContext` (`onLane`, `record`, `skip`, `noteModified`, `addProgress`, `setTotals`, `checkpoint`, `resolveFailure`), `UndoPlanner` (P1-24), `Settings` per-key persistence (P1-12), `PosixFS`.
- Produces: §3.3 `TagColor`, `FileTag`, `TagIOError`, `TagIO`, `TagEdit`, `JobKind.setTags`, `JobVerb.tagging`, `ItemAction.tagsChanged`, and the Settings members `knownTags`, `sidebarTags`, `noteTagUsed(_:)`. Internal: `TagEdit.applied(to: [FileTag]) -> [FileTag]` and `TagJobs.setTags(_ ctx: JobContext, _ urls: [URL], _ edit: TagEdit) async`.

**Format notes (verified against Finder on macOS 26):**
- Finder stores tags in the xattr `com.apple.metadata:_kMDItemUserTags`. The value is a binary property list holding an array of strings, each `"<name>\n<color digit>"`, or just `"<name>"` when the colour is none. Colour digits are the `TagColor` raw values (0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange).
- Finder no longer needs the legacy FinderInfo label bits, and Spotlight indexes the xattr. `TagIO` writes only the xattr and never touches `com.apple.FinderInfo`.
- All xattr calls use `XATTR_NOFOLLOW`, so tagging a symlink tags the link itself (Finder does the same).

- [ ] **Step 1: Write the failing `TagIO` tests**

```swift
import XCTest
import Darwin
@testable import Core
import MacxFixtures

final class TagIOTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    func testEncodeDecodeRoundTripAndFinderShape() throws {
        let tags = [FileTag(name: "Red", color: .red), FileTag(name: "Project X"), FileTag(name: "Green", color: .green)]
        let data = try TagIO.encode(tags)
        let raw = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        XCTAssertEqual(raw, ["Red\n6", "Project X", "Green\n2"])
        XCTAssertEqual(TagIO.decode(data), tags)
        var format = PropertyListSerialization.PropertyListFormat.xml
        _ = try PropertyListSerialization.propertyList(from: data, format: &format)
        XCTAssertEqual(format, .binary)
    }
    func testDecodeToleratesGarbageAndUnknownColours() {
        XCTAssertEqual(TagIO.decode(Data("nonsense".utf8)), [])
        let data = try! PropertyListSerialization.data(fromPropertyList: ["A\n9", "B\n", 42, "C\n3"], format: .binary, options: 0)
        XCTAssertEqual(TagIO.decode(data), [FileTag(name: "A"), FileTag(name: "B"), FileTag(name: "C", color: .purple)])
    }
    func testNormalize() {
        let n = TagIO.normalize([FileTag(name: "  Work "), FileTag(name: ""), FileTag(name: "work", color: .blue),
                                 FileTag(name: "\n"), FileTag(name: "Home", color: .red)])
        XCTAssertEqual(n, [FileTag(name: "Work"), FileTag(name: "Home", color: .red)])
    }
    func testStandardTags() {
        XCTAssertEqual(FileTag.standard.map(\.name), ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        XCTAssertEqual(FileTag.standard.map(\.color.rawValue), [6, 7, 5, 2, 4, 3, 1])
    }
    func testReadWriteOnSandboxFilesAndLinks() throws {
        let file = try sandbox.createFile("a.txt")
        let link = try sandbox.createSymlink("l", target: "a.txt")
        XCTAssertEqual(try TagIO.read(file), [])                                   // ENOATTR → []
        try TagIO.write([FileTag(name: "Blue", color: .blue)], to: file)
        XCTAssertEqual(try TagIO.read(file), [FileTag(name: "Blue", color: .blue)])
        XCTAssertEqual(try TagIO.read(link), [])                                   // the link has its own tags
        try TagIO.write([FileTag(name: "L")], to: link)
        XCTAssertEqual(try TagIO.read(file), [FileTag(name: "Blue", color: .blue)])
        try TagIO.write([], to: file)
        XCTAssertEqual(getxattr(file.path, TagIO.xattrName, nil, 0, 0, XATTR_NOFOLLOW), -1)   // [] removes
        XCTAssertEqual(errno, ENOATTR)
        XCTAssertNoThrow(try TagIO.write([], to: file))                            // removing twice is fine
    }
    func testReadMissingFileThrowsENOENT() {
        XCTAssertThrowsError(try TagIO.read(sandbox.url("missing"))) { XCTAssertEqual($0 as? TagIOError, TagIOError(code: ENOENT)) }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.TagIOTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'TagIO' in scope`.

- [ ] **Step 3: Implement `FileTag.swift` and `TagIO.swift`**

```swift
// FileTag.swift
public enum TagColor: Int, Sendable, Codable, CaseIterable { case none = 0, gray, green, purple, blue, yellow, red, orange }

public struct FileTag: Sendable, Codable, Hashable {
    public var name: String
    public var color: TagColor
    public init(name: String, color: TagColor = .none) { self.name = name; self.color = color }
    public static let standard: [FileTag] = [
        FileTag(name: "Red", color: .red), FileTag(name: "Orange", color: .orange), FileTag(name: "Yellow", color: .yellow),
        FileTag(name: "Green", color: .green), FileTag(name: "Blue", color: .blue), FileTag(name: "Purple", color: .purple),
        FileTag(name: "Gray", color: .gray),
    ]
}
```

```swift
// TagIO.swift
import Foundation
import Darwin
import MacxFS

public struct TagIOError: Error, Sendable, Equatable { public var code: Int32; public init(code: Int32) { self.code = code } }

public enum TagIO {
    public static let xattrName = "com.apple.metadata:_kMDItemUserTags"

    public static func decode(_ data: Data) -> [FileTag] {
        guard let array = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any] else { return [] }
        return array.compactMap { element -> FileTag? in
            guard let s = element as? String else { return nil }
            guard let nl = s.lastIndex(of: "\n") else { return FileTag(name: s) }
            let name = String(s[..<nl])
            let digit = Int(s[s.index(after: nl)...]) ?? 0
            return FileTag(name: name, color: TagColor(rawValue: digit) ?? .none)
        }
    }
    public static func encode(_ tags: [FileTag]) throws -> Data {
        let strings = tags.map { $0.color == .none ? $0.name : "\($0.name)\n\($0.color.rawValue)" }
        return try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
    }
    public static func normalize(_ tags: [FileTag]) -> [FileTag] {
        var seen = Set<String>()
        var out: [FileTag] = []
        for t in tags {
            let name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(FileTag(name: name, color: t.color))
        }
        return out
    }
    public static func read(_ url: URL) throws(TagIOError) -> [FileTag] {
        assertOffMain()
        let path = url.path
        let size = getxattr(path, xattrName, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return [] }
            throw TagIOError(code: errno)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, xattrName, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read >= 0 else { throw TagIOError(code: errno) }
        return decode(Data(buffer.prefix(read)))
    }
    public static func write(_ tags: [FileTag], to url: URL) throws(TagIOError) {
        assertOffMain()
        let path = url.path
        let normalized = normalize(tags)
        if normalized.isEmpty {
            if removexattr(path, xattrName, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw TagIOError(code: errno) }
            return
        }
        guard let data = try? encode(normalized) else { throw TagIOError(code: EINVAL) }
        let rc = data.withUnsafeBytes { setxattr(path, xattrName, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if rc != 0 { throw TagIOError(code: errno) }
    }
}
```

`getxattr` on a missing file sets `ENOENT`, which `read` reports as `TagIOError(code: ENOENT)`. `ENOATTR` is the only errno that means "no tags".

Run: `swift test --filter CoreTests.TagIOTests 2>&1 | tail -5` → `Executed 6 tests, with 0 failures`.

- [ ] **Step 4: Write the failing job, undo and settings tests**

```swift
import XCTest
import Darwin
@testable import Core
import MacxFixtures

final class TagJobTests: FileOpsTestCase {
    private func tags(_ u: URL) async throws -> [FileTag] { try await LanePool().perform(on: .unknown) { _ in try TagIO.read(u) } }
    private let red = FileTag(name: "Red", color: .red), work = FileTag(name: "Work")

    func testAppliedSemantics() {
        XCTAssertEqual(TagEdit.add(red).applied(to: [work]), [work, red])
        XCTAssertEqual(TagEdit.add(FileTag(name: "red", color: .blue)).applied(to: [red]), [red])     // case-insensitive, keeps existing
        XCTAssertEqual(TagEdit.remove("RED").applied(to: [red, work]), [work])
        XCTAssertEqual(TagEdit.set([work, work]).applied(to: [red]), [work])
    }
    func testAddAcrossSelectionRecordsOnlyChangedItems() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let (queue, _) = makeQueue()
        _ = try await run(.setTags([a], .add(red)), on: queue)
        let outcome = try await run(.setTags([a, b], .add(red)), on: queue)
        XCTAssertEqual(try await tags(a), [red]); XCTAssertEqual(try await tags(b), [red])
        XCTAssertEqual(outcome.record.verb, .tagging)
        XCTAssertEqual(outcome.record.actions, [.tagsChanged(b, old: [], new: [red])])   // a was unchanged
        XCTAssertTrue(outcome.localChanges.contains { $0.modified.contains("b.txt") })
    }
    func testToggleAddsToAllWhenMixedAndRemovesWhenAllHaveIt() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let (queue, _) = makeQueue()
        _ = try await run(.setTags([a], .add(red)), on: queue)
        _ = try await run(.setTags([a, b], .toggle(red)), on: queue)
        XCTAssertEqual(try await tags(b), [red])
        _ = try await run(.setTags([a, b], .toggle(red)), on: queue)
        XCTAssertEqual(try await tags(a), []); XCTAssertEqual(try await tags(b), [])
    }
    func testUndoRestoresPreviousTagsAndSkipsItemsChangedSince() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let (queue, _) = makeQueue()
        _ = try await run(.setTags([a, b], .set([work])), on: queue)
        let outcome = try await run(.setTags([a, b], .add(red)), on: queue)
        try await LanePool().perform(on: .unknown) { _ in try TagIO.write([FileTag(name: "Other")], to: b) }   // external edit
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(try await tags(a), [work])
        XCTAssertEqual(try await tags(b), [FileTag(name: "Other")])
        XCTAssertEqual(undo.skipped.map(\.reason), [.changedDuringMove])
        let redo = try await run(.redo(undo.record), on: queue)
        XCTAssertEqual(try await tags(a), [work, red]); XCTAssertTrue(redo.skipped.isEmpty)
    }
    func testLockedItemAsksAndSkip() async throws {
        let a = try file("a.txt")
        try sandbox.setFlags("a.txt", UInt32(UF_IMMUTABLE))
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        let outcome = try await run(.setTags([a], .add(red)), on: queue)
        XCTAssertEqual(interaction.askedErrors().map(\.kind), [.locked])
        XCTAssertEqual(outcome.skipped.map(\.url), [a]); XCTAssertTrue(outcome.record.actions.isEmpty)
    }
    func testUnlockAndContinue() async throws {
        let a = try file("a.txt")
        try sandbox.setFlags("a.txt", UInt32(UF_IMMUTABLE))
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(errors: [.unlockAndContinue]))
        _ = try await run(.setTags([a], .add(red)), on: queue)
        XCTAssertEqual(try await tags(a), [red])
    }
    @MainActor func testKnownTagsMRUAndCap() {
        let settings = Settings(storage: InMemorySettingsStorage())
        XCTAssertEqual(settings.knownTags, FileTag.standard)
        XCTAssertEqual(settings.sidebarTags, FileTag.standard.map(\.name))
        settings.noteTagUsed(FileTag(name: "Work"))
        settings.noteTagUsed(FileTag(name: "green", color: .green))
        XCTAssertEqual(settings.knownTags.prefix(2).map(\.name), ["green", "Work"])
        XCTAssertEqual(settings.knownTags.filter { $0.name.lowercased() == "green" }.count, 1)
        for i in 0..<300 { settings.noteTagUsed(FileTag(name: "t\(i)")) }
        XCTAssertEqual(settings.knownTags.count, 200)
        XCTAssertEqual(settings.knownTags.first?.name, "t299")
    }
}
```

- [ ] **Step 5: Run to verify they fail**

Run: `swift test --filter CoreTests.TagJobTests 2>&1 | tail -5`
Expected: build failure, `type 'JobKind' has no member 'setTags'`.

- [ ] **Step 6: Implement the job, undo step and settings**

`JobTypes.swift`: add `public enum TagEdit` (§3.3), `case setTags([URL], TagEdit)` to `JobKind` and `case tagging` to `JobVerb`. `allURLs` returns the URLs. `jobDescription` is `JobDescription(verb: .tagging, itemCount: urls.count, firstItemName: urls.first?.lastPathComponent, sourceFolderName: urls.first?.deletingLastPathComponent().lastPathComponent, destinationFolderName: nil)`. Lane volume: the volume of the first URL, as for `setAttributes`.

```swift
extension TagEdit {
    /// Pure. `toggle` is resolved by the job before this is called (it never reaches here).
    func applied(to current: [FileTag]) -> [FileTag] {
        switch self {
        case .set(let tags): return TagIO.normalize(tags)
        case .add(let tag):
            return current.contains { $0.name.lowercased() == tag.name.lowercased() } ? current : TagIO.normalize(current + [tag])
        case .remove(let name): return current.filter { $0.name.lowercased() != name.lowercased() }
        case .toggle(let tag): return TagEdit.add(tag).applied(to: current)
        }
    }
}
```

`JobRecord.swift`: `case tagsChanged(URL, old: [FileTag], new: [FileTag])`.

`TagJobs.swift`:

```swift
import Foundation
import Darwin
import MacxFS

enum TagJobs {
    static func setTags(_ ctx: JobContext, _ urls: [URL], _ edit: TagEdit) async {
        ctx.setTotals(items: urls.count, bytes: 0)
        ctx.setState(.running)
        var edit = edit
        if case .toggle(let tag) = edit {
            // Finder semantics: if any item lacks the tag, add it everywhere; otherwise remove it everywhere.
            let allHave = (try? await ctx.onLane { _ in
                urls.allSatisfy { u in ((try? TagIO.read(u)) ?? []).contains { $0.name.lowercased() == tag.name.lowercased() } }
            }) ?? false
            edit = allHave ? .remove(tag.name) : .add(tag)
        }
        let resolved = edit
        items: for url in urls {
            guard await ctx.checkpoint() else { break }
            while true {
                let r = (try? await ctx.onLane { _ -> (Int32, [FileTag], [FileTag]) in
                    do {
                        let old = try TagIO.read(url)
                        let new = resolved.applied(to: old)
                        if new != old { try TagIO.write(new, to: url) }
                        return (0, old, new)
                    } catch { return (error.code, [], []) }
                }) ?? (EIO, [], [])
                if r.0 == 0 {
                    if r.1 != r.2 { ctx.record(.tagsChanged(url, old: r.1, new: r.2)); ctx.noteModified(url) }
                    ctx.addProgress(items: 1, current: url.lastPathComponent)
                    continue items
                }
                switch await ctx.resolveFailure(r.0, url: url) {
                case .retry: continue
                case .skipped: continue items
                case .cancelled: return
                }
            }
        }
    }
}
```

`TagIO.write` on a `uchg` file fails with `EPERM`; `resolveFailure` maps that to `.locked` (it checks the immutable flag), which offers Unlock and Continue.

`JobRunner.run`: `case .setTags(let urls, let edit): await TagJobs.setTags(ctx, urls, edit)`.

`UndoPlanner`: `case .tagsChanged(let u, let old, let new): .restoreTags(u, expected: new, restore: old)`. Executing `.restoreTags` reads the current tags on a lane. If they differ from `expected` (compared after `normalize`), the item is skipped with `.changedDuringMove`. Otherwise it writes `restore` and records `.tagsChanged(u, old: expected, new: restore)`, so redo is the inverse of the undo record (P1-24 rule). A missing item is skipped with `.sourceGone`.

`Settings.swift`: `knownTags` (key `"knownTags"`, JSON `[FileTag]`, default `FileTag.standard`), `sidebarTags` (key `"sidebarTags"`, default the seven standard names). `noteTagUsed(_ tag:)` removes any entry with the same lowercased name, inserts `tag` at index 0, and truncates to 200.

The localized action name for `.tagging` is "Tag" (`L10n` key `undo.tagging`), so Edit shows "Undo Tag".

- [ ] **Step 7: Run the tests, build, commit**

Run: `swift test --filter "CoreTests.TagIOTests|CoreTests.TagJobTests|CoreTests.UndoPlannerTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

```bash
swift build 2>&1 | tail -5
git add Sources/Core Sources/UI/Resources Tests/CoreTests/Tags
git commit -m "feat: Finder-compatible tag xattr IO, undoable setTags job and known tags"
```

### Task P4-05: Tags UI (cache, Properties editor, context menu, Tags column)

**Files:**
- Create: `Sources/Core/Tags/TagCache.swift`, `Sources/UI/Tags/TagEditorView.swift`, `Sources/UI/Tags/TagMenu.swift`, `Sources/UI/Tags/TagDotsView.swift`
- Modify: `Sources/Core/Support/CoreEnvironment.swift` (`tagCache`), `Sources/Core/Commands/CommandAvailability.swift` (`.editTags` shipped), `Sources/UI/Menus/ContextMenuBuilder.swift` (Tags ▸ submenu), `Sources/UI/Menus/MainMenuBuilder.swift` (File › Tags…), `Sources/UI/Commands/FileCommandController.swift` (`editTags`, tag menu actions), `Sources/UI/Properties/PropertiesView.swift` and `PropertiesViewModel.swift` (Tags row), the Details view's cell provider (`Sources/UI/Content/DetailsCells.swift` or wherever Phase 2 put the Tags column; if Phase 2 has not landed, add `ColumnID.tags` to `SettingsTypes.swift` and the cell here)
- Test: `Tests/UITests/TagUITests.swift`

**Interfaces:**
- Consumes: P4-04 (`TagIO`, `TagEdit`, `JobKind.setTags`, `Settings.knownTags`, `noteTagUsed`), `OperationsCenter.perform`/`onFinished`, `ChangeBus`/`FolderEvent` row reloads, `MountTableStore`, `ContentTestHarness` (S5).
- Produces: `TagCache` (§3.3); `TagMenu.build(for urls: [URL], cache: TagCache, settings: Settings, perform: @escaping @MainActor (TagEdit) -> Void) -> NSMenu`; `TagEditorView(model: TagEditorModel)` with `@MainActor @Observable final class TagEditorModel { init(urls: [URL], context: UIContext); var tokens: [FileTag]; var mixed: Set<String>; func commit() async }`; `TagDotsView` (`NSView`, draws up to 3 overlapping 8 pt dots, `"+N"` text for more; empty for no tags).

**Behaviour:**
- `TagCache` keeps `[String: [FileTag]]` keyed by standardized path, bounded at 20,000 entries (LRU by insertion). `prefetch` drops already-cached and already-pending URLs. It batches the rest (≤ 500) into one lane call per volume (`lanes.perform(on: volumeID, .read)`), reading inside `withNoMaterialization` and treating a read error as `[]`. It stores the results and sends the URLs to observers once per batch. `invalidate` removes the entry and calls `prefetch([url])`, so the next observer event delivers the new value.
- `CoreEnvironment` builds the cache and subscribes to `operations.onFinished`. For every `.tagsChanged(u, …)` action it calls `tagCache.invalidate(u)`. The Details view invalidates rows the folder model reports as modified (`ChangeSet` reloads), which covers Finder or other apps changing tags.
- The Tags ▸ submenu is built from `settings.knownTags.prefix(7)` with no file-system access. Each item shows a coloured dot. Its state is `.on` when every selected URL's cached tags contain it, `.mixed` when some do, and `.off` otherwise; unknown cache entries count as `.off` and are prefetched. The menu's delegate observes the cache while open and updates states in place. Choosing an item performs `.toggle(tag)`. The final item, "Tags…", runs `editTags`.
- `editTags` opens a popover anchored at the first selected row containing `TagEditorView`. Properties shows the same view inline in a "Tags" row (single and multi selection). Tokens use an `NSTokenField` wrapper whose completion list is `knownTags` filtered by prefix (case-insensitive). Typing a new name and pressing Return makes a token with colour none. Each token has a context menu with the 7 colours. In multi-selection, tags only some items have are shown dimmed (in `mixed`), and are left alone unless the user deletes them.
- `TagEditorModel.commit()` diffs the tokens against what it loaded and sends one `.remove(name)` job per deleted token and one `.add(tag)` job per added token, each its own undo entry (Step 4 has the details). Edits never rewrite tags that only some items have, so a multi-selection keeps each item's other tags. It then calls `settings.noteTagUsed` for every added tag.
- The Tags column cell (Details) shows `TagDotsView` from `tagCache.cachedTags(for:)`. `nil` draws nothing and is prefetched with the visible range. When the cache's observer fires, the view reloads only the affected visible rows (`reloadData(forRowIndexes:columnIndexes:)`).
- Add `.editTags` to `shippedPhase4Commands`.

- [ ] **Step 1: Write the failing UI tests**

```swift
import XCTest
import AppKit
@testable import UI
@testable import Core

@MainActor final class TagUITests: XCTestCase {
    private func write(_ tags: [FileTag], _ url: URL, _ ui: ContentTestHarness) async throws {
        try await ui.context.environment.lanes.perform(on: .unknown) { _ in try TagIO.write(tags, to: url) }
    }

    func testTagCachePrefetchesOnLaneAndNotifiesOnce() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        try await write([FileTag(name: "Red", color: .red)], a, ui)
        let cache = ui.context.environment.tagCache
        var notified: [[URL]] = []
        let token = cache.observe { notified.append($0) }
        defer { token.cancel() }
        XCTAssertNil(cache.cachedTags(for: a))
        cache.prefetch([a, b, a])
        try await ui.waitUntil("cache filled") { cache.cachedTags(for: b) != nil }
        XCTAssertEqual(cache.cachedTags(for: a), [FileTag(name: "Red", color: .red)])
        XCTAssertEqual(cache.cachedTags(for: b), [])
        XCTAssertEqual(notified.count, 1)
        XCTAssertEqual(Set(notified[0]), [a, b])
    }
    func testTagMenuStatesComeFromCache() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        try await write([FileTag(name: "Red", color: .red)], a, ui)
        let cache = ui.context.environment.tagCache
        cache.prefetch([a, b])
        try await ui.waitUntil("cache filled") { cache.cachedTags(for: b) != nil }
        var performed: [TagEdit] = []
        let menu = TagMenu.build(for: [a, b], cache: cache, settings: ui.context.environment.settings) { performed.append($0) }
        XCTAssertEqual(menu.items.prefix(7).map(\.title), ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        XCTAssertEqual(menu.items[0].state, .mixed)
        XCTAssertEqual(menu.items[1].state, .off)
        XCTAssertEqual(menu.items.last?.title, L10n.string("tags.menu.edit"))     // "Tags…"
        menu.performActionForItem(at: 0)
        XCTAssertEqual(performed, [.toggle(FileTag(name: "Red", color: .red))])
    }
    func testChoosingTagRunsJobUpdatesCacheAndUndoes() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let window = try await ui.openBrowserWindow()
        window.session.folder.select(.only(["a.txt"]))
        let controller = FileCommandController(context: ui.context, window: window)
        await controller.applyTagEdit(.toggle(FileTag(name: "Green", color: .green)), to: [a])
        let cache = ui.context.environment.tagCache
        try await ui.waitUntil("cache updated") { cache.cachedTags(for: a) == [FileTag(name: "Green", color: .green)] }
        XCTAssertEqual(ui.context.environment.settings.knownTags.first?.name, "Green")
        XCTAssertTrue(ui.context.environment.undo.canUndo)
        ui.context.environment.undo.undoManager.undo()
        try await ui.waitUntil("undo cleared tags") { cache.cachedTags(for: a) == [] }
    }
    func testEditorModelAddsNewTagAndRemovesTokenForMixedSelection() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        try await write([FileTag(name: "Red", color: .red), FileTag(name: "Work")], a, ui)
        try await write([FileTag(name: "Work")], b, ui)
        let model = TagEditorModel(urls: [a, b], context: ui.context)
        try await ui.waitUntil("model loaded") { !model.tokens.isEmpty }
        XCTAssertEqual(model.tokens.map(\.name), ["Red", "Work"])
        XCTAssertEqual(model.mixed, ["Red"])
        model.tokens.removeAll { $0.name == "Work" }
        model.tokens.append(FileTag(name: "Project"))
        await model.commit()
        let read = { (u: URL) in try await ui.context.environment.lanes.perform(on: .unknown) { _ in try TagIO.read(u) } }
        XCTAssertEqual(try await read(a).map(\.name), ["Red", "Project"])
        XCTAssertEqual(try await read(b).map(\.name), ["Project"])
        XCTAssertTrue(ui.context.environment.settings.knownTags.contains(FileTag(name: "Project")))
    }
    func testTagDotsViewLayout() {
        let v = TagDotsView(frame: NSRect(x: 0, y: 0, width: 60, height: 16))
        v.tags = [FileTag(name: "A", color: .red), FileTag(name: "B", color: .blue), FileTag(name: "C"),
                  FileTag(name: "D", color: .green), FileTag(name: "E", color: .gray)]
        XCTAssertEqual(v.dotColors.count, 3)            // colourless tags are skipped for dots
        XCTAssertEqual(v.overflowText, "+1")
        XCTAssertEqual(v.accessibilityLabel(), "A, B, C, D, E")
    }
}
```

`FileCommandController.applyTagEdit(_:to:)` is the internal seam the Tags submenu and the popover both call. It performs `JobRequest(.setTags(urls, edit), origin: window.origin)` through `OperationsCenter.perform` and then calls `noteTagUsed` for `.add` and `.toggle` tags.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter UITests.TagUITests 2>&1 | tail -5`
Expected: build failure, `value of type 'CoreEnvironment' has no member 'tagCache'`.

- [ ] **Step 3: Implement `TagCache`**

```swift
import Foundation
import MacxFS

@MainActor
public final class TagCache {
    private let lanes: LanePool
    private let mountTable: MountTableStore
    private var values: [String: [FileTag]] = [:]
    private var order: [String] = []
    private var pending: Set<String> = []
    private let observers = Observers<[URL]>()
    static let capacity = 20_000

    public init(lanes: LanePool, mountTable: MountTableStore) { self.lanes = lanes; self.mountTable = mountTable }
    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    public func cachedTags(for url: URL) -> [FileTag]? { values[Self.key(url)] }
    public func observe(_ handler: @escaping @MainActor ([URL]) -> Void) -> ObserverToken { observers.add(handler) }

    public func invalidate(_ url: URL) {
        let k = Self.key(url)
        values[k] = nil
        prefetch([url])
    }

    public func prefetch(_ urls: [URL]) {
        var todo: [URL] = []
        for u in urls.prefix(500) {
            let k = Self.key(u)
            guard values[k] == nil, pending.insert(k).inserted else { continue }
            todo.append(u)
        }
        guard !todo.isEmpty else { return }
        let groups = Dictionary(grouping: todo) { mountTable.current.volumeID(containing: $0) ?? .unknown }
        for (volume, group) in groups {
            Task { [weak self, lanes] in
                let results = (try? await lanes.perform(on: volume, .read) { _ in
                    withNoMaterialization { group.map { ($0, (try? TagIO.read($0)) ?? []) } }
                }) ?? group.map { ($0, []) }
                self?.store(results)
            }
        }
    }

    private func store(_ results: [(URL, [FileTag])]) {
        for (u, tags) in results {
            let k = Self.key(u)
            pending.remove(k)
            if values.updateValue(tags, forKey: k) == nil { order.append(k) }
        }
        if order.count > Self.capacity {
            for k in order.prefix(order.count - Self.capacity) { values[k] = nil }
            order.removeFirst(order.count - Self.capacity)
        }
        observers.send(results.map(\.0))
    }
}
```

`mountTable.current.volumeID(containing:)` is the S1 mount-table lookup Phase 1 already uses for lane routing; if its name differs, use the one `FolderModel` uses.

- [ ] **Step 4: Implement the menu, editor, dots, column and wiring**

`TagMenu.build` returns an `NSMenu` whose items are `NSMenuItem(title: tag.name)` with `image` = a 12 pt circle filled with `TagDotsView.color(for:)` (`.none` gives an outlined circle). It also has a separator and the "Tags…" item (`target`/`action` of the controller's `macx_editTags:`). Add a private `TagMenuDelegate`: `menuWillOpen` subscribes to the cache and, on each cache event, recomputes the item states from `cachedTags`; `menuDidClose` cancels the token.

`TagDotsView.color(for:)` maps the colour cases to `NSColor.systemGray/.systemGreen/.systemPurple/.systemBlue/.systemYellow/.systemRed/.systemOrange`. `dotColors` keeps up to 3 non-`.none` colours, the most recently added last (Finder draws the last tag on top). `overflowText` is `"+N"` when more coloured tags exist, otherwise nil.

`TagEditorModel`:
- `init` loads every URL's tags with one lane call. `tokens` is the union of tags in first-seen order. `mixed` holds names that not every item has.
- `commit()` diffs against the loaded state. Removed names → one `.remove(name)` job over all URLs. Added tokens → one `.add(tag)` job each. Changed colours on an existing token → one `.set` job per item, built from that item's current tags with the colour replaced. Each job runs through `FileCommandController.applyTagEdit` semantics (via `OperationsCenter.perform`), and each is its own undo entry.

`ContextMenuBuilder.itemMenu`: insert "Tags" (submenu from `TagMenu.build`) after the Rename item, and prefetch the selection's URLs into the cache when the menu is built.

`PropertiesView`: add a "Tags" row under General with `TagEditorView` (`frame(minHeight: 22)`). The row is hidden for volumes.

The Details Tags column is created when Phase 2's `ColumnID.tags` is visible. Its cell reads the cache, and its visible-range prefetch runs from the same place Tier 1 icon requests run (`visibleRows()`).

- [ ] **Step 5: Run the tests**

Run: `swift test --filter "UITests.TagUITests|UITests.ContextMenuBuilderTests|UITests.PropertiesViewModelTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 6: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests/UITests/TagUITests.swift
git commit -m "feat: tag cache, Tags submenu, tag editor in Properties and popover, Tags column dots"
```

### Task P4-06: Tag queries and the sidebar TAGS section

**Files:**
- Create: `Sources/Core/Tags/TagQuery.swift`, `Sources/UI/Sidebar/SidebarTagsSection.swift`, `Sources/Core/Tags/TagSearchEvents.swift` (Step 5, needs Phase 3)
- Modify: `Sources/Core/Settings/SettingsTypes.swift` (`SidebarSection.tags`), `Sources/Core/Settings/Settings.swift` (`sidebarTags` editing helpers), `Sources/UI/Sidebar/SidebarViewController.swift` (section, drops, menu), `Sources/UI/Sidebar/SidebarDataSource.swift` (or the Phase 1 outline data source; add the section)
- Test: `Tests/CoreTests/Tags/TagQueryTests.swift`, `Tests/UITests/SidebarTagsTests.swift`

**Interfaces:**
- Consumes: P4-04/P4-05 (`TagIO`, `TagCache`, `JobKind.setTags`, `Settings.sidebarTags`, `knownTags`), `LanePool`, `withNoMaterialization`, `DropPolicy` (P1-36). Step 5 also consumes Phase 3: `SearchResultsModel.init(title:events:context:)`, `BrowserSession.showResults(_:recordHistory:)`, `SearchEvent`, `SearchBatch`, `SearchSummary`.
- Produces: §3.3 `TagScope`, `TagQueryUpdate`, `TagQuerying`, `SpotlightTagQuery`, `CrawlTagQuery`; `SidebarSection.tags`; internal `SpotlightTagQuery.predicate(for tagName: String) -> NSPredicate`; `Settings.setSidebarTag(_ name: String, visible: Bool)`; Step 5: `enum TagSearchEvents { static func events(query: any TagQuerying, tag: String, scope: TagScope, lanes: LanePool, types: TypeRegistry) -> (Generation) -> AsyncStream<SearchEvent> }`.

**Behaviour:**
- `SpotlightTagQuery` runs an `NSMetadataQuery` on the main thread with `predicate(for:)` (`kMDItemUserTags == %@` with `[c]` comparison, built as `NSPredicate(format: "%K ==[c] %@", "kMDItemUserTags", name)`). The scope is `NSMetadataQueryLocalComputerScope` for `.thisMac`, or `[url]` for `.directory`. It yields cumulative `.results` on `NSMetadataQueryDidUpdate`/`DidFinishGathering` (≤ 10 per second, coalesced) and `.finished` once gathering ends. It keeps running live until the stream's consumer terminates (`onTermination` stops the query on main). Tests never start it; only the pure predicate builder is tested.
- `CrawlTagQuery` works for `.directory(root)` only (`.thisMac` finishes at once with no results). On a `.read` lane, under `withNoMaterialization`, it walks with `fts_open(FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV)`. It skips package contents (`TypeRegistry.isPackage` by extension) and directories it can't read. For every entry it calls `TagIO.read` and keeps URLs that have the tag (case-insensitive). It heartbeats every 256 entries, checks `context.isCancelled`, and yields the cumulative list every 256 matches or 100 ms, then `.finished`. Termination of the stream cancels the lane task.
- The sidebar TAGS section comes after Locations. Its rows are `settings.sidebarTags` mapped to `knownTags` for colours (unknown names are colourless). Each row shows a `TagDotsView` dot and the name.
- Dropping files onto a tag row runs `setTags(urls, .add(tag))`, regardless of modifiers (`DropPolicy` returns `.copy` operation style for the cursor). Dropping from outside the app works the same way.
- The context menu on a tag row offers "Remove from Sidebar" (updates `sidebarTags`) and "Show All Tags…", which opens a sheet listing `knownTags` with checkboxes that edit `sidebarTags`. The section header menu offers "Hide Tags" (Phase 1 per-section hide).
- Clicking a tag row (Step 5) shows results in the active pane through `showResults`. The scope is `.thisMac` with `SpotlightTagQuery` normally. In sandbox mode (`options.isSandboxed`) it is `CrawlTagQuery` over `--root`, so scenarios never query Spotlight.

- [ ] **Step 1: Write the failing query tests**

```swift
import XCTest
@testable import Core
import MacxFixtures

final class TagQueryTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    private func tag(_ rel: String, _ names: String...) async throws {
        let u = sandbox.url(rel)
        try await LanePool().perform(on: .unknown) { _ in try TagIO.write(names.map { FileTag(name: $0) }, to: u) }
    }
    private func collect(_ stream: AsyncStream<TagQueryUpdate>) async -> (results: [URL], finished: Bool) {
        var last: [URL] = []; var finished = false
        for await u in stream { switch u { case .results(let r): last = r; case .finished: finished = true } }
        return (last, finished)
    }

    func testCrawlFindsTaggedItemsInsideScopeOnly() async throws {
        try sandbox.createFile("in/a.txt"); try sandbox.createFile("in/deep/b.txt"); try sandbox.createFile("in/c.txt")
        try sandbox.createDirectory("in/Folder"); try sandbox.createFile("out/d.txt")
        try await tag("in/a.txt", "Work"); try await tag("in/deep/b.txt", "work", "Home")
        try await tag("in/Folder", "Work"); try await tag("out/d.txt", "Work")
        let q = CrawlTagQuery(lanes: LanePool())
        let r = await collect(q.results(for: "WORK", scope: .directory(sandbox.url("in"))))
        XCTAssertTrue(r.finished)
        XCTAssertEqual(Set(r.results.map { $0.lastPathComponent }), ["a.txt", "b.txt", "Folder"])
    }
    func testCrawlDoesNotFollowSymlinksOrEnterPackages() async throws {
        try sandbox.createFile("outside/x.txt"); try await tag("outside/x.txt", "T")
        try sandbox.createDirectory("in")
        try sandbox.createSymlink("in/link", target: "../outside")
        try sandbox.createFile("in/App.app/Contents/y.txt"); try await tag("in/App.app/Contents/y.txt", "T")
        let r = await collect(CrawlTagQuery(lanes: LanePool()).results(for: "T", scope: .directory(sandbox.url("in"))))
        XCTAssertEqual(r.results, [])
    }
    func testCrawlThisMacFinishesEmpty() async {
        let r = await collect(CrawlTagQuery(lanes: LanePool()).results(for: "T", scope: .thisMac))
        XCTAssertEqual(r.results, []); XCTAssertTrue(r.finished)
    }
    func testCancellingStopsTheCrawl() async throws {
        try FixtureTree.flat(in: sandbox, at: "big", count: 5_000)
        let stream = CrawlTagQuery(lanes: LanePool()).results(for: "T", scope: .directory(sandbox.url("big")))
        let task = Task { for await _ in stream {} }
        task.cancel()
        let clock = ContinuousClock(); let start = clock.now
        await task.value
        XCTAssertLessThan(clock.now - start, .seconds(2))
    }
    func testSpotlightPredicateIsCaseInsensitiveAndEscapesQuotes() {
        let p = SpotlightTagQuery.predicate(for: #"Bob's "tag""#)
        XCTAssertEqual(p.predicateFormat, #"kMDItemUserTags ==[c] "Bob's \"tag\"""#)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.TagQueryTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'CrawlTagQuery' in scope`.

- [ ] **Step 3: Implement `TagQuery.swift`**

```swift
import Foundation
import Darwin
import MacxFS

public enum TagScope: Sendable, Equatable { case thisMac, directory(URL) }
public enum TagQueryUpdate: Sendable, Equatable { case results([URL]), finished }
public protocol TagQuerying: Sendable {
    func results(for tagName: String, scope: TagScope) -> AsyncStream<TagQueryUpdate>
}

public struct CrawlTagQuery: TagQuerying {
    private let lanes: LanePool
    public init(lanes: LanePool) { self.lanes = lanes }

    public func results(for tagName: String, scope: TagScope) -> AsyncStream<TagQueryUpdate> {
        AsyncStream { continuation in
            guard case .directory(let root) = scope else {
                continuation.yield(.results([])); continuation.yield(.finished); continuation.finish(); return
            }
            let wanted = tagName.lowercased()
            let task = Task { [lanes] in
                _ = try? await lanes.perform(on: .unknown, .read) { lane in
                    withNoMaterialization { Self.crawl(root, wanted, lane) { continuation.yield(.results($0)) } }
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func crawl(_ root: URL, _ wanted: String, _ lane: LaneContext, emit: ([URL]) -> Void) {
        var found: [URL] = []
        var lastEmit = ContinuousClock.now
        var seen = 0
        let path = strdup(root.path)
        defer { free(path) }
        var argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return emit([]) }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            seen += 1
            if seen % 256 == 0 { lane.heartbeat(); if lane.isCancelled { return } }
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_DP || info == FTS_DNR || info == FTS_ERR || info == FTS_NS { continue }
            let p = String(cString: ent.pointee.fts_path)
            if ent.pointee.fts_level == 0 { continue }
            if info == FTS_D, TypeRegistry.shared.isPackageExtension((p as NSString).pathExtension) {
                fts_set(fts, ent, FTS_SKIP)
            }
            let u = URL(filePath: p, directoryHint: info == FTS_D ? .isDirectory : .notDirectory)
            if ((try? TagIO.read(u)) ?? []).contains(where: { $0.name.lowercased() == wanted }) {
                found.append(u)
                if found.count % 256 == 0 || ContinuousClock.now - lastEmit > .milliseconds(100) {
                    emit(found); lastEmit = .now
                }
            }
        }
        emit(found)
    }
}
```

`TypeRegistry.shared.isPackageExtension(_:)` is the extension-based package check from S1 (`isPackage(typeIndex)` on `index(forExtension:isDirectory: true)`); use whichever spelling S1 shipped. A package directory itself is still checked for the tag (it appears in results); only its contents are skipped.

`SpotlightTagQuery`:

```swift
public struct SpotlightTagQuery: TagQuerying {
    public init() {}
    static func predicate(for tagName: String) -> NSPredicate { NSPredicate(format: "%K ==[c] %@", "kMDItemUserTags", tagName) }
    public func results(for tagName: String, scope: TagScope) -> AsyncStream<TagQueryUpdate> {
        AsyncStream { continuation in
            Task { @MainActor in
                let runner = SpotlightTagRunner(predicate: Self.predicate(for: tagName), scope: scope, continuation: continuation)
                runner.start()
                continuation.onTermination = { _ in Task { @MainActor in runner.stop() } }
            }
        }
    }
}
```

`SpotlightTagRunner` (private, `@MainActor final class`) owns the `NSMetadataQuery`. It observes `.NSMetadataQueryDidFinishGathering` and `.NSMetadataQueryDidUpdate`. It coalesces updates with a 100 ms `Task.sleep`, disables updates while reading `results` (`kMDItemPath`), and yields `.results(urls)`. After gathering it yields `.finished` once, keeps updating, and stops in `stop()`.

Run: `swift test --filter CoreTests.TagQueryTests 2>&1 | tail -5` → `Executed 5 tests, with 0 failures`.

- [ ] **Step 4: Write the failing sidebar tests, then implement the section**

```swift
@MainActor final class SidebarTagsTests: XCTestCase {
    func testSectionListsSidebarTagsWithColours() async throws {
        let ui = try await ContentTestHarness.make(self)
        let window = try await ui.openBrowserWindow()
        let section = try XCTUnwrap(window.sidebarController.tagsSection)
        XCTAssertEqual(section.rows.map(\.name), ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        XCTAssertEqual(section.rows.first?.color, .red)
        ui.context.environment.settings.setSidebarTag("Orange", visible: false)
        try await ui.waitUntil("row removed") { !section.rows.map(\.name).contains("Orange") }
    }
    func testDropOntoTagRowAddsTagWithOneUndo() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        let window = try await ui.openBrowserWindow()
        let section = try XCTUnwrap(window.sidebarController.tagsSection)
        await section.performDrop([a, b], onto: "Blue")
        let read = { (u: URL) in try await ui.context.environment.lanes.perform(on: .unknown) { _ in try TagIO.read(u) } }
        XCTAssertEqual(try await read(a), [FileTag(name: "Blue", color: .blue)])
        XCTAssertEqual(try await read(b), [FileTag(name: "Blue", color: .blue)])
        XCTAssertTrue(ui.context.environment.undo.canUndo)
    }
    func testDropValidationAcceptsFilesRejectsNonFileDrags() async throws {
        let ui = try await ContentTestHarness.make(self)
        let window = try await ui.openBrowserWindow()
        let section = try XCTUnwrap(window.sidebarController.tagsSection)
        XCTAssertEqual(section.validateDrop(fileURLs: [ui.url("x")]), .copy)
        XCTAssertEqual(section.validateDrop(fileURLs: []), [])
    }
}
```

`sidebarController`, `tagsSection`, `rows`, `performDrop(_:onto:)` and `validateDrop(fileURLs:) -> NSDragOperation` are internal seams. The real outline view's `validateDrop`/`acceptDrop` call the same two methods.

Implement `SidebarTagsSection` (`@MainActor final class`): it holds `rows: [Row]` (`struct Row { name: String; color: TagColor }`), rebuilt from `settings.sidebarTags`/`knownTags` through `withObservationTracking`; `performDrop` calls `FileCommandController.applyTagEdit(.add(tag), to: urls)`. Wire it into the Phase 1 sidebar outline as a fourth section using the same header style as Favorites/Locations. Add `SidebarSection.tags` and `Settings.setSidebarTag(_:visible:)` (appends visible names at the end; removing keeps order).

Run: `swift test --filter "UITests.SidebarTagsTests|UITests.SidebarTests" 2>&1 | tail -5` → `Executed N tests, with 0 failures`.

- [ ] **Step 5: Tag results in the content area (only when Phase 3 has landed)**

Check: `grep -rn "func showResults" Sources/UI`. If it prints nothing, skip this step and say so in the commit message ("Step 5 deferred until Phase 3"); clicking a tag row then does nothing.

Otherwise create `TagSearchEvents.swift`:

```swift
import Foundation
import MacxFS

public enum TagSearchEvents {
    /// Converts cumulative URL lists into SearchEvents: each update stats only URLs not seen before (on a lane),
    /// emits a batch per parent folder, emits `removed` for URLs that left the result set, and `completed` on `.finished`.
    public static func events(query: any TagQuerying, tag: String, scope: TagScope, lanes: LanePool,
                              types: TypeRegistry) -> (Generation) -> AsyncStream<SearchEvent> {
        { generation in
            AsyncStream { continuation in
                let task = Task {
                    var seen: Set<String> = []
                    let start = ContinuousClock.now
                    for await update in query.results(for: tag, scope: scope) {
                        switch update {
                        case .results(let urls):
                            let paths = Set(urls.map { $0.standardizedFileURL.path })
                            let gone = seen.subtracting(paths)
                            if !gone.isEmpty { continuation.yield(.removed(Array(gone))) }
                            let fresh = urls.filter { !seen.contains($0.standardizedFileURL.path) }
                            seen = paths
                            let batches = (try? await lanes.perform(on: .unknown, .read) { _ in
                                withNoMaterialization { SearchEntryFactory.batches(fresh, generation: generation, types: types) }
                            }) ?? []
                            for b in batches { continuation.yield(.batch(b)) }
                        case .finished:
                            continuation.yield(.completed(SearchSummary(resultCount: seen.count, elapsed: ContinuousClock.now - start)))
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
```

`SearchEntryFactory.batches(_:generation:types:)` is the Phase 3 helper that turns `lstat` results into `SearchBatch`es grouped by parent (P3-04 crawler). If Phase 3 named it differently, find it with `grep -rn "func batches(" Sources/Core/Search` and call that one. Do not write a second lstat-to-`Entry` converter.

In `SidebarTagsSection`, a click on a row builds `SearchResultsModel(title: tag, events: TagSearchEvents.events(query:tag:scope:lanes:types:), context: searchContext)` and calls `activeSession.showResults(model, recordHistory: true)`. The query is `CrawlTagQuery` with `.directory(options.root!)` when `options.isSandboxed`, otherwise `SpotlightTagQuery()` with `.thisMac`.

Add `testClickingTagShowsResultsInSandboxCrawl` to `SidebarTagsTests`: tag `a.txt` Red, click Red, wait until `window.probeRowNames == ["a.txt"]`, and check that the Path column is shown.

Run: `swift test --filter UITests.SidebarTagsTests 2>&1 | tail -5` → `Executed 4 tests, with 0 failures`.

- [ ] **Step 6: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests
git commit -m "feat: tag queries (Spotlight and sandbox crawl) and sidebar TAGS section with drop-to-tag"
```

### Task P4-07: Custom icons core (`IconImageData`, `WorkspaceIconWriter`, `setCustomIcon` job)

**Files:**
- Create: `Sources/Core/Icons/IconImageData.swift`, `Sources/Core/Platform/WorkspaceIconWriter.swift`, `Sources/Core/FileOps/IconJobs.swift`
- Modify: `Sources/Core/FileOps/JobTypes.swift` (`JobKind.setCustomIcon`, `JobVerb.changingIcon`), `Sources/Core/FileOps/JobRecord.swift` (`ItemAction.customIconChanged`), `Sources/Core/FileOps/JobRunner.swift` (dispatch; `JobContext.iconWriter`), `Sources/Core/FileOps/FileOpQueue.swift` (`iconWriter:` init parameter), `Sources/Core/FileOps/UndoPlanner.swift` (`UndoStep.restoreIcon`), `Sources/Core/Support/CoreEnvironment.swift` (`iconWriter`), `Sources/UI/Support/IconCache.swift` (`invalidate(rowID:)`), the content view controller (invalidate on finished `changingIcon` jobs)
- Test: `Tests/CoreTests/Icons/CustomIconTests.swift`

**Interfaces:**
- Consumes: `FileOpsTestCase`, `JobContext`, `UndoPlanner`, `IconCache` (P1-31), `OperationsCenter.onFinished`, `EntryFlags.customIcon` (S1).
- Produces: §3.4 `IconImageData`, `CustomIconWriting`, `WorkspaceIconWriter`, `JobKind.setCustomIcon`, `JobVerb.changingIcon`, `ItemAction.customIconChanged`, `IconCache.invalidate(rowID:)`. `FileOpQueue.init(lanes:trash:journal:interaction:tuning:iconWriter:)` with `iconWriter: any CustomIconWriting = WorkspaceIconWriter()`.

**How macOS stores custom icons (what `WorkspaceIconWriter` reads back):**
- Files: an `'icns'` resource with ID −16455 in the resource fork (xattr `com.apple.ResourceFork`), plus the `kHasCustomIcon` bit (`0x0400`) in the Finder flags (bytes 8–9, big-endian, of the 32-byte `com.apple.FinderInfo` xattr).
- Folders: a hidden file named `Icon\r` inside the folder carries the resource fork; the folder's FinderInfo has `kHasCustomIcon`.
- `NSWorkspace.setIcon(_:forFile:options:)` writes both and is safe to call off the main thread. Passing `nil` removes the custom icon. `WorkspaceIconWriter` uses it for writing; reading parses the resource fork itself (a small parser), because `NSWorkspace.icon(forFile:)` returns the composed icon, not the stored one.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import Darwin
import ImageIO
import UniformTypeIdentifiers
@testable import Core
import MacxFixtures

/// Records calls; used to test job and undo logic without touching icons.
final class FakeIconWriter: CustomIconWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var icons: [String: IconImageData] = [:]
    var failing: [String: Int32] = [:]
    func currentCustomIcon(_ url: URL) throws -> IconImageData? { lock.withLock { icons[url.path] } }
    func setIcon(_ data: IconImageData?, for url: URL) throws {
        try lock.withLock {
            if let code = failing[url.path] { throw TagIOError(code: code) }
            icons[url.path] = data
        }
    }
}

enum TestImages {
    /// A solid-colour PNG, built in memory.
    static func png(size: Int = 64, red: CGFloat = 1) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: red, green: 0.2, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

final class CustomIconTests: FileOpsTestCase {
    func testImageDataValidation() {
        XCTAssertTrue(IconImageData(bytes: TestImages.png()).isDecodableImage)
        XCTAssertFalse(IconImageData(bytes: Data("not an image".utf8)).isDecodableImage)
        XCTAssertEqual(IconImageData.maxBytes, 10 * 1024 * 1024)
    }
    func testWorkspaceWriterSetsReadsAndRemovesOnFileAndFolder() async throws {
        let f = try file("a.txt"), d = try dir("Folder")
        let writer = WorkspaceIconWriter()
        try await LanePool().perform(on: .unknown, .fileOp) { _ in
            XCTAssertNil(try writer.currentCustomIcon(f))
            try writer.setIcon(IconImageData(bytes: TestImages.png()), for: f)
            try writer.setIcon(IconImageData(bytes: TestImages.png()), for: d)
            XCTAssertEqual(try writer.currentCustomIcon(f)?.isDecodableImage, true)
            XCTAssertEqual(try writer.currentCustomIcon(d)?.isDecodableImage, true)
        }
        XCTAssertTrue(exists(d.appending(path: "Icon\r")))
        XCTAssertTrue(Self.hasCustomIconFlag(f.path)); XCTAssertTrue(Self.hasCustomIconFlag(d.path))
        try await LanePool().perform(on: .unknown, .fileOp) { _ in
            try writer.setIcon(nil, for: f); try writer.setIcon(nil, for: d)
            XCTAssertNil(try writer.currentCustomIcon(f)); XCTAssertNil(try writer.currentCustomIcon(d))
        }
        XCTAssertFalse(Self.hasCustomIconFlag(f.path)); XCTAssertFalse(exists(d.appending(path: "Icon\r")))
    }
    func testJobRecordsPreviousAndUndoRestoresIt() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let fake = FakeIconWriter()
        let old = IconImageData(bytes: TestImages.png(red: 0.1)), new = IconImageData(bytes: TestImages.png(red: 0.9))
        try fake.setIcon(old, for: a)
        let queue = FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                                interaction: ScriptedInteraction(), iconWriter: fake)
        let outcome = try await run(.setCustomIcon([a, b], new), on: queue)
        XCTAssertEqual(outcome.record.verb, .changingIcon)
        XCTAssertEqual(outcome.record.actions, [.customIconChanged(a, previous: old, new: new), .customIconChanged(b, previous: nil, new: new)])
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(try fake.currentCustomIcon(a), old); XCTAssertNil(try fake.currentCustomIcon(b))
        _ = try await run(.redo(undo.record), on: queue)
        XCTAssertEqual(try fake.currentCustomIcon(b), new)
    }
    func testUndoSkipsItemWhoseIconChangedSince() async throws {
        let a = try file("a.txt")
        let fake = FakeIconWriter()
        let queue = FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                                interaction: ScriptedInteraction(), iconWriter: fake)
        let outcome = try await run(.setCustomIcon([a], IconImageData(bytes: TestImages.png())), on: queue)
        try fake.setIcon(IconImageData(bytes: TestImages.png(red: 0.5)), for: a)
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(undo.skipped.map(\.reason), [.changedDuringMove])
    }
    func testRejectsUndecodableOrOversizeDataBeforeTouchingFiles() async throws {
        let a = try file("a.txt")
        let fake = FakeIconWriter()
        let interaction = ScriptedInteraction(errors: [.skip])
        let queue = FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                                interaction: interaction, iconWriter: fake)
        let outcome = try await run(.setCustomIcon([a], IconImageData(bytes: Data("x".utf8))), on: queue)
        XCTAssertTrue(outcome.record.actions.isEmpty)
        XCTAssertEqual(interaction.askedErrors().first?.kind, .other(code: EINVAL, message: "not an image"))
        XCTAssertNil(try fake.currentCustomIcon(a))
    }
    func testLockedFileIsAskedAbout() async throws {
        let a = try file("a.txt")
        let fake = FakeIconWriter(); fake.failing[a.path] = EPERM
        let interaction = ScriptedInteraction(errors: [.skip])
        let queue = FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                                interaction: interaction, iconWriter: fake)
        let outcome = try await run(.setCustomIcon([a], IconImageData(bytes: TestImages.png())), on: queue)
        XCTAssertEqual(outcome.skipped.map(\.url), [a])
    }

    static func hasCustomIconFlag(_ path: String) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(path, "com.apple.FinderInfo", &info, 32, 0, XATTR_NOFOLLOW) == 32 else { return false }
        return (UInt16(info[8]) << 8 | UInt16(info[9])) & 0x0400 != 0
    }
}
```

`TagIOError` is reused by the fake only as "some error carrying an errno". The job reads the errno through `(error as? any ErrnoCarrying)?.errnoCode ?? EIO`; add a tiny internal `protocol ErrnoCarrying { var errnoCode: Int32 { get } }` in `Sources/Core/FileOps/FileOpError.swift`. `TagIOError`, `ACLIOError` (P4-14) and `IconWriteError` conform with `var errnoCode: Int32 { code }`.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.CustomIconTests 2>&1 | tail -5`
Expected: build failure, `cannot find type 'CustomIconWriting' in scope`.

- [ ] **Step 3: Implement**

`IconImageData.swift`:

```swift
import Foundation
import ImageIO

public struct IconImageData: Sendable, Codable, Equatable {
    public var bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
    public static let maxBytes = 10 * 1024 * 1024
    public var isDecodableImage: Bool {
        guard bytes.count <= Self.maxBytes, let src = CGImageSourceCreateWithData(bytes as CFData, nil) else { return false }
        return CGImageSourceGetCount(src) > 0
    }
}
public protocol CustomIconWriting: Sendable {
    func currentCustomIcon(_ url: URL) throws -> IconImageData?
    func setIcon(_ data: IconImageData?, for url: URL) throws
}
```

`WorkspaceIconWriter.swift` (in `Core/Platform`, so it may import AppKit):

```swift
import AppKit
import Darwin
import MacxFS

struct IconWriteError: Error, Sendable, Equatable, ErrnoCarrying { var code: Int32; var errnoCode: Int32 { code } }

public struct WorkspaceIconWriter: CustomIconWriting {
    public init() {}
    static let customIconBit: UInt16 = 0x0400

    public func currentCustomIcon(_ url: URL) throws -> IconImageData? {
        assertOffMain()
        guard Self.finderFlags(url.path) & Self.customIconBit != 0 else { return nil }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let carrier = isDir ? url.appending(path: "Icon\r").path : url.path
        guard let fork = Self.xattr(carrier, "com.apple.ResourceFork"), let icns = ResourceFork.resource(type: "icns", id: -16455, in: fork)
        else { return nil }
        return IconImageData(bytes: icns)
    }
    public func setIcon(_ data: IconImageData?, for url: URL) throws {
        assertOffMain()
        guard FileManager.default.fileExists(atPath: url.path) else { throw IconWriteError(code: ENOENT) }
        let image = data.flatMap { NSImage(data: $0.bytes) }
        if data != nil && image == nil { throw IconWriteError(code: EINVAL) }
        guard NSWorkspace.shared.setIcon(image, forFile: url.path, options: []) else {
            // setIcon reports only Bool; recover the cause the way Finder would hit it.
            var st = stat()
            if lstat(url.path, &st) == 0, st.st_flags & UInt32(UF_IMMUTABLE) != 0 { throw IconWriteError(code: EPERM) }
            throw IconWriteError(code: access(url.path, W_OK) == 0 ? EIO : EACCES)
        }
    }
    static func finderFlags(_ path: String) -> UInt16 {
        guard let d = xattr(path, "com.apple.FinderInfo"), d.count >= 10 else { return 0 }
        return UInt16(d[8]) << 8 | UInt16(d[9])
    }
    static func xattr(_ path: String, _ name: String) -> Data? {
        let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        var b = [UInt8](repeating: 0, count: n)
        return getxattr(path, name, &b, n, 0, XATTR_NOFOLLOW) == n ? Data(b) : nil
    }
}

/// Minimal classic resource-fork reader (Inside Macintosh: More Toolbox, "Resource Manager").
enum ResourceFork {
    static func resource(type: String, id: Int16, in fork: Data) -> Data? {
        func u32(_ o: Int) -> Int? { o + 4 <= fork.count ? Int(fork[o]) << 24 | Int(fork[o+1]) << 16 | Int(fork[o+2]) << 8 | Int(fork[o+3]) : nil }
        func u16(_ o: Int) -> Int? { o + 2 <= fork.count ? Int(fork[o]) << 8 | Int(fork[o+1]) : nil }
        guard let dataOffset = u32(0), let mapOffset = u32(4),
              let typeListOffset = u16(mapOffset + 24), let typeCountMinus1 = u16(mapOffset + 28) else { return nil }
        let typeList = mapOffset + typeListOffset
        let wanted = Array(type.utf8)
        for t in 0...typeCountMinus1 {
            let entry = typeList + 2 + t * 8
            guard entry + 8 <= fork.count else { return nil }
            guard Array(fork[entry..<entry + 4]) == wanted, let countMinus1 = u16(entry + 4), let refOffset = u16(entry + 6) else { continue }
            for r in 0...countMinus1 {
                let ref = typeList + refOffset + r * 12
                guard let rid = u16(ref), let attrsAndOffset = u32(ref + 4) else { return nil }
                guard Int16(truncatingIfNeeded: rid) == id else { continue }
                let start = dataOffset + (attrsAndOffset & 0x00FF_FFFF)
                guard let length = u32(start), start + 4 + length <= fork.count else { return nil }
                return fork.subdata(in: start + 4 ..< start + 4 + length)
            }
        }
        return nil
    }
}
```

`IconJobs.swift`:

```swift
import Foundation
import Darwin

enum IconJobs {
    static func setCustomIcon(_ ctx: JobContext, _ urls: [URL], _ data: IconImageData?) async {
        ctx.setTotals(items: urls.count, bytes: 0)
        ctx.setState(.running)
        if let data, !data.isDecodableImage {
            _ = await ctx.askError(FileOpError(kind: .other(code: EINVAL, message: "not an image"), url: urls.first ?? URL(filePath: "/")))
            for u in urls { ctx.skip(u, reason: .other(code: EINVAL, message: "not an image")) }
            return
        }
        let writer = ctx.iconWriter
        items: for url in urls {
            guard await ctx.checkpoint() else { break }
            while true {
                let r = (try? await ctx.onLane { _ -> (Int32, IconImageData?) in
                    do {
                        let previous = try writer.currentCustomIcon(url)
                        try writer.setIcon(data, for: url)
                        return (0, previous)
                    } catch { return ((error as? any ErrnoCarrying)?.errnoCode ?? EIO, nil) }
                }) ?? (EIO, nil)
                if r.0 == 0 {
                    if r.1 != data { ctx.record(.customIconChanged(url, previous: r.1, new: data)) }
                    ctx.noteModified(url)
                    ctx.addProgress(items: 1, current: url.lastPathComponent)
                    continue items
                }
                switch await ctx.resolveFailure(r.0, url: url) {
                case .retry: continue
                case .skipped: continue items
                case .cancelled: return
                }
            }
        }
    }
}
```

`FileOpQueue` stores `iconWriter` and passes it into each `JobContext` (new stored property `let iconWriter: any CustomIconWriting`). `JobRecord` is persisted only in memory (undo stack), so `IconImageData` inside actions never reaches the journal.

`UndoPlanner`: `.customIconChanged(u, previous, new)` → `.restoreIcon(u, expected: new, restore: previous)`. Execution compares `writer.currentCustomIcon(u)` with `expected` by byte equality (the writer round-trips exactly what it stored for ICNS input; for PNG input `NSWorkspace` converts to ICNS, so the comparison uses `IconCompare.sameImage(_:_:)`, which decodes both and compares a 32×32 rasterization). Mismatch → skip `.changedDuringMove`; success records `.customIconChanged(u, previous: expected, new: restore)`.

Add `IconCompare.sameImage` (internal, `IconImageData.swift`): equal bytes → true; otherwise draw both into a 32×32 sRGB bitmap and compare the bytes. The undo test above uses the fake (exact bytes); the workspace test only checks presence.

`CoreEnvironment`: `iconWriter: any CustomIconWriting` (live and sandboxed: `WorkspaceIconWriter()`); pass it to `FileOpQueue`.

`IconCache.invalidate(rowID:)` removes every `fileImages` key with that `id` and cancels a pending request for it. The content view controller subscribes to `operations.onFinished`. For a finished `.changingIcon` job it maps each action's URL to a row in the current folder (`folder.row(named:)` when the parent matches) and calls `invalidate(rowID:)`, then reloads those rows. The next directory read refreshes `EntryFlags.customIcon`, so Tier 1 eligibility follows (S5 `needsFileIcon`).

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "CoreTests.CustomIconTests|CoreTests.UndoPlannerTests|UITests.IconCacheTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 5: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests/CoreTests/Icons
git commit -m "feat: undoable custom icon job via NSWorkspace with resource-fork read-back and Tier 1 invalidation"
```

### Task P4-08: Custom icons UI and icon packs

**Files:**
- Create: `Sources/UI/Properties/IconWell.swift`, `Sources/Core/Icons/IconPack.swift`
- Modify: `Sources/Core/Properties/ItemProperties.swift` (`hasCustomIcon`), `Sources/Core/Properties/PropertiesLoader.swift` (fill it from FinderInfo), `Sources/UI/Properties/PropertiesView.swift` and `PropertiesViewModel.swift` (icon well), `Sources/FSKit/Store/TypeRegistry.swift` (`extensionString(at:)`), `Sources/UI/Support/IconCache.swift` (`setIconPack`, pack lookup in `typeIcon`), `Sources/Core/Settings/Settings.swift` (`iconPackBookmark`), `Sources/UI/Settings/GeneralSettingsView.swift` (chooser), `Sources/App/AppBootstrap.swift` (load the pack at launch)
- Test: `Tests/CoreTests/Icons/IconPackTests.swift`, `Tests/UITests/IconWellTests.swift`

**Interfaces:**
- Consumes: P4-07 (`IconImageData`, `JobKind.setCustomIcon`), `PropertiesViewModel` (P1-37), `TypeRegistry` (S1), `IconCache` (P1-31), `LanePool`.
- Produces: §3.4 `IconPack`, `IconPackLoader`, `TypeRegistry.extensionString(at:)`, `IconCache.setIconPack(_:) async`, `Settings.iconPackBookmark`, `ItemProperties.hasCustomIcon: Bool`. UI: `IconWell` (`NSView`, internal) with `onDropImage: (IconImageData) -> Void`, `onRemove: () -> Void`, `var image: NSImage?`, `var showsRemove: Bool`; `PropertiesViewModel.setCustomIcon(_ data: IconImageData?) async`.

**Icon pack format** (documented in `docs/icon-packs.md`, created here; a few lines): a folder containing `<extension>.<fmt>` files, for example `pdf.icns`, `swift.png`, `md.pdf`, plus optionally `folder.<fmt>`. `<fmt>` is one of `IconPack.formatPriority`; when several exist for one extension, the earliest in the list wins. Names are matched case-insensitively. Subfolders, dotfiles and files over 1 MiB are ignored; at most 2,000 entries are loaded. Packs replace Tier 0 type icons only. Tier 1 icons (apps, custom icons, volumes) are unchanged.

- [ ] **Step 1: Write the failing pack tests**

```swift
import XCTest
@testable import Core
@testable import MacxFS
import MacxFixtures

final class IconPackTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    func testLoaderPicksPriorityFormatAndIgnoresNoise() async throws {
        let png = TestImages.png()
        for name in ["pdf.png", "PDF.icns", "swift.png", "folder.png", ".hidden.png", "readme.txt"] {
            try sandbox.createFile("pack/\(name)", contents: png)
        }
        try sandbox.createFile("pack/sub/zip.png", contents: png)
        try sandbox.createFile("pack/big.png", contents: Data(count: 1_048_577))
        let pack = try await IconPackLoader.load(sandbox.url("pack"), lanes: LanePool())
        XCTAssertEqual(Set(pack.byExtension.keys), ["pdf", "swift"])
        XCTAssertEqual(pack.byExtension["pdf"]?.lastPathComponent, "PDF.icns")
        XCTAssertEqual(pack.folderIcon?.lastPathComponent, "folder.png")
    }
    func testLoaderRejectsNonDirectory() async throws {
        let f = try sandbox.createFile("notapack.png")
        do { _ = try await IconPackLoader.load(f, lanes: LanePool()); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? IconPackError, .notAFolder) }
    }
    func testExtensionStringForTypeIndex() {
        let types = TypeRegistry()
        let i = types.index(forExtension: "PDF", isDirectory: false)
        XCTAssertEqual(types.extensionString(at: i), "pdf")
        XCTAssertNil(types.extensionString(at: TypeRegistry.folderIndex))
    }
}
```

`TestImages` lives in `CustomIconTests.swift` (same test target).

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.IconPackTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'IconPackLoader' in scope`.

- [ ] **Step 3: Implement the loader and the registry lookup**

```swift
import Foundation
import MacxFS

public enum IconPackError: Error, Sendable, Equatable { case notAFolder, unreadable(Int32) }

public struct IconPack: Sendable, Equatable {
    public var folder: URL
    public var byExtension: [String: URL]
    public var folderIcon: URL?
    public static let formatPriority = ["icns", "png", "pdf", "tiff", "jpg"]
    static let maxFileBytes = 1 << 20
    static let maxEntries = 2_000
}

public enum IconPackLoader {
    public static func load(_ folder: URL, lanes: LanePool) async throws -> IconPack {
        try await lanes.perform(on: .unknown, .read) { _ in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw IconPackError.notAFolder }
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) }
            catch { throw IconPackError.unreadable((error as NSError).code == NSFileReadNoPermissionError ? EACCES : EIO) }
            var best: [String: (rank: Int, url: URL)] = [:]
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = folder.appending(path: name)
                let fmt = (name as NSString).pathExtension.lowercased()
                guard let rank = IconPack.formatPriority.firstIndex(of: fmt) else { continue }
                var st = stat()
                guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= IconPack.maxFileBytes else { continue }
                let key = (name as NSString).deletingPathExtension.lowercased()
                guard !key.isEmpty, !key.contains(".") else { continue }
                if let current = best[key], current.rank <= rank { continue }
                best[key] = (rank, url)
                if best.count >= IconPack.maxEntries + 1 { break }
            }
            let folderIcon = best.removeValue(forKey: "folder")?.url
            return IconPack(folder: folder, byExtension: best.mapValues(\.url), folderIcon: folderIcon)
        }
    }
}
```

`TypeRegistry.extensionString(at:)` returns the lowercased extension the registry interned for that index, or nil for `folderIndex`, the data type and the symlink type. S1's registry already stores the extension per index for `index(forExtension:)`; expose it under the registry's lock.

Run: `swift test --filter CoreTests.IconPackTests 2>&1 | tail -5` → `Executed 3 tests, with 0 failures`.

- [ ] **Step 4: Write the failing UI tests**

```swift
import XCTest
import AppKit
@testable import UI
@testable import Core

@MainActor final class IconWellTests: XCTestCase {
    func testDropImageFileRunsJobAndRemoveRestores() async throws {
        let ui = try await ContentTestHarness.make(self)
        let target = try ui.file("a.txt")
        let imageFile = try ui.file("icon.png", contents: TestImagesUI.png())
        let model = PropertiesViewModel(urls: [target], context: ui.context)
        try await ui.waitUntil("loaded") { model.properties != nil }
        XCTAssertEqual(model.properties?.hasCustomIcon, false)
        let well = IconWell(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        well.onDropImage = { data in Task { await model.setCustomIcon(data) } }
        XCTAssertTrue(well.acceptFileURLs([imageFile]))
        try await ui.waitUntil("custom icon set") { model.properties?.hasCustomIcon == true }
        await model.setCustomIcon(nil)
        try await ui.waitUntil("custom icon removed") { model.properties?.hasCustomIcon == false }
        XCTAssertTrue(ui.context.environment.undo.canUndo)
    }
    func testWellRefusesNonImagesAndHugeFiles() async throws {
        let ui = try await ContentTestHarness.make(self)
        let text = try ui.file("t.txt")
        let well = IconWell(frame: .zero)
        var dropped = 0
        well.onDropImage = { _ in dropped += 1 }
        XCTAssertFalse(well.acceptFileURLs([text]))
        XCTAssertEqual(dropped, 0)
    }
    func testPasteFromPrivatePasteboard() async throws {
        let ui = try await ContentTestHarness.make(self)
        let pb = NSPasteboard(name: NSPasteboard.Name("macx-tests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setData(TestImagesUI.png(), forType: .png)
        let well = IconWell(frame: .zero)
        var got: IconImageData?
        well.onDropImage = { got = $0 }
        XCTAssertTrue(well.paste(from: pb))
        XCTAssertEqual(got?.isDecodableImage, true)
    }
    func testIconPackOverridesTypeIconAfterLoad() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("pack/pdf.png", contents: TestImagesUI.png(red: 0))     // a distinctive colour
        let pack = try await IconPackLoader.load(ui.url("pack"), lanes: ui.context.environment.lanes)
        let types = ui.context.environment.types
        let pdf = types.index(forExtension: "pdf", isDirectory: false)
        let before = ui.context.icons.typeIcon(pdf, points: 32, scale: 2)
        await ui.context.icons.setIconPack(pack)
        let after = ui.context.icons.typeIcon(pdf, points: 32, scale: 2)
        XCTAssertFalse(before === after)
        XCTAssertEqual(after.width, 64)
        await ui.context.icons.setIconPack(nil)
        XCTAssertFalse(ui.context.icons.typeIcon(pdf, points: 32, scale: 2) === after)
    }
}
```

`TestImagesUI.png` is a copy of `TestImages.png` in `Tests/UITests/Support/TestImagesUI.swift` (test targets can't share files). `ui.file(_:contents:)` is the harness overload with data; if S5's harness lacks it, add it (it wraps `sandbox.createFile`). `acceptFileURLs(_:)` and `paste(from:)` are the internal entry points the drag (`performDragOperation`) and `paste(_:)` responder paths call.

- [ ] **Step 5: Run to verify they fail**

Run: `swift test --filter UITests.IconWellTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'IconWell' in scope`.

- [ ] **Step 6: Implement the well, Properties wiring, pack lookup and Settings**

`IconWell` (`NSView`, 64 × 64 pt, `registerForDraggedTypes([.fileURL, .png, .tiff])`, focus ring, accepts first responder):
- `acceptFileURLs(urls)`: takes the first URL, reads it on a lane (`lanes.perform(on: .unknown, .read)`), refuses files over `IconImageData.maxBytes` or not decodable, then calls `onDropImage`. It returns true when the URL has an image extension or `.icns` (synchronous answer for drag validation); the async read decides whether `onDropImage` fires. For an app or folder URL (Finder "paste the icon of another item"), use `NSWorkspace.shared.icon(forFile:)` → TIFF data instead.
- `paste(from:)` reads `.png`, then `.tiff`, then a file URL from the pasteboard. `paste(_:)` uses `NSPasteboard.general` in normal mode and the private pasteboard name from `LaunchOptions.pasteboardName` in sandbox mode.
- `copy(_:)` writes the current image as TIFF. `delete(_:)` and the Remove button call `onRemove`.
- `image` shows the item's icon from `IconCache` Tier 1 at 64 pt; it is refreshed after the job finishes.

`PropertiesView`: the General header's icon becomes `IconWell` (wrapped in `NSViewRepresentable`) for single selections whose volume is writable. A "Remove Custom Icon" button below it is shown when `hasCustomIcon`. Multi-selection: dropping applies to all selected URLs (one job).

`PropertiesViewModel.setCustomIcon(_:)` performs `JobRequest(.setCustomIcon(urls, data), origin: originForProperties)` through `OperationsCenter.perform`, then reloads properties.

`PropertiesLoader`: `hasCustomIcon = WorkspaceIconWriter.finderFlags(path) & customIconBit != 0` (lane; it already runs there).

`IconCache`:
- `setIconPack(_ pack: IconPack?) async` drops `typeImages`. For a non-nil pack, it rasterizes every pack image at 16, 32, 64, 128 and 256 px on a lane (`lanes.perform(on: .unknown, .read)` using `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`, or `NSImage(contentsOf:)` for PDF and ICNS). It stores them in `packImages: [String: [Int: CGImage]]` and only then switches `currentPack`, so the first frame afterwards has every image.
- `typeIcon(_:points:scale:)`: if `currentPack` is set and `types.extensionString(at:)` (or the folder index → `folderIcon`) has an entry, return the nearest rasterized size ≥ the requested pixels (scaled down with `CGContext` once and cached per pixel size). Otherwise use the Phase 1 path.
- Every visible view reloads after `setIconPack` (post a `.iconPackChanged` notification that content views observe).

`Settings.iconPackBookmark: Data?` (key `"iconPackBookmark"`). `GeneralSettingsView`: "Icon pack:" with a popup (None / Choose Folder… / the current pack's folder name). Choosing runs an `NSOpenPanel` (directories only), creates a bookmark (`url.bookmarkData(options: [])`), loads the pack and calls `setIconPack`. On error, an inline red message shows "That folder isn't an icon pack." `AppBootstrap` resolves the bookmark at launch. In sandbox mode it ignores `iconPackBookmark` unless the resolved URL is inside `--root`.

- [ ] **Step 7: Run all icon tests**

Run: `swift test --filter "CoreTests.IconPackTests|CoreTests.CustomIconTests|UITests.IconWellTests|UITests.IconCacheTests|UITests.PropertiesViewModelTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 8: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests docs/icon-packs.md
git commit -m "feat: Properties icon well (drop, paste, remove) and icon packs replacing Tier 0 type icons"
```

### Task P4-09: Compress (`ArchiveFormat`, `ProcessRunner`, `compress` job)

**Files:**
- Create: `Sources/Core/Archive/ArchiveFormat.swift`, `Sources/Core/Archive/ProcessRunner.swift`, `Sources/Core/Archive/CompressJob.swift`
- Modify: `Sources/Core/FileOps/JobTypes.swift` (`JobKind.compress`, `JobVerb.compressing`), `Sources/Core/FileOps/JobRunner.swift` (dispatch), `Sources/Core/FileOps/FaultPoint.swift` (`archiveToolStarted`), `Sources/Core/FileOps/FileOpQueue.swift` (internal `FileOpTuning.toolOverride`), `Sources/Core/Commands/CommandAvailability.swift` (`.compressZip`, `.compressAppleArchive` shipped), `Sources/UI/Menus/ContextMenuBuilder.swift` (Compress ▸), `Sources/UI/Commands/FileCommandController.swift` (handlers), `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/CoreTests/Archive/CompressTests.swift`

**Interfaces:**
- Consumes: `FileOpsTestCase`, `JobContext` (`onLane`, `journal`, `record`, `landed`, `control`, `tuning`, `plan`), `Planner.plan(... mode: .enumerate(noMaterialization: true))` for totals, `NameGenerator` (P1-19), `PosixFS`, `Journal` `.partial` entries and `LaunchRecovery` (Phase 1 removes partials).
- Produces: §3.5 `ArchiveFormat`, `ProcessOutput`, `ProcessResult`, `ProcessRunner`, `JobKind.compress`, `JobVerb.compressing`, `FaultPoint.archiveToolStarted`. Internal: `ArchiveNaming.outputName(for sources: [URL], format: ArchiveFormat) -> String`, `FileOpTuning.toolOverride: (@Sendable (String) -> String)?` (maps a tool path to a replacement; tests only).

**Behaviour:**
- Output name: one source `x` → `x.zip` / `x.aar` (Finder keeps the source's extension: `a.txt.zip`). Several sources → `Archive.zip` / `Archive.aar`. If the name is taken, `NameGenerator.keepBoth` picks `Archive 2.zip`, `Archive 3.zip`, …
- The archive is written to `<parent>/.macx-partial-<UUID>.<ext>` (journaled as `.partial` before the tool starts) and renamed to the final name with `renamex_np(RENAME_EXCL)`. On `EEXIST` (a race) the next free name is tried. The job records `.created(final, identity)`, so undo moves the archive to the Trash.
- Single source + zip: `ditto -c -k --sequesterRsrc --keepParent -V <source> <partial>`.
- Otherwise the sources are staged in `<parent>/.macx-staging-<UUID>/` (journaled as `.partial`; `LaunchRecovery` removes it) with `copyfile(COPYFILE_CLONE | COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC)`. On APFS each clone is O(1) and uses no extra space; elsewhere it copies. Then zip: `ditto -c -k --sequesterRsrc -V <staging> <partial>` (entries at top level, as Finder does); aar: `aa archive -d <staging> -o <partial> -a lzfse -v`.
- Progress: totals come from the planner (items and bytes). Every stderr line from `-V`/`-v` counts as one item done. Bytes done are estimated as `itemsDone / itemsTotal × bytesTotal`.
- Pause sends `SIGSTOP`, resume `SIGCONT`. Cancel sends `SIGTERM` (then `SIGKILL` after 2 s), removes the partial and the staging directory, clears the journal entries and finishes with `wasCancelled`.
- A non-zero tool exit is reported as `FileOpError(kind: .other(code: EIO, message: <stderr tail, last line>), url: firstSource)` with Retry/Skip/Cancel. ENOSPC in stderr ("No space left on device") maps to `.noSpace(needed: nil, available: nil)`.
- Sources on different parents (possible from search results): the archive goes into the first source's parent.

- [ ] **Step 1: Write the failing tests (Review Focus 4, compress half)**

```swift
import XCTest
import Darwin
@testable import Core
import MacxFixtures

final class CompressTests: FileOpsTestCase {
    private func unzipList(_ zip: URL) throws -> [String] {
        let out = try ProcessRunnerTestTool.run("/usr/bin/zipinfo", ["-1", zip.path])
        return out.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("__MACOSX") }.sorted()
    }

    func testFormatDetectionAndNaming() {
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.ZIP"), .zip)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.tar.gz"), .tarGzip)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.tgz"), .tarGzip)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.tbz2"), .tarBzip2)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.txz"), .tarXz)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.gz"), .gzip)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.aar"), .appleArchive)
        XCTAssertNil(ArchiveFormat.detect(byName: "a.rar"))
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x50, 0x4B, 0x03, 0x04]), name: "a.bin"), .zip)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x1F, 0x8B, 0x08]), name: "a.tar.gz"), .tarGzip)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x1F, 0x8B, 0x08]), name: "notes.gz"), .gzip)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data("AA01".utf8), name: "x"), .appleArchive)
        XCTAssertEqual(ArchiveFormat.baseName(stripping: "photos.tar.gz"), "photos")
        XCTAssertEqual(ArchiveFormat.baseName(stripping: "a.b.zip"), "a.b")
        XCTAssertEqual(ArchiveNaming.outputName(for: [url("a.txt")], format: .zip), "a.txt.zip")
        XCTAssertEqual(ArchiveNaming.outputName(for: [url("a"), url("b")], format: .appleArchive), "Archive.aar")
        XCTAssertTrue(ArchiveFormat.zip.canCreate); XCTAssertFalse(ArchiveFormat.tarGzip.canCreate)
    }
    func testProcessRunnerCapturesAndCancels() async throws {
        let r = try await LanePool().perform(on: .unknown, .fileOp) { lane in
            try ProcessRunner.run("/bin/echo", ["hi"], output: .capture, context: lane, isPaused: { false }, onStderrLine: { _ in })
        }
        XCTAssertEqual(r.status, 0); XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "hi\n")
        let task = Task {
            try await LanePool().perform(on: .unknown, .fileOp) { lane in
                try ProcessRunner.run("/bin/sleep", ["30"], context: lane, isPaused: { false }, onStderrLine: { _ in })
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let start = ContinuousClock.now
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertEqual(error as? LaneError, .cancelled) }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
    }
    func testProcessRunnerFileOutputIsExclusive() async throws {
        let existing = try file("out.txt")
        do {
            _ = try await LanePool().perform(on: .unknown, .fileOp) { lane in
                try ProcessRunner.run("/bin/echo", ["x"], output: .file(existing), context: lane, isPaused: { false }, onStderrLine: { _ in })
            }
            XCTFail("expected EEXIST")
        } catch { XCTAssertEqual((error as? ProcessRunnerError)?.code, EEXIST) }
        XCTAssertEqual(text(existing), "x")
    }
    func testCompressSingleFolderZip() async throws {
        try file("photos/a.jpg"); try file("photos/sub/b.jpg")
        let (queue, journal) = makeQueue()
        let outcome = try await run(.compress([url("photos")], .zip), on: queue)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["photos.zip"])
        XCTAssertEqual(try unzipList(url("photos.zip")), ["photos/", "photos/a.jpg", "photos/sub/", "photos/sub/b.jpg"])
        XCTAssertEqual(names(root).filter { $0.hasPrefix(".macx-") }, [])
        XCTAssertTrue(await journal.entries().isEmpty)
        XCTAssertEqual(outcome.record.verb, .compressing)
    }
    func testCompressMultipleItemsPutsThemAtTopLevelAndAppleArchiveRoundTrips() async throws {
        try file("a.txt", "A"); try file("b.txt", "B")
        let (queue, _) = makeQueue()
        _ = try await run(.compress([url("a.txt"), url("b.txt")], .zip), on: queue)
        XCTAssertEqual(try unzipList(url("Archive.zip")), ["a.txt", "b.txt"])
        _ = try await run(.compress([url("a.txt"), url("b.txt")], .appleArchive), on: queue)
        try dir("check")
        _ = try ProcessRunnerTestTool.run("/usr/bin/aa", ["extract", "-i", url("Archive.aar").path, "-d", url("check").path])
        XCTAssertEqual(text(url("check/a.txt")), "A"); XCTAssertEqual(text(url("check/b.txt")), "B")
    }
    func testCompressNamesNextFreeAndCancelLeavesNothing() async throws {
        try file("a.txt"); try file("b.txt"); try file("Archive.zip", "taken"); try file("Archive 2.zip", "taken")
        let (queue, journal) = makeQueue()
        let outcome = try await run(.compress([url("a.txt"), url("b.txt")], .zip), on: queue)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["Archive 3.zip"])
        XCTAssertEqual(text(url("Archive.zip")), "taken")

        try bigFile("big/blob1", bytes: 48 << 20); try bigFile("big/blob2", bytes: 48 << 20)
        let started = expectation(description: "tool started")
        let holder = QueueHolder()
        var tuning = FileOpTuning(faultHook: { point, id in
            if point == .archiveToolStarted { started.fulfill(); Task { await holder.queue?.cancel(id) } }
        })
        let (q2, j2) = makeQueue(tuning: tuning)
        holder.queue = q2
        let cancelled = try await run(.compress([url("big")], .zip), on: q2)
        await fulfillment(of: [started], timeout: 10)
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertFalse(exists(url("big.zip")))
        XCTAssertEqual(names(root).filter { $0.hasPrefix(".macx-") }, [])
        XCTAssertTrue(await j2.entries().isEmpty); XCTAssertTrue(await journal.entries().isEmpty)
    }
    func testUndoTrashesTheArchive() async throws {
        try file("a.txt")
        let (queue, _) = makeQueue()
        let outcome = try await run(.compress([url("a.txt")], .zip), on: queue)
        _ = try await run(.undo(outcome.record), on: queue)
        XCTAssertFalse(exists(url("a.txt.zip"))); XCTAssertTrue(exists(url("a.txt")))
    }
    func testToolFailureIsAskedAndSkipLeavesNoPartial() async throws {
        try file("a.txt")
        var tuning = FileOpTuning(); tuning.toolOverride = { _ in "/usr/bin/false" }
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction, tuning: tuning)
        let outcome = try await run(.compress([url("a.txt")], .zip), on: queue)
        XCTAssertEqual(interaction.askedErrors().count, 1)
        XCTAssertTrue(outcome.created.isEmpty)
        XCTAssertEqual(names(root).filter { $0.hasPrefix(".macx-") }, [])
    }
}

/// Tiny synchronous runner for checking results in tests (not lane code; harness I/O rule).
enum ProcessRunnerTestTool {
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(filePath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
final class QueueHolder: @unchecked Sendable { var queue: FileOpQueue? }
```

The cancel half uses two 48 MiB incompressible files so `ditto` is still running when the fault hook's `cancel` arrives. If a fast machine finishes first, the test fails on `wasCancelled`; raise the sizes rather than adding sleeps.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.CompressTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'ArchiveFormat' in scope`.

- [ ] **Step 3: Implement `ArchiveFormat` and `ProcessRunner`**

```swift
// ArchiveFormat.swift
import Foundation

public enum ArchiveFormat: String, Sendable, Codable, CaseIterable {
    case zip, appleArchive, tar, tarGzip, tarBzip2, tarXz, gzip
    public var canCreate: Bool { self == .zip || self == .appleArchive }
    static let suffixes: [(String, ArchiveFormat)] = [
        (".tar.gz", .tarGzip), (".tgz", .tarGzip), (".tar.bz2", .tarBzip2), (".tbz2", .tarBzip2), (".tbz", .tarBzip2),
        (".tar.xz", .tarXz), (".txz", .tarXz), (".tar", .tar), (".zip", .zip), (".aar", .appleArchive), (".gz", .gzip),
    ]
    public static func detect(byName name: String) -> ArchiveFormat? {
        let lower = name.lowercased()
        return suffixes.first { lower.hasSuffix($0.0) && lower.count > $0.0.count }?.1
    }
    public static func detect(magic: Data, name: String) -> ArchiveFormat? {
        let b = [UInt8](magic.prefix(512))
        func starts(_ p: [UInt8]) -> Bool { b.count >= p.count && Array(b[0..<p.count]) == p }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if starts(Array("AA01".utf8)) || starts(Array("YAA1".utf8)) || starts(Array("pbz".utf8)) { return .appleArchive }
        if starts([0x1F, 0x8B]) { return detect(byName: name) == .gzip ? .gzip : .tarGzip }
        if starts(Array("BZh".utf8)) { return .tarBzip2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .tarXz }
        if b.count >= 262, Array(b[257..<262]) == Array("ustar".utf8) { return .tar }
        return nil
    }
    public static func baseName(stripping name: String) -> String {
        let lower = name.lowercased()
        guard let s = suffixes.first(where: { lower.hasSuffix($0.0) && lower.count > $0.0.count }) else { return name }
        return String(name.dropLast(s.0.count))
    }
    var fileExtension: String { self == .zip ? "zip" : "aar" }   // creatable formats only
}

enum ArchiveNaming {
    static func outputName(for sources: [URL], format: ArchiveFormat) -> String {
        sources.count == 1 ? "\(sources[0].lastPathComponent).\(format.fileExtension)" : "Archive.\(format.fileExtension)"
    }
}
```

`.aar` files that `aa` writes compressed start with `pbz` + compression byte (`pbze` lzfse, `pbzx` lzma, `pbz4` lz4) followed by a YAA/AA01 stream; detection accepts all three prefixes.

```swift
// ProcessRunner.swift
import Foundation
import Darwin
import Synchronization
import MacxFS

public enum ProcessOutput: Sendable, Equatable { case discard, capture, file(URL) }
public struct ProcessResult: Sendable, Equatable { public var status: Int32; public var stdout: Data; public var stderrTail: String }
public struct ProcessRunnerError: Error, Sendable, Equatable, ErrnoCarrying { public var code: Int32; var errnoCode: Int32 { code } }

public enum ProcessRunner {
    static let captureLimit = 64 << 20
    public static func run(_ tool: String, _ arguments: [String], output: ProcessOutput = .discard, context: LaneContext,
                           isPaused: @escaping @Sendable () -> Bool,
                           onStderrLine: @escaping @Sendable (String) -> Void) throws -> ProcessResult {
        try run(tool, arguments, output: output, context: context, isPaused: isPaused, isCancelled: { false }, onStderrLine: onStderrLine)
    }
    /// Internal overload: jobs pass `isCancelled: { control.isCancelled }`, because a job's cancel goes through
    /// JobControl, not through the awaiting Task.
    static func run(_ tool: String, _ arguments: [String], output: ProcessOutput = .discard, context: LaneContext,
                    isPaused: @escaping @Sendable () -> Bool, isCancelled: @escaping @Sendable () -> Bool,
                    onStderrLine: @escaping @Sendable (String) -> Void) throws -> ProcessResult {
        assertOffMain()
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.environment = ["LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        var outFile: FileHandle?
        switch output {
        case .discard: process.standardOutput = FileHandle.nullDevice
        case .capture: process.standardOutput = outPipe
        case .file(let url):
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw ProcessRunnerError(code: errno) }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            outFile = h; process.standardOutput = h
        }
        process.standardError = errPipe
        let captured = Mutex(Data())
        let tail = Mutex(Data())
        if case .capture = output {
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                captured.withLock { if $0.count < captureLimit { $0.append(d.prefix(captureLimit - $0.count)) } }
            }
        }
        let pending = Mutex(Data())
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            tail.withLock { $0.append(d); if $0.count > 4096 { $0 = $0.suffix(4096) } }
            let lines: [String] = pending.withLock { buf in
                buf.append(d)
                var out: [String] = []
                while let nl = buf.firstIndex(of: 0x0A) {
                    out.append(String(decoding: buf[buf.startIndex..<nl], as: UTF8.self))
                    buf.removeSubrange(buf.startIndex...nl)
                }
                return out
            }
            lines.forEach(onStderrLine)
        }
        do { try process.run() } catch { throw ProcessRunnerError(code: ENOENT) }
        try? outFile?.close()                                   // the child holds its own copy
        let pid = process.processIdentifier
        var stopped = false
        var termSentAt: ContinuousClock.Instant?
        while process.isRunning {
            context.heartbeat()
            if context.isCancelled || isCancelled(), termSentAt == nil {
                if stopped { kill(pid, SIGCONT) }
                kill(pid, SIGTERM); termSentAt = .now
            }
            if let t = termSentAt, ContinuousClock.now - t > .seconds(2) { kill(pid, SIGKILL) }
            let paused = isPaused()
            if paused != stopped, termSentAt == nil { kill(pid, paused ? SIGSTOP : SIGCONT); stopped = paused }
            usleep(50_000)
        }
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if termSentAt != nil { throw LaneError.cancelled }
        return ProcessResult(status: process.terminationStatus, stdout: captured.withLock { $0 },
                             stderrTail: String(decoding: tail.withLock { $0 }, as: UTF8.self))
    }
}
```

`CompressJob` and `ExtractJob` pass `isPaused: { control.isPaused }` and `isCancelled: { control.isCancelled }`. MacxFS is not changed for this.

- [ ] **Step 4: Implement `CompressJob`**

```swift
import Foundation
import Darwin
import MacxFS

enum CompressJob {
    static func compress(_ ctx: JobContext, _ sources: [URL], _ format: ArchiveFormat) async {
        guard let first = sources.first, format.canCreate else { return }
        let parent = first.deletingLastPathComponent()
        guard let plan = await ctx.plan(sources: sources, destination: nil, mode: .enumerate(noMaterialization: true)) else { return }
        let itemsTotal = plan.items.reduce(0) { $0 + $1.entries.count }
        ctx.setTotals(items: itemsTotal, bytes: plan.totalBytes)
        ctx.setState(.running)
        let token = UUID().uuidString
        let partial = parent.appending(path: ".macx-partial-\(token).\(format.fileExtension)")
        let staging = parent.appending(path: ".macx-staging-\(token)", directoryHint: .isDirectory)
        let needsStaging = !(sources.count == 1 && format == .zip)
        try? await ctx.journal.record(.partial(job: ctx.id, url: partial))
        if needsStaging { try? await ctx.journal.record(.partial(job: ctx.id, url: staging)) }
        defer { Task { [journal = ctx.journal, id = ctx.id] in try? await journal.finish(job: id) } }

        let tool = { (t: String) in ctx.tuning.toolOverride?(t) ?? t }
        let control = ctx.control
        let fault = ctx.tuning.faultHook
        let jobID = ctx.id
        while true {
            let result: Result<ProcessResult, Error> = await Result {
                try await ctx.onLane { lane in
                    if needsStaging {
                        guard mkdir(staging.path, 0o700) == 0 else { throw ProcessRunnerError(code: errno) }
                        for s in sources {
                            let to = staging.appending(path: s.lastPathComponent)
                            let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC)
                            guard copyfile(s.path, to.path, nil, flags) == 0 else { throw ProcessRunnerError(code: errno) }
                            lane.heartbeat()
                        }
                    }
                    let args: (String, [String]) = switch (format, needsStaging) {
                    case (.zip, false): (tool("/usr/bin/ditto"), ["-c", "-k", "--sequesterRsrc", "--keepParent", "-V", first.path, partial.path])
                    case (.zip, true): (tool("/usr/bin/ditto"), ["-c", "-k", "--sequesterRsrc", "-V", staging.path, partial.path])
                    default: (tool("/usr/bin/aa"), ["archive", "-d", staging.path, "-o", partial.path, "-a", "lzfse", "-v"])
                    }
                    fault?(.archiveToolStarted, jobID)
                    return try ProcessRunner.run(args.0, args.1, context: lane, isPaused: { control.isPaused },
                                                 isCancelled: { control.isCancelled },
                                                 onStderrLine: { _ in ctx.addProgress(items: 1) })
                }
            }
            _ = try? await ctx.onLane { _ in
                if needsStaging { _ = removefile(staging.path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) }
            }
            switch result {
            case .success(let r) where r.status == 0:
                await place(ctx, partial: partial, in: parent, name: ArchiveNaming.outputName(for: sources, format: format))
                return
            case .failure(let e as LaneError) where e == .cancelled:
                _ = try? await ctx.onLane { _ in unlink(partial.path) }
                ctx.cancelJob()
                return
            case .success(let r):
                _ = try? await ctx.onLane { _ in unlink(partial.path) }
                let line = r.stderrTail.split(separator: "\n").last.map(String.init) ?? "exit \(r.status)"
                let kind: FileOpErrorKind = line.contains("No space left") ? .noSpace(needed: nil, available: nil) : .other(code: EIO, message: line)
                switch await ctx.askError(FileOpError(kind: kind, url: first)) {
                case .retry, .continueAnyway: continue
                case .cancel: ctx.cancelJob(); return
                default: for s in sources { ctx.skip(s, reason: kind) }; return
                }
            case .failure(let e):
                _ = try? await ctx.onLane { _ in unlink(partial.path) }
                let code = (e as? any ErrnoCarrying)?.errnoCode ?? EIO
                switch await ctx.resolveFailure(code, url: first) {
                case .retry: continue
                case .skipped, .cancelled: return
                }
            }
        }
    }

    static func place(_ ctx: JobContext, partial: URL, in parent: URL, name: String) async {
        let placed = try? await ctx.onLane { _ -> (URL, FileIdentity)? in
            for _ in 0..<1_000 {
                let candidate = NameGenerator.keepBoth(name) { PosixFS.exists(parent.appending(path: $0).path) }
                let final = parent.appending(path: candidate)
                if renamex_np(partial.path, final.path, UInt32(RENAME_EXCL)) == 0 {
                    return FileIdentity.of(path: final.path).map { (final, $0) }
                }
                if errno != EEXIST { return nil }
            }
            return nil
        }
        guard let (final, id) = placed ?? nil else { return }
        ctx.record(.created(final, id))
        ctx.landed(final)
    }
}
```

`NameGenerator.keepBoth(_:exists:)` returns the name itself when free, otherwise `"Archive 2.zip"`, … (P1-19; if its signature differs, adapt the call, not P1-19). `Planner`'s `totalBytes` is the field S3 named for summed sizes.

`JobRunner.run`: `case .compress(let urls, let format): await CompressJob.compress(ctx, urls, format)`. `JobKind.allURLs` returns the sources; the description is `.compressing` with the first name and the parent folder.

- [ ] **Step 5: Menus and commands**

- Context menu (item menu, after Duplicate): "Compress ▸" with "Compress “<name>” to .zip" (or "Compress 3 Items to .zip") and "… to .aar". The main menu's File › Compress ▸ shows the same.
- `FileCommandController`: `compressZip`/`compressAppleArchive` perform `JobRequest(.compress(selectedURLs, format), origin: window.origin)`.
- The new archive is selected when it lands (`ctx.landed`, which posts `select`).
- Add both commands to `shippedPhase4Commands`.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter "CoreTests.CompressTests|CoreTests.LaunchRecoveryTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 7: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests/CoreTests/Archive
git commit -m "feat: compress to zip and Apple Archive with staging, partials, next-free names, pause and cancel"
```

### Task P4-10: Extract (`ArchiveLister`, `ArchiveSafety`, `extract` job)

**Files:**
- Create: `Sources/Core/Archive/ArchiveLister.swift`, `Sources/Core/Archive/ArchiveSafety.swift`, `Sources/Core/Archive/ExtractJob.swift`
- Modify: `Sources/Core/FileOps/JobTypes.swift` (`JobKind.extract`, `JobVerb.extracting`), `Sources/Core/FileOps/FileOpError.swift` (`.unsafeArchive`, `.unsupportedArchive`; allowed resolutions `[.skip, .cancel]`), `Sources/Core/FileOps/JobRunner.swift`, `Sources/Core/Commands/CommandAvailability.swift` (`.extractHere` shipped; `selectionIsArchive` computed by the UI), `Sources/UI/Menus/ContextMenuBuilder.swift` (Extract Here), `Sources/UI/Commands/FileCommandController.swift`, `Sources/UI/Operations/ErrorText.swift`
- Test: `Tests/CoreTests/Archive/ExtractTests.swift`, `Tests/CoreTests/Archive/CraftedArchives.swift`

**Interfaces:**
- Consumes: P4-09 (`ArchiveFormat`, `ProcessRunner`, `CompressJob.place` naming), `FileOpsTestCase`, `Journal`, `NameGenerator`, `PosixFS`, AppleArchive (`ArchiveByteStream`, `ArchiveStream`, `ArchiveHeader`).
- Produces: §3.5 `ArchiveEntry`, `ArchiveSafetyProblem`, `ArchiveSafety` (+ `Tracker`), `JobKind.extract`, `JobVerb.extracting`, `FileOpErrorKind.unsafeArchive`/`.unsupportedArchive`. Internal: `ArchiveLister.entries(of url: URL, format: ArchiveFormat, context: LaneContext) throws -> [ArchiveEntry]`.

**Safety rules (`ArchiveSafety.problems`), applied to every entry before anything is written:**
1. `absolutePath`: the path starts with `/` (after stripping one leading `./`).
2. `parentTraversal`: any `..` component, or a symlink entry whose target, resolved lexically from the entry's directory, leaves the archive root (absolute targets count as leaving).
3. `throughSymlink`: an entry whose path has, as a proper prefix, the path of an earlier symlink entry (`link` then `link/evil.txt`).
4. `unlistable`: the lister failed or returned a path that is empty or contains NUL.
Paths are compared after splitting on `/` and dropping empty and `.` components. `__MACOSX/` entries in zips follow the same rules.

**Extraction:**
- Detect the format from the first 512 bytes (`detect(magic:name:)`); nil → `.unsupportedArchive` (Skip/Cancel).
- List entries (`tar -tf` for zip and the tar family, `tar -tvf` for types and link targets in the same order; AppleArchive via `ArchiveStream` headers: `PAT`, `TYP`, `LNK`; gzip: one entry, `baseName`). Problems → `.unsafeArchive` with the first problem's path in the message; nothing is written.
- Extract into `<parent>/.macx-partial-<UUID>/` (journaled): zip `ditto -x -k --sequesterRsrc <zip> <partial>`; tar family `tar -xf <archive> -C <partial> --no-same-owner --no-same-permissions` (bsdtar refuses `..` and absolute paths by default and does not follow symlinks while extracting, which is a second layer); aar `aa extract -i <archive> -d <partial>`; gzip `gzip -dc <archive>` with `ProcessOutput.file(<partial>/<baseName>)`.
- Post-check (lane): walk the partial dir with `fts` (`FTS_PHYSICAL`). Every entry must resolve under the partial dir, and setuid/setgid bits are cleared. A violation removes the partial and reports `.unsafeArchive`.
- Placement: if the partial dir holds exactly one top-level item other than `__MACOSX`, that item moves to `<parent>/<its name>` (next free name, `photos 2`). Otherwise the partial dir is renamed to `<parent>/<baseName>` (next free). `__MACOSX` is removed first. Records `.created(final)`; undo trashes it.
- Progress: items total = entry count. Bytes total = archive size; bytes done is estimated from items done.
- Cancel/pause as in P4-09. Cancel removes the partial dir.

- [ ] **Step 1: Write the crafted-archive writers (test support)**

`Tests/CoreTests/Archive/CraftedArchives.swift`:

```swift
import Foundation

/// Writes minimal archives byte by byte so tests can build entries no real tool would produce.
enum CraftedArchives {
    struct TarEntry { var path: String; var type: UInt8 = 0x30; var linkTarget = ""; var contents = Data() }   // '0' file, '2' symlink, '5' dir

    static func tar(_ entries: [TarEntry]) -> Data {
        var out = Data()
        for e in entries {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ offset: Int, _ len: Int) { for (i, b) in s.utf8.prefix(len).enumerated() { h[offset + i] = b } }
            func octal(_ v: Int, _ offset: Int, _ len: Int) { put(String(String(v, radix: 8).suffix(len - 1)).leftPad(len - 1), offset, len - 1) }
            put(e.path, 0, 100); octal(e.type == 0x35 ? 0o755 : 0o644, 100, 8); octal(0, 108, 8); octal(0, 116, 8)
            octal(e.contents.count, 124, 12); octal(1_700_000_000, 136, 12)
            for i in 148..<156 { h[i] = 0x20 }
            h[156] = e.type; put(e.linkTarget, 157, 100); put("ustar", 257, 6); put("00", 263, 2)
            let sum = h.reduce(0) { $0 + Int($1) }
            put(String(String(sum, radix: 8)).leftPad(6) + "\0 ", 148, 8)
            out.append(contentsOf: h)
            out.append(e.contents)
            let pad = (512 - e.contents.count % 512) % 512
            out.append(Data(count: pad))
        }
        out.append(Data(count: 1024))
        return out
    }

    /// Stored (uncompressed) zip; symlinks use Unix mode 0o120777 in the external attributes.
    struct ZipEntry { var path: String; var contents = Data(); var symlink = false }
    static func zip(_ entries: [ZipEntry]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        for e in entries {
            let name = Array(e.path.utf8)
            let crc = crc32(e.contents)
            let offset = UInt32(out.count)
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04] + le16(10) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc)
                       + le32(UInt32(e.contents.count)) + le32(UInt32(e.contents.count)) + le16(name.count) + le16(0) + name)
            out.append(e.contents)
            let mode: UInt32 = e.symlink ? 0o120777 : 0o100644
            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02] + le16(0x031E) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(crc) + le32(UInt32(e.contents.count)) + le32(UInt32(e.contents.count)) + le16(name.count)
                           + le16(0) + le16(0) + le16(0) + le16(0) + le32(mode << 16) + le32(offset) + name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
                   + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        return out
    }
}

private extension String { func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self } }

/// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), bitwise; test archives are tiny.
private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
}
```

- [ ] **Step 2: Write the failing extraction tests (Review Focus 2 and 4, extract half)**

```swift
import XCTest
import Darwin
@testable import Core
import MacxFixtures

final class ExtractTests: FileOpsTestCase {
    private func snapshot(_ dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [])!
        for case let u as URL in e { out[u.path] = (try? Data(contentsOf: u)) ?? Data("<dir>".utf8) }
        return out
    }

    func testSafetyRules() {
        func f(_ p: String) -> ArchiveEntry { ArchiveEntry(path: p, type: .file) }
        XCTAssertEqual(ArchiveSafety.problems([f("a/b.txt"), f("./c.txt")]), [])
        XCTAssertEqual(ArchiveSafety.problems([f("../escape.txt")]), [.parentTraversal("../escape.txt")])
        XCTAssertEqual(ArchiveSafety.problems([f("a/../../x")]), [.parentTraversal("a/../../x")])
        XCTAssertEqual(ArchiveSafety.problems([f("/abs.txt")]), [.absolutePath("/abs.txt")])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "link", type: .symlink(target: "../outside")), f("link/evil.txt")]),
                       [.parentTraversal("link"), .throughSymlink("link/evil.txt")])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "d/ok", type: .symlink(target: "../sibling.txt"))]), [])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "abs", type: .symlink(target: "/etc/hosts"))]), [.parentTraversal("abs")])
        var t = ArchiveSafety.Tracker()
        XCTAssertNil(t.check(ArchiveEntry(path: "l", type: .symlink(target: "x"))))
        XCTAssertEqual(t.check(f("l/y")), .throughSymlink("l/y"))
    }
    func testExtractRefusesTraversalAbsoluteAndSymlinkEscape() async throws {
        try file("outside/keep.txt", "keep")
        let before = snapshot(url("outside"))
        let archives: [(String, Data)] = [
            ("trav.tar", CraftedArchives.tar([.init(path: "../escape.txt", contents: Data("x".utf8))])),
            ("abs.tar", CraftedArchives.tar([.init(path: "/abs.txt", contents: Data("x".utf8))])),
            ("link.tar", CraftedArchives.tar([.init(path: "link", type: 0x32, linkTarget: "../outside"),
                                              .init(path: "link/evil.txt", contents: Data("x".utf8))])),
            ("trav.zip", CraftedArchives.zip([.init(path: "../escape.txt", contents: Data("x".utf8))])),
            ("link.zip", CraftedArchives.zip([.init(path: "link", contents: Data("../outside".utf8), symlink: true),
                                              .init(path: "link/evil.txt", contents: Data("x".utf8))])),
        ]
        for (name, data) in archives {
            try sandbox.createFile("work/\(name)", contents: data)
            let interaction = ScriptedInteraction(errors: [.skip])
            let (queue, journal) = makeQueue(interaction: interaction)
            let outcome = try await run(.extract(url("work/\(name)")), on: queue)
            XCTAssertEqual(interaction.askedErrors().map(\.kind), [.unsafeArchive], name)
            XCTAssertTrue(outcome.created.isEmpty, name)
            XCTAssertEqual(names(url("work")), [name], name)                 // no partial dir, nothing extracted
            XCTAssertFalse(exists(url("escape.txt")), name); XCTAssertFalse(exists(url("abs.txt")), name)
            XCTAssertTrue(await journal.entries().isEmpty, name)
            XCTAssertEqual(snapshot(url("outside")), before, name)
            try sandbox.remove("work/\(name)")
        }
    }
    func testExtractZipWithSingleTopLevelFolderAndNextFreeName() async throws {
        try file("photos/a.jpg", "A"); try file("photos/sub/b.jpg", "B")
        let (queue, _) = makeQueue()
        _ = try await run(.compress([url("photos")], .zip), on: queue)
        try dir("work"); try sandbox.rename("photos.zip", to: "work/photos.zip"); try dir("work/photos")
        let outcome = try await run(.extract(url("work/photos.zip")), on: queue)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["photos 2"])
        XCTAssertEqual(text(url("work/photos 2/sub/b.jpg")), "B")
        XCTAssertFalse(exists(url("work/photos 2/__MACOSX")))
        XCTAssertEqual(names(url("work")).filter { $0.hasPrefix(".macx-") }, [])
    }
    func testExtractNextFreeFolderName() async throws {
        let tar = CraftedArchives.tar([.init(path: "a.txt", contents: Data("1".utf8)), .init(path: "b.txt", contents: Data("2".utf8))])
        try sandbox.createFile("bundle.tar", contents: tar)
        try dir("bundle")
        let (queue, _) = makeQueue()
        let outcome = try await run(.extract(url("bundle.tar")), on: queue)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["bundle 2"])
        XCTAssertEqual(names(url("bundle 2")), ["a.txt", "b.txt"])
        XCTAssertEqual(names(url("bundle")), [])
    }
    func testExtractTarGzipGzipAndAppleArchive() async throws {
        try file("src/n.txt", "N")
        _ = try ProcessRunnerTestTool.run("/usr/bin/tar", ["-czf", url("t.tar.gz").path, "-C", url("src").path, "n.txt"])
        _ = try ProcessRunnerTestTool.run("/bin/sh", ["-c", "/usr/bin/gzip -c \"$0\" > \"$1\"", url("src/n.txt").path, url("one.txt.gz").path])
        _ = try ProcessRunnerTestTool.run("/usr/bin/aa", ["archive", "-d", url("src").path, "-o", url("s.aar").path])
        let (queue, _) = makeQueue()
        let a = try await run(.extract(url("t.tar.gz")), on: queue)
        let b = try await run(.extract(url("one.txt.gz")), on: queue)
        let c = try await run(.extract(url("s.aar")), on: queue)
        XCTAssertEqual(a.created.map(\.lastPathComponent), ["n.txt"])          // single top-level item lands as itself
        XCTAssertEqual(b.created.map(\.lastPathComponent), ["one.txt"])
        XCTAssertEqual(c.created.map(\.lastPathComponent), ["n 2.txt"])
        XCTAssertEqual(text(url("one.txt")), "N")
    }
    func testUnsupportedFormatIsReported() async throws {
        try sandbox.createFile("x.rar", contents: Data("Rar!\u{1A}\u{07}\u{00}".utf8))
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        _ = try await run(.extract(url("x.rar")), on: queue)
        XCTAssertEqual(interaction.askedErrors().map(\.kind), [.unsupportedArchive])
    }
    func testUndoTrashesExtractedItem() async throws {
        try sandbox.createFile("b.tar", contents: CraftedArchives.tar([.init(path: "only.txt", contents: Data("1".utf8))]))
        let (queue, _) = makeQueue()
        let outcome = try await run(.extract(url("b.tar")), on: queue)
        _ = try await run(.undo(outcome.record), on: queue)
        XCTAssertFalse(exists(url("only.txt")))
    }
    func testSetuidBitsAreCleared() async throws {
        var e = CraftedArchives.TarEntry(path: "tool", contents: Data("#!/bin/sh\n".utf8))
        e.type = 0x30
        var data = CraftedArchives.tar([e])
        let modeField = Array("0004755".utf8) + [0]                 // setuid + 755
        data.replaceSubrange(100..<108, with: modeField)
        let sum = data.prefix(512).enumerated().reduce(0) { $0 + (148..<156 ~= $1.offset ? 0x20 : Int($1.element)) }
        data.replaceSubrange(148..<156, with: Array((String(sum, radix: 8).leftPadded(6) + "\0 ").utf8))
        try sandbox.createFile("s.tar", contents: data)
        let (queue, _) = makeQueue()
        _ = try await run(.extract(url("s.tar")), on: queue)
        XCTAssertEqual(lst(url("tool")).st_mode & (S_ISUID | S_ISGID), 0)
    }
}
private extension String { func leftPadded(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self } }
```

In `testExtractTarGzipGzipAndAppleArchive`, the third extraction lands as `n 2.txt` because `n.txt` already exists from the first one; this also covers single-file next-free naming. `aa archive -d src` stores entries relative to `src`.

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter CoreTests.ExtractTests 2>&1 | tail -5`
Expected: build failure, `type 'JobKind' has no member 'extract'`.

- [ ] **Step 4: Implement `ArchiveSafety`**

```swift
public struct ArchiveEntry: Sendable, Equatable {
    public enum EntryType: Sendable, Equatable { case file, directory, symlink(target: String), other }
    public var path: String
    public var type: EntryType
    public init(path: String, type: EntryType) { self.path = path; self.type = type }
}
public enum ArchiveSafetyProblem: Sendable, Equatable { case absolutePath(String), parentTraversal(String), throughSymlink(String), unlistable }

public enum ArchiveSafety {
    static func components(_ p: String) -> [Substring] { p.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." } }

    public static func problems(_ entries: [ArchiveEntry]) -> [ArchiveSafetyProblem] {
        var t = Tracker()
        return entries.compactMap { t.check($0) }
    }

    public struct Tracker: Sendable {
        private var links: Set<[Substring]> = []
        public init() {}
        public mutating func check(_ entry: ArchiveEntry) -> ArchiveSafetyProblem? {
            var path = entry.path
            if path.hasPrefix("./") { path.removeFirst(2) }
            if path.isEmpty || path.contains("\0") { return .unlistable }
            if path.hasPrefix("/") { return .absolutePath(entry.path) }
            let parts = ArchiveSafety.components(path)
            if parts.contains("..") { return .parentTraversal(entry.path) }
            for n in stride(from: parts.count - 1, through: 1, by: -1) where links.contains(Array(parts.prefix(n))) {
                return .throughSymlink(entry.path)
            }
            if case .symlink(let target) = entry.type {
                links.insert(parts)
                if target.hasPrefix("/") { return .parentTraversal(entry.path) }
                var depth = parts.count - 1                          // the link's directory depth
                for c in ArchiveSafety.components(target) {
                    if c == ".." { depth -= 1; if depth < 0 { return .parentTraversal(entry.path) } } else { depth += 1 }
                }
            }
            return nil
        }
    }
}
```

The symlink check counts depth lexically: `d/ok -> ../sibling.txt` stays at depth 0 (allowed); `link -> ../outside` reaches −1 (refused).

- [ ] **Step 5: Implement `ArchiveLister` and `ExtractJob`**

`ArchiveLister.entries(of:format:context:)` (lane):
- zip and tar family: run `/usr/bin/tar -tf <file>` (capture) for paths and `/usr/bin/tar -tvf <file>` for types. Split both on `\n`, require equal counts (otherwise `.unlistable`), and zip them by index. In each `-tv` line the first character gives the type (`d` directory, `l` symlink with the target after the last `" -> "` that follows the known path, `-` file, anything else `.other`). A zip with an entry whose external attributes mark a symlink is listed by bsdtar with `l`, so the same parser applies.
- AppleArchive: `ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .readOnly, options: [], permissions: [])` → `ArchiveByteStream.decompressionStream(readingFrom:)` → `ArchiveStream.decodeStream(readingFrom:)`. Then loop `readHeader()` reading `PAT` (string), `TYP` (`.directory`, `.symbolicLink`, `.regularFile`) and `LNK`, and call `skipCurrentEntry`-equivalent by reading and discarding the blob (`readBlob` into a reusable buffer). Heartbeat every 256 headers.
- gzip: `[ArchiveEntry(path: baseName(stripping: name), type: .file)]`.
- A non-zero tool status throws `ArchiveListError.unlistable`.

`ExtractJob.extract(_ ctx: JobContext, _ archive: URL) async`:
1. On a lane: read 512 bytes, detect, list entries, run `ArchiveSafety.problems`. Unknown format → ask `.unsupportedArchive`; problems → ask `.unsafeArchive` (the message is the first problem's path). With Skip or Cancel, return; nothing has been created yet.
2. `setTotals(items: entries.count, bytes: archiveSize)`; create `<parent>/.macx-partial-<UUID>/` (mode 0o700) and journal it as `.partial`.
3. Run the tool for the format (see "Extraction" above) through `ProcessRunner` with pause/cancel. `tar -v` prints one line per entry to stderr (`x path`); `ditto -V` and `aa -v` likewise. Each line is `addProgress(items: 1)`.
4. Post-check on the lane: walk the partial dir with `fts_open(FTS_PHYSICAL | FTS_NOCHDIR)`. For each entry, `realpath` of its parent must have the partial dir's `realpath` as prefix. Clear `S_ISUID | S_ISGID` with `lchmod`. A symlink whose target escapes (same lexical rule as `Tracker`) fails the check.
5. Remove `__MACOSX` if present. Place: one top-level item → `renamex_np(RENAME_EXCL)` into `<parent>` with `NameGenerator.keepBoth(item name)`, then `rmdir` the partial dir. Several → rename the partial dir itself to `keepBoth(baseName)`. Record `.created(final, identity)` and call `landed(final)`.
6. Any failure or cancel removes the partial dir (`removefile` recursive) and `journal.finish(job:)`.

`FileOpErrorKind`: add `case unsafeArchive, unsupportedArchive`. `allowedResolutions` returns `[.skip, .cancel]` for both. `ErrorText`: "“%@” can't be extracted safely because it contains items that would be written outside the destination folder." and "“%@” isn't an archive macExplorer can open."

`CommandState.selectionIsArchive` is computed by the content view from the selected row's name (`ArchiveFormat.detect(byName:) != nil`, no I/O). `extractHere` performs `.extract(url)` for each selected archive (one job each). The context menu shows "Extract Here" for a single archive selection, under Open With. Add `.extractHere` to `shippedPhase4Commands`.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter "CoreTests.ExtractTests|CoreTests.CompressTests|CoreTests.FileOpErrorTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 7: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests/CoreTests/Archive
git commit -m "feat: safe Extract Here for zip, tar family, gzip and Apple Archive with pre-listing and post-check"
```

### Task P4-11: Batch rename engine (rules, preview, cycle-safe job, undo, recovery)

**Files:**
- Create: `Sources/Core/Rename/BatchRenameRules.swift`, `Sources/Core/Rename/RegexTemplate.swift`, `Sources/Core/Rename/BatchRenamePlanner.swift`, `Sources/Core/FileOps/BatchRenameJob.swift`
- Modify: `Sources/Core/FileOps/JobTypes.swift` (`JobKind.batchRename`, `JobVerb.batchRenaming`), `Sources/Core/FileOps/JobRunner.swift`, `Sources/Core/FileOps/Journal.swift` (`JournalEntry.batchRename`, `BatchRenameStep`), `Sources/Core/FileOps/LaunchRecovery.swift` (roll back), `Sources/Core/FileOps/FaultPoint.swift` (`batchRenameStaged`), `Sources/Core/FileOps/UndoPlanner.swift` (grouped rename-back), `Tests/CoreTests/FileOps/CrashHelper.swift` (mode `"batchRename"`)
- Test: `Tests/CoreTests/Rename/BatchRenameRulesTests.swift`, `Tests/CoreTests/Rename/BatchRenameJobTests.swift`

**Interfaces:**
- Consumes: `NameRules`/`NameProblem` (P1-10), `NameNormalizer.sameName` (S1), `FileOpsTestCase`, `CrashSpec`/`runCrashingChild` (P1-21), `Journal`, `LaunchRecovery`, `FileIdentity`, `UndoPlanner` (P1-24), `NameGenerator.keepBoth` (P1-19).
- Produces: §3.6 in full. Internal: `struct BatchRenameStep: Sendable, Codable, Equatable { var original: URL; var temporary: URL; var target: URL; var identity: FileIdentity }`, `JournalEntry.batchRename(job: JobID, steps: [BatchRenameStep])`, `RecoveryReport.restoredRenames` gains the rolled-back originals, `UndoStep.batchRenameBack([BatchRenamePair])`, `BatchRenameJob.execute(_ ctx: JobContext, _ pairs: [BatchRenamePair]) async -> [ItemAction]` (shared by forward, undo and redo).

**Rule semantics (applied in this order to the part chosen by `scope`):**
1. Find/replace. Literal: every occurrence, case-insensitive unless `caseSensitive`. Regex: `NSRegularExpression` (`.caseInsensitive` unless `caseSensitive`), all matches, replacement expanded by `RegexTemplate` (`$0`–`$9`, `$$` for a literal `$`; a group that didn't participate expands to ""). An invalid pattern throws `.invalidPattern(<pattern>)`.
2. Case change: `lower`/`upper` (locale-independent), `title` (first letter of each word upper, rest lower; words split at spaces, `-`, `_` and `.`), `sentence` (first letter upper, rest lower).
3. Prefix and suffix are added.
4. Numbering: `n = start + index × step`, zero-padded to `minDigits`. `.prefix` → `"\(n)\(separator)\(part)"`, `.suffix` → `"\(part)\(separator)\(n)"`, `.replaceName` → `"\(baseName) (\(n))"` (Explorer style; `separator` unused).
5. Scope: `.baseName` edits the name without its extension (`NSString.pathExtension` rules; `.bashrc` has no extension; folders, whose URL `hasDirectoryPath`, are treated as all base name); `.wholeName` edits the full name; `.extensionOnly` edits only the extension (no extension → unchanged).

**Preview statuses** (`BatchRenamePlanner.preview`), per row, in this priority: `invalidPattern` (all rows) → `invalid(problem)` (`NameRules.validate`: empty, contains `/` or `:`, over 255 UTF-8 bytes) → `unchanged` (proposed equals original byte for byte) → `duplicateInBatch` (two proposed names equal under `NameNormalizer.sameName(caseSensitive:)`; every member of the group gets it) → `collidesWithExisting(name)` (equal to an existing folder name that is not one of the batch's originals; names being vacated count as free) → `ok`. `extensionChanged` is true when the proposed extension differs (case-insensitively) from the original's. `canApply` is true when no row blocks and at least one row is `.ok`.

**Execution (two-phase, cycle-safe):**
- Before touching anything, the job builds a `BatchRenameStep` per pair. `temporary` is `<dir>/.macx-br-<job short>-<i>` and `identity` comes from `lstat`. It journals `.batchRename(job:steps:)` once with all steps.
- Phase 1 renames every original to its temporary name with `renamex_np(RENAME_EXCL)`. Then `faultHook(.batchRenameStaged)` fires.
- Phase 2 renames each temporary to its target with `RENAME_EXCL`. On `EEXIST` (another process created the name meanwhile) the item lands at `NameGenerator.keepBoth(target)` instead and the outcome lists it in `skipped` with reason nil, so nothing is ever overwritten. On a case-insensitive volume a case-only change goes through the temporary like everything else, so it needs no special path.
- An error in phase 1 (for example `EACCES` on one item) asks Retry/Skip/Cancel. Skip leaves that item at its original name and drops its step. Cancel rolls back every item already at its temporary name. An error in phase 2 for one item renames it back to its original (always free, since its original name is either nobody's target or its own) and records the skip.
- Each completed item is recorded as `.renamed(from: original, to: final, identity)` and `ctx.noteRenamed`. The journal entry is cleared when the job ends.
- Launch recovery for a leftover `.batchRename` entry: first, for every step whose `target` exists with the recorded identity, rename target → temporary; then every temporary that exists → original (`RENAME_EXCL`, falling back to `keepBoth(original)`). The result is "all original names", which is what a user who saw the job die expects.

- [ ] **Step 1: Write the failing rule and preview tests**

```swift
import XCTest
@testable import Core

final class BatchRenameRulesTests: XCTestCase {
    private func rules(_ edit: (inout BatchRenameRules) -> Void) -> BatchRenameRules { var r = BatchRenameRules(); edit(&r); return r }
    private func u(_ n: String, dir: Bool = false) -> URL { URL(filePath: "/tmp/macx-x/\(n)", directoryHint: dir ? .isDirectory : .notDirectory) }

    func testFindReplaceLiteralAndCase() throws {
        let r = rules { $0.find = "IMG"; $0.replace = "Photo" }
        XCTAssertEqual(try r.apply(to: "img_001 IMG.jpg", index: 0), "Photo_001 Photo.jpg")
        let cs = rules { $0.find = "IMG"; $0.replace = "Photo"; $0.caseSensitive = true }
        XCTAssertEqual(try cs.apply(to: "img_001 IMG.jpg", index: 0), "img_001 Photo.jpg")
    }
    func testRegexTemplateGroupsAndDollarEscape() throws {
        let r = rules { $0.find = #"(\d{4})-(\d{2})-(\d{2})"#; $0.replace = "$3.$2.$1 $$"; $0.useRegex = true }
        XCTAssertEqual(try r.apply(to: "2026-11-01 notes.txt", index: 0), "01.11.2026 $ notes.txt")
        let optional = rules { $0.find = "(a)?b"; $0.replace = "[$1]"; $0.useRegex = true }
        XCTAssertEqual(try optional.apply(to: "b.txt", index: 0), "[].txt")
        XCTAssertThrowsError(try rules { $0.find = "("; $0.useRegex = true }.apply(to: "x", index: 0)) {
            XCTAssertEqual($0 as? BatchRenameRuleError, .invalidPattern("("))
        }
    }
    func testCaseChangesAndScope() throws {
        XCTAssertEqual(try rules { $0.caseChange = .title }.apply(to: "my holiday-photos_raw.JPG", index: 0), "My Holiday-Photos_Raw.JPG")
        XCTAssertEqual(try rules { $0.caseChange = .sentence }.apply(to: "MY FILE.TXT", index: 0), "My file.TXT")
        XCTAssertEqual(try rules { $0.caseChange = .lower; $0.scope = .wholeName }.apply(to: "A.TXT", index: 0), "a.txt")
        XCTAssertEqual(try rules { $0.caseChange = .lower; $0.scope = .extensionOnly }.apply(to: "A.TXT", index: 0), "A.txt")
        XCTAssertEqual(try rules { $0.suffix = "-x" }.apply(to: ".bashrc", index: 0), ".bashrc-x")
        XCTAssertEqual(try rules { $0.suffix = "-x"; $0.scope = .extensionOnly }.apply(to: "README", index: 0), "README")
    }
    func testPrefixSuffixAndNumbering() throws {
        var n = BatchRenameRules.Numbering(); n.start = 9; n.step = 2; n.minDigits = 3
        XCTAssertEqual(try rules { $0.prefix = "x-"; $0.numbering = n }.apply(to: "a.txt", index: 1), "x-a 011.txt")
        n.position = .prefix; n.separator = "_"
        XCTAssertEqual(try rules { $0.numbering = n }.apply(to: "a.txt", index: 0), "009_a.txt")
        var e = BatchRenameRules.Numbering(); e.position = .replaceName; e.baseName = "Trip"
        XCTAssertEqual(try rules { $0.numbering = e }.apply(to: "IMG_4411.HEIC", index: 2), "Trip (3).HEIC")
    }
    func testPreviewStatuses() {
        let urls = [u("a.txt"), u("b.txt"), u("c.txt"), u("d.txt")]
        let r = rules { $0.find = "[ab]"; $0.replace = "z"; $0.useRegex = true }
        let p = BatchRenamePlanner.preview(urls, rules: r, caseSensitive: false,
                                           existingNames: ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"])
        XCTAssertEqual(p.rows.map(\.status), [.duplicateInBatch, .duplicateInBatch, .unchanged, .unchanged])
        XCTAssertFalse(p.canApply)
        let s = rules { $0.find = "c"; $0.replace = "e" }
        XCTAssertEqual(BatchRenamePlanner.preview([u("c.txt")], rules: s, caseSensitive: false, existingNames: ["c.txt", "E.TXT"]).rows[0].status,
                       .collidesWithExisting("E.TXT"))
        let slash = rules { $0.replace = "/"; $0.find = "a" }
        XCTAssertEqual(BatchRenamePlanner.preview([u("a.txt")], rules: slash, caseSensitive: false, existingNames: ["a.txt"]).rows[0].status,
                       .invalid(.containsSlash))
        let ext = rules { $0.find = "txt"; $0.replace = "md"; $0.scope = .wholeName }
        XCTAssertTrue(BatchRenamePlanner.preview([u("a.txt")], rules: ext, caseSensitive: false, existingNames: ["a.txt"]).rows[0].extensionChanged)
    }
    func testSwapAndCaseOnlyPreviewAreOK() {
        var n = BatchRenameRules.Numbering(); n.position = .replaceName; n.baseName = "x"
        let urls = [u("x (2).txt"), u("x (1).txt")]                                   // targets are each other's names
        let p = BatchRenamePlanner.preview(urls, rules: rules { $0.numbering = n }, caseSensitive: false, existingNames: ["x (1).txt", "x (2).txt"])
        XCTAssertEqual(p.rows.map(\.proposed), ["x (1).txt", "x (2).txt"])
        XCTAssertEqual(p.rows.map(\.status), [.ok, .ok])
        let lower = rules { $0.caseChange = .lower }
        XCTAssertEqual(BatchRenamePlanner.preview([u("A.txt")], rules: lower, caseSensitive: false, existingNames: ["A.txt"]).rows[0].status, .ok)
    }
    func testFoldersAreAllBaseName() throws {
        let p = BatchRenamePlanner.preview([u("v1.0", dir: true)], rules: rules { $0.suffix = "-old" }, caseSensitive: false, existingNames: ["v1.0"])
        XCTAssertEqual(p.rows[0].proposed, "v1.0-old")
    }
    func testPreviewPerformance10k() {
        let urls = (0..<10_000).map { u("IMG_\($0).jpg") }
        let names = urls.map(\.lastPathComponent)
        var n = BatchRenameRules.Numbering(); n.position = .replaceName; n.baseName = "Trip"
        let r = rules { $0.find = "IMG"; $0.replace = "P"; $0.numbering = n }
        let elapsed = ContinuousClock().measure { _ = BatchRenamePlanner.preview(urls, rules: r, caseSensitive: false, existingNames: names) }
        XCTAssertLessThan(elapsed, .milliseconds(400))      // 100 ms budget × 4 in debug
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.BatchRenameRulesTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'BatchRenameRules' in scope`.

- [ ] **Step 3: Implement rules, template and planner**

```swift
// RegexTemplate.swift
import Foundation

enum RegexTemplate {
    /// Expands $0–$9 and $$ against one match. Other characters are literal (no backslash escapes).
    static func expand(_ template: String, match: NSTextCheckingResult, in source: NSString) -> String {
        var out = ""
        var it = template.makeIterator()
        while let c = it.next() {
            guard c == "$" else { out.append(c); continue }
            guard let n = it.next() else { out.append("$"); break }
            if n == "$" { out.append("$"); continue }
            guard let d = n.wholeNumberValue, d < match.numberOfRanges else { out.append("$"); out.append(n); continue }
            let r = match.range(at: d)
            if r.location != NSNotFound { out += source.substring(with: r) }
        }
        return out
    }
}
```

```swift
// BatchRenameRules.swift (struct per §3.6, plus:)
extension BatchRenameRules {
    public func apply(to name: String, index: Int) throws(BatchRenameRuleError) -> String { try apply(to: name, index: index, isDirectory: false) }

    func apply(to name: String, index: Int, isDirectory: Bool) throws(BatchRenameRuleError) -> String {
        let (base, ext) = Self.split(name, isDirectory: isDirectory)
        switch scope {
        case .wholeName: return try transform(name, index: index)
        case .baseName: let b = try transform(base, index: index); return ext.isEmpty ? b : "\(b).\(ext)"
        case .extensionOnly: return ext.isEmpty ? name : "\(base).\(try transform(ext, index: index))"
        }
    }
    static func split(_ name: String, isDirectory: Bool) -> (String, String) {
        guard !isDirectory else { return (name, "") }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name.count > ext.count + 1 else { return (name, "") }
        return (String(name.dropLast(ext.count + 1)), ext)
    }
    private func transform(_ part: String, index: Int) throws(BatchRenameRuleError) -> String {
        var s = part
        if !find.isEmpty {
            if useRegex {
                guard let re = try? NSRegularExpression(pattern: find, options: caseSensitive ? [] : [.caseInsensitive]) else {
                    throw .invalidPattern(find)
                }
                let ns = s as NSString
                var out = "", last = 0
                for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    out += RegexTemplate.expand(replace, match: m, in: ns)
                    last = m.range.location + m.range.length
                }
                s = out + ns.substring(from: last)
            } else {
                s = s.replacingOccurrences(of: find, with: replace, options: caseSensitive ? [.literal] : [.literal, .caseInsensitive])
            }
        }
        switch caseChange {
        case .none: break
        case .lower: s = s.lowercased(with: Locale(identifier: "en_US_POSIX"))
        case .upper: s = s.uppercased(with: Locale(identifier: "en_US_POSIX"))
        case .title:
            var out = "", startOfWord = true
            for ch in s {
                out += startOfWord ? ch.uppercased() : ch.lowercased()
                startOfWord = ch == " " || ch == "-" || ch == "_" || ch == "."
            }
            s = out
        case .sentence: s = s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }
        s = prefix + s + suffix
        if let n = numbering {
            let raw = String(n.start + index * n.step)
            let num = String(repeating: "0", count: max(0, n.minDigits - raw.count)) + raw
            switch n.position {
            case .prefix: s = "\(num)\(n.separator)\(s)"
            case .suffix: s = "\(s)\(n.separator)\(num)"
            case .replaceName: s = "\(n.baseName) (\(num))"
            }
        }
        return s
    }
}
```

`BatchRenamePlanner.preview`:
- Compute every proposal first (throwing a pattern error marks every row `.invalidPattern`).
- Then use one dictionary pass for duplicates (key `NameNormalizer.key(name, caseSensitive:)`, the same folding `sameName` uses; S1 exposes it).
- Then one set of existing keys minus the originals' keys for collisions, reporting the existing spelling.
- All of this is O(n), with no file-system access. `pairs(_:)` returns `.ok` rows in order.

- [ ] **Step 4: Write the failing job tests (Review Focus 1)**

```swift
import XCTest
import Darwin
@testable import Core
import MacxFixtures

final class BatchRenameJobTests: FileOpsTestCase {
    private func pairs(_ dir: String, _ map: [(String, String)]) -> [BatchRenamePair] {
        map.map { BatchRenamePair(url: url(dir.isEmpty ? $0.0 : "\(dir)/\($0.0)"), newName: $0.1) }
    }

    func testBatchRenameSwapChainCycleAndCaseOnly() async throws {
        try file("s/a.txt", "A"); try file("s/b.txt", "B")
        try file("c/1.txt", "1"); try file("c/2.txt", "2"); try file("c/3.txt", "3")
        try file("y/x.txt", "X"); try file("y/y.txt", "Y"); try file("y/z.txt", "Z")
        let mount = try image(.hfsPlus)                        // case-insensitive volume for the case-only rename
        try Data("K".utf8).write(to: mount.appending(path: "A.txt"))
        let (queue, journal) = makeQueue()

        _ = try await run(.batchRename(pairs("s", [("a.txt", "b.txt"), ("b.txt", "a.txt")])), on: queue)
        XCTAssertEqual(text(url("s/a.txt")), "B"); XCTAssertEqual(text(url("s/b.txt")), "A")

        _ = try await run(.batchRename(pairs("c", [("1.txt", "2.txt"), ("2.txt", "3.txt"), ("3.txt", "4.txt")])), on: queue)
        XCTAssertEqual(names(url("c")), ["2.txt", "3.txt", "4.txt"])
        XCTAssertEqual(text(url("c/2.txt")), "1"); XCTAssertEqual(text(url("c/4.txt")), "3")

        _ = try await run(.batchRename(pairs("y", [("x.txt", "y.txt"), ("y.txt", "z.txt"), ("z.txt", "x.txt")])), on: queue)
        XCTAssertEqual(text(url("y/y.txt")), "X"); XCTAssertEqual(text(url("y/z.txt")), "Y"); XCTAssertEqual(text(url("y/x.txt")), "Z")

        let caseOnly = try await run(.batchRename([BatchRenamePair(url: mount.appending(path: "A.txt"), newName: "a.txt")]), on: queue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mount.path).filter { $0.hasSuffix(".txt") }, ["a.txt"])
        XCTAssertEqual(caseOnly.record.actions.count, 1)

        XCTAssertTrue(await journal.entries().isEmpty)
        for d in ["s", "c", "y"] { XCTAssertEqual(names(url(d)).filter { $0.hasPrefix(".macx-") }, []) }
    }
    func testBatchRenameUndoRestoresAll() async throws {
        try file("y/x.txt", "X"); try file("y/y.txt", "Y"); try file("y/z.txt", "Z"); try file("y/w.txt", "W")
        let (queue, _) = makeQueue()
        let outcome = try await run(.batchRename(pairs("y", [("x.txt", "y.txt"), ("y.txt", "z.txt"), ("z.txt", "x.txt"), ("w.txt", "v.txt")])), on: queue)
        XCTAssertEqual(outcome.record.verb, .batchRenaming)
        XCTAssertEqual(outcome.record.actions.count, 4)
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertTrue(undo.skipped.isEmpty)
        XCTAssertEqual(text(url("y/x.txt")), "X"); XCTAssertEqual(text(url("y/y.txt")), "Y")
        XCTAssertEqual(text(url("y/z.txt")), "Z"); XCTAssertEqual(text(url("y/w.txt")), "W")
        _ = try await run(.redo(undo.record), on: queue)
        XCTAssertEqual(text(url("y/y.txt")), "X"); XCTAssertEqual(text(url("y/v.txt")), "W")
    }
    func testBatchRenameRecoveryRestoresOriginals() async throws {
        try file("r/a.txt", "A"); try file("r/b.txt", "B"); try file("r/c.txt", "C")
        let spec = CrashSpec(mode: "batchRename", sources: [url("r/a.txt").path, url("r/b.txt").path, url("r/c.txt").path],
                             destination: "b.txt\nc.txt\na.txt", journal: journalURL.path, trash: trashDir.path,
                             fault: FaultPoint.batchRenameStaged.rawValue, conflict: nil, forceCrossVolume: false, allowClone: false)
        XCTAssertTrue(try await runCrashingChild(spec))
        XCTAssertEqual(names(url("r")).filter { !$0.hasPrefix(".macx-br-") }, [])     // everything is at temporary names
        let journal = Journal(fileURL: journalURL)
        let report = await LaunchRecovery.run(journal: journal, lanes: LanePool())
        XCTAssertEqual(names(url("r")), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(text(url("r/a.txt")), "A"); XCTAssertEqual(text(url("r/c.txt")), "C")
        XCTAssertEqual(Set(report.restoredRenames.map(\.lastPathComponent)), ["a.txt", "b.txt", "c.txt"])
        XCTAssertTrue(await journal.entries().isEmpty)
    }
    func testRecoveryAfterPartialPhaseTwo() async throws {
        // Simulate a crash in the middle of phase 2: step 0 landed at its target, steps 1 and 2 still temporary.
        try file("p/.macx-br-t-1", "B"); try file("p/.macx-br-t-2", "C"); try file("p/b.txt", "A")
        func id(_ rel: String) -> FileIdentity { FileIdentity.of(path: url(rel).path)! }
        let steps = [
            BatchRenameStep(original: url("p/a.txt"), temporary: url("p/.macx-br-t-0"), target: url("p/b.txt"), identity: id("p/b.txt")),
            BatchRenameStep(original: url("p/b.txt"), temporary: url("p/.macx-br-t-1"), target: url("p/c.txt"), identity: id("p/.macx-br-t-1")),
            BatchRenameStep(original: url("p/c.txt"), temporary: url("p/.macx-br-t-2"), target: url("p/a.txt"), identity: id("p/.macx-br-t-2")),
        ]
        let journal = Journal(fileURL: journalURL)
        try await journal.record(.batchRename(job: JobID(), steps: steps))
        _ = await LaunchRecovery.run(journal: journal, lanes: LanePool())
        XCTAssertEqual(text(url("p/a.txt")), "A"); XCTAssertEqual(text(url("p/b.txt")), "B"); XCTAssertEqual(text(url("p/c.txt")), "C")
    }
    func testPhaseOneFailureSkipLeavesItemAndOthersProceed() async throws {
        try file("q/a.txt"); try file("q/b.txt")
        try sandbox.setFlags("q/a.txt", UInt32(UF_IMMUTABLE))       // rename of a uchg item fails with EPERM
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        let outcome = try await run(.batchRename(pairs("q", [("a.txt", "a2.txt"), ("b.txt", "b2.txt")])), on: queue)
        XCTAssertEqual(names(url("q")), ["a.txt", "b2.txt"])
        XCTAssertEqual(outcome.skipped.map(\.url.lastPathComponent), ["a.txt"])
    }
    func testExternalCreationOfTargetNeverOverwrites() async throws {
        try file("e/a.txt", "A")
        let holder = SandboxHolder(root: root)
        let (queue, _) = makeQueue(tuning: FileOpTuning(faultHook: { point, _ in
            if point == .batchRenameStaged { try? Data("intruder".utf8).write(to: holder.root.appending(path: "e/n.txt")) }
        }))
        let outcome = try await run(.batchRename(pairs("e", [("a.txt", "n.txt")])), on: queue)
        XCTAssertEqual(text(url("e/n.txt")), "intruder"); XCTAssertEqual(text(url("e/n 2.txt")), "A")
        XCTAssertEqual(outcome.skipped.count, 1)
    }
}
final class SandboxHolder: Sendable { let root: URL; init(root: URL) { self.root = root } }
```

`CrashHelper.swift`: mode `"batchRename"` reads `sources` as the URLs and `destination` as newline-separated new names, builds `BatchRenamePair`s and runs `.batchRename`. Its sandbox-prefix check is unchanged.

- [ ] **Step 5: Run to verify they fail**

Run: `swift test --filter CoreTests.BatchRenameJobTests 2>&1 | tail -5`
Expected: build failure, `type 'JobKind' has no member 'batchRename'`.

- [ ] **Step 6: Implement the job, undo grouping and recovery**

```swift
import Foundation
import Darwin
import MacxFS

enum BatchRenameJob {
    static func run(_ ctx: JobContext, _ pairs: [BatchRenamePair]) async {
        ctx.setTotals(items: pairs.count, bytes: 0)
        ctx.setState(.running)
        for a in await execute(ctx, pairs) { ctx.record(a) }
    }

    /// Two-phase executor. Returns the `.renamed` actions in input order. Used by forward, undo and redo jobs.
    static func execute(_ ctx: JobContext, _ pairs: [BatchRenamePair]) async -> [ItemAction] {
        let short = ctx.id.short
        var steps: [BatchRenameStep] = []
        let built = (try? await ctx.onLane { _ in
            pairs.enumerated().compactMap { i, p -> BatchRenameStep? in
                let dir = p.url.deletingLastPathComponent()
                guard let id = FileIdentity.of(path: p.url.path) else { return nil }
                return BatchRenameStep(original: p.url, temporary: dir.appending(path: ".macx-br-\(short)-\(i)"),
                                       target: dir.appending(path: p.newName), identity: id)
            }
        }) ?? []
        for p in pairs where !built.contains(where: { $0.original == p.url }) { ctx.skip(p.url, reason: .sourceGone) }
        steps = built
        guard !steps.isEmpty else { return [] }
        try? await ctx.journal.record(.batchRename(job: ctx.id, steps: steps))
        defer { Task { [journal = ctx.journal, id = ctx.id] in try? await journal.finish(job: id) } }

        // Phase 1: originals → temporaries.
        var staged: [BatchRenameStep] = []
        phase1: for s in steps {
            while true {
                let rc = (try? await ctx.onLane { _ in renamex_np(s.original.path, s.temporary.path, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }) ?? EIO
                if rc == 0 { staged.append(s); continue phase1 }
                switch await ctx.resolveFailure(rc, url: s.original) {
                case .retry: continue
                case .skipped: continue phase1
                case .cancelled:
                    await rollBack(ctx, staged)
                    return []
                }
            }
        }
        ctx.tuning.faultHook?(.batchRenameStaged, ctx.id)

        // Phase 2: temporaries → targets (never overwriting).
        var actions: [ItemAction] = []
        for s in staged {
            let final = (try? await ctx.onLane { _ -> URL? in
                if renamex_np(s.temporary.path, s.target.path, UInt32(RENAME_EXCL)) == 0 { return s.target }
                guard errno == EEXIST else { return nil }
                let dir = s.target.deletingLastPathComponent()
                for _ in 0..<1_000 {
                    let name = NameGenerator.keepBoth(s.target.lastPathComponent) { PosixFS.exists(dir.appending(path: $0).path) }
                    let alt = dir.appending(path: name)
                    if renamex_np(s.temporary.path, alt.path, UInt32(RENAME_EXCL)) == 0 { return alt }
                    if errno != EEXIST { break }
                }
                return nil
            }) ?? nil
            if let final {
                if final != s.target { ctx.skip(s.original, reason: nil) }
                actions.append(.renamed(from: s.original, to: final, s.identity))
                ctx.noteRenamed(from: s.original, to: final)
            } else {
                _ = try? await ctx.onLane { _ in renamex_np(s.temporary.path, s.original.path, UInt32(RENAME_EXCL)) }
                ctx.skip(s.original, reason: .other(code: EIO, message: "rename failed"))
            }
            ctx.addProgress(items: 1, current: s.target.lastPathComponent)
        }
        return actions
    }

    static func rollBack(_ ctx: JobContext, _ staged: [BatchRenameStep]) async {
        _ = try? await ctx.onLane { _ in for s in staged.reversed() { renamex_np(s.temporary.path, s.original.path, UInt32(RENAME_EXCL)) } }
    }
}
```

`ctx.noteRenamed(from:to:)` is the S3 `LocalChange.renamed` helper on `JobContext` (the rename job posts the same). If S3 named it differently, use that name.

`JobRunner.run`: `case .batchRename(let pairs): await BatchRenameJob.run(ctx, pairs)`.

`UndoPlanner.steps(for:)`: before the per-action mapping, collect runs of consecutive `.renamed` actions whose `from` URLs share one parent directory and number at least 2. Each run becomes one `UndoStep.batchRenameBack(pairs)`, with pairs `(current: to → newName: from.lastPathComponent)`, in reverse order. Single renames keep the Phase 1 `.renameBack`. Executing `.batchRenameBack` checks each item's presence and identity first (skipping gone or changed ones with `.sourceGone`/`.changedDuringMove`). It then calls `BatchRenameJob.execute` with the remaining pairs and records the returned actions. Redo of an undo record works the same way, because the undo job also recorded consecutive `.renamed` actions in one directory.

`LaunchRecovery`: for `.batchRename(job, steps)`, on a lane:

```swift
for s in steps where FileIdentity.of(path: s.target.path) == s.identity && !PosixFS.exists(s.temporary.path) {
    _ = renamex_np(s.target.path, s.temporary.path, UInt32(RENAME_EXCL))
}
for s in steps where PosixFS.exists(s.temporary.path) {
    if renamex_np(s.temporary.path, s.original.path, UInt32(RENAME_EXCL)) == 0 { report.restoredRenames.append(s.original); continue }
    let dir = s.original.deletingLastPathComponent()
    let alt = dir.appending(path: NameGenerator.keepBoth(s.original.lastPathComponent) { PosixFS.exists(dir.appending(path: $0).path) })
    if renamex_np(s.temporary.path, alt.path, UInt32(RENAME_EXCL)) == 0 { report.restoredRenames.append(alt) }
}
```

Then `journal.clear(entry)`. The identity of an item doesn't change across renames, so step 0's file at `b.txt` matches the identity recorded for `a.txt`. In `testRecoveryAfterPartialPhaseTwo` the test builds that identity from the landed file.

- [ ] **Step 7: Run the tests**

Run: `swift test --filter "CoreTests.BatchRenameRulesTests|CoreTests.BatchRenameJobTests|CoreTests.UndoPlannerTests|CoreTests.CrashRecoveryTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 8: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources/Core Tests/CoreTests
git commit -m "feat: batch rename rules, preview statuses and cycle-safe two-phase rename with undo and recovery"
```

### Task P4-12: Batch rename UI (sheet, live preview, F2 on a multi-selection)

**Files:**
- Create: `Sources/UI/Rename/BatchRenameSheet.swift`, `Sources/UI/Rename/BatchRenamePreviewTable.swift`
- Modify: `Sources/Core/Commands/CommandAvailability.swift` (`.batchRename` shipped; `rename` with `selectionCount > 1` maps to `batchRename` via `effectiveCommand`), `Sources/UI/Commands/FileCommandController.swift`, `Sources/UI/Menus/ContextMenuBuilder.swift` ("Rename N Items…"), `Sources/UI/Menus/MainMenuBuilder.swift`, `Sources/UI/Scenario/ScenarioProbe.swift` (`probeSheetTitle`), `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/BatchRenameSheetTests.swift`

**Interfaces:**
- Consumes: P4-11 (`BatchRenameRules`, `BatchRenamePlanner`, `JobKind.batchRename`), `FolderModel` (`selectedURLs`, `caseSensitive`, the full name list from `EntryStore`, hidden included), `OperationsCenter.perform`.
- Produces: `@MainActor @Observable final class BatchRenameModel { init(urls: [URL], folder: FolderModel, context: UIContext); var rules: BatchRenameRules; private(set) var preview: BatchRenamePreview?; func apply() async -> JobOutcome?; var isComputing: Bool }`; `BatchRenameSheet.present(for urls: [URL], folder: FolderModel, on window: NSWindow, context: UIContext)`; `ScenarioProbe.probeSheetTitle`.

**Behaviour:**
- F2 or Return-as-rename with more than one selected item, the context menu "Rename N Items…", and File › Rename N Items… all open the sheet. One selected item keeps Phase 1 inline rename.
- The sheet (SwiftUI in an `NSHostingController`, attached with `beginSheet`) is titled "Rename N Items". Its controls:
  - Find/Replace fields, Regex and Match Case toggles.
  - Prefix and Suffix fields.
  - A Case popup (Don't Change, lowercase, UPPERCASE, Title Case, Sentence case).
  - A Numbering disclosure (start, step, digits, position: Before / After / Replace name with base name, separator).
  - An "Apply to" segmented control (Name / Name and extension / Extension).
- Every change re-runs the preview 50 ms after the last keystroke, on a detached task (`Task.detached(priority: .userInitiated)`; the planner is pure). Existing names are snapshotted from the folder's store when the sheet opens. A newer request supersedes the older one (generation counter).
- `BatchRenamePreviewTable` (`NSViewRepresentable` wrapping a view-based `NSTableView`) has columns Original | New | Status. Rows that block show a red status text ("Duplicate name", "Already exists", "Invalid name", "Invalid pattern"). Unchanged rows are dimmed. Rows where `extensionChanged` show a yellow "Extension changes" note. It handles 10,000 rows (cell reuse, no SwiftUI `List`).
- The Rename button is disabled unless `preview.canApply`. Pressing it performs `JobRequest(.batchRename(BatchRenamePlanner.pairs(preview)), origin:)`, closes the sheet, and selects the renamed items (`LocalChange.select`). Cancel or Esc closes without changes.
- The last-used rules are not persisted (Explorer and Finder don't either).

- [ ] **Step 1: Write the failing UI tests**

```swift
import XCTest
import AppKit
@testable import UI
@testable import Core

@MainActor final class BatchRenameSheetTests: XCTestCase {
    func testModelPreviewDebouncesAndApplies() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("IMG_1.jpg"); try ui.file("IMG_2.jpg"); try ui.file("other.txt")
        let window = try await ui.openBrowserWindow()
        let folder = window.session.folder
        folder.select(.only(["IMG_1.jpg", "IMG_2.jpg"]))
        let model = BatchRenameModel(urls: folder.selectedURLs, folder: folder, context: ui.context)
        var n = BatchRenameRules.Numbering(); n.position = .replaceName; n.baseName = "Trip"
        model.rules.numbering = n
        model.rules.find = "x"                     // second change within the debounce window
        try await ui.waitUntil("preview") { model.preview?.rows.map(\.proposed) == ["Trip (1).jpg", "Trip (2).jpg"] }
        XCTAssertEqual(model.preview?.canApply, true)
        let outcome = await model.apply()
        XCTAssertEqual(outcome?.record.actions.count, 2)
        try await ui.waitUntil("rows") { window.probeRowNames.sorted() == ["other.txt", "Trip (1).jpg", "Trip (2).jpg"] }
        XCTAssertEqual(window.probeSelectedNames.sorted(), ["Trip (1).jpg", "Trip (2).jpg"])
    }
    func testCollisionWithUnselectedItemBlocksApply() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt"); try ui.file("b.txt"); try ui.file("c.txt")
        let window = try await ui.openBrowserWindow()
        window.session.folder.select(.only(["a.txt", "b.txt"]))
        let model = BatchRenameModel(urls: window.session.folder.selectedURLs, folder: window.session.folder, context: ui.context)
        model.rules.find = "[ab]"; model.rules.replace = "c"; model.rules.useRegex = true
        try await ui.waitUntil("preview") { model.preview != nil }
        XCTAssertEqual(model.preview?.canApply, false)
        XCTAssertNil(await model.apply())
        XCTAssertEqual(window.probeRowNames.sorted(), ["a.txt", "b.txt", "c.txt"])
    }
    func testF2WithMultiSelectionOpensSheetAndSingleStaysInline() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt"); try ui.file("b.txt")
        let window = try await ui.openBrowserWindow()
        window.session.folder.select(.only(["a.txt", "b.txt"]))
        NSApp.sendAction(Selector(Command.rename.selectorName), to: nil, from: nil)
        try await ui.waitUntil("sheet") { window.probeSheetTitle == "Rename 2 Items" }
        window.window!.attachedSheet.map { window.window!.endSheet($0) }
        window.session.folder.select(.only(["a.txt"]))
        NSApp.sendAction(Selector(Command.rename.selectorName), to: nil, from: nil)
        try await ui.waitUntil("inline rename") { window.probeRenameText == "a.txt" }
        XCTAssertNil(window.probeSheetTitle)
    }
    func testContextMenuTitle() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt"); try ui.file("b.txt"); try ui.file("c.txt")
        let window = try await ui.openBrowserWindow()
        let folder = window.session.folder
        folder.select(.only(["a.txt", "b.txt", "c.txt"]))
        let menu = ContextMenuBuilder(context: ui.context).itemMenu(for: IndexSet(0..<3), in: folder, handler: FileCommandController(context: ui.context, window: window))
        XCTAssertTrue(menu.items.contains { $0.title == "Rename 3 Items…" })
    }
    func testPreviewTableHandlesTenThousandRows() {
        let rows = (0..<10_000).map { BatchRenameRow(url: URL(filePath: "/tmp/macx-x/\($0)"), original: "\($0)", proposed: "n\($0)", status: .ok, extensionChanged: false) }
        let table = BatchRenamePreviewTable.makeTableForTesting()
        let clock = ContinuousClock()
        let elapsed = clock.measure { table.setRows(rows); table.tableView.layoutSubtreeIfNeeded() }
        XCTAssertEqual(table.tableView.numberOfRows, 10_000)
        XCTAssertLessThan(elapsed, .milliseconds(200))
    }
}
```

`makeTableForTesting()`, `setRows(_:)` and `tableView` are internal seams on the coordinator object the representable wraps.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter UITests.BatchRenameSheetTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'BatchRenameModel' in scope`.

- [ ] **Step 3: Implement**

`BatchRenameModel`:
- `rules` has a `didSet` that bumps `generation` and schedules `recompute()` after `Task.sleep(for: .milliseconds(50))`. It drops the result if `generation` changed meanwhile.
- `recompute` captures `urls`, `rules`, `folder.caseSensitive` and `existingNames` (computed once in `init` from the folder's `EntryStore` names, hidden rows included). It runs `BatchRenamePlanner.preview` inside `Task.detached`.
- `apply()` returns nil unless `preview?.canApply`. Otherwise it computes the pairs and calls `context.environment.operations.perform(JobRequest(.batchRename(pairs), origin: originFromWindow))`.

`CommandAvailability.effectiveCommand(.rename, state:)` returns `.batchRename` when `selectionCount > 1` and `.batchRename` is shipped. The Phase 1 rule "rename disabled for multi-selection" changes accordingly. Update its Phase 1 test expectation in the same commit (P1-13's `CommandAvailabilityTests.testRenameNeedsSingleSelection` becomes `testRenameWithMultiSelectionMapsToBatchRename`).

`FileCommandController.perform(.batchRename, …)` calls `BatchRenameSheet.present(for: folder.selectedURLs, folder:, on: window.window!, context:)`.

`ScenarioProbe.probeSheetTitle` returns the attached sheet's `title`, or the `NSHostingController`'s `title` when the sheet is SwiftUI. `BatchRenameSheet` sets `title = L10n.format("batchRename.title", count)`.

Accessibility identifiers: `macx.batchRename.find`, `.replace`, `.regex`, `.preview`, `.apply`, `.cancel`.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "UITests.BatchRenameSheetTests|UITests.ContextMenuBuilderTests|CoreTests.CommandAvailabilityTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 5: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests
git commit -m "feat: batch rename sheet with live preview, F2 and Rename N Items for multi-selections"
```

### Task P4-13: Dual pane (⌘⇧E, F5/F6 to the other pane, Tab cycle, restoration)

**Files:**
- Create: `Sources/UI/Window/PaneController.swift`, `Sources/UI/Window/PaneHeaderView.swift`
- Modify: `Sources/UI/Window/BrowserWindowController.swift` (panes, active pane, split view, toggle, focus cycle, restoration), `Sources/UI/Sidebar/SidebarViewController.swift` (navigates the active pane), `Sources/UI/Commands/FileCommandController.swift` (`toggleDualPane`, `copyToOtherPane`, `moveToOtherPane`), `Sources/UI/Menus/KeyRouter.swift` call sites (`dualPane: window.isDualPane`), `Sources/Core/Settings/Settings.swift` (`openNewWindowsInDualPane`), `Sources/Core/Support/WindowState.swift` (or wherever P1-30 stores per-window restoration state: `dualPane`, `secondURL`, `activePane`), `Sources/UI/Settings/GeneralSettingsView.swift` (checkbox), `Sources/UI/Scenario/ScenarioProbe.swift` and `ScenarioFile.swift` (pane probes and expectations), `Sources/Core/Commands/CommandAvailability.swift` (three commands shipped)
- Test: `Tests/UITests/DualPaneTests.swift`

**Interfaces:**
- Consumes: `BrowserSession`, `ContentViewController`, `AddressBarView`, `KeymapStore.resolved(dualPane:)` (P4-02), `OperationsCenter.perform`, `JobKind.copy`/`.move` (Phase 1 semantics: copy into the source's own folder uses duplicate naming; move into a descendant reports `.intoItself`).
- Produces: the §3.10 `BrowserWindowController` and `ScenarioProbe` additions; `var isDualPane: Bool { get }`; `PaneController` (`@MainActor final class`, `init(context: UIContext, initialURL: URL, index: Int)`, `session`, `content`, `header`, `var isActive: Bool`); `Settings.openNewWindowsInDualPane`; `ScenarioFile.Expectation` gains `paneCount: Int?`, `activePane: Int?`, `otherPaneRows: [String]?`, `otherPaneFolder: String?`, `sheetTitle: String?`.

**Behaviour:**
- The window layout becomes sidebar | panes. Panes is an `NSSplitView` (vertical divider, equal widths when turned on, divider position restored). Each `PaneController` owns a `BrowserSession`, a `ContentViewController` and a `PaneHeaderView`. The header holds a compact address bar plus a 2 pt accent-coloured top border when active. In single-pane mode the header is hidden and the Phase 1 toolbar address bar drives pane 0.
- The active pane is the one whose content view last became first responder (the header's address field counts too). The toolbar address bar, the status bar, the command bar, Back/Forward/Up, the sidebar and ⌘L/F4 all act on the active pane. The status bar shows the active pane's counts.
- ⌘⇧E toggles. Turning on creates pane 1 at pane 0's folder (or the restored `secondURL`). Turning off keeps the active pane's session as pane 0 and closes the other's `FolderModel`.
- `copyToOtherPane` (F5 in dual-pane): `JobRequest(.copy(sources: active.selectedURLs, destination: other.folderURL), origin:)`. When the destination is the sources' own folder, Phase 1 makes `name copy` duplicates.
- `moveToOtherPane` (F6): when `other.folderURL` equals the selection's parent (standardized), nothing happens (no job, no dialog, a beep). Otherwise `.move(sources:destination:)`; Phase 1 reports `.intoItself` per item for a destination inside a selected folder and moves the rest.
- Tab cycles focus sidebar → pane 0 content → pane 1 content → sidebar (`cycleFocusForward`); ⇧Tab goes backwards. In single-pane mode Phase 1's cycle is unchanged.
- `KeyRouter` call sites pass `keymapStore.resolved(dualPane: window.isDualPane)`, so F5 means Refresh in single-pane and Copy to Other Pane in dual-pane mode.
- Restoration (P1-30): the window state gains `dualPane`, `secondURL` and `activePane`. New windows open dual-pane when `openNewWindowsInDualPane` is on. `--root` windows open single-pane unless the scenario's first step toggles.

- [ ] **Step 1: Write the failing tests (Review Focus 5)**

```swift
import XCTest
import AppKit
@testable import UI
@testable import Core

@MainActor final class DualPaneTests: XCTestCase {
    private func dual(_ ui: ContentTestHarness, left: String, right: String) async throws -> BrowserWindowController {
        let window = try await ui.openBrowserWindow()
        window.navigate(to: ui.url(left))
        window.setDualPane(true)
        window.panes[1].session.navigate(to: ui.url(right))
        try await ui.waitUntil("panes loaded") { window.panes.allSatisfy { $0.session.folder.state == .complete } }
        window.activatePane(0)
        return window
    }

    func testToggleCreatesSecondPaneAtSameFolderAndBack() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt")
        let window = try await ui.openBrowserWindow()
        XCTAssertEqual(window.probePaneCount, 1)
        NSApp.sendAction(Selector(Command.toggleDualPane.selectorName), to: nil, from: nil)
        XCTAssertEqual(window.probePaneCount, 2)
        XCTAssertEqual(window.probeOtherPaneFolderURL?.standardizedFileURL, window.probeFolderURL.standardizedFileURL)
        window.activatePane(1)
        XCTAssertEqual(window.probeActivePaneIndex, 1)
        window.setDualPane(false)
        XCTAssertEqual(window.probePaneCount, 1)
        XCTAssertNil(window.probeOtherPaneRowNames)
    }
    func testF5CopiesSelectionToOtherPane() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("L/a.txt"); try ui.dir("R")
        let window = try await dual(ui, left: "L", right: "R")
        window.panes[0].session.folder.select(.only(["a.txt"]))
        let controller = FileCommandController(context: ui.context, window: window)
        await controller.performAndWait(.copyToOtherPane)
        try await ui.waitUntil("copied") { window.probeOtherPaneRowNames == ["a.txt"] }
        XCTAssertEqual(window.probeRowNames, ["a.txt"])
    }
    func testOtherPaneSameFolderAndDescendant() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("S/a.txt"); try ui.file("S/b.txt"); try ui.dir("S/Sub")
        // Same folder: F5 duplicates, F6 does nothing.
        let window = try await dual(ui, left: "S", right: "S")
        let controller = FileCommandController(context: ui.context, window: window)
        window.panes[0].session.folder.select(.only(["a.txt"]))
        await controller.performAndWait(.copyToOtherPane)
        try await ui.waitUntil("duplicate") { window.probeRowNames.contains("a copy.txt") }
        let jobsBefore = ui.context.environment.operations.jobs.count
        window.panes[0].session.folder.select(.only(["b.txt"]))
        let outcome = await controller.performAndWait(.moveToOtherPane)
        XCTAssertNil(outcome)                                           // no job
        XCTAssertEqual(ui.context.environment.operations.jobs.count, jobsBefore)
        XCTAssertTrue((ui.context.interaction as? ScriptedInteraction)?.askedConflicts().isEmpty ?? true)
        // Descendant: other pane inside a selected folder → .intoItself for that item, others move.
        window.panes[1].session.navigate(to: ui.url("S/Sub"))
        try await ui.waitUntil("sub loaded") { window.probeOtherPaneFolderURL?.lastPathComponent == "Sub" }
        let scripted = ScriptedInteraction(errors: [.skip])
        ui.context.environment.interaction.setTarget(scripted)
        window.panes[0].session.folder.select(.only(["Sub", "b.txt"]))
        let moved = await controller.performAndWait(.moveToOtherPane)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.intoItself])
        XCTAssertEqual(moved?.skipped.map(\.url.lastPathComponent), ["Sub"])
        try await ui.waitUntil("b moved") { window.probeOtherPaneRowNames == ["b.txt"] }
    }
    func testF5MeansRefreshInSinglePaneAndCopyInDualPane() async throws {
        let ui = try await ContentTestHarness.make(self)
        let store = ui.context.environment.keymapStore
        let f5 = KeyChord(parsing: "F5")!
        XCTAssertEqual(KeyDispatcher(keymap: store.resolved(dualPane: false)).command(for: f5, in: .content), .refresh)
        XCTAssertEqual(KeyDispatcher(keymap: store.resolved(dualPane: true)).command(for: f5, in: .content), .copyToOtherPane)
        let window = try await ui.openBrowserWindow()
        window.setDualPane(true)
        XCTAssertTrue(window.isDualPane)
    }
    func testTabCyclesSidebarPaneZeroPaneOne() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self)
        try ui.dir("L"); try ui.dir("R")
        let window = try await dual(ui, left: "L", right: "R")
        window.focus(.sidebarFavorites)
        NSApp.sendAction(Selector(Command.cycleFocusForward.selectorName), to: nil, from: nil)
        XCTAssertEqual(window.probeActivePaneIndex, 0); XCTAssertEqual(window.probeFocus, .content)
        NSApp.sendAction(Selector(Command.cycleFocusForward.selectorName), to: nil, from: nil)
        XCTAssertEqual(window.probeActivePaneIndex, 1)
        NSApp.sendAction(Selector(Command.cycleFocusForward.selectorName), to: nil, from: nil)
        XCTAssertNotEqual(window.probeFocus, .content)
    }
    func testSidebarNavigatesActivePaneAndRestorationKeepsBoth() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.dir("L"); try ui.dir("R"); try ui.dir("X")
        let window = try await dual(ui, left: "L", right: "R")
        window.activatePane(1)
        window.navigate(to: ui.url("X"))
        XCTAssertEqual(window.panes[1].session.folder.directory.lastPathComponent, "X")
        XCTAssertEqual(window.panes[0].session.folder.directory.lastPathComponent, "L")
        let state = window.restorationState()
        XCTAssertEqual(state.dualPane, true); XCTAssertEqual(state.activePane, 1)
        XCTAssertEqual(state.secondURL?.lastPathComponent, "X")
    }
}
```

`performAndWait(_:)` is an internal async seam on `FileCommandController` that performs a command against the active pane's selection and returns the job outcome (nil when no job started). `restorationState()` returns the P1-30 per-window state value. `.sidebarFavorites` is the Phase 1 `FocusContext` case for the sidebar; use the actual case name.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter UITests.DualPaneTests 2>&1 | tail -5`
Expected: build failure, `value of type 'BrowserWindowController' has no member 'panes'`.

- [ ] **Step 3: Implement `PaneController` and `PaneHeaderView`**

`PaneController` moves the per-session parts that P1-26/P1-27 put directly on `BrowserWindowController` (session, content view controller, session observers, scenario hooks for rows/selection) into one object. `BrowserWindowController.session` stays as `activePane.session`, so Phase 1 call sites keep compiling.

`PaneHeaderView` (`NSView`): an `AddressBarView` (reused, compact style) and an `isActive` flag that draws the accent border and sets the address bar's text colour (secondary when inactive). A click anywhere in the header activates the pane.

- [ ] **Step 4: Implement the window changes**

- `panes: [PaneController]` starts with one. `setDualPane(on)` inserts or removes the second pane's view in the split view and re-wires `KeyRouter`'s dual-pane flag. It also notifies `keymapStore`-dependent views (the command bar's F-key hints).
- `activatePane(i)` sets `isActive` on both panes, rebinds the toolbar address bar, the status bar and the command bar to the active session, and posts `historyChanged` so Back/Forward validation updates. A content view becoming first responder calls `activatePane` through `ContentViewController`'s `becomeFirstResponder` callback.
- `navigate(to:selecting:)` targets the active pane.
- `macx_toggleDualPane(_:)` is in the window controller (works from any focus). `copyToOtherPane`/`moveToOtherPane` are in `FileCommandController` and use `window.panes[1 - activeIndex]`.
- Probes: `probePaneCount`, `probeActivePaneIndex`, `probeOtherPaneRowNames` (nil in single-pane), `probeOtherPaneFolderURL`, and `probeSheetTitle` (P4-12).
- `ScenarioDriver` checks the new `Expectation` fields. `otherPaneFolder` is relative to `--root`, like `folder`.
- `GeneralSettingsView`: "Open new windows in dual pane" checkbox bound to `settings.openNewWindowsInDualPane`.
- Add the three commands to `shippedPhase4Commands`. The View menu shows "Dual Pane" with a checkmark when on (`validateMenuItem` sets `state`).

- [ ] **Step 5: Run the tests (and the Phase 1 window tests, which must still pass)**

Run: `swift test --filter "UITests.DualPaneTests|UITests.BrowserWindowTests|UITests.KeyRouterTests|UITests.ScenarioDriverTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 6: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests
git commit -m "feat: dual-pane browser windows with active pane, F5/F6 to other pane, Tab cycle and restoration"
```

### Task P4-14: ACL core (`ACLEntry`, `ACLIO`, `PrincipalDirectory`, `.acl` edit + undo)

**Files:**
- Create: `Sources/Core/ACL/ACLEntry.swift`, `Sources/Core/ACL/ACLIO.swift`, `Sources/Core/ACL/PrincipalDirectory.swift`
- Modify: `Sources/Core/FileOps/JobTypes.swift` (`AttributeEdit.acl`), `Sources/Core/FileOps/JobRecord.swift` (`AttributeSnapshot.acl`), `Sources/Core/FileOps/AttributeJobs.swift` (snapshot/apply for `.acl`), `Sources/Core/FileOps/UndoPlanner.swift` (`currentValues` covers `acl`)
- Test: `Tests/CoreTests/ACL/ACLTests.swift`

**Interfaces:**
- Consumes: `AttributeJobs.snapshot/apply/setAttributes` (P1-23), `UndoPlanner.currentValues` (P1-24), `FileOpsTestCase`, Darwin `acl_*`, `mbr_*`, `getpwnam_r`, `getgrnam_r`.
- Produces: §3.7 in full; `ACLIOError` conforms to `ErrnoCarrying` (P4-07).

**Mapping (Darwin `sys/acl.h`):**

| `ACLPermissions` | `acl_perm_t` |
|---|---|
| readData | `ACL_READ_DATA` (= `ACL_LIST_DIRECTORY`) |
| writeData | `ACL_WRITE_DATA` (= `ACL_ADD_FILE`) |
| execute | `ACL_EXECUTE` (= `ACL_SEARCH`) |
| delete | `ACL_DELETE` |
| appendData | `ACL_APPEND_DATA` (= `ACL_ADD_SUBDIRECTORY`) |
| deleteChild | `ACL_DELETE_CHILD` |
| readAttributes / writeAttributes | `ACL_READ_ATTRIBUTES` / `ACL_WRITE_ATTRIBUTES` |
| readExtAttributes / writeExtAttributes | `ACL_READ_EXTATTRIBUTES` / `ACL_WRITE_EXTATTRIBUTES` |
| readSecurity / writeSecurity / changeOwner | `ACL_READ_SECURITY` / `ACL_WRITE_SECURITY` / `ACL_CHANGE_OWNER` |

`rawValue` bit *i* is the *i*-th row above (bit 0 = readData), independent of the Darwin constants, so the Codable form is stable. Presets: `readOnlyPreset = [readData, execute, readAttributes, readExtAttributes, readSecurity]`; `readWritePreset = readOnly ∪ [writeData, appendData, writeAttributes, writeExtAttributes, delete, deleteChild]`; `fullControlPreset` = all 13. `ACLInheritance` maps to `ACL_ENTRY_FILE_INHERIT`, `ACL_ENTRY_DIRECTORY_INHERIT`, `ACL_ENTRY_LIMIT_INHERIT`, `ACL_ENTRY_ONLY_INHERIT`; `isInherited` is `ACL_ENTRY_INHERITED`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import Darwin
@testable import Core
import MacxFixtures

final class ACLTests: FileOpsTestCase {
    private var me: ACLPrincipal { PrincipalDirectory.resolve(user: NSUserName())! }
    private func onLane<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await LanePool().perform(on: .unknown) { _ in try body() }
    }

    func testPrincipalResolution() throws {
        guard case .user(let name, let uuid) = me else { return XCTFail() }
        XCTAssertEqual(name, NSUserName())
        var uid: uid_t = 0; var type: Int32 = 0
        var u = uuid.uuid
        XCTAssertEqual(withUnsafePointer(to: &u) { $0.withMemoryRebound(to: UInt8.self, capacity: 16) { mbr_uuid_to_id($0, &uid, &type) } }, 0)
        XCTAssertEqual(uid, getuid())
        XCTAssertEqual(PrincipalDirectory.everyone, .group(name: "everyone", uuid: UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C")!))
        XCTAssertNil(PrincipalDirectory.resolve(user: "macx-no-such-user-\(UUID().uuidString.prefix(6))"))
        XCTAssertNotNil(PrincipalDirectory.resolve(group: "staff"))
    }
    func testWriteReadAndCanonicalOrder() async throws {
        let a = try file("a.txt")
        let me = self.me
        let allow = ACLEntry(kind: .allow, principal: me, permissions: .readWritePreset)
        let deny = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete])
        try await onLane { try ACLIO.write(explicit: [allow, deny], to: a) }
        let read = try await onLane { try ACLIO.read(a) }
        XCTAssertEqual(read, [deny, allow])                                  // explicit deny before allow
        XCTAssertEqual(ACLIO.canonicalOrder([allow, deny]), [deny, allow])
        let text = try await onLane { try ACLIO.text(a) }
        XCTAssertTrue(text.contains("everyone") && text.contains("deny"))
        try await onLane { try ACLIO.restore(text: "", to: a) }
        XCTAssertEqual(try await onLane { try ACLIO.read(a) }, [])
        XCTAssertEqual(try await onLane { try ACLIO.text(a) }, "")
        try await onLane { try ACLIO.restore(text: text, to: a) }
        XCTAssertEqual(try await onLane { try ACLIO.read(a) }, [deny, allow])
    }
    func testInheritedEntriesArePreservedOnWrite() async throws {
        let d = try dir("d")
        let me = self.me
        let inheritable = ACLEntry(kind: .allow, principal: me, permissions: .readOnlyPreset, inheritance: [.fileInherit])
        try await onLane { try ACLIO.write(explicit: [inheritable], to: d) }
        let child = try file("d/child.txt")                    // created after: inherits
        let inherited = try await onLane { try ACLIO.read(child) }
        XCTAssertEqual(inherited.count, 1); XCTAssertTrue(inherited[0].isInherited)
        let explicit = ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: [.readData])
        try await onLane { try ACLIO.write(explicit: [explicit], to: child) }
        let after = try await onLane { try ACLIO.read(child) }
        XCTAssertEqual(after.map(\.isInherited), [false, true])
    }
    func testAttributeJobAndUndo() async throws {
        let a = try file("a.txt")
        let entry = ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset)
        let (queue, _) = makeQueue()
        let outcome = try await run(.setAttributes([a], .acl([entry])), on: queue)
        XCTAssertEqual(try await onLane { try ACLIO.read(a) }, [entry])
        guard case .attributesChanged(_, let old, let new)? = outcome.record.actions.first else { return XCTFail() }
        XCTAssertEqual(old.acl, ""); XCTAssertNotNil(new.acl)
        _ = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(try await onLane { try ACLIO.read(a) }, [])
    }
    func testUndoSkipsWhenACLChangedSince() async throws {
        let a = try file("a.txt")
        let (queue, _) = makeQueue()
        let outcome = try await run(.setAttributes([a], .acl([ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: [.readData])])), on: queue)
        let me = self.me
        try await onLane { try ACLIO.write(explicit: [ACLEntry(kind: .deny, principal: me, permissions: [.delete])], to: a) }
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(undo.skipped.map(\.reason), [.changedDuringMove])
    }
    func testLockedItemIsAsked() async throws {
        let a = try file("a.txt")
        try sandbox.setFlags("a.txt", UInt32(UF_IMMUTABLE))
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        _ = try await run(.setAttributes([a], .acl([])), on: queue)
        XCTAssertEqual(interaction.askedErrors().map(\.kind), [.locked])
    }
    func testAllPrincipalsListsCurrentUserAndStaff() async {
        let all = await PrincipalDirectory.all(lanes: LanePool())
        XCTAssertTrue(all.contains(me))
        XCTAssertTrue(all.contains { if case .group(let n, _) = $0 { n == "staff" } else { false } })
        XCTAssertFalse(all.contains { if case .user(let n, _) = $0 { n == "root" } else { false } })   // uid < 500 excluded
    }
}
```

`setAttributes([a], .acl([]))` on a locked file: setting an ACL needs `writesecurity`, and `uchg` blocks it with `EPERM`, which `resolveFailure` maps to `.locked`.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.ACLTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'PrincipalDirectory' in scope`.

- [ ] **Step 3: Implement `ACLEntry.swift` and `PrincipalDirectory.swift`**

`ACLEntry.swift` declares the §3.7 types. `ACLPermissions` uses the bit layout above, with `static let all: [(ACLPermissions, acl_perm_t)]` used by `ACLIO` for conversion. `ACLInheritance` likewise has `static let all: [(ACLInheritance, acl_flag_t)]`. `ACLPrincipal.uuid` and `.name` are computed helpers.

`PrincipalDirectory`:

```swift
import Foundation
import Darwin

public enum PrincipalDirectory {
    public static let everyone = ACLPrincipal.group(name: "everyone", uuid: UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C")!)

    static func uuid(_ fill: (UnsafeMutablePointer<UInt8>) -> Int32) -> UUID? {
        var raw = [UInt8](repeating: 0, count: 16)
        guard raw.withUnsafeMutableBufferPointer({ fill($0.baseAddress!) }) == 0 else { return nil }
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }
    public static func resolve(user name: String) -> ACLPrincipal? {
        var pw = passwd(), result: UnsafeMutablePointer<passwd>?
        var buf = [CChar](repeating: 0, count: 4096)
        guard getpwnam_r(name, &pw, &buf, buf.count, &result) == 0, result != nil else { return nil }
        let uid = pw.pw_uid
        return uuid { mbr_uid_to_uuid(uid, $0) }.map { .user(name: name, uuid: $0) }
    }
    public static func resolve(group name: String) -> ACLPrincipal? {
        if name == "everyone" { return everyone }
        var gr = group(), result: UnsafeMutablePointer<group>?
        var buf = [CChar](repeating: 0, count: 16_384)
        guard getgrnam_r(name, &gr, &buf, buf.count, &result) == 0, result != nil else { return nil }
        let gid = gr.gr_gid
        return uuid { mbr_gid_to_uuid(gid, $0) }.map { .group(name: name, uuid: $0) }
    }
    /// For a UUID read from an ACL entry. Unknown UUIDs keep their UUID string as the name, so an orphaned entry is
    /// still shown and written back unchanged.
    static func principal(for uuid: UUID) -> ACLPrincipal {
        if uuid == everyone.uuid { return everyone }
        var raw = uuid.uuid
        var id: id_t = 0, type: Int32 = 0
        let rc = withUnsafeBytes(of: &raw) { mbr_uuid_to_id($0.bindMemory(to: UInt8.self).baseAddress!, &id, &type) }
        if rc == 0 && type == ID_TYPE_UID {
            var pw = passwd(), result: UnsafeMutablePointer<passwd>?
            var buf = [CChar](repeating: 0, count: 4096)
            if getpwuid_r(id, &pw, &buf, buf.count, &result) == 0, result != nil { return .user(name: String(cString: pw.pw_name), uuid: uuid) }
        } else if rc == 0 && type == ID_TYPE_GID {
            var gr = group(), result: UnsafeMutablePointer<group>?
            var buf = [CChar](repeating: 0, count: 16_384)
            if getgrgid_r(id, &gr, &buf, buf.count, &result) == 0, result != nil { return .group(name: String(cString: gr.gr_name), uuid: uuid) }
        }
        return .user(name: uuid.uuidString, uuid: uuid)
    }

    public static func all(lanes: LanePool) async -> [ACLPrincipal] {
        (try? await lanes.perform(on: .unknown, .read) { _ in
            allLock.withLock {
                var users: [ACLPrincipal] = [], groups: [ACLPrincipal] = [everyone]
                setpwent(); while let p = getpwent() {
                    if p.pointee.pw_uid >= 500, let s = resolve(user: String(cString: p.pointee.pw_name)) { users.append(s) }
                }; endpwent()
                setgrent(); while let g = getgrent() {
                    let n = String(cString: g.pointee.gr_name)
                    if !n.hasPrefix("_"), let s = resolve(group: n) { groups.append(s) }
                }; endgrent()
                return Array(Set(users)).sorted { $0.name < $1.name } + Array(Set(groups)).sorted { $0.name < $1.name }
            }
        }) ?? [everyone]
    }
    private static let allLock = NSLock()      // getpwent/getgrent are not reentrant
}
```

`ACLPrincipal` gets two computed helpers in `ACLEntry.swift`: `var name: String` and `var uuid: UUID` (both cases carry them).

- [ ] **Step 4: Implement `ACLIO`**

```swift
import Foundation
import Darwin
import MacxFS

public struct ACLIOError: Error, Sendable, Equatable, ErrnoCarrying { public var code: Int32; var errnoCode: Int32 { code } }

public enum ACLIO {
    public static func read(_ url: URL) throws(ACLIOError) -> [ACLEntry] {
        assertOffMain()
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT && FileManager.default.fileExists(atPath: url.path) { return [] }   // no ACL
            if errno == ENOENT { throw ACLIOError(code: ENOENT) }
            throw ACLIOError(code: errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var out: [ACLEntry] = []
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, Int32(which), &entry) == 0, let e = entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            acl_get_tag_type(e, &tag)
            guard let q = acl_get_qualifier(e) else { continue }
            let uuid = UUID(uuid: q.assumingMemoryBound(to: uuid_t.self).pointee)
            acl_free(q)
            var permset: acl_permset_t?
            acl_get_permset(e, &permset)
            var perms: ACLPermissions = []
            for (p, d) in ACLPermissions.all where acl_get_perm_np(permset, d) == 1 { perms.insert(p) }
            var flagset: acl_flagset_t?
            acl_get_flagset_np(UnsafeMutableRawPointer(e), &flagset)
            var inh: ACLInheritance = []
            for (i, f) in ACLInheritance.all where acl_get_flag_np(flagset, f) == 1 { inh.insert(i) }
            let inherited = acl_get_flag_np(flagset, ACL_ENTRY_INHERITED) == 1
            out.append(ACLEntry(kind: tag == ACL_EXTENDED_DENY ? .deny : .allow, principal: PrincipalDirectory.principal(for: uuid),
                                permissions: perms, inheritance: inh, isInherited: inherited))
        }
        return out
    }

    public static func write(explicit: [ACLEntry], to url: URL) throws(ACLIOError) {
        assertOffMain()
        let inherited = try read(url).filter(\.isInherited)
        let ordered = canonicalOrder(explicit.map { var e = $0; e.isInherited = false; return e }) + inherited
        guard let acl = acl_init(Int32(ordered.count)) else { throw ACLIOError(code: errno) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var a: acl_t? = acl
        for e in ordered {
            var entry: acl_entry_t?
            guard acl_create_entry(&a, &entry) == 0, let entry else { throw ACLIOError(code: errno) }
            acl_set_tag_type(entry, e.kind == .deny ? ACL_EXTENDED_DENY : ACL_EXTENDED_ALLOW)
            var u = e.principal.uuid.uuid
            withUnsafeMutableBytes(of: &u) { _ = acl_set_qualifier(entry, $0.baseAddress) }
            var permset: acl_permset_t?
            acl_get_permset(entry, &permset)
            acl_clear_perms(permset)
            for (p, d) in ACLPermissions.all where e.permissions.contains(p) { acl_add_perm(permset, d) }
            acl_set_permset(entry, permset)
            var flagset: acl_flagset_t?
            acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flagset)
            acl_clear_flags_np(flagset)
            for (i, f) in ACLInheritance.all where e.inheritance.contains(i) { acl_add_flag_np(flagset, f) }
            if e.isInherited { acl_add_flag_np(flagset, ACL_ENTRY_INHERITED) }
            acl_set_flagset_np(UnsafeMutableRawPointer(entry), flagset)
        }
        guard acl_set_link_np(url.path, ACL_TYPE_EXTENDED, a) == 0 else { throw ACLIOError(code: errno) }
    }

    public static func text(_ url: URL) throws(ACLIOError) -> String {
        assertOffMain()
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT && FileManager.default.fileExists(atPath: url.path) { return "" }
            throw ACLIOError(code: errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var len = 0
        guard let t = acl_to_text(acl, &len) else { throw ACLIOError(code: errno) }
        defer { acl_free(t) }
        return String(cString: t)
    }

    public static func restore(text: String, to url: URL) throws(ACLIOError) {
        assertOffMain()
        let acl: acl_t? = text.isEmpty ? acl_init(0) : acl_from_text(text)
        guard let acl else { throw ACLIOError(code: EINVAL) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_link_np(url.path, ACL_TYPE_EXTENDED, acl) == 0 else { throw ACLIOError(code: errno) }
    }

    public static func canonicalOrder(_ entries: [ACLEntry]) -> [ACLEntry] {
        let explicit = entries.filter { !$0.isInherited }
        return explicit.filter { $0.kind == .deny } + explicit.filter { $0.kind == .allow } + entries.filter(\.isInherited)
    }
}
```

`acl_get_link_np` returns NULL with `ENOENT` both for "no ACL" and "no file". The existence check separates the two. It is a `stat` on the same lane call, so it never runs on main.

- [ ] **Step 5: Wire `.acl` into `AttributeJobs` and undo**

- `AttributeEdit.acl([ACLEntry])` and `AttributeSnapshot.acl: String?` (decodes as nil when absent).
- `AttributeJobs.snapshot(_:for: .acl)` → `AttributeSnapshot(acl: (try? ACLIO.text(url)) ?? "")`.
- `newValues(.acl(entries))` can't know the text before writing, so `setAttributes` special-cases `.acl`: snapshot old text, `ACLIO.write(explicit:)`, then snapshot new text and record `.attributesChanged(url, old:, new:)` when they differ.
- `apply(_ s: AttributeSnapshot, to:)` handles `s.acl` with `ACLIO.restore(text:)`, after the unlock step and before the lock step.
- `UndoPlanner.currentValues(_:like:)` reads `acl` text when the template has it. Undo compares the current text with the recorded new text (mismatch → `.changedDuringMove`) and restores the old text.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter "CoreTests.ACLTests|CoreTests.AttributeJobTests|CoreTests.UndoPlannerTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 7: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources/Core Tests/CoreTests/ACL
git commit -m "feat: ACL model, read/write with inherited entries preserved, principal lookup, undoable ACL edits"
```

### Task P4-15: Helper core (`MacxHelperShared`, `MacxHelperCore`)

**Files:**
- Modify: `Package.swift` (targets `MacxHelperShared`, `MacxHelperCore`, test target `HelperTests`; `Core` gains both as dependencies; §1)
- Create: `Sources/MacxHelperShared/HelperProtocol.swift`, `Sources/MacxHelperShared/HelperConstants.swift`, `Sources/MacxHelperCore/HelperPolicy.swift`, `Sources/MacxHelperCore/SafePath.swift`, `Sources/MacxHelperCore/HelperCore.swift`, `Sources/MacxHelperCore/HelperAudit.swift`
- Test: `Tests/HelperTests/HelperPolicyTests.swift`, `Tests/HelperTests/HelperCoreTests.swift`
- Modify: `scripts/check-layering.sh` (no `import AppKit`/`SwiftUI`/`Core`/`UI` under `Sources/MacxHelper*` and `Sources/macx-helper`)

**Interfaces:**
- Consumes: Darwin (`openat`, `renameatx_np`, `unlinkat`, `mkdirat`, `fchmod`, `fchflags`, `fsetxattr`, `fremovexattr`, `fcopyfile`, `removefileat`, `acl_from_text`, `acl_set_fd_np`), `MacxFixtures.Sandbox` (tests).
- Produces: §3.8 `HelperConstants`, `HelperOperation`, `HelperRequest`, `HelperResult`, `HelperRefusal`, `MacxHelperXPC`, `ClientInfo`, `HelperEnvironment`, `HelperPolicy`, `HelperCore`. Internal: `SafePath.open(_ path: String) throws(SafePathError) -> SafePath.Handle` (`parent: Int32` fd, `leaf: String`, `close()`), `HelperAudit(log: URL, maxBytes: Int = 5 << 20, keep: Int = 3)` with `func append(_ record: AuditRecord)`.

**Security model (the reason for each rule):**
- The helper runs as root, so it never trusts a path. Every path is validated, then opened component by component from `/` with `O_NOFOLLOW | O_DIRECTORY` (`SafePath`). Every operation then uses the `*at` call on the parent fd with the leaf name. A symlink anywhere in the path (including a swap race between validation and use) makes `openat` fail with `ELOOP`/`ENOTDIR`, and the request is refused as `.symlinkInPath`.
- Policy refuses: non-absolute paths; empty, `.` or `..` components; `//`; NUL bytes; paths ≥ `PATH_MAX`; the root `/` itself; anything under `defaultDeniedPrefixes`. Those are `/System`, `/bin`, `/sbin`, `/usr` (except `/usr/local`), `/private/var/db`, `/private/var/root`, `/private/etc`, `/dev`, `/Library/Apple`, `/Library/Security` and `/Applications/macExplorer.app`. They are matched on whole components, so `/Systemx` is allowed.
- Operations are single items. `removeTree` is the only recursive one; it uses `removefileat` on the parent fd, which does not follow symlinks.
- Every call is audited, before and after: one JSON line per call (`time`, `pid`, `uid`, `jobID`, `op`, `paths`, `result`). The log rotates at 5 MiB, keeping 3 files.

- [ ] **Step 1: Add the targets and write the failing policy tests**

Add to `Package.swift` exactly the §1 lines for `MacxHelperShared`, `MacxHelperCore`, `HelperTests` and the `Core` dependencies. Create `HelperConstants.swift` with the §3.8 values so the package resolves.

```swift
import XCTest
@testable import MacxHelperCore
import MacxHelperShared

final class HelperPolicyTests: XCTestCase {
    private func v(_ op: HelperOperation) -> HelperRefusal? { HelperPolicy.validate(op, deniedPrefixes: HelperPolicy.defaultDeniedPrefixes) }

    func testPathShapeRules() {
        XCTAssertEqual(v(.remove(path: "relative/x")), .badPath)
        XCTAssertEqual(v(.remove(path: "/tmp/../etc/x")), .badPath)
        XCTAssertEqual(v(.remove(path: "/tmp/./x")), .badPath)
        XCTAssertEqual(v(.remove(path: "/tmp//x")), .badPath)
        XCTAssertEqual(v(.remove(path: "/tmp/x\0y")), .badPath)
        XCTAssertEqual(v(.remove(path: "/")), .badPath)
        XCTAssertEqual(v(.remove(path: "/" + String(repeating: "a", count: Int(PATH_MAX)))), .badPath)
        XCTAssertNil(v(.remove(path: "/Library/Application Support/X/y.txt")))
    }
    func testDeniedPrefixesMatchWholeComponents() {
        XCTAssertEqual(v(.remove(path: "/System/Library/x")), .deniedLocation)
        XCTAssertEqual(v(.setMode(path: "/usr/bin/true", mode: 0o777)), .deniedLocation)
        XCTAssertNil(v(.setMode(path: "/usr/local/bin/tool", mode: 0o755)))
        XCTAssertNil(v(.remove(path: "/Systemx/file")))
        XCTAssertEqual(v(.rename(from: "/Users/Shared/a", to: "/private/etc/a", exclusive: true)), .deniedLocation)
        XCTAssertEqual(v(.copyItem(from: "/private/var/db/x", to: "/Users/Shared/x")), .deniedLocation)
        XCTAssertEqual(v(.removeTree(path: "/Applications/macExplorer.app/Contents")), .deniedLocation)
    }
    func testModeAndXattrLimits() {
        XCTAssertEqual(v(.setMode(path: "/Users/Shared/x", mode: 0o4755)), .malformed)   // no setuid/setgid via the helper
        XCTAssertEqual(v(.makeDirectory(path: "/Users/Shared/d", mode: 0o2775)), .malformed)
        XCTAssertEqual(v(.setXattr(path: "/Users/Shared/x", name: "", value: nil)), .malformed)
        XCTAssertEqual(v(.setXattr(path: "/Users/Shared/x", name: "com.apple.rootless", value: Data())), .deniedLocation)
        XCTAssertEqual(v(.setFlags(path: "/Users/Shared/x", flags: UInt32(SF_IMMUTABLE), mask: UInt32(SF_IMMUTABLE))), .malformed)  // system flags refused
    }
    func testRequestCodableRoundTrip() throws {
        let r = HelperRequest(authorization: Data(count: 32), operation: .rename(from: "/a", to: "/b", exclusive: true), jobID: "j1")
        XCTAssertEqual(try JSONDecoder().decode(HelperRequest.self, from: JSONEncoder().encode(r)), r)
        XCTAssertEqual(r.protocolVersion, HelperConstants.protocolVersion)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter HelperTests.HelperPolicyTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'HelperPolicy' in scope`.

- [ ] **Step 3: Implement `HelperProtocol.swift` and `HelperPolicy.swift`**

`HelperProtocol.swift` declares §3.8 as written (all types `Codable`; `HelperRequest.init` sets `protocolVersion = HelperConstants.protocolVersion`). `MacxHelperXPC` is `@objc` and therefore lives in a file that imports Foundation only.

```swift
import Foundation
import Darwin
import MacxHelperShared

public enum HelperPolicy {
    public static let defaultDeniedPrefixes = ["/System", "/bin", "/sbin", "/usr", "/private/var/db", "/private/var/root",
                                               "/private/etc", "/dev", "/Library/Apple", "/Library/Security",
                                               "/Applications/macExplorer.app"]
    static let allowedUnderDenied = ["/usr/local"]
    static let deniedXattrPrefixes = ["com.apple.rootless", "com.apple.provenance", "com.apple.macl"]

    static func pathProblem(_ path: String, deniedPrefixes: [String]) -> HelperRefusal? {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"), path.utf8.count < Int(PATH_MAX), !path.contains("//"),
              !path.hasSuffix("/") else { return .badPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return .badPath }
        func under(_ prefix: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }
        if allowedUnderDenied.contains(where: under) { return nil }
        return deniedPrefixes.contains(where: under) ? .deniedLocation : nil
    }

    public static func validate(_ op: HelperOperation, deniedPrefixes: [String]) -> HelperRefusal? {
        let special: UInt16 = 0o6000
        switch op {
        case .makeDirectory(let p, let m), .createFile(let p, let m):
            return m & special != 0 ? .malformed : pathProblem(p, deniedPrefixes: deniedPrefixes)
        case .setMode(let p, let m):
            return m & special != 0 ? .malformed : pathProblem(p, deniedPrefixes: deniedPrefixes)
        case .rename(let a, let b, _), .copyItem(let a, let b), .copyMetadata(let a, let b):
            return pathProblem(a, deniedPrefixes: deniedPrefixes) ?? pathProblem(b, deniedPrefixes: deniedPrefixes)
        case .remove(let p), .removeTree(let p), .moveToTrash(let p, _), .setACL(let p, _):
            return pathProblem(p, deniedPrefixes: deniedPrefixes)
        case .setFlags(let p, let flags, let mask):
            let userFlags = UInt32(UF_SETTABLE)
            return (flags | mask) & ~userFlags != 0 ? .malformed : pathProblem(p, deniedPrefixes: deniedPrefixes)
        case .setXattr(let p, let name, _):
            if name.isEmpty || name.utf8.count > 127 { return .malformed }
            if deniedXattrPrefixes.contains(where: { name.hasPrefix($0) }) { return .deniedLocation }
            return pathProblem(p, deniedPrefixes: deniedPrefixes)
        }
    }
}
```

Run: `swift test --filter HelperTests.HelperPolicyTests 2>&1 | tail -5` → `Executed 4 tests, with 0 failures`.

- [ ] **Step 4: Write the failing core tests**

`HelperCore` runs as the test user here. Every test path is inside a `Sandbox`. The test environment's `deniedPrefixes` is the default list, which the sandbox (`/private/var/folders/…`) is not under.

```swift
import XCTest
import Darwin
@testable import MacxHelperCore
import MacxHelperShared
import MacxFixtures

final class HelperCoreTests: XCTestCase {
    private var sandbox: Sandbox!
    private var core: HelperCore!
    private var auditURL: URL { sandbox.url("audit/helper-audit.log") }
    private let client = ClientInfo(pid: getpid(), uid: getuid())

    override func setUpWithError() throws {
        sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() }
        try sandbox.createDirectory("audit"); try sandbox.createDirectory("trash")
        let trash = sandbox.url("trash").path
        core = HelperCore(environment: HelperEnvironment(auditLog: auditURL, trashDirectory: { _, _ in trash }))
    }
    private func p(_ rel: String) -> String { sandbox.url(rel).path }
    private func perform(_ op: HelperOperation) -> HelperResult { core.perform(op, client: client, jobID: "test") }

    func testSingleItemOperations() throws {
        try sandbox.createFile("a.txt", contents: Data("A".utf8))
        XCTAssertEqual(perform(.makeDirectory(path: p("d"), mode: 0o755)), .ok(resultPath: nil))
        XCTAssertEqual(perform(.createFile(path: p("d/new"), mode: 0o644)), .ok(resultPath: nil))
        XCTAssertEqual(perform(.createFile(path: p("d/new"), mode: 0o644)), .failed(errno: EEXIST))
        XCTAssertEqual(perform(.copyItem(from: p("a.txt"), to: p("d/a.txt"))), .ok(resultPath: nil))
        XCTAssertEqual(try String(contentsOf: sandbox.url("d/a.txt"), encoding: .utf8), "A")
        XCTAssertEqual(perform(.rename(from: p("d/a.txt"), to: p("d/b.txt"), exclusive: true)), .ok(resultPath: nil))
        XCTAssertEqual(perform(.rename(from: p("d/b.txt"), to: p("d/new"), exclusive: true)), .failed(errno: EEXIST))
        XCTAssertEqual(perform(.setMode(path: p("d/b.txt"), mode: 0o600)), .ok(resultPath: nil))
        var st = stat(); lstat(p("d/b.txt"), &st); XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(perform(.setFlags(path: p("d/b.txt"), flags: UInt32(UF_HIDDEN), mask: UInt32(UF_HIDDEN))), .ok(resultPath: nil))
        lstat(p("d/b.txt"), &st); XCTAssertNotEqual(st.st_flags & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(perform(.setXattr(path: p("d/b.txt"), name: "com.macexplorer.test", value: Data("v".utf8))), .ok(resultPath: nil))
        XCTAssertEqual(getxattr(p("d/b.txt"), "com.macexplorer.test", nil, 0, 0, XATTR_NOFOLLOW), 1)
        XCTAssertEqual(perform(.setXattr(path: p("d/b.txt"), name: "com.macexplorer.test", value: nil)), .ok(resultPath: nil))
        XCTAssertEqual(perform(.setACL(path: p("d/b.txt"), text: "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read\n")), .ok(resultPath: nil))
        XCTAssertEqual(perform(.setACL(path: p("d/b.txt"), text: "")), .ok(resultPath: nil))
        XCTAssertEqual(perform(.remove(path: p("d/b.txt"))), .ok(resultPath: nil))
        XCTAssertEqual(perform(.remove(path: p("d/b.txt"))), .failed(errno: ENOENT))
    }
    func testCopyMetadataAndRemoveTree() throws {
        try sandbox.createDirectory("src/sub"); try sandbox.createFile("src/sub/f")
        try sandbox.setMode("src", 0o750)
        try sandbox.createDirectory("dst")
        XCTAssertEqual(perform(.copyMetadata(from: p("src"), to: p("dst"))), .ok(resultPath: nil))
        var st = stat(); lstat(p("dst"), &st); XCTAssertEqual(st.st_mode & 0o777, 0o750)
        XCTAssertEqual(perform(.removeTree(path: p("src"))), .ok(resultPath: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p("src")))
    }
    func testRemoveTreeDoesNotFollowSymlinks() throws {
        try sandbox.createFile("keep/precious.txt")
        try sandbox.createDirectory("victim")
        try sandbox.createSymlink("victim/link", target: "../keep")
        XCTAssertEqual(perform(.removeTree(path: p("victim"))), .ok(resultPath: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p("keep/precious.txt")))
    }
    func testSymlinkInPathIsRefused() throws {
        try sandbox.createFile("real/x.txt")
        try sandbox.createSymlink("alias", target: "real")
        XCTAssertEqual(perform(.remove(path: p("alias/x.txt"))), .refused(.symlinkInPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p("real/x.txt")))
        XCTAssertEqual(perform(.remove(path: p("alias"))), .ok(resultPath: nil))       // the leaf itself may be a link
        XCTAssertTrue(FileManager.default.fileExists(atPath: p("real/x.txt")))
    }
    func testMoveToTrashNamesNextFreeAndReturnsPath() throws {
        try sandbox.createFile("t.txt"); try sandbox.createFile("trash/t.txt")
        guard case .ok(let path?) = perform(.moveToTrash(path: p("t.txt"), uid: getuid())) else { return XCTFail() }
        XCTAssertEqual((path as NSString).lastPathComponent, "t 2.txt")
        XCTAssertTrue(path.hasPrefix(p("trash")))
    }
    func testPolicyRefusalIsAuditedAndNothingHappens() throws {
        XCTAssertEqual(perform(.remove(path: "/System/Library/macx-should-not-exist")), .refused(.deniedLocation))
        let lines = try String(contentsOf: auditURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let record = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(record["op"] as? String, "remove")
        XCTAssertEqual(record["result"] as? String, "refused:deniedLocation")
        XCTAssertEqual(record["uid"] as? Int, Int(getuid()))
        XCTAssertEqual(record["jobID"] as? String, "test")
    }
    func testAuditRotation() throws {
        let audit = HelperAudit(log: auditURL, maxBytes: 2_000, keep: 3)
        for i in 0..<200 { audit.append(AuditRecord(pid: 1, uid: 501, jobID: "j\(i)", op: "remove", paths: ["/tmp/x"], result: "ok")) }
        let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.url("audit").path).sorted()
        XCTAssertEqual(names, ["helper-audit.log", "helper-audit.log.1", "helper-audit.log.2"])
        XCTAssertLessThanOrEqual(try Data(contentsOf: auditURL).count, 2_000)
    }
}
```

- [ ] **Step 5: Run to verify they fail**

Run: `swift test --filter HelperTests.HelperCoreTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'HelperCore' in scope`.

- [ ] **Step 6: Implement `SafePath`, `HelperAudit` and `HelperCore`**

```swift
// SafePath.swift
import Darwin

enum SafePathError: Error, Equatable { case symlinkInPath, errno(Int32) }

enum SafePath {
    struct Handle { let parent: Int32; let leaf: String; func close() { Darwin.close(parent) } }

    /// Opens every directory component of `path` (all but the leaf) with O_NOFOLLOW. Caller closes the handle.
    static func open(_ path: String) throws(SafePathError) -> Handle {
        var parts = path.split(separator: "/").map(String.init)
        guard let leaf = parts.popLast() else { throw .errno(EINVAL) }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw .errno(errno) }
        for c in parts {
            let next = openat(fd, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let e = errno
            Darwin.close(fd)
            guard next >= 0 else { throw (e == ELOOP || e == ENOTDIR) ? .symlinkInPath : .errno(e) }
            fd = next
        }
        return Handle(parent: fd, leaf: leaf)
    }
}
```

`ENOTDIR` is mapped to `.symlinkInPath` only when `fstatat(fd, c, AT_SYMLINK_NOFOLLOW)` reports a symlink; a plain file in the middle of the path stays `.errno(ENOTDIR)`. Add that check before throwing.

`HelperAudit`: `struct AuditRecord: Codable { var time: String (ISO 8601 with fractional seconds); pid; uid; jobID; op; paths: [String]; result: String }`. `append` serializes one line, takes an `NSLock`, checks the log size (`stat`), rotates (`.2` deleted, `.1` → `.2`, log → `.1`) when `size + line > maxBytes`, opens with `O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW` (mode 0o600) and writes. The directory is created with 0o755 if missing (production: `/Library/Logs/macExplorer`). Audit failures never fail the operation; they are written to `os_log` instead.

`HelperCore.perform(op, client:, jobID:)`:
1. `HelperPolicy.validate` → refusal → audit and return `.refused`.
2. Run the operation with `SafePath` handles (two for `rename`/`copy*`):
   - `makeDirectory`: `mkdirat(parent, leaf, mode)`.
   - `createFile`: `openat(parent, leaf, O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW, mode)`.
   - `rename`: `renameatx_np(p1, l1, p2, l2, exclusive ? RENAME_EXCL : 0)`.
   - `copyItem`: open the source `O_RDONLY|O_NOFOLLOW|O_SYMLINK`, `fstat` it. A regular file → create the destination `O_EXCL|O_NOFOLLOW` and `fcopyfile(src, dst, nil, COPYFILE_ALL)` (`COPYFILE_DATA | COPYFILE_METADATA`, no recursion); a directory → `mkdirat` + `fcopyfile(COPYFILE_METADATA)`; a symlink → `readlinkat` + `symlinkat`.
   - `copyMetadata`: open both `O_RDONLY|O_NOFOLLOW` (directories `O_DIRECTORY`) and call `fcopyfile(COPYFILE_METADATA)`.
   - `remove`: `unlinkat(parent, leaf, 0)`, and on `EPERM`/`EISDIR` for a directory, `unlinkat(…, AT_REMOVEDIR)`.
   - `removeTree`: `removefileat(parent, leaf, nil, REMOVEFILE_RECURSIVE)`.
   - `moveToTrash`: `environment.trashDirectory(path, uid)` gives the directory; open it with `SafePath` as well, choose the next free name (`"t 2.txt"` style, same rule as Phase 1's `NameGenerator.keepBoth`; copy the 15-line function into `MacxHelperCore`, since the helper doesn't link `Core`), then `renameatx_np(… RENAME_EXCL)`. Returns the new path.
   - `setMode`: `openat(O_RDONLY|O_NOFOLLOW|O_SYMLINK)` + `fchmod`.
   - `setFlags`: same + `fchflags((current & ~mask) | (flags & mask))`.
   - `setXattr`: `fsetxattr`/`fremovexattr` with `XATTR_NOFOLLOW` on the `O_SYMLINK` fd (`ENOATTR` on remove counts as success).
   - `setACL`: `acl_from_text` (or `acl_init(0)` for "") + `acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED)`.
3. Map `SafePathError.symlinkInPath` → `.refused(.symlinkInPath)` and errno → `.failed(errno:)`; audit the result and return.

`HelperEnvironment.production()` uses `/Library/Logs/macExplorer/helper-audit.log`. Its `trashDirectory` returns `<home of uid>/.Trash` (from `getpwuid_r`) when the path is on the boot volume, otherwise `<volume root>/.Trashes/<uid>` (volume root from `statfs(path).f_mntonname`), creating `.Trashes/<uid>` with mode 0o700 owned by `uid` if missing.

- [ ] **Step 7: Run the tests and the layering check**

Run: `swift test --filter HelperTests 2>&1 | tail -5` → `Executed 11 tests, with 0 failures`.
Run: `scripts/check-layering.sh` → exits 0.

- [ ] **Step 8: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Package.swift Sources/MacxHelperShared Sources/MacxHelperCore Tests/HelperTests scripts/check-layering.sh
git commit -m "feat: privileged helper core with path policy, symlink-safe openat walk, single-item ops and audit log"
```

### Task P4-16: Helper transport and packaging (XPC listener, authorization, launchd, `HelperClient`)

**Files:**
- Modify: `Package.swift` (`macx-helper` product and executable target, §1)
- Create: `Sources/macx-helper/main.swift`, `Sources/macx-helper/HelperService.swift`, `Sources/macx-helper/HelperAuthorizer.swift`, `Sources/Core/Platform/HelperClient.swift`, `Sources/Core/Platform/AuthorizationClient.swift`, `Resources/LaunchDaemons/com.macexplorer.app.helper.plist`
- Modify: `scripts/bundle.sh` (embed the helper and the daemon plist), `Sources/Core/Support/CoreEnvironment.swift` (live environment uses `HelperClient()`)
- Test: `Tests/HelperTests/HelperXPCTests.swift`

**Interfaces:**
- Consumes: P4-15 (`HelperCore`, `HelperEnvironment`, `HelperRequest/Result`, `MacxHelperXPC`, `HelperConstants`), Security (`AuthorizationCreateFromExternalForm`, `AuthorizationCopyRights`, `AuthorizationRightGet/Set`), ServiceManagement (`SMAppService.daemon(plistName:)`), `NSXPCListener`, `NSXPCConnection.setCodeSigningRequirement(_:)`.
- Produces:
  - `macx-helper` executable.
  - `protocol HelperAuthorizing: Sendable { func check(_ externalForm: Data) -> Bool }`, `struct AuthorizationServicesAuthorizer: HelperAuthorizing` (live), `struct AllowAllAuthorizer`/`DenyAllAuthorizer` (tests, in the test target).
  - `final class HelperService: NSObject, NSXPCListenerDelegate, MacxHelperXPC` with `init(core: HelperCore, authorizer: any HelperAuthorizing, requirement: String?)`.
  - `enum HelperRequirement { static func string(teamID: String, bundleID: String) -> String }`.
  - `HelperClient` (`PrivilegedFileOperating`, §3.8) and `AuthorizationClient`.
  - The launchd plist template.

**Design:**
- The daemon plist lives at `Contents/Library/LaunchDaemons/com.macexplorer.app.helper.plist`:

  ```xml
  <dict>
    <key>Label</key><string>com.macexplorer.app.helper</string>
    <key>BundleProgram</key><string>Contents/MacOS/macx-helper</string>
    <key>ProgramArguments</key><array><string>macx-helper</string><string>@REQUIREMENT@</string></array>
    <key>MachServices</key><dict><key>com.macexplorer.app.helper</key><true/></dict>
    <key>AssociatedBundleIdentifiers</key><array><string>com.macexplorer.app</string></array>
  </dict>
  ```

  `bundle.sh` replaces `@REQUIREMENT@` with `HelperRequirement.string(teamID:bundleID:)`'s output for the signing team: `anchor apple generic and identifier "com.macexplorer.app" and certificate leaf[subject.OU] = "<TEAMID>"`. With no team (ad-hoc dev and dry-run builds) it writes `unsigned`, the helper refuses every connection, and `HelperClient.availability()` returns `.unavailable(.unsignedBuild)`.
- `main.swift`: `let requirement = CommandLine.arguments.dropFirst().first`; build `HelperService(core: HelperCore(environment: .production()), authorizer: AuthorizationServicesAuthorizer(), requirement: requirement)`, `NSXPCListener(machServiceName: HelperConstants.machServiceName)`, set the delegate, `resume()`, `RunLoop.main.run()`. Refuse to start (exit 78) unless `getuid() == 0`. launchd starts it on demand, and it exits after 60 s idle (a timer reset on every request).
- `HelperService.listener(_:shouldAcceptNewConnection:)`: if `requirement` is nil or `"unsigned"`, return false. Otherwise call `connection.setCodeSigningRequirement(requirement)` (the system then drops messages from non-matching peers), set the exported interface to `NSXPCInterface(with: MacxHelperXPC.self)`, export self and resume.
- `perform(_:reply:)`: decode `HelperRequest` (failure → `.refused(.malformed)`). A version mismatch → `.refused(.versionMismatch)`. `authorizer.check(request.authorization)` false → `.refused(.notAuthorized)`. Otherwise `core.perform(op, client: ClientInfo(pid: connection.processIdentifier, uid: connection.effectiveUserIdentifier), jobID:)`. Reply with encoded JSON.
- `AuthorizationServicesAuthorizer.check`:
  - `AuthorizationCreateFromExternalForm`, then `AuthorizationCopyRights` for `HelperConstants.rightName` with flags `[.extendRights]` only (no interaction: the app did the prompting).
  - At startup the helper ensures the right exists: `AuthorizationRightGet` → missing → `AuthorizationRightSet` with rule `kAuthorizationRuleAuthenticateAsAdmin`, timeout 300 s, `shared` false, and the comment "macExplorer privileged file operations".
- `AuthorizationClient.authorize(prompt:) async throws(PrivilegeError) -> Data`: runs `AuthorizationCreate` + `AuthorizationCopyRights` with `[.interactionAllowed, .extendRights, .preAuthorize]` on a background thread. It returns the 32-byte external form, or `.cancelledByUser` on `errAuthorizationCanceled`. The right's rule has a 300 s timeout, so the client caches the external form for 290 s and re-prompts after.
- `HelperClient`:
  - `availability()` maps `SMAppService.daemon(plistName:).status`: `.enabled` → available, `.requiresApproval` → `needsApproval`, `.notRegistered` → `notRegistered`, `.notFound` → `unsignedBuild`. An ad-hoc signature (no team ID in `SecCodeCopySigningInformation`) → `unsignedBuild`.
  - `authorize()`: when `notRegistered`, call `register()` (throws `needsApproval` when the user must approve it in System Settings › General › Login Items; the UI then offers "Open Login Items Settings" via `SMAppService.openSystemSettingsLoginItems()`). Then `AuthorizationClient.authorize`.
  - `perform(op, jobID:)`: open an `NSXPCConnection(machServiceName:, options: .privileged)`, then `remoteObjectProxyWithErrorHandler` → `perform` with a 30 s timeout. Map `.refused` → `PrivilegeError.refused`, `.failed(e)` → `.failed(errno: e)`, and connection errors → `.connection(message)`. Return `resultPath`.

- [ ] **Step 1: Write the failing XPC tests**

These use `NSXPCListener.anonymous()` in the test process. No launchd, no root, no authorization prompt.

```swift
import XCTest
import Darwin
@testable import MacxHelperCore
@testable import macx_helper
import MacxHelperShared
import MacxFixtures

struct AllowAllAuthorizer: HelperAuthorizing { func check(_ externalForm: Data) -> Bool { externalForm.count == 32 } }
struct DenyAllAuthorizer: HelperAuthorizing { func check(_ externalForm: Data) -> Bool { false } }

final class HelperXPCTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    private func connect(_ authorizer: any HelperAuthorizing) -> (NSXPCListener, NSXPCConnection, HelperService) {
        try! sandbox.createDirectory("trash")
        let trash = sandbox.url("trash").path
        let core = HelperCore(environment: HelperEnvironment(auditLog: sandbox.url("audit.log"), trashDirectory: { _, _ in trash }))
        let service = HelperService(core: core, authorizer: authorizer, requirement: HelperService.testRequirementAcceptAll)
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: MacxHelperXPC.self)
        connection.resume()
        addTeardownBlock { connection.invalidate(); listener.invalidate() }
        return (listener, connection, service)
    }
    private func call(_ c: NSXPCConnection, _ request: Data) async -> HelperResult? {
        await withCheckedContinuation { k in
            let proxy = c.remoteObjectProxyWithErrorHandler { _ in k.resume(returning: nil) } as! MacxHelperXPC
            proxy.perform(request) { data in k.resume(returning: try? JSONDecoder().decode(HelperResult.self, from: data)) }
        }
    }
    private func request(_ op: HelperOperation, version: Int = HelperConstants.protocolVersion) throws -> Data {
        var r = HelperRequest(authorization: Data(count: 32), operation: op, jobID: "xpc")
        r.protocolVersion = version
        return try JSONEncoder().encode(r)
    }

    func testPingAndAuthorizedOperation() async throws {
        let (_, c, _) = connect(AllowAllAuthorizer())
        let version = await withCheckedContinuation { k in
            (c.remoteObjectProxy as! MacxHelperXPC).ping { k.resume(returning: $0) }
        }
        XCTAssertEqual(version, HelperConstants.protocolVersion)
        let result = await call(c, try request(.makeDirectory(path: sandbox.url("made").path, mode: 0o755)))
        XCTAssertEqual(result, .ok(resultPath: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.url("made").path))
    }
    func testUnauthorizedMalformedAndVersionMismatchAreRefused() async throws {
        let (_, denied, _) = connect(DenyAllAuthorizer())
        XCTAssertEqual(await call(denied, try request(.makeDirectory(path: sandbox.url("x").path, mode: 0o755))), .refused(.notAuthorized))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.url("x").path))
        let (_, ok, _) = connect(AllowAllAuthorizer())
        XCTAssertEqual(await call(ok, Data("{not json".utf8)), .refused(.malformed))
        XCTAssertEqual(await call(ok, try request(.remove(path: sandbox.url("x").path), version: 99)), .refused(.versionMismatch))
    }
    func testUnsignedRequirementRejectsEveryConnection() {
        let core = HelperCore(environment: HelperEnvironment(auditLog: sandbox.url("a.log"), trashDirectory: { _, _ in nil }))
        let service = HelperService(core: core, authorizer: AllowAllAuthorizer(), requirement: "unsigned")
        XCTAssertFalse(service.listener(NSXPCListener.anonymous(), shouldAcceptNewConnection: NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)))
        let none = HelperService(core: core, authorizer: AllowAllAuthorizer(), requirement: nil)
        XCTAssertFalse(none.listener(NSXPCListener.anonymous(), shouldAcceptNewConnection: NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)))
    }
    func testRequirementString() {
        XCTAssertEqual(HelperRequirement.string(teamID: "ABCDE12345", bundleID: "com.macexplorer.app"),
                       #"anchor apple generic and identifier "com.macexplorer.app" and certificate leaf[subject.OU] = "ABCDE12345""#)
    }
}
```

`HelperService.testRequirementAcceptAll` is an internal constant (`"macx-tests-accept-all"`) under `#if DEBUG`. With it, `shouldAcceptNewConnection` skips `setCodeSigningRequirement`. `main.swift` refuses it at startup (exit 78), so a release helper can't be started that way. The `@testable import macx_helper` needs the executable target to be testable (SwiftPM supports `@testable` imports of executable targets); add `"macx-helper"` to `HelperTests`' dependencies.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter HelperTests.HelperXPCTests 2>&1 | tail -5`
Expected: build failure, `no such module 'macx_helper'`.

- [ ] **Step 3: Implement the executable, the service, the authorizer and the client**

Write the files per **Design**. `HelperService` keeps an idle timer (`DispatchSourceTimer`, 60 s, `exit(0)` on fire) only when created by `main.swift` (`idleExit: true`); tests pass the default `false`.

`HelperClient` and `AuthorizationClient` live in `Core/Platform` (they import ServiceManagement and Security). `CoreEnvironment.init` gains `privileged: (any PrivilegedFileOperating)?`. `AppBootstrap` passes `HelperClient()` in normal mode, `EmulatedPrivilegedOperator(root:)` with `--fake-helper` (P4-17), and nil otherwise in sandbox mode.

- [ ] **Step 4: Embed in the bundle**

`scripts/bundle.sh`:
- Copy `.build/<config>/macx-helper` to `Contents/MacOS/macx-helper`.
- Render the plist into `Contents/Library/LaunchDaemons/com.macexplorer.app.helper.plist` with `sed "s|@REQUIREMENT@|$REQ|"`, where `REQ` is built from `$MACX_TEAM_ID` (empty → `unsigned`), and lint it (`plutil -lint`).
- The helper is signed before the app (inside-out) with the same identity and `--options runtime`. With `--identity -` (dev/dry-run) the requirement stays `unsigned`.

Verify (writes only into the repo's own `.build`, which the build created):

```bash
swift build --product macx-helper 2>&1 | tail -1
scripts/bundle.sh --debug > /dev/null
APP=.build/debug/macExplorer.app
test -x "$APP/Contents/MacOS/macx-helper" && echo helper-ok
plutil -extract BundleProgram raw "$APP/Contents/Library/LaunchDaemons/com.macexplorer.app.helper.plist"
plutil -extract ProgramArguments.1 raw "$APP/Contents/Library/LaunchDaemons/com.macexplorer.app.helper.plist"
```

Expected: `helper-ok`, `Contents/MacOS/macx-helper`, `unsigned`. (Use the bundle path `bundle.sh` prints if P1-42 chose a different one.)

- [ ] **Step 5: Run the tests, build, commit**

Run: `swift test --filter HelperTests 2>&1 | tail -5` → `Executed 15 tests, with 0 failures`.

```bash
swift build 2>&1 | tail -5
scripts/check-layering.sh
git add Package.swift Sources Tests/HelperTests Resources/LaunchDaemons scripts/bundle.sh
git commit -m "feat: macx-helper XPC daemon with code-signing requirement, authorization right, SMAppService client"
```

### Task P4-17: Authenticate… in file operations

**Files:**
- Create: `Sources/Core/Privileged/PrivilegedFileOperating.swift`, `Sources/Core/Privileged/PrivilegedRetryPlanner.swift`, `Sources/Core/Privileged/EmulatedPrivilegedOperator.swift`
- Modify: `Sources/Core/FileOps/FileOpError.swift` (`ErrorResolution.authenticate`, `allowedResolutions(privilegedAvailable:)`, `FileOpError.failedStep`), `Sources/Core/FileOps/JobRunner.swift` (`resolveFailure(…, step:)`, `FailureResolution.doneElevated(String?)`), every Phase 1 failure site (CreateOps, rename, copy, move, trash, delete, link, attribute jobs) and the Phase 4 ones (tags, ACL) to pass a `FailedStep`, `Sources/Core/FileOps/JobTypes.swift` (`JobRequest.elevated`), `Sources/Core/FileOps/JobRecord.swift` (`JobRecord.elevated`), `Sources/Core/FileOps/FileOpQueue.swift` (`privileged:` init parameter), `Sources/Core/FileOps/UndoPlanner.swift` (undo of an elevated record is elevated), `Sources/Core/Support/LaunchOptions.swift` (`--fake-helper`), `Sources/Core/Support/CoreEnvironment.swift`, `Sources/UI/Operations/ErrorDialog.swift` (Authenticate… button), `Sources/UI/Operations/ErrorText.swift`, `Sources/UI/Operations/InteractionRouter.swift`
- Test: `Tests/CoreTests/Privileged/AuthenticateTests.swift`

**Interfaces:**
- Consumes: P4-15/16 (`HelperOperation`, `HelperCore`, `HelperEnvironment`, `HelperClient`), the Phase 1 `JobContext.resolveFailure`, `ScriptedInteraction`, `FileOpsTestCase`.
- Produces: the §3.8 Core part in full (`PrivilegeAvailability`, `PrivilegeError`, `PrivilegedFileOperating`, `FailedStep`, `PrivilegedRetryPlanner`, `EmulatedPrivilegedOperator`, `ErrorResolution.authenticate`, `allowedResolutions(privilegedAvailable:)`, `FileOpError.failedStep`, `JobRequest.elevated`, `JobRecord.elevated`, `FileOpQueue.init(…, privileged:)`), `LaunchOptions.fakeHelper`. `EmulatedPrivilegedOperator` also has the test knobs `var nextAuthorization: Result<Void, PrivilegeError>` (default success) and `var authorizeCount: Int { get }`.

**Behaviour:**
- `allowedResolutions(privilegedAvailable: true)` adds `.authenticate` after `.retry` for `.permissionDenied` only. `EPERM` from TCC/SIP is `.blockedByMacOS`, which root can't fix either; `uchg` has Unlock and Continue; `EROFS` can't be fixed. The Phase 1 property stays `allowedResolutions(privilegedAvailable: false)`.
- `JobContext.askError` sets `error.offersAuthenticate = (privileged != nil && error.failedStep != nil && !authenticateDisabled)`. A site that can't describe its step passes nil and doesn't get the button.
- `resolveFailure(code, url:, destination:, step:)` handles `.authenticate`: `try await privileged.authorize()` (cancelled → ask the same question again, without the Authenticate… button for this job), then `perform(PrivilegedRetryPlanner.operation(for: step, uid: getuid()), jobID:)`. Success returns `.doneElevated(resultPath)`, and the call site treats it like its own success (recording the same `ItemAction` and using `resultPath` for trash). A `PrivilegeError.failed(errno:)` re-asks with that errno; `.refused` reports `.other(code: EPERM, message: "macExplorer won't change protected system locations.")`.
- Once a job has used Authenticate…, later `EACCES` failures in the same job retry elevated without asking (authorization is cached). `JobRecord.elevated` becomes true.
- Undo of an elevated record runs as `JobRequest(.undo(record), registersUndo: false, elevated: true)`. With `elevated`, the first `EACCES` goes straight to authenticate (one prompt at most, if the cache expired).
- `PrivilegedRetryPlanner.operation(for:uid:)` is a pure 1:1 mapping (`FailedStep.trash(u)` → `.moveToTrash(path:, uid:)`, URL → `standardizedFileURL.path`).
- `EmulatedPrivilegedOperator(root:)` refuses (`.refused(.deniedLocation)`) any path outside `root`. To emulate root it temporarily adds `u+rwx` to the parent directory (and to the item for `setMode`/`setXattr`/`setACL`/`copyItem` sources), runs `HelperCore` with an environment whose audit log is `<root>/state/helper-audit.log` and whose trash is `<root>/.trash`, and restores the original modes. It is used by tests and by `--fake-helper` (sandbox mode only; `LaunchOptions.parse` rejects `--fake-helper` without `--state-dir`).
- ErrorDialog: when resolutions contain `.authenticate`, an "Authenticate…" button sits left of Retry. The availability reasons show inline: `.needsApproval` → "Allow macExplorer in System Settings › Login Items, then try again." with an "Open Login Items" button; `.unsignedBuild` → the button is hidden (this build can't install the helper).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import Darwin
@testable import Core
import MacxFixtures

final class AuthenticateTests: FileOpsTestCase {
    private func queue(_ interaction: ScriptedInteraction, _ op: EmulatedPrivilegedOperator?) -> FileOpQueue {
        FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                    interaction: interaction, privileged: op)
    }

    func testResolutionsOfferAuthenticateOnlyForPermissionDenied() {
        XCTAssertEqual(FileOpErrorKind.permissionDenied.allowedResolutions(privilegedAvailable: true).prefix(2), [.retry, .authenticate])
        XCTAssertFalse(FileOpErrorKind.permissionDenied.allowedResolutions.contains(.authenticate))
        XCTAssertFalse(FileOpErrorKind.blockedByMacOS.allowedResolutions(privilegedAvailable: true).contains(.authenticate))
        XCTAssertFalse(FileOpErrorKind.locked.allowedResolutions(privilegedAvailable: true).contains(.authenticate))
    }
    func testNewFolderInReadOnlyFolderSucceedsAfterAuthenticateAndUndoIsElevated() async throws {
        let ro = try dir("ro")
        try sandbox.setMode("ro", 0o555)
        let op = EmulatedPrivilegedOperator(root: root)
        let interaction = ScriptedInteraction(errors: [.authenticate])
        let q = queue(interaction, op)
        let outcome = try await run(.newItem(.folder, in: ro), on: q)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["New Folder"])
        XCTAssertTrue(outcome.record.elevated)
        XCTAssertEqual(op.authorizeCount, 1)
        var st = stat(); lstat(ro.path, &st); XCTAssertEqual(st.st_mode & 0o777, 0o555)    // emulation restored the mode
        let undo = try await run(.undo(outcome.record), on: q)
        XCTAssertTrue(undo.skipped.isEmpty)
        XCTAssertFalse(exists(url("ro/New Folder")))
        XCTAssertEqual(interaction.askedErrors().count, 1)                                  // undo didn't ask
    }
    func testSecondFailureInSameJobRetriesElevatedWithoutAsking() async throws {
        try file("src/a.txt"); try file("src/b.txt"); let ro = try dir("ro")
        try sandbox.setMode("ro", 0o555)
        let op = EmulatedPrivilegedOperator(root: root)
        let interaction = ScriptedInteraction(errors: [.authenticate])
        let outcome = try await run(.copy(sources: [url("src/a.txt"), url("src/b.txt")], destination: ro), on: queue(interaction, op))
        XCTAssertEqual(Set(outcome.created.map(\.lastPathComponent)), ["a.txt", "b.txt"])
        XCTAssertEqual(interaction.askedErrors().count, 1)
        XCTAssertEqual(op.authorizeCount, 1)
    }
    func testCancelledAuthorizationAsksAgainWithoutTheButton() async throws {
        let ro = try dir("ro"); try sandbox.setMode("ro", 0o555)
        let op = EmulatedPrivilegedOperator(root: root)
        op.nextAuthorization = .failure(.cancelledByUser)
        let interaction = ScriptedInteraction(errors: [.authenticate, .skip])
        let outcome = try await run(.newItem(.folder, in: ro), on: queue(interaction, op))
        XCTAssertTrue(outcome.created.isEmpty)
        XCTAssertEqual(interaction.askedErrors().count, 2)
        XCTAssertTrue(interaction.askedErrors().first!.offersAuthenticate)
        XCTAssertFalse(interaction.askedErrors().last!.offersAuthenticate)
    }
    func testTrashFromReadOnlyFolderReturnsTrashPathAndUndoRestores() async throws {
        try file("ro/x.txt"); try sandbox.setMode("ro", 0o555)
        let op = EmulatedPrivilegedOperator(root: root)
        let q = queue(ScriptedInteraction(errors: [.authenticate]), op)
        let outcome = try await run(.trash([url("ro/x.txt")]), on: q)
        guard case .trashed(_, let trashURL, _)? = outcome.record.actions.first else { return XCTFail("\(outcome.record.actions)") }
        XCTAssertTrue(trashURL.path.hasPrefix(trashDir.path))
        _ = try await run(.undo(outcome.record), on: q)
        XCTAssertTrue(exists(url("ro/x.txt")))
    }
    func testNoPrivilegedOperatorMeansNoButton() async throws {
        let ro = try dir("ro"); try sandbox.setMode("ro", 0o555)
        let interaction = ScriptedInteraction(errors: [.skip])
        _ = try await run(.newItem(.folder, in: ro), on: queue(interaction, nil))
        XCTAssertFalse(interaction.askedErrors().first!.offersAuthenticate)
    }
    func testEmulatedOperatorRefusesOutsideRoot() async {
        let op = EmulatedPrivilegedOperator(root: root)
        do { _ = try await op.perform(.remove(path: "/tmp/macx-not-in-root"), jobID: JobID()); XCTFail() }
        catch { XCTAssertEqual(error, .refused(.deniedLocation)) }
    }
    func testRetryPlannerMapping() {
        let u = URL(filePath: "/tmp/macx-x/a")
        XCTAssertEqual(PrivilegedRetryPlanner.operation(for: .trash(u), uid: 501), .moveToTrash(path: "/tmp/macx-x/a", uid: 501))
        XCTAssertEqual(PrivilegedRetryPlanner.operation(for: .rename(from: u, to: u.deletingLastPathComponent().appending(path: "b"), exclusive: true), uid: 0),
                       .rename(from: "/tmp/macx-x/a", to: "/tmp/macx-x/b", exclusive: true))
    }
    func testLaunchOptionRequiresStateDir() {
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--fake-helper"]))
        XCTAssertTrue(try LaunchOptions.parse(["macExplorer", "--state-dir", "/tmp/macx-scenario-x/state", "--fake-helper"]).fakeHelper)
    }
}
```

`FileOpError.offersAuthenticate` (§3.8) carries the decision to the interaction, so `FileOpInteraction` keeps its Phase 1 signature. `JobContext.askError` sets it to `privileged != nil && error.failedStep != nil && !authenticateDisabled`. The UI shows `kind.allowedResolutions(privilegedAvailable: error.offersAuthenticate)`, and an `.authenticate` answer to an error that didn't offer it is treated as `.skip`.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.AuthenticateTests 2>&1 | tail -5`
Expected: build failure, `type 'ErrorResolution' has no member 'authenticate'`.

- [ ] **Step 3: Implement the Core types**

`PrivilegedFileOperating.swift` declares §3.8's Core part. `PrivilegedRetryPlanner` is a pure `switch` over `FailedStep` (no `default:`).

`EmulatedPrivilegedOperator`:

```swift
import Foundation
import Darwin
import Synchronization
import MacxHelperCore
import MacxHelperShared

public final class EmulatedPrivilegedOperator: PrivilegedFileOperating {
    private let root: String
    private let core: HelperCore
    private let state = Mutex((next: Result<Void, PrivilegeError>.success(()), count: 0))
    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath().path
        let trash = root.appending(path: ".trash").path
        core = HelperCore(environment: HelperEnvironment(auditLog: root.appending(path: "state/helper-audit.log"),
                                                         trashDirectory: { _, _ in trash }))
    }
    public var nextAuthorization: Result<Void, PrivilegeError> {
        get { state.withLock { $0.next } } set { state.withLock { $0.next = newValue } }
    }
    public var authorizeCount: Int { state.withLock { $0.count } }
    public func availability() async -> PrivilegeAvailability { .available }
    public func authorize() async throws(PrivilegeError) {
        let r = state.withLock { s -> Result<Void, PrivilegeError> in s.count += 1; let r = s.next; s.next = .success(()); return r }
        try r.get()
    }
    public func perform(_ op: HelperOperation, jobID: JobID) async throws(PrivilegeError) -> String? {
        let paths = op.paths.map { URL(filePath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        guard paths.allSatisfy({ $0.hasPrefix(root + "/") }) else { throw .refused(.deniedLocation) }
        let result = withTemporaryAccess(op) { core.perform(op, client: ClientInfo(pid: getpid(), uid: getuid()), jobID: jobID.short) }
        switch result {
        case .ok(let p): return p
        case .failed(let e): throw .failed(errno: e)
        case .refused(let r): throw .refused(r)
        }
    }
    /// chmod u+rwx on every parent (and the item for metadata ops), run, restore. Emulation only.
    private func withTemporaryAccess(_ op: HelperOperation, _ body: () -> HelperResult) -> HelperResult {
        var saved: [(String, mode_t)] = []
        for p in op.accessPaths where p.hasPrefix(root + "/") {
            var st = stat()
            if lstat(p, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK { saved.append((p, st.st_mode & 0o7777)); chmod(p, st.st_mode | 0o700) }
        }
        defer { for (p, m) in saved.reversed() { chmod(p, m) } }
        return body()
    }
}
```

`HelperOperation.paths` (all path arguments) and `accessPaths` (each path's parent, plus the path itself for metadata ops and copy sources) are extensions in `MacxHelperShared` so the helper's audit uses the same list. The sandbox's root is resolved through symlinks (`/private/var/…`), so the prefix check works whichever spelling the job used.

- [ ] **Step 4: Thread `FailedStep` through the failure sites**

For each Phase 1 call to `ctx.resolveFailure(code, url:, destination:)`, pass the step being attempted:

| Site (S3 file) | `FailedStep` |
|---|---|
| `CreateOps.newItem` mkdir / open | `.makeDirectory(u, mode: 0o777 & ~umask)` / `.createFile(u, mode: 0o666 & ~umask)` |
| `CreateOps.performRename` | `.rename(from:to:exclusive: true)` |
| copy tree: file / directory / metadata | `.copyItem(from:to:)` / `.makeDirectory` / `.copyMetadata(from:to:)` |
| move same volume / partial rename | `.rename(from:to:exclusive:)` |
| move cross-volume source delete | `.removeTree(src)` (directory) / `.remove(src)` (file) |
| trash | `.trash(u)` |
| delete | `.removeTree(u)` / `.remove(u)` |
| alias / symlink create | nil (no helper primitive; no button) |
| `setAttributes` locked/hidden | `.setFlags(u, flags:, mask:)` |
| `setAttributes` permissions / `chmodRecursive` | `.setMode(u, mode)` |
| `setAttributes` extension hidden / quarantine | nil / `.setXattr(u, name: "com.apple.quarantine", value: nil)` |
| `.acl` (P4-14) | `.setACL(u, text:)` |
| tags (P4-04) | `.setXattr(u, name: TagIO.xattrName, value: encoded)` |
| batch rename (P4-11) phase 1/2 | `.rename(from:to:exclusive: true)` |

For each site, `.doneElevated(path)` continues exactly like the site's own success branch. For trash, the returned path becomes `trashURL`.

`JobContext` gains `let privileged: (any PrivilegedFileOperating)?` and the per-job flags `elevatedNoPrompt: Bool` (set after the first successful authenticate, or initially from `request.elevated`) and `authenticateDisabled: Bool` (after a cancelled authorization). `JobRecord.elevated` is set when any step completed elevated.

- [ ] **Step 5: UI**

- `ErrorDialog` adds the "Authenticate…" button (`AXID.errorButton(.authenticate)` = `"macx.error.authenticate"`). `InteractionRouter.resolveError` shows `kind.allowedResolutions(privilegedAvailable: error.offersAuthenticate)` and reads `environment.privileged?.availability()` (once per dialog) for the inline note.
- `ErrorText`: "You don't have permission to change “%@”. Authenticate to make this change as an administrator." When the availability is `.needsApproval`, the dialog shows the Login Items note.
- `AppBootstrap`: `--fake-helper` → `EmulatedPrivilegedOperator(root: options.root!)`.

- [ ] **Step 6: Run the tests (all FileOps tests must still pass)**

Run: `swift test --filter "CoreTests.AuthenticateTests|CoreTests.FileOp|CoreTests.Undo|CoreTests.Move|CoreTests.Copy|CoreTests.Trash|CoreTests.Attribute|UITests.ErrorDialogTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 7: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources Tests
git commit -m "feat: Authenticate… retries failed steps through the privileged helper, elevated undo, emulated operator"
```

### Task P4-18: ACL editor and unlockable permissions in Properties

**Files:**
- Create: `Sources/UI/Properties/ACLEditorView.swift`, `Sources/UI/Properties/PermissionsLock.swift`
- Modify: `Sources/UI/Properties/PropertiesView.swift` (Permissions section: padlock, ACL table), `Sources/UI/Properties/PropertiesViewModel.swift` (ACL load and edits, lock state, elevated requests), `Sources/UI/Resources/Localizable.xcstrings`
- Test: `Tests/UITests/ACLEditorTests.swift`

**Interfaces:**
- Consumes: P4-14 (`ACLEntry`, `ACLIO`, `PrincipalDirectory`, `AttributeEdit.acl`), P4-17 (`PrivilegedFileOperating`, `JobRequest.elevated`), `PropertiesViewModel` (P1-37), `ItemProperties.isOwnedByCurrentUser`.
- Produces: `@MainActor @Observable final class ACLEditorModel { init(url: URL, context: UIContext, elevated: @escaping @MainActor () -> Bool); private(set) var entries: [ACLEntry]; func add(_ e: ACLEntry) async; func remove(at index: Int) async; func replace(at index: Int, with e: ACLEntry) async; func move(from: Int, to: Int) async; var principals: [ACLPrincipal] }`; `PermissionsLock` (`@MainActor @Observable final class PermissionsLock { enum State { case notNeeded, locked, unlocked, unavailable }; var state: State; func unlock() async }`); `ACLPermissionSummary.summary(_ p: ACLPermissions) -> Summary` (`readOnly`, `readWrite`, `fullControl`, `custom`).

**Behaviour:**
- The Permissions section shows owner/group/mode as in Phase 1, plus an "Access Control" table below. Columns: Name (principal; inherited rows in secondary colour with "(inherited)"), Type (Allow/Deny), Access (summary: Read only / Read & Write / Full Control / Custom), Applies To (folders only: "This folder", "This folder, subfolders and files", …).
- The +/− buttons and double-click open an entry sheet with: a principal picker (search field over `PrincipalDirectory.all`, loaded on a lane when the sheet opens), Allow/Deny, an access preset popup plus a "Custom…" disclosure with the 13 checkboxes, and for folders the inheritance checkboxes (Files, Folders, Only children, Don't propagate). Inherited rows can't be edited or removed.
- Every edit performs `JobRequest(.setAttributes([url], .acl(newExplicitEntries)), origin:, elevated: lock.state == .unlocked)`. Each edit is its own undo entry ("Undo Change Access").
- Lock: `state == .notNeeded` when `isOwnedByCurrentUser` (owners can change modes and ACLs). Otherwise `.locked`; or `.unavailable` when `environment.privileged == nil` or its availability is `.unsignedBuild`. In `.locked`, every permission control is disabled and the padlock reads "Click the lock to make changes." `unlock()` calls `privileged.authorize()`; success → `.unlocked`, cancel → stays locked. Unlocked state lasts until the Properties window closes.
- Mode edits (Phase 1 checkboxes) and owner/group changes use the same `elevated` flag. With an elevated request, P4-17 retries the first `EACCES` through the helper without asking.
- Multi-selection: the ACL table is hidden ("Access control can be edited for one item at a time.").

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import UI
@testable import Core

@MainActor final class ACLEditorTests: XCTestCase {
    private func read(_ u: URL, _ ui: ContentTestHarness) async throws -> [ACLEntry] {
        try await ui.context.environment.lanes.perform(on: .unknown) { _ in try ACLIO.read(u) }
    }

    func testSummaries() {
        XCTAssertEqual(ACLPermissionSummary.summary(.readOnlyPreset), .readOnly)
        XCTAssertEqual(ACLPermissionSummary.summary(.readWritePreset), .readWrite)
        XCTAssertEqual(ACLPermissionSummary.summary(.fullControlPreset), .fullControl)
        XCTAssertEqual(ACLPermissionSummary.summary([.readData, .delete]), .custom)
    }
    func testAddReplaceRemoveRunUndoableJobs() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let model = ACLEditorModel(url: a, context: ui.context, elevated: { false })
        try await ui.waitUntil("loaded") { model.entries.isEmpty && model.isLoaded }
        let everyoneRead = ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset)
        await model.add(everyoneRead)
        XCTAssertEqual(try await read(a, ui), [everyoneRead])
        let deny = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete])
        await model.add(deny)
        XCTAssertEqual(model.entries, [deny, everyoneRead])               // canonical order after reload
        await model.replace(at: 1, with: ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readWritePreset))
        XCTAssertEqual(try await read(a, ui).last?.permissions, .readWritePreset)
        await model.remove(at: 0)
        XCTAssertEqual(try await read(a, ui).count, 1)
        ui.context.environment.undo.undoManager.undo()
        try await ui.waitUntil("undo finished") { ui.context.environment.undo.canRedo }
        XCTAssertEqual(try await read(a, ui).count, 2)
    }
    func testInheritedRowsAreReadOnly() async throws {
        let ui = try await ContentTestHarness.make(self)
        let d = try ui.dir("d")
        try await ui.context.environment.lanes.perform(on: .unknown) { _ in
            try ACLIO.write(explicit: [ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset, inheritance: [.fileInherit])], to: d)
        }
        let child = try ui.file("d/c.txt")
        let model = ACLEditorModel(url: child, context: ui.context, elevated: { false })
        try await ui.waitUntil("loaded") { model.entries.count == 1 }
        XCTAssertFalse(model.canEdit(row: 0))
        await model.remove(at: 0)                                         // ignored
        XCTAssertEqual(try await read(child, ui).count, 1)
    }
    func testLockStatesAndElevatedRequests() async throws {
        let ui = try await ContentTestHarness.make(self, privileged: .emulated)   // harness option: EmulatedPrivilegedOperator(root:)
        let lock = PermissionsLock(isOwnedByCurrentUser: false, privileged: ui.context.environment.privileged)
        try await ui.waitUntil("availability") { lock.state == .locked }
        await lock.unlock()
        XCTAssertEqual(lock.state, .unlocked)
        let owner = PermissionsLock(isOwnedByCurrentUser: true, privileged: ui.context.environment.privileged)
        XCTAssertEqual(owner.state, .notNeeded)
        let none = PermissionsLock(isOwnedByCurrentUser: false, privileged: nil)
        try await ui.waitUntil("unavailable") { none.state == .unavailable }
        let a = try ui.file("a.txt")
        let model = ACLEditorModel(url: a, context: ui.context, elevated: { lock.state == .unlocked })
        try await ui.waitUntil("loaded") { model.isLoaded }
        let request = model.request(for: [ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: [.readData])])
        XCTAssertTrue(request.elevated)
    }
    func testCancelledUnlockStaysLocked() async throws {
        let ui = try await ContentTestHarness.make(self, privileged: .emulated)
        let op = try XCTUnwrap(ui.context.environment.privileged as? EmulatedPrivilegedOperator)
        op.nextAuthorization = .failure(.cancelledByUser)
        let lock = PermissionsLock(isOwnedByCurrentUser: false, privileged: op)
        try await ui.waitUntil("locked") { lock.state == .locked }
        await lock.unlock()
        XCTAssertEqual(lock.state, .locked)
    }
}
```

`ContentTestHarness.make(_:privileged:)` is an additive overload; `.emulated` builds the sandboxed environment with `privileged: EmulatedPrivilegedOperator(root: sandbox.root)` (P4-17 put the parameter on `CoreEnvironment`). `isLoaded`, `canEdit(row:)` and `request(for:)` are internal seams on the model.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter UITests.ACLEditorTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'ACLEditorModel' in scope`.

- [ ] **Step 3: Implement**

`ACLEditorModel`:
- `load()` reads `ACLIO.read` on a lane and sets `entries` and `isLoaded`.
- Each edit computes the new explicit list (`entries.filter { !$0.isInherited }` with the change applied), performs `request(for:)` via `OperationsCenter.perform`, then reloads. `request(for:)` returns `JobRequest(.setAttributes([url], .acl(list)), origin: originForProperties, elevated: elevated())`.
- `principals` loads `PrincipalDirectory.all` once.

`PermissionsLock(isOwnedByCurrentUser:privileged:)` computes its initial state; for the non-owner case it awaits `privileged?.availability()` in a `Task`.

`ACLEditorView` (SwiftUI): a `Table` over `entries` with the four columns, the +/− buttons, an `.onDoubleClick`-style `contextMenu`/primary action opening `ACLEntrySheet`, and the padlock (`Button` with `lock.fill`/`lock.open.fill` and accessibility label "Lock" / "Unlock").

`PropertiesView` places the lock at the section's top right and disables the mode checkboxes, owner/group popups and ACL controls unless `lock.state` is `.notNeeded` or `.unlocked`.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "UITests.ACLEditorTests|UITests.PropertiesViewModelTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 5: Build, then commit**

```bash
swift build 2>&1 | tail -5
git add Sources/UI Tests/UITests
git commit -m "feat: ACL editor and unlockable permissions in Properties using elevated jobs"
```

### Task P4-19: Network (Connect to Server, Bonjour SMB browsing, UNC paths)

**Files:**
- Create: `Sources/Core/Network/ServerAddress.swift`, `Sources/Core/Network/NetworkMounting.swift`, `Sources/Core/Network/NetFSMounter.swift`, `Sources/Core/Network/HostBrowser.swift`, `Sources/UI/Network/ConnectToServerView.swift`, `Sources/UI/Network/ConnectToServerWindowController.swift`
- Modify: `Sources/Core/Settings/Settings.swift` (`recentServers`, `favoriteServers`, `noteServerUsed`), `Sources/Core/Support/LaunchOptions.swift` (`--fake-network <dir>`), `Sources/Core/Support/CoreEnvironment.swift` (`mounter`, `hostBrowser`), `Sources/UI/Toolbar/AddressBarView.swift` (UNC and URL input), `Sources/UI/Sidebar/SidebarViewController.swift` (Locations › Network row), `Sources/UI/Commands/FileCommandController.swift` and `Sources/App/AppDelegate.swift` (`macx_connectToServer:`), `Sources/Core/Commands/CommandAvailability.swift` (`.connectToServer` shipped), `Resources/Info.plist` (`NSLocalNetworkUsageDescription`, `NSBonjourServices`)
- Test: `Tests/CoreTests/Network/ServerAddressTests.swift`, `Tests/CoreTests/Network/NetworkFlowTests.swift`, `Tests/UITests/ConnectToServerTests.swift`

**Interfaces:**
- Consumes: NetFS (`NetFSMountURLAsync`, `NetFSMountURLCancel`), Network (`NWBrowser`, `NWConnection`), `Volumes.refresh()` (S1/S2), `BrowserWindowController.navigate(to:)`.
- Produces: §3.9 in full; `LaunchOptions.fakeNetworkRoot`; `@MainActor @Observable final class ConnectToServerModel { init(context: UIContext); var addressText: String; var state: State (idle, connecting, failed(MountError)); var nearby: [DiscoveredHost]; func connect() async -> URL?; func connect(to host: DiscoveredHost) async -> URL?; func cancel(); func toggleFavorite(); func startBrowsing(); func stopBrowsing() }`; `AddressBarParser.serverAddress(from text: String) -> ServerAddress?` (internal).

**Behaviour:**
- `ServerAddress(parsing:)` trims whitespace, then accepts:
  - `smb://`, `cifs://` (→ smb), `afp://` and `nfs://` URLs with optional `user[:password]@`, `[ipv6]`, `:port` and a path.
  - `\\host\share\sub` and `//host/share` (UNC; → smb).
  - A bare `host` or `host/share` (→ smb).
  - It rejects everything else (other schemes, empty host, spaces in the host).
  - Hosts are lowercased; percent-encoded paths are decoded for `path` and re-encoded by `url`.
- `displayString` is `scheme://[user@]host[:port]path`, without the password. `recentServers` stores `displayString` values, most recent first, deduplicated, at most 10. Passwords live only in memory for one connect call; NetFS and the system keychain UI handle saving them.
- `NetFSMounter.mount(_:allowUI:)` calls `NetFSMountURLAsync(url, nil, user, password, openOptions, mountOptions, &requestID, .main, callback)`. `openOptions` contains `kNAUIOptionKey: kNAUIOptionAllowUI` when `allowUI`, otherwise `kNAUIOptionNoUI`. The callback's status maps to `MountError`: `ECANCELED`/`userCanceledErr` → `.cancelled`, `EAUTH`/`EACCES` → `.authenticationFailed`, `EHOSTUNREACH`/`ENOENT` → `.hostNotFound`, other → `.failed(code)`. Task cancellation calls `NetFSMountURLCancel(requestID)`. On success it returns the mount points and calls `volumes.refresh()`.
- `FakeNetworkMounter(root:)` returns `[root/<host>/<first path component>]` when that directory exists (tests create it in the sandbox). A missing host directory → `.hostNotFound`; a host named `auth-fail` → `.authenticationFailed`. It never creates anything.
- `BonjourSMBBrowser` wraps `NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)`. Results become `DiscoveredHost(id: "<name>.<domain>", name:)`, sorted by name and delivered on main. `resolve(_:)` opens an `NWConnection` to the service endpoint, waits for `.ready` (≤ 5 s), reads `currentPath?.remoteEndpoint` (`.hostPort(host, _)`) and returns `ServerAddress(parsing: "smb://\(host)")`, then cancels the connection. It is started only while the Connect window is visible or the Network location is shown, never at launch, so the local-network permission prompt appears only when the user asks for it.
- `FakeHostBrowser(hosts:)` delivers `hosts` once on `start` and resolves a host `h` to `smb://<h.name>`. With `--fake-network <dir>`, `CoreEnvironment` uses `FakeNetworkMounter(root: dir)` and `FakeHostBrowser(hosts: <subdirectory names of dir>)`; `--fake-network` requires `--state-dir`.
- The ⌘K window is a single non-modal panel (one instance). It has an address field with a recents dropdown, a Favorites list (+ / −), a "Nearby" list (Bonjour hosts), and Connect/Cancel buttons. Connecting shows a spinner and disables the field; Cancel cancels the mount task. Success: `noteServerUsed`, close, and navigate the key browser window's active pane to the first mount point (open a new window if none). Failure shows inline text: "Couldn't connect to “host”." / "The user name or password is incorrect." / "The server wasn't found.".
- Address bar: when the typed text isn't an existing path and `AddressBarParser.serverAddress(from:)` parses it (UNC or a URL with a network scheme), the bar shows a spinner, mounts with `allowUI: true` and navigates to `<mountPoint>/<rest of path>` (the path after the share). A failure shows the same texts in the address bar's error popover (Phase 1 error style).
- Locations › Network: a sidebar row ("Network", `network` SF Symbol). Clicking it opens the Connect window scrolled to Nearby.
- Info.plist: `NSLocalNetworkUsageDescription` = "macExplorer looks for file servers on your network when you open Connect to Server."; `NSBonjourServices` = `["_smb._tcp"]`.

- [ ] **Step 1: Write the failing parser tests**

```swift
import XCTest
@testable import Core

final class ServerAddressTests: XCTestCase {
    func testParsingTable() {
        let cases: [(String, String?)] = [
            ("smb://NAS.local/Share", "smb://nas.local/Share"),
            ("cifs://nas/share/sub dir", "smb://nas/share/sub dir"),
            ("afp://user@mac.local:548/Vol", "afp://user@mac.local:548/Vol"),
            ("nfs://10.0.0.5/export", "nfs://10.0.0.5/export"),
            (#"\\fileserver\team\docs"#, "smb://fileserver/team/docs"),
            ("//fileserver/team", "smb://fileserver/team"),
            ("nas.local", "smb://nas.local"),
            ("nas.local/media", "smb://nas.local/media"),
            ("smb://[fe80::1%25en0]/s", "smb://fe80::1%en0/s"),
            ("  smb://nas/s  ", "smb://nas/s"),
            ("http://nas/s", nil), ("smb://", nil), ("", nil), ("smb://bad host/s", nil), (#"\\"#, nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ServerAddress(parsing: input)?.displayString, expected, input)
        }
    }
    func testPasswordIsNeverDisplayedOrPersisted() throws {
        let a = try XCTUnwrap(ServerAddress(parsing: "smb://alice:s3cret@nas/share"))
        XCTAssertEqual(a.user, "alice"); XCTAssertEqual(a.password, "s3cret")
        XCTAssertEqual(a.displayString, "smb://alice@nas/share")
        XCTAssertNil(a.withoutPassword.password)
        XCTAssertTrue(a.url.absoluteString.contains("s3cret"))
        let data = try JSONEncoder().encode(a)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("s3cret"))     // Codable drops the password
    }
    func testURLPercentEncodingRoundTrip() throws {
        let a = try XCTUnwrap(ServerAddress(parsing: "smb://nas/My Share/a#b"))
        XCTAssertEqual(a.path, "/My Share/a#b")
        XCTAssertEqual(a.url.absoluteString, "smb://nas/My%20Share/a%23b")
    }
    @MainActor func testRecentServers() {
        let s = Settings(storage: InMemorySettingsStorage())
        for i in 0..<12 { s.noteServerUsed(ServerAddress(parsing: "smb://h\(i)/s")!) }
        s.noteServerUsed(ServerAddress(parsing: "smb://u:p@h5/s")!)
        XCTAssertEqual(s.recentServers.count, 10)
        XCTAssertEqual(s.recentServers.first, "smb://u@h5/s")
        XCTAssertFalse(s.recentServers.contains { $0.contains(":p@") })
    }
}
```

`ServerAddress`'s `Codable` conformance encodes every field except `password` (custom `CodingKeys` without it).

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.ServerAddressTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'ServerAddress' in scope`.

- [ ] **Step 3: Implement `ServerAddress`**

Parse in this order:
1. A leading `\\` or `//` → UNC: split the rest on `\` or `/`; the first part is the host, the rest is the path.
2. Contains `://` → `URLComponents`. The scheme is lowercased and must be in `smb`/`cifs`/`afp`/`nfs`. The host comes from `components.host` (brackets stripped, `%25` → `%` for zone IDs). Then `port`, `user`, `password` and `path` (`components.path`, already decoded). If `URLComponents` rejects the string because of spaces in the path, percent-encode the part after the authority with `.urlPathAllowed` and retry once.
3. Otherwise a bare `host[/path]`.

The host must be non-empty and contain no whitespace or `/`. `url` rebuilds with `URLComponents` (`percentEncodedPath` from `path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["#", "?"]))`; IPv6 hosts are re-bracketed). `displayString` uses the decoded path.

Run: `swift test --filter CoreTests.ServerAddressTests 2>&1 | tail -5` → `Executed 4 tests, with 0 failures`.

- [ ] **Step 4: Write the failing flow tests (fakes only, no network)**

```swift
import XCTest
@testable import Core
@testable import UI
import MacxFixtures

@MainActor final class NetworkFlowTests: XCTestCase {
    func testFakeMounterResolvesInsideRootAndMapsErrors() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.createDirectory("net/nas/media/movies")
        let m = FakeNetworkMounter(root: sandbox.url("net"))
        let points = try await m.mount(ServerAddress(parsing: "smb://nas/media/movies")!, allowUI: false)
        XCTAssertEqual(points.map { $0.standardizedFileURL.path }, [sandbox.url("net/nas/media").standardizedFileURL.path])
        do { _ = try await m.mount(ServerAddress(parsing: "smb://ghost/x")!, allowUI: false); XCTFail() }
        catch { XCTAssertEqual(error, .hostNotFound) }
        do { _ = try await m.mount(ServerAddress(parsing: "smb://auth-fail/x")!, allowUI: false); XCTFail() }
        catch { XCTAssertEqual(error, .authenticationFailed) }
    }
    func testConnectModelNavigatesAndRecordsRecent() async throws {
        let ui = try await ContentTestHarness.make(self, network: .fake(hosts: ["nas"]))   // harness: FakeNetworkMounter(root: sandbox/net)
        try ui.dir("net/nas/media/movies")
        let window = try await ui.openBrowserWindow()
        let model = ConnectToServerModel(context: ui.context)
        model.addressText = #"\\nas\media\movies"#
        let target = await model.connect()
        XCTAssertEqual(target?.lastPathComponent, "movies")
        try await ui.waitUntil("navigated") { window.probeFolderURL.lastPathComponent == "movies" }
        XCTAssertEqual(ui.context.environment.settings.recentServers.first, "smb://nas/media/movies")
    }
    func testConnectFailureStateAndCancel() async throws {
        let ui = try await ContentTestHarness.make(self, network: .fake(hosts: []))
        let model = ConnectToServerModel(context: ui.context)
        model.addressText = "smb://ghost/s"
        XCTAssertNil(await model.connect())
        XCTAssertEqual(model.state, .failed(.hostNotFound))
        model.addressText = "ftp://x"
        XCTAssertNil(await model.connect())
        XCTAssertEqual(model.state, .failed(.unsupportedScheme))
    }
    func testNearbyListFromFakeBrowserAndResolve() async throws {
        let ui = try await ContentTestHarness.make(self, network: .fake(hosts: ["beta", "alpha"]))
        try ui.dir("net/alpha/share")
        let model = ConnectToServerModel(context: ui.context)
        model.startBrowsing()
        try await ui.waitUntil("hosts") { model.nearby.map(\.name) == ["alpha", "beta"] }
        model.stopBrowsing()
        // A host without a share path mounts the host root folder in the fake; the real browser lists shares in NetFS's UI.
        let host = model.nearby[0]
        XCTAssertEqual(await ui.context.environment.hostBrowser().resolve(host)?.displayString, "smb://alpha")
    }
    func testAddressBarParserOnlyClaimsNetworkInput() {
        XCTAssertNotNil(AddressBarParser.serverAddress(from: #"\\nas\share"#))
        XCTAssertNotNil(AddressBarParser.serverAddress(from: "smb://nas/share"))
        XCTAssertNil(AddressBarParser.serverAddress(from: "/Users/Shared"))
        XCTAssertNil(AddressBarParser.serverAddress(from: "~/Documents"))
        XCTAssertNil(AddressBarParser.serverAddress(from: "Documents"))                   // bare words stay folder names
    }
    func testFakeNetworkOptionRequiresStateDir() {
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--fake-network", "/tmp/macx-scenario-x/net"]))
    }
}
```

`ContentTestHarness.make(_:network:)` is additive; `.fake(hosts:)` sets `mounter = FakeNetworkMounter(root: sandbox/net)` and `hostBrowser = { FakeHostBrowser(hosts: …) }`. The address bar accepts bare hosts only with a network scheme or UNC prefix, unlike the Connect window, so a typed folder name never triggers a mount.

- [ ] **Step 5: Run to verify they fail**

Run: `swift test --filter "CoreTests.NetworkFlowTests|UITests.ConnectToServerModelTests" 2>&1 | tail -5`
Expected: build failure, `cannot find 'FakeNetworkMounter' in scope`.

`CoreTests` can't import `UI`, so split the block above: `Tests/CoreTests/Network/NetworkFlowTests.swift` (`import Core` only) gets `testFakeMounterResolvesInsideRootAndMapsErrors` and `testFakeNetworkOptionRequiresStateDir`; the other four tests go into `Tests/UITests/ConnectToServerTests.swift` as `final class ConnectToServerModelTests`. Keep the test names.

- [ ] **Step 6: Implement mounters, browsers, model, window, address bar and sidebar row**

Write per **Behaviour**. The Connect window's SwiftUI view binds to `ConnectToServerModel`; `ConnectToServerWindowController.shared(context:)` keeps one instance and calls `model.startBrowsing()` in `windowDidBecomeKey` and `stopBrowsing()` in `windowWillClose`. Accessibility identifiers: `macx.connect.address`, `macx.connect.connect`, `macx.connect.cancel`, `macx.connect.nearby`.

`NetFSMounter` bridges the C callback with a `CheckedContinuation` held in a `Mutex`-guarded box. `withTaskCancellationHandler` calls `NetFSMountURLCancel` on the stored request ID.

- [ ] **Step 7: Write and run the UI test**

```swift
@MainActor final class ConnectToServerTests: XCTestCase {
    func testCommandOpensSingleWindowAndAddressBarUNC() async throws {
        try XCTSkipUnless(NSScreen.main != nil, "needs a window server")
        let ui = try await ContentTestHarness.make(self, network: .fake(hosts: ["nas"]))
        try ui.dir("net/nas/share/docs")
        let window = try await ui.openBrowserWindow()
        NSApp.sendAction(Selector(Command.connectToServer.selectorName), to: nil, from: nil)
        NSApp.sendAction(Selector(Command.connectToServer.selectorName), to: nil, from: nil)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "macx.connect" && $0.isVisible }.count, 1)
        await window.addressBar.submitForTesting(#"\\nas\share\docs"#)
        try await ui.waitUntil("navigated") { window.probeFolderURL.lastPathComponent == "docs" }
    }
}
```

Run: `swift test --filter "ServerAddressTests|NetworkFlowTests|ConnectToServerModelTests|ConnectToServerTests" 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 8: Build, then commit**

```bash
swift build 2>&1 | tail -5
plutil -lint Resources/Info.plist
git add Sources Tests Resources/Info.plist
git commit -m "feat: Connect to Server with NetFS, Bonjour SMB browsing, UNC paths in the address bar"
```

### Task P4-20: Sparkle 2 auto-update

**Files:**
- Modify: `Package.swift` (Sparkle dependency, `macExplorer` target product and rpath; §1), `Package.resolved` (pinned), `Resources/Info.plist` (templated `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`), `scripts/bundle.sh` (embed `Sparkle.framework`, render the SU keys), `scripts/check-layering.sh` (Sparkle only in `Sources/App`), `Sources/Core/Commands/CommandAvailability.swift` (`.checkForUpdates` shipped), `Sources/UI/Menus/MainMenuBuilder.swift` (App › Check for Updates…), `Sources/App/AppDelegate.swift`
- Create: `Sources/Core/Support/UpdaterPolicy.swift`, `Sources/App/Updater.swift`
- Test: `Tests/CoreTests/UpdaterPolicyTests.swift`

**Interfaces:**
- Consumes: `LaunchOptions` (`isSandboxed`), `Bundle.main.infoDictionary`, Sparkle (`SPUStandardUpdaterController`, `SPUUpdater.canCheckForUpdates`).
- Produces: §3.10 `UpdaterPolicy`; `@MainActor final class Updater { init(options: LaunchOptions, infoDictionary: [String: Any]); var isRunning: Bool; func checkForUpdates() }` (App target); `CommandState.updaterAvailable` filled from `updater.isRunning && controller.updater.canCheckForUpdates`.

**Behaviour:**
- `UpdaterPolicy.shouldStart` is false when `options.isSandboxed` (any `--state-dir`, so tests, scenarios and smoke runs), when `SUFeedURL` is missing, empty or not `https`, or when `SUPublicEDKey` is missing or not 44 base64 characters (a 32-byte Ed25519 key). Everything else is true.
- `Updater.init` creates `SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)` only when the policy says yes, then calls `startUpdater()` (errors are logged; `isRunning` stays false). When the policy says no, Sparkle is never touched: no controller, no background checks, no network.
- Sparkle's own preferences apply: the first launch doesn't check, the second launch asks "Check for updates automatically?". `SUEnableAutomaticChecks` is not set in Info.plist, so Sparkle asks.
- App › "Check for Updates…" calls `updater.checkForUpdates()` (Sparkle's standard UI). The item is hidden when `!updater.isRunning`.
- `bundle.sh`:
  - Copies `Sparkle.framework` from the SwiftPM artifact (`find .build/artifacts -path '*macos-arm64_x86_64/Sparkle.framework' -maxdepth 6`) to `Contents/Frameworks/` with `ditto` (keeps symlinks and the XPC services).
  - Renders `SUFeedURL` from `$MACX_FEED_URL` and `SUPublicEDKey` from `$MACX_ED_PUBLIC_KEY`. When either is empty, it deletes both keys (`plutil -remove`), so dev builds never update.
  - Ad-hoc signs inside-out in dev (`codesign --force --sign -`). Order: `Sparkle.framework/Versions/B/XPCServices/Installer.xpc`, `Downloader.xpc`, `Autoupdate`, `Updater.app`, the framework, `macx-helper`, the app. P4-21's `sign.sh` does the same with Developer ID.
- `check-layering.sh` fails when `grep -rl "^import Sparkle" Sources | grep -v '^Sources/App/'` prints anything, or when `Sources/MacxHelper*`/`Sources/macx-helper` import AppKit, SwiftUI or Sparkle.

- [ ] **Step 1: Write the failing policy tests**

```swift
import XCTest
@testable import Core

final class UpdaterPolicyTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private func info(_ feed: String?, _ k: String?) -> [String: Any] {
        var d: [String: Any] = [:]; if let feed { d["SUFeedURL"] = feed }; if let k { d["SUPublicEDKey"] = k }; return d
    }
    func testTable() throws {
        let normal = LaunchOptions()
        let sandboxed = try LaunchOptions.parse(["macExplorer", "--root", "/tmp/macx-scenario-x", "--state-dir", "/tmp/macx-scenario-x/state"])
        let feed = "https://github.com/OWNER/macExplorer/releases/latest/download/appcast.xml"
        XCTAssertTrue(UpdaterPolicy.shouldStart(options: normal, infoDictionary: info(feed, key)))
        XCTAssertFalse(UpdaterPolicy.shouldStart(options: sandboxed, infoDictionary: info(feed, key)))
        XCTAssertFalse(UpdaterPolicy.shouldStart(options: normal, infoDictionary: info(nil, key)))
        XCTAssertFalse(UpdaterPolicy.shouldStart(options: normal, infoDictionary: info("", key)))
        XCTAssertFalse(UpdaterPolicy.shouldStart(options: normal, infoDictionary: info("http://example.com/appcast.xml", key)))
        XCTAssertFalse(UpdaterPolicy.shouldStart(options: normal, infoDictionary: info(feed, nil)))
        XCTAssertFalse(UpdaterPolicy.shouldStart(options: normal, infoDictionary: info(feed, "short")))
        XCTAssertFalse(UpdaterPolicy.shouldStart(options: normal, infoDictionary: info(feed, "@MACX_ED_PUBLIC_KEY@")))
    }
    func testTestProcessNeverStartsSparkle() {
        XCTAssertFalse(UpdaterPolicy.shouldStart(options: LaunchOptions(), infoDictionary: Bundle.main.infoDictionary ?? [:]))
    }
}
```

The test bundle's `Bundle.main` is `xctest`, which has no `SUFeedURL`, so the second test pins that the test process never starts Sparkle.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CoreTests.UpdaterPolicyTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'UpdaterPolicy' in scope`.

- [ ] **Step 3: Implement the policy**

```swift
import Foundation

public enum UpdaterPolicy {
    public static func shouldStart(options: LaunchOptions, infoDictionary: [String: Any]) -> Bool {
        guard !options.isSandboxed else { return false }
        guard let feed = infoDictionary["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme == "https", url.host != nil
        else { return false }
        guard let key = infoDictionary["SUPublicEDKey"] as? String, key.count == 44,
              let raw = Data(base64Encoded: key), raw.count == 32 else { return false }
        return true
    }
}
```

Run: `swift test --filter CoreTests.UpdaterPolicyTests 2>&1 | tail -5` → `Executed 2 tests, with 0 failures`.

- [ ] **Step 4: Add the dependency and the updater**

Edit `Package.swift` per §1. Run `swift package resolve`, then confirm `Package.resolved` pins one exact Sparkle version (`grep -A3 '"sparkle"' Package.resolved`). Commit the file.

`Sources/App/Updater.swift`:

```swift
import AppKit
import Core
import Sparkle

@MainActor
final class Updater {
    private var controller: SPUStandardUpdaterController?
    private(set) var isRunning = false

    init(options: LaunchOptions, infoDictionary: [String: Any]) {
        guard UpdaterPolicy.shouldStart(options: options, infoDictionary: infoDictionary) else { return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do { try c.updater.start(); controller = c; isRunning = true }
        catch { NSLog("macExplorer: Sparkle did not start: %@", error.localizedDescription) }
    }
    var canCheck: Bool { isRunning && (controller?.updater.canCheckForUpdates ?? false) }
    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
```

`AppDelegate` owns `updater`, implements `@objc func macx_checkForUpdates(_:)`, and feeds `updaterAvailable` into the `CommandState` that menu validation uses for the App menu. `MainMenuBuilder` adds "Check for Updates…" after "About macExplorer", hidden by `AppDelegate` when `!updater.isRunning`. Add `.checkForUpdates` to `shippedPhase4Commands`.

`Resources/Info.plist` gains `<key>SUFeedURL</key><string>@MACX_FEED_URL@</string>` and `<key>SUPublicEDKey</key><string>@MACX_ED_PUBLIC_KEY@</string>`. `bundle.sh` replaces or removes them (see **Behaviour**). The placeholder strings also fail the policy, so an unrendered plist can never start Sparkle.

- [ ] **Step 5: Bundle and layering checks**

```bash
swift build 2>&1 | tail -5
scripts/bundle.sh --debug > /dev/null
APP=.build/debug/macExplorer.app
test -d "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" && echo sparkle-ok
otool -l "$APP/Contents/MacOS/macExplorer" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks' && echo rpath-ok
plutil -extract SUFeedURL raw "$APP/Contents/Info.plist" 2>&1 | grep -q "No value" && echo no-feed-in-dev
codesign --verify --deep --strict "$APP" && echo sig-ok
scripts/check-layering.sh && echo layering-ok
```

Expected: `sparkle-ok`, `rpath-ok`, `no-feed-in-dev`, `sig-ok`, `layering-ok`. Do not launch this bundle without the sandbox arguments; P4-23 runs it in sandbox mode only.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources Tests/CoreTests/UpdaterPolicyTests.swift Resources/Info.plist scripts/bundle.sh scripts/check-layering.sh
git commit -m "feat: Sparkle 2 updater gated by UpdaterPolicy, framework embedding and layering check"
```

### Task P4-21: Release pipeline (universal build, signing, notarization, packaging, appcast)

**Files:**
- Create: `scripts/release/common.sh`, `scripts/release/build-universal.sh`, `scripts/release/sign.sh`, `scripts/release/notarize.sh`, `scripts/release/package.sh`, `scripts/release/make-appcast.swift`, `scripts/release/verify-bundle.sh`, `scripts/release/dry-run.sh`, `scripts/release/selftest.sh`, `.github/workflows/release.yml`, `docs/release/checklist.md`, `scripts/release/entitlements.plist`
- Modify: `scripts/bundle.sh` (`--universal`, `--out <dir>`, `--version <x.y.z>`, `--build <n>`)

**Interfaces:**
- Consumes: `scripts/bundle.sh` (P1-42, P4-16, P4-20), Sparkle's `SUPublicEDKey` format (raw 32-byte Ed25519 public key, base64), CryptoKit `Curve25519.Signing`.
- Produces (CLI contracts):
  - `common.sh` (sourced): `release_init <dir>` (refuses unless `<dir>` is an existing, empty directory whose basename starts with `macx-release-` and whose parent is `$TMPDIR` or `$RUNNER_TEMP`), `require_ci` (refuses unless `$CI == true` and `$GITHUB_ACTIONS == true`), `is_dry_run`, `log`.
  - `build-universal.sh --out <dir> --version V --build N`: builds `macExplorer`, `macx-helper` for `arm64` and `x86_64` in release, then `bundle.sh --universal --out <dir>`; prints the app path.
  - `sign.sh --app <path> --identity <id|->`: inside-out codesign. With `-`, no timestamp and no hardened-runtime requirement checks.
  - `notarize.sh --zip <path>`: CI only. `xcrun notarytool submit --wait` with the App Store Connect API key from env, then `xcrun stapler staple` on the app; re-zips.
  - `package.sh --app <path> --out <dir> --version V`: `macExplorer-V.zip` (ditto) and `macExplorer-V.dmg` (`hdiutil create -fs HFS+ -format UDZO -srcfolder <staging> -volname macExplorer`), both inside `<dir>`.
  - `make-appcast.swift --zip <path> --version V --build N --url <download URL> --key <base64 private key file> --out <appcast.xml> [--min-system 26.0] [--date <RFC 822>]`; also `--verify --appcast <file> --zip <path> --public-key <base64>`, exits 0 when the signature verifies.
  - `verify-bundle.sh --app <path> [--notarized]`: `lipo -archs` contains both arches for the app and helper; `codesign --verify --deep --strict`; Info.plist keys; with `--notarized`, `spctl -a -t exec -vv` and `stapler validate`.
  - `dry-run.sh`: the whole pipeline locally (see Step 4). Exits 0 on success and always deletes its dir.

**Hard safety rules for these scripts** (enforced in `common.sh` and tested in `selftest.sh`):
- Every output path must be inside the dir given to `release_init`. Scripts compute absolute paths and refuse (exit 64) any `--out`/`--app`/`--zip` outside it.
- `--dry-run` (or `MACX_RELEASE_DRY_RUN=1`) forces `--identity -` and skips notarization, stapling, keychain commands (`security`), `gh` and `git push`. `notarize.sh` calls `require_ci` before anything else.
- `hdiutil create` runs only with `-srcfolder` inside the release dir, and the scripts never call `hdiutil attach`.
- No script deletes anything outside its release dir. `dry-run.sh` deletes its own dir in an `EXIT` trap after checking `release_init`'s rules again.

- [ ] **Step 1: Write the failing self-test**

`scripts/release/selftest.sh`:

```bash
#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/common.sh"
fail=0
expect_fail() { if ( "$@" ) >/dev/null 2>&1; then echo "FAIL: expected refusal: $*"; fail=1; else echo "ok: refused $*"; fi; }
expect_ok() { if ( "$@" ) >/dev/null 2>&1; then echo "ok: $*"; else echo "FAIL: expected success: $*"; fail=1; fi; }

work="$(mktemp -d "${TMPDIR%/}/macx-release-XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

expect_fail release_init /
expect_fail release_init "$HOME"
expect_fail release_init "${TMPDIR%/}"
expect_fail release_init "$(mktemp -d "${TMPDIR%/}/other-XXXXXX")"
touch "$work/nonempty"; expect_fail release_init "$work"; rm "$work/nonempty"
expect_ok release_init "$work"
release_init "$work"                                  # again outside a subshell: exports MACX_RELEASE_DIR for the checks below
CI= GITHUB_ACTIONS= expect_fail require_ci
MACX_RELEASE_DRY_RUN=1 expect_fail "$here/notarize.sh" --zip "$work/x.zip"
expect_fail "$here/package.sh" --app "$work/macExplorer.app" --out /tmp --version 1.0.0

# Appcast golden: fixed key, fixed date, fixed archive bytes.
printf 'macx-appcast-fixture' > "$work/macExplorer-1.2.3.zip"
key="$here/tests/ed25519-test-private.b64"           # test-only key, never used for releases
swift "$here/make-appcast.swift" --zip "$work/macExplorer-1.2.3.zip" --version 1.2.3 --build 42 \
  --url https://github.com/OWNER/macExplorer/releases/download/v1.2.3/macExplorer-1.2.3.zip \
  --key "$key" --out "$work/appcast.xml" --date "Mon, 02 Nov 2026 12:00:00 +0000"
if diff -u "$here/tests/expected-appcast.xml" "$work/appcast.xml"; then echo "ok: appcast golden"; else fail=1; fi
pub="$(cat "$here/tests/ed25519-test-public.b64")"
expect_ok swift "$here/make-appcast.swift" --verify --appcast "$work/appcast.xml" --zip "$work/macExplorer-1.2.3.zip" --public-key "$pub"
printf 'tampered' >> "$work/macExplorer-1.2.3.zip"
expect_fail swift "$here/make-appcast.swift" --verify --appcast "$work/appcast.xml" --zip "$work/macExplorer-1.2.3.zip" --public-key "$pub"

exit $fail
```

Ed25519 signatures are deterministic (RFC 8032), so the golden is stable. Generate the test key pair once with a 10-line Swift snippet (`Curve25519.Signing.PrivateKey()`, `rawRepresentation.base64EncodedString()`, `publicKey.rawRepresentation…`), store both under `scripts/release/tests/`, and add a README line there: "Test-only key. Never configure it as SUPublicEDKey." Generate `expected-appcast.xml` from the first green run after reviewing it by hand.

Run: `bash scripts/release/selftest.sh`
Expected first: fails (`common.sh: No such file or directory`).

- [ ] **Step 2: Implement `common.sh`, `make-appcast.swift` and the per-step scripts**

`common.sh`:

```bash
#!/bin/bash
# Sourced by every release script. Safety guards first; nothing here deletes anything.
set -euo pipefail
log() { printf '[release] %s\n' "$*" >&2; }
is_dry_run() { [[ "${MACX_RELEASE_DRY_RUN:-0}" == 1 ]]; }
require_ci() {
  [[ "${CI:-}" == true && "${GITHUB_ACTIONS:-}" == true ]] || { log "refusing: CI-only step"; return 64; }
  is_dry_run && { log "refusing: dry run"; return 64; }
  return 0
}
_abs() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); }
release_init() {
  local dir; dir="$(_abs "$1")" || return 64
  local parent base tmp="${TMPDIR:-}" rt="${RUNNER_TEMP:-}"
  parent="$(dirname "$dir")"; base="$(basename "$dir")"
  [[ -d "$dir" && "$base" == macx-release-* ]] || { log "refusing $dir: not a macx-release-* dir"; return 64; }
  [[ ( -n "$tmp" && "$parent" == "$(cd "$tmp" && pwd -P)" ) || ( -n "$rt" && "$parent" == "$(cd "$rt" && pwd -P)" ) ]] \
    || { log "refusing $dir: parent must be \$TMPDIR or \$RUNNER_TEMP"; return 64; }
  [[ -z "$(ls -A "$dir")" ]] || { log "refusing $dir: not empty"; return 64; }
  export MACX_RELEASE_DIR="$dir"
}
require_inside() {
  local p; p="$(_abs "$1")" || return 64
  [[ -n "${MACX_RELEASE_DIR:-}" && "$p" == "$MACX_RELEASE_DIR"/* ]] || { log "refusing $1: outside the release dir"; return 64; }
}
```

The per-step scripts start with `source common.sh`. They take `MACX_RELEASE_DIR` from the environment (set by `dry-run.sh` or the workflow) and call `require_inside` on every path argument. `package.sh --out /tmp` therefore fails, as the self-test expects.

`make-appcast.swift` (runs with `swift <file>`; Foundation + CryptoKit only):
- Read the zip, sign its bytes with `Curve25519.Signing.PrivateKey(rawRepresentation: base64-decoded key file)`.
- Write:

  ```xml
  <?xml version="1.0" encoding="utf-8"?>
  <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
      <title>macExplorer</title>
      <item>
        <title>Version 1.2.3</title>
        <pubDate>Mon, 02 Nov 2026 12:00:00 +0000</pubDate>
        <sparkle:version>42</sparkle:version>
        <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
        <enclosure url="…" length="<bytes>" type="application/octet-stream" sparkle:edSignature="<base64 signature>"/>
      </item>
    </channel>
  </rss>
  ```

  Escape attribute values; `--date` defaults to now, formatted in RFC 822 with `en_US_POSIX`.
- `--verify` parses the XML with `XMLParser`, reads `sparkle:edSignature` and `length`, checks the length and `isValidSignature`, and exits 1 on any mismatch.

`sign.sh` signs in this order, each with `codesign --force --options runtime --timestamp --sign "$ID"` (dry run: `--sign -` and no `--timestamp`):
1. `Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc`
2. `…/Downloader.xpc` (with `--preserve-metadata=entitlements`)
3. `…/Versions/B/Autoupdate`
4. `…/Versions/B/Updater.app`
5. `Contents/Frameworks/Sparkle.framework`
6. `Contents/MacOS/macx-helper`
7. the app (with `scripts/release/entitlements.plist`, which is empty: no special entitlements)

It then runs `codesign --verify --deep --strict`.

`notarize.sh`: `require_ci`, then `xcrun notarytool submit "$zip" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait --timeout 30m`. It fails unless the status is `Accepted`, then runs `xcrun stapler staple "$app"`, re-zips with `ditto -c -k --keepParent` and prints the new zip path.

`package.sh` builds a staging folder `"$out/dmg-root"` with the app and an `Applications` symlink, runs `hdiutil create`, then removes the staging folder (inside the release dir).

- [ ] **Step 3: Universal build**

`bundle.sh --universal` uses `swift build -c release --arch arm64 --arch x86_64 --product macExplorer` and `--product macx-helper` (SwiftPM writes to `.build/apple/Products/Release/`). It writes `CFBundleShortVersionString`/`CFBundleVersion` from `--version`/`--build`. `--out <dir>` (required for universal) puts `macExplorer.app` there.

`verify-bundle.sh` checks `lipo -archs` prints `x86_64 arm64` (either order) for `Contents/MacOS/macExplorer`, `Contents/MacOS/macx-helper` and `Sparkle.framework/Versions/B/Sparkle`.

- [ ] **Step 4: `dry-run.sh`**

```bash
#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/common.sh"
export MACX_RELEASE_DRY_RUN=1
dir="$(mktemp -d "${TMPDIR%/}/macx-release-XXXXXX")"
release_init "$dir"
cleanup() { [[ "$(basename "$dir")" == macx-release-* ]] && rm -rf -- "$dir"; log "removed $dir"; }
trap cleanup EXIT
log "release dir: $dir"
version="0.0.0-dryrun"; build="1"
app="$("$here/build-universal.sh" --out "$dir" --version "$version" --build "$build")"
"$here/sign.sh" --app "$app" --identity -
"$here/verify-bundle.sh" --app "$app"
"$here/package.sh" --app "$app" --out "$dir" --version "$version"
swift -e 'import CryptoKit; let k = Curve25519.Signing.PrivateKey(); print(k.rawRepresentation.base64EncodedString()); print(k.publicKey.rawRepresentation.base64EncodedString())' > "$dir/ephemeral-key.txt"
sed -n 1p "$dir/ephemeral-key.txt" > "$dir/ephemeral-private.b64"; pub="$(sed -n 2p "$dir/ephemeral-key.txt")"
swift "$here/make-appcast.swift" --zip "$dir/macExplorer-$version.zip" --version "$version" --build "$build" \
  --url "https://example.invalid/macExplorer-$version.zip" --key "$dir/ephemeral-private.b64" --out "$dir/appcast.xml"
swift "$here/make-appcast.swift" --verify --appcast "$dir/appcast.xml" --zip "$dir/macExplorer-$version.zip" --public-key "$pub"
if [[ -x "$here/render-cask.sh" ]]; then                                   # P4-22
  sha="$(shasum -a 256 "$dir/macExplorer-$version.dmg" | cut -d' ' -f1)"
  "$here/render-cask.sh" --version "$version" --sha256 "$sha" --repo OWNER/macExplorer --out "$dir/macexplorer.rb"
  grep -q "sha256 \"$sha\"" "$dir/macexplorer.rb"
fi
ls -1 "$dir" >&2
log "dry run OK"
```

If `swift -e` is unavailable in the toolchain, write the 3-line key generator to `"$dir/genkey.swift"` and run `swift "$dir/genkey.swift"`.

Run: `bash scripts/release/dry-run.sh 2>&1 | tail -15`
Expected: the listing shows `macExplorer.app`, `macExplorer-0.0.0-dryrun.zip`, `macExplorer-0.0.0-dryrun.dmg` and `appcast.xml`, then `dry run OK` and `removed /…/macx-release-…`. Afterwards `ls -d "${TMPDIR%/}"/macx-release-* 2>/dev/null` prints nothing.

- [ ] **Step 5: The tag workflow and the checklist**

`.github/workflows/release.yml` (runs on `push: tags: ['v*']`, `runs-on: macos-26`, `permissions: contents: write`):
1. Checkout; `sudo xcode-select -s /Applications/Xcode_27.2.app`.
2. "keychain": create `$RUNNER_TEMP/macx-build.keychain-db` with a random password, import the Developer ID Application `.p12` from `secrets.DEVELOPER_ID_P12` (base64), set the partition list, add it to the search list. Write the App Store Connect API key to `$RUNNER_TEMP/asc.p8` and the Sparkle private key to `$RUNNER_TEMP/ed25519.b64`.
3. `dir=$(mktemp -d "$RUNNER_TEMP/macx-release-XXXXXX")`, `export MACX_RELEASE_DIR`; `release_init` via the scripts.
4. `swift test --parallel` (the full suite gates the release).
5. `MACX_TEAM_ID`, `MACX_FEED_URL=https://github.com/${{ github.repository }}/releases/latest/download/appcast.xml` and `MACX_ED_PUBLIC_KEY=${{ vars.SPARKLE_PUBLIC_KEY }}` → `build-universal.sh`, `sign.sh --identity "Developer ID Application: …"`, `package.sh` (zip), `notarize.sh`, `package.sh` again for the DMG from the stapled app, `xcrun notarytool submit` + `stapler` for the DMG, `verify-bundle.sh --notarized`.
6. `make-appcast.swift` with the release URL.
7. `gh release create "$GITHUB_REF_NAME" "$dir"/macExplorer-*.zip "$dir"/macExplorer-*.dmg "$dir"/appcast.xml --verify-tag --title "macExplorer ${GITHUB_REF_NAME#v}" --notes-file CHANGELOG-release.md`.
8. Always: `security delete-keychain "$RUNNER_TEMP/macx-build.keychain-db"` and remove the key files.
The tap job is added in P4-22.

`docs/release/checklist.md`: per-release manual steps on a signed build, run in a fresh macOS user account or VM:
- Install from the DMG.
- First-launch Gatekeeper check.
- Sparkle: install the previous version, check for updates, update, relaunch.
- Authenticate…: create a test folder owned by root with `sudo mkdir /Users/Shared/macx-checklist-<date>`, then New Folder inside it from the app → Authenticate… → helper approval in Login Items → success → undo → delete the test folder with `sudo rmdir`; touch nothing else.
- Connect to Server against a test share the tester set up.
- Bonjour Nearby list.
- Homebrew install (`brew install --cask <tap>/macexplorer`).
- Uninstall (`brew uninstall --zap`) in that account only.

- [ ] **Step 6: Run the self-test and the dry run, then commit**

Run: `bash scripts/release/selftest.sh` → every line `ok:`, exit 0.
Run: `bash scripts/release/dry-run.sh 2>&1 | tail -3` → `dry run OK` and `removed …`.

```bash
git add scripts/release scripts/bundle.sh .github/workflows/release.yml docs/release/checklist.md
git commit -m "feat: release pipeline scripts with dry-run, inside-out signing, notarization, DMG and signed appcast"
```

### Task P4-22: Homebrew cask (template, rendering, tap, submission doc)

**Files:**
- Create: `packaging/homebrew/macexplorer.rb.template`, `packaging/homebrew/tests/expected-cask.rb`, `scripts/release/render-cask.sh`, `packaging/homebrew-tap/README.md`, `packaging/homebrew-tap/.github/workflows/audit.yml`, `docs/release/homebrew-cask-submission.md`
- Modify: `scripts/release/selftest.sh` (cask golden), `.github/workflows/release.yml` (tap update job)

**Interfaces:**
- Consumes: P4-21 (`common.sh`, release artifacts named `macExplorer-<version>.dmg`, `dry-run.sh`'s optional render step).
- Produces: `render-cask.sh --version V --sha256 H --repo OWNER/REPO --out <file>` (refuses a malformed version, a sha256 that isn't 64 lowercase hex characters, a repo that isn't `owner/name`, and an `--out` outside `$MACX_RELEASE_DIR` unless `--out -` for stdout).

- [ ] **Step 1: Write the failing golden test**

Append to `selftest.sh` (before `exit $fail`):

```bash
sha="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
if "$here/render-cask.sh" --version 1.2.3 --sha256 "$sha" --repo OWNER/macExplorer --out - \
   | diff -u "$here/../../packaging/homebrew/tests/expected-cask.rb" -; then echo "ok: cask golden"; else fail=1; fi
expect_fail "$here/render-cask.sh" --version "1.2.3; rm -rf /" --sha256 "$sha" --repo OWNER/macExplorer --out -
expect_fail "$here/render-cask.sh" --version 1.2.3 --sha256 "XYZ" --repo OWNER/macExplorer --out -
expect_fail "$here/render-cask.sh" --version 1.2.3 --sha256 "$sha" --repo "not a repo" --out -
expect_fail "$here/render-cask.sh" --version 1.2.3 --sha256 "$sha" --repo OWNER/macExplorer --out /tmp/macexplorer.rb
```

`packaging/homebrew/tests/expected-cask.rb`:

```ruby
cask "macexplorer" do
  version "1.2.3"
  sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  url "https://github.com/OWNER/macExplorer/releases/download/v#{version}/macExplorer-#{version}.dmg"
  name "macExplorer"
  desc "Fast native file manager with Explorer-style navigation"
  homepage "https://github.com/OWNER/macExplorer"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "macExplorer.app"

  uninstall launchctl: "com.macexplorer.app.helper",
            quit:      "com.macexplorer.app"

  zap trash: [
    "~/Library/Application Support/macExplorer",
    "~/Library/Caches/com.macexplorer.app",
    "~/Library/HTTPStorages/com.macexplorer.app",
    "~/Library/Preferences/com.macexplorer.app.plist",
    "~/Library/Saved Application State/com.macexplorer.app.savedState",
  ]
end
```

`auto_updates true` tells Homebrew that Sparkle updates the app itself. `uninstall launchctl:` removes the helper daemon if the user approved it. The `zap` paths are the app's own state; they run only when a user explicitly runs `brew uninstall --zap`, never in our scripts or tests.

Run: `bash scripts/release/selftest.sh 2>&1 | tail -6`
Expected first: `FAIL` lines (`render-cask.sh: No such file or directory`).

- [ ] **Step 2: Implement the template and `render-cask.sh`**

The template is the golden with `@VERSION@`, `@SHA256@` and `@REPO@` placeholders. `render-cask.sh` sources `common.sh`, validates (`[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]`, `[[ $sha =~ ^[0-9a-f]{64}$ ]]`, `[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]`), substitutes with `sed` (no shell evaluation of the values), and writes to stdout or to `--out` after `require_inside`. If `brew` is installed locally, `brew style --cask <file>` runs as an extra check; it is skipped otherwise.

Run: `bash scripts/release/selftest.sh` → all `ok:`, exit 0.
Run: `bash scripts/release/dry-run.sh 2>&1 | tail -4` → the listing now includes `macexplorer.rb`, then `dry run OK`.

- [ ] **Step 3: Tap bootstrap files and the tap job**

`packaging/homebrew-tap/` holds the initial contents of the separate repository `OWNER/homebrew-macexplorer`. Its `README.md` covers `brew tap OWNER/macexplorer`, `brew install --cask macexplorer`, and that releases update `Casks/macexplorer.rb` automatically. `.github/workflows/audit.yml` runs on push and pull requests: `brew update`, `brew tap-new --no-git local/test`, then copy the cask and run `brew audit --cask --strict --online local/test/macexplorer` and `brew style --cask`.

Add a `tap` job to `release.yml` (`needs: release`):
1. Download `macExplorer-<version>.dmg` from the release, compute `shasum -a 256`.
2. `render-cask.sh` into `$RUNNER_TEMP/macx-release-tap-…/macexplorer.rb`.
3. Check out `OWNER/homebrew-macexplorer` with `secrets.TAP_TOKEN` (a fine-grained token limited to that repository, contents: write).
4. Copy to `Casks/macexplorer.rb`, commit "macexplorer <version>", push. This is the only `git push` anywhere, and it runs only on the GitHub runner.

- [ ] **Step 4: Submission document**

`docs/release/homebrew-cask-submission.md`:
- When to submit to `homebrew/homebrew-cask`: the project meets Homebrew's notability guidelines (see "Acceptable Casks" in Homebrew's docs: stars/forks/watchers thresholds for GitHub projects; the reviewer applies them), there have been at least two releases through the tap, and the app is signed and notarized.
- Steps: `brew bump-cask-pr` is not applicable to a first submission. Fork `homebrew-cask`, add `Casks/m/macexplorer.rb` from the tap, run `brew audit --cask --new --online macexplorer` and `brew style --fix`, then open the PR with the template filled in.
- After acceptance: switch the release workflow's tap job to `brew bump-cask-pr --version <v> macexplorer` (needs `HOMEBREW_GITHUB_API_TOKEN`), and keep the tap for prereleases.

- [ ] **Step 5: Commit**

```bash
git add packaging scripts/release .github/workflows/release.yml docs/release/homebrew-cask-submission.md
git commit -m "feat: Homebrew cask template, safe renderer with golden test, tap bootstrap and update job"
```

### Task P4-23: Phase 4 validation

**Files:**
- Create: `Sources/macx-scenarios/Scenarios/Phase4Scenarios.swift`, `scripts/verify-phase4.sh`, and the UI scenarios `Tests/Scenarios/p4-keymap-import.json` (+ `p4-keymap-import.keymap.json`), `p4-palette-new-folder.json`, `p4-tags-menu.json`, `p4-sidebar-tag-drop.json`, `p4-compress-zip.json`, `p4-extract-here.json`, `p4-extract-unsafe.json`, `p4-batch-rename-swap.json`, `p4-dual-pane-f5.json`, `p4-dual-pane-f6-same-folder.json`, `p4-authenticate-fake-helper.json`, `p4-connect-fake-server.json`
- Modify: `Sources/macx-scenarios/Scenarios/Catalog.swift` (`+ Phase4Scenarios.all`), `Tests/ScenarioRunnerTests/CatalogTests.swift` (Phase 4 families), `Sources/UI/Scenario/ScenarioFile.swift` (fixture fields `tags`, `archives`, `readOnlyDirs`; step `answerError`), `scripts/ui-scenarios.sh` (passes `--fake-helper` and `--fake-network <sandbox>/net` when a scenario lists them in `launchArguments`), `docs/release/checklist.md` (link from the working definition)

**Interfaces:**
- Consumes: everything above; the P1-40 `CoreScenario`/`ScenarioContext`/`Catalog` API; the P1-41 `ScenarioDriver` and `ui-scenarios.sh`; P4-02's `launchArguments`; P4-13's pane expectations.
- Produces: the Phase 4 "working" definition check (`scripts/verify-phase4.sh` exits 0).

- [ ] **Step 1: Core scenarios (headless)**

`Phase4Scenarios.swift` (each scenario uses only `ScenarioContext`'s sandbox helpers):

```swift
enum Phase4Scenarios {
    static let all: [CoreScenario] = [
        CoreScenario("tags.addToggleUndo") { ctx in
            let a = try ctx.file("work/a.txt"), b = try ctx.file("work/b.txt")
            _ = await ctx.perform(.setTags([a], .add(FileTag(name: "Red", color: .red))))
            _ = await ctx.perform(.setTags([a, b], .toggle(FileTag(name: "Red", color: .red))))
            try ctx.expect(try await ctx.onLane { try TagIO.read(b) } == [FileTag(name: "Red", color: .red)], "toggle added to all")
            try await ctx.undoAndWait()
            try ctx.expect(try await ctx.onLane { try TagIO.read(b) } == [], "undo removed")
        },
        CoreScenario("archive.compressExtractRoundTrip") { ctx in
            try ctx.file("work/photos/a.jpg", "A"); try ctx.file("work/photos/sub/b.jpg", "B")
            _ = await ctx.perform(.compress([ctx.url("work/photos")], .zip))
            try ctx.dir("out"); try ctx.rename("work/photos.zip", to: "out/photos.zip")
            let o = await ctx.perform(.extract(ctx.url("out/photos.zip")))
            try ctx.expect(o.created.map(\.lastPathComponent) == ["photos"], "extracted folder")
            try ctx.expect(ctx.text("out/photos/sub/b.jpg") == "B", "contents")
        },
        CoreScenario("archive.unsafeRefused") { ctx in
            try ctx.file("outside/keep.txt", "keep")
            try ctx.writeData("work/evil.tar", ScenarioArchives.traversalTar())
            let o = await ctx.perform(.extract(ctx.url("work/evil.tar")))
            try ctx.expect(o.created.isEmpty && ctx.names("work") == ["evil.tar"], "nothing written")
            try ctx.expect(ctx.text("outside/keep.txt") == "keep", "sibling unchanged")
        },
        CoreScenario("batchRename.cycleAndUndo") { ctx in
            try ctx.file("work/x.txt", "X"); try ctx.file("work/y.txt", "Y"); try ctx.file("work/z.txt", "Z")
            let pairs = [("x.txt", "y.txt"), ("y.txt", "z.txt"), ("z.txt", "x.txt")].map { BatchRenamePair(url: ctx.url("work/\($0.0)"), newName: $0.1) }
            _ = await ctx.perform(.batchRename(pairs))
            try ctx.expect(ctx.text("work/y.txt") == "X" && ctx.text("work/x.txt") == "Z", "cycle")
            try await ctx.undoAndWait()
            try ctx.expect(ctx.text("work/x.txt") == "X", "undo")
        },
        CoreScenario("batchRename.crashRecovery", requires: .helperProcess) { ctx in
            try ctx.file("work/a.txt", "A"); try ctx.file("work/b.txt", "B")
            try await ctx.crashBatchRename(["work/a.txt": "b.txt", "work/b.txt": "a.txt"], at: .batchRenameStaged)
            let report = await ctx.runLaunchRecovery()
            try ctx.expect(ctx.text("work/a.txt") == "A" && ctx.text("work/b.txt") == "B", "originals back")
            try ctx.expect(report.restoredRenames.count == 2, "reported")
        },
        CoreScenario("acl.editUndo") { ctx in
            let a = try ctx.file("work/a.txt")
            let e = ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset)
            _ = await ctx.perform(.setAttributes([a], .acl([e])))
            try ctx.expect(try await ctx.onLane { try ACLIO.read(a) } == [e], "written")
            try await ctx.undoAndWait()
            try ctx.expect(try await ctx.onLane { try ACLIO.read(a) } == [], "undone")
        },
        CoreScenario("privileged.emulatedAuthenticate") { ctx in
            try ctx.dir("work/ro"); try ctx.setMode("work/ro", 0o555)
            let env = ctx.environment(privileged: .emulated, errors: [.authenticate])
            let o = await env.operations.perform(JobRequest(.newItem(.folder, in: ctx.url("work/ro"))))
            try ctx.expect(o.record.elevated && o.created.count == 1, "created elevated")
        },
        CoreScenario("keymap.importRejectsConflicts") { _ in
            let bad = Data(#"{"format":"macexplorer-keymap","version":1,"base":"explorer","bindings":{"newFolder":{"primary":"cmd+l","alternates":[]}}}"#.utf8)
            do { _ = try KeymapDocument.import(bad); throw ScenarioFailure("accepted a conflicting keymap") }
            catch is KeymapImportError {}
        },
    ]
}
```

`ScenarioContext` additions (all inside its sandbox, same guard as P1-40): `writeData(_:_:)`, `setMode(_:_:)`, `onLane(_:)`, `undoAndWait()`, `runLaunchRecovery()`, `crashBatchRename(_:at:)` (re-executes `macx-scenarios crash-helper --mode batchRename …`, whose path check is unchanged), `environment(privileged:errors:)`. `ScenarioArchives.traversalTar()` is a copy of the 30-line tar writer from P4-10's `CraftedArchives` (the scenario target can't import test code).

Update `CatalogTests.testFamilies` to include `tags`, `archive`, `batchRename`, `acl`, `privileged` and `keymap`.

Run: `swift run macx-scenarios --filter tags. 2>&1 | tail -3`, then `scripts/run-scenarios.sh 2>&1 | tail -5`.
Expected: every Phase 4 scenario `passed`; the report's `sandboxRemoved` is true for all.

- [ ] **Step 2: UI scenarios**

`ScenarioFile` additions (all optional):
- `Fixture.tags: [String: [String]]?` (path → tag names, written with `TagIO` before the first step).
- `Fixture.archives: [String: String]?` (path → `"zip:<dir>"` or `"evil-tar"`, created by the driver inside the root).
- `Fixture.readOnlyDirs: [String]?` (mode 0o555; the driver restores u+w before teardown).
- `Step.answerError: String?` (`ErrorResolution` case name, answered through the `ScenarioInteraction` decorator).
- `Expectation.tags: [String: [String]]?`.
- `Expectation.sheetTitle`, `paneCount`, `activePane`, `otherPaneRows` and `otherPaneFolder` from P4-13.

Example, `Tests/Scenarios/p4-batch-rename-swap.json`:

```json
{"name": "p4-batch-rename-swap",
 "fixture": {"files": ["IMG_2.jpg", "IMG_1.jpg"], "dirs": []},
 "steps": [
   {"click": "IMG_1.jpg"}, {"click": "IMG_2.jpg", "modifiers": ["cmd"]},
   {"key": "F2"},
   {"waitFor": {"sheetTitle": "Rename 2 Items"}},
   {"type": "IMG_"},
   {"key": "tab"}, {"type": "Trip "},
   {"key": "return"},
   {"waitFor": {"rows": ["Trip 1.jpg", "Trip 2.jpg"]}, "timeoutMs": 3000},
   {"key": "cmd+z"},
   {"waitFor": {"rows": ["IMG_1.jpg", "IMG_2.jpg"]}, "timeoutMs": 3000}
 ]}
```

The other scenarios, one line each (steps use only the documented step kinds):

| File | Fixture | What it drives and checks |
|---|---|---|
| `p4-keymap-import` | `a.txt`; `launchArguments: ["--keymap", "p4-keymap-import.keymap.json"]` (binds `newFolder` to `cmd+opt+n`) | `cmd+opt+n` → rows contain `New Folder`; `cmd+shift+n` does nothing |
| `p4-palette-new-folder` | empty | `cmd+shift+p`, type `new fol`, `return` → rows `["New Folder"]` |
| `p4-tags-menu` | `a.txt` | right-click `a.txt`, `chooseMenuItem: "Red"` → `tags: {"a.txt": ["Red"]}`; `cmd+z` → `tags: {"a.txt": []}` |
| `p4-sidebar-tag-drop` | `a.txt`, `b.txt` | `drop: {sources: [a.txt, b.txt], onto: "sidebar:Blue"}` → both tagged Blue |
| `p4-compress-zip` | `photos/a.jpg` | select `photos`, `command: "compressZip"` → rows contain `photos.zip`, selection `["photos.zip"]` |
| `p4-extract-here` | `photos/a.jpg`, `dirs: ["work/photos"]`, `archives: {"work/photos.zip": "zip:photos"}` (the driver runs `ditto -c -k --keepParent <root>/photos`) | open `work`, `click: photos.zip`, `command: "extractHere"` → rows contain `photos 2` |
| `p4-extract-unsafe` | `archives: {"work/evil.tar": "evil-tar"}` (entry `../escape.txt`), `dirs: ["work"]` | open `work`, `click: evil.tar`, `command: "extractHere"`, `answerError: "skip"` → rows exactly `["evil.tar"]`, `filesAbsent: ["escape.txt"]` (the root, one level above `work`) |
| `p4-dual-pane-f5` | `L/a.txt`, `R/` | `cmd+shift+e`, navigate panes, `click a.txt`, `key F5` → `otherPaneRows: ["a.txt"]` |
| `p4-dual-pane-f6-same-folder` | `a.txt` | `cmd+shift+e`, `click a.txt`, `key F6` → rows `["a.txt"]`, `sheetPresent: false`, no operations capsule |
| `p4-authenticate-fake-helper` | `readOnlyDirs: ["ro"]`; `launchArguments: ["--fake-helper"]` | navigate into `ro`, `cmd+shift+n`, `answerError: "authenticate"` → rows `["New Folder"]` |
| `p4-connect-fake-server` | `net/nas/share/docs/`; `launchArguments: ["--fake-network", "net"]` | `cmd+l`, type `\\nas\share\docs`, `return` → `folder: "net/nas/share/docs"` |

`ui-scenarios.sh` resolves `launchArguments` values ending in `.json` (copied into the scenario sandbox, P4-02) and the special value `net` for `--fake-network` (rewritten to `<scenario root>/net`). It rejects any other absolute path.

Run: `scripts/ui-scenarios.sh --filter p4- 2>&1 | tail -15`
Expected: 12 scenarios `passed`.

- [ ] **Step 3: `scripts/verify-phase4.sh`**

```bash
#!/bin/bash
# Phase 4 "working" definition. Every artifact goes into one macx-verify-<UUID> dir that is removed at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="${TMPDIR%/}"
before="$(ls -1d "$tmp"/macx-* 2>/dev/null | sort || true)"
run="$(mktemp -d "$tmp/macx-verify-XXXXXX")"
trap '[[ "$(basename "$run")" == macx-verify-* ]] && rm -rf -- "$run"' EXIT
log() { printf '[verify-phase4] %s\n' "$*"; }

log "1/6 release build + full test suite"
swift build -c release 2>&1 | tee "$run/build.log" | tail -1
if grep -q "warning:" "$run/build.log"; then log "build has warnings"; exit 1; fi
swift test --parallel 2>&1 | tee "$run/test.log" | tail -3
grep -Eq "with 0 failures" "$run/test.log"

log "2/6 core and UI scenarios"
scripts/run-scenarios.sh > "$run/scenarios.log" 2>&1
scripts/ui-scenarios.sh > "$run/ui-scenarios.log" 2>&1
for f in Tests/Scenarios/p4-*.json; do
  n="$(basename "$f" .json)"; [[ "$n" == *.keymap ]] && continue
  grep -q "$n" "$run/ui-scenarios.log" || { log "scenario $n did not run"; exit 1; }
done

log "3/6 release dry run (universal, ad-hoc, zip, dmg, appcast, cask)"
bash scripts/release/selftest.sh > "$run/selftest.log" 2>&1
bash scripts/release/dry-run.sh > "$run/dry-run.log" 2>&1
grep -q "dry run OK" "$run/dry-run.log"

log "4/6 layering"
scripts/check-layering.sh

log "5/6 sandbox cleanliness"
after="$(ls -1d "$tmp"/macx-* 2>/dev/null | grep -v "^$run\$" | sort || true)"
if [[ "$before" != "$after" ]]; then
  log "leftover temp dirs:"; comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"); exit 1
fi
mount | grep -q "$tmp/macx-" && { log "a test disk image is still mounted"; exit 1; }

log "6/6 OK"
```

The cleanliness check compares the `macx-*` entries in `$TMPDIR` before and after. Every runner creates its own `macx-tests-*`/`macx-scenario-*`/`macx-release-*` dirs and must have removed them. Pre-existing entries (from an earlier interrupted run) are reported only if new ones appear, and the script never deletes anything it didn't create.

Run: `scripts/verify-phase4.sh 2>&1 | tail -8`
Expected: `6/6 OK`.

- [ ] **Step 4: Manual checklist pointer, then commit**

Add a "Phase 4" section to `docs/release/checklist.md` that lists the items automated tests can't cover (real helper install and approval, real SMB mount and Bonjour, Sparkle update between two signed builds, Gatekeeper on a notarized DMG) and says each runs on files and shares the tester creates for that purpose.

```bash
git add Sources/macx-scenarios Sources/UI/Scenario Tests/Scenarios Tests/ScenarioRunnerTests scripts docs/release/checklist.md
git commit -m "test: phase 4 core and UI scenarios, verify-phase4 working-definition script"
```
