import Foundation
import Core

/// Which windows open at launch (§5.1): `--root` wins; else the windows AppKit restored; else Settings' startup folder.
enum InitialWindows {
    enum Plan: Equatable { case open(URL), restore }

    static func plan(root: URL?, hasRestoredWindows: Bool, startup: StartupFolder, lastLocation: URL?, home: URL) -> Plan {
        if let root { return .open(root) }
        if hasRestoredWindows { return .restore }
        switch startup {
        case .home: return .open(home)
        case .lastLocation: return .open(lastLocation ?? home)
        case .custom(let url): return .open(url)
        }
    }
}

/// Window titles: the folder's name (a volume root shows the volume's name), or the full path when
/// Settings › Advanced › Show full path in window title is on. Pure (no file-system call).
enum WindowTitle {
    /// `volumeName` is non-nil only when `url` is that volume's mount point.
    static func title(for url: URL, volumeName: String?, fullPath: Bool) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if fullPath { return path }
        if let volumeName, !volumeName.isEmpty { return volumeName }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
