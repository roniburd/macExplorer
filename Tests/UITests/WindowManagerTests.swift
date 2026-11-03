import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class WindowManagerTests: XCTestCase {
    func testOpenWindowRegistersShowsAndTitlesTheWindow() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("Projects")
        let controller = try await h.openWindow("Projects")
        XCTAssertEqual(h.context.windows.windows.count, 1)
        XCTAssertTrue(h.context.windows.windows.first === controller)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.title, "Projects")
        XCTAssertEqual(window.accessibilityIdentifier(), AXID.window)
        XCTAssertEqual(controller.origin, OriginID(raw: window.windowNumber))
        XCTAssertTrue(h.context.windows.window(for: controller.origin) === controller)
        XCTAssertNil(h.context.windows.window(for: OriginID(raw: -12345)))
    }

    func testOpenWindowSelectingAName() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let controller = try await h.openWindow(selecting: "b.txt")
        try await h.waitUntil("b.txt selected") { controller.probeSelectedNames == ["b.txt"] }
    }

    func testMultipleWindowsAndClosingRemovesThemAndClosesTheirModels() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("one"); try h.dir("two")
        let first = try await h.openWindow("one")
        let second = try await h.openWindow("two")
        XCTAssertEqual(h.context.windows.windows.count, 2)
        XCTAssertNotEqual(first.origin, second.origin)
        let model = first.session.folder
        var events = 0
        let token = model.observe { _ in events += 1 }
        defer { token.cancel() }
        first.close()
        XCTAssertEqual(h.context.windows.windows.count, 1)
        XCTAssertTrue(h.context.windows.windows.first === second)
        try h.file("one/late.txt")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(events, 0, "a closed window's model is closed")
        second.close()
        XCTAssertTrue(h.context.windows.windows.isEmpty, "closing the last window leaves nothing registered (the app keeps running)")
    }

    func testMoveWindowsHomeNavigatesOnlyWindowsOnThatVolume() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("deep/er")
        let controller = try await h.openWindow("deep/er")
        let volume = try XCTUnwrap(controller.session.folder.volume, "the sandbox's volume is known after start()")
        h.context.windows.moveWindowsHome(onVolume: VolumeID(raw: "uuid:not-this-one"))
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "er")
        h.context.windows.moveWindowsHome(onVolume: volume.id)
        XCTAssertEqual(controller.session.folder.directory.standardizedFileURL.path,
                       h.environment.settings.home.standardizedFileURL.path, "home is the sandbox root")
    }

    func testRestoreOrOpenInitialOpensTheRootInSandboxMode() async throws {
        try ShellHarness.requireWindowServer()
        let h = try await ShellHarness.make(self)
        await h.context.windows.restoreOrOpenInitial()
        XCTAssertEqual(h.context.windows.windows.count, 1)
        let controller = try XCTUnwrap(h.context.windows.windows.first)
        XCTAssertEqual(controller.session.folder.directory.standardizedFileURL.path, h.filesRoot.standardizedFileURL.path)
        XCTAssertFalse(controller.window?.isRestorable ?? true, "no window restoration in sandbox mode")
    }

    func testNavigationRecordsLastLocation() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let controller = try await h.openWindow()
        controller.navigate(to: h.url("sub"))
        XCTAssertEqual(h.environment.settings.lastLocation?.lastPathComponent, "sub")
    }
}

final class InitialWindowsTests: XCTestCase {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    private let root = URL(filePath: "/tmp/macx-tests-x/files", directoryHint: .isDirectory)
    private let custom = URL(filePath: "/Volumes/Work", directoryHint: .isDirectory)
    private let last = URL(filePath: "/Users/someone/Documents", directoryHint: .isDirectory)

    func testRootWinsOverRestorationAndStartupFolder() {
        XCTAssertEqual(InitialWindows.plan(root: root, hasRestoredWindows: true, startup: .custom(custom),
                                           lastLocation: last, home: home), .open(root))
    }

    func testRestoredWindowsWinOverTheStartupFolder() {
        XCTAssertEqual(InitialWindows.plan(root: nil, hasRestoredWindows: true, startup: .home, lastLocation: nil, home: home),
                       .restore)
    }

    func testStartupFolderChoices() {
        XCTAssertEqual(InitialWindows.plan(root: nil, hasRestoredWindows: false, startup: .home, lastLocation: last, home: home),
                       .open(home))
        XCTAssertEqual(InitialWindows.plan(root: nil, hasRestoredWindows: false, startup: .lastLocation, lastLocation: last,
                                           home: home), .open(last))
        XCTAssertEqual(InitialWindows.plan(root: nil, hasRestoredWindows: false, startup: .lastLocation, lastLocation: nil,
                                           home: home), .open(home))
        XCTAssertEqual(InitialWindows.plan(root: nil, hasRestoredWindows: false, startup: .custom(custom), lastLocation: last,
                                           home: home), .open(custom))
    }
}

final class WindowTitleTests: XCTestCase {
    func testTitleIsTheFolderNameOrTheFullPath() {
        let url = URL(filePath: "/Users/someone/Smoke Root", directoryHint: .isDirectory)
        XCTAssertEqual(WindowTitle.title(for: url, volumeName: nil, fullPath: false), "Smoke Root")
        XCTAssertEqual(WindowTitle.title(for: url, volumeName: nil, fullPath: true), "/Users/someone/Smoke Root")
    }

    func testVolumeRootUsesTheVolumeName() {
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        XCTAssertEqual(WindowTitle.title(for: root, volumeName: "Macintosh HD", fullPath: false), "Macintosh HD")
        XCTAssertEqual(WindowTitle.title(for: root, volumeName: nil, fullPath: false), "/")
        XCTAssertEqual(WindowTitle.title(for: root, volumeName: "Macintosh HD", fullPath: true), "/")
    }
}
