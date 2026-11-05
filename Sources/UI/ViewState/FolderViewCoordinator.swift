import Foundation
import Core
import MacxFS

/// Per-folder view state for browsing (spec §11 Phase 2): looks a folder's state up (in memory, never blocking),
/// saves user changes for that folder only, adds the folder's fileID with a lane probe when the caller did not know
/// it, and implements "Apply to All Folders".
@MainActor
final class FolderViewCoordinator {
    private let store: FolderViewStore
    private let settings: Settings
    private let lanes: LanePool
    private let volumes: Volumes

    init(store: FolderViewStore, settings: Settings, lanes: LanePool, volumes: Volumes) {
        self.store = store
        self.settings = settings
        self.lanes = lanes
        self.volumes = volumes
    }

    func state(for url: URL, fileID: UInt64?) -> (FolderViewState, FolderViewLocator) {
        let locator = FolderViewLocator(url: url, volume: volumes.volume(for: url), fileID: fileID)
        return (store.state(for: locator), locator)
    }

    func state(for locator: FolderViewLocator) -> FolderViewState { store.state(for: locator) }

    func hasOverride(for locator: FolderViewLocator) -> Bool { store.hasOverride(for: locator) }

    func save(_ state: FolderViewState, for locator: FolderViewLocator) { store.save(state, for: locator) }

    /// Adds the folder's fileID when the volume has stable IDs and the caller didn't know it (lane probe, no
    /// materialization). Otherwise returns `locator` unchanged.
    func refine(_ locator: FolderViewLocator) async -> FolderViewLocator {
        guard locator.fileID == nil, let volume = locator.volume, volume.capabilities.idStable else { return locator }
        let url = URL(filePath: locator.path, directoryHint: .isDirectory)
        guard let id = await FolderIdentityProbe.fileID(of: url, lanes: lanes, volume: volume.id) else { return locator }
        return FolderViewLocator(url: url, volume: volume, fileID: id)
    }

    /// "Apply to All Folders": `state` becomes the default and every folder's own state is dropped.
    func applyToAll(_ state: FolderViewState) {
        settings.applyDefaultView(state)
        store.removeAll()
    }
}
