import Foundation
import MacxFS

/// Synthetic `VolumeInfo` values for tests: `idStable` true, every other flag false.
enum VolumeInfoFixtures {
    static func volume(id: String, mountPoint: URL) -> VolumeInfo {
        VolumeInfo(id: VolumeID(raw: id), mountPoint: mountPoint, name: id, format: "APFS",
                   isBoot: false, isInternal: false, isRemovable: false, isEjectable: false, isLocal: false,
                   isReadOnly: false, isBrowsable: false, totalCapacity: nil,
                   capabilities: VolumeCapabilities(idStable: true, renameExcl: false, clone: false, caseSensitive: false))
    }
}
