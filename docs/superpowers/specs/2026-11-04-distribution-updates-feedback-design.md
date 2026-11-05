# MacExplorer: distribution, auto-update, feedback and crash reporting (design)

Date: 2026-11-04. Status: approved in brainstorming; awaiting written-spec review.
Relates to: `2026-11-01-macexplorer-design.md` §10 (release track) and §11 Phase 4 (Sparkle auto-update), which this spec pulls forward and supersedes for those items.

## 1. Intent

**Outcome.** A user downloads MacExplorer from GitHub Releases (DMG) or Homebrew, installs it, and from then on stays current through a VS Code–style, non-modal "Restart to Update" flow on the channel they choose (Release or Beta). From inside the app they can file a bug report or feature request as a GitHub issue, and after a crash the next launch offers to report it.

**Decisions made (owner).**
- Signing: start **free** (ad-hoc, no Apple Developer Program). Move to Developer ID + notarization once the project is stable. The switch must be a CI-secrets change, with no app-code change.
- Feedback and crash reports reach GitHub through a **prefilled browser link** to an issue form. No backend, no tokens in the app; the user needs a GitHub account and clicks Submit themselves.
- Beta = **tagged pre-releases** (`vX.Y.Z-beta.N`). No nightlies.
- Update UX = **VS Code style**: silent background download, non-modal badge, "Restart to Update".
- Update engine = **Sparkle 2** with a custom `SPUUserDriver`.
- Crash detection = macOS's own **`.ips` reports**, gated by a **dirty-exit marker**. No in-process crash handler.
- Appcast hosted on **GitHub Pages** (`gh-pages`).
- **Homebrew** tap with stable and beta casks, updated by CI.

**Success criteria.**
1. Pushing a `v*` tag produces, with no manual steps, a GitHub Release (zip + dmg), an updated appcast and an updated Homebrew cask.
2. An installed copy on the Release channel picks up a newer release; a copy on Beta picks up newer betas and releases; neither ever downgrades.
3. Updates never interrupt a running file operation (they go through the existing §6 quit path).
4. Help → Report a Bug… opens a GitHub issue form with version, channel, macOS and hardware already filled.
5. After a real crash, the next launch shows the crash sheet once for that crash, and the issue it opens contains a redacted excerpt.

**Non-goals (YAGNI).** Delta updates, critical/forced updates, staged rollouts, in-app release-notes rendering, nightly channel, anonymous submission/relay server, in-process crash capture, server-side symbolication or dSYM upload, analytics/telemetry.

## 2. Architecture

Layering stays `App → UI → Core → MacxFS → CFSKit` and must pass `scripts/check-layering.sh`. Only `UI/Updates/` imports Sparkle.

### 2.1 Core (pure logic, no AppKit, no Sparkle)

| Unit | Purpose |
|---|---|
| `Core/Updates/UpdateChannel.swift` | `enum UpdateChannel { case release, beta }`, persisted in Settings (default `.release`); `allowedSparkleChannels: Set<String>` → `[]` for release, `["beta"]` for beta. |
| `Core/Updates/UpdateState.swift` | State machine: `idle`, `checking(userInitiated:)`, `upToDate(version)`, `downloading(fraction?)`, `readyToRestart(version, notesURL)`, `failed(UpdateError, userInitiated:)`. Pure transition function `reduce(state, event) -> state`; illegal transitions are ignored and logged. |
| `Core/Diagnostics/EnvironmentSummary.swift` | App version, build, channel, macOS version, hardware model (`hw.model`), architecture. Injected providers for tests. |
| `Core/Diagnostics/IssueURLBuilder.swift` | Builds `https://github.com/roniburd/macExplorer/issues/new?template=<bug.yml|feature.yml>&<field-id>=<value>…`. Field IDs are constants shared with the YAML forms. Total URL length ≤ 7,500 characters; truncates the crash excerpt first and appends `… [truncated — full report on clipboard]`. |
| `Core/Diagnostics/DirtyExitMarker.swift` | Writes `<StatePaths.root>/session.marker` (`~/Library/Application Support/macExplorer/session.marker`; `--state-dir` in sandbox runs) (JSON: pid, version, build, launch time) at launch; removes it on clean termination; reports the previous session's marker if present. Base directory is injected. |
| `Core/Diagnostics/CrashReportLocator.swift` | Lists `*.ips` in an injected directory (default `~/Library/Logs/DiagnosticReports`) whose header JSON has our bundle ID, whose timestamp is after the marker's launch time, and whose filename is not in `lastReportedCrashes`. Returns the newest match. |
| `Core/Diagnostics/CrashExcerpt.swift` | Parses an `.ips` (line 1 = header JSON, remainder = body JSON) into: exception type, signal, termination reason, crashed-thread top 20 frames (symbol if present, else `image + offset`), version, build. Replaces the user's home path with `~` everywhere. Malformed input returns `nil`, never traps. |

New Settings keys (existing Settings store): `updateChannel`, `checkForUpdatesAutomatically` (default on), `offerToReportCrashes` (default on), `lastReportedCrashes` (bounded list of filenames, newest 20).

### 2.2 UI

| Unit | Purpose |
|---|---|
| `UI/Updates/SparkleUpdateDriver.swift` | Our `SPUUserDriver`. Translates Sparkle callbacks into `UpdateState` events. On "update found" in a background check it replies "install" so Sparkle downloads silently. Talks to Sparkle through a small protocol (`UpdaterEngine`) so tests can substitute a fake. |
| `UI/Updates/UpdateController.swift` | Owns `SPUUpdater`, the driver and the published `UpdateState`; implements `SPUUpdaterDelegate.allowedChannels(for:)` from `UpdateChannel`; exposes `checkNow()`, `restartToUpdate()`. |
| `UI/Updates/UpdateBadge.swift` | Toolbar item at the trailing edge; hidden unless state is `downloading` (manual only), `readyToRestart`, or a user-initiated `checking`/`upToDate`/`failed`. Popover with status text, release-notes link, **Restart Now / Later**. |
| `UI/Feedback/FeedbackCommands.swift` | Help → **Report a Bug…**, **Request a Feature…**; a **Send Feedback** toolbar menu button with the same two items. Opens the URL from `IssueURLBuilder` via the existing `ExternalURLOpener`. |
| `UI/Feedback/CrashReportPrompt.swift` | The next-launch sheet (§4.2). |
| Settings → General | New "Updates" group: Channel (Release / Beta) popup, "Check for updates automatically", **Check Now**, and the one-line note for beta→release (§3.3). |
| Settings → Advanced | "Offer to report crashes" toggle. |
| App menu | **Check for Updates…** (below About). |

All new strings go through `scripts/l10n-add.sh`; new controls get AX identifiers in `AXID.swift`.

### 2.3 Bundle and Info.plist

- Sparkle 2 added as an SPM dependency of `UI` only (first external dependency; pin an exact version).
- `scripts/bundle.sh` copies `Sparkle.framework` into `Contents/Frameworks`, sets `@executable_path/../Frameworks` rpath, and signs inside-out (framework's XPC services and `Autoupdate`, then framework, then app). Final check: `codesign --verify --deep --strict`.
- `bundle.sh` gains `--version X.Y.Z[-beta.N]` and `--build N`, stamping `CFBundleShortVersionString` and `CFBundleVersion`. Build number = `git rev-list --count HEAD` on the tagged commit (monotonic on `main`).
- `Info.plist` gains `SUFeedURL` = `https://roniburd.github.io/macExplorer/appcast.xml`, `SUPublicEDKey`, `SUEnableAutomaticChecks` = YES, `SUScheduledCheckInterval` = 86400.
- Debug builds and the scenario bundle (`com.macexplorer.app.scenarios`) do not start the updater (`UpdateController.live` returns nil for debug builds, sandbox runs, bundle IDs ending in `.scenarios`, and an unset `SUPublicEDKey`).

## 3. Update experience

### 3.1 Background flow
1. At launch, `SPUUpdater` starts with our driver. If automatic checks are on, it checks about 24 h after the last check.
2. `allowedChannels` follows the channel setting; Sparkle picks the newest item the user may see.
3. Update found → driver accepts → silent download → `readyToRestart(version, notesURL)`.
4. The badge appears: an accented "Restart to Update" pill. Popover: "MacExplorer 0.4.0 is ready", "What's new" (GitHub release page), **Restart Now / Later**.
5. **Restart Now** calls the existing quit path. If file operations are active, the existing "N operations are in progress" prompt (main spec §6) runs first; cancelling it cancels the restart. On termination Sparkle installs and relaunches.
6. **Later** dismisses the popover; the badge stays; Sparkle installs on the next normal quit.

### 3.2 Manual check
Check for Updates… (menu) or Check Now (Settings) opens the badge popover: "Checking…" → "You're up to date (0.3.1)" / download progress → "Restart to Update" / a plain-language error.

### 3.3 Channel switch
- Release → Beta: immediate background check.
- Beta → Release: no downgrade; the user stays on the installed beta until a higher release ships. Settings shows: "You'll move to the next release that's newer than this beta."

### 3.4 Errors

| Case | Behavior |
|---|---|
| Background check fails (offline, appcast unreachable, HTTP error) | Logged only; next scheduled check retries. |
| Manual check fails | Shown in the popover with the reason. |
| EdDSA / code-signature validation fails | "This update couldn't be verified and wasn't installed." Version suppressed for the session; logged. Nothing installed. |
| Download interrupted / disk full | Back to `idle`; next check retries. Manual: error shown. |

## 4. Feedback and crash reporting

### 4.1 Feedback
- Entry points: Help menu and the toolbar Send Feedback menu (§2.2).
- Opens the browser directly at the issue form, prefilled from `EnvironmentSummary`. No intermediate sheet; the user reviews everything on GitHub before Submit.
- Issue forms (new, in `.github/ISSUE_TEMPLATE/`):
  - `bug.yml`: `what-happened` (textarea, required), `steps` (textarea), `expected` (textarea), `version`, `macos`, `hardware`, `channel` (inputs), `crash-log` (textarea, `render: text`). Labels `bug`, `from-app`.
  - `feature.yml`: `problem` (textarea, required), `proposal` (textarea), `version` (input). Labels `enhancement`, `from-app`.
  - `config.yml`: `blank_issues_enabled: true`.

### 4.2 Crash reporting
1. Launch writes the marker; `applicationWillTerminate` removes it.
2. Next launch: if a previous marker exists, and `offerToReportCrashes` is on, `CrashReportLocator` runs off main after the first window is shown.
3. Match found → sheet on the first browser window, after onboarding and the existing `RecoveryNotice` (never stacked on them):
   - Text: "MacExplorer quit unexpectedly last time. Help fix it by reporting the crash."
   - **Report on GitHub…**: opens `bug.yml` with the redacted excerpt in `crash-log`, copies the full redacted `.ips` text to the clipboard; the form's description tells the user to paste it or drag the file in.
   - **Show Report**: reveals the `.ips` file.
   - **Don't Send**.
   - Checkbox **Don't ask again** → sets `offerToReportCrashes` off.
   - Any choice adds the filename to `lastReportedCrashes` so the same crash never prompts twice.
4. Marker present but no matching `.ips` (force quit, kill, power loss): logged, no prompt.
5. The current launch's marker is written after the previous one has been read.

**Privacy.** Home path redacted to `~` in excerpt and clipboard copy. Nothing leaves the machine unless the user clicks Submit on GitHub.

## 5. Release pipeline

New `.github/workflows/release.yml`, triggered by tags `v*` and `workflow_dispatch` (dry-run input, default true for dispatch).

1. **Build.** Universal (`--arch arm64 --arch x86_64`) release build; `bundle.sh release --version <tag without v> --build <rev count>`.
2. **Sign.** If `DEVELOPER_ID_P12` is set: import into a temporary keychain, sign with Developer ID + hardened runtime, `notarytool submit --wait`, `stapler staple`. Otherwise: the identity chosen by the spike (§7): ad-hoc, or a stable self-signed certificate from `SELF_SIGNED_P12`.
3. **Package.** `MacExplorer-<version>.zip` (`ditto -c -k --keepParent`, what Sparkle downloads) and `MacExplorer-<version>.dmg` (`hdiutil`, with an Applications symlink).
4. **Publish.** GitHub Release with both assets; tags containing `-beta.` are marked pre-release. Release notes from the tag annotation, falling back to generated notes.
5. **Appcast.** `sign_update` with `SPARKLE_ED_PRIVATE_KEY` → append an `<item>` to `appcast.xml` on `gh-pages` (version, build, `sparkle:edSignature`, length, enclosure URL = the release asset, `sparkle:minimumSystemVersion` 26.0, release-notes link). Beta items carry `<sparkle:channel>beta</sparkle:channel>`. Commit and push to `gh-pages` with the workflow's `GITHUB_TOKEN` (`contents: write`).
6. **Homebrew.** In tap repo `roniburd/homebrew-macexplorer`: stable tags update `Casks/macexplorer.rb`, beta tags update `Casks/macexplorer@beta.rb` (version, sha256 of the zip, URL). Both casks: `auto_updates true`, `depends_on macos: :tahoe` (Homebrew reads a bare symbol as "this release or later"; `brew style` rejects the `">= :tahoe"` string form), `app "MacExplorer.app"`, `conflicts_with` each other. Pushed with `HOMEBREW_TAP_TOKEN` (fine-grained, contents write on the tap only).
   - Until Developer ID: README and cask `caveats` document the one-time quarantine removal (`xattr -dr com.apple.quarantine /Applications/MacExplorer.app`).
   - `brew upgrade --greedy` upgrades the cask; plain `brew upgrade` leaves it to Sparkle.
7. **Dry run** performs 1–3, generates (but does not push) the appcast item and cask diff, and uploads them as workflow artifacts.

Existing `ci.yml` gains: bundle contains `Sparkle.framework`; `codesign --verify --deep --strict` passes; `Info.plist` has a non-empty `SUPublicEDKey`.

## 6. Testing

Per the user safety rule, tests only create, read and delete files in directories the test itself created.

**Unit (`swift test`, no network).**
- `UpdateState.reduce`: every legal edge, ignored illegal edges, user-initiated vs background failure.
- `UpdateChannel.allowedSparkleChannels`.
- `IssueURLBuilder`: percent-encoding, template selection, field IDs equal the IDs parsed from `bug.yml`/`feature.yml` in the repo, length cap, truncation marker.
- `CrashReportLocator` over fixture `.ips` files in a temp dir: bundle-ID match/mismatch, older than marker, already reported, newest-wins, malformed header.
- `CrashExcerpt`: frame extraction, missing symbols, home-path redaction, truncated/garbage JSON returns `nil` (fuzz with random truncations).
- `DirtyExitMarker`: write, clean removal, dirty detection, corrupt marker treated as dirty with unknown launch time (locator then uses only `lastReportedCrashes`).
- `SparkleUpdateDriver` against a fake `UpdaterEngine`: callback → event mapping, background auto-accept, verification-failure suppression.

**UI / scenario (existing harness, sandboxed scenario bundle).**
- Badge hidden in `idle`; shown for `readyToRestart`; popover buttons.
- Restart Now with an active job goes through the quit prompt; Cancel keeps the app running.
- Channel popup persists; switching to Beta triggers `checkNow` on the fake engine.
- Crash sheet appears with a fixture marker + fixture `.ips` in sandboxed directories; Don't ask again flips the setting; the same crash never prompts twice.
- Help menu items exist and validate.

**CI.** Release dry run on `workflow_dispatch`; PR checks in §5.

## 7. Risk spike (first task of the plan; throwaway)

**Question.** With ad-hoc signing, (a) does Sparkle 2 accept an update whose ad-hoc signature differs from the installed copy's, and (b) does macOS re-prompt for Desktop/Documents/Downloads access after the update?

**Probe.** Two ad-hoc builds, 0.0.1 and 0.0.2, served from a local appcast (`file://` or `python3 -m http.server` bound to 127.0.0.1), in a scratch copy with a throwaway bundle ID.

**Outcomes.**
- Both fine → ship ad-hoc.
- Either fails → generate a stable self-signed code-signing certificate once, store it as `SELF_SIGNED_P12` (+ password), and sign every build with it so the designated requirement is stable. Record the result in this section before implementation continues.

## 8. Owner one-time setup (documented in README)

1. `generate_keys` (Sparkle) → private key into repo secret `SPARKLE_ED_PRIVATE_KEY`; public key into `Info.plist` `SUPublicEDKey`. Back up the private key offline: losing it means existing installs can't be updated.
2. Create the `gh-pages` branch and enable GitHub Pages from it.
3. Create public repo `roniburd/homebrew-macexplorer`; create a fine-grained token with contents write on it only → secret `HOMEBREW_TAP_TOKEN`.
4. If the spike requires it: create the self-signed certificate → `SELF_SIGNED_P12`, `SELF_SIGNED_P12_PASSWORD`.
5. Later (Developer ID): `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_API_KEY`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER`. No code change.

## 9. Rollout

1. Spike (§7) and record outcome.
2. Implement Core units, then UI, then bundle/CI.
3. Tag `v0.2.0-beta.1`; install manually from the DMG; set channel to Beta.
4. Tag `v0.2.0-beta.2`; verify background download, badge, Restart to Update, relaunch into beta.2; verify `brew install --cask roniburd/macexplorer/macexplorer@beta`.
5. File a test bug and a test crash report from the app; close them.
6. Tag `v0.2.0` (first release on the Release channel).
