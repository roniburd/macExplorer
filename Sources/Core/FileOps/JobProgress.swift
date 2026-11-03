import Foundation

public struct JobProgress: Sendable, Equatable {
    public var itemsDone: Int = 0
    public var itemsTotal: Int? = nil            // nil while planning
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64? = nil
    public var currentItem: String? = nil
    public var throughput: [Double] = []         // bytes/s, oldest first, ≤ 60
    public var estimatedRemaining: Duration? = nil
    public init() {}
    public var fraction: Double? {
        if let bt = bytesTotal, bt > 0 { return min(1, Double(bytesDone) / Double(bt)) }
        if let it = itemsTotal {
            return it == 0 ? 1 : min(1, Double(itemsDone) / Double(it))
        }
        return nil
    }
    public static let zero = JobProgress()
}

/// 60-sample throughput history (§6.2) and ETA from the mean of the last 10 samples.
public struct ThroughputMeter: Sendable {
    public static let capacity = 60
    public private(set) var samples: [Double] = []
    private var lastBytes: Int64 = 0
    private var lastTime: ContinuousClock.Instant?
    public init() {}

    public mutating func sample(bytesDone: Int64, at now: ContinuousClock.Instant) {
        defer { lastBytes = bytesDone; lastTime = now }
        guard let t0 = lastTime else { return }
        let dt = (now - t0).inSeconds
        guard dt > 0 else { return }
        samples.append(max(0, Double(bytesDone - lastBytes) / dt))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    public func estimatedRemaining(bytesDone: Int64, bytesTotal: Int64?) -> Duration? {
        guard let total = bytesTotal else { return nil }
        guard total > bytesDone else { return .zero }
        let recent = samples.suffix(10)
        guard !recent.isEmpty else { return nil }
        let rate = recent.reduce(0, +) / Double(recent.count)
        guard rate > 0 else { return nil }
        return .milliseconds(Int64((Double(total - bytesDone) / rate * 1000).rounded()))
    }
}

extension Duration {
    var inSeconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
