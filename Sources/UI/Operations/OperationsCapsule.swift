import AppKit
import QuartzCore
import Core

/// What the status-bar capsule shows (§6.2): hidden without visible jobs (those running ≥ 1 s or waiting).
struct CapsuleState: Equatable {
    var isVisible = false
    var percentText = ""
    var fraction: Double?
    var isWaiting = false
    var accessibilityLabel = ""

    @MainActor
    static func make(visible jobs: [JobSnapshot], overallFraction: Double?) -> CapsuleState {
        guard !jobs.isEmpty else { return CapsuleState() }
        var state = CapsuleState()
        state.isVisible = true
        state.fraction = overallFraction
        // Rounded down: never 100% before the last job finishes.
        state.percentText = overallFraction.map { String(format: L10n.string("%lld%%"), Int64(($0 * 100).rounded(.down))) } ?? ""
        state.isWaiting = jobs.contains { $0.state == .waitingForUser }
        var parts = [jobs.count == 1 ? L10n.string("1 operation in progress")
                                     : String(format: L10n.string("%lld operations in progress"), jobs.count)]
        if !state.percentText.isEmpty { parts.append(state.percentText) }
        if state.isWaiting { parts.append(L10n.string("waiting for your answer")) }
        state.accessibilityLabel = parts.joined(separator: ", ")
        return state
    }
}

/// Status-bar capsule: an accent-tinted pill with a progress ring and the overall %. Click: shows or hides the
/// window's progress card. One per window; all show the app's jobs. It pulses when the card is closed, so the user
/// sees where the card went.
@MainActor
final class OperationsCapsule: NSView {
    private let context: UIContext
    let button = CapsuleButton(title: "", target: nil, action: nil)
    private(set) var state = CapsuleState()
    private var loop: ObservationLoop?
    private var pulseLoop: ObservationLoop?
    private var seenCloseCount: Int
    private var ticker: Task<Void, Never>?
    /// Number of pulses run (tests read it).
    private(set) var pulses = 0

    init(context: UIContext) {
        self.context = context
        seenCloseCount = context.operationsUI.card.closeCount
        super.init(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(toggleCard(_:))
        button.setAccessibilityIdentifier(AXID.operationsCapsule)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: 17),
            heightAnchor.constraint(greaterThanOrEqualTo: button.heightAnchor),
        ])
        loop = ObservationLoop { [weak self] in
            _ = self?.context.environment.operations.jobs
        } onChange: { [weak self] in
            self?.refresh()
        }
        pulseLoop = ObservationLoop { [weak self] in
            _ = self?.context.operationsUI.card.closeCount
        } onChange: { [weak self] in
            guard let self else { return }
            let count = self.context.operationsUI.card.closeCount
            guard count != self.seenCloseCount else { return }
            self.seenCloseCount = count
            self.pulse()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("OperationsCapsule is created in code") }

    func refresh() {
        let operations = context.environment.operations
        context.operationsUI.card.update(jobs: operations.jobs)
        state = CapsuleState.make(visible: operations.visibleJobs, overallFraction: operations.overallFraction)
        isHidden = !state.isVisible
        let tint: NSColor = state.isWaiting ? .systemOrange : .controlAccentColor
        button.attributedTitle = NSAttributedString(string: state.percentText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: tint,
        ])
        button.image = state.isWaiting
            ? NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            : CapsuleRing.image(fraction: state.fraction, tint: tint)
        button.contentTintColor = tint
        button.layer?.backgroundColor = tint.withAlphaComponent(Self.restAlpha).cgColor
        button.setAccessibilityLabel(state.accessibilityLabel)
        button.toolTip = context.operationsUI.card.isOpen ? state.accessibilityLabel
            : [state.accessibilityLabel, L10n.string("Click to show progress")].joined(separator: " — ")
        // visibleJobs and the card's 4 s rule depend on time, so poll while any job exists.
        if operations.jobs.isEmpty {
            ticker?.cancel()
            ticker = nil
        } else if ticker == nil, window != nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    self.refresh()
                }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ticker?.cancel()
            ticker = nil
        } else {
            refresh()
        }
    }

    @objc private func toggleCard(_ sender: Any?) {
        context.operationsUI.card.toggle(jobs: context.environment.operations.jobs)
        refresh()
    }

    private static let restAlpha: CGFloat = 0.16

    /// Two flashes of the pill's tint; with motion allowed it also swells a little around its centre.
    private func pulse() {
        pulses += 1
        guard !isHidden, let layer = button.layer else { return }
        let tint: NSColor = state.isWaiting ? .systemOrange : .controlAccentColor
        let rest = tint.withAlphaComponent(Self.restAlpha).cgColor, lit = tint.withAlphaComponent(0.5).cgColor
        let flash = CAKeyframeAnimation(keyPath: "backgroundColor")
        flash.values = [rest, lit, rest, lit, rest]
        flash.duration = 1.0
        layer.add(flash, forKey: "pulse.color")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Layer-backed views keep their anchor at the origin: scale about the centre by hand.
        let c = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        func scaled(_ k: CGFloat) -> NSValue {
            var t = CATransform3DMakeTranslation(c.x, c.y, 0)
            t = CATransform3DScale(t, k, k, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(t, -c.x, -c.y, 0))
        }
        let swell = CAKeyframeAnimation(keyPath: "transform")
        swell.values = [scaled(1), scaled(1.25), scaled(1), scaled(1.15), scaled(1)]
        swell.duration = 1.0
        swell.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        layer.add(swell, forKey: "pulse.scale")
    }
}

/// A borderless button with room around its content for the pill background.
final class CapsuleButton: NSButton {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 14, height: size.height)
    }
}

/// The capsule's progress ring: a faint track and an arc that fills clockwise from the top.
enum CapsuleRing {
    static let side: CGFloat = 12

    @MainActor
    static func image(fraction: Double?, tint: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.25, dy: 1.25)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            tint.withAlphaComponent(0.25).setStroke()
            track.stroke()
            // Unknown total: a quarter arc, so the ring still reads as "working".
            let f = min(1, max(0, fraction ?? 0.25))
            guard f > 0 else { return true }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: inset.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            tint.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
