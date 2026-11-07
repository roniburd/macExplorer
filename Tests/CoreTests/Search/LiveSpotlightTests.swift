import XCTest
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
