import Foundation
import Core
import MacxFS

/// P2-07 review fix: the per-folder view store at `FolderViewStore.capacity` records, every one carrying all 12
/// columns. Measures main-actor work only (no file system): launch decode, the synchronous flush (termination and
/// "Apply to All Folders"), and one save into a full store (eviction included).
@MainActor
enum FolderViewBench {
    static let metricNames = ["folderViews.load", "folderViews.flush", "folderViews.save"]

    static func run(_ options: BenchOptions, wants: (String) -> Bool) async throws -> [MetricResult] {
        guard metricNames.contains(where: wants) else { return [] }
        let n = FolderViewStore.capacity
        let volume = VolumeInfo(id: VolumeID(raw: "uuid:0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"),
                                mountPoint: URL(filePath: "/", directoryHint: .isDirectory), name: "Bench", format: "APFS",
                                isBoot: false, isInternal: true, isRemovable: false, isEjectable: false, isLocal: true,
                                isReadOnly: false, isBrowsable: true, totalCapacity: nil,
                                capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
        func locator(_ i: Int) -> FolderViewLocator {
            FolderViewLocator(url: URL(filePath: "/Users/bench/Projects/area-\(i % 97)/folder-\(i)", directoryHint: .isDirectory),
                              volume: volume, fileID: UInt64(10_000_000 + i))
        }
        var state = FolderViewState(mode: .icons, columns: Settings.defaultColumns, sort: .default, iconSize: .large,
                                    groupBy: .kind, calculateFolderSizes: false)
        let defaults = state
        let storage = InMemorySettingsStorage()
        let full = FolderViewStore(storage: storage, defaults: { defaults }, flushDelay: .seconds(3_600))
        for i in 0..<n {
            state.columns[i % state.columns.count].width += Double(i % 3)   // a few distinct layouts, as in use
            full.save(state, for: locator(i))
        }
        full.flush()
        let clock = ContinuousClock()
        func ms(_ body: () -> Void) -> Double {
            let start = clock.now
            body()
            return Stats.milliseconds(clock.now - start)
        }
        var out: [MetricResult] = []
        if wants("folderViews.load") {
            let samples = try await Stats.sample(warmups: options.warmups, iterations: options.iterations) {
                var loaded = 0
                let t = ms { loaded = FolderViewStore(storage: storage, defaults: { defaults }).count }
                guard loaded == n else { throw BenchFailure.check("folder-view store reload (\(loaded) of \(n) records)") }
                return t
            }
            out.append(MetricResult(name: "folderViews.load", size: n, samples: samples))
        }
        if wants("folderViews.flush") {
            let samples = await Stats.sample(warmups: options.warmups, iterations: options.iterations) { ms { full.flush() } }
            out.append(MetricResult(name: "folderViews.flush", size: n, samples: samples))
        }
        if wants("folderViews.save") {
            var next = n
            let samples = await Stats.sample(warmups: options.warmups, iterations: options.iterations) {
                next += 1
                return ms { full.save(state, for: locator(next)) }
            }
            out.append(MetricResult(name: "folderViews.save", size: n, samples: samples))
        }
        return out
    }
}
