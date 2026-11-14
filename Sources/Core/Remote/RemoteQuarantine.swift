import CoreServices
import Foundation

/// Every file and folder written from a remote repository gets the `com.apple.quarantine` attribute, as a browser
/// download of the same file would, so Gatekeeper and the first-launch checks still apply when it is opened.
public enum RemoteQuarantine {
    public static let agentName = "macExplorer"

    /// The quarantine properties of a web download from `webURL` (the item's page on the provider, when it has one).
    public static func properties(webURL: URL?) -> [String: Any] {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let webURL { properties[kLSQuarantineDataURLKey as String] = webURL }
        return properties
    }

    /// Marks `url` (a downloaded file or folder; a symlink is left alone, the attribute would land on its target).
    public static func mark(_ url: URL, webURL: URL?) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return }
        var values = URLResourceValues()
        values.quarantineProperties = properties(webURL: webURL)
        var target = url
        try target.setResourceValues(values)
    }
}
