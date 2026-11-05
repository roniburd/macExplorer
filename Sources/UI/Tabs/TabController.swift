import AppKit
import Core
import MacxFS

/// Native window tabs (§11 Phase 2): every tab is its own BrowserWindowController/NSWindow in one NSWindowTabGroup, so
/// sessions, histories, OriginIDs and undo routing stay per tab. Tabs come only from WindowManager.openTab (⌘T, the
/// tab bar's "+", Open in New Tab); NSWindow.allowsAutomaticWindowTabbing is off, so ⌘N stays a separate window.
@MainActor
enum TabController {
    static let identifier = "macx.browser"

    static func configure(_ window: NSWindow) {
        // MainMenuBuilder.build() also turns this off; repeating it here keeps windows made without the app menu
        // (tests, early launch) from following the system "Prefer tabs" setting.
        NSWindow.allowsAutomaticWindowTabbing = false
        window.tabbingIdentifier = identifier
        window.tabbingMode = .automatic
    }

    /// ⌘T's folder: the sandbox root in sandbox runs (never Home), else Settings.startupFolder.
    static func newTabURL(settings: Settings, options: LaunchOptions, current: URL) -> URL {
        if let root = options.root { return root }
        switch settings.startupFolder {
        case .home: return settings.home
        case .lastLocation: return current
        case .custom(let url): return url
        }
    }

    /// The folder's display name (the volume's name at a mount point), whatever the window-title setting says.
    static func tabTitle(for url: URL, volumes: Volumes) -> String {
        let volume = volumes.volume(for: url)
        let isVolumeRoot = volume.map { pathKey($0.mountPoint) == pathKey(url) } ?? false
        return WindowTitle.title(for: url, volumeName: isVolumeRoot ? volume?.name : nil, fullPath: false)
    }

    /// The full path shown as the tab's tooltip: the same text as the full-path window title (no trailing slash).
    static func tabToolTip(for url: URL) -> String { WindowTitle.title(for: url, volumeName: nil, fullPath: true) }

    /// The tabs of `window`'s group in tab-bar order (just `window` while it has no tab group).
    static func orderedTabs(of window: NSWindow) -> [NSWindow] { window.tabbedWindows ?? [window] }

    private static func pathKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
