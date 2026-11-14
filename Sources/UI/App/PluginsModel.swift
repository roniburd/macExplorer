import Foundation
import Observation
import Core
import MacxPluginKit

/// The launch's plugin load (spec §5.3), for Settings › Connections and the smoke report.
@MainActor @Observable
public final class PluginsModel {
    public enum SkipReason: Sendable, Equatable { case disabledInSettings, optionKey, sandboxed }
    public private(set) var loaded: [LoadedPlugin] = []
    public private(set) var failures: [PluginLoadFailure] = []
    public private(set) var skipped: SkipReason?
    /// Set when `load` starts (so a second call is a no-op); `isFinished` is set when it ends.
    public private(set) var didLoad = false
    /// The load has finished (plugins loaded, refused or skipped); the smoke report waits for it.
    public private(set) var isFinished = false
    @ObservationIgnored private let environment: CoreEnvironment

    init(environment: CoreEnvironment) { self.environment = environment }

    /// Once per launch, after the first window shows. A sandboxed run loads only `--plugins-dir`, never the real folder.
    public func load(options: LaunchOptions, optionKeyHeld: Bool) async {
        guard !didLoad else { return }
        didLoad = true
        defer { isFinished = true }
        if environment.settings.pluginsDisabled { skipped = .disabledInSettings; return }
        if optionKeyHeld { skipped = .optionKey; return }
        let loader: PluginLoader
        if let dir = options.pluginsDirectory {
            // Any signature only where it can't widen trust: a debug build or an ad-hoc-signed app (the scripts' builds).
            // A certificate-signed app keeps the same-certificate check, or any local process could inject code with
            // `--plugins-dir` and inherit the app's privacy grants.
            loader = PluginLoader(directory: dir, codeCheck: await Self.allowsAnySignature() ? AnySignatureCheck() : SecCodePluginCheck())
        } else if options.isSandboxed {
            skipped = .sandboxed; return
        } else {
            loader = PluginLoader(directory: PluginLoader.defaultDirectory, codeCheck: SecCodePluginCheck())
        }
        failures = await loader.loadAll(into: environment.remote)
        loaded = loader.loaded
    }

    private static func allowsAnySignature() async -> Bool {
        #if DEBUG
        return true
        #else
        let app = Bundle.main.bundleURL
        return await Task.detached(priority: .userInitiated) { !SecCodePluginCheck.hasCertificate(app) }.value
        #endif
    }
}
