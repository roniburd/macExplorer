import XCTest
import MacxPluginKit
@testable import GitHubProvider

final class GitHubAddressTests: XCTestCase {
    private func loc(_ repo: String, _ ref: String? = nil, _ path: [String] = []) -> RemoteLocation {
        RemoteLocation(provider: GitHubAddress.providerID, repo: repo, ref: ref, path: path)
    }

    func testWebURLForms() {
        for text in ["https://github.com/octo/demo", "http://github.com/octo/demo", "github.com/octo/demo",
                     "https://www.github.com/octo/demo/", "github.com/octo/demo.git", "  'github.com/octo/demo'  ",
                     "https://github.com/octo/demo?tab=readme#top", "https://github.com/octo/demo/pulls"] {
            XCTAssertEqual(GitHubAddress.parse(text), loc("octo/demo"), text)
        }
    }

    func testTreeAndBlobKeepTheWholeRemainderAsRef() {
        XCTAssertEqual(GitHubAddress.parse("https://github.com/octo/demo/tree/main"), loc("octo/demo", "main"))
        XCTAssertEqual(GitHubAddress.parse("github.com/octo/demo/tree/feature/x/src"), loc("octo/demo", "feature/x/src"))
        XCTAssertEqual(GitHubAddress.parse("github.com/octo/demo/blob/main/src/main.swift"),
                       loc("octo/demo", "main/src/main.swift"))
        XCTAssertEqual(GitHubAddress.parse("github.com/octo/demo/tree/main/My%20Docs"), loc("octo/demo", "main/My Docs"))
    }

    func testShortForms() {
        XCTAssertEqual(GitHubAddress.parse("gh:octo/demo"), loc("octo/demo"))
        XCTAssertEqual(GitHubAddress.parse("GH:octo/demo"), loc("octo/demo"))
        XCTAssertEqual(GitHubAddress.parse("gh:octo/demo@v1.2"), loc("octo/demo", "v1.2"))
        XCTAssertEqual(GitHubAddress.parse("gh:octo/demo@main/src/lib"), loc("octo/demo", "main/src/lib"))
        XCTAssertEqual(GitHubAddress.parse("gh:octo/demo/src/lib"), loc("octo/demo", nil, ["src", "lib"]))
        XCTAssertEqual(GitHubAddress.parse("gh:octo/demo/"), loc("octo/demo"))
    }

    func testRejectsWhatIsNotARepo() {
        for text in ["", "gh:", "gh:octo", "gh:octo/", "gh:octo/demo@", "github.com", "github.com/octo",
                     "gitlab.com/octo/demo", "github.com/settings/profile", "github.com/orgs/octo",
                     "github.com/-bad/demo", "github.com/octo/..", "/Users/me/github.com/octo/demo", "src/lib"] {
            XCTAssertNil(GitHubAddress.parse(text), text)
        }
    }

    func testSplitPrefersTheLongestKnownRef() {
        let refs: Set = ["main", "feature", "feature/x"]
        XCTAssertEqual(GitHubAddress.split("feature/x/src", knownRefs: refs).ref, "feature/x")
        XCTAssertEqual(GitHubAddress.split("feature/x/src", knownRefs: refs).path, ["src"])
        XCTAssertEqual(GitHubAddress.split("main", knownRefs: refs).path, [])
        let unknown = GitHubAddress.split("0123abc/docs", knownRefs: refs)   // a SHA: not in the list
        XCTAssertEqual(unknown.ref, "0123abc")
        XCTAssertEqual(unknown.path, ["docs"])
    }

    func testDisplayRootAndWebURL() {
        XCTAssertEqual(GitHubWeb.displayRoot(loc("octo/demo", "main", ["src"])), "octo/demo")
        XCTAssertEqual(GitHubWeb.webURL(loc("octo/demo"), isFile: false)?.absoluteString, "https://github.com/octo/demo")
        XCTAssertEqual(GitHubWeb.webURL(loc("octo/demo", "main"), isFile: false)?.absoluteString,
                       "https://github.com/octo/demo/tree/main")
        XCTAssertEqual(GitHubWeb.webURL(loc("octo/demo", "feature/x", ["My Docs"]), isFile: false)?.absoluteString,
                       "https://github.com/octo/demo/tree/feature/x/My%20Docs")
        XCTAssertEqual(GitHubWeb.webURL(loc("octo/demo", "main", ["src", "a.swift"]), isFile: true)?.absoluteString,
                       "https://github.com/octo/demo/blob/main/src/a.swift")
        XCTAssertEqual(GitHubWeb.webURL(loc("octo/demo", nil, ["src"]), isFile: false)?.absoluteString,
                       "https://github.com/octo/demo/tree/HEAD/src")
    }

    func testParsedWebURLRoundTrips() {
        let url = GitHubWeb.webURL(loc("octo/demo", "main", ["src"]), isFile: false)!
        XCTAssertEqual(GitHubAddress.parse(url.absoluteString), loc("octo/demo", "main/src"))
    }
}
