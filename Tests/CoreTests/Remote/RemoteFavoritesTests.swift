@testable import Core
import Foundation
import MacxFS
import MacxPluginKit
import XCTest

@MainActor
final class RemoteFavoritesTests: XCTestCase {
    let url = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["src"]).url

    func testRemoteFavoriteResolvesWithoutTouchingTheFileSystem() async {
        let favorite = FavoritesResolver.makeRemoteFavorite(url: url, displayName: "src")
        XCTAssertEqual(favorite.remoteURL, url.absoluteString)
        let resolved = await FavoritesResolver.resolve([favorite], lanes: LanePool())
        XCTAssertEqual(resolved.first?.url, url)
        XCTAssertEqual(resolved.first?.isStale, false)
    }

    func testOldFavoritesDecodeWithoutRemoteURL() throws {
        let json = #"[{"id":"7B0E9E5C-1E0B-4B1D-9C4C-9C3C2B0C1D11","bookmark":"","displayName":"x","lastKnownPath":"/x"}]"#
        let decoded = try JSONDecoder().decode([Favorite].self, from: Data(json.utf8))
        XCTAssertNil(decoded.first?.remoteURL)
    }
}
