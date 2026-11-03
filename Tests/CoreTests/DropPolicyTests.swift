import Foundation
import MacxFS
import XCTest
@testable import Core

private func vol(_ id: String, _ path: String) -> VolumeInfo {
    VolumeInfo(id: VolumeID(raw: id), mountPoint: URL(filePath: path, directoryHint: .isDirectory), name: id, format: "APFS",
               isBoot: path == "/", isInternal: true, isRemovable: false, isEjectable: false, isLocal: true, isReadOnly: false,
               isBrowsable: true, totalCapacity: nil,
               capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
}

final class DropPolicyTests: XCTestCase {
    private let table = MountTable([vol("boot", "/"), vol("ext", "/Volumes/Ext"),
                                    vol("img", "/private/var/folders/x/macx-tests-1/mnt-1")])

    private func op(_ sources: [String], _ destination: String, _ modifiers: DragModifiers = [],
                    secondary: Bool = false, table: MountTable? = nil) -> DragOperation {
        DropPolicy.operation(sources: sources, destination: destination, modifiers: modifiers,
                             isSecondaryDrag: secondary, mountTable: table ?? self.table)
    }

    func testSecondaryDragTypeName() {
        XCTAssertEqual(DropPolicy.secondaryDragType, "com.macexplorer.secondary-drag")
    }

    func testModifierRawValues() {
        XCTAssertEqual(DragModifiers.option.rawValue, 1)
        XCTAssertEqual(DragModifiers.command.rawValue, 2)
        XCTAssertEqual(DragModifiers.control.rawValue, 4)
    }

    func testDefaultMovesOnSameVolume() {
        XCTAssertEqual(op(["/Users/me/a.txt", "/Users/me/b"], "/Users/me/dst"), .move)
        XCTAssertEqual(op(["/Volumes/Ext/a"], "/Volumes/Ext/b/c"), .move)
    }

    func testDefaultCopiesAcrossVolumes() {
        XCTAssertEqual(op(["/Users/me/a.txt"], "/Volumes/Ext/dst"), .copy)
        XCTAssertEqual(op(["/Volumes/Ext/a"], "/Users/me"), .copy)
        XCTAssertEqual(op(["/Users/me/a.txt", "/Volumes/Ext/b"], "/Users/me/dst"), .copy, "any cross-volume source copies")
    }

    func testMountPrefixIsComponentWise() {
        XCTAssertEqual(op(["/Volumes/ExtOther/a"], "/Users/me"), .move, "/Volumes/ExtOther is on the boot volume")
        XCTAssertEqual(op(["/Volumes/ExtOther/a"], "/Volumes/Ext/dst"), .copy)
    }

    func testPrivateVarSpellingsShareTheImageVolume() {
        XCTAssertEqual(op(["/var/folders/x/macx-tests-1/mnt-1/a"], "/private/var/folders/x/macx-tests-1/mnt-1/b"), .move)
        XCTAssertEqual(op(["/var/folders/x/macx-tests-1/a"], "/var/folders/x/macx-tests-1/mnt-1"), .copy)
    }

    func testUnknownVolumeCopies() {
        XCTAssertEqual(op(["/a"], "/b", table: .empty), .copy, "no mount table entry: never move by default")
    }

    func testModifiers() {
        XCTAssertEqual(op(["/Users/me/a"], "/Users/me/dst", .option), .copy)
        XCTAssertEqual(op(["/Users/me/a"], "/Volumes/Ext", .command), .move)
        XCTAssertEqual(op(["/Users/me/a"], "/Users/me/dst", [.option, .command]), .alias)
        XCTAssertEqual(op(["/Users/me/a"], "/Volumes/Ext", [.option, .command]), .alias)
    }

    func testControlOrSecondaryDragIsMenu() {
        XCTAssertEqual(op(["/Users/me/a"], "/Users/me/dst", .control), .menu)
        XCTAssertEqual(op(["/Users/me/a"], "/Users/me/dst", [.control, .option, .command]), .menu)
        XCTAssertEqual(op(["/Users/me/a"], "/Volumes/Ext", secondary: true), .menu)
        XCTAssertEqual(op(["/Users/me/a"], "/Volumes/Ext", .option, secondary: true), .menu)
    }

    func testSelfOrDescendantRefused() {
        XCTAssertEqual(op(["/Users/me/dir"], "/Users/me/dir"), .none)
        XCTAssertEqual(op(["/Users/me/dir"], "/Users/me/dir/sub/deeper"), .none)
        XCTAssertEqual(op(["/Users/me/a.txt", "/Users/me/dir"], "/Users/me/dir/sub"), .none, "any offending source refuses")
        XCTAssertEqual(op(["/Users/me/dir"], "/Users/me/dir/sub", .control), .none, "refused even for a menu drop")
        XCTAssertEqual(op(["/Users/me/dir"], "/Users/me/dir/", [.option]), .none)
    }

    func testEmptySourcesRefused() {
        XCTAssertEqual(op([], "/Users/me"), .none)
    }

    func testIntoParentIsAllowed() {
        XCTAssertEqual(op(["/Users/me/dir/a"], "/Users/me"), .move)
    }

    func testIsSelfOrDescendant() {
        XCTAssertTrue(DropPolicy.isSelfOrDescendant(source: "/a/b", destination: "/a/b"))
        XCTAssertTrue(DropPolicy.isSelfOrDescendant(source: "/a/b", destination: "/a/b/c"))
        XCTAssertTrue(DropPolicy.isSelfOrDescendant(source: "/a/b/", destination: "/a/b/c/"))
        XCTAssertTrue(DropPolicy.isSelfOrDescendant(source: "/a/./b", destination: "/a/x/../b/c"))
        XCTAssertTrue(DropPolicy.isSelfOrDescendant(source: "/private/var/f", destination: "/var/f/g"))
        XCTAssertTrue(DropPolicy.isSelfOrDescendant(source: "/", destination: "/anything"))
        XCTAssertFalse(DropPolicy.isSelfOrDescendant(source: "/a/b", destination: "/a/bc"))
        XCTAssertFalse(DropPolicy.isSelfOrDescendant(source: "/a/b", destination: "/a"))
        XCTAssertFalse(DropPolicy.isSelfOrDescendant(source: "/a/b/c", destination: "/a/b"))
    }

    func testUnicodeNamesComparedByBytes() {
        // NFC vs NFD spellings are distinct names on disk; the lexical check does not fold them.
        XCTAssertFalse(DropPolicy.isSelfOrDescendant(source: "/w/Caf\u{E9}", destination: "/w/Cafe\u{301}/x"))
        XCTAssertTrue(DropPolicy.isSelfOrDescendant(source: "/w/Cafe\u{301}", destination: "/w/Cafe\u{301}/x"))
    }
}
