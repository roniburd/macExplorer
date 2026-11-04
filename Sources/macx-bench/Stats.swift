import Foundation

enum Stats {
    static func median(_ xs: [Double]) -> Double {
        precondition(!xs.isEmpty, "median of no samples")
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Nearest-rank percentile, `p` in (0, 1].
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        precondition(!xs.isEmpty && p > 0 && p <= 1, "bad percentile input")
        let s = xs.sorted()
        let rank = Int((p * Double(s.count)).rounded(.up))
        return s[max(0, min(s.count - 1, rank - 1))]
    }

    /// Runs `body` `warmups` times (discarded), then `iterations` times; returns the measured samples.
    @MainActor
    static func sample(warmups: Int, iterations: Int, _ body: @MainActor () async throws -> Double) async rethrows -> [Double] {
        for _ in 0..<warmups { _ = try await body() }
        var out: [Double] = []
        out.reserveCapacity(iterations)
        for _ in 0..<iterations { out.append(try await body()) }
        return out
    }

    static func milliseconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
    }
}
