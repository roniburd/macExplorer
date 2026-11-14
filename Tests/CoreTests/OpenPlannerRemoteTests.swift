@testable import Core
import Foundation
import MacxFS
import MacxPluginKit
import XCTest

@MainActor
final class OpenPlannerRemoteTests: XCTestCase {
    func testRemoteFolderNavigatesAndRemoteLinkIsADocumentWithoutAnyLaneCall() async {
        let dir = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["src"]).url
        let link = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["l"]).url
        let lanes = LanePool()
        let volumes = Volumes(lanes: lanes, events: nil)   // not started: empty mount table
        let folder = await OpenPlanner.plan([OpenItem(url: dir, kind: .directory, isApplication: false)],
                                            newWindow: false, lanes: lanes, volumes: volumes)
        XCTAssertEqual(folder.actions, [.navigate(dir)])
        let doc = await OpenPlanner.plan([OpenItem(url: link, kind: .symlink, isApplication: false)],
                                         newWindow: false, lanes: lanes, volumes: volumes)
        XCTAssertEqual(doc.actions, [.openDocuments([link])])
    }
}
