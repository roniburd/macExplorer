@testable import Core
import Foundation
import MacxFixtures
import MacxPluginKit
import XCTest

final class RemoteExportTests: XCTestCase {
    var sandbox: Sandbox!
    var fake: FakeRemoteProvider!
    var export: RemoteExport!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        fake = FakeRemoteProvider()
        fake.setTree(repo: "demo", [
            "": [RemoteItem(name: "src", kind: .directory), RemoteItem(name: "top.txt", kind: .file, size: 3)],
            "src": [RemoteItem(name: "a.txt", kind: .file, size: 1), RemoteItem(name: "lib", kind: .directory)],
            "src/lib": [RemoteItem(name: "b.txt", kind: .file, size: 2)],
        ])
        export = RemoteExport(registry: ProviderRegistry(builtIns: [fake]), stagingRoot: try sandbox.createDirectory("staging"))
    }

    private func url(_ path: String...) -> URL { RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: path).url }

    func testStagesFilesAndFoldersRecursively() async throws {
        let progress = ProgressLog()
        let staged = try await export.stage([url("top.txt"), url("src")]) { progress.append($0) }
        XCTAssertEqual(staged.items.map(\.lastPathComponent), ["top.txt", "src"])
        XCTAssertEqual(try String(contentsOf: staged.items[0], encoding: .utf8), "content of top.txt")
        let b = staged.items[1].appending(path: "lib/b.txt")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "content of src/lib/b.txt")
        XCTAssertEqual(progress.last?.itemsDone, 3, "three files")
        XCTAssertTrue(staged.directory.path.hasPrefix(sandbox.url("staging").path))
    }

    func testAFailingFetchThrowsAndLeavesNoStagingFolderBehind() async throws {
        fake.failNext(.network("boom"))
        do {
            _ = try await export.stage([url("top.txt")]) { _ in }
            XCTFail("expected an error")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .network("boom"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.url("staging").path), [])
    }

    func testCancellationStopsBetweenFiles() async throws {
        let export = self.export!, source = url("src")
        let task = Task { try await export.stage([source]) { _ in withUnsafeCurrentTask { $0?.cancel() } } }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.url("staging").path), [])
    }
}

/// Collects progress callbacks from any thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RemoteExport.Progress] = []
    func append(_ p: RemoteExport.Progress) { lock.withLock { items.append(p) } }
    var last: RemoteExport.Progress? { lock.withLock { items.last } }
}
