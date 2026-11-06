@testable import Core
import Foundation
import MacxFS
import XCTest

/// Test-only writer of the "Bud1" `.DS_Store` layout (design 2026-11-05 §4), so parser tests never depend on the
/// files Finder left on this machine. Every block is 4 KiB (or the next power of two) at an offset aligned to its size.
enum DSStoreWriter {
    struct Record {
        var name: String
        var code: String
        var value: DSValue
    }

    /// `fanout` > 0 builds a two-level tree: leaves of `fanout` records under one internal node.
    static func file(_ records: [Record], fanout: Int = 0) -> Data {
        let sorted = records.sorted { ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code) }
        var blocks: [[UInt8]] = []                     // block 0 = root (bookkeeping), 1 = DSDB, 2… = nodes
        blocks.append([])
        blocks.append([])
        var rootNode: UInt32
        var levels: UInt32
        if fanout > 0 && sorted.count > fanout {
            // Leaves get every record except one separator per gap; the internal node holds the separators.
            var leaves: [[Record]] = []
            var separators: [Record] = []
            var i = 0
            while i < sorted.count {
                let chunk = Array(sorted[i..<min(sorted.count, i + fanout)])
                leaves.append(chunk)
                i += fanout
                if i < sorted.count { separators.append(sorted[i]); i += 1 }
            }
            let leafIDs = leaves.map { leaf -> UInt32 in
                blocks.append(node(rightmost: 0, entries: leaf.map { (nil, $0) }))
                return UInt32(blocks.count - 1)
            }
            var entries: [(UInt32?, Record)] = []
            for (k, sep) in separators.enumerated() { entries.append((leafIDs[k], sep)) }
            blocks.append(node(rightmost: leafIDs[separators.count], entries: entries))
            rootNode = UInt32(blocks.count - 1)
            levels = 1
        } else {
            blocks.append(node(rightmost: 0, entries: sorted.map { (nil, $0) }))
            rootNode = 2
            levels = 0
        }
        blocks[1] = be(rootNode) + be(levels) + be(UInt32(sorted.count)) + be(UInt32(blocks.count - 2)) + be(0x1000)

        // Layout: block i at offset (i + 1) * S (offset 0 is the header area), S = power of two ≥ every block.
        var size = 4096
        func rootBlock(_ addresses: [UInt32]) -> [UInt8] {
            var out = be(UInt32(addresses.count)) + be(0)
            for a in addresses { out += be(a) }
            out += [UInt8](repeating: 0, count: ((addresses.count + 255) / 256 * 256 - addresses.count) * 4)
            out += be(1) + [4] + Array("DSDB".utf8) + be(1)
            for _ in 0..<32 { out += be(0) }
            return out
        }
        let probeRoot = rootBlock([UInt32](repeating: 0, count: blocks.count))
        while ([probeRoot] + blocks).contains(where: { $0.count > size }) { size *= 2 }
        let shift = UInt32(size.trailingZeroBitCount)
        let addresses = (0..<blocks.count).map { UInt32(($0 + 1) * size) | shift }
        blocks[0] = rootBlock(addresses)
        var bytes = [UInt8](repeating: 0, count: 4 + (blocks.count + 1) * size)
        let header = be(1) + Array("Bud1".utf8) + be(UInt32(size)) + be(UInt32(blocks[0].count)) + be(UInt32(size))
        bytes.replaceSubrange(0..<header.count, with: header)
        for (i, block) in blocks.enumerated() {
            let start = 4 + (i + 1) * size
            bytes.replaceSubrange(start..<(start + block.count), with: block)
        }
        return Data(bytes)
    }

    static func node(rightmost: UInt32, entries: [(UInt32?, Record)]) -> [UInt8] {
        var out = be(rightmost) + be(UInt32(entries.count))
        for (child, record) in entries {
            if let child { out += be(child) }
            out += encode(record)
        }
        return out
    }

    static func encode(_ r: Record) -> [UInt8] {
        let name = Array(r.name.utf16)
        var out = be(UInt32(name.count))
        for unit in name { out += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        out += Array(r.code.utf8)
        switch r.value {
        case .bool(let v): out += Array("bool".utf8) + [v ? 1 : 0]
        case .long(let v): out += Array("long".utf8) + be(v)
        case .short(let v): out += Array("shor".utf8) + be(UInt32(v))
        case .type(let v): out += Array("type".utf8) + Array(v.utf8)
        case .blob(let d): out += Array("blob".utf8) + be(UInt32(d.count)) + [UInt8](d)
        case .ustr(let s):
            let units = Array(s.utf16)
            out += Array("ustr".utf8) + be(UInt32(units.count))
            for unit in units { out += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        case .comp(let v): out += Array("comp".utf8) + be(UInt32(v >> 32)) + be(UInt32(v & 0xFFFF_FFFF))
        case .dutc(let v): out += Array("dutc".utf8) + be(UInt32(v >> 32)) + be(UInt32(v & 0xFFFF_FFFF))
        }
        return out
    }

    static func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    static func plist(_ object: Any) -> Data {
        // swiftlint:disable:next force_try
        try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }
}

final class DSStoreTests: XCTestCase {
    private typealias R = DSStoreWriter.Record

    private let allTypes: [R] = [
        R(name: ".", code: "vstl", value: .type("icnv")),
        R(name: ".", code: "vSrn", value: .long(1)),
        R(name: ".", code: "ICVO", value: .bool(true)),
        R(name: ".", code: "icsp", value: .short(7)),
        R(name: "Éclair ☕️", code: "cmmt", value: .ustr("Grüße")),
        R(name: "a.txt", code: "logS", value: .comp(0x1_0000_0002)),
        R(name: "a.txt", code: "modD", value: .dutc(42)),
        R(name: "b", code: "icvp", value: .blob(DSStoreWriter.plist(["iconSize": 128]))),
    ]

    func testParsesEveryValueType() throws {
        let records = try XCTUnwrap(DSStore.parse(DSStoreWriter.file(allTypes)))
        for r in allTypes { XCTAssertEqual(records[r.name]?[r.code], r.value, "\(r.name) \(r.code)") }
    }

    func testParsesATwoLevelTree() throws {
        let many = (0..<200).map { R(name: String(format: "file-%03d", $0), code: "vSrn", value: .long(UInt32($0))) }
        let records = try XCTUnwrap(DSStore.parse(DSStoreWriter.file(many, fanout: 16)))
        XCTAssertEqual(records.count, 200)
        XCTAssertEqual(records["file-137"]?["vSrn"], .long(137))
    }

    func testRejectsNonDSStoreData() {
        XCTAssertNil(DSStore.parse(Data()))
        XCTAssertNil(DSStore.parse(Data("hello, this is not a ds_store file at all......".utf8)))
        XCTAssertNil(DSStore.parse(Data(count: DSStore.maxFileSize + 1)))
    }

    func testTruncatedFilesNeverCrash() {
        let data = DSStoreWriter.file(allTypes)
        for length in stride(from: 0, to: data.count, by: 97) { _ = DSStore.parse(data.prefix(length)) }
    }

    func testCorruptedBytesNeverCrash() {
        let data = [UInt8](DSStoreWriter.file(allTypes, fanout: 2))
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            var copy = data
            for _ in 0..<4 { copy[Int.random(in: 0..<copy.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = DSStore.parse(Data(copy))
        }
        // Flipping every byte of the meaningful region one at a time.
        let meaningful = data.indices.filter { data[$0] != 0 }
        for i in meaningful {
            var copy = data
            copy[i] ^= 0xFF
            _ = DSStore.parse(Data(copy))
        }
    }

    func testCyclicTreeIsRejected() throws {
        var data = [UInt8](DSStoreWriter.file((0..<10).map { R(name: "f\($0)", code: "vSrn", value: .long(1)) }, fanout: 3))
        // Point the internal node's rightmost child at itself. Internal node = last block; first u32 = rightmost.
        let size = Int(UInt32(data[8]) << 24 | UInt32(data[9]) << 16 | UInt32(data[10]) << 8 | UInt32(data[11]))
        let blockCount = (data.count - 4) / size - 1
        let internalStart = 4 + blockCount * size
        let selfID = DSStoreWriter.be(UInt32(blockCount - 1))
        data.replaceSubrange(internalStart..<(internalStart + 4), with: selfID)
        XCTAssertNil(DSStore.parse(Data(data)))
    }
}

@MainActor
final class FinderFolderViewTests: XCTestCase {
    private typealias R = DSStoreWriter.Record
    private let globals = Settings.defaultColumns

    private func listView(sort: String, ascending: Bool, sizeVisible: Bool = true, kindWidth: Int = 150) -> Data {
        DSStoreWriter.plist([
            "sortColumn": sort,
            "columns": [
                "name": ["visible": true, "width": 300, "ascending": true, "index": 0],
                "dateModified": ["visible": true, "width": 181, "ascending": ascending, "index": 1],
                "size": ["visible": sizeVisible, "width": 97, "ascending": false, "index": 3],
                "kind": ["visible": true, "width": kindWidth, "ascending": true, "index": 2],
                "comments": ["visible": false, "width": 300, "ascending": true, "index": 7],
            ] as [String: Any],
        ])
    }

    func testMapsViewStyleIconSizeSortAndColumns() throws {
        let record: [String: DSValue] = [
            "vstl": .type("icnv"),
            "icvp": .blob(DSStoreWriter.plist(["iconSize": 80, "arrangeBy": "name"])),
            "lsvp": .blob(listView(sort: "dateModified", ascending: false, sizeVisible: false, kindWidth: 222)),
        ]
        let view = FinderFolderView.map(record, globalColumns: globals)
        XCTAssertEqual(view.viewMode, .icons)
        XCTAssertEqual(view.iconSize, .medium)
        XCTAssertEqual(view.sort, .init(field: .dateModified, ascending: false))
        let columns = try XCTUnwrap(view.columns)
        XCTAssertEqual(columns.map(\.id), [.name, .dateModified, .kind, .size, .dateCreated, .fileExtension,
                                            .tags, .dateLastOpened, .permissions, .owner, .path, .comments])
        XCTAssertEqual(columns.first { $0.id == .comments }?.visible, false)
        XCTAssertEqual(columns.first { $0.id == .size }?.visible, false)
        XCTAssertEqual(columns.first { $0.id == .kind }?.width, 222)
        XCTAssertEqual(columns.first { $0.id == .fileExtension }, globals.first { $0.id == .fileExtension })
    }

    func testListStyleAndIconSizeBuckets() {
        XCTAssertEqual(FinderFolderView.map(["vstl": .type("Nlsv")], globalColumns: globals).viewMode, .details)
        XCTAssertEqual(FinderFolderView.map(["vstl": .type("clmv")], globalColumns: globals).viewMode, .columns,
                       "Finder's column view is the Columns view (Phase 2)")
        XCTAssertNil(FinderFolderView.map(["vstl": .type("Flwv")], globalColumns: globals).viewMode)
        for (size, expected) in [(16, IconSize.small), (48, .small), (64, .medium), (96, .medium), (128, .large), (512, .large)] {
            let record: [String: DSValue] = ["icvp": .blob(DSStoreWriter.plist(["iconSize": size]))]
            XCTAssertEqual(FinderFolderView.map(record, globalColumns: globals).iconSize, expected, "\(size)")
        }
    }

    func testUnknownSortColumnAndGarbageBlobsAreIgnored() {
        let record: [String: DSValue] = ["lsvp": .blob(DSStoreWriter.plist(["sortColumn": "version"])), "icvp": .blob(Data("junk".utf8))]
        XCTAssertTrue(FinderFolderView.map(record, globalColumns: globals).isEmpty)
    }

    /// Finder's Tags ("label"), Date Last Opened and Comments columns are Phase 2 columns: sort and visibility map.
    func testMapsPhase2Columns() throws {
        let all = Settings.defaultColumns
        let list = DSStoreWriter.plist([
            "sortColumn": "label",
            "columns": [
                "name": ["visible": true, "width": 300, "index": 0],
                "label": ["visible": true, "width": 140, "ascending": false, "index": 1],
                "dateLastOpened": ["visible": true, "width": 150, "index": 2],
                "comments": ["visible": false, "width": 200, "index": 3],
            ] as [String: Any],
        ])
        let view = FinderFolderView.map(["lsvp": .blob(list)], globalColumns: all)
        XCTAssertEqual(view.sort, .init(field: .tags, ascending: false))
        let columns = try XCTUnwrap(view.columns)
        XCTAssertEqual(columns.first { $0.id == .tags }?.visible, true)
        XCTAssertEqual(columns.first { $0.id == .tags }?.width, 140)
        XCTAssertEqual(columns.first { $0.id == .dateLastOpened }?.visible, true)
        XCTAssertEqual(columns.first { $0.id == .comments }?.visible, false)
        XCTAssertEqual(columns.first { $0.id == .owner }, all.first { $0.id == .owner }, "Finder has no Owner column")
        XCTAssertEqual(Set(columns.map(\.id)), Set(all.map(\.id)))
    }

    func testReadsOwnRecordThenParentRecord() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "macx-dsstore-\(UUID().uuidString)", directoryHint: .isDirectory)
        let child = root.appending(path: "Child", directoryHint: .isDirectory)
        let other = root.appending(path: "Other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DSStoreWriter.file([R(name: ".", code: "vstl", value: .type("icnv"))]).write(to: child.appending(path: ".DS_Store"))
        try DSStoreWriter.file([R(name: "Child", code: "vstl", value: .type("Nlsv")),
                                R(name: "Other", code: "vstl", value: .type("Nlsv"))]).write(to: root.appending(path: ".DS_Store"))
        XCTAssertEqual(FinderFolderView.read(folder: child, globalColumns: globals)?.viewMode, .icons)
        XCTAssertEqual(FinderFolderView.read(folder: other, globalColumns: globals)?.viewMode, .details)
        XCTAssertNil(FinderFolderView.read(folder: root, globalColumns: globals))
        // Reading never creates files.
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appending(path: ".DS_Store").path(percentEncoded: false)))
    }

    /// The session's read: on a read lane, off main (merge with Phase 2's lane rules).
    func testReadsOnALane() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "macx-dsstore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DSStoreWriter.file([R(name: ".", code: "vstl", value: .type("clmv"))]).write(to: root.appending(path: ".DS_Store"))
        let lanes = LanePool()
        let view = await FinderFolderView.read(folder: root, globalColumns: globals, lanes: lanes, volume: .unknown)
        XCTAssertEqual(view?.viewMode, .columns)
        let none = await FinderFolderView.read(folder: root.appending(path: "missing"), globalColumns: globals, lanes: lanes,
                                               volume: .unknown)
        XCTAssertNil(none)
    }
}
