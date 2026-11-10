# Developing MacExplorer

How to build, test and release MacExplorer.
Using the app? See the [README](README.md) and the [user guide](USER-GUIDE.md).

**Contents**

1. [Quick start](#quick-start)
2. [Architecture](#architecture)
3. [Run on a sandbox folder](#run-on-a-sandbox-folder)
4. [Tests](#tests)
5. [CI](#ci)
6. [Screenshots](#screenshots)
7. [Releasing](#releasing)
8. [Release checklist](#release-checklist)

---

## Quick start

| You need | Version |
|---|---|
| macOS | 26 (Tahoe) or later |
| Xcode | 27.2 (Swift 6.4) |

The project is SwiftPM only. There is no Xcode project.
The one dependency is [Sparkle 2](https://sparkle-project.org), for updates.

```bash
swift build -c release
scripts/bundle.sh release          # makes .build/MacExplorer.app
open .build/MacExplorer.app
```

Before you push, run the tests:

```bash
swift test --parallel              # about 2 minutes
```

<details>
<summary><b><code>scripts/bundle.sh</code> options</b></summary>

| Option | Default | Effect |
|---|---|---|
| `debug` / `release` | `debug` | Build configuration |
| `--bundle-id ID` | `com.macexplorer.app` | Bundle identifier |
| `--output PATH` | `.build/MacExplorer.app` | Where the app goes |
| `--version X.Y.Z[-beta.N]` | from `Info.plist` | Marketing version |
| `--build N` | from `Info.plist` | Build number |
| `--sign IDENTITY` | ad-hoc | Code-signing identity |
| `--feed-url URL` | from `Info.plist` | Sparkle appcast URL |
| `--ed-public-key KEY` | from `Info.plist` | Sparkle EdDSA public key |
| `--universal` | off | Build arm64 and x86_64 |

</details>

---

## Architecture

Five layers. Each one only imports the layers below it.

**App → UI → Core → MacxFS → CFSKit**

| Layer | Folder | Job |
|---|---|---|
| `App` | `Sources/App` | The executable. Starts everything. |
| `UI` | `Sources/UI` | AppKit windows and views. SwiftUI only for Properties, Settings, the conflict dialog and onboarding. |
| `Core` | `Sources/Core` | Folder models, file watching, settings, clipboard, file operations with undo. No AppKit, except in `Core/Platform`. |
| `MacxFS` | `Sources/FSKit` | Fast directory reads, I/O lanes, the `EntryStore`, sort keys, volumes. |
| `CFSKit` | `Sources/CFSKit` | C code: `getattrlistbulk` parsing, I/O policy, volume capabilities. |

Two rules hold everywhere:

- Every blocking file-system call runs on an I/O lane, never on the main thread.
- `scripts/check-layering.sh` enforces the import rules.

`MacxFS` lives in `Sources/FSKit`.
It was renamed because macOS already ships a system `FSKit.framework`.

---

## Run on a sandbox folder

Run the app on a throwaway folder when you try things out.
Nothing you own is touched.

```bash
SB="$(mktemp -d "${TMPDIR%/}/macx-fixtures-XXXXXX")"
mkdir "$SB/root" && touch "$SB/root/a.txt" "$SB/root/b.txt"

.build/MacExplorer.app/Contents/MacOS/macExplorer \
    --root "$SB/root" --state-dir "$SB/state" --sandbox-trash "$SB/trash" \
    --pasteboard "macx-fixtures-$$" --fake-launch-services --skip-onboarding

rm -rf "$SB"                       # when you're done
```

| Option | Effect |
|---|---|
| `--root <dir>` | The first window opens here. Window restoration is off. |
| `--state-dir <dir>` | Settings, journal and recents go here. Required with `--root` and `--scenario`. |
| `--sandbox-trash <dir>` | Trashed items go here instead of the real Trash. |
| `--pasteboard <name>` | Copy and paste use a private pasteboard. |
| `--fake-launch-services` | Open With never changes your real default apps. |
| `--skip-onboarding` | No first-launch sheet. |
| `--index-status enabled\|disabled\|unknown` | What the fake Spotlight reports. Default `disabled`. |
| `--scenario <file>` | Run one UI scenario and quit. |
| `--scenario-output <file>` | Where the scenario writes its result. |
| `--smoke-exit-after <seconds>` | Write `<state-dir>/smoke.json` and quit. |
| `--keymap <file>` | Import a keymap file (the Settings › Shortcuts export format) into the sandbox settings before any window opens. Needs `--state-dir`. A file that can't be used exits with status 65. |

Sandboxed runs never query the real Spotlight index and never download from iCloud.

For a bigger test tree, run `scripts/make-fixtures.sh`.
It makes odd names, emoji, symlinks, packages and locked files, and prints the folder's path.

---

## Tests

Every test works only in temporary folders it creates (`${TMPDIR}/macx-*-<UUID>`).
No test touches your files, the Trash, the clipboard or your default apps.
Each runner deletes its folders when it finishes.

| Command | What it checks | Time |
|---|---|---|
| `swift test --parallel` | Unit and integration tests | ~2 min |
| `swift test --filter <Class>` | One test class, while you iterate | seconds |
| `scripts/run-scenarios.sh` | Headless end-to-end file operations, undo, crash recovery, search | minutes |
| `scripts/ui-scenarios.sh` | Scripted UI scenarios in the real app | minutes |
| `scripts/ui-ax-smoke.sh` | Accessibility smoke test (needs Accessibility permission) | minutes |
| `swift run -c release macx-bench` | Benchmarks on 1k, 10k and 100k files | minutes |
| `scripts/check-layering.sh` | Import rules and test-safety rules | seconds |
| `scripts/verify-phase1.sh` | All of the above, then checks nothing was left behind | longest |
| `scripts/verify-phase4.sh` | `verify-phase1.sh`, then checks every Phase 4 core family, `p4-*` UI scenario and Phase 4 budget passed | longest |

Run the full suite with `--parallel`.
Serial `swift test` takes 6–7 minutes.

### UI scenarios

UI scenarios need keyboard focus.
Only one can run on the Mac at a time, across all worktrees.

- Scenario files are in `Tests/Scenarios/`.
- Their schema is in `Sources/UI/Scenario/ScenarioFile.swift`.
- They run in a separate app (`com.macexplorer.app.scenarios`), so they never change a real install's settings.
- A scenario can pass `"launchArguments": ["--keymap", "<name>.json"]`. The file comes from `Tests/Scenarios/keymaps/`
  and is copied into that scenario's sandbox first. No other launch argument is allowed.
- `"answerError": "skip"` (or another `ErrorResolution` case) answers a file-operation error dialog, and
  `"archives": {"<path>": "evil-tar"}` makes a crafted tar with a `../escape.txt` entry.

### Benchmarks

| Flag | Effect |
|---|---|
| `--metrics search-` | Run only the metrics whose name starts with `search-` |
| `--check-budgets` | Fail when a metric is over its budget (Apple Silicon only) |
| `--compare baseline.json` | Fail when a metric is much slower than the baseline |

Phase 4 adds two in-memory budgets: `palette.rank` (< 2 ms) and `batchRename.preview` (10,000 names < 100 ms).

Output is JSON with the median and p90 of each metric.

<details>
<summary><b>What <code>check-layering.sh</code> enforces</b></summary>

- `MacxFS` and `Core` never import AppKit or Quick Look (except `Sources/Core/Platform`).
- Layers only import downwards.
- Fixtures never ship in the app.
- Tests never use global user state.
- Quick Look is only used from `UITests`.
- `NSMetadataQuery` and real iCloud downloads stay in their one file.
- Tests use the fake Spotlight.
- Nothing runs `mdimport` or changes the Spotlight index.

</details>

---

## CI

CI is `.github/workflows/ci.yml`. It runs on every push to `main` and every pull request.

It runs, in order:

1. The layering checks.
2. Release and debug builds.
3. The tests.
4. The app bundle.
5. Both scenario runners.
6. The benchmarks.

### Flaky tests

Shared runners are slow, so CI retries failures once.

- `scripts/test-with-retry.sh` re-runs each failed test alone.
- It doesn't retry when more than 5 tests failed, or the build failed.
- The scenario runners re-run each failed scenario once.
- A pass on retry shows as a **Flaky test** warning, not a failure.

### Benchmark gate

A pull request fails on a benchmark only when a metric is both:

- more than 20% slower than `main`, **and**
- more than 5 ms slower.

The absolute budgets show as warnings only.

---

## Screenshots

The README and user guide screenshots come from the real app.
`site/tools/shots.py` drives it with UI scenarios on a made-up home folder.

```bash
swift build -c release
scripts/bundle.sh release --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app
swiftc -O site/tools/winid.swift -o /tmp/macx-site-winid
python3 -I site/tools/shots.py              # all shots, or name some: shots.py tabs search
```

- Full windows go to `site/assets/shots/`.
- Cropped snippets for the user guide go to `site/assets/shots/guide/`.
- It needs keyboard focus, like the UI scenarios.
- The website's zoomed snippets in `site/assets/shots/crops/` are cut from these with `sips -c <h> <w> --cropOffset <y> <x>`.

---

## Website

The website is `site/` and is published to https://roniburd.github.io/macExplorer/ by `.github/workflows/site.yml`
on every push to `main` that changes `site/`. It copies `site/` (minus `tools/`) onto the `gh-pages` branch next to
`appcast.xml`, which it never touches, and stops if `appcast.xml` is missing. The early design concepts are kept under
`site/concepts/`.

```bash
python3 -m http.server 8000 --bind 127.0.0.1 --directory site   # preview at http://127.0.0.1:8000/
```

---

## Releasing

### Each release

Versions follow semantic versioning, `vMAJOR.MINOR.PATCH`. While the major version is 0 the app is in beta, so tags
carry no `-beta` suffix:

- new features or bigger changes bump the minor version: `v0.4.0` → `v0.5.0`
- bug fixes bump the patch version: `v0.4.0` → `v0.4.1`

Tag the commit on `main` and push the tag:

```bash
git tag -a v0.4.1 -m "v0.4.1

- What changed, for users"
git push origin v0.4.1
```

`vX.Y.Z` tags publish on the Release channel (cask `macexplorer`). Copies set to the Beta channel get them too.
The workflow still accepts `vX.Y.Z-beta.N` tags (the Beta channel and the `macexplorer@beta` cask, used up to
`v0.2.0-beta.24`), but new releases don't use them.

The tag message becomes the release notes.

Pushing the tag starts `.github/workflows/release.yml`.
It does this:

1. Waits (up to 50 min) for CI on the tagged commit.
2. Stops if CI failed.
3. Builds, signs and publishes the release.
4. Updates the appcast on `gh-pages` and the Homebrew cask.

If CI failed: fix it or re-run it, then re-run the release.
If the commit has no CI run, the release runs the tests itself.

**Dry run:** Actions › Release › Run workflow.
This only shows up when `release.yml` is on the default branch.

### One-time setup

A publishing run stops early unless these secrets are set.

| Secret | What it is |
|---|---|
| `SPARKLE_ED_PRIVATE_KEY` | Signs updates. Its public key goes in `Info.plist` › `SUPublicEDKey`. |
| `HOMEBREW_TAP_TOKEN` | Token with *Contents: read and write* on `roniburd/homebrew-macexplorer` only. |
| `SELF_SIGNED_P12`, `SELF_SIGNED_P12_PASSWORD`, `SELF_SIGNED_IDENTITY` | The self-signed certificate, if `RELEASE_SIGNING: self-signed`. |

<details>
<summary><b>Setup steps</b></summary>

1. Make the Sparkle keys:
   - Run `swift package resolve`, then `.build/artifacts/sparkle/Sparkle/bin/generate_keys`.
   - Put the printed public key in `Resources/Info.plist` › `SUPublicEDKey`.
   - Export the private key with `generate_keys -x private.key`.
   - Store its contents in `SPARKLE_ED_PRIVATE_KEY`.
   - Keep an offline backup, then delete the file.
   - **If you lose this key, existing installs can't update.**
2. Create an orphan `gh-pages` branch with an empty commit. Turn on GitHub Pages from it.
3. Create the public repo `roniburd/homebrew-macexplorer`. Store a token for it in `HOMEBREW_TAP_TOKEN`.
4. For self-signed signing: store the certificate secrets. Set `RELEASE_SIGNING: self-signed` in `release.yml`. The default is `adhoc`.

</details>

<details>
<summary><b>Later: Apple Developer ID and notarization</b></summary>

1. Add these secrets: `DEVELOPER_ID_P12` (base64), `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_API_KEY` (base64 `.p8`), `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER`.
2. The workflow needs no changes.
3. Remove the quarantine note from `README.md`.
4. Remove the `caveats` block from `scripts/release/render-cask.sh`.

</details>

---

## Release checklist

Run it before every release.
Use Apple Silicon and a clean checkout of the release commit.
Every item is required.

### Automated

| # | Run | Expect |
|---|---|---|
| 1 | `scripts/verify-phase4.sh` | `[verify-phase4] OK` (it runs `verify-phase1.sh` first). Any metric over budget blocks the release. |
| 2 | `scripts/ui-ax-smoke.sh` | `PASS ui-ax-smoke` |

### Performance (Instruments)

Profile the release app on a 100k-file folder from `scripts/make-fixtures.sh`.

| What | Target |
|---|---|
| First rows painted | < 50 ms |
| Type icons | Visible in the first frame |
| Custom icons (apps, custom folder icons) | < 100 ms after the rows |
| Scrolling in Details and Icons | 120 fps on ProMotion. Cell setup < 0.5 ms. |
| Main-thread hangs | None > 100 ms (navigate, sort, filter, scroll, copy, paste) |
| Memory while sorting 100k | < 40 MB peak, not counting images |
| Cold launch to window | < 300 ms (second launch after a reboot) |

Use Time Profiler with the `PerfSignposts` intervals (navigation → firstBatch → firstPaint, sort, iconFill).

### Accessibility and appearance

| # | Check |
|---|---|
| 4 | **VoiceOver** reads the toolbar, address bar, sidebar, column headers, rows, command bar and Properties. |
| 5 | **Appearance** works in dark, light, Reduce Transparency, Increase Contrast, Reduce Motion and Differentiate Without Color. Cut items are dimmed and italic. |
| 16 | **VoiceOver with Group By:** a group row reads "<title>, <n> items, collapsed" or "…, expanded". It changes when you toggle it. |

### Disks and network

Use only a test folder you made on that disk for these checks.

| # | Check |
|---|---|
| 6 | **USB drive:** browse it and copy to and from it. Eject it from the sidebar while a window shows it. The window goes home, with no "in use" error. |
| 7 | **SMB share:** browse it and copy a file. Unplug the network while browsing. The UI never freezes, and the folder shows Retry. |
| 8 | **iCloud Drive:** browsing a folder of placeholders downloads nothing. Watch the cloud icons and `brctl status`. |
| 9 | **Privacy:** with Full Disk Access off, `~/Library/Mail` shows the "permission" empty state, with no alert. Onboarding appears once on a fresh install. |
| 14 | **Thumbnails** on a USB drive and an SMB share appear after the type icons. Fast scrolling stays smooth. |
| 15 | **iCloud placeholders:** Icons view shows no thumbnails for them. Folder sizes show "≥" and download nothing. |

### Features by hand

| # | Check |
|---|---|
| 12 | **Tab-bar drop:** drag folder `B` from another window onto the **＋** button. The cursor shows a link badge, tab "B" opens, and `B` doesn't move. |
| 13 | **Quick Look:** Space previews a PNG, a PDF and a text file. ↑/↓ move between them. Space closes. Typing `my f` then Space selects `my file.txt`. |
| 17 | **Columns keyboard (⌘3):** ↓/↑ select and open the next column. → enters it, ← goes back. Holding ↓ leaves one child column. Space opens Quick Look. Middle-click opens a tab. Tab moves focus out. |
| 18 | **Live Spotlight:** see below. |
| 19 | **Search and preview:** see below. |
| 20 | **Custom icon:** in a test folder you made, drop a PNG on a file's icon in Properties. Finder shows the same icon. ⌘Z removes it in both apps. |
| 21 | **Access Control:** on a file you made, add an "Everyone: Read" entry. `ls -le` lists it. On a file owned by another user (e.g. in `/Library`), the list is read-only and nothing can be changed. |
| 22 | **Keymap export/import:** Settings › Shortcuts › Export… to a test folder, switch to the Finder preset, then Import… the file. Your shortcuts come back. |
| 23 | **Archives from elsewhere:** Extract Here on a zip made by Windows and a `.tar.gz` from the web (copies in a test folder). The contents match `ditto -x`/`tar -x`. |
| 24 | **Batch rename on a USB drive (exFAT/FAT):** rename `A.txt` → `a.txt` and swap two names. Both work, and one ⌘Z restores them. |

<details>
<summary><b>11. Tab restoration</b> (not run yet; needs a person at an unlocked Mac)</summary>

It can't run in sandbox mode, because sandbox mode turns restoration off.

1. Bundle a separate copy:
   `scripts/bundle.sh debug --bundle-id com.macexplorer.app.restore-check --output .build/macExplorer-restore.app`
2. Check that these don't exist yet:
   - `~/Library/Saved Application State/com.macexplorer.app.restore-check.savedState`
   - `~/Library/Preferences/com.macexplorer.app.restore-check.plist`
3. Launch it with `--skip-onboarding` only.
4. Open a fresh `${TMPDIR}macx-scenario-<UUID>/A` with ⌘L.
5. Press ⌘T and open `…/B`.
6. Quit and relaunch.
7. **Expect** one window with tabs "A" and "B", with "B" selected.
8. Delete those two paths, the temp folder and the bundle.

If the tabs come back as separate windows, don't sign off.
The fix: save the tab group and tab order in `BrowserWindowController.window(_:willEncodeRestorableState:)`.
Then rebuild each group in `restoreOrOpenInitial` / `BrowserWindowRestoration.drain` with `openTab(at:in:select:)`.

Record the result (date, pass, or the fix) here.
Status on 2026-11-05: not run.

</details>

<details>
<summary><b>18. Live Spotlight</b></summary>

The automated Spotlight tests only query a sandbox under `$TMPDIR`.
Spotlight rarely indexes `$TMPDIR`, so they usually skip.

To see real results once:

1. Make `~/macx-spotlight-check` with a file `macxprobe.txt` containing "macxprobe".
2. Wait until `mdfind -onlyin ~/macx-spotlight-check macxprobe` finds it.
3. Launch the app normally (not sandboxed) and open that folder.
4. Search `macxprobe` with **Subfolders** and **Contents**. Never use This Mac.
5. **Expect** the file, with its Path.
6. Delete the folder.

</details>

<details>
<summary><b>19. Search and preview by hand</b></summary>

Automated tests never do these, because they read or change real files.

- **iCloud download:** select a not-downloaded iCloud file with the preview pane open. The pane shows **Download**. Nothing downloads until you click it. Then it previews.
- **This Mac:** finds a known app by name and a known document by content.
- **Preview pane:** Quick Look renders an image, a PDF, a movie and a Pages file.
- **VoiceOver:** reads the scope chips, the Name/Contents toggle, Stop, the notices and the preview pane.
- **Privacy:** a Subfolders search of `~` shows "folders were skipped". No privacy prompt appears.

</details>
