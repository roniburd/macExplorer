import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

/// Stands in for the AppKit dialogs: records what would be shown and lets the test answer.
@MainActor
private final class RecordingPresenter: DialogPresenting {
    struct Shown {
        let question: InteractionQuestion
        let job: JobID
        let window: NSWindow?
    }

    private(set) var shown: [Shown] = []
    private var open: [(id: Int, continuation: CheckedContinuation<InteractionAnswer?, Never>)] = []
    private var nextID = 0
    var openCount: Int { open.count }

    func present(_ question: InteractionQuestion, job: JobSnapshot, on window: NSWindow?) async -> InteractionAnswer? {
        shown.append(Shown(question: question, job: job.id, window: window))
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in open.append((id: id, continuation: continuation)) }
        } onCancel: {
            Task { @MainActor in self.finish(id, nil) }
        }
    }

    /// Answers the oldest open dialog; nil = it went away without an answer.
    func answerOldest(_ answer: InteractionAnswer?) {
        if let first = open.first { finish(first.id, answer) }
    }

    private func finish(_ id: Int, _ answer: InteractionAnswer?) {
        guard let index = open.firstIndex(where: { $0.id == id }) else { return }
        open.remove(at: index).continuation.resume(returning: answer)
    }
}

/// Which fake origins count as open windows.
@MainActor
private final class OpenOrigins {
    var raw: Set<Int> = []
}

@MainActor
final class InteractionRouterTests: XCTestCase {
    private func job(_ origin: OriginID?) -> JobSnapshot {
        JobSnapshot(id: JobID(), description: JobDescription(verb: .copying, itemCount: 2, firstItemName: "a.txt",
                                                             sourceFolderName: "src", destinationFolderName: "dst"),
                    state: .waitingForUser, progress: .zero, origin: origin, startedAt: .now)
    }

    private func conflict(_ h: ContentTestHarness) -> ConflictInfo {
        let pair = ConflictPair(source: ItemSummary(url: h.url("src/a.txt"), isDirectory: false, size: 1, modified: Date()),
                                destination: ItemSummary(url: h.url("dst/a.txt"), isDirectory: false, size: 2, modified: Date()))
        return ConflictInfo(pair: pair, isFolderMerge: false, knownRemaining: 1, pendingPairs: [pair])
    }

    private func error(_ h: ContentTestHarness, _ kind: FileOpErrorKind) -> FileOpError {
        FileOpError(kind: kind, url: h.url("a.txt"))   // a value only; nothing is created
    }

    /// A router whose hosts are fake: an origin is an open window unless `open` says otherwise.
    private func router(_ h: ContentTestHarness, _ presenter: RecordingPresenter, open: OpenOrigins? = nil) -> InteractionRouter {
        let router = InteractionRouter(windows: h.context.windows, presenter: presenter, resolveHost: { origin in
            guard let origin, open.map({ $0.raw.contains(origin.raw) }) ?? true else { return .operationsPanel }
            return .window(origin)
        })
        router.answersInline = { _ in false }
        return router
    }

    func testConcurrentQuestionsAreSerializedPerHost() async throws {   // slice Review Focus 5
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        let origin = OriginID(raw: 7)
        let inUse = error(h, .inUse), gone = error(h, .sourceGone)
        let jobA = job(origin), jobB = job(origin)
        let first = Task { await r.resolveError(inUse, job: jobA) }
        let second = Task { await r.resolveError(gone, job: jobB) }
        try await h.waitUntil("one dialog") { presenter.shown.count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(presenter.shown.count, 1, "the second question waits: one dialog per host at a time")
        let firstAsked = presenter.shown[0].question
        presenter.answerOldest(.error(.retry))
        try await h.waitUntil("second dialog") { presenter.shown.count == 2 }
        presenter.answerOldest(.error(.skip))
        let answerA = await first.value
        let answerB = await second.value
        let inAskOrder = firstAsked == .error(inUse) ? [answerA, answerB] : [answerB, answerA]
        XCTAssertEqual(inAskOrder, [.retry, .skip], "no answer lost or swapped")
        XCTAssertTrue(r.pendingHosts.isEmpty)
    }

    func testQuestionsForDifferentHostsAreShownTogether() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        let e = error(h, .inUse)
        let job1 = job(OriginID(raw: 1)), job2 = job(OriginID(raw: 2))
        let a = Task { await r.resolveError(e, job: job1) }
        let b = Task { await r.resolveError(e, job: job2) }
        try await h.waitUntil("both dialogs") { presenter.shown.count == 2 }
        XCTAssertEqual(Set(r.pendingHosts.values), [.window(OriginID(raw: 1)), .window(OriginID(raw: 2))])
        presenter.answerOldest(.error(.skip))
        presenter.answerOldest(.error(.cancel))
        let answers = [await a.value, await b.value]
        XCTAssertEqual(answers.sorted { "\($0)" < "\($1)" }, [.cancel, .skip])
    }

    func testQuestionWithoutOriginGoesToOperationsPanel() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = InteractionRouter(windows: h.context.windows, presenter: presenter)   // the real host rules
        r.panelWindow = { nil }
        XCTAssertEqual(r.route(nil), .operationsPanel)
        XCTAssertEqual(r.route(OriginID(raw: 987_654)), .operationsPanel, "no such window")
        let info = conflict(h)
        let j = job(nil)
        let task = Task { await r.resolveConflict(info, job: j) }
        try await h.waitUntil("asked") { presenter.shown.count == 1 }
        XCTAssertEqual(r.pendingHosts[j.id], .operationsPanel)
        presenter.answerOldest(.conflict(.one(.keepBoth)))
        let answer = await task.value
        XCTAssertEqual(answer, .one(.keepBoth))
    }

    func testQuestionFromClosedOriginGoesToOperationsPanel() async throws {   // slice Review Focus 5
        try ContentTestHarness.requireWindowServer()
        let h = try await ContentTestHarness.make(self)
        let browser = try await h.openBrowserWindow()
        let origin = browser.origin
        let presenter = RecordingPresenter()
        let r = InteractionRouter(windows: h.context.windows, presenter: presenter)
        r.panelWindow = { nil }
        XCTAssertEqual(r.route(origin), .window(origin))
        XCTAssertTrue(r.hostWindow(for: origin) === browser.window)
        browser.close()
        try await h.waitUntil("window gone") { h.context.windows.window(for: origin) == nil }
        XCTAssertEqual(r.route(origin), .operationsPanel)
        let info = conflict(h)
        let j = job(origin)
        let task = Task { await r.resolveConflict(info, job: j) }
        try await h.waitUntil("asked") { presenter.shown.count == 1 }
        XCTAssertEqual(r.pendingHosts[j.id], .operationsPanel, "§6.2: closing the window never loses its job's question")
        XCTAssertNil(presenter.shown[0].window)
        presenter.answerOldest(.conflict(.all(.skip)))
        let answer = await task.value
        XCTAssertEqual(answer, .all(.skip))
    }

    func testWindowClosedDuringQuestionMovesItToOperationsPanel() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let open = OpenOrigins()
        open.raw = [3]
        let r = router(h, presenter, open: open)
        let e = error(h, .inUse)
        let j = job(OriginID(raw: 3))
        let task = Task { await r.resolveError(e, job: j) }
        try await h.waitUntil("on the window") { presenter.shown.count == 1 }
        XCTAssertEqual(r.pendingHosts[j.id], .window(OriginID(raw: 3)))
        open.raw = []                          // the window closes and takes its sheet with it, unanswered
        presenter.answerOldest(nil)
        try await h.waitUntil("asked again in the panel") { presenter.shown.count == 2 }
        XCTAssertEqual(r.pendingHosts[j.id], .operationsPanel)
        XCTAssertEqual(presenter.shown[1].question, .error(e))
        presenter.answerOldest(.error(.retry))
        let answer = await task.value
        XCTAssertEqual(answer, .retry)
    }

    func testCancelledQuestionReleasesHost() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        let info = conflict(h)
        let origin = OriginID(raw: 4)
        let jobA = job(origin), jobB = job(origin)
        let first = Task { await r.resolveConflict(info, job: jobA) }
        try await h.waitUntil("shown") { presenter.openCount == 1 }
        first.cancel()                          // what S6's ScenarioInteraction does after answering itself
        let cancelled = await first.value
        XCTAssertEqual(cancelled, .cancelJob, "a dialog that goes away unanswered stops the job safely")
        let second = Task { await r.resolveConflict(info, job: jobB) }
        try await h.waitUntil("the host is free again") { presenter.shown.count == 2 && presenter.openCount == 1 }
        presenter.answerOldest(.conflict(.one(.replace)))
        let answer = await second.value
        XCTAssertEqual(answer, .one(.replace))
    }

    /// Stop and Quit (§6.7, S3 Contract note 18): a job suspended on an unanswered dialog can't finish its cancel,
    /// so the router ends open dialogs and answers waiting and later questions with the safe fallback.
    func testStopAnsweringEndsOpenDialogsAndAnswersLaterQuestionsSafely() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        let info = conflict(h)
        let e = error(h, .inUse)
        let origin = OriginID(raw: 8)
        let jobA = job(origin), jobB = job(origin)
        let open = Task { await r.resolveConflict(info, job: jobA) }
        let waiting = Task { await r.resolveError(e, job: jobB) }
        try await h.waitUntil("one dialog open, one waiting") { presenter.openCount == 1 }
        r.stopAnswering()
        let openAnswer = await open.value
        let waitingAnswer = await waiting.value
        XCTAssertEqual(openAnswer, .cancelJob, "the open dialog closes unanswered and the job stops safely")
        XCTAssertEqual(waitingAnswer, .cancel, "the waiting question never shows")
        let later = await r.confirmInsufficientSpace(SpaceShortfall(needed: 2, available: 1, volumeName: "V"), job: job(origin))
        XCTAssertFalse(later, "questions asked after Stop and Quit get the fallback at once")
        XCTAssertEqual(presenter.shown.count, 1)
        XCTAssertEqual(presenter.openCount, 0)
        XCTAssertTrue(r.pendingHosts.isEmpty)
    }

    func testErrorsFromInlineOriginsAreSkippedWithoutDialog() async throws {
        let h = try await ContentTestHarness.make(self)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        r.answersInline = { $0.raw == 9 }
        let e = error(h, .locked)
        let j = job(OriginID(raw: 9))
        let answer = await r.resolveError(e, job: j)
        XCTAssertEqual(answer, .skip, "Properties shows the error inline (§5.8)")
        XCTAssertTrue(presenter.shown.isEmpty)
        let info = conflict(h)
        let task = Task { await r.resolveConflict(info, job: j) }
        try await h.waitUntil("conflicts still ask") { presenter.shown.count == 1 }
        presenter.answerOldest(.conflict(.one(.skip)))
        _ = await task.value
    }

    func testUIContextInstallsRouterIntoProxy() async throws {
        let h = try await ContentTestHarness.make(self)
        XCTAssertTrue(h.context.interaction as AnyObject === h.context.operationsUI.router, "P1-38 replaces BasicAlertInteraction")
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        h.context.installInteraction(r)
        let proxy = h.environment.interaction
        let e = error(h, .inUse)
        let j = job(OriginID(raw: 5))
        let task = Task { await proxy.resolveError(e, job: j) }
        try await h.waitUntil("the proxy forwards to the router") { presenter.shown.count == 1 }
        presenter.answerOldest(.error(.skip))
        let answer = await task.value
        XCTAssertEqual(answer, .skip)
    }

    func testConflictFromRealCopyJobReachesRouter() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("src/a.txt", bytes: 3)
        try h.file("dst/a.txt", bytes: 5)
        let presenter = RecordingPresenter()
        let r = router(h, presenter)
        h.environment.interaction.setTarget(r)
        let request = JobRequest(.copy(sources: [h.url("src/a.txt")], destination: h.url("dst")), origin: OriginID(raw: 6))
        let operations = h.environment.operations
        let running = Task { await operations.perform(request) }
        try await h.waitUntil("conflict asked") { presenter.shown.count == 1 }
        guard case .conflict(let info) = presenter.shown[0].question else { return XCTFail("a conflict question") }
        XCTAssertEqual(info.pair.destination.url.lastPathComponent, "a.txt")
        XCTAssertFalse(info.isFolderMerge)
        presenter.answerOldest(.conflict(.one(.keepBoth)))
        let outcome = await running.value
        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertTrue(h.exists("dst/a 2.txt"))
        XCTAssertEqual(h.lstatInfo("dst/a.txt")?.st_size, 5, "Keep Both never touches the existing item")
    }
}
