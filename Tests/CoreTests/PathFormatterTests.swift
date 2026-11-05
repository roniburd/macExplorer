import XCTest
@testable import Core

final class PathFormatterTests: XCTestCase {
    let home = URL(filePath: "/Users/roni", directoryHint: .isDirectory)
    func item(_ p: String, dir: Bool = false) -> PathItem {
        PathItem(url: URL(filePath: p, directoryHint: dir ? .isDirectory : .notDirectory), isDirectory: dir)
    }

    func testPOSIX() {
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev/a.txt"), style: .posix, home: home), "/Users/roni/dev/a.txt")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev", dir: true), style: .posix, home: home), "/Users/roni/dev")
        XCTAssertEqual(PathFormatter.one(item("/", dir: true), style: .posix, home: home), "/")
    }

    func testTildeIsComponentWise() {
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev/a.txt"), style: .tilde, home: home), "~/dev/a.txt")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni", dir: true), style: .tilde, home: home), "~")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni2/a.txt"), style: .tilde, home: home), "/Users/roni2/a.txt")
        XCTAssertEqual(PathFormatter.one(item("/Volumes/USB/a"), style: .tilde, home: home), "/Volumes/USB/a")
    }

    func testFileURL() {
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/My File.txt"), style: .fileURL, home: home), "file:///Users/roni/My%20File.txt")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev", dir: true), style: .fileURL, home: home), "file:///Users/roni/dev/")
        // URL(filePath:) stores the file-system representation, so "é" arrives (and is copied) as "e" + U+0301, the
        // same spelling every path in the app has; APFS treats both spellings as the same name.
        XCTAssertEqual(PathFormatter.one(item("/tmp/\u{E9}#?.txt"), style: .fileURL, home: home), "file:///tmp/e%CC%81%23%3F.txt")
        XCTAssertEqual(PathFormatter.fileURL("/tmp/\u{E9}", isDirectory: false), "file:///tmp/%C3%A9", "a path string's own bytes")
        XCTAssertEqual(PathFormatter.one(item("/tmp/e\u{301}"), style: .fileURL, home: home), "file:///tmp/e%CC%81", "NFD kept")
        XCTAssertEqual(PathFormatter.one(item("/tmp/100%;a=b"), style: .fileURL, home: home), "file:///tmp/100%25;a=b")
        XCTAssertEqual(PathFormatter.one(item("/", dir: true), style: .fileURL, home: home), "file:///")
        for name in ["My File.txt", "it's", "a#b?c", "x[1]{2}", "tab\there"] {
            let path = "/tmp/" + name
            XCTAssertEqual(URL(string: PathFormatter.one(item(path), style: .fileURL, home: home))?.path(percentEncoded: false), path,
                           "round-trips: \(name)")
        }
    }

    func testName() {
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/dev", dir: true), style: .name, home: home), "dev")
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/.env"), style: .name, home: home), ".env")
        XCTAssertEqual(PathFormatter.one(item("/", dir: true), style: .name, home: home), "/")
    }

    func testShellQuoted() {
        XCTAssertEqual(PathFormatter.one(item("/tmp/it's here.txt"), style: .shellQuoted, home: home), #"'/tmp/it'\''s here.txt'"#)
        XCTAssertEqual(PathFormatter.one(item("/tmp/$HOME `x`"), style: .shellQuoted, home: home), "'/tmp/$HOME `x`'")
    }

    func testMultipleItemsJoin() {
        let items = [item("/a/x y"), item("/a/z")]
        XCTAssertEqual(PathFormatter.format(items, style: .posix, home: home), "/a/x y\n/a/z")
        XCTAssertEqual(PathFormatter.format(items, style: .shellQuoted, home: home), "'/a/x y' '/a/z'")
        XCTAssertEqual(PathFormatter.format([], style: .posix, home: home), "")
    }

    func testDotSegmentsResolveLexically() {
        XCTAssertEqual(PathFormatter.one(item("/Users/roni/./dev/../a.txt"), style: .posix, home: home), "/Users/roni/a.txt")
        XCTAssertEqual(PathFormatter.one(item("/private/var/x"), style: .posix, home: home), "/private/var/x", "spelling kept")
    }

    func testDecomposedNamesAreKeptAsIs() {
        let nfd = "/tmp/Cafe\u{301}.txt"
        XCTAssertEqual(PathFormatter.one(item(nfd), style: .posix, home: home).unicodeScalars.count, nfd.unicodeScalars.count)
    }

    @MainActor func testWriteStringReplacesCutState() {
        let pb = InMemoryPasteboard()
        let clipboard = Clipboard(backend: pb)
        clipboard.cut([URL(filePath: "/tmp/a")])
        XCTAssertFalse(clipboard.cutURLs.isEmpty)
        pb.writeString("/tmp/a")
        clipboard.revalidate()
        XCTAssertTrue(clipboard.cutURLs.isEmpty, "a text copy replaces the clipboard, so the cut marker no longer applies")
        XCTAssertEqual(pb.readString(), "/tmp/a")
        XCTAssertFalse(pb.hasFileURLs())
        XCTAssertFalse(pb.hasCutMarker())
        pb.writeFileURLs([URL(filePath: "/tmp/b")], cutMarker: false)
        XCTAssertEqual(pb.readString(), "/tmp/b", "a file copy replaces the text with its paths, as SystemPasteboard does")
    }
}
