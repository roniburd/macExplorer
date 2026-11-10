import AppKit
import Core
import Darwin
import Foundation
import MacxFS

enum BenchFailure: Error, CustomStringConvertible {
    case read(Int32)
    case streamEnded
    case timeout(String)
    case check(String)
    var description: String {
        switch self {
        case .read(let code): "directory read failed: errno \(code)"
        case .streamEnded: "read stream ended without .completed"
        case .timeout(let what): "timed out waiting for \(what)"
        case .check(let what): "check failed: \(what)"
        }
    }
}

/// Observes a FolderModel and timestamps the events the budgets care about.
@MainActor
final class ModelWatch {
    let model: FolderModel
    private(set) var firstChanges: ContinuousClock.Instant?
    private(set) var loaded: ContinuousClock.Instant?
    private(set) var changeEvents = 0
    private var token: ObserverToken?

    init(model: FolderModel, expectedRows: Int) {
        self.model = model
        let clock = ContinuousClock()
        token = model.observe { [weak self] event in
            guard let self else { return }
            if case .changes = event {
                self.changeEvents += 1
                if self.firstChanges == nil { self.firstChanges = clock.now }
            }
            if self.loaded == nil, self.model.state == .complete, self.model.rowCount == expectedRows {
                self.loaded = clock.now
            }
        }
    }

    func close() {
        token?.cancel()
        token = nil
        model.close()
    }
}

@MainActor
final class MetricSuite {
    let env: CoreEnvironment
    let sandbox: SandboxHandle
    let relativeDir: String
    let directory: URL
    let size: Int
    let options: BenchOptions
    private var fileCount: Int
    private var generation = Generation.initial
    private let clock = ContinuousClock()

    init(env: CoreEnvironment, sandbox: SandboxHandle, relativeDir: String, directory: URL, size: Int, options: BenchOptions) {
        self.env = env
        self.sandbox = sandbox
        self.relativeDir = relativeDir
        self.directory = directory
        self.size = size
        self.options = options
        self.fileCount = size
    }

    private func wants(_ name: String) -> Bool {
        guard let filter = options.metrics else { return true }
        return filter.contains { name.hasPrefix($0) }
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> Double { Stats.milliseconds(clock.now - start) }

    private func samples(_ body: @MainActor () async throws -> Double) async throws -> [Double] {
        try await Stats.sample(warmups: options.warmups, iterations: options.iterations, body)
    }

    private func result(_ name: String, unit: String = "ms", _ samples: [Double]) -> MetricResult {
        MetricResult(name: name, size: size, unit: unit, samples: samples)
    }

    func waitUntil(_ what: String, timeout: Duration, _ condition: () -> Bool) async throws {
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { throw BenchFailure.timeout(what) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private var identityMode: IdentityMode {
        env.volumes.volume(for: directory)?.capabilities.identityMode ?? .objectID
    }

    private var ranks: [UInt16] { env.types.kindRanks().ranks }

    /// `count` files whose names start with non-ASCII first letters (and an ASCII letter followed by a combining mark).
    private static func nonASCIIStore(count: Int, typeIndex: UInt16) -> EntryStore {
        let prefixes = ["日本語", "中文", "한국어", "Привет", "Ωmega", "Äpfel", "A\u{0308}pfel", "e\u{0301}clair", "éclair", "aé", "Ａbc", "１x"]
        let separators = ["", " ", "-", "x"]
        var store = EntryStore(identityMode: .objectID)
        for i in 0..<count {
            let id = UInt64(i + 1)
            store.upsert(Entry(rowID: id, fileID: id, size: Int64(i), allocSize: 4_096, mtime: 0, ctime: 0, nameOffset: 0,
                               nameLen: 0, kind: .file, flags: [.readable, .writable], typeIndex: typeIndex),
                         name: "\(prefixes[i % prefixes.count])\(separators[i % separators.count])\(i).txt")
        }
        return store
    }

    func readStore() async throws -> EntryStore {
        generation = generation.next()
        let reader = env.readers.reader(for: directory)
        var store = EntryStore(identityMode: identityMode)
        for await event in await reader.read(directory, generation: generation) {
            switch event {
            case .batch(let batch): store.append(batch)
            case .completed: return store
            case .failed(let failure): throw BenchFailure.read(failure.code)
            case .stalled, .waitingForPermission, .resumed: continue
            }
        }
        throw BenchFailure.streamEnded
    }

    private func sortedStore() async throws -> EntryStore {
        var store = try await readStore()
        let keys = SortKeys.nameKeys(store, range: 0..<store.count)
        store.setOrder(Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: ViewQuery(), kindRanks: ranks))
        return store
    }

    private func withLoadedModel<T>(_ body: (ModelWatch) async throws -> T) async throws -> T {
        let model = env.makeFolderModel(directory, query: ViewQuery())
        let watch = ModelWatch(model: model, expectedRows: fileCount)
        defer { watch.close() }
        model.start()
        try await waitUntil("\(size)-entry model loads", timeout: .seconds(60)) { watch.loaded != nil }
        return try await body(watch)
    }

    /// listSorted as the app sees it (QA round 1): the main actor is busy the way a browser window keeps it busy.
    /// Navigating costs a synchronous UI turn (50 ms), every presented reset a reloadData + layout (20 ms), and
    /// display cycles take 3 ms of every 8 ms frame. A pipeline that waits for main between batches fails this.
    private func listWithBusyMain() async throws -> Double {
        func busy(_ duration: Duration) {
            let end = ContinuousClock.now + duration
            while ContinuousClock.now < end {}
        }
        let model = env.makeFolderModel(directory, query: ViewQuery())
        let watch = ModelWatch(model: model, expectedRows: fileCount)
        defer { watch.close() }
        let resets = model.observe { event in if case .changes = event { busy(.milliseconds(20)) } }
        defer { resets.cancel() }
        let frames = Task { @MainActor in
            while !Task.isCancelled {
                busy(.milliseconds(3))
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { frames.cancel() }
        let start = clock.now
        model.start()
        busy(.milliseconds(50))
        try await waitUntil("\(size)-entry model loads (busy main)", timeout: .seconds(60)) { watch.loaded != nil }
        return Stats.milliseconds(watch.loaded! - start)
    }

    func runAll() async throws -> [MetricResult] {
        var out: [MetricResult] = []

        if wants("enumerate") {
            out.append(result("enumerate", try await samples {
                let start = self.clock.now
                _ = try await self.readStore()
                return self.elapsedMs(since: start)
            }))
        }

        if wants("firstBatch") || wants("listSorted") {
            var first: [Double] = []
            var loaded: [Double] = []
            for i in 0..<(options.warmups + options.iterations) {
                let model = env.makeFolderModel(directory, query: ViewQuery())
                let watch = ModelWatch(model: model, expectedRows: fileCount)
                let start = clock.now
                model.start()
                try await waitUntil("\(size)-entry model loads", timeout: .seconds(60)) {
                    watch.loaded != nil && watch.firstChanges != nil
                }
                if i >= options.warmups, let f = watch.firstChanges, let l = watch.loaded {
                    first.append(Stats.milliseconds(f - start))
                    loaded.append(Stats.milliseconds(l - start))
                }
                watch.close()
            }
            if wants("firstBatch") { out.append(result("firstBatch", first)) }
            if wants("listSorted") { out.append(result("listSorted", loaded)) }
        }

        if wants("listSorted.busyMain") {
            out.append(result("listSorted.busyMain", try await samples { try await self.listWithBusyMain() }))
        }

        let needsStore = ["sortkeys", "sort", "resort", "resort.grouped", "filter", "pasteboard"].contains { wants($0) }
        if needsStore {
            let store = try await readStore()
            let keys = SortKeys.nameKeys(store, range: 0..<store.count)
            let ranks = self.ranks
            if wants("sortkeys") {
                out.append(result("sortkeys", try await samples {
                    let start = self.clock.now
                    let k = SortKeys.nameKeys(store, range: 0..<store.count)
                    withExtendedLifetime(k) {}
                    return self.elapsedMs(since: start)
                }))
            }
            if wants("sort") {
                out.append(result("sort", try await samples {
                    let start = self.clock.now
                    let p = Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: ViewQuery(), kindRanks: ranks)
                    withExtendedLifetime(p) {}
                    return self.elapsedMs(since: start)
                }))
            }
            // FolderWorker maintains the extension column next to the name keys while loading, so a re-sort by
            // extension never folds the store; measure the same work here.
            let extensionKeys = SortKeys.extensionKeys(store, range: 0..<store.count)
            for field in SortField.entryFields where wants("resort.\(field.rawValue)") {
                let query = ViewQuery(sort: SortDescriptor(field: field, ascending: field != .name))
                out.append(result("resort.\(field.rawValue)", try await samples {
                    let start = self.clock.now
                    let p = Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: query, kindRanks: ranks,
                                               extensionKeys: extensionKeys)
                    withExtendedLifetime(p) {}
                    return self.elapsedMs(since: start)
                }))
            }
            // P2-16 review fix: Tags / Comments once loaded, every value distinct. Times what the worker does per
            // re-sort: map the by-identity values main hands over to storage indices, then the one sort.
            for field in [SortField.tags, .comments] where wants("resort.\(field.rawValue)") {
                var byID: [RowID: [UInt8]] = [:]
                byID.reserveCapacity(store.count)
                for i in 0..<UInt32(store.count) {
                    byID[store.identity(i)] = SortKeys.nameKey("\(field.rawValue) value \((Int(i) &* 7_919) % store.count)", isFolder: false)
                }
                let column = ExtraColumnValues.strings(byID)
                let query = ViewQuery(sort: SortDescriptor(field: field, ascending: true))
                out.append(result("resort.\(field.rawValue)", try await samples {
                    let start = self.clock.now
                    let extras = SortExtras.make(sizes: [:], column: column, in: store)
                    let p = Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: query, kindRanks: ranks,
                                               extensionKeys: extensionKeys, extras: extras)
                    withExtendedLifetime(p) {}
                    return self.elapsedMs(since: start)
                }))
            }
            // P2-20: a re-sort with Group by on is the sort plus the partition FolderWorker runs on its result
            // (§4.4 re-sort 100k < 30 ms includes the partition).
            let buckets = DateBuckets(now: Date(), calendar: .autoupdatingCurrent)
            for groupBy in GroupBy.allCases where groupBy != .none && wants("resort.grouped.\(groupBy.rawValue)") {
                let types = env.types
                out.append(result("resort.grouped.\(groupBy.rawValue)", try await samples {
                    let start = self.clock.now
                    let p = Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: ViewQuery(), kindRanks: ranks,
                                               extensionKeys: extensionKeys)
                    let grouped = Grouping.partition(p, store: store, by: groupBy, dateBuckets: buckets, types: types)
                    let ms = self.elapsedMs(since: start)
                    guard grouped.order.count == store.count, !grouped.runs.isEmpty else {
                        throw BenchFailure.check("grouped re-sort by \(groupBy.rawValue) (\(grouped.order.count) of \(store.count) rows)")
                    }
                    return ms
                }))
            }
            // P2-09 review: Name groups of non-ASCII names (CJK, Cyrillic, Greek, precomposed and decomposed accents,
            // fullwidth) cost about what ASCII names cost: the key is cached per first-grapheme prefix. An in-memory
            // store of `size` such names (this budget used to be a debug-build timing in GroupingTests).
            if wants("resort.grouped.nameFirstLetter.nonASCII") {
                let names = Self.nonASCIIStore(count: size, typeIndex: env.types.index(forExtension: "txt", isDirectory: false))
                let nameKeys = SortKeys.nameKeys(names, range: 0..<names.count)
                let types = env.types
                out.append(result("resort.grouped.nameFirstLetter.nonASCII", try await samples {
                    let start = self.clock.now
                    let p = Sorter.permutation(names, nameKeys: nameKeys, searchKeys: nil, query: ViewQuery(), kindRanks: ranks)
                    let grouped = Grouping.partition(p, store: names, by: .nameFirstLetter, dateBuckets: buckets, types: types)
                    let ms = self.elapsedMs(since: start)
                    guard grouped.order.count == names.count, !grouped.runs.isEmpty else {
                        throw BenchFailure.check("non-ASCII Name groups (\(grouped.runs.count) groups, \(grouped.order.count) of \(names.count) rows)")
                    }
                    return ms
                }))
            }
            if wants("filter") {
                out.append(result("filter", try await samples {
                    let start = self.clock.now
                    let search = SortKeys.searchKeys(store)
                    let p = Sorter.permutation(store, nameKeys: keys, searchKeys: search, query: ViewQuery(filter: "42"), kindRanks: ranks)
                    withExtendedLifetime(p) {}
                    return self.elapsedMs(since: start)
                }))
            }
            if wants("pasteboard") {
                let urls = (0..<store.count).map {
                    directory.appending(path: store.name(UInt32($0)), directoryHint: .notDirectory)
                }
                out.append(result("pasteboard", try await samples {
                    let name = "macx-bench-\(UUID().uuidString)"
                    let board = SystemPasteboard(name: name)
                    let start = self.clock.now
                    board.writeFileURLs(urls, cutMarker: false)
                    let ms = self.elapsedMs(since: start)
                    NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally()
                    return ms
                }))
            }
        }

        if wants("modelResort") {
            let values = try await withLoadedModel { watch in
                var ascending = false
                return try await samples {
                    let before = watch.changeEvents
                    let start = self.clock.now
                    watch.model.setQuery(ViewQuery(sort: SortDescriptor(field: .name, ascending: ascending)))
                    ascending.toggle()
                    try await self.waitUntil("re-sort applied", timeout: .seconds(60)) { watch.changeEvents > before }
                    return self.elapsedMs(since: start)
                }
            }
            out.append(result("modelResort", values))
        }

        if wants("diff") {
            let old = try await sortedStore()
            var new = old
            let touched = max(1, old.count / 100)
            for i in 0..<touched {
                var e = old.entry(UInt32(i))
                e.mtime += 1_000_000_000
                new.upsert(e, name: old.name(UInt32(i)))
            }
            new.remove(Set((0..<(touched / 2)).map { UInt32(old.count - 1 - $0) }))
            let txt = env.types.index(forExtension: "txt", isDirectory: false)
            for i in 0..<(touched / 2) {
                let id = 9_000_000_000 + UInt64(i)
                new.upsert(Entry(rowID: id, fileID: id, size: 1, allocSize: 4_096, mtime: 0, ctime: 0, nameOffset: 0,
                                 nameLen: 0, kind: .file, flags: [.readable, .writable], typeIndex: txt),
                           name: "added-\(i).txt")
            }
            let newKeys = SortKeys.nameKeys(new, range: 0..<new.count)
            new.setOrder(Sorter.permutation(new, nameKeys: newKeys, searchKeys: nil, query: ViewQuery(), kindRanks: ranks))
            out.append(result("diff", try await samples {
                let start = self.clock.now
                let r = StoreDiff.diff(old: old, new: new)
                withExtendedLifetime(r) {}
                return self.elapsedMs(since: start)
            }))
        }

        if wants("memory.steady") {
            out.append(result("memory.steady", unit: "MB", try await samples {
                _ = malloc_zone_pressure_relief(nil, 0)
                let before = Machine.footprintBytes()
                var store = try await self.readStore()
                let keys = SortKeys.nameKeys(store, range: 0..<store.count)
                store.setOrder(Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: ViewQuery(), kindRanks: self.ranks))
                _ = malloc_zone_pressure_relief(nil, 0)
                let after = Machine.footprintBytes()
                withExtendedLifetime((store, keys)) {}
                return Double(after - before) / 1_048_576
            }))
        }

        // P2-16 review fix (§4.4 memory): what sorting a loaded 100k folder by an extended column adds to the model,
        // as heap bytes in use (the footprint reuses freed pages, so its delta is not a measure of what is held).
        for field in [SortField.tags, .owner] where wants("memory.extendedSort.\(field.rawValue)") {
            out.append(result("memory.extendedSort.\(field.rawValue)", unit: "MB", try await samples {
                try await self.withLoadedModel { watch in
                    let before = Machine.heapBytesInUse()
                    let resets = watch.changeEvents
                    watch.model.setQuery(ViewQuery(sort: SortDescriptor(field: field, ascending: true)))
                    try await self.waitUntil("sorted by \(field.rawValue)", timeout: .seconds(60)) {
                        watch.changeEvents > resets && !watch.model.extendedSortLoading
                    }
                    let after = Machine.heapBytesInUse()
                    return Double(after - before) / 1_048_576
                }
            }))
        }

        if wants("fsevent.incremental") {
            let values = try await withLoadedModel { watch in
                try await samples {
                    let name = "inc-\(UUID().uuidString).txt"
                    let start = self.clock.now
                    self.sandbox.file("\(self.relativeDir)/\(name)")
                    self.fileCount += 1
                    try await self.waitUntil("incremental FSEvent applied", timeout: .seconds(60)) {
                        watch.model.row(named: name) != nil
                    }
                    return self.elapsedMs(since: start)
                }
            }
            out.append(result("fsevent.incremental", values))
        }

        if wants("fsevent.full") {
            let values = try await withLoadedModel { watch in
                try await samples {
                    let tag = UUID().uuidString.prefix(8)
                    let start = self.clock.now
                    for i in 0..<300 { self.sandbox.file("\(self.relativeDir)/full-\(tag)-\(i).txt") }
                    self.fileCount += 300
                    let target = self.fileCount
                    try await self.waitUntil("full re-read applied", timeout: .seconds(60)) { watch.model.rowCount == target }
                    return self.elapsedMs(since: start)
                }
            }
            out.append(result("fsevent.full", values))
        }

        return out
    }
}

@MainActor
enum Bench {
    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// Creates ${TMPDIR}/macx-bench-<UUID>, runs every metric per size, destroys the sandbox (unless keepFixtures).
    static func run(_ options: BenchOptions, log: (String) -> Void = { _ in }) async throws -> BenchReport {
        let sandbox = try SandboxHandle.make(prefix: "macx-bench")
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        _ = await env.start()
        log("sandbox: \(sandbox.root.path)")
        var metrics: [MetricResult] = []
        var failure: (any Error)?
        do {
            for size in options.sizes {
                let relative = "work/flat-\(size)"
                log("fixture: \(size) files")
                let directory = sandbox.flat(relative, count: size)
                let suite = MetricSuite(env: env, sandbox: sandbox, relativeDir: relative, directory: directory, size: size, options: options)
                metrics += try await suite.runAll()
            }
            let wants: (String) -> Bool = { name in options.metrics.map { filter in filter.contains { name.hasPrefix($0) } } ?? true }
            metrics += try await FolderViewBench.run(options, wants: wants)
            metrics += try await PaletteBench.run(options, wants: wants)
            metrics += try await ScanBench.run(options, env: env, sandbox: sandbox, wants: wants)
            metrics += try await SearchMetrics.run(options, env: env, sandbox: sandbox, wants: wants)
        } catch {
            failure = error
        }
        await env.fileOps.waitUntilIdle()
        var removed = false
        if !options.keepFixtures {
            sandbox.destroy()
            removed = !FileManager.default.fileExists(atPath: sandbox.root.path)
            log(removed ? "sandbox root \(sandbox.root.path) removed" : "WARNING: sandbox \(sandbox.root.path) was not removed")
        }
        if let failure { throw failure }
        return BenchReport(machine: .current(), configuration: configuration, warmups: options.warmups,
                           iterations: options.iterations, metrics: metrics, budgets: nil,
                           sandbox: sandbox.root.path, sandboxRemoved: removed)
    }
}
