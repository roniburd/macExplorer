import Foundation
import Synchronization

/// Recording `LaunchServicesProviding` for tests and `--fake-launch-services`: it never opens a file, launches an
/// app or changes a system default. Defaults it is told to set are honoured by its own lookups
/// (per file first, then per lowercased extension, then `defaultApp`).
public final class FakeLaunchServices: LaunchServicesProviding {
    private struct State {
        var apps: [AppInfo]
        var defaultApp: AppInfo?
        var fileDefaults: [String: URL] = [:]        // standardized path → app
        var typeDefaults: [String: URL] = [:]        // lowercased extension → app
        var opened: [(files: [URL], app: URL?)] = []
        var defaultsSet: [(app: URL, file: URL, forType: Bool)] = []
        var revealed: [[URL]] = []
        var applicationLookups: [URL] = []
        var defaultLookups: [URL] = []
        var openError: (any Error & Sendable)?
    }
    private let state: Mutex<State>

    public init(apps: [AppInfo] = [], defaultApp: AppInfo? = nil) {
        state = Mutex(State(apps: apps, defaultApp: defaultApp))
    }

    // MARK: recordings

    public func opened() -> [(files: [URL], app: URL?)] { state.withLock { $0.opened } }
    public func defaultsSet() -> [(app: URL, file: URL, forType: Bool)] { state.withLock { $0.defaultsSet } }
    public func revealed() -> [[URL]] { state.withLock { $0.revealed } }
    public func applicationLookups() -> [URL] { state.withLock { $0.applicationLookups } }
    public func defaultLookups() -> [URL] { state.withLock { $0.defaultLookups } }

    // MARK: scripting

    public func setApplications(_ apps: [AppInfo]) { state.withLock { $0.apps = apps } }
    public func setDefaultApp(_ app: AppInfo?) { state.withLock { $0.defaultApp = app } }
    /// Every later `open` call is recorded and then throws `error` (nil: succeed again).
    public func setOpenError(_ error: (any Error & Sendable)?) { state.withLock { $0.openError = error } }

    // MARK: LaunchServicesProviding

    public func applications(toOpen file: URL) async -> [AppInfo] {
        state.withLock { s in
            s.applicationLookups.append(file)
            return s.apps
        }
    }

    public func defaultApplication(toOpen file: URL) async -> AppInfo? {
        state.withLock { s in
            s.defaultLookups.append(file)
            let chosen = s.fileDefaults[Self.key(file)] ?? s.typeDefaults[file.pathExtension.lowercased()]
            guard let chosen else { return s.defaultApp }
            return Self.info(for: chosen, in: s)
        }
    }

    public func appInfo(at appURL: URL) async -> AppInfo? {
        state.withLock { s in s.apps.first { $0.url == appURL } ?? (s.defaultApp?.url == appURL ? s.defaultApp : nil) }
    }

    public func open(_ files: [URL]) async throws { try record(files, app: nil) }

    public func open(_ files: [URL], withApplicationAt app: URL) async throws { try record(files, app: app) }

    public func setDefaultApplication(_ app: URL, forContentTypeOf file: URL) async throws {
        state.withLock { s in
            s.defaultsSet.append((app, file, true))
            s.typeDefaults[file.pathExtension.lowercased()] = app
        }
    }

    public func setDefaultApplication(_ app: URL, forFile file: URL) async throws {
        state.withLock { s in
            s.defaultsSet.append((app, file, false))
            s.fileDefaults[Self.key(file)] = app
        }
    }

    public func revealInFinder(_ urls: [URL]) async { state.withLock { $0.revealed.append(urls) } }

    // MARK: helpers

    private func record(_ files: [URL], app: URL?) throws {
        let error = state.withLock { s -> (any Error)? in
            s.opened.append((files, app))
            return s.openError
        }
        if let error { throw error }
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path(percentEncoded: false) }

    private static func info(for app: URL, in s: State) -> AppInfo {
        s.apps.first { $0.url == app } ?? (s.defaultApp?.url == app ? s.defaultApp : nil)
            ?? AppInfo(url: app, name: app.deletingPathExtension().lastPathComponent, bundleIdentifier: nil)
    }
}
