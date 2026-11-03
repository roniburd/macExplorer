import Foundation

/// An application that can open files (§4.3 LaunchServices).
public struct AppInfo: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var name: String
    public var bundleIdentifier: String?

    public init(url: URL, name: String, bundleIdentifier: String?) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

/// LaunchServices behind a protocol (§4.3): `WorkspaceLaunchServices` runs lookups on lanes; tests and
/// `--fake-launch-services` use `FakeLaunchServices`, which records instead of opening or changing defaults.
public protocol LaunchServicesProviding: Sendable {
    func applications(toOpen file: URL) async -> [AppInfo]          // urlsForApplications(toOpen:)
    func defaultApplication(toOpen file: URL) async -> AppInfo?     // urlForApplication(toOpen: fileURL)
    func appInfo(at appURL: URL) async -> AppInfo?
    func open(_ files: [URL]) async throws                          // default apps
    func open(_ files: [URL], withApplicationAt app: URL) async throws
    func setDefaultApplication(_ app: URL, forContentTypeOf file: URL) async throws
    func setDefaultApplication(_ app: URL, forFile file: URL) async throws
    func revealInFinder(_ urls: [URL]) async
}
