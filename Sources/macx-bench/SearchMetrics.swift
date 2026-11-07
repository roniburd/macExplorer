import Foundation
import Core
import MacxFS

/// Phase 3 (P3-13) search metrics, all on fixtures inside the bench's own macx-bench-<UUID> sandbox. Selected with
/// `--metrics search-` (P1-39's metric-prefix flag):
/// - `search-filter-100k` (budget 30 ms): the This folder filter (glob + size criteria) over a 100k-entry store;
/// - `search-parse-10k`: 10,000 QuerySyntax parses of a query using every operator;
/// - `search-crawl-first-result` / `search-crawl-complete`: SubtreeCrawler over a 585-folder, 11,700-file tree;
/// - `search-results-ingest-100k`: SearchResultsModel taking 100,000 results in 50 batches (no file-system access).
/// Spotlight is never queried.
@MainActor
enum SearchMetrics {
    static let filterSize = 100_000

    static func run(_ options: BenchOptions, env: CoreEnvironment, sandbox: SandboxHandle,
                    wants: (String) -> Bool) async throws -> [MetricResult] {
        var out: [MetricResult] = []
        func samples(_ body: @MainActor () async throws -> Double) async throws -> [Double] {
            try await Stats.sample(warmups: options.warmups, iterations: options.iterations, body)
        }
        func elapsed(since start: ContinuousClock.Instant) -> Double { Stats.milliseconds(ContinuousClock.now - start) }

        if wants("search-filter-100k") || wants("search-results-ingest-100k") {
            let relative = "work/search-100k"
            let directory = sandbox.flat(relative, count: filterSize)
            let suite = MetricSuite(env: env, sandbox: sandbox, relativeDir: relative, directory: directory, size: filterSize,
                                    options: options)
            let store = try await suite.readStore()
            guard store.count == filterSize else { throw BenchFailure.check("search store has \(store.count) entries") }
            if wants("search-filter-100k") {
                let types = env.types
                let ranks = types.kindRanks().ranks
                let keys = SortKeys.nameKeys(store, range: 0..<store.count)
                let search = SortKeys.searchKeys(store)
                let query = ViewQuery(criteria: SearchCriteria(nameTerms: [NameTerm("*7*.txt")], size: ByteRange(lower: 0)))
                // FixtureTree.flat names are file-000001.txt …: the ones whose number contains a 7.
                let expected = (1...filterSize).filter { String($0).contains("7") }.count
                out.append(MetricResult(name: "search-filter-100k", size: filterSize, samples: try await samples {
                    let start = ContinuousClock.now
                    let p = Sorter.permutation(store, nameKeys: keys, searchKeys: search, query: query, kindRanks: ranks, types: types)
                    let ms = elapsed(since: start)
                    guard p.count == expected else { throw BenchFailure.check("glob filter matched \(p.count) of \(expected)") }
                    return ms
                }))
            }
            if wants("search-results-ingest-100k") {
                var context = env.searchContext()
                context.pacer = ImmediatePacer()
                let ingestContext = context
                out.append(MetricResult(name: "search-results-ingest-100k", size: filterSize, samples: try await samples {
                    let model = SearchResultsModel(title: "bench", events: { g in batches(store, g) }, context: ingestContext)
                    defer { model.close() }
                    let start = ContinuousClock.now
                    model.start()
                    while !isComplete(model) { await Task.yield() }
                    let ms = elapsed(since: start)
                    guard model.rowCount == store.count else { throw BenchFailure.check("ingested \(model.rowCount) of \(store.count)") }
                    return ms
                }))
            }
        }

        if wants("search-parse-10k") {
            let queries = (0..<10_000).map { i in
                "report\(i) kind:pdf,image ext:jpg size:>\(i)KB modified:2026-01-\(1 + i % 28) \"two words\""
            }
            out.append(MetricResult(name: "search-parse-10k", size: queries.count, samples: try await samples {
                let start = ContinuousClock.now
                var terms = 0
                for q in queries { terms += QuerySyntax.parse(q).freeTerms.count }
                let ms = elapsed(since: start)
                guard terms >= queries.count else { throw BenchFailure.check("parsed \(terms) free terms") }
                return ms
            }))
        }

        if wants("search-crawl-first-result") || wants("search-crawl-complete") {
            let tree = sandbox.deep("work/search-tree", depth: 4, breadth: 8, filesPerDir: 20)
            let folders = 1 + 8 + 64 + 512, files = folders * 20
            let lanes = env.lanes, mounts = env.volumes.mountTableStore, types = env.types
            func crawl(_ term: String) -> AsyncStream<SearchEvent> {
                SubtreeCrawler.crawl(root: tree, criteria: SearchCriteria(nameTerms: [NameTerm(term)]), options: CrawlOptions(),
                                     permissions: .none, generation: Generation.initial.next(), lanes: lanes, mountTable: mounts,
                                     types: types)
            }
            if wants("search-crawl-first-result") {
                out.append(MetricResult(name: "search-crawl-first-result", size: files, samples: try await samples {
                    let start = ContinuousClock.now
                    for await event in crawl("f1") { if case .batch = event { break } }
                    return elapsed(since: start)
                }))
            }
            if wants("search-crawl-complete") {
                out.append(MetricResult(name: "search-crawl-complete", size: files, samples: try await samples {
                    let start = ContinuousClock.now
                    var summary: SearchSummary?
                    for await event in crawl("zzz-no-match") { if case .completed(let s) = event { summary = s; break } }
                    let ms = elapsed(since: start)
                    guard let summary, summary.resultCount == 0, summary.directoriesScanned >= folders else {
                        throw BenchFailure.check("crawl summary \(String(describing: summary))")
                    }
                    return ms
                }))
            }
        }
        return out
    }

    static func isComplete(_ model: SearchResultsModel) -> Bool { if case .complete = model.state { true } else { false } }

    /// 50 batches of 2,000 from the 100k store, all under one virtual parent (never touched: the model does no I/O).
    nonisolated static func batches(_ store: EntryStore, _ g: Generation) -> AsyncStream<SearchEvent> {
        AsyncStream { c in
            let parent = URL(filePath: "/macx-bench-virtual", directoryHint: .isDirectory)
            var b = Batch(generation: g)
            for i in 0..<UInt32(store.count) {
                store.withNameBytes(i) { b.append(store.entry(i), nameBytes: $0) }
                if b.count == 2_000 {
                    c.yield(.batch(SearchBatch(parent: parent, batch: b)))
                    b = Batch(generation: g)
                }
            }
            if b.count > 0 { c.yield(.batch(SearchBatch(parent: parent, batch: b))) }
            c.yield(.completed(SearchSummary(resultCount: store.count)))
            c.finish()
        }
    }
}

/// Frame pacing for the ingest metric: the next "frame" is the next scheduler turn.
struct ImmediatePacer: FramePacer { func nextFrame() async { await Task.yield() } }
