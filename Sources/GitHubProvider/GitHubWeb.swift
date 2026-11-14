import Foundation
import MacxPluginKit

/// Labels and github.com links for a location (spec §3: breadcrumb root, Copy Path, "Open on GitHub").
public enum GitHubWeb {
    public static func displayRoot(_ location: RemoteLocation) -> String { location.repo }

    /// `https://github.com/o/r` at the root of the default branch, else `…/tree|blob/<ref>/<path>` ("HEAD" when the
    /// ref is not resolved yet). `isFile` picks blob.
    public static func webURL(_ location: RemoteLocation, isFile: Bool) -> URL? {
        var text = "https://github.com/" + location.repo.split(separator: "/").map { escapedComponent(String($0)) }
            .joined(separator: "/")
        if location.ref != nil || !location.path.isEmpty {
            text += "/" + (isFile ? "blob" : "tree") + "/" + escapedRef(location.ref ?? "HEAD")
            for component in location.path { text += "/" + escapedComponent(component) }
        }
        return URL(string: text)
    }

    /// A ref keeps its "/" (GitHub's web routes and API both accept `feature/x` as is); each piece is escaped.
    static func escapedRef(_ ref: String) -> String {
        ref.split(separator: "/", omittingEmptySubsequences: false).map { escapedComponent(String($0)) }
            .joined(separator: "/")
    }

    static func escapedComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }
}
