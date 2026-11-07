import Foundation

/// Which kind of responder has keyboard focus. Sidebar rows differ by section (§5.4); Folders-tree volume roots
/// behave like Locations rows. Phase 3: `.searchResults` is the content view showing search results (keys as in
/// `.content`); `.sidebarSavedSearch` is a SEARCHES row (keys as in `.sidebarFavorites`).
public enum FocusContext: Sendable, Hashable {
    case content, sidebarFavorites, sidebarLocations, sidebarFolders, sidebarVolumeRoot, addressBar, fieldEditor
    case searchResults, sidebarSavedSearch

    /// The sidebar foci (Favorites, Searches, Locations, Folders tree, Folders-tree volume roots).
    public var isSidebar: Bool {
        switch self {
        case .sidebarFavorites, .sidebarSavedSearch, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot: true
        case .content, .searchResults, .addressBar, .fieldEditor: false
        }
    }
}

/// Maps alternate keys (§5.6) to commands for the content views' and sidebar's `keyDown`.
public struct KeyDispatcher: Sendable {
    private let returnKey: ReturnKeyBehavior
    private let bindings: KeyBindings

    public init(returnKey: ReturnKeyBehavior, bindings: KeyBindings = .defaults) {
        self.returnKey = returnKey
        self.bindings = bindings
    }

    /// The current alternates only (defaults: Return/⌥Return, Del/⇧Del, ⌃X/⌃C/⌃V/⌃Z/⌃A, ⌘Y, ⌫, ⌥←/⌥→/⌥↑, ⌥D, F4, F3, F5, ⌘⇧R,
    /// Tab/⇧Tab, Esc, Space). Always nil for .fieldEditor and .addressBar.
    /// Space (Quick Look) is content-only. Any ⌃Tab chord is nil in every focus: it is the Show Next/Previous Tab
    /// menu key, never focus cycling.
    /// Return opens (navigates) in every sidebar section; in the content view it follows Settings › Return key.
    /// Sidebar remaps (Favorites: Del → removeFromFavorites; Searches: Del → removeSavedSearch, ⇧⌘R →
    /// renameSavedSearch, ⇧Del → nothing) go through `CommandAvailability.effectiveCommand`.
    /// `.searchResults` uses the `.content` alternates, `.sidebarSavedSearch` the `.sidebarFavorites` ones.
    public func command(for chord: KeyChord, in focus: FocusContext) -> Command? {
        let keys: FocusContext
        switch focus {
        case .fieldEditor, .addressBar:
            return nil
        case .searchResults:
            keys = .content
        case .sidebarSavedSearch:
            keys = .sidebarFavorites
        case .content, .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot:
            keys = focus
        }
        if chord.key == .tab, chord.modifiers.contains(.control) { return nil }
        guard var command = bindings.alternateCommand(for: chord) else { return nil }
        if command == .quickLook, keys != .content { return nil }
        if command == .open, chord == KeyChord(.returnKey), keys == .content, returnKey == .rename {
            command = .rename
        }
        return CommandAvailability.effectiveCommand(command, focus: focus)
    }
}
