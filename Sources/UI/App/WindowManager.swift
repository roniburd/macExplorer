import AppKit
import Core
import MacxFS

/// Opens, tracks and closes browser windows (§5.1). Closing the last window leaves the app running.
@MainActor
public final class WindowManager {
    private unowned let context: UIContext
    private var controllers: [BrowserWindowController] = []
    private var releaseToken: ObserverToken?

    public init(context: UIContext) {
        self.context = context
        // §4.2 release path (S1 note 15): windows showing a released volume go home.
        releaseToken = context.environment.volumes.addReleaseHandler { [weak self] volume in
            self?.moveWindowsHome(onVolume: volume)
        }
    }

    @discardableResult public func openWindow(at url: URL, selecting name: String? = nil) -> BrowserWindowController {
        let controller = makeController(at: url, selecting: name)
        if let window = controller.window {
            if let previous = (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? controllers.dropLast().last,
               let previousWindow = previous.window {
                window.setFrameTopLeftPoint(previousWindow.cascadeTopLeft(from: NSPoint(x: previousWindow.frame.minX,
                                                                                        y: previousWindow.frame.maxY)))
            } else {
                window.center()
            }
        }
        controller.showWindow(nil)
        controller.focus(.content)
        return controller
    }

    /// Opens `url` as a new tab at the end of `host`'s tab group (P2-05). `select: false` keeps `host`'s tab selected
    /// (background tab); `select: true` selects the new tab and gives its list the keyboard.
    @discardableResult
    func openTab(at url: URL, in host: BrowserWindowController, selecting name: String? = nil,
                 select: Bool) -> BrowserWindowController {
        let controller = makeController(at: url, selecting: name)
        guard let hostWindow = host.window, let newWindow = controller.window,
              let last = TabController.orderedTabs(of: hostWindow).last else { return controller }
        last.addTabbedWindow(newWindow, ordered: .above)
        if select {
            hostWindow.tabGroup?.selectedWindow = newWindow
            newWindow.makeKeyAndOrderFront(nil)
            controller.focus(.content)
        } else {
            hostWindow.tabGroup?.selectedWindow = hostWindow
        }
        return controller
    }

    /// A registered controller for `url` whose window is not shown yet (openWindow shows it, openTab adds it to a tab
    /// group).
    private func makeController(at url: URL, selecting name: String?) -> BrowserWindowController {
        let controller = BrowserWindowController(context: context, initialURL: url)
        if let name { controller.session.selectWhenListed(name) }
        controller.onClose = { [weak self, unowned controller] in self?.remove(controller) }
        controllers.append(controller)
        return controller
    }

    public var windows: [BrowserWindowController] { controllers }

    public func window(for origin: OriginID) -> BrowserWindowController? {
        controllers.first { $0.origin == origin }
    }

    /// --root wins; else restoration; else Settings.startupFolder.
    public func restoreOrOpenInitial() async {
        let settings = context.environment.settings
        let restorable = !context.options.isSandboxed
        let plan = InitialWindows.plan(root: context.options.root,
                                       hasRestoredWindows: restorable && !BrowserWindowRestoration.pending.isEmpty,
                                       startup: settings.startupFolder, lastLocation: settings.lastLocation, home: settings.home)
        let opened = BrowserWindowRestoration.drain { [weak self] url in
            restorable ? self?.openWindow(at: url).window : nil
        }
        switch plan {
        case .open(let url): openWindow(at: url)
        case .restore: if opened == 0 { openWindow(at: settings.home) }
        }
    }

    /// Windows showing a folder on `volume` navigate home (the volume is going away).
    public func moveWindowsHome(onVolume volume: VolumeID) {
        let volumes = context.environment.volumes
        let mountPath = volumes.list.first { $0.id == volume }.map { Self.directoryPath($0.mountPoint) }
        let home = context.environment.settings.home
        for controller in controllers {
            let folder = controller.session.folder
            let onVolume: Bool
            if let id = folder.volume?.id {
                onVolume = id == volume
            } else if let mountPath, mountPath != "/" {
                onVolume = Self.directoryPath(folder.directory).hasPrefix(mountPath)
            } else {
                onVolume = false
            }
            if onVolume { controller.navigate(to: home) }
        }
    }

    private static func directoryPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.hasSuffix("/") ? path : path + "/"
    }

    private func remove(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
    }
}
