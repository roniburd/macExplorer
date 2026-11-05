# Distribution, Auto-Update, Feedback and Crash Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship MacExplorer as a downloadable, self-updating app (Release/Beta channels, VS Code–style "Restart to Update"), with in-app GitHub feedback, next-launch crash reporting, a tag-driven release pipeline and a Homebrew tap.

**Architecture:** Pure logic (channel, update state machine, issue URLs, crash-report discovery/parsing, session marker) lives in `Core` and is unit-tested without AppKit or Sparkle. `UI/Updates/SparkleBridge.swift` is the only file that imports Sparkle; it forwards Sparkle delegate/user-driver callbacks into a testable `UpdateController`, which drives an observable `UpdateModel` that the toolbar badge, menu and Settings read. A tag-triggered GitHub Actions workflow builds, signs (ad-hoc now, Developer ID later), publishes, updates the appcast on `gh-pages` and updates the Homebrew tap.

**Tech Stack:** Swift 6.2 / SwiftPM, AppKit + SwiftUI, XCTest, Sparkle 2 (SPM binary target), GitHub Actions (`macos-26`), GitHub Pages, Homebrew casks, Python 3 (stdlib only) for the appcast script.

**Spec:** `docs/superpowers/specs/2026-11-04-distribution-updates-feedback-design.md` (read it first). Main app spec: `docs/superpowers/specs/2026-11-01-macexplorer-design.md`.

## Global Constraints

- Work only in this worktree (`.claude/worktrees/distribution-updates-feedback`, branch `feature/distribution-updates-feedback`). Never edit the primary checkout.
- Layering `App → UI → Core → MacxFS → CFSKit`; `scripts/check-layering.sh` must pass. `Core` never imports AppKit/SwiftUI/Sparkle. Only `Sources/UI/Updates/SparkleBridge.swift` imports Sparkle.
- Warnings are errors (`.treatAllWarnings(as: .error)`); Swift 6 language mode, strict concurrency.
- Every user-visible string goes through `L10n.string("…")` and is added with `scripts/l10n-add.sh "…"` (`LocalizationCoverageTests` enforces it).
- Tests only create, read and delete files inside directories the test created (`MacxFixtures.Sandbox`). Never `UserDefaults.standard`, `NSPasteboard.general`, the real `~/Library/Logs/DiagnosticReports` or the real `~/Library/Application Support/macExplorer` in tests.
- Repository for issues and appcast: `roniburd/macExplorer`. Appcast URL: `https://roniburd.github.io/macExplorer/appcast.xml`. Tap repo: `roniburd/homebrew-macexplorer`.
- Bundle ID `com.macexplorer.app`; scenario copy `com.macexplorer.app.scenarios` never runs the updater.
- Beta tags match `v<semver>-beta.<n>`; Sparkle beta items carry `<sparkle:channel>beta</sparkle:channel>`.
- Issue URL length ≤ 7,500 characters. Crash excerpt: top 20 frames of the crashed thread; home path redacted to `~`.
- `lastReportedCrashes` keeps the newest 20 filenames.
- Build verification for every task: `swift build 2>&1 | tail -5` and the task's `swift test --filter …`; before each commit also `scripts/check-layering.sh`.
- Commit messages: conventional (`feat:`, `test:`, `build:`, `ci:`, `docs:`), one commit per task minimum.

## Review Focus

1. **Restart to Update while a file operation runs**: must go through the existing quit prompt; Cancel keeps the app running *and* the badge visible (Task 6 test `testRestartWhileJobsActiveDefersToQuitPath`, Task 8 test `testBadgeStaysAfterCancelledRestart`).
2. **App launched from the DMG or a translocated path**: Sparkle errors 1003/1005 must become "Move MacExplorer to Applications to get updates", not a generic failure (Task 6 test `testRunningFromDiskImageMapsToMoveToApplications`).
3. **Huge or garbage `.ips` files** (multi-MB, truncated, non-UTF-8, other apps' reports with our name prefix): locator and parser must skip them without trapping or blocking main (Task 4 tests `testGarbageAndTruncatedFilesAreSkipped`, `testOtherBundleIDIsIgnored`, `testOversizedFileIsSkipped`).
4. **Non-ASCII and reserved characters in issue fields** (`&`, `+`, `#`, emoji in a path inside a crash excerpt): must round-trip into the GitHub form, and truncation must never split a percent-escape or a grapheme (Task 2 tests `testReservedCharactersRoundTrip`, `testTruncationNeverExceedsCapAndKeepsMarker`).
5. **Switching Beta → Release while running a beta**: must not downgrade and must not show an error (Task 1 test `testReleaseChannelNeverAllowsBetaItems`, Task 9 test `testBetaNoteShownOnlyWhenRunningABetaOnRelease`).

---

## File Structure

| Path | Responsibility |
|---|---|
| `Sources/Core/Updates/UpdateChannel.swift` | Release/Beta enum → Sparkle channel set |
| `Sources/Core/Updates/UpdateState.swift` | `UpdateState`, `UpdateEvent`, `UpdateError`, pure reducer, badge visibility |
| `Sources/Core/Diagnostics/EnvironmentSummary.swift` | Version/build/channel/macOS/hardware snapshot |
| `Sources/Core/Diagnostics/IssueURLBuilder.swift` | Prefilled GitHub issue-form URL, length cap |
| `Sources/Core/Diagnostics/DirtyExitMarker.swift` | Session marker write/read/remove |
| `Sources/Core/Diagnostics/CrashReportLocator.swift` | Find newest unreported `.ips` for our bundle |
| `Sources/Core/Diagnostics/CrashExcerpt.swift` | Parse `.ips` → redacted excerpt |
| `Sources/Core/Settings/Settings.swift` (modify) | 4 new keys |
| `Sources/Core/Support/StatePaths.swift` (modify) | `sessionMarker`, `diagnosticReports(sandboxed:)` |
| `Sources/UI/Updates/UpdateModel.swift` | Observable state + command handlers for UI |
| `Sources/UI/Updates/UpdateController.swift` | Testable glue: engine, settings, pending install, error mapping |
| `Sources/UI/Updates/SparkleBridge.swift` | Only Sparkle importer: engine, delegate, user driver |
| `Sources/UI/Updates/UpdateBadge.swift` | Toolbar item + SwiftUI pill + popover |
| `Sources/UI/Feedback/FeedbackActions.swift` | Open bug/feature URLs |
| `Sources/UI/Feedback/CrashReportFlow.swift` | Next-launch crash detection → prompt → actions |
| `Sources/UI/Feedback/CrashReportPrompt.swift` | The NSAlert sheet |
| `Sources/UI/Settings/GeneralSettingsView.swift`, `AdvancedSettingsView.swift`, `SettingsView.swift`, `SettingsWindowController.swift`, `SettingsChoices.swift` (modify) | Updates group, crash toggle |
| `Sources/UI/Toolbar/ToolbarController.swift` (modify) | Feedback menu item, update badge item |
| `Sources/UI/Menus/MainMenuBuilder.swift` (modify) | Check for Updates…, Report a Bug…, Request a Feature… |
| `Sources/UI/App/UIContext.swift` (modify) | `updates: UpdateModel` |
| `Sources/App/AppBootstrap.swift`, `AppDelegate.swift` (modify) | Wire controller, marker, crash flow, menu actions |
| `Package.swift` (modify) | Sparkle dependency on `UI` |
| `Resources/Info.plist` (modify) | `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUScheduledCheckInterval` |
| `scripts/bundle.sh` (modify) | Embed Sparkle, rpath, `--version/--build/--sign/--feed-url/--universal` |
| `scripts/check-layering.sh`, `scripts/test-check-layering.sh` (modify) | Rule 9: Sparkle import confinement |
| `scripts/release/appcast.py` | Insert a signed item into `appcast.xml` |
| `scripts/release/render-cask.sh` | Render a cask `.rb` |
| `scripts/release/test-release-scripts.sh` | Tests for both |
| `.github/ISSUE_TEMPLATE/{bug,feature,config}.yml` | Issue forms |
| `.github/workflows/release.yml` | Tag → release pipeline |
| `.github/workflows/ci.yml` (modify) | Bundle/Sparkle/Info.plist checks |
| `README.md` (modify) | Install, updates, feedback, owner setup |
| Tests: `Tests/CoreTests/{UpdateStateTests,IssueURLBuilderTests,DirtyExitMarkerTests,CrashReportTests}.swift`, `Tests/CoreTests/Support/IPSFixture.swift`, `Tests/UITests/{UpdateControllerTests,UpdateBadgeTests,UpdateSettingsTests,FeedbackTests,CrashReportFlowTests}.swift` | |

---

### Task 1: Update channel, update state machine, new Settings keys

**Files:**
- Create: `Sources/Core/Updates/UpdateChannel.swift`, `Sources/Core/Updates/UpdateState.swift`
- Modify: `Sources/Core/Settings/Settings.swift`
- Test: `Tests/CoreTests/UpdateStateTests.swift`

**Interfaces:**
- Produces:
  - `public enum UpdateChannel: String, Sendable, Codable, CaseIterable { case release, beta; var sparkleChannels: Set<String> }`
  - `public enum UpdateError: Sendable, Equatable { case offline, network(String), verificationFailed(version: String?), notInApplications, other(String) }`
  - `public enum UpdateEvent: Sendable, Equatable { checkStarted(userInitiated: Bool), noUpdateFound(currentVersion: String), updateFound(version: String), downloadProgress(Double?), readyToInstall(version: String, notesURL: URL?), failed(UpdateError), acknowledged }`
  - `public enum UpdateState: Sendable, Equatable { idle, checking(userInitiated: Bool), upToDate(version: String), downloading(version: String, fraction: Double?, userInitiated: Bool), readyToRestart(version: String, notesURL: URL?), failed(UpdateError, userInitiated: Bool) }` with `func reduce(_:) -> UpdateState` and `var isBadgeVisible: Bool`
  - `Settings.updateChannel: UpdateChannel` (default `.release`), `Settings.checkForUpdatesAutomatically: Bool` (default `true`), `Settings.offerToReportCrashes: Bool` (default `true`), `Settings.lastReportedCrashes: [String]` (newest first, ≤ 20), `Settings.markCrashReported(_ fileName: String)`, `Settings.lastReportedCrashesLimit = 20`

- [ ] **Step 1: Write the failing tests**

`Tests/CoreTests/UpdateStateTests.swift`:

```swift
import Foundation
import XCTest
@testable import Core

final class UpdateStateTests: XCTestCase {
    private let notes = URL(string: "https://github.com/roniburd/macExplorer/releases/tag/v0.4.0")!

    func testReleaseChannelNeverAllowsBetaItems() {
        XCTAssertEqual(UpdateChannel.release.sparkleChannels, [])
        XCTAssertEqual(UpdateChannel.beta.sparkleChannels, ["beta"])
    }

    func testUserCheckFindsNothing() {
        let s = UpdateState.idle.reduce(.checkStarted(userInitiated: true)).reduce(.noUpdateFound(currentVersion: "0.3.1"))
        XCTAssertEqual(s, .upToDate(version: "0.3.1"))
        XCTAssertTrue(s.isBadgeVisible)
        XCTAssertEqual(s.reduce(.acknowledged), .idle)
    }

    func testBackgroundCheckFindingNothingStaysInvisible() {
        let s = UpdateState.idle.reduce(.checkStarted(userInitiated: false))
        XCTAssertFalse(s.isBadgeVisible)
        XCTAssertEqual(s.reduce(.noUpdateFound(currentVersion: "0.3.1")), .idle)
    }

    func testBackgroundUpdateDownloadsSilentlyThenShowsBadge() {
        var s = UpdateState.idle.reduce(.updateFound(version: "0.4.0"))
        XCTAssertEqual(s, .downloading(version: "0.4.0", fraction: nil, userInitiated: false))
        XCTAssertFalse(s.isBadgeVisible)
        s = s.reduce(.downloadProgress(0.5))
        XCTAssertEqual(s, .downloading(version: "0.4.0", fraction: 0.5, userInitiated: false))
        s = s.reduce(.readyToInstall(version: "0.4.0", notesURL: notes))
        XCTAssertEqual(s, .readyToRestart(version: "0.4.0", notesURL: notes))
        XCTAssertTrue(s.isBadgeVisible)
    }

    func testUserCheckShowsDownloadProgress() {
        let s = UpdateState.idle.reduce(.checkStarted(userInitiated: true)).reduce(.updateFound(version: "0.4.0"))
        XCTAssertEqual(s, .downloading(version: "0.4.0", fraction: nil, userInitiated: true))
        XCTAssertTrue(s.isBadgeVisible)
    }

    func testUserCheckDuringBackgroundDownloadBecomesVisible() {
        let s = UpdateState.downloading(version: "0.4.0", fraction: 0.2, userInitiated: false)
            .reduce(.checkStarted(userInitiated: true))
        XCTAssertEqual(s, .downloading(version: "0.4.0", fraction: 0.2, userInitiated: true))
    }

    func testReadyToRestartIsSticky() {
        let ready = UpdateState.readyToRestart(version: "0.4.0", notesURL: notes)
        for event: UpdateEvent in [.checkStarted(userInitiated: true), .noUpdateFound(currentVersion: "0.3.1"),
                                   .updateFound(version: "0.4.0"), .downloadProgress(0.3), .failed(.offline), .acknowledged] {
            XCTAssertEqual(ready.reduce(event), ready, "\(event)")
        }
        XCTAssertEqual(ready.reduce(.readyToInstall(version: "0.4.1", notesURL: nil)), .readyToRestart(version: "0.4.1", notesURL: nil))
    }

    func testBackgroundFailureIsSilentButVerificationFailureIsShown() {
        XCTAssertEqual(UpdateState.checking(userInitiated: false).reduce(.failed(.offline)), .idle)
        let v = UpdateState.downloading(version: "0.4.0", fraction: nil, userInitiated: false)
            .reduce(.failed(.verificationFailed(version: "0.4.0")))
        XCTAssertEqual(v, .failed(.verificationFailed(version: "0.4.0"), userInitiated: false))
        XCTAssertTrue(v.isBadgeVisible)
        XCTAssertEqual(v.reduce(.acknowledged), .idle)
    }

    func testUserFailureIsShown() {
        let s = UpdateState.checking(userInitiated: true).reduce(.failed(.network("timed out")))
        XCTAssertEqual(s, .failed(.network("timed out"), userInitiated: true))
        XCTAssertTrue(s.isBadgeVisible)
    }

    func testIrrelevantEventsAreIgnored() {
        XCTAssertEqual(UpdateState.idle.reduce(.downloadProgress(0.4)), .idle)
        XCTAssertEqual(UpdateState.idle.reduce(.acknowledged), .idle)
        XCTAssertEqual(UpdateState.upToDate(version: "1").reduce(.downloadProgress(0.4)), .upToDate(version: "1"))
    }

    @MainActor func testSettingsDefaultsAndPersistence() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
        XCTAssertEqual(s.updateChannel, .release)
        XCTAssertTrue(s.checkForUpdatesAutomatically)
        XCTAssertTrue(s.offerToReportCrashes)
        XCTAssertEqual(s.lastReportedCrashes, [])
        s.updateChannel = .beta
        s.checkForUpdatesAutomatically = false
        s.offerToReportCrashes = false
        for i in 0..<25 { s.markCrashReported("macExplorer-\(i).ips") }
        s.markCrashReported("macExplorer-3.ips")
        let reloaded = Settings(storage: storage, home: s.home)
        XCTAssertEqual(reloaded.updateChannel, .beta)
        XCTAssertFalse(reloaded.checkForUpdatesAutomatically)
        XCTAssertFalse(reloaded.offerToReportCrashes)
        XCTAssertEqual(reloaded.lastReportedCrashes.count, Settings.lastReportedCrashesLimit)
        XCTAssertEqual(reloaded.lastReportedCrashes.first, "macExplorer-3.ips")
        XCTAssertEqual(reloaded.lastReportedCrashes.filter { $0 == "macExplorer-3.ips" }.count, 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CoreTests.UpdateStateTests 2>&1 | tail -5`
Expected: compile errors (`cannot find 'UpdateState' in scope`).

- [ ] **Step 3: Implement**

`Sources/Core/Updates/UpdateChannel.swift`:

```swift
/// Which Sparkle appcast items the user may receive (spec §3). Release sees only items without a channel;
/// Beta also sees `<sparkle:channel>beta</sparkle:channel>` items. Sparkle always picks the newest allowed item, so
/// moving Beta → Release never downgrades.
public enum UpdateChannel: String, Sendable, Codable, CaseIterable {
    case release, beta

    public var sparkleChannels: Set<String> {
        switch self {
        case .release: []
        case .beta: ["beta"]
        }
    }
}
```

`Sources/Core/Updates/UpdateState.swift`:

```swift
import Foundation

public enum UpdateError: Sendable, Equatable {
    case offline
    case network(String)
    case verificationFailed(version: String?)
    /// Running from a disk image or a translocated location: Sparkle can't replace the app.
    case notInApplications
    case other(String)
}

public enum UpdateEvent: Sendable, Equatable {
    case checkStarted(userInitiated: Bool)
    case noUpdateFound(currentVersion: String)
    case updateFound(version: String)
    case downloadProgress(Double?)
    case readyToInstall(version: String, notesURL: URL?)
    case failed(UpdateError)
    /// The user closed the popover on a transient result (up to date, failed).
    case acknowledged
}

/// Spec §3: background work is invisible until an update is ready; user-initiated checks show every step.
public enum UpdateState: Sendable, Equatable {
    case idle
    case checking(userInitiated: Bool)
    case upToDate(version: String)
    case downloading(version: String, fraction: Double?, userInitiated: Bool)
    case readyToRestart(version: String, notesURL: URL?)
    case failed(UpdateError, userInitiated: Bool)

    public var isBadgeVisible: Bool {
        switch self {
        case .idle: false
        case .checking(let user): user
        case .upToDate: true
        case .downloading(_, _, let user): user
        case .readyToRestart: true
        case .failed(let error, let user):
            if case .verificationFailed = error { true } else { user }
        }
    }

    /// Pure transition. Events that make no sense in the current state return `self`.
    public func reduce(_ event: UpdateEvent) -> UpdateState {
        if case .readyToRestart = self {
            if case .readyToInstall(let version, let notes) = event { return .readyToRestart(version: version, notesURL: notes) }
            return self
        }
        switch (self, event) {
        case (_, .readyToInstall(let version, let notes)):
            return .readyToRestart(version: version, notesURL: notes)

        case (.checking(let was), .checkStarted(let user)):
            return .checking(userInitiated: was || user)
        case (.downloading(let v, let f, let was), .checkStarted(let user)):
            return .downloading(version: v, fraction: f, userInitiated: was || user)
        case (_, .checkStarted(let user)):
            return .checking(userInitiated: user)

        case (.checking(let user), .noUpdateFound(let current)):
            return user ? .upToDate(version: current) : .idle

        case (.checking(let user), .updateFound(let version)):
            return .downloading(version: version, fraction: nil, userInitiated: user)
        case (.idle, .updateFound(let version)), (.upToDate, .updateFound(let version)), (.failed, .updateFound(let version)):
            return .downloading(version: version, fraction: nil, userInitiated: false)

        case (.downloading(let v, _, let user), .downloadProgress(let f)):
            return .downloading(version: v, fraction: f, userInitiated: user)

        case (.checking(let user), .failed(let error)), (.downloading(_, _, let user), .failed(let error)):
            if case .verificationFailed = error { return .failed(error, userInitiated: user) }
            return user ? .failed(error, userInitiated: true) : .idle

        case (.upToDate, .acknowledged), (.failed, .acknowledged):
            return .idle

        default:
            return self
        }
    }
}
```

`Sources/Core/Settings/Settings.swift`: add after `showFullPathInTitle` property:

```swift
    public static let lastReportedCrashesLimit = 20
    public var updateChannel: UpdateChannel { didSet { save(updateChannel, Key.updateChannel) } }
    public var checkForUpdatesAutomatically: Bool { didSet { save(checkForUpdatesAutomatically, Key.checkForUpdatesAutomatically) } }
    public var offerToReportCrashes: Bool { didSet { save(offerToReportCrashes, Key.offerToReportCrashes) } }
    /// `.ips` file names already offered (newest first, ≤ 20), so one crash prompts once.
    public private(set) var lastReportedCrashes: [String] { didSet { save(lastReportedCrashes, Key.lastReportedCrashes) } }

    public func markCrashReported(_ fileName: String) {
        lastReportedCrashes = Array(([fileName] + lastReportedCrashes.filter { $0 != fileName }).prefix(Self.lastReportedCrashesLimit))
    }
```

(Place `lastReportedCrashesLimit` next to `recentLocationsLimit`.) In `init`, before the `schemaVersion` check:

```swift
        updateChannel = Self.load(UpdateChannel.self, Key.updateChannel, from: storage) ?? .release
        checkForUpdatesAutomatically = Self.load(Bool.self, Key.checkForUpdatesAutomatically, from: storage) ?? true
        offerToReportCrashes = Self.load(Bool.self, Key.offerToReportCrashes, from: storage) ?? true
        lastReportedCrashes = Array((Self.load([String].self, Key.lastReportedCrashes, from: storage) ?? []).prefix(Self.lastReportedCrashesLimit))
```

In `enum Key` add:

```swift
        static let updateChannel = "updateChannel", checkForUpdatesAutomatically = "checkForUpdatesAutomatically"
        static let offerToReportCrashes = "offerToReportCrashes", lastReportedCrashes = "lastReportedCrashes"
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter CoreTests.UpdateStateTests 2>&1 | tail -5` → all pass. Also `swift test --filter CoreTests.Settings 2>&1 | tail -3` → existing settings tests still pass.

- [ ] **Step 5: Commit**

```bash
scripts/check-layering.sh
git add Sources/Core/Updates Sources/Core/Settings/Settings.swift Tests/CoreTests/UpdateStateTests.swift
git commit -m "feat(core): update channel, update state machine and update/crash settings"
```

---

### Task 2: Environment summary, issue URL builder, GitHub issue forms

**Files:**
- Create: `Sources/Core/Diagnostics/EnvironmentSummary.swift`, `Sources/Core/Diagnostics/IssueURLBuilder.swift`, `.github/ISSUE_TEMPLATE/bug.yml`, `.github/ISSUE_TEMPLATE/feature.yml`, `.github/ISSUE_TEMPLATE/config.yml`
- Test: `Tests/CoreTests/IssueURLBuilderTests.swift`

**Interfaces:**
- Consumes: `UpdateChannel` (Task 1)
- Produces:
  - `public struct EnvironmentSummary: Sendable, Equatable { appVersion, build, channel, macOS, hardwareModel, architecture: String; init(...); static func current(bundle: Bundle, channel: UpdateChannel) -> EnvironmentSummary; var versionLine: String; var isBetaBuild: Bool }`
  - `public enum IssueKind: String, Sendable { case bug, feature; var template: String }`
  - `public enum IssueField { static let whatHappened, steps, expected, version, macos, hardware, channel, crashLog, problem, proposal: String; static func ids(for: IssueKind) -> [String] }`
  - `public enum IssueURLBuilder { static let newIssueBase: URL; static let maxLength = 7500; static let truncationMarker: String; static func url(kind: IssueKind, environment: EnvironmentSummary, title: String? = nil, crashExcerpt: String? = nil) -> URL }`

- [ ] **Step 1: Write the issue forms**

`.github/ISSUE_TEMPLATE/bug.yml`:

```yaml
name: Bug report
description: Something in MacExplorer doesn't work the way it should.
labels: [bug, from-app]
body:
  - type: textarea
    id: what-happened
    attributes:
      label: What happened?
      description: What did you do, what did you see?
    validations:
      required: true
  - type: textarea
    id: steps
    attributes:
      label: Steps to reproduce
      placeholder: "1. Open …\n2. Press …"
  - type: textarea
    id: expected
    attributes:
      label: What did you expect?
  - type: input
    id: version
    attributes:
      label: MacExplorer version
  - type: input
    id: macos
    attributes:
      label: macOS version
  - type: input
    id: hardware
    attributes:
      label: Mac model
  - type: input
    id: channel
    attributes:
      label: Update channel
  - type: textarea
    id: crash-log
    attributes:
      label: Crash log
      description: If MacExplorer crashed, the app copied the full report to your clipboard — paste it here, or drag the .ips file in.
      render: text
```

`.github/ISSUE_TEMPLATE/feature.yml`:

```yaml
name: Feature request
description: Suggest something MacExplorer should do.
labels: [enhancement, from-app]
body:
  - type: textarea
    id: problem
    attributes:
      label: What problem would this solve?
    validations:
      required: true
  - type: textarea
    id: proposal
    attributes:
      label: What would you like to happen?
  - type: input
    id: version
    attributes:
      label: MacExplorer version
```

`.github/ISSUE_TEMPLATE/config.yml`:

```yaml
blank_issues_enabled: true
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoreTests/IssueURLBuilderTests.swift`:

```swift
import Foundation
import XCTest
@testable import Core

final class IssueURLBuilderTests: XCTestCase {
    private static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let env = EnvironmentSummary(appVersion: "0.4.0-beta.1", build: "812", channel: "beta",
                                         macOS: "26.1 (25B78)", hardwareModel: "Mac16,10", architecture: "arm64")

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    /// The `id:` values of a form, read from the YAML (simple line scan; the forms are ours).
    private func formIDs(_ name: String) throws -> Set<String> {
        let text = try String(contentsOf: Self.repo.appending(path: ".github/ISSUE_TEMPLATE/\(name)"), encoding: .utf8)
        return Set(text.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("id: ") ? String(t.dropFirst(4)) : nil
        })
    }

    func testFieldIDsMatchTheForms() throws {
        XCTAssertTrue(Set(IssueField.ids(for: .bug)).isSubset(of: try formIDs("bug.yml")))
        XCTAssertTrue(Set(IssueField.ids(for: .feature)).isSubset(of: try formIDs("feature.yml")))
    }

    func testBugURLIsPrefilled() {
        let url = IssueURLBuilder.url(kind: .bug, environment: env)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/roniburd/macExplorer/issues/new?"))
        let q = query(url)
        XCTAssertEqual(q["template"], "bug.yml")
        XCTAssertEqual(q["version"], "0.4.0-beta.1 (812)")
        XCTAssertEqual(q["macos"], "26.1 (25B78)")
        XCTAssertEqual(q["hardware"], "Mac16,10 (arm64)")
        XCTAssertEqual(q["channel"], "beta")
        XCTAssertNil(q["crash-log"])
    }

    func testFeatureURLHasOnlyVersion() {
        let q = query(IssueURLBuilder.url(kind: .feature, environment: env))
        XCTAssertEqual(q["template"], "feature.yml")
        XCTAssertEqual(q["version"], "0.4.0-beta.1 (812)")
        XCTAssertNil(q["macos"])
    }

    func testReservedCharactersRoundTrip() {
        let excerpt = "a&b=c+d #1 ? 100% ~/Docs/Ünïcødé 📁/x"
        let url = IssueURLBuilder.url(kind: .bug, environment: env, title: "Crash: A&B", crashExcerpt: excerpt)
        let q = query(url)
        XCTAssertEqual(q["crash-log"], excerpt)
        XCTAssertEqual(q["title"], "Crash: A&B")
        XCTAssertFalse(url.absoluteString.contains("+"), "a literal + would decode as a space")
    }

    func testTruncationNeverExceedsCapAndKeepsMarker() {
        let huge = String(repeating: "frame 📁 &x\n", count: 5000)
        let url = IssueURLBuilder.url(kind: .bug, environment: env, crashExcerpt: huge)
        XCTAssertLessThanOrEqual(url.absoluteString.count, IssueURLBuilder.maxLength)
        let log = query(url)["crash-log"] ?? ""
        XCTAssertTrue(log.hasSuffix(IssueURLBuilder.truncationMarker))
        XCTAssertTrue(huge.hasPrefix(String(log.dropLast(IssueURLBuilder.truncationMarker.count))))
        XCTAssertGreaterThan(log.count, 1000, "uses most of the budget")
    }

    func testShortExcerptIsNotTruncated() {
        let q = query(IssueURLBuilder.url(kind: .bug, environment: env, crashExcerpt: "short"))
        XCTAssertEqual(q["crash-log"], "short")
    }

    func testBetaBuildDetection() {
        XCTAssertTrue(env.isBetaBuild)
        var r = env
        r.appVersion = "0.4.0"
        XCTAssertFalse(r.isBetaBuild)
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter CoreTests.IssueURLBuilderTests 2>&1 | tail -5` → compile errors.

- [ ] **Step 4: Implement**

`Sources/Core/Diagnostics/EnvironmentSummary.swift`:

```swift
import Foundation

/// What a bug report needs to know about this install (spec §4.1). Everything is shown to the user on GitHub before
/// it is submitted.
public struct EnvironmentSummary: Sendable, Equatable {
    public var appVersion: String
    public var build: String
    public var channel: String
    public var macOS: String
    public var hardwareModel: String
    public var architecture: String

    public init(appVersion: String, build: String, channel: String, macOS: String, hardwareModel: String, architecture: String) {
        self.appVersion = appVersion
        self.build = build
        self.channel = channel
        self.macOS = macOS
        self.hardwareModel = hardwareModel
        self.architecture = architecture
    }

    public var versionLine: String { "\(appVersion) (\(build))" }
    public var hardwareLine: String { "\(hardwareModel) (\(architecture))" }
    public var isBetaBuild: Bool { appVersion.contains("-beta") }

    public static func current(bundle: Bundle = .main, channel: UpdateChannel) -> EnvironmentSummary {
        let info = bundle.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osBuild = sysctlString("kern.osversion").map { " (\($0))" } ?? ""
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return EnvironmentSummary(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            channel: channel.rawValue,
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\(osBuild)",
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            architecture: arch)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
```

`Sources/Core/Diagnostics/IssueURLBuilder.swift`:

```swift
import Foundation

public enum IssueKind: String, Sendable, CaseIterable {
    case bug, feature
    public var template: String { "\(rawValue).yml" }
}

/// Field `id:`s in `.github/ISSUE_TEMPLATE/*.yml` (IssueURLBuilderTests checks they exist there).
public enum IssueField {
    public static let whatHappened = "what-happened", steps = "steps", expected = "expected"
    public static let version = "version", macos = "macos", hardware = "hardware", channel = "channel"
    public static let crashLog = "crash-log", problem = "problem", proposal = "proposal"

    public static func ids(for kind: IssueKind) -> [String] {
        switch kind {
        case .bug: [whatHappened, steps, expected, version, macos, hardware, channel, crashLog]
        case .feature: [problem, proposal, version]
        }
    }
}

/// Prefilled GitHub issue-form links (spec §4.1). No network, no token: the user reviews and submits on GitHub.
public enum IssueURLBuilder {
    public static let newIssueBase = URL(string: "https://github.com/roniburd/macExplorer/issues/new")!
    /// GitHub's practical URL limit is ~8 KB; stay well under it.
    public static let maxLength = 7500
    public static let truncationMarker = "\n… [truncated — full report on clipboard]"

    /// Unreserved characters only (RFC 3986): `+`, `&`, `=`, `#` and everything else are percent-encoded.
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }

    public static func url(kind: IssueKind, environment: EnvironmentSummary, title: String? = nil,
                           crashExcerpt: String? = nil) -> URL {
        var pairs: [(String, String)] = [("template", kind.template)]
        if let title { pairs.append(("title", title)) }
        switch kind {
        case .bug:
            pairs += [(IssueField.version, environment.versionLine), (IssueField.macos, environment.macOS),
                      (IssueField.hardware, environment.hardwareLine), (IssueField.channel, environment.channel)]
        case .feature:
            pairs.append((IssueField.version, environment.versionLine))
        }
        let head = newIssueBase.absoluteString + "?" + pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        guard kind == .bug, let crashExcerpt, !crashExcerpt.isEmpty else { return URL(string: head)! }
        let prefix = "&\(IssueField.crashLog)="
        let budget = maxLength - head.count - prefix.count
        return URL(string: head + prefix + fitted(crashExcerpt, budget: budget))!
    }

    /// The whole excerpt if its encoding fits `budget`, else the longest prefix (whole Characters) + marker that does.
    static func fitted(_ text: String, budget: Int) -> String {
        let full = encode(text)
        if full.count <= budget { return full }
        let chars = Array(text)
        var lo = 0, hi = chars.count, best = encode(truncationMarker)
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candidate = encode(String(chars[0..<mid]) + truncationMarker)
            if candidate.count <= budget { best = candidate; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter CoreTests.IssueURLBuilderTests 2>&1 | tail -5` → all pass.

- [ ] **Step 6: Commit**

```bash
scripts/check-layering.sh
git add Sources/Core/Diagnostics/EnvironmentSummary.swift Sources/Core/Diagnostics/IssueURLBuilder.swift .github/ISSUE_TEMPLATE Tests/CoreTests/IssueURLBuilderTests.swift
git commit -m "feat(core): prefilled GitHub issue URLs and bug/feature issue forms"
```

---

### Task 3: Dirty-exit session marker

**Files:**
- Create: `Sources/Core/Diagnostics/DirtyExitMarker.swift`
- Modify: `Sources/Core/Support/StatePaths.swift`
- Test: `Tests/CoreTests/DirtyExitMarkerTests.swift`

**Interfaces:**
- Produces:
  - `StatePaths.sessionMarker: URL` (`root/session.marker`), `StatePaths.diagnosticReports(sandboxed: Bool) -> URL` (sandboxed → `root/DiagnosticReports`; else `~/Library/Logs/DiagnosticReports`)
  - `public struct SessionMarker: Codable, Sendable, Equatable { pid: Int32; version: String; build: String; launchedAt: Date }`
  - `public enum PreviousSession: Sendable, Equatable { case clean, dirty(SessionMarker), dirtyUnknown }`
  - `public struct DirtyExitMarker: Sendable { let fileURL: URL; init(fileURL:); func previous() -> PreviousSession; func begin(_: SessionMarker) throws; func end() }`

- [ ] **Step 1: Write the failing tests**

`Tests/CoreTests/DirtyExitMarkerTests.swift`:

```swift
import Foundation
import MacxFixtures
import XCTest
@testable import Core

final class DirtyExitMarkerTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private func marker() -> DirtyExitMarker { DirtyExitMarker(fileURL: sandbox.url("state/session.marker")) }
    private let sample = SessionMarker(pid: 42, version: "0.4.0", build: "812", launchedAt: Date(timeIntervalSince1970: 1_800_000_000))

    func testFirstLaunchIsClean() { XCTAssertEqual(marker().previous(), .clean) }

    func testBeginThenNoEndIsDirty() throws {
        try marker().begin(sample)
        XCTAssertEqual(marker().previous(), .dirty(sample))
    }

    func testEndMakesItClean() throws {
        try marker().begin(sample)
        marker().end()
        XCTAssertEqual(marker().previous(), .clean)
        marker().end()   // idempotent
    }

    func testCorruptMarkerIsDirtyUnknown() throws {
        _ = try sandbox.createDirectory("state")
        _ = try sandbox.createFile("state/session.marker", contents: Data("{nope".utf8))
        XCTAssertEqual(marker().previous(), .dirtyUnknown)
    }

    func testStatePaths() {
        let paths = StatePaths(root: sandbox.root)
        XCTAssertEqual(paths.sessionMarker.lastPathComponent, "session.marker")
        XCTAssertEqual(paths.diagnosticReports(sandboxed: true), sandbox.root.appending(path: "DiagnosticReports", directoryHint: .isDirectory))
        XCTAssertTrue(paths.diagnosticReports(sandboxed: false).path.hasSuffix("Library/Logs/DiagnosticReports"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CoreTests.DirtyExitMarkerTests 2>&1 | tail -5` → compile errors.

- [ ] **Step 3: Implement**

`Sources/Core/Support/StatePaths.swift`: add after `settingsFile`:

```swift
    /// `root/session.marker`: present while the app runs; left behind by a crash (spec §4.2).
    public var sessionMarker: URL { root.appending(path: "session.marker", directoryHint: .notDirectory) }

    /// Where macOS writes our crash reports. Sandbox runs look in `root/DiagnosticReports` so scenarios can plant fixtures.
    public func diagnosticReports(sandboxed: Bool) -> URL {
        if sandboxed { return root.appending(path: "DiagnosticReports", directoryHint: .isDirectory) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }
```

`Sources/Core/Diagnostics/DirtyExitMarker.swift`:

```swift
import Foundation

public struct SessionMarker: Codable, Sendable, Equatable {
    public var pid: Int32
    public var version: String
    public var build: String
    public var launchedAt: Date
    public init(pid: Int32, version: String, build: String, launchedAt: Date) {
        self.pid = pid
        self.version = version
        self.build = build
        self.launchedAt = launchedAt
    }
}

public enum PreviousSession: Sendable, Equatable {
    case clean
    case dirty(SessionMarker)
    /// A marker exists but can't be read: the last session didn't end cleanly; its launch time is unknown.
    case dirtyUnknown
}

/// Written at launch, removed on clean termination (spec §4.2). Small, synchronous, local file I/O.
public struct DirtyExitMarker: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func previous() -> PreviousSession {
        guard let data = try? Data(contentsOf: fileURL) else { return .clean }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(SessionMarker.self, from: data) else { return .dirtyUnknown }
        return .dirty(marker)
    }

    public func begin(_ marker: SessionMarker) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: fileURL, options: .atomic)
    }

    public func end() { try? FileManager.default.removeItem(at: fileURL) }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter CoreTests.DirtyExitMarkerTests 2>&1 | tail -5` → pass.

- [ ] **Step 5: Commit**

```bash
scripts/check-layering.sh
git add Sources/Core/Diagnostics/DirtyExitMarker.swift Sources/Core/Support/StatePaths.swift Tests/CoreTests/DirtyExitMarkerTests.swift
git commit -m "feat(core): dirty-exit session marker"
```

---

### Task 4: Crash report locator and excerpt parser

**Files:**
- Create: `Sources/Core/Diagnostics/CrashReportLocator.swift`, `Sources/Core/Diagnostics/CrashExcerpt.swift`, `Tests/CoreTests/Support/IPSFixture.swift`
- Test: `Tests/CoreTests/CrashReportTests.swift`

**Interfaces:**
- Produces:
  - `public struct CrashReport: Sendable, Equatable { fileURL: URL; fileName: String; timestamp: Date }`
  - `public struct CrashReportLocator: Sendable { init(directory: URL, bundleID: String, processName: String = "macExplorer"); static let maxFileSize = 8 * 1024 * 1024; func newest(after: Date?, excluding: Set<String>) -> CrashReport? }`
  - `public struct CrashExcerpt: Sendable, Equatable { exceptionType: String?; signal: String?; terminationReason: String?; frames: [String]; appVersion: String; build: String; static let maxFrames = 20; static func parse(_ text: String, home: String) -> CrashExcerpt?; static func redact(_ text: String, home: String) -> String; var title: String; var text: String }`
  - Test helper `enum IPSFixture { static func make(bundleID:timestamp:bugType:appVersion:build:home:) -> String }`

- [ ] **Step 1: Write the fixture builder**

`Tests/CoreTests/Support/IPSFixture.swift` (an `.ips` is a one-line header JSON, a newline, then the body JSON):

```swift
import Foundation

enum IPSFixture {
    static func make(bundleID: String = "com.macexplorer.app", timestamp: String = "2026-11-04 10:11:12.00 -0800",
                     bugType: String = "309", appVersion: String = "0.4.0", build: String = "812",
                     home: String = "/Users/tester", frameCount: Int = 30) -> String {
        let header: [String: Any] = [
            "app_name": "macExplorer", "timestamp": timestamp, "app_version": appVersion, "build_version": build,
            "bundleID": bundleID, "bug_type": bugType, "os_version": "macOS 26.1 (25B78)", "name": "macExplorer",
        ]
        let frames: [[String: Any]] = (0..<frameCount).map { i in
            i % 3 == 2 ? ["imageOffset": 4096 + i, "imageIndex": 1]
                       : ["imageOffset": 1000 + i, "symbol": "Core.Thing.method\(i)()", "symbolLocation": i, "imageIndex": 0]
        }
        let body: [String: Any] = [
            "procPath": "\(home)/Applications/MacExplorer.app/Contents/MacOS/macExplorer",
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x0"],
            "termination": ["indicator": "Segmentation fault: 11", "namespace": "SIGNAL", "code": 11],
            "faultingThread": 1,
            "threads": [["frames": [["imageOffset": 1, "imageIndex": 0]]], ["triggered": true, "frames": frames]],
            "usedImages": [
                ["name": "macExplorer", "path": "\(home)/Applications/MacExplorer.app/Contents/MacOS/macExplorer"],
                ["name": "libsystem_kernel.dylib", "path": "/usr/lib/system/libsystem_kernel.dylib"],
            ],
        ]
        func json(_ o: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)! }
        return json(header) + "\n" + json(body)
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/CoreTests/CrashReportTests.swift`:

```swift
import Foundation
import MacxFixtures
import XCTest
@testable import Core

final class CrashReportTests: XCTestCase {
    private var sandbox: Sandbox!
    private var dir: URL!
    override func setUpWithError() throws { sandbox = try Sandbox(); dir = try sandbox.createDirectory("DiagnosticReports") }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private func locator() -> CrashReportLocator { CrashReportLocator(directory: dir, bundleID: "com.macexplorer.app") }
    private func plant(_ name: String, _ text: String) throws { _ = try sandbox.createFile("DiagnosticReports/\(name)", contents: Data(text.utf8)) }
    /// 2026-11-04 10:11:12 -0800
    private let crashTime = Date(timeIntervalSince1970: 1_793_815_872)

    func testFindsNewestMatchingReport() throws {
        try plant("macExplorer-2026-11-04-101112.ips", IPSFixture.make())
        try plant("macExplorer-2026-11-04-111112.ips", IPSFixture.make(timestamp: "2026-11-04 11:11:12.00 -0800"))
        let found = try XCTUnwrap(locator().newest(after: nil, excluding: []))
        XCTAssertEqual(found.fileName, "macExplorer-2026-11-04-111112.ips")
    }

    func testOlderThanLaunchIsIgnored() throws {
        try plant("macExplorer-a.ips", IPSFixture.make())
        XCTAssertNil(locator().newest(after: crashTime.addingTimeInterval(60), excluding: []))
        XCTAssertNotNil(locator().newest(after: crashTime.addingTimeInterval(-60), excluding: []))
    }

    func testAlreadyReportedIsIgnored() throws {
        try plant("macExplorer-a.ips", IPSFixture.make())
        XCTAssertNil(locator().newest(after: nil, excluding: ["macExplorer-a.ips"]))
    }

    func testOtherBundleIDIsIgnored() throws {
        try plant("macExplorer-a.ips", IPSFixture.make(bundleID: "com.macexplorer.app.scenarios"))
        try plant("macExplorer-b.ips", IPSFixture.make(bugType: "288"))   // a hang/spin report, not a crash
        try plant("Finder-c.ips", IPSFixture.make())                      // wrong file name prefix
        XCTAssertNil(locator().newest(after: nil, excluding: []))
    }

    func testGarbageAndTruncatedFilesAreSkipped() throws {
        try plant("macExplorer-a.ips", "not json at all")
        try plant("macExplorer-b.ips", String(IPSFixture.make().prefix(40)))
        _ = try sandbox.createFile("DiagnosticReports/macExplorer-c.ips", contents: Data([0xFF, 0xFE, 0x00, 0x81]))
        try plant("macExplorer-d.ips", IPSFixture.make())
        XCTAssertEqual(locator().newest(after: nil, excluding: [])?.fileName, "macExplorer-d.ips")
    }

    func testOversizedFileIsSkipped() throws {
        let big = IPSFixture.make() + String(repeating: " ", count: CrashReportLocator.maxFileSize)
        try plant("macExplorer-big.ips", big)
        XCTAssertNil(locator().newest(after: nil, excluding: []))
    }

    func testMissingDirectoryFindsNothing() {
        XCTAssertNil(CrashReportLocator(directory: sandbox.url("nope"), bundleID: "com.macexplorer.app").newest(after: nil, excluding: []))
    }

    func testExcerptParsesAndRedacts() throws {
        let e = try XCTUnwrap(CrashExcerpt.parse(IPSFixture.make(home: "/Users/tester"), home: "/Users/tester"))
        XCTAssertEqual(e.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(e.signal, "SIGSEGV")
        XCTAssertEqual(e.terminationReason, "Segmentation fault: 11")
        XCTAssertEqual(e.frames.count, CrashExcerpt.maxFrames)
        XCTAssertEqual(e.frames[0], "0  macExplorer  Core.Thing.method0() + 0")
        XCTAssertEqual(e.frames[2], "2  libsystem_kernel.dylib  + 0x1002")
        XCTAssertEqual(e.title, "Crash: EXC_BAD_ACCESS (SIGSEGV) in 0.4.0")
        XCTAssertFalse(e.text.contains("/Users/tester"))
        XCTAssertTrue(e.text.contains("0.4.0 (812)"))
    }

    func testRedactReplacesEveryHomeOccurrence() {
        XCTAssertEqual(CrashExcerpt.redact("/Users/tester/a and /Users/tester/b /Users/testerX", home: "/Users/tester"),
                       "~/a and ~/b /Users/testerX")
    }

    func testParseNeverTrapsOnTruncations() {
        let full = IPSFixture.make()
        for cut in stride(from: 0, to: full.count, by: 97) {
            _ = CrashExcerpt.parse(String(full.prefix(cut)), home: "/Users/tester")
        }
        XCTAssertNil(CrashExcerpt.parse("", home: "/Users/tester"))
    }
}
```

- [ ] **Step 3: Run to verify failure** — `swift test --filter CoreTests.CrashReportTests 2>&1 | tail -5` → compile errors.

- [ ] **Step 4: Implement**

`Sources/Core/Diagnostics/CrashReportLocator.swift`:

```swift
import Foundation

public struct CrashReport: Sendable, Equatable {
    public var fileURL: URL
    public var fileName: String
    public var timestamp: Date
}

/// Finds macOS's crash report for our previous session (spec §4.2). Blocking file I/O: call off the main actor.
public struct CrashReportLocator: Sendable {
    public static let maxFileSize = 8 * 1024 * 1024
    /// `bug_type` of a crash report (hangs and spins use other values).
    static let crashBugType = "309"

    public let directory: URL
    public let bundleID: String
    public let processName: String

    public init(directory: URL, bundleID: String, processName: String = "macExplorer") {
        self.directory = directory
        self.bundleID = bundleID
        self.processName = processName
    }

    public func newest(after launchedAt: Date?, excluding reported: Set<String>) -> CrashReport? {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return nil }
        return urls.compactMap { report(at: $0, keys: Set(keys)) }
            .filter { !reported.contains($0.fileName) && (launchedAt.map { l in $0.timestamp > l } ?? true) }
            .max { $0.timestamp < $1.timestamp }
    }

    private func report(at url: URL, keys: Set<URLResourceKey>) -> CrashReport? {
        let name = url.lastPathComponent
        guard name.hasPrefix("\(processName)-"), url.pathExtension == "ips",
              let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              let size = values.fileSize, size <= Self.maxFileSize,
              let data = try? Data(contentsOf: url),
              let header = Self.header(data),
              header["bundleID"] as? String == bundleID,
              header["bug_type"] as? String == Self.crashBugType else { return nil }
        let stamp = (header["timestamp"] as? String).flatMap(Self.parseTimestamp) ?? values.contentModificationDate ?? .distantPast
        return CrashReport(fileURL: url, fileName: name, timestamp: stamp)
    }

    /// Line 1 of an `.ips` is a JSON object.
    static func header(_ data: Data) -> [String: Any]? {
        let line = data.prefix { $0 != UInt8(ascii: "\n") }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// "2026-11-04 10:11:12.00 -0800"
    static func parseTimestamp(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return f.date(from: s)
    }
}
```

`Sources/Core/Diagnostics/CrashExcerpt.swift`:

```swift
import Foundation

/// The part of a crash report that goes into the GitHub issue (spec §4.2), with the home path replaced by `~`.
public struct CrashExcerpt: Sendable, Equatable {
    public static let maxFrames = 20

    public var exceptionType: String?
    public var signal: String?
    public var terminationReason: String?
    public var frames: [String]
    public var appVersion: String
    public var build: String

    public var title: String {
        let kind = [exceptionType, signal.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return "Crash: \(kind.isEmpty ? "unknown" : kind) in \(appVersion)"
    }

    public var text: String {
        var lines = ["MacExplorer \(appVersion) (\(build))"]
        if let exceptionType { lines.append("Exception: \(exceptionType)\(signal.map { " (\($0))" } ?? "")") }
        if let terminationReason { lines.append("Termination: \(terminationReason)") }
        lines.append("Crashed thread:")
        lines += frames
        return lines.joined(separator: "\n")
    }

    public static func redact(_ text: String, home: String) -> String {
        guard !home.isEmpty else { return text }
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        // Replace "<home>" only when followed by "/" or the end, never inside a longer name (/Users/testerX).
        var out = "", rest = Substring(text)
        while let r = rest.range(of: h) {
            let after = rest[r.upperBound...]
            out += rest[..<r.lowerBound]
            if after.isEmpty || after.hasPrefix("/") { out += "~" } else { out += h }
            rest = after
        }
        return out + rest
    }

    public static func parse(_ text: String, home: String) -> CrashExcerpt? {
        let redacted = redact(text, home: home)
        guard let newline = redacted.firstIndex(of: "\n"),
              let header = json(redacted[..<newline]),
              let body = json(redacted[redacted.index(after: newline)...]) else { return nil }
        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let faulting = body["faultingThread"] as? Int
        let crashed = threads.first { $0["triggered"] as? Bool == true }
            ?? faulting.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
        let rawFrames = (crashed?["frames"] as? [[String: Any]]) ?? []
        let frames = rawFrames.prefix(maxFrames).enumerated().map { i, f -> String in
            let imageIndex = f["imageIndex"] as? Int
            let image = imageIndex.flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "???"
            if let symbol = f["symbol"] as? String {
                return "\(i)  \(image)  \(symbol) + \(f["symbolLocation"] as? Int ?? 0)"
            }
            return "\(i)  \(image)  + 0x\(String(f["imageOffset"] as? Int ?? 0, radix: 16))"
        }
        return CrashExcerpt(exceptionType: exception?["type"] as? String, signal: exception?["signal"] as? String,
                            terminationReason: termination?["indicator"] as? String, frames: frames,
                            appVersion: header["app_version"] as? String ?? "unknown",
                            build: header["build_version"] as? String ?? "unknown")
    }

    private static func json(_ s: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }
}
```

- [ ] **Step 5: Run tests** — `swift test --filter CoreTests.CrashReportTests 2>&1 | tail -5` → pass. If `testOlderThanLaunchIsIgnored` fails, recompute `crashTime` with `CrashReportLocator.parseTimestamp("2026-11-04 10:11:12.00 -0800")` in the test instead of the literal.

- [ ] **Step 6: Commit**

```bash
scripts/check-layering.sh
git add Sources/Core/Diagnostics/CrashReportLocator.swift Sources/Core/Diagnostics/CrashExcerpt.swift Tests/CoreTests/Support/IPSFixture.swift Tests/CoreTests/CrashReportTests.swift
git commit -m "feat(core): locate and excerpt macOS crash reports for the previous session"
```

---

### Task 5: Sparkle dependency, bundle embedding, version stamping, layering rule

**Files:**
- Modify: `Package.swift`, `Resources/Info.plist`, `scripts/bundle.sh`, `scripts/check-layering.sh`, `scripts/test-check-layering.sh`

**Interfaces:**
- Produces:
  - `import Sparkle` available in target `UI` (product `Sparkle`).
  - `scripts/bundle.sh [debug|release] [--bundle-id ID] [--output PATH] [--version X.Y.Z[-beta.N]] [--build N] [--sign IDENTITY] [--feed-url URL] [--ed-public-key KEY] [--universal]` (defaults: Info.plist version/build, `--sign -` ad-hoc, Info.plist feed/key).
  - Bundle contains `Contents/Frameworks/Sparkle.framework`; executable has rpath `@executable_path/../Frameworks`.
  - Layering rule `sparkle-confined`: only `Sources/UI/Updates/SparkleBridge.swift` may `import Sparkle`.

- [ ] **Step 1: Pin Sparkle**

Run: `gh api repos/sparkle-project/Sparkle/releases/latest --jq .tag_name` → note the version (e.g. `2.8.1`). In `Package.swift` add to `Package(...)` before `targets:`:

```swift
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "<VERSION FROM gh api>"),
    ],
```

and change the `UI` target dependencies to `["Core", "MacxFS", .product(name: "Sparkle", package: "Sparkle")]`.

Run: `swift package resolve && swift build 2>&1 | tail -3` → builds. Run: `ls "$(swift build --show-bin-path)/Sparkle.framework"` → exists. Run: `ls .build/artifacts/sparkle/Sparkle/bin` → shows `generate_keys`, `sign_update`, `generate_appcast` (note the exact path; later tasks use `SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin`).

- [ ] **Step 2: Layering rule (test first)**

Read `scripts/test-check-layering.sh` to see how it builds a fake repo per rule; add a case in the same style that writes `Sources/UI/Settings/Bad.swift` containing `import Sparkle` and expects `RULE sparkle-confined`, and a case writing `Sources/UI/Updates/SparkleBridge.swift` with `import Sparkle` expecting no violation. Run `scripts/test-check-layering.sh` → the new case fails.

In `scripts/check-layering.sh`, before the final `if [ "$violations" -gt 0 ]`, add:

```bash
# 9. Sparkle is imported in exactly one file (distribution spec §2): everything else talks to UpdateController.
report sparkle-confined < <(scan "${IMPORT}Sparkle${END}" Sources Tests | grep -v '^Sources/UI/Updates/SparkleBridge.swift:')
```

and change the final message to `check-layering: OK (9 rules)`. Run `scripts/test-check-layering.sh && scripts/check-layering.sh` → both pass (update any test that asserts the "8 rules" text).

- [ ] **Step 3: Info.plist keys**

Add to `Resources/Info.plist` (alphabetical position among keys is not required, but keep `SU*` together after `NSSupportsSuddenTermination`):

```xml
	<key>SUAutomaticallyUpdate</key>
	<true/>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUFeedURL</key>
	<string>https://roniburd.github.io/macExplorer/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>REPLACE_WITH_SPARKLE_PUBLIC_KEY</string>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
```

`REPLACE_WITH_SPARKLE_PUBLIC_KEY` is a deliberate sentinel: `UpdateController` (Task 6) treats it as "updates not configured" and stays inert; `bundle.sh --ed-public-key` overwrites it; CI release refuses to publish with it (Task 13). The owner replaces it in Task 14.

- [ ] **Step 4: bundle.sh options and Sparkle embedding**

In `scripts/bundle.sh`:

1. Update the usage comment and `usage()` to the new signature above.
2. Add variables after `output=…`: `version="" build="" sign_identity="-" feed_url="" ed_key="" universal=0`.
3. Add cases in the argument loop:

```bash
        --version) [ $# -ge 2 ] && [ -n "$2" ] || usage; version="$2"; shift ;;
        --build) [ $# -ge 2 ] && [ -n "$2" ] || usage; build="$2"; shift ;;
        --sign) [ $# -ge 2 ] && [ -n "$2" ] || usage; sign_identity="$2"; shift ;;
        --feed-url) [ $# -ge 2 ] && [ -n "$2" ] || usage; feed_url="$2"; shift ;;
        --ed-public-key) [ $# -ge 2 ] && [ -n "$2" ] || usage; ed_key="$2"; shift ;;
        --universal) universal=1 ;;
```

4. Validate: `case "$version" in ""|[0-9]*.[0-9]*.[0-9]*) ;; *) echo "bundle.sh: invalid --version $version" >&2; exit 64 ;; esac` and `case "$build" in ""|*[!0-9]*) [ -z "$build" ] || { echo "bundle.sh: --build must be digits" >&2; exit 64; } ;; esac`.
5. Replace the build lines with:

```bash
arch_args=()
[ "$universal" -eq 1 ] && arch_args=(--arch arm64 --arch x86_64)
swift build -c "$config" "${arch_args[@]}" --product macExplorer
bin="$(swift build -c "$config" "${arch_args[@]}" --show-bin-path)"
[ -d "$bin/Sparkle.framework" ] || { echo "bundle.sh: no Sparkle.framework at $bin" >&2; exit 1; }
```

6. After copying the UI resource bundle, add:

```bash
mkdir -p "$app/Contents/Frameworks"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/macExplorer" 2>/dev/null || true
plist="$app/Contents/Info.plist"
[ -z "$version" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
[ -z "$build" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
[ -z "$feed_url" ] || /usr/libexec/PlistBuddy -c "Set :SUFeedURL $feed_url" "$plist"
[ -z "$ed_key" ] || /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $ed_key" "$plist"
```

7. Replace the two `codesign` lines with inside-out signing:

```bash
sp="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --sign "$sign_identity" --options runtime --timestamp=none "$@"; }
for xpc in "$sp"/XPCServices/*.xpc; do [ -e "$xpc" ] && sign "$xpc"; done
sign "$sp/Autoupdate"
sign "$sp/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign --entitlements Resources/macExplorer.entitlements --identifier "$bundle_id" "$app/Contents/MacOS/macExplorer"
sign --entitlements Resources/macExplorer.entitlements "$app"
codesign --verify --deep --strict "$app"
```

(`--timestamp=none` is required for ad-hoc; when `sign_identity` is a Developer ID, Task 13's workflow passes `--sign "Developer ID Application: …"` and the timestamp must be on — make `sign()` use `--timestamp` instead of `--timestamp=none` when `sign_identity != "-"`.)

- [ ] **Step 5: Verify the bundle**

Run:

```bash
scripts/bundle.sh release --version 0.2.0-beta.1 --build 7 --output "$PWD/.build/check/MacExplorer.app"
codesign --verify --deep --strict .build/check/MacExplorer.app && echo SIGNED-OK
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' .build/check/MacExplorer.app/Contents/Info.plist
otool -l .build/check/MacExplorer.app/Contents/MacOS/macExplorer | grep -A2 LC_RPATH | grep Frameworks
.build/check/MacExplorer.app/Contents/MacOS/macExplorer --help 2>&1 | head -2 || true
```

Expected: `SIGNED-OK`, `0.2.0-beta.1` / `7`, an `@executable_path/../Frameworks` rpath line, and the binary starts (no `dyld: Library not loaded: @rpath/Sparkle.framework`). Then `rm -rf .build/check`. Run `swift test 2>&1 | tail -3` → all existing tests pass; run `scripts/ui-scenarios.sh` if it passes on this machine today (it uses bundle.sh).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Resources/Info.plist scripts/bundle.sh scripts/check-layering.sh scripts/test-check-layering.sh
git commit -m "build: embed Sparkle 2, stamp version/build, configurable signing identity"
```

---

### Task 6: UpdateModel, UpdateController, SparkleBridge, app wiring, Check for Updates…

**Files:**
- Create: `Sources/UI/Updates/UpdateModel.swift`, `Sources/UI/Updates/UpdateController.swift`, `Sources/UI/Updates/SparkleBridge.swift`
- Modify: `Sources/UI/App/UIContext.swift`, `Sources/UI/Menus/MainMenuBuilder.swift`, `Sources/App/AppBootstrap.swift`, `Sources/App/AppDelegate.swift`
- Test: `Tests/UITests/UpdateControllerTests.swift`

**Interfaces:**
- Consumes: `UpdateState/UpdateEvent/UpdateError/UpdateChannel`, `Settings` keys (Task 1); `EnvironmentSummary` (Task 2).
- Produces:
  - `@MainActor @Observable public final class UpdateModel { private(set) var state: UpdateState; var installedVersion: String; var isAvailable: Bool; var popoverRequest: Int; func send(_: UpdateEvent); func checkNow(userInitiated: Bool = true); func restartNow(); func acknowledge(); func setAutomaticChecks(_: Bool); func addObserver(_: @escaping @MainActor (UpdateState) -> Void) -> UpdateObservation }`
  - `@MainActor protocol UpdaterEngine: AnyObject { var automaticallyChecksForUpdates: Bool { get set }; func start() throws; func checkInBackground() }`
  - `@MainActor public final class UpdateController { init(model:settings:engine:installedVersion:terminate:); func allowedChannels() -> Set<String>; func didFindUpdate(version: String); func didNotFindUpdate(); func willInstallOnQuit(version: String, notesURL: URL?, install: @escaping @MainActor () -> Void); func didAbort(domain: String, code: Int, message: String); func downloadProgress(_: Double?); func readyToInstall(version: String, notesURL: URL?, install: @escaping @MainActor () -> Void); static func mapError(domain:code:message:version:) -> UpdateError; static func isConfigured(info: [String: Any]) -> Bool; public static func live(model:settings:options:bundle:) -> UpdateController? }`
  - `UIContext.updates: UpdateModel`
  - App selector `macx_checkForUpdates:` (AppDelegate)

- [ ] **Step 1: Write the failing tests**

`Tests/UITests/UpdateControllerTests.swift`:

```swift
import XCTest
@testable import UI
@testable import Core

@MainActor
private final class FakeEngine: UpdaterEngine {
    var automaticallyChecksForUpdates = true
    private(set) var started = 0, checks = 0
    func start() throws { started += 1 }
    func checkInBackground() { checks += 1 }
}

@MainActor
final class UpdateControllerTests: XCTestCase {
    private func make(channel: UpdateChannel = .release) -> (UpdateController, UpdateModel, FakeEngine, Core.Settings, () -> Int) {
        let settings = Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
        settings.updateChannel = channel
        let model = UpdateModel(), engine = FakeEngine()
        var terminations = 0
        let c = UpdateController(model: model, settings: settings, engine: engine, installedVersion: "0.3.1",
                                 terminate: { terminations += 1 })
        return (c, model, engine, settings, { terminations })
    }

    func testStartAppliesSettingsAndChannels() {
        let (c, model, engine, settings, _) = make(channel: .beta)
        XCTAssertEqual(engine.started, 1)
        XCTAssertTrue(model.isAvailable)
        XCTAssertEqual(c.allowedChannels(), ["beta"])
        settings.updateChannel = .release
        XCTAssertEqual(c.allowedChannels(), [])
        model.setAutomaticChecks(false)
        XCTAssertFalse(engine.automaticallyChecksForUpdates)
        XCTAssertFalse(settings.checkForUpdatesAutomatically)
    }

    func testUserCheckFlowsToUpToDate() {
        let (c, model, engine, _, _) = make()
        model.checkNow()
        XCTAssertEqual(engine.checks, 1)
        XCTAssertEqual(model.state, .checking(userInitiated: true))
        XCTAssertEqual(model.popoverRequest, 1)
        c.didNotFindUpdate()
        XCTAssertEqual(model.state, .upToDate(version: "0.3.1"))
    }

    func testBackgroundCheckDoesNotOpenPopover() {
        let (_, model, engine, _, _) = make()
        model.checkNow(userInitiated: false)
        XCTAssertEqual(engine.checks, 1)
        XCTAssertEqual(model.popoverRequest, 0)
        XCTAssertFalse(model.state.isBadgeVisible)
    }

    func testSilentInstallOnQuitShowsBadgeAndRestartInstalls() {
        let (c, model, _, _, terminations) = make()
        var installs = 0
        c.didFindUpdate(version: "0.4.0")
        c.willInstallOnQuit(version: "0.4.0", notesURL: nil) { installs += 1 }
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: nil))
        model.restartNow()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(terminations(), 0)
    }

    func testRestartWhileJobsActiveDefersToQuitPath() {
        // Sparkle's install block asks NSApp to terminate, which runs AppLifecycle.shouldTerminate (quit prompt).
        // If the user cancels, the block is spent: a second Restart Now falls back to a plain terminate request,
        // which goes through the same prompt; Sparkle still installs on quit.
        let (c, model, _, _, terminations) = make()
        var installs = 0
        c.willInstallOnQuit(version: "0.4.0", notesURL: nil) { installs += 1 }
        model.restartNow()
        model.restartNow()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(terminations(), 1)
        XCTAssertEqual(model.state, .readyToRestart(version: "0.4.0", notesURL: nil))
    }

    func testBackgroundNetworkFailureIsSilent() {
        let (c, model, _, _, _) = make()
        c.didFindUpdate(version: "0.4.0")
        c.didAbort(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, message: "offline")
        XCTAssertEqual(model.state, .idle)
    }

    func testVerificationFailureIsShown() {
        let (c, model, _, _, _) = make()
        c.didFindUpdate(version: "0.4.0")
        c.didAbort(domain: "SUSparkleErrorDomain", code: 3001, message: "bad signature")
        XCTAssertEqual(model.state, .failed(.verificationFailed(version: "0.4.0"), userInitiated: false))
    }

    func testRunningFromDiskImageMapsToMoveToApplications() {
        XCTAssertEqual(UpdateController.mapError(domain: "SUSparkleErrorDomain", code: 1003, message: "", version: nil), .notInApplications)
        XCTAssertEqual(UpdateController.mapError(domain: "SUSparkleErrorDomain", code: 1005, message: "", version: nil), .notInApplications)
        XCTAssertEqual(UpdateController.mapError(domain: "SUSparkleErrorDomain", code: 3002, message: "", version: "1"), .verificationFailed(version: "1"))
        XCTAssertEqual(UpdateController.mapError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, message: "", version: nil), .offline)
        XCTAssertEqual(UpdateController.mapError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, message: "timed out", version: nil), .network("timed out"))
        XCTAssertEqual(UpdateController.mapError(domain: "X", code: 1, message: "boom", version: nil), .other("boom"))
    }

    func testIsConfiguredRequiresARealKeyAndFeed() {
        XCTAssertFalse(UpdateController.isConfigured(info: [:]))
        XCTAssertFalse(UpdateController.isConfigured(info: ["SUFeedURL": "https://x/appcast.xml", "SUPublicEDKey": "REPLACE_WITH_SPARKLE_PUBLIC_KEY"]))
        XCTAssertTrue(UpdateController.isConfigured(info: ["SUFeedURL": "https://x/appcast.xml", "SUPublicEDKey": "abc123="]))
    }

    func testModelWithoutControllerIsUnavailableAndInert() {
        let model = UpdateModel()
        XCTAssertFalse(model.isAvailable)
        model.checkNow()
        XCTAssertEqual(model.state, .idle)
    }

    func testObserversSeeEveryChange() {
        let model = UpdateModel()
        var seen: [UpdateState] = []
        let token = model.addObserver { seen.append($0) }
        model.send(.checkStarted(userInitiated: true))
        model.send(.noUpdateFound(currentVersion: "1"))
        XCTAssertEqual(seen, [.checking(userInitiated: true), .upToDate(version: "1")])
        _ = token
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter UITests.UpdateControllerTests 2>&1 | tail -5` → compile errors.

- [ ] **Step 3: Implement UpdateModel**

`Sources/UI/Updates/UpdateModel.swift`:

```swift
import Foundation
import Observation
import os
import Core

/// Removes its observer when released.
@MainActor public final class UpdateObservation {
    private let cancel: @MainActor () -> Void
    init(_ cancel: @escaping @MainActor () -> Void) { self.cancel = cancel }
    isolated deinit { cancel() }
}

/// What the toolbar badge, the menu and Settings read (spec §3). `UpdateController` installs the handlers; without
/// one (debug builds, sandbox runs, updates not configured) the model stays `.idle` and `isAvailable` is false.
@MainActor @Observable
public final class UpdateModel {
    private static let log = Logger(subsystem: "com.macexplorer.app", category: "updates")
    public private(set) var state: UpdateState = .idle
    public var installedVersion: String = ""
    /// Incremented by user-initiated checks: the key window's badge opens its popover.
    public private(set) var popoverRequest = 0

    @ObservationIgnored var checkHandler: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var restartHandler: (@MainActor () -> Void)?
    @ObservationIgnored var automaticChecksHandler: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var observers: [UUID: @MainActor (UpdateState) -> Void] = [:]

    public init() {}

    public var isAvailable: Bool { checkHandler != nil }

    public func send(_ event: UpdateEvent) {
        // Spec §2.1: illegal transitions are ignored *and logged* (review of Task 1).
        guard let next = state.transition(event) else {
            Self.log.debug("ignored update event \(String(describing: event), privacy: .public) in state \(String(describing: self.state), privacy: .public)")
            return
        }
        guard next != state else { return }
        state = next
        for observer in observers.values { observer(next) }
    }

    public func checkNow(userInitiated: Bool = true) {
        guard let checkHandler else { return }
        if userInitiated { popoverRequest += 1 }
        send(.checkStarted(userInitiated: userInitiated))
        checkHandler(userInitiated)
    }

    public func restartNow() { restartHandler?() }
    public func acknowledge() { send(.acknowledged) }
    public func setAutomaticChecks(_ on: Bool) { automaticChecksHandler?(on) }

    public func addObserver(_ handler: @escaping @MainActor (UpdateState) -> Void) -> UpdateObservation {
        let id = UUID()
        observers[id] = handler
        return UpdateObservation { [weak self] in self?.observers[id] = nil }
    }
}
```

(If `isolated deinit` is not accepted by the toolchain, replace `UpdateObservation` with a final class whose `cancel()` must be called by the owner in its own teardown, and update `ToolbarController` in Task 8 accordingly.)

- [ ] **Step 4: Implement UpdateController**

`Sources/UI/Updates/UpdateController.swift`:

```swift
import Foundation
import Core

/// The Sparkle engine as `UpdateController` needs it (a fake in tests; `SparkleEngine` in SparkleBridge.swift).
@MainActor protocol UpdaterEngine: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    func start() throws
    func checkInBackground()
}

/// Glue between Sparkle callbacks (forwarded by SparkleBridge) and `UpdateModel` (spec §3). No Sparkle types here.
@MainActor
public final class UpdateController {
    /// The Info.plist sentinel for "no EdDSA key configured yet".
    static let unsetKey = "REPLACE_WITH_SPARKLE_PUBLIC_KEY"

    let model: UpdateModel
    private let settings: Core.Settings
    private let engine: any UpdaterEngine
    private let installedVersion: String
    private let terminate: @MainActor () -> Void
    private var pendingInstall: (@MainActor () -> Void)?
    private var foundVersion: String?

    init(model: UpdateModel, settings: Core.Settings, engine: any UpdaterEngine, installedVersion: String,
         terminate: @escaping @MainActor () -> Void) {
        self.model = model
        self.settings = settings
        self.engine = engine
        self.installedVersion = installedVersion
        self.terminate = terminate
        model.installedVersion = installedVersion
        engine.automaticallyChecksForUpdates = settings.checkForUpdatesAutomatically
        model.checkHandler = { [weak self] _ in self?.engine.checkInBackground() }
        model.restartHandler = { [weak self] in self?.restart() }
        model.automaticChecksHandler = { [weak self] on in
            self?.settings.checkForUpdatesAutomatically = on
            self?.engine.automaticallyChecksForUpdates = on
        }
        do { try engine.start() } catch {
            NSLog("MacExplorer updater failed to start: %@", String(describing: error))
            model.checkHandler = nil
        }
    }

    // MARK: Sparkle → model (called by SparkleBridge)

    func allowedChannels() -> Set<String> { settings.updateChannel.sparkleChannels }

    func didFindUpdate(version: String) {
        foundVersion = version
        model.send(.updateFound(version: version))
    }

    func didNotFindUpdate() { model.send(.noUpdateFound(currentVersion: installedVersion)) }

    func downloadProgress(_ fraction: Double?) { model.send(.downloadProgress(fraction)) }

    /// Silent path: Sparkle downloaded and will install on quit; `install` installs and relaunches now.
    func willInstallOnQuit(version: String, notesURL: URL?, install: @escaping @MainActor () -> Void) {
        readyToInstall(version: version, notesURL: notesURL, install: install)
    }

    /// Foreground (user-driver) path: same UI, different Sparkle reply.
    func readyToInstall(version: String, notesURL: URL?, install: @escaping @MainActor () -> Void) {
        pendingInstall = install
        model.send(.readyToInstall(version: version, notesURL: notesURL))
    }

    func didAbort(domain: String, code: Int, message: String) {
        let error = Self.mapError(domain: domain, code: code, message: message, version: foundVersion)
        NSLog("MacExplorer update failed: %@ %ld %@", domain, code, message)
        model.send(.failed(error))
    }

    // MARK: model → Sparkle

    private func restart() {
        if let install = pendingInstall {
            pendingInstall = nil
            install()
        } else if case .readyToRestart = model.state {
            terminate()   // Sparkle still installs on quit; the quit prompt guards running jobs.
        }
    }

    // MARK: pure helpers

    /// Sparkle codes from SUErrors.h (verify against the pinned version's header): 1003 running from a disk image,
    /// 1005 translocated, 3001 signature, 3002 validation.
    static func mapError(domain: String, code: Int, message: String, version: String?) -> UpdateError {
        if domain == "SUSparkleErrorDomain" {
            switch code {
            case 1003, 1005: return .notInApplications
            case 3001, 3002: return .verificationFailed(version: version)
            default: return .other(message)
            }
        }
        if domain == NSURLErrorDomain {
            switch code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed: return .offline
            default: return .network(message)
            }
        }
        return .other(message)
    }

    static func isConfigured(info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty, key != unsetKey else { return false }
        return true
    }

    /// The app's controller, or nil when updates must stay off: debug builds, sandbox/scenario runs, unconfigured keys.
    public static func live(model: UpdateModel, settings: Core.Settings, options: LaunchOptions,
                            bundle: Bundle = .main) -> UpdateController? {
        #if DEBUG
        return nil
        #else
        guard !options.isSandboxed, bundle.bundleIdentifier?.hasSuffix(".scenarios") == false,
              isConfigured(info: bundle.infoDictionary ?? [:]) else { return nil }
        return SparkleBridge.makeController(model: model, settings: settings, bundle: bundle)
        #endif
    }
}
```

- [ ] **Step 5: Implement SparkleBridge**

`Sources/UI/Updates/SparkleBridge.swift` (the only Sparkle importer). Check every method signature against the pinned version's `SPUUpdaterDelegate.h` and `SPUUserDriver.h` in `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Headers/`; the Swift names below are Sparkle 2's.

```swift
import AppKit
import Core
@preconcurrency import Sparkle

/// Sparkle 2 behind `UpdaterEngine` (spec §2.2). Delegate and user-driver callbacks are forwarded to UpdateController;
/// nothing here decides UI. Silent path: SUAutomaticallyUpdate downloads in the background and calls
/// `willInstallUpdateOnQuit` with an "install now" block. Foreground path (user driver) covers updates Sparkle can't
/// install silently.
@MainActor
enum SparkleBridge {
    static func makeController(model: UpdateModel, settings: Core.Settings, bundle: Bundle) -> UpdateController {
        let installed = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let forwarder = Forwarder()
        let driver = UserDriver(forwarder: forwarder, settings: settings)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: forwarder)
        let engine = SparkleEngine(updater: updater, retained: [forwarder, driver])
        let controller = UpdateController(model: model, settings: settings, engine: engine, installedVersion: installed,
                                          terminate: { NSApp.terminate(nil) })
        forwarder.controller = controller
        return controller
    }
}

@MainActor
final class SparkleEngine: UpdaterEngine {
    let updater: SPUUpdater
    private let retained: [AnyObject]
    init(updater: SPUUpdater, retained: [AnyObject]) { self.updater = updater; self.retained = retained }
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    func start() throws { try updater.start() }
    /// Background check even when the user asked: the silent download path then applies (spec §3.2); the popover
    /// shows progress from the delegate callbacks.
    func checkInBackground() { updater.checkForUpdatesInBackground() }
}

@MainActor
final class Forwarder: NSObject, SPUUpdaterDelegate {
    weak var controller: UpdateController?

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { controller?.allowedChannels() ?? [] }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { controller?.didFindUpdate(version: version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { controller?.didNotFindUpdate() }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        let notes = item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL
        nonisolated(unsafe) let install = immediateInstallHandler
        return MainActor.assumeIsolated {
            controller?.willInstallOnQuit(version: version, notesURL: notes, install: { install() })
            return controller != nil
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let e = error as NSError
        guard !(e.domain == SUSparkleErrorDomain && e.code == Int(SUError.noUpdateError.rawValue)) else { return }
        MainActor.assumeIsolated { controller?.didAbort(domain: e.domain, code: e.code, message: e.localizedDescription) }
    }
}

/// Replaces Sparkle's standard windows. Only reached for user-driver (foreground) flows.
@MainActor
final class UserDriver: NSObject, SPUUserDriver {
    private let forwarder: Forwarder
    private let settings: Core.Settings
    private var expected: UInt64 = 0, received: UInt64 = 0
    private var version = ""
    private var notes: URL?

    init(forwarder: Forwarder, settings: Core.Settings) { self.forwarder = forwarder; self.settings = settings }
    private var controller: UpdateController? { forwarder.controller }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: settings.checkForUpdatesAutomatically, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        version = appcastItem.displayVersionString
        notes = appcastItem.fullReleaseNotesURL ?? appcastItem.releaseNotesURL ?? appcastItem.infoURL
        if state.stage == .notDownloaded {
            controller?.didFindUpdate(version: version)
            reply(.install)   // download now; showReady follows
        } else {
            controller?.readyToInstall(version: version, notesURL: notes) { reply(.install) }
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.didNotFindUpdate()
        acknowledgement()
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let e = error as NSError
        controller?.didAbort(domain: e.domain, code: e.code, message: e.localizedDescription)
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { expected = 0; received = 0; controller?.downloadProgress(nil) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        controller?.downloadProgress(expected > 0 ? min(1, Double(received) / Double(expected)) : nil)
    }
    func showDownloadDidStartExtractingUpdate() { controller?.downloadProgress(nil) }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller?.readyToInstall(version: version, notesURL: notes) { reply(.install) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        // Termination was cancelled (quit prompt → Cancel): keep the badge; Restart Now retries.
        if !applicationTerminated { controller?.readyToInstall(version: version, notesURL: notes) { retryTerminatingApplication() } }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}
```

Build it: `swift build 2>&1 | grep -E "error|warning" | head -20`. Expect to adjust: (a) if `SPUUserDriver` methods are already `@MainActor` in the pinned headers, drop `@preconcurrency`; (b) if the delegate protocol is main-actor annotated, remove `nonisolated` + `MainActor.assumeIsolated`; (c) `nonisolated(unsafe)` is allowed in UI (rule 8 only limits Core/MacxFS) but must have a comment — add `// Sparkle calls the block on main; we only call it on main.` Iterate until warnings-free.

- [ ] **Step 6: Wire into the app**

`Sources/UI/App/UIContext.swift`: add `public let updates = UpdateModel()` below `options`.

`Sources/App/AppBootstrap.swift`: change `launch` to also return the controller:

```swift
    static func launch(options: LaunchOptions, statePaths: StatePaths)
        async -> (context: UIContext, lifecycle: AppLifecycle, updates: UpdateController?) {
        // … existing body up to lifecycle.didLaunch(recovery:) …
        let updates = UpdateController.live(model: context.updates, settings: environment.settings, options: options)
        return (context, lifecycle, updates)
    }
```

`Sources/App/AppDelegate.swift`: add `private var updateController: UpdateController?`; in the launch task set `self.updateController = launched.updates`; add:

```swift
    /// macExplorer › Check for Updates…
    @objc func macx_checkForUpdates(_ sender: Any?) {
        guard let context else { return }
        if context.windows.windows.isEmpty { newWindow(nil) }
        context.updates.checkNow()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == NSSelectorFromString("macx_checkForUpdates:") { return context?.updates.isAvailable ?? false }
        return true
    }
```

(If `AppDelegate` already validates elsewhere, merge into that method instead.)

`Sources/UI/Menus/MainMenuBuilder.swift` `appItems()`: after the About item insert

```swift
            standard("Check for Updates…", NSSelectorFromString("macx_checkForUpdates:")),
```

Strings: `scripts/l10n-add.sh "Check for Updates…"`.

- [ ] **Step 7: Run tests**

Run: `swift test --filter UITests.UpdateControllerTests 2>&1 | tail -5` → pass. Run: `swift test --filter UITests.MenuValidation 2>&1 | tail -5` and `swift test --filter UITests.LocalizationCoverage 2>&1 | tail -3` → pass (update any test enumerating the app menu's items to include "Check for Updates…").

- [ ] **Step 8: Commit**

```bash
scripts/check-layering.sh
git add Sources/UI/Updates Sources/UI/App/UIContext.swift Sources/UI/Menus/MainMenuBuilder.swift Sources/App Sources/UI/Resources/Localizable.xcstrings Tests/UITests/UpdateControllerTests.swift
git commit -m "feat(updates): Sparkle-backed UpdateController, update model and Check for Updates…"
```

---

### Task 7: Ad-hoc update spike (manual, throwaway artifacts)

Answers spec §7. Everything lives under `/tmp/macx-spike/` and is deleted at the end. Nothing is committed except the recorded result.

- [ ] **Step 1: Throwaway keys**

```bash
SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"
mkdir -p /tmp/macx-spike/feed
"$SPARKLE_BIN/generate_keys" --account macexplorer-spike | tee /tmp/macx-spike/keys.txt
PUB=$("$SPARKLE_BIN/generate_keys" --account macexplorer-spike -p)
```

- [ ] **Step 2: Build 0.0.1 and 0.0.2**

```bash
for v in 1 2; do
  scripts/bundle.sh release --bundle-id com.macexplorer.app.spike --version 0.0.$v --build $v \
    --feed-url http://127.0.0.1:8765/appcast.xml --ed-public-key "$PUB" \
    --output /tmp/macx-spike/v$v/MacExplorer.app
done
(cd /tmp/macx-spike/v2 && ditto -c -k --keepParent MacExplorer.app ../feed/MacExplorer-0.0.2.zip)
"$SPARKLE_BIN/generate_appcast" --account macexplorer-spike /tmp/macx-spike/feed
python3 -m http.server 8765 --bind 127.0.0.1 --directory /tmp/macx-spike/feed   # run in background
```

- [ ] **Step 3: Run the old version, grant TCC, update**

1. `cp -R /tmp/macx-spike/v1/MacExplorer.app /tmp/macx-spike/installed/` and open it. Navigate to `~/Desktop`; grant access.
2. MacExplorer › Check for Updates… → wait for "Restart to Update" (badge UI arrives in Task 8; until then watch Console for `MacExplorer update` logs and quit the app to install on quit).
3. Relaunch `/tmp/macx-spike/installed/MacExplorer.app`; About shows 0.0.2.
4. Navigate to `~/Desktop` again.

Record: (a) did Sparkle install 0.0.2? (any `SUSparkleErrorDomain` 3001/3002 or "code signature" errors in Console → no); (b) did macOS prompt for Desktop again?

If Sparkle refuses the `http://127.0.0.1` feed (`SUInsecureFeedURLError`, code 3), serve with HTTPS instead: `python3 -I` with an `ssl` context and a throwaway self-signed cert trusted only for the run, or push the feed to a scratch GitHub Pages repo you own — note which in the result.

- [ ] **Step 4: If (a) or (b) failed: retry with a stable self-signed identity**

Create a throwaway code-signing certificate in a throwaway keychain:

```bash
security create-keychain -p spike /tmp/macx-spike/spike.keychain-db
security set-keychain-settings /tmp/macx-spike/spike.keychain-db
security unlock-keychain -p spike /tmp/macx-spike/spike.keychain-db
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=MacExplorer Self-Signed" \
  -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=digitalSignature" \
  -keyout /tmp/macx-spike/key.pem -out /tmp/macx-spike/cert.pem
openssl pkcs12 -export -legacy -inkey /tmp/macx-spike/key.pem -in /tmp/macx-spike/cert.pem -out /tmp/macx-spike/cert.p12 -passout pass:spike
security import /tmp/macx-spike/cert.p12 -k /tmp/macx-spike/spike.keychain-db -P spike -T /usr/bin/codesign
security list-keychains -d user -s /tmp/macx-spike/spike.keychain-db $(security list-keychains -d user | tr -d '"')
```

Rebuild both versions with `--sign "MacExplorer Self-Signed"` and repeat Step 3. Record the result.

- [ ] **Step 5: Clean up**

Stop the HTTP server; `security delete-keychain /tmp/macx-spike/spike.keychain-db` (if created; this also removes it from the search list); `security delete-generic-password -s "https://sparkle-project.org" -a macexplorer-spike` (removes the throwaway EdDSA key only); `rm -rf /tmp/macx-spike`; `tccutil reset All com.macexplorer.app.spike`.

- [ ] **Step 6: Record and commit**

Replace the "Outcomes" bullet list in spec §7 with a "Result (2026-11-xx)" paragraph: what was tested, (a)/(b) for ad-hoc, (a)/(b) for self-signed if run, and the decision: `RELEASE_SIGNING=adhoc` or `RELEASE_SIGNING=self-signed`. Task 13 reads this decision.

```bash
git add docs/superpowers/specs/2026-11-04-distribution-updates-feedback-design.md
git commit -m "docs: record ad-hoc update spike result"
```

If the decision is self-signed, the owner action in Task 14 includes creating the real certificate (`SELF_SIGNED_P12`, `SELF_SIGNED_P12_PASSWORD`, `SELF_SIGNED_IDENTITY`).

---

### Task 8: Update badge in the toolbar

**Files:**
- Create: `Sources/UI/Updates/UpdateBadge.swift`
- Modify: `Sources/UI/Toolbar/ToolbarController.swift`, `Sources/UI/Support/AXID.swift`
- Test: `Tests/UITests/UpdateBadgeTests.swift`; update `Tests/UITests/ToolbarTests.swift` if it lists default identifiers

**Interfaces:**
- Consumes: `UpdateModel` (Task 6), `UIContext.updates`.
- Produces:
  - `ToolbarController.updateID = NSToolbarItem.Identifier("macx.toolbar.update")`; default identifiers become `[navigation, address, search, viewSwitcher, feedback, update]` (feedback item is added in Task 10; in this task append only `update`).
  - `enum UpdateBadgeText { static func pill(_: UpdateState) -> String?; static func headline(_: UpdateState) -> String; static func detail(_: UpdateState) -> String? }`
  - `final class UpdateBadgeItem: NSToolbarItem` (`isHidden` follows `state.isBadgeVisible`; `var isPopoverShown: Bool` for tests)
  - `AXID.updateBadge = "macx.updateBadge"`

- [ ] **Step 1: Write the failing tests**

`Tests/UITests/UpdateBadgeTests.swift`:

```swift
import XCTest
import AppKit
@testable import UI
@testable import Core

@MainActor
final class UpdateBadgeTests: XCTestCase {
    func testTextForEachState() {
        XCTAssertNil(UpdateBadgeText.pill(.idle))
        XCTAssertEqual(UpdateBadgeText.pill(.readyToRestart(version: "0.4.0", notesURL: nil)), "Restart to Update")
        XCTAssertEqual(UpdateBadgeText.pill(.checking(userInitiated: true)), "Checking…")
        XCTAssertEqual(UpdateBadgeText.headline(.readyToRestart(version: "0.4.0", notesURL: nil)), "MacExplorer 0.4.0 is ready")
        XCTAssertEqual(UpdateBadgeText.headline(.upToDate(version: "0.3.1")), "You're up to date (0.3.1)")
        XCTAssertEqual(UpdateBadgeText.headline(.failed(.verificationFailed(version: "0.4.0"), userInitiated: false)),
                       "This update couldn't be verified and wasn't installed.")
        XCTAssertEqual(UpdateBadgeText.headline(.failed(.notInApplications, userInitiated: true)),
                       "Move MacExplorer to the Applications folder to get updates.")
        XCTAssertEqual(UpdateBadgeText.headline(.failed(.offline, userInitiated: true)),
                       "Couldn't check for updates. You're offline.")
        XCTAssertEqual(UpdateBadgeText.detail(.downloading(version: "0.4.0", fraction: 0.5, userInitiated: true)), "50%")
    }

    func testItemHiddenUntilVisibleStateAndFollowsModel() {
        let model = UpdateModel()
        let item = UpdateBadgeItem(model: model)
        XCTAssertTrue(item.isHidden)
        model.send(.readyToInstall(version: "0.4.0", notesURL: nil))
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.view?.accessibilityIdentifier(), AXID.updateBadge)
    }

    func testBadgeStaysAfterCancelledRestart() {
        let model = UpdateModel()
        var restarts = 0
        model.restartHandler = { restarts += 1 }   // the real handler runs the quit path; Cancel leaves state alone
        let item = UpdateBadgeItem(model: model)
        model.send(.readyToInstall(version: "0.4.0", notesURL: nil))
        model.restartNow()
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(item.isHidden)
    }

    func testToolbarHasTheUpdateItem() async throws {
        let h = try await ShellHarness.make(self)
        let window = try XCTUnwrap(h.context.windows.windows.first?.window)
        let ids = window.toolbar?.items.map(\.itemIdentifier) ?? []
        XCTAssertTrue(ids.contains(ToolbarController.updateID))
    }
}
```

(Adjust `testToolbarHasTheUpdateItem` to how `ToolbarTests` opens a window with `ShellHarness`; copy its setup lines.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter UITests.UpdateBadgeTests 2>&1 | tail -5` → compile errors.

- [ ] **Step 3: Implement**

`Sources/UI/Updates/UpdateBadge.swift`:

```swift
import AppKit
import SwiftUI
import Core

@MainActor enum UpdateBadgeText {
    static func pill(_ s: UpdateState) -> String? {
        switch s {
        case .idle: nil
        case .checking: L10n.string("Checking…")
        case .downloading: L10n.string("Downloading Update…")
        case .readyToRestart: L10n.string("Restart to Update")
        case .upToDate: L10n.string("Up to Date")
        case .failed: L10n.string("Update Problem")
        }
    }

    static func headline(_ s: UpdateState) -> String {
        switch s {
        case .idle: ""
        case .checking: L10n.string("Checking for updates…")
        case .downloading(let v, _, _): String(format: L10n.string("Downloading MacExplorer %@…"), v)
        case .readyToRestart(let v, _): String(format: L10n.string("MacExplorer %@ is ready"), v)
        case .upToDate(let v): String(format: L10n.string("You're up to date (%@)"), v)
        case .failed(let e, _):
            switch e {
            case .verificationFailed: L10n.string("This update couldn't be verified and wasn't installed.")
            case .notInApplications: L10n.string("Move MacExplorer to the Applications folder to get updates.")
            case .offline: L10n.string("Couldn't check for updates. You're offline.")
            case .network(let m), .other(let m): String(format: L10n.string("Couldn't check for updates: %@"), m)
            }
        }
    }

    static func detail(_ s: UpdateState) -> String? {
        guard case .downloading(_, let f?, _) = s else { return nil }
        return "\(Int((f * 100).rounded()))%"
    }
}

/// The pill and its popover (spec §3.1–3.2).
struct UpdateBadgeView: View {
    @Bindable var model: UpdateModel
    @State private var showPopover = false

    var body: some View {
        Button { showPopover = true } label: {
            Text(UpdateBadgeText.pill(model.state) ?? "")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(isReady ? 1 : 0.18)))
                .foregroundStyle(isReady ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) { popover }
        .onChange(of: model.popoverRequest) { showPopover = true }
        .onChange(of: showPopover) { _, shown in if !shown { model.acknowledge() } }
    }

    private var isReady: Bool { if case .readyToRestart = model.state { true } else { false } }

    @ViewBuilder private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(UpdateBadgeText.headline(model.state)).font(.headline).fixedSize(horizontal: false, vertical: true)
            if case .downloading(_, let f, _) = model.state {
                if let f { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
            }
            if case .readyToRestart(_, let notes) = model.state {
                if let notes { Link(L10n.string("What's New"), destination: notes) }
                HStack {
                    Spacer()
                    Button(L10n.string("Later")) { showPopover = false }
                    Button(L10n.string("Restart Now")) { showPopover = false; model.restartNow() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// Toolbar item at the trailing edge; hidden while nothing is worth showing.
@MainActor final class UpdateBadgeItem: NSToolbarItem {
    private let model: UpdateModel
    private var observation: UpdateObservation?

    init(model: UpdateModel) {
        self.model = model
        super.init(itemIdentifier: ToolbarController.updateID)
        let host = NSHostingView(rootView: UpdateBadgeView(model: model))
        host.setAccessibilityIdentifier(AXID.updateBadge)
        view = host
        label = L10n.string("Update")
        visibilityPriority = .high
        isHidden = !model.state.isBadgeVisible
        observation = model.addObserver { [weak self] state in self?.isHidden = !state.isBadgeVisible }
    }
}
```

`AXID.swift`: add `static let updateBadge = "macx.updateBadge"`.

`ToolbarController.swift`:
- add `static let updateID = NSToolbarItem.Identifier("macx.toolbar.update")` and a stored `let updateItem: UpdateBadgeItem` initialized in `init` as `UpdateBadgeItem(model: context.updates)` (before `super.init()`);
- `toolbarDefaultItemIdentifiers` returns `[Self.navigationID, Self.addressID, Self.searchID, Self.viewSwitcherID, Self.updateID]`;
- in `itemForItemIdentifier` add `case Self.updateID: updateItem`;
- in `paletteItem(for:)` add `case updateID: spec = (L10n.string("Update"), "arrow.down.circle")`.

Strings:

```bash
scripts/l10n-add.sh "Checking…" "Downloading Update…" "Restart to Update" "Up to Date" "Update Problem" \
  "Checking for updates…" "Downloading MacExplorer %@…" "MacExplorer %@ is ready" "You're up to date (%@)" \
  "This update couldn't be verified and wasn't installed." "Move MacExplorer to the Applications folder to get updates." \
  "Couldn't check for updates. You're offline." "Couldn't check for updates: %@" "What's New" "Later" "Restart Now" "Update"
```

(Skip any key the catalog already has — `jq` simply overwrites with the same value, which is harmless.)

- [ ] **Step 4: Run tests** — `swift test --filter UITests.UpdateBadgeTests && swift test --filter UITests.Toolbar && swift test --filter UITests.LocalizationCoverage` (each `2>&1 | tail -5`) → pass; update `ToolbarTests` expected identifier lists for the new item.

- [ ] **Step 5: Manual check** — `scripts/bundle.sh debug && open .build/MacExplorer.app`: no badge visible (debug build → no controller). Confirms the hidden default.

- [ ] **Step 6: Commit**

```bash
scripts/check-layering.sh
git add Sources/UI/Updates/UpdateBadge.swift Sources/UI/Toolbar/ToolbarController.swift Sources/UI/Support/AXID.swift Sources/UI/Resources/Localizable.xcstrings Tests/UITests
git commit -m "feat(updates): VS Code-style Restart to Update toolbar badge and popover"
```

---

### Task 9: Settings — Updates group and crash toggle

**Files:**
- Modify: `Sources/UI/Settings/GeneralSettingsView.swift`, `Sources/UI/Settings/AdvancedSettingsView.swift`, `Sources/UI/Settings/SettingsView.swift`, `Sources/UI/Settings/SettingsWindowController.swift`, `Sources/UI/Settings/SettingsChoices.swift`
- Test: `Tests/UITests/UpdateSettingsTests.swift`

**Interfaces:**
- Consumes: `UpdateModel`, `Settings.updateChannel`, `Settings.checkForUpdatesAutomatically`, `Settings.offerToReportCrashes`, `EnvironmentSummary.isBetaBuild` logic (`installedVersion.contains("-beta")`).
- Produces:
  - `SettingsChoices.selectChannel(_: UpdateChannel, in: Settings, updates: UpdateModel)`
  - `SettingsChoices.title(for: UpdateChannel) -> String`
  - `SettingsChoices.showsBetaToReleaseNote(settings: Settings, installedVersion: String) -> Bool`
  - `SettingsView(settings:panels:updates:initialSection:)`

- [ ] **Step 1: Write the failing tests**

`Tests/UITests/UpdateSettingsTests.swift`:

```swift
import XCTest
@testable import UI
@testable import Core

@MainActor
final class UpdateSettingsTests: XCTestCase {
    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
    }

    func testSwitchingToBetaTriggersABackgroundCheck() {
        let s = settings(), model = UpdateModel()
        var checks: [Bool] = []
        model.checkHandler = { checks.append($0) }
        SettingsChoices.selectChannel(.beta, in: s, updates: model)
        XCTAssertEqual(s.updateChannel, .beta)
        XCTAssertEqual(checks, [false])
        XCTAssertEqual(model.popoverRequest, 0)
        SettingsChoices.selectChannel(.release, in: s, updates: model)
        XCTAssertEqual(s.updateChannel, .release)
        XCTAssertEqual(checks, [false], "Beta → Release never checks (no downgrade)")
    }

    func testBetaNoteShownOnlyWhenRunningABetaOnRelease() {
        let s = settings()
        XCTAssertFalse(SettingsChoices.showsBetaToReleaseNote(settings: s, installedVersion: "0.4.0"))
        XCTAssertTrue(SettingsChoices.showsBetaToReleaseNote(settings: s, installedVersion: "0.4.0-beta.2"))
        s.updateChannel = .beta
        XCTAssertFalse(SettingsChoices.showsBetaToReleaseNote(settings: s, installedVersion: "0.4.0-beta.2"))
    }

    func testChannelTitles() {
        XCTAssertEqual(SettingsChoices.title(for: UpdateChannel.release), "Release")
        XCTAssertEqual(SettingsChoices.title(for: UpdateChannel.beta), "Beta")
    }

    func testSettingsWindowStillOpens() async throws {
        let h = try await ShellHarness.make(self)
        let controller = SettingsWindowController.show(context: h.context)
        XCTAssertNotNil(controller.window)
        controller.close()
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter UITests.UpdateSettingsTests 2>&1 | tail -5`.

- [ ] **Step 3: Implement**

`SettingsChoices.swift` — add:

```swift
    static func title(for channel: UpdateChannel) -> String {
        switch channel {
        case .release: L10n.string("Release")
        case .beta: L10n.string("Beta")
        }
    }

    /// Release → Beta checks right away (in the background); Beta → Release never downgrades, so it doesn't.
    static func selectChannel(_ channel: UpdateChannel, in settings: Core.Settings, updates: UpdateModel) {
        let old = settings.updateChannel
        settings.updateChannel = channel
        if old == .release, channel == .beta { updates.checkNow(userInitiated: false) }
    }

    static func showsBetaToReleaseNote(settings: Core.Settings, installedVersion: String) -> Bool {
        settings.updateChannel == .release && installedVersion.contains("-beta")
    }
```

`GeneralSettingsView.swift` — add `let updates: UpdateModel` property and, after the Terminal `LabeledContent`, a section:

```swift
            Section(L10n.string("Updates")) {
                Picker(L10n.string("Channel:"), selection: Binding(
                    get: { settings.updateChannel },
                    set: { SettingsChoices.selectChannel($0, in: settings, updates: updates) })) {
                    ForEach(UpdateChannel.allCases, id: \.self) { Text(SettingsChoices.title(for: $0)).tag($0) }
                }
                if SettingsChoices.showsBetaToReleaseNote(settings: settings, installedVersion: updates.installedVersion) {
                    Text(L10n.string("You'll move to the next release that's newer than this beta."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L10n.string("Check for updates automatically"), isOn: Binding(
                    get: { settings.checkForUpdatesAutomatically },
                    set: { updates.isAvailable ? updates.setAutomaticChecks($0) : (settings.checkForUpdatesAutomatically = $0) }))
                Button(L10n.string("Check Now")) { updates.checkNow() }
                    .disabled(!updates.isAvailable)
            }
```

`AdvancedSettingsView.swift` — add after the full-path toggle:

```swift
            Toggle(L10n.string("Offer to report crashes"), isOn: $settings.offerToReportCrashes)
```

`SettingsView.swift` — add `let updates: UpdateModel` stored property and init parameter `updates: UpdateModel` (after `panels`); pass `updates: updates` to `GeneralSettingsView`. `SettingsWindowController.swift` — construct with `updates: context.updates`. Fix any other `SettingsView(` / `GeneralSettingsView(` call sites (`grep -rn "SettingsView(" Sources Tests`).

Strings: `scripts/l10n-add.sh "Release" "Beta" "Updates" "Channel:" "You'll move to the next release that's newer than this beta." "Check for updates automatically" "Check Now" "Offer to report crashes"`.

- [ ] **Step 4: Run tests** — `swift test --filter UITests.UpdateSettingsTests && swift test --filter UITests.SettingsWindow && swift test --filter UITests.LocalizationCoverage` → pass.

- [ ] **Step 5: Commit**

```bash
scripts/check-layering.sh
git add Sources/UI/Settings Sources/UI/Resources/Localizable.xcstrings Tests/UITests/UpdateSettingsTests.swift
git commit -m "feat(settings): update channel, automatic checks, Check Now and crash-report toggle"
```

---

### Task 10: Feedback commands (Help menu and toolbar)

**Files:**
- Create: `Sources/UI/Feedback/FeedbackActions.swift`
- Modify: `Sources/UI/Menus/MainMenuBuilder.swift`, `Sources/UI/Toolbar/ToolbarController.swift`, `Sources/UI/Support/AXID.swift`, `Sources/App/AppDelegate.swift`
- Test: `Tests/UITests/FeedbackTests.swift`

**Interfaces:**
- Consumes: `IssueURLBuilder`, `EnvironmentSummary` (Task 2), `ExternalOpeners.opener(for:)`, `RecordingURLOpener`.
- Produces:
  - `@MainActor public enum FeedbackActions { static func open(_ kind: IssueKind, context: UIContext, opener: (any ExternalURLOpening)? = nil); static func environment(context: UIContext) -> EnvironmentSummary }`
  - Selectors `macx_reportBug:` and `macx_requestFeature:` (AppDelegate)
  - `ToolbarController.feedbackID = NSToolbarItem.Identifier("macx.toolbar.feedback")` (an `NSMenuToolbarItem`, placed before `updateID`)
  - `AXID.feedbackMenu = "macx.feedback"`

- [ ] **Step 1: Write the failing tests**

`Tests/UITests/FeedbackTests.swift`:

```swift
import XCTest
import AppKit
@testable import UI
@testable import Core

@MainActor
final class FeedbackTests: XCTestCase {
    func testReportBugOpensPrefilledForm() async throws {
        let h = try await ShellHarness.make(self)
        let opener = RecordingURLOpener()
        FeedbackActions.open(.bug, context: h.context, opener: opener)
        let url = try XCTUnwrap(opener.opened.first)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/roniburd/macExplorer/issues/new?template=bug.yml"))
        XCTAssertTrue(url.absoluteString.contains("channel=release"))
    }

    func testRequestFeatureOpensFeatureForm() async throws {
        let h = try await ShellHarness.make(self)
        let opener = RecordingURLOpener()
        FeedbackActions.open(.feature, context: h.context, opener: opener)
        XCTAssertTrue(opener.opened.first?.absoluteString.contains("template=feature.yml") ?? false)
    }

    func testHelpMenuHasFeedbackItems() {
        let menu = MainMenuBuilder.build()
        let help = menu.items.first { $0.identifier?.rawValue == "macx.menu.help" }?.submenu
        let actions = help?.items.compactMap(\.action).map(NSStringFromSelector) ?? []
        XCTAssertTrue(actions.contains("macx_reportBug:"))
        XCTAssertTrue(actions.contains("macx_requestFeature:"))
    }

    func testToolbarHasFeedbackMenuBeforeUpdateBadge() async throws {
        let h = try await ShellHarness.make(self)
        let window = try XCTUnwrap(h.context.windows.windows.first?.window)
        let ids = window.toolbar?.items.map(\.itemIdentifier) ?? []
        let f = try XCTUnwrap(ids.firstIndex(of: ToolbarController.feedbackID))
        let u = try XCTUnwrap(ids.firstIndex(of: ToolbarController.updateID))
        XCTAssertLessThan(f, u)
    }
}
```

(`RecordingURLOpener` currently has only a `shared` instance with a private init? It has an implicit internal init — fine. If `ShellHarness` opens no window by default, copy `ToolbarTests`' window setup.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter UITests.FeedbackTests 2>&1 | tail -5`.

- [ ] **Step 3: Implement**

`Sources/UI/Feedback/FeedbackActions.swift`:

```swift
import AppKit
import Core

/// Help › Report a Bug… / Request a Feature… and the toolbar Send Feedback menu (spec §4.1): open the GitHub issue
/// form in the browser, prefilled. Sandbox runs record the URL instead (ExternalOpeners).
@MainActor public enum FeedbackActions {
    public static func open(_ kind: IssueKind, context: UIContext, opener: (any ExternalURLOpening)? = nil) {
        let url = IssueURLBuilder.url(kind: kind, environment: environment(context: context))
        (opener ?? ExternalOpeners.opener(for: context.options)).open(url)
    }

    static func environment(context: UIContext) -> EnvironmentSummary {
        EnvironmentSummary.current(channel: context.environment.settings.updateChannel)
    }

    /// The toolbar's Send Feedback menu (nil-targeted actions, handled by the app delegate).
    static func menu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("Send Feedback"))
        menu.addItem(NSMenuItem(title: L10n.string("Report a Bug…"), action: NSSelectorFromString("macx_reportBug:"), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.string("Request a Feature…"), action: NSSelectorFromString("macx_requestFeature:"), keyEquivalent: ""))
        return menu
    }
}
```

Make `ExternalURLOpening` `public`? Not needed — tests use `@testable import UI`; keep `open(_:context:opener:)` `public` only if the App target calls it with the default opener (it does; the parameter type must then be public too). Simplest: make the function `public` and the `opener` parameter internal by splitting:

```swift
    public static func open(_ kind: IssueKind, context: UIContext) { open(kind, context: context, opener: nil) }
    static func open(_ kind: IssueKind, context: UIContext, opener: (any ExternalURLOpening)?) { /* body above */ }
```

`MainMenuBuilder.helpItems()`:

```swift
    private static func helpItems() -> [NSMenuItem] {
        [
            standard("MacExplorer Help", #selector(NSApplication.showHelp(_:)), "?"),
            .separator(),
            standard("Report a Bug…", NSSelectorFromString("macx_reportBug:")),
            standard("Request a Feature…", NSSelectorFromString("macx_requestFeature:")),
        ]
    }
```

`AppDelegate.swift`:

```swift
    @objc func macx_reportBug(_ sender: Any?) { if let context { FeedbackActions.open(.bug, context: context) } }
    @objc func macx_requestFeature(_ sender: Any?) { if let context { FeedbackActions.open(.feature, context: context) } }
```

`ToolbarController.swift`:
- `static let feedbackID = NSToolbarItem.Identifier("macx.toolbar.feedback")`; stored `let feedbackItem: NSMenuToolbarItem` built in `init`:

```swift
        feedbackItem = NSMenuToolbarItem(itemIdentifier: Self.feedbackID)
        feedbackItem.menu = FeedbackActions.menu()
        feedbackItem.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: L10n.string("Send Feedback"))
        feedbackItem.label = L10n.string("Send Feedback")
        feedbackItem.toolTip = L10n.string("Send Feedback")
        feedbackItem.showsIndicator = false
```

  (set `feedbackItem` before `super.init()`, the property tweaks after; set its accessibility identifier `AXID.feedbackMenu` after `super.init()` via `feedbackItem.view?.setAccessibilityIdentifier` if a view exists, else skip — `NSMenuToolbarItem` has no custom view; in that case set `feedbackItem.menu.identifier`.)
- default identifiers: `[navigationID, addressID, searchID, viewSwitcherID, feedbackID, updateID]`;
- `itemForItemIdentifier`: `case Self.feedbackID: feedbackItem`;
- `paletteItem`: `case feedbackID: spec = (L10n.string("Send Feedback"), "bubble.left")`.

`AXID.swift`: `static let feedbackMenu = "macx.feedback"`.

Strings: `scripts/l10n-add.sh "Send Feedback" "Report a Bug…" "Request a Feature…"`.

- [ ] **Step 4: Run tests** — `swift test --filter UITests.FeedbackTests && swift test --filter UITests.Toolbar && swift test --filter UITests.MenuValidation && swift test --filter UITests.LocalizationCoverage` → pass; update fixed identifier lists in existing tests.

- [ ] **Step 5: Commit**

```bash
scripts/check-layering.sh
git add Sources/UI/Feedback Sources/UI/Menus/MainMenuBuilder.swift Sources/UI/Toolbar/ToolbarController.swift Sources/UI/Support/AXID.swift Sources/App/AppDelegate.swift Sources/UI/Resources/Localizable.xcstrings Tests/UITests
git commit -m "feat(feedback): Report a Bug / Request a Feature open prefilled GitHub issue forms"
```

---

### Task 11: Crash report flow and launch wiring

**Files:**
- Create: `Sources/UI/Feedback/CrashReportFlow.swift`, `Sources/UI/Feedback/CrashReportPrompt.swift`
- Modify: `Sources/App/AppBootstrap.swift`, `Sources/App/AppDelegate.swift`
- Test: `Tests/UITests/CrashReportFlowTests.swift`

**Interfaces:**
- Consumes: `DirtyExitMarker`, `PreviousSession`, `SessionMarker`, `StatePaths.sessionMarker`, `StatePaths.diagnosticReports(sandboxed:)` (Task 3); `CrashReportLocator`, `CrashExcerpt` (Task 4); `IssueURLBuilder`, `EnvironmentSummary` (Task 2); `Settings.offerToReportCrashes`, `markCrashReported` (Task 1).
- Produces:
  - `enum CrashChoice: Equatable { case report, showReport, dontSend }`; `struct CrashAnswer: Equatable { var choice: CrashChoice; var dontAskAgain: Bool }`
  - `@MainActor protocol CrashPrompting { func ask(title: String, on window: NSWindow?) async -> CrashAnswer }`; `AlertCrashPrompt: CrashPrompting`
  - `@MainActor final class CrashReportFlow { init(settings:, previous: PreviousSession, locator: CrashReportLocator, home: String, environment: EnvironmentSummary, prompt: any CrashPrompting, opener: any ExternalURLOpening, copyText: @escaping @MainActor (String) -> Void, reveal: @escaping @MainActor (URL) -> Void); func run(on window: NSWindow?) async -> CrashAnswer? }`
  - `public enum CrashReporting { static func start(context: UIContext, previous: PreviousSession) }` (live wiring used by AppBootstrap)

- [ ] **Step 1: Write the failing tests**

`Tests/UITests/CrashReportFlowTests.swift` (re-use the Core fixture by copying `IPSFixture.swift` into `Tests/UITests/Support/IPSFixture.swift` — test targets can't share files):

```swift
import XCTest
import AppKit
import MacxFixtures
@testable import UI
@testable import Core

@MainActor
private final class ScriptedCrashPrompt: CrashPrompting {
    var answer: CrashAnswer
    private(set) var titles: [String] = []
    init(_ answer: CrashAnswer) { self.answer = answer }
    func ask(title: String, on window: NSWindow?) async -> CrashAnswer { titles.append(title); return answer }
}

@MainActor
final class CrashReportFlowTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private let env = EnvironmentSummary(appVersion: "0.4.0", build: "812", channel: "release", macOS: "26.1", hardwareModel: "Mac16,10", architecture: "arm64")
    private let launched = Date(timeIntervalSince1970: 1_793_815_000)   // before the fixture's 10:11:12 -0800

    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: sandbox.root)
    }

    private func flow(_ s: Core.Settings, previous: PreviousSession, prompt: ScriptedCrashPrompt,
                      opener: RecordingURLOpener, copied: @escaping (String) -> Void = { _ in },
                      revealed: @escaping (URL) -> Void = { _ in }) throws -> CrashReportFlow {
        let dir = try sandbox.createDirectory("DiagnosticReports")
        _ = try sandbox.createFile("DiagnosticReports/macExplorer-2026-11-04-101112.ips",
                                   contents: Data(IPSFixture.make(home: "/Users/tester").utf8))
        return CrashReportFlow(settings: s, previous: previous,
                               locator: CrashReportLocator(directory: dir, bundleID: "com.macexplorer.app"),
                               home: "/Users/tester", environment: env, prompt: prompt, opener: opener,
                               copyText: copied, reveal: revealed)
    }

    private var dirty: PreviousSession { .dirty(SessionMarker(pid: 1, version: "0.4.0", build: "812", launchedAt: launched)) }

    func testCleanExitNeverAsks() async throws {
        let prompt = ScriptedCrashPrompt(CrashAnswer(choice: .report, dontAskAgain: false)), opener = RecordingURLOpener()
        let answer = try await flow(settings(), previous: .clean, prompt: prompt, opener: opener).run(on: nil)
        XCTAssertNil(answer)
        XCTAssertEqual(prompt.titles, [])
    }

    func testReportOpensIssueWithExcerptAndCopiesFullRedactedReport() async throws {
        let s = settings(), prompt = ScriptedCrashPrompt(CrashAnswer(choice: .report, dontAskAgain: false))
        let opener = RecordingURLOpener()
        var copied = ""
        let answer = try await flow(s, previous: dirty, prompt: prompt, opener: opener, copied: { copied = $0 }).run(on: nil)
        XCTAssertEqual(answer?.choice, .report)
        let url = try XCTUnwrap(opener.opened.first).absoluteString
        XCTAssertTrue(url.contains("template=bug.yml"))
        XCTAssertTrue(url.contains("crash-log="))
        XCTAssertFalse(url.contains("tester"))
        XCTAssertTrue(copied.contains("EXC_BAD_ACCESS"))
        XCTAssertFalse(copied.contains("/Users/tester"))
        XCTAssertEqual(s.lastReportedCrashes, ["macExplorer-2026-11-04-101112.ips"])
    }

    func testSameCrashNeverPromptsTwice() async throws {
        let s = settings(), prompt = ScriptedCrashPrompt(CrashAnswer(choice: .dontSend, dontAskAgain: false))
        let f = try flow(s, previous: dirty, prompt: prompt, opener: RecordingURLOpener())
        _ = await f.run(on: nil)
        _ = await f.run(on: nil)
        XCTAssertEqual(prompt.titles.count, 1)
    }

    func testDontAskAgainTurnsTheSettingOff() async throws {
        let s = settings(), prompt = ScriptedCrashPrompt(CrashAnswer(choice: .dontSend, dontAskAgain: true))
        _ = try await flow(s, previous: dirty, prompt: prompt, opener: RecordingURLOpener()).run(on: nil)
        XCTAssertFalse(s.offerToReportCrashes)
    }

    func testSettingOffNeverAsks() async throws {
        let s = settings()
        s.offerToReportCrashes = false
        let prompt = ScriptedCrashPrompt(CrashAnswer(choice: .report, dontAskAgain: false))
        XCTAssertNil(try await flow(s, previous: dirty, prompt: prompt, opener: RecordingURLOpener()).run(on: nil))
    }

    func testShowReportReveals() async throws {
        var revealed: URL?
        let prompt = ScriptedCrashPrompt(CrashAnswer(choice: .showReport, dontAskAgain: false))
        _ = try await flow(settings(), previous: dirty, prompt: prompt, opener: RecordingURLOpener(), revealed: { revealed = $0 }).run(on: nil)
        XCTAssertEqual(revealed?.lastPathComponent, "macExplorer-2026-11-04-101112.ips")
    }

    func testDirtyUnknownStillFindsUnreportedCrash() async throws {
        let prompt = ScriptedCrashPrompt(CrashAnswer(choice: .dontSend, dontAskAgain: false))
        _ = try await flow(settings(), previous: .dirtyUnknown, prompt: prompt, opener: RecordingURLOpener()).run(on: nil)
        XCTAssertEqual(prompt.titles.count, 1)
    }
}
```


- [ ] **Step 2: Run to verify failure** — `swift test --filter UITests.CrashReportFlowTests 2>&1 | tail -5`.

- [ ] **Step 3: Implement**

`Sources/UI/Feedback/CrashReportPrompt.swift`:

```swift
import AppKit

enum CrashChoice: Equatable { case report, showReport, dontSend }
struct CrashAnswer: Equatable { var choice: CrashChoice; var dontAskAgain: Bool }

@MainActor protocol CrashPrompting: AnyObject {
    func ask(title: String, on window: NSWindow?) async -> CrashAnswer
}

/// The next-launch sheet (spec §4.2). Waits until the window has no other sheet (onboarding, recovery notice).
@MainActor final class AlertCrashPrompt: CrashPrompting {
    func ask(title: String, on window: NSWindow?) async -> CrashAnswer {
        while let window, window.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(250)) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("MacExplorer quit unexpectedly last time")
        alert.informativeText = L10n.string("Help fix it by reporting the crash. You'll see the report on GitHub before anything is sent.")
            + "\n\n" + title
        alert.addButton(withTitle: L10n.string("Report on GitHub…"))
        alert.addButton(withTitle: L10n.string("Show Report"))
        alert.addButton(withTitle: L10n.string("Don't Send"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.string("Don't ask again")
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        } else {
            response = alert.runModal()
        }
        let choice: CrashChoice = switch response {
        case .alertFirstButtonReturn: .report
        case .alertSecondButtonReturn: .showReport
        default: .dontSend
        }
        return CrashAnswer(choice: choice, dontAskAgain: alert.suppressionButton?.state == .on)
    }
}
```

`Sources/UI/Feedback/CrashReportFlow.swift`:

```swift
import AppKit
import Core

/// Next-launch crash reporting (spec §4.2): only after a dirty exit, only for a crash report we haven't offered,
/// only when the user hasn't turned it off. The search runs off the main actor.
@MainActor final class CrashReportFlow {
    private let settings: Core.Settings
    private let previous: PreviousSession
    private let locator: CrashReportLocator
    private let home: String
    private let environment: EnvironmentSummary
    private let prompt: any CrashPrompting
    private let opener: any ExternalURLOpening
    private let copyText: @MainActor (String) -> Void
    private let reveal: @MainActor (URL) -> Void

    init(settings: Core.Settings, previous: PreviousSession, locator: CrashReportLocator, home: String,
         environment: EnvironmentSummary, prompt: any CrashPrompting, opener: any ExternalURLOpening,
         copyText: @escaping @MainActor (String) -> Void, reveal: @escaping @MainActor (URL) -> Void) {
        self.settings = settings
        self.previous = previous
        self.locator = locator
        self.home = home
        self.environment = environment
        self.prompt = prompt
        self.opener = opener
        self.copyText = copyText
        self.reveal = reveal
    }

    /// nil when nothing was asked.
    @discardableResult
    func run(on window: NSWindow?) async -> CrashAnswer? {
        guard settings.offerToReportCrashes else { return nil }
        let after: Date?
        switch previous {
        case .clean: return nil
        case .dirty(let marker): after = marker.launchedAt
        case .dirtyUnknown: after = nil
        }
        let locator = self.locator, reported = Set(settings.lastReportedCrashes), home = self.home
        let found = await Task.detached(priority: .utility) { () -> (CrashReport, CrashExcerpt, String)? in
            guard let report = locator.newest(after: after, excluding: reported),
                  let data = try? Data(contentsOf: report.fileURL),
                  let text = String(data: data, encoding: .utf8),
                  let excerpt = CrashExcerpt.parse(text, home: home) else { return nil }
            return (report, excerpt, CrashExcerpt.redact(text, home: home))
        }.value
        guard let (report, excerpt, fullRedacted) = found else {
            NSLog("MacExplorer: previous session ended without a clean quit; no crash report found")
            return nil
        }
        settings.markCrashReported(report.fileName)
        let answer = await prompt.ask(title: excerpt.title, on: window)
        if answer.dontAskAgain { settings.offerToReportCrashes = false }
        switch answer.choice {
        case .report:
            copyText(fullRedacted)
            opener.open(IssueURLBuilder.url(kind: .bug, environment: environment, title: excerpt.title, crashExcerpt: excerpt.text))
        case .showReport:
            reveal(report.fileURL)
        case .dontSend:
            break
        }
        return answer
    }
}

/// Live wiring (AppBootstrap): the previous session's marker was read before this launch's marker was written.
@MainActor public enum CrashReporting {
    public static func start(context: UIContext, previous: PreviousSession, statePaths: StatePaths) {
        let options = context.options
        let pasteboard = options.pasteboardName.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
        let flow = CrashReportFlow(
            settings: context.environment.settings, previous: previous,
            locator: CrashReportLocator(directory: statePaths.diagnosticReports(sandboxed: options.isSandboxed),
                                        bundleID: Bundle.main.bundleIdentifier ?? "com.macexplorer.app"),
            home: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
            environment: EnvironmentSummary.current(channel: context.environment.settings.updateChannel),
            prompt: AlertCrashPrompt(), opener: ExternalOpeners.opener(for: options),
            copyText: { text in pasteboard.clearContents(); pasteboard.setString(text, forType: .string) },
            reveal: { url in
                if options.isSandboxed { RecordingURLOpener.shared.open(url) }
                else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            })
        Task { @MainActor in await flow.run(on: context.windows.windows.first?.window) }
    }
}
```

Note: `home` above uses the real home (the `.ips` paths contain it); `NSPasteboard.general` appears only in `Sources/UI`, which layering rule 5 allows (it scans Tests and harnesses).

`AppBootstrap.launch` — at the very start:

```swift
        let marker = DirtyExitMarker(fileURL: statePaths.sessionMarker)
        let previous = marker.previous()
        let info = Bundle.main.infoDictionary ?? [:]
        try? marker.begin(SessionMarker(pid: ProcessInfo.processInfo.processIdentifier,
                                        version: info["CFBundleShortVersionString"] as? String ?? "unknown",
                                        build: info["CFBundleVersion"] as? String ?? "unknown", launchedAt: Date()))
```

and after `lifecycle.didLaunch(recovery:)`: `if options.scenario == nil { CrashReporting.start(context: context, previous: previous, statePaths: statePaths) }`. Return `marker` too (`launch` now returns `(context, lifecycle, updates, marker)`); `AppDelegate` stores it as `private var sessionMarker: DirtyExitMarker?` and calls `sessionMarker?.end()` at the end of `applicationWillTerminate` and in `scheduleSmokeExit` right after `self.lifecycle?.willTerminate()`.

Strings: `scripts/l10n-add.sh "MacExplorer quit unexpectedly last time" "Help fix it by reporting the crash. You'll see the report on GitHub before anything is sent." "Report on GitHub…" "Show Report" "Don't Send" "Don't ask again"`.

- [ ] **Step 4: Run tests** — `swift test --filter UITests.CrashReportFlowTests && swift test --filter UITests.AppLifecycle && swift test --filter UITests.LocalizationCoverage` → pass. Then full `swift test 2>&1 | tail -3` and `scripts/run-scenarios.sh release` (crash-recovery scenarios must still pass: they kill the app, so their next launch must not hang on a prompt — scenarios pass `--scenario`, which skips `CrashReporting.start`).

- [ ] **Step 5: Manual check (real crash)**

```bash
scripts/bundle.sh release --output "$PWD/.build/crash-check/MacExplorer.app"
open .build/crash-check/MacExplorer.app; sleep 3; pkill -SEGV -x macExplorer; sleep 5
open .build/crash-check/MacExplorer.app
```

Expected: macOS writes `~/Library/Logs/DiagnosticReports/macExplorer-*.ips`; on relaunch the sheet appears once; "Report on GitHub…" opens the browser with the prefilled form (don't submit). Relaunch again: no sheet. `rm -rf .build/crash-check`. (This uses the real home and the release bundle ID by design; it only creates the crash report macOS writes for our own process.)

- [ ] **Step 6: Commit**

```bash
scripts/check-layering.sh
git add Sources/UI/Feedback Sources/App Sources/UI/Resources/Localizable.xcstrings Tests/UITests
git commit -m "feat(feedback): offer to report the previous session's crash on next launch"
```

---

### Task 12: Release scripts — appcast and cask

**Files:**
- Create: `scripts/release/appcast.py`, `scripts/release/render-cask.sh`, `scripts/release/test-release-scripts.sh`

**Interfaces:**
- Produces:
  - `python3 -I scripts/release/appcast.py --appcast PATH --version V --build N --url URL --length BYTES --ed-signature SIG --min-os 26.0 --notes-url URL [--channel beta]` → inserts (or replaces same `build`) one `<item>` at the top of the channel's items, creating the file if missing. Exit 64 on bad args.
  - `scripts/release/render-cask.sh --token macexplorer|macexplorer@beta --version V --sha256 SHA --url URL` → cask Ruby on stdout.

- [ ] **Step 1: Write the failing test script**

`scripts/release/test-release-scripts.sh`:

```bash
#!/bin/bash
# Tests for appcast.py and render-cask.sh. Writes only inside its own mktemp directory.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/macx-release-test-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

ac="$tmp/appcast.xml"
add() { python3 -I "$here/appcast.py" --appcast "$ac" --url "https://example.invalid/$1.zip" --length 123 \
          --ed-signature "sig$2" --min-os 26.0 --notes-url "https://example.invalid/notes/$1" --version "$1" --build "$2" "${@:3}"; }

add 0.2.0-beta.1 10 --channel beta
add 0.2.0 11
add 0.2.0 11                                  # same build again: replaced, not duplicated
python3 -I - "$ac" <<'PY' || fail "appcast content"
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.parse(sys.argv[1]).getroot().find("channel").findall("item")
assert len(items) == 2, len(items)
newest = items[0]
assert newest.find("sparkle:version", ns).text == "11"
assert newest.find("sparkle:shortVersionString", ns).text == "0.2.0"
assert newest.find("sparkle:channel", ns) is None
beta = items[1]
assert beta.find("sparkle:channel", ns).text == "beta"
enc = beta.find("enclosure")
assert enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature") == "sig10"
assert enc.get("length") == "123" and enc.get("type") == "application/octet-stream"
assert beta.find("sparkle:minimumSystemVersion", ns).text == "26.0"
PY
python3 -I "$here/appcast.py" --appcast "$ac" --version x 2>/dev/null && fail "missing args accepted"

cask="$("$here/render-cask.sh" --token macexplorer@beta --version 0.2.0-beta.1 --sha256 abc123 --url https://example.invalid/a.zip)"
grep -q 'cask "macexplorer@beta" do' <<<"$cask" || fail "cask token"
grep -q 'version "0.2.0-beta.1"' <<<"$cask" || fail "cask version"
grep -q 'sha256 "abc123"' <<<"$cask" || fail "cask sha"
grep -q 'auto_updates true' <<<"$cask" || fail "auto_updates"
grep -q 'conflicts_with cask: "macexplorer"' <<<"$cask" || fail "conflicts"
grep -q 'app "MacExplorer.app"' <<<"$cask" || fail "app stanza"
"$here/render-cask.sh" --token other --version 1 --sha256 a --url u >/dev/null 2>&1 && fail "bad token accepted"
echo "release scripts: OK"
```

`chmod +x scripts/release/test-release-scripts.sh`. Run it → fails (scripts missing).

- [ ] **Step 2: Implement appcast.py**

`scripts/release/appcast.py`:

```python
#!/usr/bin/env python3
"""Insert one signed Sparkle item into appcast.xml (distribution spec §5 step 5). Stdlib only; run with python3 -I."""
import argparse, os, sys, tempfile
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
S = "{%s}" % SPARKLE


def parse_args(argv):
    p = argparse.ArgumentParser()
    for name in ("appcast", "version", "build", "url", "length", "ed-signature", "min-os", "notes-url"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--channel")
    try:
        return p.parse_args(argv)
    except SystemExit:
        sys.exit(64)


def load(path):
    if os.path.exists(path):
        return ET.parse(path)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "MacExplorer"
    ET.SubElement(channel, "link").text = "https://roniburd.github.io/macExplorer/appcast.xml"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def main(argv):
    a = parse_args(argv)
    tree = load(a.appcast)
    channel = tree.getroot().find("channel")
    for old in channel.findall("item"):
        if old.findtext(S + "version") == a.build:
            channel.remove(old)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = "MacExplorer " + a.version
    ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ET.SubElement(item, S + "version").text = a.build
    ET.SubElement(item, S + "shortVersionString").text = a.version
    ET.SubElement(item, S + "minimumSystemVersion").text = a.min_os
    ET.SubElement(item, S + "releaseNotesLink").text = a.notes_url
    if a.channel:
        ET.SubElement(item, S + "channel").text = a.channel
    ET.SubElement(item, "enclosure", {"url": a.url, "length": a.length, "type": "application/octet-stream",
                                      S + "edSignature": a.ed_signature})
    first = next((i for i, e in enumerate(list(channel)) if e.tag == "item"), len(channel))
    channel.insert(first, item)
    ET.indent(tree, space="  ")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(a.appcast)), suffix=".xml")
    with os.fdopen(fd, "wb") as f:
        tree.write(f, encoding="utf-8", xml_declaration=True)
    os.replace(tmp, a.appcast)


if __name__ == "__main__":
    main(sys.argv[1:])
```

- [ ] **Step 3: Implement render-cask.sh**

`scripts/release/render-cask.sh` (`chmod +x`):

```bash
#!/bin/bash
# Prints a Homebrew cask for MacExplorer (distribution spec §5 step 6).
# Usage: render-cask.sh --token macexplorer|macexplorer@beta --version V --sha256 SHA --url URL
set -euo pipefail
usage() { echo "usage: $0 --token macexplorer|macexplorer@beta --version V --sha256 SHA --url URL" >&2; exit 64; }
token="" version="" sha="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --token) token="${2:-}"; shift ;;
    --version) version="${2:-}"; shift ;;
    --sha256) sha="${2:-}"; shift ;;
    --url) url="${2:-}"; shift ;;
    *) usage ;;
  esac
  shift
done
[ -n "$version" ] && [ -n "$sha" ] && [ -n "$url" ] || usage
case "$token" in
  macexplorer) other="macexplorer@beta"; name="MacExplorer" ;;
  macexplorer@beta) other="macexplorer"; name="MacExplorer (Beta)" ;;
  *) usage ;;
esac
cat <<EOF
cask "$token" do
  version "$version"
  sha256 "$sha"

  url "$url"
  name "$name"
  desc "Windows Explorer-style file manager for macOS"
  homepage "https://github.com/roniburd/macExplorer"

  auto_updates true
  conflicts_with cask: "$other"
  depends_on macos: ">= :tahoe"

  app "MacExplorer.app"

  zap trash: [
    "~/Library/Application Support/macExplorer",
    "~/Library/Preferences/com.macexplorer.app.plist",
    "~/Library/Caches/com.macexplorer.app",
  ]

  caveats <<~EOS
    MacExplorer isn't notarized yet. If macOS says it can't be opened, run once:
      xattr -dr com.apple.quarantine "#{appdir}/MacExplorer.app"
    MacExplorer updates itself; \`brew upgrade --greedy\` also works.
  EOS
end
EOF
```

- [ ] **Step 4: Run** — `scripts/release/test-release-scripts.sh` → `release scripts: OK`. If `brew` is installed: `scripts/release/render-cask.sh --token macexplorer --version 0.2.0 --sha256 $(printf x | shasum -a 256 | cut -d' ' -f1) --url https://example.invalid/a.zip > "$TMPDIR/macexplorer.rb" && brew style "$TMPDIR/macexplorer.rb"; rm "$TMPDIR/macexplorer.rb"` → fix any style offenses in the template.

- [ ] **Step 5: Commit**

```bash
git add scripts/release
git commit -m "build: appcast and Homebrew cask generators for releases"
```

---

### Task 13: Release workflow and CI checks

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `bundle.sh` options (Task 5), `appcast.py`, `render-cask.sh` (Task 12), spike decision (Task 7: `RELEASE_SIGNING`).
- Produces: release on `v*` tags; `workflow_dispatch` with `dry_run` (default `true`).

- [ ] **Step 1: Write release.yml**

`.github/workflows/release.yml` (set the `RELEASE_SIGNING` env default to the spike decision recorded in spec §7):

```yaml
# Tag → signed release, appcast, Homebrew cask (distribution spec §5).
name: Release

on:
  push:
    tags: ["v*"]
  workflow_dispatch:
    inputs:
      dry_run:
        description: Build and render everything, publish nothing
        type: boolean
        default: true
      version:
        description: Version for a dry run (e.g. 0.2.0-beta.1)
        default: 0.0.0-beta.0

permissions:
  contents: write

concurrency:
  group: release
  cancel-in-progress: false

env:
  XCODE_VERSION: "27.2"
  RELEASE_SIGNING: adhoc          # from the spike (spec §7): adhoc | self-signed
  SPARKLE_BIN: .build/artifacts/sparkle/Sparkle/bin

jobs:
  release:
    runs-on: macos-26
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Select Xcode
        run: sudo xcode-select -s "/Applications/Xcode_${XCODE_VERSION}.app"

      - name: Version
        id: v
        run: |
          if [ "${GITHUB_REF_TYPE}" = "tag" ]; then version="${GITHUB_REF_NAME#v}"; dry=false
          else version="${{ inputs.version }}"; dry="${{ inputs.dry_run }}"; fi
          case "$version" in
            [0-9]*.[0-9]*.[0-9]*-beta.[0-9]*) channel=beta; token=macexplorer@beta; prerelease=true ;;
            [0-9]*.[0-9]*.[0-9]*) channel=release; token=macexplorer; prerelease=false ;;
            *) echo "::error::bad version $version"; exit 1 ;;
          esac
          {
            echo "version=$version"; echo "build=$(git rev-list --count HEAD)"; echo "channel=$channel"
            echo "token=$token"; echo "prerelease=$prerelease"; echo "dry=$dry"
          } >> "$GITHUB_OUTPUT"

      - name: Test
        run: swift test --parallel

      - name: Signing identity
        id: sign
        env:
          DEVELOPER_ID_P12: ${{ secrets.DEVELOPER_ID_P12 }}
          DEVELOPER_ID_P12_PASSWORD: ${{ secrets.DEVELOPER_ID_P12_PASSWORD }}
          SELF_SIGNED_P12: ${{ secrets.SELF_SIGNED_P12 }}
          SELF_SIGNED_P12_PASSWORD: ${{ secrets.SELF_SIGNED_P12_PASSWORD }}
          SELF_SIGNED_IDENTITY: ${{ secrets.SELF_SIGNED_IDENTITY }}
        run: |
          keychain="$RUNNER_TEMP/release.keychain-db"
          import_p12() {
            security create-keychain -p ci "$keychain"
            security set-keychain-settings -lut 3600 "$keychain"
            security unlock-keychain -p ci "$keychain"
            echo "$1" | base64 --decode > "$RUNNER_TEMP/cert.p12"
            security import "$RUNNER_TEMP/cert.p12" -k "$keychain" -P "$2" -T /usr/bin/codesign
            security set-key-partition-list -S apple-tool:,apple: -s -k ci "$keychain" >/dev/null
            security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
            rm "$RUNNER_TEMP/cert.p12"
          }
          if [ -n "$DEVELOPER_ID_P12" ]; then
            import_p12 "$DEVELOPER_ID_P12" "$DEVELOPER_ID_P12_PASSWORD"
            identity="$(security find-identity -v -p codesigning "$keychain" | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)"
            echo "identity=$identity" >> "$GITHUB_OUTPUT"; echo "notarize=true" >> "$GITHUB_OUTPUT"
          elif [ "$RELEASE_SIGNING" = "self-signed" ]; then
            [ -n "$SELF_SIGNED_P12" ] || { echo "::error::RELEASE_SIGNING=self-signed but SELF_SIGNED_P12 is not set"; exit 1; }
            import_p12 "$SELF_SIGNED_P12" "$SELF_SIGNED_P12_PASSWORD"
            echo "identity=$SELF_SIGNED_IDENTITY" >> "$GITHUB_OUTPUT"; echo "notarize=false" >> "$GITHUB_OUTPUT"
          else
            echo "identity=-" >> "$GITHUB_OUTPUT"; echo "notarize=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Check Sparkle public key
        run: |
          key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
          if [ "$key" = "REPLACE_WITH_SPARKLE_PUBLIC_KEY" ] && [ "${{ steps.v.outputs.dry }}" != "true" ]; then
            echo "::error::Set SUPublicEDKey in Resources/Info.plist before publishing (README › Releasing)"; exit 1
          fi

      - name: Bundle
        run: |
          scripts/bundle.sh release --universal --version "${{ steps.v.outputs.version }}" --build "${{ steps.v.outputs.build }}" \
            --sign "${{ steps.sign.outputs.identity }}" --output "$PWD/dist/MacExplorer.app"
          codesign --verify --deep --strict dist/MacExplorer.app
          lipo -archs dist/MacExplorer.app/Contents/MacOS/macExplorer | grep -q x86_64
          lipo -archs dist/MacExplorer.app/Contents/MacOS/macExplorer | grep -q arm64

      - name: Notarize
        if: steps.sign.outputs.notarize == 'true'
        env:
          NOTARY_API_KEY: ${{ secrets.NOTARY_API_KEY }}
          NOTARY_API_KEY_ID: ${{ secrets.NOTARY_API_KEY_ID }}
          NOTARY_API_ISSUER: ${{ secrets.NOTARY_API_ISSUER }}
        run: |
          echo "$NOTARY_API_KEY" | base64 --decode > "$RUNNER_TEMP/notary.p8"
          ditto -c -k --keepParent dist/MacExplorer.app "$RUNNER_TEMP/notarize.zip"
          xcrun notarytool submit "$RUNNER_TEMP/notarize.zip" --key "$RUNNER_TEMP/notary.p8" \
            --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER" --wait
          xcrun stapler staple dist/MacExplorer.app
          rm "$RUNNER_TEMP/notary.p8"

      - name: Package
        id: pkg
        run: |
          v="${{ steps.v.outputs.version }}"
          zip="dist/MacExplorer-$v.zip"; dmg="dist/MacExplorer-$v.dmg"
          ditto -c -k --keepParent dist/MacExplorer.app "$zip"
          mkdir -p dist/dmg && cp -R dist/MacExplorer.app dist/dmg/ && ln -s /Applications dist/dmg/Applications
          hdiutil create -volname "MacExplorer $v" -srcfolder dist/dmg -ov -format UDZO "$dmg"
          [ "${{ steps.sign.outputs.identity }}" = "-" ] || codesign --force --sign "${{ steps.sign.outputs.identity }}" "$dmg"
          { echo "zip=$zip"; echo "dmg=$dmg"; echo "length=$(stat -f%z "$zip")"; echo "sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)"; } >> "$GITHUB_OUTPUT"

      - name: Sign update (EdDSA)
        id: ed
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: |
          if [ -z "$SPARKLE_ED_PRIVATE_KEY" ]; then
            [ "${{ steps.v.outputs.dry }}" = "true" ] || { echo "::error::SPARKLE_ED_PRIVATE_KEY missing"; exit 1; }
            echo "signature=DRY-RUN" >> "$GITHUB_OUTPUT"; exit 0
          fi
          sig="$(echo "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "${{ steps.pkg.outputs.zip }}")"
          echo "signature=$sig" >> "$GITHUB_OUTPUT"

      - name: Render appcast and cask
        run: |
          v="${{ steps.v.outputs.version }}"; tag="v$v"
          base="https://github.com/${GITHUB_REPOSITORY}/releases/download/$tag"
          git fetch origin gh-pages:gh-pages 2>/dev/null || true
          mkdir -p dist/pages
          git show gh-pages:appcast.xml > dist/pages/appcast.xml 2>/dev/null || rm -f dist/pages/appcast.xml
          channel_args=(); [ "${{ steps.v.outputs.channel }}" = "beta" ] && channel_args=(--channel beta)
          python3 -I scripts/release/appcast.py --appcast dist/pages/appcast.xml --version "$v" \
            --build "${{ steps.v.outputs.build }}" --url "$base/MacExplorer-$v.zip" --length "${{ steps.pkg.outputs.length }}" \
            --ed-signature "${{ steps.ed.outputs.signature }}" --min-os 26.0 \
            --notes-url "https://github.com/${GITHUB_REPOSITORY}/releases/tag/$tag" "${channel_args[@]}"
          scripts/release/render-cask.sh --token "${{ steps.v.outputs.token }}" --version "$v" \
            --sha256 "${{ steps.pkg.outputs.sha }}" --url "$base/MacExplorer-$v.zip" > "dist/${{ steps.v.outputs.token }}.rb"

      - name: Upload dry-run artifacts
        if: steps.v.outputs.dry == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: release-dry-run
          path: |
            dist/*.zip
            dist/*.dmg
            dist/pages/appcast.xml
            dist/*.rb

      - name: GitHub Release
        if: steps.v.outputs.dry != 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          tag="v${{ steps.v.outputs.version }}"
          flags=(--verify-tag --generate-notes)
          [ "${{ steps.v.outputs.prerelease }}" = "true" ] && flags+=(--prerelease)
          gh release create "$tag" "${{ steps.pkg.outputs.zip }}" "${{ steps.pkg.outputs.dmg }}" "${flags[@]}"

      - name: Publish appcast
        if: steps.v.outputs.dry != 'true'
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git worktree add "$RUNNER_TEMP/pages" gh-pages
          cp dist/pages/appcast.xml "$RUNNER_TEMP/pages/appcast.xml"
          git -C "$RUNNER_TEMP/pages" add appcast.xml
          git -C "$RUNNER_TEMP/pages" commit -m "appcast: ${{ steps.v.outputs.version }}"
          git -C "$RUNNER_TEMP/pages" push origin gh-pages

      - name: Update Homebrew tap
        if: steps.v.outputs.dry != 'true'
        env:
          HOMEBREW_TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
        run: |
          [ -n "$HOMEBREW_TAP_TOKEN" ] || { echo "::warning::HOMEBREW_TAP_TOKEN not set; skipping tap"; exit 0; }
          git clone "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/roniburd/homebrew-macexplorer.git" "$RUNNER_TEMP/tap"
          mkdir -p "$RUNNER_TEMP/tap/Casks"
          cp "dist/${{ steps.v.outputs.token }}.rb" "$RUNNER_TEMP/tap/Casks/"
          cd "$RUNNER_TEMP/tap"
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add Casks && git commit -m "${{ steps.v.outputs.token }} ${{ steps.v.outputs.version }}" && git push

      - name: Clean up keychain
        if: always()
        run: security delete-keychain "$RUNNER_TEMP/release.keychain-db" 2>/dev/null || true
```

Note: verify `sign_update`'s flags against the pinned version (`"$SPARKLE_BIN/sign_update" --help`): Sparkle 2 accepts `--ed-key-file -` (key on stdin) and `-p` (print signature only). If `-p` isn't supported, parse `sparkle:edSignature="…"` from its default output.

- [ ] **Step 2: CI checks**

In `.github/workflows/ci.yml`, replace the `Bundle` step's run with:

```yaml
        run: |
          scripts/bundle.sh release
          codesign --verify --deep --strict .build/MacExplorer.app
          test -d .build/MacExplorer.app/Contents/Frameworks/Sparkle.framework
          test -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' .build/MacExplorer.app/Contents/Info.plist)"
          scripts/release/test-release-scripts.sh
```

- [ ] **Step 3: Validate locally**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); YAML.load_file(".github/workflows/ci.yml"); puts "yaml ok"'`. If `actionlint` is installed, run `actionlint .github/workflows/*.yml` and fix findings. Locally exercise the dry-run steps that don't need secrets: `scripts/bundle.sh release --version 0.0.0-beta.0 --build 1 --output "$PWD/dist/MacExplorer.app"` then the Package and Render steps by hand with `signature=DRY-RUN`; inspect `dist/pages/appcast.xml` and `dist/macexplorer@beta.rb`; `rm -rf dist`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml .github/workflows/ci.yml
git commit -m "ci: tag-driven release workflow (sign, package, appcast, Homebrew) and bundle checks"
```

---

### Task 14: README, owner setup, final verification

**Files:**
- Modify: `README.md`, `docs/superpowers/specs/2026-11-04-distribution-updates-feedback-design.md` (only if implementation diverged; e.g. marker path is `~/Library/Application Support/macExplorer/session.marker`)

- [ ] **Step 1: README sections**

Add to `README.md` (keep the existing structure; add after the build instructions):

```markdown
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

Help › **Report a Bug…** / **Request a Feature…** open a prefilled GitHub issue (you need a GitHub account and you
review everything before submitting). If MacExplorer crashes, it offers to report it the next time you open it; turn
this off in Settings › Advanced.

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
   `SELF_SIGNED_P12_PASSWORD`, `SELF_SIGNED_IDENTITY`.
5. Later, with an Apple Developer ID: add `DEVELOPER_ID_P12` (base64), `DEVELOPER_ID_P12_PASSWORD`,
   `NOTARY_API_KEY` (base64 .p8), `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER`. No code changes; remove the quarantine
   note above and the cask caveat.

Each release: `git tag -a v0.3.0-beta.1 -m "…" && git push origin v0.3.0-beta.1` (beta) or `v0.3.0` (release).
Try the pipeline without publishing: Actions › Release › Run workflow (dry run).
```

- [ ] **Step 2: Full verification**

```bash
scripts/check-layering.sh && scripts/test-check-layering.sh
swift build -c release 2>&1 | grep -E "warning:|error:" ; echo "release build exit: ${PIPESTATUS[0]}"
swift test --parallel 2>&1 | tail -5
scripts/release/test-release-scripts.sh
scripts/bundle.sh release && codesign --verify --deep --strict .build/MacExplorer.app && echo BUNDLE-OK
scripts/run-scenarios.sh release
scripts/ui-scenarios.sh
```

Expected: no warnings, all tests pass, `BUNDLE-OK`, scenario runners pass. Report any failure verbatim.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/superpowers/specs/2026-11-04-distribution-updates-feedback-design.md
git commit -m "docs: install, updates, feedback and release instructions"
```

- [ ] **Step 4: Hand-off to owner (do not perform)**

List for the owner the outward-facing steps that need their action: generate and store the real EdDSA key (and commit `SUPublicEDKey`), create `gh-pages`, create the tap repo + token, (if chosen) the self-signed certificate secrets, then push `v0.2.0-beta.1` and follow spec §9 rollout. Do not push, tag, create repositories or set secrets without explicit owner approval.
