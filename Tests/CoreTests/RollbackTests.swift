import CryptoKit
import XCTest
@testable import Core

/// Install Previous Version… pure logic: appcast parsing, catalog filtering, EdDSA, skip-until-newer.
final class AppcastParserTests: XCTestCase {
    /// The shape scripts/release/appcast.py writes (copied from the live feed, 2026-11-08, trimmed).
    static let fixture = Data("""
    <?xml version='1.0' encoding='utf-8'?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
      <channel>
        <title>MacExplorer</title>
        <link>https://example.invalid/appcast.xml</link>
        <item>
          <title>MacExplorer 0.2.0-beta.15</title>
          <pubDate>Sun, 08 Nov 2026 07:32:05 GMT</pubDate>
          <sparkle:version>214</sparkle:version>
          <sparkle:shortVersionString>0.2.0-beta.15</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
          <sparkle:releaseNotesLink>https://example.invalid/v0.2.0-beta.15</sparkle:releaseNotesLink>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.invalid/MacExplorer-0.2.0-beta.15.zip" length="9729909" type="application/octet-stream" sparkle:edSignature="c2lnMTU=" />
        </item>
        <item>
          <title>MacExplorer 0.2.0</title>
          <pubDate>Sat, 07 Nov 2026 20:35:24 GMT</pubDate>
          <sparkle:version>204</sparkle:version>
          <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
          <enclosure url="https://example.invalid/MacExplorer-0.2.0.zip" length="10" type="application/octet-stream" sparkle:edSignature="c2lnMjA0" />
        </item>
        <item>
          <title>No signature</title>
          <sparkle:version>203</sparkle:version>
          <enclosure url="https://example.invalid/x.zip" length="10" type="application/octet-stream" />
        </item>
        <item>
          <title>No build</title>
          <sparkle:version>abc</sparkle:version>
          <enclosure url="https://example.invalid/y.zip" length="10" type="application/octet-stream" sparkle:edSignature="eA==" />
        </item>
      </channel>
    </rss>
    """.utf8)

    func testParsesItemsAndDropsUninstallableOnes() throws {
        let items = try AppcastParser.parse(Self.fixture)
        XCTAssertEqual(items.map(\.build), [214, 204])
        let beta = items[0]
        XCTAssertEqual(beta.version, "0.2.0-beta.15")
        XCTAssertEqual(beta.channel, "beta")
        XCTAssertEqual(beta.minimumSystemVersion, "26.0")
        XCTAssertEqual(beta.length, 9_729_909)
        XCTAssertEqual(beta.edSignature, "c2lnMTU=")
        XCTAssertEqual(beta.enclosureURL.absoluteString, "https://example.invalid/MacExplorer-0.2.0-beta.15.zip")
        XCTAssertEqual(beta.notesURL?.absoluteString, "https://example.invalid/v0.2.0-beta.15")
        XCTAssertEqual(beta.pubDate, Date(timeIntervalSince1970: 1_794_123_125))
        XCTAssertNil(items[1].channel)
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try AppcastParser.parse(Data("<rss><channel><item>".utf8)))
    }
}

final class RollbackCatalogTests: XCTestCase {
    private func item(_ build: Int, channel: String? = nil, minOS: String? = "26.0") -> AppcastItem {
        AppcastItem(version: "v\(build)", build: build, channel: channel,
                    enclosureURL: URL(string: "https://example.invalid/\(build).zip")!, edSignature: "s",
                    minimumSystemVersion: minOS)
    }
    private let os26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)

    func testBetaChannelSeesOlderSignedBuildsNewestFirst() {
        let items = [item(181, channel: "beta"), item(214, channel: "beta"), item(204, channel: "beta"), item(211),
                     item(220, channel: "beta"), item(182, channel: "beta"), item(204)]
        let result = RollbackCatalog.candidates(items, channel: .beta, installedBuild: 214, osVersion: os26)
        XCTAssertEqual(result.map(\.build), [211, 204, 182])   // 214 installed, 220 newer, 181 pre-cert, 204 once
    }

    func testReleaseChannelHidesBetaItems() {
        let items = [item(211, channel: "beta"), item(204)]
        XCTAssertEqual(RollbackCatalog.candidates(items, channel: .release, installedBuild: 214, osVersion: os26).map(\.build), [204])
    }

    func testMinimumOSIsRespected() {
        let items = [item(200, minOS: "27.0"), item(199, minOS: "26.1"), item(198, minOS: nil)]
        XCTAssertEqual(RollbackCatalog.candidates(items, channel: .release, installedBuild: 214, osVersion: os26).map(\.build), [199, 198])
    }
}

final class RollbackSignatureTests: XCTestCase {
    func testAcceptsSparkleStyleSignatureAndRejectsTampering() {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("MacExplorer archive bytes".utf8)
        let signature = try! key.signature(for: data).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(RollbackSignature.isValid(data: data, signature: signature, publicKey: publicKey))
        var tampered = data
        tampered[0] ^= 1
        XCTAssertFalse(RollbackSignature.isValid(data: tampered, signature: signature, publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(RollbackSignature.isValid(data: data, signature: signature, publicKey: other))
        XCTAssertFalse(RollbackSignature.isValid(data: data, signature: "not base64!", publicKey: publicKey))
        XCTAssertFalse(RollbackSignature.isValid(data: data, signature: signature, publicKey: "AAAA"))
    }
}

final class RollbackSkipTests: XCTestCase {
    func testReconcileAfterSuccessfulSwapSkipsThroughTheOldBuild() {
        let pending = PendingRollback(targetBuild: 204, fromBuild: 214, backupPath: "/tmp/x/Replaced-214.app")
        XCTAssertEqual(RollbackSkip.reconcile(pending, installedBuild: 204),
                       .init(skipThrough: 214, trashBackup: "/tmp/x/Replaced-214.app"))
    }

    func testReconcileAfterFailedSwapAddsNoSkip() {
        let pending = PendingRollback(targetBuild: 204, fromBuild: 214, backupPath: "/tmp/x/Replaced-214.app")
        XCTAssertEqual(RollbackSkip.reconcile(pending, installedBuild: 214), .init(skipThrough: nil, trashBackup: nil))
        XCTAssertEqual(RollbackSkip.reconcile(pending, installedBuild: nil), .init(skipThrough: nil, trashBackup: nil))
    }

    func testShouldSkip() {
        XCTAssertTrue(RollbackSkip.shouldSkip(build: 214, skipThrough: 214))
        XCTAssertTrue(RollbackSkip.shouldSkip(build: 210, skipThrough: 214))
        XCTAssertFalse(RollbackSkip.shouldSkip(build: 215, skipThrough: 214))
        XCTAssertFalse(RollbackSkip.shouldSkip(build: 214, skipThrough: nil))
        XCTAssertFalse(RollbackSkip.shouldSkip(build: nil, skipThrough: 214))
    }

    @MainActor func testSettingsRoundTrip() {
        let storage = InMemorySettingsStorage()
        let home = URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory)
        let a = Settings(storage: storage, home: home)
        XCTAssertNil(a.updateSkipThroughBuild)
        XCTAssertNil(a.pendingRollback)
        a.updateSkipThroughBuild = 214
        a.pendingRollback = PendingRollback(targetBuild: 204, fromBuild: 214, backupPath: "/tmp/b.app")
        let b = Settings(storage: storage, home: home)
        XCTAssertEqual(b.updateSkipThroughBuild, 214)
        XCTAssertEqual(b.pendingRollback, PendingRollback(targetBuild: 204, fromBuild: 214, backupPath: "/tmp/b.app"))
        b.pendingRollback = nil
        XCTAssertNil(Settings(storage: storage, home: home).pendingRollback)
    }
}
