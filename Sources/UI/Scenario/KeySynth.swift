import AppKit
import Core

struct SynthKey: Equatable, Sendable {
    var keyCode: UInt16
    var characters: String
    var charactersIgnoringModifiers: String
    var flags: NSEvent.ModifierFlags
}

/// KeyChord → the NSEvent fields a real keyboard would produce (ANSI layout key codes, so
/// KeyEventTranslator's characters(byApplyingModifiers: []) sees the right base character).
enum KeySynth {
    static let ansiKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]
    static let functionKeyCodes: [Int: UInt16] = [1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100, 9: 101, 10: 109, 11: 103, 12: 111]

    static func flags(_ modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if modifiers.contains(.command) { f.insert(.command) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.control) { f.insert(.control) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        return f
    }

    static func spec(for chord: KeyChord) -> SynthKey? {
        let base = flags(chord.modifiers)
        func plain(_ s: String, _ code: UInt16) -> SynthKey { SynthKey(keyCode: code, characters: s, charactersIgnoringModifiers: s, flags: base) }
        func function(_ scalar: Int, _ code: UInt16, numericPad: Bool = false) -> SynthKey? {
            guard let u = UnicodeScalar(UInt32(scalar)) else { return nil }
            var f = base
            f.insert(.function)
            if numericPad { f.insert(.numericPad) }
            let s = String(Character(u))
            return SynthKey(keyCode: code, characters: s, charactersIgnoringModifiers: s, flags: f)
        }
        switch chord.key {
        case .character(let c):
            guard c.count == 1, let ch = c.first, let code = ansiKeyCodes[ch] else { return nil }
            let shown = chord.modifiers.contains(.shift) && !chord.modifiers.contains(.command) ? c.uppercased() : c
            return SynthKey(keyCode: code, characters: shown, charactersIgnoringModifiers: c, flags: base)
        case .up: return function(NSUpArrowFunctionKey, 126, numericPad: true)
        case .down: return function(NSDownArrowFunctionKey, 125, numericPad: true)
        case .left: return function(NSLeftArrowFunctionKey, 123, numericPad: true)
        case .right: return function(NSRightArrowFunctionKey, 124, numericPad: true)
        case .returnKey: return plain("\r", 36)
        case .enter: return plain("\u{03}", 76)
        case .tab: return plain(chord.modifiers.contains(.shift) ? "\u{19}" : "\t", 48)
        case .escape: return plain("\u{1B}", 53)
        case .space: return plain(" ", 49)
        case .backspace: return plain("\u{7F}", 51)
        case .forwardDelete: return function(NSDeleteFunctionKey, 117)
        case .function(let n):
            guard let code = functionKeyCodes[n] else { return nil }
            return function(NSF1FunctionKey + n - 1, code)
        }
    }

    /// One key per character; unknown characters use key code 0 (the text system inserts `characters`).
    static func typingSpecs(_ text: String) -> [SynthKey] {
        text.map { ch in
            let lower = Character(ch.lowercased())
            let isUpper = ch.isUppercase
            let s = String(ch)
            return SynthKey(keyCode: ansiKeyCodes[lower] ?? 0, characters: s, charactersIgnoringModifiers: s.lowercased(),
                            flags: isUpper ? [.shift] : [])
        }
    }

    /// NSEvent(cgEvent:) takes its windowNumber from this CGEvent field (verified 2026-11-03; the named
    /// `.mouseEventWindowUnderMousePointerThatCanHandleThisEvent` is 92 and is not read for key events).
    static let windowNumberField = CGEventField(rawValue: 51)

    /// keyDown + keyUp built from CGEvents (created here, never posted to the system: NSApp.postEvent delivers
    /// them to this process only). Unlike NSEvent.keyEvent(...), CGEvent-backed events carry the keyboard data
    /// AppKit's menu matching uses, so ⌘⌫ / ⌥⌘⌫ match their "\u{8}" key equivalents as the hardware key does.
    /// The unicode string is overridden only when the layout's characters differ from `key.characters` (typed
    /// text such as "é"): an overridden string no longer matches menu key equivalents.
    @MainActor
    static func events(_ key: SynthKey, windowNumber: Int) -> [NSEvent] {
        [true, false].compactMap { down -> NSEvent? in
            guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: down) else { return nil }
            cg.flags = cgFlags(key.flags)
            cg.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            if let field = windowNumberField { cg.setIntegerValueField(field, value: Int64(windowNumber)) }
            if let event = NSEvent(cgEvent: cg), event.characters == key.characters { return event }
            let utf16 = Array(key.characters.utf16)
            utf16.withUnsafeBufferPointer { cg.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            return NSEvent(cgEvent: cg)
        }
    }

    static func cgFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var f = CGEventFlags()
        if flags.contains(.command) { f.insert(.maskCommand) }
        if flags.contains(.option) { f.insert(.maskAlternate) }
        if flags.contains(.control) { f.insert(.maskControl) }
        if flags.contains(.shift) { f.insert(.maskShift) }
        if flags.contains(.function) { f.insert(.maskSecondaryFn) }
        if flags.contains(.numericPad) { f.insert(.maskNumericPad) }
        return f
    }
}
