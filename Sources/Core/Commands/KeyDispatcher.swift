import Foundation

/// Which kind of responder has keyboard focus. Sidebar rows differ by section (§5.4); Folders-tree volume roots
/// behave like Locations rows.
public enum FocusContext: Sendable, Hashable {
    case content, sidebarFavorites, sidebarLocations, sidebarFolders, sidebarVolumeRoot, addressBar, fieldEditor
}

/// Maps alternate keys (§5.6) to commands for the content views' and sidebar's `keyDown`.
public struct KeyDispatcher: Sendable {
    private let returnKey: ReturnKeyBehavior
    private static let table: [KeyChord: Command] = {
        var table: [KeyChord: Command] = [:]
        for command in Command.allCases {
            for chord in KeyMap.alternates(command) { table[chord] = command }
        }
        return table
    }()

    public init(returnKey: ReturnKeyBehavior) {
        self.returnKey = returnKey
    }

    /// Alternates only (Return/⌥Return, Del/⇧Del, ⌃X/⌃C/⌃V/⌃Z/⌃A, ⌘Y, ⌫, ⌥←/⌥→/⌥↑, ⌥D, F4, F3, F5, ⌘⇧R,
    /// Tab/⇧Tab, Esc). Always nil for .fieldEditor and .addressBar.
    /// Return opens (navigates) in every sidebar section; in the content view it follows Settings › Return key.
    /// Sidebar remaps (Favorites: Del → removeFromFavorites) go through `CommandAvailability.effectiveCommand`.
    public func command(for chord: KeyChord, in focus: FocusContext) -> Command? {
        switch focus {
        case .fieldEditor, .addressBar:
            return nil
        case .content, .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot:
            break
        }
        guard var command = Self.table[chord] else { return nil }
        if command == .open, chord == KeyChord(.returnKey), focus == .content, returnKey == .rename {
            command = .rename
        }
        return CommandAvailability.effectiveCommand(command, focus: focus)
    }
}
