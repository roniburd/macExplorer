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
    public private(set) var didLoad = false
    @ObservationIgnored private let environment: CoreEnvironment

    init(environment: CoreEnvironment) { self.environment = environment }

    /// Once per launch, after the first window shows. A sandboxed run loads only `--plugins-dir`, never the real folder.
    public func load(options: LaunchOptions, optionKeyHeld: Bool) async {
        guard !didLoad else { return }
        didLoad = true
        if environment.settings.pluginsDisabled { skipped = .disabledInSettings; return }
        if optionKeyHeld { skipped = .optionKey; return }
        let loader: PluginLoader
        if let dir = options.pluginsDirectory {
            loader = PluginLoader(directory: dir, codeCheck: AnySignatureCheck())
        } else if options.isSandboxed {
            skipped = .sandboxed; return
        } else {
            loader = PluginLoader(directory: PluginLoader.defaultDirectory, codeCheck: SecCodePluginCheck())
        }
        failures = await loader.loadAll(into: environment.remote)
        loaded = loader.loaded
    }
}
