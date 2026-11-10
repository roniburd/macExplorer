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
        var pendingErrors: [CheckedContinuation<ErrorResolution, Never>] = []
        var interceptErrors = false
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

    /// P4-23: a scenario with an `answerError` step answers errors itself (the error dialog is SwiftUI too); the
    /// dialog still shows on the origin window. Other scenarios keep the forwarded behaviour.
    func interceptErrors() { state.withLock { $0.interceptErrors = true } }
    var pendingErrorCount: Int { state.withLock { $0.pendingErrors.count } }

    /// Resolves the oldest pending error; false if none is pending.
    func answerError(_ resolution: ErrorResolution) -> Bool {
        let next = state.withLock { s -> CheckedContinuation<ErrorResolution, Never>? in
            s.pendingErrors.isEmpty ? nil : s.pendingErrors.removeFirst()
        }
        next?.resume(returning: resolution)
        return next != nil
    }

    func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        guard state.withLock({ $0.interceptErrors }) else { return await forward.resolveError(error, job: job) }
        let forward = self.forward
        let presenter = Task { _ = await forward.resolveError(error, job: job) }   // shows the dialog; answer ignored
        let resolution = await withCheckedContinuation { continuation in
            state.withLock { $0.pendingErrors.append(continuation) }
        }
        presenter.cancel()
        return resolution
    }

    func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        await forward.confirmInsufficientSpace(shortfall, job: job)
    }

    func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        await forward.confirmPermanentDeleteWithoutTrash(urls, job: job)
    }
}
