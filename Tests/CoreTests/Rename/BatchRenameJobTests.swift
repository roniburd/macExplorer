import XCTest
import Darwin
@testable import Core
import MacxFS
import MacxFixtures

final class BatchRenameJobTests: FileOpsTestCase {
    private func pairs(_ dir: String, _ map: [(String, String)]) -> [BatchRenamePair] {
        map.map { BatchRenamePair(url: url(dir.isEmpty ? $0.0 : "\(dir)/\($0.0)"), newName: $0.1) }
    }

    func testBatchRenameSwapChainCycleAndCaseOnly() async throws {
        try file("s/a.txt", "A"); try file("s/b.txt", "B")
        try file("c/1.txt", "1"); try file("c/2.txt", "2"); try file("c/3.txt", "3")
        try file("y/x.txt", "X"); try file("y/y.txt", "Y"); try file("y/z.txt", "Z")
        let mount = try image(.hfsPlus)                        // case-insensitive volume for the case-only rename
        try Data("K".utf8).write(to: mount.appending(path: "A.txt"))
        let (queue, journal) = makeQueue()

        let swap = try await run(.batchRename(pairs("s", [("a.txt", "b.txt"), ("b.txt", "a.txt")])), on: queue)
        XCTAssertEqual(text(url("s/a.txt")), "B"); XCTAssertEqual(text(url("s/b.txt")), "A")
        XCTAssertTrue(swap.skipped.isEmpty)

        _ = try await run(.batchRename(pairs("c", [("1.txt", "2.txt"), ("2.txt", "3.txt"), ("3.txt", "4.txt")])), on: queue)
        XCTAssertEqual(names(url("c")), ["2.txt", "3.txt", "4.txt"])
        XCTAssertEqual(text(url("c/2.txt")), "1"); XCTAssertEqual(text(url("c/3.txt")), "2"); XCTAssertEqual(text(url("c/4.txt")), "3")

        _ = try await run(.batchRename(pairs("y", [("x.txt", "y.txt"), ("y.txt", "z.txt"), ("z.txt", "x.txt")])), on: queue)
        XCTAssertEqual(text(url("y/y.txt")), "X"); XCTAssertEqual(text(url("y/z.txt")), "Y"); XCTAssertEqual(text(url("y/x.txt")), "Z")

        let caseOnly = try await run(.batchRename([BatchRenamePair(url: mount.appending(path: "A.txt"), newName: "a.txt")]), on: queue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mount.path).filter { $0.hasSuffix(".txt") }, ["a.txt"])
        XCTAssertEqual(caseOnly.record.actions.count, 1)
        XCTAssertEqual(text(mount.appending(path: "a.txt")), "K")

        let left = await journal.entries(); XCTAssertTrue(left.isEmpty)
        for d in ["s", "c", "y"] { XCTAssertEqual(names(url(d)).filter { $0.hasPrefix(".macx-") }, []) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mount.path).filter { $0.hasPrefix(".macx-") }, [])
    }

    func testJobDescriptionAndLocalChanges() async throws {
        try file("d/a.txt"); try file("d/b.txt")
        let kind = JobKind.batchRename(pairs("d", [("a.txt", "x.txt"), ("b.txt", "y.txt")]))
        XCTAssertEqual(kind.verb, .batchRenaming)
        XCTAssertEqual(kind.jobDescription, JobDescription(verb: .batchRenaming, itemCount: 2, firstItemName: "a.txt",
                                                           sourceFolderName: "d", destinationFolderName: nil))
        let (queue, _) = makeQueue()
        let outcome = try await run(kind, on: queue)
        let renames = outcome.localChanges.flatMap(\.renamed)
        XCTAssertEqual(renames, [LocalChange.Rename(from: "a.txt", to: "x.txt"), LocalChange.Rename(from: "b.txt", to: "y.txt")])
        XCTAssertEqual(Set(outcome.localChanges.flatMap(\.select)), ["x.txt", "y.txt"])
    }

    func testBatchRenameUndoRestoresAll() async throws {
        try file("y/x.txt", "X"); try file("y/y.txt", "Y"); try file("y/z.txt", "Z"); try file("y/w.txt", "W")
        let (queue, _) = makeQueue()
        let outcome = try await run(.batchRename(pairs("y", [("x.txt", "y.txt"), ("y.txt", "z.txt"), ("z.txt", "x.txt"), ("w.txt", "v.txt")])), on: queue)
        XCTAssertEqual(outcome.record.verb, .batchRenaming)
        XCTAssertEqual(outcome.record.actions.count, 4)
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertTrue(undo.skipped.isEmpty)
        XCTAssertEqual(text(url("y/x.txt")), "X"); XCTAssertEqual(text(url("y/y.txt")), "Y")
        XCTAssertEqual(text(url("y/z.txt")), "Z"); XCTAssertEqual(text(url("y/w.txt")), "W")
        XCTAssertEqual(names(url("y")), ["w.txt", "x.txt", "y.txt", "z.txt"])
        _ = try await run(.redo(undo.record), on: queue)
        XCTAssertEqual(text(url("y/y.txt")), "X"); XCTAssertEqual(text(url("y/z.txt")), "Y")
        XCTAssertEqual(text(url("y/x.txt")), "Z"); XCTAssertEqual(text(url("y/v.txt")), "W")
    }

    func testUndoSkipsItemsThatChangedSinceAndRestoresTheRest() async throws {
        try file("u/a.txt", "A"); try file("u/b.txt", "B"); try file("u/c.txt", "C")
        let (queue, _) = makeQueue()
        let outcome = try await run(.batchRename(pairs("u", [("a.txt", "b.txt"), ("b.txt", "a.txt"), ("c.txt", "d.txt")])), on: queue)
        // Something replaced d.txt (a different file) after the rename.
        try FileManager.default.removeItem(at: url("u/d.txt"))
        try file("u/d.txt", "other")
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(undo.skipped.map(\.url.lastPathComponent), ["d.txt"])
        XCTAssertEqual(undo.skipped.first?.reason, .changedDuringMove)
        XCTAssertEqual(text(url("u/a.txt")), "A"); XCTAssertEqual(text(url("u/b.txt")), "B")
        XCTAssertEqual(text(url("u/d.txt")), "other")
        XCTAssertFalse(exists(url("u/c.txt")))
    }

    func testUndoGroupsConsecutiveRenamesPerFolder() {
        let id = FileIdentity(device: 1, inode: 2)
        func p(_ s: String) -> URL { URL(filePath: "/s/\(s)") }
        let record = JobRecord(id: JobID(), verb: .batchRenaming, actions: [
            .renamed(from: p("a"), to: p("b"), id), .renamed(from: p("b"), to: p("a"), id),
            .renamed(from: URL(filePath: "/t/x"), to: URL(filePath: "/t/y"), id),
        ])
        XCTAssertEqual(UndoPlanner.steps(for: record), [
            .renameBack(current: URL(filePath: "/t/y"), original: URL(filePath: "/t/x"), id),
            .batchRenameBack([BatchRenameBackItem(current: p("a"), original: p("b"), identity: id),
                              BatchRenameBackItem(current: p("b"), original: p("a"), identity: id)]),
        ])
    }

    func testBatchRenameRecoveryRestoresOriginals() async throws {
        try file("r/a.txt", "A"); try file("r/b.txt", "B"); try file("r/c.txt", "C")
        let spec = CrashSpec(mode: "batchRename", sources: [url("r/a.txt").path, url("r/b.txt").path, url("r/c.txt").path],
                             destination: "b.txt\nc.txt\na.txt", journal: journalURL.path, trash: trashDir.path,
                             fault: FaultPoint.batchRenameStaged.rawValue, conflict: nil, forceCrossVolume: false, allowClone: false)
        let killed = try await runCrashingChild(spec)
        XCTAssertTrue(killed)
        XCTAssertEqual(names(url("r")).filter { !$0.hasPrefix(".macx-br-") }, [])     // everything is at temporary names
        XCTAssertEqual(names(url("r")).count, 3)
        let journal = Journal(fileURL: journalURL)
        let report = await LaunchRecovery.run(journal: journal, lanes: LanePool())
        XCTAssertEqual(names(url("r")), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(text(url("r/a.txt")), "A"); XCTAssertEqual(text(url("r/b.txt")), "B"); XCTAssertEqual(text(url("r/c.txt")), "C")
        XCTAssertEqual(Set(report.restoredRenames.map(\.lastPathComponent)), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(report.incompleteJobs.map(\.verb), [.batchRenaming])
        let left = await journal.entries(); XCTAssertTrue(left.isEmpty)
    }

    func testRecoveryAfterPartialPhaseTwo() async throws {
        // Simulate a crash in the middle of phase 2: step 0 landed at its target, steps 1 and 2 still temporary.
        try file("p/.macx-br-t-1", "B"); try file("p/.macx-br-t-2", "C"); try file("p/b.txt", "A")
        let paths = [url("p/b.txt").path, url("p/.macx-br-t-1").path, url("p/.macx-br-t-2").path]
        let ids = try await LanePool().perform(on: .unknown, .fileOp) { _ in paths.map { FileIdentity.of(path: $0)! } }
        let steps = [
            BatchRenameStep(original: url("p/a.txt"), temporary: url("p/.macx-br-t-0"), target: url("p/b.txt"), identity: ids[0]),
            BatchRenameStep(original: url("p/b.txt"), temporary: url("p/.macx-br-t-1"), target: url("p/c.txt"), identity: ids[1]),
            BatchRenameStep(original: url("p/c.txt"), temporary: url("p/.macx-br-t-2"), target: url("p/a.txt"), identity: ids[2]),
        ]
        let journal = Journal(fileURL: journalURL)
        try await journal.record(.batchRename(job: JobID(), steps: steps))
        _ = await LaunchRecovery.run(journal: journal, lanes: LanePool())
        XCTAssertEqual(names(url("p")), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(text(url("p/a.txt")), "A"); XCTAssertEqual(text(url("p/b.txt")), "B"); XCTAssertEqual(text(url("p/c.txt")), "C")
        let left = await journal.entries(); XCTAssertTrue(left.isEmpty)
    }

    func testRecoveryKeepsAFinishedBatchWhoseEntryWasNotCleared() async throws {
        // Every item already at its target and no temporary left: the job finished; keep the new names.
        try file("f/b.txt", "A"); try file("f/a.txt", "B")
        let paths = [url("f/b.txt").path, url("f/a.txt").path]
        let ids = try await LanePool().perform(on: .unknown, .fileOp) { _ in paths.map { FileIdentity.of(path: $0)! } }
        let steps = [
            BatchRenameStep(original: url("f/a.txt"), temporary: url("f/.macx-br-t-0"), target: url("f/b.txt"), identity: ids[0]),
            BatchRenameStep(original: url("f/b.txt"), temporary: url("f/.macx-br-t-1"), target: url("f/a.txt"), identity: ids[1]),
        ]
        let journal = Journal(fileURL: journalURL)
        try await journal.record(.batchRename(job: JobID(), steps: steps))
        let report = await LaunchRecovery.run(journal: journal, lanes: LanePool())
        XCTAssertEqual(text(url("f/b.txt")), "A"); XCTAssertEqual(text(url("f/a.txt")), "B")
        XCTAssertTrue(report.restoredRenames.isEmpty)
        let left = await journal.entries(); XCTAssertTrue(left.isEmpty)
    }

    func testRecoveryNeverOverwritesAnOccupiedOriginal() async throws {
        try file("o/.macx-br-t-0", "A"); try file("o/a.txt", "newcomer")
        let id = try await LanePool().perform(on: .unknown, .fileOp) { [p = url("o/.macx-br-t-0").path] _ in FileIdentity.of(path: p)! }
        let journal = Journal(fileURL: journalURL)
        try await journal.record(.batchRename(job: JobID(), steps: [
            BatchRenameStep(original: url("o/a.txt"), temporary: url("o/.macx-br-t-0"), target: url("o/z.txt"), identity: id),
        ]))
        let report = await LaunchRecovery.run(journal: journal, lanes: LanePool())
        XCTAssertEqual(text(url("o/a.txt")), "newcomer"); XCTAssertEqual(text(url("o/a 2.txt")), "A")
        XCTAssertEqual(report.restoredRenames.map(\.lastPathComponent), ["a 2.txt"])
    }

    func testPhaseOneFailureSkipLeavesItemAndOthersProceed() async throws {
        try file("q/a.txt"); try file("q/b.txt")
        try sandbox.setFlags("q/a.txt", UInt32(UF_IMMUTABLE))       // rename of a uchg item fails with EPERM
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        let outcome = try await run(.batchRename(pairs("q", [("a.txt", "a2.txt"), ("b.txt", "b2.txt")])), on: queue)
        XCTAssertEqual(names(url("q")), ["a.txt", "b2.txt"])
        XCTAssertEqual(outcome.skipped.map(\.url.lastPathComponent), ["a.txt"])
        XCTAssertEqual(outcome.record.actions.count, 1)
    }

    func testPhaseOneCancelRollsBackStagedItems() async throws {
        try file("k/a.txt", "A"); try file("k/b.txt", "B")
        try sandbox.setFlags("k/b.txt", UInt32(UF_IMMUTABLE))
        let (queue, journal) = makeQueue(interaction: ScriptedInteraction(errors: [.cancel]))
        let outcome = try await run(.batchRename(pairs("k", [("a.txt", "b.txt"), ("b.txt", "a.txt")])), on: queue)
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertTrue(outcome.record.actions.isEmpty)
        XCTAssertEqual(names(url("k")), ["a.txt", "b.txt"])
        XCTAssertEqual(text(url("k/a.txt")), "A")
        let left = await journal.entries(); XCTAssertTrue(left.isEmpty)
    }

    func testMissingSourceIsSkippedAndTheRestRenamed() async throws {
        try file("m/a.txt")
        let (queue, _) = makeQueue()
        let outcome = try await run(.batchRename(pairs("m", [("gone.txt", "x.txt"), ("a.txt", "b.txt")])), on: queue)
        XCTAssertEqual(names(url("m")), ["b.txt"])
        XCTAssertEqual(outcome.skipped, [SkippedItem(url: url("m/gone.txt"), reason: .sourceGone)])
    }

    func testExternalCreationOfTargetNeverOverwrites() async throws {
        try file("e/a.txt", "A")
        let holder = SandboxHolder(root: root)
        let (queue, _) = makeQueue(tuning: FileOpTuning(faultHook: { point, _ in
            if point == .batchRenameStaged { try? Data("intruder".utf8).write(to: holder.root.appending(path: "e/n.txt")) }
        }))
        let outcome = try await run(.batchRename(pairs("e", [("a.txt", "n.txt")])), on: queue)
        XCTAssertEqual(text(url("e/n.txt")), "intruder"); XCTAssertEqual(text(url("e/n 2.txt")), "A")
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertEqual(outcome.record.actions.count, 1)
    }
}

final class SandboxHolder: Sendable { let root: URL; init(root: URL) { self.root = root } }
