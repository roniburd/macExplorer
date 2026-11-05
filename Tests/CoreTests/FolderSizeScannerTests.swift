import Darwin
import Foundation
import Synchronization
import XCTest
@testable import Core
import MacxFS
import MacxFixtures

final class FolderSizeScannerTests: XCTestCase {
    var sandbox: Sandbox!
    let lanes = LanePool()

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        addTeardownBlock { [sandbox] in
            guard let s = sandbox else { return }
            if access(s.url("tree/d/locked").path(percentEncoded: false), F_OK) == 0 { try? s.setMode("tree/d/locked", 0o755) }
            s.destroy()
        }
    }

    func scan(_ rel: String, table: MountTable = .empty, onDirectory: (@Sendable (Int) -> Void)? = nil) async throws -> FolderSize? {
        let url = sandbox.url(rel)
        return try await lanes.perform(on: .unknown, .scan) { ctx in
            FolderSizeScanner.scan(url, context: ctx, mountTable: table, onDirectory: onDirectory)
        }
    }

    func testCountsFilesFoldersAndPackageContents() async throws {
        try sandbox.createFile("tree/a", contents: Data(count: 10))
        try sandbox.createFile("tree/d/b", contents: Data(count: 20))
        try sandbox.createFile("tree/d/e/c", contents: Data(count: 30))
        try sandbox.createDirectory("tree/d/e/f")
        try sandbox.createFile("tree/X.app/Contents/MacOS/bin", contents: Data(count: 100))
        let size = try await scan("tree")
        XCTAssertEqual(size, FolderSize(bytes: 160, allocatedBytes: size!.allocatedBytes, files: 4, folders: 6, isPartial: false))
        XCTAssertGreaterThanOrEqual(size!.allocatedBytes, 0)
    }

    // Review Focus 3 (dataless part: testDatalessDirectoryIsNotDescendedAndMarksPartial; mount part: testMountPointIsNotCrossed)
    func testScannerHardLinksSymlinkLoopUnreadableDatalessAndMountPoint() async throws {
        try sandbox.createFile("tree/d/h1", contents: Data(count: 1_000))
        try sandbox.createHardLink("tree/d/h2", to: "tree/d/h1")
        try sandbox.createSymlink("tree/d/loop", target: "..")                 // loop back to tree/
        try sandbox.createFile("outside/big", contents: Data(count: 100_000))
        try sandbox.createSymlink("tree/d/out", target: "../../outside")       // must not be followed
        try sandbox.createFile("tree/d/locked/secret", contents: Data(count: 500))
        try sandbox.setMode("tree/d/locked", 0o000)
        let size = try await scan("tree")!
        XCTAssertEqual(size.bytes, 1_000 + linkBytes(["tree/d/loop", "tree/d/out"]),
                       "hard link counted once; links counted as links, never followed; locked contents excluded")
        XCTAssertEqual(size.files, 3, "h1 (once) + two symlinks")
        XCTAssertEqual(size.folders, 2, "d and locked")
        XCTAssertTrue(size.isPartial, "the unreadable folder makes the size partial")
    }

    func testMountPointIsNotCrossed() async throws {
        guard DiskImage.isAvailable, let image = try? DiskImage.create(in: sandbox, format: .apfs, sizeMB: 8) else {
            throw XCTSkip("hdiutil unavailable")
        }
        addTeardownBlock { try? image.detach() }
        try Data(count: 1_000_000).write(to: image.mountPoint.appending(path: "inside"))   // inside the test's own image
        try sandbox.createFile("plain", contents: Data(count: 10))
        let table = MountTable([
            VolumeInfoFixtures.volume(id: "uuid:ROOT", mountPoint: URL(filePath: "/", directoryHint: .isDirectory)),
            VolumeInfoFixtures.volume(id: "uuid:IMG", mountPoint: image.mountPoint),
        ])
        let url = sandbox.root
        let size = try await lanes.perform(on: .unknown, .scan) { ctx in
            FolderSizeScanner.scan(url, context: ctx, mountTable: table)
        }!
        // The sandbox root holds `plain`, the image's own .dmg file and its mount point; only the 1 MB file inside
        // the mounted volume must be left out.
        var st = stat()
        XCTAssertEqual(lstat(image.imageURL.path(percentEncoded: false), &st), 0)
        XCTAssertEqual(size.bytes, 10 + Int64(st.st_size), "the image mounted inside the sandbox is another volume")
        XCTAssertEqual(size.files, 2, "plain and the .dmg; nothing from inside the image")
        XCTAssertFalse(size.isPartial, "skipping another volume is not partial")
    }

    func linkBytes(_ paths: [String]) -> Int64 {
        paths.reduce(0) { total, rel in
            var st = stat(); _ = lstat(sandbox.url(rel).path(percentEncoded: false), &st); return total + Int64(st.st_size)
        }
    }

    func testDatalessDirectoryIsNotDescendedAndMarksPartial() {
        var batch = Batch(generation: .initial)
        let dir = Entry(rowID: 1, fileID: 1, size: 3, allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                        kind: .directory, flags: [.dataless], typeIndex: TypeRegistry.folderIndex)
        let file = Entry(rowID: 2, fileID: 2, size: 42, allocSize: 4096, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                         kind: .file, flags: [.dataless], typeIndex: TypeRegistry.dataIndex)
        Array("cloud".utf8).withUnsafeBufferPointer { batch.append(dir, nameBytes: $0) }
        Array("f".utf8).withUnsafeBufferPointer { batch.append(file, nameBytes: $0) }
        var state = FolderSizeScanner.ScanState(mountPoints: [])
        FolderSizeScanner.accumulate(batch, in: URL(filePath: "/x", directoryHint: .isDirectory), state: &state)
        XCTAssertTrue(state.pending.isEmpty, "dataless folder never read")
        XCTAssertTrue(state.result.isPartial)
        XCTAssertEqual(state.result.bytes, 42, "a dataless file's logical size is metadata and counts")
        XCTAssertEqual(state.result.folders, 1)
    }

    func testDegradedEntryMarksPartialAndHardLinksCountOncePerScan() {
        var batch = Batch(generation: .initial)
        let a = Entry(rowID: 10, fileID: 7, size: 5, allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                      kind: .file, flags: [.hasHardLinks], typeIndex: TypeRegistry.dataIndex)
        let b = Entry(rowID: 11, fileID: 7, size: 5, allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                      kind: .file, flags: [.hasHardLinks], typeIndex: TypeRegistry.dataIndex)
        let bad = Entry(rowID: 12, fileID: 8, size: 0, allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0,
                        kind: .other, flags: [.degraded], typeIndex: TypeRegistry.dataIndex)
        for (e, n) in [(a, "a"), (b, "b"), (bad, "c")] { Array(n.utf8).withUnsafeBufferPointer { batch.append(e, nameBytes: $0) } }
        var state = FolderSizeScanner.ScanState(mountPoints: [])
        FolderSizeScanner.accumulate(batch, in: URL(filePath: "/x", directoryHint: .isDirectory), state: &state)
        XCTAssertEqual(state.result.bytes, 5)
        XCTAssertEqual(state.result.files, 2, "one hard-linked file plus the degraded entry")
        XCTAssertTrue(state.result.isPartial)
    }

    /// Review Focus 3: a cancel stops the scan within one directory. The cancel is issued from inside the scan
    /// (after directory 10), so the count at that moment is exact rather than racing a polling loop.
    func testCancellationStopsWithinADirectory() async throws {
        for i in 0..<400 { try sandbox.createFile("many/d\(i)/f", contents: Data(count: 1)) }
        let url = sandbox.url("many")
        let visited = Mutex(0)
        let cancelledAt = Mutex<Int?>(nil)
        let handle = Mutex<Task<FolderSize?, any Error>?>(nil)
        let lanes = self.lanes
        let task = Task {
            try await lanes.perform(on: .unknown, .scan) { ctx in
                FolderSizeScanner.scan(url, context: ctx, mountTable: .empty, onDirectory: { n in
                    visited.withLock { $0 = n }
                    guard n == 10 else { return }
                    var task: Task<FolderSize?, any Error>?
                    while task == nil { task = handle.withLock { $0 }; if task == nil { usleep(1_000) } }
                    task?.cancel()                      // sets the lane job's cancel flag synchronously
                    cancelledAt.withLock { $0 = n }
                })
            }
        }
        handle.withLock { $0 = task }
        let result = try? await task.value
        XCTAssertNil(result ?? nil, "a cancelled scan returns nil")
        let atCancel = try XCTUnwrap(cancelledAt.withLock { $0 })
        let final = visited.withLock { $0 }
        XCTAssertLessThanOrEqual(final, atCancel + 1, "the scan stops within one directory of the cancel")
    }

    func testScanLanesAreSeparateFromReadLanes() async throws {
        try sandbox.createDirectory("tree0-empty-ok")
        let size = try await scan("tree0-empty-ok")
        XCTAssertEqual(size, FolderSize())
        let v = VolumeID.unknown
        let reads = await lanes.liveLaneCount(of: v, .read)
        let scans = await lanes.liveLaneCount(of: v, .scan)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(scans, 1)
    }
}
