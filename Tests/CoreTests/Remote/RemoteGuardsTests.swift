@testable import Core
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import MacxPluginKit
import XCTest

@MainActor
final class RemoteGuardsTests: XCTestCase {
    private let remote = RemoteLocation(provider: "test.fake", repo: "o/r", ref: "main", path: ["Sources", "App"]).url

    func testSchemeConstantsAgree() {
        XCTAssertEqual(RemoteScheme.name, RemoteLocation.scheme)
    }

    func testRemoteVolumeInfo() throws {
        let v = try XCTUnwrap(VolumeInfo.remote(url: remote))
        XCTAssertEqual(v.id.raw, "remote:test.fake:o%2Fr")
        XCTAssertEqual(v.name, "o/r")
        XCTAssertEqual(v.mountPoint.absoluteString, "x-macexplorer-remote://test.fake/o%2Fr@main")
        XCTAssertTrue(v.isReadOnly)
        XCTAssertFalse(v.isLocal)
        XCTAssertFalse(v.isBoot)
        XCTAssertFalse(v.isBrowsable)
        XCTAssertEqual(v.capabilities.identityMode, .name(caseSensitive: true))
        XCTAssertEqual(VolumeInfo.remote(url: RemoteLocation(provider: "test.fake", repo: "o/r", ref: "dev").url)?.id, v.id,
                       "one volume per repo, whatever the ref")
        XCTAssertNil(VolumeInfo.remote(url: URL(filePath: "/tmp")))
    }

    /// The hazard: a remote URL's path ("/o%2Fr@main/…") must never match the "/" boot volume.
    func testVolumesNeverMapRemoteToBootVolume() async throws {
        let world = try await FolderTestWorld.make(self)
        XCTAssertEqual(world.volumes.volume(for: world.url(""))?.id.raw, "test-root")
        XCTAssertEqual(world.volumes.volume(for: remote)?.id.raw, "remote:test.fake:o%2Fr")
    }

    func testDirectoryReadersRefuseRemoteURLs() async throws {
        let world = try await FolderTestWorld.make(self)
        var events: [ReadEvent] = []
        for await e in await world.readers.reader(for: remote).read(remote, generation: .initial) { events.append(e) }
        guard case .failed(let f)? = events.last else { return XCTFail("expected .failed, got \(events)") }
        XCTAssertEqual(f.code, ENOTSUP)
    }

    func testRemoteIsNeverAProtectedLocation() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        XCTAssertNil(ProtectedLocations.classify(remote, home: home, volume: VolumeInfo.remote(url: remote)))
    }

    func testFolderViewLocatorKeysRemoteByURLString() {
        let locator = FolderViewLocator(url: remote, volume: VolumeInfo.remote(url: remote), fileID: nil)
        XCTAssertEqual(locator.path, remote.absoluteString)
        XCTAssertEqual(locator.url, remote)
        XCTAssertNil(locator.objectKey)
        XCTAssertEqual(locator.pathKey, .path(remote.absoluteString), "case kept: remote volumes are case-sensitive")
        let slash = FolderViewLocator(url: URL(string: remote.absoluteString + "/")!, volume: nil, fileID: nil)
        XCTAssertEqual(slash.path, remote.absoluteString)
    }
}
