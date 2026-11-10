import Foundation
import MacxFS

struct Budget: Sendable, Equatable {
    var metric: String
    var sizes: Set<Int>?        // nil = every size
    var limit: Double
    var unit: String
    var spec: String
}

struct BudgetCheck: Codable, Equatable, Sendable {
    var metric: String
    var size: Int
    var limit: Double
    var unit: String
    var median: Double
    var passed: Bool
    var spec: String
}

enum Budgets {
    /// §4.4 rows that macx-bench can measure headlessly (Apple Silicon, local APFS, warm cache).
    static let table: [Budget] = {
        var t: [Budget] = [
            Budget(metric: "firstBatch", sizes: nil, limit: 50, unit: "ms", spec: "§4.4 navigate → first rows painted < 50 ms"),
            Budget(metric: "listSorted", sizes: [100_000], limit: 250, unit: "ms", spec: "§4.4 100k entries fully listed + sorted < 250 ms"),
            Budget(metric: "listSorted.busyMain", sizes: [100_000], limit: 250, unit: "ms",
                   spec: "§4.4 100k entries fully listed + sorted < 250 ms, with the main actor as busy as in the app"),
            Budget(metric: "modelResort", sizes: [100_000], limit: 30, unit: "ms", spec: "§4.4 re-sort 100k by any column < 30 ms"),
            Budget(metric: "fsevent.incremental", sizes: nil, limit: 150, unit: "ms", spec: "§4.4 FSEvent → UI updated (incremental) < 150 ms"),
            Budget(metric: "fsevent.full", sizes: [100_000], limit: 400, unit: "ms", spec: "§4.4 FSEvent → UI updated (full re-read of 100k) < 400 ms"),
            // The StoreDiff part of a full re-read on its own (was a debug-build timing in StoreDiffTests).
            Budget(metric: "diff", sizes: [100_000], limit: 400, unit: "ms",
                   spec: "§4.4 FSEvent → UI updated (full re-read of 100k) < 400 ms: diff of 100k with 1% of rows changed"),
            Budget(metric: "memory.steady", sizes: [100_000], limit: 20, unit: "MB", spec: "§4.4 memory, 100k-entry folder < 20 MB steady"),
            // Overview §4.4 pasteboard decision (2026-11-03): ≤10k < 300 ms, 100k < 1.5 s.
            Budget(metric: "pasteboard", sizes: [1_000, 10_000], limit: 300, unit: "ms", spec: "§4.4 copy of ≤10k items (pasteboard write) < 300 ms"),
            Budget(metric: "pasteboard", sizes: [100_000], limit: 1_500, unit: "ms", spec: "§4.4 copy of 100k items (pasteboard write) < 1.5 s"),
            // P2-07 review fix: the per-folder view store, full (5,000 records), on the main actor.
            Budget(metric: "folderViews.load", sizes: nil, limit: 30, unit: "ms",
                   spec: "§4.4 no main-thread hang > 100 ms: launch decode of a full folder-view store"),
            Budget(metric: "folderViews.flush", sizes: nil, limit: 50, unit: "ms",
                   spec: "§4.4 no main-thread hang > 100 ms: synchronous folder-view flush (termination)"),
            Budget(metric: "folderViews.save", sizes: nil, limit: 2, unit: "ms",
                   spec: "§4.4 no main-thread hang > 100 ms: saving one folder's view into a full store"),
            // P4-03 review fix: the palette re-ranks on every keystroke (was a debug-build timing in PaletteCatalogTests).
            Budget(metric: "palette.rank", sizes: nil, limit: 2, unit: "ms",
                   spec: "Phase 4: palette ranking over every command plus 20 favorites plus 20 recents < 2 ms"),
        ]
        // P3-13: the This folder search filter is a re-sort with criteria (§4.4 re-sort 100k < 30 ms).
        t.append(Budget(metric: "search-filter-100k", sizes: [100_000], limit: 30, unit: "ms",
                        spec: "§4.4 re-sort 100k < 30 ms: This folder search (glob + size criteria) over 100k entries"))
        t += SortField.entryFields.map {
            Budget(metric: "resort.\($0.rawValue)", sizes: [100_000], limit: 30, unit: "ms", spec: "§4.4 re-sort 100k by any column < 30 ms")
        }
        // P2-20: a re-sort with Group by on includes the partition (§4.4, Phase 2 note on the re-sort row).
        t += GroupBy.allCases.filter { $0 != .none }.map {
            Budget(metric: "resort.grouped.\($0.rawValue)", sizes: [100_000], limit: 30, unit: "ms",
                   spec: "§4.4 re-sort 100k by any column < 30 ms, including the Group by partition")
        }
        // P2-09 review: Name groups of non-ASCII first letters (was a debug-build timing in GroupingTests).
        t.append(Budget(metric: "resort.grouped.nameFirstLetter.nonASCII", sizes: [100_000], limit: 30, unit: "ms",
                        spec: "§4.4 re-sort 100k by any column < 30 ms, including the Group by partition (non-ASCII names)"))
        // P2-16 review fix: extended string columns, every value distinct, loaded (identity map + sort).
        t += ["resort.tags", "resort.comments"].map {
            Budget(metric: $0, sizes: [100_000], limit: 30, unit: "ms", spec: "§4.4 re-sort 100k by any column < 30 ms")
        }
        // P2-16 review fix (§4.4 memory): what an extended sort of a loaded 100k folder adds (heap bytes in use),
        // small enough to keep the folder inside the 20 MB steady budget.
        t += ["memory.extendedSort.tags", "memory.extendedSort.owner"].map {
            Budget(metric: $0, sizes: [100_000], limit: 8, unit: "MB",
                   spec: "§4.4 memory, 100k-entry folder < 20 MB steady: sorting by an extended column adds < 8 MB")
        }
        return t
    }()

    static func evaluate(_ metrics: [MetricResult], table: [Budget] = Budgets.table) -> [BudgetCheck] {
        metrics.compactMap { m in
            guard let b = table.first(where: { $0.metric == m.name && $0.unit == m.unit && ($0.sizes?.contains(m.size) ?? true) }) else {
                return nil
            }
            return BudgetCheck(metric: m.name, size: m.size, limit: b.limit, unit: b.unit, median: m.median,
                               passed: m.median <= b.limit, spec: b.spec)
        }
    }

    /// GitHub Actions warning annotations for failed checks (non-blocking in CI, §9).
    static func annotations(_ checks: [BudgetCheck]) -> [String] {
        checks.filter { !$0.passed }.map {
            "::warning title=Performance budget::\($0.metric) @ \($0.size): median \(format($0.median)) \($0.unit) > \(format($0.limit)) \($0.unit) (\($0.spec))"
        }
    }

    static func format(_ v: Double) -> String { String(format: "%.1f", v) }
}
