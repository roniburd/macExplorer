@testable import Core
import Foundation
import MacxFixtures
@testable import MacxFS
import MacxPluginKit
import XCTest

@MainActor
final class RemoteFolderModelTests: XCTestCase {
    private let root = RemoteLocation(provider: "test.fake", repo: "o/r", ref: "main")

    private func makeWorld(_ fake: FakeRemoteProvider) async throws -> FolderTestWorld {
        let world = try await FolderTestWorld.make(self)
        world.remote = ProviderRegistry(builtIns: [fake])
        return world
    }

    private func fakeRepo() -> FakeRemoteProvider {
        let fake = FakeRemoteProvider()
        fake.setTree(repo: "o/r", [
            "": [RemoteItem(name: "b.txt", kind: .file, size: 1), RemoteItem(name: "a", kind: .directory)],
            "a": [RemoteItem(name: "inner.swift", kind: .file, size: 2)],
        ])
        return fake
    }

    func testListsRemoteFolderThroughTheNormalPipeline() async throws {
        let world = try await makeWorld(fakeRepo())
        let m = world.model(root.url)
        XCTAssertTrue(m.isRemote)
        m.start()
        try await world.waitUntil("complete") { m.state == .complete }
        XCTAssertEqual((0..<m.rowCount).map { m.name(atRow: $0) }, ["a", "b.txt"], "folders first, then by name")
        XCTAssertEqual(m.volume?.isReadOnly, true)
        XCTAssertEqual(m.store.identityMode, .name(caseSensitive: true))
        XCTAssertTrue(world.watchers.isEmpty, "remote folders never get a content watcher")
        XCTAssertEqual(RemoteLocation(url: m.url(atRow: 0)), root.appending("a"))
    }

    func testRefreshRelists() async throws {
        let fake = fakeRepo()
        let world = try await makeWorld(fake)
        let m = world.model(root.url.appending(path: "a"))
        m.start()
        try await world.waitUntil("complete") { m.state == .complete }
        fake.setTree(repo: "o/r", ["a": [RemoteItem(name: "inner.swift", kind: .file), RemoteItem(name: "new.md", kind: .file)]])
        m.refresh()
        try await world.waitUntil("new row") { m.row(named: "new.md") != nil }
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("list o/r@main/a") }.count, 2)
    }

    /// Review Focus 2.
    func testProviderMissingIsNotFound() async throws {
        let world = try await FolderTestWorld.make(self)
        world.remote = ProviderRegistry(builtIns: [])
        let m = world.model(root.url)
        m.start()
        try await world.waitUntil("error") { if case .error = m.state { true } else { false } }
        XCTAssertEqual(m.state, .error(.notFound))

        let noRegistry = try await FolderTestWorld.make(self)      // remote nil: still never a POSIX read
        let n = noRegistry.model(root.url)
        n.start()
        try await noRegistry.waitUntil("error") { if case .error = n.state { true } else { false } }
        XCTAssertEqual(n.state, .error(.notFound))
    }

    /// Review Focus 3: a remote failure never relocates the window to a local folder.
    func testRemoteNotFoundNeverRelocates() async throws {
        let world = try await makeWorld(fakeRepo())
        let m = world.model(root.url.appending(path: "missing"))
        var relocations: [URL] = []
        world.keep(m.observe { if case .relocate(let to, _) = $0 { relocations.append(to) } })
        m.start()
        try await world.waitUntil("error") { if case .error = m.state { true } else { false } }
        m.relocateIfGone()
        m.volumesChanged([])
        m.volumesChanged(world.volumes.list)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(relocations, [])
    }

    func testRateLimitAndNetworkStates() async throws {
        let fake = fakeRepo()
        let world = try await makeWorld(fake)
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        fake.failNext(.rateLimited(resetAt: reset))
        let m = world.model(root.url)
        m.start()
        try await world.waitUntil("error") { if case .error = m.state { true } else { false } }
        XCTAssertEqual(m.state, .error(.rateLimited(resetAt: reset)))
        fake.failNext(.network("offline"))
        m.refresh()
        try await world.waitUntil("unresponsive") { m.state == .unresponsive }
        m.refresh()
        try await world.waitUntil("recovered") { m.state == .complete }
    }

    func testSideFeaturesStayOff() async throws {
        let world = try await makeWorld(fakeRepo())
        let m = world.model(root.url)
        m.start()
        try await world.waitUntil("complete") { m.state == .complete }
        m.setFolderSizesEnabled(true)
        XCTAssertFalse(m.folderSizesEnabled)
        m.requestExtendedAttributes(rows: IndexSet(0..<m.rowCount), [.tags])
        XCTAssertNil(m.attributeTask, "no xattr reads on a remote folder")
    }
}
