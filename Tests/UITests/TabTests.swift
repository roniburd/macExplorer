import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

/// P2-05: native window tabs. Every folder lives in the harness sandbox (`macx-tests-<UUID>/files`).
@MainActor
final class TabTests: XCTestCase {
    private func harness() async throws -> ShellHarness {
        let h = try await ShellHarness.make(self)
        try h.dir("A")
        return h
    }

    private func waitListed(_ h: ShellHarness, _ controller: BrowserWindowController) async throws {
        try await h.waitUntil("tab folder complete") { controller.session.folder.state == .complete }
    }

    func testNewTabURLRules() async throws {
        let h = try await harness()
        let home = URL(filePath: "/Users/u", directoryHint: .isDirectory)
        let current = URL(filePath: "/Users/u/dev", directoryHint: .isDirectory)
        let settings = Settings(storage: InMemorySettingsStorage(), home: home)
        XCTAssertEqual(TabController.newTabURL(settings: settings, options: h.context.options, current: current), h.filesRoot,
                       "sandbox mode never opens Home")
        let plain = LaunchOptions()
        settings.startupFolder = .home
        XCTAssertEqual(TabController.newTabURL(settings: settings, options: plain, current: current), home)
        settings.startupFolder = .lastLocation
        XCTAssertEqual(TabController.newTabURL(settings: settings, options: plain, current: current), current)
        settings.startupFolder = .custom(URL(filePath: "/tmp", directoryHint: .isDirectory))
        XCTAssertEqual(TabController.newTabURL(settings: settings, options: plain, current: current).path(percentEncoded: false), "/tmp/")
    }

    func testTabTitleIsTheFolderNameEvenWithFullPathTitles() async throws {
        let h = try await harness()
        let volumes = h.environment.volumes
        XCTAssertEqual(TabController.tabTitle(for: h.url("A"), volumes: volumes), "A")
        XCTAssertEqual(TabController.tabTitle(for: URL(filePath: "/tmp/x/", directoryHint: .isDirectory), volumes: volumes), "x")
        XCTAssertFalse(TabController.tabTitle(for: URL(filePath: "/", directoryHint: .isDirectory), volumes: volumes).isEmpty)
    }

    func testOpenTabAppendsInBackgroundOrForeground() async throws {
        let h = try await harness()
        let host = try await h.openWindow()
        let hostWindow = try XCTUnwrap(host.window)
        let a = h.context.windows.openTab(at: h.url("A"), in: host, select: false)
        XCTAssertEqual(TabController.orderedTabs(of: hostWindow).count, 2)
        XCTAssertTrue(hostWindow.tabGroup?.selectedWindow === hostWindow, "background tab keeps the host selected")
        let b = h.context.windows.openTab(at: h.url(""), in: host, select: true)
        XCTAssertEqual(TabController.orderedTabs(of: hostWindow), [hostWindow, a.window!, b.window!], "appended at the end")
        XCTAssertTrue(hostWindow.tabGroup?.selectedWindow === b.window)
        XCTAssertEqual(h.context.windows.windows.count, 3)
        try await waitListed(h, a)
        XCTAssertEqual(a.window?.tab.title, "A")
        XCTAssertEqual(a.window?.tab.toolTip, a.session.folder.directory.path(percentEncoded: false).trimmingSuffixSlash)
        XCTAssertEqual(host.probeTabFolderURLs.count, 3)
        XCTAssertEqual(host.probeSelectedTabIndex, 2)
    }

    func testTabTitleAndToolTipFollowNavigationAndIgnoreFullPathSetting() async throws {
        let h = try await harness()
        h.environment.settings.showFullPathInTitle = true
        let host = try await h.openWindow()
        let a = h.context.windows.openTab(at: h.url(""), in: host, select: true)
        try await waitListed(h, a)
        a.navigate(to: h.url("A"))
        try await h.waitUntil("tab title follows navigation") { a.window?.tab.title == "A" }
        let full = a.session.folder.directory.path(percentEncoded: false).trimmingSuffixSlash
        XCTAssertTrue(full.hasSuffix("/files/A"))
        XCTAssertEqual(a.window?.title, full, "the window title still honours the full-path setting")
        XCTAssertEqual(a.window?.tab.toolTip, full)
    }

    func testNewWindowForTabOpensSandboxRootAndCommandNIsSeparateWindow() async throws {
        let h = try await harness()
        let host = try await h.openWindow("A")
        host.newWindowForTab(nil)
        let tabs = TabController.orderedTabs(of: try XCTUnwrap(host.window))
        XCTAssertEqual(tabs.count, 2)
        let newTab = try XCTUnwrap(h.context.windows.windows.first { $0.window === tabs[1] })
        XCTAssertEqual(newTab.session.folder.directory.standardizedFileURL, h.filesRoot.standardizedFileURL)
        XCTAssertTrue(host.window?.tabGroup?.selectedWindow === newTab.window, "⌘T selects the new tab")
        let other = try await h.openWindow("")
        XCTAssertEqual(TabController.orderedTabs(of: try XCTUnwrap(other.window)).count, 1, "⌘N must not join the tab group")
        XCTAssertEqual(TabController.orderedTabs(of: try XCTUnwrap(host.window)).count, 2)
    }

    func testNewTabMenuItemReachesTheWindowController() async throws {
        let h = try await harness()
        let host = try await h.openWindow()
        let action = Selector(Command.newTab.selectorName)
        XCTAssertTrue(host.responds(to: action))
        let pane = try XCTUnwrap(host.contentPane)
        XCTAssertFalse(pane.responds(to: action), "panes never intercept newWindowForTab:")
    }

    func testClosingATabKeepsTheOthers() async throws {
        let h = try await harness()
        let host = try await h.openWindow()
        let a = h.context.windows.openTab(at: h.url("A"), in: host, select: true)
        a.window?.performClose(nil)
        XCTAssertEqual(h.context.windows.windows.count, 1)
        XCTAssertTrue(h.context.windows.windows.first === host)
        XCTAssertEqual(TabController.orderedTabs(of: try XCTUnwrap(host.window)).count, 1)
    }

    func testCloseItemIsTitledCloseTabWhileTheWindowHasTabs() async throws {
        let h = try await harness()
        let host = try await h.openWindow()
        XCTAssertEqual(MenuValidation.closeTitle(for: host.window), "Close Window")
        let a = h.context.windows.openTab(at: h.url("A"), in: host, select: true)
        XCTAssertEqual(MenuValidation.closeTitle(for: host.window), "Close Tab")
        XCTAssertEqual(MenuValidation.closeTitle(for: a.window), "Close Tab")
        let item = MainMenuBuilder.item(.closeWindow)
        try await waitListed(h, a)
        XCTAssertTrue(try XCTUnwrap(a.contentPane).validateMenuItem(item))
        XCTAssertEqual(item.title, "Close Tab")
        a.window?.performClose(nil)
        XCTAssertEqual(MenuValidation.closeTitle(for: host.window), "Close Window")
        XCTAssertTrue(try XCTUnwrap(host.contentPane).validateMenuItem(item))
        XCTAssertEqual(item.title, "Close Window")
        XCTAssertEqual(MenuValidation.closeTitle(for: nil), "Close Window")
    }

    func testFileMenuRetitlesCloseForWindowsWithoutPanes() throws {
        let file = try XCTUnwrap(MainMenuBuilder.build().items.first { $0.identifier?.rawValue == "macx.menu.file" }?.submenu)
        XCTAssertTrue(file.delegate === CloseItemTitler.shared)
        let close = try XCTUnwrap(file.items.first { $0.identifier?.rawValue == "macx.menu.closeWindow" })
        close.title = "Close Tab"   // stale from a tabbed browser window
        CloseItemTitler.shared.menuNeedsUpdate(file)
        XCTAssertEqual(close.title, MenuValidation.closeTitle(for: NSApp.keyWindow))
    }

    // Review Focus 4
    func testRouterSelectsOriginTabBeforePresentingSheet() async throws {
        let h = try await harness()
        let host = try await h.openWindow()
        let a = h.context.windows.openTab(at: h.url("A"), in: host, select: false)
        let router = InteractionRouter(windows: h.context.windows)
        XCTAssertEqual(router.route(a.origin), .window(a.origin), "a background tab still hosts its own dialogs")
        XCTAssertTrue(host.window?.tabGroup?.selectedWindow === host.window, "routing alone does not switch tabs")
        XCTAssertTrue(router.hostWindow(for: a.origin) === a.window)
        XCTAssertTrue(host.window?.tabGroup?.selectedWindow === a.window, "origin tab must be selected before its sheet appears")
        XCTAssertTrue(router.window(for: .window(host.origin)) === host.window)
        XCTAssertTrue(host.window?.tabGroup?.selectedWindow === host.window)
    }

    func testRouterFallsBackToPanelWhenOriginTabClosed() async throws {
        let h = try await harness()
        let host = try await h.openWindow()
        let a = h.context.windows.openTab(at: h.url("A"), in: host, select: true)
        let origin = a.origin
        a.window?.close()
        let router = InteractionRouter(windows: h.context.windows)
        XCTAssertNil(router.hostWindow(for: origin))
        XCTAssertEqual(router.route(origin), .operationsPanel)
        XCTAssertTrue(router.hostWindow(for: host.origin) === host.window)
    }
}

private extension String {
    var trimmingSuffixSlash: String {
        var s = self
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
