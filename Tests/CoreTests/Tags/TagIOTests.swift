import XCTest
import Darwin
@testable import Core
import MacxFixtures
import MacxFS

final class TagIOTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    /// TagIO.read/write are lane-only (assertOffMain).
    private func onLane<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await LanePool().perform(on: .unknown) { _ in try body() }
    }

    func testEncodeDecodeRoundTripAndFinderShape() throws {
        let tags = [FileTag(name: "Red", color: .red), FileTag(name: "Project X"), FileTag(name: "Green", color: .green)]
        let data = try TagIO.encode(tags)
        let raw = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        XCTAssertEqual(raw, ["Red\n6", "Project X", "Green\n2"])
        XCTAssertEqual(TagIO.decode(data), tags)
        var format = PropertyListSerialization.PropertyListFormat.xml
        _ = try PropertyListSerialization.propertyList(from: data, format: &format)
        XCTAssertEqual(format, .binary)
        XCTAssertEqual(FinderMetadata.parseTags(data), ["Red", "Project X", "Green"], "the Tags column reader agrees")
    }
    func testDecodeToleratesGarbageAndUnknownColours() throws {
        XCTAssertEqual(TagIO.decode(Data("nonsense".utf8)), [])
        let data = try PropertyListSerialization.data(fromPropertyList: ["A\n9", "B\n", 42, "C\n3"] as [Any], format: .binary, options: 0)
        XCTAssertEqual(TagIO.decode(data), [FileTag(name: "A"), FileTag(name: "B"), FileTag(name: "C", color: .purple)])
    }
    func testNormalize() {
        let n = TagIO.normalize([FileTag(name: "  Work "), FileTag(name: ""), FileTag(name: "work", color: .blue),
                                 FileTag(name: "\n"), FileTag(name: "Home", color: .red)])
        XCTAssertEqual(n, [FileTag(name: "Work"), FileTag(name: "Home", color: .red)])
    }
    func testStandardTags() {
        XCTAssertEqual(FileTag.standard.map(\.name), ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        XCTAssertEqual(FileTag.standard.map(\.color.rawValue), [6, 7, 5, 2, 4, 3, 1])
    }
    func testReadWriteOnSandboxFilesAndLinks() async throws {
        let file = try sandbox.createFile("a.txt")
        let link = try sandbox.createSymlink("l", target: "a.txt")
        let blue = FileTag(name: "Blue", color: .blue)
        try await onLane {
            XCTAssertEqual(try TagIO.read(file), [])                                   // ENOATTR → []
            try TagIO.write([blue], to: file)
            XCTAssertEqual(try TagIO.read(file), [blue])
            XCTAssertEqual(try TagIO.read(link), [])                                   // the link has its own tags
            try TagIO.write([FileTag(name: "L")], to: link)
            XCTAssertEqual(try TagIO.read(link), [FileTag(name: "L")])
            XCTAssertEqual(try TagIO.read(file), [blue])
            try TagIO.write([], to: file)
            XCTAssertEqual(getxattr(file.path, TagIO.xattrName, nil, 0, 0, XATTR_NOFOLLOW), -1)   // [] removes
            XCTAssertEqual(errno, ENOATTR)
            XCTAssertNoThrow(try TagIO.write([], to: file))                            // removing twice is fine
        }
    }
    func testWriteNeverTouchesFinderInfo() async throws {
        let file = try sandbox.createFile("a.txt")
        try await onLane { try TagIO.write([FileTag(name: "Red", color: .red)], to: file) }
        XCTAssertEqual(getxattr(file.path, "com.apple.FinderInfo", nil, 0, 0, XATTR_NOFOLLOW), -1)
    }
    func testReadMissingFileThrowsENOENT() async throws {
        let missing = sandbox.url("missing")
        let error = try await onLane { () -> TagIOError? in
            do throws(TagIOError) { _ = try TagIO.read(missing); return nil } catch { return error }
        }
        XCTAssertEqual(error, TagIOError(code: ENOENT))
    }
}
