import Foundation

/// Which appcast items Install Previous Version… lists (install-previous-version spec).
public enum RollbackCatalog {
    /// v0.2.0-beta.10, the first release signed with the persistent self-signed cert. Older builds were ad-hoc
    /// signed: macOS would re-ask for folder access, and their signature can't be matched to ours.
    public static let minimumBuild = 182

    /// Items the channel may see, signed with the persistent cert, older than the installed build and runnable on
    /// this OS; newest first, one per build.
    public static func candidates(_ items: [AppcastItem], channel: UpdateChannel, installedBuild: Int,
                                  osVersion: OperatingSystemVersion) -> [AppcastItem] {
        let allowed = channel.sparkleChannels
        var seen = Set<Int>()
        return items
            .filter { item in
                if let c = item.channel, !allowed.contains(c) { return false }
                guard item.build >= minimumBuild, item.build < installedBuild else { return false }
                if let min = item.minimumSystemVersion, !satisfies(osVersion, minimum: min) { return false }
                return true
            }
            .sorted { $0.build > $1.build }
            .filter { seen.insert($0.build).inserted }
    }

    /// "26.0" / "26" / "26.1.2" against the running OS.
    static func satisfies(_ os: OperatingSystemVersion, minimum: String) -> Bool {
        let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let need = (parts.first ?? 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
        return (os.majorVersion, os.minorVersion, os.patchVersion) >= need
    }
}
