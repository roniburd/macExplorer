import Foundation
import Synchronization

/// Cancels a registration. Idempotent; also cancels on deinit, so dropping the token unsubscribes.
public final class ObserverToken: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    public init(_ cancel: @escaping @Sendable () -> Void) {
        action = Mutex(cancel)
    }

    public func cancel() {
        let run = action.withLock { value -> (@Sendable () -> Void)? in
            defer { value = nil }
            return value
        }
        run?()
    }

    /// A token whose cancel runs `remove` on the main actor: right away when cancelled on the main thread (a dropped
    /// token unsubscribes before the next event), else in a main-actor task.
    public convenience init(onMain remove: @escaping @MainActor @Sendable () -> Void) {
        self.init {
            if Thread.isMainThread {
                MainActor.assumeIsolated { remove() }
            } else {
                Task { @MainActor in remove() }
            }
        }
    }

    deinit { cancel() }
}

/// Main-actor multicast of events to registered handlers, in registration order.
@MainActor
public final class Observers<Event> {
    private var handlers: [(id: UInt64, handler: @MainActor (Event) -> Void)] = []
    private var nextID: UInt64 = 0

    public init() {}

    public func add(_ handler: @escaping @MainActor (Event) -> Void) -> ObserverToken {
        nextID += 1
        let id = nextID
        handlers.append((id, handler))
        return ObserverToken(onMain: { [weak self] in self?.remove(id) })
    }

    /// Delivers to a snapshot, so handlers may add or cancel registrations while being called.
    public func send(_ event: Event) {
        for entry in handlers { entry.handler(event) }
    }

    public var isEmpty: Bool { handlers.isEmpty }

    private func remove(_ id: UInt64) {
        handlers.removeAll { $0.id == id }
    }
}
