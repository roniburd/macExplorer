import Foundation

/// What a bug report needs to know about this install (spec §4.1). Everything is shown to the user on GitHub before
/// it is submitted.
public struct EnvironmentSummary: Sendable, Equatable {
    public var appVersion: String
    public var build: String
    public var channel: String
    public var macOS: String
    public var hardwareModel: String
    public var architecture: String

    public init(appVersion: String, build: String, channel: String, macOS: String, hardwareModel: String, architecture: String) {
        self.appVersion = appVersion
        self.build = build
        self.channel = channel
        self.macOS = macOS
        self.hardwareModel = hardwareModel
        self.architecture = architecture
    }

    public var versionLine: String { "\(appVersion) (\(build))" }
    public var hardwareLine: String { "\(hardwareModel) (\(architecture))" }
    public var isBetaBuild: Bool { appVersion.contains("-beta") }

    public static func current(bundle: Bundle = .main, channel: UpdateChannel) -> EnvironmentSummary {
        let info = bundle.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osBuild = sysctlString("kern.osversion").map { " (\($0))" } ?? ""
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return EnvironmentSummary(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            channel: channel.rawValue,
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\(osBuild)",
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            architecture: arch)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(min(size, buffer.count)).prefix { $0 != 0 }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}
