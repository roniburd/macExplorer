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
        // The delay passes when the test says so, not when a (possibly starved) runner's clock does.
        let delayPassed = Gate(), delays = EventLog()
        center.revealDelay = .milliseconds(300)
        center.revealSleep = { delays.add("\($0)"); await delayPassed.wait() }
        await queue.enqueue(w.request(.copy(sources: [try w.file("a")], destination: try w.dir("d"))))
        await w.waitUntil { @MainActor in center.jobs.count == 1 }
        XCTAssertEqual(center.visibleJobs.count, 0, "jobs that finish in under 1 s show nothing (§6.2)")
        await w.waitUntil { delays.all.count == 1 }
        XCTAssertEqual(delays.all, ["\(Duration.milliseconds(300))"], "waits out revealDelay")
        XCTAssertEqual(center.visibleJobs.count, 0, "still hidden while the delay runs")
        delayPassed.open()
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
        let k = JobProgress.itemCost
        XCTAssertEqual(OperationsCenter.overallFraction(of: [snap(items: (1, 4), bytes: (0, 0)),
                                                             snap(items: (1, 1), bytes: (2 * k, 4 * k)),
                                                             snap(items: (0, nil), bytes: (0, nil))])!,
                       Double(1 * k + 1 * k + 2 * k) / Double(4 * k + 1 * k + 4 * k), accuracy: 1e-9,
                       "weighted by each job's work (items × itemCost + bytes)")
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
        // The dialog is never answered during the call, so returning (false) at all proves it gave up at the
        // timeout; no wall-clock bound, which a stalled main actor on a loaded runner could exceed.
        let stopped = await termination.stopAllAndWait(timeout: .milliseconds(300))
        XCTAssertFalse(stopped, "§6.7: quit anyway after the timeout; launch cleanup uses the journal")
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
                                  trash: SandboxTrash(directory: w.trashDir), fileOpTuning: tuning, searchServices: .fake())
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

    func testVolumeReleaseReportsRunningJobsTouchingThatVolume() async throws {
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
                                  trash: SandboxTrash(directory: w.trashDir), fileOpTuning: tuning, searchServices: .fake())
        _ = await env.start()
        await env.volumes.refresh()
        let volume = try XCTUnwrap(env.volumes.volume(for: mnt))
        let queue = env.fileOps
        let local = try w.file("files/a")
        let writing = await queue.enqueue(w.request(.copy(sources: [local], destination: mnt)))
        await w.waitUntil { await queue.snapshots().first { $0.id == writing }?.state == .running }
        let queried = await env.runningJobs(on: volume.id)
        XCTAssertEqual(queried, [writing], "eject can ask cancel/wait before unmounting")
        var reported: [(VolumeID, [JobID])] = []
        env.onRunningJobsOnReleasedVolume = { id, jobs in reported.append((id, jobs)) }
        await env.volumes.release(volume.id)
        XCTAssertEqual(reported.map(\.0), [volume.id])
        XCTAssertEqual(reported.map(\.1), [[writing]], "§4.2: running jobs are reported, not dropped")
        let state = await queue.snapshots().first { $0.id == writing }?.state
        XCTAssertEqual(state, .running, "a running job is left for the user's cancel/wait answer")
        gate.open()
        _ = await queue.outcome(of: writing)
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
