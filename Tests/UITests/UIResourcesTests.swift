import XCTest
@testable import UI

final class UIResourcesTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "macx-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
        addTeardownBlock { [tmp] in if let tmp { try? FileManager.default.removeItem(at: tmp) } }
    }

    func testBundleNameMatchesSwiftPMResourceBundle() {
        XCTAssertEqual(UIResources.bundleName, "macExplorer_UI.bundle")
    }

    func testBundleIsTheUIResourceBundleNotMain() {
        let bundle = UIResources.bundle
        XCTAssertEqual(bundle.bundleURL.lastPathComponent, UIResources.bundleName)
        XCTAssertNotEqual(bundle.bundleURL, Bundle.main.bundleURL)
    }

    func testCompiledStringCatalogIsInTheBundle() {
        let bundle = UIResources.bundle
        XCTAssertNotNil(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"),
                        "xcstrings compiled to en.lproj/Localizable.strings")
    }

    func testL10nReturnsCatalogValueForKnownKey() {
        // A key present in the catalog is found (sentinel default value proves the table lookup hit).
        let sentinel = "\u{1}missing"
        XCTAssertEqual(UIResources.bundle.localizedString(forKey: "Quit MacExplorer", value: sentinel, table: nil), "Quit MacExplorer")
        XCTAssertEqual(L10n.string("Quit MacExplorer"), "Quit MacExplorer")
    }

    func testL10nFallsBackToKeyForUnknownKey() {
        XCTAssertEqual(L10n.string("No such key \(UUID().uuidString)").hasPrefix("No such key "), true)
    }

    func testL10nFormatKeysWorkWithStringFormat() {
        XCTAssertEqual(String(format: L10n.string("%@ \u{2014} unknown format key"), "A"), "A \u{2014} unknown format key")
    }

    func testLocatePrefersEarlierCandidate() throws {
        let first = tmp.appending(path: "first", directoryHint: .isDirectory)
        let second = tmp.appending(path: "second", directoryHint: .isDirectory)
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir.appending(path: UIResources.bundleName, directoryHint: .isDirectory),
                                                    withIntermediateDirectories: true)
        }
        let found = try XCTUnwrap(UIResources.locate(in: [first, second]))
        XCTAssertEqual(found.bundleURL.standardizedFileURL.deletingLastPathComponent().lastPathComponent, "first")
    }

    func testLocateSkipsMissingCandidates() throws {
        let missing = tmp.appending(path: "missing", directoryHint: .isDirectory)
        let present = tmp.appending(path: "present", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: present.appending(path: UIResources.bundleName, directoryHint: .isDirectory),
                                                withIntermediateDirectories: true)
        let found = try XCTUnwrap(UIResources.locate(in: [missing, present]))
        XCTAssertEqual(found.bundleURL.standardizedFileURL.deletingLastPathComponent().lastPathComponent, "present")
        XCTAssertNil(UIResources.locate(in: [missing]))
        XCTAssertNil(UIResources.locate(in: []))
    }

    func testCandidatesStartWithContentsResourcesThenExecutableDirectory() {
        let app = URL(filePath: "/Applications/macExplorer.app", directoryHint: .isDirectory)
        let candidates = UIResources.candidateDirectories(
            resourceURL: app.appending(path: "Contents/Resources", directoryHint: .isDirectory),
            executableURL: app.appending(path: "Contents/MacOS/macExplorer"),
            codeBundleURL: nil)
        XCTAssertEqual(candidates.map { $0.path(percentEncoded: false) },
                       ["/Applications/macExplorer.app/Contents/Resources/", "/Applications/macExplorer.app/Contents/MacOS/"])
    }

    func testCandidatesIncludeCodeBundleParentForTests() {
        let candidates = UIResources.candidateDirectories(
            resourceURL: nil, executableURL: nil,
            codeBundleURL: URL(filePath: "/x/Products/Debug/macExplorerPackageTests.xctest", directoryHint: .isDirectory))
        XCTAssertEqual(candidates.map { $0.path(percentEncoded: false) }, ["/x/Products/Debug/"])
    }
}
