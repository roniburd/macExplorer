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

    /// True when `id` can be a provider id (and so the URL host): dot-separated, non-empty labels of ASCII letters,
    /// digits and "-", e.g. "dev.macexplorer.github". `ProviderRegistry` refuses providers whose id is not valid.
    public static func isValidProviderID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 253
            && id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                !label.isEmpty && label.unicodeScalars.allSatisfy { $0.isASCII && providerIDCharacters.contains($0) }
            }
    }

    /// Never fails. A `provider` that is not a valid id (`isValidProviderID`) gives a URL with no host, which
    /// `init?(url:)` (and so `ProviderRegistry`) rejects, rather than a URL that parses back as another location.
    public var url: URL {
        var first = Self.encode(repo)
        if let ref { first += "@" + Self.encode(ref) }
        let tail = ([first] + path.map(Self.encode)).joined(separator: "/")
        var components = URLComponents()
        components.scheme = Self.scheme
        components.percentEncodedHost = Self.isValidProviderID(provider) ? provider : ""
        components.percentEncodedPath = "/" + tail
        // The host is a valid id or empty and the path is unreserved text plus "%", "@" and "/", so this always parses.
        guard let url = components.url else { preconditionFailure("RemoteLocation: unparseable URL \(components)") }
        return url
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host(percentEncoded: false), Self.isValidProviderID(host) else {
            return nil
        }
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
    private static let providerIDCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
}
