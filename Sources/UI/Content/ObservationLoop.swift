import Observation

/// Runs `read` under withObservationTracking and calls `onChange` on the main actor after every change of a
/// tracked @Observable property (Settings, OperationsCenter), re-arming itself until cancelled or released.
@MainActor
final class ObservationLoop {
    private let read: @MainActor () -> Void
    private let onChange: @MainActor () -> Void
    private var cancelled = false

    init(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        self.read = read
        self.onChange = onChange
        track()
    }

    func cancel() { cancelled = true }

    private func track() {
        guard !cancelled else { return }
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                self.onChange()
                self.track()
            }
        }
    }
}
