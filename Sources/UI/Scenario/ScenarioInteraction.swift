import Core
import Foundation
import Synchronization

/// Scenario-only FileOpInteraction decorator, installed by ScenarioDriver around the real router.
/// Conflicts are still forwarded, so InteractionRouter presents the real dialog on the origin window (the
/// scenario checks the sheet). The answer comes from the scenario's `answerConflict` step, because SwiftUI
/// dialogs expose no in-process accessibility tree to press (Contract note C4). Errors, the space
/// shortfall and no-trash prompts are forwarded unchanged.
final class ScenarioInteraction: FileOpInteraction {
    private struct State {
        var pending: [CheckedContinuation<ConflictResolution, Never>] = []
        var asked: Int = 0
    }
    private let forward: any FileOpInteraction
    private let state = Mutex(State())

    init(forwardingTo forward: any FileOpInteraction) { self.forward = forward }

    var pendingCount: Int { state.withLock { $0.pending.count } }
    var askedCount: Int { state.withLock { $0.asked } }

    /// Resolves the oldest pending conflict; false if none is pending.
    func answer(_ resolution: ConflictResolution) -> Bool {
        let next = state.withLock { s -> CheckedContinuation<ConflictResolution, Never>? in
            s.pending.isEmpty ? nil : s.pending.removeFirst()
        }
        next?.resume(returning: resolution)
        return next != nil
    }

    func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
        let forward = self.forward
        let presenter = Task { _ = await forward.resolveConflict(conflict, job: job) }   // shows the dialog; answer ignored
        let resolution = await withCheckedContinuation { continuation in
            state.withLock {
                $0.pending.append(continuation)
                $0.asked += 1
            }
        }
        presenter.cancel()
        return resolution
    }

    func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        await forward.resolveError(error, job: job)
    }

    func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        await forward.confirmInsufficientSpace(shortfall, job: job)
    }

    func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        await forward.confirmPermanentDeleteWithoutTrash(urls, job: job)
    }
}
