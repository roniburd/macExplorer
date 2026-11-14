@testable import Core
import Foundation
import MacxPluginKit
import XCTest

@MainActor
final class RemoteSettingsTests: XCTestCase {
    func testLastLocationRoundTripsRemoteURL() {
        let storage = InMemorySettingsStorage()
        let url = RemoteLocation(provider: "test.fake", repo: "o/r", ref: "feature/x", path: ["a b"]).url
        Settings(storage: storage).lastLocation = url
        XCTAssertEqual(Settings(storage: storage).lastLocation, url)
    }
}
