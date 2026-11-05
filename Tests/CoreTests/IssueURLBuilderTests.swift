import Foundation
import XCTest
@testable import Core

final class IssueURLBuilderTests: XCTestCase {
    private static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let env = EnvironmentSummary(appVersion: "0.4.0-beta.1", build: "812", channel: "beta",
                                         macOS: "26.1 (25B78)", hardwareModel: "Mac16,10", architecture: "arm64")

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    /// The `id:` values of a form, read from the YAML (simple line scan; the forms are ours).
    private func formIDs(_ name: String) throws -> Set<String> {
        let text = try String(contentsOf: Self.repo.appending(path: ".github/ISSUE_TEMPLATE/\(name)"), encoding: .utf8)
        return Set(text.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("id: ") ? String(t.dropFirst(4)) : nil
        })
    }

    func testFieldIDsMatchTheForms() throws {
        XCTAssertTrue(Set(IssueField.ids(for: .bug)).isSubset(of: try formIDs("bug.yml")))
        XCTAssertTrue(Set(IssueField.ids(for: .feature)).isSubset(of: try formIDs("feature.yml")))
    }

    func testBugURLIsPrefilled() {
        let url = IssueURLBuilder.url(kind: .bug, environment: env)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/roniburd/macExplorer/issues/new?"))
        let q = query(url)
        XCTAssertEqual(q["template"], "bug.yml")
        XCTAssertEqual(q["version"], "0.4.0-beta.1 (812)")
        XCTAssertEqual(q["macos"], "26.1 (25B78)")
        XCTAssertEqual(q["hardware"], "Mac16,10 (arm64)")
        XCTAssertEqual(q["channel"], "beta")
        XCTAssertNil(q["crash-log"])
    }

    func testFeatureURLHasOnlyVersion() {
        let q = query(IssueURLBuilder.url(kind: .feature, environment: env))
        XCTAssertEqual(q["template"], "feature.yml")
        XCTAssertEqual(q["version"], "0.4.0-beta.1 (812)")
        XCTAssertNil(q["macos"])
    }

    func testReservedCharactersRoundTrip() {
        let excerpt = "a&b=c+d #1 ? 100% ~/Docs/Ünïcødé 📁/x"
        let url = IssueURLBuilder.url(kind: .bug, environment: env, title: "Crash: A&B", crashExcerpt: excerpt)
        let q = query(url)
        XCTAssertEqual(q["crash-log"], excerpt)
        XCTAssertEqual(q["title"], "Crash: A&B")
        XCTAssertFalse(url.absoluteString.contains("+"), "a literal + would decode as a space")
    }

    func testTruncationNeverExceedsCapAndKeepsMarker() {
        let huge = String(repeating: "frame 📁 &x\n", count: 5000)
        let url = IssueURLBuilder.url(kind: .bug, environment: env, crashExcerpt: huge)
        XCTAssertLessThanOrEqual(url.absoluteString.count, IssueURLBuilder.maxLength)
        let log = query(url)["crash-log"] ?? ""
        XCTAssertTrue(log.hasSuffix(IssueURLBuilder.truncationMarker))
        XCTAssertTrue(huge.hasPrefix(String(log.dropLast(IssueURLBuilder.truncationMarker.count))))
        XCTAssertGreaterThan(log.count, 1000, "uses most of the budget")
    }

    func testShortExcerptIsNotTruncated() {
        let q = query(IssueURLBuilder.url(kind: .bug, environment: env, crashExcerpt: "short"))
        XCTAssertEqual(q["crash-log"], "short")
    }

    func testBetaBuildDetection() {
        XCTAssertTrue(env.isBetaBuild)
        var r = env
        r.appVersion = "0.4.0"
        XCTAssertFalse(r.isBetaBuild)
    }
}
