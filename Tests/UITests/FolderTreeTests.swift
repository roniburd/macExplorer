import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

/// FolderTreeController (§4.3 tree nodes, §5.4 FOLDERS) against sandbox volumes only.
@MainActor
final class FolderTreeTests: XCTestCase {
    private func make(_ prepare: (SidebarHarness) throws -> Void = { _ in }) async throws -> (SidebarHarness, FolderTreeController) {
        let h = try await SidebarHarness.make(self, prepare: prepare)
        let tree = FolderTreeController(readers: h.environment.readers, showHidden: false)
        tree.setVolumes(h.environment.volumes.browsable)
        return (h, tree)
    }

    private func names(_ nodes: [FolderTreeNode]) -> [String] { nodes.map(\.name) }

    func testRootsAreTheVolumes() async throws {
        let (h, tree) = try await make()
        XCTAssertEqual(names(tree.roots), ["Macintosh HD", "USB"])
        XCTAssertTrue(tree.roots.allSatisfy(\.isVolumeRoot))
        XCTAssertEqual(tree.roots[0].url, h.boot)
        XCTAssertTrue(tree.isExpandable(tree.roots[1]), "unknown until read")
    }

    func testChildrenAreFoldersOnlySortedWithoutHiddenOrPackages() async throws {
        let (_, tree) = try await make { h in
            try h.file("a.txt")
            try h.dir("b"); try h.dir("A10"); try h.dir("a2"); try h.dir(".dot"); try h.dir("Tool.app/Contents")
            try h.dir("flagged")
            try h.sandbox.setFlags("boot/flagged", UInt32(UF_HIDDEN))
        }
        let root = tree.roots[0]
        await tree.load(root)
        XCTAssertEqual(names(tree.children(of: root)), ["a2", "A10", "b", "home"])
        tree.showHidden = true
        XCTAssertEqual(names(tree.children(of: root)), [".dot", "a2", "A10", "b", "flagged", "home"])
        XCTAssertTrue(tree.children(of: root).first { $0.name == "flagged" }!.isHidden)
    }

    func testEmptyFolderIsNotExpandableAfterLoading() async throws {
        let (h, tree) = try await make()
        let usb = tree.roots[1]
        await tree.load(usb)
        XCTAssertFalse(tree.isExpandable(usb))
        try h.sandbox.createDirectory("usb/x")
        await tree.load(usb)
        XCTAssertTrue(tree.isExpandable(usb))
    }

    func testExpandedNodesAreWatchedAndFollowChanges() async throws {
        let (h, tree) = try await make { try $0.dir("a") }
        let root = tree.roots[0]
        var changed: [String] = []
        tree.onChange = { node in changed.append(node?.name ?? "*") }
        tree.didExpand(root)
        try await h.waitUntil("loaded") { root.isLoaded }
        XCTAssertEqual(tree.watchedCount, 1)
        XCTAssertEqual(names(tree.children(of: root)), ["a", "home"])
        let a = tree.children(of: root)[0]
        try h.dir("new")
        try await h.waitUntil("vnode change re-reads") { self.names(tree.children(of: root)) == ["a", "home", "new"] }
        XCTAssertTrue(tree.children(of: root)[0] === a, "existing nodes survive the merge")
        XCTAssertTrue(changed.contains("Macintosh HD"))
        try h.sandbox.remove("boot/new")
        try await h.waitUntil("removal") { self.names(tree.children(of: root)) == ["a", "home"] }
        tree.didCollapse(root)
        XCTAssertEqual(tree.watchedCount, 0)
    }

    func testCollapseUnwatchesTheSubtreeAndReExpandReReads() async throws {
        let (h, tree) = try await make { try $0.dir("a/b") }
        let root = tree.roots[0]
        tree.didExpand(root)
        try await h.waitUntil("root") { root.isLoaded }
        let a = try XCTUnwrap(tree.children(of: root).first { $0.name == "a" })
        tree.didExpand(a)
        try await h.waitUntil("a") { a.isLoaded }
        XCTAssertEqual(tree.watchedCount, 2)
        tree.didCollapse(root)
        XCTAssertEqual(tree.watchedCount, 0)
        XCTAssertFalse(a.isExpanded)
        try h.dir("a/c")
        tree.didExpand(a)
        try await h.waitUntil("re-read on re-expand") { self.names(tree.children(of: a)) == ["b", "c"] }
    }

    func testNonLocalVolumesAreNotWatchedAndRefreshWhenAsked() async throws {
        let (h, _) = try await make()
        let remote = SandboxVolumeScanner.volume("mnt:remote", name: "Share", at: h.usb, boot: false, local: false)
        let tree = FolderTreeController(readers: h.environment.readers, showHidden: false)
        tree.setVolumes([remote])
        let root = tree.roots[0]
        tree.didExpand(root)
        try await h.waitUntil("loaded") { root.isLoaded }
        XCTAssertEqual(tree.watchedCount, 0, "volumeIsLocal false: no vnode source")
        try h.sandbox.createDirectory("usb/late")
        await tree.refreshUnwatched()
        XCTAssertEqual(names(tree.children(of: root)), ["late"])
    }

    func testRevealLoadsAncestorsAndReturnsThePath() async throws {
        let (h, tree) = try await make { try $0.dir("a/b/c") }
        let revealed = await tree.reveal(h.url("a/b/c"))
        let path = try XCTUnwrap(revealed)
        XCTAssertEqual(names(path), ["Macintosh HD", "a", "b", "c"])
        XCTAssertTrue(tree.node(for: h.url("a/b")) === path[2])
        let bootPath = await tree.reveal(h.boot)
        let usbPath = await tree.reveal(h.usb)
        XCTAssertEqual(bootPath.map(names), ["Macintosh HD"])
        XCTAssertEqual(usbPath.map(names), ["USB"])
    }

    func testRevealThroughAHiddenFolderPinsItVisible() async throws {
        let (h, tree) = try await make { try $0.dir(".secret/inner") }
        let root = tree.roots[0]
        let revealed = await tree.reveal(h.url(".secret/inner"))
        let path = try XCTUnwrap(revealed)
        XCTAssertEqual(names(path), ["Macintosh HD", ".secret", "inner"])
        XCTAssertEqual(names(tree.children(of: root)), [".secret", "home"])
        _ = await tree.reveal(h.url("home"))
        XCTAssertEqual(names(tree.children(of: root)), ["home"], "unpinned once the path moves on")
    }

    func testRevealOfFilesPackagesAndMissingFoldersFails() async throws {
        let (h, tree) = try await make { h in try h.file("f.txt"); try h.dir("X.app/Contents") }
        let none1 = await tree.reveal(h.url("f.txt"))
        let none2 = await tree.reveal(h.url("X.app/Contents"))
        let none3 = await tree.reveal(h.url("gone/away"))
        let none4 = await tree.reveal(h.sandbox.root)
        XCTAssertNil(none1)
        XCTAssertNil(none2)
        XCTAssertNil(none3)
        XCTAssertNil(none4, "outside every volume")
    }

    func testAFailedOrStalledReadKeepsTheNodeExpandableAndReExpandRetries() async throws {
        let (h, tree) = try await make()
        let usb = tree.roots[1]
        let script = ScriptedLister(results: [nil, nil, [("x", false)]])
        tree.lister = { _ in script.next() }
        await tree.load(usb)
        XCTAssertFalse(usb.isLoaded, "a stall or failure leaves the children unknown")
        XCTAssertTrue(tree.isExpandable(usb), "the disclosure triangle stays")
        tree.didExpand(usb)
        try await h.waitUntil("second read") { script.reads == 2 }
        XCTAssertTrue(tree.isExpandable(usb))
        tree.didCollapse(usb)
        tree.didExpand(usb)
        try await h.waitUntil("retried") { usb.isLoaded }
        XCTAssertEqual(names(tree.children(of: usb)), ["x"])

        script.results = [nil]
        await tree.load(usb)
        XCTAssertEqual(names(tree.children(of: usb)), ["x"], "a failed re-read keeps the previous children")
    }

    func testARequestDuringAReadRunsOneMoreRead() async throws {
        let (_, tree) = try await make()
        let usb = tree.roots[1]
        let script = ScriptedLister(results: [])
        script.listing = []
        tree.lister = { _ in
            let snapshot = script.listing
            script.reads += 1
            if script.reads == 1 { await withCheckedContinuation { script.gate = $0 } }
            return snapshot
        }
        let first = Task { await tree.load(usb) }
        while script.gate == nil { await Task.yield() }
        script.listing = [("late", false)]            // created after the first read listed the folder
        let second = Task { await tree.load(usb) }
        let third = Task { await tree.load(usb) }
        for _ in 0..<10 { await Task.yield() }
        script.gate?.resume()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(names(tree.children(of: usb)), ["late"])
        XCTAssertEqual(script.reads, 2, "requests during a read coalesce into one more read")
    }

    func testRemovedVolumeDropsItsRootAndWatches() async throws {
        let (h, tree) = try await make { try $0.sandbox.createDirectory("usb/x") }
        let usb = tree.roots[1]
        tree.didExpand(usb)
        try await h.waitUntil("loaded") { usb.isLoaded }
        XCTAssertEqual(tree.watchedCount, 1)
        var dropped: [String] = []
        tree.onDrop = { dropped.append($0.name) }
        tree.setVolumes(h.environment.volumes.browsable.filter { $0.name != "USB" })
        XCTAssertEqual(names(tree.roots), ["Macintosh HD"])
        XCTAssertEqual(tree.watchedCount, 0)
        XCTAssertEqual(Set(dropped), ["USB", "x"])
    }
}

/// Scripted folder listings for FolderTreeController.lister.
@MainActor
private final class ScriptedLister {
    var results: [FolderTreeController.Listing?]
    var listing: FolderTreeController.Listing = []
    var reads = 0
    var gate: CheckedContinuation<Void, Never>?

    init(results: [FolderTreeController.Listing?]) { self.results = results }

    func next() -> FolderTreeController.Listing? {
        reads += 1
        return results.removeFirst()
    }
}
