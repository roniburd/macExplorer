import XCTest
@testable import UI
import Core
import MacxFS

@MainActor
final class IconCacheTests: XCTestCase {
    private func entry(_ kind: Kind, flags: EntryFlags = [], type: UInt16 = TypeRegistry.dataIndex) -> Entry {
        Entry(rowID: 7, fileID: 7, size: 1, allocSize: 1, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 1,
              kind: kind, flags: flags, typeIndex: type)
    }

    func testTypeIconIsCachedAndSizedInPixels() async throws {
        let h = try await ContentTestHarness.make(self)
        let a = h.context.icons.typeIcon(TypeRegistry.folderIndex, points: 32, scale: 2)
        let b = h.context.icons.typeIcon(TypeRegistry.folderIndex, points: 32, scale: 2)
        XCTAssertTrue(a === b, "Tier 0 icons are rasterized once per (type, pixel size)")
        XCTAssertEqual(a.width, 64)
        XCTAssertEqual(h.context.icons.typeIcon(TypeRegistry.folderIndex, points: 16, scale: 1).width, 16)
    }

    func testTier1OnlyForAppsIcnsCustomIconsAndVolumes() async throws {
        let h = try await ContentTestHarness.make(self)
        let icons = h.context.icons
        let app = TypeRegistry.shared.index(forExtension: "app", isDirectory: true)
        XCTAssertTrue(icons.needsFileIcon(entry(.package, type: app), name: "Fake.app", isVolumeRoot: false))
        XCTAssertTrue(icons.needsFileIcon(entry(.file), name: "Icon.ICNS", isVolumeRoot: false))
        XCTAssertTrue(icons.needsFileIcon(entry(.file, flags: .customIcon), name: "a.txt", isVolumeRoot: false))
        XCTAssertTrue(icons.needsFileIcon(entry(.directory), name: "Disk", isVolumeRoot: true))
        XCTAssertFalse(icons.needsFileIcon(entry(.file), name: "a.txt", isVolumeRoot: false))
        XCTAssertFalse(icons.needsFileIcon(entry(.directory), name: "Sub", isVolumeRoot: false))
        XCTAssertFalse(icons.needsFileIcon(entry(.file, flags: [.customIcon, .dataless]), name: "c.txt", isVolumeRoot: false),
                       "dataless items are never probed (§4.2)")
    }

    func testFileIconCompletesForAppBundle() async throws {
        let h = try await ContentTestHarness.make(self)
        let app = try h.dir("Fake.app/Contents").deletingLastPathComponent()
        var image: CGImage?
        h.context.icons.fileIcon(for: app, rowID: .name("Fake.app"), points: 16, scale: 2) { image = $0 }
        try await h.waitUntil("tier 1 icon") { image != nil }
        XCTAssertEqual(image?.width, 32)
    }

    func testCancelledFileIconNeverCallsBack() async throws {
        let h = try await ContentTestHarness.make(self)
        let app = try h.dir("Other.app/Contents").deletingLastPathComponent()
        var called = false
        h.context.icons.fileIcon(for: app, rowID: .name("Other.app"), points: 16, scale: 2) { _ in called = true }
        h.context.icons.cancelFileIcons(notIn: [])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(called)
    }

    // MARK: P4-07 invalidation

    func testInvalidateRowIDDropsCachedImagesAndInFlightResults() async throws {
        let h = try await ContentTestHarness.make(self)
        let icons = h.context.icons
        let app = try h.dir("Inv.app/Contents").deletingLastPathComponent()
        let id = RowID.name("Inv.app")
        var first: CGImage?
        icons.fileIcon(for: app, rowID: id, points: 16, scale: 2) { first = $0 }
        try await h.waitUntil("tier 1 icon") { first != nil }
        XCTAssertTrue(icons.hasCachedFileIcon(rowID: id))
        icons.invalidate(rowID: id)
        XCTAssertFalse(icons.hasCachedFileIcon(rowID: id))

        // A request in flight when the item changes is dropped: its read may predate the change.
        var stale = false
        icons.fileIcon(for: app, rowID: id, points: 16, scale: 2) { _ in stale = true }
        icons.invalidate(rowID: id)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(stale)
        XCTAssertFalse(icons.hasCachedFileIcon(rowID: id))

        var again: CGImage?
        icons.fileIcon(for: app, rowID: id, points: 16, scale: 2) { again = $0 }
        try await h.waitUntil("refetched icon") { again != nil }
        XCTAssertTrue(icons.hasCachedFileIcon(rowID: id))
    }

    func testInvalidatePathLeavesOtherItems() async throws {
        let h = try await ContentTestHarness.make(self)
        let icons = h.context.icons
        let a = try h.dir("A.app/Contents").deletingLastPathComponent()
        let b = try h.dir("B.app/Contents").deletingLastPathComponent()
        var done = 0
        icons.fileIcon(for: a, rowID: .name(a.path), points: 16, scale: 1) { _ in done += 1 }
        icons.fileIcon(for: b, rowID: .name(b.path), points: 16, scale: 1) { _ in done += 1 }
        try await h.waitUntil("both icons") { done == 2 }
        icons.invalidate(path: a.path)
        XCTAssertFalse(icons.hasCachedFileIcon(rowID: .name(a.path)))
        XCTAssertTrue(icons.hasCachedFileIcon(rowID: .name(b.path)))
    }

    func testFinishedIconJobInvalidatesRowsOfTheShownFolder() async throws {
        let h = try await ContentTestHarness.make(self)
        _ = try h.dir("Shown.app/Contents")
        _ = try h.dir("Other.app/Contents")
        let (content, session, _) = try await h.makeContent()
        let folder = session.folder
        let row = try XCTUnwrap(folder.row(named: "Shown.app")), other = try XCTUnwrap(folder.row(named: "Other.app"))
        let id = folder.identity(atRow: row), otherID = folder.identity(atRow: other)
        try await h.waitUntil("row icons fetched") {
            h.context.icons.hasCachedFileIcon(rowID: id) && h.context.icons.hasCachedFileIcon(rowID: otherID)
        }
        let record = JobRecord(id: JobID(), verb: .changingIcon,
                               actions: [.customIconChanged(folder.url(atRow: row), previous: nil, new: IconImageData(bytes: Data([1])))])
        content.customIconsChanged(record)
        XCTAssertTrue(h.context.icons.hasCachedFileIcon(rowID: otherID), "only the changed item is dropped")
        // The row is redrawn, so its icon is fetched again.
        try await h.waitUntil("changed row refetched") { h.context.icons.hasCachedFileIcon(rowID: id) }
    }
}
