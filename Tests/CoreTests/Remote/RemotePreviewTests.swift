@testable import Core
import Foundation
import MacxFixtures
import MacxFS
import MacxPluginKit
import XCTest

final class RemotePreviewTests: XCTestCase {
    var sandbox: Sandbox!
    var fake: FakeRemoteProvider!
    var registry: ProviderRegistry!
    var cache: RemoteFileCache!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        fake = FakeRemoteProvider()
        fake.setTree(repo: "demo", [
            "": [RemoteItem(name: "src", kind: .directory), RemoteItem(name: "big.bin", kind: .file, size: 11 << 20, contentID: "b1")],
            "src": [RemoteItem(name: "a.txt", kind: .file, size: 5, contentID: "a1"),
                    RemoteItem(name: "link.txt", kind: .symlink, size: 5),
                    RemoteItem(name: "up", kind: .symlink, size: 2),
                    RemoteItem(name: "out", kind: .symlink, size: 9),
                    RemoteItem(name: "abs", kind: .symlink, size: 4),
                    RemoteItem(name: "loop", kind: .symlink, size: 4)],
        ])
        fake.setLinkTarget(repo: "demo", path: "src/link.txt", "./a.txt")
        fake.setLinkTarget(repo: "demo", path: "src/up", "..")
        fake.setLinkTarget(repo: "demo", path: "src/out", "../../etc")
        fake.setLinkTarget(repo: "demo", path: "src/abs", "/etc/hosts")
        fake.setLinkTarget(repo: "demo", path: "src/loop", "loop")
        registry = ProviderRegistry(builtIns: [fake])
        cache = RemoteFileCache(root: try sandbox.createDirectory("cache"))
    }

    private func url(_ path: String...) -> URL {
        RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: path).url
    }

    func testFolderNeedsNoDownload() async {
        let d = await RemotePreview.prepare(url("src"), registry: registry, cache: cache, force: false)
        XCTAssertEqual(d, .folder)
        XCTAssertEqual(fake.fetchCount, 0)
    }

    func testSmallFileIsDownloadedAndLocal() async throws {
        let d = await RemotePreview.prepare(url("src", "a.txt"), registry: registry, cache: cache, force: false)
        guard case .local(let local) = d else { return XCTFail("got \(d)") }
        XCTAssertTrue(local.isFileURL)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "content of src/a.txt")
    }

    func testLargeFileWaitsForTheUserUnlessForced() async {
        let auto = await RemotePreview.prepare(url("big.bin"), registry: registry, cache: cache, force: false)
        XCTAssertEqual(auto, .needsDownload(size: 11 << 20))
        XCTAssertEqual(fake.fetchCount, 0, "nothing fetched before the user asks")
        let forced = await RemotePreview.prepare(url("big.bin"), registry: registry, cache: cache, force: true)
        guard case .local = forced else { return XCTFail("got \(forced)") }
    }

    func testMissingItemFailsWithENOENT() async {
        let d = await RemotePreview.prepare(url("src", "nope.txt"), registry: registry, cache: cache, force: false)
        XCTAssertEqual(d, .failed(code: ENOENT))
    }

    func testRateLimitMapsToItsErrno() async {
        fake.failAlways(.rateLimited(resetAt: nil))
        let d = await RemotePreview.prepare(url("src", "a.txt"), registry: registry, cache: cache, force: false)
        XCTAssertEqual(d, .failed(code: EAGAIN))
    }

    /// Review (Task 11): a remote symlink previews and opens as the repository item it points to.
    func testSymlinkIsFollowedInsideTheRepository() async throws {
        let d = await RemotePreview.prepare(url("src", "link.txt"), registry: registry, cache: cache, force: false)
        guard case .local(let local) = d else { return XCTFail("got \(d)") }
        XCTAssertEqual(local.lastPathComponent, "a.txt")
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "content of src/a.txt")
        let copies = await RemotePreview.localCopies([url("src", "link.txt")], registry: registry, cache: cache)
        XCTAssertEqual(copies.failed, [])
        XCTAssertEqual(copies.local, [local])
        let folder = await RemotePreview.prepare(url("src", "up"), registry: registry, cache: cache, force: false)
        XCTAssertEqual(folder, .folder, "a link to a folder is a folder")
    }

    func testSymlinksOutsideTheRepositoryOrInALoopFail() async {
        let out = await RemotePreview.prepare(url("src", "out"), registry: registry, cache: cache, force: false)
        XCTAssertEqual(out, .failed(code: ENOENT))
        let abs = await RemotePreview.prepare(url("src", "abs"), registry: registry, cache: cache, force: false)
        XCTAssertEqual(abs, .failed(code: ENOENT))
        let loop = await RemotePreview.prepare(url("src", "loop"), registry: registry, cache: cache, force: false)
        XCTAssertEqual(loop, .failed(code: ELOOP))
        let partials = sandbox.url("cache/.partial")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: partials.path(percentEncoded: false))) ?? [], [],
                       "no scratch link is left behind")
    }

    func testResolveStaysInsideTheRepository() {
        let file = RemoteLocation(provider: "p", repo: "r", ref: "dev", path: ["docs", "README.md"])
        XCTAssertEqual(RemotePreview.resolve("guide.md", from: file, absoluteFromRoot: false)?.path, ["docs", "guide.md"])
        XCTAssertEqual(RemotePreview.resolve("./img/../a.png", from: file, absoluteFromRoot: false)?.path, ["docs", "a.png"])
        XCTAssertEqual(RemotePreview.resolve("../src/x.swift", from: file, absoluteFromRoot: false)?.ref, "dev")
        XCTAssertNil(RemotePreview.resolve("../../x", from: file, absoluteFromRoot: false))
        XCTAssertNil(RemotePreview.resolve("/x", from: file, absoluteFromRoot: false))
        XCTAssertEqual(RemotePreview.resolve("/x/y", from: file, absoluteFromRoot: true)?.path, ["x", "y"])
    }

    /// Review (Task 11): a cancelled request starts no further downloads.
    func testCancelledLocalCopiesStartNoDownloads() async {
        let urls = [url("src", "a.txt"), url("big.bin")]
        let task = Task { [registry, cache] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await RemotePreview.localCopies(urls, registry: registry!, cache: cache!)
        }
        let result = await task.value
        XCTAssertEqual(result.local, [])
        XCTAssertEqual(result.failed, urls)
        XCTAssertEqual(fake.fetchCount, 0)
    }

    func testLocalCopiesPassFileURLsThroughAndReportFailures() async throws {
        let plain = sandbox.url("x.txt")
        let result = await RemotePreview.localCopies([plain, url("src", "a.txt"), url("gone.txt")], registry: registry, cache: cache)
        XCTAssertEqual(result.local.count, 2)
        XCTAssertEqual(result.local.first, plain)
        XCTAssertTrue(result.local[1].isFileURL)
        XCTAssertEqual(result.failed, [url("gone.txt")])
    }
}
