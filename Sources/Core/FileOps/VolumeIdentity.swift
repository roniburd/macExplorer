import Foundation
import MacxFS

/// §6.3 rule 1: same vs cross volume by st_dev of the source and of the destination directory
/// (the parent of every landed item), never by path prefix. Lane only.
enum VolumeIdentity {
    struct Probe: Sendable { var devices: Set<UInt64>; var laneVolume: VolumeID }
    struct Capabilities: Sendable, Equatable { var clone: Bool; var renameExcl: Bool; var caseSensitive: Bool }

    static func device(of path: String) -> UInt64? { PosixFS.info(path)?.identity.device }

    static func isSameVolume(_ source: URL, destinationDirectory: URL) -> Bool {
        guard let a = device(of: source.path), let b = device(of: destinationDirectory.path) else { return false }
        return a == b
    }

    /// Devices of every path (or of its parent when the path does not exist yet) and the fileOp lane key
    /// ("mnt:<mount point of the first path>").
    static func probe(_ urls: [URL]) -> Probe {
        assertOffMain()
        var devices = Set<UInt64>()
        var lane: VolumeID?
        for u in urls {
            let path = PosixFS.exists(u.path) ? u.path : u.deletingLastPathComponent().path
            if let d = device(of: path) { devices.insert(d) }
            if lane == nil, let mp = PosixFS.mountPoint(of: path) { lane = VolumeID(raw: "mnt:" + mp) }
        }
        return Probe(devices: devices, laneVolume: lane ?? .unknown)
    }

    static func capabilities(of directory: URL) -> Capabilities {
        assertOffMain()
        let v = try? URL(filePath: directory.path).resourceValues(forKeys: [
            .volumeSupportsFileCloningKey, .volumeSupportsExclusiveRenamingKey, .volumeSupportsCaseSensitiveNamesKey])
        return Capabilities(clone: v?.volumeSupportsFileCloning ?? false,
                            renameExcl: v?.volumeSupportsExclusiveRenaming ?? false,
                            caseSensitive: v?.volumeSupportsCaseSensitiveNames ?? false)
    }

    /// volumeAvailableCapacityForImportantUsageKey, falling back to volumeAvailableCapacityKey (§6.5).
    static func availableCapacity(of directory: URL) -> (available: Int64?, volumeName: String) {
        assertOffMain()
        let v = try? URL(filePath: directory.path).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey])
        let important = v?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        let available = important ?? v?.volumeAvailableCapacity.map(Int64.init)
        return (available, v?.volumeLocalizedName ?? "")
    }
}
