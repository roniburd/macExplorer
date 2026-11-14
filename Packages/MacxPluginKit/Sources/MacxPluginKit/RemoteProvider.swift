import Foundation

/// One source of remote repositories (GitHub built in; others from `.macxplugin` bundles). Every method may be
/// called from any thread.
public protocol RemoteProvider: Sendable {
    var id: String { get }                                     // reverse-DNS, also the URL host
    var displayName: String { get }
    var iconSymbol: String { get }                             // SF Symbol name
    func parseAddress(_ text: String) -> RemoteLocation?       // nil = not this provider's syntax
    func completions(for text: String) async -> [String]
    func displayRoot(_ location: RemoteLocation) -> String     // breadcrumb root label
    func webURL(_ location: RemoteLocation) -> URL?            // Copy Path / Open in browser
    func listRefs(repo: String) async throws(RemoteError) -> [RemoteRef]
    func resolveRef(_ location: RemoteLocation) async throws(RemoteError) -> RemoteLocation   // fills the default ref
    /// Items directly inside `location`, in one or more chunks. Throws `RemoteError` only.
    func list(_ location: RemoteLocation) -> AsyncThrowingStream<[RemoteItem], any Error>
    /// Writes the file (or, for a directory, the whole subtree) to `destination`, which does not exist yet.
    func fetch(_ location: RemoteLocation, item: RemoteItem, to destination: URL) async throws(RemoteError)
    func invalidate(repo: String, ref: String?)                // Refresh
}
