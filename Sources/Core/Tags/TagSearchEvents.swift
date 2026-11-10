import Foundation
import MacxFS

/// P4-06 Step 5: a tag query's cumulative URL lists as the Phase 3 `SearchEvent` stream that
/// `SearchResultsModel(title:events:context:)` shows (Details with a Path column).
public enum TagSearchEvents {
    /// Each update stats only the URLs not seen before (on a read lane, under no-materialization, with Phase 1's
    /// `ItemReader`), yields one batch per parent folder, yields `removed` for URLs that left the result set, and
    /// `completed` on `.finished`. URLs that no longer exist are dropped (and not counted).
    public static func events(query: any TagQuerying, tag: String, scope: TagScope, lanes: LanePool, types: TypeRegistry,
                              volume: VolumeID = .unknown) -> @MainActor (Generation) -> AsyncStream<SearchEvent> {
        { generation in
            let (stream, continuation) = AsyncStream.makeStream(of: SearchEvent.self, bufferingPolicy: .unbounded)
            let task = Task {
                var seen: [String: String] = [:]                 // lookup key → path as yielded in a batch
                let start = ContinuousClock.now
                for await update in query.results(for: tag, scope: scope) {
                    if Task.isCancelled { break }
                    switch update {
                    case .results(let urls):
                        var current: [String: String] = [:]
                        var fresh: [(parent: String, name: String)] = []
                        for url in urls {
                            let path = SearchResultStore.standardizedParent(url)
                            let key = SearchResultStore.key(path)
                            guard current[key] == nil, path != "/" else { continue }
                            current[key] = path
                            if seen[key] == nil {
                                fresh.append(((path as NSString).deletingLastPathComponent, (path as NSString).lastPathComponent))
                            }
                        }
                        let gone = seen.filter { current[$0.key] == nil }
                        if !gone.isEmpty { continuation.yield(.removed(Array(gone.values))) }
                        seen = seen.filter { current[$0.key] != nil }
                        let read = await stat(fresh, generation: generation, lanes: lanes, types: types, volume: volume)
                        for batch in read.batches {
                            let parent = SearchResultStore.standardizedParent(batch.parent)
                            for i in 0..<batch.batch.count {
                                let path = SearchResultStore.join(parent, batch.batch.name(at: i))
                                seen[SearchResultStore.key(path)] = path
                            }
                            continuation.yield(.batch(batch))
                        }
                    case .finished:
                        continuation.yield(.completed(SearchSummary(resultCount: seen.count, elapsed: ContinuousClock.now - start)))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
    }

    /// Groups `items` by parent (first-seen order) and stats each group with `ItemReader` in one lane call.
    private static func stat(_ items: [(parent: String, name: String)], generation: Generation, lanes: LanePool,
                             types: TypeRegistry, volume: VolumeID) async -> (batches: [SearchBatch], missing: Int) {
        guard !items.isEmpty else { return ([], 0) }
        var order: [String] = []
        var names: [String: [String]] = [:]
        for item in items {
            if names[item.parent] == nil { order.append(item.parent) }
            names[item.parent, default: []].append(item.name)
        }
        let groups = order.map { (URL(filePath: $0, directoryHint: .isDirectory), names[$0]!) }
        return (try? await lanes.perform(on: volume, .read) { lane in
            withNoMaterialization {
                var batches: [SearchBatch] = []
                var missing = 0
                for (parent, names) in groups {
                    if lane.isCancelled { break }
                    guard let read = try? ItemReader.read(names: names, in: parent, generation: generation, types: types,
                                                          context: lane) else { missing += names.count; continue }
                    missing += read.missing.count + read.errors.count
                    if read.batch.count > 0 { batches.append(SearchBatch(parent: parent, batch: read.batch)) }
                }
                return (batches, missing)
            }
        }) ?? ([], items.count)
    }
}
