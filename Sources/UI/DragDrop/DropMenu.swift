// Sources/UI/DragDrop/DropMenu.swift
import AppKit
import Core

enum DropChoice: String, CaseIterable, Sendable {
    case copy, move, alias, symlink, cancel

    @MainActor var title: String {
        switch self {
        case .copy: L10n.string("Copy Here")
        case .move: L10n.string("Move Here")
        case .alias: L10n.string("Create Alias Here")
        case .symlink: L10n.string("Create Symbolic Link Here")
        case .cancel: L10n.string("Cancel")
        }
    }

    func jobKind(sources: [URL], destination: URL) -> JobKind? {
        switch self {
        case .copy: .copy(sources: sources, destination: destination)
        case .move: .move(sources: sources, destination: destination)
        case .alias: .alias(sources: sources, destination: destination)
        case .symlink: .symlink(sources: sources, destination: destination)
        case .cancel: nil
        }
    }

    /// The scenario probe's menu choice (DragOperation has no symlink case; see Contract notes).
    init?(menuChoice: DragOperation?) {
        switch menuChoice {
        case .copy?: self = .copy
        case .move?: self = .move
        case .alias?: self = .alias
        default: return nil
        }
    }

    init?(operation: DragOperation) {
        switch operation {
        case .copy: self = .copy
        case .move: self = .move
        case .alias: self = .alias
        case .menu, .none: return nil
        }
    }
}

/// The menu drop (§5.6): shown at the drop point; Cancel does nothing.
@MainActor
enum DropMenu {
    static func makeMenu(choose: @escaping @MainActor (DropChoice) -> Void) -> NSMenu {
        let menu = NSMenu(title: L10n.string("Drop"))
        for choice in DropChoice.allCases {
            if choice == .cancel { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(title: choice.title) { choose(choice) })
        }
        return menu
    }

    static func run(at point: NSPoint, in view: NSView) -> DropChoice? {
        var chosen: DropChoice?
        let menu = makeMenu { chosen = $0 }
        menu.popUp(positioning: nil, at: point, in: view)   // synchronous; the item action fires before it returns
        return chosen == .cancel ? nil : chosen
    }
}
