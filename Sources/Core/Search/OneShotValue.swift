import Synchronization

/// One-shot result box: the first `resume` wins, later ones are ignored; `value()` suspends until a value exists.
/// The crawler uses it to stop waiting for a stalled lane read. `value()` may be awaited once.
final class OneShotValue<T: Sendable>: Sendable {
    private enum State { case idle, waiting(CheckedContinuation<T, Never>), done(T) }
    private let state = Mutex<State>(.idle)

    init() {}

    @discardableResult
    func resume(_ value: T) -> Bool {
        let (waiter, won): (CheckedContinuation<T, Never>?, Bool) = state.withLock { s in
            switch s {
            case .idle: s = .done(value); return (nil, true)
            case .waiting(let c): s = .done(value); return (c, true)
            case .done: return (nil, false)
            }
        }
        waiter?.resume(returning: value)
        return won
    }

    func value() async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            let ready: T? = state.withLock { s in
                switch s {
                case .done(let v): return v
                case .idle: s = .waiting(c); return nil
                case .waiting: preconditionFailure("OneShotValue.value() awaited twice")
                }
            }
            if let ready { c.resume(returning: ready) }
        }
    }
}
