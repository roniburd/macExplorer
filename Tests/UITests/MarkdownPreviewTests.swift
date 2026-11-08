import XCTest
import AppKit
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

/// The preview pane renders Markdown files (Rendered | Source switch, links, images). Every file lives in the
/// test's own sandbox; web links and remote images go to fakes (nothing opens a browser or touches the network).
@MainActor
final class MarkdownPreviewTests: XCTestCase {
    @MainActor final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

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

    private func pane() -> PreviewPaneController {
        let host = FakeQuickLookHost()
        let p = PreviewPaneController(context: context, makeHost: { host }, debounce: .milliseconds(20))
        p.view.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
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

    func testMarkdownFileDetection() {
        for name in ["a.md", "B.MD", "c.markdown", "d.mdown", "e.mkd"] { XCTAssertTrue(MarkdownFiles.isMarkdown(URL(filePath: "/x/\(name)")), name) }
        for name in ["a.txt", "md", "a.mdx", "a.rmd"] { XCTAssertFalse(MarkdownFiles.isMarkdown(URL(filePath: "/x/\(name)")), name) }
    }

    func testMarkdownRendersAndTheSwitchIsRemembered() async throws {
        try sandbox.createFile("d/README.md", contents: Data("# Hello\n\nSome **bold** text.\n".utf8))
        try sandbox.createFile("d/plain.txt", contents: Data("# not markdown".utf8))
        XCTAssertTrue(env.settings.previewRendersMarkdown, "rendered by default")
        let m = await folder("d")
        let p = pane()
        p.bind(m)
        m.select(.names(["README.md"]))
        await waitUntil("rendered") { p.probeState == "markdown" }
        XCTAssertEqual(p.shownText, "Hello\nSome bold text.")
        XCTAssertFalse(p.modeControlHidden)
        XCTAssertEqual(p.probeText, "# Hello\n\nSome **bold** text.\n", "the probe reports the file's text")

        p.setMarkdownRendered(false)
        XCTAssertEqual(p.probeState, "markdownSource")
        XCTAssertEqual(p.shownText, "# Hello\n\nSome **bold** text.\n")
        XCTAssertFalse(env.settings.previewRendersMarkdown, "the choice is saved")

        m.select(.names(["plain.txt"]))
        await waitUntil("plain") { p.probeState == "text" }
        XCTAssertTrue(p.modeControlHidden, "only Markdown files get the switch")
        XCTAssertEqual(p.shownText, "# not markdown")

        m.select(.names(["README.md"]))
        await waitUntil("source again") { p.probeState == "markdownSource" }
        XCTAssertEqual(p.shownText, "# Hello\n\nSome **bold** text.\n", "the saved choice applies to the next file")
        p.setMarkdownRendered(true)
        XCTAssertEqual(p.shownText, "Hello\nSome bold text.")
        XCTAssertTrue(env.settings.previewRendersMarkdown)
    }

    // MARK: Word documents (Reflowed | Original)

    private func writeDocument(_ rel: String, _ text: String, type: NSAttributedString.DocumentType = .officeOpenXML) throws {
        let source = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Times New Roman", size: 14)!,
                                                                   .foregroundColor: NSColor.black])
        let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: type])
        try sandbox.createFile(rel, contents: data)
    }

    func testWordDocumentReflowsAndTheSwitchShowsQuickLook() async throws {
        try writeDocument("d/report.docx", "Quarterly report\nRevenue grew.")
        try writeDocument("d/old.doc", "Legacy document", type: .docFormat)
        try writeDocument("d/open.odt", "Open document", type: .openDocument)
        try sandbox.createFile("d/broken.docx", contents: Data("not a zip".utf8))
        let host = FakeQuickLookHost()
        let p = PreviewPaneController(context: context, makeHost: { host }, debounce: .milliseconds(20))
        p.view.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        p.isActive = true
        addTeardownBlock { @MainActor in p.close() }
        let m = await folder("d")
        p.bind(m)

        m.select(.names(["report.docx"]))
        await waitUntil("reflowed") { p.probeState == "document" }
        XCTAssertEqual(p.shownText.trimmingCharacters(in: .whitespacesAndNewlines), "Quarterly report\nRevenue grew.")
        XCTAssertEqual(p.modeLabels, ["Reflowed", "Original"])
        XCTAssertFalse(p.modeControlHidden)
        XCTAssertNil(host.shownURL, "Quick Look is not used while reflowed")

        p.setDocumentReflowed(false)
        await waitUntil("original") { p.probeState == "documentOriginal" }
        XCTAssertEqual(host.shownURL, sandbox.url("d/report.docx"))
        XCTAssertFalse(env.settings.previewReflowsDocuments, "the choice is saved")
        XCTAssertFalse(p.modeControlHidden, "the switch stays over Quick Look")
        p.setDocumentReflowed(true)
        await waitUntil("reflowed again") { p.probeState == "document" }
        XCTAssertNil(host.shownURL)

        for (name, text) in [("old.doc", "Legacy document"), ("open.odt", "Open document")] {
            m.select(.names([name]))
            await waitUntil(name) { p.probeState == "document" && p.shownText.trimmingCharacters(in: .whitespacesAndNewlines) == text }
        }

        m.select(.names(["broken.docx"]))
        await waitUntil("fallback") { p.probeState == "quickLook" }
        XCTAssertEqual(host.shownURL, sandbox.url("d/broken.docx"), "unreadable documents fall back to Quick Look")
        XCTAssertTrue(p.modeControlHidden)
    }

    func testReflowedTextFollowsTheSystemTextColor() {
        let text = NSMutableAttributedString(string: "black red")
        text.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: 5))
        text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 6, length: 3))
        text.addAttribute(.backgroundColor, value: NSColor.white, range: NSRange(location: 0, length: 9))
        let adapted = DocumentReflow.adapted(text)
        XCTAssertEqual(adapted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(adapted.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor, .systemRed)
        XCTAssertNil(adapted.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertNotNil(adapted.attribute(.font, at: 0, effectiveRange: nil))
    }

    func testLocalImagesLoadRemoteOnlyOnClick() async throws {
        try sandbox.writePNG("d/img/logo.png")
        try sandbox.createFile("d/doc.md", contents: Data("![logo](img/logo.png)\n\n![badge](https://example.com/b.png)\n\n![gone](missing.png)\n".utf8))
        let m = await folder("d")
        let p = pane()
        let fetched = Box<[URL]>([])
        let png = try Data(contentsOf: sandbox.url("d/img/logo.png"))
        p.fetchRemoteImage = { url in await MainActor.run { fetched.value.append(url) }; return png }
        p.bind(m)
        m.select(.names(["doc.md"]))
        await waitUntil("local image") { p.imageAttachmentCount == 1 }
        XCTAssertEqual(p.pendingImageCount, 2, "remote and missing images stay placeholders")
        XCTAssertEqual(fetched.value, [], "nothing is fetched without a click")

        XCTAssertTrue(p.followLink(URL(string: "x-macx-load-image:1")!))
        await waitUntil("remote image") { p.imageAttachmentCount == 2 }
        XCTAssertEqual(fetched.value, [URL(string: "https://example.com/b.png")!])
        XCTAssertEqual(p.pendingImageCount, 1)
    }

    func testLinksOpenScrollOrReveal() async throws {
        let body = (1...80).map { "Line \($0)\n" }.joined(separator: "\n")
        try sandbox.createFile("d/doc.md", contents: Data("[web](https://example.com)\n\n\(body)\n## Far Away\n".utf8))
        let m = await folder("d")
        let p = pane()
        let opened = Box<[URL]>([]), revealed = Box<[URL]>([])
        p.openExternal = { opened.value.append($0) }
        p.onRevealFile = { revealed.value.append($0) }
        p.bind(m)
        m.select(.names(["doc.md"]))
        await waitUntil("rendered") { p.probeState == "markdown" }

        XCTAssertTrue(p.followLink(URL(string: "https://example.com")!))
        XCTAssertEqual(opened.value, [URL(string: "https://example.com")!])
        XCTAssertTrue(p.followLink(URL(filePath: sandbox.url("d/other.md").path)))
        XCTAssertEqual(revealed.value.map(\.lastPathComponent), ["other.md"])
        XCTAssertTrue(p.followLink(MarkdownRenderer.anchorURL("far-away")!))
        XCTAssertFalse(p.followLink(MarkdownRenderer.anchorURL("nowhere")!))
        XCTAssertFalse(p.followLink(URL(string: "ftp://example.com")!))
        XCTAssertEqual(opened.value.count, 1)
    }
}
