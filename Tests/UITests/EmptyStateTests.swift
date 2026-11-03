// Tests/UITests/EmptyStateTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class EmptyStateTests: XCTestCase {
    func testContentForEveryState() {
        func make(_ state: FolderState, count: Int = 0, filter: String = "") -> EmptyStateContent? {
            EmptyStateContent.make(state: state, folderName: "Docs", visibleCount: count, filter: filter)
        }
        XCTAssertEqual(make(.complete)?.title, "This folder is empty")
        XCTAssertNil(make(.complete, count: 3))
        XCTAssertEqual(make(.complete, filter: "zz")?.title, "No items match 'zz'")
        XCTAssertNil(make(.loading))
        XCTAssertNil(make(.partial))
        XCTAssertEqual(make(.error(.permissionTCC)), EmptyStateContent(title: "macOS is blocking access to 'Docs'", detail: nil,
                                                                      action: .openPrivacySettings))
        XCTAssertEqual(make(.error(.permissionPOSIX)), EmptyStateContent(title: "You don't have permission to view 'Docs'",
                                                                        detail: nil, action: .properties))
        XCTAssertNil(make(.error(.notFound)), "handled by navigate-to-ancestor (§4.3)")
        XCTAssertNil(make(.error(.volumeGone)))
        let notDir = try? XCTUnwrap(make(.error(.notADirectory)))
        XCTAssertEqual(notDir?.title, "Can't open 'Docs'")
        XCTAssertEqual(notDir?.detail, String(cString: strerror(ENOTDIR)))
        XCTAssertEqual(notDir?.action, .retry)
        XCTAssertEqual(make(.error(.other(EIO)))?.detail, "\(String(cString: strerror(EIO))) (\(EIO))")
        XCTAssertEqual(make(.unresponsive), EmptyStateContent(title: "Location not responding", detail: nil, action: .retry))
        XCTAssertEqual(make(.waitingForPermission),
                       EmptyStateContent(title: "Waiting for macOS permission…", detail: nil, action: nil, showsSpinner: true))
    }

    func testActionTitles() {
        XCTAssertEqual(EmptyStateAction.openPrivacySettings.title, "Open Privacy Settings")
        XCTAssertEqual(EmptyStateAction.properties.title, "Properties")
        XCTAssertEqual(EmptyStateAction.retry.title, "Retry")
    }

    func testEmptyStateOverlayPassesClicksThrough() {
        let view = EmptyStateView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.show(EmptyStateContent(title: "This folder is empty", detail: nil, action: nil))
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.hitTest(NSPoint(x: 5, y: 5)), "right-click on empty space must reach the list")
    }

    func testEmptyFolderShowsMessage() async throws {
        let h = try await ContentTestHarness.make(self)
        let (content, _, _) = try await h.makeContent()
        XCTAssertEqual(content.emptyState.currentText, "This folder is empty")
        XCTAssertEqual(content.emptyState.accessibilityIdentifier(), AXID.emptyState)
    }

    func testFilterWithNoMatchesShowsQuery() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, session, _) = try await h.makeContent()
        XCTAssertNil(content.emptyState.currentText)
        var query = session.folder.query
        query.filter = "zz"
        session.folder.setQuery(query)
        try await h.waitUntil("no-match state") { content.emptyState.currentText == "No items match 'zz'" }
    }

    func testPermissionPOSIXShowsPropertiesButton() async throws {
        try XCTSkipIf(getuid() == 0, "root can read mode-000 folders")
        let h = try await ContentTestHarness.make(self)
        try h.dir("locked")
        try h.setMode("locked", 0)
        let (content, session, _) = try await h.makeContent()
        session.navigate(to: h.url("locked"))
        try await h.waitUntil("POSIX empty state") { content.emptyState.content?.action == .properties }
        XCTAssertEqual(content.emptyState.currentText, "You don't have permission to view 'locked'")
    }

    func testRetryAndPrivacyActions() async throws {
        let h = try await ContentTestHarness.make(self)
        let (content, _, _) = try await h.makeContent()
        content.performEmptyStateAction(.openPrivacySettings)
        XCTAssertEqual(RecordingURLOpener.shared.opened, [SystemSettingsLinks.privacyAllFiles], "recorded, never opened (S5-C2)")
        content.performEmptyStateAction(.retry)
        try await h.waitUntil("retried") { content.session.folder.state == .complete }
    }

    func testBannerShowsAndHides() async throws {
        let h = try await ContentTestHarness.make(self)
        let (content, _, _) = try await h.makeContent()
        XCTAssertNil(content.banner.currentText)
        content.showBanner("'Old' was moved or deleted")
        XCTAssertEqual(content.banner.currentText, "'Old' was moved or deleted")
        XCTAssertEqual(content.banner.accessibilityIdentifier(), AXID.banner)
        content.showBanner(nil)
        XCTAssertNil(content.banner.currentText)
    }

    func testStatusBarReflectsSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt", bytes: 10); try h.file("b.txt", bytes: 20); try h.file("c.txt")
        let (content, session, _) = try await h.makeContent()
        session.folder.select(.set(IndexSet([0, 1]), cursor: 1))
        let label = try XCTUnwrap(Self.find(AXID.statusSelection, in: content.statusBar) as? NSTextField)
        try await h.waitUntil("selection shown") { label.stringValue.contains("2") }
    }

    static func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews { if let match = find(identifier, in: subview) { return match } }
        return nil
    }
}
