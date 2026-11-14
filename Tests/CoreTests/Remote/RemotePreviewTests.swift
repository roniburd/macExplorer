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
            "src": [RemoteItem(name: "a.txt", kind: .file, size: 5, contentID: "a1")],
        ])
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

    func testLocalCopiesPassFileURLsThroughAndReportFailures() async throws {
        let plain = sandbox.url("x.txt")
        let result = await RemotePreview.localCopies([plain, url("src", "a.txt"), url("gone.txt")], registry: registry, cache: cache)
        XCTAssertEqual(result.local.count, 2)
        XCTAssertEqual(result.local.first, plain)
        XCTAssertTrue(result.local[1].isFileURL)
        XCTAssertEqual(result.failed, [url("gone.txt")])
    }
}
