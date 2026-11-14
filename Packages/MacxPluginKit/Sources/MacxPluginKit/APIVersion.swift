import Foundation

/// The plugin API version. Plugins are compatible while the major version matches; additive changes bump minor.
public struct APIVersion: Sendable, Hashable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public init(major: Int, minor: Int) { self.major = major; self.minor = minor }

    /// "1", "1.0", " 2.13 " (whitespace trimmed); nil for anything else.
    public init?(string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]) else { return nil }
        let minor = parts.count == 2 ? Int(parts[1]) : 0
        guard let minor else { return nil }
        self.init(major: major, minor: minor)
    }

    public var description: String { "\(major).\(minor)" }
    public func isCompatible(with other: APIVersion) -> Bool { major == other.major }
}

public enum MacxPluginAPI {
    public static let version = APIVersion(major: 1, minor: 0)
    /// Info.plist key every `.macxplugin` bundle sets to the version it was built against ("1.0").
    public static let infoPlistKey = "MacxPluginAPIVersion"
}
