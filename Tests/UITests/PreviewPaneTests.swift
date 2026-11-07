// Tests/UITests/PreviewPaneTests.swift
import XCTest
import AppKit
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

/// P3-12: the preview pane. Every file lives in the test's own sandbox; Quick Look is the fake host (no previewer
/// ever reads a file) and downloads use FakeUbiquitousDownloader (never startDownloadingUbiquitousItem).
@MainActor
final class PreviewPaneTests: XCTestCase {
    /// Main-actor state the (Sendable) resolver closures read and write.
    @MainActor final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    var sandbox: Sandbox!
    var context: UIContext!
    var env: CoreEnvironment { context.environment }
    var host: FakeQuickLookHost!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = try sandbox.createDirectory("state")
        context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root), options: options)
        host = FakeQuickLookHost()
    }

    override func tearDown() async throws {
        host = nil
        context = nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if condition() { return }
        XCTFail("timed out: \(what)")
    }

    private func pane(resolve: PreviewPaneController.Resolver? = nil) -> PreviewPaneController {
        let host = self.host!
        let p = PreviewPaneController(context: context, makeHost: { host }, debounce: .milliseconds(20),
                                      resolve: resolve ?? PreviewPaneController.defaultResolve(context.environment))
        _ = p.view
        p.isActive = true
        addTeardownBlock { @MainActor in p.close() }
        return p
    }

    private func folder(_ rel: String) async -> FolderModel {
        let m = env.makeFolderModel(sandbox.url(rel))
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        await waitUntil("loaded") { m.state == .complete }
        return m
    }
    private func select(_ m: FolderModel, _ names: [String]) { m.select(.names(names)) }

    func testNothingTextAndTruncation() async throws {
        try sandbox.createFile("d/big.txt", contents: Data(repeating: UInt8(ascii: "a"), count: 300_000))
        try sandbox.createFile("d/small.txt", contents: Data("hello".utf8))
        let m = await folder("d")
        let p = pane()
        p.bind(m)
        await waitUntil("nothing") { p.displayState == .nothing }
        XCTAssertEqual(p.probeState, "nothing")
        select(m, ["big.txt"])
        await waitUntil("text") { if case .text(_, true) = p.displayState { true } else { false } }
        if case .text(let text, _) = p.displayState { XCTAssertEqual(text.utf8.count, 262_144) }
        XCTAssertFalse(p.truncationFooterHidden)
        select(m, ["small.txt"])
        await waitUntil("small") { p.displayState == .text("hello", truncated: false) }
        XCTAssertTrue(p.truncationFooterHidden)
        XCTAssertEqual(p.probeText, "hello")
        XCTAssertNil(host.shownURL)
        await waitUntil("details") { p.details?.size == 5 }
    }

    func testQuickLookFolderMultipleAndBrokenLink() async throws {
        try sandbox.writePNG("d/p.png")
        try sandbox.createDirectory("d/sub")
        try sandbox.createFile("d/a.txt", contents: Data("12".utf8))
        try sandbox.createSymlink("d/broken", target: "nowhere")
        let m = await folder("d")
        let p = pane()
        p.bind(m)
        select(m, ["p.png"])
        await waitUntil("quick look") { p.displayState == .quickLook(self.sandbox.url("d/p.png")) }
        XCTAssertEqual(host.shownURL?.lastPathComponent, "p.png")
        await waitUntil("details") { p.details?.pixelWidth == 64 }
        select(m, ["sub"])
        await waitUntil("folder") { if case .folder = p.displayState { true } else { false } }
        XCTAssertNil(host.shownURL, "Quick Look is cleared when not used")
        select(m, ["a.txt", "p.png"])
        await waitUntil("multiple") { if case .multiple(2, _) = p.displayState { true } else { false } }
        XCTAssertEqual(p.probeState, "multiple:2")
        XCTAssertNil(p.details)
        select(m, ["broken"])
        await waitUntil("broken") { if case .broken = p.displayState { true } else { false } }
        XCTAssertNil(p.details, "a broken link has no details")
    }

    func testRapidSelectionResolvesOnlyTheLast() async throws {
        for n in ["1.txt", "2.txt", "3.txt", "4.txt"] { try sandbox.createFile("d/\(n)") }
        let m = await folder("d")
        let resolved = Box<[String]>([])
        let base = PreviewPaneController.defaultResolve(env)
        let p = pane(resolve: { subject in resolved.value.append(subject.url.lastPathComponent); return await base(subject) })
        p.bind(m)
        for n in ["1.txt", "2.txt", "3.txt", "4.txt"] { select(m, [n]) }
        await waitUntil("last shown") { if case .text = p.displayState { true } else { false } }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(resolved.value, ["4.txt"])
    }

    func testCloudPlaceholderLoadsNothingUntilDownload() async throws {
        try sandbox.createFile("d/cloud.txt", contents: Data("now local".utf8))
        let m = await folder("d")
        let downloaded = Box(false)
        let base = PreviewPaneController.defaultResolve(env)
        let p = pane(resolve: { subject in downloaded.value ? await base(subject) : .cloudPlaceholder(subject.url) })
        let fake = FakeUbiquitousDownloader(datalessPolls: 1)
        p.downloader = fake
        p.downloadPollInterval = .milliseconds(10)
        p.bind(m)
        select(m, ["cloud.txt"])
        await waitUntil("cloud") { p.displayState == .cloud(self.sandbox.url("d/cloud.txt")) }
        XCTAssertNil(host.shownURL)
        XCTAssertEqual(p.textLoads, 0, "a dataless item is never read")
        XCTAssertEqual(fake.started(), [])
        downloaded.value = true
        p.performDownload()
        await waitUntil("downloaded and shown") { p.displayState == .text("now local", truncated: false) }
        XCTAssertEqual(fake.started(), [sandbox.url("d/cloud.txt")])
    }

    func testFailedDownloadOffersTryAgain() async throws {
        try sandbox.createFile("d/cloud.txt")
        let m = await folder("d")
        let p = pane(resolve: { .cloudPlaceholder($0.url) })
        let fake = FakeUbiquitousDownloader(failStart: true)
        p.downloader = fake
        p.bind(m)
        select(m, ["cloud.txt"])
        await waitUntil("cloud") { if case .cloud = p.displayState { true } else { false } }
        p.performDownload()
        await waitUntil("failed") { p.displayState == .downloadFailed(self.sandbox.url("d/cloud.txt")) }
        p.performDownload()                                         // "Try Again"
        await waitUntil("retried") { fake.started().count == 2 }
    }

    func testSelectionChangeCancelsADownloadInProgress() async throws {
        try sandbox.createFile("d/cloud.txt")
        try sandbox.createFile("d/b.txt", contents: Data("b".utf8))
        let m = await folder("d")
        let base = PreviewPaneController.defaultResolve(env)
        let p = pane(resolve: { $0.url.lastPathComponent == "cloud.txt" ? .cloudPlaceholder($0.url) : await base($0) })
        p.downloader = FakeUbiquitousDownloader(datalessPolls: 1_000_000)
        p.downloadPollInterval = .milliseconds(5)
        p.bind(m)
        select(m, ["cloud.txt"])
        await waitUntil("cloud") { if case .cloud = p.displayState { true } else { false } }
        p.performDownload()
        await waitUntil("downloading") { if case .downloading = p.displayState { true } else { false } }
        select(m, ["b.txt"])
        await waitUntil("b shown") { p.displayState == .text("b", truncated: false) }
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(p.displayState, .text("b", truncated: false), "the old download never repaints the pane")
    }

    func testInactivePaneDoesNoWork() async throws {
        try sandbox.createFile("d/a.txt")
        let m = await folder("d")
        let calls = Box(0)
        let p = pane(resolve: { _ in calls.value += 1; return .nothingSelected })
        p.isActive = false
        p.bind(m)
        select(m, ["a.txt"])
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(p.displayState, .hidden)
        XCTAssertEqual(p.probeState, "hidden")
        p.isActive = true
        await waitUntil("works when shown") { calls.value == 1 }
        p.isActive = false
        XCTAssertNil(host.shownURL)
        XCTAssertEqual(p.displayState, .hidden)
    }

    func testTogglePersistsVisibilityAndWidth() async throws {
        try requireGUISession()
        let window = BrowserWindowController(context: context, initialURL: sandbox.root)
        window.showWindow(nil)
        defer { window.close() }
        // Wide enough for sidebar + the content's minimum fitting width + a 400-point pane.
        window.window?.setContentSize(NSSize(width: 1400, height: 700))
        let split = try XCTUnwrap(window.splitController)
        XCTAssertEqual(split.splitViewItems.count, 3)
        XCTAssertEqual(split.splitViewItems[2].behavior, .inspector)
        XCTAssertTrue(window.contentPane is ContentViewController, "the content pane is still found with the inspector")
        XCTAssertTrue(split.previewItem.isCollapsed)
        XCTAssertFalse(split.previewPane.isActive)
        split.togglePreviewPane()
        await waitUntil("shown") { !split.previewItem.isCollapsed && !split.isAnimatingPreview }
        XCTAssertTrue(env.settings.previewPaneVisible)
        XCTAssertTrue(split.previewPane.isActive)
        let before = env.settings.previewPaneWidth
        split.setPreviewWidth(400)
        XCTAssertEqual(env.settings.previewPaneWidth, before, "a programmatic width is never persisted")
        try dragPreviewDivider(split, toWidth: 420)
        await waitUntil("dragged width persisted") { abs(self.env.settings.previewPaneWidth - before) > 40 }
        let dragged = env.settings.previewPaneWidth
        XCTAssertEqual(dragged, Double(split.previewPane.view.frame.width), accuracy: 1, "the dragged width is stored")
        XCTAssertEqual(dragged, 420, accuracy: 12)
        split.togglePreviewPane()
        await waitUntil("hidden") { split.previewItem.isCollapsed && !split.isAnimatingPreview }
        XCTAssertFalse(env.settings.previewPaneVisible)
        XCTAssertFalse(split.previewPane.isActive)
        XCTAssertEqual(env.settings.previewPaneWidth, dragged, accuracy: 1, "collapsing never stores a smaller width")
    }

    /// Drags the preview divider the way a user does: real mouse events through NSSplitView's tracking loop.
    private func dragPreviewDivider(_ split: BrowserSplitViewController, toWidth width: CGFloat) throws {
        let window = try XCTUnwrap(split.view.window)
        let splitView = split.splitView
        let thickness = splitView.dividerThickness
        let paneWidth = split.previewPane.view.frame.width
        let y = splitView.bounds.midY
        func point(_ w: CGFloat) -> NSPoint {
            splitView.convert(NSPoint(x: splitView.bounds.width - w - thickness / 2, y: y), to: nil)
        }
        func event(_ type: NSEvent.EventType, _ location: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        NSApp.postEvent(try event(.leftMouseDragged, point((paneWidth + width) / 2)), atStart: false)
        NSApp.postEvent(try event(.leftMouseDragged, point(width)), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, point(width)), atStart: false)
        splitView.mouseDown(with: try event(.leftMouseDown, point(paneWidth)))
    }

    // QA round 2: showing the pane in a window too narrow for the stored width must not overwrite it with the
    // clamped width; neither may a later window resize. Only a divider drag stores a width.
    func testToggleInNarrowWindowKeepsStoredWidth() async throws {
        try requireGUISession()
        env.settings.previewPaneWidth = 400
        let window = BrowserWindowController(context: context, initialURL: sandbox.root)
        window.showWindow(nil)
        defer { window.close() }
        window.window?.setContentSize(NSSize(width: 1004, height: 640))
        let split = try XCTUnwrap(window.splitController)
        XCTAssertTrue(split.previewItem.isCollapsed)
        split.togglePreviewPane()
        await waitUntil("shown") { !split.previewItem.isCollapsed && !split.isAnimatingPreview }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThan(split.previewPane.view.frame.width, 399, "precondition: the window is too narrow for 400")
        XCTAssertEqual(env.settings.previewPaneWidth, 400, "the toggle's clamped width is not stored")
        window.window?.setContentSize(NSSize(width: 900, height: 640))
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(env.settings.previewPaneWidth, 400, "a window resize is not stored")
        window.window?.setContentSize(NSSize(width: 1400, height: 700))
        split.setPreviewWidth(env.settings.previewPaneWidth)
        XCTAssertEqual(split.previewPane.view.frame.width, 400, accuracy: 2, "the stored width shows once it fits")
        try dragPreviewDivider(split, toWidth: 300)
        await waitUntil("drag persisted") { abs(self.env.settings.previewPaneWidth - 300) < 12 }
        XCTAssertEqual(env.settings.previewPaneWidth, Double(split.previewPane.view.frame.width), accuracy: 1)
    }

    func testTogglePreviewPaneCommandRunsThroughTheHandler() async throws {
        try requireGUISession()
        let window = BrowserWindowController(context: context, initialURL: sandbox.root)
        window.showWindow(nil)
        defer { window.close() }
        let split = try XCTUnwrap(window.splitController)
        let content = try XCTUnwrap(window.contentPane as? ContentViewController)
        let handler = try XCTUnwrap(content.handler)
        let target = try XCTUnwrap(content.commandTarget)
        XCTAssertTrue(handler.canPerform(.togglePreviewPane, target: target))
        handler.perform(.togglePreviewPane, target: target, sender: nil)
        await waitUntil("shown") { !split.previewItem.isCollapsed }
        XCTAssertTrue(env.settings.previewPaneVisible)
    }

    // Review Focus 2: ⌥P types "π" in a text field instead of toggling the pane.
    func testOptionPReachesFieldEditorWhileEditing() async throws {
        try requireGUISession()
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = MainMenuBuilder.build()
        defer { NSApp.mainMenu = previousMenu }
        let window = BrowserWindowController(context: context, initialURL: sandbox.root)
        window.showWindow(nil)
        defer { window.close() }
        let nsWindow = try XCTUnwrap(window.window)
        let action = Selector(Command.togglePreviewPane.selectorName)
        let item = try XCTUnwrap(NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.items.first { $0.action == action } }.first)
        XCTAssertEqual(item.keyEquivalent, "p")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option])
        let validator = try XCTUnwrap(window.contentPane)
        window.focus(.content)
        XCTAssertTrue(validator.validateMenuItem(item), "control: ⌥P toggles the pane from the list")

        window.focus(.addressBar)
        await waitUntil("editing") { (nsWindow.firstResponder as? NSTextView)?.isFieldEditor == true }
        let editor = try XCTUnwrap(nsWindow.firstResponder as? NSTextView)
        editor.string = ""
        // While a field editor is first responder the item is disabled (togglePreviewPane ∈ collidesWithTextEditing),
        // so the menu never consumes the key equivalent.
        XCTAssertFalse(validator.validateMenuItem(item), "⌥P is not consumed by the menu while typing")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
                                                   windowNumber: nsWindow.windowNumber, context: nil,
                                                   characters: "π", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        XCTAssertFalse(nsWindow.performKeyEquivalent(with: event))
        // The path NSApplication takes for the key window: key equivalents (window, then menu), then the first responder.
        MacxApplication.deliver(event, toPinned: nsWindow, menu: NSApp.mainMenu)
        if NSApp.keyWindow === nsWindow {
            await waitUntil("typed") { editor.string == "π" }
        } else {
            // xctest is not the active app, so the text input system ignores keyDown (FieldEditorKeyRoutingTests says
            // the same); the UI scenario preview-optp-in-field (P3-13) checks the typed character end to end.
            XCTAssertTrue(nsWindow.firstResponder === editor, "the key went to the field editor, focus unchanged")
        }
        XCTAssertFalse(env.settings.previewPaneVisible, "⌥P must not toggle the pane while typing")
        XCTAssertTrue(try XCTUnwrap(window.splitController).previewItem.isCollapsed)
    }

    func testDetailsHideAbsentRowsAndFormatValues() {
        let d = PreviewDetails(size: 1_500, created: nil, modified: Date(timeIntervalSince1970: 0), pixelWidth: 640, pixelHeight: 480,
                               duration: 65, pageCount: nil, kindDescription: "PNG image")
        let v = PreviewDetailsView.values(d)
        XCTAssertEqual(v[.kind], "PNG image")
        XCTAssertEqual(v[.size], Formatters.bytes(1_500))
        XCTAssertNil(v[.created])
        XCTAssertNotNil(v[.modified])
        XCTAssertEqual(v[.dimensions], "640 × 480")
        XCTAssertEqual(v[.duration], "1:05")
        XCTAssertNil(v[.pages])
        XCTAssertEqual(PreviewDetailsView.duration(5), "0:05")
        XCTAssertEqual(PreviewDetailsView.duration(3_723), "1:02:03")
        XCTAssertNil(PreviewDetailsView.duration(.nan))
        let view = PreviewDetailsView()
        view.show(d)
        XCTAssertEqual(view.visibleValues.count, 5)
    }

    func testMessagesForCloudAndUnavailable() async throws {
        try sandbox.createFile("d/x.txt")
        let m = await folder("d")
        let p = pane(resolve: { .cloudPlaceholder($0.url) })
        p.bind(m)
        select(m, ["x.txt"])
        await waitUntil("cloud") { if case .cloud = p.displayState { true } else { false } }
        XCTAssertEqual(p.messageTitle, L10n.string("preview.cloud"))
        XCTAssertEqual(p.messageButtonTitle, L10n.string("preview.download"))
        let q = pane(resolve: { .unavailable($0.url, code: EACCES) })
        q.bind(m)
        await waitUntil("unavailable") { if case .unavailable(_, EACCES) = q.displayState { true } else { false } }
        XCTAssertEqual(q.messageTitle, L10n.string("preview.unavailable"))
        XCTAssertNil(q.messageButtonTitle)
    }

    // QA round 1: a text-typed file whose bytes are not text (NULs) shows a message, never Quick Look (whose Text
    // bundle laid out a 2 GB sparse .txt on the main thread).
    func testTextTypedBinaryContentShowsAMessageNotQuickLook() async throws {
        try sandbox.createSparseFile("d/huge.txt", size: 64 << 20)
        let h = try FileHandle(forWritingTo: sandbox.url("d/huge.txt"))
        try h.write(contentsOf: Data("nineteen bytes text".utf8))
        try h.close()
        try sandbox.createFile("d/nul-in-utf8.log", contents: Data("line one\nline\u{0}two\n".utf8))
        let m = await folder("d")
        let p = pane()
        p.bind(m)
        select(m, ["huge.txt"])
        await waitUntil("binary") { p.displayState == .binary(self.sandbox.url("d/huge.txt")) }
        XCTAssertEqual(p.probeState, "binary")
        XCTAssertEqual(p.messageTitle, L10n.string("preview.binary"))
        XCTAssertNil(host.shownURL, "Quick Look is never handed a text-typed file that failed the content check")
        await waitUntil("details") { p.details?.size == 64 << 20 }
        select(m, ["nul-in-utf8.log"])
        await waitUntil("binary log") { p.displayState == .binary(self.sandbox.url("d/nul-in-utf8.log")) }
        XCTAssertNil(host.shownURL)
    }

    // QA polish: an empty file shows an explicit state, not a blank text area.
    func testEmptyFileShowsEmptyState() async throws {
        try sandbox.createFile("d/empty.txt", contents: Data())
        try sandbox.createFile("d/empty.zzqq", contents: Data())
        let m = await folder("d")
        let p = pane()
        p.bind(m)
        for name in ["empty.txt", "empty.zzqq"] {
            select(m, [name])
            await waitUntil("empty \(name)") { p.displayState == .empty(self.sandbox.url("d/\(name)")) }
            XCTAssertEqual(p.probeState, "empty")
            XCTAssertEqual(p.messageTitle, L10n.string("preview.empty"))
            XCTAssertNil(host.shownURL)
        }
    }

    // QA polish: Quick Look kept showing the old content after the previewed file changed on disk.
    func testQuickLookReloadsWhenTheFileChanges() async throws {
        try sandbox.writePNG("d/p.png", pixels: 16)
        let m = await folder("d")
        let p = pane()
        p.bind(m)
        select(m, ["p.png"])
        await waitUntil("quick look") { p.displayState == .quickLook(self.sandbox.url("d/p.png")) }
        XCTAssertEqual(host.refreshes, 0)
        let bigger = try XCTUnwrap(Sandbox.pngData(pixels: 64, red: 0.9, green: 0.1, blue: 0.1))
        try sandbox.overwrite("d/p.png", contents: bigger)               // a new size and modification date on disk
        await waitUntil("reloaded after the on-disk change", timeout: 10) { self.host.refreshes >= 1 }
        XCTAssertEqual(host.shownURL, sandbox.url("d/p.png"))
        let before = host.refreshes
        // An in-app change for the item (ChangeBus), even when size and date look the same, reloads it too.
        env.changeBus.post([LocalChange(directory: sandbox.url("d"), modified: ["p.png"])])
        await waitUntil("reloaded after the ChangeBus change") { self.host.refreshes > before }
        let settled = host.refreshes
        env.changeBus.post([LocalChange(directory: sandbox.url("d"), modified: ["other.png"])])
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.refreshes, settled, "a change to another item does not reload")
    }

    // QA polish: messages sat under the toolbar, their symbol half hidden: they are centred in the visible area.
    func testMessageIsCentredInTheSafeArea() async throws {
        let p = pane()
        p.view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        p.view.additionalSafeAreaInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        p.bind(nil)
        await waitUntil("nothing") { p.displayState == .nothing }
        p.view.layoutSubtreeIfNeeded()
        let safe = p.view.safeAreaRect
        let content = p.messageContentFrame
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(safe.contains(content), "\(content) inside \(safe)")
        XCTAssertEqual(content.midY, safe.midY, accuracy: 30, "vertically centred in the visible area")
        XCTAssertEqual(content.midX, safe.midX, accuracy: 2)
    }

    // QA polish: the menu title and Download for Preview read the global setting; each window has its own pane.
    func testPreviewPaneStateIsPerWindow() async throws {
        try requireGUISession()
        try sandbox.createFile("c.txt")
        let a = BrowserWindowController(context: context, initialURL: sandbox.root)
        let b = BrowserWindowController(context: context, initialURL: sandbox.root)
        a.showWindow(nil); b.showWindow(nil)
        defer { a.close(); b.close() }
        let splitA = try XCTUnwrap(a.splitController), splitB = try XCTUnwrap(b.splitController)
        splitA.togglePreviewPane()
        await waitUntil("A shown") { !splitA.previewItem.isCollapsed && !splitA.isAnimatingPreview }
        XCTAssertTrue(env.settings.previewPaneVisible)
        XCTAssertTrue(splitB.previewItem.isCollapsed, "B keeps its own pane hidden")
        let item = NSMenuItem(title: "", action: Selector(Command.togglePreviewPane.selectorName), keyEquivalent: "")
        let contentA = try XCTUnwrap(a.contentPane as? ContentViewController)
        let contentB = try XCTUnwrap(b.contentPane as? ContentViewController)
        _ = contentA.validateMenuItem(item)
        XCTAssertEqual(item.title, L10n.string("Hide Preview Pane"))
        _ = contentB.validateMenuItem(item)
        XCTAssertEqual(item.title, MainMenuTitles.title(.togglePreviewPane))
        for content in [contentA, contentB] {
            let m = content.session.folder
            await waitUntil("loaded") { m.state == .complete }
            m.select(.names(["c.txt"]))
        }
        let handlerA = try XCTUnwrap(contentA.handler), handlerB = try XCTUnwrap(contentB.handler)
        XCTAssertTrue(handlerA.canPerform(.downloadForPreview, target: try XCTUnwrap(contentA.commandTarget)))
        XCTAssertFalse(handlerB.canPerform(.downloadForPreview, target: try XCTUnwrap(contentB.commandTarget)),
                       "B's pane is hidden, whatever the setting says")
    }
}
