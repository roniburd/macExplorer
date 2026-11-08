import AppKit

/// The fast text preview (§11: "Text and code use a fast text preview of the first 256 KB"): a read-only, selectable
/// monospaced text view and a footer when the file was longer than the loaded prefix. Markdown files also get a
/// Rendered | Source switch and show formatted (`showRendered`), with clickable links.
@MainActor
final class TextPreviewView: NSView, NSTextViewDelegate {
    private let scrollView = NSScrollView()
    let textView = NSTextView()
    private let footer = NSTextField(labelWithString: L10n.string("preview.truncated"))
    let modeControl = NSSegmentedControl(labels: [L10n.string("Rendered"), L10n.string("Source")],
                                         trackingMode: .selectOne, target: nil, action: nil)
    /// The switch changed: true = Rendered.
    var onModeChange: ((Bool) -> Void)?
    /// A link in rendered Markdown was clicked; returns whether it was handled.
    var onLink: ((URL) -> Bool)?
    private static let plainFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    var footerHidden: Bool { footer.isHidden }
    var text: String { textView.string }
    var modeControlHidden: Bool { modeControl.isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.font = Self.plainFont
        textView.isAutomaticLinkDetectionEnabled = false
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true        // line wrapping on
        textView.setAccessibilityIdentifier(AXID.previewText)
        textView.setAccessibilityLabel(L10n.string("preview.pane"))

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.setAccessibilityIdentifier(AXID.previewTruncation)
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.isHidden = true

        modeControl.selectedSegment = 0
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityIdentifier(AXID.previewMarkdownMode)
        modeControl.isHidden = true

        let stack = NSStackView(views: [modeControl, scrollView, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("TextPreviewView is created in code") }

    /// Plain text (Source, or any text file). `markdown` shows the switch, set to Source.
    func show(_ text: String, truncated: Bool, markdown: Bool = false) {
        modeControl.isHidden = !markdown
        if markdown { modeControl.selectedSegment = 1 }
        if textView.isRichText || textView.string != text {
            textView.isRichText = false
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: Self.plainFont, .foregroundColor: NSColor.textColor]))
            textView.font = Self.plainFont
        }
        reset(truncated: truncated)
    }

    /// Rendered Markdown, with the switch set to Rendered.
    func showRendered(_ text: NSAttributedString, truncated: Bool) {
        modeControl.isHidden = false
        modeControl.selectedSegment = 0
        textView.isRichText = true
        textView.textStorage?.setAttributedString(text)
        reset(truncated: truncated)
    }

    private func reset(truncated: Bool) {
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        footer.isHidden = !truncated
    }

    func clear() {
        textView.isRichText = false
        textView.string = ""
        footer.isHidden = true
        modeControl.isHidden = true
    }

    /// The width an inline image may take.
    var imageWidthLimit: CGFloat {
        let width = scrollView.contentSize.width - textView.textContainerInset.width * 2 - 12
        return max(width, 80)
    }

    /// Swaps the placeholder of image `index` for the picture, scaled down to fit the pane. False when the
    /// placeholder is gone (the view shows something else).
    @discardableResult
    func replaceImage(_ index: Int, with image: NSImage) -> Bool {
        guard textView.isRichText, let storage = textView.textStorage else { return false }
        var target: NSRange?
        storage.enumerateAttribute(.macxImage, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? Int == index { target = range; stop.pointee = true }
        }
        guard let range = target, image.size.width > 0, image.size.height > 0 else { return false }
        let scale = min(1, imageWidthLimit / image.size.width, 2000 / image.size.height)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        var attrs = storage.attributes(at: range.location, effectiveRange: nil)
        if let link = attrs[.link] as? URL, link.scheme == MarkdownRenderer.loadImageScheme { attrs[.link] = nil }
        attrs[.macxImage] = nil
        let replacement = NSMutableAttributedString(attachment: attachment)
        replacement.addAttributes(attrs, range: NSRange(location: 0, length: replacement.length))
        storage.replaceCharacters(in: range, with: replacement)
        return true
    }

    /// Scrolls to the heading with this anchor slug; false when there is none.
    @discardableResult
    func scrollToAnchor(_ slug: String) -> Bool {
        guard let storage = textView.textStorage else { return false }
        var target: NSRange?
        storage.enumerateAttribute(.macxAnchor, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? String == slug { target = range; stop.pointee = true }
        }
        guard let range = target else { return false }
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
        return true
    }

    @objc private func modeChanged() { onModeChange?(modeControl.selectedSegment == 0) }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url else { return true }
        _ = onLink?(url)
        return true                                          // never let NSTextView open anything itself
    }
}
