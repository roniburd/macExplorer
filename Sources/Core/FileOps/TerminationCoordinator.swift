import Foundation
import Synchronization

/// §6.7 Stop and Quit: cancel every job (finish the current item safely, remove cross-volume partials, update
/// the journal) and wait, at most `timeout`. After a timeout the app quits anyway; launch cleanup uses the journal.
@MainActor
public final class TerminationCoordinator {
    private let queue: FileOpQueue
    private let operations: OperationsCenter

    public init(queue: FileOpQueue, operations: OperationsCenter) {
        self.queue = queue; self.operations = operations
    }

    public var activeCount: Int { operations.jobs.count }

    public func stopAllAndWait(timeout: Duration = .seconds(10)) async -> Bool {
        let queue = self.queue
        let once = ResumeOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            // A job blocked on an unanswered dialog never finishes its cancel, and `cancelAll` can't be
            // interrupted, so the two race in unstructured tasks rather than a task group (which would wait for both).
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                if once.claim() { c.resume(returning: false) }
            }
            Task {
                await queue.cancelAll()
                timer.cancel()
                if once.claim() { c.resume(returning: true) }
            }
        }
    }
}

/// First caller wins.
final class ResumeOnce: Sendable {
    private let done = Mutex(false)
    func claim() -> Bool { done.withLock { d in defer { d = true }; return !d } }
}
