@testable import Core
import Foundation
import MacxPluginKit
import XCTest

@MainActor
final class RemoteClipboardTests: XCTestCase {
    func testCopyRemoteWritesRemoteItemsAndWebText() {
        let board = InMemoryPasteboard()
        let clipboard = Clipboard(backend: board)
        let a = RemoteLocation(provider: "test.fake", repo: "demo", ref: "main", path: ["a.txt"]).url
        clipboard.copyRemote([a], webText: ["https://fake.example/demo/main/a.txt"])
        XCTAssertEqual(clipboard.remoteItems, [a])
        XCTAssertTrue(clipboard.canPaste)
        XCTAssertFalse(board.hasFileURLs(), "no file URLs, so Finder pastes nothing it can't open")
        XCTAssertEqual(board.readString(), "https://fake.example/demo/main/a.txt")
        clipboard.copy([URL(filePath: "/tmp/x")])
        XCTAssertEqual(clipboard.remoteItems, [], "a later file copy replaces the remote items")
    }
}
