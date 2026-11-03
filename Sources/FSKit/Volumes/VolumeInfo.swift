import Foundation

public struct VolumeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String                       // "uuid:<volumeUUIDString>" or "mnt:<mount path>"
    public init(raw: String) { self.raw = raw }
    public static let unknown = VolumeID(raw: "unknown")
    public var description: String { raw }
}

public struct VolumeCapabilities: Sendable, Hashable, Codable {
    public var idStable: Bool       // VOL_CAP_FMT_PERSISTENTOBJECTIDS
    public var renameExcl: Bool     // VOL_CAP_INT_RENAME_EXCL
    public var clone: Bool          // VOL_CAP_INT_CLONE
    public var caseSensitive: Bool  // volumeSupportsCaseSensitiveNamesKey (cross-checked with VOL_CAP_FMT_CASE_SENSITIVE)
    public init(idStable: Bool, renameExcl: Bool, clone: Bool, caseSensitive: Bool) {
        self.idStable = idStable
        self.renameExcl = renameExcl
        self.clone = clone
        self.caseSensitive = caseSensitive
    }
    public var identityMode: IdentityMode { idStable ? .objectID : .name(caseSensitive: caseSensitive) }
}

public struct VolumeInfo: Sendable, Hashable, Identifiable {
    public var id: VolumeID
    public var mountPoint: URL
    public var name: String                  // volumeLocalizedNameKey
    public var format: String                // volumeLocalizedFormatDescriptionKey
    public var isBoot: Bool
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isLocal: Bool
    public var isReadOnly: Bool
    public var isBrowsable: Bool             // shown in sidebar Locations
    public var totalCapacity: Int64?
    public var capabilities: VolumeCapabilities
    public init(id: VolumeID, mountPoint: URL, name: String, format: String, isBoot: Bool, isInternal: Bool,
                isRemovable: Bool, isEjectable: Bool, isLocal: Bool, isReadOnly: Bool, isBrowsable: Bool,
                totalCapacity: Int64?, capabilities: VolumeCapabilities) {
        self.id = id
        self.mountPoint = mountPoint
        self.name = name
        self.format = format
        self.isBoot = isBoot
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isLocal = isLocal
        self.isReadOnly = isReadOnly
        self.isBrowsable = isBrowsable
        self.totalCapacity = totalCapacity
        self.capabilities = capabilities
    }
}
