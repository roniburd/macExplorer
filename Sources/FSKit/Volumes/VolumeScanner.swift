import CFSKit
import Foundation

public protocol VolumeScanning: Sendable {
    /// Synchronous; called inside lane work. Includes hidden volumes (mount table needs them); isBrowsable marks sidebar ones.
    func scan() throws -> [VolumeInfo]
    /// volumeAvailableCapacityForImportantUsageKey, fallback volumeAvailableCapacityKey. Synchronous; lane only.
    func availableCapacity(of mountPoint: URL) -> Int64?
}

public struct SystemVolumeScanner: VolumeScanning {
    public init() {}

    static let keys: [URLResourceKey] = [
        .volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
        .volumeIsBrowsableKey, .volumeTotalCapacityKey, .volumeSupportsCaseSensitiveNamesKey,
    ]

    /// The sealed system volume "/" is read-only and every user path is on the Data volume through firmlinks
    /// (/Users, /Applications, …). The boot entry therefore takes the Data volume's capabilities and
    /// writability, so lookups by path ("/Users/x" → "/") see the volume that actually holds the files.
    static let dataVolumePath = "/System/Volumes/Data"

    public func scan() throws -> [VolumeInfo] {
        assertOffMain()
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys, options: []) ?? []
        var volumes = urls.compactMap(Self.info)
        if let data = volumes.first(where: { $0.mountPoint.path(percentEncoded: false) == Self.dataVolumePath }),
           let boot = volumes.firstIndex(where: { $0.isBoot }) {
            volumes[boot].capabilities = data.capabilities
            volumes[boot].isReadOnly = data.isReadOnly
        }
        return volumes
    }

    public func availableCapacity(of mountPoint: URL) -> Int64? {
        assertOffMain()
        let values = try? mountPoint.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let plain = values?.volumeAvailableCapacity.map(Int64.init)
        // Non-APFS volumes (HFS+, FAT, exFAT images) report 0 for the "important usage" key: treat as unknown.
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 || (plain ?? 0) == 0 { return important }
        return plain
    }

    static func info(_ url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let path = url.path(percentEncoded: false)
        var caps = cfsk_volcaps()
        let hasCaps = cfsk_volume_caps(path, &caps) == 0
        let caseSensitive = v.volumeSupportsCaseSensitiveNames ?? (hasCaps && caps.case_sensitive != 0)
        let id = v.volumeUUIDString.map { VolumeID(raw: "uuid:" + $0) } ?? VolumeID(raw: "mnt:" + path)
        return VolumeInfo(
            id: id, mountPoint: URL(filePath: path, directoryHint: .isDirectory),
            name: v.volumeLocalizedName ?? (path as NSString).lastPathComponent,
            format: v.volumeLocalizedFormatDescription ?? "",
            isBoot: v.volumeIsRootFileSystem ?? (path == "/"), isInternal: v.volumeIsInternal ?? false,
            isRemovable: v.volumeIsRemovable ?? false, isEjectable: v.volumeIsEjectable ?? false,
            isLocal: v.volumeIsLocal ?? true, isReadOnly: v.volumeIsReadOnly ?? false,
            isBrowsable: v.volumeIsBrowsable ?? false,
            totalCapacity: v.volumeTotalCapacity.map(Int64.init),
            capabilities: VolumeCapabilities(idStable: hasCaps && caps.persistent_ids != 0, renameExcl: hasCaps && caps.rename_excl != 0,
                                             clone: hasCaps && caps.clone != 0, caseSensitive: caseSensitive))
    }
}

public enum VolumeEvent: Sendable, Equatable {
    case didMount(URL), willUnmount(URL), didUnmount(URL), didRename(URL)
}

public protocol VolumeEventSource: Sendable {
    /// Starts delivering events (on the main actor). Implemented in Core/Platform with NSWorkspace.
    @MainActor func start(_ handler: @escaping @MainActor (VolumeEvent) -> Void)
}
