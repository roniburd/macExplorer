# Install Previous Version — design (2026-11-08)

## Goal

Let the owner roll MacExplorer back to an earlier release from inside the app (macExplorer › Install Previous
Version…), without visiting GitHub, and without the updater immediately re-installing the newer build.

Owner decisions (2026-11-08):
- After a rollback, **skip until newer**: background update checks skip every build up to the one rolled back
  from; a build published later is still offered. A manual Check for Updates… clears the skip.
- Picker is a **window with a list** (version, local date, release-notes link, Install…).
- Only builds signed with the persistent self-signed cert are listed: **v0.2.0-beta.10 (build 182) and later**.

## Why not Sparkle

Sparkle 2 has no supported downgrade: `bestValidUpdateInAppcast` documents "do not pick an item that is worse than"
the installed version. MacExplorer keeps Sparkle for forward updates and installs rollbacks itself.

## Components

Core (pure, unit-tested, no AppKit):
- `Core/Updates/Appcast.swift` — `AppcastItem` (title, version string, build `Int`, channel, pubDate, notes URL,
  enclosure URL, length, EdDSA signature, minimum OS) and `AppcastParser.parse(Data) throws -> [AppcastItem]`
  (Foundation `XMLParser`; items without a numeric build or enclosure are dropped).
- `Core/Updates/RollbackCatalog.swift` — `RollbackCatalog.candidates(items, channel, installedBuild, osVersion)`:
  items the channel may see (`UpdateChannel.sparkleChannels`), build ≥ `minimumBuild` (182), build < installed,
  minimum OS satisfied; newest first, one per build.
- `Core/Updates/RollbackSignature.swift` — `RollbackSignature.verify(file:, signature:, publicKey:)` with CryptoKit
  Ed25519 (verified compatible with Sparkle's `sign_update` output against the real beta.13 zip).
- `Core/Updates/RollbackSkip.swift` — `PendingRollback { targetBuild, fromBuild, backupPath }` and
  `RollbackSkip` decisions:
  - `reconcile(pending:, installedBuild:) -> (skipThrough: Int?, trashBackup: String?)`: running as the target →
    skip through `fromBuild`; otherwise the rollback failed → no skip. Either way the pending record is dropped.
  - `shouldSkip(build:, skipThrough:) -> Bool`: build ≤ skipThrough.
- `Settings`: `updateSkipThroughBuild: Int?`, `pendingRollback: PendingRollback?` (optional keys, no schema bump).

UI:
- `UpdateController`: takes `installedBuild`; on init reconciles a pending rollback; `shouldProceed(version:build:)`
  also rejects skipped builds (silently: the existing suppressed-error path reports "no update" on background
  checks); a user-initiated check clears the skip before checking. Builds a `RollbackService` when updates are live.
- `UI/Updates/RollbackService.swift` — fetches the appcast (`SUFeedURL`), downloads the zip (URLSession with
  progress), verifies EdDSA, unzips with `/usr/bin/ditto`, then checks the unzipped app: bundle id equals ours,
  `CFBundleVersion` equals the item's build, and `SecStaticCodeCheckValidity` against the running app's designated
  requirement (same cert leaf). Stages the result in an item-replacement directory on the app's volume.
  Network, unzip and code-signing checks sit behind small protocols so tests use fakes.
- `UI/Updates/RollbackSwap.swift` — the swap helper: a `/bin/sh` script written into the staging directory and run
  once from `applicationWillTerminate` (so a cancelled quit never swaps). Arguments: our PID, app path, staged app,
  backup path. It waits (≤ 60 s) for the PID to exit, moves the current app to the backup path, moves the staged app
  in, and `open`s it; if the second move fails it moves the original back and opens that.
- `UI/Updates/RollbackModel.swift` + `RollbackView.swift` + `RollbackWindowController.swift` — states
  `loading`, `list([AppcastItem])`, `empty`, `downloading(item, fraction)`, `failed(message)`; Install… asks
  "MacExplorer will quit and reopen as X." then downloads, verifies, records `pendingRollback`, and quits.
- Menu: macExplorer › Install Previous Version… (`macx_installPreviousVersion:`, AppDelegate), enabled when the
  updater is live (never in debug, sandbox or scenario builds).

- Sparkle's own `SUSkippedVersion` default is also set to the build rolled back from (at quit). Background checks
  in Sparkle 2.10.1 skip every item ≤ it (`SUAppcastDriver` / `SPUSkippedUpdate.m`), and every release runs that
  Sparkle, so the skip also holds in older builds that predate `updateSkipThroughBuild`. A manual check in a build
  with this feature clears both. Older builds route Check for Updates… through Sparkle's background path too, so
  there the skip lasts until a newer release is published.

## Guards and errors

- Refused while an update is downloading or waiting to install (Sparkle would install it on the same quit):
  "Restart to finish the pending update first."
- Refused when the app isn't in a writable folder, or is translocated / on a disk image.
- Offline / HTTP failure, bad EdDSA signature, wrong cert / bundle id / build: a message in the window; the staged
  files are deleted and the installed app is never touched.
- After a successful swap, the next launch moves the backup app to the Trash.

## Testing

- CoreTests: parser (real-format fixture incl. channel, missing fields), catalog filtering, signature (fixture
  keypair generated in the test + tamper), skip/reconcile logic, Settings round-trip.
- UITests: RollbackModel state flow with fake service; UpdateController skip / clear-on-manual-check /
  reconcile; swap script against fake bundles in a temp directory the test creates.
- No UI scenario: the updater is disabled in scenario builds by design.

## Out of scope

Pinning a version permanently; installing pre-beta.10 builds; admin-authenticated installs.
