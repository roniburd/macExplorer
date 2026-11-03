import AppKit
import Core
import UI

/// P1-01 launch: one empty window on `--root` (or Home). P1-26 replaces the window with UIContext/WindowManager.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    let statePaths: StatePaths
    private var windows: [NSWindow] = []

    init(options: LaunchOptions) {
        self.options = options
        self.statePaths = options.stateDirectory.map { StatePaths(root: $0) } ?? .standard()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        if options.isSandboxed {
            do {
                try FileManager.default.createDirectory(at: statePaths.root, withIntermediateDirectories: true)
            } catch {
                FileHandle.standardError.write(Data("macExplorer: cannot create state dir: \(error)\n".utf8))
                exit(73)   // EX_CANTCREAT
            }
        }
        let folder = options.root ?? FileManager.default.homeDirectoryForCurrentUser
        openWindow(at: folder)
        NSApp.activate()
        if let delay = options.smokeExitAfter { scheduleSmokeExit(after: delay) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func openWindow(at folder: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = !options.isSandboxed
        window.title = Self.title(for: folder)
        window.representedURL = folder
        window.contentView = NSView()
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    static func title(for folder: URL) -> String {
        let name = folder.lastPathComponent
        return name.isEmpty ? folder.path(percentEncoded: false) : name
    }

    private func scheduleSmokeExit(after delay: Duration) {
        Task { @MainActor [options, statePaths] in
            try? await Task.sleep(for: delay)
            let titles = NSApp.orderedWindows.filter(\.isVisible).map(\.title)
            let report = SmokeReport(windowTitles: titles, root: options.root?.path(percentEncoded: false),
                                     processID: ProcessInfo.processInfo.processIdentifier)
            do {
                try report.write(to: statePaths.root.appending(path: SmokeReport.fileName))
            } catch {
                FileHandle.standardError.write(Data("macExplorer: cannot write smoke report: \(error)\n".utf8))
                exit(1)
            }
            exit(0)
        }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.string("Quit macExplorer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return main
    }
}
