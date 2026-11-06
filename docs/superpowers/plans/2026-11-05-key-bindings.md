# Key Bindings and Mouse Buttons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mouse Back/Forward side buttons navigate folder history, and a Settings › Shortcuts tab lets the user rebind every command's keys and mouse buttons.

**Architecture:** `KeyMap` stays as built-in defaults. A sparse `KeyBindingOverrides` value in `Settings` holds the user's changes, and `KeyBindings` resolves defaults + overrides into lookup tables. The UI keeps one resolved table in `ActiveKeyBindings.current`, refreshed by `KeyBindingsController` (owned by `UIContext`) whenever the overrides change. That controller also rewrites the main menu's key equivalents. Mouse buttons are intercepted in `MacxApplication.sendEvent` and sent through the same responder walk as alternate keys.

**Tech Stack:** Swift 6 (strict concurrency), AppKit, SwiftUI (Settings), Observation, XCTest, SwiftPM (`swift build`, `swift test`).

**Spec:** `docs/superpowers/specs/2026-11-05-key-bindings-design.md` (read §9 "Plan-time adjustments" first)

## Global Constraints

- Work only in the worktree `/Users/roniburd/dev/macExplorer/.claude/worktrees/key-bindings` on branch `feature/key-bindings`. Never edit the primary checkout.
- Tests may only touch files they create (use `ShellHarness` / `Sandbox` / `InMemorySettingsStorage`). No test writes real user folders or `UserDefaults`.
- `Core` imports only Foundation (enforced by `scripts/check-layering.sh`). AppKit/SwiftUI code goes in `Sources/UI`.
- Every new `L10n.string("…")` literal must be added to `Sources/UI/Resources/Localizable.xcstrings` with `scripts/l10n-add.sh "…"` (enforced by `LocalizationCoverageTests`).
- Default mouse bindings: `buttonNumber` 3 → `.back`, `buttonNumber` 4 → `.forward`. Bindable mouse buttons: `buttonNumber` 3…8. User-facing label = `buttonNumber + 1` ("Mouse 4", "Mouse 5"). Canonical text form = `"mouse4"`, `"mouse5"`.
- Text-field chords (`KeyMap.textEditingChords`): ⌘↑, ⌘↓, ⌘⌫, ⌥⌘⌫, ⌘[, ⌘], F2, ⌘D.
- Reserved chords (never bindable): ⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘, (comma), ⌘`, Tab, ⇧Tab, Esc.
- Fixed commands (not editable): `.cycleFocusForward`, `.cycleFocusBackward`, `.cancelOperation`.
- Storage key: `"keyBindings"`. Not written while there are no overrides.
- Settings tab order: General, View, Sidebar, Shortcuts, Advanced. Tab title "Shortcuts", SF Symbol `keyboard`.
- Inclusive language in code and comments.

## Review Focus

1. **Bindings change while a text field is being edited**: a command moved onto ⌘D must stop firing while renaming; Duplicate moved off ⌘D must fire again. (Task 4: `testFieldEditorRoutingFollowsRebinding`.)
2. **Hand-edited or older stored data** with an unknown command, a bad chord, or a wrong JSON type in one field must lose only that piece. (Task 1: `testDecodingDropsBadPiecesOnly`; Task 3: `testGarbageStoredValueFallsBackWithoutOverwriting`.)
3. **A mouse button pressed outside a browser window** (Settings, Properties, alerts) must do nothing and must not be swallowed. (Task 5: `testNonBrowserWindowIsIgnored`.)
4. **Reassigning a chord that a command uses as its own other slot** (e.g. Back's alternate ⌫ made Back's primary) must not leave the chord in both slots. (Task 2: `testReassignRemovesTheTriggerFromTheSameCommandsOtherSlot`.)
5. **Back with empty history from the mouse** must be consumed without navigating or crashing. (Task 5: `testUnavailableCommandIsConsumed`.)

---

### Task 1: Core trigger types and the overrides value

**Files:**
- Create: `Sources/Core/Commands/MouseButton.swift`
- Create: `Sources/Core/Commands/Trigger.swift`
- Create: `Sources/Core/Commands/KeyBindingOverrides.swift`
- Modify: `Sources/Core/Commands/KeyChord.swift` (append Codable extension)
- Test: `Tests/CoreTests/KeyBindingOverridesTests.swift`

**Interfaces:**
- Produces: `MouseButton` (`number: Int`, `init?(number:)`, `init?(parsing:)`, `description` = `"mouse\(number+1)"`, `Comparable`, `Codable` as string). `Trigger` (`.key(KeyChord)`, `.mouse(MouseButton)`). `KeyChord: Codable` (string form). `KeyBindingOverrides` (`commands: [Command: Entry]`, `static let empty`, `Codable`), `KeyBindingOverrides.Entry` (`primary: PrimaryOverride?`, `alternates: [KeyChord]?`, `mouse: [MouseButton]?`, `isEmpty`), `KeyBindingOverrides.PrimaryOverride` (`.unbound`, `.chord(KeyChord)`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/KeyBindingOverridesTests.swift
import XCTest
@testable import Core

final class KeyBindingOverridesTests: XCTestCase {
    private func chord(_ text: String) -> KeyChord { KeyChord(parsing: text)! }

    func testMouseButtonBoundsAndText() {
        XCTAssertNil(MouseButton(number: 2))
        XCTAssertNil(MouseButton(number: 9))
        XCTAssertEqual(MouseButton(number: 3)?.description, "mouse4")
        XCTAssertEqual(MouseButton(parsing: "mouse4"), MouseButton(number: 3))
        XCTAssertEqual(MouseButton(parsing: "Mouse9"), MouseButton(number: 8))
        XCTAssertNil(MouseButton(parsing: "mouse3"), "buttonNumber 2 (middle) is not bindable")
        XCTAssertNil(MouseButton(parsing: "mousex"))
        XCTAssertLessThan(MouseButton(number: 3)!, MouseButton(number: 4)!)
    }

    func testKeyChordCodableRoundTripsEveryKeyKind() throws {
        let texts = ["cmd+[", "shift+cmd+n", "opt+cmd+delete", "fn+delete", "shift+fn+delete", "F2", "F20", "opt+left",
                     "return", "enter", "tab", "esc", "space", "ctrl+opt+shift+cmd+up", "cmd++", "x"]
        let chords = texts.map(chord)
        let data = try JSONEncoder().encode(chords)
        XCTAssertEqual(try JSONDecoder().decode([KeyChord].self, from: data), chords)
        XCTAssertThrowsError(try JSONDecoder().decode(KeyChord.self, from: Data(#""cmd+nope""#.utf8)))
    }

    func testOverridesRoundTrip() throws {
        var o = KeyBindingOverrides.empty
        o.commands[.back] = .init(primary: .chord(chord("opt+cmd+b")), alternates: [chord("delete")],
                                  mouse: [MouseButton(number: 5)!])
        o.commands[.duplicate] = .init(primary: .unbound)
        let data = try JSONEncoder().encode(o)
        XCTAssertEqual(try JSONDecoder().decode(KeyBindingOverrides.self, from: data), o)
    }

    func testDecodingDropsBadPiecesOnly() throws {
        let json = #"""
        {"back": {"primary": "cmd+nope", "alternates": ["delete", "zz+q"], "mouse": ["mouse4", "mouse99"]},
         "noSuchCommand": {"primary": "cmd+k"},
         "forward": {"primary": 7, "mouse": ["mouse5"]},
         "duplicate": {"primary": ""}}
        """#
        let o = try JSONDecoder().decode(KeyBindingOverrides.self, from: Data(json.utf8))
        XCTAssertEqual(o.commands[.back], .init(primary: nil, alternates: [chord("delete")], mouse: [MouseButton(number: 3)!]))
        XCTAssertEqual(o.commands[.forward], .init(primary: nil, alternates: nil, mouse: [MouseButton(number: 4)!]))
        XCTAssertEqual(o.commands[.duplicate], .init(primary: .unbound))
        XCTAssertEqual(o.commands.count, 3)
    }

    func testNonObjectFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(KeyBindingOverrides.self, from: Data("[1,2]".utf8)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: compile errors `cannot find 'MouseButton' in scope` and `cannot find type 'KeyBindingOverrides'`.

- [ ] **Step 3: Implement**

```swift
// Sources/Core/Commands/MouseButton.swift
import Foundation

/// An extra mouse button that can be bound to a command. `number` is AppKit's `NSEvent.buttonNumber` (3 = the
/// "back" side button, 4 = "forward"). Buttons 0–2 (left, right, middle) are never bindable.
public struct MouseButton: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let bindable = 3...8
    public let number: Int

    public init?(number: Int) {
        guard Self.bindable.contains(number) else { return nil }
        self.number = number
    }

    /// "mouse4" (case-insensitive) = buttonNumber 3. Mice label their buttons from 1, so text is number + 1.
    public init?(parsing text: String) {
        let lower = text.lowercased()
        guard lower.hasPrefix("mouse"), let label = Int(lower.dropFirst(5)) else { return nil }
        self.init(number: label - 1)
    }

    public var description: String { "mouse\(number + 1)" }
    public static func < (a: MouseButton, b: MouseButton) -> Bool { a.number < b.number }
}

extension MouseButton: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let button = MouseButton(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad mouse button '\(text)'"))
        }
        self = button
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
```

```swift
// Sources/Core/Commands/Trigger.swift
import Foundation

/// Something the user presses: a key chord or an extra mouse button.
public enum Trigger: Hashable, Sendable {
    case key(KeyChord)
    case mouse(MouseButton)
}
```

Append to `Sources/Core/Commands/KeyChord.swift`:

```swift
/// Stored as the canonical text form ("opt+cmd+delete").
extension KeyChord: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let chord = KeyChord(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad key chord '\(text)'"))
        }
        self = chord
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
```

```swift
// Sources/Core/Commands/KeyBindingOverrides.swift
import Foundation

/// The user's changes to the built-in key table (`KeyMap`). Sparse: a command with no entry uses its defaults, and
/// each nil field keeps that slot's default. Stored under Settings key "keyBindings".
public struct KeyBindingOverrides: Sendable, Equatable {
    public enum PrimaryOverride: Sendable, Equatable {
        case unbound
        case chord(KeyChord)
    }

    public struct Entry: Sendable, Equatable {
        public var primary: PrimaryOverride?
        public var alternates: [KeyChord]?
        public var mouse: [MouseButton]?
        public init(primary: PrimaryOverride? = nil, alternates: [KeyChord]? = nil, mouse: [MouseButton]? = nil) {
            self.primary = primary
            self.alternates = alternates
            self.mouse = mouse
        }
        public var isEmpty: Bool { primary == nil && alternates == nil && mouse == nil }
    }

    public var commands: [Command: Entry]
    public init(commands: [Command: Entry] = [:]) { self.commands = commands }
    public static let empty = KeyBindingOverrides()
}

/// JSON: {"back": {"primary": "opt+cmd+b", "alternates": ["delete"], "mouse": ["mouse4"]}}. "primary": "" = unbound.
/// Decoding drops what it can't read (unknown command, bad chord, wrong type) and keeps the rest.
extension KeyBindingOverrides: Codable {
    private struct Raw: Codable {
        var primary: String?
        var alternates: [String]?
        var mouse: [String]?

        init(primary: String?, alternates: [String]?, mouse: [String]?) {
            self.primary = primary
            self.alternates = alternates
            self.mouse = mouse
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            primary = try? c.decodeIfPresent(String.self, forKey: .primary)
            alternates = try? c.decodeIfPresent([String].self, forKey: .alternates)
            mouse = try? c.decodeIfPresent([String].self, forKey: .mouse)
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Raw].self)
        var commands: [Command: Entry] = [:]
        for (name, value) in raw {
            guard let command = Command(rawValue: name) else { continue }
            var entry = Entry()
            if let text = value.primary {
                entry.primary = text.isEmpty ? .unbound : KeyChord(parsing: text).map(PrimaryOverride.chord)
            }
            entry.alternates = value.alternates?.compactMap(KeyChord.init(parsing:))
            entry.mouse = value.mouse?.compactMap(MouseButton.init(parsing:))
            if !entry.isEmpty { commands[command] = entry }
        }
        self.commands = commands
    }

    public func encode(to encoder: any Encoder) throws {
        var raw: [String: Raw] = [:]
        for (command, entry) in commands {
            let primary: String? = switch entry.primary {
            case nil: nil
            case .unbound?: ""
            case .chord(let chord)?: chord.description
            }
            raw[command.rawValue] = Raw(primary: primary, alternates: entry.alternates?.map(\.description),
                                        mouse: entry.mouse?.map(\.description))
        }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeyBindingOverridesTests 2>&1 | tail -15`
Expected: all 5 tests pass. If `testKeyChordCodableRoundTripsEveryKeyKind` fails on one text, check `KeyChord.description` for that key kind and fix the round-trip in `KeyChord.swift` (the type documents that it round-trips).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Commands/MouseButton.swift Sources/Core/Commands/Trigger.swift Sources/Core/Commands/KeyBindingOverrides.swift Sources/Core/Commands/KeyChord.swift Tests/CoreTests/KeyBindingOverridesTests.swift
git commit -m "feat(core): mouse buttons, triggers and the key-binding overrides value"
```

---

### Task 2: `KeyBindings` resolution, validation and override edits

**Files:**
- Create: `Sources/Core/Commands/KeyBindings.swift`
- Create: `Sources/Core/Commands/KeyBindingOverrides+Editing.swift`
- Modify: `Sources/Core/Commands/KeyMap.swift` (add `defaultMouse`, `textEditingChords`; keep `collidesWithTextEditing` until Task 4)
- Test: `Tests/CoreTests/KeyBindingsTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  - `KeyMap.defaultMouse(_ command: Command) -> [MouseButton]`, `KeyMap.textEditingChords: Set<KeyChord>`.
  - `KeyBindings` (`Sendable`, `Equatable` by overrides): `static let defaults`, `static let fixedCommands: Set<Command>`, `static let reservedChords: Set<KeyChord>`, `init(overrides:)`, `overrides`, `primary(_:) -> KeyChord?`, `alternates(_:) -> [KeyChord]`, `mouse(_:) -> [MouseButton]`, `alternateCommand(for: KeyChord) -> Command?`, `command(for: MouseButton) -> Command?`, `uses(of: Trigger) -> [Use]`, `collidesWithTextEditing: Set<Command>`, `static func validate(_: Trigger, as: Slot) -> BindingRejection?`.
  - `KeyBindings.Slot` (`.primary`, `.alternate`, `.mouse`), `KeyBindings.Use` (`command`, `slot`), `BindingRejection` (`.reserved`, `.typesTextAsPrimary`, `.wrongSlot`).
  - `KeyBindingOverrides` mutating edits: `setPrimary(_: KeyChord?, for:)`, `removeAlternate(_:from:)`, `removeMouse(_:from:)`, `reassign(_: Trigger, to: Command, as: KeyBindings.Slot)`, `reset(_: Command)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/KeyBindingsTests.swift
import XCTest
@testable import Core

final class KeyBindingsTests: XCTestCase {
    private func chord(_ text: String) -> KeyChord { KeyChord(parsing: text)! }
    private let mouse4 = MouseButton(number: 3)!
    private let mouse5 = MouseButton(number: 4)!
    private let mouse6 = MouseButton(number: 5)!

    func testDefaultsMatchKeyMap() {
        let b = KeyBindings.defaults
        for c in Command.allCases {
            XCTAssertEqual(b.primary(c), KeyMap.primary(c), "\(c)")
            XCTAssertEqual(b.alternates(c), KeyMap.alternates(c), "\(c)")
            XCTAssertEqual(b.mouse(c), KeyMap.defaultMouse(c), "\(c)")
        }
        XCTAssertEqual(b.command(for: mouse4), .back)
        XCTAssertEqual(b.command(for: mouse5), .forward)
        XCTAssertNil(b.command(for: mouse6))
        XCTAssertEqual(b.alternateCommand(for: chord("delete")), .back)
        XCTAssertNil(b.alternateCommand(for: chord("cmd+[")), "primaries are not alternates")
    }

    func testEachOverrideSlotAppliesAlone() {
        var o = KeyBindingOverrides.empty
        o.commands[.back] = .init(primary: .chord(chord("opt+cmd+b")))
        o.commands[.forward] = .init(alternates: [])
        o.commands[.up] = .init(mouse: [mouse6])
        o.commands[.duplicate] = .init(primary: .unbound)
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.back), chord("opt+cmd+b"))
        XCTAssertEqual(b.alternates(.back), KeyMap.alternates(.back))
        XCTAssertEqual(b.mouse(.back), [mouse4])
        XCTAssertEqual(b.alternates(.forward), [])
        XCTAssertNil(b.alternateCommand(for: chord("opt+right")))
        XCTAssertEqual(b.command(for: mouse6), .up)
        XCTAssertNil(b.primary(.duplicate))
    }

    func testInvalidStoredPrimaryFallsBackToDefault() {
        var o = KeyBindingOverrides.empty
        o.commands[.back] = .init(primary: .chord(chord("cmd+q")))
        o.commands[.forward] = .init(primary: .chord(chord("x")))
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.back), KeyMap.primary(.back))
        XCTAssertEqual(b.primary(.forward), KeyMap.primary(.forward))
    }

    func testFixedCommandsIgnoreOverrides() {
        var o = KeyBindingOverrides.empty
        o.commands[.cancelOperation] = .init(alternates: [])
        XCTAssertEqual(KeyBindings(overrides: o).alternateCommand(for: chord("esc")), .cancelOperation)
        XCTAssertEqual(KeyBindings.fixedCommands, [.cycleFocusForward, .cycleFocusBackward, .cancelOperation])
    }

    func testDuplicateStoredTriggersFirstCommandWins() {
        var o = KeyBindingOverrides.empty
        o.commands[.open] = .init(mouse: [mouse6])
        o.commands[.up] = .init(mouse: [mouse6])
        XCTAssertEqual(KeyBindings(overrides: o).command(for: mouse6), .open, "Command.allCases order")
    }

    func testValidate() {
        for text in ["cmd+q", "cmd+h", "opt+cmd+h", "cmd+m", "cmd+,", "cmd+`", "tab", "shift+tab", "esc"] {
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .alternate), .reserved, text)
            XCTAssertEqual(KeyBindings.validate(.key(chord(text)), as: .primary), .reserved, text)
        }
        XCTAssertEqual(KeyBindings.validate(.key(chord("x")), as: .primary), .typesTextAsPrimary)
        XCTAssertEqual(KeyBindings.validate(.key(chord("shift+x")), as: .primary), .typesTextAsPrimary)
        XCTAssertEqual(KeyBindings.validate(.key(chord("space")), as: .primary), .typesTextAsPrimary)
        XCTAssertNil(KeyBindings.validate(.key(chord("x")), as: .alternate))
        XCTAssertNil(KeyBindings.validate(.key(chord("F6")), as: .primary))
        XCTAssertNil(KeyBindings.validate(.key(chord("opt+cmd+b")), as: .primary))
        XCTAssertNil(KeyBindings.validate(.mouse(mouse6), as: .mouse))
        XCTAssertEqual(KeyBindings.validate(.mouse(mouse6), as: .primary), .wrongSlot)
        XCTAssertEqual(KeyBindings.validate(.key(chord("cmd+k")), as: .mouse), .wrongSlot)
    }

    func testCollisionFollowsTheChord() {
        XCTAssertEqual(KeyBindings.defaults.collidesWithTextEditing,
                       [.open, .up, .moveToTrash, .deletePermanently, .back, .forward, .rename, .duplicate])
        var o = KeyBindingOverrides.empty
        o.setPrimary(chord("opt+cmd+d"), for: .duplicate)
        o.setPrimary(chord("cmd+d"), for: .newFolder)
        let b = KeyBindings(overrides: o)
        XCTAssertFalse(b.collidesWithTextEditing.contains(.duplicate))
        XCTAssertTrue(b.collidesWithTextEditing.contains(.newFolder))
    }

    func testUses() {
        let b = KeyBindings.defaults
        XCTAssertEqual(b.uses(of: .key(chord("cmd+["))), [.init(command: .back, slot: .primary)])
        XCTAssertEqual(b.uses(of: .key(chord("delete"))), [.init(command: .back, slot: .alternate)])
        XCTAssertEqual(b.uses(of: .mouse(mouse5)), [.init(command: .forward, slot: .mouse)])
        XCTAssertEqual(b.uses(of: .key(chord("opt+cmd+k"))), [])
    }

    // MARK: editing

    func testEditsBackToDefaultsLeaveNoEntry() {
        var o = KeyBindingOverrides.empty
        o.setPrimary(chord("opt+cmd+b"), for: .back)
        XCTAssertNotNil(o.commands[.back])
        o.setPrimary(chord("cmd+["), for: .back)
        XCTAssertNil(o.commands[.back])
        o.removeMouse(mouse4, from: .back)
        XCTAssertEqual(o.commands[.back], .init(mouse: []))
        o.reassign(.mouse(mouse4), to: .back, as: .mouse)
        XCTAssertEqual(o, .empty)
    }

    func testClearPrimaryStoresUnbound() {
        var o = KeyBindingOverrides.empty
        o.setPrimary(nil, for: .duplicate)
        XCTAssertEqual(o.commands[.duplicate], .init(primary: .unbound))
        XCTAssertNil(KeyBindings(overrides: o).primary(.duplicate))
    }

    func testReassignMovesTheTriggerFromEveryOtherUser() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("cmd+d")), to: .newFolder, as: .primary)
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.newFolder), chord("cmd+d"))
        XCTAssertNil(b.primary(.duplicate))
        o.reassign(.mouse(mouse4), to: .up, as: .mouse)
        let b2 = KeyBindings(overrides: o)
        XCTAssertEqual(b2.mouse(.up), [mouse4])
        XCTAssertEqual(b2.mouse(.back), [])
        XCTAssertEqual(b2.command(for: mouse4), .up)
    }

    func testReassignRemovesTheTriggerFromTheSameCommandsOtherSlot() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("opt+left")), to: .back, as: .primary)
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.back), chord("opt+left"))
        XCTAssertFalse(b.alternates(.back).contains(chord("opt+left")))
    }

    func testReassignAddsAlternatesWithoutDuplicates() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("ctrl+b")), to: .back, as: .alternate)
        o.reassign(.key(chord("ctrl+b")), to: .back, as: .alternate)
        XCTAssertEqual(KeyBindings(overrides: o).alternates(.back), KeyMap.alternates(.back) + [chord("ctrl+b")])
        o.removeAlternate(chord("ctrl+b"), from: .back)
        XCTAssertEqual(o, .empty)
    }

    func testInvalidEditsAndFixedCommandsAreIgnored() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("cmd+q")), to: .back, as: .primary)
        o.reassign(.key(chord("x")), to: .back, as: .primary)
        o.reassign(.mouse(mouse6), to: .back, as: .alternate)
        o.reassign(.key(chord("ctrl+e")), to: .cancelOperation, as: .alternate)
        o.setPrimary(chord("opt+cmd+e"), for: .cycleFocusForward)
        XCTAssertEqual(o, .empty)
    }

    func testReset() {
        var o = KeyBindingOverrides.empty
        o.setPrimary(nil, for: .back)
        o.setPrimary(nil, for: .forward)
        o.reset(.back)
        XCTAssertNil(o.commands[.back])
        XCTAssertNotNil(o.commands[.forward])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: compile errors `cannot find 'KeyBindings' in scope`.

- [ ] **Step 3: Implement**

Add to `KeyMap` in `Sources/Core/Commands/KeyMap.swift`, just above `collidesWithTextEditing` (leave that property in place; Task 4 removes it):

```swift
    /// Default mouse buttons (AppKit buttonNumber): the "back" side button (3) and the "forward" one (4), as in browsers.
    public static func defaultMouse(_ command: Command) -> [MouseButton] {
        switch command {
        case .back: [MouseButton(number: 3)!]
        case .forward: [MouseButton(number: 4)!]
        default: []
        }
    }

    /// Chords a text field uses for editing (⌘↑, ⌘↓, ⌘⌫, ⌥⌘⌫, ⌘[, ⌘], F2, ⌘D). A command whose primary is one of
    /// these is disabled while a field editor is active, so the key reaches the text (`KeyBindings.collidesWithTextEditing`).
    public static let textEditingChords: Set<KeyChord> = [
        KeyChord(.up, .command), KeyChord(.down, .command), KeyChord(.backspace, .command),
        KeyChord(.backspace, [.option, .command]), KeyChord(.character("["), .command), KeyChord(.character("]"), .command),
        KeyChord(.function(2)), KeyChord(.character("d"), .command),
    ]
```

```swift
// Sources/Core/Commands/KeyBindings.swift
import Foundation

public enum BindingRejection: Sendable, Equatable {
    /// ⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘, and ⌘` belong to the app and window menus; Tab, ⇧Tab and Esc to focus and cancel.
    case reserved
    /// A plain character or space (no ⌘, ⌃ or ⌥) as a menu shortcut would fire while typing a name.
    case typesTextAsPrimary
    /// A mouse button in a key slot, or a key in the mouse slot.
    case wrongSlot
}

/// The resolved key table: `KeyMap` defaults plus the user's `KeyBindingOverrides`.
public struct KeyBindings: Sendable, Equatable {
    public enum Slot: Sendable, Hashable { case primary, alternate, mouse }

    public struct Use: Sendable, Hashable {
        public let command: Command
        public let slot: Slot
        public init(command: Command, slot: Slot) {
            self.command = command
            self.slot = slot
        }
    }

    public static let defaults = KeyBindings(overrides: .empty)
    /// Tab / ⇧Tab (focus cycle) and Esc stay as they are; Settings shows them but can't edit them.
    public static let fixedCommands: Set<Command> = [.cycleFocusForward, .cycleFocusBackward, .cancelOperation]
    public static let reservedChords: Set<KeyChord> = [
        KeyChord(.character("q"), .command), KeyChord(.character("h"), .command),
        KeyChord(.character("h"), [.option, .command]), KeyChord(.character("m"), .command),
        KeyChord(.character(","), .command), KeyChord(.character("`"), .command),
        KeyChord(.tab), KeyChord(.tab, .shift), KeyChord(.escape),
    ]

    public let overrides: KeyBindingOverrides
    public let collidesWithTextEditing: Set<Command>
    private let primaries: [Command: KeyChord]
    private let alternateLists: [Command: [KeyChord]]
    private let mouseLists: [Command: [MouseButton]]
    private let alternateTable: [KeyChord: Command]
    private let mouseTable: [MouseButton: Command]

    public init(overrides: KeyBindingOverrides) {
        self.overrides = overrides
        var primaries: [Command: KeyChord] = [:]
        var alternateLists: [Command: [KeyChord]] = [:]
        var mouseLists: [Command: [MouseButton]] = [:]
        var alternateTable: [KeyChord: Command] = [:]
        var mouseTable: [MouseButton: Command] = [:]
        for command in Command.allCases {
            let entry = Self.fixedCommands.contains(command) ? nil : overrides.commands[command]
            let primary: KeyChord? = switch entry?.primary {
            case nil: KeyMap.primary(command)
            case .unbound?: nil
            case .chord(let chord)?: Self.validate(.key(chord), as: .primary) == nil ? chord : KeyMap.primary(command)
            }
            primaries[command] = primary
            let alternates = entry?.alternates ?? KeyMap.alternates(command)
            alternateLists[command] = alternates
            let mouse = entry?.mouse ?? KeyMap.defaultMouse(command)
            mouseLists[command] = mouse
            for chord in alternates where alternateTable[chord] == nil { alternateTable[chord] = command }
            for button in mouse where mouseTable[button] == nil { mouseTable[button] = command }
        }
        self.primaries = primaries
        self.alternateLists = alternateLists
        self.mouseLists = mouseLists
        self.alternateTable = alternateTable
        self.mouseTable = mouseTable
        self.collidesWithTextEditing = Set(primaries.compactMap { KeyMap.textEditingChords.contains($0.value) ? $0.key : nil })
    }

    public static func == (a: KeyBindings, b: KeyBindings) -> Bool { a.overrides == b.overrides }

    public func primary(_ command: Command) -> KeyChord? { primaries[command] }
    public func alternates(_ command: Command) -> [KeyChord] { alternateLists[command] ?? [] }
    public func mouse(_ command: Command) -> [MouseButton] { mouseLists[command] ?? [] }
    public func alternateCommand(for chord: KeyChord) -> Command? { alternateTable[chord] }
    public func command(for button: MouseButton) -> Command? { mouseTable[button] }

    /// Every command slot that currently holds `trigger`, in `Command.allCases` order.
    public func uses(of trigger: Trigger) -> [Use] {
        Command.allCases.flatMap { command -> [Use] in
            switch trigger {
            case .key(let chord):
                var uses: [Use] = []
                if primary(command) == chord { uses.append(Use(command: command, slot: .primary)) }
                if alternates(command).contains(chord) { uses.append(Use(command: command, slot: .alternate)) }
                return uses
            case .mouse(let button):
                return mouse(command).contains(button) ? [Use(command: command, slot: .mouse)] : []
            }
        }
    }

    public static func validate(_ trigger: Trigger, as slot: Slot) -> BindingRejection? {
        switch (trigger, slot) {
        case (.mouse, .mouse): return nil
        case (.mouse, _), (.key, .mouse): return .wrongSlot
        case (.key(let chord), _):
            if reservedChords.contains(chord) { return .reserved }
            if slot == .primary, chord.modifiers.isDisjoint(with: [.command, .control, .option]) {
                switch chord.key {
                case .character, .space: return .typesTextAsPrimary
                default: break
                }
            }
            return nil
        }
    }
}
```

```swift
// Sources/Core/Commands/KeyBindingOverrides+Editing.swift
import Foundation

/// Edits used by Settings › Shortcuts. Each edit rewrites only the slot it touches; a slot that ends up equal to its
/// `KeyMap` default is dropped, and an empty entry is removed, so "has an entry" means "differs from the defaults".
/// Fixed commands and triggers that fail `KeyBindings.validate` are ignored.
extension KeyBindingOverrides {
    private struct Slots {
        var primary: KeyChord?
        var alternates: [KeyChord]
        var mouse: [MouseButton]
    }

    public mutating func setPrimary(_ chord: KeyChord?, for command: Command) {
        if let chord, KeyBindings.validate(.key(chord), as: .primary) != nil { return }
        update(command) { $0.primary = chord }
    }

    public mutating func removeAlternate(_ chord: KeyChord, from command: Command) {
        update(command) { $0.alternates.removeAll { $0 == chord } }
    }

    public mutating func removeMouse(_ button: MouseButton, from command: Command) {
        update(command) { $0.mouse.removeAll { $0 == button } }
    }

    /// Gives `trigger` to `command`'s `slot`, first removing it from every other slot that holds it (including the
    /// same command's other slot).
    public mutating func reassign(_ trigger: Trigger, to command: Command, as slot: KeyBindings.Slot) {
        guard !KeyBindings.fixedCommands.contains(command), KeyBindings.validate(trigger, as: slot) == nil else { return }
        for use in KeyBindings(overrides: self).uses(of: trigger) where use != KeyBindings.Use(command: command, slot: slot) {
            remove(trigger, from: use)
        }
        update(command) { slots in
            switch (slot, trigger) {
            case (.primary, .key(let chord)): slots.primary = chord
            case (.alternate, .key(let chord)): if !slots.alternates.contains(chord) { slots.alternates.append(chord) }
            case (.mouse, .mouse(let button)):
                if !slots.mouse.contains(button) { slots.mouse.append(button); slots.mouse.sort() }
            default: break
            }
        }
    }

    public mutating func reset(_ command: Command) { commands[command] = nil }

    private mutating func remove(_ trigger: Trigger, from use: KeyBindings.Use) {
        switch (use.slot, trigger) {
        case (.primary, _): update(use.command) { $0.primary = nil }
        case (.alternate, .key(let chord)): removeAlternate(chord, from: use.command)
        case (.mouse, .mouse(let button)): removeMouse(button, from: use.command)
        default: break
        }
    }

    private mutating func update(_ command: Command, _ change: (inout Slots) -> Void) {
        guard !KeyBindings.fixedCommands.contains(command) else { return }
        let current = KeyBindings(overrides: self)
        var slots = Slots(primary: current.primary(command), alternates: current.alternates(command), mouse: current.mouse(command))
        change(&slots)
        var entry = Entry()
        if slots.primary != KeyMap.primary(command) { entry.primary = slots.primary.map(PrimaryOverride.chord) ?? .unbound }
        if slots.alternates != KeyMap.alternates(command) { entry.alternates = slots.alternates }
        if slots.mouse != KeyMap.defaultMouse(command) { entry.mouse = slots.mouse }
        commands[command] = entry.isEmpty ? nil : entry
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "KeyBindingsTests|KeyMapTests|KeyBindingOverridesTests" 2>&1 | tail -15`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Commands/KeyBindings.swift Sources/Core/Commands/KeyBindingOverrides+Editing.swift Sources/Core/Commands/KeyMap.swift Tests/CoreTests/KeyBindingsTests.swift
git commit -m "feat(core): resolve key bindings from defaults plus overrides, with validation and edits"
```

---

### Task 3: Persist overrides in `Settings`

**Files:**
- Modify: `Sources/Core/Settings/Settings.swift` (property, init load, `Key.keyBindings`)
- Test: `Tests/CoreTests/KeyBindingSettingsTests.swift`

**Interfaces:**
- Consumes: `KeyBindingOverrides`, `KeyBindings`.
- Produces: `Settings.keyBindingOverrides: KeyBindingOverrides` (observable, persisted under `"keyBindings"`, removed from storage when empty), `Settings.keyBindings: KeyBindings` (computed).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CoreTests/KeyBindingSettingsTests.swift
import XCTest
@testable import Core

@MainActor
final class KeyBindingSettingsTests: XCTestCase {
    private let home = URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory)

    func testDefaultIsEmptyAndNotWritten() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        XCTAssertEqual(s.keyBindingOverrides, .empty)
        XCTAssertEqual(s.keyBindings, .defaults)
        XCTAssertNil(storage.data(forKey: "keyBindings"))
    }

    func testEditsPersistAndReload() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        s.keyBindingOverrides.setPrimary(KeyChord(parsing: "opt+cmd+b"), for: .back)
        XCTAssertNotNil(storage.data(forKey: "keyBindings"))
        let reloaded = Settings(storage: storage, home: home)
        XCTAssertEqual(reloaded.keyBindings.primary(.back), KeyChord(parsing: "opt+cmd+b"))
    }

    func testResettingAllRemovesTheStoredValue() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: home)
        s.keyBindingOverrides.setPrimary(nil, for: .back)
        s.keyBindingOverrides = .empty
        XCTAssertNil(storage.data(forKey: "keyBindings"))
    }

    func testGarbageStoredValueFallsBackWithoutOverwriting() {
        let storage = InMemorySettingsStorage()
        let garbage = Data("[\"not an object\"]".utf8)
        storage.set(garbage, forKey: "keyBindings")
        let s = Settings(storage: storage, home: home)
        XCTAssertEqual(s.keyBindings, .defaults)
        XCTAssertEqual(storage.data(forKey: "keyBindings"), garbage)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: `value of type 'Settings' has no member 'keyBindingOverrides'`.

- [ ] **Step 3: Implement**

In `Sources/Core/Settings/Settings.swift`:

After the `offerToReportCrashes` property, add:

```swift
    /// Settings › Shortcuts: the user's changes to the key table (sparse; `.empty` = all defaults). Not stored while empty.
    public var keyBindingOverrides: KeyBindingOverrides {
        didSet { save(keyBindingOverrides.commands.isEmpty ? nil : keyBindingOverrides, Key.keyBindings) }
    }
    /// The resolved table for `keyBindingOverrides`.
    public var keyBindings: KeyBindings { KeyBindings(overrides: keyBindingOverrides) }
```

In `init`, after the `lastReportedCrashes = …` line:

```swift
        keyBindingOverrides = Self.load(KeyBindingOverrides.self, Key.keyBindings, from: storage) ?? .empty
```

In `private enum Key`, add a line:

```swift
        static let keyBindings = "keyBindings"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "KeyBindingSettingsTests|SettingsTypesTests" 2>&1 | tail -10`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Settings/Settings.swift Tests/CoreTests/KeyBindingSettingsTests.swift
git commit -m "feat(core): store key-binding overrides in Settings"
```

---

### Task 4: Route keys through the active bindings

Replace every reader of the fixed tables (`KeyDispatcher`'s static table, `KeyMap.collidesWithTextEditing`, `MainMenuBuilder.item`) with the resolved bindings. Add the UI-wide `ActiveKeyBindings.current` and the `KeyBindingsController` that keeps it and the menu bar in sync with Settings.

**Files:**
- Modify: `Sources/Core/Commands/KeyDispatcher.swift`
- Modify: `Sources/Core/Commands/CommandAvailability.swift:40-46`
- Modify: `Sources/Core/Commands/KeyMap.swift` (delete `collidesWithTextEditing`)
- Create: `Sources/UI/Menus/ActiveKeyBindings.swift`
- Modify: `Sources/UI/Menus/KeyRouter.swift`
- Modify: `Sources/UI/Menus/FieldEditorKeyRouting.swift`
- Modify: `Sources/UI/Menus/MenuValidation.swift`
- Modify: `Sources/UI/Menus/MainMenuBuilder.swift` (header comment, `item(_:)`, new `applyKeyEquivalents`)
- Modify: `Sources/UI/Sidebar/SidebarViewController.swift:79`, `Sources/UI/Window/ShellCommandHandler.swift:57`, `Sources/UI/Commands/FileCommandController.swift:39`
- Modify: `Sources/UI/App/UIContext.swift` (own a `KeyBindingsController`)
- Modify: `Tests/UITests/Support/ShellHarness.swift` (reset in `tearDown`)
- Modify tests: `Tests/CoreTests/KeyMapTests.swift:185-188`, `Tests/CoreTests/CommandAvailabilityTests.swift:132`, `Tests/UITests/MenuValidationTests.swift:31`
- Test: `Tests/CoreTests/KeyBindingsTests.swift` (add), `Tests/UITests/KeyBindingsRoutingTests.swift` (new)

**Interfaces:**
- Consumes: `KeyBindings`, `Settings.keyBindingOverrides`, `Settings.keyBindings`.
- Produces:
  - `KeyDispatcher.init(returnKey: ReturnKeyBehavior, bindings: KeyBindings = .defaults)`.
  - `CommandAvailability.isEnabled(_:focus:state:collidesWithTextEditing: Set<Command> = KeyBindings.defaults.collidesWithTextEditing)`.
  - `@MainActor enum ActiveKeyBindings { static var current: KeyBindings }`.
  - `@MainActor final class KeyBindingsController { init(settings: Core.Settings, menu: @escaping @MainActor () -> NSMenu?) }`.
  - `MainMenuBuilder.applyKeyEquivalents(_ bindings: KeyBindings, to menu: NSMenu)`.
  - `KeyRouter.send(_ command: Command, from view: NSView) -> Bool` (factored out of `handle`; used by Task 6).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CoreTests/KeyBindingsTests.swift`:

```swift
    func testDispatcherUsesCustomAlternates() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(chord("ctrl+b")), to: .back, as: .alternate)
        o.removeAlternate(chord("delete"), from: .back)
        let d = KeyDispatcher(returnKey: .rename, bindings: KeyBindings(overrides: o))
        XCTAssertEqual(d.command(for: chord("ctrl+b"), in: .content), .back)
        XCTAssertNil(d.command(for: chord("delete"), in: .content))
        XCTAssertEqual(d.command(for: chord("return"), in: .content), .rename, "Return → Rename still applies")
        XCTAssertNil(d.command(for: chord("ctrl+b"), in: .fieldEditor))
    }

    func testFieldEditorDisablesWhateverNowCollides() {
        var o = KeyBindingOverrides.empty
        o.setPrimary(chord("opt+cmd+d"), for: .duplicate)
        o.setPrimary(chord("cmd+d"), for: .newFolder)
        let collides = KeyBindings(overrides: o).collidesWithTextEditing
        let s = CommandState(selectionCount: 1)
        XCTAssertTrue(CommandAvailability.isEnabled(.duplicate, focus: .fieldEditor, state: s, collidesWithTextEditing: collides))
        XCTAssertFalse(CommandAvailability.isEnabled(.newFolder, focus: .fieldEditor, state: s, collidesWithTextEditing: collides))
    }
```

```swift
// Tests/UITests/KeyBindingsRoutingTests.swift
import XCTest
import AppKit
@testable import UI
import Core

@MainActor
final class KeyBindingsRoutingTests: XCTestCase {
    override func tearDown() async throws {
        ActiveKeyBindings.current = .defaults
        try await super.tearDown()
    }

    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
    }

    private func item(_ command: Command, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == "macx.menu.\(command.rawValue)" { return item }
            if let sub = item.submenu, let found = self.item(command, in: sub) { return found }
        }
        return nil
    }

    func testApplyKeyEquivalentsSetsChangesAndClears() throws {
        _ = NSApplication.shared
        let menu = MainMenuBuilder.build()
        var o = KeyBindingOverrides.empty
        o.setPrimary(KeyChord(parsing: "opt+cmd+b"), for: .back)
        o.setPrimary(nil, for: .duplicate)
        o.setPrimary(KeyChord(parsing: "opt+cmd+t"), for: .openInTerminal)
        MainMenuBuilder.applyKeyEquivalents(KeyBindings(overrides: o), to: menu)
        let back = try XCTUnwrap(item(.back, in: menu))
        XCTAssertEqual(back.keyEquivalent, "b")
        XCTAssertEqual(back.keyEquivalentModifierMask, [.option, .command])
        XCTAssertEqual(try XCTUnwrap(item(.duplicate, in: menu)).keyEquivalent, "")
        XCTAssertEqual(try XCTUnwrap(item(.openInTerminal, in: menu)).keyEquivalent, "t")
        MainMenuBuilder.applyKeyEquivalents(.defaults, to: menu)
        XCTAssertEqual(back.keyEquivalent, "[")
        XCTAssertEqual(back.keyEquivalentModifierMask, .command)
    }

    func testControllerTracksSettings() async throws {
        _ = NSApplication.shared
        let s = settings()
        let menu = MainMenuBuilder.build()
        let controller = KeyBindingsController(settings: s, menu: { menu })
        XCTAssertEqual(ActiveKeyBindings.current, .defaults)
        s.keyBindingOverrides.setPrimary(KeyChord(parsing: "opt+cmd+b"), for: .back)
        let deadline = ContinuousClock.now + .seconds(5)
        while ActiveKeyBindings.current.primary(.back) != KeyChord(parsing: "opt+cmd+b") {
            guard ContinuousClock.now < deadline else { return XCTFail("bindings never updated") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(item(.back, in: menu)?.keyEquivalent, "b")
        withExtendedLifetime(controller) {}
    }

    func testFieldEditorRoutingFollowsRebinding() {
        let cmdD = KeyEvents.key(2, "d", [.command])
        XCTAssertEqual(FieldEditorKeyRouting.collidingCommand(for: cmdD), .duplicate)
        var o = KeyBindingOverrides.empty
        o.setPrimary(KeyChord(parsing: "opt+cmd+d"), for: .duplicate)
        ActiveKeyBindings.current = KeyBindings(overrides: o)
        XCTAssertNil(FieldEditorKeyRouting.collidingCommand(for: cmdD))
        o.setPrimary(KeyChord(parsing: "cmd+d"), for: .newFolder)
        ActiveKeyBindings.current = KeyBindings(overrides: o)
        XCTAssertEqual(FieldEditorKeyRouting.collidingCommand(for: cmdD), .newFolder)
    }

    func testKeyRouterUsesActiveAlternates() {
        var o = KeyBindingOverrides.empty
        o.reassign(.key(KeyChord(parsing: "ctrl+b")!), to: .back, as: .alternate)
        ActiveKeyBindings.current = KeyBindings(overrides: o)
        let ctrlB = KeyEvents.key(11, "\u{2}", ignoring: "b", [.control])
        XCTAssertEqual(KeyRouter.command(for: ctrlB, focus: .content, returnKey: .open), .back)
    }
}
```

(`KeyEvents` is the internal helper in `Tests/UITests/KeyRouterTests.swift`; it is visible to every file in the UITests target.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: errors such as `extra argument 'bindings' in call`, `cannot find 'ActiveKeyBindings' in scope`.

- [ ] **Step 3: Implement — Core**

`Sources/Core/Commands/KeyDispatcher.swift`: replace the `returnKey`/`table`/`init` block with:

```swift
    private let returnKey: ReturnKeyBehavior
    private let bindings: KeyBindings

    public init(returnKey: ReturnKeyBehavior, bindings: KeyBindings = .defaults) {
        self.returnKey = returnKey
        self.bindings = bindings
    }
```

and in `command(for:in:)` replace `guard var command = Self.table[chord] else { return nil }` with:

```swift
        guard var command = bindings.alternateCommand(for: chord) else { return nil }
```

Update the doc comment above `command(for:in:)` from "Alternates only (Return/⌥Return, …)" to "The current alternates only (defaults: Return/⌥Return, …)".

`Sources/Core/Commands/CommandAvailability.swift`: change the signature and the field-editor check:

```swift
    /// `.fieldEditor` disables the commands in `collidesWithTextEditing` (pass `KeyBindings.collidesWithTextEditing`
    /// for the bindings in use) so their keys reach the text field; the standard edit actions stay enabled there
    /// because the field editor validates them itself.
    public static func isEnabled(_ command: Command, focus: FocusContext, state: CommandState,
                                 collidesWithTextEditing: Set<Command> = KeyBindings.defaults.collidesWithTextEditing) -> Bool {
        let section = Section(focus)
        if section == .fieldEditor {
            if collidesWithTextEditing.contains(command) { return false }
            if fieldEditorOwned.contains(command) { return true }
        }
```

`Sources/Core/Commands/KeyMap.swift`: delete `collidesWithTextEditing` and its doc comment. Change the type's doc comment first line to: `/// The §5.6 built-in key table (defaults; the user's changes live in Settings › Shortcuts, see KeyBindings).`

- [ ] **Step 4: Implement — UI**

```swift
// Sources/UI/Menus/ActiveKeyBindings.swift
import AppKit
import Core

/// The key table every window uses right now. `KeyBindingsController` replaces it whenever Settings › Shortcuts
/// changes; key routing, menu validation and mouse routing read it.
@MainActor enum ActiveKeyBindings {
    static var current: KeyBindings = .defaults
}

/// Keeps `ActiveKeyBindings.current` and the menu bar's key equivalents in step with `settings.keyBindingOverrides`.
@MainActor final class KeyBindingsController {
    private var loop: ObservationLoop?

    init(settings: Core.Settings, menu: @escaping @MainActor () -> NSMenu? = { NSApplication.shared.mainMenu }) {
        let apply: @MainActor () -> Void = { [weak settings] in
            guard let settings else { return }
            let bindings = settings.keyBindings
            ActiveKeyBindings.current = bindings
            if let menu = menu() { MainMenuBuilder.applyKeyEquivalents(bindings, to: menu) }
        }
        apply()
        loop = ObservationLoop({ [weak settings] in _ = settings?.keyBindingOverrides }, onChange: apply)
    }
}
```

`Sources/UI/Menus/KeyRouter.swift`: replace `handle` and `command(for:)` with:

```swift
    static func handle(_ event: NSEvent, focus: FocusContext, returnKey: ReturnKeyBehavior, from view: NSView) -> Bool {
        guard let command = command(for: event, focus: focus, returnKey: returnKey) else { return false }
        return send(command, from: view)
    }

    /// Sends `command`'s action to the first responder up the chain from `view` that implements it, else nil-targeted.
    @discardableResult static func send(_ command: Command, from view: NSView) -> Bool {
        let action = Selector(command.selectorName)
        if let responder = responder(for: action, from: view) {
            return NSApp.sendAction(action, to: responder, from: view)
        }
        return NSApp.sendAction(action, to: nil, from: view)
    }

    /// The command a keyDown maps to with the active bindings (nil: not an alternate here).
    static func command(for event: NSEvent, focus: FocusContext, returnKey: ReturnKeyBehavior) -> Command? {
        guard event.type == .keyDown, let chord = KeyEventTranslator.chord(for: event) else { return nil }
        return KeyDispatcher(returnKey: returnKey, bindings: ActiveKeyBindings.current).command(for: chord, in: focus)
    }
```

`Sources/UI/Menus/FieldEditorKeyRouting.swift`: delete the `collidingPrimaries` static and replace `collidingCommand` with:

```swift
    /// The colliding command whose current primary `event` is, if any.
    static func collidingCommand(for event: NSEvent) -> Command? {
        guard event.type == .keyDown, let chord = KeyEventTranslator.chord(for: event) else { return nil }
        let bindings = ActiveKeyBindings.current
        return bindings.collidesWithTextEditing.first { bindings.primary($0) == chord }
    }
```

In its header comment replace "the primaries of `KeyMap.collidesWithTextEditing` (⌘↑, …, ⌘D)" with "the primaries in `KeyBindings.collidesWithTextEditing` (by default ⌘↑, ⌘↓, ⌘⌫, ⌥⌘⌫, ⌘[, ⌘], F2, ⌘D)".

`Sources/UI/Menus/MenuValidation.swift`:

```swift
    /// false for the active bindings' colliding commands while a field editor is first responder.
    static func isEnabled(_ command: Command, window: NSWindow?, state: CommandState, focus: FocusContext) -> Bool {
        CommandAvailability.isEnabled(command, focus: isFieldEditorActive(in: window) ? .fieldEditor : focus, state: state,
                                      collidesWithTextEditing: ActiveKeyBindings.current.collidesWithTextEditing)
    }

    /// The colliding command's key (⌘⌫, ⌘[, F2, ⌘D…) must reach the text field being edited.
    static func blockedByFieldEditor(_ command: Command, window: NSWindow?) -> Bool {
        ActiveKeyBindings.current.collidesWithTextEditing.contains(command) && isFieldEditorActive(in: window)
    }
```

The other three `CommandAvailability.isEnabled` callers get the same extra argument, `collidesWithTextEditing: ActiveKeyBindings.current.collidesWithTextEditing`:
- `Sources/UI/Sidebar/SidebarViewController.swift:79`
- `Sources/UI/Window/ShellCommandHandler.swift:57`
- `Sources/UI/Commands/FileCommandController.swift:39`

`Sources/UI/Menus/MainMenuBuilder.swift`:
- Header comment: replace "take their single key equivalent from `KeyMap.primary` (rebindable in System Settings › Keyboard › App Shortcuts)" with "take their single key equivalent from the active bindings' primary (Settings › Shortcuts; System Settings › Keyboard › App Shortcuts still overrides it)".
- Replace `item(_:)` and add `applyKeyEquivalents` plus a shared setter:

```swift
    /// A command item: nil target, `macx.menu.<raw>` identifier, the active primary.
    static func item(_ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: MainMenuTitles.title(command), action: Selector(command.selectorName), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("macx.menu.\(command.rawValue)")
        if let chord = ActiveKeyBindings.current.primary(command) { setKeyEquivalent(of: item, to: chord) }
        return item
    }

    /// Rewrites the key equivalent of every command item in `menu` (recursively) from `bindings`. Never rebuilds.
    static func applyKeyEquivalents(_ bindings: KeyBindings, to menu: NSMenu) {
        let prefix = "macx.menu."
        for item in menu.items {
            if let submenu = item.submenu { applyKeyEquivalents(bindings, to: submenu) }
            guard let id = item.identifier?.rawValue, id.hasPrefix(prefix),
                  let command = Command(rawValue: String(id.dropFirst(prefix.count))) else { continue }
            setKeyEquivalent(of: item, to: bindings.primary(command))
        }
    }

    private static func setKeyEquivalent(of item: NSMenuItem, to chord: KeyChord?) {
        if let chord, let equivalent = keyEquivalent(for: chord) {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }
```

`Sources/UI/App/UIContext.swift`: add a stored property next to `settingsWindow`:

```swift
    /// Keeps the active key table and the menu bar in step with Settings › Shortcuts.
    private var keyBindings: KeyBindingsController?
```

and at the end of `init`, after `installInteraction(operationsUI.router)`:

```swift
        keyBindings = KeyBindingsController(settings: environment.settings)
```

`Tests/UITests/Support/ShellHarness.swift`: first line of `tearDown()`:

```swift
        ActiveKeyBindings.current = .defaults
```

- [ ] **Step 5: Update existing tests that used `KeyMap.collidesWithTextEditing`**

- `Tests/CoreTests/KeyMapTests.swift` — delete `testCollidingPrimaries` (now `KeyBindingsTests.testCollisionFollowsTheChord`).
- `Tests/CoreTests/CommandAvailabilityTests.swift:132` — `for c in KeyMap.collidesWithTextEditing {` → `for c in KeyBindings.defaults.collidesWithTextEditing {`.
- `Tests/UITests/MenuValidationTests.swift:31` — same replacement. At line ~83 in `testKeyEquivalentsComeFromKeyMapPrimaries`, `KeyMap.primary(command)` stays correct (defaults are active in tests).

- [ ] **Step 6: Run the full suite**

Run: `swift build 2>&1 | tail -5 && swift test > /tmp/macx-kb-test.log 2>&1; tail -30 /tmp/macx-kb-test.log; grep -E "error:|failed" /tmp/macx-kb-test.log | head -20`
Expected: no failures. `grep -rn "collidesWithTextEditing" Sources Tests` shows no `KeyMap.collidesWithTextEditing`.

- [ ] **Step 7: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: route keys and menu equivalents through the active key bindings"
```

---

### Task 5: Mouse buttons navigate (router + app hook)

**Files:**
- Create: `Sources/UI/Menus/MouseRouter.swift`
- Modify: `Sources/UI/App/MacxApplication.swift` (`sendEvent`)
- Test: `Tests/UITests/MouseRouterTests.swift`

**Interfaces:**
- Consumes: `ActiveKeyBindings.current.command(for: MouseButton)`, `KeyRouter.send(_:from:)`, `BrowserWindowController.contentPane`.
- Produces: `@MainActor enum MouseRouter { static func handle(_ event: NSEvent, in window: NSWindow?) -> Bool }` and test helper `MouseEvents.otherDown(_ buttonNumber: Int) -> NSEvent` (in the test file, used by Task 7 too).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/MouseRouterTests.swift
import XCTest
import AppKit
import CoreGraphics
@testable import UI
import Core

@MainActor
enum MouseEvents {
    /// A real `.otherMouseDown` with `buttonNumber` set (NSEvent.mouseEvent can't set it).
    static func otherDown(_ buttonNumber: Int) -> NSEvent {
        let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                         mouseButton: CGMouseButton(rawValue: UInt32(buttonNumber))!)!
        return NSEvent(cgEvent: cg)!
    }
}

@MainActor
final class MouseRouterTests: XCTestCase {
    func testSyntheticEventCarriesTheButtonNumber() {
        let event = MouseEvents.otherDown(3)
        XCTAssertEqual(event.type, .otherMouseDown)
        XCTAssertEqual(event.buttonNumber, 3)
    }

    func testBackAndForwardButtonsNavigateHistory() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("A/B")
        let controller = try await h.openWindow("A")
        controller.navigate(to: h.url("A/B"))
        try await h.waitUntil("in B") { controller.session.folder.directory.lastPathComponent == "B" }
        XCTAssertTrue(MouseRouter.handle(MouseEvents.otherDown(3), in: controller.window))
        try await h.waitUntil("back in A") { controller.session.folder.directory.lastPathComponent == "A" }
        XCTAssertTrue(MouseRouter.handle(MouseEvents.otherDown(4), in: controller.window))
        try await h.waitUntil("forward to B") { controller.session.folder.directory.lastPathComponent == "B" }
    }

    func testReboundButtonFollowsActiveBindings() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("A/B")
        let controller = try await h.openWindow("A/B")
        h.environment.settings.keyBindingOverrides.reassign(.mouse(MouseButton(number: 5)!), to: .up, as: .mouse)
        try await h.waitUntil("bindings applied") { ActiveKeyBindings.current.command(for: MouseButton(number: 5)!) == .up }
        XCTAssertTrue(MouseRouter.handle(MouseEvents.otherDown(5), in: controller.window))
        try await h.waitUntil("up to A") { controller.session.folder.directory.lastPathComponent == "A" }
    }

    func testUnboundButtonAndOtherEventsPassThrough() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        XCTAssertFalse(MouseRouter.handle(MouseEvents.otherDown(6), in: controller.window), "unbound")
        XCTAssertFalse(MouseRouter.handle(MouseEvents.otherDown(2), in: controller.window), "middle button")
        XCTAssertFalse(MouseRouter.handle(KeyEvents.backspace(), in: controller.window), "not a mouse event")
    }

    func testNonBrowserWindowIsIgnored() throws {
        try ShellHarness.requireWindowServer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(MouseRouter.handle(MouseEvents.otherDown(3), in: window))
        XCTAssertFalse(MouseRouter.handle(MouseEvents.otherDown(3), in: nil))
    }

    func testUnavailableCommandIsConsumed() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        XCTAssertFalse(controller.session.history.canGoBack)
        let before = controller.session.folder.directory
        XCTAssertTrue(MouseRouter.handle(MouseEvents.otherDown(3), in: controller.window))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.session.folder.directory, before)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: `cannot find 'MouseRouter' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/UI/Menus/MouseRouter.swift
import AppKit
import Core

/// Extra mouse buttons (Settings › Shortcuts; by default Mouse 4 = Back, Mouse 5 = Forward). Works anywhere in a
/// browser window, text fields included, as in browsers. The command goes to the window's content pane through the
/// same responder walk as alternate keys, so it acts as if the file list had focus; unavailable commands do nothing.
@MainActor enum MouseRouter {
    /// Returns true if the event was a bound mouse button in a browser window (and was consumed).
    static func handle(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.type == .otherMouseDown,
              let button = MouseButton(number: event.buttonNumber),
              let command = ActiveKeyBindings.current.command(for: button),
              let controller = window?.windowController as? BrowserWindowController,
              let view = controller.contentPane?.view else { return false }
        KeyRouter.send(command, from: view)
        return true
    }
}
```

`Sources/UI/App/MacxApplication.swift`, in `sendEvent`, after the `FieldEditorKeyRouting` line:

```swift
        if event.type == .otherMouseDown, MouseRouter.handle(event, in: event.window ?? keyWindow) { return }
```

Update that method's doc comment to: `/// §5.6 routing 1–3: colliding primaries reach the field editor being edited (FieldEditorKeyRouting); bound extra mouse buttons run their command (MouseRouter).`

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "MouseRouterTests|MacxApplicationTests" 2>&1 | tail -15`
Expected: all pass (window-server tests skip without a GUI session; run in a logged-in session to see them pass).

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/Menus/MouseRouter.swift Sources/UI/App/MacxApplication.swift Tests/UITests/MouseRouterTests.swift
git commit -m "feat: mouse back/forward buttons navigate folder history"
```

---

### Task 6: Scenario `mouse` step and `mouse-back-forward` scenario

**Files:**
- Modify: `Sources/UI/Scenario/ScenarioFile.swift` (`Step.mouse`, `actions`, `ValidationError.badMouse`, `validate`)
- Modify: `Sources/UI/Scenario/ScenarioDriver.swift` (`perform`, new `sendMouse`)
- Create: `Tests/Scenarios/mouse-back-forward.json`
- Modify: `Tests/UITests/ScenarioCatalogTests.swift:16` (count 28 → 29)
- Test: `Tests/UITests/ScenarioFileTests.swift` (add one test)

**Interfaces:**
- Consumes: `MouseButton(parsing:)`, `MacxApplication.sendEvent` → `MouseRouter`.
- Produces: scenario step `{"mouse": "mouse4"}`.

- [ ] **Step 1: Write the failing tests and the scenario**

Add to `Tests/UITests/ScenarioFileTests.swift` (inside its test class):

```swift
    func testMouseStepValidates() throws {
        let ok = #"{"name": "m", "fixture": {"files": [], "dirs": []}, "steps": [{"mouse": "mouse4"}]}"#
        XCTAssertEqual(try ScenarioFile.load(Data(ok.utf8)).steps.first?.actions, ["mouse"])
        let bad = #"{"name": "m", "fixture": {"files": [], "dirs": []}, "steps": [{"mouse": "mouse2"}]}"#
        XCTAssertThrowsError(try ScenarioFile.load(Data(bad.utf8))) { error in
            XCTAssertEqual(error as? ScenarioFile.ValidationError, .badMouse(step: 0, "mouse2"))
        }
    }
```

```json
{"name": "mouse-back-forward",
 "fixture": {"files": ["A/B/c.txt"], "dirs": ["A", "A/B"]},
 "steps": [
  {"doubleClick": "A"}, {"waitFor": {"folder": "A", "rows": ["B"]}},
  {"doubleClick": "B"}, {"waitFor": {"folder": "A/B", "rows": ["c.txt"]}},
  {"mouse": "mouse4"}, {"waitFor": {"folder": "A", "rows": ["B"]}},
  {"mouse": "mouse4"}, {"waitFor": {"folder": ""}},
  {"mouse": "mouse5"}, {"waitFor": {"folder": "A"}},
  {"mouse": "mouse5"}, {"waitFor": {"folder": "A/B", "rows": ["c.txt"]}}
 ]}
```

Save that as `Tests/Scenarios/mouse-back-forward.json`, and change `XCTAssertEqual(urls.count, 28)` to `29` in `ScenarioCatalogTests`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: `type 'ScenarioFile.ValidationError' has no member 'badMouse'`.

- [ ] **Step 3: Implement**

`Sources/UI/Scenario/ScenarioFile.swift`:
- In `Step`, after `answerAlert`: `var mouse: String?                    // additive: "mouse4" = buttonNumber 3, via MacxApplication.sendEvent`
- In `actions`, add `("mouse", mouse != nil)` after `("key", key != nil)`.
- In `ValidationError`, add `case badMouse(step: Int, String)` and its description `case .badMouse(let s, let m): "step \(s): mouse button '\(m)' must be mouse4…mouse9"`.
- In `validate()`, after the `key` check: `if let mouse = step.mouse, MouseButton(parsing: mouse) == nil { throw .badMouse(step: index, mouse) }`.
- Add `Step.mouse` to the header comment's list of additive fields.

`Sources/UI/Scenario/ScenarioDriver.swift`:
- In `perform`, after the `key` branch: `else if let mouse = step.mouse { try await sendMouse(mouse) }`.
- Next to `sendKey`:

```swift
    /// An extra mouse button press, delivered synchronously through MacxApplication.sendEvent (MouseRouter) to the
    /// pinned key window, like a real click on it.
    private func sendMouse(_ text: String) async throws {
        guard let button = MouseButton(parsing: text),
              let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                               mouseButton: CGMouseButton(rawValue: UInt32(button.number))!),
              let event = NSEvent(cgEvent: cg) else { throw DriverError("cannot synthesize '\(text)'") }
        NSApp.sendEvent(event)
        await fence()
    }
```

(Add `import CoreGraphics` at the top of the file if it isn't already reachable through AppKit.)

- [ ] **Step 4: Run tests and the scenario**

Run: `swift test --filter "ScenarioFileTests|ScenarioCatalogTests" 2>&1 | tail -10`
Expected: pass.

Run: `scripts/ui-scenarios.sh --filter mouse-back-forward 2>&1 | tail -15`
Expected: `mouse-back-forward` passes (exit 0). Without a GUI session the script exits 0 and reports a skip; in that case say so in the task report.

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/Scenario/ScenarioFile.swift Sources/UI/Scenario/ScenarioDriver.swift Tests/Scenarios/mouse-back-forward.json Tests/UITests/ScenarioCatalogTests.swift Tests/UITests/ScenarioFileTests.swift
git commit -m "test: scenario mouse step and mouse back/forward scenario"
```

---

### Task 7: Shortcuts model, display strings and recorder

The logic behind the Settings tab, kept out of SwiftUI so it can be unit-tested.

**Files:**
- Create: `Sources/UI/Support/KeyChord+Display.swift`
- Create: `Sources/UI/Settings/ShortcutsModel.swift`
- Create: `Sources/UI/Settings/ShortcutRecorder.swift`
- Modify: `Sources/UI/Resources/Localizable.xcstrings` (via `scripts/l10n-add.sh`)
- Test: `Tests/UITests/ShortcutsModelTests.swift`

**Interfaces:**
- Consumes: `Settings.keyBindingOverrides`, `KeyBindings`, `MainMenuTitles.title`, `KeyEventTranslator.chord(for:)`.
- Produces:
  - `KeyChord.displayString: String` ("⌥⌘⌫"), `MouseButton.displayName: String` ("Mouse 4"), `Trigger.displayString`.
  - `ShortcutsModel` (`@MainActor struct`): `static let groups: [ShortcutGroup]`, `init(settings:)`, `func groups(matching query: String) -> [ShortcutGroup]`, `func isModified(_:) -> Bool`, `func apply(_ trigger: Trigger, to: Command, as: KeyBindings.Slot, reassigning: Bool) -> ShortcutApply`, `func clearPrimary(_:)`, `func remove(_ trigger: Trigger, from: Command)`, `func reset(_:)`, `func resetAll()`, `static func message(_: BindingRejection) -> String`, `func conflictMessage(_ trigger: Trigger, _ uses: [KeyBindings.Use]) -> String`.
  - `ShortcutGroup` (`id: String`, `title: String`, `commands: [Command]`), `ShortcutApply` (`.saved`, `.rejected(BindingRejection)`, `.conflict([KeyBindings.Use])`).
  - `ShortcutRecorder` (`@MainActor final class`): `enum Outcome { case trigger(Trigger), clear, cancel }`, `static func outcome(for: NSEvent, acceptsMouse: Bool, backspaceClears: Bool) -> Outcome?`, `func start(acceptsMouse:backspaceClears:_:)`, `func stop()`, `var isRecording: Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UITests/ShortcutsModelTests.swift
import XCTest
import AppKit
@testable import UI
import Core

@MainActor
final class ShortcutsModelTests: XCTestCase {
    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
    }
    private func chord(_ t: String) -> KeyChord { KeyChord(parsing: t)! }

    func testDisplayStrings() {
        XCTAssertEqual(chord("opt+cmd+delete").displayString, "⌥⌘⌫")
        XCTAssertEqual(chord("ctrl+opt+shift+cmd+up").displayString, "⌃⌥⇧⌘↑")
        XCTAssertEqual(chord("cmd+[").displayString, "⌘[")
        XCTAssertEqual(chord("shift+cmd+n").displayString, "⇧⌘N")
        XCTAssertEqual(chord("F2").displayString, "F2")
        XCTAssertEqual(chord("fn+delete").displayString, "⌦")
        XCTAssertEqual(chord("space").displayString, "Space")
        XCTAssertEqual(chord("return").displayString, "↩")
        XCTAssertEqual(MouseButton(number: 3)!.displayName, "Mouse 4")
        XCTAssertEqual(Trigger.mouse(MouseButton(number: 4)!).displayString, "Mouse 5")
    }

    func testGroupsListEveryCommandOnce() {
        let listed = ShortcutsModel.groups.flatMap(\.commands)
        XCTAssertEqual(listed.count, Command.allCases.count)
        XCTAssertEqual(Set(listed), Set(Command.allCases))
    }

    func testSearchMatchesTitleGlyphTextAndMouse() {
        let m = ShortcutsModel(settings: settings())
        XCTAssertEqual(m.groups(matching: "").flatMap(\.commands).count, Command.allCases.count)
        XCTAssertTrue(m.groups(matching: "back").flatMap(\.commands).contains(.back))
        XCTAssertTrue(m.groups(matching: "⌘[").flatMap(\.commands).contains(.back))
        XCTAssertTrue(m.groups(matching: "cmd+[").flatMap(\.commands).contains(.back))
        XCTAssertEqual(m.groups(matching: "mouse 5").flatMap(\.commands), [.forward])
        XCTAssertEqual(m.groups(matching: "zzzz"), [])
    }

    func testApplySavesRejectsAndReportsConflicts() {
        let s = settings()
        let m = ShortcutsModel(settings: s)
        XCTAssertEqual(m.apply(.key(chord("opt+cmd+b")), to: .back, as: .primary, reassigning: false), .saved)
        XCTAssertEqual(s.keyBindings.primary(.back), chord("opt+cmd+b"))
        XCTAssertTrue(m.isModified(.back))
        XCTAssertEqual(m.apply(.key(chord("cmd+q")), to: .back, as: .primary, reassigning: false), .rejected(.reserved))
        XCTAssertEqual(m.apply(.key(chord("x")), to: .back, as: .primary, reassigning: false), .rejected(.typesTextAsPrimary))
        XCTAssertEqual(m.apply(.key(chord("cmd+d")), to: .newFolder, as: .primary, reassigning: false),
                       .conflict([.init(command: .duplicate, slot: .primary)]))
        XCTAssertEqual(s.keyBindings.primary(.duplicate), chord("cmd+d"), "a conflict saves nothing")
        XCTAssertEqual(m.apply(.key(chord("cmd+d")), to: .newFolder, as: .primary, reassigning: true), .saved)
        XCTAssertNil(s.keyBindings.primary(.duplicate))
        XCTAssertEqual(m.apply(.mouse(MouseButton(number: 5)!), to: .up, as: .mouse, reassigning: false), .saved)
        XCTAssertEqual(s.keyBindings.command(for: MouseButton(number: 5)!), .up)
    }

    func testReapplyingTheSameTriggerToTheSameSlotIsNotAConflict() {
        let m = ShortcutsModel(settings: settings())
        XCTAssertEqual(m.apply(.key(chord("cmd+[")), to: .back, as: .primary, reassigning: false), .saved)
        XCTAssertFalse(m.isModified(.back))
    }

    func testRemoveClearResetAndResetAll() {
        let s = settings()
        let m = ShortcutsModel(settings: s)
        m.remove(.mouse(MouseButton(number: 3)!), from: .back)
        XCTAssertNil(s.keyBindings.command(for: MouseButton(number: 3)!))
        m.clearPrimary(.forward)
        XCTAssertNil(s.keyBindings.primary(.forward))
        m.reset(.back)
        XCTAssertEqual(s.keyBindings.command(for: MouseButton(number: 3)!), .back)
        m.resetAll()
        XCTAssertEqual(s.keyBindingOverrides, .empty)
    }

    func testMessages() {
        let m = ShortcutsModel(settings: settings())
        XCTAssertEqual(ShortcutsModel.message(.reserved), "Reserved by macOS or MacExplorer.")
        XCTAssertEqual(ShortcutsModel.message(.typesTextAsPrimary), "Menu shortcuts need ⌘, ⌃ or ⌥.")
        XCTAssertEqual(m.conflictMessage(.key(chord("cmd+d")), [.init(command: .duplicate, slot: .primary)]),
                       "⌘D is used by Duplicate.")
    }

    func testRecorderOutcomes() {
        typealias R = ShortcutRecorder
        XCTAssertEqual(R.outcome(for: KeyEvents.key(53, "\u{1b}"), acceptsMouse: true, backspaceClears: true), .cancel)
        XCTAssertEqual(R.outcome(for: KeyEvents.backspace(), acceptsMouse: false, backspaceClears: true), .clear)
        XCTAssertEqual(R.outcome(for: KeyEvents.backspace(), acceptsMouse: true, backspaceClears: false),
                       .trigger(.key(KeyChord(.backspace))))
        XCTAssertEqual(R.outcome(for: KeyEvents.key(11, "b", [.option, .command]), acceptsMouse: false, backspaceClears: true),
                       .trigger(.key(chord("opt+cmd+b"))))
        XCTAssertEqual(R.outcome(for: MouseEvents.otherDown(5), acceptsMouse: true, backspaceClears: false),
                       .trigger(.mouse(MouseButton(number: 5)!)))
        XCTAssertNil(R.outcome(for: MouseEvents.otherDown(5), acceptsMouse: false, backspaceClears: true))
        XCTAssertNil(R.outcome(for: MouseEvents.otherDown(2), acceptsMouse: true, backspaceClears: false))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: `cannot find 'ShortcutsModel' in scope`.

- [ ] **Step 3: Implement display strings**

```swift
// Sources/UI/Support/KeyChord+Display.swift
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
```

- [ ] **Step 4: Implement the model**

```swift
// Sources/UI/Settings/ShortcutsModel.swift
import Core

struct ShortcutGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let commands: [Command]
}

enum ShortcutApply: Equatable {
    case saved
    case rejected(BindingRejection)
    case conflict([KeyBindings.Use])
}

/// Settings › Shortcuts logic: groups, search, and edits written straight to `settings.keyBindingOverrides`.
@MainActor struct ShortcutsModel {
    let settings: Core.Settings

    /// Main-menu order. Every Command appears exactly once.
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(id: "open", title: L10n.string("Open"),
                      commands: [.open, .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder]),
        ShortcutGroup(id: "edit", title: L10n.string("Edit"),
                      commands: [.undo, .redo, .cut, .copy, .paste, .moveItemHere, .copyAsPath]),
        ShortcutGroup(id: "selection", title: L10n.string("Selection"), commands: [.selectAll, .selectNone, .invertSelection]),
        ShortcutGroup(id: "file", title: L10n.string("File"),
                      commands: [.newFolder, .newTextFile, .newEmptyFile, .rename, .duplicate, .makeAlias, .makeSymlink,
                                 .moveToTrash, .deletePermanently, .share, .properties]),
        ShortcutGroup(id: "navigation", title: L10n.string("Navigation"),
                      commands: [.back, .forward, .up, .focusAddressBar, .focusSearch, .refresh,
                                 .cycleFocusForward, .cycleFocusBackward, .cancelOperation]),
        ShortcutGroup(id: "window", title: L10n.string("Window"), commands: [.newWindow, .closeWindow, .showOperations]),
        ShortcutGroup(id: "view", title: L10n.string("View"),
                      commands: [.viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
                                 .densityCompact, .densityRegular, .densityComfortable, .toggleHidden, .toggleCommandBar]),
        ShortcutGroup(id: "sort", title: L10n.string("Sort"),
                      commands: [.sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated,
                                 .sortAscending, .sortDescending]),
        ShortcutGroup(id: "sidebar", title: L10n.string("Sidebar"), commands: [.eject, .removeFromFavorites]),
    ]

    var bindings: KeyBindings { settings.keyBindings }

    func title(_ command: Command) -> String { MainMenuTitles.title(command) }

    /// Groups with only the commands matching `query` (title, glyphs "⌘[", text form "cmd+[", or "mouse 4"); empty groups dropped.
    func groups(matching query: String) -> [ShortcutGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.groups }
        let b = bindings
        return Self.groups.compactMap { group in
            let commands = group.commands.filter { command in
                let chords = [b.primary(command)].compactMap { $0 } + b.alternates(command)
                let haystack = [title(command)] + chords.flatMap { [$0.displayString, $0.description] }
                    + b.mouse(command).flatMap { [$0.displayName, $0.description] }
                return haystack.contains { $0.lowercased().contains(q) }
            }
            return commands.isEmpty ? nil : ShortcutGroup(id: group.id, title: group.title, commands: commands)
        }
    }

    func isModified(_ command: Command) -> Bool { settings.keyBindingOverrides.commands[command] != nil }
    func isFixed(_ command: Command) -> Bool { KeyBindings.fixedCommands.contains(command) }

    /// Validates, then saves unless another slot holds `trigger` and `reassigning` is false.
    func apply(_ trigger: Trigger, to command: Command, as slot: KeyBindings.Slot, reassigning: Bool) -> ShortcutApply {
        if let rejection = KeyBindings.validate(trigger, as: slot) { return .rejected(rejection) }
        let others = bindings.uses(of: trigger).filter { $0 != KeyBindings.Use(command: command, slot: slot) }
        if !others.isEmpty, !reassigning { return .conflict(others) }
        settings.keyBindingOverrides.reassign(trigger, to: command, as: slot)
        return .saved
    }

    func clearPrimary(_ command: Command) { settings.keyBindingOverrides.setPrimary(nil, for: command) }

    func remove(_ trigger: Trigger, from command: Command) {
        switch trigger {
        case .key(let chord): settings.keyBindingOverrides.removeAlternate(chord, from: command)
        case .mouse(let button): settings.keyBindingOverrides.removeMouse(button, from: command)
        }
    }

    func reset(_ command: Command) { settings.keyBindingOverrides.reset(command) }
    func resetAll() { settings.keyBindingOverrides = .empty }

    static func message(_ rejection: BindingRejection) -> String {
        switch rejection {
        case .reserved: L10n.string("Reserved by macOS or MacExplorer.")
        case .typesTextAsPrimary: L10n.string("Menu shortcuts need ⌘, ⌃ or ⌥.")
        case .wrongSlot: L10n.string("Mouse buttons can only be added as extras.")
        }
    }

    func conflictMessage(_ trigger: Trigger, _ uses: [KeyBindings.Use]) -> String {
        let names = uses.map { title($0.command) }.joined(separator: ", ")
        return String(format: L10n.string("%@ is used by %@."), trigger.displayString, names)
    }
}
```

- [ ] **Step 5: Implement the recorder**

```swift
// Sources/UI/Settings/ShortcutRecorder.swift
import AppKit
import Core

/// Captures the next key press (or extra mouse button) for Settings › Shortcuts. A local event monitor runs before
/// sendEvent, so the captured event never reaches menus, key routing or MouseRouter.
@MainActor final class ShortcutRecorder {
    enum Outcome: Equatable {
        case trigger(Trigger)
        case clear
        case cancel
    }

    private var monitor: Any?
    private(set) var isRecording = false

    /// Esc cancels. ⌫ clears when `backspaceClears` (the Shortcut cell), else records ⌫. Mouse buttons only when
    /// `acceptsMouse` (the [+] extras). nil = not for the recorder; the event goes on as normal.
    static func outcome(for event: NSEvent, acceptsMouse: Bool, backspaceClears: Bool) -> Outcome? {
        switch event.type {
        case .keyDown:
            guard let chord = KeyEventTranslator.chord(for: event) else { return nil }
            if chord == KeyChord(.escape) { return .cancel }
            if backspaceClears, chord == KeyChord(.backspace) { return .clear }
            return .trigger(.key(chord))
        case .otherMouseDown:
            guard acceptsMouse, let button = MouseButton(number: event.buttonNumber) else { return nil }
            return .trigger(.mouse(button))
        default:
            return nil
        }
    }

    func start(acceptsMouse: Bool, backspaceClears: Bool, _ done: @escaping @MainActor (Outcome) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            guard let outcome = Self.outcome(for: event, acceptsMouse: acceptsMouse, backspaceClears: backspaceClears) else {
                return event
            }
            self?.stop()
            done(outcome)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
```

If Swift 6 rejects the `deinit` (main-actor state in a nonisolated deinit), delete the `deinit`; `ShortcutsSettingsView` calls `stop()` in `onDisappear`.

- [ ] **Step 6: Add catalog strings**

Run:

```bash
scripts/l10n-add.sh "Space" "Mouse %d" "Selection" "Navigation" "Sort" "Reserved by macOS or MacExplorer." "Menu shortcuts need ⌘, ⌃ or ⌥." "Mouse buttons can only be added as extras." "%@ is used by %@."
```

(`l10n-add.sh` overwrites keys that exist with the same English value, so listing an existing key such as "Sidebar" is harmless; "Open", "Edit", "File", "Window", "View" and "Sidebar" are already in the catalog.)

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter "ShortcutsModelTests|LocalizationCoverageTests" 2>&1 | tail -15`
Expected: all pass. If `LocalizationCoverageTests` lists missing keys, add them with `scripts/l10n-add.sh`.

- [ ] **Step 8: Commit**

```bash
git add Sources/UI/Support/KeyChord+Display.swift Sources/UI/Settings/ShortcutsModel.swift Sources/UI/Settings/ShortcutRecorder.swift Sources/UI/Resources/Localizable.xcstrings Tests/UITests/ShortcutsModelTests.swift
git commit -m "feat(settings): shortcuts model, glyph display and shortcut recorder"
```

---

### Task 8: Settings › Shortcuts tab

**Files:**
- Create: `Sources/UI/Settings/ShortcutsSettingsView.swift`
- Modify: `Sources/UI/Settings/SettingsChoices.swift` (`SettingsSection.shortcuts`)
- Modify: `Sources/UI/Settings/SettingsView.swift` (page switch, header comment)
- Modify: `Sources/UI/Support/AXID.swift` (`shortcutsList`, `shortcutsRestoreDefaults`)
- Modify: `Sources/UI/Resources/Localizable.xcstrings`
- Modify test: `Tests/UITests/SettingsWindowTests.swift` (`testSectionsAreTheFourOfSpecSeven`)

**Interfaces:**
- Consumes: `ShortcutsModel`, `ShortcutRecorder`, `ShortcutApply`, display strings (Task 7).
- Produces: `SettingsSection.shortcuts`; `ShortcutsSettingsView(settings:)`.

- [ ] **Step 1: Update the failing test**

In `Tests/UITests/SettingsWindowTests.swift` replace `testSectionsAreTheFourOfSpecSeven` with:

```swift
    func testSectionsInTabOrder() {
        XCTAssertEqual(SettingsSection.allCases.map(\.title), ["General", "View", "Sidebar", "Shortcuts", "Advanced"])
        XCTAssertEqual(SettingsSection.shortcuts.symbolName, "keyboard")
    }

    func testShortcutsPageRenders() {
        let s = settings()
        let host = NSHostingView(rootView: ShortcutsSettingsView(settings: s))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 520)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: `type 'SettingsSection' has no member 'shortcuts'`.

- [ ] **Step 3: Implement the section**

`Sources/UI/Settings/SettingsChoices.swift`:
- `/// The §7 sections, in tab order.` and `case general, view, sidebar, shortcuts, advanced`
- In `title`: `case .shortcuts: L10n.string("Shortcuts")`
- In `symbolName`: `case .shortcuts: "keyboard"`

`Sources/UI/Settings/SettingsView.swift`:
- Header comment: "General, View, Sidebar, Shortcuts, Advanced tabs."
- In `page(_:)`: `case .shortcuts: ShortcutsSettingsView(settings: settings)`

`Sources/UI/Support/AXID.swift`, after `settingsWindow`:

```swift
    static let shortcutsList = "macx.settings.shortcuts.list"            // additive: Settings › Shortcuts
    static let shortcutsRestoreDefaults = "macx.settings.shortcuts.restore"
```

- [ ] **Step 4: Implement the view**

```swift
// Sources/UI/Settings/ShortcutsSettingsView.swift
import SwiftUI
import AppKit
import Core

/// Settings › Shortcuts (key-bindings spec §5): every command with its menu shortcut, extra keys and mouse buttons.
/// Click a shortcut to record a new one (Esc cancels, ⌫ clears); [+] records an extra key or mouse button.
struct ShortcutsSettingsView: View {
    @Bindable var settings: Core.Settings
    @State private var query = ""
    @State private var recording: Recording?
    @State private var notice: Notice?
    @State private var confirmReset = false
    @State private var recorder = ShortcutRecorder()

    struct Recording: Equatable {
        let command: Command
        let slot: KeyBindings.Slot      // .primary = the Shortcut cell; .alternate = [+] (key → alternate, mouse → mouse)
    }

    struct Notice: Equatable {
        let command: Command
        let text: String
        /// Set for a conflict: what Reassign would save.
        let pending: (trigger: Trigger, slot: KeyBindings.Slot)?
        static func == (a: Notice, b: Notice) -> Bool { a.command == b.command && a.text == b.text }
    }

    private var model: ShortcutsModel { ShortcutsModel(settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.string("Search commands…"), text: $query)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(model.groups(matching: query)) { group in
                    Section(group.title) {
                        ForEach(group.commands, id: \.self) { command in row(command) }
                    }
                }
            }
            .frame(height: 420)
            .accessibilityIdentifier(AXID.shortcutsList)
            HStack {
                Text(L10n.string("Shortcuts set in System Settings › Keyboard › App Shortcuts take precedence over menu shortcuts."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.string("Restore All Defaults")) { confirmReset = true }
                    .accessibilityIdentifier(AXID.shortcutsRestoreDefaults)
            }
        }
        .padding()
        .onDisappear { recorder.stop(); recording = nil }
        .confirmationDialog(L10n.string("Restore all shortcuts to their defaults?"), isPresented: $confirmReset) {
            Button(L10n.string("Restore All Defaults"), role: .destructive) { model.resetAll(); notice = nil }
            Button(L10n.string("Cancel"), role: .cancel) {}
        }
    }

    // MARK: rows

    @ViewBuilder private func row(_ command: Command) -> some View {
        let b = model.bindings
        let fixed = model.isFixed(command)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model.title(command))
                    .fontWeight(model.isModified(command) ? .bold : .regular)
                    .frame(width: 170, alignment: .leading)
                    .lineLimit(1)
                primaryCell(command, chord: b.primary(command), fixed: fixed)
                    .frame(width: 90, alignment: .leading)
                chips(command, keys: b.alternates(command), mouse: b.mouse(command), fixed: fixed)
                Spacer(minLength: 0)
                if !fixed {
                    Button { begin(command, .alternate) } label: {
                        Image(systemName: isRecording(command, .alternate) ? "record.circle" : "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Add a key or mouse button"))
                }
                if model.isModified(command) {
                    Button { model.reset(command); notice = nil } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help(L10n.string("Restore default"))
                }
            }
            if let notice, notice.command == command { noticeView(notice) }
        }
        .opacity(fixed ? 0.6 : 1)
        .help(fixed ? L10n.string("Fixed") : "")
    }

    @ViewBuilder private func primaryCell(_ command: Command, chord: KeyChord?, fixed: Bool) -> some View {
        if isRecording(command, .primary) {
            Text(L10n.string("Type shortcut…")).foregroundStyle(.tint)
        } else if fixed {
            Text(chord?.displayString ?? "—").foregroundStyle(.secondary)
        } else {
            Button(chord?.displayString ?? "—") { begin(command, .primary) }
                .buttonStyle(.borderless)
        }
    }

    private func chips(_ command: Command, keys: [KeyChord], mouse: [MouseButton], fixed: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(keys.map(Trigger.key) + mouse.map(Trigger.mouse), id: \.self) { trigger in
                ShortcutChip(text: trigger.displayString, removable: !fixed) { model.remove(trigger, from: command) }
            }
            if isRecording(command, .alternate) {
                Text(L10n.string("Type shortcut…")).foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder private func noticeView(_ notice: Notice) -> some View {
        HStack(spacing: 8) {
            Text(notice.text).font(.caption).foregroundStyle(notice.pending == nil ? .red : .orange)
            if let pending = notice.pending {
                Button(L10n.string("Reassign")) {
                    _ = model.apply(pending.trigger, to: notice.command, as: pending.slot, reassigning: true)
                    self.notice = nil
                }
                Button(L10n.string("Cancel")) { self.notice = nil }
            }
        }
    }

    // MARK: recording

    private func isRecording(_ command: Command, _ slot: KeyBindings.Slot) -> Bool {
        recording == Recording(command: command, slot: slot)
    }

    private func begin(_ command: Command, _ slot: KeyBindings.Slot) {
        notice = nil
        recording = Recording(command: command, slot: slot)
        recorder.start(acceptsMouse: slot == .alternate, backspaceClears: slot == .primary) { outcome in
            recording = nil
            switch outcome {
            case .cancel: break
            case .clear: model.clearPrimary(command)
            case .trigger(let trigger):
                let target: KeyBindings.Slot
                if case .mouse = trigger { target = .mouse } else { target = slot }
                switch model.apply(trigger, to: command, as: target, reassigning: false) {
                case .saved: break
                case .rejected(let rejection):
                    notice = Notice(command: command, text: ShortcutsModel.message(rejection), pending: nil)
                case .conflict(let uses):
                    notice = Notice(command: command, text: model.conflictMessage(trigger, uses), pending: (trigger, target))
                }
            }
        }
    }
}

/// An extra key or mouse button; hovering shows × to remove it.
private struct ShortcutChip: View {
    let text: String
    let removable: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Text(text).font(.callout.monospaced())
            if removable, hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Remove"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
        .onHover { hovering = $0 }
    }
}
```

The 420 pt list replaces the window's "fit content" height for this tab only; `SettingsView` keeps `.fixedSize(horizontal: false, vertical: true)`, so the window grows for this tab and shrinks back for the others.

- [ ] **Step 5: Add catalog strings**

```bash
scripts/l10n-add.sh "Shortcuts" "Search commands…" "Shortcuts set in System Settings › Keyboard › App Shortcuts take precedence over menu shortcuts." "Restore All Defaults" "Restore all shortcuts to their defaults?" "Add a key or mouse button" "Restore default" "Fixed" "Type shortcut…" "Reassign" "Remove"
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter "SettingsChoicesTests|SettingsWindowTests|LocalizationCoverageTests|AXIDTests" 2>&1 | tail -15`
Expected: pass. If `AXIDTests` checks that every AXID is used or unique, the two new IDs satisfy it (both are used in the view).

- [ ] **Step 7: Manual check in the real app**

Run: `swift build && scripts/bundle.sh debug` (or the project's `run` skill), open Settings › Shortcuts and check:
1. Back shows ⌘[ / ⌫ ⌥← Mouse 4.
2. Click Back's ⌘[, press ⌥⌘B: the Go menu shows ⌥⌘B; ⌥⌘B goes back in a window.
3. On Back's row, [+] then click mouse button 5: "Mouse 5 is used by Forward." appears; Reassign moves it.
4. Restore All Defaults → confirm → everything back.
Report what you saw. If no GUI session is available, say so instead of claiming it works.

- [ ] **Step 8: Commit**

```bash
git add Sources/UI/Settings Sources/UI/Support/AXID.swift Sources/UI/Resources/Localizable.xcstrings Tests/UITests/SettingsWindowTests.swift
git commit -m "feat(settings): Shortcuts tab for rebinding keys and mouse buttons"
```

---

### Task 9: Main spec cross-references and final verification

**Files:**
- Modify: `docs/superpowers/specs/2026-11-01-macexplorer-design.md` (§5.3 line ~247, §5.6, §7 list of sections)

- [ ] **Step 1: Update the main spec**

- Line ~247: replace "Each menu item's single primary key equivalent (§5.6) can be rebound in System Settings › Keyboard › App Shortcuts." with "Each menu item's single primary key equivalent (§5.6) can be rebound in Settings › Shortcuts (see `2026-11-05-key-bindings-design.md`); System Settings › Keyboard › App Shortcuts still overrides it."
- At the start of §5.6: add one line "The key table below is the default. Users can change it and bind extra mouse buttons (default Mouse 4 = Back, Mouse 5 = Forward) in Settings › Shortcuts; see `2026-11-05-key-bindings-design.md`."
- In §7: add "Shortcuts" between Sidebar and Advanced with a one-line pointer to the key-bindings spec.

- [ ] **Step 2: Full verification**

Run:

```bash
swift build > /tmp/macx-kb-build.log 2>&1; tail -3 /tmp/macx-kb-build.log
swift test > /tmp/macx-kb-test.log 2>&1; tail -5 /tmp/macx-kb-test.log; grep -E "failed|error:" /tmp/macx-kb-test.log | head
scripts/check-layering.sh
scripts/ui-scenarios.sh --filter mouse 2>&1 | tail -5
```

Expected: build OK, `Executed N tests, with 0 failures`, layering OK, scenario passes (or skipped without a GUI, which you must say).

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-11-01-macexplorer-design.md
git commit -m "docs: point the main spec at Settings › Shortcuts"
```
