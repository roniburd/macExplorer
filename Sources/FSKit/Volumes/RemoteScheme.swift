import Foundation

/// The URL scheme of remote (provider) folders. MacxFS can't import MacxPluginKit; a Core test asserts this equals
/// `RemoteLocation.scheme`.
public enum RemoteScheme {
    public static let name = "x-macexplorer-remote"
    public static func isRemote(_ url: URL) -> Bool { url.scheme == name }
}

extension VolumeInfo {
    /// The synthetic read-only volume of a remote URL's repository (one per provider + repo, any ref); nil for other
    /// URLs. Identity is by case-sensitive name (no inodes); never local, browsable, ejectable or boot.
    public static func remote(url: URL) -> VolumeInfo? {
        guard RemoteScheme.isRemote(url), let host = url.host(percentEncoded: false), !host.isEmpty,
              let first = url.path(percentEncoded: true).split(separator: "/").first else { return nil }
        let repoEncoded = first.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !repoEncoded.isEmpty, let root = URL(string: "\(RemoteScheme.name)://\(host)/\(first)") else { return nil }
        return VolumeInfo(id: VolumeID(raw: "remote:\(host):\(repoEncoded)"), mountPoint: root,
                          name: String(repoEncoded).removingPercentEncoding ?? String(repoEncoded),
                          format: "Remote repository", isBoot: false, isInternal: false, isRemovable: false,
                          isEjectable: false, isLocal: false, isReadOnly: true, isBrowsable: false, totalCapacity: nil,
                          capabilities: VolumeCapabilities(idStable: false, renameExcl: false, clone: false, caseSensitive: true))
    }
}
