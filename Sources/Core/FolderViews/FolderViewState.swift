import Foundation
import MacxFS
import Observation

/// The view of the folder a window shows (design 2026-11-05 §2). Lists observe `resolved`; user changes go through
/// `change`, which updates it and hands just the changed fields to `persist` (the window's per-folder store write).
@MainActor @Observable
public final class FolderViewState {
    public private(set) var resolved: ResolvedFolderView
    @ObservationIgnored public var persist: ((FolderViewSettings) -> Void)?

    public init(_ resolved: ResolvedFolderView) { self.resolved = resolved }

    /// Replaces the whole view (navigation, Finder data arriving, reset). No persistence.
    public func replace(_ view: ResolvedFolderView) {
        if view != resolved { resolved = view }
    }

    /// A user change: the fields `edit` sets are applied and persisted for the current folder.
    public func change(_ edit: (inout FolderViewSettings) -> Void) {
        var delta = FolderViewSettings()
        edit(&delta)
        guard !delta.isEmpty else { return }
        replace(Self.apply(delta, to: resolved))
        persist?(delta)
    }

    public static func apply(_ delta: FolderViewSettings, to view: ResolvedFolderView) -> ResolvedFolderView {
        ResolvedFolderView(viewMode: delta.viewMode ?? view.viewMode, iconSize: delta.iconSize ?? view.iconSize,
                           density: delta.density ?? view.density, sort: delta.sort ?? view.sort,
                           columns: delta.columns ?? view.columns)
    }
}

extension Settings {
    /// The global defaults every folder starts from (the "Use as Default for All Folders" target).
    public var defaultFolderView: ResolvedFolderView {
        get { ResolvedFolderView(viewMode: viewMode, iconSize: iconSize, density: density, sort: sort, columns: columns) }
        set {
            if viewMode != newValue.viewMode { viewMode = newValue.viewMode }
            if iconSize != newValue.iconSize { iconSize = newValue.iconSize }
            if density != newValue.density { density = newValue.density }
            if sort != newValue.sort { sort = newValue.sort }
            if columns != newValue.columns { columns = newValue.columns }
        }
    }
}
