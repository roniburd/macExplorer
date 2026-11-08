import XCTest
import AppKit
@testable import UI

/// MarkdownRenderer: Markdown to attributed text. Pure: no file is read and nothing is fetched.
@MainActor
final class MarkdownRendererTests: XCTestCase {
    private let file = URL(filePath: "/tmp/macx-md-tests/docs/README.md")

    private func render(_ s: String) -> MarkdownRendering { MarkdownRenderer.render(s, fileURL: file) }

    private func attribute(_ key: NSAttributedString.Key, of text: String, in r: MarkdownRendering) -> Any? {
        let range = (r.text.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "\(text) not in \(r.text.string)")
        guard range.location != NSNotFound else { return nil }
        return r.text.attribute(key, at: range.location, effectiveRange: nil)
    }

    private func font(of text: String, in r: MarkdownRendering) -> NSFont? { attribute(.font, of: text, in: r) as? NSFont }

    func testHeadingsAreLargerAndCarryAnchors() {
        let r = render("# Title\n\nBody text\n\n## Getting Started!\n\n## Getting Started!\n")
        XCTAssertEqual(r.text.string, "Title\nBody text\nGetting Started!\nGetting Started!")
        XCTAssertGreaterThan(font(of: "Title", in: r)!.pointSize, font(of: "Body", in: r)!.pointSize)
        XCTAssertEqual(attribute(.macxAnchor, of: "Title", in: r) as? String, "title")
        let ns = r.text.string as NSString
        let second = ns.range(of: "Getting Started!", options: .backwards)
        XCTAssertEqual(r.text.attribute(.macxAnchor, at: ns.range(of: "Getting").location, effectiveRange: nil) as? String, "getting-started")
        XCTAssertEqual(r.text.attribute(.macxAnchor, at: second.location, effectiveRange: nil) as? String, "getting-started-1")
        XCTAssertNil(attribute(.macxAnchor, of: "Body", in: r))
    }

    func testInlineStyles() {
        let r = render("Some **bold**, *italic*, ~~gone~~ and `code`.")
        XCTAssertEqual(r.text.string, "Some bold, italic, gone and code.")
        XCTAssertTrue(font(of: "bold", in: r)!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font(of: "italic", in: r)!.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertNotNil(attribute(.strikethroughStyle, of: "gone", in: r))
        XCTAssertTrue(font(of: "code", in: r)!.isFixedPitch)
    }

    func testListsAndTaskLists() {
        let r = render("- one\n- two\n  - nested\n\n1. first\n2. second\n\n- [x] done\n- [ ] todo\n")
        XCTAssertEqual(r.text.string, "•\tone\n•\ttwo\n◦\tnested\n1.\tfirst\n2.\tsecond\n☑\tdone\n□\ttodo")
        let p = attribute(.paragraphStyle, of: "nested", in: r) as? NSParagraphStyle
        XCTAssertEqual(p?.headIndent, 36)
        let spacing = { (t: String) in (self.attribute(.paragraphStyle, of: t, in: r) as? NSParagraphStyle)?.paragraphSpacing }
        XCTAssertEqual(spacing("one"), 2, "list items are tight")
        XCTAssertEqual(spacing("done"), 2)
        XCTAssertEqual(spacing("todo"), 8, "only a list's last item gets paragraph spacing")
    }

    func testCodeBlockIsMonospacedAndOneParagraph() {
        let r = render("```swift\nlet a = 1\nlet b = 2\n```\n")
        XCTAssertEqual(r.text.string, "let a = 1\u{2028}let b = 2")
        XCTAssertTrue(font(of: "let a", in: r)!.isFixedPitch)
    }

    func testTableIsAnAlignedGrid() {
        let r = render("| Name | Size |\n|:-----|-----:|\n| a | 1 |\n| long name | 200 |\n")
        let lines = r.text.string.components(separatedBy: "\u{2028}")
        XCTAssertEqual(lines, ["Name      │ Size", "──────────┼─────", "a         │    1", "long name │  200"])
        XCTAssertTrue(font(of: "Name", in: r)!.isFixedPitch)
    }

    func testLinkResolution() {
        func link(_ md: String) -> URL? {
            let r = render(md)
            return r.text.attribute(.link, at: 0, effectiveRange: nil) as? URL
        }
        XCTAssertEqual(link("[x](https://example.com/a)"), URL(string: "https://example.com/a"))
        XCTAssertEqual(link("[x](mailto:me@example.com)"), URL(string: "mailto:me@example.com"))
        XCTAssertEqual(link("[x](guide/setup.md#install)"), URL(filePath: "/tmp/macx-md-tests/docs/guide/setup.md"))
        XCTAssertEqual(link("[x](../other%20file.md)"), URL(filePath: "/tmp/macx-md-tests/other file.md"))
        XCTAssertEqual(link("[x](#Getting-Started)"), URL(string: "x-macx-anchor:getting-started"))
        XCTAssertNil(link("[x](javascript:alert(1))"))
        XCTAssertNil(link("[x](vscode://open)"))
        XCTAssertEqual(link("<https://auto.example>"), URL(string: "https://auto.example"))
    }

    func testImagesBecomePlaceholders() {
        let r = render("![logo](img/logo.png)\n\n![](https://example.com/badge.svg)\n")
        XCTAssertEqual(r.images.map(\.url), [URL(filePath: "/tmp/macx-md-tests/docs/img/logo.png"), URL(string: "https://example.com/badge.svg")!])
        XCTAssertEqual(r.images.map(\.isRemote), [false, true])
        XCTAssertEqual(attribute(.macxImage, of: "logo", in: r) as? Int, 0)
        XCTAssertNil(attribute(.link, of: "logo", in: r), "a local image is not a link")
        XCTAssertEqual(attribute(.link, of: "badge.svg", in: r) as? URL, URL(string: "x-macx-load-image:1"),
                       "a remote image loads only on a click")
    }

    func testHTMLImagesBreaksAndTagsAreHandled() {
        let r = render("<p align=\"center\">\n  <img src=\"logo.png\" alt=\"Logo\">\n</p>\n\nA<br>B &amp; <kbd>⌘</kbd>\n\n<!-- hidden -->\n")
        XCTAssertEqual(r.images.map(\.alt), ["Logo"])
        XCTAssertTrue(r.text.string.contains("A\u{2028}B & ⌘"), r.text.string)
        XCTAssertFalse(r.text.string.contains("<"), r.text.string)
        XCTAssertFalse(r.text.string.contains("hidden"))
        XCTAssertTrue(r.text.string.hasPrefix("🖼 Logo\n"), "HTML whitespace around the image is dropped: \(r.text.string.debugDescription)")
    }

    func testSlug() {
        XCTAssertEqual(MarkdownRenderer.slug("What's New in 2.0?"), "whats-new-in-20")
        XCTAssertEqual(MarkdownRenderer.slug("snake_case and-dash"), "snake_case-and-dash")
    }

    func testLargeDocumentRendersQuickly() {
        let section = "## Section\n\nSome *text* with a [link](https://example.com) and `code`.\n\n- a\n- b\n\n```\ncode\n```\n\n"
        let source = String(repeating: section, count: 2_500)            // ≈ 256 KB, the preview's read limit
        let start = ContinuousClock.now
        let r = render(source)
        XCTAssertGreaterThan(r.text.length, 100_000)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }
}
