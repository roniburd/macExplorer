import Foundation
import MacxPluginKit

/// Switching the ref of a remote folder (spec §4.2).
public enum RefSwitch {
    /// The same path in `ref` when it is a folder there, else the root of `ref`.
    public static func target(from current: RemoteLocation, to ref: String, registry: ProviderRegistry) async -> RemoteLocation {
        let same = current.withRef(ref)
        guard !same.path.isEmpty else { return same }
        if let item = try? await registry.item(at: same), item.kind == .directory { return same }
        var root = same
        root.path = []
        return root
    }
}
