import AppKit

/// An icon, a title and optionally a detail line, a spinner and a button (cloud Download / Try Again): every preview
/// state that isn't Quick Look or text.
@MainActor
final class PreviewMessageView: NSView {
    private let image = NSImageView()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    let button = NSButton(title: "", target: nil, action: nil)
    var onButton: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(AXID.previewMessage)

        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.isSelectable = false
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(buttonPressed(_:))
        button.setAccessibilityIdentifier(AXID.previewDownload)

        let stack = NSStackView(views: [image, titleLabel, detailLabel, spinner, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("PreviewMessageView is created in code") }

    var title: String { titleLabel.stringValue }
    var buttonTitle: String? { button.isHidden ? nil : button.title }

    func show(symbol: String, title: String, detail: String? = nil, button buttonTitle: String? = nil, spinner showsSpinner: Bool = false) {
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        image.setAccessibilityLabel(title)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail?.isEmpty ?? true
        if showsSpinner { spinner.isHidden = false; spinner.startAnimation(nil) } else { spinner.stopAnimation(nil); spinner.isHidden = true }
        button.title = buttonTitle ?? ""
        button.isHidden = buttonTitle == nil
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
    }

    @objc private func buttonPressed(_ sender: Any?) { onButton?() }
}
