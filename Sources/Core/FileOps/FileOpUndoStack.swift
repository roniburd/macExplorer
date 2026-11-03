import Foundation
import MacxFS

/// The app-wide file-operation undo stack (§6.6). One explicit undo group per completed undoable job; undo and
/// redo run as jobs (`.undo(record)` / `.redo(record)`, registersUndo false) on the shared FileOpQueue.
@MainActor
public final class FileOpUndoStack {
    /// UndoManager target for one job and its undo/redo chain. UndoManager does not retain its targets (a released
    /// target crashes `undo()`), so the stack keeps every live chain for the session (§6.6 "session only").
    final class Chain {
        let actionName: String
        init(actionName: String) { self.actionName = actionName }
    }
    enum Direction: Sendable { case undo, redo }

    public let undoManager: UndoManager
    private let queue: FileOpQueue
    private var chains: [ObjectIdentifier: Chain] = [:]

    public init(queue: FileOpQueue) {
        self.queue = queue
        undoManager = UndoManager()
        // Explicit groups: registration never depends on the run loop closing an event group
        // (XCTest, macx-scenarios, and jobs finishing outside any event).
        undoManager.groupsByEvent = false
    }

    public var canUndo: Bool { undoManager.canUndo }
    public var canRedo: Bool { undoManager.canRedo }
    var liveChainCount: Int { chains.count }

    public func register(_ outcome: JobOutcome, actionName: String) {
        guard outcome.record.isUndoable else { return }
        let chain = Chain(actionName: actionName)
        chains[ObjectIdentifier(chain)] = chain
        let record = outcome.record
        undoManager.beginUndoGrouping()
        registerStep(chain, record: Task<JobRecord?, Never> { record }, direction: .undo)
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    public func makeFieldEditorUndoManager() -> UndoManager { UndoManager() }

    /// The handler runs inside `undo()`/`redo()`: it starts the inverse job and, while the manager is still
    /// undoing (or redoing), registers the opposite entry so it lands on the other stack. That entry waits
    /// for the inverse job's record, so a quick redo after undo runs after it, never before.
    private func registerStep(_ chain: Chain, record: Task<JobRecord?, Never>, direction: Direction) {
        undoManager.registerUndo(withTarget: chain) { [weak self] chain in
            guard let self else { return }
            let next = self.launch(chain, record: record, direction: direction)
            self.registerStep(chain, record: next, direction: direction == .undo ? .redo : .undo)
            self.undoManager.setActionName(chain.actionName)
        }
    }

    private func launch(_ chain: Chain, record: Task<JobRecord?, Never>, direction: Direction) -> Task<JobRecord?, Never> {
        let queue = self.queue
        return Task { [weak self] () -> JobRecord? in
            guard let r = await record.value else { return nil }
            let kind: JobKind = direction == .undo ? .undo(r) : .redo(r)
            let id = await queue.enqueue(JobRequest(kind, origin: nil, registersUndo: false))
            let outcome = await queue.outcome(of: id)
            guard outcome.record.isUndoable else {
                self?.drop(chain)                 // nothing to reverse (all skipped, or a remove): no entry
                return nil
            }
            return outcome.record
        }
    }

    private func drop(_ chain: Chain) {
        undoManager.removeAllActions(withTarget: chain)
        chains[ObjectIdentifier(chain)] = nil
    }
}
