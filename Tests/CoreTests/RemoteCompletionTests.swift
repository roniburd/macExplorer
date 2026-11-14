import Foundation
import MacxFixtures
import MacxPluginKit
import XCTest
@testable import Core

final class RemoteCompletionTests: XCTestCase {
    private let registry = ProviderRegistry(builtIns: [AddressResolverRemoteTests.demo()])
    private let local = URL(filePath: "/Users/me", directoryHint: .isDirectory)

    func testSubfoldersUnderATypedRemoteParent() async {
        let all = await RemoteCompletion.complete("fake:demo@main/", current: local, registry: registry)
        XCTAssertEqual(all.subfolders, ["src"])
        let prefixed = await RemoteCompletion.complete("fake:demo@main/src/l", current: local, registry: registry)
        XCTAssertEqual(prefixed.subfolders, ["lib"])
        let none = await RemoteCompletion.complete("fake:demo@main/src/x", current: local, registry: registry)
        XCTAssertEqual(none.subfolders, [])
    }

    func testRelativeTextInsideARemoteFolder() async {
        let current = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: []).url
        let result = await RemoteCompletion.complete("s", current: current, registry: registry)
        XCTAssertEqual(result.subfolders, ["src"])
    }

    func testLocalTextGetsNoRemoteSubfolders() async {
        let result = await RemoteCompletion.complete("/Users/m", current: local, registry: registry)
        XCTAssertEqual(result.subfolders, [])
    }
}
