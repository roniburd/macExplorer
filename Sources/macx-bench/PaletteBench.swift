import Foundation
import Core

/// P4-03 review fix: palette ranking over every command plus 20 favorites and 20 recent folders, in memory (no file
/// system). One sample is the slowest of four typical queries (was a debug-build timing in PaletteCatalogTests).
@MainActor
enum PaletteBench {
    static let metricName = "palette.rank"
    static let queries = ["n", "nf", "go fo", "sort by name"]

    static func items() -> [PaletteItem] {
        var items = Command.allCases.map {
            PaletteItem(target: .command($0), title: "\($0.rawValue) command title", subtitle: nil)
        }
        for i in 0..<40 {
            let url = URL(filePath: "/Volumes/Bench/Projects/Folder \(i)", directoryHint: .isDirectory)
            items.append(PaletteItem(target: .location(url), title: "Go to Folder \(i)", subtitle: url.path))
        }
        return items
    }

    static func run(_ options: BenchOptions, wants: (String) -> Bool) async throws -> [MetricResult] {
        guard wants(metricName) else { return [] }
        let items = items()
        let recent = items.prefix(20).map(\.target)
        let clock = ContinuousClock()
        let samples = try await Stats.sample(warmups: options.warmups, iterations: options.iterations) {
            var slowest = 0.0
            for query in queries {
                let start = clock.now
                let ranked = PaletteCatalog.rank(items, query: query, recent: recent)
                slowest = max(slowest, Stats.milliseconds(clock.now - start))
                guard !ranked.isEmpty else { throw BenchFailure.check("palette ranking for \"\(query)\" found nothing") }
            }
            return slowest
        }
        return [MetricResult(name: metricName, size: items.count, samples: samples)]
    }
}
