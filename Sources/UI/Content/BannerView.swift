// Sources/UI/Content/BannerView.swift
import AppKit
import Core

/// Non-modal banner (§4.3) shown above the list, e.g. "'X' was moved or deleted". The text comes from
/// SessionEvent.banner, already localized by BrowserSession.
final class BannerView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dismiss = NSButton()
    var currentText: String? { isHidden ? nil : label.stringValue }

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(AXID.banner)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemYellow
        label.lineBreakMode = .byTruncatingMiddle
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.string("Dismiss"))
        dismiss.setAccessibilityLabel(L10n.string("Dismiss"))
        dismiss.bezelStyle = .accessoryBarAction
        dismiss.isBordered = false
        dismiss.target = self
        dismiss.action = #selector(dismissPressed(_:))
        let stack = NSStackView(views: [icon, label, dismiss])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("BannerView is created in code") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    func show(_ text: String) {
        label.stringValue = text
        isHidden = false
    }

    func hide() { isHidden = true }

    @objc private func dismissPressed(_ sender: Any?) { hide() }
}
