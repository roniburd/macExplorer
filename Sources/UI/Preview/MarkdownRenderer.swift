import AppKit
import Markdown

extension NSAttributedString.Key {
    /// A heading's GitHub-style anchor slug (`#slug` links scroll to it).
    static let macxAnchor = NSAttributedString.Key("macx.markdown.anchor")
    /// An image placeholder: its index in `MarkdownRendering.images`.
    static let macxImage = NSAttributedString.Key("macx.markdown.image")
}

/// An image a rendered Markdown file references. Local ones load on the read lanes; remote ones only on a click.
struct MarkdownImage: Equatable {
    let index: Int
    let url: URL
    let alt: String
    var isRemote: Bool { !url.isFileURL }
}

struct MarkdownRendering {
    let text: NSAttributedString
    let images: [MarkdownImage]
}

/// Markdown (CommonMark + GitHub tables, task lists, strikethrough, autolinks; parsed by swift-markdown) to an
/// attributed string for the preview pane's text view. Nothing here touches the file system or the network: links
/// and images are resolved against the file's folder but never opened or read.
@MainActor
final class MarkdownRenderer {
    static let anchorScheme = "x-macx-anchor"
    static let loadImageScheme = "x-macx-load-image"
    static let maxImages = 50

    static func render(_ source: String, fileURL: URL, fontSize: CGFloat = 12) -> MarkdownRendering {
        let renderer = MarkdownRenderer(fileURL: fileURL, fontSize: fontSize)
        renderer.blocks(Document(parsing: source))
        // Trailing paragraph breaks only add blank space under the last block.
        while renderer.out.string.hasSuffix("\n") { renderer.out.deleteCharacters(in: NSRange(location: renderer.out.length - 1, length: 1)) }
        return MarkdownRendering(text: renderer.out, images: renderer.images)
    }

    private struct Inline {
        var bold = false, italic = false, mono = false, strike = false
        var link: URL?
        var size: CGFloat
        var color: NSColor = .labelColor
    }

    private let fileURL: URL
    private let fontSize: CGFloat
    private let out = NSMutableAttributedString()
    private var images: [MarkdownImage] = []
    private var slugCounts: [String: Int] = [:]
    private var indent: CGFloat = 0
    private var quoteDepth = 0
    private var tight = false
    /// The bullet or number the next paragraph starts with (the first block of a list item).
    private var pendingMarker: String?

    private init(fileURL: URL, fontSize: CGFloat) {
        self.fileURL = fileURL
        self.fontSize = fontSize
    }

    // MARK: Blocks

    private func blocks(_ parent: any Markup) {
        for child in parent.children { block(child) }
    }

    private func block(_ markup: any Markup) {
        switch markup {
        case let heading as Heading:
            let sizes: [CGFloat] = [fontSize + 10, fontSize + 6, fontSize + 3, fontSize + 1, fontSize, fontSize - 1]
            let style = Inline(bold: true, size: sizes[min(max(heading.level, 1), 6) - 1])
            let start = out.length
            inlines(heading, style)
            let slug = uniqueSlug(Self.slug(heading.plainText))
            if out.length > start { out.addAttribute(.macxAnchor, value: slug, range: NSRange(location: start, length: out.length - start)) }
            endParagraph(from: start, before: start == 0 ? 0 : 10, after: 4)
        case let paragraph as Paragraph:
            let start = beginParagraph()
            inlines(paragraph, base())
            endParagraph(from: start, after: tight ? 2 : 8)
        case let code as CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            codeBlock(text)
        case let html as HTMLBlock:
            htmlBlock(html.rawHTML)
        case let quote as BlockQuote:
            indent += 14; quoteDepth += 1
            blocks(quote)
            indent -= 14; quoteDepth -= 1
        case let list as UnorderedList:
            listItems(Array(list.listItems), ordered: nil)
        case let list as OrderedList:
            listItems(Array(list.listItems), ordered: Int(list.startIndex))
        case is ThematicBreak:
            let start = out.length
            out.append(NSAttributedString(string: String(repeating: "─", count: 24),
                                          attributes: [.font: font(Inline(size: fontSize)), .foregroundColor: NSColor.tertiaryLabelColor]))
            endParagraph(from: start, before: 4, after: 8, alignment: .center)
        case let table as Table:
            self.table(table)
        default:
            blocks(markup)
        }
    }

    private func listItems(_ items: [ListItem], ordered start: Int?) {
        let wasTight = tight
        tight = true
        let depth = Int(indent / 18)
        let bullets = ["•", "◦", "‣"]
        for (offset, item) in items.enumerated() {
            var marker = start.map { "\($0 + offset)." } ?? bullets[depth % bullets.count]
            switch item.checkbox {
            case .checked?: marker = "☑"
            case .unchecked?: marker = "□"
            case nil: break
            }
            pendingMarker = marker
            indent += 18
            let before = out.length
            blocks(item)
            if out.length == before, let m = pendingMarker {             // an empty item still shows its marker
                pendingMarker = nil
                let s = out.length
                out.append(NSAttributedString(string: m + "\t", attributes: attributes(base())))
                endParagraph(from: s, after: 2, hanging: true)
            }
            indent -= 18
        }
        tight = wasTight
        // The list's last paragraph gets normal spacing below it.
        if !wasTight, out.length > 0 { bumpLastParagraphSpacing(8) }
    }

    private func codeBlock(_ text: String) {
        let start = out.length
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
            .foregroundColor: quoteDepth > 0 ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
        ]
        // Line separators keep the whole block one paragraph (one spacing above and below).
        out.append(NSAttributedString(string: text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attrs))
        endParagraph(from: start, before: 2, after: tight ? 4 : 10, extraIndent: 8, wraps: false)
    }

    private func table(_ table: Table) {
        let head = Array(table.head.cells).map { $0.plainText }
        let rows = Array(table.body.rows).map { Array($0.cells).map { $0.plainText } }
        let columns = max(head.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return }
        var widths = [Int](repeating: 1, count: columns)
        for row in [head] + rows { for (i, cell) in row.enumerated() { widths[i] = min(max(widths[i], cell.count), 40) } }
        let alignments = table.columnAlignments
        func pad(_ s: String, _ i: Int) -> String {
            let gap = max(widths[i] - s.count, 0)
            switch i < alignments.count ? alignments[i] : nil {
            case .right?: return String(repeating: " ", count: gap) + s
            case .center?: return String(repeating: " ", count: gap / 2) + s + String(repeating: " ", count: gap - gap / 2)
            default: return s + String(repeating: " ", count: gap)
            }
        }
        func line(_ row: [String]) -> String {
            (0..<columns).map { pad($0 < row.count ? row[$0] : "", $0) }.joined(separator: " │ ")
        }
        let mono = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
        let start = out.length
        out.append(NSAttributedString(string: line(head), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─")
        var body = "\u{2028}" + rule
        for row in rows { body += "\u{2028}" + line(row) }
        out.append(NSAttributedString(string: body, attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        endParagraph(from: start, before: 2, after: 10, wraps: false)
    }

    /// Raw HTML (common in READMEs: centred logos, badges): `<img>` becomes an image, `<br>` a line break, every
    /// other tag is dropped and its text kept.
    private func htmlBlock(_ html: String) {
        let start = beginParagraph()
        let imageCount = images.count
        let contentStart = out.length
        htmlInline(html, base())
        // HTML whitespace and line breaks around the content add nothing (a centred logo is just the logo).
        let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}"))
        while out.length > contentStart, let last = out.string.unicodeScalars.last, blank.contains(last) {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        while out.length > contentStart, let first = (out.string as NSString).substring(with: NSRange(location: contentStart, length: 1)).unicodeScalars.first,
              blank.contains(first) {
            out.deleteCharacters(in: NSRange(location: contentStart, length: 1))
        }
        if images.count == imageCount, out.length == contentStart {
            out.deleteCharacters(in: NSRange(location: start, length: out.length - start))   // only tags or comments
            return
        }
        endParagraph(from: start, after: tight ? 2 : 8)
    }

    // MARK: Inlines

    private func base() -> Inline { Inline(size: fontSize, color: quoteDepth > 0 ? .secondaryLabelColor : .labelColor) }

    private func inlines(_ parent: any Markup, _ style: Inline) {
        for child in parent.children { inline(child, style) }
    }

    private func inline(_ markup: any Markup, _ style: Inline) {
        switch markup {
        case let text as Markdown.Text:
            append(text.string, style)
        case is SoftBreak:
            append(" ", style)
        case is LineBreak:
            append("\u{2028}", style)
        case let code as InlineCode:
            var s = style; s.mono = true
            out.append(NSAttributedString(string: code.code, attributes: attributes(s).merging(
                [.backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)]) { _, new in new }))
        case let e as Emphasis:
            var s = style; s.italic = true; inlines(e, s)
        case let e as Strong:
            var s = style; s.bold = true; inlines(e, s)
        case let e as Strikethrough:
            var s = style; s.strike = true; inlines(e, s)
        case let link as Markdown.Link:
            var s = style
            s.link = link.destination.flatMap { Self.resolve($0, against: fileURL) }
            inlines(link, s)
        case let image as Markdown.Image:
            self.image(source: image.source, alt: image.plainText, style)
        case let html as InlineHTML:
            htmlInline(html.rawHTML, style)
        default:
            if markup.childCount > 0 { inlines(markup, style) } else { append(markup.format(), style) }
        }
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<(/?)([A-Za-z][A-Za-z0-9-]*)([^>]*)>|<!--[\s\S]*?-->"#)
    private static let attributePattern = try! NSRegularExpression(pattern: #"([A-Za-z-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#)

    private func htmlInline(_ html: String, _ style: Inline) {
        let ns = html as NSString
        var cursor = 0
        var style = style
        for match in Self.tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                append(Self.htmlText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))), style)
            }
            cursor = match.range.location + match.range.length
            guard match.range(at: 2).location != NSNotFound else { continue }         // a comment
            let closing = ns.substring(with: match.range(at: 1)) == "/"
            let tag = ns.substring(with: match.range(at: 2)).lowercased()
            let attrs = Self.htmlAttributes(ns.substring(with: match.range(at: 3)))
            switch (tag, closing) {
            case ("br", _): append("\u{2028}", style)
            case ("img", false): image(source: attrs["src"], alt: attrs["alt"] ?? "", style)
            case ("a", false): style.link = attrs["href"].flatMap { Self.resolve($0, against: fileURL) }
            case ("a", true): style.link = nil
            case ("b", _), ("strong", _): style.bold = !closing
            case ("i", _), ("em", _): style.italic = !closing
            case ("code", _), ("kbd", _): style.mono = !closing
            case ("p", true), ("div", true), ("h1", true), ("h2", true), ("h3", true): append("\u{2028}", style)
            default: break
            }
        }
        if cursor < ns.length { append(Self.htmlText(ns.substring(from: cursor)), style) }
    }

    private static func htmlAttributes(_ s: String) -> [String: String] {
        let ns = s as NSString
        var result: [String: String] = [:]
        for m in attributePattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let value = (3...5).lazy.map { m.range(at: $0) }.first { $0.location != NSNotFound }.map { ns.substring(with: $0) } ?? ""
            result[ns.substring(with: m.range(at: 1)).lowercased()] = decodeEntities(value)
        }
        return result
    }

    /// HTML text: runs of whitespace (newlines included) are one space, as a browser shows them.
    private static func htmlText(_ s: String) -> String {
        decodeEntities(s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// A placeholder for the image (its alt text); the pane replaces it with the picture once loaded.
    private func image(source: String?, alt: String, _ style: Inline) {
        guard let source, let url = Self.resolve(source, against: fileURL), url.scheme != Self.anchorScheme,
              url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? ""), images.count < Self.maxImages else {
            if !alt.isEmpty { append(alt, style) }
            return
        }
        let index = images.count
        images.append(MarkdownImage(index: index, url: url, alt: alt))
        let name = alt.isEmpty ? url.lastPathComponent : alt
        var s = style
        s.color = .secondaryLabelColor
        let label: String
        if url.isFileURL {
            label = "🖼 " + name
        } else {
            label = "🖼 " + String(format: L10n.string("%@ (click to load)"), name)
            s.link = URL(string: "\(Self.loadImageScheme):\(index)")
        }
        var attrs = attributes(s)
        attrs[.macxImage] = index
        out.append(NSAttributedString(string: label, attributes: attrs))
    }

    private func append(_ string: String, _ style: Inline) {
        guard !string.isEmpty else { return }
        out.append(NSAttributedString(string: string, attributes: attributes(style)))
    }

    private func attributes(_ style: Inline) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font(style), .foregroundColor: style.color]
        if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = style.link { attrs[.link] = link }
        return attrs
    }

    private func font(_ style: Inline) -> NSFont {
        var font = style.mono ? NSFont.monospacedSystemFont(ofSize: style.size - 1, weight: style.bold ? .semibold : .regular)
                              : NSFont.systemFont(ofSize: style.size, weight: style.bold ? .semibold : .regular)
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    // MARK: Paragraphs

    /// Starts a paragraph-like block; the pending list marker (if any) goes first.
    private func beginParagraph() -> Int {
        let start = out.length
        if let marker = pendingMarker {
            out.append(NSAttributedString(string: marker + "\t", attributes: attributes(base())))
        }
        return start
    }

    private func endParagraph(from start: Int, before: CGFloat = 0, after: CGFloat, alignment: NSTextAlignment = .natural,
                              extraIndent: CGFloat = 0, wraps: Bool = true, hanging: Bool? = nil) {
        let hasMarker = hanging ?? (pendingMarker != nil)
        pendingMarker = nil
        out.append(NSAttributedString(string: "\n", attributes: attributes(base())))
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        let left = indent + extraIndent
        if hasMarker {
            p.firstLineHeadIndent = left - 18
            p.headIndent = left
            p.tabStops = [NSTextTab(textAlignment: .left, location: left)]
        } else {
            p.firstLineHeadIndent = left
            p.headIndent = left
        }
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: out.length - start))
    }

    private func bumpLastParagraphSpacing(_ spacing: CGFloat) {
        let at = out.length - 1
        guard let p = out.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle,
              let copy = p.mutableCopy() as? NSMutableParagraphStyle else { return }
        copy.paragraphSpacing = spacing
        // Only the last paragraph: equal styles of earlier items merge into one attribute run.
        out.addAttribute(.paragraphStyle, value: copy, range: (out.string as NSString).paragraphRange(for: NSRange(location: at, length: 0)))
    }

    // MARK: Links and anchors

    /// A link or image destination: web and mail links as-is, `#heading` as an anchor in this file, and paths
    /// relative to the Markdown file's folder as file URLs. Anything else (javascript:, custom schemes) is no link.
    static func resolve(_ destination: String, against fileURL: URL) -> URL? {
        let d = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return nil }
        if d.hasPrefix("#") { return anchorURL(slug(String(d.dropFirst()).removingPercentEncoding ?? String(d.dropFirst()))) }
        if let colon = d.firstIndex(of: ":"), d[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
           d[..<colon].count > 1 {
            guard let url = URL(string: d), let scheme = url.scheme?.lowercased() else { return nil }
            switch scheme {
            case "http", "https", "mailto": return url
            case "file": return url.isFileURL ? url.standardizedFileURL : nil
            default: return nil
            }
        }
        var path = d
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<cut]) }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(filePath: path) : fileURL.deletingLastPathComponent().appending(path: path)
        return url.standardizedFileURL
    }

    static func anchorURL(_ slug: String) -> URL? {
        URL(string: "\(anchorScheme):\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)")
    }

    /// GitHub's heading anchors: lowercase, punctuation dropped, spaces to hyphens.
    static func slug(_ text: String) -> String {
        String(text.lowercased().compactMap { c -> Character? in
            if c == " " { return "-" }
            return c.isLetter || c.isNumber || c == "-" || c == "_" ? c : nil
        })
    }

    private func uniqueSlug(_ slug: String) -> String {
        let n = slugCounts[slug, default: 0]
        slugCounts[slug] = n + 1
        return n == 0 ? slug : "\(slug)-\(n)"
    }
}
