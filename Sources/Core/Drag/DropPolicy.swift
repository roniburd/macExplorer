import Foundation
import MacxFS

public enum DragOperation: Sendable, Equatable { case copy, move, alias, menu, none }
// No symlink case: a real right-drag picks "Make Symbolic Link Here" through UI's DropChoice, so the scenario-only
// probePerformDrop(…menuChoice:) cannot choose it (S5 Contract note 2, S6 Contract note C5).

public struct DragModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let option  = DragModifiers(rawValue: 1 << 0)
    public static let command = DragModifiers(rawValue: 1 << 1)
    public static let control = DragModifiers(rawValue: 1 << 2)
}

/// Drop validation and operation choice (§5.6). Pure and in-memory: draggingUpdated makes no file-system calls.
public enum DropPolicy {
    public static let secondaryDragType: String = "com.macexplorer.secondary-drag"

    /// Pure, in-memory, no file-system calls. none if any source is the destination or an ancestor of it.
    /// Default: move same volume / copy cross volume; ⌥ copy; ⌘ move; ⌥⌘ alias; ⌃ or secondary drag → menu.
    public static func operation(sources: [String], destination: String, modifiers: DragModifiers,
                                 isSecondaryDrag: Bool, mountTable: MountTable) -> DragOperation {
        guard !sources.isEmpty else { return .none }
        if sources.contains(where: { isSelfOrDescendant(source: $0, destination: destination) }) { return .none }
        if isSecondaryDrag || modifiers.contains(.control) { return .menu }
        if modifiers.contains([.option, .command]) { return .alias }
        if modifiers.contains(.option) { return .copy }
        if modifiers.contains(.command) { return .move }
        return sources.allSatisfy { mountTable.isSameVolume($0, destination) } ? .move : .copy
    }

    /// Lexical path-prefix check on standardized paths, component-wise and byte-wise.
    public static func isSelfOrDescendant(source: String, destination: String) -> Bool {
        LexicalPath.isSelfOrDescendant(LexicalPath.standardize(destination), of: LexicalPath.standardize(source))
    }
}
