import Foundation

/// Which kind of responder has keyboard focus. Sidebar rows differ by section (§5.4); Folders-tree volume roots
/// behave like Locations rows.
public enum FocusContext: Sendable, Hashable {
    case content, sidebarFavorites, sidebarLocations, sidebarFolders, sidebarVolumeRoot, addressBar, fieldEditor

    /// The four sidebar foci (Favorites, Locations, Folders tree, Folders-tree volume roots).
    public var isSidebar: Bool {
        switch self {
        case .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot: true
        case .content, .addressBar, .fieldEditor: false
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
    /// Sidebar remaps (Favorites: Del → removeFromFavorites) go through `CommandAvailability.effectiveCommand`.
    public func command(for chord: KeyChord, in focus: FocusContext) -> Command? {
        switch focus {
        case .fieldEditor, .addressBar:
            return nil
        case .content, .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot:
            break
        }
        if chord.key == .tab, chord.modifiers.contains(.control) { return nil }
        guard var command = bindings.alternateCommand(for: chord) else { return nil }
        if command == .quickLook, focus != .content { return nil }
        if command == .open, chord == KeyChord(.returnKey), focus == .content, returnKey == .rename {
            command = .rename
        }
        return CommandAvailability.effectiveCommand(command, focus: focus)
    }
}
