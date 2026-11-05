import AppKit
import SwiftUI
import Core

/// The badge's copy for each update state (spec §3.1–3.3). `pill` is nil when nothing is shown.
@MainActor enum UpdateBadgeText {
    static func pill(_ s: UpdateState) -> String? {
        switch s {
        case .idle: nil
        case .checking: L10n.string("Checking…")
        case .downloading: L10n.string("Downloading Update…")
        case .readyToRestart: L10n.string("Restart to Update")
        case .upToDate: L10n.string("Up to Date")
        case .failed: L10n.string("Update Problem")
        }
    }

    static func headline(_ s: UpdateState) -> String {
        switch s {
        case .idle: ""
        case .checking: L10n.string("Checking for updates…")
        case .downloading(let v, _, _): String(format: L10n.string("Downloading MacExplorer %@…"), v)
        case .readyToRestart(let v, _): String(format: L10n.string("MacExplorer %@ is ready"), v)
        case .upToDate(let v): String(format: L10n.string("You're up to date (%@)"), v)
        case .failed(let e, _):
            switch e {
            case .verificationFailed: L10n.string("This update couldn't be verified and wasn't installed.")
            case .notInApplications: L10n.string("Move MacExplorer to the Applications folder to get updates.")
            case .offline: L10n.string("Couldn't check for updates. You're offline.")
            case .network(let m), .other(let m): String(format: L10n.string("Couldn't check for updates: %@"), m)
            }
        }
    }

    static func detail(_ s: UpdateState) -> String? {
        guard case .downloading(_, let f?, _) = s else { return nil }
        return f.formatted(.percent.precision(.fractionLength(0)))   // locale-aware ("50 %" in some locales)
    }
}

/// Whether the badge's popover should be / is on screen. Held by the toolbar item so a popover request is honoured
/// even when it arrives before the (hidden) badge's SwiftUI view is mounted (review of Task 8).
@MainActor @Observable final class UpdateBadgePresenter {
    /// Drives `.popover(isPresented:)`.
    var isPresented = false
    /// True while the popover content is on screen.
    var isShown = false
}

/// The pill and its popover (spec §3.1–3.2).
struct UpdateBadgeView: View {
    let model: UpdateModel
    @Bindable var presenter: UpdateBadgePresenter

    var body: some View {
        Button { presenter.isPresented = true } label: {
            Text(UpdateBadgeText.pill(model.state) ?? "")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(isReady ? 1 : 0.18)))
                .foregroundStyle(isReady ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $presenter.isPresented, arrowEdge: .bottom) { popover }
        .onChange(of: presenter.isPresented) { _, presented in
            if !presented { model.acknowledge() }
        }
    }

    private var isReady: Bool { if case .readyToRestart = model.state { true } else { false } }

    @ViewBuilder private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(UpdateBadgeText.headline(model.state)).font(.headline).fixedSize(horizontal: false, vertical: true)
            if case .downloading(_, let f, _) = model.state {
                if let f { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                if let detail = UpdateBadgeText.detail(model.state) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if case .readyToRestart(_, let notes) = model.state {
                if let notes { Link(L10n.string("What's New"), destination: notes) }
                HStack {
                    Spacer()
                    Button(L10n.string("Later")) { presenter.isPresented = false }
                    Button(L10n.string("Restart Now")) { presenter.isPresented = false; model.restartNow() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        // Evidence that the popover is really on screen (`UpdateBadgeItem.isPopoverShown`).
        .onAppear { presenter.isShown = true }
        .onDisappear { presenter.isShown = false }
    }
}

/// Hosts the badge and reports when it joins a window (a hidden toolbar item's view is not in the window).
final class UpdateBadgeHostingView: NSHostingView<UpdateBadgeView> {
    var onWindowChange: (@MainActor () -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

/// Toolbar item at the trailing edge; hidden while nothing is worth showing.
@MainActor final class UpdateBadgeItem: NSToolbarItem {
    private let model: UpdateModel
    private let presenter = UpdateBadgePresenter()
    private var observation: UpdateObservation?
    private var requestLoop: ObservationLoop?
    /// The last `model.popoverRequest` this badge has dealt with (presented, or left to another window's badge).
    private var handledRequest: Int
    /// True while this badge's popover is on screen (tests and the scenario runner read it).
    var isPopoverShown: Bool { presenter.isShown }

    init(model: UpdateModel) {
        self.model = model
        handledRequest = model.popoverRequest   // a new window never replays an older check's popover
        super.init(itemIdentifier: ToolbarController.updateID)
        let host = UpdateBadgeHostingView(rootView: UpdateBadgeView(model: model, presenter: presenter))
        host.setAccessibilityIdentifier(AXID.updateBadge)
        view = host
        label = L10n.string("Update")
        paletteLabel = label
        visibilityPriority = .high
        isHidden = !model.state.isBadgeVisible
        observation = model.addObserver { [weak self] state in self?.isHidden = !state.isBadgeVisible }
        // A user-initiated check bumps `popoverRequest` and un-hides the badge in the same turn, before its view is
        // in the window, so an `.onChange` inside the view never sees it (review of Task 8). The item watches the
        // counter itself and re-checks once the view joins a window.
        requestLoop = ObservationLoop({ [weak model] in _ = model?.popoverRequest },
                                      onChange: { [weak self] in self?.schedulePopoverRequest() })
        host.onWindowChange = { [weak self] in self?.schedulePopoverRequest() }
    }

    /// Defers to the next main-actor turn so the toolbar has laid the un-hidden item out first.
    private func schedulePopoverRequest() {
        Task { @MainActor [weak self] in self?.handlePopoverRequest() }
    }

    private func handlePopoverRequest() {
        let request = model.popoverRequest
        guard request != handledRequest, !isHidden, view?.window != nil else { return }   // not mounted yet: wait
        handledRequest = request
        if isFrontmostBadge { presenter.isPresented = true }
    }

    /// A user-initiated check opens the popover of exactly one badge: the one in the frontmost window that has
    /// one (the key browser window, or the most recent one while Settings is in front).
    private var isFrontmostBadge: Bool {
        guard let window = view?.window else { return false }
        let front = NSApp.orderedWindows.first { candidate in
            candidate.isVisible && (candidate.toolbar?.items.contains { $0.itemIdentifier == ToolbarController.updateID } ?? false)
        }
        return front === window
    }
}
