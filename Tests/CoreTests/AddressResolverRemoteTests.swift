import Foundation
import MacxFixtures
import MacxPluginKit
@testable import MacxFS
import XCTest
@testable import Core

final class AddressResolverRemoteTests: XCTestCase {
    private var sandbox: Sandbox!
    private let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)

    override func setUp() async throws { sandbox = try Sandbox() }
    override func tearDown() async throws { sandbox.destroy(); sandbox = nil }

    private func registry(_ fake: FakeRemoteProvider = demo()) -> ProviderRegistry { ProviderRegistry(builtIns: [fake]) }

    static func demo() -> FakeRemoteProvider {
        FakeRemoteProvider(tree: ["main": [
            "": [RemoteItem(name: "src", kind: .directory), RemoteItem(name: "README.md", kind: .file, size: 3)],
            "src": [RemoteItem(name: "lib", kind: .directory), RemoteItem(name: "a.swift", kind: .file)],
            "src/lib": [],
        ]])
    }

    private func loc(_ path: [String] = [], ref: String? = "main") -> RemoteLocation {
        RemoteLocation(provider: "test.fake", repo: "demo", ref: ref, path: path)
    }

    private func resolve(_ text: String, current: URL? = nil, registry: ProviderRegistry? = nil) async -> AddressResult {
        await AddressResolver.resolve(text, current: current ?? sandbox.root, home: home, lanes: LanePool(),
                                      mounts: MountTable([]), remote: registry ?? self.registry())
    }

    func testProviderAddressResolvesToTheFolderWithItsRefFilledIn() async {
        let result = await resolve("fake:demo")
        XCTAssertEqual(result, .remote(loc().url))
        let nested = await resolve("fake:demo@main/src")
        XCTAssertEqual(nested, .remote(loc(["src"]).url))
    }

    func testAFileResolvesToItsFolderWithTheFileSelected() async {
        let result = await resolve("fake:demo/src/a.swift")
        XCTAssertEqual(result, .file(parent: loc(["src"]).url, name: "a.swift"))
    }

    func testMissingAndFailingRemotesAreReported() async {
        let missing = await resolve("fake:demo/nope")
        XCTAssertEqual(missing, .notFound("fake:demo/nope"))
        // A root is listed before it is reported as a folder: a mistyped ref or repo is not found, not a folder.
        let badRef = await resolve("fake:demo@nope")
        XCTAssertEqual(badRef, .notFound("fake:demo@nope"))
        let badRefURL = await resolve(loc(ref: "nope").url.absoluteString)
        XCTAssertEqual(badRefURL, .notFound(loc(ref: "nope").url.absoluteString))
        let onlyDemo = FakeRemoteProvider()
        onlyDemo.setTree(repo: "demo", ["": []])
        let badRepo = await resolve("fake:nosuch", registry: registry(onlyDemo))
        XCTAssertEqual(badRepo, .notFound("fake:nosuch"))
        let emptyRoot = await resolve("fake:demo", registry: registry(onlyDemo))
        XCTAssertEqual(emptyRoot, .remote(loc().url), "an empty repository is still a folder")
        let failing = Self.demo()
        failing.failure = .rateLimited(resetAt: nil)
        let refused = await resolve("fake:demo", registry: registry(failing))
        XCTAssertEqual(refused, .noAccess("fake:demo"))
    }

    func testRemoteURLTextIsAccepted() async {
        let result = await resolve(loc(["src"]).url.absoluteString)
        XCTAssertEqual(result, .remote(loc(["src"]).url))
    }

    func testRelativeInputStaysInsideTheRemoteFolder() async {
        let current = loc(["src"]).url
        let child = await resolve("lib", current: current)
        XCTAssertEqual(child, .remote(loc(["src", "lib"]).url))
        let up = await resolve("..", current: current)
        XCTAssertEqual(up, .remote(loc().url))
        let file = await resolve("./a.swift", current: current)
        XCTAssertEqual(file, .file(parent: loc(["src"]).url, name: "a.swift"))
    }

    func testAbsoluteAndTildePathsLeaveTheRemoteFolder() async {
        let current = loc(["src"]).url
        let local = await resolve(sandbox.root.path(percentEncoded: false), current: current)
        guard case .folder = local else { return XCTFail("\(local)") }
        XCTAssertNil(AddressResolver.remoteTarget("~/x", current: current, registry: registry()))
        XCTAssertNil(AddressResolver.remoteTarget("/tmp", current: current, registry: registry()))
    }

    func testWithoutARegistryNothingIsRemote() async {
        let result = await AddressResolver.resolve("fake:demo", current: sandbox.root, home: home, lanes: LanePool(),
                                                   mounts: MountTable([]))
        XCTAssertEqual(result, .notFound("fake:demo"))
    }
}
