import Foundation
import MacxPluginKit
import XCTest

final class RemoteLocationTests: XCTestCase {
    private func loc(_ repo: String = "owner/repo", ref: String? = "main", _ path: [String] = []) -> RemoteLocation {
        RemoteLocation(provider: "test.fake", repo: repo, ref: ref, path: path)
    }

    private func loc(_ path: [String]) -> RemoteLocation { loc("owner/repo", ref: "main", path) }

    func testRootURLShape() {
        XCTAssertEqual(loc().url.absoluteString, "x-macexplorer-remote://test.fake/owner%2Frepo@main")
        XCTAssertEqual(loc(ref: nil).url.absoluteString, "x-macexplorer-remote://test.fake/owner%2Frepo")
        XCTAssertEqual(RemoteLocation.scheme, "x-macexplorer-remote")
    }

    func testRoundTrips() {
        for l in [loc(), loc(ref: nil), loc(["Sources", "App"]), loc("a@b/c d", ref: "v1.0", ["x y", "é"])] {
            XCTAssertEqual(RemoteLocation(url: l.url), l, l.url.absoluteString)
        }
    }

    func testRefWithSlashesRoundTrips() {
        let l = loc(ref: "feature/x/y", ["Sources"])
        XCTAssertEqual(l.url.absoluteString, "x-macexplorer-remote://test.fake/owner%2Frepo@feature%2Fx%2Fy/Sources")
        XCTAssertEqual(RemoteLocation(url: l.url), l)
    }

    /// Review Focus 1: FolderModel builds child URLs with URL.appending(path:); parsing must give the name back.
    func testAppendingThenParsingKeepsOddNames() {
        for name in ["100% done", "a@b", "#tag", "what?", "with space", ".hidden", "e\u{301}", "é", "a+b=c", "ünï"] {
            let child = loc(["dir"]).url.appending(path: name)
            XCTAssertEqual(RemoteLocation(url: child)?.path, ["dir", name], child.absoluteString)
            XCTAssertEqual(RemoteLocation(url: child)?.ref, "main")
        }
    }

    func testRejectsOtherURLs() {
        XCTAssertNil(RemoteLocation(url: URL(filePath: "/tmp")))
        XCTAssertNil(RemoteLocation(url: URL(string: "https://github.com/o/r")!))
        XCTAssertNil(RemoteLocation(url: URL(string: "x-macexplorer-remote://test.fake/")!))
        XCTAssertNil(RemoteLocation(url: URL(string: "x-macexplorer-remote:///owner%2Frepo")!))
        XCTAssertNil(RemoteLocation(url: URL(string: "x-macexplorer-remote://test.fake/@main")!))
        XCTAssertNil(RemoteLocation(url: URL(string: "x-macexplorer-remote://test.fake/o%2Fr@")!))
    }

    func testNavigationHelpers() {
        let root = loc()
        XCTAssertNil(root.parent)
        XCTAssertNil(root.name)
        XCTAssertEqual(root.pathString, "")
        let deep = root.appending("a").appending("b")
        XCTAssertEqual(deep.path, ["a", "b"])
        XCTAssertEqual(deep.pathString, "a/b")
        XCTAssertEqual(deep.name, "b")
        XCTAssertEqual(deep.parent, root.appending("a"))
        XCTAssertEqual(deep.parent?.parent, root)
        XCTAssertEqual(deep.withRef("dev"), RemoteLocation(provider: "test.fake", repo: "owner/repo", ref: "dev", path: ["a", "b"]))
    }

    func testCodable() throws {
        let l = loc(["x"])
        XCTAssertEqual(try JSONDecoder().decode(RemoteLocation.self, from: JSONEncoder().encode(l)), l)
    }
}
