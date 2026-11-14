import XCTest
@testable import UI
@testable import Core
import MacxPluginKit

final class ScenarioRemoteTests: XCTestCase {
    func testRemoteScenarioFileValidates() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Scenarios/remote-repo-browse.json")
        let file = try ScenarioFile.load(try Data(contentsOf: url))
        XCTAssertEqual(file.fixture.remote?.repo, "demo")
    }

    func testUnsafeRemoteFixturePathIsRefused() {
        let json = #"{"name":"x","fixture":{"files":[],"dirs":[],"remote":{"repo":"b","refs":{"main":{"../x":"y"}}}},"steps":[]}"#
        XCTAssertThrowsError(try ScenarioFile.load(Data(json.utf8)))
    }

    func testScenarioProviderListsAndFetches() async throws {
        let p = ScenarioRemoteProvider(ScenarioFile.RemoteFixture(repo: "demo", refs: ["main": ["src/a.txt": "alpha", "R.md": "r"]]))
        let root = try XCTUnwrap(p.parseAddress("fake:demo@main"))
        var names: [String] = []
        for try await chunk in p.list(root) { names += chunk.map(\.name) }
        XCTAssertEqual(names.sorted(), ["R.md", "src"])
        let dir = FileManager.default.temporaryDirectory.appending(path: "macx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "a.txt")
        try await p.fetch(root.appending("src").appending("a.txt"), item: RemoteItem(name: "a.txt", kind: .file), to: dest)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "alpha")
    }
}
