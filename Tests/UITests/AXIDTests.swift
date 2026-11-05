import XCTest
@testable import UI
import Core

final class AXIDTests: XCTestCase {
    func testIdentifiersMatchTheContract() {
        XCTAssertEqual(AXID.window, "macx.window")
        XCTAssertEqual(AXID.addressBar, "macx.addressBar")
        XCTAssertEqual(AXID.addressField, "macx.addressField")
        XCTAssertEqual(AXID.breadcrumbSegment(3), "macx.breadcrumb.3")
        XCTAssertEqual(AXID.search, "macx.search")
        XCTAssertEqual(AXID.detailsTable, "macx.details")
        XCTAssertEqual(AXID.iconsGrid, "macx.icons")
        XCTAssertEqual(AXID.sidebar, "macx.sidebar")
        XCTAssertEqual(AXID.commandBarItem(.moveToTrash), "macx.commandBar.moveToTrash")
        XCTAssertEqual(AXID.statusCount, "macx.status.count")
        XCTAssertEqual(AXID.statusSelection, "macx.status.selection")
        XCTAssertEqual(AXID.statusFree, "macx.status.free")
        XCTAssertEqual(AXID.emptyState, "macx.emptyState")
        XCTAssertEqual(AXID.banner, "macx.banner")
        XCTAssertEqual(AXID.renameField, "macx.renameField")
        XCTAssertEqual(AXID.operationsCapsule, "macx.operations")
        XCTAssertEqual(AXID.conflictButton(.keepBoth), "macx.conflict.keepBoth")
        XCTAssertEqual(AXID.propertiesWindow, "macx.properties")
        XCTAssertEqual(AXID.settingsWindow, "macx.settings")
        XCTAssertEqual(AXID.onboardingSheet, "macx.onboarding")
        XCTAssertEqual(AXID.updateBadge, "macx.updateBadge")
        XCTAssertEqual(AXID.feedbackMenu, "macx.feedback")
        XCTAssertEqual(AXID.updateChannel, "macx.settings.updateChannel")
        XCTAssertEqual(AXID.automaticUpdateChecks, "macx.settings.automaticUpdateChecks")
        XCTAssertEqual(AXID.checkForUpdatesNow, "macx.settings.checkForUpdatesNow")
        XCTAssertEqual(AXID.offerCrashReports, "macx.settings.offerCrashReports")
    }
}
