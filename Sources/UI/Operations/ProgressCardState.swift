import Foundation
import Observation
import Core

/// Whether the progress card is open. One state for the app: every window's card and capsule follow it.
///
/// The card opens on its own once a job has run `autoOpenDelay` (shorter jobs show only the capsule). Closing it
/// keeps it closed for the jobs already running; a new job that runs that long opens it again. The capsule opens
/// and closes it by hand. It hides when the last job finishes.
@MainActor @Observable
final class ProgressCardState {
    private(set) var isOpen = false
    /// Bumped each time the user closes the card, so every capsule pulses once and shows where the card went.
    private(set) var closeCount = 0
    @ObservationIgnored var autoOpenDelay: Duration = .seconds(4)
    /// Jobs that may no longer open the card on their own: they already opened it, or were running when it was
    /// opened or closed by hand.
    @ObservationIgnored private var settled: Set<JobID> = []

    /// Called on every capsule tick with all current jobs (idempotent; several windows call it).
    func update(jobs: [JobSnapshot], now: ContinuousClock.Instant = .now) {
        settled.formIntersection(jobs.map(\.id))
        guard !jobs.isEmpty else {
            if isOpen { isOpen = false }
            return
        }
        let due = jobs.filter { !settled.contains($0.id) && now - $0.startedAt >= autoOpenDelay }
        guard !due.isEmpty else { return }
        settled.formUnion(due.map(\.id))
        if !isOpen { isOpen = true }
    }

    func close(jobs: [JobSnapshot]) {
        guard isOpen else { return }
        settled.formUnion(jobs.map(\.id))
        isOpen = false
        closeCount += 1
    }

    /// The capsule's click.
    func toggle(jobs: [JobSnapshot]) {
        if isOpen {
            close(jobs: jobs)
        } else if !jobs.isEmpty {
            settled.formUnion(jobs.map(\.id))
            isOpen = true
        }
    }

    struct Rows: Equatable { var shown: Int; var hidden: Int }
    nonisolated static let collapsedRowLimit = 3

    /// The card lists up to three jobs, then "+N more" until expanded.
    nonisolated static func rows(count: Int, expanded: Bool) -> Rows {
        let shown = expanded ? count : min(count, collapsedRowLimit)
        return Rows(shown: shown, hidden: count - shown)
    }
}
