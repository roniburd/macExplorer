import Darwin
import Foundation
import Core
import MacxFS
import Synchronization

/// Phase 3 (P3-13) `search.*` family: the crawler, filters, saved searches and cancellation, run headless through
/// CoreEnvironment on fixtures inside the scenario sandbox only. Spotlight is never queried (the sandboxed
/// environment's metadata query is the fake); every search root is the scenario's own `work` folder or sandbox.
enum SearchScenarios {
    @MainActor
    static func run(_ ctx: ScenarioContext, _ spec: SearchSpec, timeout: Duration = .seconds(30)) async throws -> SearchResultsModel {
        let plan = await ctx.env.planSearch(spec)
        switch plan.engine {
        case .crawler, .spotlight: break
        case .none, .folderFilter: throw ScenarioFailure("expected a streaming plan for '\(spec.text)', got \(plan.engine)")
        }
        let model = ctx.env.makeSearchResults(spec, plan: plan)
        model.start()
        try await ctx.waitUntil("search finishes", timeout: timeout) { !isSearching(model) }
        return model
    }

    @MainActor static func isSearching(_ m: SearchResultsModel) -> Bool { if case .searching = m.state { true } else { false } }
    @MainActor static func isComplete(_ m: SearchResultsModel) -> Bool { if case .complete = m.state { true } else { false } }
    @MainActor static func names(_ m: SearchResultsModel) -> Set<String> { Set((0..<m.rowCount).map { m.name(atRow: $0) }) }

    static let all: [CoreScenario] = [
        CoreScenario("search.crawlFindsNested") { ctx in
            ctx.file("needle-top.txt"); ctx.file("a/b/c/needle-deep.txt"); ctx.file("a/other.txt")
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            try ctx.expect(isComplete(m), "complete: \(m.state)")
            try ctx.expectEqual(names(m), ["needle-top.txt", "needle-deep.txt"], "nested matches")
        },
        CoreScenario("search.crawlSkipsPackagesAndHidden") { ctx in
            ctx.file("X.app/Contents/needle-pkg.txt"); ctx.file(".hidden/needle-dot.txt"); ctx.file("needle.txt")
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            try ctx.expectEqual(names(m), ["needle.txt"], "packages and hidden folders are skipped by default")
            ctx.env.settings.searchIncludesPackages = true
            defer { ctx.env.settings.searchIncludesPackages = false }
            m.rerun()
            try await ctx.waitUntil("rerun with packages") { isComplete(m) && m.rowCount == 2 }
            try ctx.expectEqual(names(m), ["needle.txt", "needle-pkg.txt"], "packages searched once enabled; hidden still skipped")
        },
        CoreScenario("search.crawlSymlinkLoopTerminates") { ctx in
            ctx.file("t/a/needle.txt")
            try ctx.symlink("t/a/loop", to: "..")
            try ctx.symlink("t/self", to: ".")
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work), timeout: .seconds(10))
            defer { m.close() }
            try ctx.expect(isComplete(m), "complete: \(m.state)")
            try ctx.expectEqual(m.rowCount, 1, "one match, symlinks never followed, crawl terminated")
        },
        CoreScenario("search.crawlUnreadableContinues") { ctx in
            ctx.file("locked/needle-a.txt"); ctx.file("open/needle-b.txt")
            try ctx.setMode(ctx.path("locked"), 0o000)
            let m: SearchResultsModel
            do {
                m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work))
            } catch {
                try? ctx.setMode(ctx.path("locked"), 0o755)
                throw error
            }
            defer { m.close() }
            try ctx.setMode(ctx.path("locked"), 0o755)
            try ctx.expect(isComplete(m), "complete: \(m.state)")
            try ctx.expectEqual(names(m), ["needle-b.txt"], "unreadable folder skipped, search continued")
            try ctx.expectEqual(m.notices, [.skippedLocations(count: 1)], "skipped notice")
        },
        CoreScenario("search.syntaxAndFilters") { ctx in
            ctx.file("big.pdf", bytes: 5_000); ctx.file("small.pdf", bytes: 10); ctx.file("big.txt", bytes: 5_000)
            try ctx.setModificationDate(ctx.file("old.pdf", bytes: 5_000), Date(timeIntervalSinceNow: -400 * 86_400))
            let m = try await run(ctx, SearchSpec(text: "kind:pdf size:>1KB modified:thisyear", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            try ctx.expectEqual(names(m), ["big.pdf"], "kind, size and date filters")
            try ctx.expect(m.plan?.diagnostics.isEmpty ?? false, "no syntax diagnostics: \(String(describing: m.plan?.diagnostics))")
        },
        CoreScenario("search.cancelStopsCrawl") { ctx in
            // The real crawler, held after its first batch (CrawlGate) so Stop lands mid-crawl however the runner
            // schedules the crawl's lanes against the main actor. How the crawler reacts to cancellation is covered by
            // SubtreeCrawlerTests; this checks that Stop cancels the engine and keeps the rows already shown.
            for i in 0..<100 { ctx.flat("bulk/d\(i)", count: 40) }
            let total = 100 * 40
            let spec = SearchSpec(text: "file", scope: .subfolders, root: ctx.work)
            let plan = await ctx.env.planSearch(spec)
            guard case .crawler(let root, let criteria) = plan.engine else {
                throw ScenarioFailure("expected a crawler plan, got \(plan.engine)")
            }
            let search = ctx.env.searchContext()
            let lanes = ctx.env.lanes, mounts = ctx.env.volumes.mountTableStore, types = ctx.env.types
            let permissions = search.crawlPermissions()
            var options = CrawlOptions()
            options.maxResults = SearchResultsModel.resultLimit
            let crawlOptions = options
            let gate = CrawlGate()
            defer { gate.open() }
            let m = SearchResultsModel(title: spec.text, events: { generation in
                gate.forward(SubtreeCrawler.crawl(root: root, criteria: criteria, options: crawlOptions, permissions: permissions,
                                                  generation: generation, lanes: lanes, mountTable: mounts, types: types))
            }, context: search)
            defer { m.close() }
            m.start()
            try await ctx.waitUntil("the first rows show while the crawl is held") { gate.isHeld && m.rowCount > 0 }
            try ctx.expect(isSearching(m), "still searching while held: \(m.state)")
            m.stop()
            let count = m.rowCount
            guard case .stopped = m.state else { throw ScenarioFailure("state after Stop: \(m.state)") }
            try await ctx.waitUntil("Stop cancels the crawl's event stream") { gate.wasCancelled }
            gate.open()
            try await Task.sleep(for: .milliseconds(300))      // a negative check: nothing may land after Stop
            guard case .stopped = m.state else { throw ScenarioFailure("state after the crawl was let go: \(m.state)") }
            try ctx.expectEqual(m.rowCount, count, "no rows land after Stop")
            try ctx.expect(count <= gate.forwardedRows && count < total, "only the rows shown before Stop (\(count) of \(total))")
        },
        CoreScenario("search.resultsFollowFileOps") { ctx in
            ctx.file("a/needle-1.txt"); ctx.file("b/needle-2.txt"); ctx.file("b/needle-3.txt")
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.work))
            defer { m.close() }
            try ctx.expectEqual(m.rowCount, 3, "three matches")
            _ = await ctx.perform(.trash([ctx.path("b/needle-2.txt")]))
            _ = await ctx.perform(.rename(ctx.path("b/needle-3.txt"), to: "renamed-3.txt"))
            try await ctx.waitUntil("results follow the trash and the rename") { names(m) == ["needle-1.txt", "renamed-3.txt"] }
            try ctx.expect(ctx.exists(ctx.path("b/renamed-3.txt")), "renamed on disk")
            try ctx.expect(!ctx.exists(ctx.path("b/needle-2.txt")), "trashed on disk (sandbox Trash)")
            try ctx.expect(isComplete(m), "never re-run: \(m.state)")
        },
        CoreScenario("search.savedSearchRoundTrip") { ctx in
            let file = ctx.path("settings.json")
            let storage = FileSettingsStorage(fileURL: file)
            let s = Settings(storage: storage, home: ctx.work)
            let spec = SearchSpec(text: "tax kind:pdf", scope: .subfolders, filters: SearchFilters(modified: .relative(.lastMonth)), root: ctx.work)
            _ = s.addSavedSearch(name: "Taxes", spec: spec)
            storage.flush()
            let reloaded = Settings(storage: FileSettingsStorage(fileURL: file), home: ctx.work)
            try ctx.expectEqual(reloaded.savedSearches.map(\.spec), [spec], "saved search survives a reload")
            try ctx.expectEqual(reloaded.savedSearches.map(\.name), ["Taxes"], "its name too")
            try ctx.expectEqual(SearchSpec(url: spec.url), spec, "history URL round-trip")
        },
        CoreScenario("search.crawlDoesNotCrossImage", requires: .diskImages) { ctx in
            let image = try await ctx.image("search", .apfs, sizeMB: 16)
            ctx.file(at: image.mountPoint.appending(path: "needle-in-image.txt"))
            ctx.file("needle-here.txt")
            await ctx.env.volumes.refresh()
            // The image mounts inside the sandbox, not under `work`: search the sandbox root, which contains both.
            let m = try await run(ctx, SearchSpec(text: "needle", scope: .subfolders, root: ctx.sandbox.root))
            defer { m.close() }
            try ctx.expect(isComplete(m), "complete: \(m.state)")
            try ctx.expectEqual(names(m), ["needle-here.txt"], "mount points are not crossed")
        },
    ]
}

/// Forwards a crawl's events to a SearchResultsModel and holds them after the first batch until `open()`, so a
/// scenario can act mid-crawl without racing the crawler. Records whether the model cancelled the stream.
final class CrawlGate: Sendable {
    private let state = Mutex((held: false, opened: false, cancelled: false, forwardedRows: 0))

    var isHeld: Bool { state.withLock { $0.held && !$0.opened } }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }
    var forwardedRows: Int { state.withLock { $0.forwardedRows } }

    func open() { state.withLock { $0.opened = true } }

    func forward(_ crawl: AsyncStream<SearchEvent>) -> AsyncStream<SearchEvent> {
        let (stream, continuation) = AsyncStream<SearchEvent>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { [self] in
            for await event in crawl {
                continuation.yield(event)
                guard case .batch(let b) = event else { continue }
                let first = state.withLock { s -> Bool in
                    s.forwardedRows += b.batch.count
                    guard !s.held else { return false }
                    s.held = true
                    return true
                }
                if first { await waitUntilOpen() }
            }
            continuation.finish()
        }
        continuation.onTermination = { [self] termination in
            if case .cancelled = termination { state.withLock { $0.cancelled = true } }
            task.cancel()
        }
        return stream
    }

    private func waitUntilOpen() async {
        while !state.withLock({ $0.opened }) && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
