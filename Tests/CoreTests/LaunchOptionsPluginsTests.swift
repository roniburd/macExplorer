import XCTest
@testable import Core

final class LaunchOptionsPluginsTests: XCTestCase {
    func testPluginsDirRequiresAStateDir() {
        XCTAssertThrowsError(try LaunchOptions.parse(["app", "--plugins-dir", "/tmp/macx-p"]))
        let o = try? LaunchOptions.parse(["app", "--plugins-dir", "/tmp/macx-p", "--state-dir", "/tmp/macx-s"])
        XCTAssertEqual(o?.pluginsDirectory?.lastPathComponent, "macx-p")   // a directory URL: its path ends in "/"
    }
}
