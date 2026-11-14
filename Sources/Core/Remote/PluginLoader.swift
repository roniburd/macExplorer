import Foundation
import MacxPluginKit

public struct PluginLoadFailure: Sendable, Equatable, Error {
    public enum Reason: Sendable, Equatable, Error {
        case apiMismatch(String?), missingPrincipalClass, signatureMismatch, loadFailed(String), duplicateProvider(String),
             invalidProviderID(String)
    }
    public var bundle: URL
    public var reason: Reason
    public init(bundle: URL, reason: Reason) { self.bundle = bundle; self.reason = reason }
}

public struct LoadedPlugin: Sendable, Equatable {
    public var bundle: URL
    public var name: String
    public var version: String
    public var apiVersion: String      // the plugin's own MacxPlugin.apiVersion: display only (part A deviation 2)
    public var providerIDs: [String]
}

/// The code-loading step, after the Info.plist and signature checks. Tests substitute it.
public protocol PluginBundleLoading: Sendable {
    @MainActor func principalClass(of bundle: URL) throws(PluginLoadFailure.Reason) -> MacxPlugin.Type
}

public struct SystemPluginBundleLoader: PluginBundleLoading {
    public init() {}
    @MainActor public func principalClass(of url: URL) throws(PluginLoadFailure.Reason) -> MacxPlugin.Type {
        guard let bundle = Bundle(url: url) else { throw .loadFailed("not a bundle") }
        do { try bundle.loadAndReturnError() } catch { throw .loadFailed(error.localizedDescription) }
        guard let type = bundle.principalClass as? MacxPlugin.Type else { throw .missingPrincipalClass }
        return type
    }
}

/// Scans `directory` for `*.macxplugin`, in name order (spec §5.1–5.3). A bundle loads only when its Info.plist
/// `MacxPluginAPIVersion` has the app's major version and its signature passes `codeCheck`; then its principal class
/// is created once on the main actor and its providers are registered. Nothing here ever stops the app: every
/// problem becomes a `PluginLoadFailure`.
///
/// The signature check runs per bundle on the main actor, immediately before that bundle's code is loaded, and again
/// immediately after: when the code identity (cdhash) differs, the bundle was swapped on disk in between and the
/// plugin is refused before its principal class is created (load-time initializers in the image have run by then).
/// Remaining race: the loaded image can't be unloaded, and
/// a swap that is reverted between the load and the second check isn't seen; the kernel's page-level code-signing
/// enforcement of the mapped file is what guards that last window.
@MainActor
public final class PluginLoader {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/macExplorer/Plugins", directoryHint: .isDirectory)
    }

    public private(set) var loaded: [LoadedPlugin] = []
    private let directory: URL
    private let codeCheck: any PluginCodeCheck
    private let appAPI: APIVersion
    private let bundleLoader: any PluginBundleLoading

    public init(directory: URL, codeCheck: any PluginCodeCheck, appAPI: APIVersion = MacxPluginAPI.version,
                bundleLoader: any PluginBundleLoading = SystemPluginBundleLoader()) {
        self.directory = directory
        self.codeCheck = codeCheck
        self.appAPI = appAPI
        self.bundleLoader = bundleLoader
    }

    private struct Candidate: Sendable { var url: URL; var info: [String: String] }

    public func loadAll(into registry: ProviderRegistry) async -> [PluginLoadFailure] {
        let directory = self.directory
        let candidates = await Task.detached(priority: .userInitiated) { () -> [Candidate] in
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return urls.filter { $0.pathExtension == "macxplugin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { url in
                    let raw = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
                    return Candidate(url: url, info: raw.compactMapValues { $0 as? String })
                }
        }.value
        var failures: [PluginLoadFailure] = []
        for c in candidates {
            let declared = c.info[MacxPluginAPI.infoPlistKey]
            guard let version = declared.flatMap(APIVersion.init(string:)), version.isCompatible(with: appAPI) else {
                failures.append(PluginLoadFailure(bundle: c.url, reason: .apiMismatch(declared))); continue
            }
            // Checked here, right before the load, not at scan time (see the type comment).
            guard let checked = codeCheck.codeIdentity(c.url) else {
                failures.append(PluginLoadFailure(bundle: c.url, reason: .signatureMismatch)); continue
            }
            let type: MacxPlugin.Type
            do { type = try bundleLoader.principalClass(of: c.url) } catch {
                failures.append(PluginLoadFailure(bundle: c.url, reason: error)); continue
            }
            guard codeCheck.codeIdentity(c.url) == checked else {
                failures.append(PluginLoadFailure(bundle: c.url, reason: .signatureMismatch)); continue
            }
            let plugin = type.init()
            let providers = plugin.makeProviders()
            let rejected = registry.register(providers, source: c.url.lastPathComponent)
            failures += rejected.map { id in
                PluginLoadFailure(bundle: c.url, reason: RemoteLocation.isValidProviderID(id) ? .duplicateProvider(id) : .invalidProviderID(id))
            }
            let accepted = providers.map(\.id).filter { !rejected.contains($0) }
            guard !accepted.isEmpty else { continue }
            loaded.append(LoadedPlugin(bundle: c.url, name: c.info["CFBundleName"] ?? c.url.deletingPathExtension().lastPathComponent,
                                       version: c.info["CFBundleShortVersionString"] ?? "?",
                                       apiVersion: plugin.apiVersion.description, providerIDs: accepted))
        }
        return failures
    }
}
