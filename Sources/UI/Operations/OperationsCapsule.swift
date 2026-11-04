import AppKit
import SwiftUI
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

/// Status-bar capsule (icon + overall %). Click: popover with the job list. One per window; all show the app's jobs.
@MainActor
final class OperationsCapsule: NSView {
    private let context: UIContext
    let button = NSButton(title: "", target: nil, action: nil)
    private(set) var state = CapsuleState()
    private var loop: ObservationLoop?
    private var ticker: Task<Void, Never>?
    private var popover: NSPopover?

    init(context: UIContext) {
        self.context = context
        super.init(frame: .zero)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.setAccessibilityIdentifier(AXID.operationsCapsule)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: button.heightAnchor),
        ])
        loop = ObservationLoop { [weak self] in
            _ = self?.context.environment.operations.jobs
        } onChange: { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("OperationsCapsule is created in code") }

    func refresh() {
        let operations = context.environment.operations
        state = CapsuleState.make(visible: operations.visibleJobs, overallFraction: operations.overallFraction)
        isHidden = !state.isVisible
        button.title = state.percentText
        button.image = NSImage(systemSymbolName: state.isWaiting ? "exclamationmark.circle.fill" : "arrow.triangle.2.circlepath",
                               accessibilityDescription: nil)
        button.contentTintColor = state.isWaiting ? .systemOrange : nil
        button.setAccessibilityLabel(state.accessibilityLabel)
        button.toolTip = state.accessibilityLabel
        // visibleJobs depends on time (the 1 s rule), so poll while any job exists.
        if operations.jobs.isEmpty {
            ticker?.cancel()
            ticker = nil
            popover?.performClose(nil)
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

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: context.operationsUI.listView())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        self.popover = popover
    }
}
