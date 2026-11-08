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
}
