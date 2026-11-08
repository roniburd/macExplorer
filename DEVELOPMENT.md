# MacExplorer: building, testing and releasing

For contributors and maintainers. Using the app? See the [README](README.md) and the [user guide](USER-GUIDE.md).

## Requirements

- macOS 26 (Tahoe) or later.
- Xcode 27.2 (Swift 6.4) for building. SwiftPM only, no Xcode project. The one third-party dependency is
  [Sparkle 2](https://sparkle-project.org) (binary SwiftPM package) for updates.

## Build and run

```bash
swift build -c release
scripts/bundle.sh release                 # assembles and ad-hoc signs .build/MacExplorer.app
open .build/MacExplorer.app
```

`scripts/bundle.sh [debug|release] [--bundle-id ID] [--output PATH] [--version X.Y.Z[-beta.N]] [--build N]
[--sign IDENTITY] [--feed-url URL] [--ed-public-key KEY] [--universal]` defaults to an ad-hoc signed debug build at
`.build/MacExplorer.app`, with version, build, feed URL and EdDSA key from `Resources/Info.plist`; `--universal`
builds arm64 + x86_64.

### Running against a sandbox folder

For trying things out, run the app on a throwaway folder so nothing you own is touched:

```bash
SB="$(mktemp -d "${TMPDIR%/}/macx-fixtures-XXXXXX")"
mkdir "$SB/root" && touch "$SB/root/a.txt" "$SB/root/b.txt"
.build/MacExplorer.app/Contents/MacOS/macExplorer --root "$SB/root" --state-dir "$SB/state" \
    --sandbox-trash "$SB/trash" --pasteboard "macx-fixtures-$$" --fake-launch-services --skip-onboarding
rm -rf "$SB"                              # afterwards
```

| Option | Effect |
|---|---|
| `--root <dir>` | the first window opens here; window restoration is off |
| `--state-dir <dir>` | journal, `settings.json` and recents live here (required with `--root` and `--scenario`) |
| `--sandbox-trash <dir>` | trashing moves items into this folder instead of the Trash |
| `--pasteboard <name>` | copy/cut/paste use a private pasteboard instead of the general one |
| `--fake-launch-services` | Open With and "Change All…" never change your real default apps |
| `--skip-onboarding` | no first-launch sheet |
| `--scenario <file.json>` / `--scenario-output <file>` | run one UI scenario and exit (used by `scripts/ui-scenarios.sh`) |
| `--smoke-exit-after <seconds>` | write `<state-dir>/smoke.json` and exit 0 |
| `--index-status enabled\|disabled\|unknown` | what the fake Spotlight index reports in a sandboxed run (default `disabled`); sandboxed runs never query the real index or download from iCloud |

`scripts/make-fixtures.sh` builds a larger fixture tree (NFD names, emoji, symlinks, packages, locked files…)
under a fresh `${TMPDIR}/macx-fixtures-<UUID>` and prints its path.

## Releasing (maintainers)

One-time setup:
1. `swift package resolve`, then `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. Put the printed public key in
   `Resources/Info.plist` › `SUPublicEDKey`. Export the private key (`generate_keys -x private.key`), store its
   contents in the repo secret `SPARKLE_ED_PRIVATE_KEY`, keep an offline backup, delete the file. Losing it means
   existing installs can't be updated.
2. Create an orphan `gh-pages` branch with an empty commit and enable GitHub Pages from it.
3. Create the public repo `roniburd/homebrew-macexplorer`; create a fine-grained token with *Contents: read and write*
   on that repo only; store it as `HOMEBREW_TAP_TOKEN`.
4. If the spike chose self-signed signing: create the certificate, store `SELF_SIGNED_P12` (base64),
   `SELF_SIGNED_P12_PASSWORD`, `SELF_SIGNED_IDENTITY`, and set `RELEASE_SIGNING: self-signed` in
   `.github/workflows/release.yml` (default `adhoc`).
5. Later, with an Apple Developer ID: add `DEVELOPER_ID_P12` (base64), `DEVELOPER_ID_P12_PASSWORD`,
   `NOTARY_API_KEY` (base64 .p8), `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER`. No workflow changes; then remove the
   quarantine note in README.md and the `caveats` block in `scripts/release/render-cask.sh`.

Each release: `git tag -a v0.3.0-beta.1 -m "…" && git push origin v0.3.0-beta.1` (beta) or `v0.3.0` (release).
Try the pipeline without publishing: Actions › Release › Run workflow (dry run). GitHub shows *Run workflow* only for
workflows on the repository's default branch, so `release.yml` has to be on the default branch first (tag pushes
don't need that: they run the workflow file at the tagged commit). `ci.yml`'s push trigger and its benchmark baseline
also watch `main`; if the default branch isn't `main`, rename it or change that trigger. A publishing run (a tag
push, or a dispatch with dry run off) stops before building unless `SUPublicEDKey` is set, `SPARKLE_ED_PRIVATE_KEY`
belongs to it, and `HOMEBREW_TAP_TOKEN` is set; until then only dry runs succeed.
The release does not re-run the tests: it waits (up to 50 min) for CI on the tagged commit
(`scripts/release/wait-for-ci.sh`) and stops if CI failed; fix or re-run CI, then re-run the release. Only when the
commit has no CI run, or its runs were all cancelled, does the release run `scripts/test-with-retry.sh` itself.

## Tests, scenarios and benchmarks

Every automated check works only inside temporary directories it creates itself (`${TMPDIR}/macx-*-<UUID>`) and
disk images it creates and mounts `-nobrowse` inside them. None of them touches your files, the Trash, the general
pasteboard or your default apps. Each runner prints the sandbox roots it used and deletes them.

| Command | What it checks |
|---|---|
| `swift test --parallel` | unit and integration tests (`FSKitTests`, `CoreTests`, `UITests`, `MacxFixturesTests`, `BenchTests`, `ScenarioRunnerTests`); GUI and `hdiutil` tests skip with a reason when unavailable |
| `scripts/run-scenarios.sh [debug\|release]` | headless end-to-end Core scenarios: every file operation, conflicts, undo, watcher bursts, cross-volume moves on disk images, crash/kill recovery, and the `search.*` family (crawler rules, filters, Stop, results following file operations, saved searches) |
| `scripts/ui-scenarios.sh` | the scripted UI scenarios in `Tests/Scenarios/` (Phase 1, the `p2-*` ones and the Phase 3 `search-*` / `preview-*` ones) driven inside the bundled app (needs a logged-in GUI session); a file's `indexStatus` is passed as `--index-status`, and Spotlight results come from the file's fake `spotlight` items |
| `scripts/ui-ax-smoke.sh` | optional Accessibility smoke through System Events; skips when the terminal lacks Accessibility permission |
| `swift run -c release macx-bench` | 1k/10k/100k benchmarks (model level, plus `listSorted.busyMain` with the main actor as busy as in the app, re-sorts with Group by on as `resort.grouped.*`, and the non-gated `folderSize.scan` of 10k files and `extattrs.read` of 2,000 files, and the Phase 3 `search-*` metrics: `--metrics search-` selects them, `search-filter-100k` is gated at 30 ms), median and p90 as JSON; `--check-budgets` gates §4.4 on Apple Silicon, `--compare baseline.json` applies the CI relative gate |
| `scripts/check-layering.sh` | `MacxFS`/`Core` never import AppKit or the Quick Look frameworks (except `Sources/Core/Platform`), layers only import downwards, fixtures never ship, tests never use global user state, Quick Look is exercised only from `UITests`, `NSMetadataQuery` and real iCloud downloads stay in their one file, tests use the fake Spotlight, nothing runs `mdimport` or changes the Spotlight index |
| `scripts/verify-phase1.sh` | every gate above in one run, then checks that nothing was left behind |

UI scenarios run in a separate bundle (`com.macexplorer.app.scenarios`, `.build/macExplorer-scenarios.app`), so
they never write the preferences of a real install. Scenario files use the schema in
`Sources/UI/Scenario/ScenarioFile.swift`.

CI (`.github/workflows/ci.yml`, `xcode-27` runner, Xcode 27.2) runs the layering checks, release and debug builds, the tests,
the bundle, both scenario runners and `macx-bench`. Shared runners are slow, so CI retries a failure once:
`scripts/test-with-retry.sh` runs `swift test --parallel` and re-runs each failed test case alone (not when more
than 5 failed, or on a build error), and both scenario runners re-run each failed scenario once; a pass on retry is a
`Flaky test` / `Flaky scenario` warning annotation instead of a failure. A pull request fails on a benchmark only when a metric is
more than 20% **and** more than 5 ms slower than the baseline measured on `main` with the same runner image; the
absolute budgets show up as warnings.

## Architecture

`App → UI → Core → MacxFS → CFSKit`, one SwiftPM target per layer.

- `CFSKit` (C): bounds-checked `getattrlistbulk` parsing, I/O policy, volume capabilities.
- `MacxFS` (`Sources/FSKit`; the spec calls it FSKit, renamed because macOS ships a system `FSKit.framework`): I/O
  lanes with a watchdog, streaming directory reads, the struct-of-arrays `EntryStore`, sort keys, volumes.
- `Core`: `FolderModel`, the FSEvents watcher, settings, clipboard, LaunchServices caches, Properties, key and
  command tables, and the journaled `FileOpQueue` with undo. No AppKit outside `Core/Platform`.
- `UI`: AppKit (SwiftUI only for Properties, Settings, the conflict dialog and onboarding).
- Every blocking file-system call runs on an I/O lane, never on the main thread.

## Release checklist

Run before every release, on Apple Silicon, from a clean checkout of the release commit. Every item is required.

1. `scripts/verify-phase1.sh` ends with `verify-phase1: N/N gates passed` (exit 0). This includes
   `macx-bench --check-budgets` on a release build; any over-budget metric blocks the release.
2. `scripts/ui-ax-smoke.sh` prints `PASS ui-ax-smoke` (grant the terminal Accessibility permission first).
3. Instruments on the release bundle, browsing a 100k-entry fixture folder from `scripts/make-fixtures.sh`
   (§4.4 rows `macx-bench` cannot measure headlessly):
   - Time Profiler and the `PerfSignposts` intervals (navigation → firstBatch → firstPaint, sort, iconFill):
     first rows painted < 50 ms; type icons visible in the first frame; custom icons (`.app`, custom-icon flag)
     < 100 ms after the rows.
   - Scrolling the 100k folder in Details and Icons: 120 fps on a ProMotion display, cell configure < 0.5 ms.
   - Hangs: no main-thread hang > 100 ms during navigate, sort, filter, scroll, copy and paste.
   - Allocations: < 40 MB peak during sort and diff of the 100k folder (images excluded).
   - Cold launch → window with the home folder < 300 ms (App Launch template, second launch after a reboot).
4. VoiceOver pass: toolbar buttons, address-bar segments, sidebar, table headers, rows, command bar, Properties.
5. Appearance: dark and light, Reduce Transparency, Increase Contrast, Reduce Motion, Differentiate Without Color
   (cut items are dimmed and italic).
6. External USB drive: browse, copy to and from it, eject from the sidebar while a window shows it (the window
   moves home, no "in use" error from macExplorer itself).
7. SMB share: browse, copy a file, and unplug the network while browsing (the UI never freezes; the folder shows
   the unresponsive state with Retry).
8. iCloud Drive: browsing a folder with placeholders downloads nothing (watch the cloud icons and `brctl status`).
9. Privacy: with Full Disk Access off, opening `~/Library/Mail` shows the "permission" empty state with Open
   Privacy Settings, and no alert. The onboarding sheet appears once on a fresh install.
10. Manual file operations for items 6-8 use only a test folder you created on that volume for the release check.
11. Tab restoration (P2-06 Step 9; not yet run, it needs a person at an unlocked Mac): bundle a copy with its own
    id (`scripts/bundle.sh debug --bundle-id com.macexplorer.app.restore-check --output .build/macExplorer-restore.app`),
    first checking that `~/Library/Saved Application State/com.macexplorer.app.restore-check.savedState` and
    `~/Library/Preferences/com.macexplorer.app.restore-check.plist` do not exist. Launch it with `--skip-onboarding`
    only, open a fresh `${TMPDIR}macx-scenario-<UUID>/A` (⌘L), ⌘T, open `…/B`, quit and relaunch: expect one window
    with tabs "A" and "B", "B" selected. Then delete exactly those two paths, the temp folder and the bundle.
    Every tab window is already restorable with `BrowserWindowRestoration` as its restoration class, so AppKit's
    native tab restoration should apply. Risk: launch restoration opens each queued request with
    `WindowManager.openWindow(at:)` (cascaded, shown as its own window) only after Core has started, then calls
    AppKit's completion handler, and macExplorer itself records no tab-group membership. If the tabs come back as
    separate windows, do not sign off: encode the tab group's identity and tab order in
    `BrowserWindowController.window(_:willEncodeRestorableState:)` (`BrowserWindowRestoration.encode`), and have
    `restoreOrOpenInitial` / `BrowserWindowRestoration.drain` rebuild each group with
    `openTab(at:in:select:)` instead of `openWindow(at:)`, selecting the tab that was selected. Then repeat this check.
    Status: still not run (2026-11-05). It cannot run in sandbox mode, which disables restoration, so an agent
    bound to `--root` sandbox launches cannot do it; it is a Phase 2 sign-off gate for the operator. Record the
    result (date, pass, or the fix applied) here.
12. Tab-bar drop: drag folder `B` from a second window (⌘N) onto the New Tab toolbar button of a window showing a
    sandbox folder: the cursor shows the link badge, a tab "B" opens and `B` stays where it was. Automated coverage
    (`MiddleClickTests.testRealDraggingInfoOnTheNewTabButtonIsALinkAndOpensTabs`) drives `draggingEntered` /
    `performDragOperation` with an `NSDraggingInfo` on a private pasteboard and gets `.link` only; the real
    window-server drag is still not run (2026-11-05) and stays a sign-off gate for the operator.
13. Quick Look visual check in a sandbox folder (`scripts/make-fixtures.sh`, plus a PNG, a PDF and a text file you
    put there): Space shows each correctly, ↑/↓ move through them, Space closes the panel, and typing `my f` then
    Space type-selects `my file.txt` instead of opening the panel.
14. Thumbnails in Icons view on an external disk and on an SMB share, in a test folder you created there: they
    appear after the type icons without blocking scrolling, and scrolling fast through a large folder stays smooth.
15. iCloud Drive placeholders: in a folder of not-downloaded items, Icons view shows type icons only (no
    thumbnails), and Calculate Folder Sizes shows "≥" sizes without downloading anything (Activity Monitor ›
    Network shows no downloads by `bird`; `brctl status` shows no new transfers).
16. VoiceOver with Group By on: each group row is announced as "<title>, <n> items, collapsed" or "…, expanded",
    and collapsing or expanding a group changes the announcement.
17. Columns view keyboard pass (⌘3) on a sandbox tree: ↓/↑ select in a column and open folders in the next one,
    → enters the child column, ← returns, holding ↓ over many folders leaves one child column on the last folder,
    Space opens Quick Look, middle-click opens a folder in a new tab, and Tab moves focus out of the columns.
18. Live Spotlight (P3-05): `LiveSpotlightTests` query only a sandbox the test creates under `$TMPDIR`, never
    "This Mac" or a real folder (a deviation from the plan's read-only `/System/Applications` test). Spotlight
    practically never indexes `$TMPDIR`, so both tests normally skip. `SystemMetadataQueryConfinementTests` still
    runs a real sandbox-scoped `NSMetadataQuery` and checks that it starts and delivers its notifications off the
    main thread, on its private queue. To see real Spotlight results once, create a folder of your own in an
    indexed location (for example `~/macx-spotlight-check`) with a file `macxprobe.txt` containing "macxprobe",
    wait until `mdfind -onlyin ~/macx-spotlight-check macxprobe` finds it, then in a normal (non-sandboxed)
    launch open that folder and search `macxprobe` with Subfolders + Contents (never This Mac): the file appears
    with its Path. Sandboxed (`--state-dir`) runs always use the fake Spotlight and iCloud services. Delete the
    folder afterwards.
19. Search & Preview by hand (Phase 3; automated tests never do these, because they read or change real files):
    - In a real iCloud Drive folder with a not-downloaded file, select it with the preview pane open: the pane
      shows "Download" and Activity Monitor › Network shows no download until you click it; clicking downloads the
      file and then previews it.
    - A This Mac search against the real index finds a known app by name and a known document by content.
    - Quick Look renders an image, a PDF, a movie and a Pages file in the preview pane.
    - VoiceOver reads the scope chips, the Name/Contents toggle, Stop, the notices and the preview pane's states.
    - A Subfolders search of `~` shows the "folders were skipped" notice and no macOS privacy prompt appears.
