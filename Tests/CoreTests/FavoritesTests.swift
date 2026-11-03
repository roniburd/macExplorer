import Foundation
import MacxFixtures
import MacxFS
import XCTest
@testable import Core

final class FavoritesTests: XCTestCase {
    private var sandbox: Sandbox!
    private var lanes: LanePool!

    override func setUp() async throws {
        sandbox = try Sandbox()
        lanes = LanePool()
    }

    override func tearDown() async throws {
        sandbox.destroy()
        sandbox = nil
        lanes = nil
    }

    private func path(_ url: URL?) -> String? {
        guard let path = url?.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false) else { return nil }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    func testMakeFavoriteRecordsNameAndPath() async throws {
        let dir = try sandbox.createDirectory("Projects")
        let f = try await FavoritesResolver.makeFavorite(for: dir, lanes: lanes)
        XCTAssertEqual(f.displayName, "Projects")
        XCTAssertEqual(path(URL(filePath: f.lastKnownPath)), path(dir))
        XCTAssertFalse(f.lastKnownPath.hasSuffix("/"))
        XCTAssertFalse(f.bookmark.isEmpty)
        let again = try await FavoritesResolver.makeFavorite(for: dir, lanes: lanes)
        XCTAssertNotEqual(f.id, again.id, "fresh identity each time")
    }

    func testMakeFavoriteForMissingItemThrows() async {
        do {
            _ = try await FavoritesResolver.makeFavorite(for: sandbox.url("missing"), lanes: lanes)
            XCTFail("expected an error")
        } catch {}
    }

    func testResolvePreservesOrderAndIdentity() async throws {
        let a = try await FavoritesResolver.makeFavorite(for: try sandbox.createDirectory("a"), lanes: lanes)
        let b = try await FavoritesResolver.makeFavorite(for: try sandbox.createDirectory("b"), lanes: lanes)
        let c = try await FavoritesResolver.makeFavorite(for: try sandbox.createDirectory("c"), lanes: lanes)
        let resolved = await FavoritesResolver.resolve([c, a, b], lanes: lanes)
        XCTAssertEqual(resolved.map(\.favorite.id), [c.id, a.id, b.id])
        XCTAssertEqual(resolved.map { $0.url?.lastPathComponent }, ["c", "a", "b"])
        XCTAssertEqual(resolved.map(\.isStale), [false, false, false])
        XCTAssertEqual(path(resolved[1].url), path(sandbox.url("a")))
    }

    func testResolveEmptyList() async {
        let resolved = await FavoritesResolver.resolve([], lanes: lanes)
        XCTAssertEqual(resolved, [])
    }

    func testBookmarkFollowsARenamedFolder() async throws {
        let f = try await FavoritesResolver.makeFavorite(for: try sandbox.createDirectory("old"), lanes: lanes)
        try sandbox.rename("old", to: "new")
        let all = await FavoritesResolver.resolve([f], lanes: lanes)
        let r = try XCTUnwrap(all.first)
        XCTAssertEqual(path(r.url), path(sandbox.url("new")))
        XCTAssertFalse(r.isStale)
        XCTAssertEqual(r.favorite.id, f.id)
        XCTAssertEqual(path(URL(filePath: r.favorite.lastKnownPath)), path(sandbox.url("new")), "refreshed path")
        XCTAssertEqual(r.favorite.displayName, "old", "the user-visible name is kept")
    }

    func testDeletedTargetIsStale() async throws {
        let f = try await FavoritesResolver.makeFavorite(for: try sandbox.createDirectory("gone"), lanes: lanes)
        let keep = try await FavoritesResolver.makeFavorite(for: try sandbox.createDirectory("keep"), lanes: lanes)
        try sandbox.remove("gone")
        let r = await FavoritesResolver.resolve([f, keep], lanes: lanes)
        XCTAssertNil(r[0].url)
        XCTAssertTrue(r[0].isStale)
        XCTAssertEqual(r[0].favorite, f, "a stale favorite is returned unchanged")
        XCTAssertFalse(r[1].isStale, "one stale bookmark does not affect the others")
        XCTAssertEqual(r[1].url?.lastPathComponent, "keep")
    }

    func testGarbageBookmarkIsStale() async {
        let f = Favorite(bookmark: Data("nope".utf8), displayName: "X", lastKnownPath: "/nowhere")
        let r = await FavoritesResolver.resolve([f], lanes: lanes)
        XCTAssertEqual(r.count, 1)
        XCTAssertNil(r[0].url)
        XCTAssertTrue(r[0].isStale)
    }

    func testFavoriteCodableRoundTrip() throws {
        let f = Favorite(bookmark: Data([1, 2, 3]), displayName: "Name", lastKnownPath: "/p")
        XCTAssertEqual(try JSONDecoder().decode(Favorite.self, from: JSONEncoder().encode(f)), f)
    }

    func testDefaultFavoriteURLs() {
        let home = URL(filePath: "/tmp/macx-tests-h", directoryHint: .isDirectory)
        func p(_ f: DefaultFavorite) -> String { FavoritesResolver.defaultFavoriteURL(f, home: home).path(percentEncoded: false) }
        XCTAssertEqual(p(.home), "/tmp/macx-tests-h/")
        XCTAssertEqual(p(.desktop), "/tmp/macx-tests-h/Desktop/")
        XCTAssertEqual(p(.documents), "/tmp/macx-tests-h/Documents/")
        XCTAssertEqual(p(.downloads), "/tmp/macx-tests-h/Downloads/")
        XCTAssertEqual(p(.applications), "/Applications/")
        for f in DefaultFavorite.allCases { XCTAssertTrue(FavoritesResolver.defaultFavoriteURL(f, home: home).hasDirectoryPath) }
    }
}
