import XCTest
import CoreGraphics
@testable import Core
@testable import MacxFS
import MacxFixtures

final class PreviewMetadataTests: XCTestCase {
    var sandbox: Sandbox!
    let types = TypeRegistry()
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    func load(_ rel: String, isDirectory: Bool = false) async -> PreviewDetails {
        let index = isDirectory ? TypeRegistry.folderIndex
            : types.index(forExtension: Substring((rel as NSString).pathExtension), isDirectory: false)
        return await PreviewMetadata.load(sandbox.url(rel), typeIndex: index, types: types, lanes: LanePool(), volume: .unknown)
    }

    /// 1 s of 8 kHz mono 16-bit silence.
    func wav() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + 16_000); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(16_000); d.append(Data(count: 16_000))
        return d
    }

    func testSizesDatesAndKind() async throws {
        try sandbox.createFile("t.txt", contents: Data("12345".utf8))
        try sandbox.createDirectory("d")
        let t = await load("t.txt")
        XCTAssertEqual(t.size, 5)
        XCTAssertNotNil(t.created)
        XCTAssertNotNil(t.modified)
        XCTAssertFalse(t.kindDescription.isEmpty)
        let d = await load("d", isDirectory: true)
        XCTAssertNil(d.size)
        XCTAssertNotNil(d.modified)
    }

    func testImageDimensions() async throws {
        try sandbox.writePNG("p.png", pixels: 64)
        let p = await load("p.png")
        XCTAssertEqual(p.pixelWidth, 64)
        XCTAssertEqual(p.pixelHeight, 64)
    }

    func testAudioDuration() async throws {
        try sandbox.createFile("tone.wav", contents: wav())
        let a = await load("tone.wav")
        XCTAssertEqual(try XCTUnwrap(a.duration), 1.0, accuracy: 0.02)
    }

    /// A symlink describes its target (like PreviewPlanner): size, folder-ness and dataless come from `stat`.
    func testSymlinkReportsTheTarget() async throws {
        let data = wav()
        try sandbox.createFile("tone.wav", contents: data)
        try sandbox.createSymlink("song.wav", target: "tone.wav")
        let a = await load("song.wav")
        XCTAssertEqual(a.size, Int64(data.count))
        XCTAssertEqual(try XCTUnwrap(a.duration), 1.0, accuracy: 0.02)
        try sandbox.createDirectory("d")
        try sandbox.createSymlink("dlink", target: "d")
        let gathered = PreviewMetadata.gather(sandbox.url("dlink").path(percentEncoded: false), type: .symbolicLink, kindDescription: "x")
        XCTAssertTrue(gathered.isDirectory)
        XCTAssertNil(gathered.details.size)
        try sandbox.createSymlink("broken.wav", target: "missing.wav")
        let broken = await load("broken.wav")
        XCTAssertEqual(broken.size, Int64("missing.wav".utf8.count))   // the link itself
        XCTAssertNil(broken.duration)
    }

    func testPDFPageCount() async throws {
        let url = sandbox.url("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        let p = await load("doc.pdf")
        XCTAssertEqual(p.pageCount, 2)
    }

    /// ImageIO / CGPDFDocument / AVFoundation never open a FIFO (it would block). Sandbox-only FIFOs.
    func testFIFONamedLikeMediaReturnsPromptly() async throws {
        for name in ["pipe.png", "pipe.pdf", "pipe.wav"] {
            XCTAssertEqual(mkfifo(sandbox.url(name).path(percentEncoded: false), 0o644), 0)
        }
        let clock = ContinuousClock(), start = clock.now
        for name in ["pipe.png", "pipe.pdf", "pipe.wav"] {
            let d = await load(name)
            XCTAssertNil(d.pixelWidth); XCTAssertNil(d.pageCount); XCTAssertNil(d.duration)
        }
        XCTAssertLessThan(clock.now - start, .seconds(5))
        XCTAssertFalse(PreviewMetadata.isMaterializedFile(sandbox.url("pipe.wav").path(percentEncoded: false)))
    }
}
