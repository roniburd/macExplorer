import Foundation

enum BenchError: Error, Equatable, CustomStringConvertible {
    case missingValue(String)
    case badValue(String, String)
    case unknownOption(String)
    var description: String {
        switch self {
        case .missingValue(let f): "missing value for \(f)"
        case .badValue(let f, let v): "bad value '\(v)' for \(f)"
        case .unknownOption(let f): "unknown option \(f)"
        }
    }
}

struct BenchOptions: Equatable, Sendable {
    var sizes: [Int] = [1_000, 10_000, 100_000]
    var warmups = 1
    var iterations = 5
    var metrics: Set<String>? = nil
    var output: URL? = nil
    var compare: URL? = nil
    var checkBudgets = false
    var warnBudgets = false
    var allowDebug = false
    var keepFixtures = false

    static func parse(_ args: [String]) throws(BenchError) -> BenchOptions {
        var o = BenchOptions()
        var i = 0
        func value(_ flag: String) throws(BenchError) -> String {
            i += 1
            guard i < args.count else { throw .missingValue(flag) }
            return args[i]
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--sizes":
                let v = try value(flag)
                let parts = v.split(separator: ",", omittingEmptySubsequences: false)
                let sizes = parts.compactMap { Int($0) }
                guard !sizes.isEmpty, sizes.count == parts.count, sizes.allSatisfy({ $0 > 0 }) else { throw .badValue(flag, v) }
                o.sizes = sizes
            case "--warmups":
                let v = try value(flag)
                guard let n = Int(v), n >= 0 else { throw .badValue(flag, v) }
                o.warmups = n
            case "--iterations":
                let v = try value(flag)
                guard let n = Int(v), n >= 1 else { throw .badValue(flag, v) }
                o.iterations = n
            case "--metrics": o.metrics = Set(try value(flag).split(separator: ",").map(String.init))
            case "--output": o.output = URL(filePath: try value(flag))
            case "--compare": o.compare = URL(filePath: try value(flag))
            case "--check-budgets": o.checkBudgets = true
            case "--warn-budgets": o.warnBudgets = true
            case "--allow-debug": o.allowDebug = true
            case "--keep-fixtures": o.keepFixtures = true
            default: throw .unknownOption(flag)
            }
            i += 1
        }
        return o
    }
}

@MainActor
enum BenchCLI {
    static let usage = """
        usage: macx-bench [--sizes 1000,10000,100000] [--warmups 1] [--iterations 5] [--metrics prefix,...]
                          [--output FILE] [--compare BASELINE.json] [--check-budgets] [--warn-budgets]
                          [--allow-debug] [--keep-fixtures]
        """

    static func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func run(_ arguments: [String]) async -> Int32 {
        let options: BenchOptions
        do { options = try BenchOptions.parse(arguments) } catch {
            stderr("macx-bench: \(error)\n\(usage)")
            return 64
        }
        if options.checkBudgets, Bench.configuration == "debug", !options.allowDebug {
            stderr("macx-bench: --check-budgets needs a release build: swift run -c release macx-bench --check-budgets")
            return 3
        }
        if Bench.configuration == "debug" { stderr("macx-bench: WARNING debug build; numbers are not meaningful") }

        var report: BenchReport
        do { report = try await Bench.run(options, log: stderr) } catch {
            stderr("macx-bench: \(error)")
            return 70
        }
        let checks = Budgets.evaluate(report.metrics)
        report.budgets = checks

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            if let output = options.output { try data.write(to: output, options: .atomic) }
            else { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
        } catch {
            stderr("macx-bench: cannot write report: \(error)")
            return 70
        }

        var code: Int32 = 0
        if options.warnBudgets { for line in Budgets.annotations(checks) { print(line) } }
        if let baseline = options.compare {
            do {
                let comparisons = BaselineCompare.compare(current: report.metrics, baseline: try BaselineCompare.loadBaseline(baseline))
                stderr(BaselineCompare.render(comparisons))
                if comparisons.contains(where: { $0.status == .regressed }) { code = 1 }
            } catch {
                stderr("macx-bench: cannot read baseline \(baseline.path): \(error)")
                return 70
            }
        }
        if options.checkBudgets {
            let failed = checks.filter { !$0.passed }
            if !report.machine.appleSilicon {
                stderr("macx-bench: budgets reported but not gated (not Apple Silicon)")
            } else if !failed.isEmpty {
                for f in failed { stderr("OVER BUDGET \(f.metric)@\(f.size): \(Budgets.format(f.median)) \(f.unit) > \(Budgets.format(f.limit)) \(f.unit)") }
                if code == 0 { code = 2 }
            } else {
                stderr("macx-bench: all \(checks.count) budget checks passed")
            }
        }
        return code
    }
}
