@testable import Core
import Foundation
import MacxFS
import XCTest

@MainActor
final class FolderViewStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "macx-folderviews-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appending(path: "folder-views.json") }
    private func folder(_ name: String) -> URL { URL(filePath: "/tmp/macx-test/\(name)", directoryHint: .isDirectory) }

    func testUpdatePersistsOnlyChangedFieldsAndSurvivesReload() {
        let store = FolderViewStore(fileURL: file)
        store.update(folder("a")) { $0.iconSize = .large }
        store.update(folder("a/")) { $0.viewMode = .icons }
        store.flush()
        let reloaded = FolderViewStore(fileURL: file)
        XCTAssertEqual(reloaded.settings(for: folder("a")), FolderViewSettings(viewMode: .icons, iconSize: .large))
        XCTAssertNil(reloaded.settings(for: folder("b")))
    }

    func testEmptySettingsRemoveTheEntry() {
        let store = FolderViewStore(fileURL: nil)
        store.update(folder("a")) { $0.density = .compact }
        store.update(folder("a")) { $0.density = nil }
        XCTAssertEqual(store.count, 0)
    }

    func testLeastRecentlyUsedEntriesAreEvicted() {
        var clock = 0.0
        let store = FolderViewStore(fileURL: nil, limit: 3, now: { Date(timeIntervalSince1970: clock) })
        for name in ["a", "b", "c"] {
            clock += 1
            store.update(folder(name)) { $0.viewMode = .icons }
        }
        clock += 1
        _ = store.settings(for: folder("a"))            // a is now the most recent
        clock += 1
        store.update(folder("d")) { $0.viewMode = .icons }
        XCTAssertEqual(store.count, 3)
        XCTAssertNil(store.settings(for: folder("b")))
        XCTAssertNotNil(store.settings(for: folder("a")))
    }

    func testCorruptFileIsMovedAsideAndIgnored() throws {
        try Data("{not json".utf8).write(to: file)
        let store = FolderViewStore(fileURL: file)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path(percentEncoded: false)))
    }

    func testResolverOrder() {
        let defaults = ResolvedFolderView(viewMode: .details, iconSize: .medium, density: .regular, sort: .default,
                                          columns: Settings.defaultColumns)
        let finder = FolderViewSettings(viewMode: .details, iconSize: .small, sort: .init(field: .size, ascending: false))
        let builtIn = FolderViewSettings(viewMode: .icons, iconSize: .large)
        let stored = FolderViewSettings(iconSize: .large)
        let view = FolderViewResolver.resolve(stored: stored, finder: finder, builtIn: builtIn, defaults: defaults)
        XCTAssertEqual(view.viewMode, .details)                          // Finder beats the built-in rule
        XCTAssertEqual(view.iconSize, .large)                            // ours beats Finder
        XCTAssertEqual(view.sort, .init(field: .size, ascending: false))
        XCTAssertEqual(view.density, .regular)                           // nobody set it: global default
        let none = FolderViewResolver.resolve(stored: nil, finder: nil, builtIn: builtIn, defaults: defaults)
        XCTAssertEqual(none.viewMode, .icons)
        XCTAssertEqual(none.iconSize, .large)
    }

    func testBuiltInRuleCoversApplicationFolders() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        for path in ["/Applications", "/Applications/", "/System/Applications", "/Applications/Utilities", "/Users/someone/Applications"] {
            XCTAssertEqual(FolderViewResolver.builtIn(for: URL(filePath: path), home: home).iconSize, .large, path)
        }
        XCTAssertTrue(FolderViewResolver.builtIn(for: URL(filePath: "/Users/someone/Documents"), home: home).isEmpty)
    }

    func testViewStateChangeAppliesAndPersistsTheDelta() {
        let state = FolderViewState(ResolvedFolderView(viewMode: .details, iconSize: .medium, density: .regular, sort: .default,
                                                       columns: Settings.defaultColumns))
        var persisted: [FolderViewSettings] = []
        state.persist = { persisted.append($0) }
        state.change { $0.iconSize = .small }
        XCTAssertEqual(state.resolved.iconSize, .small)
        XCTAssertEqual(persisted, [FolderViewSettings(iconSize: .small)])
        state.replace(ResolvedFolderView(viewMode: .icons, iconSize: .large, density: .compact, sort: .default, columns: []))
        XCTAssertEqual(persisted.count, 1)
    }
}
