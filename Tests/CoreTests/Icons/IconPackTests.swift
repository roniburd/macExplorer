import XCTest
@testable import Core
@testable import MacxFS
import MacxFixtures

final class IconPackTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    func testLoaderPicksPriorityFormatAndIgnoresNoise() async throws {
        let png = TestImages.png()
        for name in ["pdf.png", "PDF.icns", "swift.png", "folder.png", ".hidden.png", "readme.txt", "tar.gz.png"] {
            try sandbox.createFile("pack/\(name)", contents: png)
        }
        try sandbox.createFile("pack/sub/zip.png", contents: png)
        try sandbox.createFile("pack/big.png", contents: Data(count: 1_048_577))
        _ = try sandbox.createDirectory("pack/md.png")                       // a folder named like an image
        _ = try sandbox.createSymlink("pack/rtf.png", target: "swift.png")   // never followed
        let pack = try await IconPackLoader.load(sandbox.url("pack"), lanes: LanePool())
        XCTAssertEqual(Set(pack.byExtension.keys), ["pdf", "swift"])
        XCTAssertEqual(pack.byExtension["pdf"]?.lastPathComponent, "PDF.icns")
        XCTAssertEqual(pack.folderIcon?.lastPathComponent, "folder.png")
        XCTAssertFalse(pack.isEmpty)
    }

    func testLoaderRejectsNonDirectory() async throws {
        let f = try sandbox.createFile("notapack.png")
        do { _ = try await IconPackLoader.load(f, lanes: LanePool()); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? IconPackError, .notAFolder) }
        do { _ = try await IconPackLoader.load(sandbox.url("missing"), lanes: LanePool()); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? IconPackError, .notAFolder) }
    }

    func testLoaderCapsEntriesAndReportsEmptyPack() async throws {
        let empty = try sandbox.createDirectory("empty")
        let none = try await IconPackLoader.load(empty, lanes: LanePool())
        XCTAssertTrue(none.isEmpty)
        let png = Data("p".utf8)          // the loader doesn't decode; IconCache does when the pack is applied
        for i in 0..<(IconPack.maxEntries + 10) { try sandbox.createFile("many/e\(i).png", contents: png) }
        try sandbox.createFile("many/folder.png", contents: png)
        let pack = try await IconPackLoader.load(sandbox.url("many"), lanes: LanePool())
        XCTAssertEqual(pack.byExtension.count, IconPack.maxEntries)
    }

    func testExtensionStringForTypeIndex() {
        let types = TypeRegistry()
        let i = types.index(forExtension: "PDF", isDirectory: false)
        XCTAssertEqual(types.extensionString(at: i), "pdf")
        XCTAssertNil(types.extensionString(at: TypeRegistry.folderIndex))
        XCTAssertNil(types.extensionString(at: TypeRegistry.dataIndex))
        XCTAssertNil(types.extensionString(at: TypeRegistry.symlinkIndex))
        // Several extensions can share one type: every one of them is offered for the pack lookup, first seen first.
        let jpg = types.index(forExtension: "jpg", isDirectory: false)
        let jpeg = types.index(forExtension: "JPEG", isDirectory: false)
        XCTAssertEqual(jpg, jpeg)
        XCTAssertEqual(types.extensionString(at: jpg), "jpg")
        XCTAssertEqual(Array(types.extensionStrings(at: jpg).prefix(2)), ["jpg", "jpeg"])
        // An unregistered extension gets its own (dynamic) type and keeps its extension.
        let odd = types.index(forExtension: "macxodd", isDirectory: false)
        XCTAssertEqual(types.extensionString(at: odd), "macxodd")
        // A folder with an extension that isn't a package is a plain folder.
        XCTAssertNil(types.extensionString(at: types.index(forExtension: "v1", isDirectory: true)))
    }

    @MainActor func testIconPackBookmarkPersistsAndDefaultsToNil() {
        let storage = InMemorySettingsStorage()
        let settings = Settings(storage: storage)
        XCTAssertNil(settings.iconPackBookmark)
        settings.iconPackBookmark = Data([1, 2, 3])
        XCTAssertEqual(Settings(storage: storage).iconPackBookmark, Data([1, 2, 3]))
        settings.iconPackBookmark = nil
        XCTAssertNil(Settings(storage: storage).iconPackBookmark)
        XCTAssertEqual(Settings.schemaVersion, 3, "Phase 4 settings are additive")
    }

    func testPropertiesReportCustomIconFlag() async throws {
        let a = try sandbox.createFile("a.txt"), b = try sandbox.createFile("b.txt")
        let lanes = LanePool()
        let before = try await PropertiesLoader.load(a, lanes: lanes, volume: .unknown)
        XCTAssertFalse(before.hasCustomIcon)
        try await lanes.perform(on: .unknown, .fileOp) { _ in
            try WorkspaceIconWriter().setIcon(IconImageData(bytes: TestImages.png()), for: a)
        }
        let after = try await PropertiesLoader.load(a, lanes: lanes, volume: .unknown)
        XCTAssertTrue(after.hasCustomIcon)
        let many = try await PropertiesLoader.loadMany([a, b], lanes: lanes, volume: .unknown)
        XCTAssertEqual(many.customIcon, .mixed)
    }
}
