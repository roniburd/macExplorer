import XCTest
import AppKit
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

/// The preview pane's size (a share of the window, re-fitted on resize, wider for Quick Look) and zoom.
/// Every file lives in the test's own sandbox.
@MainActor
final class PreviewSizingZoomTests: XCTestCase {
    var sandbox: Sandbox!
    var context: UIContext!
    var env: CoreEnvironment { context.environment }

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = try sandbox.createDirectory("state")
        context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root), options: options)
    }

    override func tearDown() async throws { context = nil }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), file: StaticString = #filePath,
                           line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("timed out after \(timeout) waiting for: \(what)", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func openWindow(width: CGFloat) async throws -> (BrowserWindowController, BrowserSplitViewController) {
        try requireGUISession()
        let window = BrowserWindowController(context: context, initialURL: sandbox.url("d"))
        window.showWindow(nil)
        addTeardownBlock { @MainActor in window.close() }
        window.window?.setContentSize(NSSize(width: width, height: 700))
        let split = try XCTUnwrap(window.splitController)
        split.togglePreviewPane()
        await waitUntil("shown") { !split.previewItem.isCollapsed && !split.isAnimatingPreview }
        return (window, split)
    }

    private func paneWidth(_ split: BrowserSplitViewController) -> CGFloat {
        split.view.layoutSubtreeIfNeeded()
        return split.previewPane.view.frame.width
    }

    private func settle(_ split: BrowserSplitViewController) async {
        for _ in 0..<5 { split.view.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testOpensAtAShareOfTheWindowAndRefitsWhenItResizes() async throws {
        try sandbox.createFile("d/a.txt", contents: Data("hello".utf8))
        XCTAssertFalse(env.settings.hasStoredPreviewPaneWidth)
        let (window, split) = try await openWindow(width: 1600)
        let splitWidth = split.splitView.bounds.width
        XCTAssertEqual(paneWidth(split), (splitWidth * BrowserSplitViewController.defaultShare).rounded(), accuracy: 2,
                       "never dragged: opens at a share of the window")
        XCTAssertFalse(env.settings.hasStoredPreviewPaneWidth, "the default width is not stored")

        env.settings.previewPaneWidth = 1200                      // as if dragged wide on a big screen
        split.setPreviewWidth(env.settings.previewPaneWidth)
        XCTAssertEqual(paneWidth(split), split.maximumPreviewWidth(), accuracy: 2, "text previews stop at the cap")
        XCTAssertEqual(split.maximumPreviewWidth(), (splitWidth * BrowserSplitViewController.textMaximumShare).rounded(.down), accuracy: 1)

        env.settings.previewPaneWidth = 450
        split.setPreviewWidth(450)
        window.window?.setContentSize(NSSize(width: 900, height: 700))      // a smaller screen
        await settle(split)
        XCTAssertLessThanOrEqual(paneWidth(split), split.maximumPreviewWidth() + 1, "re-fitted under the cap")
        XCTAssertLessThan(paneWidth(split), 449)
        XCTAssertEqual(env.settings.previewPaneWidth, 450, "a resize never replaces the user's width")
        window.window?.setContentSize(NSSize(width: 1600, height: 700))
        await settle(split)
        XCTAssertEqual(paneWidth(split), 450, accuracy: 2, "the user's width comes back once it fits")
    }

    func testQuickLookContentGetsAWiderCap() async throws {
        try sandbox.createFile("d/a.txt", contents: Data("hello".utf8))
        try sandbox.writePNG("d/p.png")
        let (window, split) = try await openWindow(width: 1600)
        let folder = window.session.folder
        await waitUntil("listed") { folder.rowCount == 2 }
        let textCap = split.maximumPreviewWidth()
        env.settings.previewPaneWidth = 900
        folder.select(.names(["p.png"]))
        await waitUntil("quick look") { split.previewPane.probeState == "quickLook" }
        await waitUntil("wide cap") { split.previewShowsQuickLook }
        await settle(split)
        XCTAssertGreaterThan(split.maximumPreviewWidth(), textCap)
        XCTAssertGreaterThan(paneWidth(split), textCap + 50, "Quick Look content may be wider than text")
        XCTAssertLessThanOrEqual(paneWidth(split), 901, "never wider than the user's width (the file list's minimum also limits it)")
        XCTAssertFalse(split.previewPane.expandButtonHidden, "Quick Look content can open the Quick Look window")
        folder.select(.names(["a.txt"]))
        await waitUntil("text") { split.previewPane.probeState == "text" }
        await settle(split)
        XCTAssertFalse(split.previewShowsQuickLook)
        XCTAssertLessThanOrEqual(paneWidth(split), textCap + 1, "text goes back under the narrower cap")
        XCTAssertTrue(split.previewPane.expandButtonHidden)
    }

    func testZoomStepsPersistAndOnlyApplyToText() async throws {
        try sandbox.createFile("d/a.txt", contents: Data("hello".utf8))
        try sandbox.createFile("d/b.md", contents: Data("# Title".utf8))
        let host = FakeQuickLookHost()
        let p = PreviewPaneController(context: context, makeHost: { host }, debounce: .milliseconds(20))
        p.view.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        p.isActive = true
        addTeardownBlock { @MainActor in p.close() }
        let m = env.makeFolderModel(sandbox.url("d"))
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        await waitUntil("loaded") { m.state == .complete }
        p.bind(m)
        m.select(.names(["a.txt"]))
        await waitUntil("text") { p.probeState == "text" }
        XCTAssertTrue(p.canZoom)
        XCTAssertNil(p.zoomLabel, "no label at 100%")
        p.zoomIn(); p.zoomIn()
        XCTAssertEqual(env.settings.previewZoom, 1.25, accuracy: 0.001)
        XCTAssertEqual(p.zoomLabel, NumberFormatter.localizedString(from: 1.25, number: .percent))
        m.select(.names(["b.md"]))
        await waitUntil("markdown") { p.probeState == "markdown" }
        XCTAssertEqual(p.zoomLabel, NumberFormatter.localizedString(from: 1.25, number: .percent), "the zoom carries to the next file")
        for _ in 0..<20 { p.zoomIn() }
        XCTAssertEqual(env.settings.previewZoom, 3, "capped")
        for _ in 0..<20 { p.zoomOut() }
        XCTAssertEqual(env.settings.previewZoom, 0.5, "floored")
        p.resetZoom()
        XCTAssertEqual(env.settings.previewZoom, 1)
        XCTAssertNil(p.zoomLabel)
        m.select(.names([]))
        await waitUntil("nothing") { p.probeState == "nothing" }
        XCTAssertFalse(p.canZoom, "nothing to zoom")
    }
}
