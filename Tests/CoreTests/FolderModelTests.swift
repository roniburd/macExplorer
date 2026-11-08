@testable import Core
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import Synchronization
import XCTest

/// FolderModel (§4.3) against real sandbox folders and scripted reads.
@MainActor
final class FolderModelTests: XCTestCase {
    private let nameVolume = VolumeCapabilities(idStable: false, renameExcl: false, clone: false, caseSensitive: false)

    // MARK: opening

    func testOpensFolderSortedFoldersFirstAndCompletes() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("f")
        for name in ["b.txt", "a.txt", "C.txt", "file10", "file9"] { try w.file("f/" + name) }
        try w.dir("f/zeta")
        let m = w.model(w.url("f"))
        let log = FolderEventLog(m)
        XCTAssertEqual(m.state, .loading)
        m.start()
        try await w.waitUntil("complete") { m.state == .complete }
        XCTAssertEqual(m.rowNames, ["zeta", "a.txt", "b.txt", "C.txt", "file9", "file10"])
        XCTAssertEqual(log.states.last, .complete)
        XCTAssertEqual(log.changeSets.last, .reset, "the final listing is one reset")
        XCTAssertGreaterThan(m.generation, .initial)
        XCTAssertEqual(m.volume?.id, VolumeID(raw: "test-root"))
        XCTAssertFalse(m.caseSensitive)
        XCTAssertEqual(m.url(atRow: 0).lastPathComponent, "zeta")
        XCTAssertTrue(m.url(atRow: 0).hasDirectoryPath)
        XCTAssertEqual(m.url(atRow: 1), w.url("f/a.txt"))
        XCTAssertEqual(m.entry(atRow: 0).kind, .directory)
        XCTAssertEqual(m.row(named: "B.TXT"), 2, "case-insensitive volume")
        XCTAssertEqual(m.row(of: m.identity(atRow: 3)), 3)
        XCTAssertNil(m.errno(atRow: 1))
    }

    func testSmallFolderLoadsWithExactlyOneResetAndNoPartialState() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("s")
        for name in ["1", "2", "3"] { try w.file("s/" + name) }
        w.pacer = ManualFramePacer()             // no frame elapses before the read completes
        let m = w.model(w.url("s"))
        let log = FolderEventLog(m)
        m.start()
        try await w.waitUntil("complete") { m.state == .complete }
        await w.settle()
        XCTAssertEqual(log.resets, 1)
        XCTAssertEqual(log.states, [.complete])
    }

    func testEmptyFolderCompletes() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("empty")
        let m = try await w.open("empty")
        XCTAssertEqual(m.rowCount, 0)
    }

    func testHiddenRowsNeedShowHiddenAndSetQueryResortsWithOneReset() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("h")
        for name in ["a.txt", "b.txt", ".env", "notes.txt"] { try w.file("h/" + name) }
        try w.setHidden("h/notes.txt")
        let m = try await w.open("h")
        XCTAssertEqual(m.rowNames, ["a.txt", "b.txt"])
        m.select(.names(["b.txt"]))
        let log = FolderEventLog(m)
        m.setQuery(ViewQuery(showHidden: true))
        XCTAssertEqual(m.query.showHidden, true)
        try await w.waitUntil("re-sorted") { m.rowCount == 4 }
        XCTAssertEqual(m.rowNames, [".env", "a.txt", "b.txt", "notes.txt"])
        XCTAssertEqual(log.changeSets, [.reset])
        XCTAssertEqual(log.queries, [ViewQuery(showHidden: true)])
        XCTAssertEqual(m.selectedNames, ["b.txt"], "selection kept by identity")
        XCTAssertEqual(m.selection.rows, IndexSet([2]))

        log.clear()
        m.setQuery(ViewQuery(sort: SortDescriptor(field: .name, ascending: false), showHidden: true))
        try await w.waitUntil("descending") { m.rowNames.first == "notes.txt" }
        XCTAssertEqual(m.rowNames, ["notes.txt", "b.txt", "a.txt", ".env"])
        XCTAssertEqual(m.selection.rows, IndexSet([1]))
        XCTAssertEqual(log.resets, 1)
        m.setQuery(m.query)
        await w.settle()
        XCTAssertEqual(log.resets, 1, "same query: nothing to do")
    }

    func testFilterQuery() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("q")
        for name in ["Résumé.txt", "report.pdf", "photo.jpg"] { try w.file("q/" + name) }
        let m = try await w.open("q")
        m.setQuery(ViewQuery(filter: "RESU"))
        try await w.waitUntil("filtered") { m.rowCount == 1 }
        XCTAssertEqual(m.rowNames, ["Résumé.txt"])
        m.setQuery(ViewQuery(filter: ""))
        try await w.waitUntil("unfiltered") { m.rowCount == 3 }
    }

    /// P3-01: ViewQuery.criteria (kind/extension filters, name globs) filters the folder in memory.
    func testCriteriaQuery() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("c")
        for name in ["IMG_0001.png", "IMG_0002.jpg", "notes.txt", "report.pdf"] { try w.file("c/" + name) }
        try w.dir("c/Images")
        let m = try await w.open("c")
        m.setQuery(ViewQuery(criteria: SearchCriteria(kinds: [.image])))
        try await w.waitUntil("images") { m.rowCount == 2 }
        XCTAssertEqual(m.rowNames, ["IMG_0001.png", "IMG_0002.jpg"])
        m.setQuery(ViewQuery(criteria: SearchCriteria(nameTerms: [NameTerm("img_*.PNG")])))
        try await w.waitUntil("glob") { m.rowNames == ["IMG_0001.png"] }
        m.setQuery(ViewQuery(filter: "o", criteria: SearchCriteria(extensions: ["pdf", "txt"])))
        try await w.waitUntil("extensions and filter") { m.rowNames == ["notes.txt", "report.pdf"] }
        m.setQuery(ViewQuery())
        try await w.waitUntil("cleared") { m.rowCount == 5 }
    }

    // MARK: Review Focus 2

    /// Overview Review Focus 2: the duplicate check uses the whole EntryStore, hidden rows included.
    func testValidateNameSeesHiddenEntries() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("r")
        for name in ["a.txt", "notes.txt", ".env"] { try w.file("r/" + name) }
        try w.dir("r/v1.2")
        try w.setHidden("r/notes.txt")
        let m = try await w.open("r")
        XCTAssertNil(m.row(of: .name("x")))
        XCTAssertEqual(m.rowNames, ["v1.2", "a.txt"], "Show Hidden is off")
        let a = try XCTUnwrap(m.row(named: "a.txt"))
        XCTAssertEqual(m.validateName("notes.txt", renamingRow: a), .invalid(.duplicate))
        XCTAssertEqual(m.validateName(".env", renamingRow: a), .invalid(.duplicate))
        XCTAssertEqual(m.validateName("NOTES.TXT", renamingRow: a), .invalid(.duplicate))
        XCTAssertEqual(m.validateName("notes.txt", renamingRow: nil), .invalid(.duplicate), "new item")
        XCTAssertEqual(m.validateName("A.TXT", renamingRow: a), .ok(warnings: []), "case-only change of the item itself")
        XCTAssertEqual(m.validateName("b.txt", renamingRow: a), .ok(warnings: []))
        XCTAssertEqual(m.validateName("b.md", renamingRow: a), .ok(warnings: [.extensionChanged(from: "txt", to: "md")]))
        let folder = try XCTUnwrap(m.row(named: "v1.2"))
        XCTAssertEqual(m.validateName("v1.3", renamingRow: folder), .ok(warnings: []), "folders have no extension to change")
        XCTAssertEqual(m.validateName("", renamingRow: a), .invalid(.empty))
    }

    // MARK: Review Focus 3

    /// Overview Review Focus 3: open a large folder and, while its listing still streams, open a 3-item folder 20
    /// times. Nothing from the old reads reaches the newer models, the big listing never completes into its closed
    /// model, its read stream is cancelled, and the final rows are the 3 items. The big read is scripted so it is
    /// known to be in progress when the model closes (a real 100k read could finish first: CI, beta.14), and it
    /// answers late with more rows and `.completed`. testClosingAModelCancelsItsLaneRead covers the real reader.
    func testRapidNavigationDropsStaleGenerations() async throws {
        let w = try await FolderTestWorld.make(self)
        let pacer = ManualFramePacer()
        w.pacer = pacer
        try w.dir("big")
        try w.dir("small")
        for name in ["x", "y", "z"] { try w.file("small/" + name) }

        let reads = ScriptedReads()
        let big = w.model(w.url("big"))
        let bigLog = FolderEventLog(big)
        big.readSource = reads.source()
        big.start()
        try await w.waitUntil("big read started") { reads.reads.count == 1 }
        let bigRead = reads.last
        let bigReadEnded = Mutex(false)
        bigRead.continuation.onTermination = { _ in bigReadEnded.withLock { $0 = true } }
        bigRead.continuation.yield(.batch(TestBatch.files(bigRead.generation, (0..<1_000).map { "b\($0)" })))
        try await w.waitUntilAsync("first big batch ingested") {
            await big.worker.loadingEntryCount(bigRead.generation) == 1_000
        }
        try await w.waitUntil("pacer waiting") { pacer.waiting > 0 }
        pacer.tick()
        try await w.waitUntil("big streaming") { big.state == .partial }

        var previous = big
        var logs: [FolderEventLog] = []
        var current = big
        for _ in 0..<20 {
            previous.close()
            current = w.model(w.url("small"))
            logs.append(FolderEventLog(current))
            current.start()
            previous = current
        }
        let closedBigEvents = bigLog.events.count
        // The big read answers after the close, as a slow volume would.
        bigRead.continuation.yield(.batch(TestBatch.files(bigRead.generation, (0..<1_000).map { "c\($0)" }, firstID: 10_000)))
        bigRead.continuation.yield(.completed(ReadSummary(entryCount: 2_000, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("small complete") { current.state == .complete }
        try await w.waitUntil("big read stream cancelled") { bigReadEnded.withLock { $0 } }
        await w.settle(.milliseconds(200))
        XCTAssertEqual(current.rowNames, ["x", "y", "z"])
        XCTAssertEqual(bigLog.events.count, closedBigEvents, "a closed model emits nothing")
        XCTAssertEqual(big.state, .partial, "the big read never completed into the closed model")
        XCTAssertEqual(big.rowCount, 1_000, "late rows never reach the closed model")
        for log in logs.dropLast() {
            XCTAssertFalse(log.states.contains(.complete), "closed models never complete")
        }
        let reader = w.readers.reader(for: VolumeID(raw: "test-root"))
        try await w.waitUntilAsync("the small reads finished or were cancelled") { await reader.inFlightCount == 0 }
        XCTAssertEqual(logs.last?.states.last, .complete)
    }

    /// The real reader's half of Review Focus 3: closing a model whose listing is still on a lane cancels that lane
    /// read. The read emits one batch, then holds its lane (heartbeating) until it sees the cancellation.
    func testClosingAModelCancelsItsLaneRead() async throws {
        let w = try await FolderTestWorld.make(self)
        let holding = Mutex(false)
        let sawCancel = Mutex(false)
        let reader = DirectoryReader(volume: VolumeID(raw: "test-root"), lanes: w.lanes, types: .shared) { _, gen, _, _, ctx, emit in
            _ = emit(TestBatch.files(gen, ["a", "b"]))
            holding.withLock { $0 = true }
            let deadline = ContinuousClock.now + .seconds(60)        // never outlives a failed test
            while !ctx.isCancelled && ContinuousClock.now < deadline {
                ctx.heartbeat()
                usleep(1_000)
            }
            sawCancel.withLock { $0 = ctx.isCancelled }
            return ReadSummary(entryCount: 2, degradedCount: 0, usedFallback: false, elapsed: .zero)
        }
        let m = w.model(w.url(""))
        m.readSource = { directory, generation, options in
            await reader.read(directory, generation: generation, options: options)
        }
        m.start()
        try await w.waitUntil("lane read holding") { holding.withLock { $0 } }
        let running = await reader.inFlightCount
        XCTAssertEqual(running, 1, "the read is still on its lane when the model closes")
        m.close()
        try await w.waitUntilAsync("lane read ended") { await reader.inFlightCount == 0 }
        XCTAssertTrue(sawCancel.withLock { $0 }, "the lane work was cancelled, not run to the end")
        XCTAssertNotEqual(m.state, .complete)
    }

    func testStaleGenerationBatchesAreIgnored() async throws {
        let w = try await FolderTestWorld.make(self)
        let reads = ScriptedReads()
        let m = w.model(w.url(""))
        m.readSource = reads.source()
        m.start()
        try await w.waitUntil("read started") { !reads.reads.isEmpty }
        let gen = reads.last.generation
        XCTAssertEqual(gen, m.generation)
        reads.last.continuation.yield(.batch(TestBatch.files(.initial, ["stale"])))
        reads.last.continuation.yield(.batch(TestBatch.files(gen, ["fresh"], firstID: 10)))
        reads.last.continuation.yield(.completed(ReadSummary(entryCount: 1, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("complete") { m.state == .complete }
        XCTAssertEqual(m.rowNames, ["fresh"])
    }

    func testRetryAfterStallDiscardsTheOldGeneration() async throws {
        let w = try await FolderTestWorld.make(self)
        w.pacer = ManualFramePacer()             // no frame elapses between the fresh batch and .completed
        let reads = ScriptedReads()
        let m = w.model(w.url(""))
        let log = FolderEventLog(m)
        m.readSource = reads.source()
        m.start()
        try await w.waitUntil("read started") { reads.reads.count == 1 }
        let old = reads.last
        old.continuation.yield(.stalled)
        try await w.waitUntil("unresponsive") { m.state == .unresponsive }
        m.retry()
        XCTAssertEqual(m.state, .loading)
        try await w.waitUntil("second read") { reads.reads.count == 2 }
        let fresh = reads.last
        XCTAssertGreaterThan(fresh.generation, old.generation)
        XCTAssertEqual(m.generation, fresh.generation)
        // The hung read comes back late.
        old.continuation.yield(.resumed)
        old.continuation.yield(.batch(TestBatch.files(old.generation, ["late"])))
        old.continuation.yield(.completed(ReadSummary(entryCount: 1, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        await w.settle()
        XCTAssertEqual(m.state, .loading, "late results of the old generation are discarded")
        XCTAssertEqual(m.rowCount, 0)
        fresh.continuation.yield(.batch(TestBatch.files(fresh.generation, ["b", "a"], firstID: 20)))
        fresh.continuation.yield(.completed(ReadSummary(entryCount: 2, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("complete") { m.state == .complete }
        XCTAssertEqual(m.rowNames, ["a", "b"])
        XCTAssertEqual(log.states, [.unresponsive, .loading, .complete])
    }

    // MARK: loading presentation

    func testLoadingPresentsAtMostOneSortedResetPerFrameThenAFinalReset() async throws {
        let w = try await FolderTestWorld.make(self)
        let pacer = ManualFramePacer()
        w.pacer = pacer
        let reads = ScriptedReads()
        let m = w.model(w.url(""))
        let log = FolderEventLog(m)
        m.readSource = reads.source()
        m.start()
        try await w.waitUntil("read started") { !reads.reads.isEmpty }
        let r = reads.last
        r.continuation.yield(.batch(TestBatch.files(r.generation, ["m", "c", "x"], firstID: 1)))
        r.continuation.yield(.batch(TestBatch.files(r.generation, ["b", "y"], firstID: 10)))
        try await w.waitUntilAsync("both batches ingested") { await m.worker.loadingEntryCount(r.generation) == 5 }
        try await w.waitUntil("pacer waiting") { pacer.waiting > 0 }
        await w.settle()
        XCTAssertEqual(log.resets, 0, "nothing is presented between frames")
        XCTAssertEqual(m.rowCount, 0)
        pacer.tick()
        try await w.waitUntil("first frame") { log.resets == 1 }
        XCTAssertEqual(m.rowNames, ["b", "c", "m", "x", "y"], "batches merged in sorted order")
        XCTAssertEqual(m.state, .partial)
        m.select(.names(["m"]))

        r.continuation.yield(.batch(TestBatch.files(r.generation, ["a"], firstID: 20)))
        r.continuation.yield(.batch(TestBatch.files(r.generation, ["n", "d"], firstID: 30)))
        try await w.waitUntilAsync("both new batches ingested") { await m.worker.loadingEntryCount(r.generation) == 8 }
        try await w.waitUntil("pacer waiting again") { pacer.waiting > 0 }
        await w.settle()
        XCTAssertEqual(log.resets, 1)
        pacer.tick()
        try await w.waitUntil("second frame") { log.resets == 2 }
        XCTAssertEqual(m.rowNames, ["a", "b", "c", "d", "m", "n", "x", "y"])
        XCTAssertEqual(m.selectedNames, ["m"], "selection kept by identity across resets")
        XCTAssertEqual(m.selection.rows, IndexSet([4]))

        try await w.waitUntil("pacer waiting idle") { pacer.waiting > 0 }
        pacer.tick()
        await w.settle()
        XCTAssertEqual(log.resets, 2, "no new rows: no reset")

        r.continuation.yield(.batch(TestBatch.files(r.generation, ["e"], firstID: 40)))
        r.continuation.yield(.completed(ReadSummary(entryCount: 9, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("complete") { m.state == .complete }
        XCTAssertEqual(log.resets, 3, "one final reset at complete")
        XCTAssertEqual(m.rowNames, ["a", "b", "c", "d", "e", "m", "n", "x", "y"])
        XCTAssertEqual(log.states, [.partial, .complete])
    }

    // MARK: QA round 1: a busy main actor must not hold up a large listing

    func testTheReadStartsWhileTheMainActorIsStillBusy() async throws {
        let w = try await FolderTestWorld.make(self)
        let m = w.model(w.url(""))
        let started = Mutex(false)
        let (stream, continuation) = AsyncStream<ReadEvent>.makeStream()
        m.readSource = { _, _, _ in
            started.withLock { $0 = true }
            return stream
        }
        m.start()
        // Main stays busy (a navigation turn) until the read starts; the deadline only bounds a failing run.
        let deadline = ContinuousClock.now + .seconds(30)
        while !started.withLock({ $0 }) && ContinuousClock.now < deadline {}
        XCTAssertTrue(started.withLock { $0 }, "the read began without waiting for the main actor")
        continuation.finish()
    }

    func testLargeListingsPresentLessOftenThanEveryFrame() {
        XCTAssertEqual(FolderModel.loadingPresentSpacing(rows: 10), .zero)
        XCTAssertEqual(FolderModel.loadingPresentSpacing(rows: 4_999), .zero)
        XCTAssertEqual(FolderModel.loadingPresentSpacing(rows: 100_000), .milliseconds(250))
    }

    func testTheWorkerIgnoresASupersededBegin() async {
        let worker = FolderWorker(types: .shared)
        let one = Generation.initial.next(), two = one.next()
        await worker.begin(two, identityMode: .objectID, query: ViewQuery())
        await worker.begin(one, identityMode: .objectID, query: ViewQuery())
        let accepted = await worker.ingest(TestBatch.files(two, ["a"]))
        XCTAssertTrue(accepted, "the newer listing is still the one being built")
        let order = await worker.finishLoad(two, query: ViewQuery())
        XCTAssertEqual(order?.order, [0])
    }

    func testSetQueryWhileLoadingAppliesToTheNextFrame() async throws {
        let w = try await FolderTestWorld.make(self)
        let pacer = ManualFramePacer()
        w.pacer = pacer
        let reads = ScriptedReads()
        let m = w.model(w.url(""))
        let log = FolderEventLog(m)
        m.readSource = reads.source()
        m.start()
        try await w.waitUntil("read started") { !reads.reads.isEmpty }
        let r = reads.last
        r.continuation.yield(.batch(TestBatch.files(r.generation, ["a", "b", "c"])))
        try await w.waitUntilAsync("batch ingested") { await m.worker.loadingEntryCount(r.generation) == 3 }
        try await w.waitUntil("pacer waiting") { pacer.waiting > 0 }
        pacer.tick()
        try await w.waitUntil("first frame") { log.resets == 1 }
        let descending = ViewQuery(sort: SortDescriptor(field: .name, ascending: false))
        m.setQuery(descending)
        try await w.waitUntilAsync("query reached the worker") { await m.worker.loadingQuery(r.generation) == descending }
        try await w.waitUntil("pacer waiting") { pacer.waiting > 0 }
        pacer.tick()
        try await w.waitUntil("re-sorted frame") { m.rowNames == ["c", "b", "a"] }
        r.continuation.yield(.batch(TestBatch.files(r.generation, ["d"], firstID: 9)))
        r.continuation.yield(.completed(ReadSummary(entryCount: 4, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("complete") { m.state == .complete }
        XCTAssertEqual(m.rowNames, ["d", "c", "b", "a"])
    }

    // MARK: states

    func testStallThenResumeReturnsToPartial() async throws {
        let w = try await FolderTestWorld.make(self)
        let reads = ScriptedReads()
        let m = w.model(w.url(""))
        m.readSource = reads.source()
        m.start()
        try await w.waitUntil("read started") { !reads.reads.isEmpty }
        let r = reads.last
        r.continuation.yield(.batch(TestBatch.files(r.generation, ["a"])))
        try await w.waitUntil("partial") { m.state == .partial }
        r.continuation.yield(.stalled)
        try await w.waitUntil("unresponsive") { m.state == .unresponsive }
        XCTAssertEqual(m.rowNames, ["a"], "rows stay while stalled")
        r.continuation.yield(.resumed)
        try await w.waitUntil("partial again") { m.state == .partial }
        r.continuation.yield(.completed(ReadSummary(entryCount: 1, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("complete") { m.state == .complete }
    }

    func testStallBeforeAnyRowsResumesToLoading() async throws {
        let w = try await FolderTestWorld.make(self)
        let reads = ScriptedReads()
        let m = w.model(w.url(""))
        m.readSource = reads.source()
        m.start()
        try await w.waitUntil("read started") { !reads.reads.isEmpty }
        reads.last.continuation.yield(.stalled)
        try await w.waitUntil("unresponsive") { m.state == .unresponsive }
        reads.last.continuation.yield(.resumed)
        try await w.waitUntil("loading again") { m.state == .loading }
    }

    func testUnresponsiveVolumeFailureIsUnresponsiveNotAnErrno() async throws {
        let w = try await FolderTestWorld.make(self)
        let reads = ScriptedReads()
        let m = w.model(w.url(""))
        m.readSource = reads.source()
        m.start()
        try await w.waitUntil("read started") { !reads.reads.isEmpty }
        reads.last.continuation.yield(.failed(ReadFailure(code: ETIMEDOUT, stage: .unresponsiveVolume)))
        try await w.waitUntil("unresponsive") { m.state == .unresponsive }
    }

    func testReasonFromErrno() {
        XCTAssertEqual(Reason(errno: ENOENT), .notFound)
        XCTAssertEqual(Reason(errno: ENOTDIR), .notADirectory)
        XCTAssertEqual(Reason(errno: EACCES), .permissionPOSIX)
        XCTAssertEqual(Reason(errno: EPERM), .permissionTCC)
        XCTAssertEqual(Reason(errno: ENXIO), .volumeGone)
        XCTAssertEqual(Reason(errno: ENODEV), .volumeGone)
        XCTAssertEqual(Reason(errno: EIO), .other(EIO))
    }

    func testMissingFolderAndFileAreErrors() async throws {
        let w = try await FolderTestWorld.make(self)
        let missing = w.model(w.url("missing"))
        missing.start()
        try await w.waitUntil("error") { missing.state == .error(.notFound) }
        try w.file("plain.txt")
        let file = w.model(w.url("plain.txt"))
        file.start()
        try await w.waitUntil("not a directory") { file.state == .error(.notADirectory) }
    }

    func testRetryFromErrorReadsAgainWithNewGeneration() async throws {
        let w = try await FolderTestWorld.make(self)
        w.pacer = ManualFramePacer()             // no frame elapses before the one-file read completes
        let m = w.model(w.url("later"))
        let log = FolderEventLog(m)
        m.start()
        try await w.waitUntil("error") { m.state == .error(.notFound) }
        let firstGeneration = m.generation
        try w.dir("later")
        try w.file("later/a")
        m.retry()
        XCTAssertEqual(m.state, .loading)
        XCTAssertGreaterThan(m.generation, firstGeneration)
        try await w.waitUntil("complete") { m.state == .complete }
        XCTAssertEqual(m.rowNames, ["a"])
        XCTAssertEqual(log.states, [.error(.notFound), .loading, .complete])
    }

    func testPermissionPendingWaitsAndRecordsOutcome() async throws {
        let w = try await FolderTestWorld.make(self)
        w.pending = ["Desktop", "Documents"]
        let reads = ScriptedReads()
        let m = w.model(w.url("Desktop"))
        m.readSource = reads.source()
        m.start()
        try await w.waitUntil("read started") { !reads.reads.isEmpty }
        XCTAssertTrue(reads.last.options.permissionPending)
        reads.last.continuation.yield(.waitingForPermission)
        try await w.waitUntil("waiting") { m.state == .waitingForPermission }
        reads.last.continuation.yield(.resumed)
        reads.last.continuation.yield(.completed(ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("complete") { m.state == .complete }
        XCTAssertEqual(w.outcomeLog, ["Desktop:true"])

        let denied = w.model(w.url("Documents"))
        denied.readSource = reads.source()
        denied.start()
        try await w.waitUntil("second read") { reads.reads.count == 2 }
        reads.last.continuation.yield(.failed(ReadFailure(code: EPERM, stage: .open)))
        try await w.waitUntil("denied") { denied.state == .error(.permissionTCC) }
        XCTAssertEqual(w.outcomeLog, ["Desktop:true", "Documents:false"])

        let plain = w.model(w.url("other"))
        plain.readSource = reads.source()
        plain.start()
        try await w.waitUntil("third read") { reads.reads.count == 3 }
        XCTAssertFalse(reads.last.options.permissionPending)
    }

    // MARK: refresh

    func testRefreshKeepsRowsAndAppliesADiff() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("d")
        for name in ["a", "b"] { try w.file("d/" + name) }
        let m = try await w.open("d")
        m.select(.names(["b"]))
        let log = FolderEventLog(m)
        try w.remove("d/a")
        try w.file("d/c")
        let generation = m.generation
        m.refresh()
        XCTAssertEqual(m.state, .complete, "a refresh never returns a populated model to .loading")
        try await w.waitUntil("refreshed") { m.rowNames == ["b", "c"] }
        XCTAssertGreaterThan(m.generation, generation)
        XCTAssertEqual(log.states, [])
        XCTAssertFalse(log.changeSets.contains(.reset))
        XCTAssertEqual(log.changeSets.first, ChangeSet([.remove(IndexSet([0])), .insert(IndexSet([1]))]))
        XCTAssertEqual(m.selectedNames, ["b"])
        XCTAssertEqual(m.selection.rows, IndexSet([0]))
    }

    func testRefreshFromErrorRetries() async throws {
        let w = try await FolderTestWorld.make(self)
        let m = w.model(w.url("gone"))
        m.start()
        try await w.waitUntil("error") { m.state == .error(.notFound) }
        try w.dir("gone")
        m.refresh()
        try await w.waitUntil("complete") { m.state == .complete }
    }

    func testRefreshWhileAReReadIsStalledStartsANewRead() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("st")
        try w.file("st/a")
        let m = try await w.open("st")
        let reads = ScriptedReads()
        m.readSource = reads.source()
        m.refresh()
        try await w.waitUntil("re-read started") { reads.reads.count == 1 }
        let hung = reads.last
        hung.continuation.yield(.stalled)
        try await w.waitUntil("stall seen") { m.rereadStalled }
        XCTAssertEqual(m.state, .complete, "the rows on screen stay")
        m.refresh()
        try await w.waitUntil("a new re-read replaces the stalled one") { reads.reads.count == 2 }
        let fresh = reads.last
        XCTAssertGreaterThan(fresh.generation, hung.generation)
        // The stalled read answers late: ignored.
        hung.continuation.yield(.resumed)
        hung.continuation.yield(.batch(TestBatch.files(hung.generation, ["late"], firstID: 90)))
        hung.continuation.yield(.completed(ReadSummary(entryCount: 1, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        fresh.continuation.yield(.batch(TestBatch.files(fresh.generation, ["a", "b"], firstID: 80)))
        fresh.continuation.yield(.completed(ReadSummary(entryCount: 2, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("fresh result applied") { m.rowNames == ["a", "b"] }
        await w.settle()
        XCTAssertEqual(m.rowNames, ["a", "b"])
        XCTAssertEqual(m.state, .complete)
        m.refresh()
        try await w.waitUntil("not stuck: refresh reads again") { reads.reads.count == 3 }
    }

    func testRefreshWhileAReReadMakesProgressOnlyQueuesOnePending() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("pp")
        let m = try await w.open("pp")
        let reads = ScriptedReads()
        m.readSource = reads.source()
        m.refresh()
        try await w.waitUntil("re-read started") { reads.reads.count == 1 }
        reads.last.continuation.yield(.stalled)
        try await w.waitUntil("stall seen") { m.rereadStalled }
        reads.last.continuation.yield(.resumed)
        try await w.waitUntil("resume seen") { !m.rereadStalled }
        m.refresh()
        m.refresh()
        await w.settle()
        XCTAssertEqual(reads.reads.count, 1, "a read that resumed is not restarted")
    }

    func testHungItemReadDoesNotBlockAReSort() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("hs")
        for name in ["a", "b", "c"] { try w.file("hs/" + name) }
        let m = try await w.open("hs")
        let gate = HoldGate()
        defer { gate.open() }
        m.itemSource = { _, _, _ in
            await gate.wait()
            throw CancellationError()
        }
        m.applyLocalChange(LocalChange(directory: w.url("hs"), modified: ["a"]))
        try await w.waitUntil("item read issued") { gate.waiting > 0 }
        let log = FolderEventLog(m)
        m.setQuery(ViewQuery(sort: SortDescriptor(field: .name, ascending: false)))
        try await w.waitUntil("re-sorted behind a hung item read") { m.rowNames == ["c", "b", "a"] }
        XCTAssertEqual(log.changeSets, [.reset])
    }

    func testALateItemReadDoesNotOverwriteANewerOne() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("lr")
        for name in ["a", "b"] { try w.file("lr/" + name) }
        let m = try await w.open("lr")
        let gate = HoldGate()
        defer { gate.open() }
        var calls = 0
        m.itemSource = { names, _, generation in
            calls += 1
            if calls == 1 {                          // slow: answers after the newer read, with what it saw first
                await gate.wait()
                return ItemReadResult(batch: TestBatch.files(generation, names, firstID: 60), missing: [], errors: [:])
            }
            return ItemReadResult(batch: Batch(generation: generation), missing: names, errors: [:])
        }
        m.applyLocalChange(LocalChange(directory: w.url("lr"), modified: ["a", "b"]))
        try await w.waitUntil("slow read issued") { gate.waiting == 1 }
        m.applyLocalChange(LocalChange(directory: w.url("lr"), removed: ["A"]))
        try await w.waitUntil("removed") { m.rowNames == ["b"] }
        gate.open()
        try await w.waitUntil("slow read applied") { m.entry(atRow: 0).fileID == 61 }
        XCTAssertEqual(m.rowNames, ["b"], "the late answer for a is superseded; b is still applied")
    }

    // MARK: local changes

    func testLocalChangeAddsSelectsAndBeginsRename() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("n")
        try w.file("n/a.txt")
        let m = try await w.open("n")
        let log = FolderEventLog(m)
        try w.dir("n/New Folder")
        m.applyLocalChange(LocalChange(directory: w.url("n"), added: ["New Folder"], select: ["New Folder"], beginRename: "New Folder"))
        try await w.waitUntil("inserted") { m.row(named: "New Folder") != nil }
        XCTAssertEqual(m.rowNames, ["New Folder", "a.txt"])
        XCTAssertEqual(log.changeSets, [ChangeSet([.insert(IndexSet([0]))])])
        XCTAssertEqual(m.selectedNames, ["New Folder"])
        try await w.waitUntil("rename began") { !log.renames.isEmpty }
        XCTAssertEqual(log.renames, [0])
    }

    /// CPU time consumed by the calling thread (immune to time spent waiting for a core).
    private static func threadCPUTime() -> Duration {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return .seconds(Int64(ts.tv_sec)) + .nanoseconds(Int64(ts.tv_nsec))
    }

    /// QA round 1: pasting ~10k items posts 10k selections; resolving them after a patch must not be O(names × rows).
    func testTenThousandPendingSelectionsResolveQuickly() async throws {
        let w = try await FolderTestWorld.make(self)
        let reads = ScriptedReads()
        let m = w.model(w.url(""))
        m.readSource = reads.source()
        m.start()
        try await w.waitUntil("read started") { !reads.reads.isEmpty }
        let names = (0..<10_000).map { String(format: "f%05d.txt", $0) }
        reads.last.continuation.yield(.batch(TestBatch.files(reads.last.generation, names)))
        reads.last.continuation.yield(.completed(ReadSummary(entryCount: names.count, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("complete") { m.state == .complete && m.rowCount == 10_000 }
        // Thread CPU time, not wall time: both calls are synchronous on this thread, and under a loaded parallel
        // run (load average 40) wall time measured scheduling waits (9.6 s), not the work. O(names × rows) would
        // still cost seconds of CPU, so the bound keeps pinning the one-pass contract.
        m.pendingSelect = names.reversed()
        let start = Self.threadCPUTime()
        m.satisfyPending()
        let elapsed = Self.threadCPUTime() - start
        XCTAssertEqual(m.selection.count, 10_000)
        XCTAssertLessThan(elapsed, .milliseconds(250), "one pass over the store (debug build bound, CPU time)")
        let again = Self.threadCPUTime()
        m.select(.names(names))
        XCTAssertLessThan(Self.threadCPUTime() - again, .milliseconds(250), "select(.names) resolves in one pass too")
        XCTAssertEqual(m.selection.count, 10_000)
    }

    func testLocalChangeArrivesThroughTheBusWithAnySpelling() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("bus")
        let m = try await w.open("bus")
        try w.file("bus/new.txt")
        var path = w.url("bus").standardizedFileURL.path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) } else { path = "/private" + path }
        w.bus.post([LocalChange(directory: URL(filePath: path, directoryHint: .isDirectory), added: ["new.txt"], select: ["new.txt"])])
        try await w.waitUntil("posted change applied") { m.row(named: "new.txt") != nil }
        XCTAssertEqual(m.selectedNames, ["new.txt"])
        m.close()
        try w.file("bus/after-close.txt")
        w.bus.post([LocalChange(directory: w.url("bus"), added: ["after-close.txt"])])
        await w.settle()
        XCTAssertNil(m.row(named: "after-close.txt"), "a closed model drops its bus registration")
    }

    func testLocalChangeForAnotherDirectoryIsIgnored() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("one")
        try w.dir("two")
        let m = try await w.open("one")
        try w.file("one/x")
        m.applyLocalChange(LocalChange(directory: w.url("two"), added: ["x"]))
        await w.settle()
        XCTAssertEqual(m.rowCount, 0)
    }

    func testLocalChangeRemovedDropsRowAndSelection() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("rm")
        for name in ["a", "b", "c"] { try w.file("rm/" + name) }
        let m = try await w.open("rm")
        m.select(.names(["b"]))
        let log = FolderEventLog(m)
        try w.remove("rm/b")
        m.applyLocalChange(LocalChange(directory: w.url("rm"), removed: ["b"]))
        try await w.waitUntil("removed") { m.row(named: "b") == nil }
        XCTAssertEqual(m.rowNames, ["a", "c"])
        XCTAssertEqual(log.changeSets, [ChangeSet([.remove(IndexSet([1]))])])
        XCTAssertTrue(m.selection.isEmpty)
        XCTAssertEqual(log.selections.last, .empty)
    }

    func testRenameCarriesSelectionOnObjectIDVolume() async throws {
        try await assertRenameCarriesSelection(caps: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
    }

    func testRenameCarriesSelectionOnNameIdentityVolume() async throws {
        try await assertRenameCarriesSelection(caps: nameVolume)
    }

    private func assertRenameCarriesSelection(caps: VolumeCapabilities) async throws {
        let w = try await FolderTestWorld.make(self, caps: caps)
        try w.dir("mv")
        for name in ["a.txt", "b.txt"] { try w.file("mv/" + name) }
        let m = try await w.open("mv")
        m.select(.names(["a.txt"]))
        m.scrollAnchor = m.identity(atRow: 0)
        try w.rename("mv/a.txt", "mv/c.txt")
        m.applyLocalChange(LocalChange(directory: w.url("mv"), renamed: [.init(from: "a.txt", to: "c.txt")]))
        try await w.waitUntil("renamed") { m.row(named: "c.txt") != nil && m.row(named: "a.txt") == nil }
        XCTAssertEqual(m.rowNames, ["b.txt", "c.txt"])
        XCTAssertEqual(m.selectedNames, ["c.txt"], "selection follows the rename")
        XCTAssertEqual(m.scrollAnchor, m.identity(atRow: 1), "the scroll anchor follows too")
        XCTAssertEqual(m.selection.cursor, m.identity(atRow: 1))
    }

    func testAtomicSaveReplacementMovesSelectionAndAnchor() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("save")
        for name in ["a.txt", "doc.txt"] { try w.file("save/" + name) }
        let m = try await w.open("save")
        m.select(.names(["doc.txt"]))
        let oldID = m.identity(atRow: 1)
        m.scrollAnchor = oldID
        let log = FolderEventLog(m)
        try w.file("save/.doc.tmp", "new contents")
        try w.rename("save/.doc.tmp", "save/doc.txt")
        m.applyLocalChange(LocalChange(directory: w.url("save"), modified: ["doc.txt"]))
        try await w.waitUntil("replaced") { m.identity(atRow: 1) != oldID }
        XCTAssertEqual(m.rowNames, ["a.txt", "doc.txt"])
        XCTAssertEqual(log.changeSets, [ChangeSet([.reload(IndexSet([1]))])], "a replacement is a reload")
        XCTAssertEqual(m.selection.ids, [m.identity(atRow: 1)])
        XCTAssertEqual(m.scrollAnchor, m.identity(atRow: 1))
        XCTAssertEqual(m.entry(atRow: 1).size, 12)
    }

    func testLocalChangeDuringLoadingIsAppliedAfterComplete() async throws {
        let w = try await FolderTestWorld.make(self)
        let reads = ScriptedReads()
        let m = w.model(w.url(""))
        m.readSource = reads.source()
        var asked: [[String]] = []
        m.itemSource = { names, _, generation in
            asked.append(names)
            return ItemReadResult(batch: TestBatch.files(generation, ["new"], firstID: 50), missing: [], errors: [:])
        }
        m.start()
        try await w.waitUntil("read started") { !reads.reads.isEmpty }
        m.applyLocalChange(LocalChange(directory: w.url(""), added: ["new"], select: ["new"]))
        await w.settle()
        XCTAssertEqual(asked, [], "deferred until the listing completes")
        reads.last.continuation.yield(.batch(TestBatch.files(reads.last.generation, ["old"])))
        reads.last.continuation.yield(.completed(ReadSummary(entryCount: 1, degradedCount: 0, usedFallback: false, elapsed: .zero)))
        try await w.waitUntil("patched") { m.row(named: "new") != nil }
        XCTAssertEqual(asked, [["new"]])
        XCTAssertEqual(m.rowNames, ["new", "old"])
        XCTAssertEqual(m.selectedNames, ["new"])
    }

    func testItemErrorsKeepRowsAndReadItemsFailureFallsBackToFullReread() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("e")
        for name in ["a", "b"] { try w.file("e/" + name) }
        let m = try await w.open("e")
        m.itemSource = { names, _, generation in
            ItemReadResult(batch: Batch(generation: generation), missing: [], errors: Dictionary(uniqueKeysWithValues: names.map { ($0, EIO) }))
        }
        m.applyLocalChange(LocalChange(directory: w.url("e"), modified: ["a"]))
        try await w.waitUntil("errno recorded") { m.errno(atRow: 0) == EIO }
        XCTAssertEqual(m.rowNames, ["a", "b"], "a row that failed to stat is kept")

        struct Boom: Error {}
        m.itemSource = { _, _, _ in throw Boom() }
        try w.file("e/c")
        let generation = m.generation
        m.applyLocalChange(LocalChange(directory: w.url("e"), added: ["zzz-not-asked"]))
        try await w.waitUntil("full re-read") { m.row(named: "c") != nil }
        XCTAssertGreaterThan(m.generation, generation)
        XCTAssertEqual(m.state, .complete)
    }

    // MARK: selection and summary

    func testSelectionCommandsEmitAndSummaryCountsFilesFoldersBytes() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("sum")
        try w.file("sum/a", "12345")
        try w.file("sum/b", "123")
        try w.dir("sum/dir")
        try w.file("sum/dir/inner", "1234567")
        let m = try await w.open("sum")
        XCTAssertEqual(m.rowNames, ["dir", "a", "b"])
        let log = FolderEventLog(m)
        m.select(.all)
        XCTAssertEqual(m.selectionSummary, SelectionSummary(count: 3, files: 2, folders: 1, bytes: 8))
        XCTAssertEqual(m.selectedNames, ["dir", "a", "b"], "display order")
        m.select(.all)
        XCTAssertEqual(log.selections.count, 1, "an unchanged selection is not re-sent")
        m.select(.toggle(0))
        XCTAssertEqual(m.selectionSummary, SelectionSummary(count: 2, files: 2, folders: 0, bytes: 8))
        m.select(.none)
        XCTAssertEqual(m.selectionSummary, SelectionSummary(count: 0, files: 0, folders: 0, bytes: 0))
        XCTAssertEqual(log.selections.count, 3)
    }

    func testCutNamesDimRows() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("cut")
        for name in ["a", "b"] { try w.file("cut/" + name) }
        let m = try await w.open("cut")
        XCTAssertFalse(m.isCut(row: 0))
        m.cutNames = ["b"]
        XCTAssertFalse(m.isCut(row: 0))
        XCTAssertTrue(m.isCut(row: 1))
    }

    // MARK: lifecycle

    func testWatcherStartsAfterTheReadWithTheCapturedEventIDAndStopsOnClose() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("watch")
        let m = try await w.open("watch")
        let watcher = try XCTUnwrap(w.watchers.first)
        XCTAssertEqual(w.watchers.count, 1)
        XCTAssertGreaterThan(watcher.since, 0, "FSEvents ID captured before the read")
        XCTAssertEqual(watcher.events, ["start"])
        m.close()
        XCTAssertEqual(watcher.events, ["start", "stop"])
        m.close()
        XCTAssertEqual(watcher.events, ["start", "stop"], "close is idempotent")
    }

    func testCaseSensitivityFollowsTheVolume() async throws {
        let w = try await FolderTestWorld.make(self, caps: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: true))
        try w.dir("cs")
        try w.file("cs/a.txt")
        let m = try await w.open("cs")
        XCTAssertTrue(m.caseSensitive)
        XCTAssertNil(m.row(named: "A.TXT"))
        XCTAssertEqual(m.validateName("A.txt", renamingRow: 0), .ok(warnings: []))
    }

    func testNameIdentityVolumeUsesNameRowIDs() async throws {
        let w = try await FolderTestWorld.make(self, caps: nameVolume)
        try w.dir("ex")
        try w.file("ex/Read Me.TXT")
        let m = try await w.open("ex")
        XCTAssertEqual(m.identity(atRow: 0), .name("read me.txt"))
    }

    func testTimerFramePacerWaitsRoughlyItsInterval() async {
        let pacer = TimerFramePacer(interval: .milliseconds(20))
        let start = ContinuousClock.now
        await pacer.nextFrame()
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(19))
    }

    func testNoopWatcher() {
        let w = NoopWatcher()
        w.start()
        w.stop()
        XCTAssertEqual(w.lastEventID, 0)
    }
}

/// Holds callers until `open()` (a lane call that never returns while the test runs).
@MainActor
final class HoldGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    var waiting: Int { waiters.count }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let all = waiters
        waiters = []
        for c in all { c.resume() }
    }
}
