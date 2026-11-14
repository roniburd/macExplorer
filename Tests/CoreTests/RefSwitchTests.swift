import Foundation
import MacxFixtures
import MacxPluginKit
import XCTest
@testable import Core

final class RefSwitchTests: XCTestCase {
    private let registry = ProviderRegistry(builtIns: [FakeRemoteProvider(tree: [
        "main": ["": [RemoteItem(name: "src", kind: .directory), RemoteItem(name: "docs", kind: .directory)],
                 "src": [], "docs": []],
        "dev": ["": [RemoteItem(name: "src", kind: .directory)], "src": []],
    ])])
    private func loc(_ ref: String, _ path: [String]) -> RemoteLocation {
        RemoteLocation(provider: "test.fake", repo: "demo", ref: ref, path: path)
    }

    func testKeepsThePathWhenTheFolderExistsInTheNewRef() async {
        let target = await RefSwitch.target(from: loc("main", ["src"]), to: "dev", registry: registry)
        XCTAssertEqual(target, loc("dev", ["src"]))
    }

    func testFallsBackToTheRootWhenItDoesNot() async {
        let target = await RefSwitch.target(from: loc("main", ["docs"]), to: "dev", registry: registry)
        XCTAssertEqual(target, loc("dev", []))
        let unknown = await RefSwitch.target(from: loc("main", ["src"]), to: "nope", registry: registry)
        XCTAssertEqual(unknown, loc("nope", []), "an unknown ref lands on its root, whose listing reports the error")
    }

    func testTheRootStaysTheRoot() async {
        let target = await RefSwitch.target(from: loc("main", []), to: "dev", registry: registry)
        XCTAssertEqual(target, loc("dev", []))
    }
}
