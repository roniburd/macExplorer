# MacExplorer: customizable key bindings and mouse buttons (design)

Date: 2026-11-05. Status: approved in brainstorming; awaiting written-spec review.
Relates to: `2026-11-01-macexplorer-design.md` §5.6 (Interaction, key table and routing) and §7 (Settings). This spec extends §5.6 (bindings become user-editable, mouse buttons become triggers) and adds a fifth §7 section.

## 1. Intent

**Outcome.** The user's mouse Back/Forward side buttons (the same ones Chrome uses) move through the window's folder history. Double-click into a folder, click Back on the mouse, and the window returns to the previous folder. A new **Shortcuts** settings tab lists every command with its keys and mouse buttons and lets the user rebind any of them.

**Decisions made (owner).**
- One combined design: mouse buttons are bindable triggers inside the key-binding system, not a separate feature.
- Full rebinding: record a new primary shortcut, add and remove alternates and mouse buttons, conflict warnings, per-row and global reset.
- Bindable inputs: keyboard chords plus extra mouse buttons 3–8. Trackpad swipes are out of scope.
- Storage approach **A**: built-in defaults (`KeyMap`) plus a sparse overrides layer saved in `Settings`. Only differences from the defaults are stored.

**Success criteria.**
1. With default settings, mouse button 4 (AppKit `buttonNumber` 3) performs Back and button 5 (`buttonNumber` 4) performs Forward anywhere in a browser window, including while a text field is focused.
2. Rebinding any command's primary in Settings › Shortcuts updates the menu item's key equivalent immediately, with no relaunch.
3. Rebinding or adding an alternate or mouse button takes effect immediately in the content views, the sidebar and (for mouse buttons) anywhere in the browser window.
4. Defaults added or changed in a later release reach users who have customized other commands.
5. Unreadable stored bindings never break key handling. The app falls back to defaults.

**Non-goals.** Trackpad or Magic Mouse swipe gestures; the middle button (`buttonNumber` 2); multi-key chord sequences; per-window or per-focus custom bindings; import/export of binding sets.

## 2. Terminology

- **Primary**: a command's single menu key equivalent (§5.6). At most one per command.
- **Alternate**: an extra key handled only by the content views and the sidebar via `KeyDispatcher` (§5.6 step 4). Never fires in text fields.
- **Mouse binding**: an extra mouse button (`buttonNumber` 3–8) mapped to a command. Handled window-wide in browser windows.
- **Trigger**: a key chord or a mouse button.
- **Override**: a user change for one command, stored in `Settings`.

## 3. Core model (`Sources/Core/Commands/`)

### 3.1 New types

```swift
public struct MouseButton: Hashable, Sendable, Codable, Comparable {
    public let number: Int            // AppKit buttonNumber, 3...8
    public init?(number: Int)         // nil outside 3...8
    public var displayName: String    // "Mouse 4" for number 3 (1-based, matching how mice are labelled)
}

public enum Trigger: Hashable, Sendable, Codable {
    case key(KeyChord)
    case mouse(MouseButton)
}

/// Sparse user changes. A command absent from `commands` uses its defaults entirely.
public struct KeyBindingOverrides: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// nil = keep default primary; .some(nil) = explicitly no primary; .some(chord) = replacement.
        public var primary: KeyChord??
        /// nil = keep default alternates; non-nil = full replacement list.
        public var alternates: [KeyChord]?
        /// nil = keep default mouse buttons; non-nil = full replacement list.
        public var mouse: [MouseButton]?
    }
    public var commands: [Command: Entry]
    public static let none = KeyBindingOverrides(commands: [:])
}
```

`KeyChord` gains `Codable` conformance using its canonical `description` / `init?(parsing:)` text form. `Command` is already `Codable`. `KeyBindingOverrides` encodes `commands` keyed by `Command.rawValue`. When decoding, an entry whose key is not a known `Command`, or whose chord string does not parse, is dropped and does not fail the whole value.

### 3.2 Defaults

`KeyMap` stays the source of built-in defaults and gains one function:

```swift
public static func defaultMouse(_ command: Command) -> [MouseButton]
// .back → [MouseButton(number: 3)], .forward → [MouseButton(number: 4)], everything else → []
```

### 3.3 `KeyBindings`

An immutable resolved table, built from `KeyMap` defaults plus `KeyBindingOverrides`:

```swift
public struct KeyBindings: Sendable, Equatable {
    public static let defaults: KeyBindings          // KeyBindings(overrides: .none)
    public init(overrides: KeyBindingOverrides)

    public func primary(_ command: Command) -> KeyChord?
    public func alternates(_ command: Command) -> [KeyChord]
    public func mouse(_ command: Command) -> [MouseButton]

    /// Primary-or-alternate lookup for the content/sidebar (what KeyDispatcher's static table did).
    public func alternateCommand(for chord: KeyChord) -> Command?
    public func command(for button: MouseButton) -> Command?

    /// Every (command, slot) currently using `trigger`. Used by the Settings conflict warning.
    public func users(of trigger: Trigger) -> [(Command, Slot)]
    public enum Slot: Sendable, Hashable { case primary, alternate, mouse }

    /// Commands whose *current* primary is in `KeyMap.textEditingChords`.
    public var collidesWithTextEditing: Set<Command>
}
```

`KeyMap.collidesWithTextEditing: Set<Command>` is replaced by `KeyMap.textEditingChords: Set<KeyChord>`, the chords text fields own: ⌘↑, ⌘↓, ⌘⌫, ⌥⌘⌫, ⌘[, ⌘], F2, ⌘D. These are today's colliding primaries, written as chords. Collision is a property of the chord, so a command rebound onto ⌘D collides, and Duplicate moved off ⌘D stops colliding.

### 3.4 Validation rules (`KeyBindings.validate`)

```swift
public enum BindingRejection: Sendable, Equatable {
    case reserved            // ⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘, (Settings), ⌃⌘S (Show Sidebar), ⌃⌘F (Full Screen), ⌘? (⇧⌘/, Help), ⌘` (cycle windows); Tab, ⇧Tab; Esc
    case editsTextAsPrimary  // a primary with no ⌘/⌃ that isn't a function key: a character or space with any ⌥/⇧, or ↩, ⌤, ⌫, Del, arrows with no ⌥ (⇧ or not)
    case unsupported         // a chord MainMenuBuilder.keyEquivalent can't express, used as a primary
}
public static func validate(_ trigger: Trigger, as slot: Slot) -> BindingRejection?
```

Tab and ⇧Tab stay bound to `cycleFocusForward` / `cycleFocusBackward`, and Esc to `cancelOperation`. Those rows are shown in Settings but can't be edited. A primary with no ⌘, ⌃ or ⌥ must be a function key (F1…F20, ⇧ allowed). A primary becomes a menu key equivalent, and AppKit matches those before the field editor gets the key, so a bare Return, Enter, ⌫, Del or arrow (with or without ⇧) would fire while editing a name or path; none of them are in `textEditingChords`, so collision handling wouldn't catch them. ⌥ (with or without ⇧) and a character or space is refused too, because it types a character (⌥L is @ on a German layout). The reserved chords include every key equivalent of a non-command menu item; `KeyBindings.fixedMenuChords` is the single list `MainMenuBuilder` reads them from. A stored primary that fails this falls back to the default. Any of these keys, and a bare character, is allowed as an alternate, because alternates never fire in text fields.

### 3.5 Settings

```swift
public var keyBindingOverrides: KeyBindingOverrides { didSet { save(...) } }   // storage key "keyBindings"
public var keyBindings: KeyBindings { get }                                      // derived, cached per overrides value
```

This follows the existing `Settings` rules: the default (`.none`) is never written, and a value that fails to decode falls back to the default without overwriting the stored data. Per-entry tolerance (§3.1) means one bad entry loses only itself.

Mutations used by the UI (all on `Settings`, main actor):

```swift
func setPrimary(_ chord: KeyChord?, for: Command)
func addAlternate(_ chord: KeyChord, to: Command)
func removeAlternate(_ chord: KeyChord, from: Command)
func addMouse(_ button: MouseButton, to: Command)
func removeMouse(_ button: MouseButton, from: Command)
func reassign(_ trigger: Trigger, to: Command, as: Slot)   // removes trigger from every other user first
func resetBindings(for: Command)
func resetAllBindings()
```

Each mutation writes a full replacement for only the slot it touches. If the resulting entry equals the defaults, it is removed, so overrides stay sparse and "modified" means "differs from defaults".

## 4. Routing

### 4.1 Primaries (menus)

- `MainMenuBuilder.build()` takes `KeyBindings` (default `.defaults`) instead of reading `KeyMap.primary`.
- New `MainMenuBuilder.applyKeyEquivalents(_ bindings: KeyBindings, to menu: NSMenu)` walks items with identifier `macx.menu.<rawValue>` and sets or clears `keyEquivalent` / `keyEquivalentModifierMask`. It never rebuilds the menu.
- `AppDelegate` observes `settings.keyBindingOverrides` (Observation `withObservationTracking`, re-armed on each change) and calls `applyKeyEquivalents` on `NSApp.mainMenu`.
- `FieldEditorKeyRouting` builds its table from `bindings.collidesWithTextEditing` and `bindings.primary`, and is rebuilt when the bindings change. `MenuValidation` and `CommandAvailability` read `bindings.collidesWithTextEditing` instead of `KeyMap.collidesWithTextEditing`. `CommandAvailability.isEnabled` gains a `collidesWithTextEditing: Set<Command>` parameter that defaults to `KeyBindings.defaults.collidesWithTextEditing`.

### 4.2 Alternates

`KeyDispatcher.init(returnKey:bindings:)`. Its static table is replaced by `bindings.alternateCommand(for:)`. `KeyRouter.handle` / `command(for:)` take the bindings, and their callers (`DetailsViewController`, `IconsViewController`, `SidebarViewController`) pass `settings.keyBindings`. The Return → Rename substitution is unchanged and applies only when the chord is Return and the command is `.open`.

### 4.3 Mouse buttons

In `MacxApplication.sendEvent`, before `super.sendEvent`:

```swift
if event.type == .otherMouseDown, MouseRouter.handle(event) { return }
```

`MouseRouter` (new, `Sources/UI/Menus/MouseRouter.swift`, `@MainActor enum`):
1. `MouseButton(number: event.buttonNumber)`. Return false if nil.
2. `event.window` must be a browser window (`BrowserWindowController`'s window). Settings, sheets and panels return false.
3. `settings.keyBindings.command(for: button)`. Return false if unbound, so AppKit handles it normally.
4. Find the view under the pointer: `window.contentView?.hitTest(event.locationInWindow)`, falling back to the window's first responder.
5. Check availability with the same `CommandAvailability` and `CommandStateBuilder` state menus use. If the command is unavailable (e.g. Back with empty history), consume the event and do nothing.
6. Send the command with the responder walk `KeyRouter` uses (`KeyRouter.send(command, from: view)`, factored out of `KeyRouter.handle`), so it reaches that window's session even if the window is not key.
7. Return true. The matching `.otherMouseUp` is not intercepted, which is harmless.

Mouse bindings fire even while a text field is focused, matching Chrome. They do not go through `FieldEditorKeyRouting`.

## 5. Settings › Shortcuts tab (`Sources/UI/Settings/ShortcutsSettingsView.swift`)

`SettingsSection` gains `.shortcuts` (title "Shortcuts", symbol `keyboard`), ordered General, View, Sidebar, Shortcuts, Advanced.

```
┌ Search commands…                         ┐
 Command               Shortcut     Also
 ▸ Navigation
   Back                ⌘[           ⌫  ⌥←  Mouse 4   [+]
   Forward             ⌘]           ⌥→  Mouse 5      [+]
   Enclosing Folder    ⌘↑           ⌥↑               [+]
 ▸ File
   Rename              F2           ⇧⌘R              [+]
   …
                    [Restore All Defaults]
 Shortcuts set in System Settings › Keyboard › App Shortcuts take precedence over menu shortcuts.
```

- **Layout.** A `List` of about 420 pt, fixed height, inside the 500 pt-wide window. Sections follow the main-menu groups. Command titles come from `MainMenuTitles.title(command)`, with an explicit title for `cancelOperation` ("Cancel / Clear Cut"), which has no menu item. Chords display in Mac glyph form (`⌥⌘⌫`), using a new `KeyChord.displayString` in UI.
- **Search.** Case-insensitive match on the title, the glyph string, the canonical text form (`cmd+[`) or "mouse N".
- **Recording.** Clicking the Shortcut cell, or a row's `[+]`, enters recording for that slot. The cell shows "Type shortcut…". A `ShortcutRecorder` (`NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown])`) captures the next event and swallows it, so menus and `MouseRouter` don't act on it. Mouse events are accepted only in `[+]` recording. Esc cancels. ⌫ with no modifiers in the Shortcut cell clears the primary (sets "none"). In `[+]` recording, ⌫ records ⌫ as an alternate. Clicking elsewhere or closing the window cancels.
- **Validation.** `KeyBindings.validate` runs first. A rejection shows inline text under the row ("Reserved by macOS", "Reserved by MacExplorer", "Needs ⌘, ⌃ or ⌥ to be a menu shortcut") and nothing is saved.
- **Conflicts.** If `users(of:)` is non-empty (excluding the same command and slot), an inline banner says "⌘D is used by Duplicate." with **Reassign** and **Cancel**. Reassign calls `settings.reassign`.
- **Chips.** Alternates and mouse buttons show as chips. Hovering one reveals an ×, which removes it.
- **Modified state.** A row with an override shows its title in bold and an ↺ button, which calls `resetBindings(for:)`.
- **Restore All Defaults.** Shows a confirmation alert, then calls `resetAllBindings()`.
- **Non-editable rows.** Tab, ⇧Tab and Esc rows render dimmed with a "Fixed" tooltip.
- Strings go through `L10n.string`.

## 6. Error handling and edge cases

- Stored data that fails to decode: defaults are used, the bad data is left in place, and a diagnostic is logged once.
- A stored entry for a removed command is dropped on decode.
- A stored primary that now fails `validate` (e.g. a later release reserves it) is ignored at resolve time and the default is used. It is not deleted.
- Two commands both list the same alternate or mouse button in stored data (only possible if the data was edited by hand): the first in `Command.allCases` order wins for dispatch, and Settings shows the conflict on both rows.
- The Return-key setting: unchanged. If the user removes Return from `open`'s alternates, Return does nothing in the content view regardless of the setting.
- System Settings App Shortcuts can still override menu key equivalents. The app can't prevent this, so a footnote on the tab says so.
- A mouse that sends buttons through a vendor driver as key events (e.g. ⌘[) already works through the primary.

## 7. Testing

All tests use in-memory `SettingsStorage`. No test touches files it didn't create.

**Core (`Tests/CoreTests`)**
- `KeyBindings` resolution: defaults equal today's `KeyMap`; each override slot (primary replace or clear, alternates, mouse) applies on its own.
- Sparse overrides: a mutation that returns to defaults removes the entry. Reset per command and reset all.
- `reassign` removes the trigger from every other user.
- `validate`: reserved chords, bare-character primary rejected and the same chord accepted as an alternate, unsupported chord.
- `collidesWithTextEditing` follows chords: rebinding Duplicate off ⌘D and Rename onto ⌘D.
- Codable: round-trip; unknown command key and unparseable chord dropped without failing the rest; whole-value garbage falls back to defaults.
- `KeyChord` Codable round-trip for every key kind.
- `KeyDispatcher` with custom bindings, plus the Return → Rename rule.
- `MouseButton(number:)` bounds and `displayName`.

**UI (`Tests/UITests`)**
- `applyKeyEquivalents` sets, changes and clears menu item key equivalents.
- `MouseRouter`: a synthesized `.otherMouseDown` with `buttonNumber` 3 in a browser window calls `goBack()`, 4 calls `goForward()`, an unbound button returns false, a non-browser window returns false, and an unavailable command is consumed without action.
- `FieldEditorKeyRouting` reflects rebinding.

**Scenarios (`Tests/Scenarios/*.json`, run by `macx-scenarios`)**
- `mouse-back-forward.json` (needs a new `mouse` step kind that synthesizes `.otherMouseDown`): open fixture folder A, double-click subfolder B, send mouse button 3, assert the location is A; send mouse button 4, assert B. Fixture tree is created by the scenario in its sandbox.
- `rebind-back.json`: set Back's primary to ⌥⌘B through the Settings API, press it, and assert the location went back.

## 8. Files

New: `Core/Commands/MouseButton.swift`, `Trigger.swift`, `KeyBindingOverrides.swift`, `KeyBindings.swift`; `UI/Menus/MouseRouter.swift`; `UI/Settings/ShortcutsSettingsView.swift`, `ShortcutRecorder.swift`; `UI/Support/KeyChord+Display.swift`; tests and scenarios listed above.

Changed: `KeyMap.swift` (`defaultMouse`, `textEditingChords`), `KeyChord.swift` (Codable), `KeyDispatcher.swift`, `CommandAvailability.swift`, `Settings.swift`, `KeyRouter.swift`, `FieldEditorKeyRouting.swift`, `MenuValidation.swift`, `MainMenuBuilder.swift`, `MacxApplication.swift`, `AppDelegate.swift`, `SettingsChoices.swift`, `SettingsView.swift`, the three content/sidebar controllers, and main spec §5.6/§7 cross-references.

## 9. Plan-time adjustments

Made while writing the implementation plan (`docs/superpowers/plans/2026-11-05-key-bindings.md`), after reading the code. They change no behavior the owner approved.

- **Primary override type.** `Entry.primary` is `PrimaryOverride?` (`.unbound` / `.chord(KeyChord)`) instead of `KeyChord??`. Same meaning, easier to read.
- **Edits live on `KeyBindingOverrides`.** `setPrimary`, `removeAlternate`, `removeMouse`, `reassign` and `reset` are mutating methods on the overrides value. The UI mutates `settings.keyBindingOverrides` directly, which persists through its `didSet`. `Settings` gets no extra methods. "Add alternate" and "add mouse button" are `reassign` calls.
- **One active table in the UI.** Instead of passing `settings.keyBindings` into every controller, `KeyBindingsController` (owned by `UIContext`) keeps `ActiveKeyBindings.current` and the menu bar's key equivalents in step with Settings. `KeyRouter`, `FieldEditorKeyRouting`, `MenuValidation`, `MouseRouter` and the other `CommandAvailability` callers read it. The three content/sidebar controllers don't change.
- **Mouse commands go to the content pane.** `MouseRouter` sends the command from the window's content pane (same responder walk as alternate keys), not from the view under the pointer. A mouse binding acts as if the file list had focus, wherever the pointer is. Availability is checked by the existing command handler (`canPerform`), so an unavailable command is consumed silently.
- **Rejections.** `BindingRejection` is `.reserved`, `.editsTextAsPrimary` and `.wrongSlot` (mouse in a key slot or the reverse). `.editsTextAsPrimary` (renamed from `.typesTextAsPrimary`) rejects every primary with no ⌘/⌃/⌥ except function keys, not just characters and space: bare ↩, ⌤, ⌫, Del and arrows (and their ⇧ forms) would otherwise act as menu key equivalents ahead of the field editor (review of Task 2). This changes behavior: such chords are now refused as primaries and only allowed as alternates. `.unsupported` is dropped: `KeyChord(parsing:)` already refuses chords the menu can't show. The reserved message is a single "Reserved by macOS or MacExplorer."
- **`Trigger` is not `Codable`.** Only `KeyChord` and `MouseButton` are stored. `MouseButton.displayName` lives in UI (localized), and Core has the canonical text form `"mouse4"`.
- **`rebind-back` scenario → UI tests.** Rebinding is covered by `KeyBindingsRoutingTests` and `MouseRouterTests.testReboundButtonFollowsActiveBindings`. Only `mouse-back-forward.json` is a scenario.
- **Fixed rows.** `cancelOperation` is titled "Cancel" (its existing `MainMenuTitles` entry).
- **Branch review.** ⌃⌘S, ⌃⌘F and ⌘? (⇧⌘/) are reserved, from the shared `KeyBindings.fixedMenuChords`. ⌥/⇧ + a character or space is refused as a primary ("Menu shortcuts need ⌘ or ⌃, or an F key. ⌥ alone works only with keys that don't type."). `reset(_:)` works like `reassign`: each restored default trigger is first removed from any other command holding it. Settings flags a trigger two commands share on both rows (orange chip or shortcut, ⚠ with a tooltip), via `ShortcutsModel.conflicts(for:)`. Resolved alternate and mouse lists drop repeats. An undecodable "keyBindings" value is reported once through `Settings.init`'s `diagnostic` hook (NSLog by default).
