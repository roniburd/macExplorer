import AppKit
import Core

/// §6.7 Dock tile progress: the overall % of the visible jobs (jobs under 1 s show nothing, §6.2).
@MainActor enum DockBadge {
    static func label(visibleJobs: Int, fraction: Double?) -> String? {
        guard visibleJobs > 0 else { return nil }
        guard let fraction else { return "…" }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        return (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Keeps the Dock badge in step with the operations (ObservationLoop over OperationsCenter). Writes only changes.
@MainActor
final class DockBadgeController {
    private let read: @MainActor () -> (visibleJobs: Int, fraction: Double?)
    private let sink: @MainActor (String?) -> Void
    private var loop: ObservationLoop?
    private var last: String??
    private var stopped = false

    init(read: @escaping @MainActor () -> (visibleJobs: Int, fraction: Double?), sink: @escaping @MainActor (String?) -> Void) {
        self.read = read
        self.sink = sink
        update()
        loop = ObservationLoop({ _ = read() }, onChange: { [weak self] in self?.update() })
    }

    convenience init(operations: OperationsCenter, sink: @escaping @MainActor (String?) -> Void) {
        self.init(read: { (operations.visibleJobs.count, operations.overallFraction) }, sink: sink)
    }

    /// Stops following and clears the badge.
    func stop() {
        stopped = true
        loop?.cancel()
        loop = nil
        write(nil)
    }

    private func update() {
        guard !stopped else { return }
        let value = read()
        write(DockBadge.label(visibleJobs: value.visibleJobs, fraction: value.fraction))
    }

    private func write(_ label: String?) {
        if let last, last == label { return }
        last = .some(label)
        sink(label)
    }
}
