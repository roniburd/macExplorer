import Foundation
import MacxPluginKit

/// What a user types or pastes for GitHub (spec §3), parsed without the network.
/// A ref after `/tree/`, `/blob/` or `@` may itself contain "/" (`feature/x`), so it can't be told apart from the path
/// here: the whole remainder goes into `ref` (path `[]`) and `GitHubProvider.resolveRef` splits it against the
/// repository's refs (`split`). A blob URL therefore names the file itself; the address bar selects it in its folder.
public enum GitHubAddress {
    public static let providerID = "dev.macexplorer.github"

    /// First path segments of github.com that are not owners.
    static let reservedOwners: Set<String> = [
        "about", "apps", "collections", "enterprise", "explore", "features", "issues", "login", "marketplace",
        "notifications", "orgs", "pulls", "search", "settings", "sponsors", "topics",
    ]

    public static func parse(_ text: String) -> RemoteLocation? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let first = s.first, first == "'" || first == "\"", s.last == first {
            s = String(s.dropFirst().dropLast())
        }
        if s.lowercased().hasPrefix("gh:") { return parseShort(Substring(s.dropFirst(3))) }
        return parseWeb(Substring(s))
    }

    /// `owner/repo`, then `@ref[/path]` or `/path`.
    static func parseShort(_ body: Substring) -> RemoteLocation? {
        guard let slash = body.firstIndex(of: "/") else { return nil }
        let owner = String(body[..<slash])
        let rest = body[body.index(after: slash)...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "@" }) ?? rest.endIndex
        guard isOwner(owner), let repo = cleanRepo(String(rest[..<end])) else { return nil }
        var ref: String?
        var path: [String] = []
        if end < rest.endIndex {
            let tail = rest[rest.index(after: end)...]
            if rest[end] == "@" {
                let remainder = tail.split(separator: "/").joined(separator: "/")
                guard !remainder.isEmpty else { return nil }
                ref = remainder
            } else {
                path = tail.split(separator: "/").map(String.init)
            }
        }
        return RemoteLocation(provider: providerID, repo: owner + "/" + repo, ref: ref, path: path)
    }

    /// `[http(s)://][www.]github.com/owner/repo[.git][/(tree|blob)/<ref and path>]`; other sub-pages open the root.
    static func parseWeb(_ text: Substring) -> RemoteLocation? {
        var rest = text
        for scheme in ["https://", "http://"] where rest.lowercased().hasPrefix(scheme) {
            rest = rest.dropFirst(scheme.count)
            break
        }
        if rest.lowercased().hasPrefix("www.") { rest = rest.dropFirst(4) }
        guard rest.lowercased().hasPrefix("github.com/") else { return nil }
        rest = rest.dropFirst("github.com/".count)
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<cut] }
        let parts = rest.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2, isOwner(parts[0]), let repo = cleanRepo(parts[1]) else { return nil }
        let full = parts[0] + "/" + repo
        guard parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" else {
            return RemoteLocation(provider: providerID, repo: full, ref: nil, path: [])
        }
        return RemoteLocation(provider: providerID, repo: full, ref: parts[3...].joined(separator: "/"), path: [])
    }

    /// Splits "feature/x/src" into the longest leading run that is a known ref and the path after it. With no match
    /// the first component is the ref (a commit SHA, or a ref beyond the first page of the list).
    public static func split(_ remainder: String, knownRefs: Set<String>) -> (ref: String, path: [String]) {
        let parts = remainder.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return (remainder, []) }
        for count in stride(from: parts.count, through: 1, by: -1) {
            let candidate = parts[..<count].joined(separator: "/")
            if knownRefs.contains(candidate) { return (candidate, Array(parts[count...])) }
        }
        return (parts[0], Array(parts.dropFirst()))
    }

    static func isOwner(_ s: String) -> Bool {
        !reservedOwners.contains(s.lowercased())
            && s.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", options: .regularExpression) != nil
    }

    /// The repository name without ".git", or nil when it isn't one.
    static func cleanRepo(_ s: String) -> String? {
        let name = s.lowercased().hasSuffix(".git") ? String(s.dropLast(4)) : s
        guard name != ".", name != "..", name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return name
    }
}
