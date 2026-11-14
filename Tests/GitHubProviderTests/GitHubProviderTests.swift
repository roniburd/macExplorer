import XCTest
import MacxFixtures
import MacxPluginKit
@testable import GitHubProvider

final class GitHubProviderTests: XCTestCase {
    private let commit = StubTransport.commit
    private let api = StubTransport.api

    private func provider(_ stub: StubTransport) -> GitHubProvider {
        GitHubProvider(transport: stub.transport, appVersion: "9.9")
    }
    private func loc(_ ref: String? = nil, _ path: [String] = []) -> RemoteLocation {
        RemoteLocation(provider: GitHubAddress.providerID, repo: "octo/demo", ref: ref, path: path)
    }
    private func list(_ p: GitHubProvider, _ l: RemoteLocation) async throws -> [RemoteItem] {
        var all: [RemoteItem] = []
        for try await chunk in p.list(l) { all += chunk }
        return all
    }

    func testDefaultBranchThenOneTreeRequestServesEveryFolder() async throws {
        let stub = StubTransport.demo()
        let p = provider(stub)
        let root = try await list(p, loc())
        XCTAssertEqual(root.map(\.name).sorted(), ["README.md", "docs", "empty", "src", "vendor"])
        let src = try await list(p, loc("main", ["src"]))
        XCTAssertEqual(src.map(\.name).sorted(), ["link", "main.swift", "tool.sh"])
        let empty = try await list(p, loc("main", ["empty"]))
        XCTAssertEqual(empty, [])
        XCTAssertEqual(stub.count(api + "/git/trees/\(commit)?recursive=1"), 1)
        XCTAssertEqual(stub.count(api + "/commits/main"), 1)
        XCTAssertEqual(stub.count(api), 1)
    }

    func testItemKindsSizesAndContentIDsFollowTheTree() async throws {
        let p = provider(StubTransport.demo())
        let byName = Dictionary(uniqueKeysWithValues: try await list(p, loc("main", ["src"])).map { ($0.name, $0) })
        XCTAssertEqual(byName["main.swift"]?.kind, .file)
        XCTAssertEqual(byName["main.swift"]?.size, 20)
        XCTAssertEqual(byName["main.swift"]?.contentID, "b2")
        XCTAssertEqual(byName["tool.sh"]?.executable, true)
        XCTAssertEqual(byName["link"]?.kind, .symlink)
        let root = Dictionary(uniqueKeysWithValues: try await list(p, loc("main")).map { ($0.name, $0) })
        XCTAssertEqual(root["vendor"]?.kind, .submodule)
        XCTAssertEqual(root["docs"]?.kind, .directory)
        XCTAssertNil(root["docs"]?.size)
    }

    func testMissingFolderAndFileAsFolderAreNotFound() async {
        let p = provider(StubTransport.demo())
        for path in [["nope"], ["README.md"]] {
            do { _ = try await list(p, loc("main", path)); XCTFail("\(path)") }
            catch { XCTAssertEqual(error as? RemoteError, .notFound, "\(path)") }
        }
    }

    func testTruncatedTreeFallsBackToOneRequestPerFolder() async throws {
        let stub = StubTransport.demo()
        stub.set(api + "/git/trees/\(commit)?recursive=1", fixture: "tree-truncated")
        stub.set(api + "/git/trees/\(commit)", fixture: "tree-root")
        stub.set(api + "/git/trees/t1", fixture: "tree-src")
        let p = provider(stub)
        // The truncated chunk names `docs` but was cut off before `src`: nothing in it is trusted.
        let root = try await list(p, loc("main"))
        XCTAssertEqual(root.map(\.name).sorted(), ["README.md", "src"], "the root comes from the non-recursive listing")
        let src = try await list(p, loc("main", ["src"]))
        XCTAssertEqual(src.map(\.name), ["main.swift"])
        _ = try await list(p, loc("main", ["src"]))
        _ = try await list(p, loc("main"))
        XCTAssertEqual(stub.count(api + "/git/trees/t1"), 1, "a folder listed once is cached")
        XCTAssertEqual(stub.count(api + "/git/trees/\(commit)"), 1, "the root is listed non-recursively once")
        do { _ = try await list(p, loc("main", ["docs"])); XCTFail("docs is not in the real root") }
        catch { XCTAssertEqual(error as? RemoteError, .notFound) }
        XCTAssertEqual(stub.count(api + "/git/trees/t2"), 0, "a SHA from the truncated chunk is never used")
    }

    func testUnknownRefIsNotFound() async {
        let stub = StubTransport.demo()
        stub.set(api + "/commits/typo", .init(status: 422, body: Data(#"{"message":"No commit found for SHA: typo"}"#.utf8)))
        do { _ = try await list(provider(stub), loc("typo")); XCTFail("a 422 ref is not found") }
        catch { XCTAssertEqual(error as? RemoteError, .notFound) }
    }

    func testRefsAreBranchesThenTags() async throws {
        let refs = try await provider(StubTransport.demo()).listRefs(repo: "octo/demo")
        XCTAssertEqual(refs.map(\.name), ["main", "feature/x", "v1.0"])
        XCTAssertEqual(refs.map(\.kind), [.branch, .branch, .tag])
        XCTAssertEqual(refs.first?.commit, "c0ffee0000000000000000000000000000000001")
    }

    func testResolveRefFillsTheDefaultAndSplitsSlashRefs() async throws {
        let stub = StubTransport.demo()
        let p = provider(stub)
        let resolvedDefault = try await p.resolveRef(loc())
        XCTAssertEqual(resolvedDefault, loc("main"))
        let resolvedSlash = try await p.resolveRef(loc("feature/x/src/lib"))
        XCTAssertEqual(resolvedSlash, loc("feature/x", ["src", "lib"]))
        let parsed = try await p.resolveRef(GitHubAddress.parse("gh:octo/demo@main/docs")!)
        XCTAssertEqual(parsed, loc("main", ["docs"]))
        let again = try await p.resolveRef(loc("feature/x", ["src"]))
        XCTAssertEqual(again, loc("feature/x", ["src"]), "resolving a resolved location changes nothing")
        let plain = try await p.resolveRef(loc("v1.0", ["a"]))
        XCTAssertEqual(plain, loc("v1.0", ["a"]))
        XCTAssertEqual(stub.count(api + "/branches?per_page=100"), 1,
                       "refs are listed only for refs with a slash, and only once (cached)")
    }

    func testFetchFileWritesTheRawBytes() async throws {
        let stub = StubTransport.demo()
        stub.set(StubTransport.raw + "/src/main.swift", text: "print(\"hi\")\n")
        let p = provider(stub)
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let item = try await list(p, loc("main", ["src"])).first { $0.name == "main.swift" }!
        let destination = sandbox.root.appending(path: "main.swift")
        try await p.fetch(loc("main", ["src", "main.swift"]), item: item, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "print(\"hi\")\n")
    }

    func testFetchFolderCopiesTheSubtreeAndSkipsSubmodules() async throws {
        let stub = StubTransport.demo()
        stub.set(StubTransport.raw + "/README.md", text: "readme")
        stub.set(StubTransport.raw + "/docs/guide.md", text: "guide")
        stub.set(StubTransport.raw + "/src/main.swift", text: "main")
        stub.set(StubTransport.raw + "/src/tool.sh", text: "tool")
        stub.set(StubTransport.raw + "/src/link", text: "main.swift")
        let p = provider(stub)
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let rootItem = RemoteItem(name: "demo", kind: .directory)
        let destination = sandbox.root.appending(path: "demo", directoryHint: .isDirectory)
        try await p.fetch(loc("main"), item: rootItem, to: destination)
        let fm = FileManager.default
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "docs/guide.md"), encoding: .utf8), "guide")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: destination.appending(path: "src/link").path), "main.swift")
        XCTAssertTrue(fm.isExecutableFile(atPath: destination.appending(path: "src/tool.sh").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appending(path: "empty").path))
        XCTAssertFalse(fm.fileExists(atPath: destination.appending(path: "vendor").path))
    }

    func testFetchSubmoduleIsUnsupported() async throws {
        let p = provider(StubTransport.demo())
        let vendor = RemoteItem(name: "vendor", kind: .submodule)
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        do { try await p.fetch(loc("main", ["vendor"]), item: vendor, to: sandbox.root.appending(path: "v")); XCTFail() }
        catch { XCTAssertEqual(error, .unsupported) }
    }

    func testHTTPErrorsMapToRemoteErrors() async {
        let reset = 1_900_000_000
        let cases: [(StubTransport.Response, RemoteError)] = [
            (.init(status: 404), .notFound),
            (.init(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"]),
             .rateLimited(resetAt: Date(timeIntervalSince1970: TimeInterval(reset)))),
            (.init(status: 429), .rateLimited(resetAt: nil)),
            (.init(status: 403, headers: ["x-ratelimit-remaining": "12"]), .noAccess),
            (.init(status: 401), .noAccess),
            (.init(status: 502), .network("HTTP 502")),
            (.init(error: URLError(.notConnectedToInternet)), .network(URLError(.notConnectedToInternet).localizedDescription)),
        ]
        for (response, expected) in cases {
            let stub = StubTransport()
            stub.set(api, response)
            do { _ = try await provider(stub).resolveRef(loc()); XCTFail("\(expected)") }
            catch { XCTAssertEqual(error, expected) }
        }
    }

    /// Review Focus 4: once the recursive tree is cached, a rate limit only fails new repos, refs or a Refresh.
    func testRateLimitAfterAWarmCacheKeepsListingCachedFolders() async throws {
        let stub = StubTransport.demo()
        let p = provider(stub)
        _ = try await list(p, loc())
        let limited = StubTransport.Response(status: 403, headers: ["x-ratelimit-remaining": "0"])
        for url in [api, api + "/commits/main", api + "/commits/v1.0", api + "/git/trees/\(commit)?recursive=1",
                    api + "/branches?per_page=100", api + "/tags?per_page=100"] {
            stub.set(url, limited)
        }
        let src = try await list(p, loc("main", ["src"]))
        XCTAssertEqual(src.map(\.name).sorted(), ["link", "main.swift", "tool.sh"])
        let root = try await list(p, loc())
        XCTAssertEqual(root.count, 5, "the default branch is cached too")
        do { _ = try await list(p, loc("v1.0")); XCTFail("new ref") }
        catch { XCTAssertEqual(error as? RemoteError, .rateLimited(resetAt: nil)) }
        p.invalidate(repo: "octo/demo", ref: "main")
        do { _ = try await list(p, loc("main", ["src"])); XCTFail("after Refresh") }
        catch { XCTAssertEqual(error as? RemoteError, .rateLimited(resetAt: nil)) }
    }

    func testRequestsIdentifyTheApp() async throws {
        let stub = StubTransport.demo()
        _ = try await provider(stub).resolveRef(loc())
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "macExplorer/9.9")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "v1 is anonymous")
    }

    func testInvalidateDropsTheCommitAndTree() async throws {
        let stub = StubTransport.demo()
        let p = provider(stub)
        _ = try await list(p, loc("main"))
        p.invalidate(repo: "octo/demo", ref: "main")
        _ = try await list(p, loc("main"))
        XCTAssertEqual(stub.count(api + "/commits/main"), 2)
        XCTAssertEqual(stub.count(api + "/git/trees/\(commit)?recursive=1"), 2)
    }

    func testWebURLUsesBlobForListedFiles() async throws {
        let p = provider(StubTransport.demo())
        _ = try await list(p, loc("main", ["src"]))
        XCTAssertEqual(p.webURL(loc("main", ["src", "main.swift"]))?.absoluteString,
                       "https://github.com/octo/demo/blob/main/src/main.swift")
        XCTAssertEqual(p.webURL(loc("main", ["src"]))?.absoluteString, "https://github.com/octo/demo/tree/main/src")
    }

    func testCompletionsOfferTheShortPrefixAndCachedRefs() async throws {
        let p = provider(StubTransport.demo())
        let shortPrefix = await p.completions(for: "g")
        XCTAssertEqual(shortPrefix, ["gh:"])
        _ = try await p.listRefs(repo: "octo/demo")
        let refs = await p.completions(for: "gh:octo/demo@fe")
        XCTAssertEqual(refs, ["gh:octo/demo@feature/x"])
        let unknownRepo = await p.completions(for: "gh:other/repo@m")
        XCTAssertEqual(unknownRepo, [])
    }
}
