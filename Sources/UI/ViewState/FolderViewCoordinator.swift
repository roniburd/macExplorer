import Foundation
import Core
import MacxFS

/// Per-folder view state for browsing (spec §11 Phase 2 + design 2026-11-05 §2). A folder's view is resolved field
/// by field from its own record (`FolderViewStore`), Finder's `.DS_Store` view (read once per launch, local volumes,
/// on a lane), the built-in rule (application folders open as Large Icons) and the global defaults. Lookups are in
/// memory and never block; user changes save only the changed fields for that folder; the identity probe adds the
/// folder's fileID when the caller did not know it. Implements "Use as Default for All Folders", "Reset View for
/// This Folder" and "Apply to All Folders".
@MainActor
final class FolderViewCoordinator {
    private let store: FolderViewStore
    private let settings: Settings
    private let lanes: LanePool
    private let volumes: Volumes
    private let home: URL

    init(store: FolderViewStore, settings: Settings, lanes: LanePool, volumes: Volumes,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.store = store
        self.settings = settings
        self.lanes = lanes
        self.volumes = volumes
        self.home = home
    }

    func state(for url: URL, fileID: UInt64?) -> (FolderViewState, FolderViewLocator) {
        let locator = FolderViewLocator(url: url, volume: volumes.volume(for: url), fileID: fileID)
        return (state(for: locator), locator)
    }

    func state(for locator: FolderViewLocator) -> FolderViewState {
        let url = locator.url
        return FolderViewResolver.resolve(stored: store.settings(for: locator), finder: store.finderView(for: url),
                                          builtIn: FolderViewResolver.builtIn(for: url, home: home),
                                          defaults: settings.defaultFolderViewState())
    }

    func hasOverride(for locator: FolderViewLocator) -> Bool { store.hasOverride(for: locator) }

    /// A user change: only the fields in `delta` become the folder's own.
    func update(_ delta: FolderViewSettings, for locator: FolderViewLocator) {
        guard !delta.isEmpty else { return }
        store.update(locator) { $0 = delta.over($0) }
    }

    /// The identity probe returned: a pending path record moves to the folder's object key.
    func adopt(_ locator: FolderViewLocator) { store.adopt(locator) }

    /// Adds the folder's fileID when the volume has stable IDs and the caller didn't know it (lane probe, no
    /// materialization). Otherwise returns `locator` unchanged.
    func refine(_ locator: FolderViewLocator) async -> FolderViewLocator {
        guard locator.fileID == nil, let volume = locator.volume, volume.capabilities.idStable else { return locator }
        let url = locator.url
        guard let id = await FolderIdentityProbe.fileID(of: url, lanes: lanes, volume: volume.id) else { return locator }
        return FolderViewLocator(url: url, volume: volume, fileID: id)
    }

    /// Whether Finder's view of the folder still has to be read (not read this launch, and on a local volume).
    func needsFinderView(_ locator: FolderViewLocator) -> Bool {
        store.finderView(for: locator.url) == nil && (locator.volume?.isLocal ?? false)
    }

    /// Reads Finder's `.DS_Store` view of the folder on a read lane under no-materialization (never on main; never
    /// writes), caches it for the launch, and returns it (nil or empty: Finder recorded nothing).
    func readFinderView(_ locator: FolderViewLocator) async -> FolderViewSettings? {
        if let cached = store.finderView(for: locator.url) { return cached }
        guard let volume = locator.volume, volume.isLocal else { return nil }
        let url = locator.url
        let columns = settings.columns
        let found = await FinderFolderView.read(folder: url, globalColumns: columns, lanes: lanes, volume: volume.id)
        guard !Task.isCancelled else { return nil }
        let view = found ?? FolderViewSettings()
        store.setFinderView(view, for: url)
        return view
    }

    /// "Reset View for This Folder": the folder's own record goes; Finder, the built-in rule and the defaults apply.
    func reset(_ locator: FolderViewLocator) { store.remove(locator) }

    /// "Use as Default for All Folders": `state` becomes the global default. Folders keep the fields they set
    /// themselves (and Finder's), and follow the new default for the rest.
    func useAsDefault(_ state: FolderViewState) { settings.applyDefaultView(state) }

    /// "Apply to All Folders": `state` becomes the default and every folder's own record is dropped.
    func applyToAll(_ state: FolderViewState) {
        settings.applyDefaultView(state)
        store.removeAll()
    }
}
