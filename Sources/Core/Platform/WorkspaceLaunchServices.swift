import AppKit
import Foundation
import MacxFS

/// `NSWorkspace` implementation of `LaunchServicesProviding` (§4.3). Lookups that touch the file system or app
/// bundles run on a read lane; open and set-default calls are asynchronous XPC requests and are awaited directly.
/// Tests never use it for `open`/`setDefaultApplication` (Global Constraints): they use `FakeLaunchServices`.
public final class WorkspaceLaunchServices: LaunchServicesProviding {
    /// Lane key: LaunchServices lookups never share (or poison) a real volume's lanes. Lookups use
    /// `performRecovering`, so a slow cold query that returns late does not leave this key unresponsive.
    static let lane = VolumeID(raw: "system:launch-services")

    private let lanes: LanePool

    public init(lanes: LanePool) { self.lanes = lanes }

    public func applications(toOpen file: URL) async -> [AppInfo] {
        (try? await lanes.performRecovering(on: Self.lane, .read) { _ in
            assertOffMain()
            return NSWorkspace.shared.urlsForApplications(toOpen: file).map(Self.info)
        }) ?? []
    }

    public func defaultApplication(toOpen file: URL) async -> AppInfo? {
        (try? await lanes.performRecovering(on: Self.lane, .read) { _ in
            assertOffMain()
            return NSWorkspace.shared.urlForApplication(toOpen: file).map(Self.info)
        }) ?? nil
    }

    public func appInfo(at appURL: URL) async -> AppInfo? {
        (try? await lanes.performRecovering(on: Self.lane, .read) { _ in
            assertOffMain()
            return FileManager.default.fileExists(atPath: appURL.path(percentEncoded: false)) ? Self.info(appURL) : nil
        }) ?? nil
    }

    public func open(_ files: [URL]) async throws {
        for file in files {
            _ = try await NSWorkspace.shared.open(file, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    public func open(_ files: [URL], withApplicationAt app: URL) async throws {
        _ = try await NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    public func setDefaultApplication(_ app: URL, forContentTypeOf file: URL) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenContentTypeOfFileAt: file)
    }

    public func setDefaultApplication(_ app: URL, forFile file: URL) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: file)
    }

    public func revealInFinder(_ urls: [URL]) async {
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Lane only: reads the bundle's Info.plist and display name.
    private static func info(_ url: URL) -> AppInfo {
        var name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        if name.hasSuffix(".app") { name.removeLast(4) }
        return AppInfo(url: url, name: name, bundleIdentifier: Bundle(url: url)?.bundleIdentifier)
    }
}
