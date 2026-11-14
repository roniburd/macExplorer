@testable import Core
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import MacxPluginKit
import XCTest

final class RemoteListingSourceTests: XCTestCase {
    private let root = RemoteLocation(provider: "test.fake", repo: "o/r", ref: "main")

    private func world() -> (FakeRemoteProvider, RemoteListingSource) {
        let fake = FakeRemoteProvider()
        fake.setTree(repo: "o/r", ["": [
            RemoteItem(name: "README.md", kind: .file, size: 12, contentID: "b1", modified: Date(timeIntervalSince1970: 10)),
            RemoteItem(name: "Sources", kind: .directory),
            RemoteItem(name: ".github", kind: .directory),
            RemoteItem(name: "run.sh", kind: .file, size: 3, executable: true),
            RemoteItem(name: "vendor", kind: .submodule),
        ]])
        return (fake, RemoteListingSource(registry: ProviderRegistry(builtIns: [fake]), types: .shared))
    }

    private func collect(_ s: AsyncStream<ReadEvent>) async -> [ReadEvent] { var out: [ReadEvent] = []; for await e in s { out.append(e) }; return out }

    func testReadYieldsBatchesThenCompleted() async throws {
        let (_, source) = world()
        let events = await collect(source.read(root.url, generation: .initial, options: ReadOptions()))
        let batches = events.compactMap { if case .batch(let b) = $0 { b } else { nil } }
        XCTAssertEqual(batches.count, 2, "the fake yields two chunks")
        var byName: [String: Entry] = [:]
        for b in batches { for i in 0..<b.count { byName[b.name(at: i)] = b.entries[i] } }
        XCTAssertEqual(Set(byName.keys), ["README.md", "Sources", ".github", "run.sh", "vendor"])
        XCTAssertEqual(byName["README.md"]?.kind, .file)
        XCTAssertEqual(byName["README.md"]?.size, 12)
        XCTAssertEqual(byName["README.md"]?.mtime, 10_000_000_000)
        XCTAssertEqual(byName["Sources"]?.kind, .directory)
        XCTAssertEqual(byName["Sources"]?.typeIndex, TypeRegistry.folderIndex)
        XCTAssertTrue(byName[".github"]!.flags.contains(.dotName))
        XCTAssertTrue(byName["run.sh"]!.flags.contains(.executable))
        XCTAssertEqual(byName["vendor"]?.kind, .other, "submodules are not navigable")
        XCTAssertNotEqual(byName["README.md"]?.rowID, byName["run.sh"]?.rowID)
        guard case .completed(let summary)? = events.last else { return XCTFail("no .completed") }
        XCTAssertEqual(summary.entryCount, 5)
    }

    func testDirectoriesOnly() async {
        let (_, source) = world()
        var options = ReadOptions(); options.directoriesOnly = true
        let names = await collect(source.read(root.url, generation: .initial, options: options)).flatMap { e -> [String] in
            guard case .batch(let b) = e else { return [] }
            return (0..<b.count).map { b.name(at: $0) }
        }
        XCTAssertEqual(Set(names), ["Sources", ".github"])
    }

    func testErrorMapping() async {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(RemoteError, Int32, ReadFailure.Stage, Date?)] = [
            (.notFound, ENOENT, .open, nil), (.noAccess, EACCES, .open, nil), (.rateLimited(resetAt: reset), EAGAIN, .open, reset),
            (.network("down"), ETIMEDOUT, .unresponsiveVolume, nil), (.unsupported, ENOTSUP, .open, nil),
        ]
        for (error, code, stage, resetAt) in cases {
            let (fake, source) = world()
            fake.failNext(error)
            let events = await collect(source.read(root.url, generation: .initial, options: ReadOptions()))
            guard case .failed(let f)? = events.last else { XCTFail("\(error): no .failed"); continue }
            XCTAssertEqual(f, ReadFailure(code: code, stage: stage, resetAt: resetAt), "\(error)")
        }
        XCTAssertEqual(FolderState(ReadFailure(code: EAGAIN, stage: .open, resetAt: reset)), .error(.rateLimited(resetAt: reset)))
        XCTAssertEqual(FolderState(ReadFailure(code: ETIMEDOUT, stage: .unresponsiveVolume)), .unresponsive)
    }

    func testReadItems() async throws {
        let (_, source) = world()
        let result = try await source.readItems(["README.md", "gone"], in: root.url, generation: .initial)
        XCTAssertEqual(result.batch.count, 1)
        XCTAssertEqual(result.batch.name(at: 0), "README.md")
        XCTAssertEqual(result.missing, ["gone"])
    }

    func testUnknownProviderIsNotFound() async {
        let source = RemoteListingSource(registry: ProviderRegistry(builtIns: []), types: .shared)
        let events = await collect(source.read(root.url, generation: .initial, options: ReadOptions()))
        guard case .failed(let f)? = events.last else { return XCTFail("no .failed") }
        XCTAssertEqual(f.code, ENOENT)
    }
}
