import Foundation
import MacxPluginKit

/// Address-bar completion for remote text (spec §2.4): subfolders of the typed remote parent (listed through its
/// provider, ref resolved first), plus every provider's own suggestions (e.g. "gh:", known refs).
public enum RemoteCompletion {
    public static func complete(_ text: String, current: URL, registry: ProviderRegistry) async
        -> (subfolders: [String], suggestions: [String]) {
        var suggestions: [String] = []
        for provider in registry.providers { suggestions += await provider.completions(for: text) }
        let head: String
        let prefix: String
        if let slash = text.lastIndex(of: "/") {
            head = String(text[...slash])
            prefix = String(text[text.index(after: slash)...])
        } else {
            head = ""
            prefix = text
        }
        guard let parent = AddressResolver.remoteTarget(head.isEmpty ? "." : head, current: current, registry: registry),
              let provider = registry.provider(id: parent.provider),
              let resolved = try? await provider.resolveRef(parent) else { return ([], suggestions) }
        var names: [String] = []
        do {
            for try await chunk in provider.list(resolved) {
                names += chunk.filter {
                    $0.kind == .directory && PathCompletion.matches($0.name, prefix: prefix)
                        && (prefix.hasPrefix(".") || !$0.name.hasPrefix("."))
                }.map(\.name)
            }
        } catch {
            return ([], suggestions)
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return (Array(names.prefix(PathCompletion.limit)), suggestions)
    }
}
