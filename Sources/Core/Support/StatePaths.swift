import Foundation

/// Where the app keeps its own state: the crash journal, the sandbox-mode settings file and recents.
/// Pure path computation; nothing here touches the file system.
public struct StatePaths: Sendable, Equatable {
    /// `~/Library/Application Support/macExplorer`, or `--state-dir` in sandbox mode.
    public var root: URL

    /// `root/journal.json` (FileOps crash journal, spec §6.3).
    public var journal: URL { root.appending(path: "journal.json", directoryHint: .notDirectory) }

    /// `root/settings.json` (`FileSettingsStorage`, sandbox mode only).
    public var settingsFile: URL { root.appending(path: "settings.json", directoryHint: .notDirectory) }

    /// `root/folder-views.json`: per-folder view choices (FolderViewStore, design 2026-11-05 §2).
    public var folderViewsFile: URL { root.appending(path: "folder-views.json", directoryHint: .notDirectory) }

    /// `root/session.marker`: present while the app runs; left behind by a crash (spec §4.2).
    public var sessionMarker: URL { root.appending(path: "session.marker", directoryHint: .notDirectory) }

    /// Where macOS writes our crash reports. Sandbox runs look in `root/DiagnosticReports` so scenarios can plant fixtures.
    public func diagnosticReports(sandboxed: Bool) -> URL {
        if sandboxed { return root.appending(path: "DiagnosticReports", directoryHint: .isDirectory) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }

    public init(root: URL) {
        self.root = root
    }

    /// The real per-user location. Tests must never write here (overview Global Constraints › Safety).
    public static func standard() -> StatePaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return StatePaths(root: base.appending(path: "macExplorer", directoryHint: .isDirectory))
    }
}
