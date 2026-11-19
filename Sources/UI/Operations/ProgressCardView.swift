import AppKit
import SwiftUI
import Core

/// The progress card: a floating card at the bottom-right of the file list with one row per visible job. It opens
/// and closes with `ProgressCardState`; closing shrinks it into the status-bar capsule just below.
struct ProgressCardView: View {
    let operations: OperationsCenter
    let state: ProgressCardState
    let actions: JobActions
    /// Reports the card's frame (host coordinates, SwiftUI's top-left origin) so clicks elsewhere reach the list.
    var onCardFrame: (CGRect) -> Void = { _ in }
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 360
    static let inset: CGFloat = 12

    var body: some View {
        let jobs = operations.visibleJobs
        let shown = state.isOpen && !jobs.isEmpty
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            if shown {
                card(jobs)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { onCardFrame($0) }
                    .onDisappear { onCardFrame(.zero); expanded = false }
                    .padding(Self.inset)
                    .transition(transition)
            }
        }
        .coordinateSpace(.named(Self.space))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.1), value: shown)
    }

    private nonisolated static let space = "progressCardHost"

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        // In: rise from the status bar. Out: shrink into the capsule below the card's bottom-trailing corner.
        return .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                           removal: .scale(scale: 0.05, anchor: .bottomTrailing).combined(with: .opacity))
    }

    private func card(_ jobs: [JobSnapshot]) -> some View {
        let rows = ProgressCardState.rows(count: jobs.count, expanded: expanded)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: jobs.count == 1 ? L10n.string("1 operation in progress")
                                               : String(format: L10n.string("%lld operations in progress"), jobs.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { state.close(jobs: operations.jobs) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help(L10n.string("Hide (click the progress indicator in the status bar to show it again)"))
                    .accessibilityLabel(L10n.string("Hide"))
                    .accessibilityIdentifier(AXID.progressCardClose)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(jobs.prefix(rows.shown)) { job in
                        ProgressCardRow(model: JobRowModel(job), actions: actions)
                        if job.id != jobs.prefix(rows.shown).last?.id { Divider() }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            if rows.hidden > 0 || expanded && jobs.count > ProgressCardState.collapsedRowLimit {
                Button(expanded ? L10n.string("Show Less") : String(format: L10n.string("+%lld more"), rows.hidden)) {
                    expanded.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.progressCard)
    }
}

/// One job in the card: title, bar, "2 GB of 6 GB — 410 MB/s", time left, Pause/Resume and Cancel.
struct ProgressCardRow: View {
    let model: JobRowModel
    let actions: JobActions

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.isWaiting {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .accessibilityLabel(L10n.string("Waiting for your answer"))
                }
                Text(verbatim: model.title).font(.callout.weight(.medium)).lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(model.title)
                Spacer(minLength: 4)
                if model.canPause {
                    Button { actions.pause(model.id) } label: { Image(systemName: "pause.circle.fill") }
                        .buttonStyle(.borderless).help(L10n.string("Pause")).accessibilityLabel(L10n.string("Pause"))
                }
                if model.canResume {
                    Button { actions.resume(model.id) } label: { Image(systemName: "play.circle.fill") }
                        .buttonStyle(.borderless).help(L10n.string("Resume")).accessibilityLabel(L10n.string("Resume"))
                }
                if model.canCancel {
                    Button { actions.cancel(model.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help(L10n.string("Cancel")).accessibilityLabel(L10n.string("Cancel"))
                }
            }
            .font(.title3)
            if let fraction = model.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(verbatim: model.detailText)
                Spacer()
                if let eta = model.etaText { Text(verbatim: eta) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            if model.isWaiting {
                Button(L10n.string("Show")) { actions.showQuestion(model.id) }.controlSize(.small)
            }
        }
    }
}

extension JobRowModel {
    /// The card's detail line: the status while not running, else "2 GB of 6 GB — 410 MB/s" (or the item count).
    var detailText: String {
        if let statusText { return statusText }
        let amount = bytesText ?? countText ?? ""
        guard let speedText else { return amount }
        return amount.isEmpty ? speedText : amount + " — " + speedText
    }
}

/// Hosts the card over the file list. Only the card itself takes clicks; everywhere else they reach the list.
final class ProgressCardHostingView: NSHostingView<ProgressCardView> {
    /// The card's frame in SwiftUI coordinates (top-left origin); .zero while closed.
    var cardFrame: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !cardFrame.isEmpty else { return nil }
        let local = convert(point, from: superview)
        let y = isFlipped ? local.y : bounds.height - local.y
        guard cardFrame.contains(CGPoint(x: local.x, y: y)) else { return nil }
        return super.hitTest(point)
    }
}
