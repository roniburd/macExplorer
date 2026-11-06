import Foundation

/// Something the user presses: a key chord or an extra mouse button.
public enum Trigger: Hashable, Sendable {
    case key(KeyChord)
    case mouse(MouseButton)
}
