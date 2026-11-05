// Tests/UITests/TypeSelectTests.swift
import XCTest
import AppKit
import Synchronization
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

    /// CI flake root cause: a watcher patch landing while the off-main search ran bumped the store version, and the
    /// result (and with it the key press) was silently dropped. The search is gated so the patch lands mid-search.
    func testLargeFolderSearchRerunsWhenTheFolderChangesMidSearch() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<2_500 { try h.file(String(format: "a%04d", i)) }
        try h.file("zebra")
        let folder = try await h.openFolder()
        let details = DetailsViewController(context: h.context)
        _ = details.view
        details.bind(folder)
        let gate = SearchGate()
        let typeSelect = TypeSelect(search: { query, store, cursor in
            await gate.pass()
            return TypeSelectSearch.find(query, in: store, from: cursor)
        })
        typeSelect.handle("z", folder: folder, list: details)
        try await h.waitUntil("search running") { gate.calls == 1 }
        let before = folder.store.version
        try h.file("b0000")
        folder.applyLocalChange(LocalChange(directory: h.url(""), added: ["b0000"]))
        try await h.waitUntil("folder patched mid-search") { folder.store.version != before }
        XCTAssertTrue(folder.selection.rows.isEmpty)
        gate.open()
        try await h.waitUntil("type-select applied") { folder.selection.rows == IndexSet(integer: 2_501) }
        XCTAssertEqual(folder.name(atRow: 2_501), "zebra")
        // ≥ 2: late FSEvents for the 2,501 creations can patch the store again while the re-run is in flight.
        XCTAssertGreaterThanOrEqual(gate.calls, 2, "the stale result re-runs the query on the current rows")
    }
}

/// Holds searches until `open()`; afterwards they pass straight through.
private final class SearchGate: Sendable {
    private let state = Mutex<(open: Bool, calls: Int, waiting: [CheckedContinuation<Void, Never>])>((false, 0, []))

    var calls: Int { state.withLock { $0.calls } }

    func pass() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { s -> Bool in
                s.calls += 1
                if s.open { return true }
                s.waiting.append(c)
                return false
            }
            if resume { c.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiting = [] }
            return s.waiting
        }
        for c in waiting { c.resume() }
    }
}
