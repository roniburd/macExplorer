import Foundation
import Core

/// P4-23: the batch rename preview (spec §11 Phase 4: 10,000 names previewed in < 100 ms off the main thread). Pure,
/// in memory: find/replace plus Explorer-style numbering over 10,000 names, with every name of the folder as the
/// existing names (no file system).
@MainActor
enum BatchRenameBench {
    nonisolated static let metricName = "batchRename.preview"
    nonisolated static let size = 10_000

    static let rules: BatchRenameRules = {
        var rules = BatchRenameRules()
        rules.find = "IMG"; rules.replace = "P"
        var numbering = BatchRenameRules.Numbering(); numbering.position = .replaceName; numbering.baseName = "Trip"
        rules.numbering = numbering
        return rules
    }()

    static func run(_ options: BenchOptions, wants: (String) -> Bool) async throws -> [MetricResult] {
        guard wants(metricName) else { return [] }
        let urls = (0..<size).map { URL(filePath: "/Volumes/Bench/Photos/IMG_\($0).jpg") }
        let names = urls.map(\.lastPathComponent) + ["Trip (1).txt", "notes.txt"]
        let rules = Self.rules
        let clock = ContinuousClock()
        let samples = try await Stats.sample(warmups: options.warmups, iterations: options.iterations) {
            let start = clock.now
            let preview = await Task.detached(priority: .userInitiated) {
                BatchRenamePlanner.preview(urls, rules: rules, caseSensitive: false, existingNames: names)
            }.value
            let ms = Stats.milliseconds(clock.now - start)
            guard preview.canApply, preview.rows.count == size else { throw BenchFailure.check("batch rename preview cannot apply") }
            return ms
        }
        return [MetricResult(name: metricName, size: size, samples: samples)]
    }
}
