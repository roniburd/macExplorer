import XCTest
import Darwin
@testable import Core
@testable import MacxFS
import MacxFixtures

final class SubtreeCrawlerTests: XCTestCase {
    var sandbox: Sandbox!
    let types = TypeRegistry()

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    struct Collected { var paths: [String] = []; var summary: SearchSummary?; var failure: SearchFailure?; var progress = 0 }

    func collect(_ stream: AsyncStream<SearchEvent>) async -> Collected {
        var c = Collected()
        for await e in stream {
            switch e {
            case .batch(let b):
                let parent = MountTable.standardize(b.parent.path(percentEncoded: false))   // standardizedFileURL drops /private on macOS 26
                for i in 0..<b.batch.count { c.paths.append(parent + "/" + b.batch.name(at: i)) }
            case .completed(let s): c.summary = s
            case .failed(let f): c.failure = f
            case .progress: c.progress += 1
            default: break
            }
        }
        return c
    }

    func rel(_ paths: [String]) -> Set<String> {
        let root = MountTable.standardize(sandbox.root.path(percentEncoded: false)) + "/"
        return Set(paths.map { String($0.dropFirst(root.count)) })
    }

    func crawl(_ term: String, options: CrawlOptions = CrawlOptions(), permissions: CrawlPermissions = .none,
               mountTable: MountTableStore = MountTableStore(), lanes: LanePool = LanePool(),
               read: SubtreeCrawler.DirectoryRead? = nil) -> AsyncStream<SearchEvent> {
        let criteria = SearchCriteria(nameTerms: [NameTerm(term)])
        if let read {
            return SubtreeCrawler.crawl(root: sandbox.root, criteria: criteria, options: options, permissions: permissions,
                                        generation: .initial.next(), lanes: lanes, mountTable: mountTable, types: types, read: read)
        }
        return SubtreeCrawler.crawl(root: sandbox.root, criteria: criteria, options: options, permissions: permissions,
                                    generation: .initial.next(), lanes: lanes, mountTable: mountTable, types: types)
    }

    func testFindsNestedMatchesBreadthFirst() async throws {
        try sandbox.createFile("needle-top.txt")
        try sandbox.createFile("a/b/c/needle-deep.txt")
        try sandbox.createFile("a/needle-mid.txt")
        try sandbox.createFile("a/b/other.txt")
        try sandbox.createDirectory("Needles")                     // folders match too
        let c = await collect(crawl("needle"))
        XCTAssertEqual(rel(c.paths), ["needle-top.txt", "a/needle-mid.txt", "a/b/c/needle-deep.txt", "Needles"])
        XCTAssertEqual(c.paths.last.map { ($0 as NSString).lastPathComponent }, "needle-deep.txt")   // deepest last
        XCTAssertEqual(c.summary?.resultCount, 4)
        XCTAssertEqual(c.summary?.directoriesScanned, 5)            // root, a, a/b, a/b/c, Needles
        XCTAssertNil(c.failure)
    }

    func testGlobAndFiltersApply() async throws {
        try sandbox.createFile("x/report1.doc")
        try sandbox.createFile("x/report12.doc")
        try sandbox.createFile("x/report1.doc.zip")
        let c = await collect(crawl("report?.doc"))
        XCTAssertEqual(rel(c.paths), ["x/report1.doc"])
    }

    // Review Focus 4
    func testCrawlerDoesNotFollowSymlinkLoops() async throws {
        try sandbox.createFile("tree/a/needle.txt")
        try sandbox.createSymlink("tree/a/loop", target: "..")
        try sandbox.createSymlink("tree/self", target: ".")
        try sandbox.createSymlink("tree/a/needle-link", target: "needle.txt")
        let c = await collect(crawl("needle"))
        XCTAssertEqual(rel(c.paths), ["tree/a/needle.txt", "tree/a/needle-link"])   // the link matches by name, once
        XCTAssertNotNil(c.summary)
    }

    // Review Focus 4
    func testCrawlerDoesNotCrossMountPoints() async throws {
        try sandbox.createFile("mnt/needle-inside.txt")
        try sandbox.createFile("needle-outside.txt")
        let mnt = sandbox.url("mnt")
        let fake = VolumeInfo(id: VolumeID(raw: "mnt:\(mnt.path(percentEncoded: false))"), mountPoint: mnt, name: "Fake",
                              format: "APFS", isBoot: false, isInternal: false, isRemovable: true, isEjectable: true,
                              isLocal: true, isReadOnly: false, isBrowsable: true, totalCapacity: nil,
                              capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
        let c = await collect(crawl("needle", mountTable: MountTableStore(MountTable([fake]))))
        XCTAssertEqual(rel(c.paths), ["needle-outside.txt"])
    }

    func testCrawlerDoesNotCrossRealDiskImage() async throws {
        guard DiskImage.isAvailable else { throw XCTSkip("hdiutil unavailable") }
        let image = try DiskImage.create(in: sandbox, format: .apfs, sizeMB: 16, volumeName: "MACXCRAWL")
        try sandbox.createFile(image.relativeMountPath + "/needle-in-image.txt")
        try sandbox.createFile("needle-here.txt")
        let lanes = LanePool()
        let volumes = try await lanes.perform(on: .unknown) { _ in try SystemVolumeScanner().scan() }
        let c = await collect(crawl("needle", mountTable: MountTableStore(MountTable(volumes)), lanes: lanes))
        XCTAssertEqual(rel(c.paths), ["needle-here.txt"])
    }

    // Review Focus 4
    func testCrawlerSkipsUnreadableAndContinues() async throws {
        try sandbox.createFile("locked/needle-hidden-by-mode.txt")
        try sandbox.createFile("open/needle.txt")
        try sandbox.setMode("locked", 0o000)
        let c = await collect(crawl("needle"))
        XCTAssertEqual(rel(c.paths), ["open/needle.txt"])
        let skipped = try XCTUnwrap(c.summary?.skipped)
        XCTAssertEqual(skipped.map { ($0.path as NSString).lastPathComponent }, ["locked"])
        XCTAssertEqual(skipped.first?.reason, .permission(EACCES))
        XCTAssertEqual(c.summary?.skippedTotal, 1)
    }

    // Review Focus 4
    func testCrawlerSkipsBlockedPrefixesBelowRoot() async throws {
        try sandbox.createFile("Protected/needle.txt")
        try sandbox.createFile("Free/needle.txt")
        let root = sandbox.root.path(percentEncoded: false).trimmingSuffixSlash
        let reads = Locked<[String]>([])
        let spy: SubtreeCrawler.DirectoryRead = { url, g, o, t, ctx, emit in
            reads.withLock { $0.append(url.path(percentEncoded: false).trimmingSuffixSlash) }
            return SubtreeCrawler.defaultRead(url, g, o, t, ctx, emit)
        }
        let perms = CrawlPermissions(blockedPrefixes: [root + "/Protected", root])   // root itself is dropped as relevant
        let c = await collect(crawl("needle", permissions: perms, read: spy))
        XCTAssertEqual(rel(c.paths), ["Free/needle.txt"])
        XCTAssertEqual(c.summary?.skipped, [SkippedLocation(path: root + "/Protected", reason: .protectedLocation)])
        XCTAssertFalse(reads.value.contains(root + "/Protected"), "a blocked folder must never be opened")
        XCTAssertEqual(perms.relevant(forRoot: root).blockedPrefixes, [root + "/Protected"])
        let relevant = perms.relevant(forRoot: root)       // unfiltered `perms` holds the root itself, blocking everything
        XCTAssertTrue(relevant.isBlocked(root + "/Protected/x/y"))
        XCTAssertFalse(relevant.isBlocked(root + "/ProtectedNot"))
        XCTAssertTrue(relevant.isBlocked(MountTable.standardize(root) + "/Protected"), "/private and /var spellings match")
    }

    func testPackagesAndHiddenAreSkippedUnlessEnabled() async throws {
        try sandbox.createFile("Thing.app/Contents/needle-pkg.txt")
        try sandbox.createFile(".hidden/needle-dot.txt")
        try sandbox.createFile(".needle-file")
        let plain = await collect(crawl("needle"))
        XCTAssertEqual(rel(plain.paths), [])
        var options = CrawlOptions()
        options.includePackages = true
        options.includeHidden = true
        let all = await collect(crawl("needle", options: options))
        XCTAssertEqual(rel(all.paths), ["Thing.app/Contents/needle-pkg.txt", ".hidden/needle-dot.txt", ".needle-file"])
        let app = await collect(crawl("*.app"))
        XCTAssertEqual(rel(app.paths), ["Thing.app"])           // the package itself is a result
    }

    func testResultCapTruncates() async throws {
        try FixtureTree.flat(in: sandbox, at: "many", count: 300, prefix: "hit-")
        var options = CrawlOptions()
        options.maxResults = 100
        let c = await collect(crawl("hit", options: options))
        XCTAssertEqual(c.paths.count, 100)
        XCTAssertEqual(c.summary?.truncated, true)
        XCTAssertEqual(c.summary?.resultCount, 100)
    }

    func testStalledDirectoryIsSkippedWithoutWaiting() async throws {
        try sandbox.createFile("slow/needle-slow.txt")
        try sandbox.createFile("fast/needle-fast.txt")
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(200), tick: .milliseconds(50)))
        let stalling: SubtreeCrawler.DirectoryRead = { url, g, o, t, ctx, emit in
            if url.lastPathComponent == "slow" { Thread.sleep(forTimeInterval: 1.5) }      // no heartbeat
            return SubtreeCrawler.defaultRead(url, g, o, t, ctx, emit)
        }
        let start = ContinuousClock.now
        let c = await collect(crawl("needle", lanes: lanes, read: stalling))
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1_200), "the crawl must not wait for the stalled read")
        XCTAssertEqual(rel(c.paths), ["fast/needle-fast.txt"])
        XCTAssertEqual(c.summary?.skipped.first?.reason, .unresponsive)
    }

    func testUnreadableRootFails() async throws {
        try sandbox.createDirectory("r")
        try sandbox.setMode("r", 0o000)
        let stream = SubtreeCrawler.crawl(root: sandbox.url("r"), criteria: SearchCriteria(nameTerms: [NameTerm("x")]),
                                          options: CrawlOptions(), permissions: .none, generation: .initial.next(),
                                          lanes: LanePool(), mountTable: MountTableStore(), types: types)
        let c = await collect(stream)
        XCTAssertEqual(c.failure, .rootUnreadable(.permissionPOSIX))
        XCTAssertNil(c.summary)
    }

    func testCancellingIterationStopsTheCrawl() async throws {
        try FixtureTree.deep(in: sandbox, at: "deep", depth: 6, breadth: 4, filesPerDir: 20)
        let reads = Locked(0)
        let counting: SubtreeCrawler.DirectoryRead = { url, g, o, t, ctx, emit in
            reads.withLock { $0 += 1 }
            return SubtreeCrawler.defaultRead(url, g, o, t, ctx, emit)
        }
        // The stream lives only inside the consumer: leaving the loop releases it, which terminates it.
        let root = sandbox.root, types = types
        let consumer = Task {
            let stream = SubtreeCrawler.crawl(root: root, criteria: SearchCriteria(nameTerms: [NameTerm("")]),   // matches everything
                                              options: CrawlOptions(), permissions: .none, generation: .initial.next(),
                                              lanes: LanePool(), mountTable: MountTableStore(), types: types, read: counting)
            for await e in stream { if case .batch = e { break } }
        }
        await consumer.value
        try await Task.sleep(for: .milliseconds(300))
        let afterCancel = reads.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(reads.value, afterCancel, "no directory reads start after the consumer stopped")
        XCTAssertLessThan(afterCancel, 4 * 4 * 4 * 4, "the crawl stopped early")
    }

    func testAtMostTwoReadsInFlightOnScanLanesWithoutMaterialization() async throws {
        for d in 0..<8 { try sandbox.createFile("d\(d)/e/needle-\(d).txt") }
        struct Counts { var current = 0, peak = 0, sawMaterialization = false }
        let counts = Locked(Counts())
        let spy: SubtreeCrawler.DirectoryRead = { url, g, o, t, ctx, emit in
            counts.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current); if !o.noMaterialization { $0.sawMaterialization = true } }
            Thread.sleep(forTimeInterval: 0.02)
            defer { counts.withLock { $0.current -= 1 } }
            return SubtreeCrawler.defaultRead(url, g, o, t, ctx, emit)
        }
        let lanes = LanePool()
        let c = await collect(crawl("needle", lanes: lanes, read: spy))
        XCTAssertEqual(c.paths.count, 8)
        XCTAssertEqual(counts.value.peak, 2, "two directory reads overlap, never more")
        XCTAssertFalse(counts.value.sawMaterialization, "every read asks for noMaterialization")
        let scanLanes = await lanes.liveLaneCount(of: .unknown, .scan)
        let readLanes = await lanes.liveLaneCount(of: .unknown, .read)
        XCTAssertGreaterThan(scanLanes, 0)
        XCTAssertEqual(readLanes, 0, "the crawler never uses browsing (.read) lanes")
    }

    func testSkippedListCapsAtFiftyButCountsAll() async throws {
        for i in 0..<60 {
            try sandbox.createDirectory("locked-\(i)")
            try sandbox.setMode("locked-\(i)", 0o000)
        }
        let c = await collect(crawl("needle"))
        XCTAssertEqual(c.summary?.skipped.count, 50)
        XCTAssertEqual(c.summary?.skippedTotal, 60)
    }

    func testProgressIsThrottledByInterval() async throws {
        try FixtureTree.deep(in: sandbox, at: "deep", depth: 3, breadth: 3, filesPerDir: 2)
        var quiet = CrawlOptions()
        quiet.progressInterval = .seconds(3_600)
        let none = await collect(crawl("x", options: quiet))
        XCTAssertEqual(none.progress, 0)
        var chatty = CrawlOptions()
        chatty.progressInterval = .zero
        let every = await collect(crawl("x", options: chatty))
        XCTAssertEqual(every.progress, every.summary?.directoriesScanned)
    }

    func testOneShotValueFirstValueWins() async {
        let box = OneShotValue<Int>()
        XCTAssertTrue(box.resume(1))
        XCTAssertFalse(box.resume(2))
        let v = await box.value()
        XCTAssertEqual(v, 1)
        let late = OneShotValue<Int>()
        async let waited = late.value()
        try? await Task.sleep(for: .milliseconds(20))
        late.resume(7)
        let w = await waited
        XCTAssertEqual(w, 7)
    }

    func testCancellingTheConsumingTaskStopsTheCrawl() async throws {
        try FixtureTree.deep(in: sandbox, at: "deep", depth: 5, breadth: 4, filesPerDir: 10)
        let reads = Locked(0)
        let counting: SubtreeCrawler.DirectoryRead = { url, g, o, t, ctx, emit in
            reads.withLock { $0 += 1 }
            return SubtreeCrawler.defaultRead(url, g, o, t, ctx, emit)
        }
        let stream = crawl("", read: counting)
        let firstBatch = Locked(false)
        let consumer = Task {
            for await e in stream { if case .batch = e { firstBatch.withLock { $0 = true } } }
        }
        while !firstBatch.value { try await Task.sleep(for: .milliseconds(5)) }
        consumer.cancel()
        await consumer.value
        try await Task.sleep(for: .milliseconds(300))
        let afterCancel = reads.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(reads.value, afterCancel, "no directory reads start after the consuming task was cancelled")
        XCTAssertLessThan(afterCancel, 4 * 4 * 4 * 4, "the crawl stopped early")
    }

    func testBatchesCarryTheGeneration() async throws {
        try sandbox.createFile("needle.txt")
        let gen = Generation.initial.next().next()
        let stream = SubtreeCrawler.crawl(root: sandbox.root, criteria: SearchCriteria(nameTerms: [NameTerm("needle")]),
                                          options: CrawlOptions(), permissions: .none, generation: gen,
                                          lanes: LanePool(), mountTable: MountTableStore(), types: types)
        for await e in stream { if case .batch(let b) = e { XCTAssertEqual(b.batch.generation, gen) } }
    }
}

/// Lock-protected value for spies that lane threads call concurrently.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

private extension String {
    var trimmingSuffixSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}
