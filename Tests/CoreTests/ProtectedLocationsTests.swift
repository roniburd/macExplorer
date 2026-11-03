import Foundation
import MacxFS
import XCTest
@testable import Core

final class ProtectedLocationsTests: XCTestCase {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    private func vol(_ id: String, _ path: String, boot: Bool = false, inside: Bool = false, removable: Bool = false,
                     ejectable: Bool = false, local: Bool = true) -> VolumeInfo {
        VolumeInfo(id: VolumeID(raw: id), mountPoint: URL(filePath: path, directoryHint: .isDirectory), name: id, format: "APFS",
                   isBoot: boot, isInternal: inside, isRemovable: removable, isEjectable: ejectable, isLocal: local,
                   isReadOnly: false, isBrowsable: true, totalCapacity: nil,
                   capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
    }

    private var boot: VolumeInfo { vol("boot", "/", boot: true, inside: true) }

    private func classify(_ path: String, volume: VolumeInfo? = nil) -> ProtectedLocation? {
        ProtectedLocations.classify(URL(filePath: path), home: home, volume: volume)
    }

    func testHomeRelativeFoldersAndTheirContents() {
        XCTAssertEqual(classify("/Users/someone/Desktop", volume: boot), .desktop)
        XCTAssertEqual(classify("/Users/someone/Desktop/", volume: boot), .desktop)
        XCTAssertEqual(classify("/Users/someone/Desktop/a/b.txt", volume: boot), .desktop)
        XCTAssertEqual(classify("/Users/someone/Documents", volume: boot), .documents)
        XCTAssertEqual(classify("/Users/someone/Downloads/x", volume: boot), .downloads)
        XCTAssertEqual(classify("/Users/someone/desktop", volume: boot), .desktop, "case-insensitive file system")
        XCTAssertEqual(classify("/Users/someone/Pictures/../Desktop", volume: boot), .desktop, "standardized first")
    }

    func testUnprotectedPaths() {
        XCTAssertNil(classify("/Users/someone", volume: boot))
        XCTAssertNil(classify("/Users/someone/Music", volume: boot))
        XCTAssertNil(classify("/Users/someone/DesktopX", volume: boot), "prefix must end at a component")
        XCTAssertNil(classify("/Users/someone/Projects/Desktop", volume: boot), "only directly under home")
        XCTAssertNil(classify("/Users/other/Desktop", volume: boot))
        XCTAssertNil(classify("/Applications", volume: boot))
        XCTAssertNil(classify("/tmp", volume: nil))
    }

    func testICloudDrive() {
        XCTAssertEqual(classify("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs", volume: boot), .iCloudDrive)
        XCTAssertEqual(classify("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/a", volume: boot), .iCloudDrive)
        XCTAssertEqual(classify("/Users/someone/Library/Mobile Documents", volume: boot), .iCloudDrive)
        XCTAssertNil(classify("/Users/someone/Library", volume: boot))
    }

    func testVolumes() {
        let usb = vol("uuid:USB", "/Volumes/USB", removable: true, ejectable: true)
        XCTAssertEqual(classify("/Volumes/USB/a", volume: usb), .removableVolume(VolumeID(raw: "uuid:USB")))
        let image = vol("uuid:IMG", "/Volumes/Image", ejectable: true)
        XCTAssertEqual(classify("/Volumes/Image", volume: image), .removableVolume(VolumeID(raw: "uuid:IMG")), "disk images count as removable")
        let external = vol("uuid:EXT", "/Volumes/Ext")
        XCTAssertEqual(classify("/Volumes/Ext", volume: external), .removableVolume(VolumeID(raw: "uuid:EXT")), "external, non-ejectable")
        let smb = vol("mnt:/Volumes/Share", "/Volumes/Share", ejectable: true, local: false)
        XCTAssertEqual(classify("/Volumes/Share/x", volume: smb), .networkVolume(VolumeID(raw: "mnt:/Volumes/Share")))
        let data = vol("uuid:DATA", "/System/Volumes/Data", inside: true)
        XCTAssertNil(classify("/System/Volumes/Data/Users/someone/Music", volume: data), "internal volumes are not protected")
        let secondInternal = vol("uuid:IN2", "/Volumes/Work", inside: true)
        XCTAssertNil(classify("/Volumes/Work/x", volume: secondInternal))
    }

    func testHomeFolderWinsOverVolumeKind() {
        let externalHome = URL(filePath: "/Volumes/Ext/me", directoryHint: .isDirectory)
        let external = vol("uuid:EXT", "/Volumes/Ext", removable: true, ejectable: true)
        XCTAssertEqual(ProtectedLocations.classify(URL(filePath: "/Volumes/Ext/me/Documents"), home: externalHome, volume: external), .documents)
        XCTAssertEqual(ProtectedLocations.classify(URL(filePath: "/Volumes/Ext/me/Music"), home: externalHome, volume: external),
                       .removableVolume(VolumeID(raw: "uuid:EXT")))
    }

    func testPrivateVarSpellingsAreEquivalent() {
        let sandboxHome = URL(filePath: "/private/var/folders/xy/T/macx-tests-1", directoryHint: .isDirectory)
        XCTAssertEqual(ProtectedLocations.classify(URL(filePath: "/var/folders/xy/T/macx-tests-1/Desktop"), home: sandboxHome, volume: nil), .desktop)
        let varHome = URL(filePath: "/var/folders/xy/T/macx-tests-1", directoryHint: .isDirectory)
        XCTAssertEqual(ProtectedLocations.classify(URL(filePath: "/private/var/folders/xy/T/macx-tests-1/Downloads/z"), home: varHome, volume: nil), .downloads)
        XCTAssertEqual(ProtectedLocations.classify(URL(filePath: "/tmp/h/Documents"),
                                                   home: URL(filePath: "/private/tmp/h", directoryHint: .isDirectory), volume: nil), .documents)
    }
}
