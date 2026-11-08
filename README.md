# macExplorer

A native macOS file manager for people who know Windows File Explorer and now use a Mac. It looks at home on
macOS 26 (Finder-style sidebar, Liquid Glass chrome) and behaves like Explorer: an editable address bar, a folder
tree, a command bar, Explorer keyboard conventions, cut and paste, right-drag menus, a Properties window, and
Open With / choose the default app. It is built to be fast: folders with 100,000 entries open within the budgets
in the design spec (§4.4).

Status: Phase 2 ("Views & Tabs"), version `0.x`.

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

## Views & Tabs (Phase 2)

- **Tabs.** Every window is a native macOS tab group. ⌘T opens a new tab on the current folder (on `--root` in
  sandbox mode), ⌃Tab / ⌃⇧Tab move to the next / previous tab, ⌘W closes the tab, and ⇧⌘\ shows all tabs.
  Middle-click a folder in the content area, the sidebar or the folder tree to open it in a new tab; ⌘-click opens
  a new tab in the sidebar and the tree (in the content area ⌘-click still toggles the selection). "Open in New
  Tab" is also in the context menu. To open a dragged folder as a tab, drop it on the "＋" New Tab toolbar button
  (the P2-06 spike: AppKit's tab bar has no public drop target). Conflict and error dialogs of a job are shown on
  the tab that started it, which is selected first; if that tab has closed they go to the Operations panel.
- **Per-folder views.** Each folder remembers its view mode, columns, sort, icon size, density, Group by and "Calculate
  Folder Sizes" (keyed by volume UUID + file ID where IDs are stable, by path elsewhere). A folder you never changed
  follows Finder's view of it, application folders open as large icons, and everything else follows the defaults.
  View › Use as Default for All Folders makes the current view the default; View › Apply to All Folders… also forgets
  every folder's own view; View › Reset View for This Folder forgets this one's.
- **Group by** (View › Group By, or the context menu): Kind, Date Modified (Today, Yesterday, Earlier this Week…),
  Size buckets or Name (first letter), with floating group rows you can collapse. VoiceOver reads a group row as
  "<title>, <n> items, collapsed/expanded".
- **Quick Look.** Space opens and closes the Quick Look panel for the selection, and the arrow keys move through
  the items. While you are type-selecting (the last letter was typed less than a second ago) Space is part of the
  name, so `my f` reaches `my file.txt`.
- **Folder sizes.** View › Calculate Folder Sizes scans each folder of the current folder on a background lane:
  hard links count once, symlinks are never followed, other volumes are not entered, and iCloud placeholders are
  not downloaded. A size with unreadable or not-downloaded parts shows as "≥ 1.2 MB". Results are cached and
  updated through the file-system watcher; sorting by Size uses them.
- **More columns** (right-click a column header): Tags, Date Last Opened, Permissions (rwx), Owner, Comments, and
  Path in search results. All of them sort; their values are read in the background and refresh when another app
  changes only a tag or comment.
- **Copy Path As ▸** (Edit menu and context menu): POSIX Path (⇧⌘C, "Copy as Path"), ~ Path, File URL, Name,
  Quoted for Shell.
- **Thumbnails** in Icons view replace type icons for visible items once Quick Look has made them (never for iCloud
  placeholders); scrolling away cancels the request, and a 64 MB cache keeps recent ones.
- **Columns view** (⌘3, View › as Columns): one column per folder level. Selecting a folder opens the next column,
  → / ← move into and out of columns, and each column's trailing handle resizes it (double-click fits the names).

## Search & Preview (Phase 3)

- **Search field** (⌘F). Type to search; Esc clears it and returns to the folder. The scope bar under the toolbar
  has the scope chips **This Folder / Subfolders / This Mac**, a **Name / Contents** toggle, filters, progress,
  **Stop** and **Save**; the same choices are in View › Search. Which engine runs:

  | Scope | Name | Contents |
  |---|---|---|
  | This Folder | instant in-memory filter of the listed folder (every keystroke) | Spotlight, direct children only; a volume that isn't indexed falls back to the name filter with a notice |
  | Subfolders | our own crawler (parallel directory reads, packages and hidden folders skipped by default, symlinks never followed, other volumes never entered) | Spotlight inside the folder; not indexed → the crawler by name, with a notice |
  | This Mac | Spotlight over the whole Mac ("Spotlight is turned off" when indexing is off) | Spotlight |

  Every search other than the instant filter is debounced (250 ms) and shows its results in Details with a
  **Path** column. Retyping or changing the scope cancels the running search; its late results never appear.
- **Syntax** (close to Explorer's Advanced Query Syntax; terms are ANDed):

  | Token | Meaning |
  |---|---|
  | `word`, `"two words"` | a name term (Name mode) or content term (Contents mode); `*` and `?` make it a whole-name glob (`*.pdf`, `report?.doc`, `IMG_*`), case- and accent-insensitive |
  | `name:x`, `name:"a b"` | a name term in both modes |
  | `kind:` / `type:` + `folder document text pdf image movie audio archive app code` (plurals and synonyms work, comma-separated) | OR within one token and across repeated `kind:` tokens |
  | `ext:` / `extension:` + `pdf`, `.pdf`, `*.pdf`, `jpg,png` | OR |
  | `size:` + `>10MB` `>=1.5GB` `<1KB` `<=100` `=0` `1MB..10MB` `10MB` (±0.5 unit) `empty tiny small medium large huge gigantic` | repeated `size:` tokens intersect |
  | `modified:` / `date:`, `created:` + `today yesterday thisweek lastweek thismonth lastmonth thisyear lastyear last7days last30days`, `2026-01-31`, `>2026-01-31`, `>=`, `<`, `<=`, `2026-01-01..2026-01-31` | repeated tokens intersect |
  | unknown key (`foo:bar`), quoted `"kind:image"` | a literal term |
  | a known key with a bad value (`size:big`, `kind:spaceship`) | ignored, with "Didn't understand 'size:big'" under the field |

  Sizes are decimal like the sizes the app shows (`KB` = 1,000 bytes, `MB`, `GB`, `TB`); `KiB`, `MiB`, `GiB`, `TiB`
  are binary. Size words: empty < 1 B, tiny < 16 KB, small < 1 MB, medium < 128 MB, large < 1 GB, huge < 4 GB,
  gigantic ≥ 4 GB.
- **Filters** (the scope bar's Filters button): kind, date modified and created ranges, size range and extension,
  combined with the typed query.
- **Saved searches.** File › Save Search… (or Save in the scope bar) adds the search to the sidebar's **SEARCHES**
  section. Click one to run it again; rename, reorder (drag) or remove it from its context menu. Del on a saved
  search removes only the saved search, never a file.
- **Working with results.** Results follow file operations without re-running: trashed and moved items disappear,
  renamed ones show their new names. Double-click a folder result to open it and ⌘[ to return to the same results.
  Go › **Open Containing Folder** (⌥⌘R) opens the item's folder with the item selected. View › Search › **Stop
  Search** cancels a running search. A search stops at **100,000 results** and says "Showing the first 100,000
  results. Refine your search."
- **Preview pane** (View › Show Preview Pane, ⌥P, like Explorer). It shows the selection: text and code as a fast
  preview of the first 256 KB (with a note when the file is longer), other types in Quick Look, folders and
  multiple items as a summary, and a details grid underneath (size, dates, dimensions or duration). An iCloud
  file that is not downloaded is never read: the pane offers a **Download** button instead. ⌥P typed while a text
  field has focus types "π" and leaves the pane alone. The pane's visibility and width are remembered.
- **Spotlight notes.** Contents and This Mac need Spotlight indexing (`mdutil -s /` shows the state; macExplorer
  only ever runs `mdutil -s`). Volumes that aren't indexed fall back to name search with a notice. Protected
  folders (Desktop, Documents, Downloads, iCloud Drive without a recorded grant, and app data under `~/Library`)
  are skipped by Subfolders search without asking for access, and counted in "N folders were skipped".
- All new commands (preview pane, Open Containing Folder, the search scopes and modes, Stop, Save Search) can be
  rebound in Settings › Shortcuts.

## Install

- **Download:** get `MacExplorer-<version>.dmg` from [Releases](https://github.com/roniburd/macExplorer/releases), open it, drag MacExplorer to Applications.
- **Homebrew:** `brew install --cask roniburd/macexplorer/macexplorer` (or `macexplorer@beta` for betas).
- MacExplorer isn't notarized yet. The first time, macOS may refuse to open it. Run once:
  `xattr -dr com.apple.quarantine /Applications/MacExplorer.app`

## Updates

MacExplorer checks for updates once a day and downloads them in the background. When one is ready, a
**Restart to Update** button appears in the toolbar. Choose **Release** or **Beta** in Settings › General › Updates.
Moving from Beta back to Release never downgrades: you stay on your beta until a newer release ships.

## Feedback and crashes

Help › **Report a Bug…** / **Request a Feature…** (also in the toolbar's **Send Feedback** menu) open a prefilled
GitHub issue (you need a GitHub account and you review everything before submitting). If MacExplorer crashes, it
offers to report it the next time you open it; turn this off in Settings › Advanced.

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
   quarantine note above and the `caveats` block in `scripts/release/render-cask.sh`.

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

## Things macExplorer does not do

- **It does not replace Finder as the system file viewer.** macOS has no public API for that, so "Show in Finder"
  in other apps, the Dock's Finder icon and Open/Save panels still use Finder.
- **Cut in macExplorer, paste in Finder copies.** Cut writes the file URLs plus a private marker that only
  macExplorer understands. Finder sees ordinary file URLs and copies them. To move from macExplorer to Finder, drag
  the items, or copy them and use Finder's ⌥⌘V (Move Item Here). The other way round works: Finder ⌘C, then
  macExplorer ⌥⌘V (Move Item Here) moves.
- Libraries, Previous Versions, NTFS security tabs, drive letters, Mac App Store distribution, macOS before 26.
- "Put Back" from the Trash is not offered; undo restores trashed items instead.
- **Very large copies are slower to paste elsewhere.** Above 5,000 items, copy, cut and drag write each file URL as
  a promise that macExplorer fills in when another app asks for it (writing 100k items up front takes over 20 s).
  Pasting inside macExplorer is unaffected. Pasting those items in another app, or quitting macExplorer while they
  are on the clipboard, takes about 1 ms per item. Above 5,000 items the clipboard also has no plain-text list of
  the paths.

Function keys: F2 (rename) and F5 (refresh) need fn held, unless "Use F1, F2, etc. keys as standard function keys"
is on in Keyboard settings. Development builds are ad-hoc signed, so macOS may ask again for folder access after a
rebuild.

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
