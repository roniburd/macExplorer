# macExplorer Phase 1, Slice S6 (validation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove Phase 1 works. This slice adds four things: `macx-bench`, which measures the §4.4 budgets; `macx-scenarios`, a headless end-to-end Core scenario catalog that includes disk images and crash/kill recovery; an in-app UI scenario runner with 21 scripted UI scenarios; and CI, layering checks, a README and one script that runs every gate.

**Architecture:** Every runner creates its own `macx-*-<UUID>` sandbox and destroys it at the end.
- `macx-bench` builds 1k/10k/100k fixtures. It measures the real MacxFS/Core code paths: `DirectoryReader`, `SortKeys`/`Sorter`, `StoreDiff`, `FolderModel` with the live Watcher, and `SystemPasteboard` on a private pasteboard. It reports the median and p90 as JSON, gates budgets, and compares against a baseline.
- `macx-scenarios` runs each scenario against `CoreEnvironment.sandboxed(root:)`, or against `FileOpQueue`s it builds itself on disk images. It also re-executes itself as a crash helper that a scenario SIGKILLs at a `FaultPoint`.
- The UI runner is `ScenarioDriver`, which runs inside the bundled app under `--scenario`. It drives the real responder chain, menus and key handling. Key steps are posted `NSEvent`s. Mouse steps are SelectionCommands sent to the model, explained below. It reads results through `ScenarioProbe`.

**Tech Stack:** Swift 6.4 (language mode 6, warnings are errors), SwiftPM executable and test targets, XCTest, AppKit (UI runner and bench pasteboard only), Darwin, `hdiutil`, bash, GitHub Actions (`macos-26`).

**Spec:** `docs/superpowers/specs/2026-11-01-macexplorer-design.md` (§4.4, §9, §10, §5.6 key routing, §6). **Contract:** `docs/superpowers/plans/2026-11-01-phase1-00-overview.md` (§3 interface contract, §4 task list, "Phase 1 working definition").

## Global Constraints

Every Global Constraint in the overview applies to every task here. The HARD SAFETY RULE comes first and is repeated verbatim:

- **HARD SAFETY RULE.** Tests, benchmarks and any manual or automated validation must ONLY create, modify or delete files in two places: fresh temporary directories they create themselves (`FileManager.default.temporaryDirectory/macx-tests-<UUID>`, `macx-bench-<UUID>`, `macx-scenario-<UUID>`), or disk images they create themselves inside such a directory and attach with `-mountpoint <dir>/... -nobrowse`. They must never touch, move, rename, trash or delete any pre-existing user file. The app may READ the user's real folders when a human browses, but automated scenarios must point the app at a sandbox dir (`--root <sandbox>` plus `--state-dir <sandbox-sibling>/state`).

Slice-specific constraints:

- **One run directory per script.** `scripts/run-scenarios.sh`, `scripts/ui-scenarios.sh`, `scripts/ui-ax-smoke.sh` and `scripts/verify-phase1.sh` each create exactly one `${TMPDIR}/macx-<kind>-<UUID>` run directory. They refuse every path outside it, and on exit (`trap … EXIT`) they do three things in order:
  1. Detach any disk image mounted *under that directory only*.
  2. Clear `uchg` and mode-000 inside it.
  3. Delete it, then print `sandbox root <path> removed`.
- **Child processes stay in the run directory.** `run-scenarios.sh` starts `macx-scenarios` with `TMPDIR=<run dir>/`, so every `Sandbox` it creates is inside the run directory.
- **Harness I/O on the main thread is allowed, with limits.** Code in `macx-bench`, `macx-scenarios` and test files may make synchronous file-system calls on the main thread when building fixtures and checking results; these executables are not the app. They must never call lane-only MacxFS/Core APIs (anything documented "lane only") outside `LanePool.perform`.
- **The UI runner does its I/O on lanes.** `ScenarioDriver` runs inside the app, so all of its file I/O goes through `context.environment.lanes.perform(on: .unknown)`.
- **Raw writes need sandbox-derived paths.** Harnesses may write with raw POSIX calls (`open`, `rename`, `chflags`, `chmod`, `setxattr`, `utimensat`) only on URLs obtained from their `Sandbox`/`SandboxHandle`. Every such helper calls `precondition(sandbox.contains(url))`.
- **No trash outside the sandbox.** No runner ever uses `SystemTrash`. Cross-volume scenarios use `SandboxTrash(directory: <image>/.macx-trash)`, so trashing is a same-volume rename inside a test image.
- **The UI runner uses a separate bundle and sandbox options.** It executes `.build/macExplorer-scenarios.app/Contents/MacOS/macExplorer` directly, with `--root`, `--state-dir`, `--sandbox-trash`, `--pasteboard macx-scenario-<UUID>`, `--fake-launch-services`, `--skip-onboarding` and `-ApplePersistenceIgnoreState YES`. The app releases its private pasteboard before exiting.
- **Test fixture literals.** This slice's harness files never contain the literal `/Users/`: `Sources/macx-bench`, `Sources/macx-scenarios`, `Tests/BenchTests`, `Tests/ScenarioRunnerTests`, `Tests/UITests/Scenario*.swift` and `Tests/Scenarios/*.json` (enforced by `check-layering.sh`, P1-42). Use `/Library/…` or `/tmp/…` literals in negative tests. S1 and S5 unit tests use `"/Users/…"` only as pure strings for mount-table and breadcrumb math that never reach the file system, so the check does not cover them (Contract note C11).

## Review Focus

These are the five failure modes in this slice most likely to bite a person running the validation tools, most likely first. Each is pinned by a test in the task named.

1. **A scenario or bench run dies or throws while a disk image is attached, or a fixture has `uchg` files or mode-000 folders.** Expected: the image is detached, protections are cleared, and the sandbox is removed. The next run is unaffected, and nothing outside the run directory is touched. Owner P1-40: `testImagesAreDetachedWhenScenarioThrows`, `testFailingScenarioReportsMessageAndStillCleansUp` (locked file plus 000 folder). The scripts' EXIT traps do the same.
2. **`TMPDIR` is a symlinked path (`/var/folders/…` vs `/private/var/folders/…`).** Expected: the folder expectations and the fixture guard compare both spellings, and never report "outside root" for the sandbox itself. Owner P1-41: `testRelativePathAcceptsBothTmpSpellings`, `testFixturesRefuseEscapingPaths`.
3. **The bench baseline is from an older or corrupt run** (missing `unit`/`samples`/`schema`, duplicate keys, metrics added or removed). Expected: no crash. New metrics are "new", removed ones are "missing", and neither fails the gate. Owner P1-39: `testLenientDecodingOfOlderBaselines`, `testNewAndMissingMetricsNeverFail`.
4. **The scenario app cannot become the active app** (macOS cooperative activation refuses because the user is typing in another app). This was verified on this machine on 2026-11-02: `NSApp.activate()` and even `activateIgnoringOtherApps:` were refused while another app was frontmost. Expected: every scenario still runs deterministically, because the driver pins the browser window as key/main through `MacxApplication`. The result JSON records `activated` for diagnosis. Owner P1-41: `testPickKeyWindowPrefersFrontmostNonSheetWindow`. All 21 UI scenarios run in that mode.
5. **A scenario hangs** (a conflict is never answered, or a job is stuck). Expected: a per-scenario timeout fails it with "timed out", cancels its jobs and cleans up. The run never hangs, and the UI script kills a stuck app after 120 s. Owner P1-40: `testTimedOutScenarioIsCancelledAndCleanedUp`.

## Facts verified on this machine (2026-11-02, Swift 6.4, Xcode 27.2, macOS 26.7.2)

All of these were verified with throwaway packages and apps in `${TMPDIR}/macx-s6probe-*`, since deleted.

1. A test target can depend on an executable target whose `main.swift` has top-level `await` code, and use `@testable import macx_bench` (the module name replaces `-` with `_`). This works under `treatAllWarnings(as: .error)`.
2. Top-level code of the form `Task { @MainActor in …; exit(code) }` followed by `RunLoop.main.run()` runs main-actor work. An `UndoManager` with `groupsByEvent` then closes its groups, because the CFRunLoop observers fire. Both CLIs use this pattern.
3. `task_info(mach_task_self_, TASK_VM_INFO)` (`phys_footprint`) and `sysctlbyname("hw.optional.arm64")` compile under Swift 6 strict concurrency.
4. When the app is **not** active, events still get through but nil-targeted actions don't:
   - Posted `keyDown`s reach a field editor (insertion, ⌥← word moves).
   - Menu key equivalents fire.
   - `NSApp.keyWindow` and `NSApp.mainWindow` are nil, so nil-targeted actions (`NSApp.sendAction(_:to: nil, from:)`, menu items with nil targets) do **not** reach window views.
   - Synthesized clicks on an `NSTableView` in an inactive window do not select rows (first-click activation).
5. An `NSApplication` subclass that overrides `keyWindow`, `mainWindow` and `isActive` to return a pinned window makes nil-targeted actions resolve through that window's responder chain while inactive. It resolved `selectAll:` to the window's `NSTableView`.
6. `NSApp.postEvent` of `rightMouseDown`/`rightMouseUp` to a view that calls `NSMenu.popUpContextMenu` shows the menu. Main-actor tasks keep running during menu tracking. `NSMenu.didBeginTrackingNotification` delivers the menu, and `cancelTracking()` followed by `performActionForItem(at:)` performs the item.
7. An `.applicationDefined` event posted after a burst of posted key events works as a fence. A local event monitor sees it after the earlier events were dispatched.
8. SwiftUI hosting views expose **no** in-process accessibility children, even after repeated requests. A SwiftUI dialog's buttons therefore cannot be pressed by `AXID` from inside the process.
9. `hdiutil create -fs APFS|ExFAT` plus `attach -mountpoint <tmp>/mnt -nobrowse` plus `detach -force` works inside `${TMPDIR}`.
10. macOS has no `timeout(1)` command, so scripts implement their own polling timeouts. `-ApplePersistenceIgnoreState YES` with non-restorable windows wrote no `savedState`. AppKit's saved-state location ignores `TMPDIR` (it uses `DARWIN_USER_TEMP_DIR`).

## MacxFixtures surface consumed by this slice (P1-02, S1; see Contract note C1)

The overview §3 does not list the `MacxFixtures` API. S1's P1-02 defines it (`docs/superpowers/plans/2026-11-01-phase1-s1-fskit.md`, P1-02 Interfaces block and its Contract notes 1). S6 uses only these declarations, copied from there:

| S1 declaration (exact) | Used for |
|---|---|
| `public final class Sandbox: Sendable` | sandbox object |
| `public init(prefix: String = "macx-tests") throws` | creates `<FileManager.default.temporaryDirectory>/<prefix>-<UUID>`; `prefix` must be in `Sandbox.allowedPrefixes` (`macx-tests`, `macx-bench`, `macx-scenario`, `macx-fixtures`); honours `TMPDIR`, which `run-scenarios.sh` points at its run directory |
| `public let root: URL` | sandbox root, symlink-resolved (`/private/var/folders/…`) |
| `public func url(_ relative: String, file: StaticString = #fileID, line: UInt = #line) -> URL` | traps if the path escapes `root` |
| `public func contains(_ url: URL) -> Bool` | path guard |
| `@discardableResult public func createDirectory(_ relative: String) throws -> URL` | intermediate directories created; idempotent |
| `@discardableResult public func createFile(_ relative: String, contents: Data = Data("x".utf8)) throws -> URL` | parent directories created; **fails if the file exists** (`O_EXCL`) |
| `public func overwrite(_ relative: String, contents: Data) throws` | replaces the contents of an existing file |
| `public func destroy()` | idempotent; detaches the sandbox's images, clears protections, removes `root` |
| `public enum DiskImageFormat: String, Sendable, CaseIterable { case apfs = "APFS", hfsPlus = "HFS+", exfat = "ExFAT", msdos = "MS-DOS" }` | image formats |
| `public final class DiskImage: Sendable` with `mountPoint`, `relativeMountPath`, `isReadOnly` | disk image handle; mounted `-nobrowse` at `<sandbox>/mnt-<id>` |
| `public static var isAvailable: Bool` | whether `hdiutil` can be used |
| `public static func create(in sandbox: Sandbox, format: DiskImageFormat, sizeMB: Int = 32, volumeName: String = "MACXTEST", readOnly: Bool = false, populate: ((URL) throws -> Void)? = nil) throws -> DiskImage` | create and attach an image |
| `public func detach() throws` | `hdiutil detach -force`; idempotent |
| `public enum FixtureTree { @discardableResult public static func flat(in sandbox: Sandbox, at relative: String, count: Int, prefix: String = "file-", ext: String = ".txt", width: Int = 6, directoriesEvery: Int = 0) throws -> URL }` | flat fixture folders (`file-000000.txt` …) |

Only two files in this slice name these types: `Sources/macx-bench/FixtureAdapter.swift` and `Sources/macx-scenarios/FixtureAdapter.swift`. They expose non-throwing `SandboxHandle` helpers to the rest of the harness: a fixture write that fails inside a fresh temporary directory is an environment failure (disk full, `TMPDIR` unwritable), so the adapter traps with the path and the error (the scripts' EXIT traps still remove the run directory). Three UITests files also use `Sandbox` directly: `ScenarioFixturesTests`, `ScenarioInteractionTests` and `ScenarioHooksWiringTests` (BenchTests and ScenarioRunnerTests go through `SandboxHandle`). If P1-02 ships different names than S1's plan, change only these files, never P1-02.

S6 does **not** use `Sandbox(adopting:)` (S1 Contract notes 1 suggests it for `--root`): the `UI` target must not link `MacxFixtures` (test fixtures never ship in the app, enforced by `check-layering.sh`), and the UI runner's roots are `<run dir>/<scenario>/macx-scenario-root`, which is not directly in `$TMPDIR`. `ScenarioFixtures` (P1-41) applies its own guard instead (Contract note C3).

## Package.swift changes in this slice (Contract note C2)

P1-39 and P1-40 each append one test target to the `targets:` array in the overview's §1 manifest, after `UITests`:

```swift
        .testTarget(name: "BenchTests", dependencies: ["macx-bench", "Core", "MacxFS", "MacxFixtures"], swiftSettings: strict),          // P1-39
        .testTarget(name: "ScenarioRunnerTests", dependencies: ["macx-scenarios", "Core", "MacxFS", "MacxFixtures"], swiftSettings: strict), // P1-40
```

---

## Task P1-39: `macx-bench` (budgets, median/p90 JSON, `--check-budgets`, `--compare` gate)

**Spec:** §4.4 (budget table), §9 Benchmarks (1k/10k/100k fixtures; enumerate, sort-key generation, sort, re-sort, diff, 100k pasteboard write; one warm-up plus 5 measured iterations; median and p90 in JSON; relative CI gate of >20% **and** >5 ms; absolute budgets via `--check-budgets` on Apple Silicon), §10 (`swift run -c release macx-bench`).

**Files:**
- Modify: `Package.swift` (add the `BenchTests` target shown above)
- Create: `Sources/macx-bench/main.swift`, `Sources/macx-bench/BenchCLI.swift`, `Sources/macx-bench/Metrics.swift`, `Sources/macx-bench/Stats.swift`, `Sources/macx-bench/Budgets.swift`, `Sources/macx-bench/BaselineCompare.swift`, `Sources/macx-bench/Report.swift`, `Sources/macx-bench/Machine.swift`, `Sources/macx-bench/FixtureAdapter.swift`
  - The file map lists `main.swift`, `Metrics.swift`, `Stats.swift`, `Budgets.swift` and `BaselineCompare.swift`. `BenchCLI.swift`, `Report.swift`, `Machine.swift` and `FixtureAdapter.swift` are additions that keep `main.swift` a two-line entry point and make the logic testable.
- Test: `Tests/BenchTests/StatsTests.swift`, `Tests/BenchTests/BudgetsTests.swift`, `Tests/BenchTests/BaselineCompareTests.swift`, `Tests/BenchTests/BenchCLITests.swift`, `Tests/BenchTests/BenchSmokeTests.swift`

**Interfaces:**
- Consumes (from the overview §3, exact names):
  - `CoreEnvironment.sandboxed(root:)`, `CoreEnvironment.start() async -> RecoveryReport`, `CoreEnvironment.makeFolderModel(_:query:)`, plus `.readers`, `.volumes`, `.types`, `.fileOps`
  - `DirectoryReaders.reader(for: URL) -> DirectoryReader`
  - `DirectoryReader.read(_:generation:options:) -> AsyncStream<ReadEvent>`
  - `EntryStore(identityMode:)` with `append(_:)`, `setOrder(_:)`, `upsert(_:name:)`, `remove(_:)`, `entry(_:)`, `name(_:)`, `count`
  - `SortKeys.nameKeys(_:range:)`, `SortKeys.searchKeys(_:)`
  - `Sorter.permutation(_:nameKeys:searchKeys:query:kindRanks:)`
  - `StoreDiff.diff(old:new:)`
  - `TypeRegistry.kindRanks()`, `TypeRegistry.index(forExtension:isDirectory:)`
  - `FolderModel` with `start()`, `close()`, `setQuery(_:)`, `state`, `rowCount`, `row(named:)`, `observe(_:)`; `FolderEvent.changes`
  - `SystemPasteboard(name:)` with `writeFileURLs(_:cutMarker:)`
  - `Generation.initial.next()`, `ViewQuery`, `SortDescriptor`, `SortField.allCases`, `VolumeCapabilities.identityMode`, `Entry(...)`
  - From P1-02 (assumed, see the table above): `Sandbox`, `FixtureTree.flat`.
- Produces (internal to `macx_bench`, used by `BenchTests` and the CI workflow in P1-42):
  - `enum Stats { static func median(_:) -> Double; static func percentile(_:_:) -> Double; static func sample(warmups:iterations:_:) async rethrows -> [Double]; static func milliseconds(_: Duration) -> Double }`
  - `struct MetricResult: Codable { name, size, unit, median, p90, samples; key }`
  - `struct BenchReport: Codable { schema, machine, configuration, warmups, iterations, metrics, budgets, sandbox, sandboxRemoved }`
  - `struct BenchOptions { sizes, warmups, iterations, metrics, output, compare, checkBudgets, warnBudgets, allowDebug, keepFixtures; static func parse(_:) throws(BenchError) }`
  - `enum Budgets { static let table: [Budget]; static func evaluate(_:table:) -> [BudgetCheck]; static func annotations(_:) -> [String] }`
  - `enum BaselineCompare { static func isRegression(baseline:current:unit:) -> Bool; static func compare(current:baseline:) -> [Comparison]; static func decodeBaseline(_: Data) throws -> [BaselineMetric]; static func loadBaseline(_: URL) throws -> [BaselineMetric]; static func render(_:) -> String }`
  - `@MainActor enum Bench { static func run(_: BenchOptions, log:) async throws -> BenchReport }`
  - `@MainActor enum BenchCLI { static func run(_ arguments: [String]) async -> Int32 }`
- **CLI contract** (used by P1-42 CI and README):
  - Usage: `macx-bench [--sizes 1000,10000,100000] [--warmups 1] [--iterations 5] [--metrics prefix,…] [--output FILE] [--compare BASELINE.json] [--check-budgets] [--warn-budgets] [--allow-debug] [--keep-fixtures]`
  - Exit codes: 0 ok; 1 a `--compare` regression; 2 a `--check-budgets` violation on Apple Silicon; 3 `--check-budgets` on a debug build without `--allow-debug`; 64 usage error; 70 runtime error.
  - `--warn-budgets` prints `::warning title=Performance budget::…` lines to stdout and never changes the exit code.

**Metric catalogue.** Each `name@size` gets 1 warm-up plus 5 measured iterations by default.

| Metric | What is timed | Budget (§4.4) |
|---|---|---|
| `enumerate` | `DirectoryReader.read` to `.completed`, appending each `Batch` to an `EntryStore` | none (component of the next one) |
| `firstBatch` | `FolderModel.start()` to its first `.changes` event (first rows ready to paint) | < 50 ms, every size |
| `listSorted` | `FolderModel.start()` to `state == .complete` with all rows | < 250 ms @100k |
| `sortkeys` | `SortKeys.nameKeys` over the whole store | none |
| `sort` | `Sorter.permutation`, default query | none |
| `resort.<field>` | `Sorter.permutation` with precomputed keys, for each of the 6 `SortField`s | < 30 ms @100k |
| `filter` | `SortKeys.searchKeys` plus a filtered permutation (`"42"`) | none |
| `modelResort` | `FolderModel.setQuery` (name ↑/↓ alternating) to its `.changes` | < 30 ms @100k |
| `diff` | `StoreDiff.diff` with 1% modified, 0.5% removed, 0.5% added | none |
| `memory.steady` | `phys_footprint` delta after building store, keys and order (MB) | < 20 MB @100k |
| `pasteboard` | `SystemPasteboard(name: "macx-bench-<UUID>").writeFileURLs` for every row | < 300 ms @100k |
| `fsevent.incremental` | create 1 file → row present in a watched `FolderModel` | < 150 ms, every size |
| `fsevent.full` | create 300 files (> 256, full re-read) → all rows present | < 400 ms @100k |

These §4.4 rows are not measured headlessly, and go to the README release checklist (P1-42) with Instruments: scroll/cell configure, main-thread hangs, icons, cold launch, and peak memory (see Contract note C10).

- [ ] **Step 1: Add the test target and write the failing tests**

Add the `BenchTests` line to `Package.swift` (see "Package.swift changes" above). Then create the test files.

`Tests/BenchTests/StatsTests.swift`:

```swift
import XCTest
@testable import macx_bench

final class StatsTests: XCTestCase {
    func testMedianOddAndEven() {
        XCTAssertEqual(Stats.median([3, 1, 2]), 2)
        XCTAssertEqual(Stats.median([4, 1, 3, 2]), 2.5)
    }

    func testP90IsNearestRank() {
        XCTAssertEqual(Stats.percentile([5, 1, 4, 2, 3], 0.9), 5)
        XCTAssertEqual(Stats.percentile((1...10).map(Double.init), 0.9), 9)
        XCTAssertEqual(Stats.percentile([7], 0.9), 7)
    }

    @MainActor
    func testSampleRunsWarmupsThenReturnsOnlyMeasuredIterations() async {
        var calls = 0
        let samples = await Stats.sample(warmups: 1, iterations: 5) {
            calls += 1
            return Double(calls)
        }
        XCTAssertEqual(calls, 6)
        XCTAssertEqual(samples, [2, 3, 4, 5, 6])
    }

    func testMillisecondsConversion() {
        XCTAssertEqual(Stats.milliseconds(.milliseconds(1500)), 1500, accuracy: 1e-9)
        XCTAssertEqual(Stats.milliseconds(.microseconds(250)), 0.25, accuracy: 1e-9)
    }

    func testMetricResultComputesMedianAndP90() {
        let m = MetricResult(name: "sort", size: 10, samples: [10, 30, 20, 50, 40])
        XCTAssertEqual(m.median, 30)
        XCTAssertEqual(m.p90, 50)
        XCTAssertEqual(m.key, "sort@10")
        XCTAssertEqual(m.unit, "ms")
    }
}
```

`Tests/BenchTests/BudgetsTests.swift`:

```swift
import XCTest
import MacxFS
@testable import macx_bench

final class BudgetsTests: XCTestCase {
    func testOnlyListedSizesAreChecked() {
        let checks = Budgets.evaluate([
            MetricResult(name: "listSorted", size: 1_000, samples: [900]),
            MetricResult(name: "listSorted", size: 100_000, samples: [260]),
        ])
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.size, 100_000)
        XCTAssertEqual(checks.first?.passed, false)
    }

    func testFirstBatchAppliesToEverySize() {
        let checks = Budgets.evaluate([1_000, 10_000, 100_000].map { MetricResult(name: "firstBatch", size: $0, samples: [20]) })
        XCTAssertEqual(checks.map(\.passed), [true, true, true])
    }

    func testEveryResortFieldHasA30msBudgetAt100k() {
        for field in SortField.allCases {
            let budget = Budgets.table.first { $0.metric == "resort.\(field.rawValue)" }
            XCTAssertEqual(budget?.limit, 30, field.rawValue)
            XCTAssertEqual(budget?.sizes, [100_000], field.rawValue)
        }
    }

    func testMemoryBudgetUsesMegabytes() {
        let checks = Budgets.evaluate([MetricResult(name: "memory.steady", size: 100_000, unit: "MB", samples: [25])])
        XCTAssertEqual(checks.first?.passed, false)
        XCTAssertEqual(checks.first?.unit, "MB")
    }

    func testAnnotationsOnlyForFailures() {
        let checks = Budgets.evaluate([
            MetricResult(name: "pasteboard", size: 100_000, samples: [350]),
            MetricResult(name: "firstBatch", size: 1_000, samples: [5]),
        ])
        let lines = Budgets.annotations(checks)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("::warning title=Performance budget::pasteboard @ 100000"), lines[0])
    }

    func testBudgetTableCoversEveryHeadlessSpecRow() {
        let names = Set(Budgets.table.map(\.metric))
        for name in ["firstBatch", "listSorted", "modelResort", "fsevent.incremental", "fsevent.full", "memory.steady", "pasteboard"] {
            XCTAssertTrue(names.contains(name), name)
        }
    }
}
```

`Tests/BenchTests/BaselineCompareTests.swift`:

```swift
import XCTest
@testable import macx_bench

final class BaselineCompareTests: XCTestCase {
    private func base(_ name: String, _ size: Int, _ median: Double) -> BaselineMetric {
        BaselineMetric(name: name, size: size, median: median, unit: "ms")
    }

    func testFailsOnlyWhenBothRelativeAndAbsoluteThresholdsAreExceeded() {
        XCTAssertTrue(BaselineCompare.isRegression(baseline: 100, current: 121, unit: "ms"))
        XCTAssertFalse(BaselineCompare.isRegression(baseline: 100, current: 119, unit: "ms"))   // < 20 %
        XCTAssertFalse(BaselineCompare.isRegression(baseline: 10, current: 14, unit: "ms"))     // 40 % but only 4 ms
        XCTAssertTrue(BaselineCompare.isRegression(baseline: 10, current: 15.5, unit: "ms"))
        XCTAssertFalse(BaselineCompare.isRegression(baseline: 5, current: 6.5, unit: "MB"))     // MB uses a 2 MB floor
    }

    func testNewAndMissingMetricsNeverFail() {
        let comparisons = BaselineCompare.compare(
            current: [MetricResult(name: "sort", size: 1_000, samples: [5]), MetricResult(name: "diff", size: 1_000, samples: [9])],
            baseline: [base("sort", 1_000, 5), base("gone", 1_000, 1)])
        let byKey = Dictionary(uniqueKeysWithValues: comparisons.map { ($0.key, $0.status) })
        XCTAssertEqual(byKey, ["sort@1000": .ok, "diff@1000": .new, "gone@1000": .missing])
    }

    func testRegressionAndImprovementAreClassified() {
        let comparisons = BaselineCompare.compare(
            current: [MetricResult(name: "a", size: 1, samples: [200]), MetricResult(name: "b", size: 1, samples: [50])],
            baseline: [base("a", 1, 100), base("b", 1, 100)])
        XCTAssertEqual(comparisons.map(\.status), [.regressed, .improved])
        XCTAssertTrue(BaselineCompare.render(comparisons).contains("REGRESSED a@1"))
    }

    func testLenientDecodingOfOlderBaselines() throws {
        let json = #"{"metrics":[{"name":"sort","size":100000,"median":12.5},{"name":"sort","size":100000,"median":99}],"extra":true}"#
        let metrics = try BaselineCompare.decodeBaseline(Data(json.utf8))
        XCTAssertEqual(metrics.count, 2)
        let comparisons = BaselineCompare.compare(current: [MetricResult(name: "sort", size: 100_000, samples: [12])], baseline: metrics)
        XCTAssertEqual(comparisons.first?.status, .ok)   // duplicate keys: first wins, never traps
    }

    func testOwnReportFormatIsAValidBaseline() throws {
        let report = BenchReport(
            machine: MachineInfo(cpu: "test", appleSilicon: true, os: "26", cores: 12),
            configuration: "release", warmups: 1, iterations: 5,
            metrics: [MetricResult(name: "sort", size: 10, samples: [1, 2, 3])],
            budgets: nil, sandbox: "/tmp/macx-bench-x", sandboxRemoved: true)
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try BaselineCompare.decodeBaseline(data).first?.median, 2)
    }
}
```

`Tests/BenchTests/BenchCLITests.swift`:

```swift
import XCTest
@testable import macx_bench

final class BenchCLITests: XCTestCase {
    func testDefaults() throws {
        let o = try BenchOptions.parse([])
        XCTAssertEqual(o.sizes, [1_000, 10_000, 100_000])
        XCTAssertEqual(o.warmups, 1)
        XCTAssertEqual(o.iterations, 5)
        XCTAssertNil(o.metrics)
        XCTAssertFalse(o.checkBudgets)
    }

    func testParsesEveryOption() throws {
        let o = try BenchOptions.parse(["--sizes", "300,500", "--warmups", "0", "--iterations", "2", "--metrics", "sort,diff",
                                        "--output", "/tmp/macx-bench-out/b.json", "--compare", "/tmp/macx-bench-out/base.json",
                                        "--check-budgets", "--warn-budgets", "--allow-debug", "--keep-fixtures"])
        XCTAssertEqual(o.sizes, [300, 500])
        XCTAssertEqual(o.warmups, 0)
        XCTAssertEqual(o.iterations, 2)
        XCTAssertEqual(o.metrics, ["sort", "diff"])
        XCTAssertEqual(o.output?.path, "/tmp/macx-bench-out/b.json")
        XCTAssertEqual(o.compare?.lastPathComponent, "base.json")
        XCTAssertTrue(o.checkBudgets && o.warnBudgets && o.allowDebug && o.keepFixtures)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try BenchOptions.parse(["--sizes"])) { XCTAssertEqual($0 as? BenchError, .missingValue("--sizes")) }
        XCTAssertThrowsError(try BenchOptions.parse(["--sizes", "10,x"])) { XCTAssertEqual($0 as? BenchError, .badValue("--sizes", "10,x")) }
        XCTAssertThrowsError(try BenchOptions.parse(["--iterations", "0"])) { XCTAssertEqual($0 as? BenchError, .badValue("--iterations", "0")) }
        XCTAssertThrowsError(try BenchOptions.parse(["--frobnicate"])) { XCTAssertEqual($0 as? BenchError, .unknownOption("--frobnicate")) }
    }

    @MainActor
    func testUsageErrorExits64() async {
        let code = await BenchCLI.run(["--frobnicate"])
        XCTAssertEqual(code, 64)
    }

    #if DEBUG
    @MainActor
    func testCheckBudgetsRefusesDebugBuildsBeforeCreatingFixtures() async {
        let code = await BenchCLI.run(["--check-budgets", "--sizes", "10"])
        XCTAssertEqual(code, 3)
    }
    #endif
}
```

`Tests/BenchTests/BenchSmokeTests.swift`:

```swift
import XCTest
import MacxFS
@testable import macx_bench

@MainActor
final class BenchSmokeTests: XCTestCase {
    func testSmallRunProducesEveryMetricAndRemovesItsSandbox() async throws {
        let report = try await Bench.run(BenchOptions(sizes: [300], warmups: 0, iterations: 1))
        var expected: Set<String> = ["enumerate", "firstBatch", "listSorted", "sortkeys", "sort", "filter", "modelResort",
                                     "diff", "memory.steady", "pasteboard", "fsevent.incremental", "fsevent.full"]
        for field in SortField.allCases { expected.insert("resort.\(field.rawValue)") }
        XCTAssertEqual(Set(report.metrics.map(\.name)), expected)
        XCTAssertTrue(report.metrics.allSatisfy { $0.size == 300 && $0.samples.count == 1 })
        for metric in report.metrics where metric.unit == "ms" {
            XCTAssertGreaterThan(metric.median, 0, metric.key)
        }
        XCTAssertTrue(URL(filePath: report.sandbox).lastPathComponent.hasPrefix("macx-bench-"))
        XCTAssertTrue(report.sandboxRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.sandbox))
    }

    func testMetricFilterRunsOnlyRequestedFamilies() async throws {
        let report = try await Bench.run(BenchOptions(sizes: [50], warmups: 0, iterations: 1, metrics: ["sort", "resort"]))
        XCTAssertFalse(report.metrics.isEmpty)
        XCTAssertTrue(report.metrics.allSatisfy { $0.name.hasPrefix("sort") || $0.name.hasPrefix("resort") })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter BenchTests 2>&1 | grep -E "error:|Executed" | head -5`
Expected: compile errors such as `error: cannot find 'Stats' in scope` (the `macx-bench` sources are still the P1-01 stub).

- [ ] **Step 3: Implement statistics, report types, machine info and the fixture adapter**

`Sources/macx-bench/Stats.swift`:

```swift
import Foundation

enum Stats {
    static func median(_ xs: [Double]) -> Double {
        precondition(!xs.isEmpty, "median of no samples")
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Nearest-rank percentile, `p` in (0, 1].
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        precondition(!xs.isEmpty && p > 0 && p <= 1, "bad percentile input")
        let s = xs.sorted()
        let rank = Int((p * Double(s.count)).rounded(.up))
        return s[max(0, min(s.count - 1, rank - 1))]
    }

    /// Runs `body` `warmups` times (discarded), then `iterations` times; returns the measured samples.
    @MainActor
    static func sample(warmups: Int, iterations: Int, _ body: @MainActor () async throws -> Double) async rethrows -> [Double] {
        for _ in 0..<warmups { _ = try await body() }
        var out: [Double] = []
        out.reserveCapacity(iterations)
        for _ in 0..<iterations { out.append(try await body()) }
        return out
    }

    static func milliseconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
    }
}
```

`Sources/macx-bench/Report.swift`:

```swift
import Foundation

struct MetricResult: Codable, Equatable, Sendable {
    var name: String
    var size: Int
    var unit: String          // "ms" or "MB"
    var median: Double
    var p90: Double
    var samples: [Double]
    var key: String { "\(name)@\(size)" }

    init(name: String, size: Int, unit: String = "ms", samples: [Double]) {
        self.name = name
        self.size = size
        self.unit = unit
        self.samples = samples
        self.median = Stats.median(samples)
        self.p90 = Stats.percentile(samples, 0.9)
    }
}

struct MachineInfo: Codable, Equatable, Sendable {
    var cpu: String
    var appleSilicon: Bool
    var os: String
    var cores: Int
    static func current() -> MachineInfo {
        MachineInfo(cpu: Machine.cpuBrand(), appleSilicon: Machine.isAppleSilicon(),
                    os: ProcessInfo.processInfo.operatingSystemVersionString,
                    cores: ProcessInfo.processInfo.activeProcessorCount)
    }
}

struct BenchReport: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var schema: Int = BenchReport.schemaVersion
    var machine: MachineInfo
    var configuration: String          // "debug" | "release"
    var warmups: Int
    var iterations: Int
    var metrics: [MetricResult]
    var budgets: [BudgetCheck]?
    var sandbox: String
    var sandboxRemoved: Bool
}
```

`Sources/macx-bench/Machine.swift`:

```swift
import Darwin
import Foundation

enum Machine {
    /// phys_footprint of this process in bytes (-1 on failure).
    static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func cpuBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
```

`Sources/macx-bench/FixtureAdapter.swift`:

```swift
import Foundation
import MacxFixtures

/// The ONLY file in macx-bench that names MacxFixtures (P1-02) types. If P1-02's names differ from the
/// ones used here, adapt this file only (Contract note C1).
struct SandboxHandle: Sendable {
    fileprivate let sandbox: Sandbox
    var root: URL { sandbox.root }
    static func make(prefix: String) throws -> SandboxHandle { SandboxHandle(sandbox: try Sandbox(prefix: prefix)) }
    /// Creates the file, or replaces its contents if it already exists (Sandbox.createFile is O_EXCL).
    @discardableResult func file(_ relative: String, _ contents: Data = Data("x".utf8)) -> URL {
        fixtureWrite(relative) {
            let url = sandbox.url(relative)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try sandbox.overwrite(relative, contents: contents)
                return url
            }
            return try sandbox.createFile(relative, contents: contents)
        }
    }
    @discardableResult func flat(_ relative: String, count: Int) -> URL {
        fixtureWrite(relative) { try FixtureTree.flat(in: sandbox, at: relative, count: count) }
    }
    func destroy() { sandbox.destroy() }
}

/// A fixture write inside a fresh sandbox only fails when the environment is broken (disk full,
/// unwritable TMPDIR); the bench cannot measure anything then, so it stops with the reason.
func fixtureWrite<T>(_ relative: String, _ body: () throws -> T) -> T {
    do { return try body() } catch { preconditionFailure("fixture write '\(relative)' failed: \(error)") }
}
```

- [ ] **Step 4: Implement budgets and the baseline comparison**

`Sources/macx-bench/Budgets.swift`:

```swift
import Foundation
import MacxFS

struct Budget: Sendable, Equatable {
    var metric: String
    var sizes: Set<Int>?        // nil = every size
    var limit: Double
    var unit: String
    var spec: String
}

struct BudgetCheck: Codable, Equatable, Sendable {
    var metric: String
    var size: Int
    var limit: Double
    var unit: String
    var median: Double
    var passed: Bool
    var spec: String
}

enum Budgets {
    /// §4.4 rows that macx-bench can measure headlessly (Apple Silicon, local APFS, warm cache).
    static let table: [Budget] = {
        var t: [Budget] = [
            Budget(metric: "firstBatch", sizes: nil, limit: 50, unit: "ms", spec: "§4.4 navigate → first rows painted < 50 ms"),
            Budget(metric: "listSorted", sizes: [100_000], limit: 250, unit: "ms", spec: "§4.4 100k entries fully listed + sorted < 250 ms"),
            Budget(metric: "modelResort", sizes: [100_000], limit: 30, unit: "ms", spec: "§4.4 re-sort 100k by any column < 30 ms"),
            Budget(metric: "fsevent.incremental", sizes: nil, limit: 150, unit: "ms", spec: "§4.4 FSEvent → UI updated (incremental) < 150 ms"),
            Budget(metric: "fsevent.full", sizes: [100_000], limit: 400, unit: "ms", spec: "§4.4 FSEvent → UI updated (full re-read of 100k) < 400 ms"),
            Budget(metric: "memory.steady", sizes: [100_000], limit: 20, unit: "MB", spec: "§4.4 memory, 100k-entry folder < 20 MB steady"),
            Budget(metric: "pasteboard", sizes: [100_000], limit: 300, unit: "ms", spec: "§4.4 copy of 100k items (pasteboard write) < 300 ms"),
        ]
        t += SortField.allCases.map {
            Budget(metric: "resort.\($0.rawValue)", sizes: [100_000], limit: 30, unit: "ms", spec: "§4.4 re-sort 100k by any column < 30 ms")
        }
        return t
    }()

    static func evaluate(_ metrics: [MetricResult], table: [Budget] = Budgets.table) -> [BudgetCheck] {
        metrics.compactMap { m in
            guard let b = table.first(where: { $0.metric == m.name && $0.unit == m.unit && ($0.sizes?.contains(m.size) ?? true) }) else {
                return nil
            }
            return BudgetCheck(metric: m.name, size: m.size, limit: b.limit, unit: b.unit, median: m.median,
                               passed: m.median <= b.limit, spec: b.spec)
        }
    }

    /// GitHub Actions warning annotations for failed checks (non-blocking in CI, §9).
    static func annotations(_ checks: [BudgetCheck]) -> [String] {
        checks.filter { !$0.passed }.map {
            "::warning title=Performance budget::\($0.metric) @ \($0.size): median \(format($0.median)) \($0.unit) > \(format($0.limit)) \($0.unit) (\($0.spec))"
        }
    }

    static func format(_ v: Double) -> String { String(format: "%.1f", v) }
}
```

`Sources/macx-bench/BaselineCompare.swift`:

```swift
import Foundation

/// Lenient view of a baseline metric: older or foreign reports may lack unit/samples/schema.
struct BaselineMetric: Decodable, Equatable, Sendable {
    var name: String
    var size: Int
    var median: Double
    var unit: String?
    var key: String { "\(name)@\(size)" }
}

struct Comparison: Equatable, Sendable {
    enum Status: String, Sendable, Hashable { case ok, regressed, improved, new, missing }
    var key: String
    var unit: String
    var baseline: Double?
    var current: Double?
    var status: Status
}

enum BaselineCompare {
    private struct BaselineFile: Decodable { var metrics: [BaselineMetric] }

    /// §9 CI gate: fails only if more than 20 % slower AND more than 5 ms slower (2 MB for memory).
    static func isRegression(baseline: Double, current: Double, unit: String) -> Bool {
        let absoluteFloor = unit == "MB" ? 2.0 : 5.0
        return current > baseline * 1.2 && current - baseline > absoluteFloor
    }

    static func decodeBaseline(_ data: Data) throws -> [BaselineMetric] {
        try JSONDecoder().decode(BaselineFile.self, from: data).metrics
    }

    static func loadBaseline(_ url: URL) throws -> [BaselineMetric] {
        try decodeBaseline(Data(contentsOf: url))
    }

    static func compare(current: [MetricResult], baseline: [BaselineMetric]) -> [Comparison] {
        let base = Dictionary(baseline.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [Comparison] = current.map { m in
            guard let b = base[m.key] else {
                return Comparison(key: m.key, unit: m.unit, baseline: nil, current: m.median, status: .new)
            }
            let status: Comparison.Status =
                isRegression(baseline: b.median, current: m.median, unit: m.unit) ? .regressed
                : (m.median < b.median * 0.8 ? .improved : .ok)
            return Comparison(key: m.key, unit: m.unit, baseline: b.median, current: m.median, status: status)
        }
        let currentKeys = Set(current.map(\.key))
        var seenMissing = Set<String>()
        for b in baseline where !currentKeys.contains(b.key) && seenMissing.insert(b.key).inserted {
            out.append(Comparison(key: b.key, unit: b.unit ?? "ms", baseline: b.median, current: nil, status: .missing))
        }
        return out
    }

    static func render(_ comparisons: [Comparison]) -> String {
        comparisons.map { c in
            let b = c.baseline.map { Budgets.format($0) } ?? "-"
            let n = c.current.map { Budgets.format($0) } ?? "-"
            return "\(c.status.rawValue.uppercased()) \(c.key): \(b) → \(n) \(c.unit)"
        }.joined(separator: "\n")
    }
}
```

- [ ] **Step 5: Implement the metrics over the real MacxFS/Core paths**

`Sources/macx-bench/Metrics.swift`:

```swift
import AppKit
import Core
import Darwin
import Foundation
import MacxFS

enum BenchFailure: Error, CustomStringConvertible {
    case read(Int32)
    case streamEnded
    case timeout(String)
    var description: String {
        switch self {
        case .read(let code): "directory read failed: errno \(code)"
        case .streamEnded: "read stream ended without .completed"
        case .timeout(let what): "timed out waiting for \(what)"
        }
    }
}

/// Observes a FolderModel and timestamps the events the budgets care about.
@MainActor
final class ModelWatch {
    let model: FolderModel
    private(set) var firstChanges: ContinuousClock.Instant?
    private(set) var loaded: ContinuousClock.Instant?
    private(set) var changeEvents = 0
    private var token: ObserverToken?

    init(model: FolderModel, expectedRows: Int) {
        self.model = model
        let clock = ContinuousClock()
        token = model.observe { [weak self] event in
            guard let self else { return }
            if case .changes = event {
                self.changeEvents += 1
                if self.firstChanges == nil { self.firstChanges = clock.now }
            }
            if self.loaded == nil, self.model.state == .complete, self.model.rowCount == expectedRows {
                self.loaded = clock.now
            }
        }
    }

    func close() {
        token?.cancel()
        token = nil
        model.close()
    }
}

@MainActor
final class MetricSuite {
    let env: CoreEnvironment
    let sandbox: SandboxHandle
    let relativeDir: String
    let directory: URL
    let size: Int
    let options: BenchOptions
    private var fileCount: Int
    private var generation = Generation.initial
    private let clock = ContinuousClock()

    init(env: CoreEnvironment, sandbox: SandboxHandle, relativeDir: String, directory: URL, size: Int, options: BenchOptions) {
        self.env = env
        self.sandbox = sandbox
        self.relativeDir = relativeDir
        self.directory = directory
        self.size = size
        self.options = options
        self.fileCount = size
    }

    private func wants(_ name: String) -> Bool {
        guard let filter = options.metrics else { return true }
        return filter.contains { name.hasPrefix($0) }
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> Double { Stats.milliseconds(clock.now - start) }

    private func samples(_ body: @MainActor () async throws -> Double) async throws -> [Double] {
        try await Stats.sample(warmups: options.warmups, iterations: options.iterations, body)
    }

    private func result(_ name: String, unit: String = "ms", _ samples: [Double]) -> MetricResult {
        MetricResult(name: name, size: size, unit: unit, samples: samples)
    }

    func waitUntil(_ what: String, timeout: Duration, _ condition: () -> Bool) async throws {
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { throw BenchFailure.timeout(what) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private var identityMode: IdentityMode {
        env.volumes.volume(for: directory)?.capabilities.identityMode ?? .objectID
    }

    private var ranks: [UInt16] { env.types.kindRanks().ranks }

    func readStore() async throws -> EntryStore {
        generation = generation.next()
        let reader = env.readers.reader(for: directory)
        var store = EntryStore(identityMode: identityMode)
        for await event in await reader.read(directory, generation: generation) {
            switch event {
            case .batch(let batch): store.append(batch)
            case .completed: return store
            case .failed(let failure): throw BenchFailure.read(failure.code)
            case .stalled, .waitingForPermission, .resumed: continue
            }
        }
        throw BenchFailure.streamEnded
    }

    private func sortedStore() async throws -> EntryStore {
        var store = try await readStore()
        let keys = SortKeys.nameKeys(store, range: 0..<store.count)
        store.setOrder(Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: ViewQuery(), kindRanks: ranks))
        return store
    }

    private func withLoadedModel<T>(_ body: (ModelWatch) async throws -> T) async throws -> T {
        let model = env.makeFolderModel(directory, query: ViewQuery())
        let watch = ModelWatch(model: model, expectedRows: fileCount)
        defer { watch.close() }
        model.start()
        try await waitUntil("\(size)-entry model loads", timeout: .seconds(60)) { watch.loaded != nil }
        return try await body(watch)
    }

    func runAll() async throws -> [MetricResult] {
        var out: [MetricResult] = []

        if wants("enumerate") {
            out.append(result("enumerate", try await samples {
                let start = self.clock.now
                _ = try await self.readStore()
                return self.elapsedMs(since: start)
            }))
        }

        if wants("firstBatch") || wants("listSorted") {
            var first: [Double] = []
            var loaded: [Double] = []
            for i in 0..<(options.warmups + options.iterations) {
                let model = env.makeFolderModel(directory, query: ViewQuery())
                let watch = ModelWatch(model: model, expectedRows: fileCount)
                let start = clock.now
                model.start()
                try await waitUntil("\(size)-entry model loads", timeout: .seconds(60)) {
                    watch.loaded != nil && watch.firstChanges != nil
                }
                if i >= options.warmups, let f = watch.firstChanges, let l = watch.loaded {
                    first.append(Stats.milliseconds(f - start))
                    loaded.append(Stats.milliseconds(l - start))
                }
                watch.close()
            }
            if wants("firstBatch") { out.append(result("firstBatch", first)) }
            if wants("listSorted") { out.append(result("listSorted", loaded)) }
        }

        let needsStore = ["sortkeys", "sort", "resort", "filter", "pasteboard"].contains { wants($0) }
        if needsStore {
            let store = try await readStore()
            let keys = SortKeys.nameKeys(store, range: 0..<store.count)
            let ranks = self.ranks
            if wants("sortkeys") {
                out.append(result("sortkeys", try await samples {
                    let start = self.clock.now
                    let k = SortKeys.nameKeys(store, range: 0..<store.count)
                    withExtendedLifetime(k) {}
                    return self.elapsedMs(since: start)
                }))
            }
            if wants("sort") {
                out.append(result("sort", try await samples {
                    let start = self.clock.now
                    let p = Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: ViewQuery(), kindRanks: ranks)
                    withExtendedLifetime(p) {}
                    return self.elapsedMs(since: start)
                }))
            }
            for field in SortField.allCases where wants("resort.\(field.rawValue)") {
                let query = ViewQuery(sort: SortDescriptor(field: field, ascending: field != .name))
                out.append(result("resort.\(field.rawValue)", try await samples {
                    let start = self.clock.now
                    let p = Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: query, kindRanks: ranks)
                    withExtendedLifetime(p) {}
                    return self.elapsedMs(since: start)
                }))
            }
            if wants("filter") {
                out.append(result("filter", try await samples {
                    let start = self.clock.now
                    let search = SortKeys.searchKeys(store)
                    let p = Sorter.permutation(store, nameKeys: keys, searchKeys: search, query: ViewQuery(filter: "42"), kindRanks: ranks)
                    withExtendedLifetime(p) {}
                    return self.elapsedMs(since: start)
                }))
            }
            if wants("pasteboard") {
                let urls = (0..<store.count).map {
                    directory.appending(path: store.name(UInt32($0)), directoryHint: .notDirectory)
                }
                out.append(result("pasteboard", try await samples {
                    let name = "macx-bench-\(UUID().uuidString)"
                    let board = SystemPasteboard(name: name)
                    let start = self.clock.now
                    board.writeFileURLs(urls, cutMarker: false)
                    let ms = self.elapsedMs(since: start)
                    NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally()
                    return ms
                }))
            }
        }

        if wants("modelResort") {
            let values = try await withLoadedModel { watch in
                var ascending = false
                return try await samples {
                    let before = watch.changeEvents
                    let start = self.clock.now
                    watch.model.setQuery(ViewQuery(sort: SortDescriptor(field: .name, ascending: ascending)))
                    ascending.toggle()
                    try await self.waitUntil("re-sort applied", timeout: .seconds(10)) { watch.changeEvents > before }
                    return self.elapsedMs(since: start)
                }
            }
            out.append(result("modelResort", values))
        }

        if wants("diff") {
            let old = try await sortedStore()
            var new = old
            let touched = max(1, old.count / 100)
            for i in 0..<touched {
                var e = old.entry(UInt32(i))
                e.mtime += 1_000_000_000
                new.upsert(e, name: old.name(UInt32(i)))
            }
            new.remove(Set((0..<(touched / 2)).map { UInt32(old.count - 1 - $0) }))
            let txt = env.types.index(forExtension: "txt", isDirectory: false)
            for i in 0..<(touched / 2) {
                let id = 9_000_000_000 + UInt64(i)
                new.upsert(Entry(rowID: id, fileID: id, size: 1, allocSize: 4_096, mtime: 0, ctime: 0, nameOffset: 0,
                                 nameLen: 0, kind: .file, flags: [.readable, .writable], typeIndex: txt),
                           name: "added-\(i).txt")
            }
            let newKeys = SortKeys.nameKeys(new, range: 0..<new.count)
            new.setOrder(Sorter.permutation(new, nameKeys: newKeys, searchKeys: nil, query: ViewQuery(), kindRanks: ranks))
            out.append(result("diff", try await samples {
                let start = self.clock.now
                let r = StoreDiff.diff(old: old, new: new)
                withExtendedLifetime(r) {}
                return self.elapsedMs(since: start)
            }))
        }

        if wants("memory.steady") {
            out.append(result("memory.steady", unit: "MB", try await samples {
                _ = malloc_zone_pressure_relief(nil, 0)
                let before = Machine.footprintBytes()
                var store = try await self.readStore()
                let keys = SortKeys.nameKeys(store, range: 0..<store.count)
                store.setOrder(Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: ViewQuery(), kindRanks: self.ranks))
                _ = malloc_zone_pressure_relief(nil, 0)
                let after = Machine.footprintBytes()
                withExtendedLifetime((store, keys)) {}
                return Double(after - before) / 1_048_576
            }))
        }

        if wants("fsevent.incremental") {
            let values = try await withLoadedModel { watch in
                try await samples {
                    let name = "inc-\(UUID().uuidString).txt"
                    let start = self.clock.now
                    self.sandbox.file("\(self.relativeDir)/\(name)")
                    self.fileCount += 1
                    try await self.waitUntil("incremental FSEvent applied", timeout: .seconds(10)) {
                        watch.model.row(named: name) != nil
                    }
                    return self.elapsedMs(since: start)
                }
            }
            out.append(result("fsevent.incremental", values))
        }

        if wants("fsevent.full") {
            let values = try await withLoadedModel { watch in
                try await samples {
                    let tag = UUID().uuidString.prefix(8)
                    let start = self.clock.now
                    for i in 0..<300 { self.sandbox.file("\(self.relativeDir)/full-\(tag)-\(i).txt") }
                    self.fileCount += 300
                    let target = self.fileCount
                    try await self.waitUntil("full re-read applied", timeout: .seconds(20)) { watch.model.rowCount == target }
                    return self.elapsedMs(since: start)
                }
            }
            out.append(result("fsevent.full", values))
        }

        return out
    }
}

@MainActor
enum Bench {
    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// Creates ${TMPDIR}/macx-bench-<UUID>, runs every metric per size, destroys the sandbox (unless keepFixtures).
    static func run(_ options: BenchOptions, log: (String) -> Void = { _ in }) async throws -> BenchReport {
        let sandbox = try SandboxHandle.make(prefix: "macx-bench")
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        _ = await env.start()
        log("sandbox: \(sandbox.root.path)")
        var metrics: [MetricResult] = []
        var failure: (any Error)?
        do {
            for size in options.sizes {
                let relative = "work/flat-\(size)"
                log("fixture: \(size) files")
                let directory = sandbox.flat(relative, count: size)
                let suite = MetricSuite(env: env, sandbox: sandbox, relativeDir: relative, directory: directory, size: size, options: options)
                metrics += try await suite.runAll()
            }
        } catch {
            failure = error
        }
        await env.fileOps.waitUntilIdle()
        var removed = false
        if !options.keepFixtures {
            sandbox.destroy()
            removed = !FileManager.default.fileExists(atPath: sandbox.root.path)
            log(removed ? "sandbox root \(sandbox.root.path) removed" : "WARNING: sandbox \(sandbox.root.path) was not removed")
        }
        if let failure { throw failure }
        return BenchReport(machine: .current(), configuration: configuration, warmups: options.warmups,
                           iterations: options.iterations, metrics: metrics, budgets: nil,
                           sandbox: sandbox.root.path, sandboxRemoved: removed)
    }
}
```

- [ ] **Step 6: Implement option parsing, the CLI and the entry point**

`Sources/macx-bench/BenchCLI.swift`:

```swift
import Foundation

enum BenchError: Error, Equatable, CustomStringConvertible {
    case missingValue(String)
    case badValue(String, String)
    case unknownOption(String)
    var description: String {
        switch self {
        case .missingValue(let f): "missing value for \(f)"
        case .badValue(let f, let v): "bad value '\(v)' for \(f)"
        case .unknownOption(let f): "unknown option \(f)"
        }
    }
}

struct BenchOptions: Equatable, Sendable {
    var sizes: [Int] = [1_000, 10_000, 100_000]
    var warmups = 1
    var iterations = 5
    var metrics: Set<String>? = nil
    var output: URL? = nil
    var compare: URL? = nil
    var checkBudgets = false
    var warnBudgets = false
    var allowDebug = false
    var keepFixtures = false

    static func parse(_ args: [String]) throws(BenchError) -> BenchOptions {
        var o = BenchOptions()
        var i = 0
        func value(_ flag: String) throws(BenchError) -> String {
            i += 1
            guard i < args.count else { throw .missingValue(flag) }
            return args[i]
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--sizes":
                let v = try value(flag)
                let parts = v.split(separator: ",", omittingEmptySubsequences: false)
                let sizes = parts.compactMap { Int($0) }
                guard !sizes.isEmpty, sizes.count == parts.count, sizes.allSatisfy({ $0 > 0 }) else { throw .badValue(flag, v) }
                o.sizes = sizes
            case "--warmups":
                let v = try value(flag)
                guard let n = Int(v), n >= 0 else { throw .badValue(flag, v) }
                o.warmups = n
            case "--iterations":
                let v = try value(flag)
                guard let n = Int(v), n >= 1 else { throw .badValue(flag, v) }
                o.iterations = n
            case "--metrics": o.metrics = Set(try value(flag).split(separator: ",").map(String.init))
            case "--output": o.output = URL(filePath: try value(flag))
            case "--compare": o.compare = URL(filePath: try value(flag))
            case "--check-budgets": o.checkBudgets = true
            case "--warn-budgets": o.warnBudgets = true
            case "--allow-debug": o.allowDebug = true
            case "--keep-fixtures": o.keepFixtures = true
            default: throw .unknownOption(flag)
            }
            i += 1
        }
        return o
    }
}

@MainActor
enum BenchCLI {
    static let usage = """
        usage: macx-bench [--sizes 1000,10000,100000] [--warmups 1] [--iterations 5] [--metrics prefix,...]
                          [--output FILE] [--compare BASELINE.json] [--check-budgets] [--warn-budgets]
                          [--allow-debug] [--keep-fixtures]
        """

    static func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func run(_ arguments: [String]) async -> Int32 {
        let options: BenchOptions
        do { options = try BenchOptions.parse(arguments) } catch {
            stderr("macx-bench: \(error)\n\(usage)")
            return 64
        }
        if options.checkBudgets, Bench.configuration == "debug", !options.allowDebug {
            stderr("macx-bench: --check-budgets needs a release build: swift run -c release macx-bench --check-budgets")
            return 3
        }
        if Bench.configuration == "debug" { stderr("macx-bench: WARNING debug build; numbers are not meaningful") }

        var report: BenchReport
        do { report = try await Bench.run(options, log: stderr) } catch {
            stderr("macx-bench: \(error)")
            return 70
        }
        let checks = Budgets.evaluate(report.metrics)
        report.budgets = checks

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            if let output = options.output { try data.write(to: output, options: .atomic) }
            else { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
        } catch {
            stderr("macx-bench: cannot write report: \(error)")
            return 70
        }

        var code: Int32 = 0
        if options.warnBudgets { for line in Budgets.annotations(checks) { print(line) } }
        if let baseline = options.compare {
            do {
                let comparisons = BaselineCompare.compare(current: report.metrics, baseline: try BaselineCompare.loadBaseline(baseline))
                stderr(BaselineCompare.render(comparisons))
                if comparisons.contains(where: { $0.status == .regressed }) { code = 1 }
            } catch {
                stderr("macx-bench: cannot read baseline \(baseline.path): \(error)")
                return 70
            }
        }
        if options.checkBudgets {
            let failed = checks.filter { !$0.passed }
            if !report.machine.appleSilicon {
                stderr("macx-bench: budgets reported but not gated (not Apple Silicon)")
            } else if !failed.isEmpty {
                for f in failed { stderr("OVER BUDGET \(f.metric)@\(f.size): \(Budgets.format(f.median)) \(f.unit) > \(Budgets.format(f.limit)) \(f.unit)") }
                if code == 0 { code = 2 }
            } else {
                stderr("macx-bench: all \(checks.count) budget checks passed")
            }
        }
        return code
    }
}
```

`Sources/macx-bench/main.swift` (replaces the P1-01 stub):

```swift
import Foundation

Task { @MainActor in
    let code = await BenchCLI.run(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
RunLoop.main.run()
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift build 2>&1 | tail -3 && swift test --filter BenchTests 2>&1 | grep -E "error|Executed" | tail -3`
Expected: `Build complete!` with no warnings, then `Executed 23 tests, with 0 failures`. (In a release `swift test -c release` run, the `#if DEBUG` test is compiled out and the count is 22.)

- [ ] **Step 8: Run the real benchmark and look at the output**

```bash
OUT="${TMPDIR%/}/macx-bench-out-$(uuidgen)"; mkdir "$OUT"
swift run -c release macx-bench --output "$OUT/bench.json" --check-budgets; echo "exit=$?"
python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); [print(f"{m["name"]:22} {m["size"]:>7} {m["median"]:9.2f} {m["unit"]}") for m in r["metrics"]]; print("sandboxRemoved", r["sandboxRemoved"])' "$OUT/bench.json"
rm -rf "$OUT"
```

Expected on stderr: `sandbox: …/macx-bench-<UUID>`, `fixture: 1000 files`, `fixture: 10000 files`, `fixture: 100000 files`, then `sandbox root … removed` and either `all 17 budget checks passed` or `OVER BUDGET …` lines.

Expected exit code: `exit=0`, or `exit=2` if a budget is exceeded. An exceeded budget is a real performance bug in the owning task. File it, and do not loosen `Budgets.table`.

Expected table: 3 sizes × 18 metrics, and `sandboxRemoved True`.

Then check the compare gate against itself: `swift run -c release macx-bench --sizes 1000 --output "$OUT/a.json"` followed by `… --sizes 1000 --compare "$OUT/a.json"`. Each line should print `OK`, `IMPROVED` or `REGRESSED`, and the exit code should be 0 unless the machine was busy. Use a fresh `$OUT` as above and delete it afterwards.

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/macx-bench Tests/BenchTests
git commit -m "feat: macx-bench with §4.4 budgets, median/p90 JSON and baseline gate"
```

---

## Task P1-40: `macx-scenarios`, the headless Core scenario runner and catalog

**Spec:** §9 CoreTests list, run here end to end through `CoreEnvironment`, `OperationsCenter`, `ChangeBus`, `FolderModel` and the undo stack:
- every FileOps kind;
- conflict policies (Replace, Skip, Keep Both, Merge, apply-to-all, per-item);
- pause and cancel mid-copy;
- a cross-volume move on a disk image with a simulated kill during copy and during Replace, plus journal cleanup;
- EROFS, ENOSPC and exFAT case-only rename on images;
- directory metadata preservation;
- undo for each kind, including after external changes;
- the stale cut marker.

It also covers the §9 Watcher list (10k burst, atomic save, changes during enumeration, events outside the folder, removed folder) and the §6.3, §6.4 and §6.6 tables. It re-runs Review Focus 1 and 5 from the overview end to end.

**Files:**
- Modify: `Package.swift` (add `ScenarioRunnerTests`, see above)
- Create: `Sources/macx-scenarios/main.swift`, `Sources/macx-scenarios/ScenarioCLI.swift`, `Sources/macx-scenarios/CoreScenario.swift`, `Sources/macx-scenarios/ScenarioContext.swift`, `Sources/macx-scenarios/ScenarioRunner.swift`, `Sources/macx-scenarios/CrashHelper.swift`, `Sources/macx-scenarios/FixtureAdapter.swift`
- Create: `Sources/macx-scenarios/Scenarios/Catalog.swift`, `BrowseScenarios.swift`, `OpsScenarios.swift`, `ConflictScenarios.swift`, `ClipboardScenarios.swift`, `UndoScenarios.swift`, `WatcherScenarios.swift`, `CrossVolumeScenarios.swift`, `CrashScenarios.swift`
- Create: `scripts/run-scenarios.sh`
- Test: `Tests/ScenarioRunnerTests/CatalogTests.swift`, `Tests/ScenarioRunnerTests/CLITests.swift`, `Tests/ScenarioRunnerTests/RunnerTests.swift`

**Interfaces:**
- Consumes (overview §3, exact names):
  - `CoreEnvironment.sandboxed(root:)` with `start()`, `makeFolderModel(_:query:)`, `.operations`, `.undo`, `.fileOps`, `.lanes`, `.volumes`, `.journal`, `.interaction`
  - `OperationsCenter.perform(_:) async -> JobOutcome`, `OperationsCenter.onFinished(_:)`
  - `FileOpUndoStack.undoManager`, `.canUndo`, `.canRedo`
  - `FileOpQueue(lanes:trash:journal:interaction:tuning:)` with `enqueue`, `outcome(of:)`, `pause`, `resume`, `cancel`, `cancelAll`, `snapshots`
  - `FileOpTuning(progressInterval:copyChunkBytes:faultHook:)`, `FaultPoint`
  - `ScriptedInteraction(conflicts:errors:space:noTrash:)` with `askedConflicts()`, `askedErrors()`
  - `InteractionProxy.setTarget(_:)`, `SandboxTrash(directory:)`, `Journal(fileURL:)`, `LaunchRecovery.run(journal:lanes:)`, `RecoveryReport`
  - `JobKind` (all 13 cases), `JobRequest`, `JobOutcome`, `SkippedItem`, `ItemAction`, `FileOpErrorKind`, `ModeChange`, `AttributeEdit`, `NewItemKind`, `ConflictResolution`, `ConflictAction`
  - `FolderModel` (`start`, `close`, `state`, `rowCount`, `name(atRow:)`, `row(named:)`, `entry(atRow:)`, `identity(atRow:)`, `select(_:)`, `selection`, `selectedURLs`, `setQuery(_:)`, `observe(_:)`), `FolderEvent`, `RelocationReason`, `ChangeSet`, `Change`
  - `Clipboard(backend:)`, `InMemoryPasteboard` (`simulateExternalCopy`, `hasCutMarker`, `hasFileURLs`), `PastePlan`
  - `Volumes.refresh()`, `ViewQuery`
  - From P1-02 (assumed): `Sandbox`, `DiskImage`, `FixtureTree`.
- Produces (internal to `macx_scenarios`):
  - `struct CoreScenario { name, requires: Requirement, timeout, body: @MainActor @Sendable (ScenarioContext) async throws -> Void }`. The file map says "scenario protocol"; a closure-carrying struct keeps each scenario to a few lines.
  - `@MainActor final class ScenarioContext` (helpers listed in the code).
  - `struct ScenarioFailure: Error`, `struct ScenarioSkip: Error`
  - `enum Deadline { wait(for:timeout:), run(_:_:) }`
  - `@MainActor enum ScenarioRunner { runOne(_:helper:requireImages:keepSandbox:) async -> ScenarioResult; run(_:helper:requireImages:keepSandbox:log:) async -> RunReport }`
  - `enum Catalog { static let all: [CoreScenario]; static func select(_ filter: String?) -> [CoreScenario] }`
  - `struct ScenarioCLIOptions`, `struct CrashHelperOptions`, `enum CrashHelper { isInsideScenarioSandbox(_:); run(_:) async -> Int32 }`
- **CLI contract** (used by `run-scenarios.sh` and CI):
  - `macx-scenarios [--list] [--filter <substring>] [--json <report.json>] [--keep-sandbox] [--require-images]` exits 0 when every selected scenario passed (or skipped without `--require-images`), 1 on any failure, 64 on usage errors.
  - `macx-scenarios crash-helper --mode copy|replace --source P --destination P --journal P --trash P --ready P` is internal. It refuses (exit 64) any path without a `macx-scenario-*` ancestor.
  - Report JSON: `{"results":[{"name","status":"passed|failed|skipped","message"?,"durationMs","sandbox","sandboxRemoved"}],"passed","failed","skipped"}`.

- [ ] **Step 1: Add the test target and write the failing tests**

Add the `ScenarioRunnerTests` line to `Package.swift`.

`Tests/ScenarioRunnerTests/CatalogTests.swift`:

```swift
import XCTest
@testable import macx_scenarios

final class CatalogTests: XCTestCase {
    func testNamesAreUniqueAndWellFormed() {
        let names = Catalog.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate scenario names")
        for name in names {
            XCTAssertNotNil(name.range(of: #"^[a-z]+\.[A-Za-z0-9]+$"#, options: .regularExpression), name)
        }
        XCTAssertGreaterThanOrEqual(names.count, 45)
    }

    func testEveryFamilyIsPresent() {
        let families = Set(Catalog.all.map { String($0.name.split(separator: ".")[0]) })
        XCTAssertEqual(families, ["browse", "ops", "conflict", "clip", "undo", "watch", "xvol", "crash"])
    }

    func testEveryJobKindIsExercised() {
        for needle in ["copy", "move", "trash", "delete", "duplicate", "newItems", "rename", "alias", "symlink", "chmod", "setAttributes"] {
            XCTAssertTrue(Catalog.all.contains { $0.name.lowercased().contains(needle.lowercased()) }, needle)
        }
    }

    func testFilterSelectsBySubstring() {
        XCTAssertEqual(Catalog.select(nil).count, Catalog.all.count)
        XCTAssertFalse(Catalog.select("clip.").isEmpty)
        XCTAssertTrue(Catalog.select("clip.").allSatisfy { $0.name.hasPrefix("clip.") })
        XCTAssertTrue(Catalog.select("no-such-scenario").isEmpty)
    }

    func testRequirementsAreDeclared() {
        for s in Catalog.all where s.name.hasPrefix("xvol.") { XCTAssertEqual(s.requires, .diskImages, s.name) }
        for s in Catalog.all where s.name.hasPrefix("crash.") { XCTAssertEqual(s.requires, .helperProcess, s.name) }
    }
}
```

`Tests/ScenarioRunnerTests/CLITests.swift`:

```swift
import XCTest
@testable import macx_scenarios

final class CLITests: XCTestCase {
    func testParsesOptions() throws {
        let o = try ScenarioCLIOptions.parse(["--filter", "ops.", "--json", "/tmp/macx-scenario-x/r.json", "--keep-sandbox", "--require-images", "--list"])
        XCTAssertEqual(o.filter, "ops.")
        XCTAssertEqual(o.json?.lastPathComponent, "r.json")
        XCTAssertTrue(o.keepSandbox && o.requireImages && o.list)
    }

    func testRejectsUnknownOptionsAndMissingValues() {
        XCTAssertThrowsError(try ScenarioCLIOptions.parse(["--nope"])) { XCTAssertEqual($0 as? ScenarioCLIError, .unknownOption("--nope")) }
        XCTAssertThrowsError(try ScenarioCLIOptions.parse(["--filter"])) { XCTAssertEqual($0 as? ScenarioCLIError, .missingValue("--filter")) }
    }

    func testCrashHelperRefusesPathsOutsideScenarioSandboxes() {
        XCTAssertFalse(CrashHelper.isInsideScenarioSandbox("/Library/someone/file.txt"))
        XCTAssertFalse(CrashHelper.isInsideScenarioSandbox("/tmp/other/file"))
        XCTAssertFalse(CrashHelper.isInsideScenarioSandbox("/tmp/macx-scenario-1/../../etc/hosts"))
        XCTAssertFalse(CrashHelper.isInsideScenarioSandbox("relative/macx-scenario-1/a"))
        XCTAssertTrue(CrashHelper.isInsideScenarioSandbox("/private/var/folders/x/T/macx-scenario-1234/work/a.txt"))
    }

    func testCrashHelperOptionParsing() throws {
        let base = "/tmp/macx-scenario-1"
        let o = try CrashHelperOptions.parse(["--mode", "replace", "--source", "\(base)/s", "--destination", "\(base)/d",
                                              "--journal", "\(base)/j.json", "--trash", "\(base)/t", "--ready", "\(base)/r"])
        XCTAssertEqual(o.mode, .replace)
        XCTAssertEqual(o.allPaths.count, 5)
        XCTAssertThrowsError(try CrashHelperOptions.parse(["--mode", "copy"])) { XCTAssertEqual($0 as? ScenarioCLIError, .missingOption("--source")) }
        XCTAssertThrowsError(try CrashHelperOptions.parse(["--mode", "explode"]))
    }
}
```

`Tests/ScenarioRunnerTests/RunnerTests.swift`:

```swift
import XCTest
import Darwin
@testable import macx_scenarios

@MainActor final class PathBox { var path: String? }

@MainActor
final class RunnerTests: XCTestCase {
    func testPassingScenarioCleansItsSandbox() async throws {
        let box = PathBox()
        let scenario = CoreScenario("test.pass") { ctx in
            box.path = ctx.sandbox.root.path
            ctx.file("a.txt")
        }
        let r = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: false, keepSandbox: false)
        XCTAssertEqual(r.status, .passed, r.message ?? "")
        XCTAssertTrue(r.sandboxRemoved)
        let path = try XCTUnwrap(box.path)
        XCTAssertTrue(URL(filePath: path).lastPathComponent.hasPrefix("macx-scenario-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFailingScenarioReportsMessageAndStillCleansUp() async {
        let scenario = CoreScenario("test.fail") { ctx in
            let locked = ctx.file("locked.txt")
            try ctx.setFlags(locked, UInt32(UF_IMMUTABLE))
            let closed = ctx.dir("closed")
            ctx.file("closed/inner.txt")
            try ctx.setMode(closed, 0o000)
            throw ScenarioFailure("boom")
        }
        let r = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: false, keepSandbox: false)
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(r.message?.contains("boom") ?? false)
        XCTAssertTrue(r.sandboxRemoved, "uchg file and 000 folder must not block cleanup")
    }

    func testTimedOutScenarioIsCancelledAndCleanedUp() async {
        let scenario = CoreScenario("test.hang", timeout: .milliseconds(300)) { _ in
            try await Task.sleep(for: .seconds(3_600))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let r = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: false, keepSandbox: false)
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(r.message?.contains("timed out") ?? false, r.message ?? "")
        XCTAssertTrue(r.sandboxRemoved)
        XCTAssertLessThan(clock.now - start, .seconds(30))
    }

    func testSkipBecomesFailureWhenImagesAreRequired() async {
        let scenario = CoreScenario("test.skip") { _ in throw ScenarioSkip("hdiutil missing") }
        let lenient = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: false, keepSandbox: false)
        let strict = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: true, keepSandbox: false)
        XCTAssertEqual(lenient.status, .skipped)
        XCTAssertEqual(strict.status, .failed)
    }

    func testImagesAreDetachedWhenScenarioThrows() async throws {
        guard SandboxHandle.imagesAvailable else { throw XCTSkip("hdiutil unavailable") }
        let box = PathBox()
        let scenario = CoreScenario("test.imageThrow", requires: .diskImages) { ctx in
            let image = try await ctx.image("t", .apfs, sizeMB: 16)
            box.path = image.mountPoint.path
            throw ScenarioFailure("after mount")
        }
        let r = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: true, keepSandbox: false)
        XCTAssertEqual(r.status, .failed)
        XCTAssertFalse(ScenarioContext.isMounted(try XCTUnwrap(box.path)))
        XCTAssertTrue(r.sandboxRemoved, "a still-mounted image would block removal")
    }

    func testRealCatalogSubsetPasses() async {
        let selected = Catalog.select("ops.copyTree") + Catalog.select("clip.") + Catalog.select("undo.copy") + Catalog.select("browse.hidden")
        let report = await ScenarioRunner.run(selected, helper: nil, requireImages: false, keepSandbox: false) { _ in }
        XCTAssertEqual(report.failed, 0, report.results.filter { $0.status == .failed }.map { "\($0.name): \($0.message ?? "")" }.joined(separator: "\n"))
        XCTAssertTrue(report.results.allSatisfy(\.sandboxRemoved))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ScenarioRunnerTests 2>&1 | grep -E "error:|Executed" | head -5`
Expected: `error: cannot find 'Catalog' in scope` (and similar).

- [ ] **Step 3: Implement the fixture adapter, scenario type, deadline helper and context**

`Sources/macx-scenarios/FixtureAdapter.swift`:

```swift
import Darwin
import Foundation
import MacxFixtures

/// The ONLY file in macx-scenarios that names MacxFixtures (P1-02) types. If P1-02 shipped different
/// names, adapt this file only (Contract note C1).
enum ImageFormat: Sendable { case apfs, hfsPlus, exfat, msdos }

struct ImageHandle: Sendable {
    fileprivate let image: DiskImage
    var mountPoint: URL { image.mountPoint }
    func detach() throws { try image.detach() }
}

struct SandboxHandle: Sendable {
    fileprivate let sandbox: Sandbox
    var root: URL { sandbox.root }

    static func make(prefix: String) throws -> SandboxHandle { SandboxHandle(sandbox: try Sandbox(prefix: prefix)) }
    static var imagesAvailable: Bool { DiskImage.isAvailable }

    func url(_ relative: String) -> URL { sandbox.url(relative) }
    func contains(_ url: URL) -> Bool { sandbox.contains(url) }

    /// Path of `url` relative to `root`; traps outside the sandbox.
    func relative(_ url: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        precondition(p.hasPrefix(r + "/"), "outside sandbox: \(p)")
        return String(p.dropFirst(r.count + 1))
    }

    @discardableResult func dir(_ relative: String) -> URL { fixtureWrite(relative) { try sandbox.createDirectory(relative) } }
    /// Creates the file, or replaces its contents if it already exists (Sandbox.createFile is O_EXCL;
    /// watcher scenarios rewrite files in place).
    @discardableResult func file(_ relative: String, _ contents: Data = Data("x".utf8)) -> URL {
        fixtureWrite(relative) {
            let url = sandbox.url(relative)
            var st = stat()
            if lstat(url.path(percentEncoded: false), &st) == 0 {
                try sandbox.overwrite(relative, contents: contents)
                return url
            }
            return try sandbox.createFile(relative, contents: contents)
        }
    }
    @discardableResult func flat(_ relative: String, count: Int) -> URL {
        fixtureWrite(relative) { try FixtureTree.flat(in: sandbox, at: relative, count: count) }
    }

    /// `name` labels the volume ("MACX" + up to 7 upper-case alphanumerics, valid for every format
    /// including MS-DOS); S1 picks the image file and mount point names itself (`img-<id>.dmg`, `mnt-<id>`).
    func image(_ name: String, _ format: ImageFormat, sizeMB: Int, readOnly: Bool) throws -> ImageHandle {
        let f: DiskImageFormat = switch format {
        case .apfs: .apfs
        case .hfsPlus: .hfsPlus
        case .exfat: .exfat
        case .msdos: .msdos
        }
        let label = "MACX" + String(name.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(7))
        return ImageHandle(image: try DiskImage.create(in: sandbox, format: f, sizeMB: sizeMB, volumeName: label, readOnly: readOnly))
    }

    /// Clears BSD flags and gives u+rwx to every directory under root (never follows symlinks), so a
    /// fixture with uchg files or mode-000 folders can always be removed.
    func makeWritable() {
        func visit(_ path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            _ = lchflags(path, 0)
            guard (st.st_mode & 0o170000) == 0o040000 else { return }
            _ = chmod(path, 0o755)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { visit(path + "/" + name) }
        }
        precondition(root.lastPathComponent.hasPrefix("macx-"), "refusing to touch \(root.path)")
        visit(root.path)
    }

    func destroy() { sandbox.destroy() }
}

/// A fixture write inside a fresh sandbox only fails when the environment is broken (disk full,
/// unwritable TMPDIR). The runner stops with the path and reason; run-scenarios.sh's EXIT trap
/// still detaches images and removes the run directory.
func fixtureWrite<T>(_ relative: String, _ body: () throws -> T) -> T {
    do { return try body() } catch { preconditionFailure("fixture write '\(relative)' failed: \(error)") }
}
```

`Sources/macx-scenarios/CoreScenario.swift`:

```swift
import Core
import Darwin
import Foundation

struct ScenarioFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ScenarioSkip: Error, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { "skipped: \(reason)" }
}

struct CoreScenario: Sendable {
    enum Requirement: Sendable, Equatable { case none, diskImages, helperProcess }
    let name: String
    let requires: Requirement
    let timeout: Duration
    let body: @MainActor @Sendable (ScenarioContext) async throws -> Void

    init(_ name: String, requires: Requirement = .none, timeout: Duration = .seconds(60),
         _ body: @escaping @MainActor @Sendable (ScenarioContext) async throws -> Void) {
        self.name = name
        self.requires = requires
        self.timeout = timeout
        self.body = body
    }
}

enum Deadline {
    /// Waits for `task` up to `timeout`. nil on timeout (the task keeps running; the caller decides).
    static func wait<T: Sendable>(for task: Task<T, Never>, timeout: Duration) async -> T? {
        let (stream, continuation) = AsyncStream<T?>.makeStream()
        let waiter = Task { continuation.yield(await task.value) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(nil)
        }
        defer {
            waiter.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await value in stream { return value }
        return nil
    }

    static func run<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await wait(for: Task { await operation() }, timeout: timeout)
    }
}

extension FileOpTuning {
    /// 256 KiB chunks with a 3 ms pause each: a 64 MiB copy takes about 0.8 s, so pause/cancel land mid-file.
    static var slowChunks: FileOpTuning {
        FileOpTuning(copyChunkBytes: 256 << 10, faultHook: { point, _ in
            if point == .midCopyChunk { usleep(3_000) }
        })
    }
}
```

`Sources/macx-scenarios/ScenarioContext.swift`:

```swift
import Core
import Darwin
import Foundation
import MacxFS

@MainActor final class OutcomeBox { var value: JobOutcome? }

@MainActor
final class ScenarioContext {
    let name: String
    let sandbox: SandboxHandle
    let env: CoreEnvironment
    /// Fixtures live here, so CoreEnvironment.sandboxed's root/.trash and root/state never show up in listings.
    let work: URL
    let helperExecutable: URL?
    private var images: [ImageHandle] = []
    private var models: [FolderModel] = []
    private var tokens: [ObserverToken] = []
    private var queues: [FileOpQueue] = []
    private var helpers: [Process] = []

    init(name: String, sandbox: SandboxHandle, helperExecutable: URL?) {
        self.name = name
        self.sandbox = sandbox
        self.helperExecutable = helperExecutable
        self.env = CoreEnvironment.sandboxed(root: sandbox.root)
        self.work = sandbox.dir("work")
    }

    // MARK: fixtures (writes only through the sandbox or on sandbox-derived paths)

    func path(_ rel: String) -> URL { sandbox.url("work/\(rel)") }
    @discardableResult func file(_ rel: String, _ text: String = "x") -> URL { sandbox.file("work/\(rel)", Data(text.utf8)) }
    @discardableResult func file(_ rel: String, bytes: Int) -> URL { sandbox.file("work/\(rel)", Data(count: bytes)) }
    @discardableResult func file(at url: URL, _ text: String = "x") -> URL { sandbox.file(sandbox.relative(url), Data(text.utf8)) }
    @discardableResult func dir(_ rel: String) -> URL { sandbox.dir("work/\(rel)") }
    @discardableResult func dir(at url: URL) -> URL { sandbox.dir(sandbox.relative(url)) }
    @discardableResult func flat(_ rel: String, count: Int) -> URL { sandbox.flat("work/\(rel)", count: count) }

    private func guarded(_ url: URL) -> String {
        precondition(sandbox.contains(url), "outside sandbox: \(url.path)")
        return url.path
    }

    func setFlags(_ url: URL, _ flags: UInt32) throws {
        guard chflags(guarded(url), flags) == 0 else { throw ScenarioFailure("chflags \(url.lastPathComponent): errno \(errno)") }
    }
    func setMode(_ url: URL, _ mode: mode_t) throws {
        guard chmod(guarded(url), mode) == 0 else { throw ScenarioFailure("chmod \(url.lastPathComponent): errno \(errno)") }
    }
    func setModificationDate(_ url: URL, _ date: Date) throws {
        let t = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        var times = [t, t]
        guard utimensat(AT_FDCWD, guarded(url), &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw ScenarioFailure("utimensat: errno \(errno)") }
    }
    func setXattr(_ url: URL, _ name: String, _ value: String) throws {
        let path = guarded(url)
        let r = value.withCString { setxattr(path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        guard r == 0 else { throw ScenarioFailure("setxattr: errno \(errno)") }
    }
    func symlink(_ rel: String, to target: String) throws {
        guard Darwin.symlink(target, guarded(path(rel))) == 0 else { throw ScenarioFailure("symlink: errno \(errno)") }
    }
    func renameRaw(_ from: URL, to: URL) throws {
        guard Darwin.rename(guarded(from), guarded(to)) == 0 else { throw ScenarioFailure("rename: errno \(errno)") }
    }
    func removeRaw(_ url: URL) throws {
        guard unlink(guarded(url)) == 0 else { throw ScenarioFailure("unlink: errno \(errno)") }
    }
    func removeTreeRaw(_ url: URL) throws {
        _ = guarded(url)
        try FileManager.default.removeItem(at: url)
    }
    func background(_ work: @escaping @Sendable () -> Void) async { await Task.detached(operation: work).value }

    // MARK: reads (harness-side, read-only)

    private func lstatOf(_ url: URL) -> stat? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st : nil
    }
    func exists(_ url: URL) -> Bool { lstatOf(url) != nil }
    func size(_ url: URL) -> Int64? { lstatOf(url).map { Int64($0.st_size) } }
    func isDirectory(_ url: URL) -> Bool { lstatOf(url).map { ($0.st_mode & 0o170000) == 0o040000 } ?? false }
    func mode(_ url: URL) -> mode_t? { lstatOf(url).map { $0.st_mode & 0o7777 } }
    func flags(_ url: URL) -> UInt32 { lstatOf(url)?.st_flags ?? 0 }
    func inode(_ url: URL) -> UInt64? { lstatOf(url).map { UInt64($0.st_ino) } }
    func mtimeSeconds(_ url: URL) -> Int? { lstatOf(url).map { $0.st_mtimespec.tv_sec } }
    func readLink(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let n = readlink(url.path, &buffer, buffer.count - 1)
        guard n >= 0 else { return nil }
        return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func xattr(_ url: URL, _ name: String) -> String? {
        let n = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard n >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: n)
        guard getxattr(url.path, name, &buffer, n, 0, XATTR_NOFOLLOW) == n else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
    func entries(_ dir: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) }
    func isAliasFile(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true }
    func resolveAlias(_ url: URL) -> URL? { try? URL(resolvingAliasFileAt: url) }

    static func isMounted(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: s.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == URL(filePath: path).resolvingSymlinksInPath().path
    }

    // MARK: models

    func track(_ model: FolderModel) { models.append(model) }
    func keep(_ token: ObserverToken) { tokens.append(token) }
    func names(_ model: FolderModel) -> [String] { (0..<model.rowCount).map { model.name(atRow: $0) } }

    func open(_ dir: URL, query: ViewQuery = ViewQuery(), timeout: Duration = .seconds(15)) async throws -> FolderModel {
        let model = env.makeFolderModel(dir, query: query)
        track(model)
        model.start()
        try await waitUntil("\(dir.lastPathComponent) finishes loading", timeout: timeout) {
            model.state != .loading && model.state != .partial
        }
        return model
    }

    func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { throw ScenarioFailure("timed out after \(timeout) waiting for: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitUntilAsync(_ what: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now >= deadline { throw ScenarioFailure("timed out after \(timeout) waiting for: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: jobs

    func setInteraction(_ interaction: ScriptedInteraction) { env.interaction.setTarget(interaction) }
    func perform(_ kind: JobKind) async -> JobOutcome { await env.operations.perform(JobRequest(kind)) }

    func undo() async throws -> JobOutcome {
        try expect(env.undo.canUndo, "nothing to undo")
        return try await nextFinished { self.env.undo.undoManager.undo() }
    }

    func redo() async throws -> JobOutcome {
        try expect(env.undo.canRedo, "nothing to redo")
        return try await nextFinished { self.env.undo.undoManager.redo() }
    }

    private func nextFinished(_ trigger: () -> Void) async throws -> JobOutcome {
        let box = OutcomeBox()
        let token = env.operations.onFinished { _, outcome in
            if box.value == nil { box.value = outcome }
        }
        defer { token.cancel() }
        trigger()
        try await waitUntil("the undo/redo job finishes", timeout: .seconds(20)) { box.value != nil }
        return try unwrap(box.value, "undo/redo outcome")
    }

    /// A queue of our own (custom trash/tuning) for disk-image scenarios; journal inside the sandbox.
    func makeQueue(trash: URL, interaction: any FileOpInteraction, tuning: FileOpTuning = FileOpTuning()) -> FileOpQueue {
        let journal = Journal(fileURL: sandbox.dir("queue-state").appending(path: "\(UUID().uuidString).json"))
        let queue = FileOpQueue(lanes: env.lanes, trash: SandboxTrash(directory: trash), journal: journal,
                                interaction: interaction, tuning: tuning)
        queues.append(queue)
        return queue
    }

    func run(_ queue: FileOpQueue, _ kind: JobKind) async -> JobOutcome {
        let id = await queue.enqueue(JobRequest(kind, registersUndo: false))
        return await queue.outcome(of: id)
    }

    // MARK: images and helper processes

    func image(_ name: String, _ format: ImageFormat, sizeMB: Int, readOnly: Bool = false) async throws -> ImageHandle {
        guard SandboxHandle.imagesAvailable else { throw ScenarioSkip("hdiutil is not available") }
        let image = try sandbox.image(name, format, sizeMB: sizeMB, readOnly: readOnly)
        images.append(image)
        await env.volumes.refresh()
        return image
    }

    func requireHelper() throws -> URL {
        guard let helper = helperExecutable, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ScenarioSkip("the macx-scenarios executable is not available as a crash helper")
        }
        return helper
    }

    func launchHelper(_ executable: URL, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        helpers.append(process)
        return process
    }

    // MARK: assertions

    func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String,
                file: StaticString = #fileID, line: UInt = #line) throws {
        if !condition() { throw ScenarioFailure("\(message()) (\(file):\(line))") }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String, file: StaticString = #fileID, line: UInt = #line) throws {
        if actual != expected { throw ScenarioFailure("\(what): expected \(expected), got \(actual) (\(file):\(line))") }
    }

    func unwrap<T>(_ value: T?, _ what: String, file: StaticString = #fileID, line: UInt = #line) throws -> T {
        guard let value else { throw ScenarioFailure("\(what) is nil (\(file):\(line))") }
        return value
    }

    // MARK: teardown

    func closeAll() {
        for model in models { model.close() }
        models.removeAll()
        for token in tokens { token.cancel() }
        tokens.removeAll()
    }

    /// Closes models, cancels every job, kills helpers, detaches images, clears protections, deletes the sandbox.
    /// Returns true if the sandbox root no longer exists.
    func cleanup() async -> Bool {
        closeAll()
        let main = env.fileOps
        _ = await Deadline.run(.seconds(10)) { await main.cancelAll() }
        for queue in queues { _ = await Deadline.run(.seconds(10)) { await queue.cancelAll() } }
        queues.removeAll()
        for process in helpers where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        helpers.removeAll()
        for image in images.reversed() {
            do { try image.detach() } catch {
                try? await Task.sleep(for: .milliseconds(500))
                try? image.detach()
            }
        }
        images.removeAll()
        sandbox.makeWritable()
        sandbox.destroy()
        return !FileManager.default.fileExists(atPath: sandbox.root.path)
    }
}
```

- [ ] **Step 4: Implement the runner, the CLI, the crash helper and the entry point**

`Sources/macx-scenarios/ScenarioRunner.swift`:

```swift
import Foundation

struct ScenarioResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case passed, failed, skipped }
    var name: String
    var status: Status
    var message: String?
    var durationMs: Int
    var sandbox: String
    var sandboxRemoved: Bool
}

struct RunReport: Codable, Equatable, Sendable {
    var results: [ScenarioResult]
    var passed: Int
    var failed: Int
    var skipped: Int
}

enum ScenarioOutcome: Sendable, Equatable { case passed, skipped(String), failed(String) }

@MainActor
enum ScenarioRunner {
    static func runOne(_ scenario: CoreScenario, helper: URL?, requireImages: Bool, keepSandbox: Bool) async -> ScenarioResult {
        let clock = ContinuousClock()
        let start = clock.now
        let sandbox: SandboxHandle
        do { sandbox = try SandboxHandle.make(prefix: "macx-scenario") } catch {
            return ScenarioResult(name: scenario.name, status: .failed, message: "cannot create sandbox: \(error)",
                                  durationMs: 0, sandbox: "", sandboxRemoved: true)
        }
        let ctx = ScenarioContext(name: scenario.name, sandbox: sandbox, helperExecutable: helper)
        _ = await ctx.env.start()

        let task = Task { @MainActor () -> ScenarioOutcome in
            do {
                try await scenario.body(ctx)
                return .passed
            } catch let skip as ScenarioSkip {
                return .skipped(skip.reason)
            } catch {
                return .failed(String(describing: error))
            }
        }
        var outcome = await Deadline.wait(for: task, timeout: scenario.timeout)
        var stopped = true
        if outcome == nil {
            task.cancel()
            let queue = ctx.env.fileOps
            _ = await Deadline.run(.seconds(10)) { await queue.cancelAll() }
            stopped = await Deadline.wait(for: task, timeout: .seconds(5)) != nil
            outcome = .failed("timed out after \(scenario.timeout)"
                              + (stopped ? "" : "; the scenario did not stop, sandbox kept at \(sandbox.root.path)"))
        }

        var removed = false
        if stopped && !keepSandbox { removed = await ctx.cleanup() } else { ctx.closeAll() }

        let elapsed = (clock.now - start).components
        let ms = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let (status, message): (ScenarioResult.Status, String?) = switch outcome ?? .failed("no outcome") {
        case .passed: (.passed, nil)
        case .skipped(let reason): requireImages ? (.failed, "required but skipped: \(reason)") : (.skipped, reason)
        case .failed(let message): (.failed, message)
        }
        return ScenarioResult(name: scenario.name, status: status, message: message, durationMs: ms,
                              sandbox: sandbox.root.path, sandboxRemoved: removed)
    }

    static func run(_ scenarios: [CoreScenario], helper: URL?, requireImages: Bool, keepSandbox: Bool,
                    log: (String) -> Void) async -> RunReport {
        var results: [ScenarioResult] = []
        for scenario in scenarios {
            let r = await runOne(scenario, helper: helper, requireImages: requireImages, keepSandbox: keepSandbox)
            results.append(r)
            switch r.status {
            case .passed: log("PASS \(r.name) (\(r.durationMs) ms)")
            case .skipped: log("SKIP \(r.name): \(r.message ?? "")")
            case .failed: log("FAIL \(r.name): \(r.message ?? "")")
            }
            log(r.sandboxRemoved ? "  sandbox \(r.sandbox) removed" : "  sandbox \(r.sandbox) KEPT")
            if r.status == .failed && !r.sandboxRemoved && !keepSandbox {
                log("ABORT: \(r.name) left its sandbox in use; not running further scenarios")
                break
            }
        }
        return RunReport(results: results,
                         passed: results.filter { $0.status == .passed }.count,
                         failed: results.filter { $0.status == .failed }.count,
                         skipped: results.filter { $0.status == .skipped }.count)
    }
}
```

`Sources/macx-scenarios/ScenarioCLI.swift`:

```swift
import AppKit
import Foundation

enum ScenarioCLIError: Error, Equatable, CustomStringConvertible {
    case missingValue(String), unknownOption(String), missingOption(String), badValue(String, String)
    var description: String {
        switch self {
        case .missingValue(let f): "missing value for \(f)"
        case .unknownOption(let f): "unknown option \(f)"
        case .missingOption(let f): "missing required option \(f)"
        case .badValue(let f, let v): "bad value '\(v)' for \(f)"
        }
    }
}

struct ScenarioCLIOptions: Equatable, Sendable {
    var list = false
    var filter: String? = nil
    var json: URL? = nil
    var keepSandbox = false
    var requireImages = false
    var printGeneralChangeCount = false

    static func parse(_ args: [String]) throws(ScenarioCLIError) -> ScenarioCLIOptions {
        var o = ScenarioCLIOptions()
        var i = 0
        func value(_ flag: String) throws(ScenarioCLIError) -> String {
            i += 1
            guard i < args.count else { throw .missingValue(flag) }
            return args[i]
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--list": o.list = true
            case "--filter": o.filter = try value(flag)
            case "--json": o.json = URL(filePath: try value(flag))
            case "--keep-sandbox": o.keepSandbox = true
            case "--require-images": o.requireImages = true
            case "--general-pasteboard-changecount": o.printGeneralChangeCount = true
            default: throw .unknownOption(flag)
            }
            i += 1
        }
        return o
    }
}

@MainActor
enum ScenarioCLI {
    static func main(_ args: [String]) async -> Int32 {
        if args.first == "crash-helper" { return await CrashHelper.run(Array(args.dropFirst())) }
        let options: ScenarioCLIOptions
        do { options = try ScenarioCLIOptions.parse(args) } catch {
            FileHandle.standardError.write(Data("macx-scenarios: \(error)\n".utf8))
            return 64
        }
        if options.printGeneralChangeCount {
            // Read-only: verify-phase1.sh compares this before/after a full run (nothing may write the general pasteboard).
            print(NSPasteboard.general.changeCount)
            return 0
        }
        let selected = Catalog.select(options.filter)
        if options.list {
            for s in selected { print(s.name) }
            return 0
        }
        guard !selected.isEmpty else {
            FileHandle.standardError.write(Data("macx-scenarios: no scenario matches '\(options.filter ?? "")'\n".utf8))
            return 64
        }
        let report = await ScenarioRunner.run(selected, helper: Bundle.main.executableURL, requireImages: options.requireImages,
                                              keepSandbox: options.keepSandbox) { print($0) }
        if let json = options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: json, options: .atomic)
        }
        print("macx-scenarios: \(report.passed) passed, \(report.failed) failed, \(report.skipped) skipped")
        return report.failed == 0 ? 0 : 1
    }
}
```

`Sources/macx-scenarios/CrashHelper.swift`:

```swift
import Core
import Darwin
import Foundation
import MacxFS

struct CrashHelperOptions: Equatable, Sendable {
    enum Mode: String, Sendable { case copy, replace }
    var mode: Mode
    var source: URL
    var destination: URL
    var journal: URL
    var trash: URL
    var ready: URL
    var allPaths: [String] { [source, destination, journal, trash, ready].map(\.path) }

    static func parse(_ args: [String]) throws(ScenarioCLIError) -> CrashHelperOptions {
        var values: [String: String] = [:]
        var i = 0
        while i < args.count {
            let flag = args[i]
            guard ["--mode", "--source", "--destination", "--journal", "--trash", "--ready"].contains(flag) else { throw .unknownOption(flag) }
            guard i + 1 < args.count else { throw .missingValue(flag) }
            values[flag] = args[i + 1]
            i += 2
        }
        func need(_ flag: String) throws(ScenarioCLIError) -> String {
            guard let v = values[flag] else { throw .missingOption(flag) }
            return v
        }
        let modeText = try need("--mode")
        guard let mode = Mode(rawValue: modeText) else { throw .badValue("--mode", modeText) }
        return CrashHelperOptions(mode: mode, source: URL(filePath: try need("--source")),
                                  destination: URL(filePath: try need("--destination")),
                                  journal: URL(filePath: try need("--journal")), trash: URL(filePath: try need("--trash")),
                                  ready: URL(filePath: try need("--ready")))
    }
}

/// Child process for the crash scenarios: runs one cross-volume move and blocks forever at the fault point
/// (after writing the ready marker) so the parent can SIGKILL it mid-operation.
@MainActor
enum CrashHelper {
    /// True only for absolute paths that, after standardization, have a `macx-scenario-*` ancestor.
    nonisolated static func isInsideScenarioSandbox(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let standardized = URL(filePath: path).standardized.path
        return standardized.split(separator: "/").dropLast().contains { $0.hasPrefix("macx-scenario-") }
    }

    static func run(_ args: [String]) async -> Int32 {
        guard let o = try? CrashHelperOptions.parse(args), o.allPaths.allSatisfy(isInsideScenarioSandbox) else { return 64 }
        let point: FaultPoint = o.mode == .copy ? .afterPartialCopy : .afterTrashDestination
        let readyPath = o.ready.path
        let tuning = FileOpTuning(faultHook: { reached, _ in
            guard reached == point else { return }
            FileManager.default.createFile(atPath: readyPath, contents: Data("ready".utf8))
            while true { sleep(60) }        // the parent sends SIGKILL
        })
        let interaction = ScriptedInteraction(conflicts: o.mode == .replace ? [.one(.replace)] : [])
        let queue = FileOpQueue(lanes: LanePool(config: .default), trash: SandboxTrash(directory: o.trash),
                                journal: Journal(fileURL: o.journal), interaction: interaction, tuning: tuning)
        let id = await queue.enqueue(JobRequest(.move(sources: [o.source], destination: o.destination), registersUndo: false))
        _ = await queue.outcome(of: id)
        return 3   // reaching this line means the fault point never fired
    }
}
```

`Sources/macx-scenarios/main.swift` (replaces the P1-01 stub):

```swift
import Foundation

Task { @MainActor in
    let code = await ScenarioCLI.main(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
RunLoop.main.run()
```

- [ ] **Step 5: Write the browse and job-kind scenarios**

`Sources/macx-scenarios/Scenarios/BrowseScenarios.swift`:

```swift
import Core
import Darwin
import Foundation
import MacxFS

enum BrowseScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("browse.naturalOrderFoldersFirst") { ctx in
            for name in ["file10.txt", "file2.txt", "File3.txt", "file1.txt", "Zeta.txt", "alpha.txt"] { ctx.file(name) }
            ctx.dir("zdir")
            ctx.dir("Adir")
            let m = try await ctx.open(ctx.work)
            try ctx.expectEqual(m.state, .complete, "state")
            try ctx.expectEqual(ctx.names(m), ["Adir", "zdir", "alpha.txt", "file1.txt", "file2.txt", "File3.txt", "file10.txt", "Zeta.txt"],
                                "folders first, then case-insensitive numeric order")
        },
        CoreScenario("browse.hiddenItemsToggle") { ctx in
            ctx.file("visible.txt")
            ctx.file(".dotfile")
            try ctx.setFlags(ctx.file("flagged.txt"), UInt32(UF_HIDDEN))
            let m = try await ctx.open(ctx.work)
            try ctx.expectEqual(ctx.names(m), ["visible.txt"], "dot and UF_HIDDEN items are hidden by default")
            m.setQuery(ViewQuery(showHidden: true))
            try await ctx.waitUntil("hidden rows appear") { Set(ctx.names(m)) == [".dotfile", "flagged.txt", "visible.txt"] }
            m.setQuery(ViewQuery(showHidden: false))
            try await ctx.waitUntil("hidden rows disappear") { ctx.names(m) == ["visible.txt"] }
        },
        CoreScenario("browse.filterFoldsCaseAndDiacritics") { ctx in
            ctx.file("Résumé.pdf")
            ctx.file("resume-old.txt")
            ctx.file("notes.txt")
            let m = try await ctx.open(ctx.work)
            m.setQuery(ViewQuery(filter: "RESUME"))
            try await ctx.waitUntil("filter applied") { Set(ctx.names(m)) == ["Résumé.pdf", "resume-old.txt"] }
            m.setQuery(ViewQuery(filter: "zzz"))
            try await ctx.waitUntil("no matches") { m.rowCount == 0 }
            m.setQuery(ViewQuery())
            try await ctx.waitUntil("filter cleared") { m.rowCount == 3 }
        },
        CoreScenario("browse.errorStates") { ctx in
            let notDirectory = ctx.file("plain.txt")
            let closed = ctx.dir("closed")
            ctx.file("closed/inner.txt")
            try ctx.setMode(closed, 0o000)
            let missing = try await ctx.open(ctx.path("missing"))
            try ctx.expectEqual(missing.state, .error(.notFound), "missing folder")
            let file = try await ctx.open(notDirectory)
            try ctx.expectEqual(file.state, .error(.notADirectory), "file opened as a folder")
            if geteuid() != 0 {
                let denied = try await ctx.open(closed)
                try ctx.expectEqual(denied.state, .error(.permissionPOSIX), "mode-000 folder")
            }
        },
        CoreScenario("browse.rapidNavigationDropsStaleResults", timeout: .seconds(120)) { ctx in
            let big = ctx.flat("big", count: 20_000)
            let small = ctx.dir("small")
            for name in ["a.txt", "b.txt", "c.txt"] { ctx.file("small/\(name)") }
            var last: FolderModel?
            for _ in 0..<20 {
                last?.close()
                let b = ctx.env.makeFolderModel(big, query: ViewQuery())
                b.start()
                b.close()
                let s = ctx.env.makeFolderModel(small, query: ViewQuery())
                ctx.track(s)
                s.start()
                last = s
                await Task.yield()
            }
            let final = try ctx.unwrap(last, "final model")
            try await ctx.waitUntil("small folder completes", timeout: .seconds(10)) { final.state == .complete }
            try await Task.sleep(for: .milliseconds(300))
            try ctx.expectEqual(ctx.names(final), ["a.txt", "b.txt", "c.txt"], "only the small folder's rows")
            let fresh = try await ctx.open(small, timeout: .seconds(3))
            try ctx.expectEqual(fresh.state, .complete, "lanes still healthy after 20 cancelled reads")
        },
    ]
}
```

`Sources/macx-scenarios/Scenarios/OpsScenarios.swift`:

```swift
import Core
import Darwin
import Foundation
import MacxFS

enum OpsScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("ops.copyTreeWithSymlink") { ctx in
            ctx.file("src/a.txt", "hello")
            ctx.file("src/d/b.txt")
            ctx.dir("src/d/e")
            try ctx.symlink("src/link", to: "a.txt")
            let dst = ctx.dir("dst")
            let m = try await ctx.open(dst)
            let out = await ctx.perform(.copy(sources: [ctx.path("src/a.txt"), ctx.path("src/d"), ctx.path("src/link")], destination: dst))
            try ctx.expect(out.skipped.isEmpty, "nothing skipped: \(out.skipped)")
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 5, "a.txt copied")
            try ctx.expect(ctx.exists(ctx.path("dst/d/b.txt")) && ctx.isDirectory(ctx.path("dst/d/e")), "tree copied")
            try ctx.expectEqual(ctx.readLink(ctx.path("dst/link")), "a.txt", "symlink copied as a link")
            try ctx.expect(ctx.exists(ctx.path("src/a.txt")), "source kept")
            try await ctx.waitUntil("destination model shows the new rows") { Set(ctx.names(m)) == ["d", "a.txt", "link"] }
        },
        CoreScenario("ops.copyPreservesMetadata") { ctx in
            let doc = ctx.file("src/doc.txt", "data")
            try ctx.setXattr(doc, "com.macexplorer.test", "v1")
            try ctx.setMode(doc, 0o640)
            try ctx.setModificationDate(doc, Date(timeIntervalSince1970: 1_000_000_000))
            let readOnly = ctx.dir("src/readonly")
            ctx.file("src/readonly/inner.txt")
            try ctx.setModificationDate(readOnly, Date(timeIntervalSince1970: 1_100_000_000))
            try ctx.setMode(readOnly, 0o555)
            let locked = ctx.file("src/locked.txt")
            try ctx.setFlags(locked, UInt32(UF_IMMUTABLE))
            let dst = ctx.dir("dst")
            let out = await ctx.perform(.copy(sources: [doc, readOnly, locked], destination: dst))
            try ctx.expect(out.skipped.isEmpty, "nothing skipped: \(out.skipped)")
            let copiedDoc = ctx.path("dst/doc.txt")
            try ctx.expectEqual(ctx.xattr(copiedDoc, "com.macexplorer.test"), "v1", "xattr preserved")
            try ctx.expectEqual(ctx.mode(copiedDoc), 0o640, "file mode preserved")
            try ctx.expectEqual(ctx.mtimeSeconds(copiedDoc), 1_000_000_000, "file mtime preserved")
            let copiedDir = ctx.path("dst/readonly")
            try ctx.expect(ctx.exists(ctx.path("dst/readonly/inner.txt")), "child copied into a read-only folder")
            try ctx.expectEqual(ctx.mode(copiedDir), 0o555, "directory mode applied post-order")
            try ctx.expectEqual(ctx.mtimeSeconds(copiedDir), 1_100_000_000, "directory mtime applied after its children")
            try ctx.expect(ctx.flags(ctx.path("dst/locked.txt")) & UInt32(UF_IMMUTABLE) != 0, "uchg preserved")
        },
        CoreScenario("ops.duplicateNaming") { ctx in
            let a = ctx.file("a.txt")
            let d = ctx.dir("d")
            ctx.file("d/x.txt")
            _ = await ctx.perform(.duplicate([a]))
            _ = await ctx.perform(.duplicate([a]))
            _ = await ctx.perform(.duplicate([d]))
            try ctx.expectEqual(ctx.entries(ctx.work), ["a.txt", "a copy.txt", "a copy 2.txt", "d", "d copy"], "Finder-style names")
            try ctx.expect(ctx.exists(ctx.path("d copy/x.txt")), "folder duplicated recursively")
        },
        CoreScenario("ops.copyIntoSameFolderMakesCopy") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.copy(sources: [a], destination: ctx.work))
            try ctx.expectEqual(ctx.entries(ctx.work), ["a.txt", "a copy.txt"], "copy-paste into the same folder")
        },
        CoreScenario("ops.moveSameVolumeKeepsIdentity") { ctx in
            let a = ctx.file("src/a.txt")
            ctx.file("src/d/b.txt")
            let inode = try ctx.unwrap(ctx.inode(a), "inode of a.txt")
            let dst = ctx.dir("dst")
            let source = try await ctx.open(ctx.path("src"))
            let out = await ctx.perform(.move(sources: [a, ctx.path("src/d")], destination: dst))
            try ctx.expect(out.skipped.isEmpty, "nothing skipped: \(out.skipped)")
            try ctx.expectEqual(ctx.inode(ctx.path("dst/a.txt")), inode, "same-volume move is a rename")
            try ctx.expect(!ctx.exists(a) && ctx.exists(ctx.path("dst/d/b.txt")), "moved")
            try await ctx.waitUntil("source model drops moved rows") { source.rowCount == 0 }
        },
        CoreScenario("ops.trashIntoSandboxTrash") { ctx in
            let a = ctx.file("a.txt")
            ctx.file("b.txt")
            let m = try await ctx.open(ctx.work)
            let out = await ctx.perform(.trash([a]))
            guard case .trashed(let original, let trashURL, _)? = out.record.actions.first else {
                throw ScenarioFailure("expected a .trashed action, got \(out.record.actions)")
            }
            try ctx.expectEqual(original.lastPathComponent, "a.txt", "original path recorded")
            try ctx.expect(ctx.exists(trashURL) && ctx.sandbox.contains(trashURL), "item is in the sandbox trash")
            try ctx.expect(!ctx.exists(a), "item left the folder")
            try await ctx.waitUntil("row removed") { ctx.names(m) == ["b.txt"] }
        },
        CoreScenario("ops.deletePermanently") { ctx in
            let d = ctx.dir("d")
            for i in 0..<50 { ctx.file("d/f\(i).txt") }
            let out = await ctx.perform(.delete([d]))
            try ctx.expect(!ctx.exists(d), "tree removed")
            try ctx.expect(!out.record.isUndoable, "permanent delete is not undoable")
        },
        CoreScenario("ops.newItems") { ctx in
            let first = await ctx.perform(.newItem(.folder, in: ctx.work))
            _ = await ctx.perform(.newItem(.folder, in: ctx.work))
            _ = await ctx.perform(.newItem(.textFile, in: ctx.work))
            _ = await ctx.perform(.newItem(.emptyFile, in: ctx.work))
            try ctx.expectEqual(ctx.entries(ctx.work), ["New Folder", "New Folder 2", "Untitled.txt", "Untitled"], "default names")
            try ctx.expect(first.localChanges.contains { $0.beginRename == "New Folder" }, "a new folder enters inline rename")
        },
        CoreScenario("ops.renameIncludingCaseOnly") { ctx in
            let a = ctx.file("a.txt")
            let m = try await ctx.open(ctx.work)
            _ = await ctx.perform(.rename(a, to: "b.txt"))
            try ctx.expectEqual(ctx.entries(ctx.work), ["b.txt"], "renamed")
            _ = await ctx.perform(.rename(ctx.path("b.txt"), to: "B.txt"))
            try ctx.expectEqual(ctx.entries(ctx.work), ["B.txt"], "case-only rename stored on disk")
            try await ctx.waitUntil("model shows the new case") { ctx.names(m) == ["B.txt"] }
        },
        CoreScenario("ops.aliasAndRelativeSymlink") { ctx in
            let a = ctx.file("a.txt", "target")
            let sub = ctx.dir("sub")
            let alias = await ctx.perform(.alias(sources: [a], destination: ctx.work))
            let aliasURL = try ctx.unwrap(alias.created.first, "alias URL")
            try ctx.expect(ctx.isAliasFile(aliasURL), "a Finder alias file was created")
            try ctx.expectEqual(ctx.resolveAlias(aliasURL)?.lastPathComponent, "a.txt", "alias resolves to the original")
            let link = await ctx.perform(.symlink(sources: [a], destination: sub))
            let linkURL = try ctx.unwrap(link.created.first, "symlink URL")
            let target = try ctx.unwrap(ctx.readLink(linkURL), "readlink")
            try ctx.expect(!target.hasPrefix("/"), "same-volume symlink is relative, got \(target)")
            try ctx.expectEqual(ctx.size(linkURL.deletingLastPathComponent().appending(path: target)), 6, "symlink resolves to a.txt")
        },
        CoreScenario("ops.chmodRecursive") { ctx in
            let d = ctx.dir("d")
            let f = ctx.file("d/f.txt")
            let s = ctx.dir("d/s")
            let g = ctx.file("d/s/g.txt")
            _ = await ctx.perform(.chmodRecursive(d, ModeChange(mode: 0o700)))
            for url in [d, f, s, g] { try ctx.expectEqual(ctx.mode(url), 0o700, "mode of \(url.lastPathComponent)") }
        },
        CoreScenario("ops.setAttributesLockedHidden") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.setAttributes([a], .locked(true)))
            try ctx.expect(ctx.flags(a) & UInt32(UF_IMMUTABLE) != 0, "locked")
            _ = await ctx.perform(.setAttributes([a], .locked(false)))
            try ctx.expect(ctx.flags(a) & UInt32(UF_IMMUTABLE) == 0, "unlocked")
            _ = await ctx.perform(.setAttributes([a], .hidden(true)))
            try ctx.expect(ctx.flags(a) & UInt32(UF_HIDDEN) != 0, "UF_HIDDEN set")
        },
        CoreScenario("ops.refusesCopyOrMoveIntoItself") { ctx in
            let folder = ctx.dir("A")
            let sub = ctx.dir("A/sub")
            let other = ctx.file("other.txt")
            let copy = await ctx.perform(.copy(sources: [folder, other], destination: sub))
            try ctx.expect(copy.skipped.contains { $0.url.lastPathComponent == "A" && $0.reason == .intoItself },
                           "copy into its own descendant refused: \(copy.skipped)")
            try ctx.expect(ctx.exists(ctx.path("A/sub/other.txt")), "other items in the same paste proceed")
            try ctx.expect(!ctx.exists(ctx.path("A/sub/A")), "nothing copied recursively")
            let move = await ctx.perform(.move(sources: [folder], destination: folder))
            try ctx.expect(move.skipped.contains { $0.reason == .intoItself }, "move onto itself refused: \(move.skipped)")
            try ctx.expect(ctx.exists(folder), "folder intact")
        },
        CoreScenario("ops.missingSourceSkipped") { ctx in
            let a = ctx.file("a.txt")
            let dst = ctx.dir("dst")
            let out = await ctx.perform(.copy(sources: [a, ctx.path("missing.txt")], destination: dst))
            try ctx.expect(ctx.exists(ctx.path("dst/a.txt")), "existing item copied")
            try ctx.expect(out.skipped.contains { $0.url.lastPathComponent == "missing.txt" && $0.reason == .sourceGone },
                           "missing item reported per item: \(out.skipped)")
        },
    ]
}
```

- [ ] **Step 6: Write the conflict, clipboard and undo scenarios**

`Sources/macx-scenarios/Scenarios/ConflictScenarios.swift`:

```swift
import Core
import Foundation

enum ConflictScenarios {
    static func replacedTrashURL(_ out: JobOutcome) -> URL? {
        out.record.actions.lazy.compactMap { action -> URL? in
            if case .replaced(_, let trashURL, _) = action { return trashURL }
            return nil
        }.first
    }

    static let all: [CoreScenario] = [
        CoreScenario("conflict.replaceTrashesExisting") { ctx in
            let src = ctx.file("src/a.txt", "hello")
            ctx.file("dst/a.txt", "x")
            let script = ScriptedInteraction(conflicts: [.one(.replace)])
            ctx.setInteraction(script)
            let out = await ctx.perform(.copy(sources: [src], destination: ctx.path("dst")))
            try ctx.expectEqual(script.askedConflicts().count, 1, "one conflict asked")
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 5, "destination replaced by the source")
            let trashURL = try ctx.unwrap(replacedTrashURL(out), "recorded .replaced action")
            try ctx.expectEqual(ctx.size(trashURL), 1, "displaced item kept in the trash, recoverable")
        },
        CoreScenario("conflict.skipLeavesDestination") { ctx in
            let src = ctx.file("src/a.txt", "hello")
            ctx.file("dst/a.txt", "x")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.one(.skip)]))
            let out = await ctx.perform(.copy(sources: [src], destination: ctx.path("dst")))
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 1, "destination untouched")
            try ctx.expect(out.skipped.contains { $0.url.lastPathComponent == "a.txt" && $0.reason == nil }, "skip recorded: \(out.skipped)")
        },
        CoreScenario("conflict.keepBoth") { ctx in
            let src = ctx.file("src/a.txt", "hello")
            ctx.file("dst/a.txt", "x")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.one(.keepBoth)]))
            _ = await ctx.perform(.copy(sources: [src], destination: ctx.path("dst")))
            try ctx.expectEqual(ctx.entries(ctx.path("dst")), ["a.txt", "a 2.txt"], "next free name")
            try ctx.expectEqual(ctx.size(ctx.path("dst/a 2.txt")), 5, "the new copy holds the source data")
        },
        CoreScenario("conflict.mergeFolders") { ctx in
            ctx.file("src/F/x.txt", "src-x")
            ctx.file("src/F/y.txt", "src-y")
            ctx.file("dst/F/y.txt", "d")
            ctx.file("dst/F/z.txt", "dst-z")
            let script = ScriptedInteraction(conflicts: [.one(.merge), .one(.replace)])
            ctx.setInteraction(script)
            _ = await ctx.perform(.move(sources: [ctx.path("src/F")], destination: ctx.path("dst")))
            try ctx.expect(script.askedConflicts().first?.isFolderMerge == true, "first question is a folder merge")
            try ctx.expectEqual(ctx.entries(ctx.path("dst/F")), ["x.txt", "y.txt", "z.txt"], "merged contents")
            try ctx.expectEqual(ctx.size(ctx.path("dst/F/y.txt")), 5, "conflicting child replaced")
            try ctx.expect(!ctx.exists(ctx.path("src/F")), "emptied source folder removed after the merge")
        },
        CoreScenario("conflict.applyToAllAsksOnce") { ctx in
            for n in ["a", "b", "c"] {
                ctx.file("src/\(n).txt", "new")
                ctx.file("dst/\(n).txt", "o")
            }
            let script = ScriptedInteraction(conflicts: [.all(.keepBoth)])
            ctx.setInteraction(script)
            _ = await ctx.perform(.copy(sources: ["a", "b", "c"].map { ctx.path("src/\($0).txt") }, destination: ctx.path("dst")))
            try ctx.expectEqual(script.askedConflicts().count, 1, "asked once")
            try ctx.expectEqual(ctx.entries(ctx.path("dst")), ["a.txt", "b.txt", "c.txt", "a 2.txt", "b 2.txt", "c 2.txt"], "kept both for all")
        },
        CoreScenario("conflict.perItemFromCompare") { ctx in
            let a = ctx.file("src/a.txt", "new")
            let b = ctx.file("src/b.txt", "new")
            ctx.file("dst/a.txt", "o")
            ctx.file("dst/b.txt", "o")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.perItem([a: .replace])]))   // b missing → skip
            _ = await ctx.perform(.copy(sources: [a, b], destination: ctx.path("dst")))
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 3, "a replaced")
            try ctx.expectEqual(ctx.size(ctx.path("dst/b.txt")), 1, "b skipped (absent from the per-item map)")
        },
        CoreScenario("conflict.cancelJobStops") { ctx in
            let a = ctx.file("src/a.txt", "new")
            let b = ctx.file("src/b.txt", "new")
            ctx.file("dst/a.txt", "o")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.cancelJob]))
            let out = await ctx.perform(.copy(sources: [a, b], destination: ctx.path("dst")))
            try ctx.expect(out.wasCancelled, "job cancelled from the conflict dialog")
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 1, "existing item untouched")
            try ctx.expect(!ctx.exists(ctx.path("dst/b.txt")), "later items not copied")
        },
    ]
}
```

`Sources/macx-scenarios/Scenarios/ClipboardScenarios.swift`:

```swift
import Core
import Foundation

enum ClipboardScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("clip.copyThenPasteCopies") { ctx in
            let clipboard = Clipboard(backend: InMemoryPasteboard())
            let a = ctx.file("a.txt")
            let dst = ctx.dir("dst")
            clipboard.copy([a])
            let plan = try ctx.unwrap(clipboard.pastePlan(into: dst, moveItemHere: false), "paste plan")
            try ctx.expectEqual(plan.operation, .copy, "copy then paste copies")
            _ = await ctx.perform(.copy(sources: plan.sources, destination: plan.destination))
            try ctx.expect(ctx.exists(a) && ctx.exists(ctx.path("dst/a.txt")), "copied, source kept")
        },
        CoreScenario("clip.cutThenPasteMoves") { ctx in
            let clipboard = Clipboard(backend: InMemoryPasteboard())
            let a = ctx.file("a.txt")
            let dst = ctx.dir("dst")
            clipboard.cut([a])
            try ctx.expectEqual(clipboard.cutNames(in: ctx.work), ["a.txt"], "cut item marked for dimming")
            let plan = try ctx.unwrap(clipboard.pastePlan(into: dst, moveItemHere: false), "paste plan")
            try ctx.expectEqual(plan.operation, .move, "valid cut marker moves")
            _ = await ctx.perform(.move(sources: plan.sources, destination: plan.destination))
            clipboard.didPaste(plan)
            try ctx.expect(clipboard.cutURLs.isEmpty, "cut state cleared after the move")
            try ctx.expect(!ctx.exists(a) && ctx.exists(ctx.path("dst/a.txt")), "moved")
        },
        CoreScenario("clip.staleCutPastesAsCopy") { ctx in
            let board = InMemoryPasteboard()
            let clipboard = Clipboard(backend: board)
            let a = ctx.file("a.txt")
            clipboard.cut([a])
            board.simulateExternalCopy([a])
            clipboard.revalidate()
            let plan = try ctx.unwrap(clipboard.pastePlan(into: ctx.dir("dst"), moveItemHere: false), "paste plan")
            try ctx.expectEqual(plan.operation, .copy, "changeCount moved on: the marker no longer counts")
            try ctx.expect(clipboard.cutURLs.isEmpty, "nothing shown as cut")
        },
        CoreScenario("clip.cutPasteIntoSameFolderIsNoOp") { ctx in
            let clipboard = Clipboard(backend: InMemoryPasteboard())
            clipboard.cut([ctx.file("a.txt")])
            let plan = try ctx.unwrap(clipboard.pastePlan(into: ctx.work, moveItemHere: false), "paste plan")
            try ctx.expect(plan.isNoOp, "cut-paste into the items' own folder does nothing")
        },
        CoreScenario("clip.moveItemHereMovesExternalCopy") { ctx in
            let board = InMemoryPasteboard()
            let clipboard = Clipboard(backend: board)
            let a = ctx.file("a.txt")
            board.simulateExternalCopy([a])            // "Finder copied a.txt"
            let plan = try ctx.unwrap(clipboard.pastePlan(into: ctx.dir("dst"), moveItemHere: true), "paste plan")
            try ctx.expectEqual(plan.operation, .move, "⌥⌘V moves whatever file URLs are on the pasteboard")
        },
        CoreScenario("clip.escapeClearsMarkerKeepsURLs") { ctx in
            let board = InMemoryPasteboard()
            let clipboard = Clipboard(backend: board)
            clipboard.cut([ctx.file("a.txt")])
            clipboard.clearCut()
            try ctx.expect(!board.hasCutMarker() && board.hasFileURLs(), "marker removed, URLs kept")
            try ctx.expect(clipboard.cutURLs.isEmpty, "dimming cleared")
            let plan = try ctx.unwrap(clipboard.pastePlan(into: ctx.dir("dst"), moveItemHere: false), "paste plan")
            try ctx.expectEqual(plan.operation, .copy, "after Esc the paste copies")
        },
    ]
}
```

`Sources/macx-scenarios/Scenarios/UndoScenarios.swift`:

```swift
import Core
import Foundation

enum UndoScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("undo.copyTrashesCreatedItems") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.copy(sources: [a], destination: ctx.dir("dst")))
            _ = try await ctx.undo()
            try ctx.expect(!ctx.exists(ctx.path("dst/a.txt")) && ctx.exists(a), "copy undone, source untouched")
        },
        CoreScenario("undo.moveMovesBackAndRedoMovesAgain") { ctx in
            let a = ctx.file("src/a.txt")
            let dst = ctx.dir("dst")
            _ = await ctx.perform(.move(sources: [a], destination: dst))
            _ = try await ctx.undo()
            try ctx.expect(ctx.exists(a) && !ctx.exists(ctx.path("dst/a.txt")), "moved back")
            _ = try await ctx.redo()
            try ctx.expect(!ctx.exists(a) && ctx.exists(ctx.path("dst/a.txt")), "redo moved it again")
        },
        CoreScenario("undo.renameRenamesBack") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.rename(a, to: "b.txt"))
            _ = try await ctx.undo()
            try ctx.expectEqual(ctx.entries(ctx.work), ["a.txt"], "renamed back")
        },
        CoreScenario("undo.trashRestoresOriginalPath") { ctx in
            let a = ctx.file("a.txt", "keep me")
            _ = await ctx.perform(.trash([a]))
            try ctx.expect(!ctx.exists(a), "trashed")
            _ = try await ctx.undo()
            try ctx.expectEqual(ctx.size(a), 7, "restored to the original path with its data")
        },
        CoreScenario("undo.newFolderRemovesIt") { ctx in
            _ = await ctx.perform(.newItem(.folder, in: ctx.work))
            _ = try await ctx.undo()
            try ctx.expect(!ctx.exists(ctx.path("New Folder")), "new folder undone")
        },
        CoreScenario("undo.replaceRestoresDisplacedItem") { ctx in
            let src = ctx.file("src/a.txt", "hello")
            ctx.file("dst/a.txt", "x")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.one(.replace)]))
            _ = await ctx.perform(.copy(sources: [src], destination: ctx.path("dst")))
            _ = try await ctx.undo()
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 1, "the replaced original is back")
        },
        CoreScenario("undo.chmodRestoresModes") { ctx in
            let d = ctx.dir("d")
            let f = ctx.file("d/f.txt")
            try ctx.setMode(f, 0o644)
            try ctx.setMode(d, 0o755)
            _ = await ctx.perform(.chmodRecursive(d, ModeChange(mode: 0o700)))
            _ = try await ctx.undo()
            try ctx.expectEqual(ctx.mode(f), 0o644, "file mode restored")
            try ctx.expectEqual(ctx.mode(d), 0o755, "folder mode restored")
        },
        CoreScenario("undo.skipsItemsChangedExternally") { ctx in
            let a = ctx.file("src/a.txt")
            _ = await ctx.perform(.move(sources: [a], destination: ctx.dir("dst")))
            try ctx.removeRaw(ctx.path("dst/a.txt"))        // gone behind our back
            let undo = try await ctx.undo()
            try ctx.expectEqual(undo.skipped.count, 1, "the vanished item is listed in the summary")
            try ctx.expect(!ctx.exists(a), "nothing resurrected")
        },
        CoreScenario("undo.partialJobUndoesDoneItemsOnly") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.copy(sources: [a, ctx.path("missing.txt")], destination: ctx.dir("dst")))
            _ = try await ctx.undo()
            try ctx.expect(!ctx.exists(ctx.path("dst/a.txt")) && ctx.exists(a), "only the copied item was undone")
        },
    ]
}
```

- [ ] **Step 7: Write the watcher scenarios**

`Sources/macx-scenarios/Scenarios/WatcherScenarios.swift`:

```swift
import Core
import Darwin
import Foundation
import MacxFS

@MainActor final class ChangeCounter {
    private(set) var structural = 0
    private(set) var reloads = 0
    func add(_ set: ChangeSet) {
        for change in set.changes {
            switch change {
            case .insert, .remove, .move, .reset: structural += 1
            case .reload: reloads += 1
            }
        }
    }
}

@MainActor final class RelocationBox { var value: (URL, RelocationReason)? }

enum WatcherScenarios {
    static func createEmptyFiles(_ paths: [String]) {
        for path in paths {
            let fd = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o644)
            if fd >= 0 { close(fd) }
        }
    }

    static let all: [CoreScenario] = [
        CoreScenario("watch.burst10kKeepsSelection", timeout: .seconds(120)) { ctx in
            ctx.file("keep.txt")
            let m = try await ctx.open(ctx.work)
            m.select(.names(["keep.txt"]))
            let id = m.identity(atRow: try ctx.unwrap(m.row(named: "keep.txt"), "row of keep.txt"))
            let paths = (0..<10_000).map { ctx.path(String(format: "burst-%05d.txt", $0)).path }
            await ctx.background { createEmptyFiles(paths) }
            try await ctx.waitUntil("model reaches 10,001 rows", timeout: .seconds(30)) { m.rowCount == 10_001 }
            let fresh = try await ctx.open(ctx.work)
            try ctx.expectEqual(ctx.names(m), ctx.names(fresh), "watched model equals a fresh read")
            try ctx.expect(m.selection.ids == [id], "selection kept by identity")
            try ctx.expectEqual(m.selectedURLs.map(\.lastPathComponent), ["keep.txt"], "selected row is still keep.txt")
        },
        CoreScenario("watch.atomicSaveKeepsSelection") { ctx in
            ctx.file("doc.txt", "v1")
            ctx.file("other.txt")
            let m = try await ctx.open(ctx.work)
            m.select(.names(["doc.txt"]))
            let temporary = ctx.file(".doc.txt.tmp", "version-2")
            try ctx.renameRaw(temporary, to: ctx.path("doc.txt"))
            try await ctx.waitUntil("model sees the new size") {
                m.row(named: "doc.txt").map { m.entry(atRow: $0).size == 9 } ?? false
            }
            try ctx.expectEqual(m.selectedURLs.map(\.lastPathComponent), ["doc.txt"], "selection survives an atomic save")
        },
        CoreScenario("watch.externalRenameAndDelete") { ctx in
            ctx.file("b.txt")
            ctx.file("d.txt")
            ctx.file("e.txt")
            let m = try await ctx.open(ctx.work)
            try ctx.renameRaw(ctx.path("b.txt"), to: ctx.path("c.txt"))
            try ctx.removeRaw(ctx.path("d.txt"))
            try await ctx.waitUntil("rename and delete applied") { ctx.names(m) == ["c.txt", "e.txt"] }
        },
        CoreScenario("watch.subfolderChangesCauseNoReread") { ctx in
            ctx.dir("sub")
            ctx.file("top.txt")
            let m = try await ctx.open(ctx.work)
            let counter = ChangeCounter()
            ctx.keep(m.observe { if case .changes(let set) = $0 { counter.add(set) } })
            for i in 0..<50 { ctx.file("sub/n\(i).txt") }
            try await Task.sleep(for: .milliseconds(800))
            try ctx.expectEqual(counter.structural, 0, "events inside a subfolder must not insert/remove/reset rows")
            try ctx.expectEqual(m.rowCount, 2, "row count unchanged")
        },
        CoreScenario("watch.removedFolderRelocatesToParent") { ctx in
            ctx.file("sub/x.txt")
            let m = try await ctx.open(ctx.path("sub"))
            let box = RelocationBox()
            ctx.keep(m.observe { if case .relocate(let to, let reason) = $0 { box.value = (to, reason) } })
            try ctx.removeTreeRaw(ctx.path("sub"))
            try await ctx.waitUntil("relocate event", timeout: .seconds(5)) { box.value != nil }
            try ctx.expectEqual(box.value?.0.standardizedFileURL.path, ctx.work.standardizedFileURL.path, "nearest existing ancestor")
            try ctx.expectEqual(box.value?.1, .movedOrDeleted(name: "sub"), "banner reason")
        },
        CoreScenario("watch.changesDuringEnumerationNotLost", timeout: .seconds(120)) { ctx in
            let big = ctx.flat("big", count: 20_000)
            let late = ctx.path("big/zz-late.txt").path
            let m = ctx.env.makeFolderModel(big, query: ViewQuery())
            ctx.track(m)
            m.start()
            await ctx.background { createEmptyFiles([late]) }
            try await ctx.waitUntil("complete with the late file", timeout: .seconds(20)) {
                m.state == .complete && m.row(named: "zz-late.txt") != nil
            }
            try ctx.expectEqual(m.rowCount, 20_001, "no entry lost or duplicated")
        },
    ]
}
```

- [ ] **Step 8: Write the disk-image and crash scenarios, and the catalog**

`Sources/macx-scenarios/Scenarios/CrossVolumeScenarios.swift`:

```swift
import Core
import Darwin
import Foundation

enum CrossVolumeScenarios {
    static func noPartials(_ ctx: ScenarioContext, _ dir: URL) -> Bool {
        ctx.entries(dir).allSatisfy { !$0.contains(".macx-partial-") }
    }

    static func bytesDone(_ queue: FileOpQueue, _ id: JobID) async -> Int64? {
        await queue.snapshots().first { $0.id == id }?.progress.bytesDone
    }

    static let all: [CoreScenario] = [
        CoreScenario("xvol.moveTreeToAPFSImage", requires: .diskImages) { ctx in
            let image = try await ctx.image("move", .apfs, sizeMB: 64)
            ctx.file("src/a.txt", "aaaa")
            ctx.file("src/d/b.txt", "bb")
            ctx.dir("src/d/empty")
            try ctx.symlink("src/d/link", to: "b.txt")
            let out = await ctx.perform(.move(sources: [ctx.path("src/a.txt"), ctx.path("src/d")], destination: image.mountPoint))
            try ctx.expect(out.skipped.isEmpty, "nothing skipped: \(out.skipped)")
            try ctx.expect(!ctx.exists(ctx.path("src/a.txt")) && !ctx.exists(ctx.path("src/d")), "sources deleted after the verified copy")
            try ctx.expectEqual(ctx.size(image.mountPoint.appending(path: "a.txt")), 4, "a.txt landed")
            try ctx.expectEqual(ctx.readLink(image.mountPoint.appending(path: "d/link")), "b.txt", "symlink moved as a link")
            try ctx.expect(ctx.isDirectory(image.mountPoint.appending(path: "d/empty")), "empty folder moved")
            try ctx.expect(noPartials(ctx, image.mountPoint), "no partials left")
            let journal = await ctx.env.journal.entries()
            try ctx.expect(journal.isEmpty, "journal cleared after success: \(journal)")
        },
        CoreScenario("xvol.replaceAcrossVolumes", requires: .diskImages) { ctx in
            let image = try await ctx.image("replace", .apfs, sizeMB: 64)
            let src = ctx.file("a.txt", "hello")
            let dest = ctx.file(at: image.mountPoint.appending(path: "a.txt"), "x")
            let trash = ctx.dir(at: image.mountPoint.appending(path: ".macx-trash"))
            let queue = ctx.makeQueue(trash: trash, interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
            let out = await ctx.run(queue, .move(sources: [src], destination: image.mountPoint))
            try ctx.expectEqual(ctx.size(dest), 5, "replaced")
            try ctx.expect(!ctx.exists(src), "source removed after the verified replace")
            try ctx.expect(out.record.actions.contains { if case .replaced = $0 { true } else { false } }, "replacement recorded for undo")
            try ctx.expect(noPartials(ctx, image.mountPoint), "no partials left")
        },
        CoreScenario("xvol.pauseAndResumeMidCopy", requires: .diskImages, timeout: .seconds(120)) { ctx in
            let image = try await ctx.image("pause", .hfsPlus, sizeMB: 128)
            let big = ctx.file("big.bin", bytes: 64 << 20)
            let queue = ctx.makeQueue(trash: ctx.dir("t"), interaction: ScriptedInteraction(), tuning: .slowChunks)
            let id = await queue.enqueue(JobRequest(.copy(sources: [big], destination: image.mountPoint), registersUndo: false))
            try await ctx.waitUntilAsync("copy started", timeout: .seconds(20)) { (await bytesDone(queue, id) ?? 0) > 0 }
            await queue.pause(id)
            try await ctx.waitUntilAsync("paused", timeout: .seconds(5)) { await queue.snapshots().first { $0.id == id }?.state == .paused }
            try await Task.sleep(for: .milliseconds(250))
            let before = await bytesDone(queue, id)
            try await Task.sleep(for: .milliseconds(400))
            let after = await bytesDone(queue, id)
            try ctx.expectEqual(after, before, "no bytes copied while paused")
            await queue.resume(id)
            let out = await queue.outcome(of: id)
            try ctx.expect(!out.wasCancelled && out.skipped.isEmpty, "copy finished after resume")
            try ctx.expectEqual(ctx.size(image.mountPoint.appending(path: "big.bin")), Int64(64 << 20), "full size")
        },
        CoreScenario("xvol.cancelMidCopyAppliesFolderMetadata", requires: .diskImages, timeout: .seconds(120)) { ctx in
            let image = try await ctx.image("cancel", .hfsPlus, sizeMB: 128)
            let tree = ctx.dir("tree")
            ctx.file("tree/big.bin", bytes: 64 << 20)
            ctx.file("tree/z-after.txt")
            try ctx.setMode(tree, 0o755)
            let queue = ctx.makeQueue(trash: ctx.dir("t"), interaction: ScriptedInteraction(), tuning: .slowChunks)
            let id = await queue.enqueue(JobRequest(.copy(sources: [tree], destination: image.mountPoint), registersUndo: false))
            try await ctx.waitUntilAsync("copy started", timeout: .seconds(20)) { (await bytesDone(queue, id) ?? 0) > 0 }
            await queue.cancel(id)
            let out = await queue.outcome(of: id)
            try ctx.expect(out.wasCancelled, "cancelled")
            let copied = image.mountPoint.appending(path: "tree")
            if ctx.exists(copied) {
                try ctx.expectEqual(ctx.mode(copied), 0o755, "a cancelled copy never leaves a folder at 0700")
            }
            try ctx.expect(ctx.exists(tree.appending(path: "big.bin")), "source untouched")
        },
        CoreScenario("xvol.moveKeepsSourceThatChangedDuringCopy", requires: .diskImages) { ctx in
            let image = try await ctx.image("changed", .apfs, sizeMB: 64)
            let src = ctx.file("log.txt", bytes: 1 << 20)
            let path = src.path
            let tuning = FileOpTuning(faultHook: { point, _ in
                guard point == .afterPartialCopy else { return }
                let fd = open(path, O_WRONLY | O_APPEND)
                if fd >= 0 {
                    _ = write(fd, "more", 4)
                    close(fd)
                }
            })
            let queue = ctx.makeQueue(trash: ctx.dir(at: image.mountPoint.appending(path: ".macx-trash")),
                                      interaction: ScriptedInteraction(), tuning: tuning)
            let out = await ctx.run(queue, .move(sources: [src], destination: image.mountPoint))
            try ctx.expectEqual(ctx.size(src), Int64((1 << 20) + 4), "source NOT deleted and keeps the appended bytes")
            try ctx.expect(!ctx.exists(image.mountPoint.appending(path: "log.txt")), "no final copy")
            try ctx.expect(noPartials(ctx, image.mountPoint), "partial removed")
            try ctx.expect(out.skipped.contains { $0.reason == .changedDuringMove }, "reported as changed: \(out.skipped)")
        },
        CoreScenario("xvol.readOnlyDestinationReportsEROFS", requires: .diskImages) { ctx in
            let image = try await ctx.image("ro", .hfsPlus, sizeMB: 16, readOnly: true)
            let a = ctx.file("a.txt")
            let script = ScriptedInteraction(errors: [.cancel])
            ctx.setInteraction(script)
            _ = await ctx.perform(.copy(sources: [a], destination: image.mountPoint))
            try ctx.expectEqual(script.askedErrors().first?.kind, .readOnlyVolume, "EROFS mapped to readOnlyVolume")
            try ctx.expect(!ctx.exists(image.mountPoint.appending(path: "a.txt")), "nothing written")
        },
        CoreScenario("xvol.insufficientSpaceAsksFirst", requires: .diskImages) { ctx in
            let image = try await ctx.image("small", .hfsPlus, sizeMB: 16)
            let big = ctx.file("big.bin", bytes: 40 << 20)
            ctx.setInteraction(ScriptedInteraction(space: [false]))
            _ = await ctx.perform(.copy(sources: [big], destination: image.mountPoint))
            try ctx.expect(!ctx.exists(image.mountPoint.appending(path: "big.bin")), "declining the shortfall prompt copies nothing")
            try ctx.expectEqual(ctx.size(big), Int64(40 << 20), "source intact")
        },
        CoreScenario("xvol.exfatCaseOnlyRename", requires: .diskImages) { ctx in
            let image = try await ctx.image("exfat", .exfat, sizeMB: 32)
            let file = ctx.file(at: image.mountPoint.appending(path: "ab.txt"))
            let m = try await ctx.open(image.mountPoint)
            _ = await ctx.perform(.rename(file, to: "AB.txt"))
            let names = ctx.entries(image.mountPoint)
            try ctx.expect(names.contains("AB.txt") && !names.contains("ab.txt"), "case-only rename stored on exFAT: \(names)")
            try await ctx.waitUntil("model shows AB.txt", timeout: .seconds(5)) {
                ctx.names(m).contains("AB.txt") && !ctx.names(m).contains("ab.txt")
            }
        },
    ]
}
```

`Sources/macx-scenarios/Scenarios/CrashScenarios.swift`:

```swift
import Core
import Darwin
import Foundation

enum CrashScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("crash.killDuringCrossVolumeMove", requires: .helperProcess, timeout: .seconds(120)) { ctx in
            try await killHelperAndRecover(ctx, mode: "copy")
        },
        CoreScenario("crash.killDuringReplace", requires: .helperProcess, timeout: .seconds(120)) { ctx in
            try await killHelperAndRecover(ctx, mode: "replace")
        },
    ]

    /// Starts `macx-scenarios crash-helper`, which blocks at the fault point; SIGKILLs it; runs LaunchRecovery.
    @MainActor
    static func killHelperAndRecover(_ ctx: ScenarioContext, mode: String) async throws {
        let helper = try ctx.requireHelper()
        let image = try await ctx.image("crash-\(mode)", .apfs, sizeMB: 64)
        let source = ctx.file("big.bin", bytes: 8 << 20)
        let finalURL = image.mountPoint.appending(path: "big.bin")
        if mode == "replace" { ctx.file(at: finalURL, "old") }
        let trash = ctx.dir(at: image.mountPoint.appending(path: ".macx-trash"))
        let journalURL = ctx.path("helper-journal.json")
        let ready = ctx.path("helper-ready")
        let process = try ctx.launchHelper(helper, [
            "crash-helper", "--mode", mode, "--source", source.path, "--destination", image.mountPoint.path,
            "--journal", journalURL.path, "--trash", trash.path, "--ready", ready.path,
        ])
        try await ctx.waitUntil("helper reaches the fault point", timeout: .seconds(60)) { ctx.exists(ready) || !process.isRunning }
        try ctx.expect(process.isRunning, "helper exited early with status \(process.terminationStatus)")
        kill(process.processIdentifier, SIGKILL)
        try await ctx.waitUntil("helper is gone", timeout: .seconds(10)) { !process.isRunning }

        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: ctx.env.lanes)
        try ctx.expectEqual(ctx.size(source), Int64(8 << 20), "source intact after the kill")
        try ctx.expect(CrossVolumeScenarios.noPartials(ctx, image.mountPoint),
                       "partial copy removed by launch recovery: \(ctx.entries(image.mountPoint))")
        try ctx.expect(!report.incompleteJobs.isEmpty, "the incomplete job is reported to the user")
        if mode == "replace" {
            try ctx.expect(!report.restoredDestinations.isEmpty, "trashed destination restored: \(report)")
            try ctx.expectEqual(ctx.size(finalURL), 3, "original destination content back in place")
        } else {
            try ctx.expect(!report.removedPartials.isEmpty, "partial listed as removed: \(report)")
            try ctx.expect(!ctx.exists(finalURL), "nothing landed under the final name")
        }
    }
}
```

`Sources/macx-scenarios/Scenarios/Catalog.swift`:

```swift
enum Catalog {
    static let all: [CoreScenario] =
        BrowseScenarios.all + OpsScenarios.all + ConflictScenarios.all + ClipboardScenarios.all + UndoScenarios.all
        + WatcherScenarios.all + CrossVolumeScenarios.all + CrashScenarios.all

    static func select(_ filter: String?) -> [CoreScenario] {
        guard let filter, !filter.isEmpty else { return all }
        return all.filter { $0.name.contains(filter) }
    }
}
```

- [ ] **Step 9: Run the unit tests**

Run: `swift build 2>&1 | tail -3 && swift test --filter ScenarioRunnerTests 2>&1 | grep -E "error|Executed|skipped" | tail -4`
Expected: `Build complete!` with no warnings, then `Executed 15 tests, with 0 failures`. `testImagesAreDetachedWhenScenarioThrows` reports `skipped` only on machines without `hdiutil`.

If `testRealCatalogSubsetPasses` fails, its message names the scenario and the assertion (with `file:line`). Fix the product code in the owning S2/S3 task, not the scenario. The scenarios encode §6 and §9 behaviour.

- [ ] **Step 10: Write `scripts/run-scenarios.sh`**

```bash
#!/bin/bash
# Builds macx-scenarios and runs the whole Core scenario catalog (including disk images and crash/kill
# recovery) inside ONE fresh ${TMPDIR}/macx-scenario-<UUID> run directory. Usage:
#   scripts/run-scenarios.sh [debug|release] [--filter <substring>] [--keep-sandbox]
# Safety: the CLI runs with TMPDIR=<run dir>, so every Sandbox and disk image lives inside it; on exit
# this script detaches images mounted under the run dir only, clears uchg/000 inside it, and deletes it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

CONFIG=debug
if [ "${1:-}" = "debug" ] || [ "${1:-}" = "release" ]; then CONFIG="$1"; shift; fi

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
RUN="$TMPBASE/macx-scenario-$(uuidgen)"
mkdir "$RUN" || exit 2
RUN_REAL="$(cd "$RUN" && pwd -P)"

cleanup() {
  case "$RUN" in "$TMPBASE"/macx-scenario-*) ;; *) echo "refusing to clean $RUN" >&2; return 1 ;; esac
  while IFS= read -r mp; do
    case "$mp" in "$RUN_REAL"/*) hdiutil detach "$mp" -force >/dev/null 2>&1 ;; esac
  done < <(mount | sed -n 's/^.* on \(.*\) (.*)$/\1/p')
  chflags -R nouchg "$RUN" 2>/dev/null
  chmod -R u+rwx "$RUN" 2>/dev/null
  rm -rf "$RUN"
  if [ -e "$RUN" ]; then echo "ERROR: run directory $RUN was not removed" >&2; return 1; fi
  echo "sandbox root $RUN removed"
}
trap 'cleanup || exit 1' EXIT

echo "run directory: $RUN"
swift build -c "$CONFIG" --product macx-scenarios > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; exit 1; }
BIN="$(swift build -c "$CONFIG" --show-bin-path)/macx-scenarios"

TMPDIR="$RUN/" "$BIN" --require-images --json "$RUN/report.json" "$@" 2>&1 | tee "$RUN/log.txt"
status=${PIPESTATUS[0]}
mkdir -p .build && cp "$RUN/report.json" .build/scenario-report.json 2>/dev/null
exit "$status"
```

Then run `chmod +x scripts/run-scenarios.sh`.

- [ ] **Step 11: Run the whole catalog and watch the output**

Run: `scripts/run-scenarios.sh 2>&1 | tail -15`

Expected output:
- `run directory: …/macx-scenario-<UUID>` first.
- Then one `PASS <name> (<n> ms)` line per scenario, each followed by `  sandbox …/macx-scenario-<UUID>/macx-scenario-<UUID> removed`.
- The final lines are `macx-scenarios: 57 passed, 0 failed, 0 skipped` and `sandbox root …/macx-scenario-<UUID> removed`.
- Exit code 0.

Spot-check the safety properties:
- `ls "${TMPDIR%/}" | grep -c '^macx-scenario-'` returns the same count before and after the run.
- `mount | grep -c macx-scenario` prints `0`.

To run one area: `scripts/run-scenarios.sh --filter xvol.` (8 scenarios) or `--filter crash.` (2 scenarios; each starts and kills a helper process).

- [ ] **Step 12: Commit**

```bash
git add Package.swift Sources/macx-scenarios Tests/ScenarioRunnerTests scripts/run-scenarios.sh
git commit -m "feat: macx-scenarios headless Core scenario catalog with disk-image and crash-recovery runs"
```

---

## Task P1-41: UI scenario runner (`ScenarioFile`, `ScenarioDriver`, 21 scenarios, `ui-scenarios.sh`, `ui-ax-smoke.sh`)

**Spec:** This task fills the §9 UI XCUITest smoke-suite role, as allowed by the overview deviation. The smoke suite covers:
- navigating by the address bar;
- renaming with F2;
- cut and paste;
- drag-move;
- the right-drag menu;
- the conflict dialog;
- Properties;
- undo;
- colliding keys (⌥←, ⌘↑, ⌘⌫, ⌥D…) reaching the field editor while editing (§5.6 key routing 1–3).

It also covers the §5.5 empty states, hidden toggle and filter, the §5.6 key table alternates, §5.6 paste targets and Esc, §5.4 type-select, §5.5 Icons spatial arrows, and §6.6 undo/redo keys.

**How the driver works.** This design follows from facts 4–8 above.
- **Keys and typing.** These are real `NSEvent`s posted with `NSApp.postEvent` and followed by an app-defined fence event. So menu key equivalents, `validateMenuItem` collisions, the field editor and `KeyRouter` alternates all run their production code paths.
- **Pinned key window.** `MacxApplication` (a new `NSApplication` subclass) lets the driver pin the frontmost browser or Properties window as key/main. Nil-targeted actions then resolve whether or not macOS let the process activate.
- **Mouse steps go through the model.** Synthesized clicks don't work in an inactive window (fact 4):
  - `click` becomes the `SelectionCommand` that P1-33's `SelectionController` maps that click to: `.set`, `.toggle` for ⌘, or `.extend` for ⇧.
  - `doubleClick` selects the row, then sends `macx_open:` through the responder chain.
  - `rightClick` builds the real `ContextMenuBuilder` menu for that row, or the empty-space menu.
  - `chooseMenuItem` validates the item and performs it.
- **Drops.** These use the contract's `probePerformDrop`, which runs the same `DropPolicy`, `DropMenu` and job path as a real drop.
- **Conflict answers.** The real `InteractionRouter` still presents the conflict dialog on the origin window, and the scenario checks for the sheet. The answer comes from a `ScenarioInteraction` decorator, because SwiftUI buttons cannot be pressed in-process (fact 8; Contract note C4).
- **Alerts.** AppKit alerts are answered by pressing their `NSButton` by title.

**Files:**
- Create:
  - `Sources/UI/Scenario/ScenarioFile.swift` (the schema from §3.14 plus additive fields; Contract note C6)
  - `Sources/UI/Scenario/ScenarioDriver.swift`
  - `Sources/UI/Scenario/KeySynth.swift`
  - `Sources/UI/Scenario/ExpectationMatcher.swift`
  - `Sources/UI/Scenario/ScenarioInteraction.swift`
  - `Sources/UI/Scenario/ScenarioFixtures.swift`
  - `Sources/UI/Scenario/ScenarioLaunch.swift`
  - `Sources/UI/App/MacxApplication.swift`
- Modify (S4-owned files from P1-01/P1-26; one call each, shown in Step 6):
  - `Sources/App/main.swift`
  - `Sources/App/AppDelegate.swift`
  - `Resources/Info.plist` (`NSPrincipalClass`)
- Create: `Tests/Scenarios/*.json` (21 files, listed in Step 8)
- Create: `scripts/ui-scenarios.sh`, `scripts/ui-ax-smoke.sh`, `scripts/ui-ax-smoke.applescript`
- Test (all in the `UITests` target):
  - `Tests/UITests/ScenarioFileTests.swift`
  - `Tests/UITests/ScenarioKeySynthTests.swift`
  - `Tests/UITests/ScenarioExpectationTests.swift`
  - `Tests/UITests/ScenarioFixturesTests.swift`
  - `Tests/UITests/ScenarioInteractionTests.swift`
  - `Tests/UITests/ScenarioCatalogTests.swift`
  - `Tests/UITests/ScenarioDriverLogicTests.swift`
  - `Tests/UITests/ScenarioHooksWiringTests.swift`

**Interfaces:**
- Consumes (overview §3.14 and §3.10–3.13, exact names):
  - From `UIContext`: `environment`, `options`, `windows`, `interaction`, `installInteraction(_:)`.
  - From `WindowManager`: `windows`, `openWindow(at:selecting:)`.
  - `BrowserWindowController`: `session` (`folder`, `reload()`), `window`, `scenarioHooks`, and every `ScenarioProbe` member, including `probePerformDrop`.
  - `CommandHandlingViewController.handler`, `ContentViewController`.
  - `ContextMenuBuilder(context:)` with `itemMenu(for:in:handler:)` and `emptySpaceMenu(for:handler:)`.
  - `AXID` (`detailsTable`, `iconsGrid`, `propertiesWindow`).
  - `Command` and its `selectorName`.
  - `KeyChord`, which includes `init?(parsing:)`, `Key` and `KeyModifiers`.
  - `FolderModel` (`select(_:)`, `selection`), `SelectionCommand`, `FolderState`, `Reason`, `FocusContext`, `ViewMode`.
  - `DragModifiers`, `DragOperation`, `ConflictAction`, `ConflictResolution`, `ConflictInfo`, `JobSnapshot`, `FileOpError`, `ErrorResolution`, `SpaceShortfall`, `FileOpInteraction`.
  - `LaunchOptions` (`root`, `stateDirectory`, `scenario`, `scenarioOutput`, `pasteboardName`).
  - `LanePool.perform(on:_:stallPolicy:onStall:_:)` and `VolumeID.unknown`.
  - Test-only: `ScriptedInteraction`, `FileOpQueue`, `SandboxTrash`, `Journal`, `LanePool`, `CoreEnvironment.sandboxed(root:)`, and `Sandbox` (P1-02, assumed).
- Produces:
  - `@objc(MacxApplication) public final class MacxApplication: NSApplication { @MainActor static var scenarioKeyWindow: NSWindow? }`
  - `struct ScenarioFile: Codable` (§3.14 fields, exactly, plus `Fixture.modes`, `Step.command`, `Step.answerAlert`, and `Expectation.rowCount/editingAddress/viewMode/sheetPresent/propertiesWindows/windowCount/fileSizes`), with `validate() throws(ValidationError)` and `static func load(_: Data) throws -> ScenarioFile`
  - `enum ScenarioPath { static func isSafeRelative(_:) -> Bool }`
  - `struct SynthKey`, `enum KeySynth { static func spec(for: KeyChord) -> SynthKey?; static func typingSpecs(_: String) -> [SynthKey]; @MainActor static func events(_: SynthKey, windowNumber: Int) -> [NSEvent] }`
  - `struct ProbeSnapshot`, `enum ExpectationMatcher { requestedPaths(_:); mismatches(_:_:) }`, `enum ScenarioStrings { state(_:); focus(_:) }`
  - `enum ScenarioFixtures { static func create(_:in:) throws(ScenarioFixtureError); static func topLevelVisibleNames(_:) -> Set<String> }`
  - `final class ScenarioInteraction: FileOpInteraction { init(forwardingTo:); var pendingCount: Int; var askedCount: Int; func answer(_:) -> Bool }`
  - `@MainActor final class ScenarioDriver { init(context:file:output:); func run() async -> Bool; nonisolated static func pickKeyWindow(_:) -> Int?; nonisolated static func relativePath(_:roots:) -> String? }`. The `init` and `run()` signatures are exactly those in the contract.
  - `public enum ScenarioLaunch { @MainActor public static func runIfRequested(context: UIContext) }`
- Result JSON (`--scenario-output`): `{"name","passed","failedStep"?,"message"?,"durationMs","activated"}`. These are the §3.14 fields, plus the additive `activated`.
- Key names used by `Tests/Scenarios/*.json` must parse with `KeyChord(parsing:)` exactly as `ScenarioCatalogTests.testKeyNamesMapToTheIntendedKeys` pins them (Contract note C8). The names are:
  - Plain keys: `delete` (⌫), `fn+delete` (Del), `esc`, `return`, `tab`, `F2`, `F4`, `F5`, `up`, `down`, `left`, `right`.
  - With modifiers: `cmd+delete`, `opt+cmd+delete`, `shift+fn+delete`, `cmd+shift+.`, `cmd+[`, `cmd+]`, `opt+left`, `opt+right`, `opt+up`, `opt+d`, `opt+return`, `shift+right`.
  - Command and control letters: `cmd+l`, `cmd+f`, `cmd+i`, `cmd+w`, `cmd+x`, `cmd+c`, `cmd+v`, `cmd+z`, `cmd+y`, `cmd+d`, `cmd+a`, `cmd+shift+z`, `cmd+shift+n`, `cmd+shift+r`, `cmd+up`, `cmd+down`, `ctrl+x`, `ctrl+v`, `ctrl+z`.

- [ ] **Step 1: Write the failing pure-logic tests**

`Tests/UITests/ScenarioFileTests.swift`:

```swift
import XCTest
@testable import UI

final class ScenarioFileTests: XCTestCase {
    private func load(_ json: String) throws -> ScenarioFile { try ScenarioFile.load(Data(json.utf8)) }

    func testContractExampleDecodes() throws {
        let f = try load(#"""
        {"name": "rename-f2", "fixture": {"files": ["a.txt", "b.txt"], "dirs": ["sub"]},
         "steps": [{"click": "a.txt"}, {"key": "F2"}, {"expect": {"renameText": "a.txt"}}, {"type": "c"}, {"key": "return"},
                   {"waitFor": {"rows": ["sub", "b.txt", "c.txt"]}, "timeoutMs": 2000},
                   {"expect": {"filesExist": ["c.txt"], "filesAbsent": ["a.txt"], "selection": ["c.txt"]}}]}
        """#)
        XCTAssertEqual(f.name, "rename-f2")
        XCTAssertEqual(f.steps.count, 7)
        XCTAssertEqual(f.steps[5].timeoutMs, 2000)
    }

    func testRejectsStepsWithZeroOrTwoActions() {
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"timeoutMs": 5}]}"#)) {
            XCTAssertEqual($0 as? ScenarioFile.ValidationError, .actionCount(step: 0, actions: []))
        }
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"key":"F2","click":"a"}]}"#)) {
            XCTAssertEqual($0 as? ScenarioFile.ValidationError, .actionCount(step: 0, actions: ["key", "click"]))
        }
    }

    func testRejectsUnknownValues() {
        let cases: [(String, ScenarioFile.ValidationError)] = [
            (#"{"key":"hyper+q"}"#, .badKey(step: 0, "hyper+q")),
            (#"{"answerConflict":"obliterate"}"#, .badConflictAction(step: 0, "obliterate")),
            (#"{"drop":{"sources":["a"],"onto":"b","choose":"symlink"}}"#, .badDropChoice(step: 0, "symlink")),
            (#"{"command":"launchRockets"}"#, .badCommand(step: 0, "launchRockets")),
            (#"{"click":"a","modifiers":["meta"]}"#, .badModifier(step: 0, "meta")),
        ]
        for (step, expected) in cases {
            XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":["# + step + #"]}"#)) {
                XCTAssertEqual($0 as? ScenarioFile.ValidationError, expected, step)
            }
        }
    }

    func testRejectsUnsafeFixtureAndExpectationPaths() {
        for bad in ["../escape.txt", "/etc/hosts", "a/../../b", "~/x", "", "a//b", "./a"] {
            XCTAssertFalse(ScenarioPath.isSafeRelative(bad), bad)
        }
        XCTAssertTrue(ScenarioPath.isSafeRelative("dest/a copy.txt"))
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":["../x"],"dirs":[]},"steps":[]}"#))
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"expect":{"filesExist":["/etc/hosts"]}}]}"#))
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":["d"],"modes":{"d":"999"}},"steps":[]}"#))
    }
}
```

`Tests/UITests/ScenarioKeySynthTests.swift`:

```swift
import AppKit
import XCTest
import Core
@testable import UI

final class ScenarioKeySynthTests: XCTestCase {
    private func spec(_ text: String) throws -> SynthKey { try XCTUnwrap(KeyChord(parsing: text).flatMap(KeySynth.spec(for:)), text) }

    func testFunctionAndArrowKeys() throws {
        let f2 = try spec("F2")
        XCTAssertEqual(f2.keyCode, 120)
        XCTAssertEqual(f2.characters, String(UnicodeScalar(UInt32(NSF2FunctionKey))!))
        XCTAssertTrue(f2.flags.contains(.function))
        let up = try spec("cmd+up")
        XCTAssertEqual(up.keyCode, 126)
        XCTAssertEqual(up.flags.intersection([.command, .function, .numericPad]), [.command, .function, .numericPad])
    }

    func testCharacterKeysUseANSIKeyCodesAndBaseCharacters() throws {
        let dot = try spec("cmd+shift+.")
        XCTAssertEqual(dot.keyCode, 47)
        XCTAssertEqual(dot.charactersIgnoringModifiers, ".")
        XCTAssertTrue(dot.flags.contains([.command, .shift]))
        XCTAssertEqual(try spec("opt+d").keyCode, 2)
        XCTAssertEqual(try spec("cmd+[").keyCode, 33)
    }

    func testEditingKeys() throws {
        XCTAssertEqual(try spec("delete").keyCode, 51)
        XCTAssertEqual(try spec("delete").characters, "\u{7F}")
        XCTAssertEqual(try spec("fn+delete").keyCode, 117)
        XCTAssertEqual(try spec("return").characters, "\r")
        XCTAssertEqual(try spec("esc").keyCode, 53)
        XCTAssertEqual(try spec("shift+tab").characters, "\u{19}")
    }

    func testUnsupportedCharacterHasNoSpec() {
        XCTAssertNil(KeySynth.spec(for: KeyChord(.character("é"))))
    }

    func testTypingSpecs() {
        let specs = KeySynth.typingSpecs("Ab/é")
        XCTAssertEqual(specs.map(\.keyCode), [0, 11, 44, 0])
        XCTAssertEqual(specs.map(\.characters), ["A", "b", "/", "é"])
        XCTAssertTrue(specs[0].flags.contains(.shift))
        XCTAssertFalse(specs[1].flags.contains(.shift))
    }
}
```

`Tests/UITests/ScenarioExpectationTests.swift`:

```swift
import XCTest
import Core
@testable import UI

final class ScenarioExpectationTests: XCTestCase {
    func testMatchingSnapshotHasNoMismatches() {
        var s = ProbeSnapshot()
        s.rows = ["sub", "b.txt"]
        s.selection = ["b.txt"]
        s.folder = "sub"
        s.emptyState = nil
        s.fileSizes = ["sub/b.txt": 3]
        let e = ScenarioFile.Expectation(rows: ["sub", "b.txt"], rowsContain: ["b.txt"], selection: ["b.txt"], folder: "sub",
                                         filesExist: ["sub/b.txt"], filesAbsent: ["a.txt"], rowCount: 2, fileSizes: ["sub/b.txt": 3])
        XCTAssertEqual(ExpectationMatcher.mismatches(e, s), [])
    }

    func testEveryMismatchIsReported() {
        var s = ProbeSnapshot()
        s.rows = ["a.txt"]
        s.folder = nil
        s.emptyState = "This folder is empty"
        let e = ScenarioFile.Expectation(rows: ["b.txt"], folder: "", emptyState: "No items match", filesExist: ["x"], editingAddress: true)
        let m = ExpectationMatcher.mismatches(e, s)
        XCTAssertEqual(m.count, 5, m.joined(separator: "\n"))
        XCTAssertTrue(m.contains { $0.contains("outside root") })
    }

    func testEmptyStateAndBannerAreSubstringMatches() {
        var s = ProbeSnapshot()
        s.emptyState = "You don't have permission to view 'locked'"
        s.banner = "'sub' was moved or deleted"
        XCTAssertEqual(ExpectationMatcher.mismatches(ScenarioFile.Expectation(emptyState: "permission", banner: "moved or deleted"), s), [])
    }

    func testStateAndFocusStrings() {
        XCTAssertEqual(ScenarioStrings.state(.complete), "complete")
        XCTAssertEqual(ScenarioStrings.state(.error(.permissionPOSIX)), "error.permissionPOSIX")
        XCTAssertEqual(ScenarioStrings.state(.error(.other(5))), "error.other.5")
        XCTAssertEqual(ScenarioStrings.focus(.sidebarFavorites), "sidebarFavorites")
    }

    func testRequestedPathsCoverAllFileExpectations() {
        let e = ScenarioFile.Expectation(filesExist: ["a"], filesAbsent: ["b"], fileSizes: ["c": 1])
        XCTAssertEqual(Set(ExpectationMatcher.requestedPaths(e)), ["a", "b", "c"])
    }
}
```

`Tests/UITests/ScenarioDriverLogicTests.swift`:

```swift
import XCTest
@testable import UI

final class ScenarioDriverLogicTests: XCTestCase {
    func testPickKeyWindowPrefersFrontmostNonSheetWindow() {
        let candidates = [
            KeyCandidate(isVisible: true, isSheet: true, canBecomeKey: true, isPanel: false),    // conflict sheet
            KeyCandidate(isVisible: false, isSheet: false, canBecomeKey: true, isPanel: false),  // closed window
            KeyCandidate(isVisible: true, isSheet: false, canBecomeKey: true, isPanel: true),    // Operations panel
            KeyCandidate(isVisible: true, isSheet: false, canBecomeKey: true, isPanel: false),   // Properties window
            KeyCandidate(isVisible: true, isSheet: false, canBecomeKey: true, isPanel: false),   // browser window
        ]
        XCTAssertEqual(ScenarioDriver.pickKeyWindow(candidates), 3)
        XCTAssertNil(ScenarioDriver.pickKeyWindow([candidates[0]]))
    }

    func testRelativePathAcceptsBothTmpSpellings() {
        let roots = ["/var/folders/x/T/macx-scenario-1/a/macx-scenario-root", "/private/var/folders/x/T/macx-scenario-1/a/macx-scenario-root"]
        XCTAssertEqual(ScenarioDriver.relativePath("/private/var/folders/x/T/macx-scenario-1/a/macx-scenario-root", roots: roots), "")
        XCTAssertEqual(ScenarioDriver.relativePath("/var/folders/x/T/macx-scenario-1/a/macx-scenario-root/sub/deep", roots: roots), "sub/deep")
        XCTAssertNil(ScenarioDriver.relativePath("/var/folders/x/T/macx-scenario-1/a/macx-scenario-rootless", roots: roots))
        XCTAssertNil(ScenarioDriver.relativePath("/Library", roots: roots))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter UITests.Scenario 2>&1 | grep -E "error:|Executed" | head -5`
Expected: `error: cannot find 'ScenarioFile' in scope` (and similar).

- [ ] **Step 3: Write the failing fixture, interaction, catalog and wiring tests**

`Tests/UITests/ScenarioFixturesTests.swift`:

```swift
import Darwin
import XCTest
import MacxFixtures
@testable import UI

final class ScenarioFixturesTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox(prefix: "macx-tests")
        addTeardownBlock { [sandbox] in
            // a mode-000 fixture folder must not block teardown
            if let s = sandbox { chmod(s.url("macx-scenario-root/closed").path, 0o755); s.destroy() }
        }
    }

    private func root() throws -> URL { try sandbox.createDirectory("macx-scenario-root").resolvingSymlinksInPath() }

    func testCreatesFilesDirsHiddenSizesAndModes() throws {
        let r = try root()
        let f = ScenarioFile.Fixture(files: ["a.txt", "dest/b.txt", "closed/c.txt"], dirs: ["empty", "closed"],
                                     hidden: ["flagged.txt"], sizes: ["dest/b.txt": 10], modes: ["closed": "000"])
        try ScenarioFixtures.create(f, in: r)
        var st = stat()
        XCTAssertEqual(lstat(r.appending(path: "dest/b.txt").path, &st), 0)
        XCTAssertEqual(st.st_size, 10)
        XCTAssertEqual(lstat(r.appending(path: "flagged.txt").path, &st), 0)
        XCTAssertNotEqual(st.st_flags & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(lstat(r.appending(path: "closed").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0)
        XCTAssertEqual(ScenarioFixtures.topLevelVisibleNames(f), ["a.txt", "dest", "closed", "empty"])
    }

    func testRefusesRootsThatAreNotEmptyScenarioSandboxes() throws {
        let other = try sandbox.createDirectory("other").resolvingSymlinksInPath()
        XCTAssertThrowsError(try ScenarioFixtures.create(.init(files: ["a"], dirs: []), in: other)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .rootNotScenarioSandbox(other.path))
        }
        let r = try root()
        try sandbox.createFile("macx-scenario-root/existing.txt")
        XCTAssertThrowsError(try ScenarioFixtures.create(.init(files: ["a"], dirs: []), in: r)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .rootNotEmpty(r.path))
        }
    }

    func testFixturesRefuseEscapingPaths() throws {
        let r = try root()
        XCTAssertThrowsError(try ScenarioFixtures.create(.init(files: ["../escape.txt"], dirs: []), in: r)) {
            XCTAssertEqual($0 as? ScenarioFixtureError, .unsafePath("../escape.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.root.appending(path: "escape.txt").path))
    }
}
```

`Tests/UITests/ScenarioInteractionTests.swift` uses a real `FileOpQueue`. The contract gives `ConflictInfo` and `JobSnapshot` no public initializers (Contract note C7), so this is the only way to obtain them.

```swift
import XCTest
import Core
import MacxFS
import MacxFixtures
@testable import UI

final class ScenarioInteractionTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws {
        sandbox = try Sandbox(prefix: "macx-tests")
        addTeardownBlock { [sandbox] in sandbox?.destroy() }
    }

    private func queue(_ interaction: any FileOpInteraction) throws -> FileOpQueue {
        let trash = try sandbox.createDirectory("trash")
        let state = try sandbox.createDirectory("state")
        return FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trash),
                           journal: Journal(fileURL: state.appending(path: "journal.json")),
                           interaction: interaction)
    }

    func testConflictIsPresentedByTheRealTargetButAnsweredByTheScenario() async throws {
        let src = try sandbox.createFile("src/a.txt", contents: Data("hello".utf8))
        try sandbox.createFile("dst/a.txt", contents: Data("x".utf8))
        let presenter = ScriptedInteraction(conflicts: [.cancelJob])     // would cancel if its answer were used
        let scenario = ScenarioInteraction(forwardingTo: presenter)
        let q = try queue(scenario)
        XCTAssertFalse(scenario.answer(.one(.skip)), "nothing pending yet")
        let id = await q.enqueue(JobRequest(.copy(sources: [src], destination: sandbox.url("dst")), registersUndo: false))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while scenario.pendingCount == 0 && clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(scenario.pendingCount, 1)
        XCTAssertTrue(scenario.answer(.one(.replace)))
        let outcome = await q.outcome(of: id)
        XCTAssertFalse(outcome.wasCancelled, "the scenario's answer wins over the presenter's")
        XCTAssertEqual(try Data(contentsOf: sandbox.url("dst/a.txt")), Data("hello".utf8))
        let presented = clock.now + .seconds(2)
        while presenter.askedConflicts().isEmpty && clock.now < presented { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(presenter.askedConflicts().count, 1, "the real dialog path was still invoked")
        XCTAssertEqual(scenario.askedCount, 1)
    }

    func testErrorsAreForwardedUnchanged() async throws {
        let presenter = ScriptedInteraction(errors: [.skip])
        let q = try queue(ScenarioInteraction(forwardingTo: presenter))
        let destination = try sandbox.createDirectory("d")
        let id = await q.enqueue(JobRequest(.copy(sources: [sandbox.url("missing.txt")], destination: destination), registersUndo: false))
        _ = await q.outcome(of: id)
        XCTAssertEqual(presenter.askedErrors().first?.kind, .sourceGone)
    }
}
```

`Tests/UITests/ScenarioCatalogTests.swift`:

```swift
import XCTest
import Core
@testable import UI

final class ScenarioCatalogTests: XCTestCase {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Scenarios")

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEveryScenarioFileDecodesValidatesAndIsNamedAfterItsFile() throws {
        let urls = try files()
        XCTAssertEqual(urls.count, 21)
        for url in urls {
            let file = try ScenarioFile.load(Data(contentsOf: url))
            XCTAssertEqual(file.name, url.deletingPathExtension().lastPathComponent)
            XCTAssertFalse(file.steps.isEmpty, file.name)
        }
    }

    func testSpecSmokeListIsCovered() throws {
        let names = Set(try files().map { $0.deletingPathExtension().lastPathComponent })
        for required in ["navigate-address-bar", "rename-f2", "cut-paste", "drag-move", "right-drag-menu", "conflict-dialog",
                         "properties", "undo-redo", "colliding-keys", "hidden-toggle", "filter-in-folder", "empty-states"] {
            XCTAssertTrue(names.contains(required), required)
        }
    }

    func testKeyNamesMapToTheIntendedKeys() {
        let table: [(String, KeyChord)] = [
            ("cmd+l", KeyChord(.character("l"), .command)), ("F2", KeyChord(.function(2))),
            ("opt+left", KeyChord(.left, .option)), ("cmd+up", KeyChord(.up, .command)),
            ("delete", KeyChord(.backspace)), ("cmd+delete", KeyChord(.backspace, .command)),
            ("opt+cmd+delete", KeyChord(.backspace, [.option, .command])), ("fn+delete", KeyChord(.forwardDelete)),
            ("shift+fn+delete", KeyChord(.forwardDelete, .shift)), ("cmd+shift+.", KeyChord(.character("."), [.command, .shift])),
            ("cmd+[", KeyChord(.character("["), .command)), ("opt+return", KeyChord(.returnKey, .option)),
            ("esc", KeyChord(.escape)), ("return", KeyChord(.returnKey)), ("ctrl+z", KeyChord(.character("z"), .control)),
        ]
        for (text, chord) in table { XCTAssertEqual(KeyChord(parsing: text), chord, text) }
    }
}
```

`Tests/UITests/ScenarioHooksWiringTests.swift` checks the P1-26…P1-36 wiring the driver relies on:

```swift
import AppKit
import XCTest
import Core
import MacxFixtures
@testable import UI

@MainActor
final class ScenarioHooksWiringTests: XCTestCase {
    func testBrowserWindowInstallsEveryScenarioHook() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("needs a GUI session") }
        let sandbox = try Sandbox(prefix: "macx-tests")
        defer { sandbox.destroy() }
        let root = try sandbox.createDirectory("macx-scenario-root")
        var options = LaunchOptions()
        options.root = root
        options.stateDirectory = try sandbox.createDirectory("state")
        let context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root), options: options)
        let window = context.windows.openWindow(at: root)
        defer { window.close() }
        let hooks = window.scenarioHooks
        XCTAssertNotNil(hooks.addressText, "P1-27")
        XCTAssertNotNil(hooks.isEditingAddress, "P1-27")
        XCTAssertNotNil(hooks.emptyStateText, "P1-33")
        XCTAssertNotNil(hooks.bannerText, "P1-33")
        XCTAssertNotNil(hooks.renameText, "P1-34")
        XCTAssertNotNil(hooks.performDrop, "P1-36")
        XCTAssertTrue(NSClassFromString("MacxApplication") == MacxApplication.self, "@objc name used by Info.plist")
    }
}
```

- [ ] **Step 4: Run them to verify they fail**

Run: `swift test --filter UITests.Scenario 2>&1 | grep -E "error:" | head -5`
Expected: compile errors for the missing `ScenarioFixtures`, `ScenarioInteraction`, `MacxApplication` and related types.

- [ ] **Step 5: Implement the schema, key synthesis, matcher, fixtures, decorator and application class**

`Sources/UI/App/MacxApplication.swift`:

```swift
import AppKit

/// The app's NSApplication (main.swift instantiates it; Info.plist NSPrincipalClass = MacxApplication).
/// Only in UI scenario runs does ScenarioDriver set `scenarioKeyWindow`. AppKit then resolves nil-targeted
/// actions and menu validation through that window even when macOS refused to activate the process
/// (cooperative activation; verified 2026-11-02). With it nil, which is always the case outside
/// `--scenario`, every override defers to AppKit.
@objc(MacxApplication)
public final class MacxApplication: NSApplication {
    @MainActor static var scenarioKeyWindow: NSWindow?
    public override var keyWindow: NSWindow? { MacxApplication.scenarioKeyWindow ?? super.keyWindow }
    public override var mainWindow: NSWindow? { MacxApplication.scenarioKeyWindow ?? super.mainWindow }
    public override var isActive: Bool { MacxApplication.scenarioKeyWindow != nil || super.isActive }
}
```

`Sources/UI/Scenario/ScenarioFile.swift`:

```swift
import Core
import Foundation

/// §3.14 schema (field names and types exactly as in the contract) plus additive optional fields
/// (Contract note C6): Fixture.modes, Step.command, Step.answerAlert, Expectation.rowCount/editingAddress/
/// viewMode/sheetPresent/propertiesWindows/windowCount/fileSizes.
struct ScenarioFile: Codable {
    struct Fixture: Codable {
        var files: [String]
        var dirs: [String]
        var hidden: [String]?
        var sizes: [String: Int]?
        var modes: [String: String]?          // additive: octal mode applied after creation, deepest first
    }
    struct Step: Codable {
        var key: String?
        var type: String?
        var menu: [String]?
        var click: String?
        var doubleClick: String?
        var rightClick: String?
        var modifiers: [String]?
        var chooseMenuItem: String?
        var drop: Drop?
        var answerConflict: String?
        var applyToAll: Bool?
        var waitFor: Expectation?
        var timeoutMs: Int?
        var expect: Expectation?
        var sleepMs: Int?
        var command: String?                  // additive: Command raw value, performed via its main-menu item
        var answerAlert: String?              // additive: press this button of an AppKit alert/sheet

        var actions: [String] {
            let named: [(String, Bool)] = [
                ("key", key != nil), ("type", type != nil), ("menu", menu != nil), ("command", command != nil),
                ("click", click != nil), ("doubleClick", doubleClick != nil), ("rightClick", rightClick != nil),
                ("chooseMenuItem", chooseMenuItem != nil), ("drop", drop != nil), ("answerConflict", answerConflict != nil),
                ("answerAlert", answerAlert != nil), ("waitFor", waitFor != nil), ("expect", expect != nil), ("sleepMs", sleepMs != nil),
            ]
            return named.filter { $0.1 }.map { $0.0 }
        }
    }
    struct Drop: Codable {
        var sources: [String]
        var onto: String
        var secondary: Bool?
        var choose: String?
    }
    struct Expectation: Codable {
        var rows: [String]?
        var rowsContain: [String]?
        var selection: [String]?
        var cut: [String]?
        var folder: String?
        var state: String?
        var focus: String?
        var fieldEditorText: String?
        var renameText: String?
        var emptyState: String?               // substring match (Contract note C6)
        var banner: String?                   // substring match
        var filesExist: [String]?
        var filesAbsent: [String]?
        var rowCount: Int?
        var editingAddress: Bool?
        var viewMode: String?
        var sheetPresent: Bool?
        var propertiesWindows: Int?
        var windowCount: Int?
        var fileSizes: [String: Int]?
    }
    var name: String
    var fixture: Fixture
    var steps: [Step]

    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case actionCount(step: Int, actions: [String])
        case badKey(step: Int, String)
        case badConflictAction(step: Int, String)
        case badDropChoice(step: Int, String)
        case badCommand(step: Int, String)
        case badModifier(step: Int, String)
        case unsafePath(String)
        case badMode(String, String)
        var description: String {
            switch self {
            case .actionCount(let s, let a): "step \(s): exactly one action required, found \(a)"
            case .badKey(let s, let k): "step \(s): key '\(k)' cannot be parsed or synthesized"
            case .badConflictAction(let s, let a): "step \(s): unknown conflict action '\(a)'"
            case .badDropChoice(let s, let c): "step \(s): unsupported drop choice '\(c)' (copy, move, alias, cancel; see Contract note C5)"
            case .badCommand(let s, let c): "step \(s): unknown command '\(c)'"
            case .badModifier(let s, let m): "step \(s): unknown modifier '\(m)' (cmd, shift, opt, ctrl)"
            case .unsafePath(let p): "unsafe relative path '\(p)'"
            case .badMode(let p, let m): "bad octal mode '\(m)' for '\(p)'"
            }
        }
    }

    static let modifierNames: Set<String> = ["cmd", "shift", "opt", "ctrl"]
    static let dropChoices: Set<String> = ["copy", "move", "alias", "cancel"]

    func validate() throws(ValidationError) {
        let fixturePaths = fixture.files + fixture.dirs + (fixture.hidden ?? [])
            + Array((fixture.sizes ?? [:]).keys) + Array((fixture.modes ?? [:]).keys)
        for path in fixturePaths where !ScenarioPath.isSafeRelative(path) { throw .unsafePath(path) }
        for (path, mode) in fixture.modes ?? [:] where mode.count > 4 || UInt16(mode, radix: 8) == nil { throw .badMode(path, mode) }
        for (index, step) in steps.enumerated() {
            let actions = step.actions
            guard actions.count == 1 else { throw .actionCount(step: index, actions: actions) }
            if let key = step.key, KeyChord(parsing: key).flatMap(KeySynth.spec(for:)) == nil { throw .badKey(step: index, key) }
            if let action = step.answerConflict, ConflictAction(rawValue: action) == nil { throw .badConflictAction(step: index, action) }
            if let choice = step.drop?.choose, !Self.dropChoices.contains(choice) { throw .badDropChoice(step: index, choice) }
            if let command = step.command, Command(rawValue: command) == nil { throw .badCommand(step: index, command) }
            for modifier in step.modifiers ?? [] where !Self.modifierNames.contains(modifier) { throw .badModifier(step: index, modifier) }
            let paths = (step.waitFor.map(ExpectationMatcher.requestedPaths) ?? []) + (step.expect.map(ExpectationMatcher.requestedPaths) ?? [])
            for path in paths where !ScenarioPath.isSafeRelative(path) { throw .unsafePath(path) }
        }
    }

    static func load(_ data: Data) throws -> ScenarioFile {
        let file = try JSONDecoder().decode(ScenarioFile.self, from: data)
        try file.validate()
        return file
    }
}

enum ScenarioPath {
    /// Non-empty, relative, no "~", and no empty, "." or ".." components.
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
```

`Sources/UI/Scenario/KeySynth.swift`:

```swift
import AppKit
import Core

struct SynthKey: Equatable, Sendable {
    var keyCode: UInt16
    var characters: String
    var charactersIgnoringModifiers: String
    var flags: NSEvent.ModifierFlags
}

/// KeyChord → the NSEvent fields a real keyboard would produce (ANSI layout key codes, so
/// KeyEventTranslator's characters(byApplyingModifiers: []) sees the right base character).
enum KeySynth {
    static let ansiKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]
    static let functionKeyCodes: [Int: UInt16] = [1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100, 9: 101, 10: 109, 11: 103, 12: 111]

    static func flags(_ modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if modifiers.contains(.command) { f.insert(.command) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.control) { f.insert(.control) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        return f
    }

    static func spec(for chord: KeyChord) -> SynthKey? {
        let base = flags(chord.modifiers)
        func plain(_ s: String, _ code: UInt16) -> SynthKey { SynthKey(keyCode: code, characters: s, charactersIgnoringModifiers: s, flags: base) }
        func function(_ scalar: Int, _ code: UInt16, numericPad: Bool = false) -> SynthKey? {
            guard let u = UnicodeScalar(UInt32(scalar)) else { return nil }
            var f = base
            f.insert(.function)
            if numericPad { f.insert(.numericPad) }
            let s = String(Character(u))
            return SynthKey(keyCode: code, characters: s, charactersIgnoringModifiers: s, flags: f)
        }
        switch chord.key {
        case .character(let c):
            guard c.count == 1, let ch = c.first, let code = ansiKeyCodes[ch] else { return nil }
            let shown = chord.modifiers.contains(.shift) && !chord.modifiers.contains(.command) ? c.uppercased() : c
            return SynthKey(keyCode: code, characters: shown, charactersIgnoringModifiers: c, flags: base)
        case .up: return function(NSUpArrowFunctionKey, 126, numericPad: true)
        case .down: return function(NSDownArrowFunctionKey, 125, numericPad: true)
        case .left: return function(NSLeftArrowFunctionKey, 123, numericPad: true)
        case .right: return function(NSRightArrowFunctionKey, 124, numericPad: true)
        case .returnKey: return plain("\r", 36)
        case .enter: return plain("\u{03}", 76)
        case .tab: return plain(chord.modifiers.contains(.shift) ? "\u{19}" : "\t", 48)
        case .escape: return plain("\u{1B}", 53)
        case .space: return plain(" ", 49)
        case .backspace: return plain("\u{7F}", 51)
        case .forwardDelete: return function(NSDeleteFunctionKey, 117)
        case .function(let n):
            guard let code = functionKeyCodes[n] else { return nil }
            return function(NSF1FunctionKey + n - 1, code)
        }
    }

    /// One key per character; unknown characters use key code 0 (the text system inserts `characters`).
    static func typingSpecs(_ text: String) -> [SynthKey] {
        text.map { ch in
            let lower = Character(ch.lowercased())
            let isUpper = ch.isUppercase
            let s = String(ch)
            return SynthKey(keyCode: ansiKeyCodes[lower] ?? 0, characters: s, charactersIgnoringModifiers: s.lowercased(),
                            flags: isUpper ? [.shift] : [])
        }
    }

    @MainActor
    static func events(_ key: SynthKey, windowNumber: Int) -> [NSEvent] {
        [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
                             characters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                             isARepeat: false, keyCode: key.keyCode)
        }
    }
}
```

`Sources/UI/Scenario/ExpectationMatcher.swift`:

```swift
import Core
import Foundation

struct ProbeSnapshot: Equatable {
    var rows: [String] = []
    var selection: [String] = []
    var cut: [String] = []
    var folder: String? = ""                 // relative to --root; nil = outside it
    var state = "complete"
    var focus = "content"
    var fieldEditorText: String?
    var renameText: String?
    var emptyState: String?
    var banner: String?
    var editingAddress = false
    var viewMode = "details"
    var sheetPresent = false
    var propertiesWindows = 0
    var windowCount = 1
    var fileSizes: [String: Int] = [:]       // requested paths that exist → st_size
}

enum ScenarioStrings {
    static func state(_ s: FolderState) -> String {
        switch s {
        case .loading: "loading"
        case .partial: "partial"
        case .complete: "complete"
        case .unresponsive: "unresponsive"
        case .waitingForPermission: "waitingForPermission"
        case .error(let r): "error." + reason(r)
        }
    }
    static func reason(_ r: Reason) -> String {
        switch r {
        case .notFound: "notFound"
        case .notADirectory: "notADirectory"
        case .permissionPOSIX: "permissionPOSIX"
        case .permissionTCC: "permissionTCC"
        case .volumeGone: "volumeGone"
        case .other(let code): "other.\(code)"
        }
    }
    static func focus(_ f: FocusContext) -> String { String(describing: f) }
}

enum ExpectationMatcher {
    static func requestedPaths(_ e: ScenarioFile.Expectation) -> [String] {
        (e.filesExist ?? []) + (e.filesAbsent ?? []) + Array((e.fileSizes ?? [:]).keys)
    }

    static func mismatches(_ e: ScenarioFile.Expectation, _ s: ProbeSnapshot) -> [String] {
        var m: [String] = []
        func check<T: Equatable>(_ label: String, _ expected: T?, _ actual: T) {
            if let expected, expected != actual { m.append("\(label): expected \(expected), got \(actual)") }
        }
        check("rows", e.rows, s.rows)
        if let want = e.rowsContain {
            let missing = want.filter { !s.rows.contains($0) }
            if !missing.isEmpty { m.append("rowsContain: missing \(missing) in \(s.rows)") }
        }
        check("rowCount", e.rowCount, s.rows.count)
        if let want = e.selection, Set(want) != Set(s.selection) { m.append("selection: expected \(want), got \(s.selection)") }
        if let want = e.cut, Set(want) != Set(s.cut) { m.append("cut: expected \(want), got \(s.cut)") }
        if let want = e.folder, want != s.folder {
            m.append("folder: expected '\(want)', got \(s.folder.map { "'\($0)'" } ?? "a folder outside root")")
        }
        check("state", e.state, s.state)
        check("focus", e.focus, s.focus)
        if let want = e.fieldEditorText, want != s.fieldEditorText { m.append("fieldEditorText: expected '\(want)', got \(String(describing: s.fieldEditorText))") }
        if let want = e.renameText, want != s.renameText { m.append("renameText: expected '\(want)', got \(String(describing: s.renameText))") }
        if let want = e.emptyState, !(s.emptyState?.contains(want) ?? false) { m.append("emptyState: expected to contain '\(want)', got \(String(describing: s.emptyState))") }
        if let want = e.banner, !(s.banner?.contains(want) ?? false) { m.append("banner: expected to contain '\(want)', got \(String(describing: s.banner))") }
        check("editingAddress", e.editingAddress, s.editingAddress)
        check("viewMode", e.viewMode, s.viewMode)
        check("sheetPresent", e.sheetPresent, s.sheetPresent)
        check("propertiesWindows", e.propertiesWindows, s.propertiesWindows)
        check("windowCount", e.windowCount, s.windowCount)
        for path in e.filesExist ?? [] where s.fileSizes[path] == nil { m.append("filesExist: '\(path)' is missing") }
        for path in e.filesAbsent ?? [] where s.fileSizes[path] != nil { m.append("filesAbsent: '\(path)' exists") }
        for (path, size) in (e.fileSizes ?? [:]).sorted(by: { $0.key < $1.key }) where s.fileSizes[path] != size {
            m.append("fileSizes: '\(path)' expected \(size) bytes, got \(s.fileSizes[path].map { String($0) } ?? "missing")")
        }
        return m
    }
}
```

`Sources/UI/Scenario/ScenarioFixtures.swift`:

```swift
import Darwin
import Foundation

enum ScenarioFixtureError: Error, Equatable, CustomStringConvertible {
    case rootNotScenarioSandbox(String)
    case rootNotEmpty(String)
    case unsafePath(String)
    case io(String, Int32)
    case badMode(String)
    var description: String {
        switch self {
        case .rootNotScenarioSandbox(let p): "refusing: --root \(p) is not a macx-scenario-* directory"
        case .rootNotEmpty(let p): "refusing: --root \(p) is not empty"
        case .unsafePath(let p): "refusing unsafe fixture path '\(p)'"
        case .io(let p, let e): "fixture I/O failed for '\(p)' (errno \(e))"
        case .badMode(let p): "bad mode for '\(p)'"
        }
    }
}

enum ScenarioFixtures {
    static let rootPrefix = "macx-scenario-"

    /// Synchronous: call only inside lane work. `root` must already be symlink-resolved. Refuses unless root's
    /// last component starts with "macx-scenario-" and root is empty; every path must stay inside root.
    static func create(_ fixture: ScenarioFile.Fixture, in root: URL) throws(ScenarioFixtureError) {
        guard root.lastPathComponent.hasPrefix(rootPrefix) else { throw .rootNotScenarioSandbox(root.path) }
        let fm = FileManager.default
        let existing: [String]
        do { existing = try fm.contentsOfDirectory(atPath: root.path) } catch { throw .io(root.path, Int32((error as NSError).code)) }
        guard existing.isEmpty else { throw .rootNotEmpty(root.path) }
        let rootPath = root.standardizedFileURL.path

        func target(_ relative: String) throws(ScenarioFixtureError) -> URL {
            guard ScenarioPath.isSafeRelative(relative) else { throw .unsafePath(relative) }
            let url = root.appending(path: relative)
            guard url.standardizedFileURL.path.hasPrefix(rootPath + "/") else { throw .unsafePath(relative) }
            return url
        }

        for dir in fixture.dirs {
            let url = try target(dir)
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch { throw .io(dir, Int32((error as NSError).code)) }
        }
        let hidden = fixture.hidden ?? []
        for path in fixture.files + hidden {
            let url = try target(path)
            do { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
                throw .io(path, Int32((error as NSError).code))
            }
            let data = fixture.sizes?[path].map { Data(repeating: 0x78, count: $0) } ?? Data("x".utf8)
            guard fm.createFile(atPath: url.path, contents: data) else { throw .io(path, errno) }
            if hidden.contains(path), chflags(url.path, UInt32(UF_HIDDEN)) != 0 { throw .io(path, errno) }
        }
        for (path, mode) in (fixture.modes ?? [:]).sorted(by: { $0.key.count > $1.key.count }) {
            let url = try target(path)
            guard let bits = UInt16(mode, radix: 8) else { throw .badMode(path) }
            if chmod(url.path, mode_t(bits)) != 0 { throw .io(path, errno) }
        }
    }

    /// Names the browser should list in --root once the fixture exists (Show Hidden off).
    static func topLevelVisibleNames(_ fixture: ScenarioFile.Fixture) -> Set<String> {
        let hidden = Set(fixture.hidden ?? [])
        return Set((fixture.files + fixture.dirs).filter { !hidden.contains($0) }
            .compactMap { $0.split(separator: "/").first.map(String.init) }
            .filter { !$0.hasPrefix(".") })
    }
}
```

`Sources/UI/Scenario/ScenarioInteraction.swift`:

```swift
import Core
import Foundation
import Synchronization

/// Scenario-only FileOpInteraction decorator, installed by ScenarioDriver around the real router.
/// Conflicts are still forwarded, so InteractionRouter presents the real dialog on the origin window (the
/// scenario checks the sheet). The answer comes from the scenario's `answerConflict` step, because SwiftUI
/// dialogs expose no in-process accessibility tree to press (Contract note C4). Errors, the space
/// shortfall and no-trash prompts are forwarded unchanged.
final class ScenarioInteraction: FileOpInteraction {
    private struct State {
        var pending: [CheckedContinuation<ConflictResolution, Never>] = []
        var asked: Int = 0
    }
    private let forward: any FileOpInteraction
    private let state = Mutex(State())

    init(forwardingTo forward: any FileOpInteraction) { self.forward = forward }

    var pendingCount: Int { state.withLock { $0.pending.count } }
    var askedCount: Int { state.withLock { $0.asked } }

    /// Resolves the oldest pending conflict; false if none is pending.
    func answer(_ resolution: ConflictResolution) -> Bool {
        let next = state.withLock { s -> CheckedContinuation<ConflictResolution, Never>? in
            s.pending.isEmpty ? nil : s.pending.removeFirst()
        }
        next?.resume(returning: resolution)
        return next != nil
    }

    func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
        let forward = self.forward
        let presenter = Task { _ = await forward.resolveConflict(conflict, job: job) }   // shows the dialog; answer ignored
        let resolution = await withCheckedContinuation { continuation in
            state.withLock {
                $0.pending.append(continuation)
                $0.asked += 1
            }
        }
        presenter.cancel()
        return resolution
    }

    func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        await forward.resolveError(error, job: job)
    }

    func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        await forward.confirmInsufficientSpace(shortfall, job: job)
    }

    func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        await forward.confirmPermanentDeleteWithoutTrash(urls, job: job)
    }
}
```

- [ ] **Step 6: Implement the driver and the launch hook, and wire them into the app**

`Sources/UI/Scenario/ScenarioDriver.swift`:

```swift
import AppKit
import Core
import Darwin
import MacxFS

struct KeyCandidate: Equatable, Sendable {
    var isVisible: Bool
    var isSheet: Bool
    var canBecomeKey: Bool
    var isPanel: Bool
}

struct UIScenarioResult: Codable, Equatable {
    var name: String
    var passed = false
    var failedStep: Int?
    var message: String?
    var durationMs = 0
    var activated = false        // additive: did macOS actually activate the process?
}

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// In-process UI scenario runner (§9 UI smoke suite). Started by ScenarioLaunch when --scenario is set.
@MainActor
final class ScenarioDriver {
    static let fenceSubtype: Int16 = 0x4D58
    private let context: UIContext
    private let file: URL
    private let output: URL
    private var rootReal: URL?
    private var rootPrefixes: [String] = []
    private var decorator: ScenarioInteraction?
    private var contextMenu: NSMenu?
    private var fenceWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextFence = 1
    private var monitor: Any?

    init(context: UIContext, file: URL, output: URL) {
        self.context = context
        self.file = file
        self.output = output
    }

    // MARK: pure helpers (unit-tested)

    nonisolated static func pickKeyWindow(_ candidates: [KeyCandidate]) -> Int? {
        candidates.firstIndex { $0.isVisible && !$0.isSheet && $0.canBecomeKey && !$0.isPanel }
    }

    /// `path` relative to whichever spelling of the root matches (/var/... vs /private/var/...); nil if outside.
    nonisolated static func relativePath(_ path: String, roots: [String]) -> String? {
        for root in roots {
            if path == root { return "" }
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return nil
    }

    // MARK: run

    func run() async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        var result = UIScenarioResult(name: file.deletingPathExtension().lastPathComponent)
        do {
            let scenario = try await loadScenario()
            result.name = scenario.name
            try await prepare(scenario.fixture)
            for (index, step) in scenario.steps.enumerated() {
                do { try await perform(step) } catch {
                    result.failedStep = index
                    throw error
                }
            }
            result.passed = true
        } catch {
            result.message = String(describing: error)
        }
        let elapsed = (clock.now - started).components
        result.durationMs = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        result.activated = NSRunningApplication.current.isActive
        await write(result)
        teardown()
        return result.passed
    }

    private var lanes: LanePool { context.environment.lanes }

    private func loadScenario() async throws -> ScenarioFile {
        let url = file
        let data = try await lanes.perform(on: .unknown) { _ in try Data(contentsOf: url) }
        return try ScenarioFile.load(data)
    }

    private func prepare(_ fixture: ScenarioFile.Fixture) async throws {
        guard let given = context.options.root else { throw DriverError("--scenario requires --root") }
        let real = try await lanes.perform(on: .unknown) { _ in
            let resolved = given.resolvingSymlinksInPath()
            try ScenarioFixtures.create(fixture, in: resolved)
            return resolved
        }
        rootReal = real
        rootPrefixes = [given.standardizedFileURL.path, real.standardizedFileURL.path]
        installRouting()
        let window = try browserWindow()
        window.session.reload()
        let expected = ScenarioFixtures.topLevelVisibleNames(fixture)
        try await waitUntil("the fixture is listed", timeout: .seconds(5)) {
            Set(window.probeRowNames) == expected && window.probeFolderState == .complete
        }
        focusList(in: window)
    }

    private func installRouting() {
        // Real activation where macOS allows it (cooperative activation may refuse; see fact 4).
        _ = NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: NSNumber(value: true))
        MacxApplication.scenarioKeyWindow = (try? browserWindow())?.window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            guard event.subtype.rawValue == ScenarioDriver.fenceSubtype else { return event }
            self?.releaseFence(event.data1)
            return nil
        }
        let decorator = ScenarioInteraction(forwardingTo: context.interaction)
        context.installInteraction(decorator)
        self.decorator = decorator
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @objc private func menuDidBeginTracking(_ note: Notification) {
        // A real popUpContextMenu (e.g. from a key or tracker) becomes the menu chooseMenuItem acts on.
        if let menu = note.object as? NSMenu, menu !== NSApp.mainMenu { contextMenu = menu }
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        MacxApplication.scenarioKeyWindow = nil
    }

    private func write(_ result: UIScenarioResult) async {
        guard let data = try? JSONEncoder().encode(result) else { return }
        let url = output
        _ = try? await lanes.perform(on: .unknown) { _ in try data.write(to: url, options: .atomic) }
    }

    // MARK: windows

    private func refreshKeyWindow() {
        let windows = NSApp.orderedWindows
        let candidates = windows.map {
            KeyCandidate(isVisible: $0.isVisible, isSheet: $0.sheetParent != nil, canBecomeKey: $0.canBecomeKey, isPanel: $0 is NSPanel)
        }
        if let index = Self.pickKeyWindow(candidates) { MacxApplication.scenarioKeyWindow = windows[index] }
    }

    private func browserWindow() throws -> BrowserWindowController {
        let all = context.windows.windows
        if let key = MacxApplication.scenarioKeyWindow, let match = all.first(where: { $0.window === key }) { return match }
        if let first = all.first { return first }
        throw DriverError("no browser window is open")
    }

    private func keyWindowNumber() throws -> Int {
        if let key = MacxApplication.scenarioKeyWindow { return key.windowNumber }
        guard let number = try browserWindow().window?.windowNumber else { throw DriverError("browser window has no NSWindow") }
        return number
    }

    private func listView(in controller: BrowserWindowController) -> NSView? {
        guard let root = controller.window?.contentView else { return nil }
        let ids: Set<String> = [AXID.detailsTable, AXID.iconsGrid]
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            let id = view.accessibilityIdentifier()
            if (ids.contains(id) || ids.contains(view.identifier?.rawValue ?? "")) && !view.isHiddenOrHasHiddenAncestor {
                return (view as? NSScrollView)?.documentView ?? view
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func focusList(in controller: BrowserWindowController) {
        MacxApplication.scenarioKeyWindow = controller.window
        controller.window?.orderFront(nil)
        if let list = listView(in: controller) { controller.window?.makeFirstResponder(list) }
    }

    private func contentController(in controller: BrowserWindowController) -> ContentViewController? {
        var responder: NSResponder? = listView(in: controller)
        while let r = responder {
            if let content = r as? ContentViewController { return content }
            responder = r.nextResponder
        }
        return nil
    }

    // MARK: fences and waits

    private func releaseFence(_ id: Int) { fenceWaiters.removeValue(forKey: id)?.resume() }

    /// Waits until every event posted before it has been dispatched (or 2 s, e.g. a modal loop swallowed it).
    private func fence() async {
        guard let number = try? keyWindowNumber() else { return }
        let id = nextFence
        nextFence += 1
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: number, context: nil, subtype: Self.fenceSubtype,
                                             data1: id, data2: 0) else { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.releaseFence(id)
        }
        await withCheckedContinuation { continuation in
            fenceWaiters[id] = continuation
            NSApp.postEvent(event, atStart: false)
        }
        timer.cancel()
    }

    private func waitUntil(_ what: String, timeout: Duration, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { throw DriverError("timed out after \(timeout) waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func milliseconds(_ ms: Int?, default fallback: Int) -> Duration { .milliseconds(ms ?? fallback) }

    // MARK: steps

    private func perform(_ step: ScenarioFile.Step) async throws {
        refreshKeyWindow()
        if let key = step.key { try await sendKey(key) }
        else if let text = step.type { try await typeText(text) }
        else if let path = step.menu { try performMenu(path: path); await fence() }
        else if let command = step.command { try performCommand(command); await fence() }
        else if let name = step.click { try click(name, modifiers: step.modifiers ?? []) }
        else if let name = step.doubleClick { try doubleClick(name); await fence() }
        else if let name = step.rightClick { try openContextMenu(on: name) }
        else if let title = step.chooseMenuItem { try chooseMenuItem(title); await fence() }
        else if let drop = step.drop { try await performDrop(drop, modifiers: step.modifiers ?? []) }
        else if let action = step.answerConflict {
            try await answerConflict(action, all: step.applyToAll ?? false, timeout: milliseconds(step.timeoutMs, default: 5_000))
        }
        else if let title = step.answerAlert { try await answerAlert(title, timeout: milliseconds(step.timeoutMs, default: 3_000)) }
        else if let expectation = step.waitFor { try await waitFor(expectation, timeout: milliseconds(step.timeoutMs, default: 3_000)) }
        else if let expectation = step.expect {
            let problems = ExpectationMatcher.mismatches(expectation, try await snapshot(for: expectation))
            if !problems.isEmpty { throw DriverError(problems.joined(separator: "; ")) }
        }
        else if let ms = step.sleepMs { try await Task.sleep(for: .milliseconds(ms)) }
    }

    private func post(_ keys: [SynthKey]) throws {
        let number = try keyWindowNumber()
        for key in keys { for event in KeySynth.events(key, windowNumber: number) { NSApp.postEvent(event, atStart: false) } }
    }

    private func sendKey(_ text: String) async throws {
        guard let chord = KeyChord(parsing: text), let key = KeySynth.spec(for: chord) else { throw DriverError("cannot synthesize '\(text)'") }
        try post([key])
        await fence()
    }

    private func typeText(_ text: String) async throws {
        try post(KeySynth.typingSpecs(text))
        await fence()
    }

    private func invoke(_ item: NSMenuItem, in menu: NSMenu) throws {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        guard item.isEnabled else { throw DriverError("menu item '\(item.title)' is disabled") }
        let index = menu.index(of: item)
        guard index >= 0 else { throw DriverError("menu item '\(item.title)' left its menu") }
        menu.performActionForItem(at: index)
    }

    private func performMenu(path: [String]) throws {
        guard var menu = NSApp.mainMenu else { throw DriverError("no main menu") }
        for (i, title) in path.enumerated() {
            guard let item = menu.items.first(where: { $0.title == title || $0.submenu?.title == title }) else {
                throw DriverError("menu '\(title)' not found among \(menu.items.map { $0.submenu?.title ?? $0.title })")
            }
            if i == path.count - 1 { return try invoke(item, in: menu) }
            guard let sub = item.submenu else { throw DriverError("'\(title)' has no submenu") }
            sub.delegate?.menuNeedsUpdate?(sub)
            menu = sub
        }
    }

    private func findItem(_ menu: NSMenu, _ matches: (NSMenuItem) -> Bool) -> (NSMenuItem, NSMenu)? {
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if matches(item) { return (item, menu) }
            if let sub = item.submenu, let found = findItem(sub, matches) { return found }
        }
        return nil
    }

    private func performCommand(_ raw: String) throws {
        guard let command = Command(rawValue: raw), let main = NSApp.mainMenu else { throw DriverError("unknown command '\(raw)'") }
        let selector = Selector(command.selectorName)
        guard let (item, menu) = findItem(main, { $0.action == selector }) else {
            throw DriverError("no main-menu item for command \(raw) (\(command.selectorName))")
        }
        try invoke(item, in: menu)
    }

    private func row(named name: String, in controller: BrowserWindowController) throws -> Int {
        guard let row = controller.probeRowNames.firstIndex(of: name) else {
            throw DriverError("no row named '\(name)' in \(controller.probeRowNames)")
        }
        return row
    }

    /// Model-level click: the SelectionCommand P1-33 maps the click to (fact 4: synthesized clicks don't work inactive).
    private func click(_ name: String, modifiers: [String]) throws {
        let controller = try browserWindow()
        let row = try row(named: name, in: controller)
        let command: SelectionCommand =
            modifiers.contains("cmd") ? .toggle(row)
            : modifiers.contains("shift") ? .extend(to: row)
            : .set(IndexSet(integer: row), cursor: row)
        controller.session.folder.select(command)
        focusList(in: controller)
    }

    private func doubleClick(_ name: String) throws {
        try click(name, modifiers: [])
        guard NSApp.sendAction(Selector(Command.open.selectorName), to: nil, from: nil) else {
            throw DriverError("\(Command.open.selectorName) was not handled by the responder chain")
        }
    }

    private func openContextMenu(on name: String) throws {
        let controller = try browserWindow()
        guard let content = contentController(in: controller), let handler = content.handler else {
            throw DriverError("content view controller or its command handler not found")
        }
        let folder = controller.session.folder
        let builder = ContextMenuBuilder(context: context)
        if name.isEmpty {
            contextMenu = builder.emptySpaceMenu(for: folder, handler: handler)
        } else {
            let row = try row(named: name, in: controller)
            if !folder.selection.rows.contains(row) { folder.select(.set(IndexSet(integer: row), cursor: row)) }
            contextMenu = builder.itemMenu(for: folder.selection.rows, in: folder, handler: handler)
        }
        focusList(in: controller)
    }

    private func chooseMenuItem(_ title: String) throws {
        guard let menu = contextMenu else { throw DriverError("no context menu is open") }
        guard let (item, owner) = findItem(menu, { $0.title == title }) else {
            throw DriverError("'\(title)' not in the context menu: \(menu.items.map(\.title))")
        }
        menu.cancelTracking()
        contextMenu = nil
        try invoke(item, in: owner)
    }

    private func performDrop(_ drop: ScenarioFile.Drop, modifiers: [String]) async throws {
        let controller = try browserWindow()
        let folderURL = controller.probeFolderURL
        var mods = DragModifiers()
        if modifiers.contains("opt") { mods.insert(.option) }
        if modifiers.contains("cmd") { mods.insert(.command) }
        if modifiers.contains("ctrl") { mods.insert(.control) }
        let choice: DragOperation? = try drop.choose.map { raw -> DragOperation in
            switch raw {
            case "copy": .copy
            case "move": .move
            case "alias": .alias
            case "cancel": DragOperation.none
            default: throw DriverError("unsupported drop choice '\(raw)' (Contract note C5)")
            }
        }
        await controller.probePerformDrop(sources: drop.sources.map { folderURL.appending(path: $0) }, onto: drop.onto,
                                          modifiers: mods, secondary: drop.secondary ?? false, menuChoice: choice)
        await fence()
    }

    private func answerConflict(_ raw: String, all: Bool, timeout: Duration) async throws {
        guard let action = ConflictAction(rawValue: raw), let decorator else { throw DriverError("bad conflict answer '\(raw)'") }
        try await waitUntil("a conflict to be asked", timeout: timeout) { decorator.pendingCount > 0 }
        let controller = try browserWindow()
        try await waitUntil("the conflict dialog on the origin window", timeout: .seconds(3)) {
            controller.window?.attachedSheet != nil
        }
        _ = decorator.answer(all ? .all(action) : .one(action))
        if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        await fence()
    }

    private func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private func answerAlert(_ title: String, timeout: Duration) async throws {
        var found: [String] = []
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            var windows: [NSWindow] = []
            if let modal = NSApp.modalWindow { windows.append(modal) }
            windows += context.windows.windows.compactMap { $0.window?.attachedSheet }
            for window in windows {
                guard let root = window.contentView else { continue }
                let candidates = buttons(in: root)
                found = candidates.map(\.title)
                if let button = candidates.first(where: { $0.title == title && $0.isEnabled }) {
                    button.performClick(nil)
                    await fence()
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DriverError("no alert button '\(title)' (buttons seen: \(found))")
    }

    private func waitFor(_ expectation: ScenarioFile.Expectation, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var problems: [String] = []
        repeat {
            problems = ExpectationMatcher.mismatches(expectation, try await snapshot(for: expectation))
            if problems.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        } while clock.now < deadline
        throw DriverError("after \(timeout): " + problems.joined(separator: "; "))
    }

    private func snapshot(for expectation: ScenarioFile.Expectation) async throws -> ProbeSnapshot {
        let w = try browserWindow()
        var s = ProbeSnapshot()
        s.rows = w.probeRowNames
        s.selection = w.probeSelectedNames
        s.cut = w.probeCutNames
        s.folder = Self.relativePath(w.probeFolderURL.standardizedFileURL.path, roots: rootPrefixes)
        s.state = ScenarioStrings.state(w.probeFolderState)
        s.focus = ScenarioStrings.focus(w.probeFocus)
        s.fieldEditorText = w.probeFieldEditorText
        s.renameText = w.probeRenameText
        s.emptyState = w.probeEmptyStateText
        s.banner = w.probeBannerText
        s.editingAddress = w.probeIsEditingAddress
        s.viewMode = w.probeViewMode.rawValue
        s.sheetPresent = w.window?.attachedSheet != nil
        s.propertiesWindows = NSApp.windows.filter {
            $0.isVisible && ($0.identifier?.rawValue == AXID.propertiesWindow || $0.accessibilityIdentifier() == AXID.propertiesWindow)
        }.count
        s.windowCount = context.windows.windows.count
        let paths = ExpectationMatcher.requestedPaths(expectation).filter(ScenarioPath.isSafeRelative)
        if !paths.isEmpty, let root = rootReal {
            s.fileSizes = try await lanes.perform(on: .unknown) { _ in
                var sizes: [String: Int] = [:]
                for path in paths {
                    var st = stat()
                    if lstat(root.appending(path: path).path, &st) == 0 { sizes[path] = Int(st.st_size) }
                }
                return sizes
            }
        }
        return s
    }
}
```

`Sources/UI/Scenario/ScenarioLaunch.swift`:

```swift
import AppKit
import Core
import Foundation

public enum ScenarioLaunch {
    /// Call once the first browser window is open. A no-op unless --scenario was given; otherwise runs the
    /// driver, releases the private pasteboard, and exits 0 (passed) or 1 (failed). It skips
    /// applicationShouldTerminate: sandbox runs have nothing to save, and ui-scenarios.sh deletes the sandbox.
    @MainActor public static func runIfRequested(context: UIContext) {
        guard let file = context.options.scenario else { return }
        let stateDirectory = context.options.stateDirectory ?? FileManager.default.temporaryDirectory
        let output = context.options.scenarioOutput ?? stateDirectory.appending(path: "scenario-result.json")
        Task { @MainActor in
            let passed = await ScenarioDriver(context: context, file: file, output: output).run()
            if let name = context.options.pasteboardName { NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally() }
            exit(passed ? 0 : 1)
        }
    }
}
```

Wire the driver into the app. These are three one-line edits to S4-owned files.
1. **`Sources/App/main.swift`:** change the line that creates the application object from `let app = NSApplication.shared` to `let app = MacxApplication.shared`. It must stay the first access to `NSApplication.shared` in the process.
2. **`Resources/Info.plist`:** change `<key>NSPrincipalClass</key><string>NSApplication</string>` to `<string>MacxApplication</string>`.
3. **`Sources/App/AppDelegate.swift`:** in `applicationDidFinishLaunching`, find the place where the delegate awaits `windows.restoreOrOpenInitial()` on its `UIContext` (P1-26). Directly after that await, add `ScenarioLaunch.runIfRequested(context: <that UIContext property>)`. For example, if the property is named `ui`, the line is `ScenarioLaunch.runIfRequested(context: ui)`.

- [ ] **Step 7: Run the unit tests**

Run: `swift build 2>&1 | tail -3 && swift test --filter UITests.Scenario 2>&1 | grep -E "error|Executed|skipped" | tail -4`
Expected: `Build complete!` with no warnings, then `Executed 25 tests, with 0 failures`.
- `ScenarioCatalogTests.testEveryScenarioFileDecodesValidatesAndIsNamedAfterItsFile` fails until Step 8 adds the JSON files. That is expected here; rerun after Step 8.
- `ScenarioHooksWiringTests` is skipped without a GUI session.
- If `testKeyNamesMapToTheIntendedKeys` fails, P1-13's `KeyChord(parsing:)` spells a key differently. Fix the scenario JSON key strings and this table together, not P1-13 (Contract note C8).

- [ ] **Step 8: Write the 21 scenario files in `Tests/Scenarios/`**

Each file is named `<name>.json`, where `<name>` matches its `"name"` field. Menu titles ("Duplicate", "Paste") and alert buttons ("Cancel", "Delete") use the spec's English wording (Contract note C9).

`navigate-address-bar.json`:

```json
{"name": "navigate-address-bar",
 "fixture": {"files": ["top.txt", "a/b/deep.txt"], "dirs": ["a", "a/b"]},
 "steps": [
  {"key": "cmd+l"}, {"waitFor": {"editingAddress": true}},
  {"type": "a/b"}, {"key": "return"},
  {"waitFor": {"folder": "a/b", "rows": ["deep.txt"], "editingAddress": false}},
  {"key": "cmd+l"}, {"type": "../../top.txt"}, {"key": "return"},
  {"waitFor": {"folder": "", "selection": ["top.txt"]}},
  {"key": "cmd+l"}, {"type": "does-not-exist"}, {"key": "return"}, {"sleepMs": 300},
  {"expect": {"editingAddress": true, "folder": ""}},
  {"key": "esc"}, {"waitFor": {"editingAddress": false, "folder": ""}}
 ]}
```

`rename-f2.json` (the contract example):

```json
{"name": "rename-f2",
 "fixture": {"files": ["a.txt", "b.txt"], "dirs": ["sub"]},
 "steps": [{"click": "a.txt"}, {"key": "F2"}, {"expect": {"renameText": "a.txt"}},
           {"type": "c"}, {"key": "return"},
           {"waitFor": {"rows": ["sub", "b.txt", "c.txt"]}, "timeoutMs": 2000},
           {"expect": {"filesExist": ["c.txt"], "filesAbsent": ["a.txt"], "selection": ["c.txt"]}}]}
```

`rename-rejects-duplicate-and-hidden.json` covers Review Focus 2 in the UI:

```json
{"name": "rename-rejects-duplicate-and-hidden",
 "fixture": {"files": ["a.txt", "b.txt"], "dirs": [], "hidden": ["notes.txt"]},
 "steps": [
  {"click": "a.txt"}, {"key": "F2"}, {"waitFor": {"renameText": "a.txt"}},
  {"type": "b"}, {"key": "return"}, {"sleepMs": 300},
  {"expect": {"renameText": "b.txt", "filesExist": ["a.txt", "b.txt"]}},
  {"key": "esc"}, {"waitFor": {"rows": ["a.txt", "b.txt"]}},
  {"click": "a.txt"}, {"key": "cmd+shift+r"}, {"waitFor": {"renameText": "a.txt"}},
  {"type": "notes"}, {"key": "return"}, {"sleepMs": 300},
  {"expect": {"renameText": "notes.txt", "filesExist": ["a.txt", "notes.txt"]}},
  {"key": "esc"}, {"waitFor": {"rows": ["a.txt", "b.txt"]}}
 ]}
```

`cut-paste.json`:

```json
{"name": "cut-paste",
 "fixture": {"files": ["a.txt", "b.txt"], "dirs": ["dest"]},
 "steps": [
  {"click": "a.txt"}, {"key": "cmd+x"}, {"waitFor": {"cut": ["a.txt"]}},
  {"doubleClick": "dest"}, {"waitFor": {"folder": "dest", "rows": []}},
  {"key": "cmd+v"}, {"waitFor": {"rows": ["a.txt"]}, "timeoutMs": 5000},
  {"expect": {"filesExist": ["dest/a.txt"], "filesAbsent": ["a.txt"], "cut": []}},
  {"key": "cmd+["}, {"waitFor": {"folder": "", "rows": ["dest", "b.txt"]}},
  {"click": "b.txt"}, {"key": "ctrl+x"}, {"waitFor": {"cut": ["b.txt"]}},
  {"key": "esc"}, {"waitFor": {"cut": []}}
 ]}
```

`copy-paste-same-folder.json`:

```json
{"name": "copy-paste-same-folder",
 "fixture": {"files": ["b.txt"], "dirs": []},
 "steps": [
  {"click": "b.txt"}, {"key": "cmd+c"}, {"key": "cmd+v"},
  {"waitFor": {"rowCount": 2, "rowsContain": ["b.txt", "b copy.txt"]}, "timeoutMs": 5000},
  {"key": "ctrl+v"},
  {"waitFor": {"rowCount": 3, "rowsContain": ["b copy 2.txt"], "filesExist": ["b copy.txt", "b copy 2.txt"]}, "timeoutMs": 5000}
 ]}
```

`drag-move.json`:

```json
{"name": "drag-move",
 "fixture": {"files": ["a.txt", "b.txt"], "dirs": ["dest"]},
 "steps": [
  {"drop": {"sources": ["a.txt"], "onto": "dest"}},
  {"waitFor": {"rows": ["dest", "b.txt"], "filesExist": ["dest/a.txt"], "filesAbsent": ["a.txt"]}, "timeoutMs": 5000},
  {"drop": {"sources": ["b.txt"], "onto": "dest"}, "modifiers": ["opt"]},
  {"waitFor": {"filesExist": ["dest/b.txt", "b.txt"]}, "timeoutMs": 5000},
  {"drop": {"sources": ["dest"], "onto": "dest"}}, {"sleepMs": 300},
  {"expect": {"rows": ["dest", "b.txt"], "filesExist": ["dest/a.txt", "dest/b.txt"], "filesAbsent": ["dest/dest"]}}
 ]}
```

`right-drag-menu.json`:

```json
{"name": "right-drag-menu",
 "fixture": {"files": ["a.txt", "b.txt", "c.txt"], "dirs": ["dest"]},
 "steps": [
  {"drop": {"sources": ["a.txt"], "onto": "dest", "secondary": true, "choose": "copy"}},
  {"waitFor": {"filesExist": ["a.txt", "dest/a.txt"]}, "timeoutMs": 5000},
  {"drop": {"sources": ["b.txt"], "onto": "dest", "secondary": true, "choose": "move"}},
  {"waitFor": {"filesExist": ["dest/b.txt"], "filesAbsent": ["b.txt"]}, "timeoutMs": 5000},
  {"drop": {"sources": ["c.txt"], "onto": "dest", "secondary": true, "choose": "cancel"}}, {"sleepMs": 300},
  {"expect": {"filesExist": ["c.txt"], "filesAbsent": ["dest/c.txt"]}},
  {"drop": {"sources": ["c.txt"], "onto": "dest", "choose": "move"}, "modifiers": ["ctrl"]},
  {"waitFor": {"filesExist": ["dest/c.txt"], "filesAbsent": ["c.txt"]}, "timeoutMs": 5000}
 ]}
```

`conflict-dialog.json`:

```json
{"name": "conflict-dialog",
 "fixture": {"files": ["a.txt", "dest/a.txt"], "dirs": ["dest"], "sizes": {"a.txt": 10, "dest/a.txt": 3}},
 "steps": [
  {"click": "a.txt"}, {"key": "cmd+c"},
  {"doubleClick": "dest"}, {"waitFor": {"folder": "dest", "rows": ["a.txt"]}},
  {"key": "cmd+v"}, {"answerConflict": "keepBoth", "timeoutMs": 5000},
  {"waitFor": {"rowsContain": ["a.txt", "a 2.txt"], "sheetPresent": false}, "timeoutMs": 5000},
  {"key": "cmd+v"}, {"answerConflict": "replace", "timeoutMs": 5000},
  {"waitFor": {"fileSizes": {"dest/a.txt": 10}}, "timeoutMs": 5000},
  {"key": "cmd+z"}, {"waitFor": {"fileSizes": {"dest/a.txt": 3}}, "timeoutMs": 5000}
 ]}
```

`properties.json`:

```json
{"name": "properties",
 "fixture": {"files": ["a.txt"], "dirs": ["sub"]},
 "steps": [
  {"click": "a.txt"}, {"key": "cmd+i"}, {"waitFor": {"propertiesWindows": 1}},
  {"click": "a.txt"}, {"key": "cmd+i"}, {"sleepMs": 300}, {"expect": {"propertiesWindows": 1}},
  {"click": "sub"}, {"key": "opt+return"}, {"waitFor": {"propertiesWindows": 2}},
  {"key": "cmd+w"}, {"waitFor": {"propertiesWindows": 1}}
 ]}
```

`undo-redo.json`:

```json
{"name": "undo-redo",
 "fixture": {"files": ["a.txt", "b.txt"], "dirs": []},
 "steps": [
  {"click": "a.txt"}, {"key": "fn+delete"}, {"waitFor": {"rows": ["b.txt"], "filesAbsent": ["a.txt"]}, "timeoutMs": 5000},
  {"key": "cmd+z"}, {"waitFor": {"rows": ["a.txt", "b.txt"], "filesExist": ["a.txt"]}, "timeoutMs": 5000},
  {"key": "cmd+shift+z"}, {"waitFor": {"rows": ["b.txt"]}, "timeoutMs": 5000},
  {"key": "ctrl+z"}, {"waitFor": {"rows": ["a.txt", "b.txt"]}, "timeoutMs": 5000},
  {"key": "cmd+y"}, {"waitFor": {"rows": ["b.txt"]}, "timeoutMs": 5000},
  {"click": "b.txt"}, {"key": "cmd+delete"}, {"waitFor": {"rows": []}, "timeoutMs": 5000},
  {"command": "undo"}, {"waitFor": {"rows": ["b.txt"], "filesExist": ["b.txt"]}, "timeoutMs": 5000}
 ]}
```

`colliding-keys.json`. While the address field is editing, every colliding primary and every content alternate must reach the field editor (§5.6 routing rules 1–3):

```json
{"name": "colliding-keys",
 "fixture": {"files": ["sub/a.txt", "sub/b.txt"], "dirs": ["sub"]},
 "steps": [
  {"doubleClick": "sub"}, {"waitFor": {"folder": "sub", "rows": ["a.txt", "b.txt"]}},
  {"click": "a.txt"}, {"expect": {"selection": ["a.txt"]}},
  {"key": "cmd+l"}, {"waitFor": {"editingAddress": true}},
  {"type": "abc"}, {"expect": {"fieldEditorText": "abc"}},
  {"key": "cmd+up"}, {"type": "x"}, {"expect": {"fieldEditorText": "xabc", "folder": "sub"}},
  {"key": "cmd+down"}, {"type": "y"}, {"expect": {"fieldEditorText": "xabcy", "folder": "sub"}},
  {"key": "opt+left"}, {"type": "z"}, {"expect": {"fieldEditorText": "zxabcy", "folder": "sub"}},
  {"key": "cmd+delete"}, {"expect": {"fieldEditorText": "xabcy", "filesExist": ["sub/a.txt"]}},
  {"key": "opt+cmd+delete"}, {"sleepMs": 300},
  {"expect": {"filesExist": ["sub/a.txt"], "sheetPresent": false, "editingAddress": true}},
  {"key": "cmd+["}, {"key": "cmd+]"}, {"sleepMs": 300}, {"expect": {"folder": "sub", "editingAddress": true}},
  {"key": "F2"}, {"key": "cmd+d"}, {"sleepMs": 300},
  {"expect": {"filesAbsent": ["sub/a copy.txt"], "editingAddress": true}},
  {"key": "delete"}, {"key": "fn+delete"}, {"key": "opt+d"}, {"key": "opt+up"}, {"key": "opt+right"}, {"sleepMs": 300},
  {"expect": {"folder": "sub", "editingAddress": true, "filesExist": ["sub/a.txt", "sub/b.txt"]}},
  {"key": "esc"}, {"waitFor": {"editingAddress": false, "folder": "sub"}}
 ]}
```

`hidden-toggle.json`:

```json
{"name": "hidden-toggle",
 "fixture": {"files": ["a.txt", ".dot"], "dirs": [], "hidden": ["flagged.txt"]},
 "steps": [
  {"expect": {"rows": ["a.txt"]}},
  {"key": "cmd+shift+."}, {"waitFor": {"rowCount": 3, "rowsContain": [".dot", "a.txt", "flagged.txt"]}},
  {"key": "cmd+shift+."}, {"waitFor": {"rows": ["a.txt"]}}
 ]}
```

`filter-in-folder.json`:

```json
{"name": "filter-in-folder",
 "fixture": {"files": ["Résumé.pdf", "resume-old.txt", "notes.txt"], "dirs": ["sub"]},
 "steps": [
  {"key": "cmd+f"}, {"type": "RESUME"},
  {"waitFor": {"rowCount": 2, "rowsContain": ["Résumé.pdf", "resume-old.txt"]}},
  {"type": "zzz"}, {"waitFor": {"rowCount": 0, "emptyState": "No items match"}},
  {"key": "esc"}, {"waitFor": {"rowCount": 4}},
  {"type": "notes"}, {"waitFor": {"rows": ["notes.txt"]}},
  {"key": "cmd+l"}, {"type": "sub"}, {"key": "return"}, {"waitFor": {"folder": "sub"}},
  {"key": "cmd+["}, {"waitFor": {"folder": "", "rowCount": 4}}
 ]}
```

`empty-states.json`. The TCC state can't be reproduced in a sandbox; P1-33's `EmptyStateView` tests and the release checklist cover it.

```json
{"name": "empty-states",
 "fixture": {"files": ["closed/inner.txt"], "dirs": ["empty", "closed"], "modes": {"closed": "000"}},
 "steps": [
  {"doubleClick": "empty"}, {"waitFor": {"folder": "empty", "emptyState": "This folder is empty"}},
  {"key": "cmd+["}, {"waitFor": {"folder": ""}},
  {"doubleClick": "closed"},
  {"waitFor": {"folder": "closed", "state": "error.permissionPOSIX", "emptyState": "permission"}}
 ]}
```

`icons-view.json`:

```json
{"name": "icons-view",
 "fixture": {"files": ["a.txt", "b.txt", "c.txt"], "dirs": []},
 "steps": [
  {"command": "viewAsIcons"}, {"waitFor": {"viewMode": "icons"}},
  {"click": "a.txt"}, {"key": "right"}, {"waitFor": {"selection": ["b.txt"]}},
  {"key": "shift+right"}, {"waitFor": {"selection": ["b.txt", "c.txt"]}},
  {"key": "cmd+a"}, {"waitFor": {"selection": ["a.txt", "b.txt", "c.txt"]}},
  {"command": "viewAsDetails"}, {"waitFor": {"viewMode": "details", "selection": ["a.txt", "b.txt", "c.txt"]}}
 ]}
```

`new-folder-inline-rename.json`:

```json
{"name": "new-folder-inline-rename",
 "fixture": {"files": ["a.txt"], "dirs": []},
 "steps": [
  {"key": "cmd+shift+n"}, {"waitFor": {"renameText": "New Folder", "filesExist": ["New Folder"]}, "timeoutMs": 5000},
  {"type": "Projects"}, {"key": "return"},
  {"waitFor": {"rowsContain": ["Projects"], "filesExist": ["Projects"], "filesAbsent": ["New Folder"], "selection": ["Projects"]}, "timeoutMs": 5000}
 ]}
```

`delete-permanently-confirms.json`:

```json
{"name": "delete-permanently-confirms",
 "fixture": {"files": ["a.txt", "b.txt"], "dirs": []},
 "steps": [
  {"click": "a.txt"}, {"key": "opt+cmd+delete"},
  {"answerAlert": "Cancel", "timeoutMs": 3000}, {"sleepMs": 300}, {"expect": {"filesExist": ["a.txt"]}},
  {"click": "a.txt"}, {"key": "shift+fn+delete"},
  {"answerAlert": "Delete", "timeoutMs": 3000},
  {"waitFor": {"rows": ["b.txt"], "filesAbsent": ["a.txt"]}, "timeoutMs": 5000}
 ]}
```

`duplicate.json`:

```json
{"name": "duplicate",
 "fixture": {"files": ["a.txt"], "dirs": []},
 "steps": [
  {"click": "a.txt"}, {"key": "cmd+d"},
  {"waitFor": {"rowsContain": ["a.txt", "a copy.txt"], "filesExist": ["a copy.txt"]}, "timeoutMs": 5000}
 ]}
```

`keyboard-navigation.json`:

```json
{"name": "keyboard-navigation",
 "fixture": {"files": ["sub/inner.txt", "top.txt"], "dirs": ["sub"]},
 "steps": [
  {"click": "sub"}, {"key": "cmd+down"}, {"waitFor": {"folder": "sub", "rows": ["inner.txt"]}},
  {"key": "cmd+up"}, {"waitFor": {"folder": ""}},
  {"key": "opt+left"}, {"waitFor": {"folder": "sub"}},
  {"key": "opt+right"}, {"waitFor": {"folder": ""}},
  {"key": "delete"}, {"waitFor": {"folder": "sub"}},
  {"key": "opt+up"}, {"waitFor": {"folder": ""}},
  {"click": "sub"}, {"key": "return"}, {"waitFor": {"folder": "sub"}},
  {"key": "cmd+["}, {"waitFor": {"folder": ""}},
  {"key": "opt+d"}, {"waitFor": {"editingAddress": true}}, {"key": "esc"}, {"waitFor": {"editingAddress": false}},
  {"key": "F4"}, {"waitFor": {"editingAddress": true}}, {"key": "esc"}, {"waitFor": {"editingAddress": false}},
  {"key": "F5"}, {"sleepMs": 300}, {"expect": {"state": "complete", "rowCount": 2}}
 ]}
```

`type-select.json`:

```json
{"name": "type-select",
 "fixture": {"files": ["apple.txt", "banana.txt", "mango.txt", "melon.txt"], "dirs": []},
 "steps": [
  {"click": "apple.txt"}, {"type": "me"}, {"waitFor": {"selection": ["melon.txt"]}},
  {"sleepMs": 1500}, {"type": "b"}, {"waitFor": {"selection": ["banana.txt"]}}
 ]}
```

`context-menu.json`:

```json
{"name": "context-menu",
 "fixture": {"files": ["a.txt"], "dirs": ["dest"]},
 "steps": [
  {"rightClick": "a.txt"}, {"chooseMenuItem": "Duplicate"},
  {"waitFor": {"rowsContain": ["a copy.txt"]}, "timeoutMs": 5000},
  {"click": "a.txt"}, {"key": "cmd+c"},
  {"rightClick": "dest"}, {"chooseMenuItem": "Paste"},
  {"waitFor": {"filesExist": ["dest/a.txt"]}, "timeoutMs": 5000},
  {"rightClick": ""}, {"chooseMenuItem": "Paste"},
  {"waitFor": {"rowsContain": ["a copy 2.txt"]}, "timeoutMs": 5000}
 ]}
```

Rerun Step 7. Expected: `Executed 25 tests, with 0 failures` (catalog test now green).

- [ ] **Step 9: Write `scripts/ui-scenarios.sh`**

The script bundles the scenario copy of the app, proves the app opens a window on a sandbox (a `--smoke-exit-after 1` probe, which also tells a missing GUI session apart from a broken scenario), then runs each scenario in its own app process. Every scenario gets `<run>/<name>/macx-scenario-root` (the empty root `ScenarioFixtures` requires, Contract note C3), `<run>/<name>/state` and `<run>/<name>/trash`, and a fresh private pasteboard name. Scenarios run one at a time: two scenario apps would fight over the key window.

```bash
#!/bin/bash
# Bundles the scenario copy of the app and runs every Tests/Scenarios/*.json through it, one app process per
# scenario, inside ONE fresh ${TMPDIR}/macx-scenario-ui-<UUID> run directory. Usage:
#   scripts/ui-scenarios.sh [debug|release] [--filter <substring>] [--timeout <seconds>] [--require-gui] [--keep-sandbox]
# Each scenario gets <run>/<name>/{macx-scenario-root,state,trash}. The app runs with --root, --state-dir,
# --sandbox-trash, a private --pasteboard, --fake-launch-services and --skip-onboarding, so it never writes a real
# user folder, the real Trash, the general pasteboard or real LaunchServices defaults.
# Exit codes: 0 all passed (or no GUI session without --require-gui), 1 a scenario failed, 2 environment, 64 usage.
# On exit: kill our app if it still runs, detach images under the run dir, clear uchg/000, delete the run dir.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"

usage() { echo "usage: $0 [debug|release] [--filter <substring>] [--timeout <seconds>] [--require-gui] [--keep-sandbox]" >&2; exit 64; }
CONFIG=debug; FILTER=""; TIMEOUT=120; REQUIRE_GUI=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    debug|release) CONFIG="$1" ;;
    --filter) [ $# -ge 2 ] || usage; FILTER="$2"; shift ;;
    --timeout) [ $# -ge 2 ] && [ "$2" -gt 0 ] 2>/dev/null || usage; TIMEOUT="$2"; shift ;;
    --require-gui) REQUIRE_GUI=1 ;;
    --keep-sandbox) KEEP=1 ;;
    *) usage ;;
  esac
  shift
done

APP="$REPO/.build/macExplorer-scenarios.app"
BIN="$APP/Contents/MacOS/macExplorer"
SCEN_DIR="$REPO/Tests/Scenarios"
if pgrep -f 'macExplorer-scenarios.app/Contents/MacOS/macExplorer' >/dev/null; then
  echo "ui-scenarios: another scenario app is running; quit it first" >&2; exit 2
fi

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
RUN="$TMPBASE/macx-scenario-ui-$(uuidgen)"
mkdir "$RUN" || exit 2
RUN_REAL="$(cd "$RUN" && pwd -P)"
APP_PID=""

cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then kill -KILL "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; fi
  case "$RUN" in "$TMPBASE"/macx-scenario-ui-*) ;; *) echo "refusing to clean $RUN" >&2; return 1 ;; esac
  while IFS= read -r mp; do
    case "$mp" in "$RUN_REAL"/*) hdiutil detach "$mp" -force >/dev/null 2>&1 ;; esac
  done < <(mount | sed -n 's/^.* on \(.*\) (.*)$/\1/p')
  chflags -R nouchg "$RUN" 2>/dev/null
  chmod -R u+rwx "$RUN" 2>/dev/null
  if [ "$KEEP" = 1 ]; then echo "sandbox root $RUN kept (--keep-sandbox)"; return 0; fi
  rm -rf "$RUN"
  if [ -e "$RUN" ]; then echo "ERROR: run directory $RUN was not removed" >&2; return 1; fi
  echo "sandbox root $RUN removed"
}
trap 'cleanup || exit 1' EXIT
trap 'exit 130' INT TERM

json_string() { printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }
field() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }

# launch <scenario dir> <log> [extra app arguments...]: starts the app in the background with the sandbox options.
launch() {
  local dir="$1" log="$2"
  shift 2
  case "$dir" in "$RUN"/*) ;; *) echo "refusing to launch outside $RUN: $dir" >&2; exit 2 ;; esac
  mkdir -p "$dir/macx-scenario-root" "$dir/state" "$dir/trash" || exit 2
  "$BIN" --root "$dir/macx-scenario-root" --state-dir "$dir/state" --sandbox-trash "$dir/trash" \
    --pasteboard "macx-scenario-$(uuidgen)" --fake-launch-services --skip-onboarding "$@" \
    -ApplePersistenceIgnoreState YES > "$log" 2>&1 &
  APP_PID=$!
}

# await_app <seconds>: waits for $APP_PID; kills it after the timeout. Sets APP_CODE (exit code, or "timeout").
await_app() {
  local limit="$1" start
  start=$(date +%s)
  APP_CODE=""
  while kill -0 "$APP_PID" 2>/dev/null; do
    if [ $(( $(date +%s) - start )) -ge "$limit" ]; then kill -KILL "$APP_PID" 2>/dev/null; APP_CODE=timeout; break; fi
    sleep 0.2
  done
  wait "$APP_PID" 2>/dev/null
  local code=$?
  [ -n "$APP_CODE" ] || APP_CODE=$code
  APP_PID=""
}

echo "run directory: $RUN"
TMPDIR="$RUN/" scripts/bundle.sh "$CONFIG" --bundle-id com.macexplorer.app.scenarios --output "$APP" > "$RUN/bundle.log" 2>&1 \
  || { tail -30 "$RUN/bundle.log"; exit 1; }

# GUI probe: the app must open a window titled after its sandbox root (working definition 2).
launch "$RUN/gui-probe" "$RUN/gui-probe.log" --smoke-exit-after 1
await_app 60
title="$(field windowTitles.0 "$RUN/gui-probe/state/smoke.json")"
if [ "$APP_CODE" != 0 ] || [ "$title" != "macx-scenario-root" ]; then
  echo "ui-scenarios: the app opened no window on its sandbox (exit $APP_CODE, title '$title'); no GUI session?"
  tail -10 "$RUN/gui-probe.log" | sed 's/^/    /'
  if [ "$REQUIRE_GUI" = 1 ]; then exit 1; fi
  echo "SKIP: UI scenarios need a logged-in GUI session (pass --require-gui to fail instead)"; exit 0
fi

names=()
for f in "$SCEN_DIR"/*.json; do
  [ -f "$f" ] || continue
  n="$(basename "$f" .json)"
  case "$n" in *[!a-z0-9-]*) echo "ui-scenarios: ignoring unexpected file name $n.json" >&2; continue ;; esac
  if [ -n "$FILTER" ]; then case "$n" in *"$FILTER"*) ;; *) continue ;; esac; fi
  names+=("$n")
done
[ ${#names[@]} -gt 0 ] || { echo "ui-scenarios: no scenario matches '$FILTER'" >&2; exit 64; }

LOGS="$REPO/.build/ui-scenario-logs/$(basename "$RUN")"
passed=0; failed=0; entries=""
for n in "${names[@]}"; do
  dir="$RUN/$n"
  launch "$dir" "$RUN/$n.log" --scenario "$SCEN_DIR/$n.json" --scenario-output "$dir/result.json"
  await_app "$TIMEOUT"
  out="$dir/result.json"
  ms=0; act=false
  if [ "$APP_CODE" = timeout ]; then
    msg="timed out after $TIMEOUT s (app killed)"
  elif [ ! -s "$out" ]; then
    msg="no result file (app exit $APP_CODE); see $n.log"
  else
    ms="$(field durationMs "$out")"; act="$(field activated "$out")"
    if [ "$(field passed "$out")" = true ] && [ "$APP_CODE" = 0 ]; then msg=""
    else msg="step $(field failedStep "$out" || echo '?'): $(field message "$out") (exit $APP_CODE)"; fi
  fi
  if [ -z "$msg" ]; then
    passed=$((passed + 1)); status=passed
    echo "PASS $n (${ms} ms, activated=${act:-false})"
  else
    failed=$((failed + 1)); status=failed
    echo "FAIL $n: $msg"
    mkdir -p "$LOGS" && cp "$RUN/$n.log" "$LOGS/$n.log" 2>/dev/null && { [ ! -s "$out" ] || cp "$out" "$LOGS/$n.json"; }
  fi
  entry="{\"name\":$(json_string "$n"),\"status\":\"$status\",\"durationMs\":${ms:-0},\"activated\":${act:-false},\"message\":$(json_string "$msg")}"
  entries="${entries:+$entries,}$entry"
done

mkdir -p "$REPO/.build"
printf '{"results":[%s],"passed":%d,"failed":%d}\n' "$entries" "$passed" "$failed" > "$REPO/.build/ui-scenario-report.json"
echo "ui-scenarios: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || echo "logs of failed scenarios: $LOGS"
[ "$failed" -eq 0 ]
```

Then run `chmod +x scripts/ui-scenarios.sh`.

Notes:
- The app is executed directly (never `open`), so the scenario bundle is not registered with LaunchServices as a document handler, and the per-scenario process gets the exact argument list above.
- A scenario the app reports as passed but whose process exits non-zero (for example, a crash during teardown) counts as failed.
- A killed app (timeout) cannot release its private pasteboard. That leaks one named in-memory pasteboard in `pboard` until logout; no file is involved.
- Failed scenarios keep their `app.log` and `result.json` in `.build/ui-scenario-logs/<run>/` (a new directory per run, so the script never deletes earlier output). The fixture files themselves are deleted with the run directory.
- `.build/ui-scenario-report.json` has the shape `{"results":[{"name","status":"passed|failed","durationMs","activated","message"}],"passed","failed"}`. CI uploads it.

- [ ] **Step 10: Run the UI catalog in the bundled app**

This needs a logged-in GUI session (a Terminal window on the Mac, not ssh). It is fine to keep typing in another app while it runs: the driver does not need the app to be active (Review Focus 4).

Run: `ls "${TMPDIR%/}" | grep -c '^macx-scenario-ui-'; scripts/ui-scenarios.sh --require-gui 2>&1 | tail -26; echo "exit=$?"`

Expected output:
- `run directory: …/macx-scenario-ui-<UUID>` first.
- 21 lines `PASS <name> (<n> ms, activated=<true|false>)`, in file-name order (`colliding-keys` … `undo-redo`).
- `ui-scenarios: 21 passed, 0 failed`, then `sandbox root …/macx-scenario-ui-<UUID> removed`.
- `exit=0`.

Then check the safety properties:
- `ls "${TMPDIR%/}" | grep -c '^macx-scenario-ui-'` prints the same count as before the run.
- `pgrep -f macExplorer-scenarios.app` prints nothing.
- `mount | grep -c macx-scenario` prints `0`.

If a scenario fails, rerun only it with `scripts/ui-scenarios.sh --filter <name> --keep-sandbox` and read `<run>/<name>.log` and `<run>/<name>/result.json` (the message names the step index and the mismatching expectation). Delete the kept run directory afterwards with `rm -rf "${TMPDIR%/}"/macx-scenario-ui-<UUID>` (only that path). Fix the product code in the owning S4/S5 task, not the scenario: the scenarios encode §5.5, §5.6 and §6.6 behaviour. The exceptions are key names (Contract note C8) and English titles (Contract note C9).

- [ ] **Step 11: Write `scripts/ui-ax-smoke.applescript` and `scripts/ui-ax-smoke.sh`**

This is the optional out-of-process check from the file map: it reads the window title, the window's accessibility identifier and the Details row count through System Events, the same way VoiceOver and XCUITest see the app. It never presses anything. Without Accessibility permission for the terminal it prints `SKIP` and exits 0.

`scripts/ui-ax-smoke.applescript`:

```applescript
-- Out-of-process Accessibility smoke for macExplorer (run by scripts/ui-ax-smoke.sh; read-only, presses nothing).
-- Usage: osascript ui-ax-smoke.applescript <pid> <expected row count> <timeout seconds>
-- Prints "title=<window title>", "window=<AXIdentifier>", "rows=<row count of macx.details>" on success.
on run argv
	set targetPID to (item 1 of argv) as integer
	set wantRows to (item 2 of argv) as integer
	set deadline to (current date) + ((item 3 of argv) as integer)
	tell application "System Events"
		repeat
			set procs to (every process whose unix id is targetPID)
			if (count of procs) > 0 then
				if (count of windows of (item 1 of procs)) > 0 then exit repeat
			end if
			if (current date) > deadline then error "no window within the timeout" number 1001
			delay 0.2
		end repeat
		set w to window 1 of (item 1 of procs)
		set winTitle to name of w
		set winID to ""
		try
			set winID to value of attribute "AXIdentifier" of w
		end try
		set rowCount to -1
		repeat
			repeat with e in (entire contents of w)
				try
					if (value of attribute "AXIdentifier" of e) is "macx.details" then
						set rowCount to count of (UI elements of e whose role is "AXRow")
						exit repeat
					end if
				end try
			end repeat
			if rowCount is wantRows then exit repeat
			if (current date) > deadline then exit repeat
			delay 0.3
		end repeat
	end tell
	return "title=" & winTitle & linefeed & "window=" & winID & linefeed & "rows=" & rowCount
end run
```

`scripts/ui-ax-smoke.sh`:

```bash
#!/bin/bash
# Optional out-of-process Accessibility smoke: launches the scenario bundle on a 4-item sandbox folder and reads
# the window title and the Details row count through System Events (scripts/ui-ax-smoke.applescript).
# Usage: scripts/ui-ax-smoke.sh [--skip-bundle]
# Exit codes: 0 passed, or skipped because this terminal lacks Accessibility/Automation permission (prints SKIP);
# 1 failed; 2 environment. Everything lives in ONE fresh ${TMPDIR}/macx-scenario-ax-<UUID> run directory.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"
SKIP_BUNDLE=0
for a in "$@"; do case "$a" in --skip-bundle) SKIP_BUNDLE=1 ;; *) echo "usage: $0 [--skip-bundle]" >&2; exit 64 ;; esac; done

APP="$REPO/.build/macExplorer-scenarios.app"
BIN="$APP/Contents/MacOS/macExplorer"

perm="$(osascript -e 'tell application "System Events" to return UI elements enabled' 2>&1)"
if [ "$perm" != "true" ]; then
  echo "SKIP: this terminal lacks Accessibility (or Automation for System Events) permission: $perm"
  echo "      Grant it in System Settings > Privacy & Security > Accessibility to run this smoke."
  exit 0
fi
if pgrep -f 'macExplorer-scenarios.app/Contents/MacOS/macExplorer' >/dev/null; then
  echo "ui-ax-smoke: another scenario app is running; quit it first" >&2; exit 2
fi

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
RUN="$TMPBASE/macx-scenario-ax-$(uuidgen)"
mkdir "$RUN" || exit 2
APP_PID=""
cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
  fi
  case "$RUN" in "$TMPBASE"/macx-scenario-ax-*) ;; *) echo "refusing to clean $RUN" >&2; return 1 ;; esac
  chmod -R u+rwx "$RUN" 2>/dev/null
  rm -rf "$RUN"
  if [ -e "$RUN" ]; then echo "ERROR: run directory $RUN was not removed" >&2; return 1; fi
  echo "sandbox root $RUN removed"
}
trap 'cleanup || exit 1' EXIT
trap 'exit 130' INT TERM

echo "run directory: $RUN"
if [ "$SKIP_BUNDLE" = 0 ]; then
  TMPDIR="$RUN/" scripts/bundle.sh debug --bundle-id com.macexplorer.app.scenarios --output "$APP" > "$RUN/bundle.log" 2>&1 \
    || { tail -30 "$RUN/bundle.log"; exit 1; }
fi
[ -x "$BIN" ] || { echo "ui-ax-smoke: no scenario bundle at $APP" >&2; exit 2; }

ROOT="$RUN/macx-scenario-root"
mkdir -p "$ROOT/sub" "$RUN/state" "$RUN/trash" || exit 2
for f in a.txt b.txt c.txt; do : > "$ROOT/$f" || exit 2; done   # 4 rows: sub, a.txt, b.txt, c.txt

# --smoke-exit-after 30 is a safety net: the app quits by itself even if this script is killed.
"$BIN" --root "$ROOT" --state-dir "$RUN/state" --sandbox-trash "$RUN/trash" --pasteboard "macx-scenario-$(uuidgen)" \
  --fake-launch-services --skip-onboarding --smoke-exit-after 30 -ApplePersistenceIgnoreState YES > "$RUN/app.log" 2>&1 &
APP_PID=$!

out="$(osascript scripts/ui-ax-smoke.applescript "$APP_PID" 4 15 2>&1)"; code=$?
echo "$out" | sed 's/^/  /'
if [ $code -ne 0 ]; then
  case "$out" in *-25211*|*-1719*|*-1743*|*"assistive access"*) echo "SKIP: Accessibility access was refused: $out"; exit 0 ;; esac
  echo "FAIL ui-ax-smoke: osascript exit $code"; exit 1
fi
fails=0
printf '%s\n' "$out" | grep -qx 'title=macx-scenario-root' || { echo "FAIL: window title is not macx-scenario-root"; fails=1; }
printf '%s\n' "$out" | grep -qx 'window=macx.window' || { echo "FAIL: window AXIdentifier is not macx.window"; fails=1; }
printf '%s\n' "$out" | grep -qx 'rows=4' || { echo "FAIL: macx.details does not show 4 rows"; fails=1; }
[ $fails -eq 0 ] && echo "PASS ui-ax-smoke"
[ $fails -eq 0 ]
```

Then run `chmod +x scripts/ui-ax-smoke.sh`.

The script itself creates the four fixture items with `mkdir`/`:` on paths built from its own run directory. `--smoke-exit-after 30` makes the app quit by itself even if the script is killed before its EXIT trap runs.

- [ ] **Step 12: Run the Accessibility smoke**

Run: `scripts/ui-ax-smoke.sh 2>&1 | tail -8; echo "exit=$?"`

Expected with Accessibility permission for the terminal:
- `  title=macx-scenario-root`, `  window=macx.window`, `  rows=4`
- `PASS ui-ax-smoke`, then `sandbox root …/macx-scenario-ax-<UUID> removed`, and `exit=0`.

Expected without the permission: one `SKIP: this terminal lacks Accessibility …` line (no run directory is created) and `exit=0`. The release checklist (P1-42) requires the PASS form.

If `rows` is `-1`, `macx.details` is missing from the accessibility tree: P1-31 must set `AXID.detailsTable` as the table's `accessibilityIdentifier`. If `window` is empty, P1-26 must set `AXID.window` on the browser window.

- [ ] **Step 13: Run the whole UITests target and commit**

Run: `swift build 2>&1 | tail -3 && swift test --filter UITests 2>&1 | grep -E "error|Executed" | tail -3`
Expected: `Build complete!` with no warnings, then `with 0 failures` (the S4/S5 UI tests plus the 25 scenario tests).

```bash
git add Sources/UI/Scenario Sources/UI/App/MacxApplication.swift Sources/App/main.swift Sources/App/AppDelegate.swift \
        Resources/Info.plist Tests/UITests/Scenario*.swift Tests/Scenarios \
        scripts/ui-scenarios.sh scripts/ui-ax-smoke.sh scripts/ui-ax-smoke.applescript
git commit -m "feat: in-process UI scenario runner with 21 scenarios, ui-scenarios.sh and accessibility smoke"
```

---

## Task P1-42: CI, layering checks, README with release checklist, and the full verification run

**Spec:** §4.1 layering (with the overview's `MacxFS` and `Core/Platform` deviations), §9 Benchmarks CI gate (relative: >20% **and** >5 ms against a same-image `main` baseline, cached and recomputed when the image changes; absolute budgets as a non-blocking warning), §9 manual checklist per release, §10 Local and CI ("on each PR: build, test and bench with the relative gate"), §1 non-goals (README documents the Finder limitation) and §5.6 Clipboard ("cutting in macExplorer and pasting in Finder copies; the README documents this"), §12 risks (Hangs instrument and iCloud check in the release checklist). It verifies the overview's "Phase 1 working definition" items 1–6 in one run.

**Files:**
- Create: `scripts/check-layering.sh`, `scripts/test-check-layering.sh`, `scripts/verify-phase1.sh`, `.github/workflows/ci.yml`, `README.md`
  - The file map lists `check-layering.sh`, `verify-phase1.sh`, `ci.yml` and `README.md` (the release checklist is a README section). `test-check-layering.sh` is an addition: the checker's own failing-first test.
- No Swift files. If the real repository fails a layering rule, the fix belongs in the owning task's code, never in the rule.

**Interfaces:**
- Consumes:
  - `scripts/bundle.sh [debug|release] [--bundle-id ID] [--output PATH]` (P1-01).
  - `macExplorer` launch options (§3.12) and `<state-dir>/smoke.json` from `--smoke-exit-after`, whose `windowTitles` lists the visible window titles front to back (P1-01 `SmokeReport`; see Contract note C12).
  - `scripts/run-scenarios.sh` and `macx-scenarios --general-pasteboard-changecount` (P1-40).
  - `scripts/ui-scenarios.sh --require-gui` and `scripts/ui-ax-smoke.sh` (P1-41).
  - The `macx-bench` CLI contract (P1-39): `--output`, `--compare`, `--check-budgets`, `--warn-budgets`, exit codes 0/1/2/3.
- Produces:
  - `scripts/check-layering.sh [--root <dir>]`: exit 0 clean, 1 with one `RULE <id>: <file>:<line>: <text>` line per violation, 64 usage. Rule ids: `appkit-in-core`, `upward-import`, `fixtures-in-app`, `manifest-fixtures`, `test-globals`, `system-trash`, `users-literal`, `unsafe-escape`.
  - `scripts/verify-phase1.sh [--skip-ui]`: one `GATE <name> PASS|FAIL|SKIPPED` line per gate, then `verify-phase1: N/N gates passed` (exit 0), `… FAILED` (exit 1), or `… GUI gate(s) SKIPPED` (exit 3).
  - CI jobs `build-test`, `scenarios`, `bench`; artifacts `scenario-reports` and `bench`; cache entries `bench-baseline-<ImageOS>-<ImageVersion>-<arch>-<sha>`.

**The eight layering rules.**

| Rule | Fails when | Source of the rule |
|---|---|---|
| `appkit-in-core` | a file in `Sources/FSKit` or `Sources/Core` (outside `Sources/Core/Platform/`) imports `AppKit`, `Cocoa` or `SwiftUI`, in any import form (`@preconcurrency import`, `import class AppKit.X`) | overview AppKit deviation from §4.1 |
| `upward-import` | `MacxFS` imports `Core`/`UI`/`macExplorer`/a harness/`MacxFixtures`, or `Core` imports `UI`/`macExplorer`/a harness/`MacxFixtures` | §4.1 layer order |
| `fixtures-in-app` | `Sources/UI` or `Sources/App` imports `MacxFixtures`, `macx_bench` or `macx_scenarios` | test fixtures never ship (§3.0, Contract note C3) |
| `manifest-fixtures` | in `swift package dump-package`, `CFSKit`, `MacxFS`, `Core`, `UI` or `macExplorer` reaches `MacxFixtures` directly or transitively | same, enforced on the manifest |
| `test-globals` | `Tests/` or a harness (`Sources/macx-bench`, `Sources/macx-scenarios`, `Sources/UI/Scenario`) uses `UserDefaults.standard`, `UserDefaults(suiteName:)`, `UserDefaultsStorage()` (its default argument is `.standard`) or `NSPasteboard.general` (reading `.changeCount` alone is allowed, Contract note C13) | overview "Tests never use" |
| `system-trash` | a harness mentions `SystemTrash`, or a test calls `SystemTrash()` outside a test method whose name ends in `OnDiskImage` (S3's `testSystemTrashOnDiskImage`, Contract note C13) | overview "Tests never use", S6 "No trash outside the sandbox" |
| `users-literal` | a file in the C11 scope contains `/Users/` (comments included) | S6 Global Constraints, Contract note C11 |
| `unsafe-escape` | a `MacxFS`/`Core` file has more than one `@unchecked Sendable`/`nonisolated(unsafe)` outside comments (exactly one prints a `note:` for the reviewer) | overview Platform and language |

Comment-only lines never count for the import and global-state rules (S5's `/// touches NSPasteboard.general (S5-C2)` doc comment stays legal).

- [ ] **Step 1: Write the failing self-test `scripts/test-check-layering.sh`**

Each case copies a clean fake repository and injects exactly one violation (or one legal near-miss). The fake trees live in one `${TMPDIR}/macx-tests-<UUID>` sandbox that the EXIT trap deletes. The `manifest` helper writes a small `Package.swift` with the real layering; `swift package dump-package` reads it without any source files being present (verified on this machine, about 1 s per case).

```bash
#!/bin/bash
# Self-test for scripts/check-layering.sh. Builds small fake repositories inside ONE fresh
# ${TMPDIR}/macx-tests-<UUID> directory, injects one violation per case, and checks the rule that fires.
# Usage: scripts/test-check-layering.sh      Exit 0 when every case behaves, 1 otherwise.
set -uo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd -P)/check-layering.sh"

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
SB="$TMPBASE/macx-tests-$(uuidgen)"
mkdir "$SB" || exit 2
cleanup() {
  case "$SB" in "$TMPBASE"/macx-tests-*) rm -rf "$SB" ;; *) echo "refusing to clean $SB" >&2; return 1 ;; esac
  echo "sandbox root $SB removed"
}
trap 'cleanup || exit 1' EXIT

# put <case> <relative path> <content>: writes a file inside $SB/<case> only.
put() {
  case "$1/$2" in *..*|/*) echo "refusing path $1/$2" >&2; exit 2 ;; esac
  mkdir -p "$(dirname "$SB/$1/$2")" && printf '%s\n' "$3" > "$SB/$1/$2"
}
new_case() { cp -R "$SB/clean" "$SB/$1"; }

# manifest <Core dependencies> <UI dependencies> [extra target lines]: a small manifest with the real layering.
manifest() {
  cat <<SWIFT
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "LayeringFixture",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CFSKit"),
        .target(name: "MacxFS", dependencies: ["CFSKit"], path: "Sources/FSKit"),
        .target(name: "Core", dependencies: [$1]),
        .target(name: "UI", dependencies: [$2]),
        .executableTarget(name: "macExplorer", dependencies: ["UI", "Core"], path: "Sources/App"),
        .target(name: "MacxFixtures", dependencies: ["MacxFS"]),
        .executableTarget(name: "macx-scenarios", dependencies: ["Core", "MacxFixtures"]),
        .testTarget(name: "CoreTests", dependencies: ["Core", "MacxFixtures"]),${3:-}
    ]
)
SWIFT
}
put clean Package.swift "$(manifest '"MacxFS"' '"Core", "MacxFS"')"
put clean Sources/FSKit/Lane.swift $'import Foundation\nimport CFSKit'
put clean Sources/Core/Model.swift $'import Foundation\nimport MacxFS\n// never import AppKit here'
put clean Sources/Core/Platform/Pasteboard.swift $'import AppKit\nimport MacxFS'
put clean Sources/Core/OneEscape.swift $'// Confined to one lane thread (header comment explains the @unchecked Sendable below).\nfinal class Box: @unchecked Sendable {}'
put clean Sources/UI/View.swift $'import AppKit\nimport SwiftUI\n@preconcurrency import Core'
put clean Sources/App/main.swift $'import AppKit\nimport UI'
put clean Sources/macx-scenarios/CLI.swift $'import Core\nimport MacxFixtures\nprint(NSPasteboard.general.changeCount)'
put clean Tests/CoreTests/ModelTests.swift $'import XCTest\n@testable import Core\n// never NSPasteboard.general\nfinal class ModelTests: XCTestCase {\n    func testBreadcrumbMath() { _ = "/Users/alice/Desktop" }\n    func testSystemTrashOnDiskImage() { _ = try? SystemTrash().trash(url) }\n}'
put clean Tests/Scenarios/a.json '{"name": "a", "fixture": {"files": ["/tmp/x"], "dirs": []}, "steps": []}'

fails=0
# run_case <case> <expected exit> [rule that must fire]
run_case() {
  local name="$1" want="$2" rule="${3:-}" out code
  out="$("$CHECK" --root "$SB/$name" 2>&1)"; code=$?
  if [ "$code" -ne "$want" ]; then
    echo "FAIL $name: exit $code, expected $want"; printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1)); return
  fi
  if [ -n "$rule" ] && ! printf '%s\n' "$out" | grep -q "^RULE $rule: "; then
    echo "FAIL $name: no 'RULE $rule' line"; printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1)); return
  fi
  echo "ok   $name"
}

run_case clean 0

new_case appkit-in-core;   put appkit-in-core Sources/Core/Model/Bad.swift 'import AppKit'
new_case swiftui-in-fs;    put swiftui-in-fs Sources/FSKit/Bad.swift '@preconcurrency import SwiftUI'
new_case class-import;     put class-import Sources/Core/Bad.swift 'import class AppKit.NSWorkspace'
new_case fs-imports-core;  put fs-imports-core Sources/FSKit/Bad.swift 'import Core'
new_case core-imports-ui;  put core-imports-ui Sources/Core/Bad.swift '@testable import UI'
new_case ui-fixtures;      put ui-fixtures Sources/UI/Bad.swift 'import MacxFixtures'
new_case manifest;         put manifest Package.swift "$(manifest '"MacxFS"' '"Core", "MacxFS", "MacxFixtures"')"
new_case manifest-transitive
put manifest-transitive Package.swift "$(manifest '"MacxFS", "Helpers"' '"Core", "MacxFS"' '
        .target(name: "Helpers", dependencies: ["MacxFixtures"]),')"
new_case defaults;         put defaults Tests/CoreTests/Bad.swift '    let d = UserDefaults.standard'
new_case suite;            put suite Tests/CoreTests/Bad.swift '    let d = UserDefaults(suiteName: "x")'
new_case storage;          put storage Tests/CoreTests/Bad.swift '    let s = UserDefaultsStorage()'
new_case general;          put general Tests/UITests/Bad.swift '    NSPasteboard.general.clearContents()'
new_case harness-general;  put harness-general Sources/macx-bench/Bad.swift 'NSPasteboard.general.writeObjects([])'
new_case trash-in-test;    put trash-in-test Tests/CoreTests/Bad.swift $'func testTrash() {\n    _ = try? SystemTrash().trash(u)\n}'
new_case trash-in-helper;  put trash-in-helper Tests/CoreTests/Bad.swift $'func testSystemTrashOnDiskImage() {}\nfunc helper() { _ = SystemTrash() }'
new_case trash-harness;    put trash-harness Sources/macx-scenarios/Bad.swift 'let t: any TrashService = SystemTrash()'
new_case users-json;       put users-json Tests/Scenarios/b.json '{"name": "b", "fixture": {"files": ["/Users/me/x"], "dirs": []}, "steps": []}'
new_case users-bench;      put users-bench Sources/macx-bench/Bad.swift '// e.g. /Users/me'
new_case users-uitest;     put users-uitest Tests/UITests/ScenarioBadTests.swift 'let p = "/Users/me"'
new_case users-other-ok;   put users-other-ok Tests/UITests/BreadcrumbTests.swift 'let p = "/Users/me"'
new_case platform-ok;      put platform-ok Sources/Core/Platform/Workspace.swift 'import AppKit'
new_case two-escapes;      put two-escapes Sources/Core/Bad.swift $'final class A: @unchecked Sendable {}\nnonisolated(unsafe) var b = 0'

run_case appkit-in-core 1 appkit-in-core
run_case swiftui-in-fs 1 appkit-in-core
run_case class-import 1 appkit-in-core
run_case fs-imports-core 1 upward-import
run_case core-imports-ui 1 upward-import
run_case ui-fixtures 1 fixtures-in-app
run_case manifest 1 manifest-fixtures
run_case manifest-transitive 1 manifest-fixtures
run_case defaults 1 test-globals
run_case suite 1 test-globals
run_case storage 1 test-globals
run_case general 1 test-globals
run_case harness-general 1 test-globals
run_case trash-in-test 1 system-trash
run_case trash-in-helper 1 system-trash
run_case trash-harness 1 system-trash
run_case users-json 1 users-literal
run_case users-bench 1 users-literal
run_case users-uitest 1 users-literal
run_case users-other-ok 0
run_case platform-ok 0
run_case two-escapes 1 unsafe-escape

if [ "$fails" -gt 0 ]; then echo "test-check-layering: $fails case(s) failed"; exit 1; fi
echo "test-check-layering: all cases passed"
```

Then run `chmod +x scripts/test-check-layering.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test-check-layering.sh 2>&1 | tail -4`
Expected: `FAIL two-escapes: exit 127, expected 1` with `…/check-layering.sh: No such file or directory` below it, then `test-check-layering: 23 case(s) failed` and `sandbox root …/macx-tests-<UUID> removed`. Every one of the 23 cases fails the same way.

- [ ] **Step 3: Write `scripts/check-layering.sh`**

```bash
#!/bin/bash
# Layering and test-safety checks (spec §4.1, overview Global Constraints, S6 Contract notes C11 and C13).
# Usage: scripts/check-layering.sh [--root <repository dir>]   (default: the repository containing this script)
# Prints one "RULE <id>: <file>:<line>: <text>" line per violation and exits 1 if there is any, 0 when clean,
# 64 on usage errors. It only reads source files and runs `swift package dump-package`; it writes nothing.
set -uo pipefail

usage() { echo "usage: $0 [--root <repository dir>]" >&2; exit 64; }
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] && [ -d "$2" ] || usage; ROOT="$(cd "$2" && pwd -P)"; shift ;;
    *) usage ;;
  esac
  shift
done
cd "$ROOT" || exit 64

violations=0

# report <rule> [keep-comments] < "file:line:text" lines. Comment-only lines are ignored unless keep-comments.
report() {
  local rule="$1" keep="${2:-}" line text
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -z "$keep" ]; then
      text="${line#*:}"; text="${text#*:}"
      if printf '%s\n' "$text" | grep -qE '^[[:space:]]*//'; then continue; fi
    fi
    echo "RULE $rule: $line"
    violations=$((violations + 1))
  done
}

# scan <ERE> <path>...: "file:line:text" for every match in the *.swift files under the existing paths.
scan() {
  local pattern="$1" p
  shift
  local existing=()
  for p in "$@"; do [ -e "$p" ] && existing+=("$p"); done
  [ ${#existing[@]} -gt 0 ] || return 0
  find "${existing[@]}" -type f -name '*.swift' -exec grep -nHE -- "$pattern" {} + 2>/dev/null
}

IMPORT='^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?'
END='([^A-Za-z0-9_]|$)'
HARNESS="Sources/macx-bench Sources/macx-scenarios Sources/UI/Scenario"

# 1. MacxFS and Core never import AppKit/Cocoa/SwiftUI, except Sources/Core/Platform (overview AppKit deviation).
report appkit-in-core < <(scan "${IMPORT}(AppKit|Cocoa|SwiftUI)${END}" Sources/FSKit Sources/Core | grep -v '^Sources/Core/Platform/')

# 2. Imports only point down the layers (App → UI → Core → MacxFS → CFSKit).
report upward-import < <(scan "${IMPORT}(Core|UI|macExplorer|MacxFixtures|macx_bench|macx_scenarios)${END}" Sources/FSKit)
report upward-import < <(scan "${IMPORT}(UI|macExplorer|MacxFixtures|macx_bench|macx_scenarios)${END}" Sources/Core)

# 3. Test fixtures never ship in the app.
report fixtures-in-app < <(scan "${IMPORT}(MacxFixtures|macx_bench|macx_scenarios)${END}" Sources/UI Sources/App)

# 4. No shipping target reaches MacxFixtures through Package.swift (direct or transitive dependency).
MANIFEST_CHECK='
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("Package.swift:0:cannot load the manifest (swift package dump-package failed)"); sys.exit(0)
deps = {}
for t in d.get("targets", []):
    names = []
    for dep in t.get("dependencies", []):
        for kind in ("byName", "target", "product"):
            if kind in dep:
                names.append(dep[kind][0])
    deps[t["name"]] = names
def path(start, goal, seen):
    if start == goal:
        return [goal]
    for n in deps.get(start, []):
        if n not in seen:
            p = path(n, goal, seen | {start})
            if p:
                return [start] + p
    return None
for t in ("CFSKit", "MacxFS", "Core", "UI", "macExplorer"):
    if t in deps:
        p = path(t, "MacxFixtures", set())
        if p:
            print("Package.swift:0:target %s reaches MacxFixtures via %s" % (t, " -> ".join(p)))
'
report manifest-fixtures keep < <(swift package dump-package 2>/dev/null | python3 -I -c "$MANIFEST_CHECK")

# 5. Tests and harnesses never touch global user state (overview "Tests never use"). Reading the general
#    pasteboard's changeCount is allowed: verify-phase1.sh compares it before and after a run (C13).
# shellcheck disable=SC2086
report test-globals < <(scan 'UserDefaults\.standard|UserDefaults\(suiteName:|UserDefaultsStorage\(\)|NSPasteboard\.general' Tests $HARNESS \
  | grep -vE 'NSPasteboard\.general\.changeCount[^A-Za-z0-9_.]*$')

# 6. SystemTrash: never in harnesses; in tests only inside a test method whose name ends in "OnDiskImage" (C13).
# shellcheck disable=SC2086
report system-trash < <(scan 'SystemTrash' $HARNESS)
report system-trash < <(
  [ -d Tests ] && find Tests -type f -name '*.swift' -exec awk '
    FNR == 1 { fn = "" }
    /func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
      match($0, /func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/); fn = substr($0, RSTART, RLENGTH); sub(/^func[[:space:]]+/, "", fn)
    }
    /SystemTrash\(\)/ { if (fn !~ /OnDiskImage$/) printf "%s:%d:%s\n", FILENAME, FNR, $0 }
  ' {} +)

# 7. Harness files never contain the literal /Users/ (S6 Global Constraints; scope in Contract note C11).
report users-literal keep < <(
  for p in Sources/macx-bench Sources/macx-scenarios Tests/BenchTests Tests/ScenarioRunnerTests; do
    [ -d "$p" ] && grep -rnHF --include='*.swift' '/Users/' "$p"
  done
  for p in Tests/UITests/Scenario*.swift Tests/Scenarios/*.json; do
    [ -f "$p" ] && grep -nHF '/Users/' "$p"
  done
  true)

# 8. At most one @unchecked Sendable / nonisolated(unsafe) per MacxFS/Core file (overview Platform and language).
report unsafe-escape keep < <(
  for p in Sources/FSKit Sources/Core; do [ -d "$p" ] && find "$p" -type f -name '*.swift'; done | while IFS= read -r f; do
    n=$(grep -vE '^[[:space:]]*//' "$f" | grep -cE '@unchecked[[:space:]]+Sendable|nonisolated\(unsafe\)')
    if [ "$n" -gt 1 ]; then
      echo "$f:0:$n concurrency escapes (@unchecked Sendable / nonisolated(unsafe)); at most 1 per file"
    elif [ "$n" -eq 1 ]; then
      echo "note: $f has 1 concurrency escape; its header comment must explain the confinement" >&2
    fi
  done)

if [ "$violations" -gt 0 ]; then
  echo "check-layering: $violations violation(s)"
  exit 1
fi
echo "check-layering: OK (8 rules)"
```

Then run `chmod +x scripts/check-layering.sh`.

Implementation notes:
- `report` reads through process substitution (`< <(…)`), not a pipe, so the violation counter survives (bash 3.2, the system bash, runs a piped `while` in a subshell).
- Imports are matched from the start of the line, so `// import AppKit` in a comment never matches.
- The `system-trash` awk tracks the enclosing `func` name per file. A helper function after a `…OnDiskImage` test resets it, so the allowance cannot leak into the next function.
- The manifest rule uses `python3 -I` (isolated mode, nothing from the current directory is importable). If `dump-package` fails, the rule reports `cannot load the manifest` instead of passing.

- [ ] **Step 4: Run the self-test and the checker on the real repository**

Run: `scripts/test-check-layering.sh 2>&1 | tail -3`
Expected: 23 `ok   <case>` lines in total (the tail shows the last of them), then `test-check-layering: all cases passed` and `sandbox root …/macx-tests-<UUID> removed`; exit 0. This passed in a dry run of the exact scripts above on this machine (2026-11-03, about 30 s).

Run: `scripts/check-layering.sh; echo "exit=$?"`
Expected: `check-layering: OK (8 rules)` and `exit=0`. `note:` lines on stderr list files with one concurrency escape; check that each has the confinement header comment the overview requires. A `RULE` line is a real violation in the named file: fix it in that file's owning task.

- [ ] **Step 5: Write `scripts/verify-phase1.sh`**

One command for the overview's "Phase 1 working definition". Gates run in order and do not stop at the first failure, so one run shows everything that is broken. The gate logs go into the script's own `${TMPDIR}/macx-verify-<UUID>` run directory and are copied to `.build/verify-phase1/<run>/` before it is deleted.

The child runners keep their own `TMPDIR`. They are not nested inside the verify run directory, because `swift build`/`swift test` put Unix-domain sockets in `TMPDIR`, and a nested path would get close to the 104-byte socket path limit. Instead, the `safety` gate checks from the outside:
- every `sandbox [root] <path> removed` line in any gate log names a path that no longer exists;
- no `macx-*` entry appeared in `$TMPDIR` during the run;
- no new mount has `/macx-` in its path;
- no scenario app is still running;
- the general pasteboard's `changeCount` is unchanged (read with P1-40's read-only flag);
- `defaults read com.macexplorer.app` is byte-identical (no run touched a real install's preferences).

```bash
#!/bin/bash
# Runs every Phase 1 gate (overview "Phase 1 working definition" 1-6) and then checks that the runners left
# nothing behind. Gate logs live in ONE fresh ${TMPDIR}/macx-verify-<UUID> run directory, copied to
# .build/verify-phase1/<run>/ before it is deleted. Usage: scripts/verify-phase1.sh [--skip-ui]
# --skip-ui records the two gates that need a GUI session (app-launch, ui-scenarios) as SKIPPED.
# Exit 0 when every gate passed, 1 when any gate failed, 3 when all ran gates passed but GUI gates were skipped.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"
SKIP_UI=0
for a in "$@"; do case "$a" in --skip-ui) SKIP_UI=1 ;; *) echo "usage: $0 [--skip-ui]" >&2; exit 64 ;; esac; done

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
RUN="$TMPBASE/macx-verify-$(uuidgen)"
mkdir "$RUN" || exit 2
RUN_REAL="$(cd "$RUN" && pwd -P)"
LOGS="$REPO/.build/verify-phase1/$(basename "$RUN")"
APP_PID=""

cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then kill -KILL "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; fi
  case "$RUN" in "$TMPBASE"/macx-verify-*) ;; *) echo "refusing to clean $RUN" >&2; return 1 ;; esac
  mkdir -p "$LOGS" && cp "$RUN"/*.log "$RUN"/*.json "$LOGS"/ 2>/dev/null
  while IFS= read -r mp; do
    case "$mp" in "$RUN_REAL"/*) hdiutil detach "$mp" -force >/dev/null 2>&1 ;; esac
  done < <(mount | sed -n 's/^.* on \(.*\) (.*)$/\1/p')
  chflags -R nouchg "$RUN" 2>/dev/null
  chmod -R u+rwx "$RUN" 2>/dev/null
  rm -rf "$RUN"
  if [ -e "$RUN" ]; then echo "ERROR: run directory $RUN was not removed" >&2; return 1; fi
  echo "sandbox root $RUN removed (logs in $LOGS)"
}
trap 'cleanup || exit 1' EXIT
trap 'exit 130' INT TERM

total=0; failed=0; skipped=0
# gate <name> <command...>: runs the command with its output in $RUN/<name>.log and prints one GATE line.
gate() {
  local name="$1" start code secs
  shift
  start=$(date +%s)
  "$@" > "$RUN/$name.log" 2>&1; code=$?
  secs=$(( $(date +%s) - start ))
  total=$((total + 1))
  if [ $code -eq 0 ]; then
    echo "GATE $name PASS (${secs} s)"
  else
    failed=$((failed + 1))
    echo "GATE $name FAIL (exit $code, ${secs} s); last lines of $name.log:"
    tail -15 "$RUN/$name.log" | sed 's/^/    /'
  fi
}

# build_clean <debug|release>: swift build, failing on any warning line (Swift warnings are already errors).
build_clean() {
  local out code
  out="$(swift build -c "$1" 2>&1)"; code=$?
  printf '%s\n' "$out"
  [ $code -eq 0 ] || return $code
  if printf '%s\n' "$out" | grep -E '(^|[^A-Za-z])warning:'; then echo "build_clean: warnings present"; return 1; fi
}

# app_launch: release bundle + a sandboxed launch of a release copy under the scenarios bundle id (C12).
app_launch() {
  scripts/bundle.sh release || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' .build/macExplorer.app/Contents/Info.plist)" = com.macexplorer.app ] || return 1
  codesign --verify --strict .build/macExplorer.app || return 1
  TMPDIR="$RUN/" scripts/bundle.sh release --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app || return 1
  local d="$RUN/launch"
  mkdir -p "$d/macx-scenario-root" "$d/state" "$d/trash" || return 1
  .build/macExplorer-scenarios.app/Contents/MacOS/macExplorer --root "$d/macx-scenario-root" --state-dir "$d/state" \
    --sandbox-trash "$d/trash" --pasteboard "macx-scenario-$(uuidgen)" --fake-launch-services --skip-onboarding \
    --smoke-exit-after 2 -ApplePersistenceIgnoreState YES &
  APP_PID=$!
  local start
  start=$(date +%s)
  while kill -0 "$APP_PID" 2>/dev/null; do
    if [ $(( $(date +%s) - start )) -ge 60 ]; then kill -KILL "$APP_PID"; echo "app did not exit within 60 s"; return 1; fi
    sleep 0.2
  done
  wait "$APP_PID"; local code=$?
  APP_PID=""
  [ $code -eq 0 ] || { echo "app exit $code"; return 1; }
  cat "$d/state/smoke.json"
  [ "$(plutil -extract windowTitles.0 raw -o - "$d/state/smoke.json")" = macx-scenario-root ]
}

# bench: release macx-bench with the absolute budgets (exit 2 means over budget on Apple Silicon).
bench() {
  swift run -c release macx-bench --check-budgets --output "$RUN/bench.json"
}

macx_tmp_entries() { ls -1 "$TMPBASE" 2>/dev/null | grep '^macx-' | grep -vx "$(basename "$RUN")" | sort; }
macx_mounts() { mount | sed -n 's/^.* on \(.*\) (.*)$/\1/p' | grep '/macx-' | sort; }
general_changecount() { "$(swift build --show-bin-path)/macx-scenarios" --general-pasteboard-changecount; }

# safety: overview working definition 6, checked from the outside after every runner finished.
safety() {
  local bad=0 p
  while IFS= read -r p; do
    if [ -e "$p" ]; then echo "LEFT BEHIND: $p"; bad=1; else echo "gone: $p"; fi
  done < <(cat "$RUN"/*.log | sed -n 's/^.*sandbox \(root \)\{0,1\}\(\/.*\) removed.*$/\2/p' | sort -u)
  macx_tmp_entries > "$RUN/tmp-after.txt"
  while IFS= read -r p; do echo "NEW IN TMPDIR: $TMPBASE/$p"; bad=1; done < <(comm -13 "$RUN/tmp-before.txt" "$RUN/tmp-after.txt")
  macx_mounts > "$RUN/mounts-after.txt"
  while IFS= read -r p; do echo "STILL MOUNTED: $p"; bad=1; done < <(comm -13 "$RUN/mounts-before.txt" "$RUN/mounts-after.txt")
  if pgrep -f 'macExplorer-scenarios.app/Contents/MacOS/macExplorer' >/dev/null; then echo "scenario app still running"; bad=1; fi
  local after
  after="$(general_changecount)"
  if [ "$after" != "$GENERAL_BEFORE" ]; then
    echo "general pasteboard changeCount changed ($GENERAL_BEFORE -> $after). If you copied something during the run, rerun."
    bad=1
  fi
  [ "$(defaults read com.macexplorer.app 2>&1 | shasum)" = "$DEFAULTS_BEFORE" ] || { echo "the com.macexplorer.app defaults domain changed"; bad=1; }
  return $bad
}

echo "run directory: $RUN"
macx_tmp_entries > "$RUN/tmp-before.txt"
macx_mounts > "$RUN/mounts-before.txt"
DEFAULTS_BEFORE="$(defaults read com.macexplorer.app 2>&1 | shasum)"

gate layering scripts/check-layering.sh
gate layering-selftest scripts/test-check-layering.sh
gate build-release build_clean release
gate build-debug build_clean debug
GENERAL_BEFORE="$(general_changecount)"
gate test swift test --parallel
if [ "$SKIP_UI" = 1 ]; then echo "GATE app-launch SKIPPED (--skip-ui)"; skipped=$((skipped + 1)); else gate app-launch app_launch; fi
gate core-scenarios scripts/run-scenarios.sh release
if [ "$SKIP_UI" = 1 ]; then echo "GATE ui-scenarios SKIPPED (--skip-ui)"; skipped=$((skipped + 1)); else gate ui-scenarios scripts/ui-scenarios.sh --require-gui; fi
gate bench bench
gate safety safety

if [ "$failed" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  echo "verify-phase1: $total/$total gates passed"
  exit 0
fi
[ "$failed" -eq 0 ] && { echo "verify-phase1: $total/$total gates passed, $skipped GUI gate(s) SKIPPED (not a full Phase 1 verification)"; exit 3; }
echo "verify-phase1: $failed of $total gates FAILED"
exit 1
```

Then run `chmod +x scripts/verify-phase1.sh`.

The `app-launch` gate covers working definition 2. It bundles `.build/macExplorer.app` (release, real bundle id, `codesign --verify --strict`), but launches a release copy bundled under the scenarios bundle id, so even this launch never writes the real install's preference domain (Contract note C12). The UI gate rebundles the debug scenario copy afterwards.

Run `bash -n scripts/verify-phase1.sh && echo ok`. Expected: `ok`.

- [ ] **Step 6: Write `.github/workflows/ci.yml`**

```yaml
# macExplorer CI (spec §9 and §10, P1-42). Pull requests and main: layering, build, test, bundle, both scenario
# runners, and macx-bench with the relative gate against a baseline from main on the same runner image.
# The §4.4 absolute budgets appear only as warning annotations here; they are gated by
# `macx-bench --check-budgets` on Apple Silicon as part of the release checklist (README).
name: CI

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

env:
  XCODE_VERSION: "27.2"

jobs:
  build-test:
    runs-on: macos-26
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: |
          sudo xcode-select -s "/Applications/Xcode_${XCODE_VERSION}.app"
          swift --version
      - name: Layering checks
        run: scripts/check-layering.sh && scripts/test-check-layering.sh
      - name: Build (release, warnings fail)
        run: |
          swift build -c release 2>&1 | tee "$RUNNER_TEMP/build-release.log"
          test "${PIPESTATUS[0]}" -eq 0
          ! grep -E '(^|[^A-Za-z])warning:' "$RUNNER_TEMP/build-release.log"
      - name: Build (debug, warnings fail)
        run: |
          swift build 2>&1 | tee "$RUNNER_TEMP/build-debug.log"
          test "${PIPESTATUS[0]}" -eq 0
          ! grep -E '(^|[^A-Za-z])warning:' "$RUNNER_TEMP/build-debug.log"
      - name: Test
        run: swift test --parallel
      - name: Bundle
        run: |
          scripts/bundle.sh release
          codesign --verify --strict .build/macExplorer.app

  scenarios:
    runs-on: macos-26
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s "/Applications/Xcode_${XCODE_VERSION}.app"
      - name: Core scenarios (disk images, crash recovery)
        run: scripts/run-scenarios.sh release
      - name: UI scenarios (bundled app, sandboxed)
        run: scripts/ui-scenarios.sh --require-gui
      - name: Upload scenario reports
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: scenario-reports
          path: |
            .build/scenario-report.json
            .build/ui-scenario-report.json
            .build/ui-scenario-logs/
          if-no-files-found: ignore

  bench:
    runs-on: macos-26
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Select Xcode
        run: sudo xcode-select -s "/Applications/Xcode_${XCODE_VERSION}.app"
      - name: Baseline cache key (runner image + architecture)
        id: key
        run: |
          image="${ImageOS:-macos}-${ImageVersion:-$(sw_vers -buildVersion)}"
          echo "prefix=bench-baseline-${image}-$(uname -m)-" >> "$GITHUB_OUTPUT"
      - name: Restore the main baseline for this image
        if: github.event_name == 'pull_request'
        uses: actions/cache/restore@v4
        with:
          path: .build/bench-baseline.json
          key: ${{ steps.key.outputs.prefix }}${{ github.event.pull_request.base.sha }}
          restore-keys: ${{ steps.key.outputs.prefix }}
      - name: Measure the base commit when no baseline exists for this image
        if: github.event_name == 'pull_request'
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
        run: |
          mkdir -p .build
          if [ -f .build/bench-baseline.json ]; then echo "baseline restored from cache"; exit 0; fi
          git worktree add "$RUNNER_TEMP/base" "$BASE_SHA"
          if (cd "$RUNNER_TEMP/base" && swift run -c release macx-bench --output "$GITHUB_WORKSPACE/.build/bench-baseline.json"); then
            echo "baseline measured on $BASE_SHA"
          else
            rm -f .build/bench-baseline.json
            echo "::notice title=Benchmark baseline::the base commit has no working macx-bench; relative gate skipped"
          fi
      - name: Benchmark (relative gate; budgets as warnings)
        run: |
          args=(--output .build/bench.json --warn-budgets)
          if [ -f .build/bench-baseline.json ]; then args+=(--compare .build/bench-baseline.json); fi
          swift run -c release macx-bench "${args[@]}" | tee "$RUNNER_TEMP/bench.txt"
          status=${PIPESTATUS[0]}
          { echo '### macx-bench'; echo '```'; grep -vE '^::' "$RUNNER_TEMP/bench.txt"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
          exit "$status"
      - name: Keep this run as the main baseline
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: cp .build/bench.json .build/bench-baseline.json
      - name: Save the main baseline
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: actions/cache/save@v4
        with:
          path: .build/bench-baseline.json
          key: ${{ steps.key.outputs.prefix }}${{ github.sha }}
      - name: Upload bench report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: bench
          path: .build/bench*.json
          if-no-files-found: ignore
```

How the bench gate meets §9:
- **Baseline from `main` on the same image.** Every push to `main` saves its `bench.json` under `bench-baseline-<ImageOS>-<ImageVersion>-<arch>-<sha>`. A pull request restores the newest entry with its image's prefix (caches saved on `main` are readable from pull requests).
- **Recomputed when the image changes.** A new runner image has a new prefix, so nothing is restored. The job then measures the PR's base commit in a `git worktree` under `$RUNNER_TEMP` on the same machine, and gates against that.
- **Relative gate.** `--compare` makes `macx-bench` exit 1 on a regression (>20% **and** >5 ms, `BaselineCompare.isRegression`), which fails the job.
- **Budgets as warnings.** `--warn-budgets` prints `::warning title=Performance budget::…` lines, which GitHub shows as annotations, and never changes the exit code. CI never passes `--check-budgets` (shared runners are noisy; §9 gates the budgets on Apple Silicon per release).

The `scenarios` job runs on a hosted macOS runner, which has a logged-in GUI session. `--require-gui` makes a missing session a failure rather than a silent skip. The tag workflow from §10 (universal binary, Developer ID, notarization, DMG, cask) is not part of Phase 1 (Contract note C14).

Lint it: `ruby -e 'require "yaml"; y = YAML.safe_load(File.read(ARGV[0])); puts y["jobs"].keys.join(" ")' .github/workflows/ci.yml`
Expected: `build-test scenarios bench`. If `actionlint` is installed (`command -v actionlint`), also run `actionlint .github/workflows/ci.yml` and expect no output. It is not a project dependency.

- [ ] **Step 7: Write `README.md`**

The file map asks for build/test/bench/run instructions, the Finder-replacement non-goal and the cut→Finder caveat. The task table adds the release checklist section. It covers the §9 manual checklist and the §4.4 rows that `macx-bench` does not measure (Contract note C10).

````markdown
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
````

Check the commands it names exist: `for s in bundle.sh make-fixtures.sh run-scenarios.sh ui-scenarios.sh ui-ax-smoke.sh check-layering.sh verify-phase1.sh; do test -x "scripts/$s" || echo "missing $s"; done`
Expected: no output.

- [ ] **Step 8: Run the full-suite verification**

Run it on Apple Silicon, in a Terminal window of a logged-in session, with nothing else using `${TMPDIR}/macx-*` (a concurrent test run elsewhere makes the `safety` gate report its directories as new). Do not copy anything to the clipboard while it runs. It takes about 15–30 minutes.

Run: `scripts/verify-phase1.sh 2>&1 | tee "${TMPDIR%/}/verify-phase1-$(date +%s).txt" | grep -E '^(run directory|GATE|verify-phase1|sandbox root)'`

Expected:

```
run directory: …/macx-verify-<UUID>
GATE layering PASS (… s)
GATE layering-selftest PASS (… s)
GATE build-release PASS (… s)
GATE build-debug PASS (… s)
GATE test PASS (… s)
GATE app-launch PASS (… s)
GATE core-scenarios PASS (… s)
GATE ui-scenarios PASS (… s)
GATE bench PASS (… s)
GATE safety PASS (… s)
verify-phase1: 10/10 gates passed
sandbox root …/macx-verify-<UUID> removed (logs in …/.build/verify-phase1/macx-verify-<UUID>)
```

Exit code 0. Then:
- `cat .build/verify-phase1/macx-verify-*/safety.log` lists one `gone: <path>` line per sandbox root the runners reported (the test sandboxes, the run-scenarios root and its 57 scenario sandboxes, the UI run directory, the bench sandbox, the layering self-test sandbox), and no `LEFT BEHIND`/`NEW IN TMPDIR`/`STILL MOUNTED` line.
- `.build/verify-phase1/macx-verify-*/bench.json` has `sandboxRemoved: true`.
- Remove the tee transcript: `rm "${TMPDIR%/}"/verify-phase1-<that timestamp>.txt` (only that file).

A failing gate is a real bug in the owning task. In particular:
- `bench` exit 2 (over budget) is a performance bug to fix, not a budget to loosen.
- `ui-scenarios` failures are triaged as in P1-41 Step 10.

Phase 1 is "working" only after a run that prints `10/10 gates passed`. A `--skip-ui` run (exit 3) is not enough.

- [ ] **Step 9: Commit**

```bash
git add scripts/check-layering.sh scripts/test-check-layering.sh scripts/verify-phase1.sh .github/workflows/ci.yml README.md
git commit -m "ci: layering checks, verify-phase1 gate runner, PR workflow with bench gate, README and release checklist"
```

---

## Spec coverage (this slice)

| Spec | Covered by |
|---|---|
| §4.4 budgets measurable headlessly: first rows, 100k list+sort, re-sort, FSEvent incremental and full, steady memory, 100k pasteboard write | P1-39 metric catalogue and `Budgets.table`; `--check-budgets` in `verify-phase1.sh` (`bench` gate); `--warn-budgets` in CI |
| §4.4 scroll/cell configure, main-thread hangs, type and custom icons, peak memory, cold launch | README release checklist item 3 (Instruments), Contract note C10 |
| §9 Benchmarks: 1k/10k/100k fixtures, enumerate, sort keys, sort, re-sort, diff, pasteboard, 1 warm-up + 5, median/p90 JSON | P1-39 `StatsTests`, `BenchCLITests`, `BenchSmokeTests`, Step 8 |
| §9 CI relative gate (>20% and >5 ms, same-image `main` baseline, recomputed on image change) | P1-39 `BaselineCompareTests` (`testLenientDecodingOfOlderBaselines`, `testNewAndMissingMetricsNeverFail`); P1-42 `ci.yml` `bench` job |
| §9 CoreTests list end to end (every job kind, conflicts, pause/cancel, cross-volume kill during copy and Replace, EROFS/ENOSPC/exFAT images, metadata, undo incl. external changes, stale cut marker) | P1-40 catalog (57 scenarios), `run-scenarios.sh`; Review Focus 1 and 5 of the overview re-run end to end |
| §9 Watcher tests (bursts, atomic save, changes during enumeration, events outside the folder) | P1-40 `WatcherScenarios.swift` |
| §9 UI smoke suite (address bar, F2, cut/paste, drag-move, right-drag menu, conflict dialog, Properties, undo, colliding keys reach the field editor) | P1-41 `Tests/Scenarios/*.json`, `ScenarioCatalogTests.testSpecSmokeListIsCovered`, `ui-scenarios.sh` |
| §5.5 empty states, hidden toggle, filter, Icons spatial arrows; §5.4 type-select; §5.6 key table alternates, paste targets, Esc; §6.6 undo/redo keys | P1-41 `empty-states`, `hidden-toggle`, `filter-in-folder`, `icons-view`, `type-select`, `keyboard-navigation`, `context-menu`, `cut-paste`, `undo-redo` |
| §5.6 key routing rules 1–3 (field editor wins) | P1-41 `colliding-keys.json` |
| §8 accessibility identifiers reachable out of process | P1-41 `ui-ax-smoke.sh` (window title, `macx.window`, `macx.details` rows); README checklist item 4 (VoiceOver) |
| §9 manual checklist per release (`--check-budgets`, VoiceOver, dark/light, Reduce Transparency, USB drive incl. eject, SMB, iCloud placeholders) | README release checklist items 1–9 |
| §10 Local (`swift build -c release`, `bundle.sh`, `swift test`, `swift run -c release macx-bench`) | README "Build and run" and "Tests, scenarios and benchmarks"; `verify-phase1.sh` gates `build-release`, `app-launch`, `test`, `bench` |
| §10 CI on each PR (build, test, bench with the relative gate) | `ci.yml` jobs `build-test`, `scenarios`, `bench` |
| §10 CI on a tag (universal binary, Developer ID, notarization, DMG, cask) | not in Phase 1 (Contract note C14) |
| §4.1 layering (with the `MacxFS` and `Core/Platform` deviations) | `check-layering.sh` rules `appkit-in-core`, `upward-import`, `fixtures-in-app`, `manifest-fixtures`; `test-check-layering.sh` |
| §1 non-goal "README documents that Finder is not replaced"; §5.6 "cut in macExplorer, paste in Finder copies" | README "Things macExplorer does not do" |
| §12 risks: Hangs instrument and iCloud check per release; benchmark noise on shared runners | README checklist items 3 and 8; relative gate plus same-image baseline in `ci.yml` |
| Overview Safety HARD RULE | S6 Global Constraints; every runner's EXIT trap; P1-40 `testImagesAreDetachedWhenScenarioThrows`, `testFailingScenarioReportsMessageAndStillCleansUp`; P1-41 `testFixturesRefuseEscapingPaths`; `check-layering.sh` `test-globals`, `system-trash`, `users-literal`; `verify-phase1.sh` `safety` gate |
| Overview "Phase 1 working definition" 1–6 | `verify-phase1.sh` (P1-42 Step 8) |

## Contract notes

Gaps or deviations found while writing this slice. The overview was not edited by this slice; the consistency pass of 2026-11-02 already folded C1, C2 and C4–C6 into overview §1, §3.0 and §3.14.

- **C1. `MacxFixtures` was not in overview §3.** S6 uses S1 P1-02's declarations exactly (the table near the top of this file, now overview §3.0). Only the two `FixtureAdapter.swift` files (`macx-bench`, `macx-scenarios`) and three UITests files name them. If P1-02 ships different names, adapt those files only, never P1-02.
- **C2. Two test targets are appended to the manifest:** `BenchTests` (P1-39) and `ScenarioRunnerTests` (P1-40), after `UITests`, with the `strict` settings. Tests import the executables as `@testable import macx_bench` / `macx_scenarios` (fact 1).
- **C3. No `Sandbox(adopting:)` in the app.** S1 Contract notes 1 suggests it for `--root`. But `UI` must not link `MacxFixtures` (enforced by `fixtures-in-app` and `manifest-fixtures`), and the UI runner's roots are `<run dir>/<scenario>/macx-scenario-root`, not direct children of `$TMPDIR`. `ScenarioFixtures` applies its own guard: the root's last component starts with `macx-scenario-`, the root is empty, every relative path passes `ScenarioPath.isSafeRelative` and stays under the root after standardization.
- **C4. Conflict answers come from a decorator.** SwiftUI hosting views expose no in-process accessibility children (fact 8), so the conflict dialog's buttons cannot be pressed from inside the process. `ScenarioInteraction` wraps the real `InteractionRouter`: the router still presents the real sheet on the origin window (scenarios assert `sheetPresent`), the scenario's `answerConflict` step supplies the `ConflictResolution`, and the driver then ends the sheet. P1-38's router must therefore tolerate its sheet being ended from outside while its presenter task is cancelled (it answers nothing; the decorator ignores the forwarded answer). The real buttons are covered by P1-38's own tests and the release VoiceOver pass.
- **C5. No `symlink` drop choice.** `DragOperation` has no symlink case, so `Drop.choose` accepts `copy`, `move`, `alias` and `cancel` only, and the driver rejects anything else with a message naming this note. If a later contract adds a symlink drop operation, extend `Drop.choose` validation and the driver switch together.
- **C6. Additive scenario schema fields.** On top of the §3.14 fields, exactly: `Fixture.modes` (`[path: octal string]`, for mode-000 folders), `Step.command` (a `Command` raw value performed through its main-menu item), `Step.answerAlert` (an AppKit alert or sheet button title), and `Expectation.rowCount`, `editingAddress`, `viewMode`, `sheetPresent`, `propertiesWindows`, `windowCount`, `fileSizes`. `Expectation.emptyState` and `banner` are substring matches. The result JSON adds `activated`. All are optional, so files written against the bare §3.14 schema still decode.
- **C7. `ConflictInfo` and `JobSnapshot` have no public initializers** in the contract. `ScenarioInteractionTests` gets real values by running a real `FileOpQueue` on a sandbox and letting it hit a conflict. Public memberwise initializers in a later contract revision would let that test be a pure unit test.
- **C8. Key names are pinned by a test, not by the contract.** The S2 plan (P1-13, `KeyChord(parsing:)`) did not exist when this slice was written. `ScenarioCatalogTests.testKeyNamesMapToTheIntendedKeys` pins every key string the scenario files use (the list in P1-41 Interfaces). If P1-13 spells a key differently, change the scenario JSON and that table together, not P1-13. P1-13 must parse at least `cmd`, `shift`, `opt`, `ctrl` and `fn` modifiers joined by `+`, named keys (`delete`, `esc`, `return`, `tab`, arrows, `F1`–`F12`) and single characters.
- **C9. Menu and alert titles are matched in English.** `chooseMenuItem` and `answerAlert` match the visible title ("Duplicate", "Paste", "Cancel", "Delete"), taken from the spec's English wording. Phase 1 is English only, and the titles come from `Localizable.xcstrings`. If a title there differs from the spec, align the string catalog with the spec, not the scenario. When localization arrives (later phase), the driver should match menu items by action selector instead.
- **C10. Some §4.4 rows are not measured headlessly.** `macx-bench` cannot measure scroll fps and cell configure time, main-thread hangs, type/custom icon timing, peak memory during sort/diff, or cold launch: these need a window server and Instruments. They are required items in the README release checklist (item 3), measured with Time Profiler, Hangs, Allocations, App Launch and the `PerfSignposts` intervals. `macx-bench` covers every other row (P1-39 metric catalogue).
- **C11. Scope of the `/Users/` literal rule.** `users-literal` checks only this slice's harness files: `Sources/macx-bench`, `Sources/macx-scenarios`, `Tests/BenchTests`, `Tests/ScenarioRunnerTests`, `Tests/UITests/Scenario*.swift` and `Tests/Scenarios/*.json`. S1 and S5 unit tests use `"/Users/…"` strings for mount-table and breadcrumb math that never reach the file system, so they are out of scope (the self-test's `users-other-ok` case pins this).
- **C12. The sandboxed launch check uses the scenarios bundle id.** Working definition 2 says to launch `.build/macExplorer.app` with sandbox arguments. That bundle carries the real id `com.macexplorer.app`, and AppKit would write that preference domain even in sandbox mode. `verify-phase1.sh` therefore checks the real bundle (`bundle.sh release`, bundle id, `codesign --verify --strict`), and launches a release build bundled with `--bundle-id com.macexplorer.app.scenarios`. It reads P1-01's `smoke.json` (`windowTitles`, `root`, `processID`) and requires `windowTitles[0] == "macx-scenario-root"`, P1-01's "window titled with the root's name".
- **C13. Two allowances in the test-safety rules.** (a) S3's `testSystemTrashOnDiskImage` (P1-17) legitimately calls `SystemTrash()` on a test-created disk image, whose Trash is inside the image. The rule allows `SystemTrash()` only inside test methods whose names end in `OnDiskImage`, so new uses must follow that naming and the image-only pattern. (b) P1-40's `--general-pasteboard-changecount` reads `NSPasteboard.general.changeCount` (read-only) so `verify-phase1.sh` can prove that no run wrote the general pasteboard. Lines that only read `.changeCount` are allowed; every other `NSPasteboard.general` use in tests and harnesses fails.
- **C14. No tag/release workflow in Phase 1.** §10's tag pipeline (universal `arm64`+`x86_64` build, Developer ID signing with the hardened runtime, `notarytool submit --wait`, `stapler staple`, zip/DMG upload, cask update in `homebrew-macexplorer`) needs the Developer ID certificate and an App Store Connect API key. Those need the owner to enroll in the Apple Developer Program, and the overview's Phase 1 task list does not include the pipeline. `ci.yml` covers the per-PR half of §10. The release workflow should be its own task once the secrets exist.
