import XCTest
import AppKit
import SwiftUI
@testable import UI
import Core
import MacxFS

/// §7 Settings: the choice helpers the SwiftUI sections bind to, and the window that hosts them.
@MainActor
final class SettingsChoicesTests: XCTestCase {
    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
    }

    func testSectionsAreTheFourOfSpecSeven() {
        XCTAssertEqual(SettingsSection.allCases.map(\.title), ["General", "View", "Sidebar", "Advanced"])
    }

    func testStartupChoiceMirrorsTheSetting() {
        let s = settings()
        XCTAssertEqual(StartupFolderChoice(s.startupFolder), .home)
        s.startupFolder = .lastLocation
        XCTAssertEqual(StartupFolderChoice(s.startupFolder), .lastLocation)
        s.startupFolder = .custom(URL(filePath: "/tmp/x", directoryHint: .isDirectory))
        XCTAssertEqual(StartupFolderChoice(s.startupFolder), .custom)
        XCTAssertEqual(StartupFolderChoice.allCases.map(\.title), ["Home", "Last location", "Custom…"])
    }

    func testSelectingHomeOrLastLocationNeverAsksForAFolder() {
        let s = settings()
        SettingsChoices.select(.lastLocation, in: s) { XCTFail("no panel"); return nil }
        XCTAssertEqual(s.startupFolder, .lastLocation)
        SettingsChoices.select(.home, in: s) { XCTFail("no panel"); return nil }
        XCTAssertEqual(s.startupFolder, .home)
    }

    func testSelectingCustomAsksForAFolderAndKeepsThePreviousChoiceOnCancel() {
        let s = settings()
        s.startupFolder = .lastLocation
        var asked = 0
        SettingsChoices.select(.custom, in: s) { asked += 1; return nil }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(s.startupFolder, .lastLocation, "cancelled panel: unchanged")
        let folder = URL(filePath: "/tmp/macx-tests-custom", directoryHint: .isDirectory)
        SettingsChoices.select(.custom, in: s) { folder }
        XCTAssertEqual(s.startupFolder, .custom(folder))
        XCTAssertEqual(SettingsChoices.customFolderName(s), "macx-tests-custom")
        SettingsChoices.select(.custom, in: s) { XCTFail("already custom: keep it"); return nil }
        XCTAssertEqual(s.startupFolder, .custom(folder))
    }

    func testChooseCustomFolderReplacesTheFolderOnlyWhenOneIsChosen() {
        let s = settings()
        let a = URL(filePath: "/tmp/a", directoryHint: .isDirectory), b = URL(filePath: "/tmp/b", directoryHint: .isDirectory)
        s.startupFolder = .custom(a)
        SettingsChoices.chooseCustomFolder(in: s) { nil }
        XCTAssertEqual(s.startupFolder, .custom(a))
        SettingsChoices.chooseCustomFolder(in: s) { b }
        XCTAssertEqual(s.startupFolder, .custom(b))
        XCTAssertNil(SettingsChoices.customFolderName(settings()))
    }

    func testTerminalAppNameDefaultsToTerminalAndCanBeChosenAndReset() {
        let s = settings()
        XCTAssertEqual(SettingsChoices.terminalAppName(s), "Terminal")
        SettingsChoices.chooseTerminalApp(in: s) { nil }
        XCTAssertNil(s.terminalApp)
        let iterm = URL(filePath: "/Applications/iTerm.app", directoryHint: .isDirectory)
        SettingsChoices.chooseTerminalApp(in: s) { iterm }
        XCTAssertEqual(s.terminalApp, iterm)
        XCTAssertEqual(SettingsChoices.terminalAppName(s), "iTerm")
        SettingsChoices.resetTerminalApp(in: s)
        XCTAssertNil(s.terminalApp)
    }

    func testDefaultFavoriteVisibilityEditsTheHiddenSet() {
        let s = settings()
        XCTAssertTrue(DefaultFavorite.allCases.allSatisfy { SettingsChoices.isVisible($0, in: s) })
        SettingsChoices.setVisible(false, .downloads, in: s)
        XCTAssertEqual(s.hiddenDefaultFavorites, [.downloads])
        XCTAssertFalse(SettingsChoices.isVisible(.downloads, in: s))
        SettingsChoices.setVisible(true, .downloads, in: s)
        XCTAssertEqual(s.hiddenDefaultFavorites, [])
        XCTAssertEqual(DefaultFavorite.allCases.map(SettingsChoices.title(for:)),
                       ["Home", "Desktop", "Documents", "Downloads", "Applications"])
    }

    func testBindingsWriteThroughToSettings() {
        let s = settings()
        let visible = SettingsChoices.visibilityBinding(.desktop, in: s)
        visible.wrappedValue = false
        XCTAssertEqual(s.hiddenDefaultFavorites, [.desktop])
        let startup = SettingsChoices.startupBinding(in: s) { nil }
        startup.wrappedValue = .lastLocation
        XCTAssertEqual(s.startupFolder, .lastLocation)
        XCTAssertEqual(startup.wrappedValue, .lastLocation)
    }

    func testOptionTitles() {
        XCTAssertEqual(Density.allCases.map(SettingsChoices.title(for:)), ["Compact", "Regular", "Comfortable"])
        XCTAssertEqual([DateStyle.relative, .absolute].map(SettingsChoices.title(for:)), ["Relative", "Absolute"])
        XCTAssertEqual([OpenFoldersIn.sameWindow, .newWindow].map(SettingsChoices.title(for:)), ["In the same window", "In a new window"])
        XCTAssertEqual([ReturnKeyBehavior.open, .rename].map(SettingsChoices.title(for:)), ["Open", "Rename"])
    }

    func testConfirmBeforeDeleteStaysLockedOn() {
        XCTAssertTrue(settings().confirmBeforeDelete, "§7: delete confirmation is locked on; the view shows a disabled checkbox")
    }
}

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testShowOpensOneSettingsWindowAndReusesIt() async throws {
        try ShellHarness.requireWindowServer()
        let h = try await ShellHarness.make(self)
        let first = SettingsWindowController.show(context: h.context)
        addTeardownBlock { @MainActor in first.close() }
        let window = try XCTUnwrap(first.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.title, "MacExplorer Settings")
        XCTAssertEqual(window.accessibilityIdentifier(), AXID.settingsWindow)
        XCTAssertTrue(window.contentViewController is NSHostingController<SettingsView>)
        XCTAssertFalse(window.isRestorable, "never restored")
        let second = SettingsWindowController.show(context: h.context)
        XCTAssertTrue(first === second, "one Settings window per app")
    }

    func testClosingTheWindowLetsTheNextShowCreateAFreshOne() async throws {
        try ShellHarness.requireWindowServer()
        let h = try await ShellHarness.make(self)
        let first = SettingsWindowController.show(context: h.context)
        first.window?.performClose(nil)
        XCTAssertFalse(first.window?.isVisible ?? true)
        let second = SettingsWindowController.show(context: h.context)
        addTeardownBlock { @MainActor in second.close() }
        XCTAssertFalse(first === second)
        XCTAssertTrue(second.window?.isVisible ?? false)
    }

    func testSettingsViewBuildsForEverySection() async throws {
        let h = try await ShellHarness.make(self)
        for section in SettingsSection.allCases {
            let host = NSHostingController(rootView: SettingsView(settings: h.environment.settings, panels: NoPanels(),
                                                                  initialSection: section))
            _ = host.view
            XCTAssertGreaterThan(host.view.fittingSize.width, 0, "\(section)")
        }
    }

    func testWindowTitleFollowsShowFullPathSetting() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("Alpha")
        let controller = try await h.openWindow("Alpha")
        XCTAssertEqual(controller.window?.title, "Alpha")
        h.environment.settings.showFullPathInTitle = true
        let full = h.url("Alpha").path(percentEncoded: false)
        try await h.waitUntil("full path title") { controller.window?.title == String(full.dropLast(full.hasSuffix("/") ? 1 : 0)) }
        h.environment.settings.showFullPathInTitle = false
        try await h.waitUntil("name title") { controller.window?.title == "Alpha" }
    }
}

@MainActor
private final class NoPanels: SettingsPanels {
    func chooseFolder() -> URL? { nil }
    func chooseApplication() -> URL? { nil }
}
