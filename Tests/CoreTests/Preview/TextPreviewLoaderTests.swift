import XCTest
import Darwin
@testable import Core
@testable import MacxFS
import MacxFixtures

final class TextPreviewLoaderTests: XCTestCase {
    var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    func testUTF8AndBOMs() {
        XCTAssertEqual(TextPreviewLoader.decode(Array("héllo\n".utf8), truncated: false),
                       TextPreview(text: "héllo\n", truncated: false, encoding: .utf8))
        XCTAssertEqual(TextPreviewLoader.decode([0xEF, 0xBB, 0xBF] + Array("a".utf8), truncated: false)?.text, "a")
        XCTAssertEqual(TextPreviewLoader.decode([0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00], truncated: false),
                       TextPreview(text: "AB", truncated: false, encoding: .utf16LE))
        XCTAssertEqual(TextPreviewLoader.decode([0xFE, 0xFF, 0x00, 0x41], truncated: false)?.encoding, .utf16BE)
    }

    func testUTF16WithoutBOM() {
        let le = Array("plain ascii text".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertEqual(TextPreviewLoader.decode(le, truncated: false)?.encoding, .utf16LE)
        XCTAssertEqual(TextPreviewLoader.decode(le, truncated: false)?.text, "plain ascii text")
    }

    func testLegacyEncodings() {
        XCTAssertEqual(TextPreviewLoader.decode([0x63, 0x61, 0x66, 0xE9, 0x20, 0x80], truncated: false),
                       TextPreview(text: "café €", truncated: false, encoding: .windows1252))
        XCTAssertEqual(TextPreviewLoader.decode(Array("abcdefghij".utf8) + [0x81], truncated: false)?.encoding, .latin1)   // 0x81 undefined in CP1252
        let prose: [UInt8] = Array("Le caf".utf8) + [0xE9] + Array(" est cr".utf8) + [0xE8] + Array("me, d".utf8) + [0xE9, 0x6A, 0xE0] + Array(" pr".utf8) + [0xEA] + Array("t.".utf8)
        XCTAssertEqual(TextPreviewLoader.decode(prose, truncated: false)?.encoding, .windows1252, "Western prose stays CP1252")
    }

    // QA polish: UTF-16 CJK text without a BOM has no NUL bytes; it used to decode as Windows-1252 mojibake.
    func testUTF16CJKWithoutBOMOrNULs() {
        let text = "日本語のテキストです。中文文本测试。한국어"
        let le = Array(text.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let be = Array(text.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        XCTAssertFalse(le.contains(0), "precondition: no NUL bytes")
        XCTAssertEqual(TextPreviewLoader.decode(le, truncated: false), TextPreview(text: text, truncated: false, encoding: .utf16LE))
        XCTAssertEqual(TextPreviewLoader.decode(be, truncated: false), TextPreview(text: text, truncated: false, encoding: .utf16BE))
        // Mixed with ASCII spaces and newlines: NULs, but too few for the parity check.
        let mixed = "日本語のテキスト 中文文本测试\n한국어 텍스트입니다"
        let mixedLE = Array(mixed.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertEqual(TextPreviewLoader.decode(mixedLE, truncated: false)?.text, mixed)
    }

    // QA polish: a mislabelled .txt of random high bytes is not text (it used to show as Windows-1252 garbage).
    func testRandomHighBytesAreNotText() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let bytes = (0..<4_096).map { _ in UInt8.random(in: 0x80...0xFF, using: &rng) }
            XCTAssertNil(TextPreviewLoader.decode(bytes, truncated: true))
        }
        var seeded = Seeded(seed: 42)
        let fixed = (0..<1_000).map { _ in UInt8.random(in: 0x80...0xFF, using: &seeded) }
        XCTAssertNil(TextPreviewLoader.decode(fixed, truncated: false))
    }

    func testBinaryIsNil() {
        XCTAssertNil(TextPreviewLoader.decode([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D], truncated: false))
        XCTAssertNil(TextPreviewLoader.decode((0..<200).map { UInt8(($0 * 7) % 32) | 0x01 }, truncated: false))
    }

    func testTruncatedMidCharacterIsTrimmedNotReplaced() {
        let bytes = Array("abé".utf8).dropLast()                        // "ab" + first byte of é
        let p = TextPreviewLoader.decode(Array(bytes), truncated: true)
        XCTAssertEqual(p?.text, "ab")
        XCTAssertEqual(p?.encoding, .utf8)
    }

    func testLoadTruncatesAtLimit() async throws {
        try sandbox.createFile("big.txt", contents: Data(repeating: UInt8(ascii: "a"), count: 300_000))
        let p = try await TextPreviewLoader.load(sandbox.url("big.txt"), lanes: LanePool(), volume: .unknown)
        XCTAssertEqual(TextPreviewLoader.limit, 262_144)
        XCTAssertEqual(p.text.utf8.count, 262_144)
        XCTAssertTrue(p.truncated)
        try sandbox.createFile("exact.txt", contents: Data(repeating: UInt8(ascii: "b"), count: 262_144))
        let exact = try await TextPreviewLoader.load(sandbox.url("exact.txt"), lanes: LanePool(), volume: .unknown)
        XCTAssertFalse(exact.truncated)
    }

    func testLoadErrors() async throws {
        try sandbox.createFile("bin.dat", contents: Data([0x00, 0x01, 0x02, 0x00, 0xFF, 0x00, 0x13, 0x00, 0x00, 0x7F]))
        do { _ = try await TextPreviewLoader.load(sandbox.url("bin.dat"), lanes: LanePool(), volume: .unknown); XCTFail() }
        catch { XCTAssertEqual(error, .binary) }
        do { _ = try await TextPreviewLoader.load(sandbox.url("missing.txt"), lanes: LanePool(), volume: .unknown); XCTFail() }
        catch { XCTAssertEqual(error, .posix(ENOENT)) }
    }

    /// open() on a FIFO with no writer would block the lane forever: refuse non-regular files promptly.
    func testLoadRefusesAFIFOPromptly() async throws {
        XCTAssertEqual(mkfifo(sandbox.url("pipe.txt").path(percentEncoded: false), 0o644), 0)
        let clock = ContinuousClock(), start = clock.now
        do { _ = try await TextPreviewLoader.load(sandbox.url("pipe.txt"), lanes: LanePool(), volume: .unknown); XCTFail() }
        catch { XCTAssertEqual(error, .posix(ENOTSUP)) }
        XCTAssertLessThan(clock.now - start, .seconds(5))
    }
}

/// SplitMix64: a deterministic generator for reproducible byte soup.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
