import Foundation
import MacxPluginKit
import Synchronization

/// The remote providers in use: built-ins first, then plugin providers in load order. Thread-safe.
public final class ProviderRegistry: Sendable {
    private let state: Mutex<[any RemoteProvider]>

    public init(builtIns: [any RemoteProvider]) {
        var unique: [any RemoteProvider] = []
        for provider in builtIns
        where RemoteLocation.isValidProviderID(provider.id) && !unique.contains(where: { $0.id == provider.id }) {
            unique.append(provider)
        }
        state = Mutex(unique)
    }

    /// Adds `providers` from `source` (a plugin bundle name). Returns the ids refused because one is already in use or
    /// is not a valid id (`RemoteLocation.isValidProviderID`).
    @discardableResult
    public func register(_ providers: [any RemoteProvider], source: String) -> [String] {
        state.withLock { list in
            var rejected: [String] = []
            for provider in providers {
                if !RemoteLocation.isValidProviderID(provider.id) || list.contains(where: { $0.id == provider.id }) {
                    rejected.append(provider.id)
                } else {
                    list.append(provider)
                }
            }
            return rejected
        }
    }

    public var providers: [any RemoteProvider] { state.withLock { $0 } }

    public func provider(id: String) -> (any RemoteProvider)? { state.withLock { list in list.first { $0.id == id } } }

    public func provider(for url: URL) -> (any RemoteProvider)? {
        RemoteLocation(url: url).flatMap { provider(id: $0.provider) }
    }

    /// The first provider (in order) that claims `address`.
    public func parse(address: String) -> RemoteLocation? {
        for provider in providers { if let location = provider.parseAddress(address) { return location } }
        return nil
    }

    /// The item at `location`, found by listing its parent; the root is a synthetic directory named after the repo.
    /// An item whose name is not a valid single path component (`RemoteItem.isValidName`) is never returned.
    public func item(at location: RemoteLocation) async throws(RemoteError) -> RemoteItem {
        guard let provider = provider(id: location.provider) else { throw .notFound }
        guard let parent = location.parent, let name = location.name else {
            return RemoteItem(name: location.repo, kind: .directory)
        }
        do {
            for try await chunk in provider.list(parent) {
                if let hit = chunk.first(where: { $0.name == name }) {
                    guard RemoteItem.isValidName(hit.name) else { throw RemoteError.notFound }
                    return hit
                }
            }
        } catch let error as RemoteError {
            throw error
        } catch {
            throw .network(String(describing: error))
        }
        throw .notFound
    }
}
