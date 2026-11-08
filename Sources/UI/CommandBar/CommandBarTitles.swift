import AppKit
import Core

/// Command-bar button labels, SF Symbols and pull-down item titles (§5.3).
@MainActor enum CommandBarTitles {
    /// Button label (also its accessibility label and tool tip).
    static func title(_ command: Command) -> String {
        switch command {
        case .moveToTrash: L10n.string("Delete")
        default: MainMenuTitles.title(command)
        }
    }

    /// Pull-down item title (New ▾ items read "Folder", View ▾ items read "Details", "Small Icons", "Hidden Items").
    static func menuTitle(_ command: Command) -> String {
        switch command {
        case .newFolder: L10n.string("Folder")
        case .newTextFile: L10n.string("Text File")
        case .newEmptyFile: L10n.string("Empty File")
        case .viewAsDetails: L10n.string("Details")
        case .viewAsColumns: L10n.string("Columns")
        case .iconSizeSmall: L10n.string("Small Icons")
        case .iconSizeMedium: L10n.string("Medium Icons")
        case .iconSizeLarge: L10n.string("Large Icons")
        case .toggleHidden: L10n.string("Hidden Items")
        case .toggleCommandBar: L10n.string("Command Bar")
        default: MainMenuTitles.title(command)
        }
    }

    /// Enabled icon colour: the accent colour, red for the destructive Delete / Delete Permanently.
    static func tint(_ command: Command) -> NSColor {
        switch command {
        case .moveToTrash, .deletePermanently: .systemRed
        default: .controlAccentColor
        }
    }

    static func symbol(_ command: Command) -> String {
        switch command {
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .rename: "pencil"
        case .share: "square.and.arrow.up"
        case .moveToTrash: "trash"
        case .deletePermanently: "xmark.bin"
        case .properties: "info.circle"
        default: "questionmark"
        }
    }
}
