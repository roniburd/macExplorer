# macExplorer Phase 1, Slice S1 (fskit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the file-system foundation of macExplorer: the guarded test-fixture library (`MacxFixtures`), the bounds-checked `getattrlistbulk` C layer (`CFSKit`), and the `MacxFS` module (I/O lanes with a stall watchdog, the struct-of-arrays `EntryStore`, streaming directory reading, byte sort keys and sorting, and the volume table) — tasks P1-02 … P1-08 of the Phase 1 overview.

**Architecture:** Every blocking call runs on an `IOLane` (a dedicated `Thread` with a serial FIFO) owned by the `LanePool` actor, which polls job heartbeats and poisons a lane whose work makes no progress for 2 s. `DirectoryReader` (one actor per volume) streams `Batch`es parsed by the C cursor; `EntryStore` is a copy-on-write value that the main-actor `FolderModel` (S2) owns; `SortKeys`/`Sorter` turn names into memcmp-able byte keys and permutations; `Volumes` is the main-actor registry with a `Mutex`-protected `MountTableStore` mirror for off-main lookups. `MacxFixtures` is the only way tests, benchmarks and scenario runners write files: everything lives in `Sandbox` roots and sandbox-owned disk images.

**Tech Stack:** Swift 6.4.2 (Xcode 27.2, swift-tools-version 6.2, Swift 6 language mode, warnings as errors), C (`-Wall -Wextra -Werror`), Darwin (`getattrlistbulk`, `getattrlistat`, `getattrlist`, `readdir`, `setiopolicy_np`, `getmntinfo`), Foundation, UniformTypeIdentifiers, Synchronization (`Mutex`, `Atomic`), Observation, os (`OSSignposter`), XCTest via `swift test`, `hdiutil`.

**Spec:** `docs/superpowers/specs/2026-11-01-macexplorer-design.md` (sections cited per task). Overview and binding interface contract: `docs/superpowers/plans/2026-11-01-phase1-00-overview.md` (§3.1–§3.6 are this slice's public API; copy them exactly).

**How this plan was checked:** every source and test file below was compiled and run on 2026-11-02 in a throwaway package under `$TMPDIR` (Xcode 27.2, Swift 6.4.2, macOS 26.7.2, M3 Pro) with the same `Package.swift` settings: 100 tests, 0 failures, `swift test --parallel` green, `--sanitize=address` green for the fuzz tests. The findings that shaped the code are listed in "Contract notes" at the end.

## Global Constraints

Global Constraints: see overview, all apply (safety HARD RULE, platform/language, performance budgets, testing). Repeated here because every task depends on it:

- **Safety (HARD RULE):** tests, benchmarks and any manual/automated validation must ONLY create/modify/delete files inside fresh temp directories they create themselves (`FileManager.default.temporaryDirectory/macx-tests-<UUID>`, `macx-bench-<UUID>`, `macx-scenario-<UUID>`, `macx-fixtures-<UUID>`) or disk images they create (inside such a directory, attached with `-mountpoint <that dir>/mnt-<id> -nobrowse`). Never touch, move, rename, trash or delete any pre-existing user file. The app may READ the user's real folders when browsing, but automated scenarios must point the app at a sandbox dir.
- Slice-specific rules that implement it:
  - Every test that writes creates a `Sandbox` in `setUp` and registers `addTeardownBlock { sandbox.destroy() }`. Fixture writes use `Sandbox` helpers or URLs obtained from `sandbox.url(_:)`; `FileManager` write APIs are never called on any other path.
  - `Sandbox` resolves symlinks and `..` like the kernel does and traps (`preconditionFailure`) on any path outside its root. `Sandbox.destroy()` refuses (traps) unless the root is directly in the temporary directory with an allowed prefix, force-detaches every image mounted under the root first, and deletes only the root.
  - Trap tests run the trapping code in a child `xctest` process (`TrapProbe`) whose only "outside" target is a second test-owned sandbox; the parent asserts that sandbox stayed empty.
  - `DiskImage` only creates images inside a sandbox and always attaches with `-nobrowse -noautoopen -mountpoint <sandbox>/mnt-<id>`; tests also `detach()` explicitly.
  - Lane tests simulate hung reads with `Gate` semaphores, never with a real hung mount; every `Gate` is opened in `tearDown`.
  - `scripts/make-fixtures.sh` creates `${TMPDIR}/macx-fixtures-<UUID>` itself and its `--remove` refuses any other path.
- No `@unchecked Sendable` and no `nonisolated(unsafe)` anywhere in this slice (none is needed: shared mutable state is in `Mutex`/`Atomic` or actors).
- Module `MacxFS` lives in `Sources/FSKit` (system `FSKit.framework` name clash); tests import `MacxFS` (`@testable` where they use internal seams).
- Every `MacxFS` function that makes a blocking file-system call starts with `assertOffMain()`.
- **Toolchain hazard (verified):** never pass a closure declared `throws(E)` where a plain `throws` closure is expected (`LanePool.perform`, `withNoMaterialization`). With Swift 6.4.2 this produced a corrupted error payload (`ReadFailure(code: -1299264944)`). Inside such closures call typed-throws functions normally, or convert to `Result` with `do throws(E) { … } catch { … }`.
- `String(cString:)` is deprecated in this SDK and warnings are errors: decode C char arrays with `withUnsafeBytes` + `String(decoding:as:)`.
- Each task ends with `swift build 2>&1 | tail -5` showing `Build complete!` (no warnings), its own filtered test run showing `0 failures`, and a commit (`git add <files>`; never `git add -A`; never push).

## Review Focus

The five inputs this slice's code meets in real use that the spec does not spell out, most likely to bite first. Each has a test in the owning task (the overview's five Review Focus items belong to S2/S3/S5 tasks; this slice supplies their groundwork: `EntryStore.firstIndex(named:)` sees hidden rows (P1-05, for Review Focus 2) and the reader never follows symlinks (P1-06, for Review Focus 4)).

1. **A volume that hangs mid-listing (dead SMB/NFS server, sleeping USB disk).** Expected: the read reports `.stalled` after 2 s, the lane is poisoned and never reused, Retry gets a fresh lane, the late result still arrives tagged with its old generation, and after 4 poisoned lanes the volume reads fail fast as `unresponsiveVolume` until it remounts. Owner P1-04 `testHungReadPoisonsLaneAndRetryGetsFreshLane`, `testPoisonCapMarksVolumeUnresponsiveUntilReset`, `testJobsQueuedBehindAHungJobMoveToAFreshLane`; P1-06 `testHungReadReportsStalledThenResumed`, `testUnresponsiveVolumeFailsReadsImmediately`, `testStaleGenerationResultsCanBeDiscardedByTheConsumer`; P1-08 `testReappearingVolumeResetsUnresponsiveMark`.
2. **Names that are not valid UTF-8 or are stored NFD (SMB, FAT, files copied from Linux).** Expected: the row appears with a lossy display name, raw bytes are kept for operations, identity and sort keys never trap, and NFD/NFC spellings get identical sort keys. Owner P1-05 `testInvalidUTF8NamesDecodeLossilyWithoutTrapping`, `testNameIdentityIsNFCAndCaseFoldedOnCaseInsensitiveVolumes`; P1-06 golden NFD assertion; P1-07 `testFoldingAndNFCTieBreak`.
3. **Malformed or truncated `getattrlistbulk` buffers (buggy FUSE/SMB file systems, short reads).** Expected: a bad record is dropped, a bad length stops the buffer, nothing reads out of bounds, the folder still lists the good entries. Owner P1-03 `CursorFuzzTests` (100k random buffers, 100k byte-flip mutations, every truncation, under ASan).
4. **Non-APFS volumes (exFAT/FAT USB sticks, HFS+ images): no persistent IDs, no hard links, no allocation size, zero "important usage" capacity.** Expected: identity falls back to normalized names, missing attributes are zero rather than degraded, free space falls back to `volumeAvailableCapacityKey`, and the fallback reader matches the bulk reader there too. Owner P1-03 `testVolumeCapabilitiesOfExFATImage`; P1-06 `testFallbackMatchesBulkOnHFSImage`; P1-08 `testDiskImagesAppearWithCapabilitiesAndDisappearAfterDetach`, `testVolumesHandleSeesRealImageMountAndUnmount`.
5. **The user navigates away while a big folder is still streaming.** Expected: ending iteration of the stream cancels the lane work at the next batch boundary, the fd closes, `cancelAll()` (eject/unmount) returns within 1 s even if a read is hung. Owner P1-06 `testStoppingIterationCancelsTheLaneWork`, `testCancelAllWaitsAtMostOneSecond`; P1-04 `testCancellingAQueuedJobThrowsCancelledWithoutRunningIt`, `testRunningJobSeesCancellation`.

## File structure (this slice)

```
Sources/MacxFixtures/Sandbox.swift          [P1-02] guarded temp root; all fixture writes; destroy()
Sources/MacxFixtures/DiskImage.swift        [P1-02] hdiutil create/attach/detach inside a Sandbox
Sources/MacxFixtures/FixtureTree.swift      [P1-02] GoldenName (§9 tree), golden/flat/deep builders
Sources/MacxFixtures/TrapProbe.swift        [P1-02] run one XCTest in a child xctest process to prove a trap
Sources/MacxFixtures/SortCorpus.swift       [P1-07] deterministic 5k-name corpus
scripts/make-fixtures.sh                    [P1-02] shell twin of the golden tree (+ --flat N, --remove)
Sources/CFSKit/include/CFSKit.h             [P1-03] contract §3.1 header (verbatim)
Sources/CFSKit/cursor.c                     [P1-03] bounds-checked record parser
Sources/CFSKit/bulk.c                       [P1-03] attribute list, cfsk_bulk_read, cfsk_stat_at
Sources/CFSKit/iopolicy.c                   [P1-03] materialization policy
Sources/CFSKit/volcaps.c                    [P1-03] ATTR_VOL_CAPABILITIES
Sources/FSKit/Support/{Observers,MainThread,PerfSignposts}.swift      [P1-04]
Sources/FSKit/Lanes/{Generation,Materialization,LaneContext,IOLane,Watchdog,LanePool}.swift  [P1-04]
Sources/FSKit/Volumes/VolumeInfo.swift      [P1-04 creates with VolumeID only; P1-08 completes]
Sources/FSKit/Store/{Entry,NameArena,Batch,RowID,TypeRegistry,EntryStore}.swift              [P1-05]
Sources/FSKit/Reader/{ReadTypes,RecordConverter,BulkReader,FallbackReader,ItemReader,DirectoryReader}.swift  [P1-06]
Sources/FSKit/Sort/{ViewQuery,SortKeyColumn,SortKeys,Sorter}.swift    [P1-07]
Sources/FSKit/Volumes/{MountTable,VolumeScanner,Volumes}.swift        [P1-08]
Sources/FSKit/Reader/DirectoryReaders.swift [P1-08] (moved from P1-06: needs MountTableStore)
Tests/MacxFixturesTests/{SandboxTests,DiskImageTests,FixtureTreeTests}.swift                 [P1-02]
Tests/FSKitTests/Support/RecordBuilder.swift [P1-03] hand-built getattrlistbulk records
Tests/FSKitTests/Support/TestHelpers.swift   [P1-04] Recorder, Gate, eventually
Tests/FSKitTests/Support/ReadHelpers.swift   [P1-06] readAll, collect
Tests/FSKitTests/Support/SortDivergence.swift [P1-07] divergence finder + categories
Tests/FSKitTests/{CFSKitTests,CursorFuzzTests}.swift                  [P1-03]
Tests/FSKitTests/LaneTests.swift            [P1-04]
Tests/FSKitTests/{EntryStoreTests,TypeRegistryTests}.swift            [P1-05]
Tests/FSKitTests/{ReaderGoldenTests,ReaderParityTests,DirectoryReaderTests}.swift            [P1-06]
Tests/FSKitTests/{SortGoldenTests,SorterTests}.swift                  [P1-07]
Tests/FSKitTests/Corpus/sort-allowed-divergences.json                 [P1-07, generated by record mode]
Tests/FSKitTests/VolumesTests.swift         [P1-08]
```

P1-01 (S4) creates `Package.swift` exactly as in overview §1 plus one stub file per target. When a task below adds the first real file to a target, it deletes that target's stub (check with `git ls-files Sources/<dir> Tests/<dir>`; the stub is the file P1-01 created only to make the target compile). Test targets must always contain at least one test: with Xcode installed each test target is its own `.xctest` bundle and an empty one fails to load ("The bundle … couldn't be loaded because its executable couldn't be located"), so delete a test-target stub only in the same commit that adds real tests to it.

---
## Task P1-02: MacxFixtures: Sandbox, DiskImage, FixtureTree, TrapProbe, make-fixtures.sh

**Spec:** §9 FSKitTests (fixture generator `scripts/make-fixtures.sh` plus a Swift helper; golden tree kinds), §9 CoreTests (disk images via `hdiutil`), overview Global Constraints › Safety.

**Files:**
- Create: `Sources/MacxFixtures/Sandbox.swift`
- Create: `Sources/MacxFixtures/DiskImage.swift`
- Create: `Sources/MacxFixtures/FixtureTree.swift`
- Create: `Sources/MacxFixtures/TrapProbe.swift`
- Create: `scripts/make-fixtures.sh`
- Test: `Tests/MacxFixturesTests/SandboxTests.swift`
- Test: `Tests/MacxFixturesTests/DiskImageTests.swift`
- Test: `Tests/MacxFixturesTests/FixtureTreeTests.swift`
- Delete: P1-01's stub files in `Sources/MacxFixtures/` and `Tests/MacxFixturesTests/`

**Interfaces:**
- Consumes: P1-01 `Package.swift` (targets `MacxFixtures`, `MacxFixturesTests`). Nothing from MacxFS yet.
- Produces: the MacxFixtures API every later test, `macx-bench` and `macx-scenarios` uses (not in overview §3; see Contract notes 1 — copy these names exactly):

```swift
public final class Sandbox: Sendable {
    public static let allowedPrefixes: [String]            // macx-tests, macx-bench, macx-scenario, macx-fixtures
    public let root: URL                                     // symlink-resolved, /private/var/folders/…/T/<prefix>-<UUID>
    public init(prefix: String = "macx-tests") throws
    public init(adopting directory: URL) throws              // runner-created <prefix>-* dir directly in $TMPDIR
    public func contains(_ url: URL) -> Bool
    @discardableResult public func checked(_ url: URL, file: StaticString = #fileID, line: UInt = #line) -> URL   // traps outside
    public func url(_ relative: String, file: StaticString = #fileID, line: UInt = #line) -> URL               // traps outside
    @discardableResult public func createDirectory(_ relative: String) throws -> URL
    @discardableResult public func createFile(_ relative: String, contents: Data = Data("x".utf8)) throws -> URL
    public func overwrite(_ relative: String, contents: Data) throws
    public func append(_ relative: String, contents: Data) throws
    @discardableResult public func createSparseFile(_ relative: String, size: Int64) throws -> URL
    @discardableResult public func createSymlink(_ relative: String, target: String) throws -> URL
    @discardableResult public func createHardLink(_ relative: String, to existing: String) throws -> URL
    @discardableResult public func createAlias(_ relative: String, to target: String) throws -> URL
    public func setFlags(_ relative: String, _ flags: UInt32) throws          // lchflags, replaces all flags
    public func setMode(_ relative: String, _ mode: mode_t) throws
    public func setXattr(_ relative: String, name: String, value: Data) throws
    public func setHiddenExtension(_ relative: String, _ hidden: Bool = true) throws
    public func setDates(_ relative: String, modified: Date? = nil, created: Date? = nil) throws
    public func rename(_ from: String, to: String) throws
    public func remove(_ relative: String) throws
    public func destroy()                                     // idempotent; detaches images first
    public static func resolvedTemporaryDirectory() throws -> String
}
public enum SandboxError: Error, Equatable, Sendable { case notASandboxDirectory(String) }
public enum DiskImageFormat: String, Sendable, CaseIterable { case apfs = "APFS", hfsPlus = "HFS+", exfat = "ExFAT", msdos = "MS-DOS" }
public enum DiskImageError: Error, Sendable, Equatable { case hdiutilFailed(arguments: [String], status: Int32, output: String), timedOut(arguments: [String]) }
public final class DiskImage: Sendable {
    public let imageURL: URL, mountPoint: URL, relativeMountPath: String, format: DiskImageFormat, isReadOnly: Bool
    public static var isAvailable: Bool { get }
    public static func create(in sandbox: Sandbox, format: DiskImageFormat, sizeMB: Int = 32, volumeName: String = "MACXTEST",
                              readOnly: Bool = false, populate: ((URL) throws -> Void)? = nil) throws -> DiskImage
    public func detach() throws                               // hdiutil detach -force; idempotent
}
public enum GoldenName { public static let plain, empty, sparse, nfc, nfd, emoji, long255, long255Multibyte, dotHidden, flagHidden,
    symlinkToFile, symlinkToDir, brokenSymlink, alias, app, rtfd, folder, dottedFolder, locked, xattrs, extensionHidden,
    hardLinkA, hardLinkB, noAccessDir, noAccessFile, executable, readOnly, dated: String; public static let all: [String] }
public enum FixtureTree {
    @discardableResult public static func golden(in sandbox: Sandbox, at relative: String = "golden") throws -> URL
    @discardableResult public static func flat(in sandbox: Sandbox, at relative: String, count: Int, prefix: String = "file-",
                                               ext: String = ".txt", width: Int = 6, directoriesEvery: Int = 0) throws -> URL
    @discardableResult public static func deep(in sandbox: Sandbox, at relative: String, depth: Int, breadth: Int, filesPerDir: Int) throws -> URL
}
public enum TrapProbe {
    public static let environmentKey: String                 // "MACX_TRAP_PROBE"
    public static let trappedStatus: Int32                   // 86
    public struct Result: Sendable, Equatable { public var status: Int32; public var trapped: Bool { get }; public var output: String }
    public static func isChild(_ name: String) -> Bool
    public static func value(_ key: String) -> String?
    public static func run(name: String, testIdentifier: String, bundle: URL, environment: [String: String] = [:]) throws -> Result
}
```

Usage pattern for every later test that touches the file system:

```swift
override func setUpWithError() throws {
    sandbox = try Sandbox()
    let s = sandbox!
    addTeardownBlock { s.destroy() }
}
```

- [ ] **Step 1: Write the failing Sandbox tests**

Create `Tests/MacxFixturesTests/SandboxTests.swift`:

```swift
import Darwin
import Foundation
import XCTest
@testable import MacxFixtures

final class SandboxTests: XCTestCase {
    private var sandbox: Sandbox!
    private var outside: Sandbox!   // a second sandbox: the only "outside" place a broken guard could touch

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        outside = try Sandbox()
        let s = sandbox!, o = outside!
        addTeardownBlock { s.destroy(); o.destroy() }
    }

    func testRootIsFreshResolvedTempDirectory() throws {
        let temp = try Sandbox.resolvedTemporaryDirectory()
        let path = sandbox.root.path(percentEncoded: false)
        XCTAssertTrue(path.hasPrefix(temp + "/macx-tests-"), path)
        XCTAssertTrue(path.hasPrefix("/private/"), "root must be symlink-resolved: \(path)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path), [])
    }

    func testContainsRejectsEscapes() throws {
        try sandbox.createDirectory("d")
        try sandbox.createSymlink("out-link", target: outside.root.path(percentEncoded: false))
        try sandbox.createSymlink("d/up-link", target: "../..")
        try sandbox.createSymlink("dangling-out", target: outside.root.path(percentEncoded: false) + "/new.txt")
        XCTAssertTrue(sandbox.contains(sandbox.root.appending(path: "d/new.txt")))
        XCTAssertTrue(sandbox.contains(sandbox.root.appending(path: "d/../x")))
        XCTAssertFalse(sandbox.contains(sandbox.root.appending(path: "../escape.txt")))
        XCTAssertFalse(sandbox.contains(sandbox.root.appending(path: "out-link/x.txt")))
        XCTAssertFalse(sandbox.contains(sandbox.root.appending(path: "d/up-link/x.txt")))
        XCTAssertFalse(sandbox.contains(sandbox.root.appending(path: "dangling-out")))
        XCTAssertFalse(sandbox.contains(URL(filePath: "/tmp/x")))
        XCTAssertFalse(sandbox.contains(outside.root))
    }

    func testWriteHelpersStayInside() throws {
        let file = try sandbox.createFile("a/b/c.txt", contents: Data("hello".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("hello".utf8))
        try sandbox.createHardLink("a/hard.txt", to: "a/b/c.txt")
        try sandbox.createSymlink("a/link", target: "b/c.txt")
        try sandbox.setFlags("a/b/c.txt", UInt32(UF_IMMUTABLE))
        try sandbox.createSparseFile("sparse.bin", size: 1 << 20)
        var st = stat()
        XCTAssertEqual(lstat(sandbox.url("sparse.bin").path(percentEncoded: false), &st), 0)
        XCTAssertEqual(st.st_size, 1 << 20)
        XCTAssertThrowsError(try sandbox.createFile("a/link"), "createFile must not write through a symlink")
    }

    func testDestroyRemovesLockedAndUnreadableContent() throws {
        try sandbox.createFile("locked.txt")
        try sandbox.setFlags("locked.txt", UInt32(UF_IMMUTABLE))
        try sandbox.createFile("closed/inner.txt")
        try sandbox.setMode("closed", 0)
        let path = sandbox.root.path(percentEncoded: false)
        sandbox.destroy()
        XCTAssertNotEqual(access(path, F_OK), 0)
        sandbox.destroy()   // idempotent
    }

    func testAdoptingRefusesNonSandboxDirectories() throws {
        XCTAssertThrowsError(try Sandbox(adopting: URL(filePath: NSHomeDirectory())))
        XCTAssertThrowsError(try Sandbox(adopting: sandbox.root.appending(path: "nested")))
        let adopted = try Sandbox(adopting: outside.root)
        XCTAssertEqual(adopted.root, outside.root)
    }

    func testOutOfSandboxWritesTrap() throws {
        if TrapProbe.value(TrapProbe.environmentKey) != nil { throw XCTSkip("in child") }
        try sandbox.createSymlink("out", target: outside.root.path(percentEncoded: false))
        let bundle = Bundle(for: SandboxTests.self).bundleURL
        let env = ["MACX_SANDBOX": sandbox.root.path(percentEncoded: false),
                   "MACX_OUTSIDE": outside.root.path(percentEncoded: false)]
        for (name, test) in [("escape", "testProbeChildEscape"), ("dotdot", "testProbeChildDotDot")] {
            let result = try TrapProbe.run(name: name, testIdentifier: "MacxFixturesTests.SandboxTrapProbes/\(test)",
                                           bundle: bundle, environment: env)
            XCTAssertTrue(result.trapped, "\(name): status \(result.status)\n\(result.output.suffix(2000))")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.root.path(percentEncoded: false)), [],
                       "nothing may be written outside the sandbox")
    }
}

/// Child-process halves of testOutOfSandboxWritesTrap. No setUp: the parent owns both sandboxes and the
/// child adopts them, so a trapping child leaks nothing.
final class SandboxTrapProbes: XCTestCase {
    func testProbeChildEscape() throws {
        guard TrapProbe.isChild("escape") else { throw XCTSkip("trap probe child only") }
        let s = try Sandbox(adopting: URL(filePath: TrapProbe.value("MACX_SANDBOX")!))
        _ = try s.createFile("out/escaped.txt")   // "out" links to the other sandbox: must trap before writing
        XCTFail("createFile through an escaping symlink did not trap")
    }

    func testProbeChildDotDot() throws {
        guard TrapProbe.isChild("dotdot") else { throw XCTSkip("trap probe child only") }
        let s = try Sandbox(adopting: URL(filePath: TrapProbe.value("MACX_SANDBOX")!))
        _ = s.url("../\((TrapProbe.value("MACX_OUTSIDE")! as NSString).lastPathComponent)/escaped.txt")
        XCTFail("url(..) did not trap")
    }

}
```

- [ ] **Step 2: Write the failing DiskImage and FixtureTree tests**

Create `Tests/MacxFixturesTests/DiskImageTests.swift`:

```swift
import Darwin
import Foundation
import XCTest
@testable import MacxFixtures

final class DiskImageTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func fsType(_ url: URL) -> String {
        var st = statfs()
        guard statfs(url.path(percentEncoded: false), &st) == 0 else { return "?" }
        return withUnsafeBytes(of: &st.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    func testEachFormatMountsInsideSandboxWithNoBrowse() throws {
        let expected: [DiskImageFormat: String] = [.apfs: "apfs", .hfsPlus: "hfs", .exfat: "exfat", .msdos: "msdos"]
        for format in DiskImageFormat.allCases {
            let image = try DiskImage.create(in: sandbox, format: format, sizeMB: 16)
            XCTAssertTrue(sandbox.contains(image.mountPoint))
            XCTAssertEqual(fsType(image.mountPoint), expected[format], "\(format)")
            var st = statfs()
            XCTAssertEqual(statfs(image.mountPoint.path(percentEncoded: false), &st), 0)
            XCTAssertNotEqual(st.f_flags & UInt32(MNT_DONTBROWSE), 0, "\(format) must be mounted -nobrowse")
            try sandbox.createFile(image.relativeMountPath + "/hello.txt")
            try image.detach()
            try image.detach()   // idempotent
            XCTAssertFalse(FileManager.default.fileExists(atPath: image.mountPoint.path(percentEncoded: false) + "/hello.txt"))
        }
    }

    func testReadOnlyImageRejectsWrites() throws {
        let image = try DiskImage.create(in: sandbox, format: .apfs, sizeMB: 16, readOnly: true) { mount in
            try self.sandbox.createFile("\(mount.lastPathComponent)/seed.txt")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.mountPoint.path(percentEncoded: false) + "/seed.txt"))
        XCTAssertThrowsError(try sandbox.createFile(image.relativeMountPath + "/new.txt")) { error in
            XCTAssertEqual((error as NSError).code, Int(EROFS))
        }
    }

    func testDestroyDetachesStillMountedImages() throws {
        let image = try DiskImage.create(in: sandbox, format: .hfsPlus, sizeMB: 16)
        let point = image.mountPoint.path(percentEncoded: false)
        sandbox.destroy()
        XCTAssertFalse(Sandbox.mountPoints(under: (point as NSString).deletingLastPathComponent).contains(point))
        XCTAssertNotEqual(access(sandbox.root.path(percentEncoded: false), F_OK), 0)
    }
}
```

Create `Tests/MacxFixturesTests/FixtureTreeTests.swift`:

```swift
import Darwin
import Foundation
import XCTest
import MacxFixtures

final class FixtureTreeTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func lstatOf(_ url: URL) -> stat? {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0 ? st : nil
    }

    func testGoldenTreeHasEveryKind() throws {
        let root = try FixtureTree.golden(in: sandbox)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)))
        XCTAssertEqual(names.count, GoldenName.all.count)
        for name in GoldenName.all {
            XCTAssertTrue(names.contains(where: { $0 == name && Array($0.utf8) == Array(name.utf8) }) || names.contains(name),
                          "missing \(name)")
        }
        XCTAssertTrue(names.contains { Array($0.unicodeScalars) == Array(GoldenName.nfd.unicodeScalars) }, "NFD name was normalized")
        XCTAssertEqual(GoldenName.long255.utf8.count, 255)
        XCTAssertEqual(GoldenName.long255Multibyte.utf8.count, 255)

        let flagHidden = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.flagHidden)))
        XCTAssertNotEqual(flagHidden.st_flags & UInt32(UF_HIDDEN), 0)
        let locked = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.locked)))
        XCTAssertNotEqual(locked.st_flags & UInt32(UF_IMMUTABLE), 0)
        let a = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.hardLinkA)))
        let b = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.hardLinkB)))
        XCTAssertEqual(a.st_ino, b.st_ino)
        XCTAssertEqual(a.st_nlink, 2)
        let link = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.brokenSymlink)))
        XCTAssertEqual(link.st_mode & S_IFMT, S_IFLNK)
        let sparse = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.sparse)))
        XCTAssertEqual(sparse.st_size, 8 << 20)
        let alias = try root.appending(path: GoldenName.alias).resourceValues(forKeys: [.isAliasFileKey])
        XCTAssertEqual(alias.isAliasFile, true)
        let ext = try root.appending(path: GoldenName.extensionHidden).resourceValues(forKeys: [.hasHiddenExtensionKey])
        XCTAssertEqual(ext.hasHiddenExtension, true)
        let dated = try XCTUnwrap(lstatOf(root.appending(path: GoldenName.dated)))
        XCTAssertEqual(dated.st_mtimespec.tv_sec, 1_012_608_000)
        XCTAssertEqual(dated.st_birthtimespec.tv_sec, 978_307_200)
    }

    func testFlatCreatesExactlyCountEntries() throws {
        let dir = try FixtureTree.flat(in: sandbox, at: "flat", count: 1_000, directoriesEvery: 10)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        XCTAssertEqual(names.count, 1_000)
        XCTAssertTrue(names.contains("file-000001.txt"))
        XCTAssertTrue(names.contains("file-000010"))   // every 10th is a directory without extension
    }

    func testDeepTreeShape() throws {
        let dir = try FixtureTree.deep(in: sandbox, at: "deep", depth: 3, breadth: 2, filesPerDir: 2)
        let all = FileManager.default.enumerator(atPath: dir.path(percentEncoded: false))!.allObjects as! [String]
        // dirs: 2 + 4 = 6; files: 2 × (1 + 2 + 4) = 14
        XCTAssertEqual(all.count, 20)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter MacxFixturesTests 2>&1 | grep -E "error:" | head -5`
Expected: compile errors such as `cannot find 'Sandbox' in scope` / `cannot find 'TrapProbe' in scope`.

- [ ] **Step 4: Implement Sandbox**

Create `Sources/MacxFixtures/Sandbox.swift`. `resolve(_:)` walks the path from `/` component by component, follows every symlink it meets (including dangling ones, textually) and applies `..` to the already-resolved prefix, so `d/up-link/../x`, `out-link/x` and a dangling link to an outside file are all caught — a lexical `standardizedFileURL` check would miss them.

```swift
import Darwin
import Foundation
import Synchronization

/// A guarded temporary directory. Every fixture write made by tests, benchmarks and scenario runners
/// goes through a Sandbox (Global Constraints, Safety). Any path that resolves outside `root`
/// (after following symlinks of existing components, including "..") is a programming error and traps.
public final class Sandbox: Sendable {
    /// Directory-name prefixes a sandbox may use. Teardown refuses to delete anything else.
    public static let allowedPrefixes: [String] = ["macx-tests", "macx-bench", "macx-scenario", "macx-fixtures"]

    /// Fully resolved root, e.g. /private/var/folders/…/T/macx-tests-<UUID>.
    public let root: URL
    private let mounts = Mutex<[String]>([])

    /// Creates `<temporaryDirectory>/<prefix>-<UUID>`.
    public init(prefix: String = "macx-tests") throws {
        precondition(Sandbox.allowedPrefixes.contains(prefix), "Sandbox: unknown prefix \(prefix)")
        let temp = try Sandbox.resolvedTemporaryDirectory()
        let path = temp + "/" + prefix + "-" + UUID().uuidString
        guard mkdir(path, 0o700) == 0 else { throw Sandbox.posixError(errno, path) }
        root = URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Adopts an existing, empty directory created by a runner script (e.g. `--root` of a scenario run).
    /// Refuses (throws) unless it sits directly in the temporary directory and its name starts with an allowed prefix.
    public init(adopting directory: URL) throws {
        let temp = try Sandbox.resolvedTemporaryDirectory()
        guard let resolved = Sandbox.resolve(directory.path(percentEncoded: false)) else {
            throw Sandbox.posixError(ENOENT, directory.path(percentEncoded: false))
        }
        let name = (resolved as NSString).lastPathComponent
        let parent = (resolved as NSString).deletingLastPathComponent
        guard parent == temp, Sandbox.allowedPrefixes.contains(where: { name.hasPrefix($0 + "-") }) else {
            throw SandboxError.notASandboxDirectory(resolved)
        }
        root = URL(filePath: resolved, directoryHint: .isDirectory)
    }

    // MARK: Guard

    /// True when `url` resolves to `root` or something below it.
    public func contains(_ url: URL) -> Bool {
        guard let resolved = Sandbox.resolve(url.path(percentEncoded: false)) else { return false }
        let base = root.path(percentEncoded: false).trimmingSuffix("/")
        return resolved == base || resolved.hasPrefix(base + "/")
    }

    /// Returns `url` unchanged if it is inside the sandbox; traps otherwise.
    @discardableResult
    public func checked(_ url: URL, file: StaticString = #fileID, line: UInt = #line) -> URL {
        if !contains(url) {
            preconditionFailure("Sandbox violation: \(url.path(percentEncoded: false)) is outside \(root.path(percentEncoded: false))",
                                file: file, line: line)
        }
        return url
    }

    /// URL of `relative` (no leading "/") inside the sandbox; traps if it escapes.
    public func url(_ relative: String, file: StaticString = #fileID, line: UInt = #line) -> URL {
        precondition(!relative.hasPrefix("/"), "Sandbox.url expects a relative path, got \(relative)", file: file, line: line)
        let url = relative.isEmpty ? root : root.appending(path: relative)
        return checked(url, file: file, line: line)
    }

    // MARK: Writes (all guarded)

    @discardableResult
    public func createDirectory(_ relative: String) throws -> URL {
        let url = self.url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a new file (fails if it exists; never follows a symlink at the final component).
    @discardableResult
    public func createFile(_ relative: String, contents: Data = Data("x".utf8)) throws -> URL {
        let url = self.url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Sandbox.posixError(errno, path) }
        defer { close(fd) }
        try contents.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw Sandbox.posixError(errno, path) }
                offset += n
            }
        }
        return url
    }

    /// Replaces the contents of an existing regular file inside the sandbox.
    public func overwrite(_ relative: String, contents: Data) throws {
        let url = self.url(relative)
        try contents.write(to: url, options: [])
    }

    /// Appends bytes to an existing file (e.g. "source changes while being copied").
    public func append(_ relative: String, contents: Data) throws {
        let url = self.url(relative)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: contents)
    }

    /// Logical size `size`, one byte written at the end (a hole before it where the volume supports it).
    @discardableResult
    public func createSparseFile(_ relative: String, size: Int64) throws -> URL {
        precondition(size > 0)
        let url = try createFile(relative, contents: Data())
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Sandbox.posixError(errno, path) }
        defer { close(fd) }
        var byte: UInt8 = 0x78
        guard ftruncate(fd, off_t(size)) == 0, pwrite(fd, &byte, 1, off_t(size - 1)) == 1 else {
            throw Sandbox.posixError(errno, path)
        }
        return url
    }

    /// `relative` becomes a symlink whose link text is `target` (relative or absolute; never written through).
    @discardableResult
    public func createSymlink(_ relative: String, target: String) throws -> URL {
        let url = self.url(relative)
        guard symlink(target, url.path(percentEncoded: false)) == 0 else { throw Sandbox.posixError(errno, url.path(percentEncoded: false)) }
        return url
    }

    @discardableResult
    public func createHardLink(_ relative: String, to existing: String) throws -> URL {
        let url = self.url(relative)
        let source = self.url(existing)
        guard link(source.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 else {
            throw Sandbox.posixError(errno, url.path(percentEncoded: false))
        }
        return url
    }

    /// A Finder alias (bookmark file) at `relative` pointing to `target`.
    @discardableResult
    public func createAlias(_ relative: String, to target: String) throws -> URL {
        let url = self.url(relative)
        let data = try self.url(target).bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(data, to: url)
        return url
    }

    /// lchflags; e.g. UInt32(UF_HIDDEN), UInt32(UF_IMMUTABLE). Replaces all flags.
    public func setFlags(_ relative: String, _ flags: UInt32) throws {
        let path = url(relative).path(percentEncoded: false)
        guard lchflags(path, flags) == 0 else { throw Sandbox.posixError(errno, path) }
    }

    public func setMode(_ relative: String, _ mode: mode_t) throws {
        let path = url(relative).path(percentEncoded: false)
        guard chmod(path, mode) == 0 else { throw Sandbox.posixError(errno, path) }
    }

    public func setXattr(_ relative: String, name: String, value: Data) throws {
        let path = url(relative).path(percentEncoded: false)
        let rc = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard rc == 0 else { throw Sandbox.posixError(errno, path) }
    }

    public func setHiddenExtension(_ relative: String, _ hidden: Bool = true) throws {
        var url = self.url(relative)
        var values = URLResourceValues()
        values.hasHiddenExtension = hidden
        try url.setResourceValues(values)
    }

    public func setDates(_ relative: String, modified: Date? = nil, created: Date? = nil) throws {
        var url = self.url(relative)
        var values = URLResourceValues()
        if let modified { values.contentModificationDate = modified }
        if let created { values.creationDate = created }
        try url.setResourceValues(values)
    }

    public func rename(_ from: String, to: String) throws {
        let a = url(from).path(percentEncoded: false), b = url(to).path(percentEncoded: false)
        guard Darwin.rename(a, b) == 0 else { throw Sandbox.posixError(errno, a) }
    }

    /// Removes an item (clearing locks/permissions below it first).
    public func remove(_ relative: String) throws {
        let url = self.url(relative)
        precondition(url.path(percentEncoded: false) != root.path(percentEncoded: false), "use destroy() to remove the root")
        Sandbox.unlockTree(url.path(percentEncoded: false))
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Mounts (DiskImage registers here so destroy() can detach first)

    func registerMount(_ mountPoint: String) { mounts.withLock { $0.append(mountPoint) } }
    func unregisterMount(_ mountPoint: String) { mounts.withLock { $0.removeAll { $0 == mountPoint } } }

    /// Detaches every image mounted inside the root, clears locks and permissions, deletes the root.
    /// Idempotent. Refuses (traps) if `root` is not a sandbox directory in the temporary directory.
    public func destroy() {
        let base = root.path(percentEncoded: false).trimmingSuffix("/")
        let name = (base as NSString).lastPathComponent
        guard let temp = try? Sandbox.resolvedTemporaryDirectory(),
              (base as NSString).deletingLastPathComponent == temp,
              Sandbox.allowedPrefixes.contains(where: { name.hasPrefix($0 + "-") }) else {
            preconditionFailure("Sandbox.destroy refused for \(base)")
        }
        var points = Set(mounts.withLock { $0 })
        points.formUnion(Sandbox.mountPoints(under: base))
        for point in points.sorted(by: { $0.count > $1.count }) {
            DiskImage.forceDetach(mountPoint: point)
        }
        mounts.withLock { $0.removeAll() }
        guard access(base, F_OK) == 0 else { return }
        Sandbox.unlockTree(base)
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: Helpers

    public static func resolvedTemporaryDirectory() throws -> String {
        let raw = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        guard let resolved = resolve(raw) else { throw posixError(ENOENT, raw) }
        return resolved.trimmingSuffix("/")
    }

    /// Kernel-equivalent resolution: walks components from "/", following symlinks (also dangling ones,
    /// textually) and applying ".." to the resolved prefix. Components that don't exist are appended as-is.
    static func resolve(_ path: String, depth: Int = 0) -> String? {
        guard depth < 40, path.hasPrefix("/") else { return nil }
        var current = ""
        var rest = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        while !rest.isEmpty {
            let component = rest.removeFirst()
            if component == "." { continue }
            if component == ".." {
                current = (current as NSString).deletingLastPathComponent
                if current == "/" { current = "" }
                continue
            }
            let next = current + "/" + component
            var st = stat()
            guard lstat(next, &st) == 0 else {
                // Doesn't exist: the remainder is created fresh, nothing to follow.
                current = next
                continue
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(next, &buffer, Int(PATH_MAX))
                guard n >= 0 else { return nil }
                let target = String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let joined = (target.hasPrefix("/") ? target : (current.isEmpty ? "" : current) + "/" + target)
                    + (rest.isEmpty ? "" : "/" + rest.joined(separator: "/"))
                return resolve(joined, depth: depth + 1)
            }
            current = next
        }
        return current.isEmpty ? "/" : current
    }

    static func unlockTree(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 { _ = lchflags(path, 0) }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            _ = chmod(path, 0o700)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                unlockTree(path + "/" + name)
            }
        }
    }

    static func mountPoints(under base: String) -> [String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var result: [String] = []
        for i in 0..<Int(count) {
            var entry = buffer[i]
            let point = withUnsafeBytes(of: &entry.f_mntonname) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if point.hasPrefix(base + "/") { result.append(point) }
        }
        return result
    }

    static func posixError(_ code: Int32, _ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}

public enum SandboxError: Error, Equatable, Sendable {
    case notASandboxDirectory(String)
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        guard count > 1, hasSuffix(suffix) else { return self }
        return String(dropLast(suffix.count))
    }
}
```

- [ ] **Step 5: Implement DiskImage**

Create `Sources/MacxFixtures/DiskImage.swift`. Notes verified on this machine: 16 MB works for all four formats (`MS-DOS` picks FAT16 at that size; `MS-DOS FAT32` needs ≥ ~33 MB and is not offered); exFAT and FAT mount through macOS 26's user-space FSKit modules and support no hard links; `-owners on` is passed for APFS/HFS+ so permission tests behave on images.

```swift
import Darwin
import Foundation
import Synchronization

public enum DiskImageFormat: String, Sendable, CaseIterable {
    case apfs = "APFS"
    case hfsPlus = "HFS+"
    case exfat = "ExFAT"
    case msdos = "MS-DOS"      // FAT16/FAT32 chosen by hdiutil from the size
}

public enum DiskImageError: Error, Sendable, Equatable {
    case hdiutilFailed(arguments: [String], status: Int32, output: String)
    case timedOut(arguments: [String])
}

/// A disk image created inside a Sandbox and attached with `-nobrowse` at `<sandbox>/mnt-<id>`.
/// Detach is idempotent; Sandbox.destroy() force-detaches anything still attached.
public final class DiskImage: Sendable {
    public let imageURL: URL
    public let mountPoint: URL
    /// Mount point relative to the sandbox root, for Sandbox write helpers ("mnt-1a2b3c4d").
    public let relativeMountPath: String
    public let format: DiskImageFormat
    public let isReadOnly: Bool
    private let sandbox: Sandbox
    private let attached = Mutex<Bool>(false)

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") }

    /// Creates `<sandbox>/img-<id>.dmg` (UDIF, GPT), attaches it read-write, runs `populate` with the mount
    /// point, and — if `readOnly` — detaches and re-attaches it with `-readonly`.
    public static func create(in sandbox: Sandbox, format: DiskImageFormat, sizeMB: Int = 32,
                              volumeName: String = "MACXTEST", readOnly: Bool = false,
                              populate: ((URL) throws -> Void)? = nil) throws -> DiskImage {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let image = sandbox.url("img-\(id).dmg")
        let mount = try sandbox.createDirectory("mnt-\(id)")
        try hdiutil(["create", "-size", "\(sizeMB)m", "-fs", format.rawValue, "-volname", volumeName,
                     "-type", "UDIF", "-layout", "GPTSPUD", image.path(percentEncoded: false)])
        let disk = DiskImage(sandbox: sandbox, image: image, mount: mount, relative: "mnt-\(id)",
                             format: format, readOnly: readOnly)
        try disk.attach(readOnly: false)
        if let populate { try populate(mount) }
        if readOnly {
            try disk.detach()
            try disk.attach(readOnly: true)
        }
        return disk
    }

    private init(sandbox: Sandbox, image: URL, mount: URL, relative: String, format: DiskImageFormat, readOnly: Bool) {
        self.sandbox = sandbox
        self.imageURL = image
        self.mountPoint = mount
        self.relativeMountPath = relative
        self.format = format
        self.isReadOnly = readOnly
    }

    private func attach(readOnly: Bool) throws {
        var args = ["attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path(percentEncoded: false)]
        if format == .apfs || format == .hfsPlus { args += ["-owners", "on"] }
        if readOnly { args.append("-readonly") }
        args.append(imageURL.path(percentEncoded: false))
        try DiskImage.hdiutil(args)
        attached.withLock { $0 = true }
        sandbox.registerMount(mountPoint.path(percentEncoded: false))
    }

    /// `hdiutil detach -force`. Idempotent.
    public func detach() throws {
        let wasAttached = attached.withLock { value -> Bool in
            defer { value = false }
            return value
        }
        guard wasAttached else { return }
        sandbox.unregisterMount(mountPoint.path(percentEncoded: false))
        try DiskImage.hdiutil(["detach", "-force", mountPoint.path(percentEncoded: false)])
    }

    static func forceDetach(mountPoint: String) {
        _ = try? hdiutil(["detach", "-force", mountPoint])
    }

    @discardableResult
    static func hdiutil(_ arguments: [String], timeout: Duration = .seconds(60)) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments + ["-quiet"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let seconds = Double(timeout.components.seconds)
        if done.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            throw DiskImageError.timedOut(arguments: arguments)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw DiskImageError.hdiutilFailed(arguments: arguments, status: process.terminationStatus, output: output)
        }
        return output
    }
}
```

- [ ] **Step 6: Implement FixtureTree and TrapProbe**

Create `Sources/MacxFixtures/FixtureTree.swift`. The golden tree covers every §9 kind that can be produced on a local APFS volume as a normal user. Two §9 kinds cannot be produced that way and are covered synthetically in P1-03/P1-06 instead: per-entry `ATTR_CMN_ERROR` records and dataless (`SF_DATALESS`) files.

```swift
import Darwin
import Foundation

/// Names of the §9 golden tree. Every name is a top-level item of the tree's root directory.
public enum GoldenName {
    public static let plain = "plain.txt"                         // 6 bytes "hello\n"
    public static let empty = "empty.bin"                         // 0 bytes
    public static let sparse = "sparse.bin"                       // 8 MiB logical, 1 byte written at the end
    public static let nfc = "R\u{E9}sum\u{E9}.txt"                // precomposed é
    public static let nfd = "Cafe\u{301}.txt"                     // e + combining acute (APFS preserves NFD)
    public static let emoji = "emoji \u{1F600}\u{1F389}.txt"
    public static let long255 = String(repeating: "n", count: 251) + ".txt"   // 255 UTF-8 bytes
    public static let long255Multibyte = String(repeating: "\u{65E5}", count: 85)  // 85 × 3 bytes = 255
    public static let dotHidden = ".dot-hidden"
    public static let flagHidden = "flag-hidden.txt"              // UF_HIDDEN
    public static let symlinkToFile = "link-to-plain"             // → plain.txt
    public static let symlinkToDir = "link-to-folder"             // → folder
    public static let brokenSymlink = "broken-link"               // → does-not-exist
    public static let alias = "alias-to-plain"                    // Finder alias (bookmark file)
    public static let app = "Tool.app"                            // package (application bundle)
    public static let rtfd = "Note.rtfd"                          // package (document bundle)
    public static let folder = "folder"                           // a.txt, b.txt, sub/
    public static let dottedFolder = "v1.2"                       // directory, not a package
    public static let locked = "locked.txt"                       // UF_IMMUTABLE
    public static let xattrs = "with-xattrs.txt"                  // com.macexplorer.test + com.apple.metadata:kMDItemWhereFroms
    public static let extensionHidden = "ext-hidden.txt"          // Finder kIsExtensionHidden
    public static let hardLinkA = "hardlink-a.txt"                // same inode as hardlink-b.txt
    public static let hardLinkB = "hardlink-b.txt"
    public static let noAccessDir = "no-access-dir"               // mode 000 (contains one file)
    public static let noAccessFile = "no-access.txt"              // mode 000
    public static let executable = "run.sh"                       // mode 755
    public static let readOnly = "read-only.txt"                  // mode 444
    public static let dated = "dated.txt"                         // created 2001-01-01, modified 2002-02-02 (UTC)

    public static let all: [String] = [
        plain, empty, sparse, nfc, nfd, emoji, long255, long255Multibyte, dotHidden, flagHidden,
        symlinkToFile, symlinkToDir, brokenSymlink, alias, app, rtfd, folder, dottedFolder, locked, xattrs,
        extensionHidden, hardLinkA, hardLinkB, noAccessDir, noAccessFile, executable, readOnly, dated,
    ]
}

public enum FixtureTree {
    /// Builds the §9 golden tree at `<sandbox>/<relative>` and returns its URL.
    @discardableResult
    public static func golden(in sandbox: Sandbox, at relative: String = "golden") throws -> URL {
        let root = try sandbox.createDirectory(relative)
        func p(_ name: String) -> String { relative + "/" + name }
        try sandbox.createFile(p(GoldenName.plain), contents: Data("hello\n".utf8))
        try sandbox.createFile(p(GoldenName.empty), contents: Data())
        try sandbox.createSparseFile(p(GoldenName.sparse), size: 8 << 20)
        try sandbox.createFile(p(GoldenName.nfc))
        try sandbox.createFile(p(GoldenName.nfd))
        try sandbox.createFile(p(GoldenName.emoji))
        try sandbox.createFile(p(GoldenName.long255))
        try sandbox.createFile(p(GoldenName.long255Multibyte))
        try sandbox.createFile(p(GoldenName.dotHidden))
        try sandbox.createFile(p(GoldenName.flagHidden))
        try sandbox.setFlags(p(GoldenName.flagHidden), UInt32(UF_HIDDEN))
        try sandbox.createSymlink(p(GoldenName.symlinkToFile), target: GoldenName.plain)
        try sandbox.createSymlink(p(GoldenName.symlinkToDir), target: GoldenName.folder)
        try sandbox.createSymlink(p(GoldenName.brokenSymlink), target: "does-not-exist")
        try sandbox.createFile(p(GoldenName.app + "/Contents/Info.plist"), contents: Data("<plist/>".utf8))
        try sandbox.createFile(p(GoldenName.app + "/Contents/MacOS/Tool"))
        try sandbox.createFile(p(GoldenName.rtfd + "/TXT.rtf"), contents: Data("{\\rtf1}".utf8))
        try sandbox.createFile(p(GoldenName.folder + "/a.txt"))
        try sandbox.createFile(p(GoldenName.folder + "/b.txt"))
        try sandbox.createDirectory(p(GoldenName.folder + "/sub"))
        try sandbox.createFile(p(GoldenName.dottedFolder + "/inside.txt"))
        try sandbox.createAlias(p(GoldenName.alias), to: p(GoldenName.plain))
        try sandbox.createFile(p(GoldenName.locked))
        try sandbox.setFlags(p(GoldenName.locked), UInt32(UF_IMMUTABLE))
        try sandbox.createFile(p(GoldenName.xattrs))
        try sandbox.setXattr(p(GoldenName.xattrs), name: "com.macexplorer.test", value: Data("value".utf8))
        try sandbox.setXattr(p(GoldenName.xattrs), name: "com.apple.metadata:kMDItemWhereFroms",
                             value: try PropertyListSerialization.data(fromPropertyList: ["https://example.com/f"], format: .binary, options: 0))
        try sandbox.createFile(p(GoldenName.extensionHidden))
        try sandbox.setHiddenExtension(p(GoldenName.extensionHidden))
        try sandbox.createFile(p(GoldenName.hardLinkA), contents: Data("linked".utf8))
        try sandbox.createHardLink(p(GoldenName.hardLinkB), to: p(GoldenName.hardLinkA))
        try sandbox.createFile(p(GoldenName.noAccessDir + "/secret.txt"))
        try sandbox.setMode(p(GoldenName.noAccessDir), 0)
        try sandbox.createFile(p(GoldenName.noAccessFile))
        try sandbox.setMode(p(GoldenName.noAccessFile), 0)
        try sandbox.createFile(p(GoldenName.executable), contents: Data("#!/bin/sh\n".utf8))
        try sandbox.setMode(p(GoldenName.executable), 0o755)
        try sandbox.createFile(p(GoldenName.readOnly))
        try sandbox.setMode(p(GoldenName.readOnly), 0o444)
        try sandbox.createFile(p(GoldenName.dated))
        try sandbox.setDates(p(GoldenName.dated), modified: Date(timeIntervalSince1970: 1_012_608_000),
                             created: Date(timeIntervalSince1970: 978_307_200))
        return root
    }

    /// `count` empty files named `<prefix><n zero-padded to width><ext>` (n from 1) in `<sandbox>/<relative>`.
    @discardableResult
    public static func flat(in sandbox: Sandbox, at relative: String, count: Int, prefix: String = "file-",
                            ext: String = ".txt", width: Int = 6, directoriesEvery: Int = 0) throws -> URL {
        precondition(!prefix.contains("/") && !ext.contains("/"), "flat: names must not contain '/'")
        let root = try sandbox.createDirectory(relative)
        let base = root.path(percentEncoded: false)
        guard count > 0 else { return root }
        for i in 1...count {
            let number = String(i)
            let name = prefix + String(repeating: "0", count: max(0, width - number.count)) + number
            if directoriesEvery > 0 && i % directoriesEvery == 0 {
                guard mkdir(base + "/" + name, 0o755) == 0 else { throw Sandbox.posixError(errno, name) }
            } else {
                let fd = open(base + "/" + name + ext, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
                guard fd >= 0 else { throw Sandbox.posixError(errno, name) }
                close(fd)
            }
        }
        return root
    }

    /// A tree `depth` levels deep; each directory has `breadth` subdirectories "d<n>" and `filesPerDir` files "f<n>.txt".
    @discardableResult
    public static func deep(in sandbox: Sandbox, at relative: String, depth: Int, breadth: Int, filesPerDir: Int) throws -> URL {
        let root = try sandbox.createDirectory(relative)
        func fill(_ rel: String, level: Int) throws {
            for f in 0..<filesPerDir { try sandbox.createFile("\(rel)/f\(f).txt") }
            guard level < depth else { return }
            for d in 0..<breadth {
                try sandbox.createDirectory("\(rel)/d\(d)")
                try fill("\(rel)/d\(d)", level: level + 1)
            }
        }
        try fill(relative, level: 1)
        return root
    }
}
```

Create `Sources/MacxFixtures/TrapProbe.swift`. The child installs a handler that turns `SIGTRAP`/`SIGILL`/`SIGABRT` into `_exit(86)`, so a proven trap writes no crash report.

```swift
import Darwin
import Foundation

/// Proves that a code path traps (preconditionFailure) by re-running one XCTest method of the current
/// test bundle in a child `xctest` process. The child sees `MACX_TRAP_PROBE=<name>`; when it traps, a
/// signal handler exits with `TrapProbe.trappedStatus` so no crash report is written.
public enum TrapProbe {
    public static let environmentKey = "MACX_TRAP_PROBE"
    public static let trappedStatus: Int32 = 86

    public struct Result: Sendable, Equatable {
        public var status: Int32
        public var trapped: Bool { status == TrapProbe.trappedStatus }
        public var output: String
    }

    /// Call first thing inside the probe test. Returns true in the child (and installs the trap handler).
    public static func isChild(_ name: String) -> Bool {
        guard ProcessInfo.processInfo.environment[environmentKey] == name else { return false }
        for sig in [SIGTRAP, SIGILL, SIGABRT] {
            signal(sig) { _ in _exit(TrapProbe.trappedStatus) }
        }
        return true
    }

    /// The value the parent passed for `key` (e.g. a sandbox root the child adopts).
    public static func value(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

    /// Runs `xcrun xctest -XCTest <testIdentifier> <bundle>` with the probe environment and waits (≤ 120 s).
    public static func run(name: String, testIdentifier: String, bundle: URL,
                           environment: [String: String] = [:]) throws -> Result {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", testIdentifier, bundle.path(percentEncoded: false)]
        var env = ProcessInfo.processInfo.environment
        env[environmentKey] = name
        env.merge(environment) { _, new in new }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter MacxFixturesTests 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 14 tests, with 2 tests skipped and 0 failures` (the 2 skips are the `SandboxTrapProbes` child halves; `testOutOfSandboxWritesTrap` runs them in a child process and passes). DiskImage tests take ~12 s.

Then confirm nothing leaked: `ls -d "$TMPDIR"/macx-tests-* 2>/dev/null | wc -l` → `0`, and `mount | grep -c macx-tests` → `0`.

- [ ] **Step 8: Add scripts/make-fixtures.sh**

Create `scripts/make-fixtures.sh` and `chmod +x scripts/make-fixtures.sh`. It is the shell twin of `FixtureTree.golden` for manual and benchmark use (the alias and the hidden-extension file need Foundation, so only the Swift builder creates those two).

```bash
#!/bin/bash
# Creates the §9 golden fixture tree in a fresh ${TMPDIR}/macx-fixtures-<UUID> directory and prints its path.
#   scripts/make-fixtures.sh                 golden tree only
#   scripts/make-fixtures.sh --flat 100000   golden tree + flat-100000/ with that many empty files
#   scripts/make-fixtures.sh --remove <dir>  deletes a directory this script created (and nothing else)
# Safety: never writes outside the directory it creates; --remove refuses any other path.
set -euo pipefail

TMP="${TMPDIR:-/tmp}"
TMP="$(cd "$TMP" && pwd -P)"
PREFIX="$TMP/macx-fixtures-"

refuse() { echo "make-fixtures: refusing: $1" >&2; exit 2; }

if [[ "${1:-}" == "--remove" ]]; then
    target="$(cd "${2:?usage: --remove <dir>}" && pwd -P)"
    [[ "$target" == "$PREFIX"* && "$target" != */*/../* ]] || refuse "$target is not a macx-fixtures directory in $TMP"
    chflags -R nouchg,nohidden "$target" 2>/dev/null || true
    chmod -R u+rwx "$target" 2>/dev/null || true
    rm -rf -- "$target"
    exit 0
fi

FLAT=0
if [[ "${1:-}" == "--flat" ]]; then FLAT="${2:?usage: --flat <count>}"; fi
[[ "$FLAT" =~ ^[0-9]+$ ]] || refuse "--flat needs a number"

ROOT="$PREFIX$(uuidgen)"
mkdir "$ROOT"
G="$ROOT/golden"
inside() { [[ "$1" == "$ROOT/"* ]] || refuse "$1 is outside $ROOT"; }
mkdir "$G"; cd "$G"; inside "$PWD/x"

printf 'hello\n' > plain.txt
: > empty.bin
dd if=/dev/zero of=sparse.bin bs=1 count=0 seek=$((8 * 1024 * 1024 - 1)) 2>/dev/null; printf 'x' >> sparse.bin
printf 'x' > "$(printf 'R\xc3\xa9sum\xc3\xa9.txt')"          # NFC
printf 'x' > "$(printf 'Cafe\xcc\x81.txt')"                 # NFD
printf 'x' > "$(printf 'emoji \xf0\x9f\x98\x80\xf0\x9f\x8e\x89.txt')"
printf 'x' > "$(printf 'n%.0s' $(seq 1 251)).txt"           # 255 bytes
printf 'x' > "$(for _ in $(seq 1 85); do printf '\xe6\x97\xa5'; done)"   # 85 × 3 bytes
printf 'x' > .dot-hidden
printf 'x' > flag-hidden.txt; chflags hidden flag-hidden.txt
ln -s plain.txt link-to-plain; ln -s folder link-to-folder; ln -s does-not-exist broken-link
mkdir -p Tool.app/Contents/MacOS; printf '<plist/>' > Tool.app/Contents/Info.plist; printf 'x' > Tool.app/Contents/MacOS/Tool
mkdir Note.rtfd; printf '{\\rtf1}' > Note.rtfd/TXT.rtf
mkdir -p folder/sub; printf 'x' > folder/a.txt; printf 'x' > folder/b.txt
mkdir v1.2; printf 'x' > v1.2/inside.txt
printf 'x' > locked.txt; chflags uchg locked.txt
printf 'x' > with-xattrs.txt; xattr -w com.macexplorer.test value with-xattrs.txt
printf 'linked' > hardlink-a.txt; ln hardlink-a.txt hardlink-b.txt
mkdir no-access-dir; printf 'x' > no-access-dir/secret.txt; chmod 000 no-access-dir
printf 'x' > no-access.txt; chmod 000 no-access.txt
printf '#!/bin/sh\n' > run.sh; chmod 755 run.sh
printf 'x' > read-only.txt; chmod 444 read-only.txt
printf 'x' > dated.txt; touch -t 200202020000 dated.txt
# Not created by the shell version (need Foundation): alias-to-plain, ext-hidden.txt. FixtureTree.golden makes them.

if (( FLAT > 0 )); then
    F="$ROOT/flat-$FLAT"; mkdir "$F"; cd "$F"; inside "$PWD/x"
    for ((i = 1; i <= FLAT; i += 1000)); do
        end=$(( i + 999 < FLAT ? i + 999 : FLAT ))
        touch $(seq -f 'file-%06g.txt' "$i" "$end")
    done
fi
echo "$ROOT"
```

Run:
```bash
R=$(scripts/make-fixtures.sh --flat 2500); echo "$R"; ls -A "$R/golden" | wc -l; ls "$R/flat-2500" | wc -l
scripts/make-fixtures.sh --remove /tmp; echo "rc=$?"
scripts/make-fixtures.sh --remove "$R"; ls -d "$R" 2>&1 | tail -1
```
Expected: a path `…/T/macx-fixtures-<UUID>`; `26`; `2500`; `make-fixtures: refusing: /private/tmp is not a macx-fixtures directory …` and `rc=2`; `ls: …: No such file or directory`.

- [ ] **Step 9: Build with zero warnings**

Run: `swift build 2>&1 | tail -5`
Expected: last line `Build complete! (…)`, no `warning:` lines above it.

- [ ] **Step 10: Commit**

```bash
git ls-files Sources/MacxFixtures Tests/MacxFixturesTests   # P1-01's stubs are the listed files not created in this task
git rm -q <each stub file listed above>
git add Sources/MacxFixtures Tests/MacxFixturesTests scripts/make-fixtures.sh
git commit -m "feat: guarded test sandbox, disk images and fixture trees (P1-02)"
```

---
## Task P1-03: CFSKit: bulk read, bounds-checked cursor, stat_at, materialization, volume capabilities

**Spec:** §4.2 DirectoryReader (attribute list, parser rules 1–4, fallback), §4.2 Materialization policy, §4.2 Volumes (`ATTR_VOL_CAPABILITIES`), §9 (fuzzing never crashes; per-entry `ATTR_CMN_ERROR`; output vs `lstat`).

**Files:**
- Create: `Sources/CFSKit/include/CFSKit.h` (overview §3.1 verbatim)
- Create: `Sources/CFSKit/cursor.c`
- Create: `Sources/CFSKit/bulk.c`
- Create: `Sources/CFSKit/iopolicy.c`
- Create: `Sources/CFSKit/volcaps.c`
- Test: `Tests/FSKitTests/Support/RecordBuilder.swift`
- Test: `Tests/FSKitTests/CursorFuzzTests.swift`
- Test: `Tests/FSKitTests/CFSKitTests.swift`
- Delete: P1-01's stubs in `Sources/CFSKit/` and `Tests/FSKitTests/` (this task adds the first real FSKitTests; keep `Tests/FSKitTests/Corpus/`)

**Interfaces:**
- Consumes: P1-02 `Sandbox`, `FixtureTree.golden`, `GoldenName`, `DiskImage`.
- Produces: overview §3.1 exactly:

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

Plus one internal (non-header) function shared by the C files: `int cfsk_parse_single(const void *buf, size_t used_len, cfsk_record *out);` (cursor.c, used by `cfsk_stat_at`).

**Field semantics decided here (see Contract notes 4):** `access_mask` is filled from `ATTR_CMN_USERACCESS` (R_OK|W_OK|X_OK for the calling user, as the contract comment says). The spec's `ATTR_CMN_ACCESSMASK` returns the file's *mode bits* (verified: `0x81a4` for a 0644 file), which nothing in `Entry` stores, so it is not requested.

- [ ] **Step 1: Add the synthetic record builder (test support)**

Real volumes don't produce per-entry errors or malformed records, so tests build records by hand in the kernel's packing order: length, `attribute_set_t`, error (if returned), then common attributes in bit order (NAME, OBJTYPE, CRTIME, MODTIME, FNDRINFO, FLAGS, USERACCESS, FILEID), dir (ENTRYCOUNT), file (ALLOCSIZE, DATALENGTH), extended common (LINKID), then the name bytes.

Create `Tests/FSKitTests/Support/RecordBuilder.swift`:

```swift
import Darwin
import Foundation

/// Builds getattrlistbulk-format records by hand (for per-entry errors, missing attributes and
/// malformed input that a real volume won't produce). Layout follows the kernel's packing order.
struct RecordBuilder {
    struct Spec {
        var name: String? = "file.txt"
        var error: UInt32? = nil
        var objType: UInt32? = 1                 // VREG
        var crtime: (Int, Int)? = (1_000, 5)
        var mtime: (Int, Int)? = (2_000, 7)
        var finderFlags: UInt16? = 0
        var flags: UInt32? = 0
        var userAccess: UInt32? = 6
        var fileID: UInt64? = 42
        var entryCount: UInt32? = nil            // directories only
        var allocSize: Int64? = 4_096
        var dataLength: Int64? = 10
        var linkID: UInt64? = 42
    }

    private(set) var bytes: [UInt8] = []
    private(set) var count: UInt32 = 0

    mutating func add(_ s: Spec) {
        var common: UInt32 = UInt32(bitPattern: Int32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS))
        var fixed: [UInt8] = []
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { fixed.append(contentsOf: $0) } }
        if let e = s.error { common |= UInt32(ATTR_CMN_ERROR); put(e) }
        let nameRefAt = fixed.count
        if s.name != nil { common |= UInt32(ATTR_CMN_NAME); put(Int32(0)); put(UInt32(0)) }
        if let t = s.objType { common |= UInt32(ATTR_CMN_OBJTYPE); put(t) }
        if let c = s.crtime { common |= UInt32(ATTR_CMN_CRTIME); put(timespec(tv_sec: c.0, tv_nsec: c.1)) }
        if let m = s.mtime { common |= UInt32(ATTR_CMN_MODTIME); put(timespec(tv_sec: m.0, tv_nsec: m.1)) }
        if let f = s.finderFlags {
            common |= UInt32(ATTR_CMN_FNDRINFO)
            var info = [UInt8](repeating: 0, count: 32)
            info[8] = UInt8(f >> 8); info[9] = UInt8(f & 0xFF)
            fixed.append(contentsOf: info)
        }
        if let f = s.flags { common |= UInt32(ATTR_CMN_FLAGS); put(f) }
        if let a = s.userAccess { common |= UInt32(ATTR_CMN_USERACCESS); put(a) }
        if let id = s.fileID { common |= UInt32(ATTR_CMN_FILEID); put(id) }
        var dir: UInt32 = 0, file: UInt32 = 0, fork: UInt32 = 0
        if let n = s.entryCount { dir |= UInt32(ATTR_DIR_ENTRYCOUNT); put(n) }
        if let a = s.allocSize { file |= UInt32(ATTR_FILE_ALLOCSIZE); put(a) }
        if let d = s.dataLength { file |= UInt32(ATTR_FILE_DATALENGTH); put(d) }
        if let l = s.linkID { fork |= UInt32(ATTR_CMNEXT_LINKID); put(l) }

        let header = 4 + 20
        var record: [UInt8] = []
        let nameBytes: [UInt8] = s.name.map { Array($0.utf8) + [0] } ?? []
        let total = (header + fixed.count + nameBytes.count + 3) & ~3
        withUnsafeBytes(of: UInt32(total)) { record.append(contentsOf: $0) }
        let set = attribute_set_t(commonattr: common, volattr: 0, dirattr: dir, fileattr: file, forkattr: fork)
        withUnsafeBytes(of: set) { record.append(contentsOf: $0) }
        if s.name != nil {
            let refOffset = header + nameRefAt
            let dataOffset = Int32(header + fixed.count - refOffset)
            fixed.replaceSubrange(nameRefAt..<nameRefAt + 4, with: withUnsafeBytes(of: dataOffset) { Array($0) })
            fixed.replaceSubrange(nameRefAt + 4..<nameRefAt + 8, with: withUnsafeBytes(of: UInt32(nameBytes.count)) { Array($0) })
        }
        record += fixed + nameBytes
        record += [UInt8](repeating: 0, count: total - record.count)
        bytes += record
        count += 1
    }

    /// Patches the attrreference of the record starting at `recordStart` (tests of bad name refs).
    mutating func patchNameRef(recordStart: Int, refOffsetInRecord: Int, dataOffset: Int32, length: UInt32) {
        let at = recordStart + refOffsetInRecord
        bytes.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: dataOffset) { Array($0) })
        bytes.replaceSubrange(at + 4..<at + 8, with: withUnsafeBytes(of: length) { Array($0) })
    }
}
```

- [ ] **Step 2: Write the failing parser fuzz tests**

Create `Tests/FSKitTests/CursorFuzzTests.swift`:

```swift
import CFSKit
import Darwin
import Foundation
import XCTest

final class CursorFuzzTests: XCTestCase {
    /// Parses every record from an exact-size heap copy (so ASan flags any overread); returns
    /// (ok, dropped, truncated). Never more than `count` + 1 calls.
    private func parseAll(_ bytes: [UInt8], count: UInt32) -> (ok: Int, dropped: Int, truncated: Bool) {
        let size = bytes.count
        let heap = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 1)
        defer { heap.deallocate() }
        bytes.withUnsafeBytes { if size > 0 { heap.copyMemory(from: $0.baseAddress!, byteCount: size) } }
        var cursor = cfsk_cursor()
        cfsk_cursor_init(&cursor, heap, size, count)
        var record = cfsk_record()
        var ok = 0, dropped = 0, calls = 0
        while true {
            calls += 1
            precondition(calls <= Int(count) + 1, "cursor did not terminate")
            switch cfsk_cursor_next(&cursor, &record) {
            case CFSK_NEXT_OK:
                ok += 1
                if record.fields & CFSK_HAS_NAME != 0 {
                    let base = UnsafeRawPointer(heap), start = UnsafeRawPointer(record.name!)
                    precondition(start >= base && start + Int(record.name_len) <= base + size, "name outside buffer")
                    _ = UnsafeRawBufferPointer(start: start, count: Int(record.name_len)).reduce(0, &+)   // touch every byte
                }
            case CFSK_NEXT_DROPPED: dropped += 1
            case CFSK_NEXT_TRUNCATED: return (ok, dropped, true)
            default: return (ok, dropped, false)
            }
        }
    }

    func testWellFormedRecordsParse() {
        var b = RecordBuilder()
        b.add(.init())
        b.add(.init(name: "dir", objType: 2, entryCount: 3, allocSize: nil, dataLength: nil))
        let r = parseAll(b.bytes, count: b.count)
        XCTAssertEqual(r.ok, 2); XCTAssertEqual(r.dropped, 0); XCTAssertFalse(r.truncated)
    }

    func testRandomBuffersNeverCrash() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100_000 {
            let n = Int.random(in: 0...512, using: &rng)
            var bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if n >= 4, Bool.random(using: &rng) {   // plausible length prefix makes the parser go deeper
                let len = UInt32.random(in: 24...UInt32(max(24, n)), using: &rng)
                withUnsafeBytes(of: len) { bytes.replaceSubrange(0..<4, with: $0) }
            }
            _ = parseAll(bytes, count: UInt32.random(in: 0...64, using: &rng))
        }
    }

    func testEveryTruncationOfValidBufferIsSafe() {
        var b = RecordBuilder()
        for i in 0..<20 { b.add(.init(name: "name-\(i)-" + String(repeating: "é", count: i))) }
        for cut in 0...b.bytes.count {
            let r = parseAll(Array(b.bytes.prefix(cut)), count: b.count)
            XCTAssertLessThanOrEqual(r.ok, 20)
        }
    }

    func testByteFlipsOfValidBufferAreSafe() {
        var b = RecordBuilder()
        for i in 0..<8 { b.add(.init(name: "f\(i).txt")) }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100_000 {
            var bytes = b.bytes
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = parseAll(bytes, count: b.count)
        }
    }

    func testNameReferenceOutsideRecordIsDropped() {
        var b = RecordBuilder()
        b.add(.init(name: "a.txt"))
        b.add(.init(name: "b.txt"))
        // name ref of record 0 sits right after length + attribute_set_t (no error field)
        b.patchNameRef(recordStart: 0, refOffsetInRecord: 24, dataOffset: 10_000, length: 6)
        let r = parseAll(b.bytes, count: b.count)
        XCTAssertEqual(r.ok, 1, "the bad record is dropped, the next one still parses")
        XCTAssertEqual(r.dropped, 1)
    }

    func testLengthLargerThanBufferStopsWithTruncated() {
        var b = RecordBuilder()
        b.add(.init())
        var bytes = b.bytes
        withUnsafeBytes(of: UInt32(bytes.count + 100)) { bytes.replaceSubrange(0..<4, with: $0) }
        let r = parseAll(bytes, count: 1)
        XCTAssertEqual(r.ok, 0); XCTAssertTrue(r.truncated)
    }

    func testPerEntryErrorKeepsValidFields() {
        var b = RecordBuilder()
        b.add(.init(name: "broken", error: UInt32(EACCES), objType: 1, crtime: nil, mtime: nil, finderFlags: nil,
                    flags: nil, userAccess: nil, fileID: 77, allocSize: nil, dataLength: nil, linkID: nil))
        b.bytes.withUnsafeBytes { raw in
            var c = cfsk_cursor(); var r = cfsk_record()
            cfsk_cursor_init(&c, raw.baseAddress, raw.count, b.count)
            XCTAssertEqual(cfsk_cursor_next(&c, &r), CFSK_NEXT_OK)
            XCTAssertEqual(r.error, UInt32(EACCES))
            XCTAssertEqual(r.fields, CFSK_HAS_ERROR | CFSK_HAS_NAME | CFSK_HAS_OBJTYPE | CFSK_HAS_FILEID)
            XCTAssertEqual(r.file_id, 77)
            XCTAssertEqual(String(decoding: UnsafeRawBufferPointer(start: r.name, count: Int(r.name_len)), as: UTF8.self), "broken")
        }
    }
}
```

- [ ] **Step 3: Write the failing real-volume tests**

Create `Tests/FSKitTests/CFSKitTests.swift` (compares the C layer with `lstat(2)` on the golden tree; checks `getattrlistat` parity, the I/O policy and volume capabilities on APFS and an exFAT image):

```swift
import CFSKit
import Darwin
import Foundation
import MacxFixtures
import XCTest

final class CFSKitTests: XCTestCase {
    private var sandbox: Sandbox!
    private var golden: URL!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        golden = try FixtureTree.golden(in: sandbox)
    }

    private func bulkRecords(_ dir: URL) throws -> [String: cfsk_record] {
        let fd = open(dir.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        defer { close(fd) }
        let size = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var result: [String: cfsk_record] = [:]
        while true {
            let n = cfsk_bulk_read(fd, buffer, size)
            XCTAssertGreaterThanOrEqual(n, 0, "errno \(errno)")
            if n <= 0 { break }
            var cursor = cfsk_cursor()
            cfsk_cursor_init(&cursor, buffer, size, UInt32(n))
            var record = cfsk_record()
            while true {
                let rc = cfsk_cursor_next(&cursor, &record)
                if rc == CFSK_NEXT_END || rc == CFSK_NEXT_TRUNCATED { XCTAssertEqual(rc, CFSK_NEXT_END); break }
                XCTAssertEqual(rc, CFSK_NEXT_OK)
                let name = String(decoding: UnsafeRawBufferPointer(start: record.name, count: Int(record.name_len)), as: UTF8.self)
                record.name = nil   // pointer dies with the buffer
                result[name] = record
            }
        }
        return result
    }

    func testBulkReadReturnsEveryEntryWithLstatFields() throws {
        let records = try bulkRecords(golden)
        XCTAssertEqual(Set(records.keys), Set(GoldenName.all))
        for (name, r) in records {
            var st = stat()
            XCTAssertEqual(lstat(golden.appending(path: name).path(percentEncoded: false), &st), 0, name)
            XCTAssertEqual(r.error, 0, name)
            XCTAssertEqual(r.file_id, UInt64(st.st_ino), name)
            XCTAssertEqual(r.bsd_flags, st.st_flags, name)
            XCTAssertEqual(r.mtime_ns, Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), name)
            XCTAssertEqual(r.crtime_ns, Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec), name)
            if (st.st_mode & S_IFMT) == S_IFDIR {
                XCTAssertEqual(r.obj_type, 2, name)       // VDIR
                XCTAssertNotEqual(r.fields & CFSK_HAS_ENTRYCOUNT, 0, name)
                XCTAssertEqual(r.fields & CFSK_HAS_DATALENGTH, 0, name)
            } else {
                XCTAssertEqual(r.data_length, Int64(st.st_size), name)
                XCTAssertEqual(r.alloc_size, Int64(st.st_blocks) * 512, name)
                XCTAssertEqual(r.fields & CFSK_HAS_ENTRYCOUNT, 0, name)
            }
            XCTAssertEqual(r.obj_type == 5, (st.st_mode & S_IFMT) == S_IFLNK, name)   // VLNK
        }
        XCTAssertEqual(records[GoldenName.folder]?.entry_count, 3)
        XCTAssertEqual(records[GoldenName.locked]?.access_mask, UInt32(R_OK), "uchg: read only")
        XCTAssertEqual(records[GoldenName.noAccessFile]?.access_mask, 0)
        XCTAssertEqual(records[GoldenName.executable].map { $0.access_mask & UInt32(X_OK) }, UInt32(X_OK))
        XCTAssertEqual(records[GoldenName.alias].map { $0.finder_flags & 0x8000 }, 0x8000, "kIsAlias")
        XCTAssertEqual(records[GoldenName.alias]?.finder_type, 0x616c_6973, "'alis'")
        XCTAssertEqual(records[GoldenName.extensionHidden].map { $0.finder_flags & 0x0010 }, 0x0010, "kIsExtensionHidden")
        let a = try XCTUnwrap(records[GoldenName.hardLinkA]), b = try XCTUnwrap(records[GoldenName.hardLinkB])
        XCTAssertEqual(a.file_id, b.file_id)
        XCTAssertNotEqual(a.link_id, b.link_id, "ATTR_CMNEXT_LINKID distinguishes hard links")
        XCTAssertEqual(records[GoldenName.plain]?.link_id, records[GoldenName.plain]?.file_id)
    }

    func testStatAtMatchesBulkExceptAbsentFinderInfo() throws {
        let records = try bulkRecords(golden)
        let fd = open(golden.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 2048)
        for (name, bulk) in records {
            var single = cfsk_record()
            let rc = buffer.withUnsafeMutableBytes { cfsk_stat_at(fd, name, $0.baseAddress, $0.count, &single) }
            XCTAssertEqual(rc, 0, "\(name) errno \(errno)")
            // getattrlist omits all-zero Finder info that getattrlistbulk returns as zeros.
            XCTAssertEqual(single.fields | CFSK_HAS_FNDRINFO, bulk.fields | CFSK_HAS_FNDRINFO, name)
            XCTAssertEqual(single.finder_flags, bulk.finder_flags, name)
            XCTAssertEqual(single.file_id, bulk.file_id, name)
            XCTAssertEqual(single.link_id, bulk.link_id, name)
            XCTAssertEqual(single.data_length, bulk.data_length, name)
            XCTAssertEqual(single.alloc_size, bulk.alloc_size, name)
            XCTAssertEqual(single.entry_count, bulk.entry_count, name)
            XCTAssertEqual(single.mtime_ns, bulk.mtime_ns, name)
            XCTAssertEqual(single.access_mask, bulk.access_mask, name)
        }
        var single = cfsk_record()
        let rc = buffer.withUnsafeMutableBytes { cfsk_stat_at(fd, "nope", $0.baseAddress, $0.count, &single) }
        XCTAssertEqual(rc, -1); XCTAssertEqual(errno, ENOENT)
    }

    func testBulkReadOnUnreadableDirectoryFailsAtOpen() {
        let fd = open(golden.appending(path: GoldenName.noAccessDir).path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
        XCTAssertEqual(fd, -1); XCTAssertEqual(errno, EACCES)
    }

    func testMaterializationPolicyIsThreadScopedAndRestored() {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, scope = IOPOL_SCOPE_THREAD
        let before = getiopolicy_np(type, scope)
        var previous: Int32 = -1
        XCTAssertEqual(cfsk_materialize_off(&previous), 0)
        XCTAssertEqual(previous, before)
        XCTAssertEqual(getiopolicy_np(type, scope), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertEqual(cfsk_materialize_restore(previous), 0)
        XCTAssertEqual(getiopolicy_np(type, scope), before)
    }

    func testVolumeCapabilitiesOfTempVolume() {
        var caps = cfsk_volcaps()
        XCTAssertEqual(cfsk_volume_caps(sandbox.root.path(percentEncoded: false), &caps), 0)
        XCTAssertEqual(caps.persistent_ids, 1, "APFS has persistent object IDs")
        XCTAssertEqual(caps.rename_excl, 1)
        XCTAssertEqual(caps.clone, 1)
        XCTAssertEqual(cfsk_volume_caps("/nonexistent-\(UUID().uuidString)", &caps), -1)
    }

    func testVolumeCapabilitiesOfExFATImage() throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let image = try DiskImage.create(in: sandbox, format: .exfat, sizeMB: 16)
        defer { try? image.detach() }
        var caps = cfsk_volcaps()
        XCTAssertEqual(cfsk_volume_caps(image.mountPoint.path(percentEncoded: false), &caps), 0)
        XCTAssertEqual(caps.persistent_ids, 0)
        XCTAssertEqual(caps.clone, 0)
        XCTAssertEqual(caps.case_sensitive, 0)
    }
}
```

- [ ] **Step 4: Run to verify failure**

Run: `swift test --filter "FSKitTests.(CursorFuzzTests|CFSKitTests)" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'cfsk_cursor_init' in scope` (or a missing-header error for CFSKit.h).

- [ ] **Step 5: Write the header**

Create `Sources/CFSKit/include/CFSKit.h` with exactly the overview §3.1 block (shown under Interfaces above). The `static const` constants import into Swift as `let`s and trigger no `-Wunused-const-variable` under `-Wall -Wextra -Werror` (verified).

- [ ] **Step 6: Implement the cursor**

Create `Sources/CFSKit/cursor.c`. Rules (§4.2): each record is walked by its own length (`len < 24` or `len > remaining bytes` → `CFSK_NEXT_TRUNCATED`, stop); fields are read with `memcpy` (records are only 4-byte aligned) only if present in the returned set, in kernel order; the error field comes right after the attribute set; the name `attrreference_t` offset is relative to the reference itself and must stay inside the record, else the record is `CFSK_NEXT_DROPPED`; Finder info is big-endian on disk (verified: alias `finder_type == 'alis'`, `finder_flags & 0x8000`).

```c
#include "CFSKit.h"
#include <string.h>
#include <sys/attr.h>
#include <sys/vnode.h>

/* Fixed sizes of the attributes we request, in kernel packing order. */
#define CFSK_SET_SIZE   ((size_t)sizeof(attribute_set_t))   /* 20 */
#define CFSK_REF_SIZE   ((size_t)sizeof(attrreference_t))   /* 8 */
#define CFSK_TS_SIZE    ((size_t)sizeof(struct timespec))   /* 16 on LP64 */
#define CFSK_FINFO_SIZE ((size_t)32)

typedef struct cfsk_reader {
    const uint8_t *p;     /* next field */
    const uint8_t *end;   /* end of this record */
    int ok;               /* 0 once a field ran past `end` */
} cfsk_reader;

static int take(cfsk_reader *r, void *dst, size_t n) {
    if (!r->ok || (size_t)(r->end - r->p) < n) { r->ok = 0; return 0; }
    memcpy(dst, r->p, n);
    r->p += n;
    return 1;
}

static int64_t ts_to_ns(const struct timespec *ts) {
    const int64_t limit = INT64_MAX / 1000000000LL - 1;
    int64_t sec = (int64_t)ts->tv_sec;
    if (sec > limit) return INT64_MAX;
    if (sec < -limit) return INT64_MIN;
    return sec * 1000000000LL + (int64_t)ts->tv_nsec;
}

static uint16_t be16(const uint8_t *b) { return (uint16_t)(((uint16_t)b[0] << 8) | b[1]); }
static uint32_t be32(const uint8_t *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

void cfsk_cursor_init(cfsk_cursor *c, const void *buf, size_t used_len, uint32_t count) {
    c->next = (const uint8_t *)buf;
    c->end = (const uint8_t *)buf + (buf ? used_len : 0);
    c->remaining = buf ? count : 0;
}

/* Parses one record whose bytes are [start, start+len). Returns CFSK_NEXT_OK or CFSK_NEXT_DROPPED. */
static int parse_record(const uint8_t *start, uint32_t len, int has_error_field, cfsk_record *out) {
    memset(out, 0, sizeof *out);
    cfsk_reader r = { start + sizeof(uint32_t), start + len, 1 };
    attribute_set_t set;
    if (!take(&r, &set, CFSK_SET_SIZE)) return CFSK_NEXT_DROPPED;

    if (has_error_field && (set.commonattr & ATTR_CMN_ERROR)) {
        if (!take(&r, &out->error, sizeof(uint32_t))) return CFSK_NEXT_DROPPED;
        out->fields |= CFSK_HAS_ERROR;
    }
    if (set.commonattr & ATTR_CMN_NAME) {
        const uint8_t *ref_at = r.p;
        attrreference_t ref;
        if (!take(&r, &ref, CFSK_REF_SIZE)) return CFSK_NEXT_DROPPED;
        /* offset is relative to the attrreference itself; must stay inside this record */
        int64_t off = (int64_t)ref.attr_dataoffset;
        int64_t rel = (int64_t)(ref_at - start) + off;
        if (off < 0 || ref.attr_length == 0 || rel < 0 || rel > (int64_t)len ||
            (int64_t)ref.attr_length > (int64_t)len - rel) return CFSK_NEXT_DROPPED;
        const char *name = (const char *)(start + rel);
        uint32_t n = ref.attr_length;
        if (name[n - 1] == '\0') n -= 1;          /* kernel includes the NUL in attr_length */
        if (n == 0 || memchr(name, '\0', n) != NULL) return CFSK_NEXT_DROPPED;
        out->name = name;
        out->name_len = n;
        out->fields |= CFSK_HAS_NAME;
    }
    if (set.commonattr & ATTR_CMN_OBJTYPE) {
        fsobj_type_t t;
        if (!take(&r, &t, sizeof t)) return CFSK_NEXT_DROPPED;
        out->obj_type = (uint32_t)t;
        out->fields |= CFSK_HAS_OBJTYPE;
    }
    if (set.commonattr & ATTR_CMN_CRTIME) {
        struct timespec ts;
        if (!take(&r, &ts, CFSK_TS_SIZE)) return CFSK_NEXT_DROPPED;
        out->crtime_ns = ts_to_ns(&ts);
        out->fields |= CFSK_HAS_CRTIME;
    }
    if (set.commonattr & ATTR_CMN_MODTIME) {
        struct timespec ts;
        if (!take(&r, &ts, CFSK_TS_SIZE)) return CFSK_NEXT_DROPPED;
        out->mtime_ns = ts_to_ns(&ts);
        out->fields |= CFSK_HAS_MODTIME;
    }
    if (set.commonattr & ATTR_CMN_FNDRINFO) {
        uint8_t fi[CFSK_FINFO_SIZE];
        if (!take(&r, fi, sizeof fi)) return CFSK_NEXT_DROPPED;
        /* FileInfo: fdType[0..4], fdCreator[4..8], fdFlags[8..10]; FolderInfo: frRect[0..8], frFlags[8..10].
           Finder info is stored big-endian. */
        out->finder_flags = be16(fi + 8);
        out->finder_type = be32(fi);
        out->fields |= CFSK_HAS_FNDRINFO;
    }
    if (set.commonattr & ATTR_CMN_FLAGS) {
        uint32_t f;
        if (!take(&r, &f, sizeof f)) return CFSK_NEXT_DROPPED;
        out->bsd_flags = f;
        out->fields |= CFSK_HAS_FLAGS;
    }
    if (set.commonattr & ATTR_CMN_USERACCESS) {
        uint32_t m;
        if (!take(&r, &m, sizeof m)) return CFSK_NEXT_DROPPED;
        out->access_mask = m;
        out->fields |= CFSK_HAS_ACCESSMASK;
    }
    if (set.commonattr & ATTR_CMN_FILEID) {
        uint64_t id;
        if (!take(&r, &id, sizeof id)) return CFSK_NEXT_DROPPED;
        out->file_id = id;
        out->fields |= CFSK_HAS_FILEID;
    }
    if (set.dirattr & ATTR_DIR_ENTRYCOUNT) {
        uint32_t n;
        if (!take(&r, &n, sizeof n)) return CFSK_NEXT_DROPPED;
        out->entry_count = n;
        out->fields |= CFSK_HAS_ENTRYCOUNT;
    }
    if (set.fileattr & ATTR_FILE_ALLOCSIZE) {
        off_t v;
        if (!take(&r, &v, sizeof v)) return CFSK_NEXT_DROPPED;
        out->alloc_size = (int64_t)v;
        out->fields |= CFSK_HAS_ALLOCSIZE;
    }
    if (set.fileattr & ATTR_FILE_DATALENGTH) {
        off_t v;
        if (!take(&r, &v, sizeof v)) return CFSK_NEXT_DROPPED;
        out->data_length = (int64_t)v;
        out->fields |= CFSK_HAS_DATALENGTH;
    }
    if (set.forkattr & ATTR_CMNEXT_LINKID) {
        uint64_t id;
        if (!take(&r, &id, sizeof id)) return CFSK_NEXT_DROPPED;
        out->link_id = id;
        out->fields |= CFSK_HAS_LINKID;
    }
    return CFSK_NEXT_OK;
}

int cfsk_cursor_next(cfsk_cursor *c, cfsk_record *out) {
    for (;;) {
        if (c->remaining == 0 || c->next >= c->end) return CFSK_NEXT_END;
        size_t avail = (size_t)(c->end - c->next);
        uint32_t len;
        if (avail < sizeof len) { c->remaining = 0; return CFSK_NEXT_TRUNCATED; }
        memcpy(&len, c->next, sizeof len);
        if (len < sizeof(uint32_t) + CFSK_SET_SIZE || len > avail) { c->remaining = 0; return CFSK_NEXT_TRUNCATED; }
        const uint8_t *start = c->next;
        c->next += len;
        c->remaining -= 1;
        int rc = parse_record(start, len, 1, out);
        if (rc == CFSK_NEXT_OK) return rc;
        return CFSK_NEXT_DROPPED;
    }
}

/* Used by cfsk_stat_at (bulk.c): a getattrlist buffer is one record without ATTR_CMN_ERROR. */
int cfsk_parse_single(const void *buf, size_t used_len, cfsk_record *out) {
    uint32_t len;
    if (used_len < sizeof len) return CFSK_NEXT_TRUNCATED;
    memcpy(&len, buf, sizeof len);
    if (len < sizeof(uint32_t) + CFSK_SET_SIZE || len > used_len) return CFSK_NEXT_TRUNCATED;
    return parse_record((const uint8_t *)buf, len, 0, out);
}
```

- [ ] **Step 7: Implement bulk read, stat_at, I/O policy and capabilities**

Create `Sources/CFSKit/bulk.c`:

```c
#include "CFSKit.h"
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/attr.h>

int cfsk_parse_single(const void *buf, size_t used_len, cfsk_record *out);  /* cursor.c */

static void fill_attrlist(struct attrlist *al, int bulk) {
    memset(al, 0, sizeof *al);
    al->bitmapcount = ATTR_BIT_MAP_COUNT;
    al->commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID |
                     ATTR_CMN_MODTIME | ATTR_CMN_CRTIME | ATTR_CMN_FLAGS | ATTR_CMN_USERACCESS | ATTR_CMN_FNDRINFO;
    if (bulk) al->commonattr |= ATTR_CMN_ERROR;
    al->fileattr = ATTR_FILE_DATALENGTH | ATTR_FILE_ALLOCSIZE;
    al->dirattr = ATTR_DIR_ENTRYCOUNT;
    al->forkattr = ATTR_CMNEXT_LINKID;
}

int cfsk_bulk_read(int dirfd, void *buf, size_t buflen) {
    struct attrlist al;
    fill_attrlist(&al, 1);
    return getattrlistbulk(dirfd, &al, buf, buflen, FSOPT_ATTR_CMN_EXTENDED);
}

int cfsk_stat_at(int dirfd, const char *name, void *buf, size_t buflen, cfsk_record *out) {
    struct attrlist al;
    fill_attrlist(&al, 0);
    if (getattrlistat(dirfd, name, &al, buf, buflen, FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED) != 0) return -1;
    int rc = cfsk_parse_single(buf, buflen, out);
    if (rc != CFSK_NEXT_OK) { errno = EIO; return -1; }
    return 0;
}
```

Create `Sources/CFSKit/iopolicy.c` (thread scope; the default value read back is `IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT` = 0 and restoring it works):

```c
#include "CFSKit.h"
#include <sys/resource.h>

int cfsk_materialize_off(int *previous) {
    int prev = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    if (prev < 0) return -1;
    if (setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF) != 0) return -1;
    *previous = prev;
    return 0;
}

int cfsk_materialize_restore(int previous) {
    return setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous);
}
```

Create `Sources/CFSKit/volcaps.c`:

```c
#include "CFSKit.h"
#include <string.h>
#include <sys/attr.h>
#include <unistd.h>

struct cfsk_capsbuf {
    uint32_t length;
    vol_capabilities_attr_t caps;
} __attribute__((aligned(4), packed));

static uint8_t has(const vol_capabilities_attr_t *c, int idx, uint32_t bit) {
    return (c->valid[idx] & bit) && (c->capabilities[idx] & bit) ? 1 : 0;
}

int cfsk_volume_caps(const char *mount_path, cfsk_volcaps *out) {
    struct attrlist al;
    memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES;
    struct cfsk_capsbuf buf;
    memset(&buf, 0, sizeof buf);
    if (getattrlist(mount_path, &al, &buf, sizeof buf, 0) != 0) return -1;
    out->persistent_ids = has(&buf.caps, VOL_CAPABILITIES_FORMAT, VOL_CAP_FMT_PERSISTENTOBJECTIDS);
    out->case_sensitive = has(&buf.caps, VOL_CAPABILITIES_FORMAT, VOL_CAP_FMT_CASE_SENSITIVE);
    out->rename_excl = has(&buf.caps, VOL_CAPABILITIES_INTERFACES, VOL_CAP_INT_RENAME_EXCL);
    out->clone = has(&buf.caps, VOL_CAPABILITIES_INTERFACES, VOL_CAP_INT_CLONE);
    return 0;
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter "FSKitTests.(CursorFuzzTests|CFSKitTests)" 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 13 tests, with 0 failures` (fuzz tests ~6 s, exFAT image ~2 s).

- [ ] **Step 9: Run the fuzz tests under AddressSanitizer**

Run: `swift test --sanitize=address --filter FSKitTests.CursorFuzzTests 2>&1 | grep -E "Executed 7|AddressSanitizer" | tail -2`
Expected: `Executed 7 tests, with 0 failures`, no `AddressSanitizer` report (~25 s). The fuzz helper copies every buffer into an exact-size heap allocation, so a one-byte overread is caught.

- [ ] **Step 10: Build with zero warnings**

Run: `swift build 2>&1 | tail -5`
Expected: last line `Build complete! (…)`, no `warning:` lines above it.

- [ ] **Step 11: Commit**

```bash
git ls-files Sources/CFSKit Tests/FSKitTests     # P1-01's stubs are the listed files not created in this task
git rm -q <each stub file listed above>           # e.g. Sources/CFSKit/stub.c; keep Corpus/sort-allowed-divergences.json
git add Sources/CFSKit Tests/FSKitTests/Support/RecordBuilder.swift Tests/FSKitTests/CursorFuzzTests.swift Tests/FSKitTests/CFSKitTests.swift
git commit -m "feat: CFSKit getattrlistbulk parser, stat_at, iopolicy, volume caps (P1-03)"
```

---
## Task P1-04: Lanes: IOLane, LanePool + watchdog, Generation, withNoMaterialization, assertOffMain, Observers, PerfSignposts

**Spec:** §4.2 I/O threading (dedicated threads, 2 read lanes + 2 FileOps lanes per volume, 2 s watchdog, poisoned lanes never reused or joined, cap of 4 → unresponsive, TCC prompt → waiting, never poisoned, generation IDs), §4.2 Materialization policy, §4.4 main-thread rule (`assertOffMain`), §9 lane tests, §9 UI `OSSignposter` intervals.

**Files:**
- Create: `Sources/FSKit/Support/Observers.swift`
- Create: `Sources/FSKit/Support/MainThread.swift`
- Create: `Sources/FSKit/Support/PerfSignposts.swift`
- Create: `Sources/FSKit/Lanes/Generation.swift`
- Create: `Sources/FSKit/Lanes/Materialization.swift`
- Create: `Sources/FSKit/Lanes/LaneContext.swift`
- Create: `Sources/FSKit/Lanes/IOLane.swift`
- Create: `Sources/FSKit/Lanes/Watchdog.swift`
- Create: `Sources/FSKit/Lanes/LanePool.swift`
- Create: `Sources/FSKit/Volumes/VolumeInfo.swift` (only `VolumeID` in this task; P1-08 completes the file — Contract notes 2)
- Test: `Tests/FSKitTests/Support/TestHelpers.swift`
- Test: `Tests/FSKitTests/LaneTests.swift`
- Delete: P1-01's stub in `Sources/FSKit/`

**Interfaces:**
- Consumes: P1-03 `cfsk_materialize_off/restore`; P1-02 `TrapProbe` (assertOffMain trap test).
- Produces: overview §3.2 exactly, plus `VolumeID` from §3.6 (moved earlier because `LanePool` keys lanes by volume):

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

```swift
public struct VolumeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String                       // "uuid:<volumeUUIDString>" or "mnt:<mount path>"
    public init(raw: String) { self.raw = raw }
    public static let unknown = VolumeID(raw: "unknown")
    public var description: String { raw }
}
```

One attribute addition with no signature change: `perform` is `@discardableResult` (Void-returning calls otherwise warn → error).

Internal (tests use `@testable import MacxFS`): `LaneJob` (per-job atomics: `lastBeat`, `cancelled`, `stalled`, `everStalled`, `laneID`), `IOLane.Item`, `ResumeOnce`, `HealthHub`. `healthChanges` returns a fresh stream per access (multiple consumers allowed).

- [ ] **Step 1: Add test helpers**

Create `Tests/FSKitTests/Support/TestHelpers.swift`:

```swift
import Foundation
import Synchronization

/// Thread-safe recorder for values produced on lane threads.
final class Recorder<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    func append(_ value: T) { items.withLock { $0.append(value) } }
    var values: [T] { items.withLock { $0 } }
}

/// A gate a lane job blocks on (no heartbeats) to simulate a hung syscall. Always open it in teardown.
final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open(count: Int = 1) { for _ in 0..<count { semaphore.signal() } }
}

/// Polls `condition` every 10 ms until true or `timeout`.
func eventually(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
```

- [ ] **Step 2: Write the failing lane tests**

Create `Tests/FSKitTests/LaneTests.swift`. Shared constants live at file scope: in Swift 6, `Task { … }` closures in a test method may not capture the non-Sendable `XCTestCase` `self`.

```swift
import CFSKit
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import XCTest

private let fast = WatchdogConfig(stallTimeout: .milliseconds(200), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 4)
private let volume = VolumeID(raw: "mnt:/test")

final class LaneTests: XCTestCase {
    private var gates: [Gate] = []

    override func tearDown() {
        for gate in gates { gate.open(count: 8) }   // never leave a lane thread blocked
        gates.removeAll()
        super.tearDown()
    }

    private func gate() -> Gate { let g = Gate(); gates.append(g); return g }

    func testWorkRunsOnNamedLaneThreadOffMain() async throws {
        let pool = LanePool(config: fast)
        let (isMain, name) = try await pool.perform(on: volume) { _ in
            assertOffMain()
            return (Thread.isMainThread, Thread.current.name ?? "")
        }
        XCTAssertFalse(isMain)
        XCTAssertTrue(name.hasPrefix("macx.lane.read.mnt:/test."), name)
    }

    func testErrorsPropagate() async {
        struct Boom: Error {}
        let pool = LanePool(config: fast)
        do {
            _ = try await pool.perform(on: volume) { _ -> Int in throw Boom() }
            XCTFail("expected throw")
        } catch { XCTAssertTrue(error is Boom) }
    }

    func testAtMostLanesPerClassAndClassesAreSeparate() async throws {
        let pool = LanePool(config: fast)
        let lanesSeen = Recorder<UInt64>()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    try await pool.perform(on: volume, i.isMultiple(of: 3) ? .fileOp : .read) { ctx in
                        lanesSeen.append(ctx.laneID.raw)
                        usleep(20_000)
                        ctx.heartbeat()
                    }
                }
            }
            try await group.waitForAll()
        }
        let readCount = await pool.liveLaneCount(of: volume, .read)
        let opCount = await pool.liveLaneCount(of: volume, .fileOp)
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(opCount, 2)
        XCTAssertEqual(Set(lanesSeen.values).count, 4)
    }

    func testHungReadPoisonsLaneAndRetryGetsFreshLane() async throws {
        let pool = LanePool(config: fast)
        let hung = gate()
        let notices = Recorder<StallNotice>()
        let hungLane = Recorder<UInt64>()
        let late = Task {
            try await pool.perform(on: volume, onStall: { notices.append($0) }) { ctx -> String in
                hungLane.append(ctx.laneID.raw)
                hung.wait()                    // simulated hung getattrlistbulk: no heartbeat
                return "late"
            }
        }
        let stalled = await eventually { notices.values == [.stalled] }
        XCTAssertTrue(stalled)
        let poisonedCount = await pool.poisonedCount(of: volume)
        let health = await pool.health(of: volume)
        XCTAssertEqual(poisonedCount, 1)
        XCTAssertEqual(health, .healthy)

        // Retry: a fresh lane answers while the poisoned one is still blocked.
        let retryLane = try await pool.perform(on: volume) { ctx in ctx.laneID.raw }
        XCTAssertNotEqual(retryLane, hungLane.values.first)

        hung.open()
        let value = try await late.value                 // the late result still arrives…
        XCTAssertEqual(value, "late")
        XCTAssertEqual(notices.values, [.stalled, .resumed])
        // …and the poisoned lane is never used again.
        for _ in 0..<5 {
            let lane = try await pool.perform(on: volume) { ctx in ctx.laneID.raw }
            XCTAssertNotEqual(lane, hungLane.values.first)
        }
    }

    func testHeartbeatingWorkIsNotPoisoned() async throws {
        let pool = LanePool(config: fast)
        let notices = Recorder<StallNotice>()
        try await pool.perform(on: volume, onStall: { notices.append($0) }) { ctx in
            for _ in 0..<12 { usleep(50_000); ctx.heartbeat() }   // 600 ms total, beats every 50 ms
        }
        XCTAssertEqual(notices.values, [])
        let count = await pool.poisonedCount(of: volume)
        XCTAssertEqual(count, 0)
    }

    func testAwaitingPermissionReportsWaitingAndNeverPoisons() async throws {
        let pool = LanePool(config: fast)
        let notices = Recorder<StallNotice>()
        try await pool.perform(on: volume, stallPolicy: .awaitingPermission, onStall: { notices.append($0) }) { _ in
            usleep(500_000)          // the TCC prompt is up
        }
        XCTAssertEqual(notices.values, [.waitingForPermission, .resumed])
        let count = await pool.poisonedCount(of: volume)
        let lanes = await pool.liveLaneCount(of: volume, .read)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(lanes, 1)
    }

    func testPoisonCapMarksVolumeUnresponsiveUntilReset() async throws {
        let config = WatchdogConfig(stallTimeout: .milliseconds(150), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 2)
        let pool = LanePool(config: config)
        let healthEvents = Recorder<VolumeHealth>()
        let watcher = Task {
            for await (id, health) in pool.healthChanges where id == volume { healthEvents.append(health) }
        }
        defer { watcher.cancel() }
        let hung = gate()
        let other = VolumeID(raw: "mnt:/other")
        let a = Task { try await pool.perform(on: volume) { _ in hung.wait() } }
        let b = Task { try await pool.perform(on: volume) { _ in hung.wait() } }
        let marked = await eventually { await pool.health(of: volume) == .unresponsive }
        XCTAssertTrue(marked)
        do {
            try await pool.perform(on: volume) { _ in }
            XCTFail("an unresponsive volume must not get new reads")
        } catch {
            XCTAssertEqual(error as? LaneError, .volumeUnresponsive(volume))
        }
        let otherValue = try await pool.perform(on: other) { _ in 7 }      // other volumes unaffected
        XCTAssertEqual(otherValue, 7)

        await pool.resetVolume(volume)                                     // remount
        let health = await pool.health(of: volume)
        XCTAssertEqual(health, .healthy)
        let after = try await pool.perform(on: volume) { _ in 1 }
        XCTAssertEqual(after, 1)
        let sawBoth = await eventually { healthEvents.values == [.unresponsive, .healthy] }
        XCTAssertTrue(sawBoth, "\(healthEvents.values)")
        hung.open(count: 2)
        _ = try await (a.value, b.value)
    }

    func testJobsQueuedBehindAHungJobMoveToAFreshLane() async throws {
        let config = WatchdogConfig(stallTimeout: .milliseconds(150), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 4)
        let pool = LanePool(config: config)
        let hung = gate()
        let a = Task { try await pool.perform(on: volume) { _ in hung.wait() } }
        try await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        let b = try await pool.perform(on: volume) { _ in "b" }            // queued behind `a` on the only lane
        XCTAssertEqual(b, "b")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        hung.open()
        _ = try await a.value
    }

    func testCancellingAQueuedJobThrowsCancelledWithoutRunningIt() async throws {
        let config = WatchdogConfig(stallTimeout: .seconds(30), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 4)
        let pool = LanePool(config: config)
        let busy = gate()
        let ran = Recorder<Bool>()
        let a = Task { try await pool.perform(on: volume) { _ in busy.wait() } }
        try await Task.sleep(for: .milliseconds(30))
        let b = Task { try await pool.perform(on: volume) { _ in ran.append(true) } }
        try await Task.sleep(for: .milliseconds(30))
        b.cancel()
        do {
            try await b.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? LaneError, .cancelled)
        }
        busy.open()
        _ = try await a.value
        XCTAssertEqual(ran.values, [])
    }

    func testRunningJobSeesCancellation() async throws {
        let pool = LanePool(config: fast)
        let started = Recorder<Bool>()
        let task = Task {
            try await pool.perform(on: volume) { ctx -> Bool in
                started.append(true)
                while !ctx.isCancelled { usleep(5_000); ctx.heartbeat() }
                return true
            }
        }
        _ = await eventually { started.values == [true] }
        task.cancel()
        let sawCancel = try await task.value
        XCTAssertTrue(sawCancel)
    }

    func testNoMaterializationAppliesOnlyInsideBody() async throws {
        let pool = LanePool(config: fast)
        let (inside, after) = try await pool.perform(on: volume) { _ in
            let inside = withNoMaterialization {
                getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            }
            return (inside, getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD))
        }
        XCTAssertEqual(inside, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertNotEqual(after, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    func testGenerationOrdering() {
        let g0 = Generation.initial
        let g1 = g0.next()
        XCTAssertEqual(g0.raw, 0)
        XCTAssertEqual(g1.raw, 1)
        XCTAssertLessThan(g0, g1)
        XCTAssertEqual(g1.next().description, "gen2")
    }

    @MainActor
    func testObserversDeliverInOrderAndTokensCancel() {
        let observers = Observers<Int>()
        var log: [String] = []
        let a = observers.add { log.append("a\($0)") }
        var b: ObserverToken? = observers.add { log.append("b\($0)") }
        observers.send(1)
        b = nil                                   // deinit cancels
        observers.send(2)
        a.cancel(); a.cancel()                    // idempotent
        observers.send(3)
        XCTAssertEqual(log, ["a1", "b1", "a2"])
        XCTAssertTrue(observers.isEmpty)
        _ = b
    }

    func testAssertOffMainTrapsOnMainThread() throws {
        #if DEBUG
        if TrapProbe.value(TrapProbe.environmentKey) != nil { throw XCTSkip("in child") }
        let result = try TrapProbe.run(name: "main", testIdentifier: "FSKitTests.LaneTrapProbes/testProbeAssertOffMainOnMain",
                                       bundle: Bundle(for: LaneTests.self).bundleURL)
        XCTAssertTrue(result.trapped, "status \(result.status)\n\(result.output.suffix(1500))")
        #else
        throw XCTSkip("assertOffMain is a no-op in release builds")
        #endif
    }
}

final class LaneTrapProbes: XCTestCase {
    func testProbeAssertOffMainOnMain() throws {
        guard TrapProbe.isChild("main") else { throw XCTSkip("trap probe child only") }
        XCTAssertTrue(Thread.isMainThread)
        assertOffMain()
        XCTFail("assertOffMain did not trap on the main thread")
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter FSKitTests.Lane 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find type 'WatchdogConfig' in scope` (and similar).

- [ ] **Step 4: Implement support types**

Create `Sources/FSKit/Volumes/VolumeInfo.swift` with only `VolumeID` (shown under Interfaces). Create `Sources/FSKit/Support/Observers.swift`:

```swift
import Foundation
import Synchronization

/// Cancels a registration. Idempotent; also cancels on deinit, so dropping the token unsubscribes.
public final class ObserverToken: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    public init(_ cancel: @escaping @Sendable () -> Void) {
        action = Mutex(cancel)
    }

    public func cancel() {
        let run = action.withLock { value -> (@Sendable () -> Void)? in
            defer { value = nil }
            return value
        }
        run?()
    }

    deinit { cancel() }
}

/// Main-actor multicast of events to registered handlers, in registration order.
@MainActor
public final class Observers<Event> {
    private var handlers: [(id: UInt64, handler: @MainActor (Event) -> Void)] = []
    private var nextID: UInt64 = 0

    public init() {}

    public func add(_ handler: @escaping @MainActor (Event) -> Void) -> ObserverToken {
        nextID += 1
        let id = nextID
        handlers.append((id, handler))
        return ObserverToken { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.remove(id) }
            } else {
                Task { @MainActor in self?.remove(id) }
            }
        }
    }

    /// Delivers to a snapshot, so handlers may add or cancel registrations while being called.
    public func send(_ event: Event) {
        for entry in handlers { entry.handler(event) }
    }

    public var isEmpty: Bool { handlers.isEmpty }

    private func remove(_ id: UInt64) {
        handlers.removeAll { $0.id == id }
    }
}
```

Create `Sources/FSKit/Support/MainThread.swift`:

```swift
import Foundation

/// Debug builds: preconditionFailure if called on the main thread. Release: no-op.
/// Called at the top of every MacxFS/Core function that makes a blocking file-system call (§4.4).
public func assertOffMain(_ function: StaticString = #function, file: StaticString = #fileID, line: UInt = #line) {
    #if DEBUG
    if Thread.isMainThread {
        preconditionFailure("\(function) must not run on the main thread (§4.4 main-thread rule)", file: file, line: line)
    }
    #endif
}
```

Create `Sources/FSKit/Support/PerfSignposts.swift`:

```swift
import os

/// Shared signposter for the §9 intervals: navigate → firstBatch → firstPaint, enumerate, sort, iconFill.
public enum PerfSignposts {
    public static let signposter = OSSignposter(subsystem: "com.macexplorer.app", category: "perf")
    public static let navigate: StaticString = "navigate"
    public static let enumerate: StaticString = "enumerate"
    public static let firstBatch: StaticString = "firstBatch"
    public static let firstPaint: StaticString = "firstPaint"
    public static let sort: StaticString = "sort"
    public static let iconFill: StaticString = "iconFill"
}
```

Create `Sources/FSKit/Lanes/Generation.swift`:

```swift
/// Monotonic read generation (§4.2). A result is applied only if its generation is still current.
public struct Generation: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public static let initial = Generation(raw: 0)
    private init(raw: UInt64) { self.raw = raw }
    public func next() -> Generation { Generation(raw: raw &+ 1) }
    public static func < (lhs: Generation, rhs: Generation) -> Bool { lhs.raw < rhs.raw }
    public var description: String { "gen\(raw)" }
}
```

Create `Sources/FSKit/Lanes/Materialization.swift`:

```swift
import CFSKit

/// Runs body synchronously on the current (lane) thread with dataless materialization off; restores the
/// previous policy afterwards. Never contains a suspension point. Call only from lane work.
public func withNoMaterialization<T>(_ body: () throws -> T) rethrows -> T {
    var previous: Int32 = 0
    let changed = cfsk_materialize_off(&previous) == 0
    defer { if changed { _ = cfsk_materialize_restore(previous) } }
    return try body()
}
```

- [ ] **Step 5: Implement LaneContext, IOLane and Watchdog types**

Create `Sources/FSKit/Lanes/LaneContext.swift`. Heartbeats are an `Atomic<UInt64>` of `DispatchTime` uptime nanoseconds; a heartbeat after a stall notice emits `.resumed` exactly once (`stalled.exchange(false)`).

```swift
import Dispatch
import Synchronization

/// Per-job state shared by the lane thread (heartbeats), the awaiting task (cancellation) and the watchdog.
final class LaneJob: Sendable {
    let id: UInt64
    let volume: VolumeID
    let laneClass: LaneClass
    let policy: StallPolicy
    let onStall: (@Sendable (StallNotice) -> Void)?
    let lastBeat = Atomic<UInt64>(0)          // DispatchTime uptime nanoseconds; 0 = not started
    let cancelled = Atomic<Bool>(false)
    let stalled = Atomic<Bool>(false)         // a .stalled/.waitingForPermission notice is outstanding
    let everStalled = Atomic<Bool>(false)     // .poison jobs report .stalled at most once
    let laneID = Atomic<UInt64>(0)

    init(id: UInt64, volume: VolumeID, laneClass: LaneClass, policy: StallPolicy,
         onStall: (@Sendable (StallNotice) -> Void)?) {
        self.id = id
        self.volume = volume
        self.laneClass = laneClass
        self.policy = policy
        self.onStall = onStall
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func beat() {
        lastBeat.store(LaneJob.now(), ordering: .relaxed)
        if stalled.exchange(false, ordering: .acquiringAndReleasing) {
            onStall?(.resumed)
        }
    }
}

public struct LaneContext: Sendable {
    let job: LaneJob

    /// Call at least every 250 ms while making progress (after each syscall batch, per emitted batch).
    public func heartbeat() { job.beat() }
    /// True once the awaiting Task was cancelled. Work should return promptly (partial results are fine).
    public var isCancelled: Bool { job.cancelled.load(ordering: .relaxed) }
    public var laneID: LaneID { LaneID(raw: job.laneID.load(ordering: .relaxed)) }
}
```

Create `Sources/FSKit/Lanes/IOLane.swift`. The thread blocks on a `DispatchSemaphore`; the queue is a `Mutex`-protected FIFO. A poisoned lane hands back its not-started items and its thread exits once the blocked item finally returns; it is never joined.

```swift
import Foundation
import Synchronization

public struct LaneID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public var description: String { "lane\(raw)" }
}

public enum LaneClass: Sendable, Hashable { case read, fileOp }

/// One dedicated Thread with a serial FIFO of work items (§4.2). Never the cooperative pool or a GCD
/// global queue. A poisoned lane accepts no more work; its thread exits once its current item returns.
final class IOLane: Sendable {
    struct Item: Sendable {
        let job: LaneJob
        let run: @Sendable () -> Void
        let fail: @Sendable (any Error) -> Void
    }

    private struct State {
        var queue: [Item] = []
        var running: LaneJob?
        var poisoned = false
        var stopped = false
    }

    let id: LaneID
    let volume: VolumeID
    let laneClass: LaneClass
    private let state = Mutex(State())
    private let wakeup = DispatchSemaphore(value: 0)

    init(id: LaneID, volume: VolumeID, laneClass: LaneClass) {
        self.id = id
        self.volume = volume
        self.laneClass = laneClass
        let thread = Thread { [self] in self.loop() }
        thread.name = "macx.lane.\(laneClass).\(volume.raw).\(id.raw)"
        thread.qualityOfService = laneClass == .read ? .userInitiated : .utility
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Number of queued + running items.
    var load: Int { state.withLock { $0.queue.count + ($0.running == nil ? 0 : 1) } }
    var runningJob: LaneJob? { state.withLock { $0.running } }

    /// False if the lane is poisoned or stopped (caller picks another lane).
    func submit(_ item: Item) -> Bool {
        let accepted = state.withLock { s -> Bool in
            guard !s.poisoned, !s.stopped else { return false }
            s.queue.append(item)
            return true
        }
        if accepted { wakeup.signal() }
        return accepted
    }

    /// Removes a not-yet-started job (cancellation before start). Nil if it already started or isn't here.
    func withdraw(_ job: LaneJob) -> Item? {
        state.withLock { s in
            guard let i = s.queue.firstIndex(where: { $0.job === job }) else { return nil }
            return s.queue.remove(at: i)
        }
    }

    /// Marks the lane poisoned and hands back the items that had not started, for re-dispatch.
    func poison() -> [Item] {
        let drained = state.withLock { s -> [Item] in
            s.poisoned = true
            defer { s.queue.removeAll() }
            return s.queue
        }
        wakeup.signal()
        return drained
    }

    /// Lets an idle, healthy lane's thread exit (pool shutdown).
    func stop() {
        state.withLock { $0.stopped = true }
        wakeup.signal()
    }

    private func loop() {
        while true {
            wakeup.wait()
            let next = state.withLock { s -> Item? in
                if s.poisoned || (s.stopped && s.queue.isEmpty) { return nil }
                guard !s.queue.isEmpty else { return nil }
                let item = s.queue.removeFirst()
                s.running = item.job
                return item
            }
            guard let item = next else {
                if state.withLock({ $0.poisoned || $0.stopped }) { return }
                continue
            }
            item.job.laneID.store(id.raw, ordering: .relaxed)
            item.job.beat()
            item.run()
            let exit = state.withLock { s -> Bool in
                s.running = nil
                return s.poisoned
            }
            if exit { return }   // poisoned while blocked: never reused
        }
    }
}
```

Create `Sources/FSKit/Lanes/Watchdog.swift`:

```swift
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
    public static let `default` = WatchdogConfig()
    public init(stallTimeout: Duration = .seconds(2), tick: Duration = .milliseconds(250), lanesPerClass: Int = 2, poisonCap: Int = 4) {
        self.stallTimeout = stallTimeout
        self.tick = tick
        self.lanesPerClass = lanesPerClass
        self.poisonCap = poisonCap
    }

    var stallNanoseconds: UInt64 {
        let c = stallTimeout.components
        return UInt64(c.seconds) * 1_000_000_000 + UInt64(c.attoseconds / 1_000_000_000)
    }
}
```

- [ ] **Step 6: Implement LanePool**

Create `Sources/FSKit/Lanes/LanePool.swift`. Design: `perform` registers the job, dispatches it to the least-loaded healthy lane (creating one while fewer than `lanesPerClass` exist), and awaits a continuation resumed exactly once (`ResumeOnce`) by whichever comes first: the lane finishing, a cancellation before start (`withdraw`), or the poison cap failing re-dispatched items. A watchdog task runs every `tick` while jobs are in flight: a running `.poison` job with no heartbeat for `stallTimeout` poisons its lane (removed from the pool, queued items re-dispatched to a fresh lane, poisoned count +1, volume `.unresponsive` at `poisonCap`) and gets `.stalled` once; an `.awaitingPermission` job gets `.waitingForPermission` and its lane stays.

```swift
import Foundation
import Synchronization

public enum VolumeHealth: Sendable, Equatable { case healthy, unresponsive }

public enum LaneError: Error, Sendable, Equatable {
    case volumeUnresponsive(VolumeID)      // poisonCap reached; no reads issued until resetVolume
    case cancelled
}

/// Resumes a continuation exactly once, from whichever path gets there first (lane, cancel, poison cap).
final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>
    init(_ c: CheckedContinuation<T, any Error>) { continuation = Mutex(c) }
    func resume(_ result: Result<T, any Error>) {
        let c = continuation.withLock { value -> CheckedContinuation<T, any Error>? in
            defer { value = nil }
            return value
        }
        c?.resume(with: result)
    }
}

/// Broadcasts health changes to any number of AsyncStream subscribers.
final class HealthHub: Sendable {
    typealias Element = (VolumeID, VolumeHealth)
    private let subscribers = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in _ = self?.subscribers.withLock { $0.removeValue(forKey: id) } }
        return stream
    }

    func send(_ element: Element) {
        for c in subscribers.withLock({ Array($0.values) }) { c.yield(element) }
    }
}

/// Per-volume I/O lanes with a stall watchdog (§4.2). See the contract in the overview §3.2.
public actor LanePool {
    public static let shared = LanePool()

    private struct Key: Hashable { var volume: VolumeID; var laneClass: LaneClass }
    private struct Active { var job: LaneJob; var lane: IOLane }

    private let config: WatchdogConfig
    private var lanes: [Key: [IOLane]] = [:]
    private var poisoned: [VolumeID: Int] = [:]
    private var unresponsive: Set<VolumeID> = []
    private var active: [UInt64: Active] = [:]
    private var nextJobID: UInt64 = 0
    private var nextLaneID: UInt64 = 0
    private var watchdog: Task<Void, Never>?
    private nonisolated let hub = HealthHub()

    public init(config: WatchdogConfig = .default) {
        self.config = config
    }

    deinit {
        for lane in lanes.values.joined() { lane.stop() }
    }

    @discardableResult
    public func perform<T: Sendable>(
        on volume: VolumeID,
        _ laneClass: LaneClass = .read,
        stallPolicy: StallPolicy = .poison,
        onStall: (@Sendable (StallNotice) -> Void)? = nil,
        _ work: @escaping @Sendable (LaneContext) throws -> T
    ) async throws -> T {
        if unresponsive.contains(volume) { throw LaneError.volumeUnresponsive(volume) }
        nextJobID += 1
        let job = LaneJob(id: nextJobID, volume: volume, laneClass: laneClass, policy: stallPolicy, onStall: onStall)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let once = ResumeOnce(continuation)
                let item = IOLane.Item(
                    job: job,
                    run: { [self] in
                        defer { Task { await self.finished(job.id) } }
                        if job.cancelled.load(ordering: .relaxed) {
                            once.resume(.failure(LaneError.cancelled))
                            return
                        }
                        let result = Result<T, any Error> { try work(LaneContext(job: job)) }
                        if job.stalled.exchange(false, ordering: .acquiringAndReleasing) { job.onStall?(.resumed) }
                        once.resume(result)
                    },
                    fail: { error in once.resume(.failure(error)) }
                )
                dispatch(item)
            }
        } onCancel: {
            job.cancelled.store(true, ordering: .relaxed)
            Task { await self.withdraw(job) }
        }
    }

    public func health(of volume: VolumeID) -> VolumeHealth {
        unresponsive.contains(volume) ? .unresponsive : .healthy
    }

    public func poisonedCount(of volume: VolumeID) -> Int { poisoned[volume, default: 0] }

    public func liveLaneCount(of volume: VolumeID, _ laneClass: LaneClass) -> Int {
        lanes[Key(volume: volume, laneClass: laneClass)]?.count ?? 0
    }

    /// Called on remount/reappearance: forget the unresponsive mark and poisoned count.
    public func resetVolume(_ volume: VolumeID) {
        poisoned[volume] = nil
        if unresponsive.remove(volume) != nil { hub.send((volume, .healthy)) }
    }

    public nonisolated var healthChanges: AsyncStream<(VolumeID, VolumeHealth)> { hub.stream() }

    // MARK: Internals

    private func dispatch(_ item: IOLane.Item) {
        let job = item.job
        if unresponsive.contains(job.volume) {
            item.fail(LaneError.volumeUnresponsive(job.volume))
            return
        }
        let key = Key(volume: job.volume, laneClass: job.laneClass)
        var pool = lanes[key, default: []]
        let lane: IOLane
        if pool.count < config.lanesPerClass {
            nextLaneID += 1
            lane = IOLane(id: LaneID(raw: nextLaneID), volume: job.volume, laneClass: job.laneClass)
            pool.append(lane)
            lanes[key] = pool
        } else {
            lane = pool.min { $0.load < $1.load }!
        }
        // Only this actor poisons or stops lanes, so a lane taken from the pool accepts work.
        let accepted = lane.submit(item)
        precondition(accepted, "LanePool: pooled lane refused work")
        active[job.id] = Active(job: job, lane: lane)
        startWatchdogIfNeeded()
    }

    private func finished(_ id: UInt64) {
        active[id] = nil
    }

    /// Cancellation before the job started: take it off its lane and fail it now.
    private func withdraw(_ job: LaneJob) {
        guard let entry = active[job.id], let item = entry.lane.withdraw(job) else { return }
        active[job.id] = nil
        item.fail(LaneError.cancelled)
    }

    private func startWatchdogIfNeeded() {
        guard watchdog == nil else { return }
        let tick = config.tick
        watchdog = Task { [weak self] in
            while true {
                try? await Task.sleep(for: tick)
                guard let self, await self.tickWatchdog() else { return }
            }
        }
    }

    /// One watchdog pass. Returns false (and clears `watchdog`) when nothing is in flight.
    private func tickWatchdog() -> Bool {
        let now = LaneJob.now()
        let limit = config.stallNanoseconds
        for entry in active.values {
            let job = entry.job
            let beat = job.lastBeat.load(ordering: .relaxed)
            guard beat != 0, entry.lane.runningJob === job, now &- beat >= limit else { continue }
            guard !job.stalled.load(ordering: .relaxed) else { continue }
            switch job.policy {
            case .poison:
                guard !job.everStalled.exchange(true, ordering: .relaxed) else { continue }
                job.stalled.store(true, ordering: .relaxed)
                poison(entry.lane)
                job.onStall?(.stalled)
            case .awaitingPermission:
                job.stalled.store(true, ordering: .relaxed)
                job.onStall?(.waitingForPermission)
            }
        }
        if active.isEmpty {
            watchdog = nil
            return false
        }
        return true
    }

    private func poison(_ lane: IOLane) {
        let key = Key(volume: lane.volume, laneClass: lane.laneClass)
        lanes[key]?.removeAll { $0 === lane }
        let count = poisoned[lane.volume, default: 0] + 1
        poisoned[lane.volume] = count
        let drained = lane.poison()
        if count >= config.poisonCap, unresponsive.insert(lane.volume).inserted {
            hub.send((lane.volume, .unresponsive))
        }
        for item in drained {
            active[item.job.id] = nil
            dispatch(item)   // fails with volumeUnresponsive past the cap
        }
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter FSKitTests.Lane 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 15 tests, with 1 test skipped and 0 failures` (~2.5 s; the skip is the trap-probe child half).

Run it three more times with `--parallel` to check timing robustness: `for i in 1 2 3; do swift test --parallel --filter FSKitTests.Lane 2>&1 | grep -cE "error:"; done` → `0` three times.

- [ ] **Step 8: Build with zero warnings**

Run: `swift build 2>&1 | tail -5`
Expected: last line `Build complete! (…)`, no `warning:` lines above it.

- [ ] **Step 9: Commit**

```bash
git ls-files Sources/FSKit                    # P1-01's MacxFS stub is the file not created in this task
git rm -q <the stub file listed above>
git add Sources/FSKit/Support Sources/FSKit/Lanes Sources/FSKit/Volumes/VolumeInfo.swift Tests/FSKitTests/Support/TestHelpers.swift Tests/FSKitTests/LaneTests.swift
git commit -m "feat: I/O lanes with stall watchdog, poison cap and materialization policy (P1-04)"
```

---
## Task P1-05: Store: Entry, EntryFlags, Batch, NameArena, RowID/IdentityMode/NameNormalizer, TypeRegistry, EntryStore

**Spec:** §4.2 EntryStore (Entry fields, UTF-8 arena, `[UInt32]` permutation, hidden = dot or `UF_HIDDEN`), §4.2 Types (interned UTType table, packages = directory + conforms to `.package`), §4.2 SortKeys rule 4 (kind ranks by `localizedDescription` with `localizedStandardCompare`), §4.3 Ownership (value-type store, identity→index map), §4.3 Row identity (rowID on idStable volumes, normalized names elsewhere; duplicates never trap), §5.6 F2 rename (duplicate check NFC + case-insensitive; Review Focus 2 groundwork).

**Files:**
- Create: `Sources/FSKit/Store/Entry.swift`
- Create: `Sources/FSKit/Store/NameArena.swift`
- Create: `Sources/FSKit/Store/Batch.swift`
- Create: `Sources/FSKit/Store/RowID.swift`
- Create: `Sources/FSKit/Store/TypeRegistry.swift`
- Create: `Sources/FSKit/Store/EntryStore.swift`
- Test: `Tests/FSKitTests/EntryStoreTests.swift`
- Test: `Tests/FSKitTests/TypeRegistryTests.swift`

**Interfaces:**
- Consumes: P1-04 `Generation`, `Recorder` (test helper).
- Produces: overview §3.3 exactly:

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

Additions: `EntryError` gets a memberwise `public init(index:code:)` (needed by tests and readers). Internal: `fileExtensionRange(_:)` (shared with the reader and sorter: the bytes after the last `.` that is neither first nor last), `NameArena.removeAll(keepingCapacity:)`.

Behaviour other slices rely on: `append` never changes `order`; `upsert` keeps an existing identity's storage index and row (in name mode a new name is a new identity, so a rename there is remove + insert, §4.3); `remove` compacts and remaps `order`, errors and identities and compacts the arena when more than half of it (and > 64 KB) is garbage; `firstIndex(of:)` returns the first index for duplicate identities and the survivor takes over after removal.

- [ ] **Step 1: Write the failing store tests**

Create `Tests/FSKitTests/EntryStoreTests.swift` (`makeEntry`/`makeBatch` are reused by later FSKitTests files):

```swift
import MacxFS
import XCTest

func makeEntry(_ id: UInt64, kind: Kind = .file, size: Int64 = 0, mtime: Int64 = 0, flags: EntryFlags = []) -> Entry {
    Entry(rowID: id, fileID: id, size: size, allocSize: 0, mtime: mtime, ctime: 0, nameOffset: 0, nameLen: 0,
          kind: kind, flags: flags, typeIndex: kind == .directory ? TypeRegistry.folderIndex : TypeRegistry.dataIndex)
}

func makeBatch(_ items: [(String, Entry)], generation: Generation = .initial, errors: [EntryError] = []) -> Batch {
    var batch = Batch(generation: generation)
    for (name, entry) in items {
        Array(name.utf8).withUnsafeBufferPointer { batch.append(entry, nameBytes: $0) }
    }
    batch.errors = errors
    return batch
}

final class EntryStoreTests: XCTestCase {
    func testBatchAppendRewritesNameOffsets() {
        let batch = makeBatch([("a.txt", makeEntry(1)), ("Résumé", makeEntry(2))])
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.name(at: 0), "a.txt")
        XCTAssertEqual(batch.name(at: 1), "Résumé")
        XCTAssertEqual(batch.entries[1].nameOffset, 5)
        XCTAssertEqual(batch.entries[1].nameLen, UInt16("Résumé".utf8.count))
    }

    func testAppendIsOrderNeutralAndIdentitiesResolve() {
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("b", makeEntry(10)), ("a", makeEntry(11))]))
        store.append(makeBatch([("c", makeEntry(12))], errors: [EntryError(index: 0, code: 13)]))
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.visibleCount, 0, "append never changes order")
        XCTAssertEqual(store.name(2), "c")
        XCTAssertEqual(store.errno(2), 13)
        XCTAssertNil(store.errno(0))
        store.setOrder([1, 0, 2])
        XCTAssertEqual(store.storageIndex(forRow: 0), 1)
        XCTAssertEqual(store.row(ofStorageIndex: 2), 2)
        XCTAssertEqual(store.row(of: .object(10)), 1)
        XCTAssertEqual(store.identity(1), .object(11))
    }

    func testDuplicateIdentitiesNeverTrapFirstWins() {
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("x", makeEntry(5)), ("y", makeEntry(5))]))
        XCTAssertEqual(store.firstIndex(of: .object(5)), 0)
        store.remove([0])
        XCTAssertEqual(store.firstIndex(of: .object(5)), 0, "the survivor takes over the identity")
        XCTAssertEqual(store.name(0), "y")
    }

    func testNameIdentityIsNFCAndCaseFoldedOnCaseInsensitiveVolumes() {
        var store = EntryStore(identityMode: .name(caseSensitive: false))
        store.append(makeBatch([("Cafe\u{301}.TXT", makeEntry(1))]))
        XCTAssertEqual(store.identity(0), .name("caf\u{E9}.txt"))
        XCTAssertEqual(store.firstIndex(of: .name("caf\u{E9}.txt")), 0)
        var sensitive = EntryStore(identityMode: .name(caseSensitive: true))
        sensitive.append(makeBatch([("A", makeEntry(1)), ("a", makeEntry(2))]))
        XCTAssertNotEqual(sensitive.identity(0), sensitive.identity(1))
    }

    func testFirstIndexNamedIncludesHiddenRowsNotInOrder() {
        // Review Focus 2 groundwork: duplicate checks see the whole store, not the visible permutation.
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("visible.txt", makeEntry(1)), (".env", makeEntry(2, flags: .dotName)),
                                ("notes.txt", makeEntry(3, flags: .bsdHidden))]))
        store.setOrder([0])
        XCTAssertEqual(store.firstIndex(named: ".env", caseSensitive: false), 1)
        XCTAssertEqual(store.firstIndex(named: "NOTES.TXT", caseSensitive: false), 2)
        XCTAssertNil(store.firstIndex(named: "NOTES.TXT", caseSensitive: true))
        XCTAssertEqual(store.firstIndex(named: "visible.txt", caseSensitive: true), 0)
    }

    func testUpsertReplacesSameIdentityInPlaceOrAppends() {
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch([("a", makeEntry(1, size: 1)), ("b", makeEntry(2))]))
        store.setOrder([0, 1])
        let v = store.version
        let replaced = store.upsert(makeEntry(1, size: 99), name: "a-renamed")
        XCTAssertEqual(replaced, 0)
        XCTAssertEqual(store.entry(0).size, 99)
        XCTAssertEqual(store.name(0), "a-renamed")
        XCTAssertEqual(store.row(of: .object(1)), 0, "row kept")
        XCTAssertGreaterThan(store.version, v)
        let appended = store.upsert(makeEntry(3), name: "c")
        XCTAssertEqual(appended, 2)
        XCTAssertNil(store.row(ofStorageIndex: 2), "new entries are not displayed until setOrder")
    }

    func testUpsertInNameModeRenameIsANewIdentity() {
        var store = EntryStore(identityMode: .name(caseSensitive: true))
        store.append(makeBatch([("a", makeEntry(1))]))
        XCTAssertEqual(store.upsert(makeEntry(1, size: 5), name: "a"), 0)
        XCTAssertEqual(store.upsert(makeEntry(1), name: "b"), 1)
    }

    func testRemoveCompactsAndRemapsOrderErrorsAndInverse() {
        var store = EntryStore(identityMode: .objectID)
        store.append(makeBatch((0..<6).map { ("n\($0)", makeEntry(UInt64(100 + $0))) },
                               errors: [EntryError(index: 4, code: 1)]))
        store.setOrder([5, 3, 1, 4])
        store.remove([1, 2])
        XCTAssertEqual(store.count, 4)
        XCTAssertEqual((0..<4).map { store.name(UInt32($0)) }, ["n0", "n3", "n4", "n5"])
        XCTAssertEqual(store.order, [3, 1, 2])
        XCTAssertEqual(store.row(of: .object(105)), 0)
        XCTAssertEqual(store.row(of: .object(103)), 1)
        XCTAssertNil(store.firstIndex(of: .object(101)))
        XCTAssertEqual(store.errno(2), 1)
        XCTAssertNil(store.row(ofStorageIndex: 0))
    }

    func testArenaCompactionKeepsNamesIntact() {
        var store = EntryStore(identityMode: .objectID)
        let long = String(repeating: "x", count: 200)
        store.append(makeBatch((0..<1_000).map { ("\(long)-\($0)", makeEntry(UInt64($0))) }))
        store.remove(Set((0..<900).map(UInt32.init)))   // > 64 KB garbage and > half the arena
        XCTAssertEqual(store.count, 100)
        XCTAssertLessThan(store.names.bytes.count, 30_000)
        XCTAssertEqual(store.name(0), "\(long)-900")
        XCTAssertEqual(store.name(99), "\(long)-999")
    }

    func testCopiesAreIndependent() {
        var a = EntryStore(identityMode: .objectID)
        a.append(makeBatch([("a", makeEntry(1))]))
        var b = a
        b.append(makeBatch([("b", makeEntry(2))]))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 2)
    }

    func testHiddenFlagAndFolderSorting() {
        XCTAssertTrue(EntryFlags.dotName.isHidden)
        XCTAssertTrue(EntryFlags.bsdHidden.isHidden)
        XCTAssertFalse(EntryFlags.locked.isHidden)
        XCTAssertTrue(makeEntry(1, kind: .directory).isFolderForSorting)
        XCTAssertFalse(makeEntry(1, kind: .package).isFolderForSorting)
    }

    func testInvalidUTF8NamesDecodeLossilyWithoutTrapping() {
        // SMB/FAT volumes can deliver bytes that are not UTF-8; rows must still appear.
        var batch = Batch(generation: .initial)
        ([0x62, 0xFF, 0x2E, 0x74] as [UInt8]).withUnsafeBufferPointer { batch.append(makeEntry(1), nameBytes: $0) }
        XCTAssertEqual(batch.name(at: 0), "b\u{FFFD}.t")
        var store = EntryStore(identityMode: .name(caseSensitive: false))
        store.append(batch)
        XCTAssertEqual(store.name(0), "b\u{FFFD}.t")
        XCTAssertEqual(store.identity(0), .name("b\u{FFFD}.t"))
        XCTAssertEqual(store.withNameBytes(0) { Array($0) }, [0x62, 0xFF, 0x2E, 0x74], "raw bytes are kept for operations")
    }

    func testNameNormalizerSameName() {
        XCTAssertTrue(NameNormalizer.sameName("Cafe\u{301}", "Caf\u{E9}", caseSensitive: true))
        XCTAssertTrue(NameNormalizer.sameName("ABC", "abc", caseSensitive: false))
        XCTAssertFalse(NameNormalizer.sameName("ABC", "abc", caseSensitive: true))
        XCTAssertEqual(Array(NameNormalizer.nfc("Cafe\u{301}").unicodeScalars), Array("Caf\u{E9}".unicodeScalars))
    }
}
```

Create `Tests/FSKitTests/TypeRegistryTests.swift`:

```swift
import Foundation
import MacxFS
import XCTest

final class TypeRegistryTests: XCTestCase {
    func testFixedIndices() {
        let r = TypeRegistry()
        XCTAssertEqual(r.type(at: TypeRegistry.folderIndex), .folder)
        XCTAssertEqual(r.type(at: TypeRegistry.dataIndex), .data)
        XCTAssertEqual(r.type(at: TypeRegistry.symlinkIndex), .symbolicLink)
        XCTAssertEqual(r.index(forExtension: "", isDirectory: false), TypeRegistry.dataIndex)
        XCTAssertEqual(r.index(forExtension: "", isDirectory: true), TypeRegistry.folderIndex)
    }

    func testInterningIsCaseInsensitiveAndStable() {
        let r = TypeRegistry()
        let a = r.index(forExtension: "txt", isDirectory: false)
        XCTAssertEqual(r.index(forExtension: "TXT", isDirectory: false), a)
        XCTAssertEqual(r.type(at: a), .plainText)
        let v = r.version
        _ = r.index(forExtension: "txt", isDirectory: false)
        XCTAssertEqual(r.version, v)
    }

    func testPackagesAndApplications() {
        let r = TypeRegistry()
        let app = r.index(forExtension: "app", isDirectory: true)
        XCTAssertTrue(r.isPackage(app))
        XCTAssertTrue(r.isApplication(app))
        let rtfd = r.index(forExtension: "rtfd", isDirectory: true)
        XCTAssertTrue(r.isPackage(rtfd))
        XCTAssertFalse(r.isApplication(rtfd))
        XCTAssertEqual(r.index(forExtension: "2", isDirectory: true), TypeRegistry.folderIndex, "v1.2 is a folder")
        XCTAssertFalse(r.isPackage(r.index(forExtension: "app", isDirectory: false)), "a file named x.app is not a package")
    }

    func testUnknownExtensionGetsDynamicType() {
        let r = TypeRegistry()
        let i = r.index(forExtension: "macxunknownext", isDirectory: false)
        XCTAssertNotEqual(i, TypeRegistry.dataIndex)
        XCTAssertTrue(r.type(at: i).identifier.hasPrefix("dyn."))
    }

    func testKindRanksFollowLocalizedDescriptionAndRecomputeOnGrowth() {
        let r = TypeRegistry()
        let txt = r.index(forExtension: "txt", isDirectory: false)
        let pdf = r.index(forExtension: "pdf", isDirectory: false)
        let first = r.kindRanks()
        XCTAssertEqual(first.version, r.version)
        let byRank = (0..<UInt16(first.ranks.count)).sorted { first.ranks[Int($0)] < first.ranks[Int($1)] }
        let descriptions = byRank.map { r.localizedDescription($0) }
        XCTAssertEqual(descriptions, descriptions.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertNotEqual(first.ranks[Int(txt)], first.ranks[Int(pdf)])
        _ = r.index(forExtension: "png", isDirectory: false)
        XCTAssertEqual(r.kindRanks().ranks.count, first.ranks.count + 1)
    }

    func testConcurrentInterningIsConsistent() {
        let r = TypeRegistry()
        let exts = ["txt", "pdf", "png", "jpg", "swift", "md", "zip", "json"]
        let results = Recorder<[UInt16]>()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            results.append(exts.map { r.index(forExtension: Substring($0), isDirectory: false) })
        }
        XCTAssertEqual(Set(results.values).count, 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "FSKitTests.(EntryStoreTests|TypeRegistryTests)" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find type 'Entry' in scope` (and similar).

- [ ] **Step 3: Implement Entry, NameArena, Batch, RowID**

Create `Sources/FSKit/Store/Entry.swift`:

```swift
public enum Kind: UInt8, Sendable, Codable { case file, directory, symlink, package, alias, other }

public struct EntryFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
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
    public var isHidden: Bool { !isDisjoint(with: [.dotName, .bsdHidden]) }
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
                nameOffset: UInt32, nameLen: UInt16, kind: Kind, flags: EntryFlags, typeIndex: UInt16) {
        self.rowID = rowID
        self.fileID = fileID
        self.size = size
        self.allocSize = allocSize
        self.mtime = mtime
        self.ctime = ctime
        self.nameOffset = nameOffset
        self.nameLen = nameLen
        self.kind = kind
        self.flags = flags
        self.typeIndex = typeIndex
    }
    public var isFolderForSorting: Bool { kind == .directory }   // packages sort as files
}
```

Create `Sources/FSKit/Store/NameArena.swift`:

```swift
/// Concatenated UTF-8 names. Strings are made only for visible cells and operations (§4.2).
public struct NameArena: Sendable {
    public init() {}
    public private(set) var bytes: [UInt8] = []

    public mutating func append(_ bytes: some Collection<UInt8>) -> UInt32 {
        let offset = UInt32(self.bytes.count)
        self.bytes.append(contentsOf: bytes)
        return offset
    }

    public func string(offset: UInt32, length: UInt16) -> String {
        withBytes(offset: offset, length: length) { String(decoding: $0, as: UTF8.self) }
    }

    public func withBytes<R>(offset: UInt32, length: UInt16, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { all in
            try body(UnsafeBufferPointer(rebasing: all[Int(offset)..<Int(offset) + Int(length)]))
        }
    }

    mutating func removeAll(keepingCapacity: Bool) { bytes.removeAll(keepingCapacity: keepingCapacity) }
}

/// Byte range of the file extension in a UTF-8 name: after the last ".", which is neither the first nor
/// the last byte (".bashrc" and "name." have no extension).
func fileExtensionRange(_ name: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
    guard name.count > 2, let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < name.count - 1 else { return nil }
    return (dot + 1)..<name.count
}
```

Create `Sources/FSKit/Store/Batch.swift`:

```swift
public struct EntryError: Sendable, Equatable {
    public var index: UInt32
    public var code: Int32
    public init(index: UInt32, code: Int32) { self.index = index; self.code = code }
}

/// A Sendable chunk of directory entries with its own name arena (§4.2 streaming).
public struct Batch: Sendable {
    public var generation: Generation
    public var entries: [Entry] = []      // nameOffset relative to `names`
    public var names: [UInt8] = []        // concatenated UTF-8 names
    public var errors: [EntryError] = []  // index into `entries`
    public init(generation: Generation) { self.generation = generation }
    public var count: Int { entries.count }

    public func name(at index: Int) -> String {
        let e = entries[index]
        return names.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[Int(e.nameOffset)..<Int(e.nameOffset) + Int(e.nameLen)]), as: UTF8.self)
        }
    }

    public mutating func append(_ entry: Entry, nameBytes: UnsafeBufferPointer<UInt8>) {
        var e = entry
        e.nameOffset = UInt32(names.count)
        e.nameLen = UInt16(clamping: nameBytes.count)
        names.append(contentsOf: nameBytes.prefix(Int(e.nameLen)))
        entries.append(e)
    }
}
```

Create `Sources/FSKit/Store/RowID.swift`:

```swift
import Foundation

public enum IdentityMode: Sendable, Hashable {
    case objectID                         // idStable volume: identity = Entry.rowID
    case name(caseSensitive: Bool)        // other volumes: identity = normalized name
}

public enum RowID: Hashable, Sendable {
    case object(UInt64)
    case name(String)                     // NFC; lowercased (locale-independent) when the volume is case-insensitive
}

public enum NameNormalizer {
    public static func nfc(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }

    public static func identityName(_ name: String, caseSensitive: Bool) -> String {
        let n = nfc(name)
        return caseSensitive ? n : n.lowercased()
    }

    /// Same-name test used by rename duplicate checks: NFC always, case-insensitive when !caseSensitive.
    /// Compares unicode scalars (Swift's == is already canonical-equivalence based; scalars make it explicit).
    public static func sameName(_ a: String, _ b: String, caseSensitive: Bool) -> Bool {
        identityName(a, caseSensitive: caseSensitive).unicodeScalars
            .elementsEqual(identityName(b, caseSensitive: caseSensitive).unicodeScalars)
    }
}
```

- [ ] **Step 4: Implement TypeRegistry**

Create `Sources/FSKit/Store/TypeRegistry.swift`. `UTType(filenameExtension:conformingTo:)` is resolved outside the lock; a directory gets its own index only when its type conforms to `.package` (so `v1.2` stays a folder and `Tool.app` is an application package); a regular file named `x.app` is not a package.

```swift
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Interned UTType table (§4.2 Types). Index 0/1/2 are fixed; others are added on first sighting.
public final class TypeRegistry: Sendable {
    public static let shared = TypeRegistry()
    public static let folderIndex: UInt16 = 0     // public.folder
    public static let dataIndex: UInt16 = 1       // public.data (no extension)
    public static let symlinkIndex: UInt16 = 2    // public.symlink

    private struct Key: Hashable { var ext: String; var isDirectory: Bool }
    private struct State {
        var byKey: [Key: UInt16] = [:]
        var types: [UTType] = [.folder, .data, .symbolicLink]
        var packages: [Bool] = [false, false, false]
        var applications: [Bool] = [false, false, false]
        var descriptions: [String] = []
        var rankCache: (version: Int, ranks: [UInt16])?
    }
    private let state: Mutex<State>

    public init() {
        var s = State()
        s.descriptions = s.types.map { $0.localizedDescription ?? $0.identifier }
        state = Mutex(s)
    }

    public var version: Int { state.withLock { $0.types.count } }

    /// Interns (lowercased extension, isDirectory). Thread-safe (Mutex). ~O(1) after first sighting.
    /// Directories whose extension isn't a package type map to folderIndex ("v1.2" is a folder).
    public func index(forExtension ext: Substring, isDirectory: Bool) -> UInt16 {
        if ext.isEmpty { return isDirectory ? Self.folderIndex : Self.dataIndex }
        let key = Key(ext: ext.lowercased(), isDirectory: isDirectory)
        if let hit = state.withLock({ $0.byKey[key] }) { return hit }
        // Resolve outside the lock (UTType lookups take ~µs), then insert (another thread may have won).
        let resolved: UTType? = isDirectory
            ? UTType(filenameExtension: key.ext, conformingTo: .directory)
            : UTType(filenameExtension: key.ext, conformingTo: .data)
        return state.withLock { s in
            if let hit = s.byKey[key] { return hit }
            let index: UInt16
            if let type = resolved, !(isDirectory && !type.conforms(to: .package)), s.types.count < Int(UInt16.max) {
                if let existing = s.types.firstIndex(of: type) {
                    index = UInt16(existing)
                } else {
                    index = UInt16(s.types.count)
                    s.types.append(type)
                    s.packages.append(isDirectory && type.conforms(to: .package))
                    s.applications.append(type.conforms(to: .application))
                    s.descriptions.append(type.localizedDescription ?? type.identifier)
                }
            } else {
                index = isDirectory ? Self.folderIndex : Self.dataIndex
            }
            s.byKey[key] = index
            return index
        }
    }

    public func type(at index: UInt16) -> UTType { state.withLock { $0.types[Int(index)] } }
    public func isPackage(_ index: UInt16) -> Bool { state.withLock { $0.packages[Int(index)] } }
    public func isApplication(_ index: UInt16) -> Bool { state.withLock { $0.applications[Int(index)] } }
    public func localizedDescription(_ index: UInt16) -> String { state.withLock { $0.descriptions[Int(index)] } }

    /// Rank by localizedDescription (localizedStandardCompare); recomputed when the table grows.
    /// Equal descriptions share a rank, so the name tie-break decides.
    public func kindRanks() -> (version: Int, ranks: [UInt16]) {
        let (version, cached, descriptions) = state.withLock { s in (s.types.count, s.rankCache, s.descriptions) }
        if let cached, cached.version == version { return cached }
        let order = descriptions.indices.sorted {
            descriptions[$0].localizedStandardCompare(descriptions[$1]) == .orderedAscending
        }
        var ranks = [UInt16](repeating: 0, count: descriptions.count)
        var rank: UInt16 = 0
        for (position, index) in order.enumerated() {
            if position > 0, descriptions[order[position - 1]].localizedStandardCompare(descriptions[index]) != .orderedSame {
                rank += 1
            }
            ranks[index] = rank
        }
        let result = (version, ranks)
        state.withLock { s in if s.types.count == version { s.rankCache = result } }
        return result
    }
}
```

- [ ] **Step 5: Implement EntryStore**

Create `Sources/FSKit/Store/EntryStore.swift`:

```swift
/// Struct-of-arrays folder snapshot (§4.2, §4.3 ownership). Value type with copy-on-write arrays: the
/// main-actor FolderModel owns and mutates it; sorting/diffing work on immutable copies off main.
public struct EntryStore: Sendable {
    public let identityMode: IdentityMode
    public private(set) var entries: [Entry] = []      // storage order (append order)
    public private(set) var names = NameArena()
    public private(set) var order: [UInt32] = []       // display permutation: storage indices of visible rows
    public private(set) var version: UInt64 = 0        // incremented by every mutation

    private var rowOfIndex: [Int32] = []               // inverse permutation; -1 = not displayed
    private var identities: [RowID: UInt32] = [:]      // first storage index per identity
    private var errors: [UInt32: Int32] = [:]          // per-entry errno side table
    private var garbageBytes = 0                       // arena bytes no entry references any more

    public init(identityMode: IdentityMode) { self.identityMode = identityMode }

    public var count: Int { entries.count }
    public var visibleCount: Int { order.count }

    // MARK: Storage-index access

    public func entry(_ index: UInt32) -> Entry { entries[Int(index)] }

    public func name(_ index: UInt32) -> String {
        let e = entries[Int(index)]
        return names.string(offset: e.nameOffset, length: e.nameLen)
    }

    public func withNameBytes<R>(_ index: UInt32, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        let e = entries[Int(index)]
        return try names.withBytes(offset: e.nameOffset, length: e.nameLen, body)
    }

    public func identity(_ index: UInt32) -> RowID {
        identity(of: entries[Int(index)], name: name(index))
    }

    public func firstIndex(of id: RowID) -> UInt32? { identities[id] }

    /// O(n). NameNormalizer.sameName semantics; hidden rows (not in `order`) included.
    public func firstIndex(named name: String, caseSensitive: Bool) -> UInt32? {
        let wanted = NameNormalizer.identityName(name, caseSensitive: caseSensitive)
        for i in entries.indices where NameNormalizer.identityName(self.name(UInt32(i)), caseSensitive: caseSensitive) == wanted {
            return UInt32(i)
        }
        return nil
    }

    public func errno(_ index: UInt32) -> Int32? { errors[index] }

    // MARK: Display-row access

    public func storageIndex(forRow row: Int) -> UInt32 { order[row] }

    public func row(ofStorageIndex index: UInt32) -> Int? {
        guard Int(index) < rowOfIndex.count else { return nil }
        let row = rowOfIndex[Int(index)]
        return row < 0 ? nil : Int(row)
    }

    public func row(of id: RowID) -> Int? { firstIndex(of: id).flatMap { row(ofStorageIndex: $0) } }

    // MARK: Mutation

    /// O(batch); leaves `order` unchanged.
    public mutating func append(_ batch: Batch) {
        let base = UInt32(entries.count)
        let arenaBase = UInt32(names.bytes.count)
        _ = names.append(batch.names)
        entries.reserveCapacity(entries.count + batch.count)
        for var e in batch.entries {
            e.nameOffset += arenaBase
            entries.append(e)
            let index = UInt32(entries.count - 1)
            let id = identity(index)
            if identities[id] == nil { identities[id] = index }
        }
        rowOfIndex.append(contentsOf: repeatElement(-1, count: batch.count))
        for error in batch.errors { errors[base + error.index] = error.code }
        version &+= 1
    }

    public mutating func setOrder(_ order: [UInt32]) {
        self.order = order
        rowOfIndex = [Int32](repeating: -1, count: entries.count)
        for (row, index) in order.enumerated() { rowOfIndex[Int(index)] = Int32(row) }
        version &+= 1
    }

    /// Replaces the entry with the same identity (keeping its storage index and row) or appends a new one
    /// (not displayed until the next setOrder). Returns the storage index.
    @discardableResult
    public mutating func upsert(_ entry: Entry, name: String) -> UInt32 {
        var e = entry
        let bytes = Array(name.utf8)
        e.nameLen = UInt16(clamping: bytes.count)
        e.nameOffset = names.append(bytes.prefix(Int(e.nameLen)))
        let id = identity(of: e, name: name)
        if let index = identities[id] {
            let old = entries[Int(index)]
            garbageBytes += Int(old.nameLen)
            if identity(of: old, name: self.name(index)) != id { identities[identity(index)] = nil }
            entries[Int(index)] = e
            identities[id] = index
            version &+= 1
            return index
        }
        entries.append(e)
        rowOfIndex.append(-1)
        let index = UInt32(entries.count - 1)
        identities[id] = index
        version &+= 1
        return index
    }

    /// Compacts storage, remaps `order`, identities and errors. O(n).
    public mutating func remove(_ indices: Set<UInt32>) {
        guard !indices.isEmpty else { return }
        var remap = [Int32](repeating: -1, count: entries.count)
        var kept: [Entry] = []
        kept.reserveCapacity(entries.count - indices.count)
        for (i, e) in entries.enumerated() {
            if indices.contains(UInt32(i)) { garbageBytes += Int(e.nameLen); continue }
            remap[i] = Int32(kept.count)
            kept.append(e)
        }
        entries = kept
        order = order.compactMap { remap[Int($0)] >= 0 ? UInt32(remap[Int($0)]) : nil }
        var newErrors: [UInt32: Int32] = [:]
        for (i, code) in errors where remap[Int(i)] >= 0 { newErrors[UInt32(remap[Int(i)])] = code }
        errors = newErrors
        if garbageBytes > 64 * 1024 && garbageBytes * 2 > names.bytes.count { compactArena() }
        rebuildIdentities()
        setOrder(order)   // rebuilds the inverse permutation; bumps version
    }

    public mutating func setError(_ code: Int32?, at index: UInt32) {
        errors[index] = code
        if code == nil { errors.removeValue(forKey: index) }
        version &+= 1
    }

    // MARK: Private

    private func identity(of entry: Entry, name: @autoclosure () -> String) -> RowID {
        switch identityMode {
        case .objectID: return .object(entry.rowID)
        case .name(let caseSensitive): return .name(NameNormalizer.identityName(name(), caseSensitive: caseSensitive))
        }
    }

    private mutating func rebuildIdentities() {
        identities.removeAll(keepingCapacity: true)
        for i in entries.indices {
            let id = identity(UInt32(i))
            if identities[id] == nil { identities[id] = UInt32(i) }
        }
    }

    private mutating func compactArena() {
        var fresh = NameArena()
        for i in entries.indices {
            let e = entries[i]
            entries[i].nameOffset = names.withBytes(offset: e.nameOffset, length: e.nameLen) { fresh.append($0) }
        }
        names = fresh
        garbageBytes = 0
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "FSKitTests.(EntryStoreTests|TypeRegistryTests)" 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 19 tests, with 0 failures`.

- [ ] **Step 7: Build with zero warnings**

Run: `swift build 2>&1 | tail -5`
Expected: last line `Build complete! (…)`, no `warning:` lines above it.

- [ ] **Step 8: Commit**

```bash
git add Sources/FSKit/Store Tests/FSKitTests/EntryStoreTests.swift Tests/FSKitTests/TypeRegistryTests.swift
git commit -m "feat: struct-of-arrays EntryStore, batches, row identity and type registry (P1-05)"
```

---
## Task P1-06: Reading: BulkReader, FallbackReader, RecordConverter, ItemReader, DirectoryReader

**Spec:** §4.2 DirectoryReader (actor per volume on read lanes, `getattrlistbulk` 256 KB, parser rules, degraded rows, `readdir`+`fstatat` fallback on `ENOTSUP`/`EINVAL`, streaming 2,000 entries / 8 ms), §4.2 Materialization (dataless items listed, never opened; `noMaterialization` reads), §4.2 TCC prompts (`permissionPending` → waiting, never poisoned), §4.2 Volumes.release (cancel in-flight reads, wait ≤ 1 s), §4.3 Watcher incremental path (`readItems`), §9 parser golden test vs `lstat`/`getattrlist`, fallback parity, lane tests (stale generation).

**Files:**
- Create: `Sources/FSKit/Reader/ReadTypes.swift`
- Create: `Sources/FSKit/Reader/RecordConverter.swift`
- Create: `Sources/FSKit/Reader/BulkReader.swift`
- Create: `Sources/FSKit/Reader/FallbackReader.swift`
- Create: `Sources/FSKit/Reader/ItemReader.swift`
- Create: `Sources/FSKit/Reader/DirectoryReader.swift`
- Test: `Tests/FSKitTests/Support/ReadHelpers.swift`
- Test: `Tests/FSKitTests/ReaderGoldenTests.swift`
- Test: `Tests/FSKitTests/ReaderParityTests.swift`
- Test: `Tests/FSKitTests/DirectoryReaderTests.swift`
- Not in this task: `Sources/FSKit/Reader/DirectoryReaders.swift` moves to P1-08 (it needs `MountTableStore`; Contract notes 3)

**Interfaces:**
- Consumes: P1-02 fixtures; P1-03 `cfsk_bulk_read`, `cfsk_cursor_*`, `cfsk_stat_at`; P1-04 `LanePool.perform`, `LaneContext`, `StallPolicy`, `withNoMaterialization`, `assertOffMain`, `PerfSignposts`, `Generation`; P1-05 `Batch`, `Entry`, `EntryFlags`, `TypeRegistry`, `fileExtensionRange`.
- Produces: overview §3.4 without `DirectoryReaders` (P1-08):

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
```

Additions: memberwise `public init`s for `ReadSummary(entryCount:degradedCount:usedFallback:elapsed:)` and `ReadFailure(code:stage:)`. Internal seams (`@testable`): `BatchAccumulator(batchSize:interval:now:)`, `RecordConverter`, `DirectoryReader.init(volume:lanes:types:implementation:)` with `ReadImplementation` (untyped `throws`, see Global Constraints toolchain hazard), `DirectoryReader.inFlightCount`.

Event contract consumed by `FolderModel` (S2, P1-10): batches carry the read's generation; `.stalled`/`.waitingForPermission` may be followed by `.resumed`; the stream always ends with exactly one `.completed` or `.failed`, except when the consumer stopped iterating (then it just finishes). Directory-level errors are `.failed(ReadFailure(code: errno, stage: .open))` (`ENOENT`, `ENOTDIR`, `EACCES`, `EPERM`); a volume past the poison cap yields `.failed(ReadFailure(code: ETIMEDOUT, stage: .unresponsiveVolume))`. Directory `Entry.size` is the entry count. `directoriesOnly` returns `Kind.directory` only (packages and symlinks excluded). An empty directory completes with no batches.

- [ ] **Step 1: Add read helpers (test support)**

Create `Tests/FSKitTests/Support/ReadHelpers.swift`:

```swift
import Foundation
import MacxFS

/// Runs BulkReader (or FallbackReader) synchronously on a lane and returns name → (entry, errno).
func readAll(_ dir: URL, options: ReadOptions = ReadOptions(), lanes: LanePool = LanePool(),
             types: TypeRegistry = .shared) async throws -> (entries: [String: (Entry, Int32?)], summary: ReadSummary, batches: [Int]) {
    try await lanes.perform(on: .unknown) { ctx in
        var entries: [String: (Entry, Int32?)] = [:]
        var sizes: [Int] = []
        let summary = try BulkReader.read(dir, generation: .initial, options: options, types: types, context: ctx) { batch in
            sizes.append(batch.count)
            let errs = Dictionary(uniqueKeysWithValues: batch.errors.map { ($0.index, $0.code) })
            for i in 0..<batch.count { entries[batch.name(at: i)] = (batch.entries[i], errs[UInt32(i)]) }
            return true
        }
        return (entries, summary, sizes)
    }
}

/// Collects a DirectoryReader stream.
func collect(_ stream: AsyncStream<ReadEvent>) async -> (batches: [Batch], others: [String]) {
    var batches: [Batch] = [], others: [String] = []
    for await event in stream {
        switch event {
        case .batch(let b): batches.append(b)
        case .stalled: others.append("stalled")
        case .waitingForPermission: others.append("waiting")
        case .resumed: others.append("resumed")
        case .completed(let s): others.append("completed:\(s.entryCount)")
        case .failed(let f): others.append("failed:\(f.code):\(f.stage)")
        }
    }
    return (batches, others)
}
```

- [ ] **Step 2: Write the failing golden test**

Create `Tests/FSKitTests/ReaderGoldenTests.swift`. Every entry of the §9 tree is compared field by field with `lstat(2)`, `access(2)` and an independent `getattrlist(ATTR_CMNEXT_LINKID)` call; synthetic records cover per-entry errors and dataless/custom-icon flags.

```swift
import CFSKit
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import XCTest

final class ReaderGoldenTests: XCTestCase {
    private var sandbox: Sandbox!
    private var golden: URL!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        golden = try FixtureTree.golden(in: sandbox)
    }

    private static func ns(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec) }

    /// ATTR_CMNEXT_LINKID straight from getattrlist(2), independent of CFSKit.
    private func linkID(_ url: URL) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_LINKID)
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes {
            getattrlist(url.path(percentEncoded: false), &list, $0.baseAddress, $0.count,
                        UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
        }
        guard rc == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }

    func testEveryFieldMatchesLstatAndGetattrlist() async throws {
        let (entries, summary, _) = try await readAll(golden)
        XCTAssertEqual(Set(entries.keys), Set(GoldenName.all))
        XCTAssertEqual(summary.entryCount, GoldenName.all.count)
        XCTAssertEqual(summary.degradedCount, 0)
        XCTAssertFalse(summary.usedFallback)
        for (name, (e, errno)) in entries {
            let url = golden.appending(path: name)
            var st = stat()
            XCTAssertEqual(lstat(url.path(percentEncoded: false), &st), 0, name)
            XCTAssertNil(errno, name)
            XCTAssertEqual(e.fileID, UInt64(st.st_ino), name)
            XCTAssertEqual(e.rowID, linkID(url), name)
            XCTAssertEqual(e.mtime, Self.ns(st.st_mtimespec), name)
            XCTAssertEqual(e.ctime, Self.ns(st.st_birthtimespec), name)
            XCTAssertEqual(e.flags.contains(.bsdHidden), st.st_flags & UInt32(UF_HIDDEN) != 0, name)
            XCTAssertEqual(e.flags.contains(.locked), st.st_flags & UInt32(UF_IMMUTABLE) != 0, name)
            XCTAssertEqual(e.flags.contains(.dotName), name.hasPrefix("."), name)
            XCTAssertEqual(e.flags.contains(.readable), access(url.path(percentEncoded: false), R_OK) == 0 || (st.st_mode & S_IFMT) == S_IFLNK, name)
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                XCTAssertTrue(e.kind == .directory || e.kind == .package, name)
                if access(url.path(percentEncoded: false), R_OK) == 0 {
                    let children = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
                    XCTAssertEqual(e.size, Int64(children.count), "\(name): directory size = entry count")
                }
            case S_IFLNK:
                XCTAssertEqual(e.kind, .symlink, name)
                XCTAssertEqual(e.typeIndex, TypeRegistry.symlinkIndex, name)
                XCTAssertEqual(e.size, Int64(st.st_size), name)
            default:
                XCTAssertTrue(e.kind == .file || e.kind == .alias, name)
                XCTAssertEqual(e.size, Int64(st.st_size), name)
                XCTAssertEqual(e.allocSize, Int64(st.st_blocks) * 512, name)
            }
        }
        let k = { (n: String) in entries[n]!.0 }
        XCTAssertEqual(k(GoldenName.app).kind, .package)
        XCTAssertEqual(k(GoldenName.rtfd).kind, .package)
        XCTAssertEqual(k(GoldenName.dottedFolder).kind, .directory)
        XCTAssertEqual(k(GoldenName.folder).kind, .directory)
        XCTAssertEqual(k(GoldenName.alias).kind, .alias)
        XCTAssertTrue(k(GoldenName.extensionHidden).flags.contains(.extensionHidden))
        XCTAssertTrue(k(GoldenName.executable).flags.contains(.executable))
        XCTAssertFalse(k(GoldenName.plain).flags.contains(.executable))
        XCTAssertFalse(k(GoldenName.readOnly).flags.contains(.writable))
        XCTAssertFalse(k(GoldenName.noAccessFile).flags.contains(.readable))
        XCTAssertTrue(k(GoldenName.hardLinkA).flags.contains(.hasHardLinks))
        XCTAssertNotEqual(k(GoldenName.hardLinkA).rowID, k(GoldenName.hardLinkB).rowID)
        XCTAssertEqual(k(GoldenName.hardLinkA).fileID, k(GoldenName.hardLinkB).fileID)
        XCTAssertEqual(k(GoldenName.long255).nameLen, 255)
        XCTAssertEqual(k(GoldenName.dated).mtime, 1_012_608_000 * 1_000_000_000)
        XCTAssertEqual(TypeRegistry.shared.type(at: k(GoldenName.plain).typeIndex), .plainText)
        XCTAssertTrue(entries.keys.contains { Array($0.unicodeScalars) == Array(GoldenName.nfd.unicodeScalars) },
                      "NFD bytes are delivered as stored")
    }

    func testDirectoriesOnlyListsFoldersNotPackagesOrLinks() async throws {
        var options = ReadOptions()
        options.directoriesOnly = true
        let names = Set(try await readAll(golden, options: options).entries.keys)
        XCTAssertEqual(names, [GoldenName.folder, GoldenName.dottedFolder, GoldenName.noAccessDir])
    }

    func testNoMaterializationReadGivesSameEntries() async throws {
        var options = ReadOptions()
        options.noMaterialization = true
        let a = try await readAll(golden).entries.mapValues { $0.0 }
        let b = try await readAll(golden, options: options).entries.mapValues { $0.0 }
        XCTAssertEqual(a, b)
    }

    func testDirectoryLevelFailures() async throws {
        let cases: [(URL, Int32)] = [
            (golden.appending(path: "missing"), ENOENT),
            (golden.appending(path: GoldenName.plain), ENOTDIR),
            (golden.appending(path: GoldenName.noAccessDir), EACCES),
        ]
        for (url, code) in cases {
            do {
                _ = try await readAll(url)
                XCTFail("\(url.lastPathComponent) should fail")
            } catch let failure as ReadFailure {
                XCTAssertEqual(failure, ReadFailure(code: code, stage: .open), url.lastPathComponent)
            }
        }
    }

    func testEmptyDirectoryCompletesWithoutBatches() async throws {
        let dir = try sandbox.createDirectory("empty")
        let (entries, summary, batches) = try await readAll(dir)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(summary.entryCount, 0)
        XCTAssertEqual(batches, [])
    }

    func testDegradedRecordKeepsRowAndErrno() {
        var builder = RecordBuilder()
        builder.add(.init(name: "half", error: UInt32(EIO), objType: 1, crtime: nil, mtime: nil, finderFlags: nil,
                          flags: nil, userAccess: nil, fileID: nil, allocSize: nil, dataLength: nil, linkID: nil))
        builder.add(.init(name: "whole"))
        var batch = Batch(generation: .initial)
        var converter = RecordConverter(types: TypeRegistry())
        builder.bytes.withUnsafeBytes { raw in
            var c = cfsk_cursor(); var r = cfsk_record()
            cfsk_cursor_init(&c, raw.baseAddress, raw.count, builder.count)
            while cfsk_cursor_next(&c, &r) == CFSK_NEXT_OK { _ = converter.append(r, to: &batch, directoriesOnly: false) }
        }
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.name(at: 0), "half")
        XCTAssertTrue(batch.entries[0].flags.contains(.degraded))
        XCTAssertEqual(batch.errors, [EntryError(index: 0, code: EIO)])
        XCTAssertFalse(batch.entries[1].flags.contains(.degraded))
    }

    func testDatalessAndCustomIconFlagsFromSyntheticRecords() {
        var builder = RecordBuilder()
        builder.add(.init(name: "cloud.pdf", finderFlags: 0x0400, flags: UInt32(bitPattern: SF_DATALESS)))
        var batch = Batch(generation: .initial)
        var converter = RecordConverter(types: TypeRegistry())
        builder.bytes.withUnsafeBytes { raw in
            var c = cfsk_cursor(); var r = cfsk_record()
            cfsk_cursor_init(&c, raw.baseAddress, raw.count, builder.count)
            XCTAssertEqual(cfsk_cursor_next(&c, &r), CFSK_NEXT_OK)
            _ = converter.append(r, to: &batch, directoriesOnly: false)
        }
        XCTAssertTrue(batch.entries[0].flags.contains(.dataless))
        XCTAssertTrue(batch.entries[0].flags.contains(.customIcon))
    }
}
```

- [ ] **Step 3: Write the failing parity and DirectoryReader tests**

Create `Tests/FSKitTests/ReaderParityTests.swift`:

```swift
import Foundation
import MacxFixtures
import MacxFS
import XCTest

final class ReaderParityTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func assertParity(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        var fallback = ReadOptions()
        fallback.forceFallback = true
        let bulk = try await readAll(dir)
        let slow = try await readAll(dir, options: fallback)
        XCTAssertFalse(bulk.summary.usedFallback, file: file, line: line)
        XCTAssertTrue(slow.summary.usedFallback, file: file, line: line)
        XCTAssertEqual(Set(bulk.entries.keys), Set(slow.entries.keys), file: file, line: line)
        for (name, (a, _)) in bulk.entries {
            var b = try XCTUnwrap(slow.entries[name]?.0, name, file: file, line: line)
            b.nameOffset = a.nameOffset   // arena positions depend on readdir order
            XCTAssertEqual(a, b, name, file: file, line: line)
        }
    }

    func testFallbackMatchesBulkOnGoldenTree() async throws {
        try await assertParity(try FixtureTree.golden(in: sandbox))
    }

    func testFallbackMatchesBulkOnFlatFolderAcrossBatches() async throws {
        try await assertParity(try FixtureTree.flat(in: sandbox, at: "flat", count: 5_000, directoriesEvery: 7))
    }

    func testFallbackMatchesBulkOnHFSImage() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let image = try DiskImage.create(in: sandbox, format: .hfsPlus, sizeMB: 16)
        defer { try? image.detach() }
        _ = try FixtureTree.golden(in: sandbox, at: image.relativeMountPath + "/golden")
        try await assertParity(image.mountPoint.appending(path: "golden"))
    }
}
```

Create `Tests/FSKitTests/DirectoryReaderTests.swift`:

```swift
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import XCTest

private let vol = VolumeID(raw: "mnt:/reader-tests")
private let fastLanes = WatchdogConfig(stallTimeout: .milliseconds(200), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 4)

final class DirectoryReaderTests: XCTestCase {
    private var sandbox: Sandbox!
    private var gates: [Gate] = []

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    override func tearDown() {
        for g in gates { g.open(count: 8) }
        super.tearDown()
    }

    func testStreamsBatchesOfAtMost2000ThenCompletes() async throws {
        let dir = try FixtureTree.flat(in: sandbox, at: "flat", count: 10_000)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes))
        let gen = Generation.initial.next()
        let (batches, others) = await collect(await reader.read(dir, generation: gen))
        XCTAssertEqual(batches.reduce(0) { $0 + $1.count }, 10_000)
        XCTAssertGreaterThanOrEqual(batches.count, 5)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 2_000 && $0.generation == gen })
        XCTAssertEqual(others, ["completed:10000"])
        let names = Set(batches.flatMap { b in (0..<b.count).map { b.name(at: $0) } })
        XCTAssertEqual(names.count, 10_000)
    }

    func testBatchIntervalFlushesSmallBatches() {
        var clock: UInt64 = 0
        var acc = BatchAccumulator(batchSize: 2_000, interval: .milliseconds(8), now: { clock })
        XCTAssertFalse(acc.shouldFlush(count: 10))
        clock += 7_000_000
        XCTAssertFalse(acc.shouldFlush(count: 500))
        clock += 1_000_000
        XCTAssertTrue(acc.shouldFlush(count: 501), "8 ms elapsed")
        XCTAssertTrue(acc.shouldFlush(count: 2_000), "size limit")
        XCTAssertFalse(acc.shouldFlush(count: 0))
    }

    func testFailureIsReportedOnTheStream() async throws {
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes))
        let (batches, others) = await collect(await reader.read(sandbox.url("missing"), generation: .initial))
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(others, ["failed:\(ENOENT):open"])
    }

    func testStoppingIterationCancelsTheLaneWork() async throws {
        let calls = Recorder<Int>()
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes), types: .shared) { _, gen, _, _, ctx, emit in
            var n = 0
            while !ctx.isCancelled {
                n += 1
                calls.append(n)
                ctx.heartbeat()
                if !emit(Batch(generation: gen)) { break }
                usleep(2_000)
            }
            return ReadSummary(entryCount: n, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        for await event in await reader.read(URL(filePath: "/unused"), generation: .initial) {
            if case .batch = event { break }        // consumer navigates away after the first batch
        }
        let idle = await eventually { await reader.inFlightCount == 0 }
        XCTAssertTrue(idle, "the lane work stopped")
        let count = calls.values.count
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.values.count, count, "no more work after cancellation")
    }

    func testHungReadReportsStalledThenResumed() async throws {
        let gate = Gate(); gates.append(gate)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes), types: .shared) { _, gen, _, _, _, emit in
            gate.wait()                              // hung network volume
            _ = emit(Batch(generation: gen))
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        let stream = await reader.read(URL(filePath: "/unused"), generation: .initial)
        var events: [String] = []
        for await event in stream {
            switch event {
            case .stalled: events.append("stalled"); gate.open()
            case .resumed: events.append("resumed")
            case .batch: events.append("batch")
            case .completed: events.append("completed")
            default: events.append("other")
            }
        }
        XCTAssertEqual(events, ["stalled", "batch", "resumed", "completed"])
    }

    func testPermissionPendingReportsWaitingNotStalled() async throws {
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes), types: .shared) { _, _, _, _, _, _ in
            usleep(400_000)                          // TCC prompt showing
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        var options = ReadOptions()
        options.permissionPending = true
        let (_, others) = await collect(await reader.read(URL(filePath: "/unused"), generation: .initial, options: options))
        XCTAssertEqual(others, ["waiting", "resumed", "completed:0"])
    }

    func testUnresponsiveVolumeFailsReadsImmediately() async throws {
        let gate = Gate(); gates.append(gate)
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(150), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 1))
        let reader = DirectoryReader(volume: vol, lanes: lanes, types: .shared) { _, _, _, _, _, _ in
            gate.wait()
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        let first = Task { await collect(await reader.read(URL(filePath: "/a"), generation: .initial)) }
        _ = await eventually { await lanes.health(of: vol) == .unresponsive }
        let (_, others) = await collect(await reader.read(URL(filePath: "/b"), generation: .initial.next()))
        XCTAssertEqual(others, ["failed:\(ETIMEDOUT):unresponsiveVolume"])
        gate.open()
        _ = await first.value
    }

    func testStaleGenerationResultsCanBeDiscardedByTheConsumer() async throws {
        // §9 lane test: Retry gets a fresh lane; the late result of the old generation arrives tagged with it.
        let dir = try FixtureTree.flat(in: sandbox, at: "three", count: 3)
        let gate = Gate(); gates.append(gate)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes), types: .shared) { url, gen, options, types, ctx, emit in
            if gen == Generation.initial.next() { gate.wait() }    // first attempt hangs
            return try BulkReader.read(url, generation: gen, options: options, types: types, context: ctx, emit: emit)
        }
        let g1 = Generation.initial.next(), g2 = g1.next()
        let late = Task { await collect(await reader.read(dir, generation: g1)) }
        try await Task.sleep(for: .milliseconds(300))              // g1 is poisoned by now
        let fresh = await collect(await reader.read(dir, generation: g2))
        XCTAssertEqual(fresh.batches.map(\.generation), [g2])
        gate.open()
        let old = await late.value
        XCTAssertEqual(old.batches.map(\.generation), [g1])
        var current = g2
        let applied = (old.batches + fresh.batches).filter { $0.generation == current }
        XCTAssertEqual(applied.reduce(0) { $0 + $1.count }, 3)
        current = g2
    }

    func testCancelAllWaitsAtMostOneSecond() async throws {
        let gate = Gate(); gates.append(gate)
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: WatchdogConfig(stallTimeout: .seconds(30))), types: .shared) { _, _, _, _, _, _ in
            gate.wait()
            return ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        let stream = await reader.read(URL(filePath: "/hung"), generation: .initial)
        let consumer = Task { await collect(stream) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        await reader.cancelAll()
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(1_500))
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(900), "a hung read keeps cancelAll waiting the full second")
        gate.open()
        _ = await consumer.value
    }

    func testReadItemsReportsPresentAndMissing() async throws {
        let dir = try sandbox.createDirectory("items")
        try sandbox.createFile("items/a.txt")
        try sandbox.createSymlink("items/link", target: "nowhere")
        let reader = DirectoryReader(volume: vol, lanes: LanePool(config: fastLanes))
        let result = try await reader.readItems(["a.txt", "gone.txt", "link"], in: dir, generation: .initial)
        XCTAssertEqual((0..<result.batch.count).map { result.batch.name(at: $0) }, ["a.txt", "link"])
        XCTAssertEqual(result.batch.entries[1].kind, .symlink, "never follows symlinks")
        XCTAssertEqual(result.missing, ["gone.txt"])
    }
}
```

- [ ] **Step 4: Run to verify failure**

Run: `swift test --filter "FSKitTests.(ReaderGoldenTests|ReaderParityTests|DirectoryReaderTests)" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'BulkReader' in scope` (and similar).

- [ ] **Step 5: Implement read types and the record converter**

Create `Sources/FSKit/Reader/ReadTypes.swift`:

```swift
public struct ReadOptions: Sendable, Hashable {
    public var directoriesOnly: Bool = false       // tree children
    public var noMaterialization: Bool = false     // background/tree re-reads (§4.2 list)
    public var permissionPending: Bool = false     // → StallPolicy.awaitingPermission
    public var forceFallback: Bool = false         // tests: readdir + fstatat path
    public var batchSize: Int = 2_000
    public var batchInterval: Duration = .milliseconds(8)
    public var bufferSize: Int = 256 * 1024
    public init() {}
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
    public init(entryCount: Int, degradedCount: Int, usedFallback: Bool, elapsed: Duration) {
        self.entryCount = entryCount
        self.degradedCount = degradedCount
        self.usedFallback = usedFallback
        self.elapsed = elapsed
    }
}

public struct ReadFailure: Error, Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case open, read, unresponsiveVolume }
    public var code: Int32        // errno (ENOENT, ENOTDIR, EACCES, EPERM, ENXIO, ...)
    public var stage: Stage
    public init(code: Int32, stage: Stage) { self.code = code; self.stage = stage }
}

/// Batching policy: flush at `batchSize` entries or when `interval` has passed since the last flush.
struct BatchAccumulator {
    let batchSize: Int
    let intervalNanos: UInt64
    let now: () -> UInt64
    private var lastFlush: UInt64

    init(batchSize: Int, interval: Duration, now: @escaping () -> UInt64 = { LaneJob.now() }) {
        self.batchSize = max(1, batchSize)
        let c = interval.components
        self.intervalNanos = UInt64(c.seconds) * 1_000_000_000 + UInt64(c.attoseconds / 1_000_000_000)
        self.now = now
        self.lastFlush = now()
    }

    mutating func shouldFlush(count: Int) -> Bool {
        guard count > 0 else { return false }
        if count >= batchSize || now() &- lastFlush >= intervalNanos {
            lastFlush = now()
            return true
        }
        return false
    }
}
```

Create `Sources/FSKit/Reader/RecordConverter.swift`. Kind: `VDIR` → `.package` if the type registry says package, else `.directory`; `VLNK` → `.symlink` (type `symlinkIndex`); `VREG` → `.alias` when Finder `kIsAlias` is set, else `.file`; anything else `.other`. `rowID` = `ATTR_CMNEXT_LINKID` if present and non-zero, else `fileID`. Missing Finder info (getattrlist omits all-zero Finder info; FAT omits it entirely) is zero, not degraded; missing `OBJTYPE`/`FILEID` or a non-zero `ATTR_CMN_ERROR` marks the row `.degraded` and records errno in `Batch.errors`.

```swift
import CFSKit
import Darwin

/// cfsk_record → Entry (§4.2): kind, flags, type index, identity. Shared by bulk, fallback and item reads.
struct RecordConverter {
    // Finder flags (big-endian on disk; cfsk delivers host order).
    static let kIsAlias: UInt16 = 0x8000
    static let kHasCustomIcon: UInt16 = 0x0400
    static let kIsExtensionHidden: UInt16 = 0x0010
    static let VREG: UInt32 = 1, VDIR: UInt32 = 2, VLNK: UInt32 = 5

    let types: TypeRegistry
    private var cache: [String: UInt16] = [:]   // "<d|f><ext>" → index; avoids the registry lock per entry

    init(types: TypeRegistry) { self.types = types }

    /// Appends the record to `batch`. Returns false if it has no name (dropped).
    mutating func append(_ r: cfsk_record, to batch: inout Batch, directoriesOnly: Bool) -> (appended: Bool, degraded: Bool) {
        guard r.fields & CFSK_HAS_NAME != 0, let namePtr = r.name, r.name_len > 0 else { return (false, false) }
        let name = UnsafeBufferPointer(start: UnsafeRawPointer(namePtr).assumingMemoryBound(to: UInt8.self), count: Int(r.name_len))
        let has = { (bit: UInt32) in r.fields & bit != 0 }
        let isDir = has(CFSK_HAS_OBJTYPE) && r.obj_type == Self.VDIR
        if directoriesOnly && !isDir { return (false, false) }   // cheap pre-filter; packages dropped below

        var flags: EntryFlags = []
        if name.first == UInt8(ascii: ".") { flags.insert(.dotName) }
        if has(CFSK_HAS_FLAGS) {
            if r.bsd_flags & UInt32(UF_HIDDEN) != 0 { flags.insert(.bsdHidden) }
            if r.bsd_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { flags.insert(.locked) }
            if r.bsd_flags & UInt32(bitPattern: SF_DATALESS) != 0 { flags.insert(.dataless) }
        }
        let finder = has(CFSK_HAS_FNDRINFO) ? r.finder_flags : 0
        if finder & Self.kHasCustomIcon != 0 { flags.insert(.customIcon) }
        if finder & Self.kIsExtensionHidden != 0 { flags.insert(.extensionHidden) }
        if has(CFSK_HAS_ACCESSMASK) {
            if r.access_mask & UInt32(R_OK) != 0 { flags.insert(.readable) }
            if r.access_mask & UInt32(W_OK) != 0 { flags.insert(.writable) }
            if r.access_mask & UInt32(X_OK) != 0 && has(CFSK_HAS_OBJTYPE) && r.obj_type == Self.VREG { flags.insert(.executable) }
        }
        let degraded = r.error != 0 || !has(CFSK_HAS_OBJTYPE) || !has(CFSK_HAS_FILEID)
        if degraded { flags.insert(.degraded) }
        if has(CFSK_HAS_LINKID) && has(CFSK_HAS_FILEID) && r.link_id != r.file_id { flags.insert(.hasHardLinks) }

        var kind: Kind
        var typeIndex: UInt16
        switch has(CFSK_HAS_OBJTYPE) ? r.obj_type : 0 {
        case Self.VDIR:
            typeIndex = typeIndexFor(name, isDirectory: true)
            kind = types.isPackage(typeIndex) ? .package : .directory
        case Self.VLNK:
            kind = .symlink
            typeIndex = TypeRegistry.symlinkIndex
        case Self.VREG:
            kind = finder & Self.kIsAlias != 0 ? .alias : .file
            typeIndex = typeIndexFor(name, isDirectory: false)
        default:
            kind = .other
            typeIndex = TypeRegistry.dataIndex
        }
        if directoriesOnly && kind != .directory { return (false, false) }
        let fileID = has(CFSK_HAS_FILEID) ? r.file_id : 0
        let rowID = has(CFSK_HAS_LINKID) && r.link_id != 0 ? r.link_id : fileID
        let size: Int64 = isDir ? Int64(r.entry_count) : (has(CFSK_HAS_DATALENGTH) ? r.data_length : 0)
        let entry = Entry(rowID: rowID, fileID: fileID, size: size,
                          allocSize: has(CFSK_HAS_ALLOCSIZE) ? r.alloc_size : 0,
                          mtime: has(CFSK_HAS_MODTIME) ? r.mtime_ns : 0,
                          ctime: has(CFSK_HAS_CRTIME) ? r.crtime_ns : 0,
                          nameOffset: 0, nameLen: 0, kind: kind, flags: flags, typeIndex: typeIndex)
        batch.append(entry, nameBytes: name)
        if r.error != 0 { batch.errors.append(EntryError(index: UInt32(batch.count - 1), code: Int32(bitPattern: r.error))) }
        return (true, degraded)
    }

    private mutating func typeIndexFor(_ name: UnsafeBufferPointer<UInt8>, isDirectory: Bool) -> UInt16 {
        guard let range = fileExtensionRange(name) else { return isDirectory ? TypeRegistry.folderIndex : TypeRegistry.dataIndex }
        let ext = String(decoding: UnsafeBufferPointer(rebasing: name[range]), as: UTF8.self)
        let key = (isDirectory ? "d" : "f") + ext
        if let hit = cache[key] { return hit }
        let index = types.index(forExtension: Substring(ext), isDirectory: isDirectory)
        cache[key] = index
        return index
    }
}
```

- [ ] **Step 6: Implement BulkReader and FallbackReader**

Create `Sources/FSKit/Reader/BulkReader.swift`. It heartbeats after every syscall and every emitted batch, checks `context.isCancelled` at batch boundaries, and switches to `FallbackReader` when the very first `getattrlistbulk` call fails with `ENOTSUP`/`EINVAL`. The `noMaterialization` wrapper converts to `Result` instead of passing a typed-throws closure (toolchain hazard).

```swift
import CFSKit
import Darwin
import Foundation

func openDirectory(_ directory: URL) throws(ReadFailure) -> Int32 {
    let fd = open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw ReadFailure(code: errno, stage: .open) }
    return fd
}

public enum BulkReader {
    /// Reads `directory`, calling `emit` per batch (size/interval from options). Throws ReadFailure.
    /// Returns false from `emit` to stop early. Falls back to FallbackReader on ENOTSUP/EINVAL.
    public static func read(_ directory: URL, generation: Generation, options: ReadOptions,
                            types: TypeRegistry, context: LaneContext,
                            emit: (Batch) -> Bool) throws(ReadFailure) -> ReadSummary {
        assertOffMain()
        if options.forceFallback {
            return try FallbackReader.read(directory, generation: generation, options: options, types: types, context: context, emit: emit)
        }
        if options.noMaterialization {
            var inner = options
            inner.noMaterialization = false
            // Result instead of a throwing closure: no typed-throws closure conversion (see DirectoryReader).
            let result: Result<ReadSummary, ReadFailure> = withNoMaterialization {
                do throws(ReadFailure) { return .success(try read(directory, generation: generation, options: inner, types: types, context: context, emit: emit)) }
                catch { return .failure(error) }
            }
            return try result.get()
        }
        let start = ContinuousClock.now
        let fd = try openDirectory(directory)
        defer { close(fd) }
        let size = max(options.bufferSize, 4096)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var converter = RecordConverter(types: types)
        var accumulator = BatchAccumulator(batchSize: options.batchSize, interval: options.batchInterval)
        var batch = Batch(generation: generation)
        var total = 0, degraded = 0
        var stopped = false

        reading: while !stopped {
            let n = cfsk_bulk_read(fd, buffer, size)
            context.heartbeat()
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                if (code == ENOTSUP || code == EINVAL) && total == 0 && batch.count == 0 {
                    return try FallbackReader.read(directory, generation: generation, options: options, types: types, context: context, emit: emit)
                }
                throw ReadFailure(code: code, stage: .read)
            }
            if n == 0 { break }
            var cursor = cfsk_cursor()
            cfsk_cursor_init(&cursor, buffer, size, UInt32(n))
            var record = cfsk_record()
            while true {
                let rc = cfsk_cursor_next(&cursor, &record)
                if rc == CFSK_NEXT_END || rc == CFSK_NEXT_TRUNCATED { break }
                if rc == CFSK_NEXT_DROPPED { continue }
                let r = converter.append(record, to: &batch, directoriesOnly: options.directoriesOnly)
                if r.appended { total += 1 }
                if r.degraded { degraded += 1 }
                if accumulator.shouldFlush(count: batch.count) {
                    if context.isCancelled || !emit(batch) { stopped = true; break reading }
                    batch = Batch(generation: generation)
                    context.heartbeat()
                }
            }
            if context.isCancelled { stopped = true }
        }
        if !stopped && batch.count > 0 { _ = emit(batch) }
        return ReadSummary(entryCount: total, degradedCount: degraded, usedFallback: false, elapsed: ContinuousClock.now - start)
    }
}
```

Create `Sources/FSKit/Reader/FallbackReader.swift` (`readdir` on a `dup`ed fd + `cfsk_stat_at` per name; an entry that vanished between `readdir` and stat is skipped; any other stat error keeps a degraded row with the `d_type` kind):

```swift
import CFSKit
import Darwin
import Foundation

public enum FallbackReader {
    public static func read(_ directory: URL, generation: Generation, options: ReadOptions,
                            types: TypeRegistry, context: LaneContext,
                            emit: (Batch) -> Bool) throws(ReadFailure) -> ReadSummary {
        assertOffMain()
        let start = ContinuousClock.now
        let fd = try openDirectory(directory)
        let listFD = dup(fd)
        defer { close(fd) }
        guard listFD >= 0, let dir = fdopendir(listFD) else { throw ReadFailure(code: errno, stage: .open) }
        defer { closedir(dir) }
        var converter = RecordConverter(types: types)
        var accumulator = BatchAccumulator(batchSize: options.batchSize, interval: options.batchInterval)
        var batch = Batch(generation: generation)
        var buffer = [UInt8](repeating: 0, count: 2048)
        var total = 0, degraded = 0, stopped = false
        while true {
            errno = 0
            guard let dent = readdir(dir) else {
                if errno != 0 { throw ReadFailure(code: errno, stage: .read) }
                break
            }
            let name = withUnsafeBytes(of: dent.pointee.d_name) { raw in
                Array(raw.prefix(Int(dent.pointee.d_namlen)).bindMemory(to: UInt8.self))
            }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            var record = cfsk_record()
            let rc = name.withUnsafeBufferPointer { nb -> Int32 in
                let cName = String(decoding: nb, as: UTF8.self)
                return buffer.withUnsafeMutableBytes { cfsk_stat_at(fd, cName, $0.baseAddress, $0.count, &record) }
            }
            if rc != 0 {
                let code = errno
                if code == ENOENT { continue }      // vanished between readdir and stat
                // Degraded row: name + d_type only, errno in the side table (§4.2 rule 3).
                var fake = cfsk_record()
                fake.fields = CFSK_HAS_NAME | CFSK_HAS_ERROR | CFSK_HAS_OBJTYPE
                fake.error = UInt32(bitPattern: code)
                fake.obj_type = dent.pointee.d_type == DT_DIR ? RecordConverter.VDIR : dent.pointee.d_type == DT_LNK ? RecordConverter.VLNK : RecordConverter.VREG
                fake.name_len = UInt32(name.count)
                let r = name.withUnsafeBufferPointer { nb -> (appended: Bool, degraded: Bool) in
                    fake.name = UnsafeRawPointer(nb.baseAddress!).assumingMemoryBound(to: CChar.self)
                    return converter.append(fake, to: &batch, directoriesOnly: options.directoriesOnly)
                }
                if r.appended { total += 1; degraded += 1 }
            } else {
                // record.name points into `buffer`; still valid here.
                let r = buffer.withUnsafeBytes { _ in converter.append(record, to: &batch, directoriesOnly: options.directoriesOnly) }
                if r.appended { total += 1 }
                if r.degraded { degraded += 1 }
            }
            if accumulator.shouldFlush(count: batch.count) {
                context.heartbeat()
                if context.isCancelled || !emit(batch) { stopped = true; break }
                batch = Batch(generation: generation)
            }
        }
        if !stopped && batch.count > 0 { _ = emit(batch) }
        return ReadSummary(entryCount: total, degradedCount: degraded, usedFallback: true, elapsed: ContinuousClock.now - start)
    }
}
```

- [ ] **Step 7: Implement ItemReader and DirectoryReader**

Create `Sources/FSKit/Reader/ItemReader.swift`:

```swift
import CFSKit
import Darwin
import Foundation

public struct ItemReadResult: Sendable {
    public var batch: Batch          // entries for names that exist
    public var missing: [String]     // names that no longer exist
}

public enum ItemReader {
    /// Stats each name in `directory` without following symlinks (watcher incremental path, §4.3).
    public static func read(names: [String], in directory: URL, generation: Generation, types: TypeRegistry) -> ItemReadResult {
        assertOffMain()
        var result = ItemReadResult(batch: Batch(generation: generation), missing: [])
        guard let fd = try? openDirectory(directory) else {
            result.missing = names
            return result
        }
        defer { close(fd) }
        var converter = RecordConverter(types: types)
        var buffer = [UInt8](repeating: 0, count: 2048)
        for name in names {
            var record = cfsk_record()
            let rc = buffer.withUnsafeMutableBytes { cfsk_stat_at(fd, name, $0.baseAddress, $0.count, &record) }
            if rc != 0 {
                result.missing.append(name)   // ENOENT (and anything else unreadable): treat as gone
                continue
            }
            _ = buffer.withUnsafeBytes { _ in converter.append(record, to: &result.batch, directoriesOnly: false) }
        }
        return result
    }
}
```

Create `Sources/FSKit/Reader/DirectoryReader.swift`. Each read is a `Task` (actor-isolated) that awaits `lanes.perform`; `continuation.onTermination` cancels it, which flips `LaneContext.isCancelled` so the reader stops at the next batch. `cancelAll()` cancels every in-flight task and waits until they finish or 1 s passes (a hung read cannot make it wait longer). Each read is wrapped in a `PerfSignposts.enumerate` interval.

```swift
import Darwin
import Foundation

/// Lane-side read function; BulkReader.read in production, a fake in tests (@testable init).
/// Untyped `throws` on purpose: converting a typed-throws closure to LanePool's `throws` work closure
/// produced corrupted error payloads with Swift 6.4 (verified 2026-11-02). Throw only ReadFailure.
typealias ReadImplementation = @Sendable (URL, Generation, ReadOptions, TypeRegistry, LaneContext, (Batch) -> Bool) throws -> ReadSummary

/// One per volume (§4.2). Holds only coordination state; every blocking call runs on that volume's read lanes.
public actor DirectoryReader {
    public nonisolated let volume: VolumeID
    private let lanes: LanePool
    private let types: TypeRegistry
    private let implementation: ReadImplementation
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(volume: VolumeID, lanes: LanePool, types: TypeRegistry = .shared) {
        self.init(volume: volume, lanes: lanes, types: types) { dir, gen, options, types, ctx, emit in
            try BulkReader.read(dir, generation: gen, options: options, types: types, context: ctx, emit: emit)
        }
    }

    init(volume: VolumeID, lanes: LanePool, types: TypeRegistry, implementation: @escaping ReadImplementation) {
        self.volume = volume
        self.lanes = lanes
        self.types = types
        self.implementation = implementation
    }

    /// Test seam: reads currently running.
    var inFlightCount: Int { inFlight.count }

    /// One stream per read; ends after .completed or .failed (or when the consumer cancels iteration,
    /// which cancels the lane work at the next batch boundary).
    public func read(_ directory: URL, generation: Generation, options: ReadOptions = ReadOptions()) -> AsyncStream<ReadEvent> {
        let (stream, continuation) = AsyncStream<ReadEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let lanes = self.lanes, types = self.types, implementation = self.implementation, volume = self.volume
        let signpost = PerfSignposts.signposter.beginInterval(PerfSignposts.enumerate)
        let task = Task {
            let policy: StallPolicy = options.permissionPending ? .awaitingPermission : .poison
            do {
                let summary = try await lanes.perform(on: volume, .read, stallPolicy: policy, onStall: { notice in
                    switch notice {
                    case .stalled: continuation.yield(.stalled)
                    case .waitingForPermission: continuation.yield(.waitingForPermission)
                    case .resumed: continuation.yield(.resumed)
                    }
                }) { ctx -> ReadSummary in
                    try implementation(directory, generation, options, types, ctx) { batch in
                        if ctx.isCancelled { return false }
                        continuation.yield(.batch(batch))
                        return true
                    }
                }
                continuation.yield(.completed(summary))
            } catch let failure as ReadFailure {
                continuation.yield(.failed(failure))
            } catch LaneError.volumeUnresponsive {
                continuation.yield(.failed(ReadFailure(code: ETIMEDOUT, stage: .unresponsiveVolume)))
            } catch {
                // LaneError.cancelled: the consumer went away; nothing to report.
            }
            PerfSignposts.signposter.endInterval(PerfSignposts.enumerate, signpost)
            continuation.finish()
            self.finished(id)
        }
        inFlight[id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Single-shot stat of names (watcher incremental path). Runs on a read lane.
    public func readItems(_ names: [String], in directory: URL, generation: Generation) async throws -> ItemReadResult {
        let types = self.types
        return try await lanes.perform(on: volume, .read) { _ in
            ItemReader.read(names: names, in: directory, generation: generation, types: types)
        }
    }

    /// Volumes.release: cancel in-flight reads, wait ≤ 1 s for their fds to close.
    public func cancelAll() async {
        for task in inFlight.values { task.cancel() }
        await waitForIdle(timeout: .seconds(1))
    }

    private func waitForIdle(timeout: Duration) async {
        guard !inFlight.isEmpty else { return }
        let id = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            idleWaiters[id] = c
            Task {
                try? await Task.sleep(for: timeout)
                self.resumeWaiter(id)
            }
        }
    }

    private func resumeWaiter(_ id: UUID) { idleWaiters.removeValue(forKey: id)?.resume() }

    private func finished(_ id: UUID) {
        inFlight[id] = nil
        if inFlight.isEmpty {
            let waiters = idleWaiters.values
            idleWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter "FSKitTests.(ReaderGoldenTests|ReaderParityTests|DirectoryReaderTests)" 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 20 tests, with 0 failures` (~8 s; the HFS+ parity test attaches an image).

- [ ] **Step 9: Build with zero warnings**

Run: `swift build 2>&1 | tail -5`
Expected: last line `Build complete! (…)`, no `warning:` lines above it.

- [ ] **Step 10: Commit**

```bash
git add Sources/FSKit/Reader Tests/FSKitTests/Support/ReadHelpers.swift Tests/FSKitTests/ReaderGoldenTests.swift Tests/FSKitTests/ReaderParityTests.swift Tests/FSKitTests/DirectoryReaderTests.swift
git commit -m "feat: streaming DirectoryReader with bulk and fallback readers (P1-06)"
```

---
## Task P1-07: Sorting: ViewQuery, SortKeyColumn, SortKeys, Sorter, SortCorpus, sort golden

**Spec:** §4.2 SortKeys (CFStringFold case/diacritic/width with a fixed locale, digit runs as length byte + digits without leading zeros up to 255, layout kind byte + folded + 0x00 + NFC, kind key by rank, filter-in-folder search fold, memcmp sort, integer date/size keys with name tie-break, `concurrentPerform`), §4.4 re-sort 100k < 30 ms, §5.2 search field (substring, case/diacritic-insensitive), §5.5 Details (folders always first; folder size `--`), §9 sort golden (~5k corpus vs `localizedStandardCompare`, divergences listed).

**Files:**
- Create: `Sources/FSKit/Sort/ViewQuery.swift`
- Create: `Sources/FSKit/Sort/SortKeyColumn.swift`
- Create: `Sources/FSKit/Sort/SortKeys.swift`
- Create: `Sources/FSKit/Sort/Sorter.swift`
- Create: `Sources/MacxFixtures/SortCorpus.swift`
- Test: `Tests/FSKitTests/Support/SortDivergence.swift`
- Test: `Tests/FSKitTests/SortGoldenTests.swift`
- Test: `Tests/FSKitTests/SorterTests.swift`
- Modify (regenerate): `Tests/FSKitTests/Corpus/sort-allowed-divergences.json` (P1-01 created `[]`)

**Interfaces:**
- Consumes: P1-05 `EntryStore`, `Entry`, `Batch`, `TypeRegistry.kindRanks()`, `fileExtensionRange`; P1-04 `Recorder` (tests).
- Produces: overview §3.5 exactly:

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

Addition (Contract notes 5), for the S2 `FolderWorker` loading path that sorts each new batch then merges it:

```swift
public static func sortedRun(_ store: EntryStore, range: Range<Int>, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                             query: ViewQuery, kindRanks: [UInt16]) -> [UInt32]   // filtered + sorted subset of storage indices
```

Rules other slices rely on: `nameKeys` must cover every storage index (column index == storage index; keep it in step with `EntryStore.remove` via `SortKeyColumn.remove`); `searchKeys: nil` with a non-empty filter folds names on the fly (correct, slower); descending reverses within the folders and files groups; packages sort as files; size sort orders folders by name; ties end on storage index, so every order is total and deterministic.

MacxFixtures addition: `public enum SortCorpus { public static func names(count: Int = 5_000, seed: UInt64 = 0x6D61_6378) -> [String] }`.

- [ ] **Step 1: Add the corpus generator**

Create `Sources/MacxFixtures/SortCorpus.swift` (accented Latin incl. ø/ł/œ/ß/ligatures/fullwidth, Greek, Cyrillic, Han, kana, Hangul, separators, leading zeros, 10–40-digit runs, extensions; SplitMix64 so the list is identical everywhere):

```swift
/// Deterministic ~5k-name corpus for the §9 sort golden test (no file system involved).
public enum SortCorpus {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let latin = ["report", "Report", "résumé", "Resume", "café", "Cafe", "naïve", "Zoë", "Ångström", "über",
                        "Über", "straße", "Strasse", "façade", "élan", "Élan", "año", "Ano", "crème", "œuvre",
                        "ﬁle", "ｆｕｌｌ", "photo", "Photo", "notes", "zebra", "apple", "Apple", "Øresund", "łódź"]
    static let greek = ["αλφα", "Βήτα", "γάμμα", "Δέλτα", "έψιλον", "ζήτα", "ήτα", "Θήτα"]
    static let cyrillic = ["альфа", "Бета", "гамма", "Дельта", "ёлка", "Елка", "жук", "Яблоко"]
    static let cjk = ["文件", "资料", "写真", "ファイル", "ふぁいる", "자료", "한글", "日本"]
    static let separators = [" ", "-", "_", ".", " (", "~", ""]
    static let extensions = ["", ".txt", ".pdf", ".JPG", ".tar.gz", ".swift", ".md"]

    /// `count` distinct names; same seed → same list.
    public static func names(count: Int = 5_000, seed: UInt64 = 0x6D61_6378) -> [String] {
        var rng = SplitMix64(state: seed)
        var seen = Set<[UInt8]>()
        var result: [String] = []
        let words = latin + greek + cyrillic + cjk
        while result.count < count {
            var name = words.randomElement(using: &rng)!
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: name += separators.randomElement(using: &rng)! + String(Int.random(in: 0...120, using: &rng))
            case 1:                                                    // leading zeros
                let n = Int.random(in: 0...99, using: &rng)
                name += " " + String(repeating: "0", count: Int.random(in: 0...3, using: &rng)) + String(n)
            case 2:                                                    // long digit runs (up to 40 digits)
                let len = Int.random(in: 10...40, using: &rng)
                name += (0..<len).map { i in String(i == 0 ? Int.random(in: 1...9, using: &rng) : Int.random(in: 0...9, using: &rng)) }.joined()
            case 3: name = String(Int.random(in: 0...2_000, using: &rng)) + separators.randomElement(using: &rng)! + name
            case 4: name += separators.randomElement(using: &rng)! + words.randomElement(using: &rng)!
            default: break
            }
            name += extensions.randomElement(using: &rng)!
            if seen.insert(Array(name.utf8)).inserted { result.append(name) }
        }
        return result
    }
}
```

- [ ] **Step 2: Add the divergence finder (test support)**

A divergence is an adjacent pair (a, b) of the reference order (`compare(options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering], locale: en_US)`, which is `localizedStandardCompare` with the locale pinned so CI and laptops agree) that our keys order b < a. Checking adjacent pairs is enough: our order equals the reference exactly when no adjacent pair is inverted. Each divergence is classified; an `other` classification fails the test. The categories below were measured on the corpus (570 of 4,999 pairs on macOS 26.7.2: long-digit-run 295, punctuation 152, tie-break 40, non-decomposable-letter 37, kana-variant 36, script-order 9, compatibility-character 1).

Create `Tests/FSKitTests/Support/SortDivergence.swift`:

```swift
import Foundation
import MacxFS

/// Classifies why our byte key orders `a` after `b` although localizedStandardCompare orders a < b.
/// Every category is a documented, accepted consequence of the §4.2 key layout.
enum DivergenceCategory: String, Codable, CaseIterable {
    case tieBreak = "tie-break"                       // folded keys equal: NFC-byte tie-break (A < a) vs ICU tertiary (a < A)
    case longDigitRun = "long-digit-run"              // a digit run > 18 digits: ICU stops comparing numerically
    case punctuation = "punctuation"                  // first difference involves a space/punctuation/symbol/digit-run byte
    case scriptOrder = "script-order"                 // first difference is between letters of different scripts
    case nonDecomposableLetter = "non-decomposable-letter"  // ø, ł, œ, æ, ß…: no diacritic decomposition to fold away
    case kanaVariant = "kana-variant"                 // hiragana vs katakana: ICU equal at primary strength, fold keeps them apart
    case compatibilityCharacter = "compatibility-character"  // ligatures like ﬁ: ICU expands them, the fold does not
    case other = "other"                              // unexplained: the test fails

    var reason: String {
        switch self {
        case .tieBreak: return "Folded keys are equal; the key tie-breaks on unfolded NFC bytes (uppercase before lowercase, more leading zeros first), ICU puts lowercase first."
        case .longDigitRun: return "localizedStandardCompare compares digit runs numerically only while they fit in 64 bits; the key compares runs of up to 255 digits numerically (§4.2 rule 2)."
        case .punctuation: return "ICU orders spaces < punctuation < symbols < digits by collation weight; the key uses folded UTF-8 code-unit order, and digit runs start with a length byte (0x01–0xFF)."
        case .scriptOrder: return "ICU root collation orders scripts (e.g. Hangul before Han); the key uses code-point order."
        case .nonDecomposableLetter: return "Letters such as ø, ł, œ, æ have no canonical decomposition, so CFStringFold keeps them; ICU sorts them next to their base letter."
        case .kanaVariant: return "ICU treats hiragana and katakana as equal at primary strength; CFStringFold has no kana-insensitive option, so the key orders them by code point."
        case .compatibilityCharacter: return "ICU expands compatibility characters (ligatures such as ﬁ) to their letters; CFStringFold with these options does not."
        case .other: return "Unexplained divergence: fix the key or add a category with a reason."
        }
    }

    static func classify(_ a: String, _ b: String) -> DivergenceCategory {
        let fa = SortKeys.nameKey(a, isFolder: false), fb = SortKeys.nameKey(b, isFolder: false)
        if fa.prefix(upTo: fa.firstIndex(of: 0)!) == fb.prefix(upTo: fb.firstIndex(of: 0)!) { return .tieBreak }
        if maxDigitRun(a) > 18 || maxDigitRun(b) > 18 { return .longDigitRun }
        let sa = Array(SortKeys.searchFold(a).unicodeScalarsFromUTF8), sb = Array(SortKeys.searchFold(b).unicodeScalarsFromUTF8)
        var i = 0
        while i < min(sa.count, sb.count) && sa[i] == sb[i] { i += 1 }
        guard i < sa.count && i < sb.count else { return .punctuation }   // one is a prefix: separator/extension decides
        let ca = sa[i], cb = sb[i]
        if String(ca).precomposedStringWithCompatibilityMapping != String(ca)
            || String(cb).precomposedStringWithCompatibilityMapping != String(cb) { return .compatibilityCharacter }
        if !isLetter(ca) || !isLetter(cb) { return .punctuation }
        if block(ca) == 3 && block(cb) == 3 { return .kanaVariant }
        if block(ca) != block(cb) { return .scriptOrder }
        if block(ca) == 0 && (!isASCIILetter(ca) || !isASCIILetter(cb)) { return .nonDecomposableLetter }
        if a.precomposedStringWithCompatibilityMapping != a || b.precomposedStringWithCompatibilityMapping != b {
            return .compatibilityCharacter
        }
        return .other
    }

    private static func maxDigitRun(_ s: String) -> Int {
        var best = 0, run = 0
        for u in s.utf8 { if u >= 48 && u <= 57 { run += 1; best = max(best, run) } else { run = 0 } }
        return best
    }
    private static func isLetter(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic }
    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool { (0x61...0x7A).contains(c.value) || (0x41...0x5A).contains(c.value) }
    /// Coarse script block: 0 Latin, 1 Greek, 2 Cyrillic, 3 kana, 4 Han, 5 Hangul, 6 other.
    private static func block(_ c: Unicode.Scalar) -> Int {
        switch c.value {
        case 0..<0x370: return 0
        case 0x370..<0x400: return 1
        case 0x400..<0x530: return 2
        case 0x3040..<0x3100: return 3
        case 0x4E00..<0xA000: return 4
        case 0xAC00..<0xD7B0: return 5
        default: return 6
        }
    }
}

extension Array where Element == UInt8 {
    var unicodeScalarsFromUTF8: String.UnicodeScalarView { String(decoding: self, as: UTF8.self).unicodeScalars }
}

struct Divergence: Codable, Equatable, Hashable {
    var a: String
    var b: String
    var category: String
}

struct DivergenceFile: Codable, Equatable {
    var comment: String
    var categories: [String: String]
    var divergences: [Divergence]
}

/// Adjacent pairs of the reference order that our keys invert.
func sortDivergences(_ names: [String]) -> [Divergence] {
    let locale = Locale(identifier: "en_US")
    let options: String.CompareOptions = [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering]
    let reference = names.sorted { $0.compare($1, options: options, range: nil, locale: locale) == .orderedAscending }
    let keys = Dictionary(uniqueKeysWithValues: names.map { ($0, SortKeys.nameKey($0, isFolder: false)) })
    var result: [Divergence] = []
    for i in 0..<(reference.count - 1) {
        let a = reference[i], b = reference[i + 1]
        guard a.compare(b, options: options, range: nil, locale: locale) == .orderedAscending else { continue }
        if !keys[a]!.lexicographicallyPrecedes(keys[b]!) {
            result.append(Divergence(a: a, b: b, category: DivergenceCategory.classify(a, b).rawValue))
        }
    }
    return result
}
```

- [ ] **Step 3: Write the failing sort tests**

Create `Tests/FSKitTests/SortGoldenTests.swift`:

```swift
import Foundation
import MacxFixtures
import MacxFS
import XCTest

final class SortGoldenTests: XCTestCase {
    private func less(_ a: String, _ b: String, folderA: Bool = false, folderB: Bool = false) -> Bool {
        SortKeys.nameKey(a, isFolder: folderA).lexicographicallyPrecedes(SortKeys.nameKey(b, isFolder: folderB))
    }

    func testDigitRunsCompareNumerically() {
        XCTAssertTrue(less("file2", "file10"))
        XCTAssertTrue(less("file9.txt", "file10.txt"))
        XCTAssertTrue(less("v1.9", "v1.10"))
        let big = "x" + String(repeating: "9", count: 254), bigger = "x1" + String(repeating: "0", count: 254)
        XCTAssertTrue(less(big, bigger), "254 nines < 1 followed by 254 zeros")
        XCTAssertTrue(less("a0", "a1"))
        XCTAssertTrue(less("a000", "a1"), "an all-zero run keeps one digit and never collides with the 0x00 separator")
        XCTAssertFalse(SortKeys.nameKey("a000", isFolder: false).dropFirst().prefix(3).contains(0))
    }

    func testLeadingZerosTieBreakOnRunLength() {
        XCTAssertTrue(less("a01", "a2"))
        XCTAssertTrue(less("a001", "a01"), "equal values: more leading zeros first (NFC-byte tie-break)")
        XCTAssertTrue(less("a01", "a1"))
        XCTAssertTrue(less("a1b", "a01c"), "the tie-break never overrides a later difference")
    }

    func testFoldingAndNFCTieBreak() {
        XCTAssertTrue(less("e", "\u{E9}"), "e < é")
        XCTAssertTrue(less("\u{E9}", "f"), "é < f")
        XCTAssertTrue(less("\u{E9}a", "eb"), "diacritics ignored before the tie-break")
        XCTAssertEqual(SortKeys.nameKey("Cafe\u{301}", isFolder: false), SortKeys.nameKey("Caf\u{E9}", isFolder: false),
                       "NFD and NFC spellings get identical keys")
        XCTAssertTrue(less("apple", "Banana"))
        XCTAssertTrue(less("ｆｉｌｅ1", "file2"), "width-insensitive")
    }

    func testFoldersFirstByteAndLayout() {
        XCTAssertTrue(less("zzz", "aaa", folderA: true, folderB: false))
        let key = SortKeys.nameKey("Ab1", isFolder: true)
        XCTAssertEqual(key, [0, 0x61, 0x62, 1, 0x31, 0] + Array("Ab1".utf8))
    }

    func testSearchFold() {
        XCTAssertEqual(SortKeys.searchFold("Résumé"), Array("resume".utf8))
        XCTAssertEqual(SortKeys.searchFold("ＡＢＣ"), Array("abc".utf8))
        XCTAssertEqual(SortKeys.searchFold("file10"), Array("file10".utf8), "no digit encoding")
    }

    func testCorpusIsDeterministicAndLarge() {
        let a = SortCorpus.names(), b = SortCorpus.names()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 5_000)
        XCTAssertEqual(Set(a).count, 5_000)
    }

    /// §4.2 / §9 golden: our order vs localizedStandardCompare (en_US) on the corpus. Every adjacent pair of the
    /// reference order that our keys invert must be listed, with its category, in Corpus/sort-allowed-divergences.json.
    /// Re-record after an intentional key change or an OS collation change:
    ///   MACX_RECORD_SORT_DIVERGENCES=1 swift test --filter FSKitTests.SortGoldenTests/testCorpusMatchesLocalizedStandardCompareExceptListed
    func testCorpusMatchesLocalizedStandardCompareExceptListed() throws {
        let actual = sortDivergences(SortCorpus.names())
        XCTAssertFalse(actual.contains { $0.category == DivergenceCategory.other.rawValue },
                       "unexplained: \(actual.filter { $0.category == "other" }.prefix(10))")
        if ProcessInfo.processInfo.environment["MACX_RECORD_SORT_DIVERGENCES"] == "1" {
            let file = DivergenceFile(
                comment: "Generated by SortGoldenTests (record mode). Adjacent pairs (a < b by localizedStandardCompare, en_US) that SortKeys orders b < a.",
                categories: Dictionary(uniqueKeysWithValues: DivergenceCategory.allCases.filter { $0 != .other }.map { ($0.rawValue, $0.reason) }),
                divergences: actual)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let target = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Corpus/sort-allowed-divergences.json")
            try encoder.encode(file).write(to: target)
            throw XCTSkip("recorded \(actual.count) divergences to \(target.path(percentEncoded: false)); review and commit")
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sort-allowed-divergences", withExtension: "json", subdirectory: "Corpus"))
        let listed = try JSONDecoder().decode(DivergenceFile.self, from: Data(contentsOf: url))
        let known = Set(listed.divergences), now = Set(actual)
        XCTAssertEqual(now.subtracting(known).sorted { $0.a < $1.a }.prefix(20), [], "new divergences (not listed)")
        XCTAssertEqual(known.subtracting(now).sorted { $0.a < $1.a }.prefix(20), [], "listed divergences that no longer occur")
        for category in Set(listed.divergences.map(\.category)) {
            XCTAssertNotNil(listed.categories[category], "category \(category) needs a reason")
        }
    }
}
```

Create `Tests/FSKitTests/SorterTests.swift`:

```swift
import Foundation
import MacxFS
import XCTest

final class SorterTests: XCTestCase {
    private let registry = TypeRegistry()

    /// (name, kind, size, mtime, flags)
    private func store(_ rows: [(String, Kind, Int64, Int64, EntryFlags)]) -> EntryStore {
        var s = EntryStore(identityMode: .objectID)
        var batch = Batch(generation: .initial)
        for (i, r) in rows.enumerated() {
            let ext = r.0.split(separator: ".").count > 1 ? r.0.split(separator: ".").last! : ""
            let type = r.1 == .directory ? TypeRegistry.folderIndex : registry.index(forExtension: ext, isDirectory: false)
            let e = Entry(rowID: UInt64(i + 1), fileID: UInt64(i + 1), size: r.2, allocSize: 0, mtime: r.3, ctime: -r.3,
                          nameOffset: 0, nameLen: 0, kind: r.1, flags: r.4, typeIndex: type)
            Array(r.0.utf8).withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
        }
        s.append(batch)
        return s
    }

    private func names(_ s: EntryStore, _ query: ViewQuery) -> [String] {
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        let perm = Sorter.permutation(s, nameKeys: keys, searchKeys: SortKeys.searchKeys(s), query: query, kindRanks: registry.kindRanks().ranks)
        return perm.map { s.name($0) }
    }

    private lazy var sample = store([
        ("b.txt", .file, 30, 300, []), ("A.pdf", .file, 10, 100, []), ("zeta", .directory, 2, 50, []),
        ("alpha", .directory, 9, 900, []), (".hidden", .file, 1, 1, .dotName), ("secret.txt", .file, 5, 5, .bsdHidden),
        ("Tool.app", .package, 0, 400, []), ("c10.txt", .file, 20, 200, []), ("c9.txt", .file, 20, 250, []),
    ])

    func testNameAscendingFoldersFirstHiddenExcluded() {
        XCTAssertEqual(names(sample, ViewQuery()), ["alpha", "zeta", "A.pdf", "b.txt", "c9.txt", "c10.txt", "Tool.app"])
    }

    func testShowHiddenIncludesDotAndFlagHidden() {
        XCTAssertEqual(names(sample, ViewQuery(showHidden: true)),
                       ["alpha", "zeta", ".hidden", "A.pdf", "b.txt", "c9.txt", "c10.txt", "secret.txt", "Tool.app"])
    }

    func testDescendingKeepsFoldersFirst() {
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .name, ascending: false))),
                       ["zeta", "alpha", "Tool.app", "c10.txt", "c9.txt", "b.txt", "A.pdf"])
    }

    func testSizeSortOrdersFoldersByName() {
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .size, ascending: true))),
                       ["alpha", "zeta", "Tool.app", "A.pdf", "c9.txt", "c10.txt", "b.txt"])
    }

    func testDateSortsWithNameTieBreak() {
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .dateModified, ascending: true))),
                       ["zeta", "alpha", "A.pdf", "c10.txt", "c9.txt", "b.txt", "Tool.app"])
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .dateCreated, ascending: true))),
                       ["alpha", "zeta", "Tool.app", "b.txt", "c9.txt", "c10.txt", "A.pdf"])
    }

    func testKindSortUsesRanksThenName() {
        let order = names(sample, ViewQuery(sort: SortDescriptor(field: .kind, ascending: true)))
        XCTAssertEqual(Array(order.prefix(2)), ["alpha", "zeta"])
        let txt = order.filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(txt, ["b.txt", "c9.txt", "c10.txt"], "same kind: name order")
        let ranks = registry.kindRanks().ranks
        let ranked = order.dropFirst(2).map { n -> UInt16 in
            let i = (0..<UInt32(sample.count)).first { sample.name($0) == n }!
            return ranks[Int(sample.entry(i).typeIndex)]
        }
        XCTAssertEqual(ranked, ranked.sorted())
    }

    func testExtensionSort() {
        XCTAssertEqual(names(sample, ViewQuery(sort: SortDescriptor(field: .fileExtension, ascending: true))),
                       ["alpha", "zeta", "Tool.app", "A.pdf", "b.txt", "c9.txt", "c10.txt"])
    }

    func testFilterIsCaseAndDiacriticInsensitiveSubstring() {
        let s = store([("Résumé.pdf", .file, 0, 0, []), ("resume-old", .directory, 0, 0, []), ("notes", .file, 0, 0, [])])
        XCTAssertEqual(names(s, ViewQuery(filter: "RESUME")), ["resume-old", "Résumé.pdf"])
        XCTAssertEqual(names(s, ViewQuery(filter: "sum")), ["resume-old", "Résumé.pdf"])
        XCTAssertEqual(names(s, ViewQuery(filter: "zzz")), [])
    }

    func testFilterWithoutSearchKeysFallsBackToFoldingNames() {
        let s = store([("Résumé.pdf", .file, 0, 0, []), ("notes", .file, 0, 0, [])])
        let perm = Sorter.permutation(s, nameKeys: SortKeys.nameKeys(s, range: 0..<s.count), searchKeys: nil,
                                      query: ViewQuery(filter: "resu"), kindRanks: [])
        XCTAssertEqual(perm.map { s.name($0) }, ["Résumé.pdf"])
    }

    func testMergeOfSortedRunsEqualsFullSort() {
        var s = EntryStore(identityMode: .objectID)
        var keys = SortKeyColumn()
        var merged: [UInt32] = []
        let query = ViewQuery()
        var rng = SystemRandomNumberGenerator()
        for b in 0..<5 {
            var batch = Batch(generation: .initial)
            for i in 0..<400 {
                let n = "item \(Int.random(in: 0..<10_000, using: &rng)) \(b)-\(i)"
                let e = Entry(rowID: UInt64(b * 1_000 + i), fileID: 0, size: 0, allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0,
                              nameLen: 0, kind: i.isMultiple(of: 9) ? .directory : .file, flags: [], typeIndex: 0)
                Array(n.utf8).withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
            }
            let start = s.count
            s.append(batch)
            keys.append(contentsOf: SortKeys.nameKeys(batch))
            let run = Sorter.sortedRun(s, range: start..<s.count, nameKeys: keys, searchKeys: nil, query: query, kindRanks: [])
            merged = Sorter.merge(merged, run, store: s, nameKeys: keys, query: query, kindRanks: [])
        }
        XCTAssertEqual(merged, Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: query, kindRanks: []))
    }

    func testSortKeyColumnRemoveAndReplaceMirrorStore() {
        var column = SortKeyColumn()
        for k in [[1], [2, 2], [3, 3, 3]] as [[UInt8]] { k.withUnsafeBytes { column.append($0) } }
        column.remove([1])
        XCTAssertEqual(column.count, 2)
        XCTAssertEqual(column.withKey(1) { Array($0) }, [3, 3, 3])
        column.replace(0, with: [9])
        XCTAssertEqual(column.withKey(0) { Array($0) }, [9])
    }

    func testParallelKeysEqualSerialKeys() {
        let s = store((0..<5_000).map { ("name \($0 * 7919 % 5_000)", Kind.file, 0, 0, EntryFlags()) })
        let parallel = SortKeys.nameKeys(s, range: 0..<s.count)
        for i in stride(from: 0, to: s.count, by: 97) {
            XCTAssertEqual(parallel.withKey(i) { Array($0) }, SortKeys.nameKey(s.name(UInt32(i)), isFolder: false))
        }
    }

    /// §4.4 smoke: 100k re-sort per field. Debug: sanity bound; release (-c release -Xswiftc -enable-testing): 4 × 30 ms.
    func testResort100kSmoke() {
        var rows: [(String, Kind, Int64, Int64, EntryFlags)] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let kind: Kind = i.isMultiple(of: 50) ? .directory : .file
            rows.append(("file \(i * 7_919 % 100_000).txt", kind, Int64(i * 31 % 9_973), Int64(i * 17 % 100_003), []))
        }
        let s = store(rows)
        let keys = SortKeys.nameKeys(s, range: 0..<s.count)
        let ranks = registry.kindRanks().ranks
        #if DEBUG
        let budget = Duration.seconds(10)   // sanity only: -Onone and swift test --parallel contention
        #else
        let budget = Duration.milliseconds(120)
        #endif
        for field in SortField.allCases {
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                _ = Sorter.permutation(s, nameKeys: keys, searchKeys: nil, query: ViewQuery(sort: SortDescriptor(field: field, ascending: true)), kindRanks: ranks)
            }
            print("resort100k \(field): \(elapsed)")
            XCTAssertLessThan(elapsed, budget, "\(field)")
        }
    }
}
```

- [ ] **Step 4: Run to verify failure**

Run: `swift test --filter "FSKitTests.(SortGoldenTests|SorterTests)" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'SortKeys' in scope` (and similar).

- [ ] **Step 5: Implement ViewQuery, SortKeyColumn and SortKeys**

Create `Sources/FSKit/Sort/ViewQuery.swift`:

```swift
public enum SortField: String, Sendable, Codable, CaseIterable { case name, dateModified, size, kind, dateCreated, fileExtension }

public struct SortDescriptor: Sendable, Codable, Hashable {
    public var field: SortField
    public var ascending: Bool
    public init(field: SortField, ascending: Bool) { self.field = field; self.ascending = ascending }
    public static let `default` = SortDescriptor(field: .name, ascending: true)
}

public struct ViewQuery: Sendable, Hashable {
    public var sort: SortDescriptor
    public var showHidden: Bool
    public var filter: String                             // "" = no filter
    public init(sort: SortDescriptor = .default, showHidden: Bool = false, filter: String = "") {
        self.sort = sort
        self.showHidden = showHidden
        self.filter = filter
    }
}
```

Create `Sources/FSKit/Sort/SortKeyColumn.swift`:

```swift
/// Byte keys, one per storage index, in a single arena (no per-key allocation).
public struct SortKeyColumn: Sendable {
    private(set) var bytes: [UInt8] = []
    private(set) var starts: [UInt32] = []
    private(set) var lengths: [UInt32] = []

    public init() {}
    public var count: Int { starts.count }

    public mutating func append(_ key: UnsafeRawBufferPointer) {
        starts.append(UInt32(bytes.count))
        lengths.append(UInt32(key.count))
        bytes.append(contentsOf: key)
    }

    mutating func append(_ key: [UInt8]) { key.withUnsafeBytes { append($0) } }

    public mutating func append(contentsOf other: SortKeyColumn) {
        let base = UInt32(bytes.count)
        bytes.append(contentsOf: other.bytes)
        starts.append(contentsOf: other.starts.map { $0 + base })
        lengths.append(contentsOf: other.lengths)
    }

    public func withKey<R>(_ index: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes { raw in
            try body(UnsafeRawBufferPointer(rebasing: raw[Int(starts[index])..<Int(starts[index]) + Int(lengths[index])]))
        }
    }

    /// Mirrors EntryStore.remove compaction (indices are storage indices before removal).
    public mutating func remove(_ indices: Set<UInt32>) {
        guard !indices.isEmpty else { return }
        var fresh = SortKeyColumn()
        bytes.withUnsafeBytes { raw in
            for i in 0..<count where !indices.contains(UInt32(i)) {
                fresh.append(UnsafeRawBufferPointer(rebasing: raw[Int(starts[i])..<Int(starts[i]) + Int(lengths[i])]))
            }
        }
        self = fresh
    }

    /// Replaces key `index` (old bytes stay in the arena until the next remove).
    public mutating func replace(_ index: Int, with key: [UInt8]) {
        starts[index] = UInt32(bytes.count)
        lengths[index] = UInt32(key.count)
        bytes.append(contentsOf: key)
    }

    /// Unsafe fast access for Sorter: calls body with (arena, starts, lengths).
    func withStorage<R>(_ body: (UnsafeRawBufferPointer, UnsafeBufferPointer<UInt32>, UnsafeBufferPointer<UInt32>) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes { b in
            try starts.withUnsafeBufferPointer { s in try lengths.withUnsafeBufferPointer { l in try body(b, s, l) } }
        }
    }
}
```

Create `Sources/FSKit/Sort/SortKeys.swift`. `String.folding(options:locale:)` is Foundation's `CFStringFold`. An all-zero digit run keeps one `0`, so the length byte is never `0x00` (the separator). Parallel key building writes each 1,024-key chunk once into a `Mutex`-guarded array (`concurrentPerform`'s closure is `@Sendable` in this SDK, so an unsafe buffer capture does not compile).

```swift
import Foundation
import Synchronization

public enum SortKeys {
    static let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    static let foldLocale = Locale(identifier: "en_US_POSIX")

    /// [kind byte: 0 folder / 1 other] + CFStringFold(case|diacritic|width, fixed en_US_POSIX locale) UTF-8 with
    /// digit runs encoded as [len byte][digits without leading zeros] (tie-break on original run length)
    /// + 0x00 + unfolded NFC bytes.
    public static func nameKey(_ name: String, isFolder: Bool) -> [UInt8] {
        let folded = name.folding(options: foldOptions, locale: foldLocale)
        var key: [UInt8] = [isFolder ? 0 : 1]
        key.reserveCapacity(folded.utf8.count * 2 + 4)
        var digits: [UInt8] = []
        func flushDigits() {
            guard !digits.isEmpty else { return }
            var start = 0
            while start < digits.count - 1 && digits[start] == UInt8(ascii: "0") { start += 1 }  // keep ≥ 1 digit
            let run = digits[start...].prefix(255)
            key.append(UInt8(run.count))
            key.append(contentsOf: run)
            digits.removeAll(keepingCapacity: true)
        }
        for byte in folded.utf8 {
            if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                digits.append(byte)
            } else {
                flushDigits()
                key.append(byte)
            }
        }
        flushDigits()
        key.append(0)
        // Tie-break: unfolded NFC bytes. For equal digit values the run with more leading zeros sorts first.
        key.append(contentsOf: name.precomposedStringWithCanonicalMapping.utf8)
        return key
    }

    /// Same fold, no digit encoding, no kind prefix.
    public static func searchFold(_ text: String) -> [UInt8] {
        Array(text.folding(options: foldOptions, locale: foldLocale).utf8)
    }

    /// Name keys for storage indices `range` of `store`, using concurrentPerform.
    public static func nameKeys(_ store: EntryStore, range: Range<Int>) -> SortKeyColumn {
        build(count: range.count) { i in
            let index = UInt32(range.lowerBound + i)
            return nameKey(store.name(index), isFolder: store.entry(index).isFolderForSorting)
        }
    }

    public static func nameKeys(_ batch: Batch) -> SortKeyColumn {
        build(count: batch.count) { i in nameKey(batch.name(at: i), isFolder: batch.entries[i].isFolderForSorting) }
    }

    public static func searchKeys(_ store: EntryStore) -> SortKeyColumn {
        build(count: store.count) { i in searchFold(store.name(UInt32(i))) }
    }

    /// Parallel build in chunks of 1,024; chunks are concatenated in order.
    private static func build(count: Int, _ make: @Sendable (Int) -> [UInt8]) -> SortKeyColumn {
        let chunk = 1_024
        let chunks = (count + chunk - 1) / chunk
        guard chunks > 1 else {
            var column = SortKeyColumn()
            for i in 0..<count { column.append(make(i)) }
            return column
        }
        // One locked write per 1,024-key chunk: negligible contention, no unsafe sharing.
        let parts = Mutex([SortKeyColumn](repeating: SortKeyColumn(), count: chunks))
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var column = SortKeyColumn()
            for i in (c * chunk)..<min(count, (c + 1) * chunk) { column.append(make(i)) }
            parts.withLock { $0[c] = column }
        }
        var result = SortKeyColumn()
        for part in parts.withLock({ $0 }) { result.append(contentsOf: part) }
        return result
    }
}
```

- [ ] **Step 6: Implement Sorter**

Create `Sources/FSKit/Sort/Sorter.swift`. Each candidate becomes an `Item` (group, integer primary key, first 8 key bytes big-endian, index); comparisons are integer compares and at most one `memcmp`, all inside a single `withStorage` scope (opening the arena per comparison made 100k name sorts ~50% slower). Extension sort ranks the distinct folded extensions once, so it is an integer sort too (a per-entry `[UInt8]` key took 124 ms for 100k).

```swift
import Darwin

public enum Sorter {
    /// Visible storage indices of `store` in display order: hidden rows excluded unless query.showHidden,
    /// rows not matching query.filter (byte substring of searchKeys) excluded, folders first, then the sort
    /// field (name: memcmp of nameKeys; dates/size: integer key, name tie-break; kind: TypeRegistry rank
    /// then name; extension: folded extension then name). Size sort orders folders by name (their size is
    /// "--"). Descending reverses within each folders/files group; folders stay first.
    public static func permutation(_ store: EntryStore, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                   query: ViewQuery, kindRanks: [UInt16]) -> [UInt32] {
        sortedRun(store, range: 0..<store.count, nameKeys: nameKeys, searchKeys: searchKeys, query: query, kindRanks: kindRanks)
    }

    /// Like `permutation`, restricted to storage indices in `range` (the loading path sorts each new batch
    /// with this, then `merge`s it). Addition to the §3.5 contract.
    public static func sortedRun(_ store: EntryStore, range: Range<Int>, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                 query: ViewQuery, kindRanks: [UInt16]) -> [UInt32] {
        precondition(nameKeys.count >= range.upperBound, "Sorter: nameKeys must cover every storage index")
        let filter = query.filter.isEmpty ? nil : SortKeys.searchFold(query.filter)
        var items: [Item] = []
        items.reserveCapacity(range.count)
        let ordering = Ordering(store: store, nameKeys: nameKeys, query: query, kindRanks: kindRanks)
        for i in range {
            let index = UInt32(i)
            let entry = store.entry(index)
            if !query.showHidden && entry.flags.isHidden { continue }
            if let filter, !matches(index, store: store, searchKeys: searchKeys, filter: filter) { continue }
            items.append(ordering.item(index))
        }
        ordering.sort(&items)
        return items.map(\.index)
    }

    /// Loading path: merge an already-sorted run of new indices into a sorted permutation.
    public static func merge(_ sorted: [UInt32], _ run: [UInt32], store: EntryStore, nameKeys: SortKeyColumn,
                             query: ViewQuery, kindRanks: [UInt16]) -> [UInt32] {
        if run.isEmpty { return sorted }
        if sorted.isEmpty { return run }
        let ordering = Ordering(store: store, nameKeys: nameKeys, query: query, kindRanks: kindRanks)
        let a = sorted.map(ordering.item), b = run.map(ordering.item)
        var out: [UInt32] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        ordering.withLess { less in
            while i < a.count && j < b.count {
                if less(b[j], a[i]) { out.append(b[j].index); j += 1 } else { out.append(a[i].index); i += 1 }
            }
        }
        while i < a.count { out.append(a[i].index); i += 1 }
        while j < b.count { out.append(b[j].index); j += 1 }
        return out
    }

    static func matches(_ index: UInt32, store: EntryStore, searchKeys: SortKeyColumn?, filter: [UInt8]) -> Bool {
        if filter.isEmpty { return true }
        if let searchKeys, Int(index) < searchKeys.count {
            return searchKeys.withKey(Int(index)) { contains($0, filter) }
        }
        let folded = SortKeys.searchFold(store.name(index))
        return folded.withUnsafeBytes { contains($0, filter) }
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in memmem(haystack.baseAddress, haystack.count, n.baseAddress, n.count) != nil }
    }
}

/// Sort item: group (folders 0 / files 1) | primary integer key | first 8 name-key bytes | storage index.
struct Item {
    var group: UInt8
    var primary: UInt64
    var prefix: UInt64
    var index: UInt32
}

struct Ordering {
    let store: EntryStore
    let nameKeys: SortKeyColumn
    let field: SortField
    let ascending: Bool
    let kindRanks: [UInt16]
    /// fileExtension sort: rank of each storage index's folded extension among the distinct extensions.
    private let extensionRanks: [UInt32]

    init(store: EntryStore, nameKeys: SortKeyColumn, query: ViewQuery, kindRanks: [UInt16]) {
        self.store = store
        self.nameKeys = nameKeys
        self.field = query.sort.field
        self.ascending = query.sort.ascending
        self.kindRanks = kindRanks
        guard query.sort.field == .fileExtension else { extensionRanks = []; return }
        var folded = [[UInt8]](repeating: [], count: store.count)
        var distinct = Set<[UInt8]>()
        for i in 0..<store.count {
            let ext = store.withNameBytes(UInt32(i)) { name -> [UInt8] in
                guard store.entry(UInt32(i)).kind != .directory, let r = fileExtensionRange(name) else { return [] }
                return SortKeys.searchFold(String(decoding: UnsafeBufferPointer(rebasing: name[r]), as: UTF8.self))
            }
            folded[i] = ext
            distinct.insert(ext)
        }
        let rank = Dictionary(uniqueKeysWithValues: distinct.sorted { $0.lexicographicallyPrecedes($1) }.enumerated().map { ($1, UInt32($0)) })
        extensionRanks = folded.map { rank[$0]! }
    }

    func item(_ index: UInt32) -> Item {
        let e = store.entry(index)
        let folder = e.isFolderForSorting
        let primary: UInt64
        switch field {
        case .name: primary = 0
        case .fileExtension: primary = UInt64(extensionRanks[Int(index)])
        case .dateModified: primary = UInt64(bitPattern: e.mtime) ^ (1 << 63)
        case .dateCreated: primary = UInt64(bitPattern: e.ctime) ^ (1 << 63)
        case .size: primary = folder ? 0 : UInt64(bitPattern: e.size) ^ (1 << 63)
        case .kind: primary = Int(e.typeIndex) < kindRanks.count ? UInt64(kindRanks[Int(e.typeIndex)]) : UInt64(UInt16.max)
        }
        let prefix = nameKeys.withKey(Int(index)) { key -> UInt64 in
            var p: UInt64 = 0
            for k in 0..<8 { p = (p << 8) | UInt64(k < key.count ? key[k] : 0) }
            return p
        }
        return Item(group: folder ? 0 : 1, primary: primary, prefix: prefix, index: index)
    }

    /// Calls `body` with a strict-weak-order `less` (total: the storage index breaks remaining ties).
    /// The key arena is opened once, so each comparison is integer compares plus at most one memcmp.
    func withLess<R>(_ body: ((Item, Item) -> Bool) -> R) -> R {
        nameKeys.withStorage { bytes, starts, lengths in
            let base = bytes.baseAddress
            let ascending = self.ascending
            func ordered(_ a: Item, _ b: Item) -> Bool {
                if a.primary != b.primary { return a.primary < b.primary }
                if a.prefix != b.prefix { return a.prefix < b.prefix }
                let la = Int(lengths[Int(a.index)]), lb = Int(lengths[Int(b.index)])
                let c = memcmp(base! + Int(starts[Int(a.index)]), base! + Int(starts[Int(b.index)]), min(la, lb))
                if c != 0 { return c < 0 }
                if la != lb { return la < lb }
                return a.index < b.index
            }
            return body { a, b in
                if a.group != b.group { return a.group < b.group }
                return ascending ? ordered(a, b) : ordered(b, a)
            }
        }
    }

    func sort(_ items: inout [Item]) {
        guard items.count > 1 else { return }
        withLess { less in items.sort(by: less) }
    }
}
```

- [ ] **Step 7: Record the divergence list, review it, and run the tests**

Run:
```bash
MACX_RECORD_SORT_DIVERGENCES=1 swift test --filter FSKitTests.SortGoldenTests/testCorpusMatchesLocalizedStandardCompareExceptListed 2>&1 | grep -E "recorded|error:"
```
Expected: `Test skipped - recorded 570 divergences to …/Tests/FSKitTests/Corpus/sort-allowed-divergences.json; review and commit` (the exact count can differ on another macOS build; any count is fine as long as no pair is `other`, which fails the test before writing).

Review: `python3 -I -c "import json,collections;d=json.load(open('Tests/FSKitTests/Corpus/sort-allowed-divergences.json'));print(collections.Counter(x['category'] for x in d['divergences']))"` — expect only the seven listed categories; open the file and read ten pairs of each to confirm the classification is right.

Then run: `swift test --filter "FSKitTests.(SortGoldenTests|SorterTests)" 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 20 tests, with 0 failures`.

- [ ] **Step 8: Check the 100k re-sort against 4 × the §4.4 budget in a release build**

Run: `swift test -c release -Xswiftc -enable-testing --filter FSKitTests.SorterTests/testResort100kSmoke 2>&1 | grep -E "resort100k|error:"`
Expected (M3 Pro reference): `name ≈ 21 ms`, `dateModified ≈ 7 ms`, `size ≈ 11 ms`, `kind ≈ 20 ms`, `dateCreated ≈ 10 ms`, `fileExtension` well under 120 ms; no `error:`. The real gate is `macx-bench --check-budgets` (P1-39); the debug-build version of this test only sanity-checks (< 10 s, since `swift test --parallel` contention made it reach 2.5 s once).

- [ ] **Step 9: Build with zero warnings**

Run: `swift build 2>&1 | tail -5`
Expected: last line `Build complete! (…)`, no `warning:` lines above it.

- [ ] **Step 10: Commit**

```bash
git add Sources/FSKit/Sort Sources/MacxFixtures/SortCorpus.swift Tests/FSKitTests/Support/SortDivergence.swift Tests/FSKitTests/SortGoldenTests.swift Tests/FSKitTests/SorterTests.swift Tests/FSKitTests/Corpus/sort-allowed-divergences.json
git commit -m "feat: byte sort keys, sorter and sort golden corpus (P1-07)"
```

---
## Task P1-08: Volumes: VolumeInfo/Capabilities, MountTable/Store, SystemVolumeScanner, Volumes, DirectoryReaders

**Spec:** §4.2 Volumes (mountedVolumeURLs read on a lane, NSWorkspace events delivered through `VolumeEventSource`, capabilities `idStable`/`renameExcl`/`clone` + `volumeSupportsCaseSensitiveNamesKey`, main-actor mount table, `Volumes.release` on willUnmount), §4.2 poison cap (reads resume when the volume remounts or reappears), §4.3 Row identity (identity mode from capabilities), §5.4 Locations (browsable volumes), §5.5 status bar free space (`volumeAvailableCapacityForImportantUsageKey`, fallback `volumeAvailableCapacityKey`, fetched on a lane, cached), §5.6 drag validation (longest-prefix mount-table match, in memory).

**Files:**
- Modify: `Sources/FSKit/Volumes/VolumeInfo.swift` (add `VolumeCapabilities`, `VolumeInfo`; `import Foundation`)
- Create: `Sources/FSKit/Volumes/MountTable.swift`
- Create: `Sources/FSKit/Volumes/VolumeScanner.swift`
- Create: `Sources/FSKit/Volumes/Volumes.swift`
- Create: `Sources/FSKit/Reader/DirectoryReaders.swift` (moved here from P1-06)
- Test: `Tests/FSKitTests/VolumesTests.swift`

**Interfaces:**
- Consumes: P1-03 `cfsk_volume_caps`; P1-04 `LanePool` (`perform`, `resetVolume`, `health`), `Observers`, `ObserverToken`, `assertOffMain`, `VolumeID`; P1-05 `IdentityMode`; P1-06 `DirectoryReader`; P1-02 `DiskImage`; test helpers `Gate`, `eventually`.
- Produces: overview §3.6 exactly:

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

and, from §3.4:

```swift
// Reader/DirectoryReaders.swift
public final class DirectoryReaders: Sendable {
    public init(lanes: LanePool, mountTable: MountTableStore, types: TypeRegistry = .shared)
    public func reader(for directory: URL) -> DirectoryReader          // by MountTable volume, else VolumeID.unknown
    public func reader(for volume: VolumeID) -> DirectoryReader
    public func cancelAll(on volume: VolumeID) async
}
```

Behaviour other slices rely on:
- `SystemVolumeScanner.scan()` includes hidden volumes (`isBrowsable == false` for `/System/Volumes/*`, `-nobrowse` images, `/dev`). The boot entry (`/`) takes the Data volume's capabilities and `isReadOnly`, because every user path reaches the Data volume through firmlinks while `/` itself is the sealed read-only system volume; so `MountTable.volume(containing: "/Users/…")` is the boot entry with correct capabilities (Contract notes 10).
- `VolumeID` is `uuid:<volumeUUIDString>` when the volume has one, else `mnt:<mount path>`.
- `Volumes.refresh()` calls `LanePool.resetVolume` for every volume ID that newly appears, which clears a previous unresponsive mark (§4.2). It publishes to `observe` handlers only when the list changed.
- `Volumes.handle(.willUnmount)` runs `release` (all handlers, in registration order, awaited one after another) before rescanning. `Volumes` registers no handlers itself: `CoreEnvironment` (P1-25) adds them — `readers.cancelAll(on:)`, watcher stop, FileOps pause, windows → Home.
- `availableCapacity(of:)` falls back to `volumeAvailableCapacityKey` when the important-usage value is nil **or 0 while the plain value is positive** (HFS+/FAT images report 0; Contract notes 9).

- [ ] **Step 1: Write the failing volume tests**

Create `Tests/FSKitTests/VolumesTests.swift` (fake scanner/events for logic; real `SystemVolumeScanner` on the boot volume and on APFS, exFAT, MS-DOS and HFS+ images created in the sandbox):

```swift
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import Synchronization
import XCTest

private func volume(_ id: String, _ path: String, boot: Bool = false, browsable: Bool = true,
                    caps: VolumeCapabilities = VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false)) -> VolumeInfo {
    VolumeInfo(id: VolumeID(raw: id), mountPoint: URL(filePath: path, directoryHint: .isDirectory), name: id, format: "APFS",
               isBoot: boot, isInternal: boot, isRemovable: !boot, isEjectable: !boot, isLocal: true, isReadOnly: false,
               isBrowsable: browsable, totalCapacity: 1_000, capabilities: caps)
}

final class FakeScanner: VolumeScanning {
    let volumes: Mutex<[VolumeInfo]>
    let capacity = Mutex<Int64?>(4_242)
    init(_ v: [VolumeInfo]) { volumes = Mutex(v) }
    func scan() throws -> [VolumeInfo] { volumes.withLock { $0 } }
    func availableCapacity(of mountPoint: URL) -> Int64? { capacity.withLock { $0 } }
    func set(_ v: [VolumeInfo]) { volumes.withLock { $0 = v } }
}

@MainActor
final class FakeEvents: VolumeEventSource {
    var handler: (@MainActor (VolumeEvent) -> Void)?
    func start(_ handler: @escaping @MainActor (VolumeEvent) -> Void) { self.handler = handler }
}

final class MountTableTests: XCTestCase {
    private let table = MountTable([volume("boot", "/", boot: true), volume("usb", "/Volumes/USB"),
                                    volume("usb2", "/Volumes/USB 2"), volume("data", "/System/Volumes/Data", browsable: false)])

    func testLongestPrefixMatch() {
        XCTAssertEqual(table.volume(containing: "/Users/me/file")?.id.raw, "boot")
        XCTAssertEqual(table.volume(containing: "/Volumes/USB")?.id.raw, "usb")
        XCTAssertEqual(table.volume(containing: "/Volumes/USB/a/b")?.id.raw, "usb")
        XCTAssertEqual(table.volume(containing: "/Volumes/USB 2/x")?.id.raw, "usb2")
        XCTAssertEqual(table.volume(containing: "/Volumes/USBX/x")?.id.raw, "boot", "prefix must end at a path component")
        XCTAssertEqual(table.volume(containing: "/Volumes/USB/../USB 2/x")?.id.raw, "usb2", "standardized first")
        XCTAssertEqual(table.volume(containing: "/System/Volumes/Data/Users")?.id.raw, "data")
        XCTAssertNil(MountTable.empty.volume(containing: "/x"))
    }

    func testIsSameVolume() {
        XCTAssertTrue(table.isSameVolume("/Users/a", "/Applications/b"))
        XCTAssertFalse(table.isSameVolume("/Users/a", "/Volumes/USB/b"))
        XCTAssertFalse(MountTable.empty.isSameVolume("/a", "/a"))
    }

    func testStoreMirrorsUpdates() {
        let store = MountTableStore()
        XCTAssertEqual(store.current(), .empty)
        store.update(table)
        XCTAssertEqual(store.current().volume(containing: "/Volumes/USB/x")?.id.raw, "usb")
    }

    func testIdentityModeFollowsCapabilities() {
        XCTAssertEqual(VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false).identityMode, .objectID)
        XCTAssertEqual(VolumeCapabilities(idStable: false, renameExcl: false, clone: false, caseSensitive: false).identityMode,
                       .name(caseSensitive: false))
    }

    func testDirectoryReadersPickReaderByVolume() {
        let store = MountTableStore(table)
        let readers = DirectoryReaders(lanes: LanePool(), mountTable: store)
        XCTAssertEqual(readers.reader(for: URL(filePath: "/Volumes/USB/x")).volume.raw, "usb")
        XCTAssertTrue(readers.reader(for: URL(filePath: "/Volumes/USB/y")) === readers.reader(for: VolumeID(raw: "usb")))
        XCTAssertEqual(DirectoryReaders(lanes: LanePool(), mountTable: MountTableStore()).reader(for: URL(filePath: "/x")).volume, .unknown)
    }
}

@MainActor
final class VolumesTests: XCTestCase {
    func testStartScansSortsAndPublishesMirror() async {
        let scanner = FakeScanner([volume("usb", "/Volumes/USB"), volume("data", "/System/Volumes/Data", browsable: false),
                                   volume("boot", "/", boot: true)])
        let volumes = Volumes(lanes: LanePool(), scanner: scanner, events: nil)
        await volumes.start()
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot", "data", "usb"], "boot first, then by name")
        XCTAssertEqual(volumes.browsable.map(\.id.raw), ["boot", "usb"])
        XCTAssertEqual(volumes.volume(for: URL(filePath: "/Volumes/USB/f"))?.id.raw, "usb")
        XCTAssertEqual(volumes.mountTableStore.current(), volumes.mountTable)
    }

    func testEventsRescanAndWillUnmountReleasesFirst() async {
        let scanner = FakeScanner([volume("boot", "/", boot: true), volume("usb", "/Volumes/USB")])
        let events = FakeEvents()
        let volumes = Volumes(lanes: LanePool(), scanner: scanner, events: events)
        await volumes.start()
        var log: [String] = []
        var changes: [[String]] = []
        let a = volumes.addReleaseHandler { id in log.append("cancel reads \(id.raw)") }
        let b = volumes.addReleaseHandler { id in log.append("move windows \(id.raw)") }
        let c = volumes.observe { list in changes.append(list.map(\.id.raw)) }
        await volumes.handle(.willUnmount(URL(filePath: "/Volumes/USB")))
        XCTAssertEqual(log, ["cancel reads usb", "move windows usb"], "handlers run in registration order")
        scanner.set([volume("boot", "/", boot: true)])
        await volumes.handle(.didUnmount(URL(filePath: "/Volumes/USB")))
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot"])
        scanner.set([volume("boot", "/", boot: true), volume("cam", "/Volumes/CAM")])
        events.handler?(.didMount(URL(filePath: "/Volumes/CAM")))
        let mounted = await eventuallyMain { volumes.list.count == 2 }
        XCTAssertTrue(mounted)
        XCTAssertEqual(changes, [["boot"], ["boot", "cam"]])
        a.cancel()
        await volumes.release(VolumeID(raw: "cam"))
        XCTAssertEqual(log.last, "move windows cam", "cancelled handler no longer runs")
        _ = (b, c)
    }

    func testReappearingVolumeResetsUnresponsiveMark() async throws {
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(100), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 1))
        let scanner = FakeScanner([volume("boot", "/", boot: true)])
        let volumes = Volumes(lanes: lanes, scanner: scanner, events: nil)
        await volumes.start()
        let nas = VolumeID(raw: "nas")
        let gate = Gate()
        let hung = Task { try await lanes.perform(on: nas) { _ in gate.wait() } }
        let unresponsive = await eventually { await lanes.health(of: nas) == .unresponsive }
        XCTAssertTrue(unresponsive)
        scanner.set([volume("boot", "/", boot: true), volume("nas", "/Volumes/NAS")])
        await volumes.handle(.didMount(URL(filePath: "/Volumes/NAS")))
        let health = await lanes.health(of: nas)
        XCTAssertEqual(health, .healthy)
        gate.open()
        _ = try await hung.value
    }

    func testCapacityIsFetchedOnALaneAndCached() async {
        let scanner = FakeScanner([volume("boot", "/", boot: true)])
        let volumes = Volumes(lanes: LanePool(), scanner: scanner, events: nil)
        await volumes.start()
        let boot = VolumeID(raw: "boot")
        XCTAssertNil(volumes.cachedAvailableCapacity(boot))
        let fetched = await volumes.refreshAvailableCapacity(boot)
        XCTAssertEqual(fetched, 4_242)
        XCTAssertEqual(volumes.cachedAvailableCapacity(boot), 4_242)
        let unknown = await volumes.refreshAvailableCapacity(VolumeID(raw: "nope"))
        XCTAssertNil(unknown)
    }

    private func eventuallyMain(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

final class SystemVolumeScannerTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func scan() async throws -> [VolumeInfo] {
        try await LanePool().perform(on: .unknown) { _ in try SystemVolumeScanner().scan() }
    }

    func testBootVolumeIsPresentAndWritableThroughData() async throws {
        let volumes = try await scan()
        let boot = try XCTUnwrap(volumes.first { $0.isBoot })
        XCTAssertEqual(boot.mountPoint.path(percentEncoded: false), "/")
        XCTAssertTrue(boot.isBrowsable)
        XCTAssertTrue(boot.capabilities.idStable)
        XCTAssertFalse(boot.isReadOnly, "takes the Data volume's writability")
        XCTAssertTrue(boot.id.raw.hasPrefix("uuid:"))
        let table = MountTable(volumes)
        XCTAssertEqual(table.volume(containing: NSHomeDirectory())?.id, boot.id)
        let capacity = try await LanePool().perform(on: boot.id) { _ in SystemVolumeScanner().availableCapacity(of: boot.mountPoint) }
        XCTAssertGreaterThan(capacity ?? 0, 0)
    }

    func testDiskImagesAppearWithCapabilitiesAndDisappearAfterDetach() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let expectations: [(DiskImageFormat, IdentityMode, Bool)] = [
            (.apfs, .objectID, true), (.exfat, .name(caseSensitive: false), false), (.msdos, .name(caseSensitive: false), false),
        ]
        for (format, mode, clone) in expectations {
            let image = try DiskImage.create(in: sandbox, format: format, sizeMB: 16, volumeName: "MACXVOL")
            let mounted = try await scan().first { $0.mountPoint.path(percentEncoded: false).trimmingCharacters(in: ["/"]) ==
                                                       image.mountPoint.path(percentEncoded: false).trimmingCharacters(in: ["/"]) }
            let info = try XCTUnwrap(mounted, "\(format) image not in scan")
            XCTAssertFalse(info.isBrowsable, "\(format): -nobrowse images stay out of the sidebar")
            XCTAssertEqual(info.capabilities.identityMode, mode, "\(format)")
            XCTAssertEqual(info.capabilities.clone, clone, "\(format)")
            XCTAssertFalse(info.isBoot)
            let table = MountTable(try await scan())
            XCTAssertEqual(table.volume(containing: image.mountPoint.path(percentEncoded: false) + "/x")?.id, info.id)
            try image.detach()
            let after = try await scan().contains { $0.id == info.id }
            XCTAssertFalse(after, "\(format) still listed after detach")
        }
    }

    @MainActor
    func testVolumesHandleSeesRealImageMountAndUnmount() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let volumes = Volumes(lanes: LanePool(), events: nil)
        await volumes.start()
        let before = volumes.list.count
        let image = try DiskImage.create(in: sandbox, format: .hfsPlus, sizeMB: 16)
        await volumes.handle(.didMount(image.mountPoint))
        XCTAssertEqual(volumes.list.count, before + 1)
        let info = try XCTUnwrap(volumes.volume(for: image.mountPoint.appending(path: "file")))
        XCTAssertFalse(info.isBoot)
        let free = await volumes.refreshAvailableCapacity(info.id)
        XCTAssertGreaterThan(free ?? 0, 0)
        try image.detach()
        await volumes.handle(.didUnmount(image.mountPoint))
        XCTAssertEqual(volumes.list.count, before)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "FSKitTests.(MountTableTests|VolumesTests|SystemVolumeScannerTests)" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find type 'VolumeInfo' in scope` (and similar).

- [ ] **Step 3: Complete VolumeInfo.swift and add MountTable**

Replace `Sources/FSKit/Volumes/VolumeInfo.swift` with:

```swift
import Foundation

public struct VolumeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String                       // "uuid:<volumeUUIDString>" or "mnt:<mount path>"
    public init(raw: String) { self.raw = raw }
    public static let unknown = VolumeID(raw: "unknown")
    public var description: String { raw }
}

public struct VolumeCapabilities: Sendable, Hashable, Codable {
    public var idStable: Bool       // VOL_CAP_FMT_PERSISTENTOBJECTIDS
    public var renameExcl: Bool     // VOL_CAP_INT_RENAME_EXCL
    public var clone: Bool          // VOL_CAP_INT_CLONE
    public var caseSensitive: Bool  // volumeSupportsCaseSensitiveNamesKey (cross-checked with VOL_CAP_FMT_CASE_SENSITIVE)
    public init(idStable: Bool, renameExcl: Bool, clone: Bool, caseSensitive: Bool) {
        self.idStable = idStable
        self.renameExcl = renameExcl
        self.clone = clone
        self.caseSensitive = caseSensitive
    }
    public var identityMode: IdentityMode { idStable ? .objectID : .name(caseSensitive: caseSensitive) }
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
                totalCapacity: Int64?, capabilities: VolumeCapabilities) {
        self.id = id
        self.mountPoint = mountPoint
        self.name = name
        self.format = format
        self.isBoot = isBoot
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isLocal = isLocal
        self.isReadOnly = isReadOnly
        self.isBrowsable = isBrowsable
        self.totalCapacity = totalCapacity
        self.capabilities = capabilities
    }
}
```

Create `Sources/FSKit/Volumes/MountTable.swift`:

```swift
import Foundation
import Synchronization

/// In-memory mount table (§4.2, §5.6 drag validation). Pure; no file-system calls.
public struct MountTable: Sendable, Equatable {
    private let byLength: [VolumeInfo]   // longest mount path first
    private let paths: [String]          // standardized mount paths, parallel to byLength

    public init(_ volumes: [VolumeInfo]) {
        let pairs = volumes.map { (MountTable.standardize($0.mountPoint.path(percentEncoded: false)), $0) }
            .sorted { $0.0.utf8.count > $1.0.utf8.count }
        byLength = pairs.map(\.1)
        paths = pairs.map(\.0)
    }

    public static let empty = MountTable([])
    public var volumes: [VolumeInfo] { byLength }

    /// Longest-prefix match of the standardized path against mount points (pure, in-memory).
    public func volume(containing path: String) -> VolumeInfo? {
        let p = MountTable.standardize(path)
        for (i, mount) in paths.enumerated() where mount == "/" || p == mount || p.hasPrefix(mount + "/") {
            return byLength[i]
        }
        return nil
    }

    public func isSameVolume(_ a: String, _ b: String) -> Bool {
        guard let x = volume(containing: a), let y = volume(containing: b) else { return false }
        return x.id == y.id
    }

    /// Lexical: removes "." / ".." / duplicate and trailing slashes; maps "/private/var|tmp|etc" to the
    /// form mountedVolumeURLs reports is left as is (both spellings are on the same volume anyway).
    static func standardize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast(); continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// Mutex-protected mirror of the main-actor table for off-main readers (DirectoryReaders, FileOps planning).
public final class MountTableStore: Sendable {
    private let table: Mutex<MountTable>
    public init(_ table: MountTable = .empty) { self.table = Mutex(table) }
    public func current() -> MountTable { table.withLock { $0 } }
    public func update(_ table: MountTable) { self.table.withLock { $0 = table } }
}
```

- [ ] **Step 4: Implement the scanner and the event types**

Create `Sources/FSKit/Volumes/VolumeScanner.swift`:

```swift
import CFSKit
import Foundation

public protocol VolumeScanning: Sendable {
    /// Synchronous; called inside lane work. Includes hidden volumes (mount table needs them); isBrowsable marks sidebar ones.
    func scan() throws -> [VolumeInfo]
    /// volumeAvailableCapacityForImportantUsageKey, fallback volumeAvailableCapacityKey. Synchronous; lane only.
    func availableCapacity(of mountPoint: URL) -> Int64?
}

public struct SystemVolumeScanner: VolumeScanning {
    public init() {}

    static let keys: [URLResourceKey] = [
        .volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
        .volumeIsBrowsableKey, .volumeTotalCapacityKey, .volumeSupportsCaseSensitiveNamesKey,
    ]

    /// The sealed system volume "/" is read-only and every user path is on the Data volume through firmlinks
    /// (/Users, /Applications, …). The boot entry therefore takes the Data volume's capabilities and
    /// writability, so lookups by path ("/Users/x" → "/") see the volume that actually holds the files.
    static let dataVolumePath = "/System/Volumes/Data"

    public func scan() throws -> [VolumeInfo] {
        assertOffMain()
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys, options: []) ?? []
        var volumes = urls.compactMap(Self.info)
        if let data = volumes.first(where: { $0.mountPoint.path(percentEncoded: false) == Self.dataVolumePath }),
           let boot = volumes.firstIndex(where: { $0.isBoot }) {
            volumes[boot].capabilities = data.capabilities
            volumes[boot].isReadOnly = data.isReadOnly
        }
        return volumes
    }

    public func availableCapacity(of mountPoint: URL) -> Int64? {
        assertOffMain()
        let values = try? mountPoint.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let plain = values?.volumeAvailableCapacity.map(Int64.init)
        // Non-APFS volumes (HFS+, FAT, exFAT images) report 0 for the "important usage" key: treat as unknown.
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 || (plain ?? 0) == 0 { return important }
        return plain
    }

    static func info(_ url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let path = url.path(percentEncoded: false)
        var caps = cfsk_volcaps()
        let hasCaps = cfsk_volume_caps(path, &caps) == 0
        let caseSensitive = v.volumeSupportsCaseSensitiveNames ?? (hasCaps && caps.case_sensitive != 0)
        let id = v.volumeUUIDString.map { VolumeID(raw: "uuid:" + $0) } ?? VolumeID(raw: "mnt:" + path)
        return VolumeInfo(
            id: id, mountPoint: URL(filePath: path, directoryHint: .isDirectory),
            name: v.volumeLocalizedName ?? (path as NSString).lastPathComponent,
            format: v.volumeLocalizedFormatDescription ?? "",
            isBoot: v.volumeIsRootFileSystem ?? (path == "/"), isInternal: v.volumeIsInternal ?? false,
            isRemovable: v.volumeIsRemovable ?? false, isEjectable: v.volumeIsEjectable ?? false,
            isLocal: v.volumeIsLocal ?? true, isReadOnly: v.volumeIsReadOnly ?? false,
            isBrowsable: v.volumeIsBrowsable ?? false,
            totalCapacity: v.volumeTotalCapacity.map(Int64.init),
            capabilities: VolumeCapabilities(idStable: hasCaps && caps.persistent_ids != 0, renameExcl: hasCaps && caps.rename_excl != 0,
                                             clone: hasCaps && caps.clone != 0, caseSensitive: caseSensitive))
    }
}

public enum VolumeEvent: Sendable, Equatable {
    case didMount(URL), willUnmount(URL), didUnmount(URL), didRename(URL)
}

public protocol VolumeEventSource: Sendable {
    /// Starts delivering events (on the main actor). Implemented in Core/Platform with NSWorkspace.
    @MainActor func start(_ handler: @escaping @MainActor (VolumeEvent) -> Void)
}
```

- [ ] **Step 5: Implement Volumes and DirectoryReaders**

Create `Sources/FSKit/Volumes/Volumes.swift`:

```swift
import Foundation
import Observation

/// Main-actor volume registry (§4.2 Volumes): list, mount table, capacity cache, release handlers.
@MainActor @Observable
public final class Volumes {
    public private(set) var list: [VolumeInfo] = []          // all mounted
    public var browsable: [VolumeInfo] { list.filter(\.isBrowsable) }
    public private(set) var mountTable: MountTable = .empty
    @ObservationIgnored public let mountTableStore = MountTableStore()

    @ObservationIgnored private let lanes: LanePool
    @ObservationIgnored private let scanner: any VolumeScanning
    @ObservationIgnored private let events: (any VolumeEventSource)?
    @ObservationIgnored private var capacity: [VolumeID: Int64] = [:]
    @ObservationIgnored private var handlers: [UInt64: @MainActor (VolumeID) async -> Void] = [:]
    @ObservationIgnored private var nextHandler: UInt64 = 0
    @ObservationIgnored private let listObservers = Observers<[VolumeInfo]>()
    @ObservationIgnored private var started = false

    public init(lanes: LanePool, scanner: any VolumeScanning = SystemVolumeScanner(), events: (any VolumeEventSource)?) {
        self.lanes = lanes
        self.scanner = scanner
        self.events = events
    }

    /// Initial scan on a lane + subscribe to events.
    public func start() async {
        await refresh()
        guard !started else { return }
        started = true
        events?.start { [weak self] event in
            Task { @MainActor in await self?.handle(event) }
        }
    }

    public func refresh() async {
        let scanner = self.scanner
        guard let scanned = try? await lanes.perform(on: .unknown, .read, { _ in try scanner.scan() }) else { return }
        let sorted = scanned.sorted { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let old = Set(list.map(\.id))
        for v in sorted where !old.contains(v.id) { await lanes.resetVolume(v.id) }   // remounted / reappeared
        let gone = old.subtracting(sorted.map(\.id))
        for id in gone { capacity[id] = nil }
        guard sorted != list else { return }
        list = sorted
        mountTable = MountTable(sorted)
        mountTableStore.update(mountTable)
        listObservers.send(sorted)
    }

    /// Rescan; willUnmount → release first (the volume is still mounted then).
    public func handle(_ event: VolumeEvent) async {
        if case .willUnmount(let url) = event, let v = volume(for: url) {
            await release(v.id)
        }
        await refresh()
    }

    public func volume(for url: URL) -> VolumeInfo? { mountTable.volume(containing: url.path(percentEncoded: false)) }

    public func cachedAvailableCapacity(_ volume: VolumeID) -> Int64? { capacity[volume] }

    public func refreshAvailableCapacity(_ volume: VolumeID) async -> Int64? {
        guard let info = list.first(where: { $0.id == volume }) else { return nil }
        let scanner = self.scanner, mount = info.mountPoint
        guard let value = try? await lanes.perform(on: volume, .read, { _ in scanner.availableCapacity(of: mount) }) else {
            return capacity[volume]
        }
        capacity[volume] = value
        return value
    }

    /// Runs every release handler in registration order (cancel reads ≤1 s, stop watchers, pause jobs, move windows home).
    public func release(_ volume: VolumeID) async {
        for key in handlers.keys.sorted() {
            if let handler = handlers[key] { await handler(volume) }
        }
    }

    public func addReleaseHandler(_ handler: @escaping @MainActor (VolumeID) async -> Void) -> ObserverToken {
        nextHandler += 1
        let key = nextHandler
        handlers[key] = handler
        return ObserverToken { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handlers[key] = nil }
            } else {
                Task { @MainActor in self?.handlers[key] = nil }
            }
        }
    }

    public func observe(_ handler: @escaping @MainActor ([VolumeInfo]) -> Void) -> ObserverToken {
        listObservers.add(handler)
    }
}
```

Create `Sources/FSKit/Reader/DirectoryReaders.swift`:

```swift
import Foundation
import Synchronization

/// One DirectoryReader per volume, chosen by the in-memory mount table.
public final class DirectoryReaders: Sendable {
    private let lanes: LanePool
    private let mountTable: MountTableStore
    private let types: TypeRegistry
    private let readers = Mutex<[VolumeID: DirectoryReader]>([:])

    public init(lanes: LanePool, mountTable: MountTableStore, types: TypeRegistry = .shared) {
        self.lanes = lanes
        self.mountTable = mountTable
        self.types = types
    }

    /// By MountTable volume, else VolumeID.unknown.
    public func reader(for directory: URL) -> DirectoryReader {
        reader(for: mountTable.current().volume(containing: directory.path(percentEncoded: false))?.id ?? .unknown)
    }

    public func reader(for volume: VolumeID) -> DirectoryReader {
        readers.withLock { map in
            if let existing = map[volume] { return existing }
            let created = DirectoryReader(volume: volume, lanes: lanes, types: types)
            map[volume] = created
            return created
        }
    }

    public func cancelAll(on volume: VolumeID) async {
        guard let reader = readers.withLock({ $0[volume] }) else { return }
        await reader.cancelAll()
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "FSKitTests.(MountTableTests|VolumesTests|SystemVolumeScannerTests)" 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 12 tests, with 0 failures` (~8 s for four images). Then `mount | grep -c macx-tests` → `0`.

- [ ] **Step 7: Run the whole slice, serial and parallel**

Run: `swift test --filter "FSKitTests|MacxFixturesTests" 2>&1 | grep -E "Executed [0-9]+ tests" | sort -u`
Expected, among the lines: `Executed 14 tests, with 2 tests skipped and 0 failures` (MacxFixturesTests bundle) and `Executed 99 tests, with 1 test skipped and 0 failures` (FSKitTests bundle), ~45 s total.

Run: `swift test --parallel 2>&1 | grep -E "error:|failed \(" | head -5` → no output. Then `ls -d "$TMPDIR"/macx-tests-* 2>/dev/null | wc -l` → `0`, `mount | grep -c macx-tests` → `0`.

- [ ] **Step 8: Build with zero warnings**

Run: `swift build 2>&1 | tail -5`
Expected: last line `Build complete! (…)`, no `warning:` lines above it.

- [ ] **Step 9: Commit**

```bash
git add Sources/FSKit/Volumes Sources/FSKit/Reader/DirectoryReaders.swift Tests/FSKitTests/VolumesTests.swift
git commit -m "feat: volume registry, mount table and per-volume reader registry (P1-08)"
```

---
## Spec coverage (this slice)

| Spec requirement | Task / test |
|---|---|
| §4.2 I/O lanes: dedicated threads, 2 read + 2 FileOps lanes per volume | P1-04 `testWorkRunsOnNamedLaneThreadOffMain`, `testAtMostLanesPerClassAndClassesAreSeparate` |
| §4.2 watchdog 2 s, poisoned lane never reused, Retry gets a fresh lane | P1-04 `testHungReadPoisonsLaneAndRetryGetsFreshLane` |
| §4.2 cap of 4 poisoned lanes → unresponsive until remount/reappear | P1-04 `testPoisonCapMarksVolumeUnresponsiveUntilReset`; P1-08 `testReappearingVolumeResetsUnresponsiveMark` |
| §4.2 TCC prompt: waiting, lane not poisoned | P1-04 `testAwaitingPermissionReportsWaitingAndNeverPoisons`; P1-06 `testPermissionPendingReportsWaitingNotStalled` |
| §4.2 generation per read; stale results discarded | P1-04 `Generation`; P1-06 `testStaleGenerationResultsCanBeDiscardedByTheConsumer` (FolderModel discarding: S2 P1-10) |
| §4.2 `withNoMaterialization` | P1-03 `testMaterializationPolicyIsThreadScopedAndRestored`; P1-04 `testNoMaterializationAppliesOnlyInsideBody`; P1-06 `testNoMaterializationReadGivesSameEntries` |
| §4.2 getattrlistbulk attribute set, 256 KB, parser rules 1–4 | P1-03 all tests; P1-06 golden |
| §4.2 degraded rows (per-entry error) | P1-03 `testPerEntryErrorKeepsValidFields`; P1-06 `testDegradedRecordKeepsRowAndErrno` |
| §4.2 dataless items flagged, never opened | P1-06 `testDatalessAndCustomIconFlagsFromSyntheticRecords` (the reader never opens entries) |
| §4.2 fallback readdir + fstatat; parity | P1-06 `ReaderParityTests` |
| §4.2 streaming 2,000 / 8 ms | P1-06 `testStreamsBatchesOfAtMost2000ThenCompletes`, `testBatchIntervalFlushesSmallBatches` |
| §4.2 EntryStore SoA, arena, permutation, hidden rule | P1-05 `EntryStoreTests` |
| §4.2 Types: interned UTType, packages | P1-05 `TypeRegistryTests`; P1-06 golden kinds |
| §4.2 SortKeys rules 1–5, golden corpus, listed divergences | P1-07 `SortGoldenTests` |
| §4.2 date/size integer sorts, name tie-break; folders first | P1-07 `SorterTests` |
| §4.4 re-sort 100k < 30 ms | P1-07 `testResort100kSmoke` (release check, Step 8) |
| §4.2 Volumes: list on a lane, events, capabilities, mount table, release | P1-08 all tests |
| §4.3 row identity modes, duplicates never trap | P1-05 identity tests; P1-08 `testIdentityModeFollowsCapabilities`, image capabilities |
| §4.4 `assertOffMain` | P1-04 `testAssertOffMainTrapsOnMainThread` |
| §5.5 status bar free space (important usage, fallback, lane, cache) | P1-08 `testCapacityIsFetchedOnALaneAndCached`, `testVolumesHandleSeesRealImageMountAndUnmount` |
| §5.6 drag validation via in-memory mount table | P1-08 `MountTableTests` |
| §9 fixture generator + Swift helper, golden tree kinds | P1-02 `FixtureTreeTests`, `make-fixtures.sh` |
| §9 fuzzing never crashes | P1-03 `CursorFuzzTests` (+ ASan step) |
| §9 UI signposts (shared signposter) | P1-04 `PerfSignposts`; `enumerate` interval in P1-06 |
| Safety HARD RULE | P1-02 `SandboxTests` (trap probes), `DiskImageTests` (`-nobrowse`, destroy detaches) |

## Contract notes

Defects or gaps found while writing and verifying this slice. The overview was not edited (task instruction); slice authors and the architect should apply these.

1. **MacxFixtures has no interface in overview §3**, although every slice's tests use it (`Sandbox`, `DiskImage.create(in: sandbox, …)` in §5). This plan defines it (P1-02 Interfaces block): `Sandbox(prefix:)`, `Sandbox(adopting:)`, `root`, `contains/checked/url`, write helpers taking sandbox-relative paths (`createFile`, `createDirectory`, `createSymlink`, `createHardLink`, `createAlias`, `createSparseFile`, `overwrite`, `append`, `setFlags`, `setMode`, `setXattr`, `setHiddenExtension`, `setDates`, `rename`, `remove`), `destroy()`; `DiskImage.create(in:format:sizeMB:volumeName:readOnly:populate:)`, `mountPoint`, `relativeMountPath`, `detach()`, `DiskImage.isAvailable`, `DiskImageFormat {apfs, hfsPlus, exfat, msdos}`; `FixtureTree.golden/flat/deep`, `GoldenName`; `SortCorpus.names(count:seed:)`; `TrapProbe` (new file `Sources/MacxFixtures/TrapProbe.swift`, not in the §2 file map). Writes into a mounted image go through the sandbox with `image.relativeMountPath + "/…"`. S2/S3/S6 should use these names; `Sandbox(adopting:)` is what `macx-scenarios`/`ScenarioDriver` should use for `--root` (it enforces "directly in `$TMPDIR`, name starts with an allowed prefix").
2. **`VolumeID` is needed by P1-04** (`LanePool.perform(on: VolumeID …)`) but lives in P1-08's file. P1-04 creates `Sources/FSKit/Volumes/VolumeInfo.swift` with `VolumeID` only; P1-08 adds `VolumeCapabilities` and `VolumeInfo` to it.
3. **`DirectoryReaders` (§3.4, P1-06) needs `MountTableStore` (§3.6, P1-08).** It is implemented in P1-08. Its only consumers (P1-10 onward) depend on both tasks, so the ID order still works.
4. **`ATTR_CMN_ACCESSMASK` is the file's mode bits, not the caller's access** (verified: `0x81a4` for a 0644 file). The contract comment on `cfsk_record.access_mask` ("R_OK|W_OK|X_OK for the calling user") and `EntryFlags.readable/writable/executable` need `ATTR_CMN_USERACCESS`, which CFSKit requests instead (spec §4.2 attribute list deviation; a uchg file correctly reports `R_OK` only). If Properties (S2 P1-16) needs mode bits, it reads them with `lstat`, as it already plans.
5. **`Sorter.sortedRun(_:range:nameKeys:searchKeys:query:kindRanks:)` added** (public). `Sorter.merge` needs an already-sorted run of new indices and §3.5 had no way to produce one for a subset of the store; S2's `FolderWorker` should use it for the per-batch sort while loading.
6. **`LanePool.perform` is `@discardableResult`** (attribute only; signature unchanged).
7. **Typed-throws closure conversion is unsafe on Swift 6.4.2**: passing a `throws(ReadFailure)` closure to `LanePool.perform`'s `throws` parameter produced a garbage error payload. Contract-level consequence: `BulkReader.read`/`FallbackReader.read` keep their typed `throws(ReadFailure)` (calling them is fine), but closures handed to `perform` or `withNoMaterialization` must be plain `throws` (or return `Result`). S2/S3 code calling lanes should follow the same rule.
8. **`Tests/FSKitTests/Corpus/sort-allowed-divergences.json` format**: P1-01 creates `[]`; P1-07 regenerates it as `{ "comment", "categories": {name: reason}, "divergences": [{a, b, category}] }`. P1-01 only needs the file to exist so the `.copy("Corpus")` resource compiles.
9. **Free space on non-APFS volumes**: `volumeAvailableCapacityForImportantUsageKey` returns `0` (not nil) on HFS+/FAT/exFAT images. The scanner falls back to `volumeAvailableCapacityKey` when the important value is nil, or 0 while the plain value is positive (spec §5.5 says "when nil").
10. **Boot volume vs Data volume**: with prefix matching, `/Users/…` maps to `/` (the sealed, read-only system volume) while the files live on `/System/Volumes/Data`. `SystemVolumeScanner` gives the boot entry the Data volume's capabilities and writability; paths spelled `/System/Volumes/Data/…` still map to the (hidden) Data entry, so `MountTable.isSameVolume("/Users/a", "/System/Volumes/Data/b")` is false (drag would copy instead of move; FileOps decides by `st_dev` anyway, §6.3).
11. **Spec §9 golden-tree kinds that a normal user can't create on APFS**: per-entry `ATTR_CMN_ERROR` (a mode-000 directory still lists fine in its parent) and dataless files. Both are covered with synthetic records (`RecordBuilder`) in P1-03/P1-06; the golden tree has `no-access-dir`/`no-access.txt` for the permission paths.
12. **getattrlist vs getattrlistbulk**: `getattrlistat` omits all-zero Finder info that `getattrlistbulk` returns as zeros, and on FAT `getattrlistbulk` omits `ATTR_FILE_ALLOCSIZE` that `getattrlistat` returns. The converter treats missing Finder info / alloc size as 0 (not degraded); parity is asserted on `Entry`, not on raw fields.
13. **Sparse files on APFS** report `st_blocks` for the full logical size in this configuration (an 8 MiB file with a hole reports 8 MiB allocated). Tests compare `allocSize` with `lstat`, never assume it is small. S3's free-space estimate (§6.5) should not rely on sparse files having small allocation.
14. **Empty test targets fail `swift test`** when Xcode is installed (each target is its own `.xctest`; an empty one fails to load). P1-01's stubs for `FSKitTests`, `CoreTests`, `UITests`, `MacxFixturesTests` must each contain at least one test method.
15. **`Volumes` itself registers no release handlers.** Spec §4.2 lists what `release` does (cancel reads ≤ 1 s, stop watchers, pause jobs, move windows home); those are registered by `CoreEnvironment` (P1-25: `readers.cancelAll(on:)`, …) and the UI (P1-26 `WindowManager`). Handlers run sequentially in registration order, so register reader cancellation first.
16. **Unresponsive reads surface as `.failed(ReadFailure(code: ETIMEDOUT, stage: .unresponsiveVolume))`.** `Reason(errno:)` (§3.7) maps `ETIMEDOUT` to `.other(ETIMEDOUT)`; P1-10 should check `stage == .unresponsiveVolume` first and enter `FolderState.unresponsive`.
17. **Directory `Entry.size` is the entry count** from `ATTR_DIR_ENTRYCOUNT`; exFAT and FAT don't return it (size 0 there). UI shows `--` for folders anyway (§5.5).
