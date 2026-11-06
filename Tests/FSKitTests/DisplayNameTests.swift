import MacxFS
import XCTest

final class DisplayNameTests: XCTestCase {
    private func make(_ name: String, _ kind: Kind = .file, _ flags: EntryFlags = [], stem: String? = nil, all: Bool = false) -> String {
        DisplayName.make(name: name, kind: kind, flags: flags, localizedStem: stem, showAllExtensions: all)
    }

    func testPlainNamesAreUnchanged() {
        XCTAssertEqual(make("report.pdf"), "report.pdf")
        XCTAssertEqual(make("Folder", .directory), "Folder")
    }

    func testFinderHiddenExtensionFlag() {
        XCTAssertEqual(make("report.pdf", .file, .extensionHidden), "report")
        XCTAssertEqual(make("Archive.tar.gz", .file, .extensionHidden), "Archive.tar")
        XCTAssertEqual(make("Photos.photoslibrary", .package, .extensionHidden), "Photos")
    }

    func testAppBundlesAlwaysHideTheirExtension() {
        XCTAssertEqual(make("Safari.app", .package), "Safari")
        XCTAssertEqual(make("Old.APP", .package), "Old")
        XCTAssertEqual(make("Not a bundle.app", .directory), "Not a bundle.app")
        XCTAssertEqual(make("script.app", .file), "script.app")
    }

    func testNamesWithoutAnExtensionAreNeverTrimmed() {
        XCTAssertEqual(make(".zshrc", .file, .extensionHidden), ".zshrc")
        XCTAssertEqual(make("name.", .file, .extensionHidden), "name.")
        XCTAssertEqual(make("README", .file, .extensionHidden), "README")
        XCTAssertEqual(make(".app", .package), ".app")
    }

    func testShowAllExtensionsWins() {
        XCTAssertEqual(make("Safari.app", .package, [], all: true), "Safari.app")
        XCTAssertEqual(make("report.pdf", .file, .extensionHidden, all: true), "report.pdf")
    }

    func testLocalizedStem() {
        XCTAssertEqual(make("System Settings.app", .package, stem: "Ajustes del Sistema"), "Ajustes del Sistema")
        XCTAssertEqual(make("System Settings.app", .package, stem: "Ajustes del Sistema", all: true), "Ajustes del Sistema.app")
        XCTAssertEqual(make("Applications", .directory, stem: "Aplicaciones"), "Aplicaciones")
        XCTAssertEqual(make("Applications", .directory, stem: ""), "Applications")
    }

    /// "*.localized" folders show their localized stem without the ".localized" suffix, as in Finder.
    func testLocalizedFoldersHideTheirSuffix() {
        XCTAssertEqual(make("Projects.localized", .directory, stem: "Projects"), "Projects")
        XCTAssertEqual(make("Projects.localized", .directory, stem: "Proyectos", all: true), "Proyectos")
        XCTAssertEqual(make("Projects.localized", .directory), "Projects.localized", "no stem yet: the real name")
    }
}
