public struct VolumeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String                       // "uuid:<volumeUUIDString>" or "mnt:<mount path>"
    public init(raw: String) { self.raw = raw }
    public static let unknown = VolumeID(raw: "unknown")
    public var description: String { raw }
}
