import Darwin
import Foundation
import MacxFixtures
import MacxFS
import XCTest
@testable import Core

// MARK: - PermissionModel

final class PermissionModelTests: XCTestCase {
    func testAccessReadsReadWriteBitsPerClass() {
        XCTAssertEqual(PermissionModel.access(0o644, .owner), .readWrite)
        XCTAssertEqual(PermissionModel.access(0o644, .group), .readOnly)
        XCTAssertEqual(PermissionModel.access(0o644, .everyone), .readOnly)
        XCTAssertEqual(PermissionModel.access(0o620, .group), .writeOnly)
        XCTAssertEqual(PermissionModel.access(0o600, .everyone), .noAccess)
        XCTAssertEqual(PermissionModel.access(0o111, .owner), .noAccess, "execute alone is no access")
        XCTAssertEqual(PermissionModel.access(0o4755, .owner), .readWrite, "setuid does not matter")
    }

    func testApplyingChangesOnlyThatClassAndKeepsExecuteAndSpecialBits() {
        XCTAssertEqual(PermissionModel.applying(.noAccess, .everyone, to: 0o644), 0o640)
        XCTAssertEqual(PermissionModel.applying(.readWrite, .group, to: 0o640), 0o660)
        XCTAssertEqual(PermissionModel.applying(.readOnly, .owner, to: 0o755), 0o555)
        XCTAssertEqual(PermissionModel.applying(.writeOnly, .everyone, to: 0o755), 0o753)
        XCTAssertEqual(PermissionModel.applying(.noAccess, .owner, to: 0o4755), 0o4155)
        XCTAssertEqual(PermissionModel.applying(.readWrite, .owner, to: 0o644), 0o644, "unchanged value is identity")
    }

    /// Folders: each level carries the search (x) bit, so Read & Write repairs a 000 folder (QA round 3).
    func testApplyingOnDirectoryAlsoSetsSearchBit() {
        XCTAssertEqual(PermissionModel.applying(.readWrite, .owner, to: 0o000, isDirectory: true), 0o700)
        XCTAssertEqual(PermissionModel.applying(.readOnly, .owner, to: 0o700, isDirectory: true), 0o500)
        XCTAssertEqual(PermissionModel.applying(.readOnly, .group, to: 0o700, isDirectory: true), 0o750)
        XCTAssertEqual(PermissionModel.applying(.writeOnly, .everyone, to: 0o755, isDirectory: true), 0o753, "drop box")
        XCTAssertEqual(PermissionModel.applying(.noAccess, .everyone, to: 0o755, isDirectory: true), 0o750)
        XCTAssertEqual(PermissionModel.applying(.readWrite, .owner, to: 0o1644, isDirectory: true), 0o1744, "sticky kept")
        XCTAssertEqual(PermissionModel.applying(.readWrite, .owner, to: 0o000), 0o600, "files keep their x bits")
    }

    /// The mode "Apply to enclosed items…" sends: each class's level re-applied with the folder x rule.
    func testDirectoryModeNormalizesEveryClass() {
        XCTAssertEqual(PermissionModel.directoryMode(0o644), 0o755)
        XCTAssertEqual(PermissionModel.directoryMode(0o700), 0o700)
        XCTAssertEqual(PermissionModel.directoryMode(0o620), 0o730)
        XCTAssertEqual(PermissionModel.directoryMode(0o4100), 0o4000)
    }

    func testApplyingThenReadingRoundTripsForEveryCombination() {
        for mode: UInt16 in [0, 0o777, 0o644, 0o1750, 0o2711] {
            for who in PermissionClass.allCases {
                for access in PermissionAccess.allCases {
                    let applied = PermissionModel.applying(access, who, to: mode)
                    XCTAssertEqual(PermissionModel.access(applied, who), access, "\(String(mode, radix: 8)) \(who) \(access)")
                    for other in PermissionClass.allCases where other != who {
                        XCTAssertEqual(PermissionModel.access(applied, other), PermissionModel.access(mode, other))
                    }
                    XCTAssertEqual(applied & 0o7111, mode & 0o7111, "execute and special bits kept")
                }
            }
        }
    }

    func testIsExecutable() {
        XCTAssertTrue(PermissionModel.isExecutable(0o755))
        XCTAssertTrue(PermissionModel.isExecutable(0o601))
        XCTAssertFalse(PermissionModel.isExecutable(0o644))
        XCTAssertFalse(PermissionModel.isExecutable(0o4666))
    }

    func testOwnerAndGroupNames() {
        XCTAssertEqual(PermissionModel.userName(0), "root")
        XCTAssertEqual(PermissionModel.groupName(0), "wheel")
        XCTAssertEqual(PermissionModel.userName(geteuid()), NSUserName())
        XCTAssertEqual(PermissionModel.userName(4_000_000_123), "4000000123", "unknown ids fall back to the number")
        XCTAssertEqual(PermissionModel.groupName(4_000_000_123), "4000000123")
    }
}

// MARK: - Xattrs

final class XattrsTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUp() async throws { sandbox = try Sandbox() }
    override func tearDown() async throws { sandbox.destroy(); sandbox = nil }

    private func path(_ relative: String) -> String { sandbox.url(relative).path(percentEncoded: false) }

    func testListReturnsNamesAndSizesSortedWithoutFollowingLinks() throws {
        try sandbox.createFile("a.txt")
        try sandbox.setXattr("a.txt", name: "com.example.zeta", value: Data("hello".utf8))
        try sandbox.setXattr("a.txt", name: "com.example.alpha", value: Data())
        try sandbox.createSymlink("link", target: "a.txt")
        // macOS may add its own com.apple.* attributes (e.g. com.apple.provenance); only ours are pinned.
        let mine = { (list: [XattrInfo]) in list.filter { $0.name.hasPrefix("com.example.") } }
        XCTAssertEqual(mine(Xattrs.list(path("a.txt"))), [XattrInfo(name: "com.example.alpha", size: 0),
                                                           XattrInfo(name: "com.example.zeta", size: 5)])
        XCTAssertEqual(Xattrs.list(path("a.txt")).map(\.name), Xattrs.list(path("a.txt")).map(\.name).sorted())
        XCTAssertEqual(mine(Xattrs.list(path("link"))), [], "the link's own xattrs, not the target's")
        XCTAssertEqual(Xattrs.read(path("a.txt"), "com.example.zeta"), Data("hello".utf8))
        XCTAssertNil(Xattrs.read(path("a.txt"), "com.example.missing"))
        XCTAssertEqual(Xattrs.list(path("missing")), [])
    }

    func testParsesQuarantine() throws {
        let raw = Data("0081;65f0c3a1;Safari;F0A1B2C3-0000-0000-0000-000000000000".utf8)
        let q = Xattrs.parseQuarantine(raw)
        XCTAssertEqual(q.raw, raw)
        XCTAssertEqual(q.agentName, "Safari")
        XCTAssertEqual(q.date, Date(timeIntervalSince1970: TimeInterval(0x65f0c3a1)))

        let bare = Xattrs.parseQuarantine(Data("0081;zz;;".utf8))
        XCTAssertNil(bare.agentName)
        XCTAssertNil(bare.date)
        XCTAssertNil(Xattrs.parseQuarantine(Data([0xff, 0xfe])).agentName, "garbage still yields an info with raw bytes")
    }

    func testReadsQuarantineFromDisk() throws {
        try sandbox.createFile("q.txt")
        try sandbox.createFile("clean.txt")
        let raw = Data("0081;65f0c3a1;Safari;".utf8)
        try sandbox.setXattr("q.txt", name: Xattrs.quarantineName, value: raw)
        XCTAssertEqual(Xattrs.quarantine(path("q.txt"))?.raw, raw)
        XCTAssertEqual(Xattrs.quarantine(path("q.txt"))?.agentName, "Safari")
        XCTAssertNil(Xattrs.quarantine(path("clean.txt")))
    }

    func testReadsWhereFromsFromMetadataXattr() throws {
        try sandbox.createFile("d.zip")
        try sandbox.createFile("none.zip")
        let urls = ["https://example.com/d.zip", "https://example.com/"]
        let plist = try PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0)
        try sandbox.setXattr("d.zip", name: Xattrs.whereFromsName, value: plist)
        XCTAssertEqual(Xattrs.whereFroms(path("d.zip")), urls)
        XCTAssertEqual(Xattrs.whereFroms(path("none.zip")), [])
        XCTAssertEqual(Xattrs.decodeWhereFroms(Data("not a plist".utf8)), [])
    }
}

// MARK: - FolderCounter

final class FolderCounterTests: XCTestCase {
    private var sandbox: Sandbox!
    private var lanes: LanePool!
    private let volume = VolumeID(raw: "test-count")

    override func setUp() async throws {
        sandbox = try Sandbox()
        lanes = LanePool()
    }

    override func tearDown() async throws {
        sandbox.destroy()
        sandbox = nil
        lanes = nil
    }

    private func collect(_ stream: AsyncStream<CountProgress>) async -> [CountProgress] {
        var all: [CountProgress] = []
        for await p in stream { all.append(p) }
        return all
    }

    func testCountsContentsNotTheFolderItself() async throws {
        try sandbox.createFile("F/a.txt", contents: Data(count: 10))
        try sandbox.createFile("F/b.txt", contents: Data(count: 20))
        try sandbox.createFile("F/sub/c.txt", contents: Data(count: 30))
        let all = await collect(FolderCounter.count(sandbox.url("F"), lanes: lanes, volume: volume))
        let last = try XCTUnwrap(all.last)
        XCTAssertEqual([last.files, last.folders], [3, 1])
        XCTAssertEqual(last.bytes, 60)
        XCTAssertTrue(last.finished)
        XCTAssertGreaterThanOrEqual(last.diskBytes, 60, "allocated bytes, for Size on disk")
        XCTAssertEqual(last.unreadableFolders, 0)
        XCTAssertFalse(last.rootUnreadable)
        XCTAssertEqual(all.filter(\.finished).count, 1, "exactly one final update, and it is the last")
    }

    func testEmptyAndMissingFoldersFinishWithZero() async throws {
        try sandbox.createDirectory("E")
        let empty = await collect(FolderCounter.count(sandbox.url("E"), lanes: lanes, volume: volume))
        XCTAssertEqual(empty.last, CountProgress(files: 0, folders: 0, bytes: 0, finished: true))
        let missing = await collect(FolderCounter.count(sandbox.url("nope"), lanes: lanes, volume: volume))
        XCTAssertEqual(missing.last, CountProgress(files: 0, folders: 0, bytes: 0, finished: true, rootUnreadable: true),
                       "a folder that can't be read is not reported as empty")
    }

    /// QA round 2: a mode-000 folder used to finish as "0 files, 0 folders, Zero KB", as if it were empty.
    func testUnreadableRootIsReportedAsUnreadable() async throws {
        try sandbox.createFile("denied/s.txt", contents: Data(count: 100))
        try sandbox.setMode("denied", 0)
        let deniedPath = sandbox.url("denied").path(percentEncoded: false)
        addTeardownBlock { _ = chmod(deniedPath, 0o700) }
        let all = await collect(FolderCounter.count(sandbox.url("denied"), lanes: lanes, volume: volume))
        let last = try XCTUnwrap(all.last)
        XCTAssertTrue(last.finished)
        XCTAssertTrue(last.rootUnreadable)
    }

    /// Review Focus 4: symlinks are never followed, counted once, and recursion terminates.
    func testFolderCounterDoesNotFollowSymlinkLoop() async throws {
        try sandbox.createFile("F/a.txt", contents: Data(count: 4))
        try sandbox.createFile("F/sub/b.txt", contents: Data(count: 4))
        try sandbox.createSymlink("F/loop", target: "..")          // F/loop -> sandbox root (contains F)
        try sandbox.createSymlink("F/sub/self", target: ".")       // F/sub/self -> F/sub
        try sandbox.createSymlink("F/sub/up", target: "../..")
        try sandbox.createFile("outside/big.bin", contents: Data(count: 10_000))
        let all = await collect(FolderCounter.count(sandbox.url("F"), lanes: lanes, volume: volume))
        let last = try XCTUnwrap(all.last)
        XCTAssertTrue(last.finished)
        XCTAssertEqual(last.folders, 1, "only F/sub")
        XCTAssertEqual(last.files, 5, "a.txt, b.txt and the three links, each once")
        XCTAssertLessThan(last.bytes, 10_000, "nothing outside F was counted")
    }

    func testCountingASymlinkToAFolderDoesNotFollowIt() async throws {
        try sandbox.createFile("T/a.txt")
        try sandbox.createSymlink("L", target: "T")
        let all = await collect(FolderCounter.count(sandbox.url("L"), lanes: lanes, volume: volume))
        XCTAssertEqual(all.last, CountProgress(files: 0, folders: 0, bytes: 0, finished: true))
    }

    func testUnreadableSubfolderIsCountedAndCountFinishes() async throws {
        try sandbox.createFile("F/a.txt")
        try sandbox.createFile("F/locked/hidden.txt")
        try sandbox.setMode("F/locked", 0)
        let lockedPath = sandbox.url("F/locked").path(percentEncoded: false)
        addTeardownBlock { _ = chmod(lockedPath, 0o700) }
        let all = await collect(FolderCounter.count(sandbox.url("F"), lanes: lanes, volume: volume))
        let last = try XCTUnwrap(all.last)
        XCTAssertEqual([last.files, last.folders], [1, 1])
        XCTAssertEqual(last.bytes, 1)
        XCTAssertTrue(last.finished)
        XCTAssertEqual(last.unreadableFolders, 1, "the undercount is flagged (QA round 2)")
        XCTAssertFalse(last.rootUnreadable)
    }

    func testReportsMonotonicProgressBeforeFinishing() async throws {
        try FixtureTree.flat(in: sandbox, at: "F", count: 400)
        let all = await collect(FolderCounter.count(sandbox.url("F"), lanes: lanes, volume: volume, interval: .zero))
        XCTAssertGreaterThan(all.count, 2, "intermediate updates are sent")
        XCTAssertTrue(all.dropLast().allSatisfy { !$0.finished })
        for (a, b) in zip(all, all.dropFirst()) {
            XCTAssertLessThanOrEqual(a.files, b.files)
            XCTAssertLessThanOrEqual(a.bytes, b.bytes)
        }
        XCTAssertEqual(all.last?.files, 400)
        XCTAssertEqual(all.last?.finished, true)
    }

    func testDefaultIntervalThrottlesUpdates() async throws {
        try FixtureTree.flat(in: sandbox, at: "F", count: 400)
        let all = await collect(FolderCounter.count(sandbox.url("F"), lanes: lanes, volume: volume))
        XCTAssertLessThan(all.count, 50, "~10 Hz, not one update per entry")
        XCTAssertEqual(all.last?.files, 400)
    }

    func testEndingIterationCancelsAndReleasesTheLane() async throws {
        try FixtureTree.deep(in: sandbox, at: "F", depth: 3, breadth: 6, filesPerDir: 20)
        let single = LanePool(config: WatchdogConfig(lanesPerClass: 1))
        var seen = 0
        // The stream lives only as long as the loop, so `break` terminates it.
        for await p in FolderCounter.count(sandbox.url("F"), lanes: single, volume: volume, interval: .zero) {
            seen += 1
            XCTAssertFalse(p.finished)
            break
        }
        XCTAssertEqual(seen, 1)
        // The only read lane for this volume must become free again: the walk stopped.
        let ran = try await single.perform(on: volume, .read) { _ in true }
        XCTAssertTrue(ran)
    }

    func testWalkStopsAsSoonAsAskedAndReportsNothingFinal() async throws {
        try FixtureTree.flat(in: sandbox, at: "F", count: 200)
        let path = sandbox.url("F").path(percentEncoded: false)
        let result = try await lanes.perform(on: volume, .read) { _ -> (CountProgress?, Int) in
            nonisolated(unsafe) var asked = 0
            let r = FolderCounter.walk(path, shouldStop: { asked += 1; return asked > 10 })
            return (r, asked)
        }
        XCTAssertNil(result.0, "a stopped walk has no total")
        XCTAssertEqual(result.1, 11, "stops at the first check that says so")
    }

    func testCancellingTheConsumingTaskStopsTheCount() async throws {
        try FixtureTree.deep(in: sandbox, at: "F", depth: 3, breadth: 6, filesPerDir: 20)
        let single = LanePool(config: WatchdogConfig(lanesPerClass: 1))
        let url = sandbox.url("F")
        let volume = self.volume
        let task = Task {
            var last: CountProgress?
            for await p in FolderCounter.count(url, lanes: single, volume: volume, interval: .zero) { last = p }
            return last
        }
        task.cancel()
        let last = await task.value
        XCTAssertNotEqual(last?.finished, true, "a cancelled count never reports finished")
        let ran = try await single.perform(on: volume, .read) { _ in true }
        XCTAssertTrue(ran)
    }
}

// MARK: - PropertiesLoader

final class PropertiesTests: XCTestCase {
    private var sandbox: Sandbox!
    private var lanes: LanePool!
    private let volume = VolumeID(raw: "test-props")

    override func setUp() async throws {
        sandbox = try Sandbox()
        lanes = LanePool()
    }

    override func tearDown() async throws {
        sandbox.destroy()
        sandbox = nil
        lanes = nil
    }

    private func load(_ relative: String) async throws -> ItemProperties {
        try await PropertiesLoader.load(sandbox.url(relative), lanes: lanes, volume: volume)
    }

    private func lst(_ relative: String) -> stat {
        var st = stat()
        XCTAssertEqual(lstat(sandbox.url(relative).path(percentEncoded: false), &st), 0)
        return st
    }

    func testLoadsAPlainFile() async throws {
        try sandbox.createFile("a.txt", contents: Data(count: 1_234))
        try sandbox.setMode("a.txt", 0o640)
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try sandbox.setDates("a.txt", modified: modified, created: created)
        let p = try await load("a.txt")
        XCTAssertEqual(p.name, "a.txt")
        XCTAssertEqual(p.displayName, "a.txt")
        XCTAssertEqual(p.kind, .file)
        XCTAssertEqual(p.typeIdentifier, "public.plain-text")
        XCTAssertFalse(p.kindDescription.isEmpty)
        XCTAssertEqual(p.logicalSize, 1_234)
        XCTAssertEqual(p.physicalSize, Int64(lst("a.txt").st_blocks) * 512)
        XCTAssertEqual(p.created, created)
        XCTAssertEqual(p.modified, modified)
        XCTAssertEqual(p.mode, 0o640, "permission bits from lstat, without the file-type bits")
        XCTAssertEqual(p.ownerID, geteuid())
        XCTAssertEqual(p.ownerName, NSUserName())
        XCTAssertEqual(p.groupID, lst("a.txt").st_gid)
        XCTAssertEqual(p.groupName, PermissionModel.groupName(lst("a.txt").st_gid))
        XCTAssertTrue(p.isOwnedByCurrentUser)
        XCTAssertEqual(p.inode, lst("a.txt").st_ino)
        XCTAssertFalse(p.volumeName.isEmpty)
        XCTAssertFalse(p.isLocked)
        XCTAssertFalse(p.isHidden)
        XCTAssertFalse(p.isExtensionHidden)
        XCTAssertEqual(p.aclEntries, [])
        XCTAssertEqual(p.whereFroms, [])
        XCTAssertNil(p.quarantine)
        XCTAssertEqual(p.xattrs.filter { !$0.name.hasPrefix("com.apple.") }, [])
        XCTAssertEqual(p.url.lastPathComponent, "a.txt")
    }

    func testFlagsAndHiddenExtension() async throws {
        try sandbox.createFile("h.txt")
        try sandbox.setFlags("h.txt", UInt32(UF_HIDDEN))
        try sandbox.createFile("e.txt")
        try sandbox.setHiddenExtension("e.txt")
        try sandbox.createFile("l.txt")
        try sandbox.setFlags("l.txt", UInt32(UF_IMMUTABLE))
        let lockedPath = sandbox.url("l.txt").path(percentEncoded: false)
        addTeardownBlock { _ = lchflags(lockedPath, 0) }
        let hidden = try await load("h.txt")
        XCTAssertTrue(hidden.isHidden)
        XCTAssertFalse(hidden.isLocked)
        let ext = try await load("e.txt")
        XCTAssertTrue(ext.isExtensionHidden)
        XCTAssertEqual(ext.displayName, "e")
        XCTAssertEqual(ext.name, "e.txt")
        let locked = try await load("l.txt")
        XCTAssertTrue(locked.isLocked)
        XCTAssertFalse(locked.isHidden)
    }

    func testKindsForFolderPackageSymlinkAndAlias() async throws {
        try sandbox.createFile("D/x.txt")
        try sandbox.createFile("Thing.app/Contents/Info.plist")
        try sandbox.createSymlink("link", target: "D")
        try sandbox.createAlias("alias", to: "D")
        let folder = try await load("D")
        XCTAssertEqual(folder.kind, .directory)
        XCTAssertNil(folder.logicalSize, "folder sizes come from FolderCounter")
        XCTAssertEqual(folder.typeIdentifier, "public.folder")
        let package = try await load("Thing.app")
        XCTAssertEqual(package.kind, .package)
        let link = try await load("link")
        XCTAssertEqual(link.kind, .symlink, "never follows the link")
        XCTAssertEqual(link.inode, lst("link").st_ino)
        XCTAssertEqual(link.logicalSize, 1, "the link's own size (its target string)")
        let alias = try await load("alias")
        XCTAssertEqual(alias.kind, .alias)
    }

    func testDetailsXattrsQuarantineAndWhereFroms() async throws {
        try sandbox.createFile("dl.zip")
        try sandbox.setXattr("dl.zip", name: "com.example.note", value: Data("12345".utf8))
        try sandbox.setXattr("dl.zip", name: Xattrs.quarantineName, value: Data("0081;65f0c3a1;Safari;".utf8))
        let froms = ["https://example.com/dl.zip"]
        try sandbox.setXattr("dl.zip", name: Xattrs.whereFromsName,
                             value: try PropertyListSerialization.data(fromPropertyList: froms, format: .binary, options: 0))
        let p = try await load("dl.zip")
        XCTAssertEqual(p.quarantine?.agentName, "Safari")
        XCTAssertEqual(p.quarantine?.date, Date(timeIntervalSince1970: TimeInterval(0x65f0c3a1)))
        XCTAssertEqual(p.whereFroms, froms)
        XCTAssertTrue(p.xattrs.contains(XattrInfo(name: "com.example.note", size: 5)))
        XCTAssertTrue(p.xattrs.contains { $0.name == Xattrs.quarantineName })
        XCTAssertEqual(p.xattrs.map(\.name), p.xattrs.map(\.name).sorted())
    }

    func testListsACLEntries() async throws {
        let path = try sandbox.createFile("acl.txt").path(percentEncoded: false)
        func runChmod(_ arguments: [String]) throws -> Int32 {
            let chmod = Process()
            chmod.executableURL = URL(filePath: "/bin/chmod")
            chmod.arguments = arguments + [path]
            try chmod.run()
            chmod.waitUntilExit()
            return chmod.terminationStatus
        }
        // The deny-delete entry would stop the sandbox teardown; strip every ACL entry first (registered before
        // tearDown runs, since teardown blocks run before tearDown).
        addTeardownBlock { _ = try? runChmod(["-N"]) }
        XCTAssertEqual(try runChmod(["+a", "everyone deny delete"]), 0)
        let p = try await load("acl.txt")
        XCTAssertEqual(p.aclEntries.count, 1)
        let entry = try XCTUnwrap(p.aclEntries.first)
        XCTAssertTrue(entry.contains("everyone"), entry)
        XCTAssertTrue(entry.contains("deny"), entry)
        XCTAssertTrue(entry.contains("delete"), entry)
    }

    func testMissingItemThrowsReadFailure() async throws {
        do {
            _ = try await load("missing.txt")
            XCTFail("expected a ReadFailure")
        } catch let failure as ReadFailure {
            XCTAssertEqual(failure.code, ENOENT)
        }
    }

    func testLoadManyCountsFilesFoldersSizeAndTriState() async throws {
        try sandbox.createFile("a.txt", contents: Data(count: 3))
        try sandbox.createFile("b.txt", contents: Data(count: 4))
        try sandbox.setFlags("b.txt", UInt32(UF_HIDDEN))
        try sandbox.createFile("F/c.txt", contents: Data(count: 100))
        try sandbox.setFlags("F", UInt32(UF_HIDDEN))
        try sandbox.setHiddenExtension("a.txt")
        try sandbox.setHiddenExtension("b.txt")
        let urls = ["a.txt", "b.txt", "F"].map { sandbox.url($0) }
        let m = try await PropertiesLoader.loadMany(urls, lanes: lanes, volume: volume)
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m.files, 2)
        XCTAssertEqual(m.folders, 1)
        XCTAssertEqual(m.totalSize, 107, "file sizes plus each folder's contents")
        XCTAssertEqual(m.hidden, .mixed)
        XCTAssertEqual(m.locked, .off)
        XCTAssertEqual(m.extensionHidden, .mixed)

        let hiddenOnly = try await PropertiesLoader.loadMany([sandbox.url("b.txt"), sandbox.url("F")], lanes: lanes, volume: volume)
        XCTAssertEqual(hiddenOnly.hidden, .on)
    }

    func testLoadManyThrowsWhenAnItemIsMissing() async throws {
        try sandbox.createFile("a.txt")
        do {
            _ = try await PropertiesLoader.loadMany([sandbox.url("a.txt"), sandbox.url("gone")], lanes: lanes, volume: volume)
            XCTFail("expected a ReadFailure")
        } catch let failure as ReadFailure {
            XCTAssertEqual(failure.code, ENOENT)
        }
    }

    func testLoadVolumeUsesScannerForAvailableSpace() async throws {
        let info = VolumeInfo(id: volume, mountPoint: sandbox.root, name: "Test", format: "APFS", isBoot: false,
                              isInternal: true, isRemovable: false, isEjectable: false, isLocal: true, isReadOnly: false,
                              isBrowsable: true, totalCapacity: 100,
                              capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
        let v = await PropertiesLoader.loadVolume(info, scanner: FixedScanner(available: 25), lanes: lanes)
        XCTAssertEqual(v.volume, info)
        XCTAssertEqual(v.capacity, 100)
        XCTAssertEqual(v.available, 25)
        XCTAssertEqual(v.used, 75)

        let unknown = await PropertiesLoader.loadVolume(info, scanner: FixedScanner(available: nil), lanes: lanes)
        XCTAssertNil(unknown.available)
        XCTAssertNil(unknown.used)
    }

    func testLoadVolumeReadsCapacityWhenTheInfoHasNone() async throws {
        var info = VolumeInfo(id: volume, mountPoint: sandbox.root, name: "Test", format: "APFS", isBoot: false,
                              isInternal: true, isRemovable: false, isEjectable: false, isLocal: true, isReadOnly: false,
                              isBrowsable: true, totalCapacity: nil,
                              capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
        let v = await PropertiesLoader.loadVolume(info, scanner: SystemVolumeScanner(), lanes: lanes)
        XCTAssertGreaterThan(v.capacity ?? 0, 0)
        XCTAssertGreaterThan(v.available ?? 0, 0)
        XCTAssertGreaterThanOrEqual(v.used ?? -1, 0)
        info.totalCapacity = 10
        XCTAssertEqual(VolumeProperties(volume: info, capacity: 10, available: 20).used, 0, "never negative")
    }
}

private struct FixedScanner: VolumeScanning {
    let available: Int64?
    func scan() throws -> [VolumeInfo] { [] }
    func availableCapacity(of mountPoint: URL) -> Int64? { available }
}
