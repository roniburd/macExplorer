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
        let controller = BrowserWindowController(context: context, initialURL: url)
        if let name { controller.session.selectWhenListed(name) }
        controller.onClose = { [weak self, unowned controller] in self?.remove(controller) }
        if let window = controller.window {
            if let previous = (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? controllers.last,
               let previousWindow = previous.window {
                window.setFrameTopLeftPoint(previousWindow.cascadeTopLeft(from: NSPoint(x: previousWindow.frame.minX,
                                                                                        y: previousWindow.frame.maxY)))
            } else {
                window.center()
            }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.focus(.content)
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
