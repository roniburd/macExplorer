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
        return ObserverToken { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.remove(id) }
            } else {
                Task { @MainActor in self?.remove(id) }
            }
        }
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
