import AppKit

/// The fast text preview (§11: "Text and code use a fast text preview of the first 256 KB"): a read-only, selectable
/// monospaced text view and a footer when the file was longer than the loaded prefix.
@MainActor
final class TextPreviewView: NSView {
    private let scrollView = NSScrollView()
    let textView = NSTextView()
    private let footer = NSTextField(labelWithString: L10n.string("preview.truncated"))

    var footerHidden: Bool { footer.isHidden }
    var text: String { textView.string }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
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

        let stack = NSStackView(views: [scrollView, footer])
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

    func show(_ text: String, truncated: Bool) {
        if textView.string != text { textView.string = text }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        footer.isHidden = !truncated
    }

    func clear() {
        textView.string = ""
        footer.isHidden = true
    }
}
