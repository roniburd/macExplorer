import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

/// Test harnesses build CoreEnvironment directly; they must get fake search services (no Spotlight over real files,
/// no mdutil, no real iCloud downloads). CoreEnvironment's init has no default for `searchServices`, so this also
/// guards that the shared harness keeps choosing the fakes.
@MainActor
final class HarnessSearchServicesTests: XCTestCase {
    func testSidebarHarnessUsesFakeSearchServices() async throws {
        let h = try await SidebarHarness.make(self)
        let services = h.environment.searchServices
        XCTAssertTrue(services.metadataQuery is FakeMetadataQuery, "\(type(of: services.metadataQuery))")
        XCTAssertTrue(services.downloader is FakeUbiquitousDownloader, "\(type(of: services.downloader))")
        XCTAssertFalse(services.indexStatus is MdutilIndexStatus)
    }

    func testSandboxedEnvironmentUsesFakeSearchServices() throws {
        let sandbox = try Sandbox(prefix: "macx-tests")
        defer { sandbox.destroy() }
        let services = CoreEnvironment.sandboxed(root: sandbox.root).searchServices
        XCTAssertTrue(services.metadataQuery is FakeMetadataQuery)
        XCTAssertTrue(services.downloader is FakeUbiquitousDownloader)
    }
}
