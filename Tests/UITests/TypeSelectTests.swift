// Tests/UITests/TypeSelectTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class TypeSelectTests: XCTestCase {
    func testBufferResetsAfterTimeout() {
        var time = ContinuousClock.now
        let typeSelect = TypeSelect(timeout: .seconds(1), now: { time })
        XCTAssertEqual(typeSelect.append("a"), TypeSelectQuery(text: "a", cycle: true))
        XCTAssertEqual(typeSelect.append("b"), TypeSelectQuery(text: "ab", cycle: false))
        time = time.advanced(by: .milliseconds(1_500))
        XCTAssertEqual(typeSelect.append("c"), TypeSelectQuery(text: "c", cycle: true))
    }

    func testRepeatedLetterCycles() {
        let typeSelect = TypeSelect()
        _ = typeSelect.append("s")
        XCTAssertEqual(typeSelect.append("s"), TypeSelectQuery(text: "s", cycle: true))
        XCTAssertEqual(typeSelect.append("s"), TypeSelectQuery(text: "s", cycle: true))
    }

    func testFindIsCaseAndDiacriticInsensitive() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["apple.txt", "École.txt", "zeta.txt"] { try h.file(name) }
        let folder = try await h.openFolder()
        let row = TypeSelectSearch.find(TypeSelectQuery(text: "eco", cycle: false), in: folder.store, from: nil)
        XCTAssertEqual(row.map(folder.name(atRow:)), "École.txt")
        XCTAssertNil(TypeSelectSearch.find(TypeSelectQuery(text: "q", cycle: true), in: folder.store, from: nil))
    }

    func testFindWrapsAndCyclesFromCursor() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["sa", "sb", "t", "sc"] { try h.file(name) }
        let folder = try await h.openFolder()   // display order: sa sb sc t
        let s = TypeSelectQuery(text: "s", cycle: true)
        XCTAssertEqual(TypeSelectSearch.find(s, in: folder.store, from: 0), 1, "cycling starts after the cursor")
        XCTAssertEqual(TypeSelectSearch.find(s, in: folder.store, from: 2), 0, "and wraps")
        XCTAssertEqual(TypeSelectSearch.find(TypeSelectQuery(text: "sb", cycle: false), in: folder.store, from: 1), 1,
                       "a longer prefix may stay on the cursor row")
    }

    func testTypingSelectsMatchingRow() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["alpha", "beta", "gamma"] { try h.file(name) }
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        _ = details.view
        details.bind(folder)
        details.typeSelect.handle("g", folder: folder, list: details)
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: 2))
    }

    func testLargeFolderSearchRunsOffMainAndApplies() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<2_500 { try h.file(String(format: "a%04d", i)) }
        try h.file("zebra")
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        _ = details.view
        details.bind(folder)
        details.typeSelect.handle("z", folder: folder, list: details)
        XCTAssertTrue(folder.selection.rows.isEmpty, "large folders search off main")
        // Correctness, not speed: a loaded CI runner can take several seconds for 2,500 names.
        try await h.waitUntil("type-select applied", timeout: .seconds(30)) { folder.selection.rows == IndexSet(integer: 2_500) }
    }
}
