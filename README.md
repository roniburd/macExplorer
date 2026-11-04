# macExplorer

A native macOS file manager for people who know Windows File Explorer and now use a Mac. It looks at home on
macOS 26 (Finder-style sidebar, Liquid Glass chrome) and behaves like Explorer: an editable address bar, a folder
tree, a command bar, Explorer keyboard conventions, cut and paste, right-drag menus, a Properties window, and
Open With / choose the default app. It is built to be fast: folders with 100,000 entries open within the budgets
in the design spec (§4.4).

Status: Phase 1 ("Core"), version `0.x`. Design: `docs/superpowers/specs/2026-11-01-macexplorer-design.md`.

## Requirements

- macOS 26 (Tahoe) or later.
- Xcode 27.2 (Swift 6.4) for building. SwiftPM only, no Xcode project and no third-party dependencies.

## Build and run

```bash
swift build -c release
scripts/bundle.sh release                 # assembles and ad-hoc signs .build/macExplorer.app
open .build/macExplorer.app
```

`scripts/bundle.sh [debug|release] [--bundle-id ID] [--output PATH]` defaults to a debug build at
`.build/macExplorer.app`.

### Running against a sandbox folder

For trying things out, run the app on a throwaway folder so nothing you own is touched:

```bash
SB="$(mktemp -d "${TMPDIR%/}/macx-fixtures-XXXXXX")"
mkdir "$SB/root" && touch "$SB/root/a.txt" "$SB/root/b.txt"
.build/macExplorer.app/Contents/MacOS/macExplorer --root "$SB/root" --state-dir "$SB/state" \
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

`scripts/make-fixtures.sh` builds a larger fixture tree (NFD names, emoji, symlinks, packages, locked files…)
under a fresh `${TMPDIR}/macx-fixtures-<UUID>` and prints its path.

## Tests, scenarios and benchmarks

Every automated check works only inside temporary directories it creates itself (`${TMPDIR}/macx-*-<UUID>`) and
disk images it creates and mounts `-nobrowse` inside them. None of them touches your files, the Trash, the general
pasteboard or your default apps. Each runner prints the sandbox roots it used and deletes them.

| Command | What it checks |
|---|---|
| `swift test --parallel` | unit and integration tests (`FSKitTests`, `CoreTests`, `UITests`, `MacxFixturesTests`, `BenchTests`, `ScenarioRunnerTests`); GUI and `hdiutil` tests skip with a reason when unavailable |
| `scripts/run-scenarios.sh [debug\|release]` | headless end-to-end Core scenarios: every file operation, conflicts, undo, watcher bursts, cross-volume moves on disk images, crash/kill recovery |
| `scripts/ui-scenarios.sh` | the 21 scripted UI scenarios in `Tests/Scenarios/` driven inside the bundled app (needs a logged-in GUI session) |
| `scripts/ui-ax-smoke.sh` | optional Accessibility smoke through System Events; skips when the terminal lacks Accessibility permission |
| `swift run -c release macx-bench` | 1k/10k/100k benchmarks, median and p90 as JSON; `--check-budgets` gates §4.4 on Apple Silicon, `--compare baseline.json` applies the CI relative gate |
| `scripts/check-layering.sh` | `MacxFS`/`Core` never import AppKit (except `Sources/Core/Platform`), layers only import downwards, fixtures never ship, tests never use global user state |
| `scripts/verify-phase1.sh` | every gate above in one run, then checks that nothing was left behind |

UI scenarios run in a separate bundle (`com.macexplorer.app.scenarios`, `.build/macExplorer-scenarios.app`), so
they never write the preferences of a real install. Scenario files use the schema in
`Sources/UI/Scenario/ScenarioFile.swift`.

CI (`.github/workflows/ci.yml`, `macos-26` runner) runs the layering checks, release and debug builds, the tests,
the bundle, both scenario runners and `macx-bench`. A pull request fails on a benchmark only when a metric is
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
