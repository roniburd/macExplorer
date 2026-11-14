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

    func testInvalidAndDuplicateChildNamesAreSkippedAndNothingLeavesTheDestination() async throws {
        fake.setTree(repo: "demo", [
            "": [RemoteItem(name: "evil", kind: .directory)],
            "evil": [RemoteItem(name: "../escaped.txt", kind: .file), RemoteItem(name: "..", kind: .directory),
                     RemoteItem(name: ".", kind: .directory), RemoteItem(name: "", kind: .file),
                     RemoteItem(name: "ok.txt", kind: .file), RemoteItem(name: "ok.txt", kind: .file)],
        ])
        let staged = try await export.stage([url("evil")]) { _ in }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staged.items[0].path), ["ok.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staged.directory.path), ["evil"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.url("staging").appending(path: "escaped.txt").path))
    }

    func testStagedFilesAndFoldersAreQuarantined() async throws {
        let staged = try await export.stage([url("src")]) { _ in }
        for item in [staged.items[0], staged.items[0].appending(path: "lib"), staged.items[0].appending(path: "lib/b.txt")] {
            let q = try item.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            XCTAssertEqual(q?["LSQuarantineAgentName"] as? String, RemoteQuarantine.agentName, item.lastPathComponent)
        }
    }

    func testDownloadOfARepositoryRootUsesTheRepoName() async throws {
        fake.setTree(repo: "owner/demo", ["": [RemoteItem(name: "a.txt", kind: .file)]])
        let root = RemoteLocation(provider: "test.fake", repo: "owner/demo", ref: "main").url
        let staged = try await export.stage([root]) { _ in }
        XCTAssertEqual(staged.items.map(\.lastPathComponent), ["demo"])
    }

    /// A folder download (a file promise) that fails partway leaves nothing at the destination.
    func testAFailedFolderDownloadLeavesNothingAtTheDestination() async throws {
        let drop = try sandbox.createDirectory("drop")
        let destination = drop.appending(path: "src")
        let location = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["src"])
        let item = RemoteItem(name: "src", kind: .directory)
        let export = self.export!
        let task = Task {
            try await export.download(location, item: item, to: destination) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        do { try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drop.path), [])
        try await export.download(location, item: item, to: destination) { _ in }
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "lib/b.txt"), encoding: .utf8), "content of src/lib/b.txt")
    }
}

/// Collects progress callbacks from any thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RemoteExport.Progress] = []
    func append(_ p: RemoteExport.Progress) { lock.withLock { items.append(p) } }
    var last: RemoteExport.Progress? { lock.withLock { items.last } }
}
