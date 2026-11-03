import Foundation
import MacxFS

public enum ProtectedLocations {
    /// Pure, in-memory: classifies a URL (home-relative Desktop/Documents/Downloads, iCloud Drive, or the volume kind).
    /// `volume` is the volume containing `url` (or nil when unknown). Home-relative folders win over the volume kind.
    /// Paths are compared standardized, with `/private/var` ≡ `/var` (and `/tmp`, `/etc`), and case-insensitively.
    public static func classify(_ url: URL, home: URL, volume: VolumeInfo?) -> ProtectedLocation? {
        let path = components(url)
        let base = components(home)
        if path.count > base.count, zip(base, path).allSatisfy({ same($0, $1) }) {
            let rest = Array(path[base.count...])
            switch rest[0].lowercased() {
            case "desktop": return .desktop
            case "documents": return .documents
            case "downloads": return .downloads
            case "library" where rest.count > 1 && same(rest[1], "Mobile Documents"): return .iCloudDrive
            default: break
            }
        }
        guard let volume, !volume.isBoot else { return nil }
        if !volume.isLocal { return .networkVolume(volume.id) }
        if volume.isRemovable || volume.isEjectable || !volume.isInternal { return .removableVolume(volume.id) }
        return nil
    }

    private static let firmlinked: Set<String> = ["var", "tmp", "etc"]

    /// Standardized path components without "/", with a leading "private" dropped before var/tmp/etc.
    private static func components(_ url: URL) -> [String] {
        var parts = url.standardizedFileURL.path(percentEncoded: false).split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "private", firmlinked.contains(parts[1]) { parts.removeFirst() }
        return parts
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive]) == .orderedSame
    }
}
