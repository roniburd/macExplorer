import Foundation

struct MetricResult: Codable, Equatable, Sendable {
    var name: String
    var size: Int
    var unit: String          // "ms" or "MB"
    var median: Double
    var p90: Double
    var samples: [Double]
    var key: String { "\(name)@\(size)" }

    init(name: String, size: Int, unit: String = "ms", samples: [Double]) {
        self.name = name
        self.size = size
        self.unit = unit
        self.samples = samples
        self.median = Stats.median(samples)
        self.p90 = Stats.percentile(samples, 0.9)
    }
}

struct MachineInfo: Codable, Equatable, Sendable {
    var cpu: String
    var appleSilicon: Bool
    var os: String
    var cores: Int
    static func current() -> MachineInfo {
        MachineInfo(cpu: Machine.cpuBrand(), appleSilicon: Machine.isAppleSilicon(),
                    os: ProcessInfo.processInfo.operatingSystemVersionString,
                    cores: ProcessInfo.processInfo.activeProcessorCount)
    }
}

struct BenchReport: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var schema: Int = BenchReport.schemaVersion
    var machine: MachineInfo
    var configuration: String          // "debug" | "release"
    var warmups: Int
    var iterations: Int
    var metrics: [MetricResult]
    var budgets: [BudgetCheck]?
    var sandbox: String
    var sandboxRemoved: Bool
}
