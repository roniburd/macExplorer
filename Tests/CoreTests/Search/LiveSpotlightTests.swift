import XCTest
import Synchronization
@testable import Core
@testable import MacxFS
import MacxFixtures

/// Live `NSMetadataQuery` integration, scoped ONLY to a sandbox this test creates ($TMPDIR/macx-tests-*). It never
/// queries "This Mac" or any real folder, and never asks Spotlight to index anything (no mdimport / mdutil -i).
/// Spotlight usually does not index $TMPDIR, so these tests skip when the probe file never shows up.
final class LiveSpotlightTests: XCTestCase {
    var sandbox: Sandbox!
    var token = ""
    var request: SpotlightRequest!

    override func setUp() async throws {
        let status = await MdutilIndexStatus(lanes: LanePool()).status(ofVolumeAt: URL(filePath: "/"))
        guard status == .enabled else { throw XCTSkip("Spotlight indexing is disabled on /") }
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        token = "macxprobe" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        _ = try sandbox.createFile("\(token).txt", contents: Data("macx spotlight probe".utf8))
        _ = try sandbox.createFile("other.txt")
        request = SpotlightRequest(criteria: SearchCriteria(nameTerms: [NameTerm(token)]), contentTerms: [],
                                   scope: .folders([sandbox.root]))
    }

    /// Waits up to `seconds` for `found` to report a hit; returns the collected names (empty when not indexed).
    func collect<E: Sendable>(_ stream: AsyncStream<E>, seconds: Int = 15,
                              names: @escaping @Sendable (E) -> [String]) async -> [String] {
        let token = self.token
        let collector = Task {
            var out: [String] = []
            for await e in stream {
                out += names(e)
                if out.contains(where: { $0.hasPrefix(token) }) { break }
            }
            return out
        }
        let timer = Task { try await Task.sleep(for: .seconds(seconds)); collector.cancel() }
        defer { timer.cancel() }
        return await collector.value
    }

    func testSystemQueryStreamsSandboxProbe() async throws {
        let found = await collect(SystemMetadataQuery().run(request)) { e -> [String] in
            switch e {
            case .added(let items), .updated(let items): return items.map(\.name)
            default: return []
            }
        }
        guard !found.isEmpty else { throw XCTSkip("Spotlight does not index the test sandbox ($TMPDIR)") }
        XCTAssertEqual(found, ["\(token).txt"])
    }

    func testSpotlightSearchOverSystemQuery() async throws {
        let stream = SpotlightSearch.events(request, query: SystemMetadataQuery(), includeHidden: false,
                                            generation: .initial.next())
        let found = await collect(stream) { e -> [String] in
            guard case .batch(let b) = e else { return [] }
            return (0..<b.batch.count).map { b.batch.name(at: $0) }
        }
        guard !found.isEmpty else { throw XCTSkip("Spotlight does not index the test sandbox ($TMPDIR)") }
        XCTAssertEqual(found, ["\(token).txt"])
    }
}

/// SystemMetadataQuery's confinement (P3-05): the query is built, started and its notifications delivered on the
/// private queue, never on main. Scoped ONLY to a fresh sandbox; it does not need the sandbox to be indexed (an
/// unindexed scope still gathers, with zero results), so unlike LiveSpotlightTests it runs on every machine.
final class SystemMetadataQueryConfinementTests: XCTestCase {
    func testQueryRunsOffMainOnItsPrivateQueue() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        _ = try sandbox.createFile("a.txt")
        let seen = Mutex<[(String, Bool, String?)]>([])
        let query = SystemMetadataQuery { label in
            seen.withLock { $0.append((label, Thread.isMainThread, OperationQueue.current?.name)) }
        }
        let request = SpotlightRequest(criteria: SearchCriteria(nameTerms: [NameTerm("macx-none-\(UUID().uuidString)")]),
                                       contentTerms: [], scope: .folders([sandbox.root]))
        let collector = Task { () -> [MetadataQueryEvent] in
            var out: [MetadataQueryEvent] = []
            for await e in query.run(request) {
                out.append(e)
                if case .gatheringFinished = e { break }
                if case .failed = e { break }
            }
            return out
        }
        let timer = Task { try await Task.sleep(for: .seconds(30)); collector.cancel() }
        defer { timer.cancel() }
        let events = await collector.value
        if events.contains(where: { if case .failed = $0 { true } else { false } }) {
            throw XCTSkip("NSMetadataQuery could not start (Spotlight unavailable)")
        }
        let labels = seen.withLock { $0 }
        XCTAssertEqual(labels.first?.0, "begin")
        XCTAssertTrue(labels.contains { $0.0 == "finished" }, "\(labels.map(\.0)) \(events)")
        for (label, onMain, queue) in labels {
            XCTAssertFalse(onMain, "\(label) ran on the main thread")
            XCTAssertEqual(queue, "com.macexplorer.spotlight", label)
        }
    }

    /// An empty kinds / extensions set reaches NSMetadataQuery as an always-false metadata comparison, never as
    /// FALSEPREDICATE (which raises NSInvalidArgumentException and kills the process). Sandbox-scoped only.
    func testEmptyKindsAndExtensionsDoNotCrashTheQuery() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        _ = try sandbox.createFile("a.pdf")
        for criteria in [SearchCriteria(kinds: []), SearchCriteria(nameTerms: [NameTerm("a")], kinds: [.image], extensions: [])] {
            let request = SpotlightRequest(criteria: criteria, contentTerms: [], scope: .folders([sandbox.root]))
            let collector = Task { () -> [MetadataQueryEvent] in
                var out: [MetadataQueryEvent] = []
                for await e in SystemMetadataQuery().run(request) {
                    out.append(e)
                    if case .gatheringFinished = e { break }
                    if case .failed = e { break }
                }
                return out
            }
            let timer = Task { try await Task.sleep(for: .seconds(30)); collector.cancel() }
            let events = await collector.value
            timer.cancel()
            for e in events { if case .added(let items) = e { XCTFail("unexpected results \(items)") } }
        }
    }
}
