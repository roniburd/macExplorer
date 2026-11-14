import Foundation
import MacxPluginKit

/// Anonymous GitHub REST + raw.githubusercontent.com (spec §3). Every failure is a RemoteError.
struct GitHubClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let api = "https://api.github.com"
    static let raw = "https://raw.githubusercontent.com"

    let transport: Transport
    let userAgent: String

    struct RepoInfo: Decodable { let defaultBranch: String
        enum CodingKeys: String, CodingKey { case defaultBranch = "default_branch" } }
    struct NamedRef: Decodable { let name: String; let commit: Commit
        struct Commit: Decodable { let sha: String } }
    struct TreeResponse: Decodable { let sha: String; let truncated: Bool?; let tree: [TreeEntry] }
    struct TreeEntry: Decodable, Sendable, Equatable {
        let path: String, mode: String, type: String, sha: String
        let size: Int64?
    }

    /// `/repos/o/r` with each piece escaped.
    static func repoPath(_ repo: String) -> String {
        "/repos/" + repo.split(separator: "/").map { GitHubWeb.escapedComponent(String($0)) }.joined(separator: "/")
    }

    func defaultBranch(_ repo: String) async throws(RemoteError) -> String {
        try await json(RepoInfo.self, Self.api + Self.repoPath(repo)).defaultBranch
    }

    /// The commit a branch, tag or SHA names. The whole ref is one escaped path piece ("feature%2Fx").
    func commit(_ repo: String, ref: String) async throws(RemoteError) -> String {
        let url = Self.api + Self.repoPath(repo) + "/commits/" + GitHubWeb.escapedComponent(ref)
        let text = String(decoding: try await data(url, accept: "application/vnd.github.sha"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 40, text.allSatisfy(\.isHexDigit) else { throw .network("unexpected response") }
        return text
    }

    func tree(_ repo: String, sha: String, recursive: Bool) async throws(RemoteError) -> TreeResponse {
        try await json(TreeResponse.self, Self.api + Self.repoPath(repo) + "/git/trees/" + sha
                       + (recursive ? "?recursive=1" : ""))
    }

    func refs(_ repo: String, kind: String) async throws(RemoteError) -> [NamedRef] {
        try await json([NamedRef].self, Self.api + Self.repoPath(repo) + "/" + kind + "?per_page=100")
    }

    func raw(_ repo: String, commit: String, path: String) async throws(RemoteError) -> Data {
        let escaped = path.split(separator: "/").map { GitHubWeb.escapedComponent(String($0)) }.joined(separator: "/")
        return try await data(Self.raw + "/" + repo + "/" + commit + "/" + escaped, accept: "*/*")
    }

    func json<T: Decodable>(_ type: T.Type, _ url: String) async throws(RemoteError) -> T {
        let body = try await data(url, accept: "application/vnd.github+json")
        do { return try JSONDecoder().decode(T.self, from: body) } catch { throw .network("unexpected response") }
    }

    func data(_ urlString: String, accept: String) async throws(RemoteError) -> Data {
        guard let url = URL(string: urlString) else { throw .network("bad URL") }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let body: Data
        let response: URLResponse
        do { (body, response) = try await transport(request) } catch { throw .network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw .network("not HTTP") }
        if let error = Self.error(status: http.statusCode, response: http) { throw error }
        return body
    }

    /// 404 → notFound; 429, or 403 with no requests left → rateLimited(reset); other 401/403 → noAccess; else network.
    static func error(status: Int, response: HTTPURLResponse) -> RemoteError? {
        switch status {
        case 200..<300: return nil
        case 404: return .notFound
        case 403, 429:
            if status == 429 || response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
                return .rateLimited(resetAt: reset.map { Date(timeIntervalSince1970: $0) })
            }
            return .noAccess
        case 401: return .noAccess
        default: return .network("HTTP \(status)")
        }
    }
}
