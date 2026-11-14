import Foundation

/// A folder or file inside a provider's repository, and its `x-macexplorer-remote` URL:
/// `x-macexplorer-remote://<provider>/<repo>@<ref>/<path…>` with repo, ref and each path component percent-encoded
/// (repo and ref encode "/" and "@"; a literal "@" in the first component separates them).
public struct RemoteLocation: Sendable, Hashable, Codable {
    public static let scheme = "x-macexplorer-remote"

    public var provider: String
    public var repo: String
    public var ref: String?
    public var path: [String]

    public init(provider: String, repo: String, ref: String? = nil, path: [String] = []) {
        self.provider = provider
        self.repo = repo
        self.ref = ref
        self.path = path
    }

    public var url: URL {
        var first = Self.encode(repo)
        if let ref { first += "@" + Self.encode(ref) }
        let tail = ([first] + path.map(Self.encode)).joined(separator: "/")
        return URL(string: "\(Self.scheme)://\(provider)/\(tail)")!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let pieces = first.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let repo = String(pieces[0]).removingPercentEncoding, !repo.isEmpty else { return nil }
        var ref: String?
        if pieces.count == 2 {
            guard let decoded = String(pieces[1]).removingPercentEncoding, !decoded.isEmpty else { return nil }
            ref = decoded
        }
        var path: [String] = []
        for part in parts.dropFirst() {
            guard let decoded = String(part).removingPercentEncoding, !decoded.isEmpty else { return nil }
            path.append(decoded)
        }
        self.init(provider: host, repo: repo, ref: ref, path: path)
    }

    public func appending(_ name: String) -> RemoteLocation {
        RemoteLocation(provider: provider, repo: repo, ref: ref, path: path + [name])
    }

    /// nil at the repository root.
    public var parent: RemoteLocation? {
        path.isEmpty ? nil : RemoteLocation(provider: provider, repo: repo, ref: ref, path: Array(path.dropLast()))
    }

    /// The last path component; nil at the repository root.
    public var name: String? { path.last }

    public func withRef(_ ref: String?) -> RemoteLocation { RemoteLocation(provider: provider, repo: repo, ref: ref, path: path) }

    /// "a/b"; "" at the root.
    public var pathString: String { path.joined(separator: "/") }

    /// RFC 3986 unreserved characters only, so "/", "@", "%", "#", "?" and spaces are always encoded.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved)! }
}
