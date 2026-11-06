import XCTest
@testable import Core

@MainActor
final class KeyBindingSettingsTests: XCTestCase {
    private let home = URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory)

    func testDefaultIsEmptyAndNotWritten() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        XCTAssertEqual(s.keyBindingOverrides, .empty)
        XCTAssertEqual(s.keyBindings, .defaults)
        XCTAssertNil(storage.data(forKey: "keyBindings"))
    }

    func testEditsPersistAndReload() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        s.keyBindingOverrides.setPrimary(KeyChord(parsing: "opt+cmd+b"), for: .back)
        XCTAssertNotNil(storage.data(forKey: "keyBindings"))
        let reloaded = Settings(storage: storage, home: home)
        XCTAssertEqual(reloaded.keyBindings.primary(.back), KeyChord(parsing: "opt+cmd+b"))
    }

    func testResettingAllRemovesTheStoredValue() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        s.keyBindingOverrides.setPrimary(nil, for: .back)
        s.keyBindingOverrides = .empty
        XCTAssertNil(storage.data(forKey: "keyBindings"))
    }

    /// Spec §6: undecodable data → defaults, data left in place, one diagnostic.
    func testUndecodableStoredValueIsReportedOnceAndLeftInPlace() {
        let storage = InMemorySettingsStorage()
        let garbage = Data("42".utf8)
        storage.set(garbage, forKey: "keyBindings")
        var reports: [String] = []
        let s = Settings(storage: storage, home: home, diagnostic: { reports.append($0) })
        XCTAssertEqual(s.keyBindingOverrides, .empty)
        XCTAssertEqual(storage.data(forKey: "keyBindings"), garbage)
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports.first?.contains("keyBindings") == true, reports.first ?? "")
        _ = Settings(storage: InMemorySettingsStorage(), home: home, diagnostic: { reports.append($0) })
        XCTAssertEqual(reports.count, 1, "nothing stored → nothing reported")
    }

    func testGarbageStoredValueFallsBackWithoutOverwriting() {
        let storage = InMemorySettingsStorage()
        let garbage = Data("[\"not an object\"]".utf8)
        storage.set(garbage, forKey: "keyBindings")
        let s = Settings(storage: storage, home: home)
        XCTAssertEqual(s.keyBindings, .defaults)
        XCTAssertEqual(storage.data(forKey: "keyBindings"), garbage)
    }
}
