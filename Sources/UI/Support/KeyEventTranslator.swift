import AppKit
import Core

/// NSEvent → KeyChord (§5.6). Special keys come from the hardware key code (layout-independent), falling back to the
/// characters AppKit reports; character keys use the base character with no modifiers applied
/// (`characters(byApplyingModifiers: [])`), lowercased, so ⌘⇧. is "shift+cmd+." and ⌥D is "opt+d" whatever ⌥D types.
/// `.function`, `.numericPad` and Caps Lock are ignored.
enum KeyEventTranslator {
    static func chord(for event: NSEvent) -> KeyChord? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let modifiers = modifiers(event.modifierFlags)
        if let key = specialKey(code: event.keyCode) ?? specialKey(characters: event.charactersIgnoringModifiers) {
            return KeyChord(key, modifiers)
        }
        guard let base = baseCharacter(event) else { return nil }
        return KeyChord(.character(base), modifiers)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// ANSI hardware key codes (Carbon kVK_*) of the keys KeyChord names.
    private static let keyCodes: [UInt16: Key] = [
        36: .returnKey, 76: .enter, 48: .tab, 53: .escape, 49: .space, 51: .backspace, 117: .forwardDelete,
        123: .left, 124: .right, 125: .down, 126: .up,
        122: .function(1), 120: .function(2), 99: .function(3), 118: .function(4), 96: .function(5), 97: .function(6),
        98: .function(7), 100: .function(8), 101: .function(9), 109: .function(10), 103: .function(11),
        111: .function(12), 105: .function(13), 107: .function(14), 113: .function(15), 106: .function(16),
        64: .function(17), 79: .function(18), 80: .function(19), 90: .function(20),
    ]

    private static func specialKey(code: UInt16) -> Key? { keyCodes[code] }

    private static func specialKey(characters: String?) -> Key? {
        guard let scalar = characters?.unicodeScalars.first, characters?.unicodeScalars.count == 1 else { return nil }
        let value = Int(scalar.value)
        switch value {
        case 0x0D: return .returnKey
        case 0x03: return .enter
        case 0x09, 0x19: return .tab                       // ⇧Tab reports backtab
        case 0x1B: return .escape
        case 0x20: return .space
        case 0x7F, 0x08: return .backspace
        case NSDeleteFunctionKey: return .forwardDelete
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        case NSLeftArrowFunctionKey: return .left
        case NSRightArrowFunctionKey: return .right
        case NSF1FunctionKey...(NSF1FunctionKey + 19): return .function(value - NSF1FunctionKey + 1)
        default: return nil
        }
    }

    private static func baseCharacter(_ event: NSEvent) -> String? {
        for candidate in [event.characters(byApplyingModifiers: []), event.charactersIgnoringModifiers] {
            guard let text = candidate, text.count == 1, let scalar = text.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar) else { continue }
            return text.lowercased()
        }
        return nil
    }
}
