import Foundation

/// Lenient view of a baseline metric: older or foreign reports may lack unit/samples/schema.
struct BaselineMetric: Decodable, Equatable, Sendable {
    var name: String
    var size: Int
    var median: Double
    var unit: String?
    var key: String { "\(name)@\(size)" }
}

struct Comparison: Equatable, Sendable {
    enum Status: String, Sendable, Hashable { case ok, regressed, improved, new, missing }
    var key: String
    var unit: String
    var baseline: Double?
    var current: Double?
    var status: Status
}

enum BaselineCompare {
    private struct BaselineFile: Decodable { var metrics: [BaselineMetric] }

    /// §9 CI gate: fails only if more than 20 % slower AND more than 5 ms slower (2 MB for memory).
    static func isRegression(baseline: Double, current: Double, unit: String) -> Bool {
        let absoluteFloor = unit == "MB" ? 2.0 : 5.0
        return current > baseline * 1.2 && current - baseline > absoluteFloor
    }

    static func decodeBaseline(_ data: Data) throws -> [BaselineMetric] {
        try JSONDecoder().decode(BaselineFile.self, from: data).metrics
    }

    static func loadBaseline(_ url: URL) throws -> [BaselineMetric] {
        try decodeBaseline(Data(contentsOf: url))
    }

    static func compare(current: [MetricResult], baseline: [BaselineMetric]) -> [Comparison] {
        let base = Dictionary(baseline.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [Comparison] = current.map { m in
            guard let b = base[m.key] else {
                return Comparison(key: m.key, unit: m.unit, baseline: nil, current: m.median, status: .new)
            }
            let status: Comparison.Status =
                isRegression(baseline: b.median, current: m.median, unit: m.unit) ? .regressed
                : (m.median < b.median * 0.8 ? .improved : .ok)
            return Comparison(key: m.key, unit: m.unit, baseline: b.median, current: m.median, status: status)
        }
        let currentKeys = Set(current.map(\.key))
        var seenMissing = Set<String>()
        for b in baseline where !currentKeys.contains(b.key) && seenMissing.insert(b.key).inserted {
            out.append(Comparison(key: b.key, unit: b.unit ?? "ms", baseline: b.median, current: nil, status: .missing))
        }
        return out
    }

    static func render(_ comparisons: [Comparison]) -> String {
        comparisons.map { c in
            let b = c.baseline.map { Budgets.format($0) } ?? "-"
            let n = c.current.map { Budgets.format($0) } ?? "-"
            return "\(c.status.rawValue.uppercased()) \(c.key): \(b) → \(n) \(c.unit)"
        }.joined(separator: "\n")
    }
}
