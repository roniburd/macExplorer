import Core

extension KeyChord {
    /// Mac glyph form, modifiers in the standard ⌃⌥⇧⌘ order: "⌥⌘⌫", "⇧⌘N", "F2".
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let c): text += c.uppercased()
        case .up: text += "↑"
        case .down: text += "↓"
        case .left: text += "←"
        case .right: text += "→"
        case .returnKey: text += "↩"
        case .enter: text += "⌤"
        case .tab: text += "⇥"
        case .escape: text += "⎋"
        case .space: text += L10n.string("Space")
        case .backspace: text += "⌫"
        case .forwardDelete: text += "⌦"
        case .function(let n): text += "F\(n)"
        }
        return text
    }
}

extension MouseButton {
    /// "Mouse 4" for buttonNumber 3 (mice label buttons from 1).
    var displayName: String { String(format: L10n.string("Mouse %d"), number + 1) }
}

extension Trigger {
    var displayString: String {
        switch self {
        case .key(let chord): chord.displayString
        case .mouse(let button): button.displayName
        }
    }
}
