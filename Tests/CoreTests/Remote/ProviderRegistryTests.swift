@testable import Core
import Foundation
import MacxFixtures
import MacxPluginKit
import XCTest

final class ProviderRegistryTests: XCTestCase {
    func testBuiltInsFirstAndDuplicatesRejected() {
        let a = FakeRemoteProvider(id: "test.a"), b = FakeRemoteProvider(id: "test.b")
        let registry = ProviderRegistry(builtIns: [a])
        XCTAssertEqual(registry.register([b, FakeRemoteProvider(id: "test.a")], source: "plugin.x"), ["test.a"])
        XCTAssertEqual(registry.providers.map(\.id), ["test.a", "test.b"])
        XCTAssertTrue((registry.provider(id: "test.b") as AnyObject) === b)
        XCTAssertNil(registry.provider(id: "missing"))
    }

    func testInvalidProviderIDsRejected() {
        let registry = ProviderRegistry(builtIns: [FakeRemoteProvider(id: "bad id"), FakeRemoteProvider(id: "test.a")])
        XCTAssertEqual(registry.providers.map(\.id), ["test.a"])
        XCTAssertEqual(registry.register([FakeRemoteProvider(id: "a:b"), FakeRemoteProvider(id: "a/b")], source: "p"), ["a:b", "a/b"])
        XCTAssertEqual(registry.providers.map(\.id), ["test.a"])
    }

    func testProviderForURL() {
        let fake = FakeRemoteProvider()
        let registry = ProviderRegistry(builtIns: [fake])
        XCTAssertTrue((registry.provider(for: RemoteLocation(provider: "test.fake", repo: "o/r").url) as AnyObject) === fake)
        XCTAssertNil(registry.provider(for: RemoteLocation(provider: "other", repo: "o/r").url))
        XCTAssertNil(registry.provider(for: URL(filePath: "/tmp")))
    }

    func testParseAskesProvidersInOrder() {
        let first = FakeRemoteProvider(id: "test.first"), second = FakeRemoteProvider(id: "test.second")
        let registry = ProviderRegistry(builtIns: [first, second])
        XCTAssertEqual(registry.parse(address: "fake:r@dev/a"),
                       RemoteLocation(provider: "test.first", repo: "r", ref: "dev", path: ["a"]))
        XCTAssertNil(registry.parse(address: "/Users/someone"))
    }

    func testItemAtLocation() async throws {
        let fake = FakeRemoteProvider()
        fake.setTree(repo: "o/r", ["": [RemoteItem(name: "README.md", kind: .file, size: 5), RemoteItem(name: "src", kind: .directory)]])
        let registry = ProviderRegistry(builtIns: [fake])
        let root = RemoteLocation(provider: "test.fake", repo: "o/r", ref: "main")
        let readme = try await registry.item(at: root.appending("README.md"))
        XCTAssertEqual(readme.size, 5)
        let rootItem = try await registry.item(at: root)
        XCTAssertEqual(rootItem.kind, .directory)
        XCTAssertEqual(rootItem.name, "o/r")
        do { _ = try await registry.item(at: root.appending("nope")); XCTFail("expected notFound") } catch { XCTAssertEqual(error, .notFound) }
        fake.failNext(.rateLimited(resetAt: nil))
        do { _ = try await registry.item(at: root.appending("README.md")); XCTFail("expected rateLimited") }
        catch { XCTAssertEqual(error, .rateLimited(resetAt: nil)) }
    }

    func testItemWithAnInvalidNameIsNeverReturned() async {
        let fake = FakeRemoteProvider()
        fake.setTree(repo: "o/r", ["": [RemoteItem(name: "..", kind: .directory), RemoteItem(name: "a/b", kind: .file)]])
        let registry = ProviderRegistry(builtIns: [fake])
        let root = RemoteLocation(provider: "test.fake", repo: "o/r", ref: "main")
        for name in ["..", "a/b"] {
            do { _ = try await registry.item(at: root.appending(name)); XCTFail("expected notFound for \(name)") }
            catch { XCTAssertEqual(error, .notFound) }
        }
    }
}
