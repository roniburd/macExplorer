import AppKit
import Darwin
import Core
import MacxFS

/// Which dropped URLs open as tabs (§11 Tabs, tab-bar drop). Validation during the drag is in memory only
/// (`URL.hasDirectoryPath`: Finder and macExplorer write folder URLs with a trailing slash); the drop confirms each
/// one on a read lane.
@MainActor
enum TabDropPolicy {
    static func candidateFolders(_ urls: [URL]) -> [URL] { urls.filter(\.hasDirectoryPath) }

    /// stat on a read lane of each URL's volume; keeps existing directories that are not packages, in order.
    static func confirmFolders(_ urls: [URL], lanes: LanePool, volumes: Volumes) async -> [URL] {
        var result: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            let ext = url.standardizedFileURL.pathExtension
            let volume = volumes.volume(for: url)?.id ?? .unknown
            let isFolder = (try? await lanes.perform(on: volume, .read) { _ -> Bool in
                var st = stat()
                guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
                let types = TypeRegistry.shared
                return ext.isEmpty || !types.isPackage(types.index(forExtension: Substring(ext), isDirectory: true))
            }) ?? false
            if isFolder { result.append(URL(filePath: path, directoryHint: .isDirectory)) }
        }
        return result
    }
}

/// The "New Tab" toolbar item (identifier `macx.newTab`): click = ⌘T, dropping folders on it opens one tab per folder.
/// It is the tab-bar drop target, because AppKit has no public drop API for the native tab bar (P2-06 spike).
@MainActor
final class NewTabToolbarItem: NSToolbarItem {
    let button = NewTabButton()

    init() {
        super.init(itemIdentifier: ToolbarController.newTabID)
        let title = L10n.string("New Tab")
        label = title
        paletteLabel = title
        toolTip = title
        view = button
    }
}

/// The New Tab item's button. Drops are links: the dragged items are never moved or copied.
@MainActor
final class NewTabButton: NSButton {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 24))
        let title = L10n.string("New Tab")
        image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: title)
        imagePosition = .imageOnly
        bezelStyle = .toolbar
        action = #selector(NSResponder.newWindowForTab(_:))
        target = nil   // up the responder chain to BrowserWindowController
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(AXID.newTabItem)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("NewTabButton is created in code") }

    /// `.link` when any URL could be a folder, else no drop.
    static func dragOperation(for urls: [URL]) -> NSDragOperation {
        TabDropPolicy.candidateFolders(urls).isEmpty ? [] : .link
    }

    private static func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.dragOperation(for: Self.fileURLs(sender))
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.dragOperation(for: Self.fileURLs(sender))
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender)
        guard !TabDropPolicy.candidateFolders(urls).isEmpty else { return false }
        Task { await self.openDropped(urls) }
        return true
    }

    /// Opens every dropped folder as a tab of this button's window; the first one is selected. False when none was a
    /// folder (or the button is not in a browser window).
    @discardableResult
    func openDropped(_ urls: [URL]) async -> Bool {
        guard let controller = window?.windowController as? BrowserWindowController else { return false }
        let environment = controller.context.environment
        let folders = await TabDropPolicy.confirmFolders(TabDropPolicy.candidateFolders(urls),
                                                         lanes: environment.lanes, volumes: environment.volumes)
        guard !folders.isEmpty else { return false }
        controller.openTabs(folders)
        return true
    }
}
