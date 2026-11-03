import Foundation
import MacxFixtures
import MacxFS
import XCTest
@testable import Core

@MainActor
final class OpenPlannerTests: XCTestCase {
    private var sandbox: Sandbox!
    private var lanes: LanePool!
    private var volumes: Volumes!

    override func setUp() async throws {
        sandbox = try Sandbox()
        lanes = LanePool()
        volumes = Volumes(lanes: lanes, events: nil)   // not started: empty mount table, VolumeID.unknown lanes
    }

    override func tearDown() async throws {
        sandbox.destroy()
        sandbox = nil
        volumes = nil
        lanes = nil
    }

    private func plan(_ items: [OpenItem], newWindow: Bool = false) async -> OpenPlan {
        await OpenPlanner.plan(items, newWindow: newWindow, lanes: lanes, volumes: volumes)
    }

    private func folder(_ name: String) throws -> OpenItem {
        OpenItem(url: try sandbox.createDirectory(name), kind: .directory, isApplication: false)
    }

    private func file(_ name: String) throws -> OpenItem {
        OpenItem(url: try sandbox.createFile(name), kind: .file, isApplication: false)
    }

    private func app(_ name: String) throws -> OpenItem {
        try sandbox.createFile(name + "/Contents/Info.plist", contents: Data("<plist/>".utf8))
        return OpenItem(url: sandbox.url(name), kind: .package, isApplication: true)
    }

    /// Standardized path form of every URL in the plan, so /private spellings and trailing slashes compare equal.
    private func normalized(_ plan: OpenPlan) -> [OpenAction] {
        return plan.actions.map {
            switch $0 {
            case .navigate(let u): .navigate(n(u))
            case .openInNewWindow(let u): .openInNewWindow(n(u))
            case .launchApplication(let u): .launchApplication(n(u))
            case .openDocuments(let us): .openDocuments(us.map(n))
            case .brokenLink(let u): .brokenLink(n(u))
            }
        }
    }

    private func u(_ relative: String) -> URL { n(sandbox.root.appending(path: relative)) }

    /// /private/var and /var, trailing slashes: one spelling. Resolves only the parent, so a link stays a link.
    private func n(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath().path(percentEncoded: false)
        if parent.hasPrefix("/private/") { parent.removeFirst("/private".count) }
        if parent.hasSuffix("/") { parent.removeLast() }
        return URL(filePath: parent + "/" + standardized.lastPathComponent)
    }

    // MARK: plain items

    func testEmptySelectionPlansNothing() async {
        let p = await plan([])
        XCTAssertEqual(p, OpenPlan(actions: [], needsConfirmation: false))
    }

    func testSingleFolderNavigatesInPlace() async throws {
        let p = await plan([try folder("Docs")])
        XCTAssertEqual(normalized(p), [.navigate(u("Docs"))])
        XCTAssertFalse(p.needsConfirmation)
    }

    func testSingleFolderWithNewWindowOpensAWindow() async throws {
        let p = await plan([try folder("Docs")], newWindow: true)
        XCTAssertEqual(normalized(p), [.openInNewWindow(u("Docs"))])
    }

    func testApplicationLaunches() async throws {
        let p = await plan([try app("Tool.app")])
        XCTAssertEqual(normalized(p), [.launchApplication(u("Tool.app"))])
    }

    func testOtherPackagesAreDocuments() async throws {
        let rtfd = try sandbox.createFile("Notes.rtfd/TXT.rtf")
        let p = await plan([OpenItem(url: rtfd.deletingLastPathComponent(), kind: .package, isApplication: false)])
        XCTAssertEqual(normalized(p), [.openDocuments([u("Notes.rtfd")])])
    }

    func testFileOpensWithItsDefaultApp() async throws {
        let p = await plan([try file("a.txt")])
        XCTAssertEqual(normalized(p), [.openDocuments([u("a.txt")])])
    }

    func testNewWindowFlagDoesNotAffectFiles() async throws {
        let p = await plan([try file("a.txt")], newWindow: true)
        XCTAssertEqual(normalized(p), [.openDocuments([u("a.txt")])])
    }

    // MARK: multiple selection

    func testMultipleSelectionOpensFoldersInWindowsAndFilesTogether() async throws {
        let items = [try file("a.txt"), try folder("F"), try file("b.txt"), try app("Tool.app"), try folder("G")]
        let p = await plan(items)
        XCTAssertEqual(normalized(p), [
            .openDocuments([u("a.txt"), u("b.txt")]),
            .openInNewWindow(u("F")),
            .launchApplication(u("Tool.app")),
            .openInNewWindow(u("G")),
        ])
        XCTAssertFalse(p.needsConfirmation)
    }

    func testTenFoldersNeedNoConfirmationElevenDo() async throws {
        let ten = try (0..<10).map { try folder("d\($0)") }
        let p10 = await plan(ten)
        XCTAssertEqual(p10.actions.count, 10)
        XCTAssertFalse(p10.needsConfirmation)
        let p11 = await plan(ten + [try folder("d10")])
        XCTAssertTrue(p11.needsConfirmation, "more than 10 folders would open in new windows")
        XCTAssertTrue(p11.actions.allSatisfy { if case .openInNewWindow = $0 { true } else { false } })
    }

    func testManyFilesNeedNoConfirmation() async throws {
        let files = try (0..<20).map { try file("f\($0).txt") }
        let p = await plan(files)
        XCTAssertFalse(p.needsConfirmation)
        XCTAssertEqual(p.actions.count, 1)
    }

    // MARK: links

    func testSymlinkToFolderNavigatesToTheTarget() async throws {
        try sandbox.createDirectory("real")
        let link = try sandbox.createSymlink("link", target: "real")
        let p = await plan([OpenItem(url: link, kind: .symlink, isApplication: false)])
        XCTAssertEqual(normalized(p), [.navigate(u("real"))])
    }

    func testSymlinkToFolderWithNewWindow() async throws {
        try sandbox.createDirectory("real")
        let link = try sandbox.createSymlink("link", target: sandbox.url("real").path(percentEncoded: false))
        let p = await plan([OpenItem(url: link, kind: .symlink, isApplication: false)], newWindow: true)
        XCTAssertEqual(normalized(p), [.openInNewWindow(u("real"))])
    }

    func testSymlinkToFileOpensTheTarget() async throws {
        try sandbox.createFile("sub/target.txt")
        let link = try sandbox.createSymlink("link.txt", target: "sub/target.txt")
        let p = await plan([OpenItem(url: link, kind: .symlink, isApplication: false)])
        XCTAssertEqual(normalized(p), [.openDocuments([u("sub/target.txt")])])
    }

    func testSymlinkToApplicationLaunchesIt() async throws {
        _ = try app("Tool.app")
        let link = try sandbox.createSymlink("ToolLink", target: "Tool.app")
        let p = await plan([OpenItem(url: link, kind: .symlink, isApplication: false)])
        XCTAssertEqual(normalized(p), [.launchApplication(u("Tool.app"))])
    }

    func testSymlinkChainResolvesToTheEnd() async throws {
        try sandbox.createDirectory("real")
        try sandbox.createSymlink("hop1", target: "real")
        let link = try sandbox.createSymlink("hop2", target: "hop1")
        let p = await plan([OpenItem(url: link, kind: .symlink, isApplication: false)])
        XCTAssertEqual(normalized(p), [.navigate(u("real"))])
    }

    func testBrokenSymlinkIsReported() async throws {
        let link = try sandbox.createSymlink("dangling", target: "nowhere")
        let p = await plan([OpenItem(url: link, kind: .symlink, isApplication: false)])
        XCTAssertEqual(normalized(p), [.brokenLink(u("dangling"))])
    }

    func testSymlinkLoopIsBroken() async throws {
        try sandbox.createSymlink("a", target: "b")
        let link = try sandbox.createSymlink("b", target: "a")
        let p = await plan([OpenItem(url: link, kind: .symlink, isApplication: false)])
        XCTAssertEqual(normalized(p), [.brokenLink(u("b"))])
    }

    func testAliasToFolderNavigatesToTheTarget() async throws {
        try sandbox.createDirectory("real")
        let alias = try sandbox.createAlias("real alias", to: "real")
        let p = await plan([OpenItem(url: alias, kind: .alias, isApplication: false)])
        XCTAssertEqual(normalized(p), [.navigate(u("real"))])
    }

    func testAliasToFileOpensTheTarget() async throws {
        try sandbox.createFile("doc.txt")
        let alias = try sandbox.createAlias("doc alias", to: "doc.txt")
        let p = await plan([OpenItem(url: alias, kind: .alias, isApplication: false)])
        XCTAssertEqual(normalized(p), [.openDocuments([u("doc.txt")])])
    }

    func testAliasWhoseTargetWasDeletedIsBroken() async throws {
        try sandbox.createFile("gone.txt")
        let alias = try sandbox.createAlias("gone alias", to: "gone.txt")
        try sandbox.remove("gone.txt")
        let p = await plan([OpenItem(url: alias, kind: .alias, isApplication: false)])
        XCTAssertEqual(normalized(p), [.brokenLink(u("gone alias"))])
    }

    func testLinksInAMultipleSelection() async throws {
        try sandbox.createDirectory("real")
        try sandbox.createFile("t.txt")
        let toFolder = try sandbox.createSymlink("L", target: "real")
        let toFile = try sandbox.createSymlink("M", target: "t.txt")
        let broken = try sandbox.createSymlink("N", target: "missing")
        let items = [OpenItem(url: toFolder, kind: .symlink, isApplication: false),
                     OpenItem(url: toFile, kind: .symlink, isApplication: false),
                     OpenItem(url: broken, kind: .symlink, isApplication: false),
                     try file("plain.txt")]
        let p = await plan(items)
        XCTAssertEqual(normalized(p), [
            .openInNewWindow(u("real")),
            .openDocuments([u("t.txt"), u("plain.txt")]),
            .brokenLink(u("N")),
        ])
    }
}
