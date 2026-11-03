import Foundation
import CoreGraphics
import MacxFS

/// One breadcrumb segment: the volume root (index 0) or one path component below it (§5.2).
struct BreadcrumbSegment: Equatable {
    var title: String
    var url: URL
    var isVolumeRoot: Bool
    /// SF Symbol for the volume segment (nil for folders).
    var symbolName: String? = nil
}

/// Pure breadcrumb math (no file-system access).
enum BreadcrumbPath {
    /// Segments from the volume to `directory`. Index 0 is the volume root, then one segment per path component below
    /// it: the same indexing as the scenario "crumb:<index>" drop target (P1-36 `DropDestinationResolver.crumbURL`).
    /// A missing volume, or one that does not contain `directory`, falls back to "/" titled "/".
    static func segments(for directory: URL, volume: VolumeInfo?) -> [BreadcrumbSegment] {
        let slash = URL(filePath: "/", directoryHint: .isDirectory)
        let components = directory.standardizedFileURL.pathComponents
        var root = slash
        var title = "/"
        var symbol = "internaldrive"
        if let volume {
            let mount = volume.mountPoint.standardizedFileURL
            if components.starts(with: mount.pathComponents) {
                root = mount
                if !volume.name.isEmpty { title = volume.name }
                symbol = symbolName(for: volume)
            }
        }
        let rootCount = root.pathComponents.count
        var url = root
        var segments = [BreadcrumbSegment(title: title, url: url, isVolumeRoot: true, symbolName: symbol)]
        for component in components.dropFirst(rootCount) {
            url.append(path: component, directoryHint: .isDirectory)
            segments.append(BreadcrumbSegment(title: component, url: url, isVolumeRoot: false))
        }
        return segments
    }

    static func symbolName(for volume: VolumeInfo) -> String {
        if !volume.isLocal { return "network" }
        if volume.isEjectable || volume.isRemovable || !volume.isInternal { return "externaldrive" }
        return "internaldrive"
    }

    /// The edit-mode text: the POSIX path as given (no standardization: /private/var stays as is), no trailing slash.
    static func posixPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// How many leading segments collapse into the « menu so the rest fits in `available`. Each segment costs its
    /// width plus a chevron; collapsing adds the « button. The last segment (the current folder) always stays.
    static func collapsedCount(segmentWidths: [CGFloat], chevronWidth: CGFloat, overflowWidth: CGFloat,
                               available: CGFloat) -> Int {
        let costs = segmentWidths.map { $0 + chevronWidth }
        guard !costs.isEmpty, costs.reduce(0, +) > available else { return 0 }
        var remaining = costs.reduce(0, +)
        for k in 1..<costs.count {
            remaining -= costs[k - 1]
            if overflowWidth + remaining <= available { return k }
        }
        return costs.count - 1
    }
}
