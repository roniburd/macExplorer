// Sources/UI/Content/SelectionController.swift
import AppKit
import Core

struct ClickModifiers: OptionSet, Sendable {
    let rawValue: UInt8
    static let command = ClickModifiers(rawValue: 1 << 0)
    static let shift = ClickModifiers(rawValue: 1 << 1)
    init(rawValue: UInt8) { self.rawValue = rawValue }
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: ClickModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}

enum ClickResolution: Equatable {
    case select(SelectionCommand)
    case selectOnMouseUp(SelectionCommand)   // mouse-down inside a multi-selection: keep it so it can be dragged
    case open(newWindow: Bool)
    case nothing
}

enum NavKey: Equatable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown
    init?(_ key: NSEvent.SpecialKey?) {
        switch key {
        case .upArrow?: self = .up
        case .downArrow?: self = .down
        case .leftArrow?: self = .left
        case .rightArrow?: self = .right
        case .home?: self = .home
        case .end?: self = .end
        case .pageUp?: self = .pageUp
        case .pageDown?: self = .pageDown
        default: return nil
        }
    }
}

/// Pure mapping from input to SelectionCommand (§5.5). Both lists use it; Icons passes a spatial navigator.
enum SelectionController {
    static func click(row: Int?, clickCount: Int, modifiers: ClickModifiers, selectedRows: IndexSet) -> ClickResolution {
        if clickCount >= 2 { return row == nil ? .nothing : .open(newWindow: modifiers.contains(.command)) }
        guard let row else { return modifiers.isEmpty ? .select(.none) : .nothing }
        if modifiers.contains(.shift) { return .select(.extend(to: row)) }
        if modifiers.contains(.command) { return .select(.toggle(row)) }
        let only = SelectionCommand.set(IndexSet(integer: row), cursor: row)
        return selectedRows.contains(row) && selectedRows.count > 1 ? .selectOnMouseUp(only) : .select(only)
    }

    static func arrow(_ key: NavKey, extend: Bool, cursorRow: Int?, rowCount: Int, pageSize: Int,
                      navigate: (Int, NavKey) -> Int?) -> SelectionCommand? {
        guard rowCount > 0 else { return nil }
        let target: Int?
        switch (key, cursorRow) {
        case (.home, _): target = 0
        case (.end, _): target = rowCount - 1
        case (_, nil): target = 0
        case (.pageUp, let cursor?): target = max(0, cursor - max(pageSize, 1))
        case (.pageDown, let cursor?): target = min(rowCount - 1, cursor + max(pageSize, 1))
        case (_, let cursor?): target = navigate(cursor, key)
        }
        guard let target else { return nil }
        return extend ? .extend(to: target) : .set(IndexSet(integer: target), cursor: target)
    }

    static func linearNavigator(rowCount: Int) -> (Int, NavKey) -> Int? {
        { row, key in
            switch key {
            case .up: row > 0 ? row - 1 : nil
            case .down: row + 1 < rowCount ? row + 1 : nil
            default: nil   // ←/→ do nothing in Details; ⌘←/⌘→ are unbound (§5.5)
            }
        }
    }

    @MainActor
    static func gridNavigator(_ layout: FileGridLayout) -> (Int, NavKey) -> Int? {
        { row, key in
            switch key {
            case .up: layout.neighbor(of: row, .up)
            case .down: layout.neighbor(of: row, .down)
            case .left: layout.neighbor(of: row, .left)
            case .right: layout.neighbor(of: row, .right)
            default: nil
            }
        }
    }

    static func targetRow(of command: SelectionCommand) -> Int? {
        switch command {
        case .set(_, let cursor): cursor
        case .extend(let row): row
        case .toggle(let row): row
        default: nil
        }
    }
}

/// Mouse handling shared by Details and Icons. Built-in selection tracking is bypassed (S5-C4).
@MainActor
final class ListMouseHandler {
    private var pendingMouseUp: SelectionCommand?
    private(set) var mouseDownWindowPoint: NSPoint?
    private(set) var mouseDownRow: Int?

    func mouseDown(row: Int?, event: NSEvent, folder: FolderModel, from view: NSView) {
        mouseDownWindowPoint = event.locationInWindow
        mouseDownRow = row
        pendingMouseUp = nil
        switch SelectionController.click(row: row, clickCount: event.clickCount, modifiers: ClickModifiers(event.modifierFlags),
                                         selectedRows: folder.selection.rows) {
        case .select(let command): folder.select(command)
        case .selectOnMouseUp(let command): pendingMouseUp = command
        case .open(let newWindow):
            NSApp.sendAction(Selector((newWindow ? Command.openInNewWindow : Command.open).selectorName), to: nil, from: view)
        case .nothing: break
        }
    }

    func mouseUp(folder: FolderModel) {
        if let pendingMouseUp { folder.select(pendingMouseUp) }
        pendingMouseUp = nil
        mouseDownWindowPoint = nil
        mouseDownRow = nil
    }

    /// A drag started from the mouse-down (P1-36): keep the multi-selection.
    func cancelPendingForDrag() { pendingMouseUp = nil }
}

/// Navigation keys and type-select for a list (KeyRouter runs first for alternates).
@MainActor
enum ListKeys {
    static func handle(_ event: NSEvent, folder: FolderModel, list: FileListView, pageSize: Int,
                       navigate: (Int, NavKey) -> Int?, typeSelect: TypeSelect) -> Bool {
        if let key = NavKey(event.specialKey) {
            typeSelect.reset()
            if event.modifierFlags.contains(.command) { return true }   // ⌘-arrows never change the selection (§5.5)
            let cursor = folder.selection.cursor.flatMap { folder.row(of: $0) }
            if let command = SelectionController.arrow(key, extend: event.modifierFlags.contains(.shift), cursorRow: cursor,
                                                       rowCount: folder.rowCount, pageSize: pageSize, navigate: navigate) {
                folder.select(command)
                if let row = SelectionController.targetRow(of: command) { list.scrollToRow(row) }
            }
            return true
        }
        if TypeSelect.accepts(event, bufferEmpty: typeSelect.buffer.isEmpty) {
            typeSelect.handle(event.characters ?? "", folder: folder, list: list)
            return true
        }
        return false
    }
}
