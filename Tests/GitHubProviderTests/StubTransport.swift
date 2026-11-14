import Foundation
import Synchronization
@testable import GitHubProvider

/// Answers GitHubClient requests from a table (URL string → response); records every request. One per test, so
/// parallel tests never share state. An unknown URL answers 404.
final class StubTransport: Sendable {
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError?
    }

    private let table = Mutex<[String: Response]>([:])
    private let log = Mutex<[URLRequest]>([])

    static let commit = "c0ffee0000000000000000000000000000000001"
    static let api = "https://api.github.com/repos/octo/demo"
    static let raw = "https://raw.githubusercontent.com/octo/demo/" + commit

    func set(_ url: String, _ response: Response) { table.withLock { $0[url] = response } }
    func set(_ url: String, fixture name: String) { set(url, Response(body: Self.fixture(name))) }
    func set(_ url: String, text: String) { set(url, Response(body: Data(text.utf8))) }

    var requests: [URLRequest] { log.withLock { $0 } }
    func count(_ url: String) -> Int { requests.filter { $0.url?.absoluteString == url }.count }

    var transport: GitHubClient.Transport {
        { [self] request in
            log.withLock { $0.append(request) }
            let response = table.withLock { $0[request.url?.absoluteString ?? ""] } ?? Response(status: 404)
            if let error = response.error { throw error }
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                       headerFields: response.headers)!
            return (response.body, http)
        }
    }

    /// The fixture repo `octo/demo` on `main` at `commit`, with the full recursive tree.
    static func demo() -> StubTransport {
        let stub = StubTransport()
        stub.set(api, fixture: "repo")
        stub.set(api + "/commits/main", text: commit)
        stub.set(api + "/git/trees/\(commit)?recursive=1", fixture: "tree-recursive")
        stub.set(api + "/branches?per_page=100", fixture: "branches")
        stub.set(api + "/tags?per_page=100", fixture: "tags")
        return stub
    }

    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
}
