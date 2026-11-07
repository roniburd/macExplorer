import XCTest
import Darwin
import Synchronization
import UniformTypeIdentifiers
@testable import Core
@testable import MacxFS
import MacxFixtures

final class PreviewPlannerTests: XCTestCase {
    var sandbox: Sandbox!
    let types = TypeRegistry()
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    func subject(_ rel: String, _ kind: Kind = .file) -> PreviewSubject {
        let ext = Substring((rel as NSString).pathExtension)
        let isDir = kind == .directory || kind == .package
        let index: UInt16 = switch kind {
        case .directory: TypeRegistry.folderIndex
        case .symlink: TypeRegistry.symlinkIndex
        default: types.index(forExtension: ext, isDirectory: isDir)
        }
        return PreviewSubject(url: sandbox.url(rel), kind: kind, typeIndex: index, flags: [], size: 0)
    }
    func resolve(_ s: PreviewSubject) async -> PreviewContent {
        await PreviewPlanner.resolve(s, lanes: LanePool(), volume: .unknown, types: types)
    }

    func testClassify() {
        XCTAssertEqual(PreviewPlanner.classify(.plainText), .text)
        XCTAssertEqual(PreviewPlanner.classify(.swiftSource), .text)
        XCTAssertEqual(PreviewPlanner.classify(.json), .text)
        XCTAssertEqual(PreviewPlanner.classify(.html), .text)
        XCTAssertEqual(PreviewPlanner.classify(UTType("public.yaml")!), .text)
        XCTAssertEqual(PreviewPlanner.classify(.shellScript), .text)
        XCTAssertEqual(PreviewPlanner.classify(.rtf), .quickLook)
        XCTAssertEqual(PreviewPlanner.classify(.pdf), .quickLook)
        XCTAssertEqual(PreviewPlanner.classify(.png), .quickLook)
        XCTAssertEqual(PreviewPlanner.classify(.mpeg4Movie), .quickLook)
        XCTAssertEqual(PreviewPlanner.classify(.propertyList), .sniff)
        XCTAssertEqual(PreviewPlanner.classify(.data), .sniff)
        XCTAssertEqual(PreviewPlanner.classify(UTType(filenameExtension: "zzqq")!), .sniff)
    }

    func testResolveRealFiles() async throws {
        try sandbox.createFile("a.txt", contents: Data("hi".utf8))
        try sandbox.writePNG("p.png")
        try sandbox.createDirectory("dir")
        try sandbox.createDirectory("X.app/Contents")
        try sandbox.createSymlink("broken", target: "nowhere.txt")
        try sandbox.createSymlink("link.txt", target: "a.txt")
        try sandbox.createFile("notes.zzqq", contents: Data("plain words".utf8))
        try sandbox.createFile("blob.zzqq", contents: Data([0, 1, 2, 3, 0, 0, 255, 254, 0, 9]))
        try sandbox.createFile("empty.zzqq", contents: Data())
        try sandbox.createFile("locked.zzqq", contents: Data("x".utf8))
        try sandbox.setMode("locked.zzqq", 0o000)

        let res1 = await resolve(subject("a.txt"));             XCTAssertEqual(res1, .text(sandbox.url("a.txt")))
        let res2 = await resolve(subject("p.png"));             XCTAssertEqual(res2, .quickLook(sandbox.url("p.png")))
        let res3 = await resolve(subject("dir", .directory));   XCTAssertEqual(res3, .folder(sandbox.url("dir")))
        let res4 = await resolve(subject("X.app", .package));   XCTAssertEqual(res4, .quickLook(sandbox.url("X.app")))
        let res5 = await resolve(subject("broken", .symlink));  XCTAssertEqual(res5, .brokenLink(sandbox.url("broken")))
        let res6 = await resolve(subject("link.txt", .symlink)); XCTAssertEqual(res6, .text(sandbox.url("link.txt")))
        let res7 = await resolve(subject("notes.zzqq"));        XCTAssertEqual(res7, .text(sandbox.url("notes.zzqq")))
        let res8 = await resolve(subject("blob.zzqq"));         XCTAssertEqual(res8, .quickLook(sandbox.url("blob.zzqq")))
        let res9 = await resolve(subject("empty.zzqq"));        XCTAssertEqual(res9, .text(sandbox.url("empty.zzqq")))
        let res10 = await resolve(subject("locked.zzqq"));      XCTAssertEqual(res10, .unavailable(sandbox.url("locked.zzqq"), code: EACCES))
        let res11 = await resolve(subject("gone.txt"));         XCTAssertEqual(res11, .unavailable(sandbox.url("gone.txt"), code: ENOENT))
    }

    func testDatalessIsCloudPlaceholderAndNeverRead() async {
        let reads = LockedCounter()
        let probe = PreviewProbe(
            stat: { _, _ in .success(ProbeStat(mode: S_IFREG | 0o644, flags: UInt32(SF_DATALESS))) },
            readPrefix: { _, _ in reads.increment(); return .success([]) })
        let s = PreviewSubject(url: URL(filePath: "/tmp/macx-tests-none/cloud.zzqq"), kind: .file,
                               typeIndex: types.index(forExtension: "zzqq", isDirectory: false), flags: [.dataless], size: 10)
        let content = await PreviewPlanner.resolve(s, lanes: LanePool(), volume: .unknown, types: types, probe: probe)
        XCTAssertEqual(content, .cloudPlaceholder(s.url))
        XCTAssertEqual(reads.value, 0)
    }

    /// An evicted package (.pages, .rtfd, .app) must not reach QLPreviewView, which would materialize it (spec §11).
    func testDatalessPackageIsCloudPlaceholderAndDatalessFolderStaysFolder() async {
        let probe = PreviewProbe(
            stat: { _, _ in .success(ProbeStat(mode: S_IFDIR | 0o755, flags: UInt32(SF_DATALESS))) },
            readPrefix: { _, _ in .success([]) })
        let pkg = PreviewSubject(url: URL(filePath: "/tmp/macx-tests-none/doc.rtfd"), kind: .package,
                                 typeIndex: types.index(forExtension: "rtfd", isDirectory: true), flags: [.dataless], size: 0)
        let content = await PreviewPlanner.resolve(pkg, lanes: LanePool(), volume: .unknown, types: types, probe: probe)
        XCTAssertEqual(content, .cloudPlaceholder(pkg.url))
        let folder = PreviewSubject(url: URL(filePath: "/tmp/macx-tests-none/Folder"), kind: .directory,
                                    typeIndex: TypeRegistry.folderIndex, flags: [.dataless], size: 0)
        let folderContent = await PreviewPlanner.resolve(folder, lanes: LanePool(), volume: .unknown, types: types, probe: probe)
        XCTAssertEqual(folderContent, .folder(folder.url))
    }
}

final class LockedCounter: Sendable {
    private let state = Mutex(0)
    func increment() { state.withLock { $0 += 1 } }
    var value: Int { state.withLock { $0 } }
}
