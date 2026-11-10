import XCTest
import Darwin
import ImageIO
import UniformTypeIdentifiers
@testable import Core
import MacxFixtures
import MacxFS

/// Records calls; used to test job and undo logic without touching icons.
final class FakeIconWriter: CustomIconWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var icons: [String: IconImageData] = [:]
    private var failingPaths: [String: Int32] = [:]
    func fail(_ url: URL, with code: Int32) { lock.withLock { failingPaths[url.path] = code } }
    func currentCustomIcon(_ url: URL) throws -> IconImageData? { lock.withLock { icons[url.path] } }
    func setIcon(_ data: IconImageData?, for url: URL) throws {
        try lock.withLock {
            if let code = failingPaths[url.path] { throw TagIOError(code: code) }
            icons[url.path] = data
        }
    }
}

enum TestImages {
    /// A solid-colour PNG, built in memory.
    static func png(size: Int = 64, red: CGFloat = 1) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: red, green: 0.2, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

final class CustomIconTests: FileOpsTestCase {
    private func queue(_ fake: FakeIconWriter, interaction: ScriptedInteraction = ScriptedInteraction()) -> FileOpQueue {
        FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                    interaction: interaction, iconWriter: fake)
    }

    func testImageDataValidation() {
        XCTAssertTrue(IconImageData(bytes: TestImages.png()).isDecodableImage)
        XCTAssertFalse(IconImageData(bytes: Data("not an image".utf8)).isDecodableImage)
        XCTAssertFalse(IconImageData(bytes: Data()).isDecodableImage)
        XCTAssertEqual(IconImageData.maxBytes, 10 * 1024 * 1024)
        XCTAssertFalse(IconImageData(bytes: Data(count: IconImageData.maxBytes + 1)).isDecodableImage)
    }

    func testSameImageComparesPixelsNotBytes() {
        let a = IconImageData(bytes: TestImages.png(size: 64, red: 0.9))
        let b = IconImageData(bytes: TestImages.png(size: 128, red: 0.9))     // other bytes, same picture
        let c = IconImageData(bytes: TestImages.png(size: 64, red: 0.1))
        XCTAssertTrue(IconCompare.sameImage(a, a))
        XCTAssertTrue(IconCompare.sameImage(a, b))
        XCTAssertFalse(IconCompare.sameImage(a, c))
        XCTAssertTrue(IconCompare.sameImage(nil, nil))
        XCTAssertFalse(IconCompare.sameImage(a, nil))
        XCTAssertFalse(IconCompare.sameImage(IconImageData(bytes: Data("x".utf8)), IconImageData(bytes: Data("y".utf8))))
    }

    func testResourceForkParserFindsIconAndRejectsTruncatedForks() {
        let payload = Data("ICNSDATA".utf8)
        let fork = Self.fork(type: "icns", id: -16455, payload: payload)
        XCTAssertEqual(ResourceFork.resource(type: "icns", id: -16455, in: fork), payload)
        XCTAssertNil(ResourceFork.resource(type: "icns", id: 128, in: fork))
        XCTAssertNil(ResourceFork.resource(type: "PICT", id: -16455, in: fork))
        for cut in [0, 3, 20, fork.count / 2, fork.count - 5] {   // the trailing 4-byte handle is never read
            XCTAssertNil(ResourceFork.resource(type: "icns", id: -16455, in: fork.prefix(cut)), "cut at \(cut)")
        }
    }

    func testDescriptionAndURLs() throws {
        let a = try file("d/a.txt"), b = try file("d/b.txt")
        let kind = JobKind.setCustomIcon([a, b], nil)
        XCTAssertEqual(kind.allURLs, [a, b])
        XCTAssertEqual(kind.jobDescription, JobDescription(verb: .changingIcon, itemCount: 2, firstItemName: "a.txt",
                                                           sourceFolderName: "d", destinationFolderName: nil))
    }

    func testWorkspaceWriterSetsReadsAndRemovesOnFileAndFolder() async throws {
        let f = try file("a.txt"), d = try dir("Folder")
        let writer = WorkspaceIconWriter()
        let lanes = LanePool()
        let before = try await lanes.perform(on: .unknown, .fileOp) { _ in try writer.currentCustomIcon(f) }
        XCTAssertNil(before)
        let decodable = try await lanes.perform(on: .unknown, .fileOp) { _ -> [Bool?] in
            try writer.setIcon(IconImageData(bytes: TestImages.png()), for: f)
            try writer.setIcon(IconImageData(bytes: TestImages.png()), for: d)
            return [try writer.currentCustomIcon(f)?.isDecodableImage, try writer.currentCustomIcon(d)?.isDecodableImage]
        }
        XCTAssertEqual(decodable, [true, true])
        XCTAssertTrue(exists(d.appending(path: "Icon\r")))
        XCTAssertTrue(Self.hasCustomIconFlag(f.path)); XCTAssertTrue(Self.hasCustomIconFlag(d.path))
        let read = try await lanes.perform(on: .unknown, .fileOp) { _ -> IconImageData? in try writer.currentCustomIcon(f) }
        XCTAssertTrue(IconCompare.sameImage(read, IconImageData(bytes: TestImages.png())), "read-back is the stored picture")
        let after = try await lanes.perform(on: .unknown, .fileOp) { _ -> [Bool] in
            try writer.setIcon(nil, for: f); try writer.setIcon(nil, for: d)
            return [try writer.currentCustomIcon(f) == nil, try writer.currentCustomIcon(d) == nil]
        }
        XCTAssertEqual(after, [true, true])
        XCTAssertFalse(Self.hasCustomIconFlag(f.path)); XCTAssertFalse(exists(d.appending(path: "Icon\r")))
    }

    func testWorkspaceWriterErrors() async throws {
        let writer = WorkspaceIconWriter()
        let missing = url("missing.txt"), f = try file("b.txt")
        let codes = try await LanePool().perform(on: .unknown, .fileOp) { _ -> [Int32] in
            var out: [Int32] = []
            do { try writer.setIcon(IconImageData(bytes: TestImages.png()), for: missing) } catch let e as IconWriteError { out.append(e.code) }
            do { try writer.setIcon(IconImageData(bytes: Data("x".utf8)), for: f) } catch let e as IconWriteError { out.append(e.code) }
            return out
        }
        XCTAssertEqual(codes, [ENOENT, EINVAL])
        XCTAssertFalse(Self.hasCustomIconFlag(f.path))
    }

    /// The real writer re-encodes PNGs as ICNS: undo still recognises the icon it set and restores the earlier one.
    func testWorkspaceWriterJobUndoAndRedoRoundTrip() async throws {
        let f = try file("w.txt")
        let queue = FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                                interaction: ScriptedInteraction(), iconWriter: WorkspaceIconWriter())
        let first = IconImageData(bytes: TestImages.png(red: 0.1)), second = IconImageData(bytes: TestImages.png(red: 0.9))
        _ = try await run(.setCustomIcon([f], first), on: queue)
        let change = try await run(.setCustomIcon([f], second), on: queue)
        XCTAssertEqual(change.record.actions.count, 1)
        let current = { try await LanePool().perform(on: .unknown, .fileOp) { _ in try WorkspaceIconWriter().currentCustomIcon(f) } }
        let afterSet = try await current()
        XCTAssertTrue(IconCompare.sameImage(afterSet, second))
        let undo = try await run(.undo(change.record), on: queue)
        XCTAssertTrue(undo.skipped.isEmpty)
        let afterUndo = try await current()
        XCTAssertTrue(IconCompare.sameImage(afterUndo, first))
        _ = try await run(.redo(undo.record), on: queue)
        let afterRedo = try await current()
        XCTAssertTrue(IconCompare.sameImage(afterRedo, second))
        let removal = try await run(.setCustomIcon([f], nil), on: queue)
        XCTAssertFalse(Self.hasCustomIconFlag(f.path))
        _ = try await run(.undo(removal.record), on: queue)
        XCTAssertTrue(Self.hasCustomIconFlag(f.path))
    }

    func testJobRecordsPreviousAndUndoRestoresIt() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let fake = FakeIconWriter()
        let old = IconImageData(bytes: TestImages.png(red: 0.1)), new = IconImageData(bytes: TestImages.png(red: 0.9))
        try fake.setIcon(old, for: a)
        let queue = queue(fake)
        let outcome = try await run(.setCustomIcon([a, b], new), on: queue)
        XCTAssertEqual(outcome.record.verb, .changingIcon)
        XCTAssertEqual(outcome.record.actions, [.customIconChanged(a, previous: old, new: new), .customIconChanged(b, previous: nil, new: new)])
        XCTAssertTrue(outcome.localChanges.contains { $0.modified.contains("b.txt") })
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(try fake.currentCustomIcon(a), old); XCTAssertNil(try fake.currentCustomIcon(b))
        XCTAssertTrue(undo.skipped.isEmpty)
        _ = try await run(.redo(undo.record), on: queue)
        XCTAssertEqual(try fake.currentCustomIcon(a), new)
        XCTAssertEqual(try fake.currentCustomIcon(b), new)
    }

    func testRemoveRecordsOnlyItemsThatHadAnIconAndUndoPutsItBack() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let fake = FakeIconWriter()
        let old = IconImageData(bytes: TestImages.png(red: 0.3))
        try fake.setIcon(old, for: a)
        let queue = queue(fake)
        let outcome = try await run(.setCustomIcon([a, b], nil), on: queue)
        XCTAssertEqual(outcome.record.actions, [.customIconChanged(a, previous: old, new: nil)])
        XCTAssertNil(try fake.currentCustomIcon(a))
        _ = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(try fake.currentCustomIcon(a), old)
    }

    func testUndoSkipsItemWhoseIconChangedSince() async throws {
        let a = try file("a.txt")
        let fake = FakeIconWriter()
        let queue = queue(fake)
        let outcome = try await run(.setCustomIcon([a], IconImageData(bytes: TestImages.png())), on: queue)
        let external = IconImageData(bytes: TestImages.png(red: 0.5))
        try fake.setIcon(external, for: a)
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(undo.skipped.map(\.reason), [.changedDuringMove])
        XCTAssertEqual(try fake.currentCustomIcon(a), external)
    }

    func testUndoSkipsItemThatIsGone() async throws {
        let a = try file("a.txt")
        let fake = FakeIconWriter()
        let queue = queue(fake)
        let outcome = try await run(.setCustomIcon([a], IconImageData(bytes: TestImages.png())), on: queue)
        try FileManager.default.removeItem(at: a)      // the sandbox file this test created
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(undo.skipped.map(\.reason), [.sourceGone])
    }

    func testUndoPlannerStep() {
        let u = URL(filePath: "/tmp/macx-x/a.txt")
        let p = IconImageData(bytes: Data([1])), n = IconImageData(bytes: Data([2]))
        let record = JobRecord(id: JobID(), verb: .changingIcon, actions: [.customIconChanged(u, previous: p, new: n)])
        XCTAssertEqual(UndoPlanner.steps(for: record), [.restoreIcon(u, expected: n, restore: p)])
        XCTAssertEqual(ItemAction.customIconChanged(u, previous: p, new: n).urls, [u])
    }

    func testRejectsUndecodableOrOversizeDataBeforeTouchingFiles() async throws {
        let a = try file("a.txt")
        let fake = FakeIconWriter()
        let interaction = ScriptedInteraction(errors: [.skip])
        let outcome = try await run(.setCustomIcon([a], IconImageData(bytes: Data("x".utf8))), on: queue(fake, interaction: interaction))
        XCTAssertTrue(outcome.record.actions.isEmpty)
        XCTAssertEqual(interaction.askedErrors().first?.kind, .other(code: EINVAL, message: "not an image"))
        XCTAssertEqual(outcome.skipped.map(\.url), [a])
        XCTAssertNil(try fake.currentCustomIcon(a))
    }

    func testLockedFileIsAskedAbout() async throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let fake = FakeIconWriter(); fake.fail(a, with: EPERM)
        let interaction = ScriptedInteraction(errors: [.skip])
        let outcome = try await run(.setCustomIcon([a, b], IconImageData(bytes: TestImages.png())), on: queue(fake, interaction: interaction))
        XCTAssertEqual(outcome.skipped.map(\.url), [a])
        XCTAssertEqual(interaction.askedErrors().count, 1)
        XCTAssertNotNil(try fake.currentCustomIcon(b))
    }

    /// NSWorkspace.setIcon follows symlinks: the real writer refuses a link (ENOTSUP) so the target, which may be
    /// outside the selection, is never changed; the job skips the link with a reason and records nothing.
    func testSymlinkIsRefusedAndItsTargetKeepsItsXattrs() async throws {
        let target = try file("target.txt")
        let link = url("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)   // inside this test's sandbox
        let before = Self.xattrNames(target.path)
        let code = try await LanePool().perform(on: .unknown, .fileOp) { _ -> Int32? in
            do { try WorkspaceIconWriter().setIcon(IconImageData(bytes: TestImages.png()), for: link); return nil }
            catch let e as IconWriteError { return e.code }
        }
        XCTAssertEqual(code, ENOTSUP)
        let interaction = ScriptedInteraction()
        let queue = FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                                interaction: interaction, iconWriter: WorkspaceIconWriter())
        let outcome = try await run(.setCustomIcon([link], IconImageData(bytes: TestImages.png())), on: queue)
        XCTAssertTrue(outcome.record.actions.isEmpty)
        XCTAssertEqual(outcome.skipped.map(\.url), [link])
        XCTAssertNotNil(outcome.skipped.first?.reason)
        XCTAssertTrue(interaction.askedErrors().isEmpty, "skipped without a pointless Retry question")
        XCTAssertEqual(Self.xattrNames(target.path), before)
        XCTAssertFalse(Self.hasCustomIconFlag(target.path))
        XCTAssertFalse(Self.xattrNames(link.path).contains { $0 == "com.apple.FinderInfo" || $0 == "com.apple.ResourceFork" })
    }

    // MARK: helpers

    static func xattrNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let n = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard n > 0 else { return [] }
        return buffer.prefix(n).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
    }

    static func hasCustomIconFlag(_ path: String) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(path, "com.apple.FinderInfo", &info, 32, 0, XATTR_NOFOLLOW) == 32 else { return false }
        return (UInt16(info[8]) << 8 | UInt16(info[9])) & 0x0400 != 0
    }

    /// A one-resource classic resource fork (header, data, map with one type and one reference).
    static func fork(type: String, id: Int16, payload: Data) -> Data {
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let dataOffset = 256
        let data = be32(payload.count) + Array(payload)
        let mapOffset = dataOffset + data.count
        var map = [UInt8](repeating: 0, count: 24)               // header copy, handle, file ref, attributes
        map += be16(28) + be16(28 + 2 + 8 + 12)                    // type list offset, name list offset
        map += be16(0)                                             // type count - 1
        map += Array(type.utf8) + be16(0) + be16(2 + 8)            // type, count - 1, ref list offset (from type list)
        map += be16(Int(UInt16(bitPattern: id))) + be16(0xFFFF) + [0] + [0, 0, 0] + be32(0)   // id, no name, attrs, offset 0
        var out = be32(dataOffset) + be32(mapOffset) + be32(data.count) + be32(map.count)
        out += [UInt8](repeating: 0, count: dataOffset - out.count)
        return Data(out + data + map)
    }
}
