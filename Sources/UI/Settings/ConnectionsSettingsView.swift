import SwiftUI
import Core
import MacxPluginKit

struct ConnectionRow: Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    var status: String
}

enum ConnectionRows {
    /// Every registered provider, in registry order: built-ins say so, plugin ones name their plugin and version.
    static func rows(registry: ProviderRegistry, loaded: [LoadedPlugin]) -> [ConnectionRow] {
        registry.providers.map { provider in
            let plugin = loaded.first { $0.providerIDs.contains(provider.id) }
            let status = plugin.map { String(format: L10n.string("Plugin %@ %@"), $0.name, $0.version) } ?? L10n.string("Built in")
            return ConnectionRow(id: provider.id, name: provider.displayName, symbol: provider.iconSymbol, status: status)
        }
    }
}

enum PluginFailureText {
    static func text(_ reason: PluginLoadFailure.Reason) -> String {
        switch reason {
        case .apiMismatch(let found):
            String(format: L10n.string("Built for plugin API %@ — this version needs %@"), found ?? L10n.string("unknown"),
                   "\(MacxPluginAPI.version.major).x")
        case .missingPrincipalClass: L10n.string("The bundle has no plugin class.")
        case .signatureMismatch: L10n.string("Not signed with macExplorer's certificate.")
        case .loadFailed(let message): String(format: L10n.string("Couldn't load: %@"), message)
        case .duplicateProvider(let id): String(format: L10n.string("Another provider already uses the id %@."), id)
        case .invalidProviderID(let id):
            String(format: L10n.string("The provider id “%@” isn't valid: use letters, digits, “-” and “.” only."), id)
        }
    }
}

/// §4.9 Settings › Connections: providers and their source, plugins that didn't load and why, the Plugins folder,
/// Disable plugins, and the downloaded-files cache.
struct ConnectionsSettingsView: View {
    @Bindable var settings: Core.Settings
    let plugins: PluginsModel
    let registry: ProviderRegistry
    let cache: RemoteFileCache
    let revealPlugins: () -> Void
    @State private var cacheBytes: Int64?

    var body: some View {
        Form {
            Section(L10n.string("Providers")) {
                ForEach(ConnectionRows.rows(registry: registry, loaded: plugins.loaded)) { row in
                    LabeledContent { Text(row.status).foregroundStyle(.secondary) } label: { Label(row.name, systemImage: row.symbol) }
                }
            }
            if !plugins.failures.isEmpty {
                Section(L10n.string("Plugins that didn't load")) {
                    ForEach(Array(plugins.failures.enumerated()), id: \.offset) { _, failure in
                        LabeledContent(failure.bundle.deletingPathExtension().lastPathComponent) {
                            Text(PluginFailureText.text(failure.reason)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section(L10n.string("Plugins")) {
                Toggle(L10n.string("Disable plugins"), isOn: $settings.pluginsDisabled)
                Text(L10n.string("Takes effect the next time macExplorer starts. Hold Option while it starts to skip plugins once."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.string("Show Plugins Folder"), action: revealPlugins)
            }
            Section(L10n.string("Downloaded files")) {
                LabeledContent(L10n.string("Cache size"), value: cacheBytes.map(Formatters.bytes) ?? "…")
                Button(L10n.string("Clear Cache")) {
                    Task { await cache.clear(); cacheBytes = await cache.totalSize() }
                }
            }
        }
        .formStyle(.grouped)
        .task { cacheBytes = await cache.totalSize() }
    }
}
