import XCTest
import Darwin
@testable import Core
import MacxFixtures
import MacxFS

final class TagJobTests: FileOpsTestCase {
    private func tags(_ u: URL) async throws -> [FileTag] { try await LanePool().perform(on: .unknown) { _ in try TagIO.read(u) } }
    private let red = FileTag(name: "Red", color: .red), work = FileTag(name: "Work")

    func testAppliedSemantics() {
        XCTAssertEqual(TagEdit.add(red).applied(to: [work]), [work, red])
        XCTAssertEqual(TagEdit.add(FileTag(name: "red", color: .blue)).applied(to: [red]), [red])     // case-insensitive, keeps existing
        XCTAssertEqual(TagEdit.remove("RED").applied(to: [red, work]), [work])
        XCTAssertEqual(TagEdit.set([work, work]).applied(to: [red]), [work])
    }
    func testDescriptionAndURLs() throws {
        let a = try file("d/a.txt"), b = try file("d/b.txt")
        let kind = JobKind.setTags([a, b], .add(red))
        XCTAssertEqual(kind.allURLs, [a, b])
        XCTAssertEqual(kind.jobDescription, JobDescription(verb: .tagging, itemCount: 2, firstItemName: "a.txt",
                                                           sourceFolderName: "d", destinationFolderName: nil))
    }
    func testAddAcrossSelectionRecordsOnlyChangedItems() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let (queue, _) = makeQueue()
        _ = try await run(.setTags([a], .add(red)), on: queue)
        let outcome = try await run(.setTags([a, b], .add(red)), on: queue)
        let ta = try await tags(a), tb = try await tags(b)
        XCTAssertEqual(ta, [red]); XCTAssertEqual(tb, [red])
        XCTAssertEqual(outcome.record.verb, .tagging)
        XCTAssertEqual(outcome.record.actions, [.tagsChanged(b, old: [], new: [red])])   // a was unchanged
        XCTAssertTrue(outcome.localChanges.contains { $0.modified.contains("b.txt") })
    }
    func testToggleAddsToAllWhenMixedAndRemovesWhenAllHaveIt() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let (queue, _) = makeQueue()
        _ = try await run(.setTags([a], .add(red)), on: queue)
        _ = try await run(.setTags([a, b], .toggle(red)), on: queue)
        let tb = try await tags(b)
        XCTAssertEqual(tb, [red])
        _ = try await run(.setTags([a, b], .toggle(red)), on: queue)
        let ta2 = try await tags(a), tb2 = try await tags(b)
        XCTAssertEqual(ta2, []); XCTAssertEqual(tb2, [])
    }
    func testUndoRestoresPreviousTagsAndSkipsItemsChangedSince() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let (queue, _) = makeQueue()
        _ = try await run(.setTags([a, b], .set([work])), on: queue)
        let outcome = try await run(.setTags([a, b], .add(red)), on: queue)
        try await LanePool().perform(on: .unknown) { _ in try TagIO.write([FileTag(name: "Other")], to: b) }   // external edit
        let undo = try await run(.undo(outcome.record), on: queue)
        let ta = try await tags(a), tb = try await tags(b)
        XCTAssertEqual(ta, [work])
        XCTAssertEqual(tb, [FileTag(name: "Other")])
        XCTAssertEqual(undo.skipped.map(\.reason), [.changedDuringMove])
        let redo = try await run(.redo(undo.record), on: queue)
        let ta2 = try await tags(a)
        XCTAssertEqual(ta2, [work, red]); XCTAssertTrue(redo.skipped.isEmpty)
    }
    func testUndoSkipsMissingItem() async throws {
        let a = try file("a.txt")
        let (queue, _) = makeQueue()
        let outcome = try await run(.setTags([a], .add(red)), on: queue)
        try sandbox.remove("a.txt")
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(undo.skipped.map(\.reason), [.sourceGone])
    }
    func testRecordRoundTripsThroughJournalCoding() throws {
        let u = url("a.txt")
        let record = JobRecord(id: JobID(), verb: .tagging, actions: [.tagsChanged(u, old: [work], new: [work, red])])
        let decoded = try JSONDecoder().decode(JobRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(UndoPlanner.steps(for: record), [.restoreTags(u, expected: [work, red], restore: [work])])
    }
    func testLockedItemAsksAndSkip() async throws {
        let a = try file("a.txt")
        try sandbox.setFlags("a.txt", UInt32(UF_IMMUTABLE))
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        let outcome = try await run(.setTags([a], .add(red)), on: queue)
        XCTAssertEqual(interaction.askedErrors().map(\.kind), [.locked])
        XCTAssertEqual(outcome.skipped.map(\.url), [a]); XCTAssertTrue(outcome.record.actions.isEmpty)
    }
    func testUnlockAndContinue() async throws {
        let a = try file("a.txt")
        try sandbox.setFlags("a.txt", UInt32(UF_IMMUTABLE))
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(errors: [.unlockAndContinue]))
        _ = try await run(.setTags([a], .add(red)), on: queue)
        let ta = try await tags(a)
        XCTAssertEqual(ta, [red])
    }
    @MainActor func testKnownTagsMRUAndCap() {
        let storage = InMemorySettingsStorage()
        let settings = Settings(storage: storage)
        XCTAssertEqual(settings.knownTags, FileTag.standard)
        XCTAssertEqual(settings.sidebarTags, FileTag.standard.map(\.name))
        settings.noteTagUsed(FileTag(name: "Work"))
        settings.noteTagUsed(FileTag(name: "green", color: .green))
        XCTAssertEqual(settings.knownTags.prefix(2).map(\.name), ["green", "Work"])
        XCTAssertEqual(settings.knownTags.filter { $0.name.lowercased() == "green" }.count, 1)
        for i in 0..<300 { settings.noteTagUsed(FileTag(name: "t\(i)")) }
        XCTAssertEqual(settings.knownTags.count, 200)
        XCTAssertEqual(settings.knownTags.first?.name, "t299")
        settings.sidebarTags = ["Work"]
        let reloaded = Settings(storage: storage)
        XCTAssertEqual(reloaded.knownTags, settings.knownTags)
        XCTAssertEqual(reloaded.sidebarTags, ["Work"])
        XCTAssertEqual(Settings.schemaVersion, 3, "Phase 4 settings are additive")
    }
}
