import Foundation
import Core
import MacxFS

/// Settings › Shortcuts presets, keymap import/export and the import problem report (P4-02). The view gets the file
/// URLs from NSOpenPanel/NSSavePanel; tests pass Sandbox URLs. Files are read and written on a lane.
extension ShortcutsModel {
    enum PresetChoice: Hashable {
        case preset(KeymapPreset)
        /// The keys differ from every preset (the user edited them or imported a keymap).
        case custom
    }

    enum KeymapImportFailure: Error, Equatable {
        /// The file couldn't be read, or is larger than `maxKeymapFileSize`.
        case unreadable
        case invalid(KeymapImportError)
    }

    enum KeymapImportResult: Equatable {
        case imported(warnings: [KeymapWarning])
        case failed(KeymapImportFailure)
    }

    /// What Settings › Shortcuts shows after an import fails: a sentence, then one line per problem.
    struct Report: Equatable {
        let summary: String
        let details: [String]
    }

    /// A keymap file is a few kilobytes; anything much larger isn't one, so it isn't read.
    static let maxKeymapFileSize = 1 << 20

    static let presetChoices: [PresetChoice] = KeymapPreset.allCases.map(PresetChoice.preset) + [.custom]

    static func title(_ choice: PresetChoice) -> String {
        switch choice {
        case .preset(.explorer): L10n.string("Explorer (default)")
        case .preset(.finder): L10n.string("Finder")
        case .custom: L10n.string("Custom (edited)")
        }
    }

    var presetChoice: PresetChoice { settings.keymapPreset.map(PresetChoice.preset) ?? .custom }

    /// Replaces every shortcut with the preset's, and sets the Return key to match it (Finder: Rename).
    func applyPreset(_ preset: KeymapPreset) { settings.applyKeymapPreset(preset) }

    /// Writes the current keys (and Return key setting) to `url`, replacing a file that is there.
    func exportKeymap(to url: URL, lanes: LanePool) async throws {
        let data = settings.exportKeymap()
        try await lanes.perform(on: .unknown, .fileOp) { _ in try data.write(to: url, options: .atomic) }
    }

    /// Reads `url` and, if it is a usable keymap, replaces the keys with it. On failure nothing changes.
    func importKeymap(from url: URL, lanes: LanePool) async -> KeymapImportResult {
        let limit = Self.maxKeymapFileSize
        let read = try? await lanes.perform(on: .unknown, .fileOp) { _ -> Data? in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= limit else { return nil }
            return try Data(contentsOf: url)
        }
        guard let data = read ?? nil else { return .failed(.unreadable) }
        do {
            return .imported(warnings: try settings.importKeymap(data))
        } catch {
            return .failed(.invalid(error))
        }
    }

    // MARK: words

    static func report(_ failure: KeymapImportFailure) -> Report {
        switch failure {
        case .unreadable:
            return Report(summary: L10n.string("The file couldn’t be read."), details: [])
        case .invalid(.notAKeymap):
            return Report(summary: L10n.string("This file isn’t a MacExplorer keymap."), details: [])
        case .invalid(.unsupportedVersion):
            return Report(summary: L10n.string("This keymap was made by a newer version of MacExplorer."), details: [])
        case .invalid(.unknownBase(let name)):
            return Report(summary: String(format: L10n.string("This keymap is based on an unknown preset, “%@”."), name),
                          details: [])
        case .invalid(.invalidChord(let command, let text)):
            return Report(summary: String(format: L10n.string("“%@” for “%@” isn’t a shortcut MacExplorer can read."),
                                          text, command), details: [])
        case .invalid(.issues(let issues)):
            return Report(summary: L10n.string("This keymap can’t be used. Nothing was changed."),
                          details: issues.map(message))
        }
    }

    static func message(_ issue: KeymapIssue) -> String {
        switch issue {
        case .conflict(let trigger, let commands):
            String(format: L10n.string("%@ is used by %@."), trigger.displayString,
                   commands.map(MainMenuTitles.title).joined(separator: ", "))
        case .reserved(let chord, let command):
            String(format: L10n.string("%@ is reserved by macOS or MacExplorer (%@)."), chord.displayString,
                   MainMenuTitles.title(command))
        case .notAPrimary(let chord, let command):
            String(format: L10n.string("%@ types text, so it can’t be the menu shortcut of %@."), chord.displayString,
                   MainMenuTitles.title(command))
        }
    }

    static func message(_ warning: KeymapWarning) -> String {
        switch warning {
        case .unknownCommand(let name):
            String(format: L10n.string("Skipped “%@”: not a command in this version of MacExplorer."), name)
        case .fixedCommand(let command):
            String(format: L10n.string("Skipped %@: its shortcut can’t be changed."), MainMenuTitles.title(command))
        }
    }
}
