import Foundation
import MacxFS
import XCTest
@testable import Core

@MainActor
final class SettingsV2Tests: XCTestCase {
    func testSchemaVersionIsTwo() {
        XCTAssertGreaterThanOrEqual(Settings.schemaVersion, 2, "schema versions only move forward (P3-07: 3)")
    }

    func testMigrateColumnsAppendsMissingIDsInvisibleAndKeepsOrder() {
        let stored = [
            ColumnSetting(id: .name, width: 300, visible: true),
            ColumnSetting(id: .size, width: 90, visible: true),
            ColumnSetting(id: .name, width: 10, visible: false),   // duplicate: first wins
        ]
        let migrated = Settings.migrateColumns(stored)
        XCTAssertEqual(migrated.prefix(2).map(\.id), [.name, .size])
        XCTAssertEqual(migrated[0].width, 300)
        XCTAssertEqual(Set(migrated.map(\.id)), Set(ColumnID.allCases))
        XCTAssertEqual(migrated.count, ColumnID.allCases.count)
        for setting in migrated.dropFirst(2) {
            XCTAssertFalse(setting.visible, "\(setting.id) must be appended invisible")
            XCTAssertEqual(setting.width, setting.id.defaultWidth)
        }
        XCTAssertEqual(Settings.migrateColumns(migrated), migrated, "idempotent")
    }

    func testVersionOneSettingsLoadWithNewColumnsInvisible() throws {
        let storage = InMemorySettingsStorage()
        let v1 = Settings(storage: storage)
        v1.columns = [ColumnSetting(id: .name, width: 280, visible: true),
                      ColumnSetting(id: .kind, width: 120, visible: true)]
        // Simulate a Phase 1 store: rewrite the version key to 1.
        storage.set(try JSONEncoder().encode(1), forKey: Settings.schemaVersionKey)
        let reloaded = Settings(storage: storage)
        XCTAssertEqual(reloaded.columns.filter(\.visible).map(\.id), [.name, .kind])
        XCTAssertTrue(reloaded.columns.contains { $0.id == .tags && !$0.visible })
        XCTAssertEqual(reloaded.groupBy, .none)
        XCTAssertTrue(reloaded.showThumbnails)
        XCTAssertEqual(reloaded.columnWidth, 220)
        let version = try XCTUnwrap(storage.data(forKey: Settings.schemaVersionKey))
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: version), Settings.schemaVersion, "current version written back once")
    }

    func testFreshInstallColumnsArePhaseOneDefaultsThenNewIDsInvisible() {
        let s = Settings(storage: InMemorySettingsStorage())
        XCTAssertEqual(s.columns.map(\.id), ColumnID.allCases)
        XCTAssertEqual(s.columns.filter(\.visible).map(\.id), [.name, .dateModified, .size, .kind])
        XCTAssertEqual(s.columns, Settings.defaultColumns)
    }

    func testNewKeysPersist() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage)
        s.groupBy = .dateModified
        s.showThumbnails = false
        s.columnWidth = 300
        let r = Settings(storage: storage)
        XCTAssertEqual(r.groupBy, .dateModified)
        XCTAssertFalse(r.showThumbnails)
        XCTAssertEqual(r.columnWidth, 300)
    }

    func testSortFieldMetadata() {
        XCTAssertEqual(SortField.entryFields, [.name, .dateModified, .size, .kind, .dateCreated, .fileExtension])
        XCTAssertEqual(SortField.allCases.filter(\.isExtended), [.tags, .dateLastOpened, .permissions, .owner, .comments])
        XCTAssertEqual(ColumnID.tags.sortField, .tags)
        XCTAssertEqual(ColumnID.path.sortField, .path)
        XCTAssertEqual(SortField.name.rawValue, "name")   // Phase 1 raw values unchanged
        XCTAssertEqual(ViewMode.allCases, [.details, .icons, .columns])
        XCTAssertEqual(GroupBy.allCases, [.none, .kind, .dateModified, .size, .nameFirstLetter])
    }
}
