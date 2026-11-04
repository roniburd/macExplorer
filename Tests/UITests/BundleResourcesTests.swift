import XCTest

/// Checks the committed app-bundle inputs under `Resources/` and `scripts/` (P1-01). Read-only.
final class BundleResourcesTests: XCTestCase {
    private static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo.appending(path: relativePath))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testInfoPlistIdentityAndPlatform() throws {
        let info = try plist("Resources/Info.plist")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.macexplorer.app")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "macExplorer")
        XCTAssertEqual(info["CFBundleName"] as? String, "MacExplorer", "published name; the executable stays macExplorer")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "MacExplorer")
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "26.0")
        XCTAssertEqual(info["NSPrincipalClass"] as? String, "MacxApplication", "P1-41: ScenarioDriver pins the key window through it")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertEqual(info["NSHighResolutionCapable"] as? Bool, true)
        XCTAssertNotNil(info["CFBundleShortVersionString"] as? String)
        XCTAssertNotNil(info["CFBundleVersion"] as? String)
    }

    func testInfoPlistHasPrivacyUsageDescriptions() throws {
        let info = try plist("Resources/Info.plist")
        for key in ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription",
                    "NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription"] {
            let text = try XCTUnwrap(info[key] as? String, key)
            XCTAssertFalse(text.isEmpty, key)
        }
    }

    func testEntitlementsAreAnEmptyDictionary() throws {
        XCTAssertTrue(try plist("Resources/macExplorer.entitlements").isEmpty, "Phase 1: hardened runtime, no sandbox, no entitlements")
    }

    func testAppIconIsAnICNSFile() throws {
        let data = try Data(contentsOf: Self.repo.appending(path: "Resources/AppIcon.icns"))
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "icns")
        let declared = data.dropFirst(4).prefix(4).reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(declared, data.count, "header length matches file size")
        XCTAssertGreaterThan(data.count, 1024)
    }

    func testScriptsAreExecutable() {
        for script in ["scripts/bundle.sh", "scripts/make-icon.sh"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Self.repo.appending(path: script).path(percentEncoded: false)), script)
        }
    }
}
