# macExplorer Phase 1, Slice S3 (fileops) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the crash-safe file-operation engine of spec §6 (`Core/FileOps`): the job model, the app-wide `FileOpQueue` with plan/execute phases, every Phase 1 job kind (copy, move, trash, delete, duplicate, newItem, rename, alias, symlink, chmodRecursive, setAttributes, undo, redo), conflicts, the §6.5 error table, the journal and launch recovery, undo/redo, the main-actor `OperationsCenter`/`TerminationCoordinator`, and the `CoreEnvironment` that wires all of Core together (tasks P1-17 … P1-25).

**Architecture:** `FileOpQueue` (actor) only schedules and mirrors state; each job runs in a `JobRunner` that owns a `JobContext` (a `Sendable` final class whose mutable state sits in a `Mutex`). Every blocking call (`fts`, `lstat`, `copyfile`, `removefile`, `renamex_np`, `trashItem`, `mkdir`, xattrs) runs inside `LanePool.perform(on:, .fileOp)` lane work; the async job code between lane calls asks the user (through `FileOpInteraction`), writes the `Journal` (an actor whose executor is a private `DispatchSerialQueue`, so its small file writes never run on the cooperative pool), and checks pause/cancel. Lane work is written as resumable steps (a tree copy returns at the first failing entry with its state; the async side asks Retry/Skip/Cancel and resumes), so no lane thread ever waits for the UI.

**Tech Stack:** Swift 6.4 (Swift 6 language mode), Foundation, Darwin (`fts`, `copyfile`, `removefile`, `renamex_np`, `lchflags`, xattr), Synchronization (`Mutex`), Dispatch (`DispatchSerialQueue` as an actor executor), XCTest via `swift test`, `hdiutil` through `MacxFixtures.DiskImage`.

**Spec:** `docs/superpowers/specs/2026-11-01-macexplorer-design.md` (§4.2 lanes and materialization, §4.3 FolderModel/LocalChange, §5.6 rename rules and clipboard, §6.1–§6.7 file operations, §9 CoreTests). Interface contract and task index: `docs/superpowers/plans/2026-11-01-phase1-00-overview.md` (§3.13 is binding for this slice; §3.12 for `CoreEnvironment`).

## Global Constraints

Global Constraints: see overview, all apply. These are repeated or added for this slice:

- **HARD SAFETY RULE.** Tests, benchmarks and any manual or automated validation create, modify or delete files ONLY inside fresh temporary directories they create themselves (`FileManager.default.temporaryDirectory/macx-tests-<UUID>`, through `MacxFixtures.Sandbox`) or inside disk images they create inside such a directory (attached with `-mountpoint <sandbox>/mnt-<n> -nobrowse`). They never touch, move, rename, trash or delete any pre-existing user file. Every FileOps test goes through `FileOpsTestCase.run(_:on:)`, which fails the test before enqueueing if any URL in the `JobKind` is outside the sandbox root. Tests never use `SystemTrash` except on a test-created disk image, never the real journal path (`StatePaths.standard()`), never `UserDefaults`, never `NSPasteboard.general`.
- **Recovery is conservative.** `LaunchRecovery` only deletes paths whose last component matches `^\..+\.macx-partial-[0-9a-f]{8}$` and that the journal names; it restores a trashed destination or a two-step rename only when the original path is free. It never deletes anything else.
- **Never lose the source.** Cross-volume moves delete the source only after the partial copy is verified and renamed into place (§6.3). Replace trashes the existing item, never deletes it, and only after the new copy is verified.
- **Symlinks are never followed** by any recursive operation (`FTS_PHYSICAL`, `COPYFILE_NOFOLLOW_SRC`, `lstat`, `lchflags`).
- No blocking file-system call outside lane work, except `Journal` writes, which run on the journal actor's own serial queue (never the cooperative pool, never the main thread). Every lane-side helper calls `assertOffMain()`.
- Core produces no user-visible English text: errors are `FileOpErrorKind`, descriptions are `JobDescription`.
- Test-only knobs live as `internal` stored properties of `FileOpTuning` (`allowClone`, `forceCrossVolume`, `bodyOverride`) and are reached with `@testable import Core`; the public `FileOpTuning.init` is exactly the contract's.
- Every task ends with `swift build 2>&1 | tail -5` showing `Build complete!` with zero warnings and the task's `swift test --filter` run showing `Executed N tests, with 0 failures` (tests that need `hdiutil` report as skipped, not failed, when it is unavailable).

## Review Focus

Inputs the spec implies, that spec-derived tests would not naturally exercise, most likely to bite a user first. Items 1, 2 and 3 are the overview's Review Focus 1, 4 and 5 (mandatory tests, same names).

1. **Paste / Move Item Here of a folder into itself or a descendant** → the plan refuses only that item with `.intoItself`, nothing is copied recursively, other items proceed. P1-18 `testPlanRefusesCopyAndMoveIntoSelfOrDescendant`; P1-20 `testCopyJobIntoOwnDescendantSkipsOnlyThatItem`.
2. **Symlinks to directories and symlink loops inside a copied tree** → links are copied as links, counted once, recursion terminates. P1-20 `testCopyTreeWithSymlinkLoopCopiesLinksAndTerminates`.
3. **A source file that changes while a cross-volume move copies it** → verification fails, the partial is removed, the source is not deleted, the item reports `.changedDuringMove` (Retry/Skip/Cancel). P1-21 `testCrossVolumeMoveKeepsSourceWhenItChangesDuringCopy`.
4. **Cancel in the middle of a large file inside a folder copy** → no half-written file remains, and no copied directory is left at mode 0700 or without its metadata. P1-20 `testCancelMidFileRemovesPartialFileAndFinalizesDirectories`.
5. **Undo after the user re-created something at the original path** (moved `a.txt` away, then saved a new `a.txt` where it was) → undo never overwrites; it asks the conflict question (default Skip) and both files survive. P1-24 `testUndoIntoOccupiedPathAsksConflictAndNeverOverwrites`.

---

## Consumed from other slices (exact names)

From the contract (§3): `LanePool.perform(on:_:stallPolicy:onStall:_:)`, `LaneContext.heartbeat()/isCancelled`, `LaneClass.fileOp`, `VolumeID(raw:)`, `VolumeID.unknown`, `withNoMaterialization(_:)`, `assertOffMain()`, `ObserverToken`, `Observers<Event>`, `LocalChange`, `ChangeBus`, `FolderModel`, `FolderContext`, `Volumes`, `MountTableStore`, `DirectoryReaders`, `Watcher`, `Settings`, `InMemorySettingsStorage`, `ProtectedLocations.classify`, `Clipboard`, `PasteboardBackend`, `InMemoryPasteboard`, `LaunchServicesCache`, `FakeLaunchServices`, `LaunchServicesProviding`, `EjectCoordinator`, `Ejecting`, `EjectError`, `VolumeScanning`, `SystemVolumeScanner`, `VolumeEventSource`, `StatePaths`, `TypeRegistry.shared`, `NameNormalizer.sameName`.

From P1-02 (S1, `MacxFixtures`; not in the §3 contract, see Contract notes 1): `Sandbox` and `DiskImage`, with the exact names of the S1 plan's P1-02 Interfaces block. This slice uses only these members, all of them through one adapter file (`Tests/CoreTests/FileOps/FileOpsTestSupport.swift`) so a naming difference is fixed in one place:

```swift
public final class Sandbox: Sendable {
    public init(prefix: String = "macx-tests") throws           // creates $TMPDIR/<prefix>-<UUID>
    public let root: URL                                        // symlink-resolved
    public func url(_ relative: String, file: StaticString = #fileID, line: UInt = #line) -> URL   // traps if it escapes root
    @discardableResult public func createDirectory(_ relative: String) throws -> URL               // mkdir -p; existing is fine
    @discardableResult public func createFile(_ relative: String, contents: Data = Data("x".utf8)) throws -> URL   // creates parent dirs
    public func destroy()                                       // idempotent; detaches images, unlocks, deletes root only
}
public enum DiskImageFormat: String, Sendable, CaseIterable { case apfs = "APFS", hfsPlus = "HFS+", exfat = "ExFAT", msdos = "MS-DOS" }
public final class DiskImage: Sendable {
    public static var isAvailable: Bool { get }                 // hdiutil present and usable
    public static func create(in sandbox: Sandbox, format: DiskImageFormat, sizeMB: Int = 32, volumeName: String = "MACXTEST",
                              readOnly: Bool = false, populate: ((URL) throws -> Void)? = nil) throws -> DiskImage
    public let mountPoint: URL                                  // <sandbox>/mnt-<n>, attached -nobrowse
    public func detach() throws                                 // hdiutil detach -force; idempotent
}
```

## File structure (this slice)

```
Sources/Core/FileOps/JobTypes.swift            [P1-17] JobID, OriginID, NewItemKind, ModeChange, AttributeEdit, JobKind (+ allURLs), JobRequest, JobState, JobVerb, JobDescription, JobSnapshot, PartialName
Sources/Core/FileOps/JobProgress.swift         [P1-17] JobProgress, ThroughputMeter, Duration.inSeconds
Sources/Core/FileOps/FileOpError.swift         [P1-17] ErrorResolution, FileOpErrorKind (errno map, §6.5 actions), FileOpError
Sources/Core/FileOps/Interaction.swift         [P1-17] ItemSummary … FileOpInteraction, InteractionProxy, ScriptedInteraction
Sources/Core/FileOps/JobRecord.swift           [P1-17] FileIdentity, AttributeSnapshot, ItemAction, JobRecord, SkippedItem, JobOutcome
Sources/Core/FileOps/Journal.swift             [P1-17] JournalEntry, Journal (actor on a private serial queue, atomic writes)
Sources/Core/FileOps/LaunchRecovery.swift      [P1-17] RecoveryReport, LaunchRecovery
Sources/Core/FileOps/TrashService.swift        [P1-17] TrashService, SystemTrash, SandboxTrash
Sources/Core/FileOps/FaultPoint.swift          [P1-17] FaultPoint
Sources/Core/FileOps/PosixFS.swift             [P1-17] internal lane-only POSIX helpers (lstat info, rename, removeTree, clearImmutable, mount point, tree stats)
Sources/Core/FileOps/FileOpQueue.swift         [P1-18] FileOpTuning, JobEvent, FileOpQueue
Sources/Core/FileOps/JobRunner.swift           [P1-18] JobControl, JobContext, StepResult, JobRunner (dispatch per JobKind)
Sources/Core/FileOps/Planner.swift             [P1-18] PlanEntry, PlanItem, JobPlan, Planner (fts, existence, counts, space, self/descendant)
Sources/Core/FileOps/VolumeIdentity.swift      [P1-18] st_dev comparison, capabilities, lane volume key
Sources/Core/FileOps/RenamePrimitive.swift     [P1-19] RenamePrimitive
Sources/Core/FileOps/NameGenerator.swift       [P1-19] NameGenerator
Sources/Core/FileOps/CreateOps.swift           [P1-19] newItem and rename jobs
Sources/Core/FileOps/CopyEngine.swift          [P1-20] copyfile per item, directory pre/post-order, TreeCopyState, TreeCopier
Sources/Core/FileOps/CopyJob.swift             [P1-20] copy and duplicate jobs
Sources/Core/FileOps/MoveJob.swift             [P1-21] same-volume and cross-volume moves
Sources/Core/FileOps/ConflictExecutor.swift    [P1-22] Replace / Skip / Keep Both / Merge, apply-to-all, per-item
Sources/Core/FileOps/TrashDeleteJobs.swift     [P1-23] trash (+ no-trash fallback), permanent delete
Sources/Core/FileOps/LinkJobs.swift            [P1-23] alias, symlink
Sources/Core/FileOps/AttributeJobs.swift       [P1-23] setAttributes, chmodRecursive, snapshot apply
Sources/Core/FileOps/UndoPlanner.swift         [P1-24] JobRecord → inverse steps, execution
Sources/Core/FileOps/FileOpUndoStack.swift     [P1-24] app-wide UndoManager
Sources/Core/FileOps/OperationsCenter.swift    [P1-25] @MainActor @Observable job mirror
Sources/Core/FileOps/TerminationCoordinator.swift [P1-25]
Sources/Core/Support/CoreEnvironment.swift     [P1-25] wiring, folderContext(), start() (launch recovery), sandboxed(root:)
Sources/Core/Support/SandboxEjector.swift      [P1-25] Ejecting that only detaches images under a sandbox root (new file; Contract notes 8)
Tests/CoreTests/FileOps/FileOpsTestSupport.swift [P1-17, P1-24] FileOpsTestCase base class (sandbox, images, guarded run); FileOpsWorld (Sendable view for @MainActor tests)
Tests/CoreTests/FileOps/FileOpErrorTests.swift [P1-17] errno map, resolutions, progress meter, interaction proxy/scripted
Tests/CoreTests/FileOps/JournalTests.swift     [P1-17] journal, recovery, trash services
Tests/CoreTests/FileOps/QueueTests.swift       [P1-18]
Tests/CoreTests/FileOps/PlannerTests.swift     [P1-18]
Tests/CoreTests/FileOps/RenameTests.swift      [P1-19]
Tests/CoreTests/FileOps/CopyTests.swift        [P1-20]
Tests/CoreTests/FileOps/MoveTests.swift        [P1-21]
Tests/CoreTests/FileOps/CrashHelper.swift      [P1-21] child-process entry point + launcher
Tests/CoreTests/FileOps/CrashRecoveryTests.swift [P1-21, P1-22]
Tests/CoreTests/FileOps/ConflictTests.swift    [P1-22]
Tests/CoreTests/FileOps/TrashDeleteTests.swift [P1-23] trash, delete, alias, symlink, attributes, chmod
Tests/CoreTests/FileOps/ErrorTableTests.swift  [P1-23]
Tests/CoreTests/FileOps/UndoTests.swift        [P1-24] UndoTests (undo/redo jobs), UndoStackTests (FileOpUndoStack)
Tests/CoreTests/OperationsCenterTests.swift    [P1-25] OperationsCenterTests, TerminationTests, EnvironmentTests (incl. end-to-end), SandboxEjectorTests
```

---

### Task P1-17: FileOps foundation (types, errors, interaction, records, journal, recovery, trash)

Spec: §6.1 (job kinds, progress, per-item records), §6.2 (throughput samples, ETA), §6.3 (journal, partial names, launch cleanup), §6.4/§6.5 (conflict and error vocabularies, action table), §6.6 (records feed undo), §4.2 (lanes), §9 CoreTests.

**Files:**
- Create: `Sources/Core/FileOps/JobTypes.swift`, `JobProgress.swift`, `FileOpError.swift`, `Interaction.swift`, `JobRecord.swift`, `Journal.swift`, `LaunchRecovery.swift`, `TrashService.swift`, `FaultPoint.swift`, `PosixFS.swift`
- Test: `Tests/CoreTests/FileOps/FileOpsTestSupport.swift`, `Tests/CoreTests/FileOps/FileOpErrorTests.swift`, `Tests/CoreTests/FileOps/JournalTests.swift`

**Interfaces:**
- Consumes: `LanePool.perform(on:_:stallPolicy:onStall:_:)`, `LaneClass.fileOp`, `VolumeID.unknown`, `assertOffMain()`, `LocalChange` (P1-10), `Sandbox`/`DiskImage` (P1-02).
- Produces (contract §3.13, copied exactly; additive members marked *additive*):

```swift
public struct JobID: Hashable, Sendable, Codable, CustomStringConvertible { public let raw: UUID; public init() }
//   additive: public var short: String  (first 8 lowercase hex chars; used in partial names)
public struct OriginID: Hashable, Sendable, Codable { public let raw: Int; public init(raw: Int) }
public enum NewItemKind: String, Sendable, Codable { case folder, textFile, emptyFile }
public struct ModeChange: Sendable, Codable, Equatable { public var mode: UInt16; public var applyToDirectories: Bool; public var applyToFiles: Bool
    public init(mode: UInt16, applyToDirectories: Bool = true, applyToFiles: Bool = true) }
public enum AttributeEdit: Sendable, Codable, Equatable { case locked(Bool), hidden(Bool), extensionHidden(Bool), permissions(UInt16), removeQuarantine }
public indirect enum JobKind: Sendable, Equatable { case copy(sources: [URL], destination: URL), move(sources: [URL], destination: URL), trash([URL]), delete([URL]),
    duplicate([URL]), newItem(NewItemKind, in: URL), rename(URL, to: String), alias(sources: [URL], destination: URL), symlink(sources: [URL], destination: URL),
    chmodRecursive(URL, ModeChange), setAttributes([URL], AttributeEdit), undo(JobRecord), redo(JobRecord) }
public struct JobRequest: Sendable { public var kind: JobKind; public var origin: OriginID?; public var registersUndo: Bool
    public init(_ kind: JobKind, origin: OriginID? = nil, registersUndo: Bool = true) }
public enum JobState: Sendable, Equatable { case queued, planning, running, paused, waitingForUser, cancelling, finished }
public enum JobVerb: String, Sendable, Codable { case copying, moving, trashing, deleting, duplicating, creating, renaming, makingAlias, makingSymlink, changingPermissions, changingAttributes, undoing, redoing }
public struct JobDescription: Sendable, Equatable { public var verb: JobVerb; public var itemCount: Int; public var firstItemName: String?; public var sourceFolderName: String?; public var destinationFolderName: String? }
//   additive: Codable (JournalEntry.jobStarted stores it; see Contract notes 2), public memberwise init
public struct JobSnapshot: Sendable, Identifiable, Equatable { public var id: JobID; public var description: JobDescription; public var state: JobState
    public var progress: JobProgress; public var origin: OriginID?; public var startedAt: ContinuousClock.Instant }
public struct JobProgress: Sendable, Equatable { itemsDone, itemsTotal, bytesDone, bytesTotal, currentItem, throughput, estimatedRemaining; public var fraction: Double? { get }; public static let zero }
public enum ErrorResolution: Sendable, Equatable { case retry, skip, skipAll, cancel, unlockAndContinue, continueAnyway }
public enum FileOpErrorKind: Sendable, Equatable { … ; public init(errno: Int32, isLockedItem: Bool); public var allowedResolutions: [ErrorResolution] { get } }
public struct FileOpError: Error, Sendable, Equatable { public var kind: FileOpErrorKind; public var url: URL; public var destination: URL?; public init(kind:url:destination:) }
public protocol FileOpInteraction: Sendable { resolveConflict, resolveError, confirmInsufficientSpace, confirmPermanentDeleteWithoutTrash }
public final class InteractionProxy: FileOpInteraction { public init(); public func setTarget(_ target: any FileOpInteraction) }
public final class ScriptedInteraction: FileOpInteraction { public init(conflicts:errors:space:noTrash:); public func askedConflicts() -> [ConflictInfo]; public func askedErrors() -> [FileOpError] }
//   additive: askedSpace() -> [SpaceShortfall], askedNoTrash() -> [[URL]]
public struct FileIdentity: Sendable, Codable, Hashable { device, inode; public init(device:inode:); public static func of(path: String) -> FileIdentity? }
public struct AttributeSnapshot / public enum ItemAction / public struct JobRecord (isUndoable) / SkippedItem / JobOutcome   // exactly §3.13
//   additive: public memberwise inits for AttributeSnapshot, JobRecord, SkippedItem, JobOutcome
public protocol TrashService: Sendable { func trash(_ url: URL) throws -> URL }
public struct SystemTrash: TrashService { public init() }
public struct SandboxTrash: TrashService { public init(directory: URL) }
//   additive: public init(directory: URL, refusingPathsUnder: [URL])  (simulates volumes without a Trash)
public enum JournalEntry: Sendable, Codable, Equatable { partial, trashedDestination, twoStepRename, jobStarted }
//   additive: public var job: JobID { get }
public actor Journal { public init(fileURL: URL); record, clear, finish(job:), entries() }
public struct RecoveryReport: Sendable, Equatable { removedPartials, restoredDestinations, restoredRenames, incompleteJobs; isEmpty }   // additive: public init()
public enum LaunchRecovery { public static func run(journal: Journal, lanes: LanePool) async -> RecoveryReport }
public enum FaultPoint: String, Sendable, CaseIterable { case afterPartialCopy, beforePartialRename, afterTrashDestination, beforeSourceDelete, midCopyChunk, afterFirstItem }
// internal
enum PartialName { static func make(for name: String, job: JobID) -> String; static func isPartial(_ lastComponent: String) -> Bool }
enum PosixFS { struct Info; static func info(_:) -> Info?; exists; rename; removeTree; clearImmutable; mountPoint(of:); treeStats(_:) }
```

- [ ] **Step 1: Write the test support base class**

`Tests/CoreTests/FileOps/FileOpsTestSupport.swift`:

```swift
import XCTest
import Foundation
import Darwin
@testable import Core
import MacxFS
import MacxFixtures

/// Base class for every FileOps test. Every path a test touches comes from `sandbox`.
/// Teardown blocks (image detach) run first, then `tearDown` unlocks and deletes ONLY the sandbox root.
class FileOpsTestCase: XCTestCase {
    private(set) var sandbox: Sandbox!
    var root: URL { sandbox.root }
    var trashDir: URL { root.appending(path: ".trash", directoryHint: .isDirectory) }
    var journalURL: URL { root.appending(path: "state/journal.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = try Sandbox(prefix: "macx-tests")
        try sandbox.createDirectory("state")
        try sandbox.createDirectory(".trash")
    }

    override func tearDownWithError() throws {
        if let sandbox {
            Self.unlockTree(sandbox.root)
            sandbox.destroy()
        }
        sandbox = nil
        try super.tearDownWithError()
    }

    /// Clears uchg and restores u+rwx under the sandbox so it can be removed. Refuses anything else.
    static func unlockTree(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(tmp + "/"), url.lastPathComponent.hasPrefix("macx-tests-") else {
            preconditionFailure("unlockTree refused \(path)")
        }
        for (tool, args) in [("/usr/bin/chflags", ["-R", "nouchg", path]), ("/bin/chmod", ["-R", "u+rwx", path])] {
            let p = Process()
            p.executableURL = URL(filePath: tool)
            p.arguments = args
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    // MARK: fixtures (all through Sandbox)

    @discardableResult func file(_ rel: String, _ text: String = "x") throws -> URL {
        try sandbox.createFile(rel, contents: Data(text.utf8))
    }
    @discardableResult func bigFile(_ rel: String, bytes: Int) throws -> URL {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<bytes { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }   // incompressible enough, not sparse
        }
        return try sandbox.createFile(rel, contents: data)
    }
    @discardableResult func dir(_ rel: String) throws -> URL { try sandbox.createDirectory(rel) }
    func url(_ rel: String) -> URL { sandbox.url(rel) }

    /// A disk image inside the sandbox; detached in a teardown block. Skips the test when hdiutil is unavailable.
    func image(_ format: DiskImageFormat = .hfsPlus, sizeMB: Int = 64, readOnly: Bool = false) throws -> URL {
        guard DiskImage.isAvailable else { throw XCTSkip("hdiutil unavailable") }
        let image = try DiskImage.create(in: sandbox, format: format, sizeMB: sizeMB, readOnly: readOnly)
        addTeardownBlock { try? image.detach() }
        return image.mountPoint
    }

    // MARK: queue

    func makeQueue(interaction: ScriptedInteraction = ScriptedInteraction(),
                   tuning: FileOpTuning = FileOpTuning(),
                   trash: (any TrashService)? = nil) -> (FileOpQueue, Journal) {
        let journal = Journal(fileURL: journalURL)
        let queue = FileOpQueue(lanes: LanePool(), trash: trash ?? SandboxTrash(directory: trashDir),
                                journal: journal, interaction: interaction, tuning: tuning)
        return (queue, journal)
    }

    /// The only way FileOps tests start jobs: refuses (fails the test, does not enqueue) any URL outside the sandbox.
    func run(_ kind: JobKind, on queue: FileOpQueue, file: StaticString = #filePath, line: UInt = #line) async throws -> JobOutcome {
        let rootPath = root.path + "/"
        for u in kind.allURLs where !(u.standardizedFileURL.path + "/").hasPrefix(rootPath) {
            XCTFail("URL outside the sandbox: \(u.path)", file: file, line: line)
            throw XCTSkip("refused to run a job outside the sandbox")
        }
        let id = await queue.enqueue(JobRequest(kind))
        return await queue.outcome(of: id)
    }

    // MARK: inspection (read-only)

    func text(_ u: URL) -> String? { (try? Data(contentsOf: u)).map { String(decoding: $0, as: UTF8.self) } }
    func names(_ u: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }
    func exists(_ u: URL) -> Bool { var st = stat(); return lstat(u.path, &st) == 0 }
    func lst(_ u: URL) -> stat { var st = stat(); _ = lstat(u.path, &st); return st }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: @escaping @Sendable () async -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout)", file: file, line: line)
    }
}
```

- [ ] **Step 2: Write the failing tests for errors, progress and interaction**

`Tests/CoreTests/FileOps/FileOpErrorTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core

final class FileOpErrorTests: XCTestCase {
    func testErrnoMapping() {
        XCTAssertEqual(FileOpErrorKind(errno: EACCES, isLockedItem: false), .permissionDenied)
        XCTAssertEqual(FileOpErrorKind(errno: EPERM, isLockedItem: false), .blockedByMacOS)
        XCTAssertEqual(FileOpErrorKind(errno: EPERM, isLockedItem: true), .locked)
        XCTAssertEqual(FileOpErrorKind(errno: EROFS, isLockedItem: false), .readOnlyVolume)
        XCTAssertEqual(FileOpErrorKind(errno: ENOSPC, isLockedItem: false), .noSpace(needed: nil, available: nil))
        XCTAssertEqual(FileOpErrorKind(errno: EBUSY, isLockedItem: false), .inUse)
        XCTAssertEqual(FileOpErrorKind(errno: ETXTBSY, isLockedItem: false), .inUse)
        XCTAssertEqual(FileOpErrorKind(errno: ENAMETOOLONG, isLockedItem: false), .nameTooLong)
        XCTAssertEqual(FileOpErrorKind(errno: ENOENT, isLockedItem: false), .sourceGone)
        guard case .other(let code, let message) = FileOpErrorKind(errno: EIO, isLockedItem: false) else { return XCTFail() }
        XCTAssertEqual(code, EIO)
        XCTAssertFalse(message.isEmpty)
    }

    /// §6.5 table, row by row.
    func testAllowedResolutionsMatchSpecTable() {
        XCTAssertEqual(FileOpErrorKind.permissionDenied.allowedResolutions, [.retry, .skip, .skipAll, .cancel])
        XCTAssertEqual(FileOpErrorKind.blockedByMacOS.allowedResolutions, [.retry, .skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.locked.allowedResolutions, [.unlockAndContinue, .skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.readOnlyVolume.allowedResolutions, [.cancel])
        XCTAssertEqual(FileOpErrorKind.noSpace(needed: 1, available: 0).allowedResolutions, [.retry, .cancel])
        XCTAssertEqual(FileOpErrorKind.inUse.allowedResolutions, [.retry, .skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.nameTooLong.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.sourceGone.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.intoItself.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.changedDuringMove.allowedResolutions, [.retry, .skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.noTrash.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.other(code: EIO, message: "x").allowedResolutions, [.retry, .skip, .cancel])
    }

    func testProgressFraction() {
        var p = JobProgress.zero
        XCTAssertNil(p.fraction)
        p.itemsTotal = 4; p.itemsDone = 1
        XCTAssertEqual(p.fraction, 0.25)
        p.bytesTotal = 200; p.bytesDone = 150
        XCTAssertEqual(p.fraction, 0.75)          // bytes win when known
        p.itemsTotal = 0; p.bytesTotal = nil
        XCTAssertEqual(p.fraction, 1)
    }

    func testThroughputMeterKeeps60SamplesAndEstimates() {
        var meter = ThroughputMeter()
        let t0 = ContinuousClock.now
        for i in 0...100 { meter.sample(bytesDone: Int64(i) * 1_000, at: t0 + .milliseconds(100 * i)) }
        XCTAssertEqual(meter.samples.count, 60)
        XCTAssertEqual(meter.samples.last!, 10_000, accuracy: 1)       // 1,000 bytes per 100 ms
        let eta = meter.estimatedRemaining(bytesDone: 100_000, bytesTotal: 150_000)
        XCTAssertEqual(eta!.inSeconds, 5, accuracy: 0.1)
        XCTAssertEqual(meter.estimatedRemaining(bytesDone: 5, bytesTotal: 5), .zero)
    }

    func testPartialNameShapeAndLimit() {
        let job = JobID()
        let name = PartialName.make(for: "report.pdf", job: job)
        XCTAssertEqual(name, ".report.pdf.macx-partial-\(job.short)")
        XCTAssertTrue(PartialName.isPartial(name))
        XCTAssertFalse(PartialName.isPartial("report.pdf"))
        XCTAssertFalse(PartialName.isPartial(".report.pdf.macx-partial-XYZ"))
        let long = PartialName.make(for: String(repeating: "é", count: 127), job: job)   // 254 UTF-8 bytes
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertTrue(PartialName.isPartial(long))
    }

    func testInteractionProxySuspendsUntilTargetIsSet() async {
        let proxy = InteractionProxy()
        let scripted = ScriptedInteraction(errors: [.retry])
        let snapshot = JobSnapshot.testValue
        let task = Task { await proxy.resolveError(FileOpError(kind: .inUse, url: URL(filePath: "/x")), job: snapshot) }
        try? await Task.sleep(for: .milliseconds(50))
        proxy.setTarget(scripted)
        let answer = await task.value
        XCTAssertEqual(answer, .retry)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.inUse])
    }

    func testScriptedInteractionDefaults() async {
        let s = ScriptedInteraction()
        let snap = JobSnapshot.testValue
        let pair = ConflictPair(source: .init(url: URL(filePath: "/a"), isDirectory: false, size: 1, modified: .now),
                                destination: .init(url: URL(filePath: "/b"), isDirectory: false, size: 1, modified: .now))
        let info = ConflictInfo(pair: pair, isFolderMerge: false, knownRemaining: 1, pendingPairs: [pair])
        let r = await s.resolveConflict(info, job: snap)
        XCTAssertEqual(r, .one(.skip))
        let e = await s.resolveError(FileOpError(kind: .inUse, url: URL(filePath: "/a")), job: snap)
        XCTAssertEqual(e, .skip)
        let space = await s.confirmInsufficientSpace(SpaceShortfall(needed: 2, available: 1, volumeName: "v"), job: snap)
        XCTAssertFalse(space)
        let noTrash = await s.confirmPermanentDeleteWithoutTrash([URL(filePath: "/a")], job: snap)
        XCTAssertFalse(noTrash)
        XCTAssertEqual(s.askedConflicts().count, 1)
    }

    func testRecordUndoability() {
        let id = FileIdentity(device: 1, inode: 2)
        XCTAssertFalse(JobRecord(id: JobID(), verb: .copying, actions: []).isUndoable)
        XCTAssertTrue(JobRecord(id: JobID(), verb: .copying, actions: [.created(URL(filePath: "/a"), id)]).isUndoable)
        XCTAssertFalse(JobRecord(id: JobID(), verb: .deleting, actions: [.deleted(URL(filePath: "/a"))]).isUndoable)
    }
}

extension JobSnapshot {
    static var testValue: JobSnapshot {
        JobSnapshot(id: JobID(), description: JobDescription(verb: .copying, itemCount: 1, firstItemName: "a",
                                                             sourceFolderName: nil, destinationFolderName: nil),
                    state: .running, progress: .zero, origin: nil, startedAt: .now)
    }
}
```

- [ ] **Step 3: Write the failing journal, recovery and trash tests**

`Tests/CoreTests/FileOps/JournalTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

final class JournalTests: FileOpsTestCase {
    func testRecordClearFinishPersistAcrossInstances() async throws {
        let job = JobID()
        let j1 = Journal(fileURL: journalURL)
        let partial = url("dst/.a.macx-partial-\(job.short)")
        try await j1.record(.jobStarted(job: job, description: JobDescription(verb: .moving, itemCount: 1, firstItemName: "a", sourceFolderName: "src", destinationFolderName: "dst")))
        try await j1.record(.partial(job: job, url: partial))
        let j2 = Journal(fileURL: journalURL)                     // as after a relaunch
        let reloaded = await j2.entries()
        XCTAssertEqual(reloaded.count, 2)
        try await j2.clear(.partial(job: job, url: partial))
        let afterClear = await Journal(fileURL: journalURL).entries()
        XCTAssertEqual(afterClear.count, 1)
        try await j2.finish(job: job)
        let afterFinish = await Journal(fileURL: journalURL).entries()
        XCTAssertEqual(afterFinish, [])
    }

    func testJournalFileIsAlwaysValidJSON() async throws {
        let j = Journal(fileURL: journalURL)
        for i in 0..<50 { try await j.record(.partial(job: JobID(), url: url("p\(i)"))) }
        let data = try Data(contentsOf: journalURL)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        XCTAssertFalse(names(url("state")).contains { $0.hasPrefix(".dat") || $0.hasSuffix(".tmp") }, "no temp leftovers")
    }

    func testCorruptJournalIsSetAsideNotDeleted() async throws {
        try file("state/journal.json", "{ not json")
        let j = Journal(fileURL: journalURL)
        let entries = await j.entries()
        XCTAssertEqual(entries, [])
        XCTAssertTrue(names(url("state")).contains { $0.hasPrefix("journal.corrupt-") })
    }

    func testRecoveryRemovesJournaledPartialsOnly() async throws {
        let job = JobID()
        let partialName = PartialName.make(for: "big", job: job)
        try dir("dst/\(partialName)/inner")
        try file("dst/\(partialName)/inner/f", "partial bytes")
        let impostor = try file("dst/not-a-partial", "user data")      // journaled by a bug: must survive
        let j = Journal(fileURL: journalURL)
        try await j.record(.jobStarted(job: job, description: JobDescription(verb: .moving, itemCount: 1, firstItemName: "big", sourceFolderName: nil, destinationFolderName: nil)))
        try await j.record(.partial(job: job, url: url("dst/\(partialName)")))
        try await j.record(.partial(job: job, url: impostor))
        let report = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(report.removedPartials, [url("dst/\(partialName)")])
        XCTAssertFalse(exists(url("dst/\(partialName)")))
        XCTAssertEqual(text(impostor), "user data")
        XCTAssertEqual(report.incompleteJobs.map(\.firstItemName), ["big"])
        let left = await j.entries()
        XCTAssertEqual(left, [])
    }

    func testRecoveryRemovesLockedPartialTree() async throws {
        let job = JobID()
        let p = PartialName.make(for: "locked", job: job)
        try file("dst/\(p)/f", "x")
        XCTAssertEqual(lchflags(url("dst/\(p)/f").path, UInt32(UF_IMMUTABLE)), 0)
        let j = Journal(fileURL: journalURL)
        try await j.record(.partial(job: job, url: url("dst/\(p)")))
        let report = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(report.removedPartials.count, 1)
        XCTAssertFalse(exists(url("dst/\(p)")))
    }

    func testRecoveryRestoresTrashedDestinationOnlyWhenOriginalIsFree() async throws {
        let job = JobID()
        let trashed = try file(".trash/b1/a.txt", "old")
        let trashed2 = try file(".trash/b2/c.txt", "old c")
        try file("dst/c.txt", "new c")                                  // replacement landed
        let j = Journal(fileURL: journalURL)
        try await j.record(.trashedDestination(job: job, original: url("dst/a.txt"), trashURL: trashed))
        try await j.record(.trashedDestination(job: job, original: url("dst/c.txt"), trashURL: trashed2))
        let report = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(report.restoredDestinations, [url("dst/a.txt")])
        XCTAssertEqual(text(url("dst/a.txt")), "old")
        XCTAssertEqual(text(url("dst/c.txt")), "new c")
        XCTAssertEqual(text(trashed2), "old c")                          // stays in the trash
    }

    func testRecoveryRestoresInterruptedTwoStepRename() async throws {
        let job = JobID()
        let temp = try file("d/.tmp.macx-rename-\(job.short)", "content")
        let j = Journal(fileURL: journalURL)
        try await j.record(.twoStepRename(job: job, temporary: temp, original: url("d/a.txt"), target: url("d/A.txt")))
        let report = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(report.restoredRenames, [url("d/a.txt")])
        XCTAssertEqual(text(url("d/a.txt")), "content")
        XCTAssertFalse(exists(temp))
    }

    func testEmptyJournalYieldsEmptyReport() async {
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertTrue(report.isEmpty)
    }

    func testSandboxTrashMovesIntoBucketAndReturnsURL() async throws {
        let a = try file("a.txt", "A")
        let trash = SandboxTrash(directory: trashDir)
        let result = try await LanePool().perform(on: .unknown, .fileOp) { _ in try trash.trash(a) }
        XCTAssertFalse(exists(a))
        XCTAssertEqual(result.lastPathComponent, "a.txt")
        XCTAssertTrue(result.path.hasPrefix(trashDir.path + "/"))
        XCTAssertEqual(text(result), "A")
    }

    func testSandboxTrashRefusingPrefixThrowsNoTrash() async throws {
        let a = try file("nt/a.txt")
        let trash = SandboxTrash(directory: trashDir, refusingPathsUnder: [url("nt")])
        do {
            _ = try await LanePool().perform(on: .unknown, .fileOp) { _ in try trash.trash(a) }
            XCTFail("expected noTrash")
        } catch let e as FileOpError {
            XCTAssertEqual(e.kind, .noTrash)
        }
        XCTAssertTrue(exists(a))
    }

    /// SystemTrash only ever runs on a test-created image (its Trash is inside the image).
    func testSystemTrashOnDiskImage() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 32)
        let f = mnt.appending(path: "t.txt")
        try Data("t".utf8).write(to: f)
        let result = try await LanePool().perform(on: .unknown, .fileOp) { _ in try SystemTrash().trash(f) }
        XCTAssertTrue(result.path.hasPrefix(mnt.path + "/"), "trash of an image item stays on the image: \(result.path)")
        XCTAssertFalse(exists(f))
    }
}
```

`testSystemTrashOnDiskImage` writes with `Data.write(to:)` into the mount point. That point comes from `DiskImage`, so it is inside the sandbox.

- [ ] **Step 4: Run the tests and watch them fail**

Run: `swift test --filter 'CoreTests.(FileOpErrorTests|JournalTests)' 2>&1 | tail -15`
Expected: build failure, e.g. `error: cannot find 'FileOpErrorKind' in scope`.

- [ ] **Step 5: Implement `JobTypes.swift`**

```swift
import Foundation

public struct JobID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UUID
    public init() { raw = UUID() }
    public var description: String { raw.uuidString.lowercased() }
    /// First 8 hex chars; used in partial and temporary names.
    public var short: String { String(description.prefix(8)) }
}

public struct OriginID: Hashable, Sendable, Codable {
    public let raw: Int
    public init(raw: Int) { self.raw = raw }
}

/// "New Folder", "Untitled.txt", "Untitled".
public enum NewItemKind: String, Sendable, Codable { case folder, textFile, emptyFile }

public struct ModeChange: Sendable, Codable, Equatable {
    public var mode: UInt16
    public var applyToDirectories: Bool
    public var applyToFiles: Bool
    public init(mode: UInt16, applyToDirectories: Bool = true, applyToFiles: Bool = true) {
        self.mode = mode; self.applyToDirectories = applyToDirectories; self.applyToFiles = applyToFiles
    }
}

public enum AttributeEdit: Sendable, Codable, Equatable {
    case locked(Bool), hidden(Bool), extensionHidden(Bool), permissions(UInt16), removeQuarantine
}

public indirect enum JobKind: Sendable, Equatable {
    case copy(sources: [URL], destination: URL)
    case move(sources: [URL], destination: URL)
    case trash([URL])
    case delete([URL])
    case duplicate([URL])
    case newItem(NewItemKind, in: URL)
    case rename(URL, to: String)
    case alias(sources: [URL], destination: URL)
    case symlink(sources: [URL], destination: URL)
    case chmodRecursive(URL, ModeChange)
    case setAttributes([URL], AttributeEdit)
    case undo(JobRecord)
    case redo(JobRecord)
}

extension JobKind {
    /// Every path the job may read or write (scheduling, sandbox guard in tests).
    var allURLs: [URL] {
        switch self {
        case .copy(let s, let d), .move(let s, let d), .alias(let s, let d), .symlink(let s, let d): return s + [d]
        case .trash(let u), .delete(let u), .duplicate(let u), .setAttributes(let u, _): return u
        case .newItem(_, let d): return [d]
        case .rename(let u, _), .chmodRecursive(let u, _): return [u]
        case .undo(let r), .redo(let r): return r.actions.flatMap(\.urls)
        }
    }
    var verb: JobVerb {
        switch self {
        case .copy: .copying
        case .move: .moving
        case .trash: .trashing
        case .delete: .deleting
        case .duplicate: .duplicating
        case .newItem: .creating
        case .rename: .renaming
        case .alias: .makingAlias
        case .symlink: .makingSymlink
        case .chmodRecursive: .changingPermissions
        case .setAttributes: .changingAttributes
        case .undo: .undoing
        case .redo: .redoing
        }
    }
    var jobDescription: JobDescription {
        func folderName(_ u: URL?) -> String? { u.map { $0.deletingLastPathComponent().lastPathComponent } }
        switch self {
        case .copy(let s, let d), .move(let s, let d), .alias(let s, let d), .symlink(let s, let d):
            return JobDescription(verb: verb, itemCount: s.count, firstItemName: s.first?.lastPathComponent,
                                  sourceFolderName: folderName(s.first), destinationFolderName: d.lastPathComponent)
        case .trash(let u), .delete(let u), .duplicate(let u), .setAttributes(let u, _):
            return JobDescription(verb: verb, itemCount: u.count, firstItemName: u.first?.lastPathComponent,
                                  sourceFolderName: folderName(u.first), destinationFolderName: nil)
        case .newItem(_, let d):
            return JobDescription(verb: verb, itemCount: 1, firstItemName: nil, sourceFolderName: nil, destinationFolderName: d.lastPathComponent)
        case .rename(let u, _), .chmodRecursive(let u, _):
            return JobDescription(verb: verb, itemCount: 1, firstItemName: u.lastPathComponent,
                                  sourceFolderName: folderName(u), destinationFolderName: nil)
        case .undo(let r), .redo(let r):
            return JobDescription(verb: verb, itemCount: r.actions.count, firstItemName: r.actions.first?.urls.first?.lastPathComponent,
                                  sourceFolderName: nil, destinationFolderName: nil)
        }
    }
}

public struct JobRequest: Sendable {
    public var kind: JobKind
    public var origin: OriginID?
    public var registersUndo: Bool
    public init(_ kind: JobKind, origin: OriginID? = nil, registersUndo: Bool = true) {
        self.kind = kind; self.origin = origin; self.registersUndo = registersUndo
    }
}

public enum JobState: Sendable, Equatable { case queued, planning, running, paused, waitingForUser, cancelling, finished }

public enum JobVerb: String, Sendable, Codable {
    case copying, moving, trashing, deleting, duplicating, creating, renaming, makingAlias, makingSymlink,
         changingPermissions, changingAttributes, undoing, redoing
}

/// UI formats "Copying 1,204 items from Downloads to Backup".
public struct JobDescription: Sendable, Equatable, Codable {
    public var verb: JobVerb
    public var itemCount: Int
    public var firstItemName: String?
    public var sourceFolderName: String?
    public var destinationFolderName: String?
    public init(verb: JobVerb, itemCount: Int, firstItemName: String?, sourceFolderName: String?, destinationFolderName: String?) {
        self.verb = verb; self.itemCount = itemCount; self.firstItemName = firstItemName
        self.sourceFolderName = sourceFolderName; self.destinationFolderName = destinationFolderName
    }
}

public struct JobSnapshot: Sendable, Identifiable, Equatable {
    public var id: JobID
    public var description: JobDescription
    public var state: JobState
    public var progress: JobProgress
    public var origin: OriginID?
    public var startedAt: ContinuousClock.Instant
    public init(id: JobID, description: JobDescription, state: JobState, progress: JobProgress,
                origin: OriginID?, startedAt: ContinuousClock.Instant) {
        self.id = id; self.description = description; self.state = state
        self.progress = progress; self.origin = origin; self.startedAt = startedAt
    }
}

/// `.<name>.macx-partial-<job.short>`, truncating the name (on a character boundary) to stay within 255 bytes.
enum PartialName {
    static let marker = ".macx-partial-"
    static func make(for name: String, job: JobID) -> String {
        let suffix = marker + job.short
        var base = name
        while ("." + base + suffix).utf8.count > 255 { base.removeLast() }
        return "." + base + suffix
    }
    static func isPartial(_ lastComponent: String) -> Bool {
        lastComponent.wholeMatch(of: /\..+\.macx-partial-[0-9a-f]{8}/) != nil
    }
}
```

- [ ] **Step 6: Implement `JobProgress.swift`**

```swift
import Foundation

public struct JobProgress: Sendable, Equatable {
    public var itemsDone: Int = 0
    public var itemsTotal: Int? = nil            // nil while planning
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64? = nil
    public var currentItem: String? = nil
    public var throughput: [Double] = []         // bytes/s, oldest first, ≤ 60
    public var estimatedRemaining: Duration? = nil
    public init() {}
    public var fraction: Double? {
        if let bt = bytesTotal, bt > 0 { return min(1, Double(bytesDone) / Double(bt)) }
        if let it = itemsTotal {
            return it == 0 ? 1 : min(1, Double(itemsDone) / Double(it))
        }
        return nil
    }
    public static let zero = JobProgress()
}

/// 60-sample throughput history (§6.2) and ETA from the mean of the last 10 samples.
public struct ThroughputMeter: Sendable {
    public static let capacity = 60
    public private(set) var samples: [Double] = []
    private var lastBytes: Int64 = 0
    private var lastTime: ContinuousClock.Instant?
    public init() {}

    public mutating func sample(bytesDone: Int64, at now: ContinuousClock.Instant) {
        defer { lastBytes = bytesDone; lastTime = now }
        guard let t0 = lastTime else { return }
        let dt = (now - t0).inSeconds
        guard dt > 0 else { return }
        samples.append(max(0, Double(bytesDone - lastBytes) / dt))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    public func estimatedRemaining(bytesDone: Int64, bytesTotal: Int64?) -> Duration? {
        guard let total = bytesTotal else { return nil }
        guard total > bytesDone else { return .zero }
        let recent = samples.suffix(10)
        guard !recent.isEmpty else { return nil }
        let rate = recent.reduce(0, +) / Double(recent.count)
        guard rate > 0 else { return nil }
        return .milliseconds(Int64((Double(total - bytesDone) / rate * 1000).rounded()))
    }
}

extension Duration {
    var inSeconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
```

- [ ] **Step 7: Implement `FileOpError.swift`**

```swift
import Foundation
import Darwin

public enum ErrorResolution: Sendable, Equatable { case retry, skip, skipAll, cancel, unlockAndContinue, continueAnyway }

public enum FileOpErrorKind: Sendable, Equatable {
    case permissionDenied
    case blockedByMacOS
    case locked
    case readOnlyVolume
    case noSpace(needed: Int64?, available: Int64?)
    case inUse
    case nameTooLong
    case sourceGone
    case intoItself
    case changedDuringMove
    case noTrash
    case other(code: Int32, message: String)

    /// `isLockedItem`: the item (or its parent, for creates) has UF_IMMUTABLE; EPERM then means "locked".
    public init(errno code: Int32, isLockedItem: Bool) {
        switch code {
        case EACCES: self = .permissionDenied
        case EPERM: self = isLockedItem ? .locked : .blockedByMacOS
        case EROFS: self = .readOnlyVolume
        case ENOSPC, EDQUOT: self = .noSpace(needed: nil, available: nil)
        case EBUSY, ETXTBSY: self = .inUse
        case ENAMETOOLONG: self = .nameTooLong
        case ENOENT: self = .sourceGone
        default: self = .other(code: code, message: String(cString: strerror(code)))
        }
    }

    /// Maps a Foundation error (FileManager, URL resource APIs) by its POSIX code.
    init(error: any Error, isLockedItem: Bool) {
        if let e = error as? FileOpError { self = e.kind; return }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { self.init(errno: Int32(ns.code), isLockedItem: isLockedItem); return }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            self.init(errno: Int32(under.code), isLockedItem: isLockedItem); return
        }
        switch CocoaError.Code(rawValue: ns.code) {
        case .fileNoSuchFile, .fileReadNoSuchFile: self = .sourceGone
        case .fileWriteNoPermission, .fileReadNoPermission: self = .permissionDenied
        case .fileWriteVolumeReadOnly: self = .readOnlyVolume
        case .fileWriteOutOfSpace: self = .noSpace(needed: nil, available: nil)
        case .featureUnsupported: self = .noTrash
        default: self = .other(code: Int32(ns.code), message: ns.localizedDescription)
        }
    }

    /// §6.5 actions. The UI shows "Open Privacy Settings" for .blockedByMacOS and answers .retry after opening it.
    public var allowedResolutions: [ErrorResolution] {
        switch self {
        case .permissionDenied: [.retry, .skip, .skipAll, .cancel]
        case .blockedByMacOS: [.retry, .skip, .cancel]
        case .locked: [.unlockAndContinue, .skip, .cancel]
        case .readOnlyVolume: [.cancel]
        case .noSpace: [.retry, .cancel]
        case .inUse: [.retry, .skip, .cancel]
        case .nameTooLong, .sourceGone, .intoItself, .noTrash: [.skip, .cancel]
        case .changedDuringMove, .other: [.retry, .skip, .cancel]
        }
    }
}

public struct FileOpError: Error, Sendable, Equatable {
    public var kind: FileOpErrorKind
    public var url: URL
    public var destination: URL?
    public init(kind: FileOpErrorKind, url: URL, destination: URL? = nil) {
        self.kind = kind; self.url = url; self.destination = destination
    }
}
```

- [ ] **Step 8: Implement `Interaction.swift`**

```swift
import Foundation
import Synchronization

public struct ItemSummary: Sendable, Equatable {
    public var url: URL
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public init(url: URL, isDirectory: Bool, size: Int64, modified: Date) {
        self.url = url; self.isDirectory = isDirectory; self.size = size; self.modified = modified
    }
}
public struct ConflictPair: Sendable, Equatable {
    public var source: ItemSummary
    public var destination: ItemSummary
    public init(source: ItemSummary, destination: ItemSummary) { self.source = source; self.destination = destination }
}
public enum ConflictAction: String, Sendable, Codable { case replace, skip, keepBoth, merge }
public struct ConflictInfo: Sendable, Equatable {
    public var pair: ConflictPair
    public var isFolderMerge: Bool
    public var knownRemaining: Int
    public var pendingPairs: [ConflictPair]
    public init(pair: ConflictPair, isFolderMerge: Bool, knownRemaining: Int, pendingPairs: [ConflictPair]) {
        self.pair = pair; self.isFolderMerge = isFolderMerge; self.knownRemaining = knownRemaining; self.pendingPairs = pendingPairs
    }
}
public enum ConflictResolution: Sendable, Equatable {
    case one(ConflictAction)
    case all(ConflictAction)
    case perItem([URL: ConflictAction])
    case cancelJob
}
public struct SpaceShortfall: Sendable, Equatable {
    public var needed: Int64
    public var available: Int64
    public var volumeName: String
    public init(needed: Int64, available: Int64, volumeName: String) { self.needed = needed; self.available = available; self.volumeName = volumeName }
}

public protocol FileOpInteraction: Sendable {
    func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution
    func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution
    func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool
    func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool
}

/// Forwards to a target set later. Calls made before a target exists suspend until `setTarget`.
public final class InteractionProxy: FileOpInteraction {
    private struct State {
        var target: (any FileOpInteraction)?
        var waiters: [CheckedContinuation<any FileOpInteraction, Never>] = []
    }
    private let state = Mutex(State())
    public init() {}

    public func setTarget(_ target: any FileOpInteraction) {
        let waiters = state.withLock { s -> [CheckedContinuation<any FileOpInteraction, Never>] in
            s.target = target
            let w = s.waiters
            s.waiters = []
            return w
        }
        for w in waiters { w.resume(returning: target) }
    }

    private func target() async -> any FileOpInteraction {
        if let t = state.withLock({ $0.target }) { return t }
        return await withCheckedContinuation { (c: CheckedContinuation<any FileOpInteraction, Never>) in
            let ready: (any FileOpInteraction)? = state.withLock { s in
                if let t = s.target { return t }
                s.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    public func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
        await target().resolveConflict(conflict, job: job)
    }
    public func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        await target().resolveError(error, job: job)
    }
    public func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        await target().confirmInsufficientSpace(shortfall, job: job)
    }
    public func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        await target().confirmPermanentDeleteWithoutTrash(urls, job: job)
    }
}

/// Tests and macx-scenarios: answers from queues (defaults: .one(.skip), .skip, false, false) and records questions.
public final class ScriptedInteraction: FileOpInteraction {
    private struct State {
        var conflicts: [ConflictResolution]; var errors: [ErrorResolution]; var space: [Bool]; var noTrash: [Bool]
        var askedConflicts: [ConflictInfo] = []; var askedErrors: [FileOpError] = []
        var askedSpace: [SpaceShortfall] = []; var askedNoTrash: [[URL]] = []
    }
    private let state: Mutex<State>
    public init(conflicts: [ConflictResolution] = [], errors: [ErrorResolution] = [],
                space: [Bool] = [], noTrash: [Bool] = []) {
        state = Mutex(State(conflicts: conflicts, errors: errors, space: space, noTrash: noTrash))
    }
    public func askedConflicts() -> [ConflictInfo] { state.withLock { $0.askedConflicts } }
    public func askedErrors() -> [FileOpError] { state.withLock { $0.askedErrors } }
    public func askedSpace() -> [SpaceShortfall] { state.withLock { $0.askedSpace } }
    public func askedNoTrash() -> [[URL]] { state.withLock { $0.askedNoTrash } }

    public func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
        state.withLock { s in
            s.askedConflicts.append(conflict)
            return s.conflicts.isEmpty ? .one(.skip) : s.conflicts.removeFirst()
        }
    }
    public func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        state.withLock { s in
            s.askedErrors.append(error)
            return s.errors.isEmpty ? .skip : s.errors.removeFirst()
        }
    }
    public func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        state.withLock { s in
            s.askedSpace.append(shortfall)
            return s.space.isEmpty ? false : s.space.removeFirst()
        }
    }
    public func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        state.withLock { s in
            s.askedNoTrash.append(urls)
            return s.noTrash.isEmpty ? false : s.noTrash.removeFirst()
        }
    }
}
```

- [ ] **Step 9: Implement `JobRecord.swift` and `FaultPoint.swift`**

`JobRecord.swift`:

```swift
import Foundation
import Darwin

public struct FileIdentity: Sendable, Codable, Hashable {
    public var device: UInt64
    public var inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
    /// lstat; lane only.
    public static func of(path: String) -> FileIdentity? {
        assertOffMain()
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino)
    }
}

public struct AttributeSnapshot: Sendable, Codable, Equatable {
    public var locked: Bool?
    public var hidden: Bool?
    public var extensionHidden: Bool?
    public var mode: UInt16?
    public var quarantine: Data?
    public init(locked: Bool? = nil, hidden: Bool? = nil, extensionHidden: Bool? = nil, mode: UInt16? = nil, quarantine: Data? = nil) {
        self.locked = locked; self.hidden = hidden; self.extensionHidden = extensionHidden; self.mode = mode; self.quarantine = quarantine
    }
}

public enum ItemAction: Sendable, Codable, Equatable {
    case created(URL, FileIdentity)
    case createdDirectory(URL, FileIdentity)
    case moved(from: URL, to: URL, FileIdentity)
    case renamed(from: URL, to: URL, FileIdentity)
    case trashed(original: URL, trashURL: URL, FileIdentity)
    case replaced(original: URL, trashURL: URL, FileIdentity)
    case modeChanged(URL, old: UInt16, new: UInt16)
    case attributesChanged(URL, old: AttributeSnapshot, new: AttributeSnapshot)
    case deleted(URL)

    var urls: [URL] {
        switch self {
        case .created(let u, _), .createdDirectory(let u, _), .modeChanged(let u, _, _), .attributesChanged(let u, _, _), .deleted(let u): [u]
        case .moved(let a, let b, _), .renamed(let a, let b, _): [a, b]
        case .trashed(let a, let b, _), .replaced(let a, let b, _): [a, b]
        }
    }
}

public struct JobRecord: Sendable, Codable, Equatable {
    public var id: JobID
    public var verb: JobVerb
    public var actions: [ItemAction]
    public init(id: JobID, verb: JobVerb, actions: [ItemAction]) { self.id = id; self.verb = verb; self.actions = actions }
    public var isUndoable: Bool {
        !actions.isEmpty && !actions.contains { if case .deleted = $0 { true } else { false } }
    }
}

public struct SkippedItem: Sendable, Equatable {
    public var url: URL
    public var reason: FileOpErrorKind?            // nil = conflict skipped
    public init(url: URL, reason: FileOpErrorKind?) { self.url = url; self.reason = reason }
}

public struct JobOutcome: Sendable, Equatable {
    public var record: JobRecord
    public var skipped: [SkippedItem]
    public var wasCancelled: Bool
    public var created: [URL]
    public var localChanges: [LocalChange]
    public init(record: JobRecord, skipped: [SkippedItem], wasCancelled: Bool, created: [URL], localChanges: [LocalChange]) {
        self.record = record; self.skipped = skipped; self.wasCancelled = wasCancelled; self.created = created; self.localChanges = localChanges
    }
}
```

`FaultPoint.swift`:

```swift
/// Test-only fault injection points; `FileOpTuning.faultHook` is called synchronously at each (on a lane or in job code).
public enum FaultPoint: String, Sendable, CaseIterable {
    case afterPartialCopy, beforePartialRename, afterTrashDestination, beforeSourceDelete, midCopyChunk, afterFirstItem
}
```

- [ ] **Step 10: Implement `PosixFS.swift` (internal, lane-only helpers)**

```swift
import Foundation
import Darwin

/// Lane-only POSIX helpers. Every function calls assertOffMain(). Symlinks are never followed.
enum PosixFS {
    struct Info: Sendable, Equatable {
        var isDirectory: Bool
        var isSymlink: Bool
        var isRegular: Bool
        var size: Int64
        var allocSize: Int64
        var mode: UInt16
        var flags: UInt32
        var mtime: Date
        var identity: FileIdentity
        var isLocked: Bool { flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 }
        var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
    }

    static func info(_ path: String) -> Info? {
        assertOffMain()
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        return Info(isDirectory: type == S_IFDIR, isSymlink: type == S_IFLNK, isRegular: type == S_IFREG,
                    size: Int64(st.st_size), allocSize: Int64(st.st_blocks) * 512, mode: UInt16(st.st_mode & 0o7777),
                    flags: st.st_flags,
                    mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9),
                    identity: FileIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino))
    }

    static func exists(_ path: String) -> Bool { info(path) != nil }

    /// 0 or errno.
    static func rename(_ from: String, _ to: String) -> Int32 {
        assertOffMain()
        return Darwin.rename(from, to) == 0 ? 0 : errno
    }

    /// Clears UF_IMMUTABLE on `path` and (when a directory) everything under it, without following links.
    static func clearImmutable(_ path: String, recursive: Bool = true) {
        assertOffMain()
        guard recursive, let i = info(path), i.isDirectory else {
            if let i = info(path), i.flags & UInt32(UF_IMMUTABLE) != 0 { _ = lchflags(path, i.flags & ~UInt32(UF_IMMUTABLE)) }
            return
        }
        walk(path) { p, _ in
            if let i = info(p), i.flags & UInt32(UF_IMMUTABLE) != 0 { _ = lchflags(p, i.flags & ~UInt32(UF_IMMUTABLE)) }
            if let i = info(p), i.isDirectory, i.mode & 0o700 != 0o700 { _ = chmod(p, mode_t(i.mode | 0o700)) }
            return true
        }
    }

    /// Recursive delete of a file or tree (removefile). `unlock` first clears uchg. 0 or errno.
    static func removeTree(_ path: String, unlock: Bool = false) -> Int32 {
        assertOffMain()
        if unlock { clearImmutable(path) }
        return removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 ? 0 : errno
    }

    /// Mount point (f_mntonname) of the volume holding `path`.
    static func mountPoint(of path: String) -> String? {
        assertOffMain()
        var sfs = statfs()
        guard statfs(path, &sfs) == 0 else { return nil }
        return withUnsafeBytes(of: &sfs.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Pre-order fts walk (FTS_PHYSICAL | FTS_NOCHDIR). `body(path, entry)` returns false to skip a directory's contents.
    static func walk(_ root: String, _ body: (String, UnsafeMutablePointer<FTSENT>) -> Bool) {
        assertOffMain()
        guard let cRoot = strdup(root) else { return }
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_DP { continue }
            let path = String(cString: ent.pointee.fts_path)
            if !body(path, ent), info == FTS_D { fts_set(fts, ent, FTS_SKIP) }
        }
    }

    /// Item count (every entry, links counted once) and total logical bytes of regular files. Used by move verification.
    static func treeStats(_ root: String) -> (items: Int, bytes: Int64) {
        var items = 0
        var bytes: Int64 = 0
        walk(root) { _, ent in
            items += 1
            if Int32(ent.pointee.fts_info) == FTS_F { bytes += Int64(ent.pointee.fts_statp.pointee.st_size) }
            return true
        }
        return (items, bytes)
    }
}
```

- [ ] **Step 11: Implement `Journal.swift`**

```swift
import Foundation
import Dispatch

public enum JournalEntry: Sendable, Codable, Equatable {
    case partial(job: JobID, url: URL)
    case trashedDestination(job: JobID, original: URL, trashURL: URL)
    case twoStepRename(job: JobID, temporary: URL, original: URL, target: URL)
    case jobStarted(job: JobID, description: JobDescription)

    public var job: JobID {
        switch self {
        case .partial(let j, _), .trashedDestination(let j, _, _), .twoStepRename(let j, _, _, _), .jobStarted(let j, _): j
        }
    }
}

/// Crash journal (§6.3). Rewritten atomically (Data.write .atomic = temp file + rename) on every change.
/// Its executor is a private serial DispatchQueue, so these small blocking writes never run on the
/// cooperative pool or the main thread.
public actor Journal {
    private struct FileFormat: Codable { var version = 1; var entries: [JournalEntry] }

    private let fileURL: URL
    private let executorQueue: DispatchSerialQueue
    private var items: [JournalEntry] = []
    private var loaded = false

    public nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.executorQueue = DispatchSerialQueue(label: "com.macexplorer.journal")
    }

    public func record(_ entry: JournalEntry) throws {
        loadIfNeeded()
        items.append(entry)
        try persist()
    }

    public func clear(_ entry: JournalEntry) throws {
        loadIfNeeded()
        if let i = items.firstIndex(of: entry) { items.remove(at: i) }
        try persist()
    }

    public func finish(job: JobID) throws {
        loadIfNeeded()
        let before = items.count
        items.removeAll { $0.job == job }
        if items.count != before { try persist() }
    }

    public func entries() -> [JournalEntry] {
        loadIfNeeded()
        return items
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(FileFormat.self, from: data) {
            items = decoded.entries
        } else {
            // Our own file but unreadable: set it aside (never delete it) and start empty.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent().appending(path: "journal.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(FileFormat(entries: items))
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 12: Implement `TrashService.swift`**

```swift
import Foundation
import Darwin
import MacxFS

public protocol TrashService: Sendable {
    /// Synchronous; lane only. Returns the resulting URL. Throws FileOpError(.noTrash) where unsupported.
    func trash(_ url: URL) throws -> URL
}

public struct SystemTrash: TrashService {
    public init() {}
    public func trash(_ url: URL) throws -> URL {
        assertOffMain()
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        } catch {
            let locked = PosixFS.info(url.path)?.isLocked ?? false
            throw FileOpError(kind: FileOpErrorKind(error: error, isLockedItem: locked), url: url)
        }
        guard let result else { throw FileOpError(kind: .noTrash, url: url) }
        return result as URL
    }
}

/// Moves items into `directory/<UUID>/<name>`. For items on another volume (rename gives EXDEV) the bucket is
/// `<item's mount point>/.macx-sandbox-trash/<UUID>/<name>` (tests only use this on images they created).
/// Paths under `refusingPathsUnder` throw .noTrash (simulates volumes without a Trash).
public struct SandboxTrash: TrashService {
    public let directory: URL
    private let refusing: [String]
    public init(directory: URL) { self.init(directory: directory, refusingPathsUnder: []) }
    public init(directory: URL, refusingPathsUnder prefixes: [URL]) {
        self.directory = directory
        self.refusing = prefixes.map { $0.standardizedFileURL.path + "/" }
    }

    public func trash(_ url: URL) throws -> URL {
        assertOffMain()
        let path = url.standardizedFileURL.path
        if refusing.contains(where: { (path + "/").hasPrefix($0) && path + "/" != $0 }) {
            throw FileOpError(kind: .noTrash, url: url)
        }
        guard PosixFS.exists(path) else { throw FileOpError(kind: .sourceGone, url: url) }
        let locked = PosixFS.info(path)?.isLocked ?? false
        func attempt(into bucketRoot: URL) throws -> (URL, Int32) {
            let bucket = bucketRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
            let target = bucket.appending(path: url.lastPathComponent)
            return (target, PosixFS.rename(path, target.path))
        }
        var (target, code) = try attempt(into: directory)
        if code == EXDEV, let mount = PosixFS.mountPoint(of: path) {
            (target, code) = try attempt(into: URL(filePath: mount).appending(path: ".macx-sandbox-trash", directoryHint: .isDirectory))
        }
        guard code == 0 else { throw FileOpError(kind: FileOpErrorKind(errno: code, isLockedItem: locked), url: url) }
        return target
    }
}
```

- [ ] **Step 13: Implement `LaunchRecovery.swift`**

```swift
import Foundation
import Darwin
import MacxFS

public struct RecoveryReport: Sendable, Equatable {
    public var removedPartials: [URL] = []
    public var restoredDestinations: [URL] = []
    public var restoredRenames: [URL] = []
    public var incompleteJobs: [JobDescription] = []
    public init() {}
    public var isEmpty: Bool { removedPartials.isEmpty && restoredDestinations.isEmpty && restoredRenames.isEmpty && incompleteJobs.isEmpty }
}

public enum LaunchRecovery {
    /// Order: interrupted two-step renames, then journaled partials (only names matching PartialName), then
    /// trashed destinations whose original path is free. Every job in the journal is then finished.
    public static func run(journal: Journal, lanes: LanePool) async -> RecoveryReport {
        let entries = await journal.entries()
        guard !entries.isEmpty else { return RecoveryReport() }
        var report = (try? await lanes.perform(on: .unknown, .fileOp) { lane in recover(entries, lane) }) ?? RecoveryReport()
        report.incompleteJobs = entries.compactMap { if case .jobStarted(_, let d) = $0 { d } else { nil } }
        var seen = Set<JobID>()
        for e in entries where seen.insert(e.job).inserted { try? await journal.finish(job: e.job) }
        return report
    }

    static func recover(_ entries: [JournalEntry], _ lane: LaneContext) -> RecoveryReport {
        assertOffMain()
        var report = RecoveryReport()
        for case .twoStepRename(_, let temp, let original, _) in entries {
            lane.heartbeat()
            if PosixFS.exists(temp.path), !PosixFS.exists(original.path), PosixFS.rename(temp.path, original.path) == 0 {
                report.restoredRenames.append(original)
            }
        }
        for case .partial(_, let url) in entries {
            lane.heartbeat()
            guard PartialName.isPartial(url.lastPathComponent), PosixFS.exists(url.path) else { continue }
            if PosixFS.removeTree(url.path, unlock: true) == 0 { report.removedPartials.append(url) }
        }
        for case .trashedDestination(_, let original, let trashURL) in entries {
            lane.heartbeat()
            if !PosixFS.exists(original.path), PosixFS.exists(trashURL.path),
               PosixFS.rename(trashURL.path, original.path) == 0 {
                report.restoredDestinations.append(original)
            }
        }
        return report
    }
}
```

- [ ] **Step 14: Run the tests and see them pass**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` with no warnings.
Run: `swift test --filter 'CoreTests.(FileOpErrorTests|JournalTests)' 2>&1 | tail -5`
Expected: `Executed 19 tests, with 0 failures` (`testSystemTrashOnDiskImage` is reported as skipped if hdiutil is unavailable).

- [ ] **Step 15: Commit**

```bash
git add Sources/Core/FileOps Tests/CoreTests/FileOps
git commit -m "feat: file-operation foundation types, journal, launch recovery and trash services"
```

---
### Task P1-18: FileOpQueue, JobRunner, Planner, VolumeIdentity

Spec: §6.1 (app-wide actor, disjoint volume sets concurrent, same volume pair FIFO, plan then execute, `fts` enumeration, existence re-check, ≤10 Hz progress, pause between items and chunks, cancel finishes the current item), §6.3 rule 1 (same/cross volume by `st_dev`, never by path prefix), §6.5 free-space check, §4.2 (lanes, materialization policy for plan-phase enumeration of trash/delete/chmodRecursive), §5.6 paste re-checks existence in the plan phase. Review Focus 1.

**Files:**
- Create: `Sources/Core/FileOps/FileOpQueue.swift`, `Sources/Core/FileOps/JobRunner.swift`, `Sources/Core/FileOps/Planner.swift`, `Sources/Core/FileOps/VolumeIdentity.swift`
- Test: `Tests/CoreTests/FileOps/QueueTests.swift`, `Tests/CoreTests/FileOps/PlannerTests.swift`

**Interfaces:**
- Consumes: everything P1-17 produced; `LanePool.perform`, `LaneContext`, `withNoMaterialization`, `VolumeID(raw:)`.
- Produces (contract §3.13, exact):

```swift
public struct FileOpTuning: Sendable {
    public var progressInterval: Duration          // .milliseconds(100)
    public var copyChunkBytes: Int                 // 1 MiB
    public var faultHook: (@Sendable (FaultPoint, JobID) -> Void)?
    public init(progressInterval: Duration = .milliseconds(100), copyChunkBytes: Int = 1 << 20,
                faultHook: (@Sendable (FaultPoint, JobID) -> Void)? = nil)
    // internal test knobs: var allowClone = true; var forceCrossVolume = false; var bodyOverride: (@Sendable (JobContext) async -> Void)? = nil
}
public enum JobEvent: Sendable { case added(JobSnapshot), updated(JobSnapshot), finished(JobSnapshot, JobOutcome) }
public actor FileOpQueue {
    public init(lanes: LanePool, trash: any TrashService, journal: Journal, interaction: any FileOpInteraction, tuning: FileOpTuning = FileOpTuning())
    @discardableResult public func enqueue(_ request: JobRequest) -> JobID
    public func pause(_ id: JobID)
    public func resume(_ id: JobID)
    public func cancel(_ id: JobID)
    public func cancelAll() async
    public func snapshots() -> [JobSnapshot]
    public func outcome(of id: JobID) async -> JobOutcome
    public func waitUntilIdle() async
    public var hasActiveJobs: Bool { get }
    public func suspendJobs(touching mountPoint: URL) -> [JobID]
    public nonisolated var events: AsyncStream<JobEvent> { get }
    // additive (Contract notes 3): public func registersUndo(_ id: JobID) -> Bool
}
```

- Produces (internal, used by P1-19 … P1-24):

```swift
enum StepResult: Sendable, Equatable { case done, skipped, cancelled }
final class JobControl: Sendable { var isPaused: Bool; var isCancelled: Bool; func pause(); func resume(); func cancel()
    func laneCheckpoint(_ lane: LaneContext) -> Bool; func checkpoint() async -> Bool }
final class JobContext: Sendable {
    let id: JobID; let request: JobRequest; var kind: JobKind; let lanes: LanePool; let trash: any TrashService
    let journal: Journal; let interaction: any FileOpInteraction; let tuning: FileOpTuning; let control: JobControl
    var laneVolume: VolumeID
    func snapshot() -> JobSnapshot; func setState(_ s: JobState)
    func onLane<T: Sendable>(_ work: @escaping @Sendable (LaneContext) throws -> T) async throws -> T
    func setTotals(items: Int, bytes: Int64?); func addProgress(items: Int = 0, bytes: Int64 = 0, current: String? = nil)
    func record(_ action: ItemAction); func removeLastAction(where: (ItemAction) -> Bool); func skip(_ url: URL, reason: FileOpErrorKind?)
    func landed(_ url: URL, select: Bool = true, beginRename: Bool = false); func noteRemoved(_ url: URL)
    func noteRenamed(from: URL, to: URL); func noteModified(_ url: URL)
    func fault(_ point: FaultPoint)
    func journalRecord(_ entry: JournalEntry) async throws; func journalClear(_ entry: JournalEntry) async
    func checkpoint() async -> Bool; func cancelJob()
    func askError(_ error: FileOpError) async -> ErrorResolution
    func attempt(_ url: URL, destination: URL? = nil, _ step: @escaping @Sendable (LaneContext) -> Int32) async -> StepResult
    func plan(sources: [URL], destination: URL?, mode: PlanMode) async -> JobPlan?
    func outcome() -> JobOutcome
}
enum JobRunner { static func run(_ ctx: JobContext) async -> JobOutcome }
struct PlanEntry: Sendable, Equatable { enum EntryType { file, directory, symlink, other }; var relativePath: String; var type: EntryType; var size: Int64; var allocSize: Int64; var mode: UInt16; var isLocked: Bool; var errorCode: Int32 }
struct PlanItem: Sendable { var source: URL; var info: PosixFS.Info; var entries: [PlanEntry]; var sameVolume: Bool; var contentsUnknown: Bool; var itemCount: Int; var byteCount: Int64 }
struct Refusal: Sendable, Equatable { var url: URL; var kind: FileOpErrorKind }
struct JobPlan: Sendable { var items: [PlanItem]; var refused: [Refusal]; var neededBytes: Int64; var availableBytes: Int64?; var destinationVolumeName: String
    var capabilities: VolumeIdentity.Capabilities; var topLevelConflicts: [URL]; var totalItems: Int; var totalBytes: Int64 }
enum PlanMode: Sendable, Equatable { case copy, move, enumerate(noMaterialization: Bool), shallow }
enum Planner { static func plan(sources: [URL], destination: URL?, mode: PlanMode, forceCrossVolume: Bool, lane: LaneContext) -> JobPlan
    static func enumerate(_ url: URL, info: PosixFS.Info, noMaterialization: Bool, lane: LaneContext) -> (entries: [PlanEntry], contentsUnknown: Bool)
    static func isSelfOrDescendant(source: String, destination: String) -> Bool }
enum VolumeIdentity { struct Probe: Sendable { var devices: Set<UInt64>; var laneVolume: VolumeID }
    struct Capabilities: Sendable, Equatable { var clone: Bool; var renameExcl: Bool; var caseSensitive: Bool }
    static func device(of path: String) -> UInt64?; static func isSameVolume(_ source: URL, destinationDirectory: URL) -> Bool
    static func probe(_ urls: [URL]) -> Probe; static func capabilities(of directory: URL) -> Capabilities
    static func availableCapacity(of directory: URL) -> (available: Int64?, volumeName: String) }
```

- [ ] **Step 1: Write the failing queue tests**

`Tests/CoreTests/FileOps/QueueTests.swift`:

```swift
import XCTest
import Synchronization
@testable import Core
import MacxFS

final class EventLog: Sendable {
    private let m = Mutex<[String]>([])
    func add(_ s: String) { m.withLock { $0.append(s) } }
    var all: [String] { m.withLock { $0 } }
}

final class QueueTests: FileOpsTestCase {
    /// Body used by scheduling tests: logs start/end with the first source's name.
    private func timedBody(_ log: EventLog, _ duration: Duration) -> @Sendable (JobContext) async -> Void {
        { ctx in
            let name = ctx.kind.allURLs.first?.lastPathComponent ?? "?"
            log.add("start \(name)")
            try? await Task.sleep(for: duration)
            log.add("end \(name)")
        }
    }

    func testSameVolumeJobsRunFIFO() async throws {
        let log = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = timedBody(log, .milliseconds(150))
        let (queue, _) = makeQueue(tuning: tuning)
        let a = try file("a"), b = try file("b"), d = try dir("d")
        let ida = await queue.enqueue(JobRequest(.copy(sources: [a], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [b], destination: d)))
        _ = await queue.outcome(of: ida)
        _ = await queue.outcome(of: idb)
        XCTAssertEqual(log.all, ["start a", "end a", "start b", "end b"])
    }

    func testDisjointVolumesRunConcurrently() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let log = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = timedBody(log, .milliseconds(300))
        let (queue, _) = makeQueue(tuning: tuning)
        let a = try file("a"), d = try dir("d")
        let b = mnt.appending(path: "b"); try Data("b".utf8).write(to: b)
        let d2 = mnt.appending(path: "d2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: d2, withIntermediateDirectories: false)
        let ida = await queue.enqueue(JobRequest(.copy(sources: [a], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [b], destination: d2)))
        _ = await queue.outcome(of: ida)
        _ = await queue.outcome(of: idb)
        XCTAssertEqual(Set(log.all.prefix(2)), ["start a", "start b"], "both started before either ended: \(log.all)")
    }

    func testPauseResumeCancelRunningJob() async throws {
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            ctx.setTotals(items: 400, bytes: nil)
            for _ in 0..<400 {
                guard await ctx.checkpoint() else { return }
                ctx.addProgress(items: 1)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let (queue, _) = makeQueue(tuning: tuning)
        let id = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: try dir("d"))))
        await waitUntil { await queue.snapshots().first?.progress.itemsDone ?? 0 > 5 }
        await queue.pause(id)
        try await Task.sleep(for: .milliseconds(60))
        let paused = await queue.snapshots().first!
        XCTAssertEqual(paused.state, .paused)
        try await Task.sleep(for: .milliseconds(150))
        let stillPaused = await queue.snapshots().first!
        XCTAssertEqual(stillPaused.progress.itemsDone, paused.progress.itemsDone)
        await queue.resume(id)
        await waitUntil { await queue.snapshots().first?.progress.itemsDone ?? 0 > paused.progress.itemsDone + 3 }
        await queue.cancel(id)
        let outcome = await queue.outcome(of: id)
        XCTAssertTrue(outcome.wasCancelled)
        let hasActive = await queue.hasActiveJobs
        XCTAssertFalse(hasActive)
    }

    func testProgressUpdatesAreAtMost10Hz() async throws {
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            for _ in 0..<500 { ctx.addProgress(bytes: 10); try? await Task.sleep(for: .milliseconds(1)) }
        }
        let (queue, _) = makeQueue(tuning: tuning)
        let counter = EventLog()
        let consumer = Task {
            for await e in queue.events {
                switch e {
                case .added: counter.add("added")
                case .updated: counter.add("updated")
                case .finished: counter.add("finished"); return
                }
            }
        }
        let start = ContinuousClock.now
        let id = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: try dir("d"))))
        _ = await queue.outcome(of: id)
        await consumer.value
        let elapsed = (ContinuousClock.now - start).inSeconds
        let updates = counter.all.filter { $0 == "updated" }.count
        XCTAssertEqual(counter.all.first, "added")
        XCTAssertEqual(counter.all.last, "finished")
        XCTAssertGreaterThanOrEqual(updates, 1)
        XCTAssertLessThanOrEqual(Double(updates), elapsed * 10 + 2, "\(updates) updates in \(elapsed) s")
    }

    func testCancelQueuedJobFinishesWithoutRunning() async throws {
        let log = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = timedBody(log, .milliseconds(200))
        let (queue, _) = makeQueue(tuning: tuning)
        let d = try dir("d")
        let ida = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [try file("b")], destination: d)))
        await queue.cancel(idb)
        let ob = await queue.outcome(of: idb)
        XCTAssertTrue(ob.wasCancelled)
        _ = await queue.outcome(of: ida)
        XCTAssertFalse(log.all.contains("start b"))
    }

    func testCancelAllReturnsWhenEveryJobFinished() async throws {
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in while await ctx.checkpoint() { try? await Task.sleep(for: .milliseconds(5)) } }
        let (queue, _) = makeQueue(tuning: tuning)
        let d = try dir("d")
        for n in ["a", "b", "c"] { await queue.enqueue(JobRequest(.copy(sources: [try file(n)], destination: d))) }
        await queue.cancelAll()
        let active = await queue.hasActiveJobs
        XCTAssertFalse(active)
        let snaps = await queue.snapshots()
        XCTAssertEqual(snaps, [])
    }

    func testSuspendJobsTouchingMountPointPausesQueuedAndReportsRunning() async throws {
        let gate = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            gate.add("run \(ctx.kind.allURLs.first!.lastPathComponent)")
            while await ctx.checkpoint(), !gate.all.contains("release") { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let (queue, _) = makeQueue(tuning: tuning)
        let d = try dir("d")
        let ida = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [try file("b")], destination: d)))
        await waitUntil { gate.all.contains("run a") }
        let running = await queue.suspendJobs(touching: root)
        XCTAssertEqual(running, [ida])
        gate.add("release")
        _ = await queue.outcome(of: ida)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(gate.all.contains("run b"), "suspended job must not start")
        let stateB = await queue.snapshots().first { $0.id == idb }?.state
        XCTAssertEqual(stateB, .paused)
        await queue.resume(idb)
        _ = await queue.outcome(of: idb)
        XCTAssertTrue(gate.all.contains("run b"))
    }

    func testRegistersUndoFlagIsKept() async throws {
        var tuning = FileOpTuning()
        tuning.bodyOverride = { _ in }
        let (queue, _) = makeQueue(tuning: tuning)
        let id1 = await queue.enqueue(JobRequest(.trash([try file("a")]), registersUndo: false))
        let id2 = await queue.enqueue(JobRequest(.trash([try file("b")])))
        _ = await queue.outcome(of: id1); _ = await queue.outcome(of: id2)
        let r1 = await queue.registersUndo(id1), r2 = await queue.registersUndo(id2)
        XCTAssertFalse(r1); XCTAssertTrue(r2)
    }

    /// Review Focus 1 at job level: the plan phase asks per refused item and continues with the rest.
    func testPlanPhaseReportsIntoItselfPerItemAndContinues() async throws {
        let scripted = ScriptedInteraction(errors: [.skip])
        let a = try dir("A/sub"), b = try file("B")
        let bigA = url("A")
        let planned = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            if let plan = await ctx.plan(sources: [bigA, b], destination: a, mode: .copy) {
                planned.add(plan.items.map(\.source.lastPathComponent).joined(separator: ","))
            }
        }
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let outcome = try await run(.copy(sources: [url("A"), b], destination: a), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.intoItself])
        XCTAssertEqual(outcome.skipped, [SkippedItem(url: url("A"), reason: .intoItself)])
        XCTAssertEqual(planned.all, ["B"])
    }

    func testInsufficientSpacePromptsBeforeExecution() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let big = try bigFile("big", bytes: 40 << 20)
        let scripted = ScriptedInteraction(space: [false])
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in _ = await ctx.plan(sources: [big], destination: mnt, mode: .copy) }
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let id = await queue.enqueue(JobRequest(.copy(sources: [big], destination: mnt)))
        let outcome = await queue.outcome(of: id)
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(scripted.askedSpace().count, 1)
        XCTAssertGreaterThan(scripted.askedSpace()[0].needed, scripted.askedSpace()[0].available)
    }
}
```

The image-based tests write with `Data.write`/`createDirectory` only under `mnt`, which `DiskImage` mounted inside the sandbox.

- [ ] **Step 2: Write the failing planner tests**

`Tests/CoreTests/FileOps/PlannerTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

final class PlannerTests: FileOpsTestCase {
    private func plan(_ sources: [URL], _ dest: URL?, _ mode: PlanMode, force: Bool = false) async throws -> JobPlan {
        try await LanePool().perform(on: .unknown, .fileOp) { lane in
            Planner.plan(sources: sources, destination: dest, mode: mode, forceCrossVolume: force, lane: lane)
        }
    }

    func testPlanCountsItemsAndBytes() async throws {
        try file("a/f1", String(repeating: "1", count: 10))
        try file("a/sub/f2", String(repeating: "2", count: 20))
        let p = try await plan([url("a")], try dir("d"), .copy)
        XCTAssertEqual(p.items.count, 1)
        XCTAssertEqual(p.items[0].entries.map(\.relativePath), ["", "f1", "sub", "sub/f2"])
        XCTAssertEqual(p.totalItems, 4)
        XCTAssertEqual(p.totalBytes, 30)
        XCTAssertEqual(p.items[0].entries.first?.type, .directory)
    }

    func testPlanReportsMissingSourceAsSourceGone() async throws {
        let p = try await plan([url("missing"), try file("x")], try dir("d"), .copy)
        XCTAssertEqual(p.refused, [Refusal(url: url("missing"), kind: .sourceGone)])
        XCTAssertEqual(p.items.map(\.source), [url("x")])
    }

    /// Review Focus 1 (mandatory name).
    func testPlanRefusesCopyAndMoveIntoSelfOrDescendant() async throws {
        let a = try dir("A/sub")
        let b = try file("B")
        XCTAssertEqual(symlink(url("A").path, url("L").path), 0)       // destination reached through a link
        for mode in [PlanMode.copy, .move] {
            for dest in [a, url("A"), url("L/sub")] {
                let p = try await plan([url("A"), b], dest, mode)
                XCTAssertEqual(p.refused, [Refusal(url: url("A"), kind: .intoItself)], "\(mode) into \(dest.path)")
                XCTAssertEqual(p.items.map(\.source), [b])
            }
        }
        XCTAssertTrue(Planner.isSelfOrDescendant(source: "/x/A", destination: "/x/A"))
        XCTAssertTrue(Planner.isSelfOrDescendant(source: "/x/A", destination: "/x/A/b/c"))
        XCTAssertFalse(Planner.isSelfOrDescendant(source: "/x/A", destination: "/x/AB"))
        XCTAssertFalse(Planner.isSelfOrDescendant(source: "/x/A", destination: "/x"))
    }

    func testPlanNeverFollowsSymlinks() async throws {
        try bigFile("elsewhere/huge", bytes: 1 << 20)
        try dir("a")
        XCTAssertEqual(symlink("../elsewhere", url("a/link").path), 0)
        XCTAssertEqual(symlink(".", url("a/self").path), 0)
        let p = try await plan([url("a")], try dir("d"), .copy)
        XCTAssertEqual(Set(p.items[0].entries.map(\.relativePath)), ["", "link", "self"])
        XCTAssertEqual(p.items[0].entries.filter { $0.type == .symlink }.count, 2)
        XCTAssertEqual(p.totalBytes, 0)
    }

    func testSameVolumeMoveIsShallowAndNeedsNoSpace() async throws {
        try file("a/f1"); try file("a/f2")
        let p = try await plan([url("a")], try dir("d"), .move)
        XCTAssertTrue(p.items[0].sameVolume)
        XCTAssertEqual(p.items[0].entries.count, 1)
        XCTAssertEqual(p.neededBytes, 0)
    }

    func testForcedCrossVolumeMoveEnumeratesAndCountsSpace() async throws {
        try bigFile("a/f1", bytes: 64 << 10)
        let p = try await plan([url("a")], try dir("d"), .move, force: true)
        XCTAssertFalse(p.items[0].sameVolume)
        XCTAssertEqual(p.items[0].entries.count, 2)
        XCTAssertGreaterThanOrEqual(p.neededBytes, 64 << 10)
    }

    func testCopyNeedsNoSpaceWhenDestinationClones() async throws {
        try bigFile("f", bytes: 1 << 20)
        let p = try await plan([url("f")], try dir("d"), .copy)
        guard p.capabilities.clone else { throw XCTSkip("sandbox volume does not clone") }
        XCTAssertEqual(p.neededBytes, 0)
    }

    func testTopLevelConflictsAreDetected() async throws {
        try file("src/a"); try file("src/b"); try file("d/a")
        let p = try await plan([url("src/a"), url("src/b")], url("d"), .copy)
        XCTAssertEqual(p.topLevelConflicts, [url("src/a")])
    }

    func testEnumerateWithNoMaterializationMatchesDefault() async throws {
        try file("t/x"); try file("t/y/z")
        let lanes = LanePool()
        let t = url("t")
        let (withPolicy, plain) = try await lanes.perform(on: .unknown, .fileOp) { lane in
            let info = PosixFS.info(t.path)!
            return (Planner.enumerate(t, info: info, noMaterialization: true, lane: lane).entries,
                    Planner.enumerate(t, info: info, noMaterialization: false, lane: lane).entries)
        }
        XCTAssertEqual(withPolicy, plain)
    }

    func testVolumeIdentityUsesDeviceNotPrefix() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let a = try file("a")
        let sandboxRoot = root
        let same = try await LanePool().perform(on: .unknown, .fileOp) { _ in
            (VolumeIdentity.isSameVolume(a, destinationDirectory: sandboxRoot),
             VolumeIdentity.isSameVolume(a, destinationDirectory: mnt))
        }
        XCTAssertTrue(same.0)
        XCTAssertFalse(same.1, "the image is mounted under the sandbox path but is another device")
    }
}
```

- [ ] **Step 3: Run the tests and watch them fail**

Run: `swift test --filter 'CoreTests.(QueueTests|PlannerTests)' 2>&1 | tail -10`
Expected: compile failure, `cannot find 'FileOpTuning' in scope` / `cannot find 'Planner' in scope`.

- [ ] **Step 4: Implement `VolumeIdentity.swift`**

```swift
import Foundation
import MacxFS

/// §6.3 rule 1: same vs cross volume by st_dev of the source and of the destination directory
/// (the parent of every landed item), never by path prefix. Lane only.
enum VolumeIdentity {
    struct Probe: Sendable { var devices: Set<UInt64>; var laneVolume: VolumeID }
    struct Capabilities: Sendable, Equatable { var clone: Bool; var renameExcl: Bool; var caseSensitive: Bool }

    static func device(of path: String) -> UInt64? { PosixFS.info(path)?.identity.device }

    static func isSameVolume(_ source: URL, destinationDirectory: URL) -> Bool {
        guard let a = device(of: source.path), let b = device(of: destinationDirectory.path) else { return false }
        return a == b
    }

    /// Devices of every path (or of its parent when the path does not exist yet) and the fileOp lane key
    /// ("mnt:<mount point of the first path>").
    static func probe(_ urls: [URL]) -> Probe {
        assertOffMain()
        var devices = Set<UInt64>()
        var lane: VolumeID?
        for u in urls {
            let path = PosixFS.exists(u.path) ? u.path : u.deletingLastPathComponent().path
            if let d = device(of: path) { devices.insert(d) }
            if lane == nil, let mp = PosixFS.mountPoint(of: path) { lane = VolumeID(raw: "mnt:" + mp) }
        }
        return Probe(devices: devices, laneVolume: lane ?? .unknown)
    }

    static func capabilities(of directory: URL) -> Capabilities {
        assertOffMain()
        let v = try? URL(filePath: directory.path).resourceValues(forKeys: [
            .volumeSupportsFileCloningKey, .volumeSupportsExclusiveRenamingKey, .volumeSupportsCaseSensitiveNamesKey])
        return Capabilities(clone: v?.volumeSupportsFileCloning ?? false,
                            renameExcl: v?.volumeSupportsExclusiveRenaming ?? false,
                            caseSensitive: v?.volumeSupportsCaseSensitiveNames ?? false)
    }

    /// volumeAvailableCapacityForImportantUsageKey, falling back to volumeAvailableCapacityKey (§6.5).
    static func availableCapacity(of directory: URL) -> (available: Int64?, volumeName: String) {
        assertOffMain()
        let v = try? URL(filePath: directory.path).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey])
        let important = v?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        let available = important ?? v?.volumeAvailableCapacity.map(Int64.init)
        return (available, v?.volumeLocalizedName ?? "")
    }
}
```

- [ ] **Step 5: Implement `Planner.swift`**

```swift
import Foundation
import Darwin
import MacxFS

struct PlanEntry: Sendable, Equatable {
    enum EntryType: Sendable, Equatable { case file, directory, symlink, other }
    var relativePath: String          // "" = the top-level item itself
    var type: EntryType
    var size: Int64
    var allocSize: Int64
    var mode: UInt16
    var isLocked: Bool
    var errorCode: Int32              // fts_errno for unreadable entries, else 0
}

struct PlanItem: Sendable {
    var source: URL
    var info: PosixFS.Info
    var entries: [PlanEntry]          // pre-order; only the root entry when not enumerated
    var sameVolume: Bool
    var contentsUnknown: Bool         // dataless folder under no-materialization
    var itemCount: Int { entries.count }
    var byteCount: Int64 { entries.reduce(0) { $0 + ($1.type == .file ? $1.size : 0) } }
}

struct Refusal: Sendable, Equatable { var url: URL; var kind: FileOpErrorKind }

struct JobPlan: Sendable {
    var items: [PlanItem] = []
    var refused: [Refusal] = []
    var neededBytes: Int64 = 0
    var availableBytes: Int64? = nil
    var destinationVolumeName = ""
    var capabilities = VolumeIdentity.Capabilities(clone: false, renameExcl: false, caseSensitive: false)
    var topLevelConflicts: [URL] = []
    var totalItems: Int { items.reduce(0) { $0 + $1.itemCount } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
}

enum PlanMode: Sendable, Equatable { case copy, move, enumerate(noMaterialization: Bool), shallow }

enum Planner {
    static func plan(sources: [URL], destination: URL?, mode: PlanMode, forceCrossVolume: Bool, lane: LaneContext) -> JobPlan {
        assertOffMain()
        var plan = JobPlan()
        let destResolved = destination.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        let destDevice = destination.flatMap { VolumeIdentity.device(of: $0.path) }
        if let destination {
            plan.capabilities = VolumeIdentity.capabilities(of: destination)
            let cap = VolumeIdentity.availableCapacity(of: destination)
            plan.availableBytes = cap.available
            plan.destinationVolumeName = cap.volumeName
        }
        for src in sources {
            lane.heartbeat()
            guard let info = PosixFS.info(src.path) else {
                plan.refused.append(Refusal(url: src, kind: .sourceGone)); continue
            }
            if let destResolved, mode == .copy || mode == .move {
                // Resolve only the parent: a symlink source must not be replaced by its target.
                let s = src.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appending(path: src.lastPathComponent).standardizedFileURL.path
                if isSelfOrDescendant(source: s, destination: destResolved) {
                    plan.refused.append(Refusal(url: src, kind: .intoItself)); continue
                }
            }
            let sameVolume = !forceCrossVolume && (destDevice == nil || info.identity.device == destDevice)
            let deep: Bool
            var noMat = false
            switch mode {
            case .copy: deep = true
            case .move: deep = !sameVolume
            case .enumerate(let nm): deep = true; noMat = nm
            case .shallow: deep = false
            }
            let (entries, unknown) = deep ? enumerate(src, info: info, noMaterialization: noMat, lane: lane)
                                          : ([rootEntry(info)], false)
            plan.items.append(PlanItem(source: src, info: info, entries: entries, sameVolume: sameVolume, contentsUnknown: unknown))
            if let destination, src.deletingLastPathComponent().standardizedFileURL.path != destination.standardizedFileURL.path,
               PosixFS.exists(destination.appending(path: src.lastPathComponent).path) {
                plan.topLevelConflicts.append(src)
            }
        }
        plan.neededBytes = neededBytes(plan.items, mode: mode, destinationClones: plan.capabilities.clone)
        return plan
    }

    static func isSelfOrDescendant(source: String, destination: String) -> Bool {
        destination == source || destination.hasPrefix(source.hasSuffix("/") ? source : source + "/")
    }

    /// §6.5: sum of allocated sizes of files that won't clone; same-volume moves need 0.
    static func neededBytes(_ items: [PlanItem], mode: PlanMode, destinationClones: Bool) -> Int64 {
        var total: Int64 = 0
        for item in items {
            switch mode {
            case .move where item.sameVolume: continue
            case .copy where item.sameVolume && destinationClones: continue
            case .copy, .move: total += item.entries.reduce(0) { $0 + ($1.type == .file ? $1.allocSize : 0) }
            default: continue
            }
        }
        return total
    }

    static func rootEntry(_ info: PosixFS.Info) -> PlanEntry {
        PlanEntry(relativePath: "", type: info.isDirectory ? .directory : info.isSymlink ? .symlink : info.isRegular ? .file : .other,
                  size: info.size, allocSize: info.allocSize, mode: info.mode, isLocked: info.isLocked, errorCode: 0)
    }

    /// Pre-order fts (FTS_PHYSICAL): links are entries, never followed; loops cannot occur.
    static func enumerate(_ url: URL, info: PosixFS.Info, noMaterialization: Bool, lane: LaneContext) -> (entries: [PlanEntry], contentsUnknown: Bool) {
        guard info.isDirectory else { return ([rootEntry(info)], false) }
        if noMaterialization && info.isDataless { return ([rootEntry(info)], true) }
        func walk() -> ([PlanEntry], Bool) {
            var out: [PlanEntry] = []
            var unknown = false
            let rootBytes = url.path.utf8.count
            PosixFS.walk(url.path) { path, ent in
                if out.count % 256 == 0 { lane.heartbeat() }
                let rel = path.utf8.count <= rootBytes ? "" : String(decoding: path.utf8.dropFirst(rootBytes + 1), as: UTF8.self)
                let st = ent.pointee.fts_statp?.pointee
                let ftsInfo = Int32(ent.pointee.fts_info)
                let type: PlanEntry.EntryType = switch ftsInfo {
                case FTS_D, FTS_DNR, FTS_DC: .directory
                case FTS_F: .file
                case FTS_SL, FTS_SLNONE: .symlink
                default: .other
                }
                let flags = st?.st_flags ?? 0
                out.append(PlanEntry(relativePath: rel, type: type, size: Int64(st?.st_size ?? 0),
                                     allocSize: Int64(st?.st_blocks ?? 0) * 512, mode: UInt16((st?.st_mode ?? 0) & 0o7777),
                                     isLocked: flags & UInt32(UF_IMMUTABLE) != 0,
                                     errorCode: ftsInfo == FTS_DNR || ftsInfo == FTS_ERR || ftsInfo == FTS_NS ? ent.pointee.fts_errno : 0))
                if noMaterialization, type == .directory, flags & UInt32(SF_DATALESS) != 0 { unknown = true; return false }
                return true
            }
            return (out, unknown)
        }
        return noMaterialization ? withNoMaterialization(walk) : walk()
    }
}
```

- [ ] **Step 6: Implement `JobRunner.swift` (control, context, dispatch)**

```swift
import Foundation
import Darwin
import Synchronization
import MacxFS

enum StepResult: Sendable, Equatable { case done, skipped, cancelled }

/// Pause/cancel flags shared by async job code and lane work.
final class JobControl: Sendable {
    private let flags = Mutex((paused: false, cancelled: false))
    var isPaused: Bool { flags.withLock { $0.paused } }
    var isCancelled: Bool { flags.withLock { $0.cancelled } }
    func pause() { flags.withLock { $0.paused = true } }
    func resume() { flags.withLock { $0.paused = false } }
    func cancel() { flags.withLock { $0.cancelled = true; $0.paused = false } }

    /// Lane side (between copy chunks): waits while paused, heartbeating so the watchdog never poisons
    /// a paused lane. Returns false when cancelled.
    func laneCheckpoint(_ lane: LaneContext) -> Bool {
        while true {
            let f = flags.withLock { $0 }
            if f.cancelled || lane.isCancelled { return false }
            if !f.paused { return true }
            lane.heartbeat()
            usleep(20_000)
        }
    }

    /// Async side (between items).
    func checkpoint() async -> Bool {
        while isPaused && !isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
        return !isCancelled
    }
}

final class JobContext: Sendable {
    let id: JobID
    let request: JobRequest
    var kind: JobKind { request.kind }
    let lanes: LanePool
    let trash: any TrashService
    let journal: Journal
    let interaction: any FileOpInteraction
    let tuning: FileOpTuning
    let control = JobControl()

    private struct State {
        var snapshot: JobSnapshot
        var laneVolume: VolumeID = .unknown
        var actions: [ItemAction] = []
        var skipped: [SkippedItem] = []
        var created: [URL] = []
        var changes: [URL: LocalChange] = [:]
        var changeOrder: [URL] = []
        var skipAll: Set<String> = []
        var journaledStart = false
        var meter = ThroughputMeter()
        var fileConflictAction: ConflictAction?
        var folderConflictAction: ConflictAction?
        var perItemConflicts: [URL: ConflictAction]?
    }
    private let state: Mutex<State>

    init(id: JobID, request: JobRequest, lanes: LanePool, trash: any TrashService, journal: Journal,
         interaction: any FileOpInteraction, tuning: FileOpTuning) {
        self.id = id; self.request = request; self.lanes = lanes; self.trash = trash
        self.journal = journal; self.interaction = interaction; self.tuning = tuning
        state = Mutex(State(snapshot: JobSnapshot(id: id, description: request.kind.jobDescription, state: .queued,
                                                  progress: .zero, origin: request.origin, startedAt: .now)))
    }

    // MARK: snapshot and progress
    func snapshot() -> JobSnapshot { state.withLock { $0.snapshot } }
    func setState(_ s: JobState) { state.withLock { $0.snapshot.state = s } }
    var laneVolume: VolumeID {
        get { state.withLock { $0.laneVolume } }
    }
    func setLaneVolume(_ v: VolumeID) { state.withLock { $0.laneVolume = v } }
    func setTotals(items: Int, bytes: Int64?) {
        state.withLock { $0.snapshot.progress.itemsTotal = items; $0.snapshot.progress.bytesTotal = bytes }
    }
    func addProgress(items: Int = 0, bytes: Int64 = 0, current: String? = nil) {
        state.withLock { s in
            s.snapshot.progress.itemsDone += items
            s.snapshot.progress.bytesDone += bytes
            if let current { s.snapshot.progress.currentItem = current }
        }
    }
    /// Called by the queue's ticker every progressInterval.
    func tickThroughput(now: ContinuousClock.Instant) {
        state.withLock { s in
            s.meter.sample(bytesDone: s.snapshot.progress.bytesDone, at: now)
            s.snapshot.progress.throughput = s.meter.samples
            s.snapshot.progress.estimatedRemaining = s.meter.estimatedRemaining(bytesDone: s.snapshot.progress.bytesDone,
                                                                                bytesTotal: s.snapshot.progress.bytesTotal)
        }
    }

    // MARK: lanes
    func onLane<T: Sendable>(_ work: @escaping @Sendable (LaneContext) throws -> T) async throws -> T {
        try await lanes.perform(on: laneVolume, .fileOp, work)
    }

    // MARK: record
    func record(_ action: ItemAction) { state.withLock { $0.actions.append(action) } }
    func removeLastAction(where match: (ItemAction) -> Bool) {
        state.withLock { s in if let i = s.actions.lastIndex(where: match) { s.actions.remove(at: i) } }
    }
    func skip(_ url: URL, reason: FileOpErrorKind?) { state.withLock { $0.skipped.append(SkippedItem(url: url, reason: reason)) } }

    private func mutateChange(_ dir: URL, _ body: (inout LocalChange) -> Void) {
        let key = URL(filePath: dir.standardizedFileURL.path, directoryHint: .isDirectory)   // one key per folder
        state.withLock { s in
            if s.changes[key] == nil { s.changes[key] = LocalChange(directory: key); s.changeOrder.append(key) }
            body(&s.changes[key]!)
        }
    }
    func landed(_ url: URL, select: Bool = true, beginRename: Bool = false) {
        state.withLock { $0.created.append(url) }
        let name = url.lastPathComponent
        mutateChange(url.deletingLastPathComponent()) { c in
            c.added.append(name)
            if select { c.select.append(name) }
            if beginRename { c.beginRename = name }
        }
    }
    func noteRemoved(_ url: URL) { mutateChange(url.deletingLastPathComponent()) { $0.removed.append(url.lastPathComponent) } }
    func noteModified(_ url: URL) { mutateChange(url.deletingLastPathComponent()) { $0.modified.append(url.lastPathComponent) } }
    func noteRenamed(from: URL, to: URL) {
        if from.deletingLastPathComponent().standardizedFileURL.path == to.deletingLastPathComponent().standardizedFileURL.path {
            mutateChange(to.deletingLastPathComponent()) { c in
                c.renamed.append(LocalChange.Rename(from: from.lastPathComponent, to: to.lastPathComponent))
                c.select.append(to.lastPathComponent)
            }
        } else {
            noteRemoved(from)
            landed(to)
        }
    }

    // MARK: faults, journal
    func fault(_ point: FaultPoint) { tuning.faultHook?(point, id) }

    /// Records `jobStarted` before the job's first journal entry.
    func journalRecord(_ entry: JournalEntry) async throws {
        let first = state.withLock { s -> Bool in defer { s.journaledStart = true }; return !s.journaledStart }
        if first { try await journal.record(.jobStarted(job: id, description: snapshot().description)) }
        try await journal.record(entry)
    }
    func journalClear(_ entry: JournalEntry) async { try? await journal.clear(entry) }

    // MARK: control and questions
    func checkpoint() async -> Bool { await control.checkpoint() }
    func cancelJob() { control.cancel(); setState(.cancelling) }

    private func waitingForUser<T>(_ body: () async -> T) async -> T {
        let previous = snapshot().state
        setState(.waitingForUser)
        let r = await body()
        if snapshot().state == .waitingForUser { setState(previous) }
        return r
    }

    /// Honors an earlier "Skip All" for the same error class.
    func askError(_ error: FileOpError) async -> ErrorResolution {
        let key = error.kind.categoryKey
        if state.withLock({ $0.skipAll.contains(key) }) { return .skip }
        let answer = await waitingForUser { await interaction.resolveError(error, job: snapshot()) }
        if answer == .skipAll { state.withLock { _ = $0.skipAll.insert(key) } }
        return answer
    }

    func askSpace(_ shortfall: SpaceShortfall) async -> Bool {
        await waitingForUser { await interaction.confirmInsufficientSpace(shortfall, job: snapshot()) }
    }

    /// Runs a lane step (returns 0 or an errno) until it succeeds or the user skips or cancels.
    func attempt(_ url: URL, destination: URL? = nil, _ step: @escaping @Sendable (LaneContext) -> Int32) async -> StepResult {
        while true {
            let code: Int32 = (try? await onLane(step)) ?? EIO
            if code == 0 { return .done }
            let locked = code == EPERM ? ((try? await onLane { _ in
                (PosixFS.info(url.path)?.isLocked ?? false) || (PosixFS.info(url.deletingLastPathComponent().path)?.isLocked ?? false)
            }) ?? false) : false
            let kind = FileOpErrorKind(errno: code, isLockedItem: locked)
            switch await askError(FileOpError(kind: kind, url: url, destination: destination)) {
            case .retry, .continueAnyway: continue
            case .skip, .skipAll: skip(url, reason: kind); return .skipped
            case .cancel: cancelJob(); return .cancelled
            case .unlockAndContinue:
                _ = try? await onLane { _ in PosixFS.clearImmutable(url.path, recursive: false) }
                continue
            }
        }
    }

    // MARK: conflicts memory (used by ConflictExecutor, P1-22)
    /// nil = nothing remembered for this class; ask the user.
    func rememberedConflictAction(folder: Bool, source: URL) -> ConflictAction? {
        state.withLock { s in
            if let map = s.perItemConflicts { return map[source] ?? .skip }
            return folder ? s.folderConflictAction : s.fileConflictAction
        }
    }
    func rememberConflict(_ resolution: ConflictResolution, folder: Bool) {
        state.withLock { s in
            switch resolution {
            case .all(let a): if folder { s.folderConflictAction = a } else { s.fileConflictAction = a }
            case .perItem(let m): s.perItemConflicts = m
            case .one, .cancelJob: break
            }
        }
    }
    func askConflict(_ info: ConflictInfo) async -> ConflictResolution {
        await waitingForUser { await interaction.resolveConflict(info, job: snapshot()) }
    }

    // MARK: outcome
    func outcome() -> JobOutcome {
        state.withLock { s in
            JobOutcome(record: JobRecord(id: id, verb: kind.verb, actions: s.actions), skipped: s.skipped,
                       wasCancelled: control.isCancelled, created: s.created,
                       localChanges: s.changeOrder.compactMap { s.changes[$0] })
        }
    }
}

extension FileOpErrorKind {
    /// Groups errors for "Skip All" (associated values ignored).
    var categoryKey: String {
        switch self {
        case .permissionDenied: "permissionDenied"
        case .blockedByMacOS: "blockedByMacOS"
        case .locked: "locked"
        case .readOnlyVolume: "readOnlyVolume"
        case .noSpace: "noSpace"
        case .inUse: "inUse"
        case .nameTooLong: "nameTooLong"
        case .sourceGone: "sourceGone"
        case .intoItself: "intoItself"
        case .changedDuringMove: "changedDuringMove"
        case .noTrash: "noTrash"
        case .other(let code, _): "other\(code)"
        }
    }
}

extension JobContext {
    /// Plan phase shared by copy/move/trash/delete/chmod: lane plan, per-item refusals (Skip/Cancel),
    /// free-space prompt, totals. nil = the job was cancelled.
    func plan(sources: [URL], destination: URL?, mode: PlanMode) async -> JobPlan? {
        setState(.planning)
        let force = tuning.forceCrossVolume
        let planned = try? await onLane { lane in
            Planner.plan(sources: sources, destination: destination, mode: mode, forceCrossVolume: force, lane: lane)
        }
        guard let plan = planned else {
            for s in sources { skip(s, reason: .other(code: EIO, message: String(cString: strerror(EIO)))) }
            return nil
        }
        for r in plan.refused {
            if await askError(FileOpError(kind: r.kind, url: r.url, destination: destination)) == .cancel {
                cancelJob(); return nil
            }
            skip(r.url, reason: r.kind)
        }
        if plan.neededBytes > 0, let available = plan.availableBytes, plan.neededBytes > available {
            let go = await askSpace(SpaceShortfall(needed: plan.neededBytes, available: available, volumeName: plan.destinationVolumeName))
            if !go { cancelJob(); return nil }
        }
        setTotals(items: plan.totalItems, bytes: plan.totalBytes)
        setState(.running)
        return plan
    }
}

enum JobRunner {
    static func run(_ ctx: JobContext) async -> JobOutcome {
        ctx.setState(.planning)
        switch ctx.kind {
        default:
            // Kinds are wired one by one in P1-19 … P1-24; P1-24 removes this branch.
            for u in ctx.kind.allURLs { ctx.skip(u, reason: .other(code: ENOTSUP, message: String(cString: strerror(ENOTSUP)))) }
        }
        try? await ctx.journal.finish(job: ctx.id)
        return ctx.outcome()
    }
}
```

- [ ] **Step 7: Implement `FileOpQueue.swift`**

```swift
import Foundation
import MacxFS

public struct FileOpTuning: Sendable {
    public var progressInterval: Duration
    public var copyChunkBytes: Int
    public var faultHook: (@Sendable (FaultPoint, JobID) -> Void)?
    /// Test knobs (`@testable import Core`).
    var allowClone = true
    var forceCrossVolume = false
    var bodyOverride: (@Sendable (JobContext) async -> Void)? = nil
    public init(progressInterval: Duration = .milliseconds(100), copyChunkBytes: Int = 1 << 20,
                faultHook: (@Sendable (FaultPoint, JobID) -> Void)? = nil) {
        self.progressInterval = progressInterval; self.copyChunkBytes = copyChunkBytes; self.faultHook = faultHook
    }
}

public enum JobEvent: Sendable {
    case added(JobSnapshot)
    case updated(JobSnapshot)
    case finished(JobSnapshot, JobOutcome)
}

public actor FileOpQueue {
    private struct Entry {
        let ctx: JobContext
        var devices: Set<UInt64>?
        var started = false
        var suspended = false
        var finished = false
    }

    private let lanes: LanePool
    private let trash: any TrashService
    private let journal: Journal
    private let interaction: any FileOpInteraction
    private let tuning: FileOpTuning
    private var order: [JobID] = []
    private var entries: [JobID: Entry] = [:]
    private var outcomes: [JobID: JobOutcome] = [:]
    private var undoFlags: [JobID: Bool] = [:]
    private var outcomeWaiters: [JobID: [CheckedContinuation<JobOutcome, Never>]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private nonisolated let eventStream: AsyncStream<JobEvent>
    private nonisolated let continuation: AsyncStream<JobEvent>.Continuation

    public init(lanes: LanePool, trash: any TrashService, journal: Journal, interaction: any FileOpInteraction,
                tuning: FileOpTuning = FileOpTuning()) {
        self.lanes = lanes; self.trash = trash; self.journal = journal; self.interaction = interaction; self.tuning = tuning
        (eventStream, continuation) = AsyncStream.makeStream(of: JobEvent.self, bufferingPolicy: .unbounded)
    }

    public nonisolated var events: AsyncStream<JobEvent> { eventStream }

    @discardableResult
    public func enqueue(_ request: JobRequest) -> JobID {
        let id = JobID()
        let ctx = JobContext(id: id, request: request, lanes: lanes, trash: trash, journal: journal,
                             interaction: interaction, tuning: tuning)
        order.append(id)
        entries[id] = Entry(ctx: ctx)
        undoFlags[id] = request.registersUndo
        continuation.yield(.added(ctx.snapshot()))
        let urls = request.kind.allURLs
        let lanes = self.lanes
        Task {
            let probe = (try? await lanes.perform(on: .unknown, .fileOp) { _ in VolumeIdentity.probe(urls) })
                ?? VolumeIdentity.Probe(devices: [], laneVolume: .unknown)
            self.didProbe(id, probe)
        }
        return id
    }

    private func didProbe(_ id: JobID, _ probe: VolumeIdentity.Probe) {
        guard entries[id] != nil, !(entries[id]!.finished) else { return }
        entries[id]!.devices = probe.devices
        entries[id]!.ctx.setLaneVolume(probe.laneVolume)
        schedule()
    }

    /// A job starts when no earlier unfinished job has an unknown or overlapping device set (FIFO per volume set).
    private func schedule() {
        var earlier: [Set<UInt64>?] = []
        for id in order {
            guard let e = entries[id], !e.finished else { continue }
            let blocked = e.devices == nil || earlier.contains { d in
                guard let d, let mine = e.devices else { return true }
                return !d.isDisjoint(with: mine)
            }
            if !e.started && !e.suspended && !blocked { start(id) }
            earlier.append(e.devices)
        }
    }

    private func start(_ id: JobID) {
        entries[id]!.started = true
        let ctx = entries[id]!.ctx
        let ticker = startTicker(ctx)
        let body = tuning.bodyOverride
        Task {
            let outcome: JobOutcome
            if let body {
                ctx.setState(.running)
                await body(ctx)
                outcome = ctx.outcome()
            } else {
                outcome = await JobRunner.run(ctx)
            }
            ticker.cancel()
            self.didFinish(id, outcome)
        }
    }

    private func startTicker(_ ctx: JobContext) -> Task<Void, Never> {
        let interval = tuning.progressInterval
        let continuation = self.continuation
        return Task.detached {
            var last: JobSnapshot?
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                ctx.tickThroughput(now: .now)
                let s = ctx.snapshot()
                if s != last { continuation.yield(.updated(s)); last = s }
            }
        }
    }

    private func didFinish(_ id: JobID, _ outcome: JobOutcome) {
        guard let e = entries[id], !e.finished else { return }
        e.ctx.setState(.finished)
        entries[id] = nil
        order.removeAll { $0 == id }
        outcomes[id] = outcome
        continuation.yield(.finished(e.ctx.snapshot(), outcome))
        for w in outcomeWaiters.removeValue(forKey: id) ?? [] { w.resume(returning: outcome) }
        schedule()
        if !hasActiveJobs {
            let waiters = idleWaiters
            idleWaiters = []
            for w in waiters { w.resume() }
        }
    }

    public func pause(_ id: JobID) {
        guard let e = entries[id] else { return }
        e.ctx.control.pause()
        e.ctx.setState(.paused)
        if !e.started { entries[id]!.suspended = true }
    }

    public func resume(_ id: JobID) {
        guard let e = entries[id] else { return }
        e.ctx.control.resume()
        e.ctx.setState(e.started ? .running : .queued)
        entries[id]!.suspended = false
        schedule()
    }

    public func cancel(_ id: JobID) {
        guard let e = entries[id] else { return }
        e.ctx.cancelJob()
        if !e.started { didFinish(id, e.ctx.outcome()) }
    }

    public func cancelAll() async {
        for id in order { cancel(id) }
        await waitUntilIdle()
    }

    public func snapshots() -> [JobSnapshot] { order.compactMap { entries[$0]?.ctx.snapshot() } }

    public func outcome(of id: JobID) async -> JobOutcome {
        if let o = outcomes[id] { return o }
        guard entries[id] != nil else {
            return JobOutcome(record: JobRecord(id: id, verb: .copying, actions: []), skipped: [], wasCancelled: false, created: [], localChanges: [])
        }
        return await withCheckedContinuation { outcomeWaiters[id, default: []].append($0) }
    }

    public func waitUntilIdle() async {
        guard hasActiveJobs else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public var hasActiveJobs: Bool { !entries.isEmpty }

    public func suspendJobs(touching mountPoint: URL) -> [JobID] {
        let prefix = mountPoint.standardizedFileURL.path
        func touches(_ e: Entry) -> Bool {
            e.ctx.kind.allURLs.contains { u in let p = u.standardizedFileURL.path; return p == prefix || p.hasPrefix(prefix + "/") }
        }
        var running: [JobID] = []
        for id in order {
            guard let e = entries[id], touches(e) else { continue }
            if e.started { running.append(id) } else { pause(id) }
        }
        return running
    }

    /// Whether the request asked for an undo entry (OperationsCenter checks it on .finished).
    public func registersUndo(_ id: JobID) -> Bool { undoFlags[id] ?? false }
}
```

- [ ] **Step 8: Run the tests and see them pass**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, no warnings.
Run: `swift test --filter 'CoreTests.(QueueTests|PlannerTests)' 2>&1 | tail -5`
Expected: `Executed 20 tests, with 0 failures` (the 3 image tests show as skipped without hdiutil).

- [ ] **Step 9: Commit**

```bash
git add Sources/Core/FileOps Tests/CoreTests/FileOps
git commit -m "feat: file-operation queue with volume-set scheduling, plan phase and progress"
```

---
### Task P1-19: Rename primitive, name generator, newItem and rename jobs

Spec: §6.3 rename primitive (rules 1–3), §5.6 F2 rename (case/normalization-only rename uses plain `rename(2)`, read back, two-step fallback recorded in the journal), §6.3 "New items" (New Folder / New Folder 2, Untitled.txt, Untitled; enter inline rename), §6.4 Keep Both naming (`x 2.ext`), §6.3 Duplicate naming (`name copy`, `name copy 2`), §9 (rename-primitive fallback and case-only renames on an exFAT image).

**Files:**
- Create: `Sources/Core/FileOps/RenamePrimitive.swift`, `Sources/Core/FileOps/NameGenerator.swift`, `Sources/Core/FileOps/CreateOps.swift`
- Modify: `Sources/Core/FileOps/JobRunner.swift` (add `FailureResolution` + `resolveFailure`; dispatch `.newItem`, `.rename`)
- Test: `Tests/CoreTests/FileOps/RenameTests.swift`

**Interfaces:**
- Consumes: `JobContext` (P1-18: `onLane`, `attempt`, `askError`, `record`, `landed`, `noteRenamed`, `journalRecord`, `journalClear`, `skip`, `cancelJob`, `setTotals`, `addProgress`), `PosixFS`, `VolumeIdentity.capabilities(of:)`, `NameNormalizer.nfc(_:)` and `NameNormalizer.sameName(_:_:caseSensitive:)` (P1-05).
- Produces (internal):

```swift
enum RenameOutcome: Sendable, Equatable { case renamed, exists, crossDevice, failed(Int32) }
enum InPlaceRename: Sendable, Equatable { case applied, needsTwoStep, failed(Int32) }
enum RenamePrimitive {
    static func rename(_ from: String, _ to: String, renameExcl: Bool) -> RenameOutcome     // lane only
    static func isSameItemRename(_ old: String, _ new: String, caseSensitive: Bool) -> Bool  // pure
    static func renameInPlace(_ from: String, _ to: String) -> InPlaceRename                // lane only
    static func directory(_ dir: String, containsExactly name: String) -> Bool              // lane only, readdir bytes
}
enum NameGenerator {
    static func split(_ name: String, isDirectory: Bool) -> (base: String, ext: String)
    static func keepBoth(_ name: String, isDirectory: Bool, taken: (String) -> Bool) -> String     // "x 2.ext"
    static func copyName(_ name: String, isDirectory: Bool, taken: (String) -> Bool) -> String     // "x copy.ext", "x copy 2.ext"
    static func newItemName(_ kind: NewItemKind, taken: (String) -> Bool) -> String               // "New Folder", "Untitled.txt", "Untitled"
}
enum FailureResolution: Sendable, Equatable { case retry, skipped, cancelled }
extension JobContext { func resolveFailure(_ code: Int32, url: URL, destination: URL? = nil) async -> FailureResolution }
enum CreateOps {
    static func newItem(_ ctx: JobContext, kind: NewItemKind, in directory: URL) async
    static func rename(_ ctx: JobContext, _ url: URL, to newName: String) async
    static func twoStepRename(_ ctx: JobContext, from: URL, to: URL) async -> StepResult
}
```

- [ ] **Step 1: Write the failing tests**

`Tests/CoreTests/FileOps/RenameTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

final class RenameTests: FileOpsTestCase {
    // MARK: NameGenerator (pure)

    func testKeepBothNames() {
        var taken: Set<String> = ["x.txt"]
        XCTAssertEqual(NameGenerator.keepBoth("x.txt", isDirectory: false) { taken.contains($0) }, "x 2.txt")
        taken.insert("x 2.txt")
        XCTAssertEqual(NameGenerator.keepBoth("x.txt", isDirectory: false) { taken.contains($0) }, "x 3.txt")
        XCTAssertEqual(NameGenerator.keepBoth("x 2.txt", isDirectory: false) { taken.contains($0) }, "x 3.txt")
        XCTAssertEqual(NameGenerator.keepBoth("photos.album", isDirectory: true) { _ in false }, "photos.album 2")
        XCTAssertEqual(NameGenerator.keepBoth(".env", isDirectory: false) { _ in false }, ".env 2")
        XCTAssertEqual(NameGenerator.keepBoth("Makefile", isDirectory: false) { _ in false }, "Makefile 2")
        let long = String(repeating: "a", count: 251) + ".txt"
        let kept = NameGenerator.keepBoth(long, isDirectory: false) { _ in false }
        XCTAssertLessThanOrEqual(kept.utf8.count, 255)
        XCTAssertTrue(kept.hasSuffix(" 2.txt"))
    }

    func testCopyNames() {
        var taken: Set<String> = []
        XCTAssertEqual(NameGenerator.copyName("a.txt", isDirectory: false) { taken.contains($0) }, "a copy.txt")
        taken = ["a copy.txt"]
        XCTAssertEqual(NameGenerator.copyName("a.txt", isDirectory: false) { taken.contains($0) }, "a copy 2.txt")
        XCTAssertEqual(NameGenerator.copyName("dir", isDirectory: true) { _ in false }, "dir copy")
    }

    func testNewItemNames() {
        XCTAssertEqual(NameGenerator.newItemName(.folder) { _ in false }, "New Folder")
        XCTAssertEqual(NameGenerator.newItemName(.folder) { $0 == "New Folder" }, "New Folder 2")
        XCTAssertEqual(NameGenerator.newItemName(.textFile) { _ in false }, "Untitled.txt")
        XCTAssertEqual(NameGenerator.newItemName(.textFile) { $0 == "Untitled.txt" }, "Untitled 2.txt")
        XCTAssertEqual(NameGenerator.newItemName(.emptyFile) { _ in false }, "Untitled")
    }

    func testIsSameItemRename() {
        XCTAssertTrue(RenamePrimitive.isSameItemRename("a.txt", "A.txt", caseSensitive: false))
        XCTAssertFalse(RenamePrimitive.isSameItemRename("a.txt", "A.txt", caseSensitive: true))
        XCTAssertTrue(RenamePrimitive.isSameItemRename("caf\u{E9}", "cafe\u{301}", caseSensitive: true))
        XCTAssertFalse(RenamePrimitive.isSameItemRename("a.txt", "a.txt", caseSensitive: false))
        XCTAssertFalse(RenamePrimitive.isSameItemRename("a.txt", "b.txt", caseSensitive: false))
    }

    // MARK: primitive

    func testRenamePrimitiveExclusiveAndFallback() async throws {
        let a = try file("a", "A"), b = try file("b", "B")
        let lanes = LanePool()
        for excl in [true, false] {
            let r = try await lanes.perform(on: .unknown, .fileOp) { _ in RenamePrimitive.rename(a.path, b.path, renameExcl: excl) }
            XCTAssertEqual(r, .exists, "excl=\(excl)")
            XCTAssertEqual(text(b), "B")
        }
        let c = url("c")
        let ok = try await lanes.perform(on: .unknown, .fileOp) { _ in RenamePrimitive.rename(a.path, c.path, renameExcl: false) }
        XCTAssertEqual(ok, .renamed)
        XCTAssertEqual(text(c), "A")
    }

    // MARK: jobs

    func testRenameJobRenamesRecordsAndPostsLocalChange() async throws {
        let a = try file("d/a.txt", "A")
        let inode = lst(a).st_ino
        let (queue, _) = makeQueue()
        let outcome = try await run(.rename(a, to: "b.txt"), on: queue)
        let b = url("d/b.txt")
        XCTAssertEqual(text(b), "A")
        XCTAssertFalse(exists(a))
        XCTAssertEqual(lst(b).st_ino, inode)
        guard case .renamed(let from, let to, let id)? = outcome.record.actions.first else { return XCTFail("\(outcome.record)") }
        XCTAssertEqual(from, a); XCTAssertEqual(to, b); XCTAssertEqual(id.inode, inode)
        XCTAssertEqual(outcome.localChanges.first?.renamed, [LocalChange.Rename(from: "a.txt", to: "b.txt")])
        XCTAssertEqual(outcome.localChanges.first?.select, ["b.txt"])
    }

    func testRenameOntoExistingNameNeverOverwrites() async throws {
        let a = try file("a.txt", "A"); try file("b.txt", "B")
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: scripted)
        let outcome = try await run(.rename(a, to: "b.txt"), on: queue)
        XCTAssertEqual(text(url("b.txt")), "B")
        XCTAssertEqual(text(a), "A")
        XCTAssertEqual(scripted.askedErrors().first?.kind, .other(code: EEXIST, message: String(cString: strerror(EEXIST))))
        XCTAssertEqual(outcome.record.actions, [])
    }

    func testCaseOnlyRenameOnSandboxVolume() async throws {
        let a = try file("d/a.txt", "A")
        let (queue, journal) = makeQueue()
        _ = try await run(.rename(a, to: "A.txt"), on: queue)
        XCTAssertEqual(names(url("d")), ["A.txt"])
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testNormalizationOnlyRenameStoresNewBytes() async throws {
        let nfc = "caf\u{E9}.txt", nfd = "cafe\u{301}.txt"
        let a = try file("d/\(nfc)", "A")
        let (queue, _) = makeQueue()
        _ = try await run(.rename(a, to: nfd), on: queue)
        let dirURL = url("d")
        let hasNFD = try await LanePool().perform(on: .unknown, .fileOp) { _ in RenamePrimitive.directory(dirURL.path, containsExactly: nfd) }
        XCTAssertTrue(hasNFD)
    }

    func testCaseOnlyRenameOnExFATImage() async throws {
        let mnt = try image(.exfat, sizeMB: 32)
        let a = mnt.appending(path: "a.txt")
        try Data("A".utf8).write(to: a)
        let (queue, journal) = makeQueue()
        let outcome = try await run(.rename(a, to: "A.txt"), on: queue)
        let mntPath = mnt.path
        let exact = try await LanePool().perform(on: .unknown, .fileOp) { _ in RenamePrimitive.directory(mntPath, containsExactly: "A.txt") }
        XCTAssertTrue(exact, "exFAT listing: \(names(mnt))")
        XCTAssertEqual(text(mnt.appending(path: "A.txt")), "A")
        XCTAssertEqual(outcome.skipped, [])
        let entries = await journal.entries()
        XCTAssertEqual(entries, [], "two-step journal entry cleared")
    }

    func testTwoStepRenameLandsAndClearsJournal() async throws {
        let a = try file("d/a.txt", "A")
        let journal = Journal(fileURL: journalURL)
        let ctx = JobContext(id: JobID(), request: JobRequest(.rename(a, to: "A.txt")), lanes: LanePool(),
                             trash: SandboxTrash(directory: trashDir), journal: journal,
                             interaction: ScriptedInteraction(), tuning: FileOpTuning())
        let r = await CreateOps.twoStepRename(ctx, from: a, to: url("d/A.txt"))
        XCTAssertEqual(r, .done)
        XCTAssertEqual(names(url("d")), ["A.txt"])
        let entries = await journal.entries()
        XCTAssertEqual(entries.filter { if case .twoStepRename = $0 { true } else { false } }, [])
    }

    func testRenameRejectsSlashEmptyAndTooLong() async throws {
        let a = try file("a.txt")
        let scripted = ScriptedInteraction()
        let (queue, _) = makeQueue(interaction: scripted)
        for bad in ["x/y", "", String(repeating: "n", count: 256)] {
            let outcome = try await run(.rename(a, to: bad), on: queue)
            XCTAssertEqual(outcome.record.actions, [], bad)
        }
        XCTAssertTrue(exists(a))
        XCTAssertEqual(scripted.askedErrors().last?.kind, .nameTooLong)
    }

    func testRenameLockedItemOffersUnlockAndContinue() async throws {
        let a = try file("a.txt", "A")
        XCTAssertEqual(lchflags(a.path, UInt32(UF_IMMUTABLE)), 0)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.rename(a, to: "b.txt"), on: queue)
        XCTAssertEqual(scripted.askedErrors().first?.kind, .locked)
        XCTAssertEqual(text(url("b.txt")), "A")
    }

    func testNewItemsGetSequentialNamesAndBeginRename() async throws {
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let o1 = try await run(.newItem(.folder, in: d), on: queue)
        let o2 = try await run(.newItem(.folder, in: d), on: queue)
        let o3 = try await run(.newItem(.textFile, in: d), on: queue)
        let o4 = try await run(.newItem(.emptyFile, in: d), on: queue)
        XCTAssertEqual(names(d), ["New Folder", "New Folder 2", "Untitled", "Untitled.txt"])
        XCTAssertEqual(o1.localChanges.first?.beginRename, "New Folder")
        XCTAssertEqual(o2.created.map(\.lastPathComponent), ["New Folder 2"])
        XCTAssertEqual(o3.localChanges.first?.added, ["Untitled.txt"])
        guard case .created(let u, _)? = o4.record.actions.first else { return XCTFail() }
        XCTAssertEqual(u.lastPathComponent, "Untitled")
        XCTAssertEqual(lst(url("d/Untitled.txt")).st_size, 0)
    }
}
```

`testCaseOnlyRenameOnExFATImage` writes with `Data.write` into the mount point of an image this test created.

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --filter CoreTests.RenameTests 2>&1 | tail -10`
Expected: compile failure, `cannot find 'NameGenerator' in scope`.

- [ ] **Step 3: Implement `NameGenerator.swift`**

```swift
import Foundation

/// On-disk names fixed by spec §6.3/§6.4 (Phase 1 ships English only; these are file names, not UI text).
enum NameGenerator {
    static func split(_ name: String, isDirectory: Bool) -> (base: String, ext: String) {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, !ext.contains(" ") else { return (name, "") }
        return (String(name[..<dot]), String(ext))
    }

    /// base + suffix (+ "." + ext), shortening base on a character boundary to stay ≤ 255 UTF-8 bytes.
    static func join(_ base: String, suffix: String, _ ext: String) -> String {
        var b = base
        func make() -> String { ext.isEmpty ? b + suffix : b + suffix + "." + ext }
        while make().utf8.count > 255, !b.isEmpty { b.removeLast() }
        return make()
    }

    static func keepBoth(_ name: String, isDirectory: Bool, taken: (String) -> Bool) -> String {
        let (base, ext) = split(name, isDirectory: isDirectory)
        var stem = base
        var n = 2
        if let m = base.wholeMatch(of: /(.+) (\d{1,4})/), let k = Int(m.2) { stem = String(m.1); n = k + 1 }
        while true {
            let candidate = join(stem, suffix: " \(n)", ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    static func copyName(_ name: String, isDirectory: Bool, taken: (String) -> Bool) -> String {
        let (base, ext) = split(name, isDirectory: isDirectory)
        let first = join(base, suffix: " copy", ext)
        if !taken(first) { return first }
        var n = 2
        while true {
            let candidate = join(base, suffix: " copy \(n)", ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    static func newItemName(_ kind: NewItemKind, taken: (String) -> Bool) -> String {
        let (base, ext): (String, String) = switch kind {
        case .folder: ("New Folder", "")
        case .textFile: ("Untitled", "txt")
        case .emptyFile: ("Untitled", "")
        }
        let first = join(base, suffix: "", ext)
        if !taken(first) { return first }
        var n = 2
        while true {
            let candidate = join(base, suffix: " \(n)", ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}
```

- [ ] **Step 4: Implement `RenamePrimitive.swift`**

```swift
import Foundation
import Darwin
import MacxFS

enum RenameOutcome: Sendable, Equatable { case renamed, exists, crossDevice, failed(Int32) }
enum InPlaceRename: Sendable, Equatable { case applied, needsTwoStep, failed(Int32) }

/// §6.3 rename primitive. Same vs cross volume is decided by callers with st_dev (VolumeIdentity).
enum RenamePrimitive {
    /// renamex_np(RENAME_EXCL); without renameExcl, or on ENOTSUP/EINVAL, lstat check + rename(2)
    /// (the small race against other processes is accepted; per-volume FIFO covers our own jobs).
    static func rename(_ from: String, _ to: String, renameExcl: Bool) -> RenameOutcome {
        assertOffMain()
        if renameExcl {
            if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return .renamed }
            let e = errno
            switch e {
            case EEXIST: return .exists
            case EXDEV: return .crossDevice
            case ENOTSUP, EINVAL: break
            default: return .failed(e)
            }
        }
        if PosixFS.exists(to) { return .exists }
        if Darwin.rename(from, to) == 0 { return .renamed }
        let e = errno
        switch e {
        case EXDEV: return .crossDevice
        case EEXIST, ENOTEMPTY: return .exists
        default: return .failed(e)
        }
    }

    /// The new name designates the same file: normalization-only, or case-only on a case-insensitive volume.
    static func isSameItemRename(_ old: String, _ new: String, caseSensitive: Bool) -> Bool {
        guard Array(old.utf8) != Array(new.utf8) else { return false }
        if NameNormalizer.nfc(old) == NameNormalizer.nfc(new) { return true }
        return !caseSensitive && NameNormalizer.sameName(old, new, caseSensitive: false)
    }

    /// Plain rename(2) (atomic on APFS/HFS+), then read the name back. Volumes that reject it or keep
    /// the old spelling (some SMB, exFAT, FAT) need the journaled two-step rename.
    static func renameInPlace(_ from: String, _ to: String) -> InPlaceRename {
        assertOffMain()
        if Darwin.rename(from, to) != 0 {
            let e = errno
            switch e {
            case ENOENT, EACCES, EPERM, EROFS, ENAMETOOLONG: return .failed(e)
            default: return .needsTwoStep
            }
        }
        let dir = (to as NSString).deletingLastPathComponent
        let name = (to as NSString).lastPathComponent
        return directory(dir, containsExactly: name) ? .applied : .needsTwoStep
    }

    /// readdir byte comparison (no normalization, no case folding).
    static func directory(_ dir: String, containsExactly name: String) -> Bool {
        assertOffMain()
        guard let d = opendir(dir) else { return false }
        defer { closedir(d) }
        let target = Array(name.utf8)
        while let ent = readdir(d) {
            let len = Int(ent.pointee.d_namlen)
            let match = withUnsafeBytes(of: &ent.pointee.d_name) { raw in
                len == target.count && raw.prefix(len).elementsEqual(target)
            }
            if match { return true }
        }
        return false
    }
}
```

- [ ] **Step 5: Add `resolveFailure` to `JobRunner.swift`**

Append to `Sources/Core/FileOps/JobRunner.swift`:

```swift
enum FailureResolution: Sendable, Equatable { case retry, skipped, cancelled }

extension JobContext {
    /// Asks about one failed step (errno). Skip records the item; Unlock and Continue clears uchg first.
    func resolveFailure(_ code: Int32, url: URL, destination: URL? = nil) async -> FailureResolution {
        let locked = code == EPERM ? ((try? await onLane { _ in
            (PosixFS.info(url.path)?.isLocked ?? false) || (PosixFS.info(url.deletingLastPathComponent().path)?.isLocked ?? false)
        }) ?? false) : false
        let kind = FileOpErrorKind(errno: code, isLockedItem: locked)
        switch await askError(FileOpError(kind: kind, url: url, destination: destination)) {
        case .retry, .continueAnyway: return .retry
        case .unlockAndContinue:
            _ = try? await onLane { _ in PosixFS.clearImmutable(url.path, recursive: false) }
            return .retry
        case .skip, .skipAll: skip(url, reason: kind); return .skipped
        case .cancel: cancelJob(); return .cancelled
        }
    }
}
```

- [ ] **Step 6: Implement `CreateOps.swift`**

```swift
import Foundation
import Darwin
import MacxFS

enum CreateOps {
    static func newItem(_ ctx: JobContext, kind: NewItemKind, in directory: URL) async {
        ctx.setTotals(items: 1, bytes: 0)
        ctx.setState(.running)
        while true {
            let result = (try? await ctx.onLane { _ -> (Int32, URL?, FileIdentity?) in
                for _ in 0..<1_000 {
                    let name = NameGenerator.newItemName(kind) { PosixFS.exists(directory.appending(path: $0).path) }
                    let u = directory.appending(path: name, directoryHint: kind == .folder ? .isDirectory : .notDirectory)
                    let rc: Int32
                    if kind == .folder {
                        rc = mkdir(u.path, 0o777) == 0 ? 0 : errno
                    } else {
                        let fd = open(u.path, O_CREAT | O_EXCL | O_WRONLY, 0o666)
                        rc = fd >= 0 ? 0 : errno
                        if fd >= 0 { close(fd) }
                    }
                    if rc == EEXIST { continue }               // lost a race with another process; next name
                    return (rc, rc == 0 ? u : nil, rc == 0 ? FileIdentity.of(path: u.path) : nil)
                }
                return (EEXIST, nil, nil)
            }) ?? (EIO, nil, nil)
            if result.0 == 0, let url = result.1, let id = result.2 {
                ctx.record(.created(url, id))
                ctx.landed(url, select: true, beginRename: true)
                ctx.addProgress(items: 1, current: url.lastPathComponent)
                return
            }
            switch await ctx.resolveFailure(result.0, url: directory) {
            case .retry: continue
            case .skipped, .cancelled: return
            }
        }
    }

    static func rename(_ ctx: JobContext, _ url: URL, to newName: String) async {
        ctx.setTotals(items: 1, bytes: 0)
        ctx.setState(.running)
        if newName.isEmpty || newName.contains("/") || newName.utf8.count > 255 {
            let kind: FileOpErrorKind = newName.utf8.count > 255 ? .nameTooLong
                : .other(code: EINVAL, message: String(cString: strerror(EINVAL)))
            if await ctx.askError(FileOpError(kind: kind, url: url)) == .cancel { ctx.cancelJob() } else { ctx.skip(url, reason: kind) }
            return
        }
        guard url.lastPathComponent != newName else { return }
        let target = url.deletingLastPathComponent().appending(path: newName)
        let parent = url.deletingLastPathComponent()
        let caps = (try? await ctx.onLane { _ in VolumeIdentity.capabilities(of: parent) })
            ?? VolumeIdentity.Capabilities(clone: false, renameExcl: false, caseSensitive: false)
        let result: StepResult
        if RenamePrimitive.isSameItemRename(url.lastPathComponent, newName, caseSensitive: caps.caseSensitive) {
            result = await inPlace(ctx, from: url, to: target)
        } else {
            result = await ctx.attempt(url, destination: target) { _ in
                switch RenamePrimitive.rename(url.path, target.path, renameExcl: caps.renameExcl) {
                case .renamed: 0
                case .exists: EEXIST
                case .crossDevice: EXDEV
                case .failed(let e): e
                }
            }
        }
        guard result == .done else { return }
        let id = (try? await ctx.onLane { _ in FileIdentity.of(path: target.path) }) ?? nil
        if let id { ctx.record(.renamed(from: url, to: target, id)) }
        ctx.noteRenamed(from: url, to: target)
        ctx.addProgress(items: 1, current: newName)
    }

    private static func inPlace(_ ctx: JobContext, from: URL, to: URL) async -> StepResult {
        while true {
            let r = (try? await ctx.onLane { _ in RenamePrimitive.renameInPlace(from.path, to.path) }) ?? .failed(EIO)
            switch r {
            case .applied: return .done
            case .needsTwoStep: return await twoStepRename(ctx, from: from, to: to)
            case .failed(let e):
                switch await ctx.resolveFailure(e, url: from, destination: to) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
        }
    }

    /// from → temp → target, journaled first so LaunchRecovery can restore `from` after a crash.
    static func twoStepRename(_ ctx: JobContext, from: URL, to: URL) async -> StepResult {
        let temp = from.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString.prefix(8).lowercased()).macx-rename-\(ctx.id.short)")
        let entry = JournalEntry.twoStepRename(job: ctx.id, temporary: temp, original: from, target: to)
        do { try await ctx.journalRecord(entry) } catch {
            _ = await ctx.resolveFailure(EIO, url: from, destination: to)
            return .skipped
        }
        let r = await ctx.attempt(from, destination: to) { _ in
            let first = PosixFS.rename(from.path, temp.path)
            guard first == 0 else { return first }
            let second = PosixFS.rename(temp.path, to.path)
            if second != 0 { _ = PosixFS.rename(temp.path, from.path) }
            return second
        }
        await ctx.journalClear(entry)
        return r
    }
}
```

- [ ] **Step 7: Dispatch the two kinds in `JobRunner.run`**

In `Sources/Core/FileOps/JobRunner.swift`, inside `switch ctx.kind {` in `JobRunner.run`, insert above `default:`:

```swift
        case .newItem(let kind, let directory):
            await CreateOps.newItem(ctx, kind: kind, in: directory)
        case .rename(let url, let newName):
            await CreateOps.rename(ctx, url, to: newName)
```

- [ ] **Step 8: Run the tests and see them pass**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, no warnings.
Run: `swift test --filter CoreTests.RenameTests 2>&1 | tail -5`
Expected: `Executed 14 tests, with 0 failures` (`testCaseOnlyRenameOnExFATImage` skipped without hdiutil).

- [ ] **Step 9: Commit**

```bash
git add Sources/Core/FileOps Tests/CoreTests/FileOps/RenameTests.swift
git commit -m "feat: rename primitive, name generator, rename and new-item jobs"
```

---
### Task P1-20: CopyEngine, copy and duplicate jobs

Spec: §6.3 "Copy, files and symlinks" (`copyfile(3)` with `COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_DATA_SPARSE | COPYFILE_NOFOLLOW_SRC`, one call per item, our own recursion, clone byte accounting, the UI accepts jumps), §6.3 "Copy, directories" (pre-order `mkdir` 0700, post-order `COPYFILE_METADATA`, also for finished directories on cancel or failure), §6.3 Duplicate (`name copy`, `name copy 2`), §5.6 (copy-paste into the same folder makes Finder-style copies), §6.1 (pause between items and copy chunks; cancel finishes the current item safely), §6.4 conflict question (Skip and Keep Both here, Replace/Merge in P1-22), §6.5 free-space dialog, §9 (preservation of mtime, mode, `uchg`, xattrs, tags, ACLs, sparse files; pause and cancel mid-copy). Review Focus 1 (job level), 2 and 4.

**Files:**
- Create: `Sources/Core/FileOps/CopyEngine.swift`, `Sources/Core/FileOps/CopyJob.swift`, `Sources/Core/FileOps/ConflictExecutor.swift` (question and memory only; P1-22 adds the Replace/Merge sequences to this file)
- Modify: `Sources/Core/FileOps/JobRunner.swift` (dispatch `.copy`, `.duplicate`)
- Test: `Tests/CoreTests/FileOps/CopyTests.swift`

**Interfaces:**
- Consumes: `JobContext` (P1-18), `JobPlan`/`PlanItem`/`PlanEntry`, `Planner`, `ctx.plan(sources:destination:mode:)`, `ctx.resolveFailure` (P1-19), `NameGenerator.copyName/keepBoth` (P1-19), `PosixFS`, `FileOpTuning.allowClone`.
- Produces (internal):

```swift
enum CopyResult: Sendable, Equatable { case copied, cancelled, failed(Int32) }
struct TreeCopyState: Sendable { struct OpenDir: Sendable { var relativePath, source, destination: String }
    var next: Int; var openDirs: [OpenDir]; var skippedPrefix: String?; var hadSkips: Bool }
enum TreeStep: Sendable, Equatable { case finished, failed(index: Int, code: Int32), cancelled }
enum TreeOutcome: Sendable, Equatable { case completed, partial, skipped, cancelled }
enum CopyEngine {
    static func fileFlags(clone: Bool) -> copyfile_flags_t
    static let metadataFlags: copyfile_flags_t
    static func copyFile(from: String, to: String, expectedSize: Int64, clone: Bool, chunkBytes: Int, lane: LaneContext,
                         control: JobControl, onBytes: @escaping (Int64) -> Void, onChunk: @escaping () -> Void) -> CopyResult
    static func makeDirectory(_ dst: String) -> Int32
    static func finalizeDirectory(from: String, to: String) -> Int32
    static func copyTree(_ item: PlanItem, to destinationRoot: String, state: inout TreeCopyState, clone: Bool, chunkBytes: Int,
                         lane: LaneContext, control: JobControl, progress: @escaping (Int, Int64, String?) -> Void,
                         onChunk: @escaping () -> Void) -> TreeStep
    static func finalizeAll(_ state: inout TreeCopyState)
    static func skipEntry(_ item: PlanItem, _ state: inout TreeCopyState)
}
enum TreeCopier { static func copy(_ ctx: JobContext, _ item: PlanItem, to destination: URL) async -> TreeOutcome }
enum CopyJob {
    static func run(_ ctx: JobContext, sources: [URL], destination: URL, duplicate: Bool) async
    static func copyItem(_ ctx: JobContext, _ item: PlanItem, to target: URL) async -> TreeOutcome
}
enum ConflictExecutor {
    enum Operation: Sendable, Equatable { case copy, move }
    static func summary(_ url: URL) -> ItemSummary?                                           // lane only
    /// Asks (or reuses an "all"/per-item answer). nil = the user cancelled the job.
    static func decide(_ ctx: JobContext, source: URL, target: URL, pending: [URL], destinationDir: URL) async -> ConflictAction?
}
```

- [ ] **Step 1: Write the failing tests**

`Tests/CoreTests/FileOps/CopyTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

final class CopyTests: FileOpsTestCase {
    private func runWithFinalSnapshot(_ kind: JobKind, _ queue: FileOpQueue) async throws -> (JobOutcome, JobSnapshot?) {
        let consumer = Task { () -> JobSnapshot? in
            for await e in queue.events { if case .finished(let s, _) = e { return s } }
            return nil
        }
        let outcome = try await run(kind, on: queue)
        return (outcome, await consumer.value)
    }
    private func link(_ u: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: u.path) }

    func testCopyFileRecordsCreatedLocalChangeAndCloneBytes() async throws {
        let a = try bigFile("src/a.bin", bytes: 8 << 20)
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let (outcome, final) = try await runWithFinalSnapshot(.copy(sources: [a], destination: d), queue)
        let copy = url("d/a.bin")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: a))
        guard case .created(let u, _)? = outcome.record.actions.first else { return XCTFail("\(outcome.record)") }
        XCTAssertEqual(u, copy)
        XCTAssertEqual(outcome.created, [copy])
        XCTAssertEqual(outcome.localChanges.map(\.directory.path), [d.standardizedFileURL.path])
        XCTAssertEqual(outcome.localChanges.first?.added, ["a.bin"])
        XCTAssertEqual(outcome.localChanges.first?.select, ["a.bin"])
        XCTAssertEqual(final?.progress.bytesDone, 8 << 20, "a clone sends no callbacks; bytes are counted when copyfile returns")
        XCTAssertEqual(final?.progress.itemsDone, 1)
    }

    func testCopyTreePreservesStructure() async throws {
        try file("T/a", "A"); try file("T/sub/b", "B"); try dir("T/empty")
        let (queue, _) = makeQueue()
        _ = try await run(.copy(sources: [url("T")], destination: try dir("d")), on: queue)
        XCTAssertEqual(names(url("d/T")), ["a", "empty", "sub"])
        XCTAssertEqual(text(url("d/T/sub/b")), "B")
    }

    func testDuplicateUsesFinderNames() async throws {
        let a = try file("a.txt", "A"), f = try dir("folder")
        let (queue, _) = makeQueue()
        _ = try await run(.duplicate([a, f]), on: queue)
        _ = try await run(.duplicate([a]), on: queue)
        XCTAssertEqual(names(root).filter { !$0.hasPrefix(".") && $0 != "state" },
                       ["a copy 2.txt", "a copy.txt", "a.txt", "folder", "folder copy"])
    }

    func testCopyIntoSameFolderMakesCopies() async throws {
        let a = try file("d/a.txt", "A")
        let (queue, _) = makeQueue()
        let o = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(names(url("d")), ["a copy.txt", "a.txt"])
        XCTAssertEqual(o.skipped, [])
    }

    /// Review Focus 1 at job level.
    func testCopyJobIntoOwnDescendantSkipsOnlyThatItem() async throws {
        try file("A/sub/x"); let b = try file("B", "b")
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [url("A"), b], destination: url("A/sub")), on: queue)
        XCTAssertEqual(names(url("A/sub")), ["B", "x"])
        XCTAssertEqual(o.skipped, [SkippedItem(url: url("A"), reason: .intoItself)])
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.intoItself])
    }

    /// Review Focus 2 (mandatory name).
    func testCopyTreeWithSymlinkLoopCopiesLinksAndTerminates() async throws {
        try file("A/f", "F"); try dir("A/sub")
        let absTarget = url("A").path
        for (target, rel) in [(".", "A/self"), ("..", "A/sub/up"), (absTarget, "A/abs"), ("nowhere", "A/broken"), ("sub", "A/sublink")] {
            XCTAssertEqual(symlink(target, url(rel).path), 0)
        }
        let (queue, _) = makeQueue()
        let start = ContinuousClock.now
        let o = try await run(.copy(sources: [url("A")], destination: try dir("d")), on: queue)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
        XCTAssertEqual(o.skipped, [])
        XCTAssertEqual(names(url("d/A")), ["abs", "broken", "f", "self", "sub", "sublink"])
        for (rel, target) in [("self", "."), ("sub/up", ".."), ("abs", absTarget), ("broken", "nowhere"), ("sublink", "sub")] {
            XCTAssertEqual(lst(url("d/A/\(rel)")).st_mode & S_IFMT, S_IFLNK, rel)
            XCTAssertEqual(link(url("d/A/\(rel)")), target, rel)
        }
    }

    func testDirectoryCopyPreservesMtimeModeAndLock() async throws {
        try file("T/ro/f"); try file("T/locked/g")
        var times = [timeval(tv_sec: 978_307_200, tv_usec: 0), timeval(tv_sec: 978_307_200, tv_usec: 0)]
        XCTAssertEqual(utimes(url("T/ro").path, &times), 0)
        XCTAssertEqual(utimes(url("T/locked").path, &times), 0)
        XCTAssertEqual(chmod(url("T/ro").path, 0o555), 0)
        XCTAssertEqual(lchflags(url("T/locked").path, UInt32(UF_IMMUTABLE)), 0)
        let (queue, _) = makeQueue()
        let o = try await run(.copy(sources: [url("T")], destination: try dir("d")), on: queue)
        XCTAssertEqual(o.skipped, [])
        let ro = lst(url("d/T/ro")), locked = lst(url("d/T/locked"))
        XCTAssertEqual(ro.st_mode & 0o7777, 0o555)
        XCTAssertEqual(ro.st_mtimespec.tv_sec, 978_307_200)
        XCTAssertEqual(locked.st_mtimespec.tv_sec, 978_307_200)
        XCTAssertNotEqual(locked.st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertTrue(exists(url("d/T/ro/f")))
        XCTAssertTrue(exists(url("d/T/locked/g")))
    }

    func testXattrsTagsAndACLPreservedWithoutClone() async throws {
        let f = try file("x.txt", "X")
        XCTAssertEqual(setxattr(f.path, "com.macexplorer.test", "v", 1, 0, XATTR_NOFOLLOW), 0)
        var rv = URLResourceValues(); rv.tagNames = ["Red"]
        var fu = f; try fu.setResourceValues(rv)
        let chmodA = Process()
        chmodA.executableURL = URL(filePath: "/bin/chmod")
        chmodA.arguments = ["+a", "everyone deny delete", f.path]
        try chmodA.run(); chmodA.waitUntilExit()
        XCTAssertEqual(chmodA.terminationStatus, 0)
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(tuning: tuning)
        _ = try await run(.copy(sources: [f], destination: try dir("d")), on: queue)
        let c = url("d/x.txt")
        var buf = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(getxattr(c.path, "com.macexplorer.test", &buf, 8, 0, XATTR_NOFOLLOW), 1)
        XCTAssertEqual(try URL(filePath: c.path).resourceValues(forKeys: [.tagNamesKey]).tagNames, ["Red"])
        let acl = acl_get_link_np(c.path, ACL_TYPE_EXTENDED)
        XCTAssertNotNil(acl, "extended ACL copied")
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
    }

    func testSparseFileStaysSparseWithoutClone() async throws {
        let s = try sandbox.createFile("sparse", contents: Data())
        let h = try FileHandle(forWritingTo: s)
        try h.seek(toOffset: 256 << 20); try h.write(contentsOf: Data([1])); try h.close()
        guard Int64(lst(s).st_blocks) * 512 < 1 << 20 else { throw XCTSkip("sandbox volume does not store sparse files") }
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(tuning: tuning)
        _ = try await run(.copy(sources: [s], destination: try dir("d")), on: queue)
        let c = lst(url("d/sparse"))
        XCTAssertEqual(c.st_size, (256 << 20) + 1)
        XCTAssertLessThan(Int64(c.st_blocks) * 512, 4 << 20)
    }

    func testPauseAndResumeMidFile() async throws {
        let big = try bigFile("big", bytes: 64 << 20)
        let d = try dir("d")
        let reached = EventLog()
        let proceed = DispatchSemaphore(value: 0)
        var tuning = FileOpTuning(copyChunkBytes: 1 << 20, faultHook: { point, _ in
            if point == .midCopyChunk, !reached.all.contains("chunk") { reached.add("chunk"); proceed.wait() }
        })
        tuning.allowClone = false
        let (queue, _) = makeQueue(tuning: tuning)
        let id = await queue.enqueue(JobRequest(.copy(sources: [big], destination: d)))
        await waitUntil { reached.all.contains("chunk") }
        await queue.pause(id)
        proceed.signal()
        try await Task.sleep(for: .milliseconds(300))
        let s1 = await queue.snapshots().first!
        try await Task.sleep(for: .milliseconds(200))
        let s2 = await queue.snapshots().first!
        XCTAssertEqual(s1.state, .paused)
        XCTAssertEqual(s1.progress.bytesDone, s2.progress.bytesDone, "no bytes copied while paused")
        XCTAssertLessThan(s2.progress.bytesDone, 64 << 20)
        await queue.resume(id)
        let o = await queue.outcome(of: id)
        XCTAssertFalse(o.wasCancelled)
        XCTAssertEqual(try Data(contentsOf: url("d/big")), try Data(contentsOf: big))
    }

    /// Slice Review Focus 4.
    func testCancelMidFileRemovesPartialFileAndFinalizesDirectories() async throws {
        try file("T/a", "A")
        try bigFile("T/z-big", bytes: 64 << 20)
        XCTAssertEqual(chmod(url("T").path, 0o750), 0)
        let reached = EventLog()
        let proceed = DispatchSemaphore(value: 0)
        var tuning = FileOpTuning(faultHook: { point, _ in
            if point == .midCopyChunk, !reached.all.contains("chunk") { reached.add("chunk"); proceed.wait() }
        })
        tuning.allowClone = false
        let (queue, _) = makeQueue(tuning: tuning)
        let id = await queue.enqueue(JobRequest(.copy(sources: [url("T")], destination: try dir("d"))))
        await waitUntil { reached.all.contains("chunk") }
        await queue.cancel(id)
        proceed.signal()
        let o = await queue.outcome(of: id)
        XCTAssertTrue(o.wasCancelled)
        XCTAssertEqual(names(url("d/T")), ["a"], "the interrupted file is removed")
        XCTAssertEqual(lst(url("d/T")).st_mode & 0o7777, 0o750, "directory finalized, not left at 0700")
        guard case .created(let u, _)? = o.record.actions.first else { return XCTFail() }
        XCTAssertEqual(u, url("d/T"))
    }

    func testUnreadableEntryReportsPermissionAndOtherEntriesCopy() async throws {
        try file("T/a"); try file("T/secret"); try file("T/c")
        XCTAssertEqual(chmod(url("T/secret").path, 0o000), 0)
        let scripted = ScriptedInteraction(errors: [.skip])
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.copy(sources: [url("T")], destination: try dir("d")), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.permissionDenied])
        XCTAssertEqual(names(url("d/T")), ["a", "c"])
        XCTAssertEqual(o.skipped.map(\.url), [url("T/secret")])
    }

    func testConflictAskedAndSkipKeepsDestination() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        let scripted = ScriptedInteraction()
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a")), "old")
        XCTAssertEqual(o.skipped, [SkippedItem(url: a, reason: nil)])
        let asked = scripted.askedConflicts()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.isFolderMerge, false)
        XCTAssertEqual(asked.first?.knownRemaining, 1)
        XCTAssertEqual(asked.first?.pair.destination.url, url("d/a"))
    }

    func testConflictKeepBoth() async throws {
        let a = try file("src/a.txt", "new"); try file("d/a.txt", "old")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.keepBoth)]))
        _ = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "old")
        XCTAssertEqual(text(url("d/a 2.txt")), "new")
    }

    func testCopyToSmallImageAsksForSpaceAndCopiesNothingWhenDeclined() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let big = try bigFile("big", bytes: 40 << 20)
        let scripted = ScriptedInteraction(space: [false])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [big], destination: mnt), on: queue)
        XCTAssertTrue(o.wasCancelled)
        XCTAssertEqual(scripted.askedSpace().count, 1)
        XCTAssertFalse(names(mnt).contains("big"))
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --filter CoreTests.CopyTests 2>&1 | tail -10`
Expected: compile failure (`cannot find 'TreeCopier' in scope`), or, once it compiles, every test fails with `ENOTSUP` skips from the `default:` dispatch.

- [ ] **Step 3: Implement `CopyEngine.swift`**

```swift
import Foundation
import Darwin
import MacxFS

enum CopyResult: Sendable, Equatable { case copied, cancelled, failed(Int32) }

struct TreeCopyState: Sendable {
    struct OpenDir: Sendable { var relativePath: String; var source: String; var destination: String }
    var next = 0
    var openDirs: [OpenDir] = []
    var skippedPrefix: String? = nil
    var hadSkips = false
}

enum TreeStep: Sendable, Equatable { case finished, failed(index: Int, code: Int32), cancelled }

/// Callback context for one copyfile call; lives on the lane thread only (never crosses isolation).
final class CopyProgressBox {
    let lane: LaneContext
    let control: JobControl
    let chunk: Int64
    var reported: Int64 = 0
    var nextMark: Int64
    let onBytes: (Int64) -> Void
    let onChunk: () -> Void
    init(lane: LaneContext, control: JobControl, chunk: Int64, onBytes: @escaping (Int64) -> Void, onChunk: @escaping () -> Void) {
        self.lane = lane; self.control = control; self.chunk = max(1, chunk); self.nextMark = max(1, chunk)
        self.onBytes = onBytes; self.onChunk = onChunk
    }
    func progress(_ copied: Int64) {
        if copied > reported { onBytes(copied - reported); reported = copied }
        while copied >= nextMark { nextMark += chunk; onChunk() }
    }
}

enum CopyEngine {
    /// COPYFILE_ALL | DATA_SPARSE | NOFOLLOW_SRC | EXCL (+ CLONE, which also implies EXCL).
    static func fileFlags(clone: Bool) -> copyfile_flags_t {
        var f = copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA)
        f |= copyfile_flags_t(COPYFILE_DATA_SPARSE) | copyfile_flags_t(COPYFILE_NOFOLLOW_SRC) | copyfile_flags_t(COPYFILE_EXCL)
        if clone { f |= copyfile_flags_t(COPYFILE_CLONE) }
        return f
    }
    static let metadataFlags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR)

    /// One file or symlink. Never leaves a half-written destination behind (it is created exclusively,
    /// so on failure other than EEXIST it is ours to unlink).
    static func copyFile(from src: String, to dst: String, expectedSize: Int64, clone: Bool, chunkBytes: Int,
                         lane: LaneContext, control: JobControl,
                         onBytes: @escaping (Int64) -> Void, onChunk: @escaping () -> Void) -> CopyResult {
        assertOffMain()
        guard let state = copyfile_state_alloc() else { return .failed(ENOMEM) }
        defer { copyfile_state_free(state) }
        let box = CopyProgressBox(lane: lane, control: control, chunk: Int64(chunkBytes), onBytes: onBytes, onChunk: onChunk)
        return withExtendedLifetime(box) {
            let callback: copyfile_callback_t = { what, stage, state, _, _, ctx in
                guard let ctx else { return COPYFILE_CONTINUE }
                let box = Unmanaged<CopyProgressBox>.fromOpaque(ctx).takeUnretainedValue()
                if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                    var copied: off_t = 0
                    _ = copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                    box.progress(Int64(copied))
                }
                box.lane.heartbeat()
                return box.control.laneCheckpoint(box.lane) ? COPYFILE_CONTINUE : COPYFILE_QUIT
            }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(box).toOpaque())
            if copyfile(src, dst, state, fileFlags(clone: clone)) == 0 {
                if expectedSize > box.reported { onBytes(expectedSize - box.reported) }   // clone: no callbacks
                return .copied
            }
            let e = errno
            if e != EEXIST { _ = unlink(dst) }
            if control.isCancelled || e == ECANCELED { return .cancelled }
            return .failed(e)
        }
    }

    static func makeDirectory(_ dst: String) -> Int32 {
        assertOffMain()
        return mkdir(dst, 0o700) == 0 ? 0 : errno
    }

    /// Post-order: mode, timestamps, BSD flags (uchg), ACL, xattrs.
    static func finalizeDirectory(from src: String, to dst: String) -> Int32 {
        assertOffMain()
        return copyfile(src, dst, nil, metadataFlags) == 0 ? 0 : errno
    }

    static func isUnder(_ rel: String, _ dirRel: String) -> Bool { dirRel.isEmpty || rel.hasPrefix(dirRel + "/") }
    static func join(_ root: String, _ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    /// Resumable: copies item.entries[state.next...]; returns at the first failing entry (state.next stays
    /// on it) so the async side can ask Retry/Skip/Cancel; closes directories post-order; finalizes every
    /// open directory on finish and on cancel.
    static func copyTree(_ item: PlanItem, to destinationRoot: String, state: inout TreeCopyState, clone: Bool,
                         chunkBytes: Int, lane: LaneContext, control: JobControl,
                         progress: @escaping (Int, Int64, String?) -> Void, onChunk: @escaping () -> Void) -> TreeStep {
        assertOffMain()
        let srcRoot = item.source.path
        while state.next < item.entries.count {
            let e = item.entries[state.next]
            if let skipped = state.skippedPrefix {
                if e.relativePath != skipped && isUnder(e.relativePath, skipped) { state.next += 1; continue }
                state.skippedPrefix = nil
            }
            while let top = state.openDirs.last, !isUnder(e.relativePath, top.relativePath) {
                state.openDirs.removeLast()
                _ = finalizeDirectory(from: top.source, to: top.destination)
            }
            guard control.laneCheckpoint(lane) else { finalizeAll(&state); return .cancelled }
            lane.heartbeat()
            let src = join(srcRoot, e.relativePath)
            let dst = join(destinationRoot, e.relativePath)
            let label = e.relativePath.isEmpty ? item.source.lastPathComponent : e.relativePath
            switch e.type {
            case .directory:
                if e.errorCode != 0 { return .failed(index: state.next, code: e.errorCode) }
                let rc = makeDirectory(dst)
                if rc != 0 { return .failed(index: state.next, code: rc) }
                state.openDirs.append(.init(relativePath: e.relativePath, source: src, destination: dst))
                progress(1, 0, label)
            case .file, .symlink:
                let r = copyFile(from: src, to: dst, expectedSize: e.type == .file ? e.size : 0, clone: clone,
                                 chunkBytes: chunkBytes, lane: lane, control: control,
                                 onBytes: { progress(0, $0, nil) }, onChunk: onChunk)
                switch r {
                case .copied: progress(1, 0, label)
                case .cancelled: finalizeAll(&state); return .cancelled
                case .failed(let code): return .failed(index: state.next, code: code)
                }
            case .other:
                return .failed(index: state.next, code: ENOTSUP)   // FIFOs, sockets, devices: never read
            }
            state.next += 1
        }
        finalizeAll(&state)
        return .finished
    }

    static func finalizeAll(_ state: inout TreeCopyState) {
        while let top = state.openDirs.popLast() { _ = finalizeDirectory(from: top.source, to: top.destination) }
    }

    /// Skip the failing entry (and its subtree when it is a directory).
    static func skipEntry(_ item: PlanItem, _ state: inout TreeCopyState) {
        let e = item.entries[state.next]
        if e.type == .directory { state.skippedPrefix = e.relativePath }
        state.next += 1
        state.hadSkips = true
    }
}

enum TreeOutcome: Sendable, Equatable { case completed, partial, skipped, cancelled }

/// Async driver: runs copyTree on a fileOp lane, asks about failing entries, resumes.
enum TreeCopier {
    static func copy(_ ctx: JobContext, _ item: PlanItem, to destination: URL) async -> TreeOutcome {
        var state = TreeCopyState()
        let clone = ctx.tuning.allowClone
        let chunk = ctx.tuning.copyChunkBytes
        let control = ctx.control
        let jobID = ctx.id
        let hook = ctx.tuning.faultHook
        while true {
            let start = state
            let result = try? await ctx.onLane { lane -> (TreeStep, TreeCopyState) in
                var st = start
                let step = CopyEngine.copyTree(item, to: destination.path, state: &st, clone: clone, chunkBytes: chunk,
                                               lane: lane, control: control,
                                               progress: { items, bytes, current in ctx.addProgress(items: items, bytes: bytes, current: current) },
                                               onChunk: { hook?(.midCopyChunk, jobID) })
                return (step, st)
            }
            let (step, newState) = result ?? (.failed(index: state.next, code: EIO), state)
            state = newState
            switch step {
            case .finished:
                return state.hadSkips ? .partial : .completed
            case .cancelled:
                return .cancelled
            case .failed(let index, let code):
                let rel = item.entries[index].relativePath
                let failing = rel.isEmpty ? item.source : item.source.appending(path: rel)
                switch await ctx.resolveFailure(code, url: failing, destination: destination) {
                case .retry:
                    continue
                case .skipped:
                    if index == 0 {
                        let s = state
                        _ = try? await ctx.onLane { _ in var st = s; CopyEngine.finalizeAll(&st) }
                        return .skipped
                    }
                    CopyEngine.skipEntry(item, &state)
                case .cancelled:
                    let s = state
                    _ = try? await ctx.onLane { _ in var st = s; CopyEngine.finalizeAll(&st) }
                    return .cancelled
                }
            }
        }
    }
}
```

- [ ] **Step 4: Implement `ConflictExecutor.swift` (question and memory)**

```swift
import Foundation
import MacxFS

enum ConflictExecutor {
    enum Operation: Sendable, Equatable { case copy, move }

    static func summary(_ url: URL) -> ItemSummary? {
        guard let i = PosixFS.info(url.path) else { return nil }
        return ItemSummary(url: url, isDirectory: i.isDirectory, size: i.size, modified: i.mtime)
    }

    /// §6.4: asks once per conflict unless an "all" (per class: file/file or folder/folder) or per-item
    /// (Compare) answer applies. Replace on folder/folder means Merge (as in Explorer); Merge on a
    /// non-folder pair means Keep Both. nil = the user cancelled the job.
    static func decide(_ ctx: JobContext, source: URL, target: URL, pending: [URL], destinationDir: URL) async -> ConflictAction? {
        let summaries = try? await ctx.onLane { _ -> (ItemSummary?, ItemSummary?, [ConflictPair]) in
            let pairs = pending.compactMap { p -> ConflictPair? in
                guard let s = summary(p), let d = summary(destinationDir.appending(path: p.lastPathComponent)) else { return nil }
                return ConflictPair(source: s, destination: d)
            }
            return (summary(source), summary(target), pairs)
        }
        guard case let (s?, d?, pairs)? = summaries else { return .skip }
        let folder = s.isDirectory && d.isDirectory
        func normalize(_ a: ConflictAction) -> ConflictAction {
            switch (a, folder) {
            case (.replace, true): .merge
            case (.merge, false): .keepBoth
            default: a
            }
        }
        if let remembered = ctx.rememberedConflictAction(folder: folder, source: source) { return normalize(remembered) }
        let info = ConflictInfo(pair: ConflictPair(source: s, destination: d), isFolderMerge: folder,
                                knownRemaining: max(1, pairs.count), pendingPairs: pairs.isEmpty ? [ConflictPair(source: s, destination: d)] : pairs)
        let resolution = await ctx.askConflict(info)
        ctx.rememberConflict(resolution, folder: folder)
        switch resolution {
        case .one(let a), .all(let a): return normalize(a)
        case .perItem(let map): return normalize(map[source] ?? .skip)
        case .cancelJob: ctx.cancelJob(); return nil
        }
    }
}
```

- [ ] **Step 5: Implement `CopyJob.swift`**

```swift
import Foundation
import MacxFS

enum CopyJob {
    /// Copy (destination == source parent → duplicate naming) and Duplicate.
    static func run(_ ctx: JobContext, sources: [URL], destination: URL, duplicate: Bool) async {
        guard let plan = await ctx.plan(sources: sources, destination: destination, mode: .copy) else { return }
        var pending = plan.topLevelConflicts
        var first = true
        for item in plan.items {
            guard await ctx.checkpoint() else { break }
            let src = item.source
            let isDir = item.info.isDirectory
            let sameParent = src.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path
            var name = src.lastPathComponent
            if duplicate || sameParent {
                name = (try? await ctx.onLane { _ in
                    NameGenerator.copyName(src.lastPathComponent, isDirectory: isDir) { PosixFS.exists(destination.appending(path: $0).path) }
                }) ?? name
            } else if (try? await ctx.onLane({ _ in PosixFS.exists(destination.appending(path: src.lastPathComponent).path) })) == true {
                let target = destination.appending(path: name)
                guard let action = await ConflictExecutor.decide(ctx, source: src, target: target, pending: pending, destinationDir: destination) else { break }
                pending.removeAll { $0 == src }
                switch action {
                case .skip:
                    ctx.skip(src, reason: nil)
                    continue
                case .keepBoth:
                    name = (try? await ctx.onLane { _ in
                        NameGenerator.keepBoth(src.lastPathComponent, isDirectory: isDir) { PosixFS.exists(destination.appending(path: $0).path) }
                    }) ?? name
                case .replace, .merge:
                    // P1-22 replaces this case with ConflictExecutor.execute(...).
                    ctx.skip(src, reason: nil)
                    continue
                }
            }
            _ = await copyItem(ctx, item, to: destination.appending(path: name))
            if first { first = false; ctx.fault(.afterFirstItem) }
        }
    }

    /// Copies one top-level item to `target` and records it (also when cancelled or partly skipped:
    /// whatever landed is recorded so undo can remove it).
    @discardableResult
    static func copyItem(_ ctx: JobContext, _ item: PlanItem, to target: URL) async -> TreeOutcome {
        let outcome = await TreeCopier.copy(ctx, item, to: target)
        guard outcome != .skipped else { return outcome }
        if let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil {
            ctx.record(.created(target, id))
            ctx.landed(target)
        }
        return outcome
    }
}
```

- [ ] **Step 6: Dispatch copy and duplicate in `JobRunner.run`**

Insert above `default:` in the `switch ctx.kind` of `JobRunner.run`:

```swift
        case .copy(let sources, let destination):
            await CopyJob.run(ctx, sources: sources, destination: destination, duplicate: false)
        case .duplicate(let urls):
            let groups = Dictionary(grouping: urls) { $0.deletingLastPathComponent().standardizedFileURL.path }
            for parent in groups.keys.sorted() where !ctx.control.isCancelled {
                await CopyJob.run(ctx, sources: groups[parent]!, destination: URL(filePath: parent, directoryHint: .isDirectory), duplicate: true)
            }
```

- [ ] **Step 7: Run the tests and see them pass**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, no warnings.
Run: `swift test --filter CoreTests.CopyTests 2>&1 | tail -5`
Expected: `Executed 15 tests, with 0 failures` (the image test is skipped without hdiutil; the sparse test skips only if the sandbox volume is not sparse-capable).

- [ ] **Step 8: Run the earlier FileOps suites (regression)**

Run: `swift test --filter 'CoreTests.(FileOpErrorTests|JournalTests|QueueTests|PlannerTests|RenameTests)' 2>&1 | tail -3`
Expected: `with 0 failures`.

- [ ] **Step 9: Commit**

```bash
git add Sources/Core/FileOps Tests/CoreTests/FileOps/CopyTests.swift
git commit -m "feat: copy engine with per-item copyfile, two-pass directory metadata, copy and duplicate jobs"
```

---
### Task P1-21: MoveJob (same-volume rename, cross-volume partial → verify → rename → delete), crash tests

Spec: §6.3 "Move, same volume" (rename primitive; `EXDEV` → re-plan as cross-volume), "Move, across volumes" (copy to `<dest>/.<name>.macx-partial-<jobID>`, verify item count and byte totals, rename to the final name, only then delete the source; on failure remove the partial and never delete the source; journal; launch cleanup), §5.6 (cut-paste into the items' own folder does nothing), §9 (cross-volume move on a disk image with a simulated kill during copy; source intact; journal cleanup works). Review Focus 3.

**Files:**
- Create: `Sources/Core/FileOps/MoveJob.swift`
- Modify: `Sources/Core/FileOps/JobRunner.swift` (dispatch `.move`)
- Test: `Tests/CoreTests/FileOps/MoveTests.swift`, `Tests/CoreTests/FileOps/CrashHelper.swift`, `Tests/CoreTests/FileOps/CrashRecoveryTests.swift`

**Interfaces:**
- Consumes: `TreeCopier.copy`, `ConflictExecutor.decide`, `RenamePrimitive.rename`, `PartialName.make`, `PosixFS.treeStats/removeTree`, `Planner.enumerate`, `ctx.journalRecord/journalClear/fault/resolveFailure/askError`, `LaunchRecovery.run` (P1-17).
- Produces (internal):

```swift
enum MoveJob {
    static func run(_ ctx: JobContext, sources: [URL], destination: URL) async
    static func moveItem(_ ctx: JobContext, _ item: PlanItem, to target: URL, renameExcl: Bool) async -> StepResult
    static func crossVolume(_ ctx: JobContext, _ item: PlanItem, to target: URL) async -> StepResult
    static func removePartial(_ ctx: JobContext, _ partial: URL, _ entry: JournalEntry) async
}
// Tests/CoreTests/FileOps/CrashHelper.swift (test target)
struct CrashSpec: Codable { var mode: String; var sources: [String]; var destination: String; var journal: String
    var trash: String; var fault: String; var conflict: String?; var forceCrossVolume: Bool; var allowClone: Bool }
final class CrashHelperEntry: XCTestCase { func testRunCrashHelper() async throws }
extension FileOpsTestCase { func runCrashingChild(_ spec: CrashSpec) async throws -> Bool }   // true = child died by SIGKILL
```

- [ ] **Step 1: Write the crash helper (child entry point and launcher)**

`Tests/CoreTests/FileOps/CrashHelper.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

/// Describes a job the child process runs until it SIGKILLs itself at `fault`.
struct CrashSpec: Codable {
    var mode: String                 // "move" | "copy"
    var sources: [String]
    var destination: String
    var journal: String
    var trash: String
    var fault: String                // FaultPoint raw value
    var conflict: String?            // ConflictAction raw value answered for every conflict
    var forceCrossVolume: Bool
    var allowClone: Bool
}

/// Entry point executed only inside the child `xctest` process (skips everywhere else).
final class CrashHelperEntry: XCTestCase {
    func testRunCrashHelper() async throws {
        guard let raw = ProcessInfo.processInfo.environment["MACX_CRASH_SPEC"] else {
            throw XCTSkip("child-process entry point for crash tests")
        }
        let spec = try JSONDecoder().decode(CrashSpec.self, from: Data(raw.utf8))
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/macx-tests-"
        for p in spec.sources + [spec.destination, spec.journal, spec.trash] where !p.hasPrefix(tmp) {
            return XCTFail("crash helper refuses a path outside a test sandbox: \(p)")
        }
        let fault = try XCTUnwrap(FaultPoint(rawValue: spec.fault))
        var tuning = FileOpTuning(faultHook: { point, _ in if point == fault { kill(getpid(), SIGKILL) } })
        tuning.forceCrossVolume = spec.forceCrossVolume
        tuning.allowClone = spec.allowClone
        let interaction = ScriptedInteraction(conflicts: spec.conflict.flatMap(ConflictAction.init(rawValue:)).map { [.all($0)] } ?? [])
        let queue = FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: URL(filePath: spec.trash, directoryHint: .isDirectory)),
                                journal: Journal(fileURL: URL(filePath: spec.journal)), interaction: interaction, tuning: tuning)
        let sources = spec.sources.map { URL(filePath: $0) }
        let destination = URL(filePath: spec.destination, directoryHint: .isDirectory)
        let kind: JobKind = spec.mode == "move" ? .move(sources: sources, destination: destination)
                                                : .copy(sources: sources, destination: destination)
        let id = await queue.enqueue(JobRequest(kind))
        _ = await queue.outcome(of: id)
        XCTFail("fault point \(spec.fault) was never reached")
    }
}

extension FileOpsTestCase {
    /// Runs `spec` in a child `xcrun xctest` process of this same test bundle. Returns true if the child was SIGKILLed.
    func runCrashingChild(_ spec: CrashSpec) async throws -> Bool {
        for p in spec.sources + [spec.destination, spec.journal, spec.trash] {
            guard p.hasPrefix(root.path + "/") else { XCTFail("outside sandbox: \(p)"); return false }
        }
        let bundle = Bundle(for: CrashHelperEntry.self).bundlePath
        guard bundle.hasSuffix(".xctest"), FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("xcrun xctest unavailable (bundle \(bundle))")
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "CoreTests.CrashHelperEntry/testRunCrashHelper", bundle]
        var env = ProcessInfo.processInfo.environment
        env["MACX_CRASH_SPEC"] = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, any Error>) in
            process.terminationHandler = { p in
                c.resume(returning: p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL)
            }
            do { try process.run() } catch { c.resume(throwing: error) }
        }
    }
}
```

- [ ] **Step 2: Write the failing move tests**

`Tests/CoreTests/FileOps/MoveTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

final class MoveTests: FileOpsTestCase {
    private func partials(_ dir: URL) -> [String] { names(dir).filter { $0.contains(PartialName.marker) } }

    func testSameVolumeMoveKeepsInodeAndRecords() async throws {
        let a = try file("src/a.txt", "A")
        let inode = lst(a).st_ino
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let o = try await run(.move(sources: [a], destination: d), on: queue)
        XCTAssertFalse(exists(a))
        XCTAssertEqual(lst(url("d/a.txt")).st_ino, inode)
        guard case .moved(let from, let to, let id)? = o.record.actions.first else { return XCTFail("\(o.record)") }
        XCTAssertEqual(from, a); XCTAssertEqual(to, url("d/a.txt")); XCTAssertEqual(id.inode, inode)
        XCTAssertEqual(Set(o.localChanges.flatMap(\.removed)), ["a.txt"])
        XCTAssertEqual(Set(o.localChanges.flatMap(\.added)), ["a.txt"])
    }

    func testSameVolumeMoveOfFolder() async throws {
        try file("src/T/x"); try file("src/T/y/z")
        let (queue, _) = makeQueue()
        _ = try await run(.move(sources: [url("src/T")], destination: try dir("d")), on: queue)
        XCTAssertEqual(names(url("d/T")), ["x", "y"])
        XCTAssertFalse(exists(url("src/T")))
    }

    func testMoveIntoOwnFolderIsNoOp() async throws {
        let a = try file("d/a.txt")
        let scripted = ScriptedInteraction()
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(o.record.actions, [])
        XCTAssertEqual(scripted.askedConflicts().count, 0)
        XCTAssertTrue(exists(a))
    }

    func testForcedCrossVolumeMoveCopiesVerifiesAndDeletesSource() async throws {
        try file("src/T/x", "X"); try bigFile("src/T/y/big", bytes: 2 << 20)
        var tuning = FileOpTuning(); tuning.forceCrossVolume = true
        let (queue, journal) = makeQueue(tuning: tuning)
        let d = try dir("d")
        let o = try await run(.move(sources: [url("src/T")], destination: d), on: queue)
        XCTAssertEqual(text(url("d/T/x")), "X")
        XCTAssertEqual(lst(url("d/T/y/big")).st_size, 2 << 20)
        XCTAssertFalse(exists(url("src/T")))
        XCTAssertEqual(partials(d), [])
        guard case .moved(let from, let to, _)? = o.record.actions.last else { return XCTFail("\(o.record)") }
        XCTAssertEqual(from, url("src/T")); XCTAssertEqual(to, url("d/T"))
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testCrossVolumeMoveToDiskImage() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 32)
        try file("src/T/x", "X"); try file("src/T/sub/y", "Y")
        let (queue, _) = makeQueue()
        let o = try await run(.move(sources: [url("src/T")], destination: mnt), on: queue)
        XCTAssertEqual(text(mnt.appending(path: "T/sub/y")), "Y")
        XCTAssertFalse(exists(url("src/T")))
        XCTAssertEqual(partials(mnt), [])
        XCTAssertEqual(o.skipped, [])
    }

    func testCrossDeviceRenameFallsBackToCopy() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let a = try file("a.txt", "A")
        let lanes = LanePool()
        let item = try await lanes.perform(on: .unknown, .fileOp) { lane in
            Planner.plan(sources: [a], destination: nil, mode: .shallow, forceCrossVolume: false, lane: lane).items[0]
        }
        XCTAssertTrue(item.sameVolume, "planned as same-volume, so the rename will hit EXDEV")
        let ctx = JobContext(id: JobID(), request: JobRequest(.move(sources: [a], destination: mnt)), lanes: lanes,
                             trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                             interaction: ScriptedInteraction(), tuning: FileOpTuning())
        let r = await MoveJob.moveItem(ctx, item, to: mnt.appending(path: "a.txt"), renameExcl: true)
        XCTAssertEqual(r, .done)
        XCTAssertEqual(text(mnt.appending(path: "a.txt")), "A")
        XCTAssertFalse(exists(a))
    }

    /// Review Focus 3 (mandatory name).
    func testCrossVolumeMoveKeepsSourceWhenItChangesDuringCopy() async throws {
        let src = try bigFile("src/log.txt", bytes: 1 << 20)
        let d = try dir("d")
        let srcPath = src.path
        var tuning = FileOpTuning(faultHook: { point, _ in
            guard point == .afterPartialCopy, let h = FileHandle(forWritingAtPath: srcPath) else { return }
            h.seekToEndOfFile(); h.write(Data("more".utf8)); h.closeFile()
        })
        tuning.forceCrossVolume = true
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, journal) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.move(sources: [src], destination: d), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.changedDuringMove])
        XCTAssertEqual(FileOpErrorKind.changedDuringMove.allowedResolutions, [.retry, .skip, .cancel])
        XCTAssertEqual(lst(src).st_size, (1 << 20) + 4, "source kept, with the new bytes")
        XCTAssertEqual(names(d), [], "partial removed, nothing landed")
        XCTAssertEqual(o.skipped, [SkippedItem(url: src, reason: .changedDuringMove)])
        XCTAssertEqual(o.record.actions, [])
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testChangedDuringMoveRetryMovesTheNewContent() async throws {
        let src = try bigFile("src/log.txt", bytes: 1 << 20)
        let d = try dir("d")
        let srcPath = src.path
        let once = EventLog()
        var tuning = FileOpTuning(faultHook: { point, _ in
            guard point == .afterPartialCopy, once.all.isEmpty, let h = FileHandle(forWritingAtPath: srcPath) else { return }
            once.add("appended")
            h.seekToEndOfFile(); h.write(Data("more".utf8)); h.closeFile()
        })
        tuning.forceCrossVolume = true
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(errors: [.retry]), tuning: tuning)
        _ = try await run(.move(sources: [src], destination: d), on: queue)
        XCTAssertFalse(exists(src))
        XCTAssertEqual(lst(url("d/log.txt")).st_size, (1 << 20) + 4)
    }

    func testCrossVolumeCopyFailureRemovesPartialAndKeepsSource() async throws {
        try file("src/T/a", "A"); try file("src/T/secret", "S")
        XCTAssertEqual(chmod(url("src/T/secret").path, 0o000), 0)
        var tuning = FileOpTuning(); tuning.forceCrossVolume = true; tuning.allowClone = false
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(errors: [.skip]), tuning: tuning)
        let d = try dir("d")
        _ = try await run(.move(sources: [url("src/T")], destination: d), on: queue)
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(names(url("src/T")), ["a", "secret"])
    }

    func testMoveConflictKeepBoth() async throws {
        let a = try file("src/a.txt", "new"); try file("d/a.txt", "old")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.keepBoth)]))
        _ = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "old")
        XCTAssertEqual(text(url("d/a 2.txt")), "new")
        XCTAssertFalse(exists(a))
    }
}
```

- [ ] **Step 3: Write the failing crash-recovery tests**

`Tests/CoreTests/FileOps/CrashRecoveryTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

final class CrashRecoveryTests: FileOpsTestCase {
    private func spec(_ sources: [URL], _ dest: URL, fault: FaultPoint, mode: String = "move",
                      conflict: ConflictAction? = nil, force: Bool) -> CrashSpec {
        CrashSpec(mode: mode, sources: sources.map(\.path), destination: dest.path, journal: journalURL.path,
                  trash: trashDir.path, fault: fault.rawValue, conflict: conflict?.rawValue,
                  forceCrossVolume: force, allowClone: false)
    }

    func testKillDuringCrossVolumeCopyKeepsSourceAndRecoveryRemovesPartial() async throws {
        try bigFile("src/T/big", bytes: 32 << 20); try file("src/T/small", "S")
        let before = try Data(contentsOf: url("src/T/big"))
        let d = try dir("d")
        let killed = try await runCrashingChild(spec([url("src/T")], d, fault: .midCopyChunk, force: true))
        XCTAssertTrue(killed)
        XCTAssertEqual(names(d).filter { PartialName.isPartial($0) }.count, 1, "partial left by the crash: \(names(d))")
        XCTAssertEqual(try Data(contentsOf: url("src/T/big")), before)
        let journal = Journal(fileURL: journalURL)
        let report = await LaunchRecovery.run(journal: journal, lanes: LanePool())
        XCTAssertEqual(report.removedPartials.count, 1)
        XCTAssertEqual(report.incompleteJobs.count, 1)
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(names(url("src/T")), ["big", "small"])
        let left = await journal.entries()
        XCTAssertEqual(left, [])
    }

    func testKillDuringMoveToDiskImageKeepsSource() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 64)
        try bigFile("src/big", bytes: 24 << 20)
        let killed = try await runCrashingChild(spec([url("src/big")], mnt, fault: .midCopyChunk, force: false))
        XCTAssertTrue(killed)
        XCTAssertEqual(lst(url("src/big")).st_size, 24 << 20)
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(report.removedPartials.count, 1)
        XCTAssertFalse(names(mnt).contains { PartialName.isPartial($0) || $0 == "big" })
    }

    func testKillBeforeSourceDeleteLosesNothing() async throws {
        try file("src/T/a", "A")
        let d = try dir("d")
        let killed = try await runCrashingChild(spec([url("src/T")], d, fault: .beforeSourceDelete, force: true))
        XCTAssertTrue(killed)
        XCTAssertEqual(text(url("d/T/a")), "A")
        XCTAssertEqual(text(url("src/T/a")), "A")
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(report.removedPartials, [])
        XCTAssertEqual(report.incompleteJobs.count, 1)
        XCTAssertEqual(text(url("d/T/a")), "A")
        XCTAssertEqual(text(url("src/T/a")), "A")
    }

    func testKillAfterPartialCopyRecoveryRemovesCompletePartial() async throws {
        try file("src/f", "F")
        let d = try dir("d")
        let killed = try await runCrashingChild(spec([url("src/f")], d, fault: .afterPartialCopy, force: true))
        XCTAssertTrue(killed)
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(report.removedPartials.map { PartialName.isPartial($0.lastPathComponent) }, [true])
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(text(url("src/f")), "F")
    }
}
```

- [ ] **Step 4: Run the tests and watch them fail**

Run: `swift test --filter 'CoreTests.(MoveTests|CrashRecoveryTests)' 2>&1 | tail -10`
Expected: failures; moves are skipped with `ENOTSUP` by the `default:` dispatch and the crash children exit without being killed (`XCTAssertTrue failed`).

- [ ] **Step 5: Implement `MoveJob.swift`**

```swift
import Foundation
import Darwin
import MacxFS

enum MoveJob {
    static func run(_ ctx: JobContext, sources: [URL], destination: URL) async {
        guard let plan = await ctx.plan(sources: sources, destination: destination, mode: .move) else { return }
        var pending = plan.topLevelConflicts
        var first = true
        for item in plan.items {
            guard await ctx.checkpoint() else { break }
            let src = item.source
            if src.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path { continue }
            let isDir = item.info.isDirectory
            var name = src.lastPathComponent
            if (try? await ctx.onLane({ _ in PosixFS.exists(destination.appending(path: src.lastPathComponent).path) })) == true {
                let target = destination.appending(path: name)
                guard let action = await ConflictExecutor.decide(ctx, source: src, target: target, pending: pending, destinationDir: destination) else { break }
                pending.removeAll { $0 == src }
                switch action {
                case .skip:
                    ctx.skip(src, reason: nil)
                    continue
                case .keepBoth:
                    name = (try? await ctx.onLane { _ in
                        NameGenerator.keepBoth(src.lastPathComponent, isDirectory: isDir) { PosixFS.exists(destination.appending(path: $0).path) }
                    }) ?? name
                case .replace, .merge:
                    // P1-22 replaces this case with ConflictExecutor.execute(...).
                    ctx.skip(src, reason: nil)
                    continue
                }
            }
            _ = await moveItem(ctx, item, to: destination.appending(path: name), renameExcl: plan.capabilities.renameExcl)
            if first { first = false; ctx.fault(.afterFirstItem) }
        }
    }

    /// Same volume: rename primitive (EXDEV → re-plan deep and move across volumes). Otherwise cross-volume.
    static func moveItem(_ ctx: JobContext, _ item: PlanItem, to target: URL, renameExcl: Bool) async -> StepResult {
        guard item.sameVolume else { return await crossVolume(ctx, item, to: target) }
        let src = item.source
        while true {
            let outcome = (try? await ctx.onLane { _ in RenamePrimitive.rename(src.path, target.path, renameExcl: renameExcl) }) ?? .failed(EIO)
            let code: Int32
            switch outcome {
            case .renamed:
                if let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil {
                    ctx.record(.moved(from: src, to: target, id))
                }
                ctx.noteRemoved(src)
                ctx.landed(target)
                ctx.addProgress(items: item.itemCount, bytes: item.byteCount, current: src.lastPathComponent)
                return .done
            case .crossDevice:
                let info = item.info
                let entries = (try? await ctx.onLane { lane in Planner.enumerate(src, info: info, noMaterialization: false, lane: lane) })
                var deep = item
                deep.sameVolume = false
                if let entries { deep.entries = entries.entries }
                return await crossVolume(ctx, deep, to: target)
            case .exists: code = EEXIST
            case .failed(let e): code = e
            }
            switch await ctx.resolveFailure(code, url: src, destination: target) {
            case .retry: continue
            case .skipped: return .skipped
            case .cancelled: return .cancelled
            }
        }
    }

    /// §6.3: partial copy → verify → rename into place → delete source. The source is never deleted
    /// unless the verified copy is at its final name.
    static func crossVolume(_ ctx: JobContext, _ item: PlanItem, to target: URL) async -> StepResult {
        let src = item.source
        let partial = target.deletingLastPathComponent().appending(path: PartialName.make(for: target.lastPathComponent, job: ctx.id))
        let entry = JournalEntry.partial(job: ctx.id, url: partial)
        while true {
            do { try await ctx.journalRecord(entry) } catch {
                switch await ctx.resolveFailure(EIO, url: src, destination: target) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
            let copied = await TreeCopier.copy(ctx, item, to: partial)
            guard copied == .completed else {
                await removePartial(ctx, partial, entry)
                return copied == .cancelled ? .cancelled : .skipped
            }
            ctx.fault(.afterPartialCopy)
            let verified = (try? await ctx.onLane { _ -> Bool in
                let a = PosixFS.treeStats(src.path), b = PosixFS.treeStats(partial.path)
                return a.items == b.items && a.bytes == b.bytes
            }) ?? false
            guard verified else {
                await removePartial(ctx, partial, entry)
                switch await ctx.askError(FileOpError(kind: .changedDuringMove, url: src, destination: target)) {
                case .retry, .continueAnyway, .unlockAndContinue: continue
                case .skip, .skipAll: ctx.skip(src, reason: .changedDuringMove); return .skipped
                case .cancel: ctx.cancelJob(); return .cancelled
                }
            }
            ctx.fault(.beforePartialRename)
            let renamed = (try? await ctx.onLane { _ in RenamePrimitive.rename(partial.path, target.path, renameExcl: true) }) ?? .failed(EIO)
            guard renamed == .renamed else {
                await removePartial(ctx, partial, entry)
                let code: Int32 = switch renamed { case .exists: EEXIST; case .crossDevice: EXDEV; case .failed(let e): e; case .renamed: 0 }
                switch await ctx.resolveFailure(code, url: src, destination: target) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
            await ctx.journalClear(entry)
            ctx.fault(.beforeSourceDelete)
            let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil
            var removed = false
            var unlock = false
            deleting: while true {
                let u = unlock
                let rc = (try? await ctx.onLane { _ in PosixFS.removeTree(src.path, unlock: u) }) ?? EIO
                if rc == 0 { removed = true; break deleting }
                switch await ctx.resolveFailure(rc, url: src) {
                case .retry: unlock = true; continue deleting
                case .skipped, .cancelled: break deleting
                }
            }
            if let id { ctx.record(removed ? .moved(from: src, to: target, id) : .created(target, id)) }
            if removed { ctx.noteRemoved(src) }
            ctx.landed(target)
            return .done
        }
    }

    static func removePartial(_ ctx: JobContext, _ partial: URL, _ entry: JournalEntry) async {
        _ = try? await ctx.onLane { _ in PosixFS.removeTree(partial.path, unlock: true) }
        await ctx.journalClear(entry)
    }
}
```

`deep.entries` and `deep.sameVolume` are assigned, so `PlanItem.entries` and `PlanItem.sameVolume` must be `var` (they are, P1-18).

- [ ] **Step 6: Dispatch `.move` in `JobRunner.run`**

Insert above `default:`:

```swift
        case .move(let sources, let destination):
            await MoveJob.run(ctx, sources: sources, destination: destination)
```

- [ ] **Step 7: Run the tests and see them pass**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, no warnings.
Run: `swift test --filter 'CoreTests.(MoveTests|CrashRecoveryTests|CrashHelperEntry)' 2>&1 | tail -5`
Expected: `Executed 15 tests, with 0 failures` (image tests skipped without hdiutil; `testRunCrashHelper` is skipped in the parent process).

- [ ] **Step 8: Commit**

```bash
git add Sources/Core/FileOps Tests/CoreTests/FileOps
git commit -m "feat: move job with crash-safe cross-volume path and kill/recovery tests"
```

---
### Task P1-22: ConflictExecutor (Replace, Keep Both, Merge, apply-to-all, per-item)

Spec: §6.3 "Conflicts during copy and move" (Replace for copy / cross-volume move: partial → verify → trash existing, journal its Trash URL → rename partial to final with `RENAME_EXCL` → delete source for a move; restore the trashed item if the final rename fails. Replace for same-volume move: trash existing, then the rename primitive. Merge: recurse, children follow the rules and the dialog, source folders removed only once empty. Keep Both: `x 2.ext`), §6.4 (Replace / Skip / Keep Both / Compare per-item, "Do this for all remaining conflicts (N)", folder onto folder = Merge / Keep Both / Skip, Replace never deletes), §9 (conflict-policy combinations same- and cross-volume; simulated kill during Replace restores the replaced item).

**Files:**
- Modify: `Sources/Core/FileOps/ConflictExecutor.swift` (add the execution sequences)
- Modify: `Sources/Core/FileOps/MoveJob.swift` (extract `finishMove`; route `.replace, .merge`)
- Modify: `Sources/Core/FileOps/CopyJob.swift` (route `.replace, .merge`)
- Test: `Tests/CoreTests/FileOps/ConflictTests.swift`; add one test to `Tests/CoreTests/FileOps/CrashRecoveryTests.swift`

**Interfaces:**
- Consumes: `ConflictExecutor.decide` (P1-20), `TreeCopier.copy`, `CopyJob.copyItem`, `MoveJob.moveItem/removePartial`, `PartialName`, `ctx.trash`, `ctx.journalRecord/journalClear/removeLastAction/fault/resolveFailure/askError`.
- Produces (internal):

```swift
extension ConflictExecutor {
    struct Trashed: Sendable { var original: URL; var trashURL: URL; var entry: JournalEntry }
    static func execute(_ ctx: JobContext, action: ConflictAction, item: PlanItem, destinationDir: URL, name: String,
                        operation: Operation, renameExcl: Bool) async -> StepResult
    static func transfer(_ ctx: JobContext, _ item: PlanItem, to target: URL, operation: Operation, renameExcl: Bool) async -> StepResult
    static func replace(_ ctx: JobContext, item: PlanItem, target: URL, operation: Operation, renameExcl: Bool) async -> StepResult
    static func merge(_ ctx: JobContext, item: PlanItem, into target: URL, operation: Operation, renameExcl: Bool) async -> StepResult
    static func trashExisting(_ ctx: JobContext, _ target: URL) async -> Trashed?
    static func restore(_ ctx: JobContext, _ trashed: Trashed) async
}
extension MoveJob { static func finishMove(_ ctx: JobContext, source: URL, target: URL) async }   // delete source, record moved/created, landed
```

- [ ] **Step 1: Write the failing conflict tests**

`Tests/CoreTests/FileOps/ConflictTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

final class ConflictTests: FileOpsTestCase {
    /// Every file named `name` anywhere under the sandbox trash, with its text.
    private func trashed(_ name: String) -> [String] {
        let e = FileManager.default.enumerator(atPath: trashDir.path)
        var out: [String] = []
        while let rel = e?.nextObject() as? String {
            guard (rel as NSString).lastPathComponent == name, let t = text(trashDir.appending(path: rel)) else { continue }
            out.append(t)
        }
        return out
    }
    private func partials(_ dir: URL) -> [String] { names(dir).filter { PartialName.isPartial($0) } }

    func testReplaceCopyTrashesExistingAfterVerifiedCopy() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        let (queue, journal) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        let o = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a")), "new")
        XCTAssertEqual(text(a), "new")
        XCTAssertEqual(trashed("a"), ["old"])
        XCTAssertEqual(partials(url("d")), [])
        guard o.record.actions.count == 2, case .replaced(let original, _, _) = o.record.actions[0],
              case .created(let created, _) = o.record.actions[1] else { return XCTFail("\(o.record.actions)") }
        XCTAssertEqual(original, url("d/a")); XCTAssertEqual(created, url("d/a"))
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testReplaceSameVolumeMoveTrashesThenRenames() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        let inode = lst(a).st_ino
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        let o = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(lst(url("d/a")).st_ino, inode, "renamed, not copied")
        XCTAssertFalse(exists(a))
        XCTAssertEqual(trashed("a"), ["old"])
        guard case .replaced = o.record.actions.first, case .moved = o.record.actions.last else { return XCTFail("\(o.record.actions)") }
    }

    func testReplaceCrossVolumeMove() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        var tuning = FileOpTuning(); tuning.forceCrossVolume = true
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]), tuning: tuning)
        _ = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a")), "new")
        XCTAssertFalse(exists(a))
        XCTAssertEqual(trashed("a"), ["old"])
        XCTAssertEqual(partials(url("d")), [])
    }

    func testReplaceRestoresTrashedItemWhenFinalRenameFails() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        let dPath = url("d").path
        var tuning = FileOpTuning(faultHook: { point, _ in
            guard point == .afterTrashDestination else { return }
            // Make the final rename fail: move the partial out of the way.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dPath)) ?? []
            if let p = names.first(where: { PartialName.isPartial($0) }) { _ = Darwin.rename(dPath + "/" + p, dPath + "/moved-away") }
        })
        tuning.forceCrossVolume = true
        let scripted = ScriptedInteraction(conflicts: [.one(.replace)], errors: [.skip])
        let (queue, journal) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a")), "old", "replaced item restored from the trash")
        XCTAssertEqual(text(a), "new", "source never deleted")
        XCTAssertEqual(trashed("a"), [])
        XCTAssertFalse(o.record.actions.contains { if case .replaced = $0 { true } else { false } })
        XCTAssertEqual(scripted.askedErrors().count, 1)
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testApplyToAllAnswersEveryRemainingConflict() async throws {
        for n in ["a", "b", "c"] { try file("src/\(n)", "new \(n)"); try file("d/\(n)", "old") }
        let scripted = ScriptedInteraction(conflicts: [.all(.keepBoth)])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.copy(sources: ["a", "b", "c"].map { url("src/\($0)") }, destination: url("d")), on: queue)
        XCTAssertEqual(scripted.askedConflicts().count, 1)
        XCTAssertEqual(scripted.askedConflicts().first?.knownRemaining, 3)
        XCTAssertEqual(names(url("d")), ["a", "a 2", "b", "b 2", "c", "c 2"])
    }

    func testPerItemCompareAnswersAndMissingKeysSkip() async throws {
        let a = try file("src/a", "new a"), b = try file("src/b", "new b")
        try file("d/a", "old a"); try file("d/b", "old b")
        let scripted = ScriptedInteraction(conflicts: [.perItem([a: .replace])])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [a, b], destination: url("d")), on: queue)
        XCTAssertEqual(scripted.askedConflicts().count, 1)
        XCTAssertEqual(scripted.askedConflicts().first?.pendingPairs.count, 2)
        XCTAssertEqual(text(url("d/a")), "new a")
        XCTAssertEqual(text(url("d/b")), "old b")
        XCTAssertEqual(o.skipped, [SkippedItem(url: b, reason: nil)])
    }

    func testCancelJobFromConflictStopsEverything() async throws {
        let a = try file("src/a"), b = try file("src/b")
        try file("d/a", "old")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.cancelJob]))
        let o = try await run(.copy(sources: [a, b], destination: url("d")), on: queue)
        XCTAssertTrue(o.wasCancelled)
        XCTAssertEqual(names(url("d")), ["a"])
        XCTAssertEqual(text(url("d/a")), "old")
    }

    func testFolderConflictOffersMergeAndMergesCopy() async throws {
        try file("src/F/a", "A"); try file("src/F/b", "new b"); try file("src/F/sub/c", "C")
        try file("d/F/b", "old b"); try file("d/F/x", "X")
        let scripted = ScriptedInteraction(conflicts: [.one(.merge), .one(.replace)])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.copy(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertEqual(scripted.askedConflicts().map(\.isFolderMerge), [true, false])
        XCTAssertEqual(names(url("d/F")), ["a", "b", "sub", "x"])
        XCTAssertEqual(text(url("d/F/b")), "new b")
        XCTAssertEqual(text(url("d/F/sub/c")), "C")
        XCTAssertEqual(trashed("b"), ["old b"])
        XCTAssertEqual(names(url("src/F")), ["a", "b", "sub"], "copy leaves the source")
    }

    func testMergeMoveRemovesSourceFolderOnlyWhenEmpty() async throws {
        try file("src/F/a", "A"); try file("src/F/b", "new b"); try file("src/F/sub/c", "C")
        try file("d/F/b", "old b"); try file("d/F/x", "X")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.merge), .one(.skip)]))
        _ = try await run(.move(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertEqual(names(url("src/F")), ["b"], "the skipped child stays; its folder stays")
        XCTAssertEqual(names(url("d/F")), ["a", "b", "sub", "x"])
        XCTAssertEqual(text(url("d/F/b")), "old b")
    }

    func testMergeMoveRemovesEmptiedSourceFolder() async throws {
        try file("src/F/a", "A"); try file("src/F/b", "new b")
        try file("d/F/b", "old b")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.merge), .one(.replace)]))
        _ = try await run(.move(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertFalse(exists(url("src/F")))
        XCTAssertEqual(text(url("d/F/b")), "new b")
    }

    func testReplaceOnFolderPairMeansMerge() async throws {
        try file("src/F/a", "A"); try file("d/F/x", "X")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        _ = try await run(.copy(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertEqual(names(url("d/F")), ["a", "x"], "folders are merged, never trashed wholesale")
    }

    func testReplaceAcrossDiskImage() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 32)
        let a = try file("src/a", "new")
        try Data("old".utf8).write(to: mnt.appending(path: "a"))
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        _ = try await run(.move(sources: [a], destination: mnt), on: queue)
        XCTAssertEqual(text(mnt.appending(path: "a")), "new")
        XCTAssertFalse(exists(a))
        XCTAssertFalse(names(mnt).contains { PartialName.isPartial($0) })
    }
}
```

Append to `CrashRecoveryTests`:

```swift
    func testKillAfterTrashingDestinationRestoresIt() async throws {
        try file("src/a", "new"); try file("d/a", "old")
        let d = url("d")
        let killed = try await runCrashingChild(spec([url("src/a")], d, fault: .afterTrashDestination, conflict: .replace, force: true))
        XCTAssertTrue(killed)
        XCTAssertFalse(exists(url("d/a")), "destination was in the trash at the moment of the kill")
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(report.restoredDestinations, [url("d/a")])
        XCTAssertEqual(report.removedPartials.count, 1)
        XCTAssertEqual(text(url("d/a")), "old")
        XCTAssertEqual(text(url("src/a")), "new")
        XCTAssertEqual(names(d), ["a"])
    }
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --filter 'CoreTests.(ConflictTests|CrashRecoveryTests)' 2>&1 | tail -10`
Expected: Replace/Merge tests fail (the item is skipped, e.g. `XCTAssertEqual failed: ("Optional("old")") is not equal to ("Optional("new")")`); Keep Both/per-item/cancel may already pass.

- [ ] **Step 3: Extract `finishMove` in `MoveJob.swift`**

In `MoveJob.crossVolume`, replace everything from `ctx.fault(.beforeSourceDelete)` to the `return .done` that ends the success path with:

```swift
            ctx.fault(.beforeSourceDelete)
            await finishMove(ctx, source: src, target: target)
            return .done
```

and add to `enum MoveJob`:

```swift
    /// After the verified copy is at `target`: delete the source (asking on failure; Retry also clears
    /// uchg), record moved (or created if the user skipped the deletion), post the changes.
    static func finishMove(_ ctx: JobContext, source src: URL, target: URL) async {
        let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil
        var removed = false
        var unlock = false
        deleting: while true {
            let u = unlock
            let rc = (try? await ctx.onLane { _ in PosixFS.removeTree(src.path, unlock: u) }) ?? EIO
            if rc == 0 { removed = true; break deleting }
            switch await ctx.resolveFailure(rc, url: src) {
            case .retry: unlock = true; continue deleting
            case .skipped, .cancelled: break deleting
            }
        }
        if let id { ctx.record(removed ? .moved(from: src, to: target, id) : .created(target, id)) }
        if removed { ctx.noteRemoved(src) }
        ctx.landed(target)
    }
```

- [ ] **Step 4: Add the execution sequences to `ConflictExecutor.swift`**

```swift
extension ConflictExecutor {
    struct Trashed: Sendable { var original: URL; var trashURL: URL; var entry: JournalEntry }

    static func execute(_ ctx: JobContext, action: ConflictAction, item: PlanItem, destinationDir: URL, name: String,
                        operation: Operation, renameExcl: Bool) async -> StepResult {
        let target = destinationDir.appending(path: name)
        switch action {
        case .skip:
            ctx.skip(item.source, reason: nil)
            return .skipped
        case .keepBoth:
            let isDir = item.info.isDirectory
            let free = (try? await ctx.onLane { _ in
                NameGenerator.keepBoth(name, isDirectory: isDir) { PosixFS.exists(destinationDir.appending(path: $0).path) }
            }) ?? name
            return await transfer(ctx, item, to: destinationDir.appending(path: free), operation: operation, renameExcl: renameExcl)
        case .replace:
            return await replace(ctx, item: item, target: target, operation: operation, renameExcl: renameExcl)
        case .merge:
            return await merge(ctx, item: item, into: target, operation: operation, renameExcl: renameExcl)
        }
    }

    /// Non-conflicting landing (rules of §6.3).
    static func transfer(_ ctx: JobContext, _ item: PlanItem, to target: URL, operation: Operation, renameExcl: Bool) async -> StepResult {
        switch operation {
        case .copy:
            switch await CopyJob.copyItem(ctx, item, to: target) {
            case .completed: return .done
            case .partial, .skipped: return .skipped
            case .cancelled: return .cancelled
            }
        case .move:
            return await MoveJob.moveItem(ctx, item, to: target, renameExcl: renameExcl)
        }
    }

    /// Trash the existing destination (never delete it), journal its Trash URL, record `.replaced`.
    static func trashExisting(_ ctx: JobContext, _ target: URL) async -> Trashed? {
        let trash = ctx.trash
        while true {
            let result: Result<(URL, FileIdentity?), FileOpError> = (try? await ctx.onLane { _ in
                let id = FileIdentity.of(path: target.path)
                do { return .success((try trash.trash(target), id)) }
                catch let e as FileOpError { return .failure(e) }
                catch { return .failure(FileOpError(kind: FileOpErrorKind(error: error, isLockedItem: false), url: target)) }
            }) ?? .failure(FileOpError(kind: .other(code: EIO, message: String(cString: strerror(EIO))), url: target))
            switch result {
            case .success(let (trashURL, id)):
                let entry = JournalEntry.trashedDestination(job: ctx.id, original: target, trashURL: trashURL)
                try? await ctx.journalRecord(entry)
                if let id { ctx.record(.replaced(original: target, trashURL: trashURL, id)) }
                return Trashed(original: target, trashURL: trashURL, entry: entry)
            case .failure(let e):
                switch await ctx.askError(e) {
                case .retry, .continueAnyway: continue
                case .unlockAndContinue:
                    _ = try? await ctx.onLane { _ in PosixFS.clearImmutable(target.path, recursive: false) }
                    continue
                case .cancel: ctx.cancelJob(); return nil
                case .skip, .skipAll: return nil
                }
            }
        }
    }

    /// Put the trashed destination back (its original path is free because the new item did not land).
    static func restore(_ ctx: JobContext, _ trashed: Trashed) async {
        _ = try? await ctx.onLane { _ in
            if !PosixFS.exists(trashed.original.path) { _ = PosixFS.rename(trashed.trashURL.path, trashed.original.path) }
        }
        ctx.removeLastAction { if case .replaced(_, let t, _) = $0 { t == trashed.trashURL } else { false } }
        await ctx.journalClear(trashed.entry)
    }

    static func replace(_ ctx: JobContext, item: PlanItem, target: URL, operation: Operation, renameExcl: Bool) async -> StepResult {
        let src = item.source
        if operation == .move && item.sameVolume {
            // Nothing is copied, so the source can't be lost: trash existing, then the rename primitive.
            guard let trashed = await trashExisting(ctx, target) else {
                if !ctx.control.isCancelled { ctx.skip(src, reason: nil) }
                return ctx.control.isCancelled ? .cancelled : .skipped
            }
            ctx.fault(.afterTrashDestination)
            let r = await MoveJob.moveItem(ctx, item, to: target, renameExcl: renameExcl)
            if r == .done { await ctx.journalClear(trashed.entry) } else { await restore(ctx, trashed) }
            return r
        }
        // Copy or cross-volume move: partial → verify → trash existing → rename → (move) delete source.
        let partial = target.deletingLastPathComponent().appending(path: PartialName.make(for: target.lastPathComponent, job: ctx.id))
        let entry = JournalEntry.partial(job: ctx.id, url: partial)
        try? await ctx.journalRecord(entry)
        let copied = await TreeCopier.copy(ctx, item, to: partial)
        guard copied == .completed else {
            await MoveJob.removePartial(ctx, partial, entry)
            return copied == .cancelled ? .cancelled : .skipped
        }
        ctx.fault(.afterPartialCopy)
        let verified = (try? await ctx.onLane { _ -> Bool in
            let a = PosixFS.treeStats(src.path), b = PosixFS.treeStats(partial.path)
            return a.items == b.items && a.bytes == b.bytes
        }) ?? false
        guard verified else {
            await MoveJob.removePartial(ctx, partial, entry)
            switch await ctx.askError(FileOpError(kind: .changedDuringMove, url: src, destination: target)) {
            case .retry, .continueAnyway, .unlockAndContinue:
                return await replace(ctx, item: item, target: target, operation: operation, renameExcl: renameExcl)
            case .skip, .skipAll: ctx.skip(src, reason: .changedDuringMove); return .skipped
            case .cancel: ctx.cancelJob(); return .cancelled
            }
        }
        guard let trashed = await trashExisting(ctx, target) else {
            await MoveJob.removePartial(ctx, partial, entry)
            if !ctx.control.isCancelled { ctx.skip(src, reason: nil) }
            return ctx.control.isCancelled ? .cancelled : .skipped
        }
        ctx.fault(.afterTrashDestination)
        ctx.fault(.beforePartialRename)
        let renamed = (try? await ctx.onLane { _ in RenamePrimitive.rename(partial.path, target.path, renameExcl: true) }) ?? .failed(EIO)
        guard renamed == .renamed else {
            await restore(ctx, trashed)
            await MoveJob.removePartial(ctx, partial, entry)
            let code: Int32 = switch renamed { case .exists: EEXIST; case .crossDevice: EXDEV; case .failed(let e): e; case .renamed: 0 }
            switch await ctx.resolveFailure(code, url: src, destination: target) {
            case .retry: return await replace(ctx, item: item, target: target, operation: operation, renameExcl: renameExcl)
            case .skipped: return .skipped
            case .cancelled: return .cancelled
            }
        }
        await ctx.journalClear(entry)
        await ctx.journalClear(trashed.entry)
        switch operation {
        case .copy:
            if let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil { ctx.record(.created(target, id)) }
            ctx.landed(target)
        case .move:
            ctx.fault(.beforeSourceDelete)
            await MoveJob.finishMove(ctx, source: src, target: target)
        }
        return .done
    }

    /// Folder onto folder: children that don't exist land with the normal rules; conflicting children
    /// follow the dialog (recursively). For a move the source folder is removed only once empty.
    static func merge(_ ctx: JobContext, item: PlanItem, into target: URL, operation: Operation, renameExcl: Bool) async -> StepResult {
        let src = item.source
        let force = ctx.tuning.forceCrossVolume
        let children = (try? await ctx.onLane { _ in
            ((try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? []).sorted()
        }) ?? []
        var result: StepResult = .done
        for child in children {
            guard await ctx.checkpoint() else { return .cancelled }
            let childSrc = src.appending(path: child)
            let childDst = target.appending(path: child)
            let planned = try? await ctx.onLane { lane -> (PlanItem?, Bool) in
                let p = Planner.plan(sources: [childSrc], destination: target, mode: operation == .copy ? .copy : .move,
                                     forceCrossVolume: force, lane: lane)
                return (p.items.first, PosixFS.exists(childDst.path))
            }
            guard case let (childItem?, conflicting)? = planned else { continue }
            let r: StepResult
            if conflicting {
                guard let action = await decide(ctx, source: childSrc, target: childDst, pending: [childSrc], destinationDir: target) else {
                    return .cancelled
                }
                r = await execute(ctx, action: action, item: childItem, destinationDir: target, name: child,
                                  operation: operation, renameExcl: renameExcl)
            } else {
                r = await transfer(ctx, childItem, to: childDst, operation: operation, renameExcl: renameExcl)
            }
            if r == .cancelled { return .cancelled }
            if r == .skipped { result = .skipped }
        }
        if operation == .move {
            let removed = (try? await ctx.onLane { _ in rmdir(src.path) == 0 }) ?? false
            if removed { ctx.noteRemoved(src) }
        }
        return result
    }
}
```

`execute(... .skip ...)` records the skipped child with `reason: nil`, the same as a top-level skip.

- [ ] **Step 5: Route Replace/Merge from CopyJob and MoveJob**

In `CopyJob.run`, replace the `case .replace, .merge:` block (the three lines that start with the `// P1-22 replaces` comment) with:

```swift
                case .replace, .merge:
                    let r = await ConflictExecutor.execute(ctx, action: action, item: item, destinationDir: destination, name: name,
                                                           operation: .copy, renameExcl: plan.capabilities.renameExcl)
                    if r == .cancelled { return }
                    continue
```

In `MoveJob.run`, replace its `case .replace, .merge:` block the same way, using `operation: .move`.

- [ ] **Step 6: Run the tests and see them pass**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, no warnings.
Run: `swift test --filter 'CoreTests.(ConflictTests|CrashRecoveryTests|CopyTests|MoveTests)' 2>&1 | tail -5`
Expected: `Executed 42 tests, with 0 failures` (12 conflict + 5 crash + 15 copy + 10 move; image tests skipped without hdiutil).

- [ ] **Step 7: Commit**

```bash
git add Sources/Core/FileOps Tests/CoreTests/FileOps
git commit -m "feat: conflict resolution with crash-safe replace, keep both, merge and apply-to-all"
```

---
### Task P1-23: Trash, delete permanently, alias, symlink, setAttributes, chmodRecursive; §6.5 error table on images

Spec: §6.3 Trash (`FileManager.trashItem(at:resultingItemURL:)`, URL stored for undo; volumes without a trash fall back to "Delete permanently?" with confirmation), Delete permanently (`removefile(3)` with progress; the UI confirmed before enqueue), Alias (bookmark file: `URL.bookmarkData(options: .suitableForBookmarkFile)` + `writeBookmarkData`), Symlink (`symlink(2)`, relative path on the same volume), §5.8 Properties edits as `setAttributes` (locked/`uchg`, hidden/`UF_HIDDEN`, hide extension, permissions, quarantine removal; previous values recorded), "Apply to enclosed items" as `chmodRecursive`, §4.2 materialization policy for the plan-phase enumeration of delete and chmodRecursive, §6.5 error table and "an error affects only its own item", §9 (`EROFS` image, locked files, `ENOSPC` on a small image).

**Files:**
- Create: `Sources/Core/FileOps/TrashDeleteJobs.swift`, `Sources/Core/FileOps/LinkJobs.swift`, `Sources/Core/FileOps/AttributeJobs.swift`
- Modify: `Sources/Core/FileOps/JobRunner.swift` (dispatch `.trash`, `.delete`, `.alias`, `.symlink`, `.chmodRecursive`, `.setAttributes`; add `JobContext.askNoTrash`)
- Test: `Tests/CoreTests/FileOps/TrashDeleteTests.swift`, `Tests/CoreTests/FileOps/ErrorTableTests.swift`

**Interfaces:**
- Consumes: `ctx.plan(sources:destination:mode:)` with `.shallow` and `.enumerate(noMaterialization: true)`, `ctx.trash`, `ctx.resolveFailure`, `ctx.askError`, `NameGenerator.keepBoth`, `VolumeIdentity.isSameVolume`, `PosixFS`.
- Produces (internal; `AttributeJobs.apply(_:to:)` is reused by undo in P1-24):

```swift
extension JobContext { func askNoTrash(_ urls: [URL]) async -> Bool }
enum TrashDeleteJobs {
    static func trash(_ ctx: JobContext, _ urls: [URL]) async
    static func delete(_ ctx: JobContext, _ urls: [URL]) async
    static func deleteItem(_ ctx: JobContext, _ url: URL) async -> StepResult
    static func removeWithProgress(_ path: String, unlock: Bool, lane: LaneContext, control: JobControl, onItem: @escaping () -> Void) -> Int32
}
enum LinkJobs {
    static func alias(_ ctx: JobContext, sources: [URL], destination: URL) async
    static func symlink(_ ctx: JobContext, sources: [URL], destination: URL) async
    static func relativePath(from directory: URL, to target: URL) -> String     // lane only (resolves symlinks)
}
enum AttributeJobs {
    static let quarantineName: String                                          // "com.apple.quarantine"
    static func snapshot(_ url: URL, for edit: AttributeEdit) -> AttributeSnapshot?   // lane only
    static func newValues(_ edit: AttributeEdit) -> AttributeSnapshot
    static func apply(_ edit: AttributeEdit, to url: URL) -> Int32                    // lane only; 0 or errno
    static func apply(_ snapshot: AttributeSnapshot, to url: URL) -> Int32            // lane only; undo
    static func setAttributes(_ ctx: JobContext, _ urls: [URL], _ edit: AttributeEdit) async
    static func chmodRecursive(_ ctx: JobContext, _ url: URL, _ change: ModeChange) async
}
```

Trash plans with `.shallow` (existence and identity only): trashing is a rename, so enumerating a large folder first would only slow it down. Delete and chmodRecursive enumerate under `withNoMaterialization`. See Contract notes 5.

- [ ] **Step 1: Write the failing trash/delete/link/attribute tests**

`Tests/CoreTests/FileOps/TrashDeleteTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

final class TrashDeleteTests: FileOpsTestCase {
    func testTrashRecordsResultingURLAndPostsRemoval() async throws {
        let a = try file("d/a.txt", "A")
        let inode = lst(a).st_ino
        let (queue, _) = makeQueue()
        let o = try await run(.trash([a]), on: queue)
        XCTAssertFalse(exists(a))
        guard case .trashed(let original, let trashURL, let id)? = o.record.actions.first else { return XCTFail("\(o.record)") }
        XCTAssertEqual(original, a); XCTAssertEqual(id.inode, inode)
        XCTAssertEqual(text(trashURL), "A")
        XCTAssertEqual(o.localChanges.first?.removed, ["a.txt"])
        XCTAssertTrue(o.record.isUndoable)
    }

    func testNoTrashFallsBackToConfirmedPermanentDelete() async throws {
        let a = try file("nt/a.txt")
        let scripted = ScriptedInteraction(noTrash: [true])
        let (queue, _) = makeQueue(interaction: scripted, trash: SandboxTrash(directory: trashDir, refusingPathsUnder: [url("nt")]))
        let o = try await run(.trash([a]), on: queue)
        XCTAssertEqual(scripted.askedNoTrash(), [[a]])
        XCTAssertFalse(exists(a))
        XCTAssertEqual(o.record.actions, [.deleted(a)])
        XCTAssertFalse(o.record.isUndoable)
    }

    func testNoTrashDeclinedKeepsItem() async throws {
        let a = try file("nt/a.txt")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(noTrash: [false]),
                                   trash: SandboxTrash(directory: trashDir, refusingPathsUnder: [url("nt")]))
        let o = try await run(.trash([a]), on: queue)
        XCTAssertTrue(exists(a))
        XCTAssertEqual(o.skipped, [SkippedItem(url: a, reason: .noTrash)])
    }

    func testTrashLockedItemOffersUnlockAndContinue() async throws {
        let a = try file("a.txt")
        XCTAssertEqual(lchflags(a.path, UInt32(UF_IMMUTABLE)), 0)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.trash([a]), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.locked])
        XCTAssertFalse(exists(a))
    }

    func testDeletePermanentlyRemovesTreeWithProgress() async throws {
        for i in 0..<50 { try file("T/f\(i)") }
        try file("T/sub/g")
        let (queue, _) = makeQueue()
        let consumer = Task { () -> JobSnapshot? in
            for await e in queue.events { if case .finished(let s, _) = e { return s } }
            return nil
        }
        let o = try await run(.delete([url("T")]), on: queue)
        let final = await consumer.value
        XCTAssertFalse(exists(url("T")))
        XCTAssertEqual(o.record.actions, [.deleted(url("T"))])
        XCTAssertGreaterThanOrEqual(final?.progress.itemsDone ?? 0, 52)
        XCTAssertEqual(final?.progress.itemsTotal, 53)
    }

    func testDeleteLockedTreeUnlockAndContinue() async throws {
        try file("T/f")
        XCTAssertEqual(lchflags(url("T/f").path, UInt32(UF_IMMUTABLE)), 0)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.delete([url("T")]), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.locked])
        XCTAssertFalse(exists(url("T")))
    }

    func testAliasResolvesToOriginal() async throws {
        let a = try file("src/a.txt", "A")
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let o = try await run(.alias(sources: [a], destination: d), on: queue)
        let alias = url("d/a.txt alias")
        XCTAssertEqual(o.created, [alias])
        let resolved = try URL(resolvingAliasFileAt: alias)
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path, a.resolvingSymlinksInPath().path)
        let o2 = try await run(.alias(sources: [a], destination: d), on: queue)
        XCTAssertEqual(o2.created.map(\.lastPathComponent), ["a.txt alias 2"])
    }

    func testSymlinkIsRelativeOnSameVolume() async throws {
        let a = try file("src/a.txt", "A")
        let d = try dir("d")
        let (queue, _) = makeQueue()
        _ = try await run(.symlink(sources: [a], destination: d), on: queue)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url("d/a.txt").path), "../src/a.txt")
        XCTAssertEqual(text(url("d/a.txt")), "A")
        _ = try await run(.symlink(sources: [a], destination: url("src")), on: queue)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url("src/a.txt symlink").path), "a.txt")
    }

    func testSymlinkIsAbsoluteAcrossVolumes() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let a = try file("a.txt", "A")
        let (queue, _) = makeQueue()
        _ = try await run(.symlink(sources: [a], destination: mnt), on: queue)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: mnt.appending(path: "a.txt").path), a.path)
    }

    func testSetAttributesRecordsOldAndNewValues() async throws {
        let a = try file("a.txt")
        let quarantine = Array("0081;5f000000;Safari;".utf8)
        XCTAssertEqual(setxattr(a.path, AttributeJobs.quarantineName, quarantine, quarantine.count, 0, XATTR_NOFOLLOW), 0)
        let (queue, _) = makeQueue()
        let locked = try await run(.setAttributes([a], .locked(true)), on: queue)
        XCTAssertNotEqual(lst(a).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(locked.record.actions, [.attributesChanged(a, old: AttributeSnapshot(locked: false), new: AttributeSnapshot(locked: true))])
        _ = try await run(.setAttributes([a], .locked(false)), on: queue)
        let hidden = try await run(.setAttributes([a], .hidden(true)), on: queue)
        XCTAssertNotEqual(lst(a).st_flags & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(hidden.localChanges.first?.modified, ["a.txt"])
        _ = try await run(.setAttributes([a], .extensionHidden(true)), on: queue)
        XCTAssertEqual(try URL(filePath: a.path).resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension, true)
        let perms = try await run(.setAttributes([a], .permissions(0o600)), on: queue)
        XCTAssertEqual(lst(a).st_mode & 0o7777, 0o600)
        XCTAssertEqual(perms.record.actions, [.attributesChanged(a, old: AttributeSnapshot(mode: 0o644), new: AttributeSnapshot(mode: 0o600))])
        let q = try await run(.setAttributes([a], .removeQuarantine), on: queue)
        XCTAssertEqual(getxattr(a.path, AttributeJobs.quarantineName, nil, 0, 0, XATTR_NOFOLLOW), -1)
        XCTAssertEqual(q.record.actions, [.attributesChanged(a, old: AttributeSnapshot(quarantine: Data(quarantine)), new: AttributeSnapshot(quarantine: Data()))])
    }

    func testChmodRecursiveAppliesChildrenFirstAndRecords() async throws {
        try file("T/sub/f"); try file("T/g")
        let (queue, _) = makeQueue()
        let o = try await run(.chmodRecursive(url("T"), ModeChange(mode: 0o700)), on: queue)
        for rel in ["T", "T/sub", "T/sub/f", "T/g"] { XCTAssertEqual(lst(url(rel)).st_mode & 0o777, 0o700, rel) }
        XCTAssertEqual(o.record.actions.count, 4)
        guard case .modeChanged(let first, _, _)? = o.record.actions.first,
              case .modeChanged(let last, let old, let new)? = o.record.actions.last else { return XCTFail() }
        XCTAssertNotEqual(first, url("T"), "children first")
        XCTAssertEqual(last, url("T")); XCTAssertEqual(old, 0o755); XCTAssertEqual(new, 0o700)
    }

    func testChmodRecursiveFilesOnly() async throws {
        try file("T/f")
        let (queue, _) = makeQueue()
        _ = try await run(.chmodRecursive(url("T"), ModeChange(mode: 0o600, applyToDirectories: false, applyToFiles: true)), on: queue)
        XCTAssertEqual(lst(url("T")).st_mode & 0o777, 0o755)
        XCTAssertEqual(lst(url("T/f")).st_mode & 0o777, 0o600)
    }
}
```

The `0o644`/`0o755` expectations assume the default umask 022 of the test process. If `umask` reports otherwise, the executor sets the modes explicitly with `chmod` in the test before running the job.

- [ ] **Step 2: Write the failing error-table tests**

`Tests/CoreTests/FileOps/ErrorTableTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

/// §6.5 rows exercised for real (images created inside the sandbox).
final class ErrorTableTests: FileOpsTestCase {
    func testCopyOntoReadOnlyImageReportsReadOnlyVolume() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16, readOnly: true)
        let a = try file("a.txt", "A")
        let scripted = ScriptedInteraction(errors: [.cancel], space: [true])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [a], destination: mnt), on: queue)
        XCTAssertEqual(scripted.askedErrors().first?.kind, .readOnlyVolume)
        XCTAssertEqual(FileOpErrorKind.readOnlyVolume.allowedResolutions, [.cancel])
        XCTAssertTrue(o.wasCancelled)
    }

    func testLockedSourceMoveOffersUnlockAndContinue() async throws {
        let a = try file("src/a.txt", "A")
        XCTAssertEqual(lchflags(a.path, UInt32(UF_IMMUTABLE)), 0)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.locked])
        XCTAssertEqual(FileOpErrorKind.locked.allowedResolutions, [.unlockAndContinue, .skip, .cancel])
        XCTAssertEqual(text(url("d/a.txt")), "A")
    }

    func testENOSPCOnSmallImageLeavesNoPartialFile() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 8)
        let big = try bigFile("big", bytes: 24 << 20)
        let scripted = ScriptedInteraction(errors: [.cancel], space: [true])     // Continue Anyway, then Cancel
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [big], destination: mnt), on: queue)
        XCTAssertEqual(scripted.askedSpace().count, 1)
        guard case .noSpace? = scripted.askedErrors().first?.kind else { return XCTFail("\(scripted.askedErrors())") }
        XCTAssertEqual(scripted.askedErrors().first?.kind.allowedResolutions, [.retry, .cancel])
        XCTAssertFalse(names(mnt).contains("big"), "half-written file removed")
        XCTAssertTrue(o.wasCancelled)
    }

    func testDeepDestinationReportsNameTooLongAndSkipsOnlyThatItem() async throws {
        let deep = try dir([String(repeating: "x", count: 200), String(repeating: "y", count: 200),
                            String(repeating: "z", count: 200), String(repeating: "w", count: 200)].joined(separator: "/"))
        try file("T/short", "S")
        try file("T/" + String(repeating: "c", count: 200), "C")
        guard deep.path.utf8.count + 3 + 200 > Int(PATH_MAX) else { throw XCTSkip("sandbox path too short to exceed PATH_MAX") }
        let scripted = ScriptedInteraction(errors: [.skip])
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.copy(sources: [url("T")], destination: deep), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.nameTooLong])
        XCTAssertEqual(FileOpErrorKind.nameTooLong.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(names(deep.appending(path: "T")), ["short"])
        XCTAssertEqual(o.skipped.count, 1)
    }

    func testPermissionDeniedSkipAllAppliesToTheRest() async throws {
        let files = try ["a", "b", "c"].map { try file("src/\($0)") }
        let d = try dir("d")
        XCTAssertEqual(chmod(d.path, 0o555), 0)
        let scripted = ScriptedInteraction(errors: [.skipAll])
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.copy(sources: files, destination: d), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.permissionDenied], "asked once")
        XCTAssertEqual(o.skipped.count, 3)
        XCTAssertFalse(o.wasCancelled, "an error affects only its own item")
    }
}
```

`testDeepDestinationReportsNameTooLong…` creates its long directory chain through `Sandbox.createDirectory` (through `dir(_:)`), so it stays inside the sandbox.

- [ ] **Step 3: Run the tests and watch them fail**

Run: `swift test --filter 'CoreTests.(TrashDeleteTests|ErrorTableTests)' 2>&1 | tail -10`
Expected: trash/delete/alias/symlink/attribute tests fail (items skipped with `ENOTSUP`); the copy/move error-table tests that only need P1-20/21 may already pass.

- [ ] **Step 4: Add `askNoTrash` to `JobRunner.swift`**

Append to `Sources/Core/FileOps/JobRunner.swift`:

```swift
extension JobContext {
    /// "Delete permanently?" for items on volumes without a Trash.
    func askNoTrash(_ urls: [URL]) async -> Bool {
        let previous = snapshot().state
        setState(.waitingForUser)
        let answer = await interaction.confirmPermanentDeleteWithoutTrash(urls, job: snapshot())
        setState(previous)
        return answer
    }
}
```

- [ ] **Step 5: Implement `TrashDeleteJobs.swift`**

```swift
import Foundation
import Darwin
import MacxFS

final class RemoveProgressBox {
    let lane: LaneContext
    let control: JobControl
    let onItem: () -> Void
    init(lane: LaneContext, control: JobControl, onItem: @escaping () -> Void) { self.lane = lane; self.control = control; self.onItem = onItem }
}

enum TrashDeleteJobs {
    static func trash(_ ctx: JobContext, _ urls: [URL]) async {
        guard let plan = await ctx.plan(sources: urls, destination: nil, mode: .shallow) else { return }
        var noTrash: [URL] = []
        let trash = ctx.trash
        items: for item in plan.items {
            guard await ctx.checkpoint() else { break }
            let src = item.source
            while true {
                let result: Result<URL, FileOpError> = (try? await ctx.onLane { _ in
                    do { return .success(try trash.trash(src)) }
                    catch let e as FileOpError { return .failure(e) }
                    catch { return .failure(FileOpError(kind: FileOpErrorKind(error: error, isLockedItem: PosixFS.info(src.path)?.isLocked ?? false), url: src)) }
                }) ?? .failure(FileOpError(kind: .other(code: EIO, message: String(cString: strerror(EIO))), url: src))
                switch result {
                case .success(let trashURL):
                    ctx.record(.trashed(original: src, trashURL: trashURL, item.info.identity))
                    ctx.noteRemoved(src)
                    ctx.addProgress(items: 1, current: src.lastPathComponent)
                    continue items
                case .failure(let e) where e.kind == .noTrash:
                    noTrash.append(src)
                    continue items
                case .failure(let e):
                    switch await ctx.askError(e) {
                    case .retry, .continueAnyway: continue
                    case .unlockAndContinue:
                        _ = try? await ctx.onLane { _ in PosixFS.clearImmutable(src.path, recursive: false) }
                        continue
                    case .skip, .skipAll: ctx.skip(src, reason: e.kind); continue items
                    case .cancel: ctx.cancelJob(); return
                    }
                }
            }
        }
        guard !noTrash.isEmpty, !ctx.control.isCancelled else { return }
        if await ctx.askNoTrash(noTrash) {
            for u in noTrash {
                if await deleteItem(ctx, u) == .cancelled { return }
            }
        } else {
            for u in noTrash { ctx.skip(u, reason: .noTrash) }
        }
    }

    static func delete(_ ctx: JobContext, _ urls: [URL]) async {
        guard let plan = await ctx.plan(sources: urls, destination: nil, mode: .enumerate(noMaterialization: true)) else { return }
        for item in plan.items {
            guard await ctx.checkpoint() else { break }
            if await deleteItem(ctx, item.source) == .cancelled { return }
        }
    }

    /// removefile with a status callback per removed item; Retry after a locked error unlocks the tree.
    static func deleteItem(_ ctx: JobContext, _ url: URL) async -> StepResult {
        let control = ctx.control
        var unlock = false
        while true {
            let u = unlock
            let rc = (try? await ctx.onLane { lane in
                removeWithProgress(url.path, unlock: u, lane: lane, control: control) { ctx.addProgress(items: 1) }
            }) ?? EIO
            if rc == 0 {
                ctx.record(.deleted(url))
                ctx.noteRemoved(url)
                return .done
            }
            if control.isCancelled { return .cancelled }
            let hasLocked = rc == EPERM ? ((try? await ctx.onLane { _ -> Bool in
                var found = false
                PosixFS.walk(url.path) { p, _ in if PosixFS.info(p)?.isLocked == true { found = true }; return !found }
                return found
            }) ?? false) : false
            let kind = FileOpErrorKind(errno: rc, isLockedItem: hasLocked)
            switch await ctx.askError(FileOpError(kind: kind, url: url)) {
            case .retry, .continueAnyway: continue
            case .unlockAndContinue: unlock = true; continue
            case .skip, .skipAll: ctx.skip(url, reason: kind); return .skipped
            case .cancel: ctx.cancelJob(); return .cancelled
            }
        }
    }

    static func removeWithProgress(_ path: String, unlock: Bool, lane: LaneContext, control: JobControl, onItem: @escaping () -> Void) -> Int32 {
        assertOffMain()
        if unlock { PosixFS.clearImmutable(path) }
        guard let state = removefile_state_alloc() else { return ENOMEM }
        defer { removefile_state_free(state) }
        let box = RemoveProgressBox(lane: lane, control: control, onItem: onItem)
        return withExtendedLifetime(box) {
            let callback: removefile_callback_t = { _, _, ctx in
                guard let ctx else { return Int32(REMOVEFILE_PROCEED) }
                let box = Unmanaged<RemoveProgressBox>.fromOpaque(ctx).takeUnretainedValue()
                box.onItem()
                box.lane.heartbeat()
                return box.control.laneCheckpoint(box.lane) ? Int32(REMOVEFILE_PROCEED) : Int32(REMOVEFILE_STOP)
            }
            removefile_state_set(state, UInt32(REMOVEFILE_STATE_STATUS_CALLBACK), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            removefile_state_set(state, UInt32(REMOVEFILE_STATE_STATUS_CONTEXT), Unmanaged.passUnretained(box).toOpaque())
            return removefile(path, state, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 ? 0 : errno
        }
    }
}
```

- [ ] **Step 6: Implement `LinkJobs.swift`**

```swift
import Foundation
import Darwin
import MacxFS

enum LinkJobs {
    private enum Made: Sendable { case ok(URL, FileIdentity), failed(FileOpErrorKind) }

    static func alias(_ ctx: JobContext, sources: [URL], destination: URL) async {
        await make(ctx, sources: sources, destination: destination) { src, dir in
            let name = freeName("\(src.lastPathComponent) alias", in: dir, isDirectory: false)
            let aliasURL = dir.appending(path: name)
            let data = try src.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: aliasURL)
            return aliasURL
        }
    }

    static func symlink(_ ctx: JobContext, sources: [URL], destination: URL) async {
        await make(ctx, sources: sources, destination: destination) { src, dir in
            let sameFolder = src.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path
            let name = freeName(sameFolder ? "\(src.lastPathComponent) symlink" : src.lastPathComponent, in: dir, isDirectory: false)
            let link = dir.appending(path: name)
            let target = VolumeIdentity.isSameVolume(src, destinationDirectory: dir) ? relativePath(from: dir, to: src) : src.path
            guard Darwin.symlink(target, link.path) == 0 else { throw FileOpError(kind: FileOpErrorKind(errno: errno, isLockedItem: false), url: link) }
            return link
        }
    }

    /// Lane only: `../src/a.txt`-style path from `directory` to `target` (symlinks in the parents resolved).
    static func relativePath(from directory: URL, to target: URL) -> String {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var i = 0
        while i < base.count, i < parent.count, base[i] == parent[i] { i += 1 }
        let ups = Array(repeating: "..", count: base.count - i)
        return (ups + Array(parent[i...]) + [target.lastPathComponent]).joined(separator: "/")
    }

    private static func freeName(_ name: String, in dir: URL, isDirectory: Bool) -> String {
        PosixFS.exists(dir.appending(path: name).path)
            ? NameGenerator.keepBoth(name, isDirectory: isDirectory) { PosixFS.exists(dir.appending(path: $0).path) }
            : name
    }

    private static func make(_ ctx: JobContext, sources: [URL], destination: URL,
                             _ body: @escaping @Sendable (URL, URL) throws -> URL) async {
        ctx.setTotals(items: sources.count, bytes: 0)
        ctx.setState(.running)
        items: for src in sources {
            guard await ctx.checkpoint() else { break }
            while true {
                let made = (try? await ctx.onLane { _ -> Made in
                    guard PosixFS.exists(src.path) else { return .failed(.sourceGone) }
                    do {
                        let u = try body(src, destination)
                        guard let id = FileIdentity.of(path: u.path) else { return .failed(.sourceGone) }
                        return .ok(u, id)
                    } catch { return .failed(FileOpErrorKind(error: error, isLockedItem: PosixFS.info(destination.path)?.isLocked ?? false)) }
                }) ?? .failed(.other(code: EIO, message: String(cString: strerror(EIO))))
                switch made {
                case .ok(let u, let id):
                    ctx.record(.created(u, id))
                    ctx.landed(u)
                    ctx.addProgress(items: 1, current: u.lastPathComponent)
                    continue items
                case .failed(let kind):
                    switch await ctx.askError(FileOpError(kind: kind, url: src, destination: destination)) {
                    case .retry, .continueAnyway, .unlockAndContinue: continue
                    case .skip, .skipAll: ctx.skip(src, reason: kind); continue items
                    case .cancel: ctx.cancelJob(); return
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 7: Implement `AttributeJobs.swift`**

```swift
import Foundation
import Darwin
import MacxFS

enum AttributeJobs {
    static let quarantineName = "com.apple.quarantine"

    static func readXattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buf, size, 0, XATTR_NOFOLLOW)
        return read >= 0 ? Data(buf.prefix(read)) : nil
    }

    /// Lane only. Current values of exactly the fields `edit` touches (nil fields = untouched).
    static func snapshot(_ url: URL, for edit: AttributeEdit) -> AttributeSnapshot? {
        assertOffMain()
        guard let info = PosixFS.info(url.path) else { return nil }
        switch edit {
        case .locked: return AttributeSnapshot(locked: info.flags & UInt32(UF_IMMUTABLE) != 0)
        case .hidden: return AttributeSnapshot(hidden: info.flags & UInt32(UF_HIDDEN) != 0)
        case .extensionHidden:
            let v = try? URL(filePath: url.path).resourceValues(forKeys: [.hasHiddenExtensionKey])
            return AttributeSnapshot(extensionHidden: v?.hasHiddenExtension ?? false)
        case .permissions: return AttributeSnapshot(mode: info.mode)
        case .removeQuarantine: return AttributeSnapshot(quarantine: readXattr(url.path, quarantineName) ?? Data())
        }
    }

    /// Values after applying `edit`. Quarantine `Data()` means "absent".
    static func newValues(_ edit: AttributeEdit) -> AttributeSnapshot {
        switch edit {
        case .locked(let v): AttributeSnapshot(locked: v)
        case .hidden(let v): AttributeSnapshot(hidden: v)
        case .extensionHidden(let v): AttributeSnapshot(extensionHidden: v)
        case .permissions(let m): AttributeSnapshot(mode: m)
        case .removeQuarantine: AttributeSnapshot(quarantine: Data())
        }
    }

    static func apply(_ edit: AttributeEdit, to url: URL) -> Int32 { apply(newValues(edit), to: url) }

    /// Lane only. Applies every non-nil field; unlocks first and locks last so other edits can land.
    static func apply(_ s: AttributeSnapshot, to url: URL) -> Int32 {
        assertOffMain()
        let path = url.path
        func setFlag(_ flag: UInt32, _ on: Bool) -> Int32 {
            guard let i = PosixFS.info(path) else { return ENOENT }
            let flags = on ? i.flags | flag : i.flags & ~flag
            return flags == i.flags || lchflags(path, flags) == 0 ? 0 : errno
        }
        if s.locked == false, case let rc = setFlag(UInt32(UF_IMMUTABLE), false), rc != 0 { return rc }
        if let h = s.hidden, case let rc = setFlag(UInt32(UF_HIDDEN), h), rc != 0 { return rc }
        if let m = s.mode, chmod(path, mode_t(m & 0o7777)) != 0 { return errno }
        if let e = s.extensionHidden {
            var rv = URLResourceValues(); rv.hasHiddenExtension = e
            var u = URL(filePath: path)
            do { try u.setResourceValues(rv) } catch { return EPERM }
        }
        if let q = s.quarantine {
            if q.isEmpty {
                if removexattr(path, quarantineName, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { return errno }
            } else {
                let rc = q.withUnsafeBytes { setxattr(path, quarantineName, $0.baseAddress, q.count, 0, XATTR_NOFOLLOW) }
                if rc != 0 { return errno }
            }
        }
        if s.locked == true, case let rc = setFlag(UInt32(UF_IMMUTABLE), true), rc != 0 { return rc }
        return 0
    }

    static func setAttributes(_ ctx: JobContext, _ urls: [URL], _ edit: AttributeEdit) async {
        ctx.setTotals(items: urls.count, bytes: 0)
        ctx.setState(.running)
        let new = newValues(edit)
        items: for url in urls {
            guard await ctx.checkpoint() else { break }
            while true {
                let r = (try? await ctx.onLane { _ -> (Int32, AttributeSnapshot?) in
                    guard let old = snapshot(url, for: edit) else { return (ENOENT, nil) }
                    return (apply(edit, to: url), old)
                }) ?? (EIO, nil)
                if r.0 == 0, let old = r.1 {
                    if old != new { ctx.record(.attributesChanged(url, old: old, new: new)) }
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

    /// Children first (reverse pre-order), so a folder never loses x before its contents are done.
    static func chmodRecursive(_ ctx: JobContext, _ url: URL, _ change: ModeChange) async {
        guard let plan = await ctx.plan(sources: [url], destination: nil, mode: .enumerate(noMaterialization: true)),
              let item = plan.items.first else { return }
        struct Change: Sendable { var url: URL; var old: UInt16; var new: UInt16 }
        let changes: [Change] = item.entries.reversed().compactMap { e in
            guard e.type != .symlink, e.type != .other else { return nil }
            if e.type == .directory && !change.applyToDirectories { return nil }
            if e.type == .file && !change.applyToFiles { return nil }
            let new = (e.mode & ~0o777) | (change.mode & 0o777)
            guard new != e.mode else { return nil }
            return Change(url: e.relativePath.isEmpty ? url : url.appending(path: e.relativePath), old: e.mode, new: new)
        }
        let control = ctx.control
        // One lane call for the whole batch; failures come back for per-item questions.
        let failures = (try? await ctx.onLane { lane -> [Int: Int32] in
            var failed: [Int: Int32] = [:]
            for (i, c) in changes.enumerated() {
                if i % 256 == 0 { lane.heartbeat(); if !control.laneCheckpoint(lane) { break } }
                if chmod(c.url.path, mode_t(c.new)) != 0 { failed[i] = errno }
            }
            return failed
        }) ?? [:]
        for (i, c) in changes.enumerated() {
            if var code = failures[i] {
                retry: while true {
                    switch await ctx.resolveFailure(code, url: c.url) {
                    case .retry:
                        code = (try? await ctx.onLane { _ in chmod(c.url.path, mode_t(c.new)) == 0 ? 0 : errno }) ?? EIO
                        if code == 0 { break retry }
                    case .skipped: break retry
                    case .cancelled: return
                    }
                }
                if code != 0 { continue }
            }
            ctx.record(.modeChanged(c.url, old: c.old, new: c.new))
            ctx.addProgress(items: 1)
        }
        ctx.noteModified(url)
    }
}
```

`if s.locked == false, case let rc = …, rc != 0` binds the result inside the condition list; if the executor's compiler rejects `case let` there, they use a plain `let rc = …` followed by `if rc != 0 { return rc }` (same behavior).

- [ ] **Step 8: Dispatch the six kinds in `JobRunner.run`**

Insert above `default:`:

```swift
        case .trash(let urls):
            await TrashDeleteJobs.trash(ctx, urls)
        case .delete(let urls):
            await TrashDeleteJobs.delete(ctx, urls)
        case .alias(let sources, let destination):
            await LinkJobs.alias(ctx, sources: sources, destination: destination)
        case .symlink(let sources, let destination):
            await LinkJobs.symlink(ctx, sources: sources, destination: destination)
        case .chmodRecursive(let url, let change):
            await AttributeJobs.chmodRecursive(ctx, url, change)
        case .setAttributes(let urls, let edit):
            await AttributeJobs.setAttributes(ctx, urls, edit)
```

- [ ] **Step 9: Run the tests and see them pass**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, no warnings.
Run: `swift test --filter 'CoreTests.(TrashDeleteTests|ErrorTableTests)' 2>&1 | tail -5`
Expected: `Executed 17 tests, with 0 failures` (3 image tests skipped without hdiutil).

- [ ] **Step 10: Commit**

```bash
git add Sources/Core/FileOps Tests/CoreTests/FileOps
git commit -m "feat: trash with no-trash fallback, permanent delete, alias, symlink, attribute and permission jobs"
```

---
### Task P1-24: UndoPlanner + FileOpUndoStack (inverse per §6.6 row, identity checks, occupied paths, partial jobs, redo, field-editor managers)

Spec: §6.6 (one app-wide `UndoManager` on the main actor; one entry per completed job, also partly completed ones; the inverse table row by row; identity check before acting, items that have gone or changed are skipped and listed; an occupied original path goes through the conflict dialog; undo runs as a job with progress and conflict handling; permanent delete can't be undone; session-only history; per-edit field-editor managers), §6.3 (Trash keeps `resultingItemURL`; Replace trashes, never deletes), §6.1 (pause/cancel between items), §9 ("undo for each job kind, including undo after the items were changed externally"). Slice Review Focus 5.

**Files:**
- Create: `Sources/Core/FileOps/UndoPlanner.swift`, `Sources/Core/FileOps/FileOpUndoStack.swift`
- Modify: `Sources/Core/FileOps/JobRunner.swift` (final exhaustive dispatch incl. `.undo`/`.redo`, removes the `default:` branch; add `JobContext.setItemsDone`, `JobContext.noteAdded`)
- Modify: `Sources/Core/FileOps/TrashDeleteJobs.swift` (extract `trashOne`), `Sources/Core/FileOps/CreateOps.swift` (extract `performRename`)
- Modify: `Tests/CoreTests/FileOps/FileOpsTestSupport.swift` (add the `Sendable` `FileOpsWorld` view used by `@MainActor` test classes)
- Test: `Tests/CoreTests/FileOps/UndoTests.swift` (classes `UndoTests` and `UndoStackTests`)

**Interfaces:**
- Consumes: `JobContext` (P1-18: `onLane`, `attempt`, `askError`, `record`, `skip`, `landed`, `noteRemoved`, `noteModified`, `checkpoint`, `cancelJob`, `setTotals`, `journalClear`, `tuning`, `control`), `ctx.resolveFailure` (P1-19), `ctx.askNoTrash` (P1-23), `Planner.plan` (P1-18), `MoveJob.moveItem` (P1-21), `ConflictExecutor.decide/trashExisting/restore` (P1-20/P1-22), `NameGenerator.keepBoth` (P1-19), `TrashDeleteJobs.deleteItem` (P1-23), `AttributeJobs.snapshot/apply` (P1-23), `PosixFS`, `FileOpQueue.enqueue/outcome(of:)`.
- Produces (contract §3.13, exact):

```swift
@MainActor
public final class FileOpUndoStack {
    public init(queue: FileOpQueue)
    public let undoManager: UndoManager            // returned by every window's windowWillReturnUndoManager
    /// Registers one entry per completed undoable job (also partly completed ones).
    public func register(_ outcome: JobOutcome, actionName: String)
    /// Per-edit manager for field editors; discard when editing ends.
    public func makeFieldEditorUndoManager() -> UndoManager
    public var canUndo: Bool { get }
    public var canRedo: Bool { get }
}
```

- Produces (internal):

```swift
enum UndoStep: Sendable, Equatable {
    case trash(URL, FileIdentity)                                   // .created by copy/duplicate/new/cross-volume move
    case remove(URL, FileIdentity)                                  // .created by alias/symlink (§6.6 "remove")
    case removeDirectoryIfEmpty(URL, FileIdentity)                  // .createdDirectory
    case moveBack(current: URL, original: URL, FileIdentity)        // .moved, .trashed, .replaced
    case renameBack(current: URL, original: URL, FileIdentity)      // .renamed
    case restoreMode(URL, expected: UInt16, restore: UInt16)        // .modeChanged
    case restoreAttributes(URL, expected: AttributeSnapshot, restore: AttributeSnapshot)   // .attributesChanged
    var isRestoreMode: Bool { get }
}
enum UndoPlanner {
    enum Presence: Sendable, Equatable { case same, gone, changed }
    struct MadeDirectory: Sendable { var url: URL; var identity: FileIdentity }
    static func steps(for record: JobRecord) -> [UndoStep]?          // pure; reverse order; nil = not undoable
    static func run(_ ctx: JobContext, _ record: JobRecord) async    // body of .undo and .redo jobs
    static func presence(_ url: URL, _ id: FileIdentity) -> Presence // lane only
    static func makeMissingDirectories(_ directory: URL) -> (code: Int32, made: [MadeDirectory])   // lane only
    static func currentValues(_ url: URL, like template: AttributeSnapshot) -> AttributeSnapshot?  // lane only
}
extension JobContext { func setItemsDone(_ n: Int); func noteAdded(_ url: URL) }
extension TrashDeleteJobs { enum TrashOne { case done, noTrash, skipped, cancelled }
    static func trashOne(_ ctx: JobContext, _ src: URL, identity: FileIdentity) async -> TrashOne }
extension CreateOps { @discardableResult static func performRename(_ ctx: JobContext, _ url: URL, to newName: String) async -> StepResult }
struct FileOpsWorld: Sendable   // tests only (see Step 1)
```

**Design (what the code below implements):**
- An undo or redo is a job (`JobKind.undo(record)` / `.redo(record)`, `registersUndo: false`) whose body is `UndoPlanner.run`. It turns the record into `UndoStep`s, last action first, and executes them with the same helpers the forward jobs use (rename primitive, cross-volume move, trash, conflict question), so it has progress, pause/cancel, error dialogs and its own `JobRecord`.
- Redo is the inverse of the **undo job's** record, not a re-run of the original request: redo of "copy" moves the copy back out of the Trash instead of copying again, and every inverse is checked the same way.
- Every step first checks that the item is still at the recorded path with the recorded `FileIdentity` (`lstat` device + inode). A gone item is skipped with `.sourceGone`, an item with another identity (an editor's atomic save, a replacement) with `.changedDuringMove` (Contract notes 11). Mode and attribute steps compare the current value with the recorded new value instead.
- Undo never overwrites. If the original path holds a different item, the step asks `ConflictExecutor.decide` (so "do this for all" and Compare work): Skip (the default of `ScriptedInteraction`) leaves both, Keep Both lands under `x 2.ext`, Replace trashes the occupant (recorded `.replaced`, so redo puts it back), and Merge counts as Keep Both.
- Missing parent folders of an original path (a merge-move removed the emptied source folder, §6.3) are re-created and recorded as `.createdDirectory`, which the inverse removes once empty (§6.6 Merge row).
- `FileOpUndoStack` registers one explicit undo group per job (`groupsByEvent = false`, so registration never depends on a run loop: XCTest, `macx-scenarios`). Each entry has its own target object (a `Chain`). Its handler enqueues the inverse job asynchronously and, still inside the handler, registers the opposite entry, so the opposite lands on the redo (or undo) stack. That entry waits for the inverse job's record. An inverse whose record turns out empty or not undoable removes its chain from both stacks (`removeAllActions(withTarget:)`). `UndoManager` does not retain targets (verified: a released target crashes `undo()`), so the stack keeps its chains alive.

- [ ] **Step 1: Add the `Sendable` test view `FileOpsWorld`**

`@MainActor` test classes (this task's `UndoStackTests`, P1-25's center and environment tests) can't call the base class's `async` helpers: under Swift 6 region isolation that sends the non-`Sendable` test case off the main actor (verified: `error: sending value of non-Sendable type 'MainTests' risks causing data races`). Append to `Tests/CoreTests/FileOps/FileOpsTestSupport.swift`:

```swift
/// Sendable view of a FileOpsTestCase's sandbox, for @MainActor test classes: `let w = world`, then
/// `try await w.run(...)`, `await w.waitUntil { @MainActor in ... }`. Same sandbox guard as FileOpsTestCase.run.
struct FileOpsWorld: Sendable {
    let sandbox: Sandbox
    var root: URL { sandbox.root }
    var trashDir: URL { root.appending(path: ".trash", directoryHint: .isDirectory) }
    var journalURL: URL { root.appending(path: "state/journal.json") }

    func url(_ rel: String) -> URL { sandbox.url(rel) }
    @discardableResult func file(_ rel: String, _ text: String = "x") throws -> URL {
        try sandbox.createFile(rel, contents: Data(text.utf8))
    }
    @discardableResult func dir(_ rel: String) throws -> URL { try sandbox.createDirectory(rel) }
    func text(_ u: URL) -> String? { (try? Data(contentsOf: u)).map { String(decoding: $0, as: UTF8.self) } }
    func names(_ u: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }
    func exists(_ u: URL) -> Bool { var st = stat(); return lstat(u.path, &st) == 0 }

    func makeQueue(interaction: any FileOpInteraction = ScriptedInteraction(), tuning: FileOpTuning = FileOpTuning(),
                   trash: (any TrashService)? = nil) -> (FileOpQueue, Journal) {
        let journal = Journal(fileURL: journalURL)
        let queue = FileOpQueue(lanes: LanePool(), trash: trash ?? SandboxTrash(directory: trashDir),
                                journal: journal, interaction: interaction, tuning: tuning)
        return (queue, journal)
    }

    /// The only way @MainActor tests build requests: traps before anything is enqueued if a URL is outside the sandbox.
    func request(_ kind: JobKind, registersUndo: Bool = true) -> JobRequest {
        let rootPath = root.path + "/"
        for u in kind.allURLs {
            precondition((u.standardizedFileURL.path + "/").hasPrefix(rootPath), "URL outside the sandbox: \(u.path)")
        }
        return JobRequest(kind, registersUndo: registersUndo)
    }

    func run(_ kind: JobKind, on queue: FileOpQueue) async -> JobOutcome {
        let id = await queue.enqueue(request(kind))
        return await queue.outcome(of: id)
    }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: @escaping @Sendable () async -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout)", file: file, line: line)
    }
}

extension FileOpsTestCase {
    var world: FileOpsWorld { FileOpsWorld(sandbox: sandbox) }
}

/// lstat existence by path (usable inside @Sendable wait conditions).
func onDisk(_ path: String) -> Bool { var st = stat(); return lstat(path, &st) == 0 }
```

(`Sandbox` is `Sendable` in P1-02, so the struct is too.)

- [ ] **Step 2: Write the failing undo-job tests**

`Tests/CoreTests/FileOps/UndoTests.swift`:

```swift
import XCTest
import Darwin
@testable import Core
import MacxFS

/// Texts of every file named `name` anywhere under the sandbox trash.
func trashedTexts(_ name: String, in trashDir: URL) -> [String] {
    let e = FileManager.default.enumerator(atPath: trashDir.path)
    var out: [String] = []
    while let rel = e?.nextObject() as? String {
        guard (rel as NSString).lastPathComponent == name,
              let data = try? Data(contentsOf: trashDir.appending(path: rel)) else { continue }
        out.append(String(decoding: data, as: UTF8.self))
    }
    return out.sorted()
}

final class UndoTests: FileOpsTestCase {
    private func trashed(_ name: String) -> [String] { trashedTexts(name, in: trashDir) }
    private func inTrash(_ name: String) -> Bool {
        let e = FileManager.default.enumerator(atPath: trashDir.path)
        while let rel = e?.nextObject() as? String { if (rel as NSString).lastPathComponent == name { return true } }
        return false
    }

    func testStepsInvertEveryActionInReverseOrder() {
        let id = FileIdentity(device: 1, inode: 2)
        let u = URL(filePath: "/s/a"), v = URL(filePath: "/s/b"), t = URL(filePath: "/s/.trash/x/a")
        let record = JobRecord(id: JobID(), verb: .moving, actions: [
            .created(u, id), .createdDirectory(v, id), .moved(from: u, to: v, id), .renamed(from: u, to: v, id),
            .trashed(original: u, trashURL: t, id), .replaced(original: v, trashURL: t, id),
            .modeChanged(u, old: 0o644, new: 0o600),
            .attributesChanged(u, old: AttributeSnapshot(locked: false), new: AttributeSnapshot(locked: true)),
        ])
        XCTAssertEqual(UndoPlanner.steps(for: record), [
            .restoreAttributes(u, expected: AttributeSnapshot(locked: true), restore: AttributeSnapshot(locked: false)),
            .restoreMode(u, expected: 0o600, restore: 0o644),
            .moveBack(current: t, original: v, id),
            .moveBack(current: t, original: u, id),
            .renameBack(current: v, original: u, id),
            .moveBack(current: v, original: u, id),
            .removeDirectoryIfEmpty(v, id),
            .trash(u, id),
        ])
        XCTAssertEqual(UndoPlanner.steps(for: JobRecord(id: JobID(), verb: .makingSymlink, actions: [.created(u, id)])), [.remove(u, id)])
        XCTAssertEqual(UndoPlanner.steps(for: JobRecord(id: JobID(), verb: .makingAlias, actions: [.created(u, id)])), [.remove(u, id)])
        XCTAssertNil(UndoPlanner.steps(for: JobRecord(id: JobID(), verb: .deleting, actions: [.deleted(u)])))
        XCTAssertNil(UndoPlanner.steps(for: JobRecord(id: JobID(), verb: .copying, actions: [])))
    }

    func testUndoCopyTrashesCreatedItemsAndRedoBringsThemBack() async throws {
        let a = try file("src/a.txt", "A"); try file("src/T/x", "X")
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let copied = try await run(.copy(sources: [a, url("src/T")], destination: d), on: queue)
        let undone = try await run(.undo(copied.record), on: queue)
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(text(a), "A")
        XCTAssertEqual(text(url("src/T/x")), "X", "sources untouched")
        XCTAssertEqual(trashed("a.txt"), ["A"], "copies go to the trash, never deleted")
        XCTAssertEqual(undone.record.verb, .undoing)
        XCTAssertEqual(undone.record.actions.count, 2)
        XCTAssertTrue(undone.record.actions.allSatisfy { if case .trashed = $0 { true } else { false } })
        XCTAssertEqual(Set(undone.localChanges.flatMap(\.removed)), ["a.txt", "T"])
        let redone = try await run(.redo(undone.record), on: queue)
        XCTAssertEqual(names(d), ["T", "a.txt"])
        XCTAssertEqual(text(url("d/T/x")), "X")
        XCTAssertEqual(redone.record.verb, .redoing)
        XCTAssertEqual(Set(redone.created), [url("d/a.txt"), url("d/T")])
        XCTAssertEqual(trashed("a.txt"), [])
    }

    func testUndoSameVolumeMoveMovesBackKeepingIdentity() async throws {
        let a = try file("src/a.txt", "A")
        let inode = lst(a).st_ino
        let (queue, _) = makeQueue()
        let moved = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        let undone = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(lst(a).st_ino, inode, "renamed back, not copied")
        XCTAssertFalse(exists(url("d/a.txt")))
        guard case .moved(let from, let to, _)? = undone.record.actions.first else { return XCTFail("\(undone.record)") }
        XCTAssertEqual(from, url("d/a.txt"))
        XCTAssertEqual(to, a)
        XCTAssertEqual(undone.created, [a])
        XCTAssertEqual(undone.localChanges.first { $0.directory.lastPathComponent == "src" }?.select, ["a.txt"])
    }

    func testUndoCrossVolumeMoveMovesBackAcrossVolumes() async throws {
        try file("src/T/x", "X")
        var tuning = FileOpTuning(); tuning.forceCrossVolume = true
        let (queue, journal) = makeQueue(tuning: tuning)
        let moved = try await run(.move(sources: [url("src/T")], destination: try dir("d")), on: queue)
        XCTAssertFalse(exists(url("src/T")))
        _ = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(text(url("src/T/x")), "X")
        XCTAssertFalse(exists(url("d/T")))
        XCTAssertEqual(names(url("src")).filter { PartialName.isPartial($0) }, [])
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testUndoRenameRenamesBack() async throws {
        let a = try file("d/a.txt", "A")
        let (queue, _) = makeQueue()
        let renamed = try await run(.rename(a, to: "b.txt"), on: queue)
        let undone = try await run(.undo(renamed.record), on: queue)
        XCTAssertEqual(names(url("d")), ["a.txt"])
        XCTAssertEqual(undone.localChanges.first?.renamed, [LocalChange.Rename(from: "b.txt", to: "a.txt")])
    }

    func testUndoCaseOnlyRenameIsNotAnOccupiedPath() async throws {
        let a = try file("d/a.txt", "A")
        let scripted = ScriptedInteraction()
        let (queue, _) = makeQueue(interaction: scripted)
        let renamed = try await run(.rename(a, to: "A.txt"), on: queue)
        XCTAssertEqual(names(url("d")), ["A.txt"])
        _ = try await run(.undo(renamed.record), on: queue)
        XCTAssertEqual(names(url("d")), ["a.txt"])
        XCTAssertEqual(scripted.askedConflicts().count, 0, "the original spelling names the same file, not an occupant")
    }

    func testUndoTrashRestoresOriginalPath() async throws {
        let a = try file("d/a.txt", "keep me")
        let (queue, _) = makeQueue()
        let trashedJob = try await run(.trash([a]), on: queue)
        XCTAssertFalse(exists(a))
        let undone = try await run(.undo(trashedJob.record), on: queue)
        XCTAssertEqual(text(a), "keep me")
        XCTAssertEqual(undone.created, [a])
        XCTAssertEqual(trashed("a.txt"), [])
    }

    func testUndoNewFolderTrashesIt() async throws {
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let made = try await run(.newItem(.folder, in: d), on: queue)
        XCTAssertEqual(names(d), ["New Folder"])
        _ = try await run(.undo(made.record), on: queue)
        XCTAssertEqual(names(d), [])
        XCTAssertTrue(inTrash("New Folder"))
    }

    func testUndoCopyThatReplacedRestoresTheDisplacedItem() async throws {
        let a = try file("src/a.txt", "new"); try file("d/a.txt", "old")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        let copied = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "new")
        _ = try await run(.undo(copied.record), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "old", "the replaced item is back from its stored trash URL")
        XCTAssertEqual(trashed("a.txt"), ["new"], "the new copy went to the trash")
        XCTAssertEqual(text(a), "new")
    }

    func testUndoMergeMoveRecreatesTheRemovedSourceFolderAndRedoRemovesItAgain() async throws {
        try file("src/F/a", "A"); try file("src/F/b", "new b")
        try file("d/F/b", "old b"); try file("d/F/x", "X")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.merge), .one(.replace)]))
        let moved = try await run(.move(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertFalse(exists(url("src/F")), "merge-move removed the emptied source folder")
        let undone = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(names(url("src/F")), ["a", "b"])
        XCTAssertEqual(text(url("src/F/b")), "new b")
        XCTAssertEqual(names(url("d/F")), ["b", "x"])
        XCTAssertEqual(text(url("d/F/b")), "old b")
        guard case .createdDirectory(let made, _)? = undone.record.actions.first else { return XCTFail("\(undone.record)") }
        XCTAssertEqual(made.path, url("src/F").path)
        _ = try await run(.redo(undone.record), on: queue)
        XCTAssertFalse(exists(url("src/F")), "the folder undo re-created is removed once empty")
        XCTAssertEqual(names(url("d/F")), ["a", "b", "x"])
        XCTAssertEqual(text(url("d/F/b")), "new b")
        XCTAssertEqual(trashed("b"), ["old b"])
    }

    func testUndoChmodRecursiveRestoresEveryRecordedMode() async throws {
        try file("T/sub/f"); try file("T/g")
        let modes: [(String, mode_t)] = [("T", 0o755), ("T/sub", 0o750), ("T/sub/f", 0o640), ("T/g", 0o644)]
        for (rel, m) in modes { XCTAssertEqual(chmod(url(rel).path, m), 0) }
        let (queue, _) = makeQueue()
        let changed = try await run(.chmodRecursive(url("T"), ModeChange(mode: 0o700)), on: queue)
        XCTAssertEqual(changed.record.actions.count, 4)
        let undone = try await run(.undo(changed.record), on: queue)
        for (rel, m) in modes { XCTAssertEqual(lst(url(rel)).st_mode & 0o7777, m, rel) }
        XCTAssertEqual(undone.record.actions.count, 4)
        XCTAssertEqual(undone.skipped, [])
    }

    func testUndoChmodSkipsItemsWhoseModeChangedSince() async throws {
        try file("T/f")
        XCTAssertEqual(chmod(url("T").path, 0o755), 0)
        XCTAssertEqual(chmod(url("T/f").path, 0o644), 0)
        let (queue, _) = makeQueue()
        let changed = try await run(.chmodRecursive(url("T"), ModeChange(mode: 0o700)), on: queue)
        XCTAssertEqual(chmod(url("T/f").path, 0o600), 0)                  // changed behind our back
        let undone = try await run(.undo(changed.record), on: queue)
        XCTAssertEqual(undone.skipped, [SkippedItem(url: url("T/f"), reason: .changedDuringMove)])
        XCTAssertEqual(lst(url("T/f")).st_mode & 0o7777, 0o600, "the external change is kept")
        XCTAssertEqual(lst(url("T")).st_mode & 0o7777, 0o755)
    }

    func testUndoSetAttributesRestoresPreviousValues() async throws {
        let a = try file("a.txt")
        let quarantine = Array("0081;5f000000;Safari;".utf8)
        XCTAssertEqual(setxattr(a.path, AttributeJobs.quarantineName, quarantine, quarantine.count, 0, XATTR_NOFOLLOW), 0)
        let (queue, _) = makeQueue()
        let hidden = try await run(.setAttributes([a], .hidden(true)), on: queue)
        let unquarantined = try await run(.setAttributes([a], .removeQuarantine), on: queue)
        let locked = try await run(.setAttributes([a], .locked(true)), on: queue)
        _ = try await run(.undo(locked.record), on: queue)                // newest first, like the stack
        XCTAssertEqual(lst(a).st_flags & UInt32(UF_IMMUTABLE), 0)
        _ = try await run(.undo(unquarantined.record), on: queue)
        XCTAssertEqual(AttributeJobs.readXattr(a.path, AttributeJobs.quarantineName), Data(quarantine), "saved xattr rewritten")
        let undoneHidden = try await run(.undo(hidden.record), on: queue)
        XCTAssertEqual(lst(a).st_flags & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(undoneHidden.record.actions,
                       [.attributesChanged(a, old: AttributeSnapshot(hidden: true), new: AttributeSnapshot(hidden: false))])
        XCTAssertEqual(undoneHidden.localChanges.first?.modified, ["a.txt"])
    }

    func testUndoAliasAndSymlinkRemovesThemAndLeavesNothingToRedo() async throws {
        let a = try file("src/a.txt", "A")
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let alias = try await run(.alias(sources: [a], destination: d), on: queue)
        let link = try await run(.symlink(sources: [a], destination: d), on: queue)
        let undoneLink = try await run(.undo(link.record), on: queue)
        let undoneAlias = try await run(.undo(alias.record), on: queue)
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(text(a), "A", "the original is untouched")
        XCTAssertEqual(undoneLink.record.actions, [.deleted(url("d/a.txt"))])
        XCTAssertFalse(undoneAlias.record.isUndoable)
        XCTAssertFalse(inTrash("a.txt alias"), "removed, not trashed (§6.6)")
    }

    func testUndoSkipsItemsThatWereRemovedOrReplacedAndListsThem() async throws {
        let a = try file("src/a.txt"), b = try file("src/b.txt")
        let (queue, _) = makeQueue()
        let copied = try await run(.copy(sources: [a, b], destination: try dir("d")), on: queue)
        try FileManager.default.removeItem(at: url("d/a.txt"))                         // gone
        try file("d/b.new", "saved by an editor")
        XCTAssertEqual(Darwin.rename(url("d/b.new").path, url("d/b.txt").path), 0)     // atomic save: new identity
        let undone = try await run(.undo(copied.record), on: queue)
        XCTAssertEqual(undone.skipped, [SkippedItem(url: url("d/b.txt"), reason: .changedDuringMove),
                                        SkippedItem(url: url("d/a.txt"), reason: .sourceGone)])
        XCTAssertEqual(text(url("d/b.txt")), "saved by an editor", "a changed item is never trashed")
        XCTAssertEqual(undone.record.actions, [])
    }

    /// Slice Review Focus 5.
    func testUndoIntoOccupiedPathAsksConflictAndNeverOverwrites() async throws {
        let a = try file("src/a.txt", "moved")
        let scripted = ScriptedInteraction()                                          // default answer: Skip
        let (queue, _) = makeQueue(interaction: scripted)
        let moved = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        try file("src/a.txt", "new at the old place")
        let undone = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(scripted.askedConflicts().count, 1)
        XCTAssertEqual(scripted.askedConflicts().first?.pair.source.url, url("d/a.txt"))
        XCTAssertEqual(scripted.askedConflicts().first?.pair.destination.url, a)
        XCTAssertEqual(text(a), "new at the old place")
        XCTAssertEqual(text(url("d/a.txt")), "moved")
        XCTAssertEqual(undone.skipped, [SkippedItem(url: url("d/a.txt"), reason: nil)])
    }

    func testUndoIntoOccupiedPathKeepBothLandsUnderTheNextFreeName() async throws {
        let a = try file("src/a.txt", "moved")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.keepBoth)]))
        let moved = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        try file("src/a.txt", "new")
        _ = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(names(url("src")), ["a 2.txt", "a.txt"])
        XCTAssertEqual(text(url("src/a 2.txt")), "moved")
        XCTAssertEqual(text(a), "new")
    }

    func testUndoIntoOccupiedPathReplaceTrashesTheOccupantAndRedoRestoresIt() async throws {
        let a = try file("src/a.txt", "moved")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        let moved = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        try file("src/a.txt", "occupant")
        let undone = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(text(a), "moved")
        XCTAssertEqual(trashed("a.txt"), ["occupant"], "the occupant is trashed, never deleted")
        XCTAssertTrue(undone.record.actions.contains { if case .replaced = $0 { true } else { false } })
        _ = try await run(.redo(undone.record), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "moved")
        XCTAssertEqual(text(a), "occupant", "redo puts the displaced occupant back")
        XCTAssertEqual(trashed("a.txt"), [])
    }

    func testPartlyCompletedJobUndoesOnlyTheItemsThatWereDone() async throws {
        let a = try file("a.txt")
        let (queue, _) = makeQueue()                                                   // missing source: plan refusal, Skip
        let copied = try await run(.copy(sources: [a, url("missing.txt")], destination: try dir("d")), on: queue)
        XCTAssertEqual(copied.skipped.map(\.url), [url("missing.txt")])
        _ = try await run(.undo(copied.record), on: queue)
        XCTAssertEqual(names(url("d")), [])
        XCTAssertTrue(exists(a))
    }

    func testUndoOfANonUndoableRecordDoesNothing() async throws {
        let a = try file("a.txt")
        let (queue, _) = makeQueue()
        let record = JobRecord(id: JobID(), verb: .deleting,
                               actions: [.created(a, FileIdentity(device: 0, inode: 0)), .deleted(url("gone"))])
        let o = try await run(.undo(record), on: queue)
        XCTAssertEqual(o.record.actions, [])
        XCTAssertTrue(exists(a), "a record with a permanent delete is not undoable at all")
    }
}
```

`testUndoSkipsItems…` removes and renames files with `FileManager`/`rename(2)` only on URLs obtained from the sandbox (`url(_:)`/`file(_:)`). `testUndoCaseOnlyRename…` also holds on a case-sensitive sandbox volume: there the two spellings are different names and nothing conflicts either.

- [ ] **Step 3: Write the failing undo-stack tests**

Append to `Tests/CoreTests/FileOps/UndoTests.swift`:

```swift
@MainActor
final class UndoStackTests: FileOpsTestCase {
    private func copyJob(_ w: FileOpsWorld, _ queue: FileOpQueue) async throws -> JobOutcome {
        let a = try w.file("src/a.txt", "A")
        return await w.run(.copy(sources: [a], destination: try w.dir("d")), on: queue)
    }
    private func emptyOutcome(_ actions: [ItemAction]) -> JobOutcome {
        JobOutcome(record: JobRecord(id: JobID(), verb: .deleting, actions: actions), skipped: [], wasCancelled: false,
                   created: [], localChanges: [])
    }

    func testRegistersOneNamedEntryPerUndoableJob() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        XCTAssertFalse(stack.canUndo)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        XCTAssertTrue(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.undoManager.undoActionName, "Copy")
        stack.register(emptyOutcome([.deleted(w.url("x"))]), actionName: "Delete")
        stack.register(emptyOutcome([]), actionName: "Nothing")
        XCTAssertEqual(stack.undoManager.undoActionName, "Copy", "permanent delete and empty jobs register nothing")
    }

    func testUndoAndRedoThroughTheUndoManagerRunAsJobs() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        let target = w.url("d/a.txt").path
        stack.undoManager.undo()
        XCTAssertTrue(stack.canRedo, "the redo entry is registered synchronously, while undoing")
        XCTAssertEqual(stack.undoManager.redoActionName, "Copy")
        await w.waitUntil { !onDisk(target) }
        stack.undoManager.redo()
        XCTAssertTrue(stack.canUndo)
        XCTAssertEqual(stack.undoManager.undoActionName, "Copy")
        await w.waitUntil { onDisk(target) }
        XCTAssertEqual(w.text(w.url("d/a.txt")), "A")
    }

    func testRedoPressedBeforeTheUndoJobFinishedRunsAfterIt() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        let inverses = Task { () -> [JobVerb] in              // the copy's events are still buffered; skip them
            var verbs: [JobVerb] = []
            for await event in queue.events {
                if case .finished(let s, _) = event, s.description.verb != .copying { verbs.append(s.description.verb) }
                if verbs.count == 2 { break }
            }
            return verbs
        }
        stack.undoManager.undo()
        stack.undoManager.redo()                        // the undo job may still be queued
        let verbs = await inverses.value
        XCTAssertEqual(verbs, [.undoing, .redoing], "redo ran after undo, never before it")
        XCTAssertTrue(onDisk(w.url("d/a.txt").path))
        XCTAssertEqual(trashedTexts("a.txt", in: w.trashDir), [])
    }

    func testAnInverseThatDidNothingLeavesNoRedo() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        try FileManager.default.removeItem(at: w.url("d/a.txt"))     // gone behind our back
        stack.undoManager.undo()
        XCTAssertTrue(stack.canRedo)
        await w.waitUntil { @MainActor in !stack.canRedo }
        XCTAssertFalse(stack.canUndo)
    }

    func testANewJobClearsRedo() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        stack.undoManager.undo()
        let target = w.url("d/a.txt").path
        await w.waitUntil { !onDisk(target) }
        XCTAssertTrue(stack.canRedo)
        let made = await w.run(.newItem(.folder, in: w.url("d")), on: queue)
        stack.register(made, actionName: "New Folder")
        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.undoManager.undoActionName, "New Folder")
    }

    func testFieldEditorManagersAreSeparateFromTheFileStack() {
        let (queue, _) = world.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        let m1 = stack.makeFieldEditorUndoManager(), m2 = stack.makeFieldEditorUndoManager()
        XCTAssertFalse(m1 === stack.undoManager)
        XCTAssertFalse(m1 === m2, "one manager per edit, discarded when editing ends")
        XCTAssertTrue(m1.groupsByEvent, "typing undo groups by event")
        XCTAssertFalse(stack.undoManager.groupsByEvent, "file-operation entries are explicit groups")
    }
}
```

- [ ] **Step 4: Run the tests and watch them fail**

Run: `swift test --filter 'CoreTests.(UndoTests|UndoStackTests)' 2>&1 | tail -10`
Expected: compile failure, `cannot find 'UndoPlanner' in scope` / `cannot find 'FileOpUndoStack' in scope`.

- [ ] **Step 5: Add `setItemsDone` and `noteAdded` to `JobRunner.swift`**

Append to `Sources/Core/FileOps/JobRunner.swift` (same file as `JobContext`, so the extension reaches its private `state` and `mutateChange`):

```swift
extension JobContext {
    /// Undo/redo count one item per step, whatever the reused helpers added (they add their own item counts).
    func setItemsDone(_ n: Int) { state.withLock { $0.snapshot.progress.itemsDone = n } }

    /// A folder appeared without becoming part of the selection or `JobOutcome.created` (undo re-creating a parent).
    func noteAdded(_ url: URL) { mutateChange(url.deletingLastPathComponent()) { $0.added.append(url.lastPathComponent) } }
}
```

- [ ] **Step 6: Extract `trashOne` in `TrashDeleteJobs.swift`**

Replace the whole `static func trash(_ ctx: JobContext, _ urls: [URL]) async { … }` of P1-23 with these two functions (same behavior for trash jobs; undo reuses `trashOne`):

```swift
    enum TrashOne: Sendable, Equatable { case done, noTrash, skipped, cancelled }

    /// Trashes one item, asking on errors (Unlock and Continue clears uchg). Records `.trashed` with the
    /// resulting URL and posts the removal. `.noTrash`: the volume has no Trash; the caller decides.
    static func trashOne(_ ctx: JobContext, _ src: URL, identity: FileIdentity) async -> TrashOne {
        let trash = ctx.trash
        while true {
            let result: Result<URL, FileOpError> = (try? await ctx.onLane { _ in
                do { return .success(try trash.trash(src)) }
                catch let e as FileOpError { return .failure(e) }
                catch { return .failure(FileOpError(kind: FileOpErrorKind(error: error, isLockedItem: PosixFS.info(src.path)?.isLocked ?? false), url: src)) }
            }) ?? .failure(FileOpError(kind: .other(code: EIO, message: String(cString: strerror(EIO))), url: src))
            switch result {
            case .success(let trashURL):
                ctx.record(.trashed(original: src, trashURL: trashURL, identity))
                ctx.noteRemoved(src)
                ctx.addProgress(items: 1, current: src.lastPathComponent)
                return .done
            case .failure(let e) where e.kind == .noTrash:
                return .noTrash
            case .failure(let e):
                switch await ctx.askError(e) {
                case .retry, .continueAnyway: continue
                case .unlockAndContinue:
                    _ = try? await ctx.onLane { _ in PosixFS.clearImmutable(src.path, recursive: false) }
                    continue
                case .skip, .skipAll: ctx.skip(src, reason: e.kind); return .skipped
                case .cancel: ctx.cancelJob(); return .cancelled
                }
            }
        }
    }

    static func trash(_ ctx: JobContext, _ urls: [URL]) async {
        guard let plan = await ctx.plan(sources: urls, destination: nil, mode: .shallow) else { return }
        var noTrash: [URL] = []
        for item in plan.items {
            guard await ctx.checkpoint() else { break }
            switch await trashOne(ctx, item.source, identity: item.info.identity) {
            case .noTrash: noTrash.append(item.source)
            case .cancelled: return
            case .done, .skipped: continue
            }
        }
        guard !noTrash.isEmpty, !ctx.control.isCancelled else { return }
        if await ctx.askNoTrash(noTrash) {
            for u in noTrash {
                if await deleteItem(ctx, u) == .cancelled { return }
            }
        } else {
            for u in noTrash { ctx.skip(u, reason: .noTrash) }
        }
    }
```

- [ ] **Step 7: Extract `performRename` in `CreateOps.swift`**

Replace `static func rename(_ ctx: JobContext, _ url: URL, to newName: String) async { … }` of P1-19 with:

```swift
    static func rename(_ ctx: JobContext, _ url: URL, to newName: String) async {
        ctx.setTotals(items: 1, bytes: 0)
        ctx.setState(.running)
        await performRename(ctx, url, to: newName)
    }

    /// Validation, same-item rename in place (or journaled two-step), otherwise the rename primitive.
    /// Records `.renamed` and posts old → new. Undo reuses it without touching the job's totals.
    @discardableResult
    static func performRename(_ ctx: JobContext, _ url: URL, to newName: String) async -> StepResult {
        if newName.isEmpty || newName.contains("/") || newName.utf8.count > 255 {
            let kind: FileOpErrorKind = newName.utf8.count > 255 ? .nameTooLong
                : .other(code: EINVAL, message: String(cString: strerror(EINVAL)))
            if await ctx.askError(FileOpError(kind: kind, url: url)) == .cancel { ctx.cancelJob(); return .cancelled }
            ctx.skip(url, reason: kind)
            return .skipped
        }
        guard url.lastPathComponent != newName else { return .done }
        let target = url.deletingLastPathComponent().appending(path: newName)
        let parent = url.deletingLastPathComponent()
        let caps = (try? await ctx.onLane { _ in VolumeIdentity.capabilities(of: parent) })
            ?? VolumeIdentity.Capabilities(clone: false, renameExcl: false, caseSensitive: false)
        let result: StepResult
        if RenamePrimitive.isSameItemRename(url.lastPathComponent, newName, caseSensitive: caps.caseSensitive) {
            result = await inPlace(ctx, from: url, to: target)
        } else {
            result = await ctx.attempt(url, destination: target) { _ in
                switch RenamePrimitive.rename(url.path, target.path, renameExcl: caps.renameExcl) {
                case .renamed: 0
                case .exists: EEXIST
                case .crossDevice: EXDEV
                case .failed(let e): e
                }
            }
        }
        guard result == .done else { return result }
        let id = (try? await ctx.onLane { _ in FileIdentity.of(path: target.path) }) ?? nil
        if let id { ctx.record(.renamed(from: url, to: target, id)) }
        ctx.noteRenamed(from: url, to: target)
        ctx.addProgress(items: 1, current: newName)
        return .done
    }
```

The only behavioral difference from P1-19 is the return value; `RenameTests` must still pass unchanged.

- [ ] **Step 8: Implement `UndoPlanner.swift`**

```swift
import Foundation
import Darwin
import MacxFS

/// One inverse step of §6.6, derived from one recorded ItemAction.
enum UndoStep: Sendable, Equatable {
    case trash(URL, FileIdentity)
    case remove(URL, FileIdentity)
    case removeDirectoryIfEmpty(URL, FileIdentity)
    case moveBack(current: URL, original: URL, FileIdentity)
    case renameBack(current: URL, original: URL, FileIdentity)
    case restoreMode(URL, expected: UInt16, restore: UInt16)
    case restoreAttributes(URL, expected: AttributeSnapshot, restore: AttributeSnapshot)

    var isRestoreMode: Bool { if case .restoreMode = self { true } else { false } }
}

/// Body of `.undo(record)` and `.redo(record)` jobs (§6.6). Never overwrites; checks identity first.
enum UndoPlanner {
    enum Presence: Sendable, Equatable { case same, gone, changed }
    struct MadeDirectory: Sendable { var url: URL; var identity: FileIdentity }

    /// Pure. Inverse steps, last action first. nil when the record is not undoable (empty, or any `.deleted`).
    static func steps(for record: JobRecord) -> [UndoStep]? {
        guard record.isUndoable else { return nil }
        let removesLinks = record.verb == .makingAlias || record.verb == .makingSymlink
        return record.actions.reversed().compactMap { action -> UndoStep? in
            switch action {
            case .created(let u, let id): removesLinks ? .remove(u, id) : .trash(u, id)
            case .createdDirectory(let u, let id): .removeDirectoryIfEmpty(u, id)
            case .moved(let from, let to, let id): .moveBack(current: to, original: from, id)
            case .renamed(let from, let to, let id): .renameBack(current: to, original: from, id)
            case .trashed(let original, let t, let id), .replaced(let original, let t, let id):
                .moveBack(current: t, original: original, id)
            case .modeChanged(let u, let old, let new): .restoreMode(u, expected: new, restore: old)
            case .attributesChanged(let u, let old, let new): .restoreAttributes(u, expected: new, restore: old)
            case .deleted: nil
            }
        }
    }

    static func run(_ ctx: JobContext, _ record: JobRecord) async {
        guard let steps = steps(for: record) else { return }
        ctx.setTotals(items: steps.count, bytes: nil)
        ctx.setState(.running)
        var index = 0
        while index < steps.count {
            guard await ctx.checkpoint() else { return }
            if steps[index].isRestoreMode {
                var end = index
                while end < steps.count, steps[end].isRestoreMode { end += 1 }
                let finished = await restoreModes(ctx, Array(steps[index..<end]))
                index = end
                ctx.setItemsDone(index)
                guard finished else { return }
            } else {
                let result = await perform(ctx, steps[index])
                index += 1
                ctx.setItemsDone(index)
                if result == .cancelled { return }
            }
        }
    }

    static func perform(_ ctx: JobContext, _ step: UndoStep) async -> StepResult {
        switch step {
        case .trash(let u, let id): return await trashCreated(ctx, u, id)
        case .remove(let u, let id): return await remove(ctx, u, id)
        case .removeDirectoryIfEmpty(let u, let id): return await removeDirectoryIfEmpty(ctx, u, id)
        case .moveBack(let c, let o, let id): return await moveBack(ctx, current: c, original: o, id)
        case .renameBack(let c, let o, let id): return await renameBack(ctx, current: c, original: o, id)
        case .restoreMode: return await restoreModes(ctx, [step]) ? .done : .cancelled
        case .restoreAttributes(let u, let e, let r): return await restoreAttributes(ctx, u, expected: e, restore: r)
        }
    }

    // MARK: identity

    /// Lane only.
    static func presence(_ url: URL, _ id: FileIdentity) -> Presence {
        assertOffMain()
        guard let info = PosixFS.info(url.path) else { return .gone }
        return info.identity == id ? .same : .changed
    }

    /// Skips (and lists) items that have gone or changed. true = act.
    static func check(_ ctx: JobContext, _ url: URL, _ id: FileIdentity) async -> Bool {
        switch (try? await ctx.onLane { _ in presence(url, id) }) ?? .gone {
        case .same: return true
        case .gone: ctx.skip(url, reason: .sourceGone); return false
        case .changed: ctx.skip(url, reason: .changedDuringMove); return false
        }
    }

    // MARK: created items

    static func trashCreated(_ ctx: JobContext, _ url: URL, _ id: FileIdentity) async -> StepResult {
        guard await check(ctx, url, id) else { return .skipped }
        switch await TrashDeleteJobs.trashOne(ctx, url, identity: id) {
        case .done: return .done
        case .skipped: return .skipped
        case .cancelled: return .cancelled
        case .noTrash:
            guard await ctx.askNoTrash([url]) else { ctx.skip(url, reason: .noTrash); return .skipped }
            return await TrashDeleteJobs.deleteItem(ctx, url)
        }
    }

    /// Alias / symlink: removed (§6.6). The undo record then holds `.deleted`, so it has no redo.
    static func remove(_ ctx: JobContext, _ url: URL, _ id: FileIdentity) async -> StepResult {
        guard await check(ctx, url, id) else { return .skipped }
        let result = await ctx.attempt(url) { _ in PosixFS.removeTree(url.path) }
        if result == .done {
            ctx.record(.deleted(url))
            ctx.noteRemoved(url)
        }
        return result
    }

    /// A folder a merge (or an earlier undo) created: removed only once empty; otherwise left alone, silently.
    static func removeDirectoryIfEmpty(_ ctx: JobContext, _ url: URL, _ id: FileIdentity) async -> StepResult {
        let removed = (try? await ctx.onLane { _ in presence(url, id) == .same && rmdir(url.path) == 0 }) ?? false
        if removed { ctx.noteRemoved(url) }
        return .done
    }

    // MARK: moves and renames

    enum Landing { case at(URL, displaced: ConflictExecutor.Trashed?), skipped, cancelled }

    /// An occupied original path goes through the conflict question (§6.6). Undo never overwrites:
    /// Skip leaves both, Keep Both (and Merge) picks the next free name, Replace trashes the occupant.
    static func landing(_ ctx: JobContext, current: URL, original: URL, _ id: FileIdentity) async -> Landing {
        let parent = original.deletingLastPathComponent()
        // Same identity at the original spelling = a case/normalization-only rename of this very item.
        let occupied = (try? await ctx.onLane { _ in PosixFS.info(original.path).map { $0.identity != id } ?? false }) ?? false
        guard occupied else { return .at(original, displaced: nil) }
        guard let action = await ConflictExecutor.decide(ctx, source: current, target: original, pending: [], destinationDir: parent) else {
            return .cancelled
        }
        switch action {
        case .skip:
            ctx.skip(current, reason: nil)
            return .skipped
        case .keepBoth, .merge:
            let free = (try? await ctx.onLane { _ -> String in
                let isDir = PosixFS.info(current.path)?.isDirectory ?? false
                return NameGenerator.keepBoth(original.lastPathComponent, isDirectory: isDir) { PosixFS.exists(parent.appending(path: $0).path) }
            }) ?? original.lastPathComponent
            return .at(parent.appending(path: free), displaced: nil)
        case .replace:
            guard let trashed = await ConflictExecutor.trashExisting(ctx, original) else {
                if ctx.control.isCancelled { return .cancelled }
                ctx.skip(current, reason: nil)
                return .skipped
            }
            return .at(original, displaced: trashed)
        }
    }

    /// Moves `current` back to `original` (same volume: rename primitive; otherwise partial → verify →
    /// rename → delete, P1-21). Trash URLs and moved items both come back this way.
    static func moveBack(_ ctx: JobContext, current: URL, original: URL, _ id: FileIdentity) async -> StepResult {
        guard await check(ctx, current, id) else { return .skipped }
        let target: URL
        let displaced: ConflictExecutor.Trashed?
        switch await landing(ctx, current: current, original: original, id) {
        case .at(let t, let d): target = t; displaced = d
        case .skipped: return .skipped
        case .cancelled: return .cancelled
        }
        let parentReady = await ensureParent(ctx, of: target, for: current)
        guard parentReady == .done else {
            if let displaced { await ConflictExecutor.restore(ctx, displaced) }
            return parentReady
        }
        let parent = target.deletingLastPathComponent()
        let force = ctx.tuning.forceCrossVolume
        let planned = try? await ctx.onLane { lane in
            Planner.plan(sources: [current], destination: parent, mode: .move, forceCrossVolume: force, lane: lane)
        }
        guard let plan = planned, let item = plan.items.first else {
            if let displaced { await ConflictExecutor.restore(ctx, displaced) }
            ctx.skip(current, reason: .sourceGone)
            return .skipped
        }
        let result = await MoveJob.moveItem(ctx, item, to: target, renameExcl: plan.capabilities.renameExcl)
        if let displaced {
            if result == .done { await ctx.journalClear(displaced.entry) } else { await ConflictExecutor.restore(ctx, displaced) }
        }
        return result
    }

    static func renameBack(_ ctx: JobContext, current: URL, original: URL, _ id: FileIdentity) async -> StepResult {
        guard current.deletingLastPathComponent().standardizedFileURL.path
                == original.deletingLastPathComponent().standardizedFileURL.path else {
            return await moveBack(ctx, current: current, original: original, id)
        }
        guard await check(ctx, current, id) else { return .skipped }
        switch await landing(ctx, current: current, original: original, id) {
        case .at(let target, let displaced):
            let result = await CreateOps.performRename(ctx, current, to: target.lastPathComponent)
            if let displaced {
                if result == .done { await ctx.journalClear(displaced.entry) } else { await ConflictExecutor.restore(ctx, displaced) }
            }
            return result
        case .skipped: return .skipped
        case .cancelled: return .cancelled
        }
    }

    /// Lane only: `mkdir -p` of `directory`, returning the folders it created, outermost first. 0 or errno.
    static func makeMissingDirectories(_ directory: URL) -> (code: Int32, made: [MadeDirectory]) {
        assertOffMain()
        var missing: [String] = []
        var path = directory.standardizedFileURL.path
        while path != "/", !path.isEmpty, !PosixFS.exists(path) {
            missing.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        var made: [MadeDirectory] = []
        for dir in missing.reversed() {
            if mkdir(dir, 0o777) != 0 {
                let e = errno
                if e == EEXIST { continue }          // someone else made it: not ours to remove later
                return (e, made)
            }
            if let id = FileIdentity.of(path: dir) {
                made.append(MadeDirectory(url: URL(filePath: dir, directoryHint: .isDirectory), identity: id))
            }
        }
        return (0, made)
    }

    /// Re-creates missing parents of `target` (e.g. the source folder a merge-move removed once empty) and records
    /// them as `.createdDirectory`, so the inverse removes them again once empty.
    static func ensureParent(_ ctx: JobContext, of target: URL, for item: URL) async -> StepResult {
        let parent = target.deletingLastPathComponent()
        while true {
            let r = (try? await ctx.onLane { _ in makeMissingDirectories(parent) }) ?? (code: EIO, made: [])
            for d in r.made {
                ctx.record(.createdDirectory(d.url, d.identity))
                ctx.noteAdded(d.url)
            }
            if r.code == 0 { return .done }
            switch await ctx.resolveFailure(r.code, url: item, destination: parent) {
            case .retry: continue
            case .skipped: return .skipped
            case .cancelled: return .cancelled
            }
        }
    }

    // MARK: modes and attributes

    /// Consecutive mode restores run in one lane call (chmodRecursive of a large tree); failures are asked per item.
    /// false = the job was cancelled.
    static func restoreModes(_ ctx: JobContext, _ steps: [UndoStep]) async -> Bool {
        struct ModeItem: Sendable { var url: URL; var expected: UInt16; var restore: UInt16 }
        enum ModeResult: Sendable { case done, gone, changed, failed(Int32) }
        let items: [ModeItem] = steps.compactMap {
            if case .restoreMode(let u, let e, let r) = $0 { ModeItem(url: u, expected: e, restore: r) } else { nil }
        }
        let control = ctx.control
        let results: [ModeResult] = (try? await ctx.onLane { lane -> [ModeResult] in
            var out: [ModeResult] = []
            out.reserveCapacity(items.count)
            for (i, m) in items.enumerated() {
                if i % 256 == 0 { lane.heartbeat(); if !control.laneCheckpoint(lane) { break } }
                guard let info = PosixFS.info(m.url.path) else { out.append(.gone); continue }
                guard info.mode == m.expected else { out.append(.changed); continue }
                out.append(chmod(m.url.path, mode_t(m.restore)) == 0 ? .done : .failed(errno))
            }
            return out
        }) ?? items.map { _ in .failed(EIO) }
        let paths = Set(items.map { $0.url.standardizedFileURL.path })
        for (i, m) in items.enumerated() {
            guard i < results.count else { return false }               // the lane stopped at a cancel
            var outcome = results[i]
            retry: while case .failed(let code) = outcome {
                switch await ctx.resolveFailure(code, url: m.url) {
                case .retry:
                    outcome = (try? await ctx.onLane { _ in chmod(m.url.path, mode_t(m.restore)) == 0 ? ModeResult.done : .failed(errno) }) ?? .failed(EIO)
                case .skipped: break retry
                case .cancelled: return false
                }
            }
            switch outcome {
            case .done:
                ctx.record(.modeChanged(m.url, old: m.expected, new: m.restore))
                // One post per changed subtree: items whose parent is also in the batch are covered by it.
                if !paths.contains(m.url.deletingLastPathComponent().standardizedFileURL.path) { ctx.noteModified(m.url) }
            case .gone: ctx.skip(m.url, reason: .sourceGone)
            case .changed: ctx.skip(m.url, reason: .changedDuringMove)
            case .failed: break                                          // skipped by resolveFailure
            }
        }
        return !control.isCancelled
    }

    /// Lane only. Current values of exactly the fields `template` sets.
    static func currentValues(_ url: URL, like template: AttributeSnapshot) -> AttributeSnapshot? {
        var out = AttributeSnapshot()
        if template.locked != nil {
            guard let s = AttributeJobs.snapshot(url, for: .locked(false)) else { return nil }
            out.locked = s.locked
        }
        if template.hidden != nil {
            guard let s = AttributeJobs.snapshot(url, for: .hidden(false)) else { return nil }
            out.hidden = s.hidden
        }
        if template.extensionHidden != nil {
            guard let s = AttributeJobs.snapshot(url, for: .extensionHidden(false)) else { return nil }
            out.extensionHidden = s.extensionHidden
        }
        if template.mode != nil {
            guard let s = AttributeJobs.snapshot(url, for: .permissions(0)) else { return nil }
            out.mode = s.mode
        }
        if template.quarantine != nil {
            guard let s = AttributeJobs.snapshot(url, for: .removeQuarantine) else { return nil }
            out.quarantine = s.quarantine
        }
        return out
    }

    /// Properties edits: restore the recorded previous value (quarantine: rewrite the saved xattr), only while
    /// the item still has the value the job set.
    static func restoreAttributes(_ ctx: JobContext, _ url: URL, expected: AttributeSnapshot, restore: AttributeSnapshot) async -> StepResult {
        while true {
            let r = (try? await ctx.onLane { _ -> (Presence, Int32) in
                guard PosixFS.exists(url.path) else { return (.gone, 0) }
                guard currentValues(url, like: expected) == expected else { return (.changed, 0) }
                return (.same, AttributeJobs.apply(restore, to: url))
            }) ?? (.same, EIO)
            switch r {
            case (.gone, _):
                ctx.skip(url, reason: .sourceGone)
                return .skipped
            case (.changed, _):
                ctx.skip(url, reason: .changedDuringMove)
                return .skipped
            case (.same, 0):
                ctx.record(.attributesChanged(url, old: expected, new: restore))
                ctx.noteModified(url)
                return .done
            case (.same, let code):
                switch await ctx.resolveFailure(code, url: url) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
        }
    }
}
```

Notes for the executor:
- `ConflictExecutor.Trashed` is the P1-22 struct (`original`, `trashURL`, `entry`); `restore` puts it back and drops the recorded `.replaced`, exactly as Replace does in P1-22.
- `MoveJob.moveItem` records `.moved(from: current, to: target, id)` with the identity after the move, posts the removal and the landing (selected), and handles `EXDEV` by re-planning across volumes.
- If the compiler rejects the `retry: while case .failed(let code) = outcome` form, use `while true { guard case .failed(let code) = outcome else { break }; … }` (same behavior).

- [ ] **Step 9: Implement `FileOpUndoStack.swift`**

```swift
import Foundation
import MacxFS

/// The app-wide file-operation undo stack (§6.6). One explicit undo group per completed undoable job; undo and
/// redo run as jobs (`.undo(record)` / `.redo(record)`, registersUndo false) on the shared FileOpQueue.
@MainActor
public final class FileOpUndoStack {
    /// UndoManager target for one job and its undo/redo chain. UndoManager does not retain its targets (a released
    /// target crashes `undo()`), so the stack keeps every live chain for the session (§6.6 "session only").
    final class Chain {
        let actionName: String
        init(actionName: String) { self.actionName = actionName }
    }
    enum Direction: Sendable { case undo, redo }

    public let undoManager: UndoManager
    private let queue: FileOpQueue
    private var chains: [ObjectIdentifier: Chain] = [:]

    public init(queue: FileOpQueue) {
        self.queue = queue
        undoManager = UndoManager()
        // Explicit groups: registration never depends on the run loop closing an event group
        // (XCTest, macx-scenarios, and jobs finishing outside any event).
        undoManager.groupsByEvent = false
    }

    public var canUndo: Bool { undoManager.canUndo }
    public var canRedo: Bool { undoManager.canRedo }
    var liveChainCount: Int { chains.count }

    public func register(_ outcome: JobOutcome, actionName: String) {
        guard outcome.record.isUndoable else { return }
        let chain = Chain(actionName: actionName)
        chains[ObjectIdentifier(chain)] = chain
        let record = outcome.record
        undoManager.beginUndoGrouping()
        registerStep(chain, record: Task<JobRecord?, Never> { record }, direction: .undo)
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    public func makeFieldEditorUndoManager() -> UndoManager { UndoManager() }

    /// The handler runs inside `undo()`/`redo()`: it starts the inverse job and, while the manager is still
    /// undoing (or redoing), registers the opposite entry so it lands on the other stack. That entry waits
    /// for the inverse job's record, so a quick redo after undo runs after it, never before.
    private func registerStep(_ chain: Chain, record: Task<JobRecord?, Never>, direction: Direction) {
        undoManager.registerUndo(withTarget: chain) { [weak self] chain in
            guard let self else { return }
            let next = self.launch(chain, record: record, direction: direction)
            self.registerStep(chain, record: next, direction: direction == .undo ? .redo : .undo)
            self.undoManager.setActionName(chain.actionName)
        }
    }

    private func launch(_ chain: Chain, record: Task<JobRecord?, Never>, direction: Direction) -> Task<JobRecord?, Never> {
        let queue = self.queue
        return Task { [weak self] () -> JobRecord? in
            guard let r = await record.value else { return nil }
            let kind: JobKind = direction == .undo ? .undo(r) : .redo(r)
            let id = await queue.enqueue(JobRequest(kind, origin: nil, registersUndo: false))
            let outcome = await queue.outcome(of: id)
            guard outcome.record.isUndoable else {
                self?.drop(chain)                 // nothing to reverse (all skipped, or a remove): no entry
                return nil
            }
            return outcome.record
        }
    }

    private func drop(_ chain: Chain) {
        undoManager.removeAllActions(withTarget: chain)
        chains[ObjectIdentifier(chain)] = nil
    }
}
```

Entries whose redo was cleared by a newer registration keep their small `Chain` until the session ends (UndoManager reports no such event). That is bounded by the number of jobs in the session.

- [ ] **Step 10: Final dispatch in `JobRunner.run`**

Replace the whole `enum JobRunner { … }` in `Sources/Core/FileOps/JobRunner.swift` (the cases P1-19 … P1-23 inserted plus the `default:` branch) with the exhaustive switch. With `default:` gone, the compiler now checks that every `JobKind` has a body:

```swift
enum JobRunner {
    static func run(_ ctx: JobContext) async -> JobOutcome {
        ctx.setState(.planning)
        switch ctx.kind {
        case .newItem(let kind, let directory):
            await CreateOps.newItem(ctx, kind: kind, in: directory)
        case .rename(let url, let newName):
            await CreateOps.rename(ctx, url, to: newName)
        case .copy(let sources, let destination):
            await CopyJob.run(ctx, sources: sources, destination: destination, duplicate: false)
        case .duplicate(let urls):
            let groups = Dictionary(grouping: urls) { $0.deletingLastPathComponent().standardizedFileURL.path }
            for parent in groups.keys.sorted() where !ctx.control.isCancelled {
                await CopyJob.run(ctx, sources: groups[parent]!, destination: URL(filePath: parent, directoryHint: .isDirectory), duplicate: true)
            }
        case .move(let sources, let destination):
            await MoveJob.run(ctx, sources: sources, destination: destination)
        case .trash(let urls):
            await TrashDeleteJobs.trash(ctx, urls)
        case .delete(let urls):
            await TrashDeleteJobs.delete(ctx, urls)
        case .alias(let sources, let destination):
            await LinkJobs.alias(ctx, sources: sources, destination: destination)
        case .symlink(let sources, let destination):
            await LinkJobs.symlink(ctx, sources: sources, destination: destination)
        case .chmodRecursive(let url, let change):
            await AttributeJobs.chmodRecursive(ctx, url, change)
        case .setAttributes(let urls, let edit):
            await AttributeJobs.setAttributes(ctx, urls, edit)
        case .undo(let record), .redo(let record):
            await UndoPlanner.run(ctx, record)
        }
        try? await ctx.journal.finish(job: ctx.id)
        return ctx.outcome()
    }
}
```

- [ ] **Step 11: Run the tests and see them pass**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, no warnings.
Run: `swift test --filter 'CoreTests.(UndoTests|UndoStackTests)' 2>&1 | tail -5`
Expected: `Executed 26 tests, with 0 failures` (20 `UndoTests` + 6 `UndoStackTests`).

- [ ] **Step 12: Run every FileOps suite (the extractions and the final dispatch touch all job kinds)**

Run: `swift test --filter 'CoreTests.(FileOpErrorTests|JournalTests|QueueTests|PlannerTests|RenameTests|CopyTests|MoveTests|CrashRecoveryTests|ConflictTests|TrashDeleteTests|ErrorTableTests|UndoTests|UndoStackTests)' 2>&1 | tail -3`
Expected: `with 0 failures` (image tests skipped without hdiutil; `testRunCrashHelper` skipped in the parent process).

- [ ] **Step 13: Commit**

```bash
git add Sources/Core/FileOps Tests/CoreTests/FileOps
git commit -m "feat: undo planner and app-wide file-operation undo stack with redo"
```

---
### Task P1-25: OperationsCenter, TerminationCoordinator, CoreEnvironment (+ sandboxed(root:)), folderContext(), launch recovery wiring; end-to-end Core test

Spec: §6.1 (jobs belong to the app), §6.2 (jobs finishing in under 1 s show nothing; overall %; waiting jobs badge), §6.3 (launch cleanup from the journal; the user is told about incomplete jobs), §6.6 (an entry is registered when its job completes, whatever window started it), §6.7 (Stop and Quit cancels every job through the §6.1 cancel path and waits; after 10 s the app quits anyway), §4.2 (volume release: cancel reads ≤ 1 s, pause jobs), §4.3 (FileOps posts the paths it changed directly, so the app's own edits refresh without waiting for FSEvents), §5.9 (TCC outcomes per location), overview §3.12 (`CoreEnvironment`, `sandboxed(root:)`), Global Constraints › Safety (sandbox-only factory).

**Files:**
- Create: `Sources/Core/FileOps/OperationsCenter.swift`, `Sources/Core/FileOps/TerminationCoordinator.swift`, `Sources/Core/Support/CoreEnvironment.swift` (replaces P1-01's stub if one exists), `Sources/Core/Support/SandboxEjector.swift` (new file, see Contract notes 8)
- Modify: `Sources/Core/FileOps/FileOpQueue.swift` (internal `startsHeld` init + `releaseHold()`; `suspendJobs(touching:)` fix for the `/` mount point)
- Test: `Tests/CoreTests/OperationsCenterTests.swift` (classes `OperationsCenterTests`, `TerminationTests`, `EnvironmentTests`, `SandboxEjectorTests`); add one test to `Tests/CoreTests/FileOps/QueueTests.swift`

**Interfaces:**
- Consumes (contract §3, S1/S2 types used exactly as declared there): `Volumes(lanes:scanner:events:)`, `.start()`, `.refresh()`, `.volume(for:)`, `.list`, `.release(_:)`, `.addReleaseHandler(_:)`, `.mountTableStore`; `DirectoryReaders(lanes:mountTable:types:)`, `.cancelAll(on:)`; `Settings(storage:home:)`, `.home`, `.viewQuery()`, `.tccOutcome(for:)`, `.recordTCCOutcome(_:for:)`; `ProtectedLocations.classify(_:home:volume:)`; `ChangeBus()`, `.post(_:)`, `.observe(directory:_:)`; `Clipboard(backend:)`, `.copy(_:)`, `.pastePlan(into:moveItemHere:)`; `LaunchServicesCache(provider:types:)`; `EjectCoordinator(volumes:ejector:)`; `Ejecting`, `EjectError`; `FolderContext(...)`, `FolderModel(directory:context:query:)`, `.start()`, `.close()`, `.state`, `.rowCount`, `.name(atRow:)`, `.row(named:)`, `.selectedURLs`; `Watcher(directory:since:latency:handler:)`, `Watcher.currentEventID()`; `TimerFramePacer()`; `InMemorySettingsStorage()`, `InMemoryPasteboard()`, `FakeLaunchServices()`, `SystemVolumeScanner()`, `StatePaths(root:)`, `LaunchRecovery.run(journal:lanes:)`, `Observers`, `ObserverToken`, `TypeRegistry.shared`; from this slice everything P1-17 … P1-24 produced.
- Produces (contract §3.12/§3.13, exact; additive members marked):

```swift
@MainActor @Observable
public final class OperationsCenter {
    public init(queue: FileOpQueue, undo: FileOpUndoStack, changeBus: ChangeBus,
                actionName: @escaping @MainActor (JobDescription) -> String)
    public private(set) var jobs: [JobSnapshot]          // all unfinished
    public var visibleJobs: [JobSnapshot] { get }         // running ≥ 1 s or waitingForUser
    public var overallFraction: Double? { get }
    public var hasActiveJobs: Bool { get }
    public func start()                                   // consumes queue.events; posts localChanges; registers undo
    public func perform(_ request: JobRequest) async -> JobOutcome   // enqueue + await (UI convenience)
    public func onFinished(_ handler: @escaping @MainActor (JobSnapshot, JobOutcome) -> Void) -> ObserverToken
    // internal: var revealDelay: Duration (1 s); func handle(_ event: JobEvent) async; nonisolated static func overallFraction(of:) -> Double?
}

@MainActor
public final class TerminationCoordinator {
    public init(queue: FileOpQueue, operations: OperationsCenter)
    public var activeCount: Int { get }
    public func stopAllAndWait(timeout: Duration = .seconds(10)) async -> Bool
}

@MainActor
public final class CoreEnvironment {
    public let statePaths: StatePaths
    public let lanes: LanePool
    public let types: TypeRegistry
    public let readers: DirectoryReaders
    public let volumes: Volumes
    public let settings: Settings
    public let changeBus: ChangeBus
    public let clipboard: Clipboard
    public let launchServices: LaunchServicesCache
    public let ejectCoordinator: EjectCoordinator
    public let journal: Journal
    public let trash: any TrashService
    public let interaction: InteractionProxy
    public let fileOps: FileOpQueue
    public let undo: FileOpUndoStack
    public let operations: OperationsCenter
    public let termination: TerminationCoordinator
    public init(statePaths: StatePaths, lanes: LanePool, settingsStorage: any SettingsStorage,
                volumeScanner: any VolumeScanning, volumeEvents: (any VolumeEventSource)?,
                pasteboard: any PasteboardBackend, launchServices: any LaunchServicesProviding,
                ejector: any Ejecting, trash: any TrashService, fileOpTuning: FileOpTuning = FileOpTuning())
    public func folderContext() -> FolderContext
    public func makeFolderModel(_ directory: URL, query: ViewQuery? = nil) -> FolderModel
    public func start() async -> RecoveryReport
    public static func sandboxed(root: URL) -> CoreEnvironment
    // additive (Contract notes 7): public var undoActionName: @MainActor (JobDescription) -> String   (default: verb.rawValue)
    // internal: nonisolated static func isSandboxRoot(_:) -> Bool, nonisolated static func canonicalTempPath(_:) -> String
}
// internal
struct SandboxEjector: Ejecting { init(root: URL, lanes: LanePool); struct Holder: Equatable { var pid: Int32; var command: String }
    static func parseLsof(_ output: String) -> [Holder] }
extension FileOpQueue { init(lanes:trash:journal:interaction:tuning:startsHeld:); func releaseHold() }
```

**Design:**
- `OperationsCenter` is the single consumer of `FileOpQueue.events`. On `.finished` it, in this order: drops the job from `jobs`, posts `outcome.localChanges` to the `ChangeBus` (so the folder shows the result and selects it without waiting for FSEvents, §4.3), registers the undo entry when `queue.registersUndo(id)` (undo/redo jobs and opt-out requests never register), notifies `onFinished` observers, and resumes `perform` callers. `perform` therefore returns only after the change is posted and the entry exists. That matters to `macx-scenarios` (S6 calls `perform` and then `undo()`) and to the UI's menu validation.
- `visibleJobs`: a job becomes visible `revealDelay` (1 s) after it was added if it still hasn't finished, or immediately while it is `waitingForUser`. A timer task per job sets an observed flag, so SwiftUI/AppKit observers re-render without polling.
- `CoreEnvironment` builds the queue held (`startsHeld: true`). `start()` runs `LaunchRecovery` first, then releases the hold. Recovery deletes journaled partials, so it must see the journal before any job of this session writes to it; a job enqueued before `start()` (a fast click at launch) just waits in `.queued`.
- `sandboxed(root:)` traps unless `root` is a `macx-*` sandbox directory in the temporary directory. The check is pure string work, with no file-system call on the main thread. It puts everything inside the root: `state/` (journal), `.trash/` (`SandboxTrash`), `Settings.home = root`, `InMemorySettingsStorage`, `InMemoryPasteboard`, `FakeLaunchServices`, and a `SandboxEjector` that detaches only images mounted under the root. The interaction target is `ScriptedInteraction()`, so a forgotten `setTarget` answers Skip instead of hanging.

- [ ] **Step 1: Write the failing queue test for the `/` mount point**

Append to `QueueTests` in `Tests/CoreTests/FileOps/QueueTests.swift`:

```swift
    /// The boot volume's mount point is "/": every absolute path is on it (P1-18's prefix test missed it).
    func testSuspendJobsTouchingTheRootMountPointPausesQueuedJobs() async throws {
        let gate = EventLog()
        var tuning = FileOpTuning()
        tuning.bodyOverride = { ctx in
            while await ctx.checkpoint(), !gate.all.contains("go") { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let (queue, _) = makeQueue(tuning: tuning)
        let d = try dir("d")
        let ida = await queue.enqueue(JobRequest(.copy(sources: [try file("a")], destination: d)))
        let idb = await queue.enqueue(JobRequest(.copy(sources: [try file("b")], destination: d)))
        await waitUntil { await queue.snapshots().first { $0.id == ida }?.state == .running }
        let running = await queue.suspendJobs(touching: URL(filePath: "/", directoryHint: .isDirectory))
        XCTAssertEqual(running, [ida])
        let stateB = await queue.snapshots().first { $0.id == idb }?.state
        XCTAssertEqual(stateB, .paused)
        gate.add("go")
        _ = await queue.outcome(of: ida)
        await queue.resume(idb)
        _ = await queue.outcome(of: idb)
    }
```

(It only pauses and resumes this test's own queue; nothing outside the sandbox is touched.)

- [ ] **Step 2: Write the failing center, termination, environment and ejector tests**

`Tests/CoreTests/OperationsCenterTests.swift`:

```swift
import XCTest
import Darwin
import Synchronization
@testable import Core
import MacxFS

/// A latch bodies and interactions wait on.
final class Gate: Sendable {
    private let flag = Mutex(false)
    func open() { flag.withLock { $0 = true } }
    var isOpen: Bool { flag.withLock { $0 } }
    func wait() async { while !isOpen { try? await Task.sleep(for: .milliseconds(5)) } }
}

/// A dialog nobody answers until `gate` opens; then Cancel.
struct HeldInteraction: FileOpInteraction {
    let gate: Gate
    func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution { await gate.wait(); return .cancelJob }
    func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution { await gate.wait(); return .cancel }
    func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool { await gate.wait(); return false }
    func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool { await gate.wait(); return false }
}

@MainActor final class MainLog<T> { var items: [T] = [] }

@MainActor
func makeCenter(_ queue: FileOpQueue, name: @escaping @MainActor (JobDescription) -> String = { $0.verb.rawValue })
    -> (OperationsCenter, FileOpUndoStack, ChangeBus) {
    let undo = FileOpUndoStack(queue: queue)
    let bus = ChangeBus()
    let center = OperationsCenter(queue: queue, undo: undo, changeBus: bus, actionName: name)
    center.start()
    return (center, undo, bus)
}

/// Body that blocks on `gate` (after `before`), with fast progress ticks.
func gatedTuning(_ gate: Gate, before: @escaping @Sendable (JobContext) -> Void = { _ in }) -> FileOpTuning {
    var tuning = FileOpTuning(progressInterval: .milliseconds(20))
    tuning.bodyOverride = { ctx in before(ctx); await gate.wait() }
    return tuning
}

@MainActor
final class OperationsCenterTests: FileOpsTestCase {
    func testMirrorsUnfinishedJobsAndForgetsFinishedOnes() async throws {
        let w = world, gate = Gate()
        let (queue, _) = w.makeQueue(tuning: gatedTuning(gate))
        let (center, _, _) = makeCenter(queue)
        let id = await queue.enqueue(w.request(.copy(sources: [try w.file("a")], destination: try w.dir("d"))))
        await w.waitUntil { @MainActor in center.jobs.map(\.id) == [id] }
        XCTAssertTrue(center.hasActiveJobs)
        gate.open()
        await w.waitUntil { @MainActor in center.jobs.isEmpty }
        XCTAssertFalse(center.hasActiveJobs)
    }

    func testJobsBecomeVisibleOnlyAfterTheRevealDelay() async throws {
        let w = world, gate = Gate()
        let (queue, _) = w.makeQueue(tuning: gatedTuning(gate))
        let (center, _, _) = makeCenter(queue)
        center.revealDelay = .milliseconds(300)
        await queue.enqueue(w.request(.copy(sources: [try w.file("a")], destination: try w.dir("d"))))
        await w.waitUntil { @MainActor in center.jobs.count == 1 }
        XCTAssertEqual(center.visibleJobs.count, 0, "jobs that finish in under 1 s show nothing (§6.2)")
        await w.waitUntil { @MainActor in center.visibleJobs.count == 1 }
        gate.open()
        await w.waitUntil { @MainActor in center.visibleJobs.isEmpty && center.jobs.isEmpty }
    }

    func testJobWaitingForTheUserIsVisibleImmediately() async throws {
        let w = world, gate = Gate()
        let (queue, _) = w.makeQueue(tuning: gatedTuning(gate, before: { $0.setState(.waitingForUser) }))
        let (center, _, _) = makeCenter(queue)
        center.revealDelay = .seconds(30)
        await queue.enqueue(w.request(.copy(sources: [try w.file("a")], destination: try w.dir("d"))))
        await w.waitUntil { @MainActor in center.visibleJobs.first?.state == .waitingForUser }
        gate.open()
        await w.waitUntil { @MainActor in center.jobs.isEmpty }
    }

    func testOverallFractionWeighsBytesThenFallsBackToItemFractions() {
        func snap(items: (Int, Int?), bytes: (Int64, Int64?)) -> JobSnapshot {
            var p = JobProgress.zero
            p.itemsDone = items.0; p.itemsTotal = items.1; p.bytesDone = bytes.0; p.bytesTotal = bytes.1
            return JobSnapshot(id: JobID(), description: JobSnapshot.testValue.description, state: .running,
                               progress: p, origin: nil, startedAt: .now)
        }
        XCTAssertNil(OperationsCenter.overallFraction(of: []))
        XCTAssertNil(OperationsCenter.overallFraction(of: [snap(items: (0, nil), bytes: (0, nil))]), "still planning")
        XCTAssertEqual(OperationsCenter.overallFraction(of: [snap(items: (1, 4), bytes: (25, 100)),
                                                             snap(items: (0, 1), bytes: (275, 300)),
                                                             snap(items: (0, nil), bytes: (0, nil))]), 0.75)
        XCTAssertEqual(OperationsCenter.overallFraction(of: [snap(items: (1, 4), bytes: (0, 0)),
                                                             snap(items: (3, 4), bytes: (0, nil))]), 0.5)
    }

    func testFinishedJobPostsItsLocalChangesBeforePerformReturns() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let (center, _, bus) = makeCenter(queue)
        let a = try w.file("src/a.txt")
        let d = try w.dir("d")
        let log = MainLog<LocalChange>()
        let token = bus.observe(directory: d) { log.items.append($0) }
        defer { token.cancel() }
        let outcome = await center.perform(w.request(.copy(sources: [a], destination: d)))
        XCTAssertEqual(outcome.created, [w.url("d/a.txt")])
        XCTAssertEqual(log.items.flatMap(\.added), ["a.txt"])
        XCTAssertEqual(log.items.flatMap(\.select), ["a.txt"])
    }

    func testPerformRegistersTheUndoEntryWithItsFormattedNameBeforeReturning() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let (center, undo, _) = makeCenter(queue, name: { "Undo-\($0.verb.rawValue)-\($0.itemCount)" })
        _ = await center.perform(w.request(.copy(sources: [try w.file("a")], destination: try w.dir("d"))))
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoManager.undoActionName, "Undo-copying-1")
    }

    func testOptOutRequestsAndUndoJobsRegisterNothing() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let (center, undo, _) = makeCenter(queue)
        let copied = await center.perform(w.request(.copy(sources: [try w.file("a")], destination: try w.dir("d")), registersUndo: false))
        XCTAssertFalse(undo.canUndo)
        _ = await center.perform(w.request(.undo(copied.record), registersUndo: false))
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(w.exists(w.url("d/a")))
    }

    func testOnFinishedFiresForEveryJobIncludingUndoJobs() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let (center, undo, _) = makeCenter(queue)
        let log = MainLog<JobVerb>()
        let token = center.onFinished { snapshot, _ in log.items.append(snapshot.description.verb) }
        defer { token.cancel() }
        _ = await center.perform(w.request(.copy(sources: [try w.file("a")], destination: try w.dir("d"))))
        undo.undoManager.undo()
        await w.waitUntil { @MainActor in log.items.count == 2 }
        XCTAssertEqual(log.items, [.copying, .undoing])
    }

    func testLateProgressUpdateAfterFinishIsIgnored() async {
        let (queue, _) = world.makeQueue()
        let undo = FileOpUndoStack(queue: queue)
        let center = OperationsCenter(queue: queue, undo: undo, changeBus: ChangeBus(), actionName: { $0.verb.rawValue })
        let s = JobSnapshot.testValue
        await center.handle(.added(s))
        XCTAssertEqual(center.jobs.count, 1)
        await center.handle(.finished(s, JobOutcome(record: JobRecord(id: s.id, verb: .copying, actions: []), skipped: [],
                                                     wasCancelled: false, created: [], localChanges: [])))
        await center.handle(.updated(s))            // the ticker raced the finish
        XCTAssertTrue(center.jobs.isEmpty)
    }
}

@MainActor
final class TerminationTests: FileOpsTestCase {
    func testStopAllAndWaitCancelsEveryJobAndReturnsTrue() async throws {
        let w = world
        var tuning = FileOpTuning(progressInterval: .milliseconds(20))
        tuning.bodyOverride = { ctx in while await ctx.checkpoint() { try? await Task.sleep(for: .milliseconds(5)) } }
        let (queue, _) = w.makeQueue(tuning: tuning)
        let (center, _, _) = makeCenter(queue)
        let termination = TerminationCoordinator(queue: queue, operations: center)
        let d = try w.dir("d")
        for n in ["a", "b", "c"] { await queue.enqueue(w.request(.copy(sources: [try w.file(n)], destination: d))) }
        await w.waitUntil { @MainActor in termination.activeCount == 3 }
        let stopped = await termination.stopAllAndWait(timeout: .seconds(5))
        XCTAssertTrue(stopped)
        await w.waitUntil { @MainActor in termination.activeCount == 0 }
    }

    func testStopAllAndWaitGivesUpAtTheTimeoutWhileAJobWaitsOnTheUser() async throws {
        let w = world, answer = Gate()
        var tuning = FileOpTuning(progressInterval: .milliseconds(20))
        tuning.bodyOverride = { ctx in _ = await ctx.askError(FileOpError(kind: .inUse, url: ctx.kind.allURLs[0])) }
        let (queue, _) = w.makeQueue(interaction: HeldInteraction(gate: answer), tuning: tuning)
        let (center, _, _) = makeCenter(queue)
        let termination = TerminationCoordinator(queue: queue, operations: center)
        await queue.enqueue(w.request(.copy(sources: [try w.file("a")], destination: try w.dir("d"))))
        await w.waitUntil { @MainActor in center.jobs.first?.state == .waitingForUser }
        let start = ContinuousClock.now
        let stopped = await termination.stopAllAndWait(timeout: .milliseconds(300))
        XCTAssertFalse(stopped, "§6.7: quit anyway after the timeout; launch cleanup uses the journal")
        XCTAssertLessThan((ContinuousClock.now - start).inSeconds, 2)
        answer.open()                                    // the dialog is dismissed; the job then finishes
        await w.waitUntil { @MainActor in termination.activeCount == 0 }
    }

    func testStopAllMidCrossVolumeMoveRemovesThePartialAndKeepsTheSource() async throws {
        let w = world
        let big = try bigFile("src/big", bytes: 16 << 20)
        let d = try w.dir("d")
        let reached = EventLog()
        let proceed = DispatchSemaphore(value: 0)
        var tuning = FileOpTuning(copyChunkBytes: 1 << 20, faultHook: { point, _ in
            if point == .midCopyChunk, !reached.all.contains("chunk") { reached.add("chunk"); proceed.wait() }
        })
        tuning.forceCrossVolume = true
        tuning.allowClone = false
        let (queue, journal) = w.makeQueue(tuning: tuning)
        let (center, _, _) = makeCenter(queue)
        let termination = TerminationCoordinator(queue: queue, operations: center)
        let id = await queue.enqueue(w.request(.move(sources: [big], destination: d)))
        await w.waitUntil { reached.all.contains("chunk") }
        let stop = Task { @MainActor in await termination.stopAllAndWait(timeout: .seconds(10)) }
        await w.waitUntil { await queue.snapshots().first?.state == .cancelling }
        proceed.signal()
        let stopped = await stop.value
        XCTAssertTrue(stopped)
        let outcome = await queue.outcome(of: id)
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(lst(big).st_size, 16 << 20, "the source is never deleted")
        XCTAssertEqual(w.names(d), [], "the partial copy was removed")
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }
}

@MainActor
final class EnvironmentTests: FileOpsTestCase {
    private func rowNames(_ m: FolderModel) -> [String] { (0..<m.rowCount).map { m.name(atRow: $0) } }

    func testSandboxedPutsEveryServiceInsideTheSandbox() async throws {
        let w = world
        let env = CoreEnvironment.sandboxed(root: root)
        XCTAssertEqual(env.statePaths.root.path, w.url("state").path)
        XCTAssertEqual(env.statePaths.journal.path, w.journalURL.path)
        XCTAssertEqual((env.trash as? SandboxTrash)?.directory.path, w.trashDir.path)
        XCTAssertTrue(env.launchServices.provider is FakeLaunchServices)
        XCTAssertEqual(env.settings.home.path, root.path)
        let report = await env.start()
        XCTAssertTrue(report.isEmpty)
        // ScriptedInteraction is the default target: a conflict is skipped, never shown to a human.
        let a = try w.file("files/src/a.txt", "new")
        try w.file("files/d/a.txt", "old")
        let o = await env.operations.perform(w.request(.copy(sources: [a], destination: w.url("files/d"))))
        XCTAssertEqual(o.skipped, [SkippedItem(url: a, reason: nil)])
        XCTAssertEqual(w.text(w.url("files/d/a.txt")), "old")
    }

    func testSandboxRootCheckAcceptsOnlyMacxDirectoriesInTheTemporaryDirectory() {
        let tmp = FileManager.default.temporaryDirectory
        XCTAssertTrue(CoreEnvironment.isSandboxRoot(root), "resolved /private/var spelling")
        XCTAssertTrue(CoreEnvironment.isSandboxRoot(tmp.appending(path: "macx-scenario-\(UUID().uuidString)")), "/var spelling")
        XCTAssertFalse(CoreEnvironment.isSandboxRoot(tmp))
        XCTAssertFalse(CoreEnvironment.isSandboxRoot(tmp.appending(path: "macx-tests-")))
        XCTAssertFalse(CoreEnvironment.isSandboxRoot(tmp.appending(path: "other-\(UUID().uuidString)")))
        XCTAssertFalse(CoreEnvironment.isSandboxRoot(FileManager.default.homeDirectoryForCurrentUser))
        XCTAssertFalse(CoreEnvironment.isSandboxRoot(root.appending(path: "../../macx-tests-escape")))
        XCTAssertFalse(CoreEnvironment.isSandboxRoot(URL(filePath: "/Users/macx-tests-x")))
    }

    func testFolderContextWiresWatcherAndPermissionOutcomes() {
        let env = CoreEnvironment.sandboxed(root: root)
        let context = env.folderContext()
        let watcher = context.makeWatcher(url("files"), Watcher.currentEventID(), { _ in })
        XCTAssertTrue(watcher is Watcher)
        let desktop = root.appending(path: "Desktop", directoryHint: .isDirectory)     // home is the sandbox root
        XCTAssertTrue(context.permissionPending(desktop), "protected location without a recorded outcome")
        XCTAssertFalse(context.permissionPending(url("files")))
        context.recordPermissionOutcome(desktop, true)
        XCTAssertFalse(context.permissionPending(desktop))
        XCTAssertEqual(env.settings.tccOutcome(for: .desktop), .granted)
    }

    func testStartRunsLaunchRecoveryBeforeAnyJobRuns() async throws {
        let w = world
        let job = JobID()
        let partialName = PartialName.make(for: "big", job: job)
        try w.file("files/d/\(partialName)/f", "partial bytes")
        let seed = Journal(fileURL: w.journalURL)                        // a previous session that crashed
        try await seed.record(.jobStarted(job: job, description: JobDescription(verb: .moving, itemCount: 1, firstItemName: "big",
                                                                                sourceFolderName: nil, destinationFolderName: nil)))
        try await seed.record(.partial(job: job, url: w.url("files/d/\(partialName)")))
        let env = CoreEnvironment.sandboxed(root: root)
        let queue = env.fileOps
        let a = try w.file("files/src/a.txt")
        let id = await queue.enqueue(w.request(.copy(sources: [a], destination: w.url("files/d"))))
        try await Task.sleep(for: .milliseconds(200))
        let held = await queue.snapshots().first { $0.id == id }?.state
        XCTAssertEqual(held, .queued, "no job runs before launch recovery")
        XCTAssertFalse(w.exists(w.url("files/d/a.txt")))
        let report = await env.start()
        XCTAssertEqual(report.removedPartials, [w.url("files/d/\(partialName)")])
        XCTAssertEqual(report.incompleteJobs.map(\.firstItemName), ["big"])
        let o = await queue.outcome(of: id)
        XCTAssertEqual(o.created, [w.url("files/d/a.txt")])
        XCTAssertEqual(w.names(w.url("files/d")), ["a.txt"])
        let again = await env.start()
        XCTAssertEqual(again, report, "start() is idempotent")
    }

    func testVolumeReleasePausesQueuedJobsTouchingThatVolume() async throws {
        let w = world
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let gate = Gate()
        var tuning = FileOpTuning()
        tuning.bodyOverride = { _ in await gate.wait() }
        let lanes = LanePool()
        let env = CoreEnvironment(statePaths: StatePaths(root: w.url("state")), lanes: lanes,
                                  settingsStorage: InMemorySettingsStorage(), volumeScanner: SystemVolumeScanner(),
                                  volumeEvents: nil, pasteboard: InMemoryPasteboard(), launchServices: FakeLaunchServices(),
                                  ejector: SandboxEjector(root: w.root, lanes: lanes),
                                  trash: SandboxTrash(directory: w.trashDir), fileOpTuning: tuning)
        _ = await env.start()
        await env.volumes.refresh()
        let volume = try XCTUnwrap(env.volumes.volume(for: mnt))
        let queue = env.fileOps
        let local = try w.file("files/a")
        let running = await queue.enqueue(w.request(.copy(sources: [local], destination: try w.dir("files/d"))))
        await w.waitUntil { await queue.snapshots().first { $0.id == running }?.state == .running }
        let toImage = await queue.enqueue(w.request(.copy(sources: [local], destination: mnt)))   // queued behind `running`
        try await Task.sleep(for: .milliseconds(100))
        let before = await queue.snapshots().first { $0.id == toImage }?.state
        XCTAssertEqual(before, .queued)
        await env.volumes.release(volume.id)
        let after = await queue.snapshots().first { $0.id == toImage }?.state
        XCTAssertEqual(after, .paused, "§4.2: release pauses jobs touching the volume")
        gate.open()
        _ = await queue.outcome(of: running)
        try await Task.sleep(for: .milliseconds(100))
        let still = await queue.snapshots().first { $0.id == toImage }?.state
        XCTAssertEqual(still, .paused, "a paused job does not start when the volume pair frees up")
        await queue.resume(toImage)
        _ = await queue.outcome(of: toImage)
    }

    /// End to end through Core: browse a sandbox folder, paste-copy into it, see the posted LocalChange select the
    /// new row (FSEvents never select), undo, redo.
    func testEndToEndBrowsePasteCopySeeLocalChangeAndUndo() async throws {
        let w = world
        let a = try w.file("files/src/a.txt", "A")
        let dst = try w.dir("files/dst")
        try w.file("files/dst/existing.txt")
        let env = CoreEnvironment.sandboxed(root: root)
        env.undoActionName = { "Undo \($0.verb.rawValue)" }
        _ = await env.start()
        let model = env.makeFolderModel(dst)
        model.start()
        defer { model.close() }
        await w.waitUntil { @MainActor in model.state == .complete }
        XCTAssertEqual(rowNames(model), ["existing.txt"])

        env.clipboard.copy([a])
        let plan = try XCTUnwrap(env.clipboard.pastePlan(into: dst, moveItemHere: false))
        XCTAssertEqual(plan.operation, .copy)
        let outcome = await env.operations.perform(w.request(.copy(sources: plan.sources, destination: plan.destination)))
        XCTAssertEqual(outcome.created, [w.url("files/dst/a.txt")])
        await w.waitUntil { @MainActor in model.row(named: "a.txt") != nil }
        XCTAssertEqual(model.selectedURLs.map(\.lastPathComponent), ["a.txt"], "selected by the posted LocalChange")
        XCTAssertTrue(env.undo.canUndo)
        XCTAssertEqual(env.undo.undoManager.undoActionName, "Undo copying")

        env.undo.undoManager.undo()
        await w.waitUntil { @MainActor in model.row(named: "a.txt") == nil }
        XCTAssertFalse(w.exists(w.url("files/dst/a.txt")))
        XCTAssertEqual(w.text(a), "A")
        XCTAssertTrue(env.undo.canRedo)

        env.undo.undoManager.redo()
        await w.waitUntil { @MainActor in model.row(named: "a.txt") != nil }
        XCTAssertEqual(w.text(w.url("files/dst/a.txt")), "A")
        XCTAssertEqual(rowNames(model), ["a.txt", "existing.txt"])
    }
}

/// statfs mount point of `path` (nil if it doesn't exist).
func mountPath(of path: String) -> String? {
    var sfs = statfs()
    guard statfs(path, &sfs) == 0 else { return nil }
    return withUnsafeBytes(of: &sfs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

final class SandboxEjectorTests: FileOpsTestCase {
    func testRefusesMountPointsOutsideTheSandboxAndDetachesItsOwnImages() async throws {
        let ejector = SandboxEjector(root: root, lanes: LanePool())
        var refused: EjectError?
        do throws(EjectError) { try await ejector.eject(URL(filePath: "/Volumes/NotOurs")) } catch { refused = error }
        XCTAssertEqual(refused, .failed(code: EPERM, message: ""), "never runs hdiutil outside the sandbox")
        let outside = await ejector.blockingProcesses(URL(filePath: "/"), timeout: .seconds(1))
        XCTAssertEqual(outside, [], "not even lsof outside the sandbox")
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let canonical = { (p: String?) in p.map(CoreEnvironment.canonicalTempPath) }
        XCTAssertEqual(canonical(mountPath(of: mnt.path)), canonical(mnt.path))
        var failure: EjectError?
        do throws(EjectError) { try await ejector.eject(mnt) } catch { failure = error }
        XCTAssertNil(failure)
        XCTAssertNotEqual(canonical(mountPath(of: mnt.path)), canonical(mnt.path), "the sandbox image is detached")
    }

    func testLsofOutputParsing() {
        let me = getpid()
        XCTAssertEqual(SandboxEjector.parseLsof("p\(me)\ncxctest\np1\nclaunchd\nf3\np42\ncmds\n"),
                       [.init(pid: me, command: "xctest"), .init(pid: 1, command: "launchd"), .init(pid: 42, command: "mds")])
        XCTAssertEqual(SandboxEjector.parseLsof(""), [])
    }
}
```

The environment tests keep fixtures under `<sandbox>/files`: `sandboxed(root:)` puts `state/` and `.trash/` directly in the root, and those must not show up in listings. `testVolumeRelease…` and the ejector test need `hdiutil` (skipped otherwise). The release test releases only the image's volume, in this test's own environment: release handlers act on this environment's readers and queue, and nothing is unmounted.

- [ ] **Step 3: Run the tests and watch them fail**

Run: `swift test --filter 'CoreTests.(OperationsCenterTests|TerminationTests|EnvironmentTests|SandboxEjectorTests|QueueTests)' 2>&1 | tail -10`
Expected: compile failure, `cannot find 'OperationsCenter' in scope` / `cannot find 'CoreEnvironment' in scope`.

- [ ] **Step 4: Hold and the `/` fix in `FileOpQueue.swift`**

In `Sources/Core/FileOps/FileOpQueue.swift`:

1. Add the stored property `private var held = false` next to `private var order`.
2. Replace the public `init(lanes:trash:journal:interaction:tuning:)` with the delegating public init plus the internal designated one:

```swift
    public init(lanes: LanePool, trash: any TrashService, journal: Journal, interaction: any FileOpInteraction,
                tuning: FileOpTuning = FileOpTuning()) {
        self.init(lanes: lanes, trash: trash, journal: journal, interaction: interaction, tuning: tuning, startsHeld: false)
    }

    /// `startsHeld`: jobs stay queued until `releaseHold()`. CoreEnvironment uses it so LaunchRecovery sees the
    /// journal before any job of this session writes to it.
    init(lanes: LanePool, trash: any TrashService, journal: Journal, interaction: any FileOpInteraction,
         tuning: FileOpTuning, startsHeld: Bool) {
        self.lanes = lanes; self.trash = trash; self.journal = journal; self.interaction = interaction; self.tuning = tuning
        self.held = startsHeld
        (eventStream, continuation) = AsyncStream.makeStream(of: JobEvent.self, bufferingPolicy: .unbounded)
    }

    func releaseHold() {
        held = false
        schedule()
    }
```

3. First line of `schedule()`: `guard !held else { return }`.
4. Replace `suspendJobs(touching:)` with:

```swift
    public func suspendJobs(touching mountPoint: URL) -> [JobID] {
        let base = mountPoint.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"            // "/" (boot volume) must match every path
        func touches(_ e: Entry) -> Bool {
            e.ctx.kind.allURLs.contains { u in let p = u.standardizedFileURL.path; return p == base || p.hasPrefix(prefix) }
        }
        var running: [JobID] = []
        for id in order {
            guard let e = entries[id], touches(e) else { continue }
            if e.started { running.append(id) } else { pause(id) }
        }
        return running
    }
```

`cancel(_:)` of a held job still finishes it at once (it never started), so quitting before `start()` works.

- [ ] **Step 5: Implement `OperationsCenter.swift`**

```swift
import Foundation
import Observation
import MacxFS

/// Main-actor mirror of the FileOpQueue (§6.2) and the router of finished jobs: LocalChange posts (§4.3),
/// undo registration (§6.6), onFinished observers, `perform` callers. The single consumer of `queue.events`.
@MainActor @Observable
public final class OperationsCenter {
    public private(set) var jobs: [JobSnapshot] = []
    private var revealed: Set<JobID> = []

    private let queue: FileOpQueue
    private let undo: FileOpUndoStack
    private let changeBus: ChangeBus
    private let actionName: @MainActor (JobDescription) -> String
    private let finishedObservers = Observers<(JobSnapshot, JobOutcome)>()
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var waiters: [JobID: [CheckedContinuation<JobOutcome, Never>]] = [:]
    @ObservationIgnored private var unclaimed: [JobID: JobOutcome] = [:]
    @ObservationIgnored private var performsInFlight = 0
    /// §6.2: jobs that finish sooner show nothing.
    @ObservationIgnored var revealDelay: Duration = .seconds(1)

    public init(queue: FileOpQueue, undo: FileOpUndoStack, changeBus: ChangeBus,
                actionName: @escaping @MainActor (JobDescription) -> String) {
        self.queue = queue; self.undo = undo; self.changeBus = changeBus; self.actionName = actionName
    }

    public var visibleJobs: [JobSnapshot] { jobs.filter { $0.state == .waitingForUser || revealed.contains($0.id) } }
    public var overallFraction: Double? { Self.overallFraction(of: jobs) }
    public var hasActiveJobs: Bool { !jobs.isEmpty }

    /// Bytes-weighted over jobs that know their byte total; otherwise the mean of the known fractions.
    nonisolated static func overallFraction(of jobs: [JobSnapshot]) -> Double? {
        let withBytes = jobs.filter { ($0.progress.bytesTotal ?? 0) > 0 }
        if !withBytes.isEmpty {
            let done = withBytes.reduce(Int64(0)) { $0 + $1.progress.bytesDone }
            let total = withBytes.reduce(Int64(0)) { $0 + ($1.progress.bytesTotal ?? 0) }
            return min(1, Double(done) / Double(total))
        }
        let fractions = jobs.compactMap(\.progress.fraction)
        return fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
    }

    /// Idempotent.
    public func start() {
        guard consumer == nil else { return }
        let events = queue.events
        consumer = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    func handle(_ event: JobEvent) async {
        switch event {
        case .added(let s):
            guard !jobs.contains(where: { $0.id == s.id }) else { return }
            jobs.append(s)
            scheduleReveal(s.id)
        case .updated(let s):
            // A ticker update can race the finish; one for a job we no longer list is stale.
            guard let i = jobs.firstIndex(where: { $0.id == s.id }) else { return }
            jobs[i] = s
        case .finished(let s, let outcome):
            jobs.removeAll { $0.id == s.id }
            revealed.remove(s.id)
            changeBus.post(outcome.localChanges)
            if await queue.registersUndo(s.id) {
                undo.register(outcome, actionName: actionName(s.description))
            }
            finishedObservers.send((s, outcome))
            if let ws = waiters.removeValue(forKey: s.id) {
                for w in ws { w.resume(returning: outcome) }
            } else if performsInFlight > 0 {
                unclaimed[s.id] = outcome                 // finished before its perform caller started waiting
            }
        }
    }

    private func scheduleReveal(_ id: JobID) {
        let delay = revealDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.jobs.contains(where: { $0.id == id }) else { return }
            self.revealed.insert(id)
        }
    }

    /// Returns after the finished job's changes were posted and its undo entry registered.
    public func perform(_ request: JobRequest) async -> JobOutcome {
        start()
        performsInFlight += 1
        defer {
            performsInFlight -= 1
            if performsInFlight == 0 { unclaimed.removeAll() }
        }
        let id = await queue.enqueue(request)
        if let outcome = unclaimed.removeValue(forKey: id) { return outcome }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    public func onFinished(_ handler: @escaping @MainActor (JobSnapshot, JobOutcome) -> Void) -> ObserverToken {
        finishedObservers.add { handler($0.0, $0.1) }
    }
}
```

`let` properties are not tracked by `@Observable`; `jobs` and `revealed` are, so `visibleJobs`, `overallFraction` and `hasActiveJobs` update observers. The UI (P1-30 Dock badge, P1-38 capsule) reads them with `withObservationTracking` or SwiftUI.

- [ ] **Step 6: Implement `TerminationCoordinator.swift`**

```swift
import Foundation
import Synchronization

/// §6.7 Stop and Quit: cancel every job (finish the current item safely, remove cross-volume partials, update
/// the journal) and wait, at most `timeout`. After a timeout the app quits anyway; launch cleanup uses the journal.
@MainActor
public final class TerminationCoordinator {
    private let queue: FileOpQueue
    private let operations: OperationsCenter

    public init(queue: FileOpQueue, operations: OperationsCenter) {
        self.queue = queue; self.operations = operations
    }

    public var activeCount: Int { operations.jobs.count }

    public func stopAllAndWait(timeout: Duration = .seconds(10)) async -> Bool {
        let queue = self.queue
        let once = ResumeOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            // A job blocked on an unanswered dialog never finishes its cancel, and `cancelAll` can't be
            // interrupted, so the two race in unstructured tasks rather than a task group (which would wait for both).
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                if once.claim() { c.resume(returning: false) }
            }
            Task {
                await queue.cancelAll()
                timer.cancel()
                if once.claim() { c.resume(returning: true) }
            }
        }
    }
}

/// First caller wins.
final class ResumeOnce: Sendable {
    private let done = Mutex(false)
    func claim() -> Bool { done.withLock { d in defer { d = true }; return !d } }
}
```

- [ ] **Step 7: Implement `SandboxEjector.swift`**

```swift
import Foundation
import Darwin
import Synchronization
import MacxFS

/// `Ejecting` for sandboxed environments (tests, macx-scenarios): only disk images mounted under `root` are
/// detached (`hdiutil detach` without -force, so a busy volume reports busy). Everything else is refused before
/// any tool runs. Tools run on a fileOp lane of the image's volume and heartbeat while they wait.
struct SandboxEjector: Ejecting {
    struct Holder: Sendable, Equatable { var pid: Int32; var command: String }

    let root: URL
    let lanes: LanePool

    init(root: URL, lanes: LanePool) { self.root = root; self.lanes = lanes }

    func isInside(_ mountPoint: URL) -> Bool {
        let r = CoreEnvironment.canonicalTempPath(root.standardizedFileURL.path)
        let m = CoreEnvironment.canonicalTempPath(mountPoint.standardizedFileURL.path)
        return m.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    private func lane(_ mountPoint: URL) -> VolumeID { VolumeID(raw: "mnt:" + mountPoint.standardizedFileURL.path) }

    func eject(_ mountPoint: URL) async throws(EjectError) {
        guard isInside(mountPoint) else { throw EjectError.failed(code: EPERM, message: "") }
        let path = mountPoint.standardizedFileURL.path
        let result: (status: Int32, output: String)
        do {
            result = try await lanes.perform(on: lane(mountPoint), .fileOp) { lane in
                Self.runTool("/usr/bin/hdiutil", ["detach", path], timeout: .seconds(30), lane: lane)
            }
        } catch {
            throw EjectError.failed(code: EIO, message: "")
        }
        guard result.status != 0 else { return }
        if result.output.localizedCaseInsensitiveContains("busy") {
            throw EjectError.busy(processes: await blockingProcesses(mountPoint, timeout: .seconds(2)))
        }
        throw EjectError.failed(code: result.status, message: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func blockingProcesses(_ mountPoint: URL, timeout: Duration) async -> [String] {
        let me = getpid()
        var names: [String] = []
        for h in await holders(mountPoint, timeout: timeout) where h.pid != me && !names.contains(h.command) {
            names.append(h.command)
        }
        return names
    }

    func onlyOwnProcessHolds(_ mountPoint: URL, timeout: Duration) async -> Bool {
        let me = getpid()
        let h = await holders(mountPoint, timeout: timeout)
        return h.contains { $0.pid == me } && h.allSatisfy { $0.pid == me }
    }

    private func holders(_ mountPoint: URL, timeout: Duration) async -> [Holder] {
        guard isInside(mountPoint) else { return [] }
        let path = mountPoint.standardizedFileURL.path
        let out = try? await lanes.perform(on: lane(mountPoint), .fileOp) { lane in
            Self.runTool("/usr/sbin/lsof", ["-F", "pc", "--", path], timeout: timeout, lane: lane)
        }
        return Self.parseLsof(out?.output ?? "")
    }

    /// `lsof -F pc` output: "p<pid>" then "c<command>" lines (other field lines ignored).
    static func parseLsof(_ output: String) -> [Holder] {
        var out: [Holder] = []
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            else if line.hasPrefix("c"), let p = pid { out.append(Holder(pid: p, command: String(line.dropFirst()))) }
        }
        return out
    }

    final class OutputBox: Sendable {
        let data = Mutex(Data())
    }

    /// Lane only. Runs a tool, heartbeating while it runs; terminates it after `timeout` (status ETIMEDOUT).
    static func runTool(_ tool: String, _ arguments: [String], timeout: Duration, lane: LaneContext) -> (status: Int32, output: String) {
        assertOffMain()
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let box = OutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            box.data.withLock { $0.append(chunk) }
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (ENOENT, "")
        }
        let deadline = ContinuousClock.now + timeout
        var timedOut = false
        while process.isRunning {
            lane.heartbeat()
            if ContinuousClock.now > deadline { timedOut = true; process.terminate(); break }
            usleep(20_000)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        let data = box.data.withLock { $0 } + rest
        return (timedOut ? ETIMEDOUT : process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
```

- [ ] **Step 8: Implement `CoreEnvironment.swift`**

```swift
import Foundation
import MacxFS

/// Every Core service, wired once per app (or per test/scenario sandbox). §3.12.
@MainActor
public final class CoreEnvironment {
    public let statePaths: StatePaths
    public let lanes: LanePool
    public let types: TypeRegistry
    public let readers: DirectoryReaders
    public let volumes: Volumes
    public let settings: Settings
    public let changeBus: ChangeBus
    public let clipboard: Clipboard
    public let launchServices: LaunchServicesCache
    public let ejectCoordinator: EjectCoordinator
    public let journal: Journal
    public let trash: any TrashService
    public let interaction: InteractionProxy
    public let fileOps: FileOpQueue
    public let undo: FileOpUndoStack
    public let operations: OperationsCenter
    public let termination: TerminationCoordinator

    /// Undo action names ("Copy", "Move"…) are user-visible text, which Core never produces: the app installs a
    /// localized formatter at launch (P1-26). Default: the verb's raw value ("copying").
    public var undoActionName: @MainActor (JobDescription) -> String {
        get { actionNamer.format }
        set { actionNamer.format = newValue }
    }

    @MainActor final class ActionNamer {
        var format: @MainActor (JobDescription) -> String = { $0.verb.rawValue }
    }

    private let actionNamer: ActionNamer
    private var tokens: [ObserverToken] = []
    private var startTask: Task<RecoveryReport, Never>?

    public convenience init(statePaths: StatePaths, lanes: LanePool, settingsStorage: any SettingsStorage,
                            volumeScanner: any VolumeScanning, volumeEvents: (any VolumeEventSource)?,
                            pasteboard: any PasteboardBackend, launchServices: any LaunchServicesProviding,
                            ejector: any Ejecting, trash: any TrashService, fileOpTuning: FileOpTuning = FileOpTuning()) {
        self.init(statePaths: statePaths, lanes: lanes, settingsStorage: settingsStorage, volumeScanner: volumeScanner,
                  volumeEvents: volumeEvents, pasteboard: pasteboard, launchServices: launchServices, ejector: ejector,
                  trash: trash, fileOpTuning: fileOpTuning, home: FileManager.default.homeDirectoryForCurrentUser,
                  interactionTarget: nil)
    }

    init(statePaths: StatePaths, lanes: LanePool, settingsStorage: any SettingsStorage,
         volumeScanner: any VolumeScanning, volumeEvents: (any VolumeEventSource)?,
         pasteboard: any PasteboardBackend, launchServices provider: any LaunchServicesProviding,
         ejector: any Ejecting, trash: any TrashService, fileOpTuning: FileOpTuning,
         home: URL, interactionTarget: (any FileOpInteraction)?) {
        self.statePaths = statePaths
        self.lanes = lanes
        self.types = .shared
        let volumes = Volumes(lanes: lanes, scanner: volumeScanner, events: volumeEvents)
        self.volumes = volumes
        let readers = DirectoryReaders(lanes: lanes, mountTable: volumes.mountTableStore, types: .shared)
        self.readers = readers
        self.settings = Settings(storage: settingsStorage, home: home)
        let bus = ChangeBus()
        self.changeBus = bus
        self.clipboard = Clipboard(backend: pasteboard)
        self.launchServices = LaunchServicesCache(provider: provider, types: .shared)
        self.ejectCoordinator = EjectCoordinator(volumes: volumes, ejector: ejector)
        let journal = Journal(fileURL: statePaths.journal)
        self.journal = journal
        self.trash = trash
        let interaction = InteractionProxy()
        if let interactionTarget { interaction.setTarget(interactionTarget) }
        self.interaction = interaction
        let queue = FileOpQueue(lanes: lanes, trash: trash, journal: journal, interaction: interaction,
                                tuning: fileOpTuning, startsHeld: true)
        self.fileOps = queue
        let undo = FileOpUndoStack(queue: queue)
        self.undo = undo
        let namer = ActionNamer()
        self.actionNamer = namer
        let operations = OperationsCenter(queue: queue, undo: undo, changeBus: bus, actionName: { namer.format($0) })
        self.operations = operations
        self.termination = TerminationCoordinator(queue: queue, operations: operations)

        // §4.2 release (S1 contract note 15): cancel this volume's reads first, then pause the jobs touching it.
        // Watchers stop through FolderModel's volume-gone path (P1-11); windows move home in WindowManager (P1-26).
        tokens.append(volumes.addReleaseHandler { [weak volumes] id in
            await readers.cancelAll(on: id)
            if let mountPoint = volumes?.list.first(where: { $0.id == id })?.mountPoint {
                _ = await queue.suspendJobs(touching: mountPoint)
            }
        })
    }

    public func folderContext() -> FolderContext {
        let settings = self.settings, volumes = self.volumes
        return FolderContext(
            readers: readers, lanes: lanes, volumes: volumes, changeBus: changeBus, types: types,
            pacer: TimerFramePacer(),
            makeWatcher: { directory, since, handler in Watcher(directory: directory, since: since, handler: handler) },
            permissionPending: { url in
                guard let location = Self.protectedLocation(url, settings: settings, volumes: volumes) else { return false }
                return settings.tccOutcome(for: location) == nil
            },
            recordPermissionOutcome: { url, granted in
                guard let location = Self.protectedLocation(url, settings: settings, volumes: volumes) else { return }
                settings.recordTCCOutcome(granted ? .granted : .denied, for: location)
            })
    }

    static func protectedLocation(_ url: URL, settings: Settings, volumes: Volumes) -> ProtectedLocation? {
        ProtectedLocations.classify(url, home: settings.home, volume: volumes.volume(for: url))
    }

    public func makeFolderModel(_ directory: URL, query: ViewQuery? = nil) -> FolderModel {
        FolderModel(directory: directory, context: folderContext(), query: query ?? settings.viewQuery())
    }

    /// Idempotent. Launch recovery first (§6.3: partials removed, trashed destinations restored, incomplete jobs
    /// reported), then jobs may run, then the operations consumer and the volume list start.
    public func start() async -> RecoveryReport {
        if let startTask { return await startTask.value }
        let journal = self.journal, lanes = self.lanes, queue = fileOps, operations = self.operations, volumes = self.volumes
        let task = Task { () -> RecoveryReport in
            let report = await LaunchRecovery.run(journal: journal, lanes: lanes)
            operations.start()
            await queue.releaseHold()
            await volumes.start()
            return report
        }
        startTask = task
        return await task.value
    }

    // MARK: sandbox

    nonisolated static let sandboxPrefixes = ["macx-tests-", "macx-bench-", "macx-scenario-", "macx-fixtures-"]

    /// "/private/var/…" and "/var/…" (and /tmp) name the same place; compare one spelling. Pure string work.
    nonisolated static func canonicalTempPath(_ path: String) -> String {
        for p in ["/private/var/", "/private/tmp/"] where path.hasPrefix(p) { return String(path.dropFirst("/private".count)) }
        return path
    }

    /// Pure: a `macx-*-<something>` directory somewhere inside the temporary directory (no file-system call).
    nonisolated static func isSandboxRoot(_ url: URL) -> Bool {
        let path = canonicalTempPath(url.standardizedFileURL.path)
        var tmp = canonicalTempPath(FileManager.default.temporaryDirectory.standardizedFileURL.path)
        if !tmp.hasSuffix("/") { tmp += "/" }
        guard path.hasPrefix(tmp), path.count > tmp.count else { return false }
        let name = (path as NSString).lastPathComponent
        return sandboxPrefixes.contains { name.hasPrefix($0) && name.count > $0.count }
    }

    /// Test/scenario factory (§3.12). Everything lives inside `root`; nothing is written until used.
    public static func sandboxed(root: URL) -> CoreEnvironment {
        precondition(isSandboxRoot(root), "CoreEnvironment.sandboxed requires a macx-* sandbox root in the temporary directory, got \(root.path)")
        let base = root.standardizedFileURL
        let lanes = LanePool()
        return CoreEnvironment(
            statePaths: StatePaths(root: base.appending(path: "state", directoryHint: .isDirectory)),
            lanes: lanes, settingsStorage: InMemorySettingsStorage(), volumeScanner: SystemVolumeScanner(),
            volumeEvents: nil, pasteboard: InMemoryPasteboard(), launchServices: FakeLaunchServices(),
            ejector: SandboxEjector(root: base, lanes: lanes),
            trash: SandboxTrash(directory: base.appending(path: ".trash", directoryHint: .isDirectory)),
            fileOpTuning: FileOpTuning(), home: base, interactionTarget: ScriptedInteraction())
    }
}
```

Notes for the executor:
- If the compiler rejects the convenience initializer's exact contract signature next to the designated one (the label `launchServices` is shared), keep the public one exactly as in §3.12 and rename only the internal init's label (e.g. `launchServicesProvider:`).
- The release handler captures `readers` and `queue` (both `Sendable`) and `volumes` weakly (the handler is stored inside `volumes`).
- `FolderContext.types` defaults to `.shared` and `pacer` to `TimerFramePacer()`; both are passed explicitly here so the environment is the one place that decides.

- [ ] **Step 9: Run the tests and see them pass**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, no warnings.
Run: `swift test --filter 'CoreTests.(OperationsCenterTests|TerminationTests|EnvironmentTests|SandboxEjectorTests|QueueTests)' 2>&1 | tail -5`
Expected: `Executed 31 tests, with 0 failures` (9 center + 3 termination + 6 environment + 2 ejector + 11 queue; the release, ejector and disjoint-volume image tests are skipped without hdiutil).

- [ ] **Step 10: Run the whole Core suite and the full parallel run**

Run: `swift test --filter CoreTests 2>&1 | tail -3`
Expected: `with 0 failures`.
Run: `swift test --parallel 2>&1 | tail -3`
Expected: no failures. The FileOps tests use per-test sandboxes, journals and `LanePool`s, so they are parallel-safe. `swift test --parallel` reports per-suite results rather than one `Executed N tests` line.

- [ ] **Step 11: Verify the safety rule held**

Run: `ls -d "${TMPDIR}"macx-tests-* 2>/dev/null | wc -l`
Expected: `0` (every sandbox was destroyed in teardown).
Run: `hdiutil info | grep -c "${TMPDIR%/}" || true`
Expected: `0` (no test image left attached).

- [ ] **Step 12: Commit**

```bash
git add Sources/Core/FileOps Sources/Core/Support Tests/CoreTests
git commit -m "feat: operations center, termination coordinator and core environment with sandboxed factory"
```

---

## Spec coverage (this slice)

| Spec | Covered by |
|---|---|
| §6.1 job kinds, plan/execute, volume-set scheduling, 10 Hz progress, pause/cancel | P1-18 `QueueTests`, `PlannerTests`; every job-kind suite P1-19 … P1-24 |
| §6.1 per-item records for undo and journal | P1-17 `testRecordUndoability`; record assertions in every job suite; P1-24 `UndoTests` |
| §6.2 throughput samples, ETA, < 1 s jobs show nothing, overall % | P1-17 `testThroughputMeterKeeps60SamplesAndEstimates`; P1-25 `testJobsBecomeVisibleOnlyAfterTheRevealDelay`, `testOverallFraction…` |
| §6.3 rename primitive, case-only, two-step + journal | P1-19 `RenameTests` |
| §6.3 copy (copyfile flags, clone accounting, two-pass directories, symlinks) | P1-20 `CopyTests` (Review Focus 2, 4) |
| §6.3 cross-volume move partial → verify → rename → delete; journal; launch cleanup | P1-21 `MoveTests`, `CrashRecoveryTests` (Review Focus 3); P1-25 `testStartRunsLaunchRecoveryBeforeAnyJobRuns` |
| §6.3/§6.4 conflicts: Replace (trash, restore), Merge, Keep Both, apply-to-all, Compare | P1-22 `ConflictTests`, `testKillAfterTrashingDestinationRestoresIt` |
| §6.3 trash (no-trash fallback), delete permanently, alias, symlink | P1-23 `TrashDeleteTests` |
| §5.8 Properties edits, chmodRecursive | P1-23 `testSetAttributes…`, `testChmodRecursive…` |
| §6.5 error table, free-space dialog, errors affect only their item | P1-17 `testAllowedResolutionsMatchSpecTable`; P1-18 `testInsufficientSpacePromptsBeforeExecution`; P1-23 `ErrorTableTests` |
| §6.6 inverse table row by row | P1-24 `testStepsInvertEveryActionInReverseOrder` + one test per row (copy, move same/cross volume, rename, trash, new, replace, merge, chmod, attributes, alias/symlink) |
| §6.6 identity checks, skipped summary, occupied path → conflict, partial jobs | P1-24 `testUndoSkipsItems…`, `testUndoIntoOccupiedPath…` (Review Focus 5), `testPartlyCompletedJob…`, `testUndoChmodSkips…` |
| §6.6 one app-wide UndoManager, entry on completion, redo, field-editor managers | P1-24 `UndoStackTests`; P1-25 `testPerformRegistersTheUndoEntry…`, end-to-end test |
| §6.7 Stop and Quit, 10 s timeout | P1-25 `TerminationTests` |
| §4.2 release pauses jobs | P1-25 `testVolumeReleasePausesQueuedJobsTouchingThatVolume`; P1-25 queue `/` test |
| §4.3 FileOps posts the paths it changed | P1-25 `testFinishedJobPostsItsLocalChanges…`, end-to-end test |
| §9 CoreTests: images (EROFS, ENOSPC, exFAT case-only, cross-volume kill) | P1-19, P1-21, P1-22, P1-23 image tests |
| Safety HARD RULE | `FileOpsTestCase.run` / `FileOpsWorld.request` guards; `CoreEnvironment.isSandboxRoot`; `SandboxEjector.isInside`; P1-25 Step 11 |

## Contract notes

Gaps or deviations found while writing this slice. The overview was not edited (this slice commits only its own file). The architect should fold these into overview §3.

1. **MacxFixtures is not in overview §3.** This slice uses S1's P1-02 names exactly: `Sandbox(prefix:)`, `root`, `url(_:)`, `createDirectory(_:)`, `createFile(_:contents:)`, `destroy()`, `DiskImageFormat`, `DiskImage.create(in:format:sizeMB:volumeName:readOnly:populate:)`, `mountPoint`, `detach()`, `isAvailable`. They are all reached through `FileOpsTestSupport.swift`. An earlier draft of P1-17 used `makeFile`/`makeDirectory`/`remove()`/`DiskImage.Format`; that draft was corrected in this file. Tests write into mounted images with `Data.write` on `mountPoint` paths, which `DiskImage` mounted inside the sandbox. S1 also offers `relativeMountPath` for sandbox-guarded writes.
2. **`JobDescription` is `Codable` with a public memberwise init** (additive), because `JournalEntry.jobStarted` stores it and `RecoveryReport.incompleteJobs` returns it. Also additive: public memberwise inits of `AttributeSnapshot`, `JobRecord`, `SkippedItem`, `JobOutcome`, `JobSnapshot`, `RecoveryReport()`; `JobID.short`; `JournalEntry.job`; `ScriptedInteraction.askedSpace()/askedNoTrash()`; `SandboxTrash(directory:refusingPathsUnder:)`.
3. **`FileOpQueue.registersUndo(_ id: JobID) -> Bool`** (additive, public). `OperationsCenter` needs to know whether a finished job asked for an undo entry, also for jobs enqueued on the queue directly (S5/S6 code does both).
4. **Internal test knobs on `FileOpTuning`** (`allowClone`, `forceCrossVolume`, `bodyOverride`), reached with `@testable import Core`. The public init is exactly the contract's.
5. **Trash plans `.shallow`.** §6.1 says the plan phase enumerates sources recursively with `fts`. Trash is a rename, so enumerating a large tree first would only slow it down. Trash checks existence and identity only. Delete and chmodRecursive enumerate under `withNoMaterialization` (§4.2).
6. **The queue starts held in `CoreEnvironment`** (internal `FileOpQueue.init(…, startsHeld:)` and `releaseHold()`). `LaunchRecovery` removes journaled partials, so no job of the new session may write the journal before it ran. `CoreEnvironment.start()` must be awaited at launch (S4 `AppBootstrap`, P1-26). A job enqueued earlier waits in `.queued`; quitting before `start()` still works, because cancel of an unstarted job finishes it at once.
7. **`CoreEnvironment.undoActionName`** (additive, public, settable). The contract's `OperationsCenter(actionName:)` needs a formatter, but `CoreEnvironment.init` has no parameter for one, and Core never produces user-visible text. The default is the verb's raw value (`"copying"`). **S4 must set a localized formatter at launch** (e.g. `environment.undoActionName = { L10n.undoName($0) }`), or the Edit menu shows "Undo copying".
8. **`sandboxed(root:)` details.** It traps unless `root`'s last component is `macx-tests-`/`macx-bench-`/`macx-scenario-`/`macx-fixtures-` + something, somewhere inside `$TMPDIR` (both `/var` and `/private/var` spellings accepted; pure string check). It sets `Settings.home = root`, so default favorites, protected-location classification and the "go home" fallbacks (S5 `FileCommandController`, volume-gone relocation) stay inside the sandbox. Its ejector is the internal `SandboxEjector` in a new file `Sources/Core/Support/SandboxEjector.swift` (not in overview §2's file map; it keeps `CoreEnvironment.swift` under ~300 lines). The ejector refuses mount points outside the root before running `hdiutil` or `lsof`. The default interaction target is `ScriptedInteraction()`.
9. **`UndoManager` does not retain registration targets.** Verified: `undo()` on an entry whose target was released traps (`Could not cast value of type '__NSDictionaryM'`). `FileOpUndoStack` keeps one small `Chain` object per registered job for the session.
10. **`FileOpUndoStack.undoManager.groupsByEvent == false`.** Each job is one explicit group, so registration works without a run loop closing event groups (XCTest, `macx-scenarios`, jobs that finish outside any event). UI code must not call `beginUndoGrouping()` on it. Field-editor managers from `makeFieldEditorUndoManager()` keep the default `groupsByEvent = true`.
11. **Undo skip reasons reuse existing kinds.** An item that has gone is `SkippedItem(reason: .sourceGone)`. An item that changed since the job (other identity, or a mode/attribute that no longer has the value the job set) is `.changedDuringMove`. A conflict skipped at an occupied original path has `reason: nil`. P1-38's summary should word `.changedDuringMove` in `.undoing`/`.redoing` jobs as "changed since the operation". A dedicated `FileOpErrorKind.changedSinceOperation` would be clearer in a later contract revision.
12. **Undo conflicts.** Merge is answered as Keep Both: undo moves one item back and doesn't merge trees. Replace trashes the occupant and records it as `.replaced`, so redo puts it back.
13. **Redo is the inverse of the undo job's record**, not a re-run of the original request. For example, redo of a copy moves the copy back from the Trash. Alias/symlink undo removes the link permanently (§6.6 "remove"), so that undo record holds `.deleted` and has no redo. An inverse job whose record is empty (everything skipped) or not undoable removes its entry from both stacks, so the menu never offers a no-op.
14. **Undo re-creates missing parent folders** (a merge-move removes emptied source folders, §6.3) with default metadata and records them as `.createdDirectory`. This is the only producer of that action in Phase 1. Its inverse removes the folder only once empty, silently otherwise.
15. **`OperationsCenter.perform` returns after the center processed the finish**: changes posted, undo entry registered, observers called. `queue.outcome(of:)` can return earlier. UI and scenario code that checks `canUndo` or the folder right after a job should use `perform`. `perform` calls `start()` itself.
16. **`ChangeBus` key normalization (S2).** `LocalChange.directory` is built as `URL(filePath: <standardized path>, directoryHint: .isDirectory)` (trailing slash). Observers register with whatever URL the folder has (usually no trailing slash, sometimes `/private/var` vs `/var`). `ChangeBus` must compare by standardized path without the trailing slash. P1-25's end-to-end test fails otherwise.
17. **`suspendJobs(touching:)` fix**: the prefix test now handles the `/` mount point (P1-18 compared against `"//"`).
18. **Stop and Quit with an open dialog.** A job suspended in `FileOpInteraction` can't finish its cancel until the question is answered, so `stopAllAndWait` returns `false` at the timeout (tested). P1-30's quit flow and P1-38's `InteractionRouter` should answer pending questions with `.cancel`/`.cancelJob`/`false` when Stop and Quit starts, so the cancel path (partials removed, journal updated) completes before the 10 s timeout.
19. **`visibleJobs`** reveals a job `revealDelay` (1 s) after it was added, queued or running, unless it finished first. `waitingForUser` jobs are visible at once.
20. **Swift 6 test isolation.** `@MainActor` test classes can't call the `FileOpsTestCase` base class's `async` helpers: under region isolation the call sends the non-`Sendable` test case off the main actor (verified error: `sending value of non-Sendable type … risks causing data races`). They use the `Sendable` `FileOpsWorld` view (`world`), whose `request(_:)` traps before enqueueing any URL outside the sandbox. S5/S6 harnesses that subclass `XCTestCase` under `@MainActor` hit the same rule.
