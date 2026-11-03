import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class BreadcrumbTests: XCTestCase {
    private func volume(_ mount: String, _ name: String) -> VolumeInfo {
        VolumeInfo(id: VolumeID(raw: "mnt:" + mount), mountPoint: URL(filePath: mount, directoryHint: .isDirectory),
                   name: name, format: "APFS", isBoot: mount == "/", isInternal: true, isRemovable: false,
                   isEjectable: false, isLocal: true, isReadOnly: false, isBrowsable: true, totalCapacity: nil,
                   capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
    }

    private func dir(_ path: String) -> URL { URL(filePath: path, directoryHint: .isDirectory) }

    // MARK: pure segment math (strings only, never reach the file system)

    func testSegmentsRunFromTheVolumeToTheFolder() {
        let segments = BreadcrumbPath.segments(for: dir("/Volumes/Data/a/b"), volume: volume("/Volumes/Data", "Data"))
        XCTAssertEqual(segments.map(\.title), ["Data", "a", "b"])
        XCTAssertEqual(segments.map { $0.url.path(percentEncoded: false) }, ["/Volumes/Data/", "/Volumes/Data/a/", "/Volumes/Data/a/b/"])
        XCTAssertEqual(segments.map(\.isVolumeRoot), [true, false, false])
    }

    func testBootVolumeRootIsOneSegment() {
        let segments = BreadcrumbPath.segments(for: dir("/"), volume: volume("/", "Macintosh HD"))
        XCTAssertEqual(segments.map(\.title), ["Macintosh HD"])
        XCTAssertEqual(segments.first?.url.path(percentEncoded: false), "/")
    }

    func testUnknownVolumeOrForeignMountFallsBackToSlash() {
        XCTAssertEqual(BreadcrumbPath.segments(for: dir("/Library/x"), volume: nil).map(\.title), ["/", "Library", "x"])
        let foreign = BreadcrumbPath.segments(for: dir("/Library/x"), volume: volume("/Volumes/Other", "Other"))
        XCTAssertEqual(foreign.map(\.title), ["/", "Library", "x"])
    }

    func testSegmentIndexMatchesCrumbIndexSemantics() {
        // Scenario "crumb:<index>" (P1-36): 0 is the volume root, then one segment per component below it.
        let segments = BreadcrumbPath.segments(for: dir("/Users/me/dev"), volume: volume("/", "Macintosh HD"))
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[2].url.path(percentEncoded: false), "/Users/me/")
    }

    func testVolumeSegmentSymbolFollowsTheVolumeKind() {
        XCTAssertEqual(BreadcrumbPath.segments(for: dir("/a"), volume: volume("/", "Macintosh HD")).first?.symbolName, "internaldrive")
        var external = volume("/Volumes/Stick", "Stick")
        external.isEjectable = true
        XCTAssertEqual(BreadcrumbPath.segments(for: dir("/Volumes/Stick/a"), volume: external).first?.symbolName, "externaldrive")
        var share = volume("/Volumes/share", "share")
        share.isLocal = false
        XCTAssertEqual(BreadcrumbPath.segments(for: dir("/Volumes/share"), volume: share).first?.symbolName, "network")
        XCTAssertNil(BreadcrumbPath.segments(for: dir("/Volumes/share/x"), volume: share).last?.symbolName)
    }

    func testPosixPathHasNoTrailingSlash() {
        XCTAssertEqual(BreadcrumbPath.posixPath(dir("/Library/x")), "/Library/x")
        XCTAssertEqual(BreadcrumbPath.posixPath(dir("/")), "/")
    }

    func testCollapsedCount() {
        // Each segment costs its width plus the chevron (10).
        let widths: [CGFloat] = [100, 50, 50, 50]
        XCTAssertEqual(BreadcrumbPath.collapsedCount(segmentWidths: widths, chevronWidth: 10, overflowWidth: 20, available: 1000), 0)
        XCTAssertEqual(BreadcrumbPath.collapsedCount(segmentWidths: widths, chevronWidth: 10, overflowWidth: 20, available: 290), 0)
        XCTAssertEqual(BreadcrumbPath.collapsedCount(segmentWidths: widths, chevronWidth: 10, overflowWidth: 20, available: 289), 1)
        XCTAssertEqual(BreadcrumbPath.collapsedCount(segmentWidths: widths, chevronWidth: 10, overflowWidth: 20, available: 140), 2)
        XCTAssertEqual(BreadcrumbPath.collapsedCount(segmentWidths: widths, chevronWidth: 10, overflowWidth: 20, available: 5), 3,
                       "the current folder always stays visible")
        XCTAssertEqual(BreadcrumbPath.collapsedCount(segmentWidths: [], chevronWidth: 10, overflowWidth: 20, available: 5), 0)
    }

    // MARK: view

    private func makeView(width: CGFloat) -> BreadcrumbView {
        let view = BreadcrumbView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        view.show(BreadcrumbPath.segments(for: dir("/Volumes/Data/alpha/beta/gamma"), volume: volume("/Volumes/Data", "Data")))
        view.layoutSubtreeIfNeeded()
        view.layout()
        return view
    }

    func testSegmentButtonsHaveIdentifiersAndNavigate() {
        let view = makeView(width: 2000)
        XCTAssertEqual(view.collapsedCount, 0)
        XCTAssertEqual(view.segmentButtons.map { $0.accessibilityIdentifier() }, (0..<4).map(AXID.breadcrumbSegment))
        XCTAssertEqual(view.segmentButtons.map(\.title), ["Data", "alpha", "beta", "gamma"])
        XCTAssertTrue(view.segmentButtons.allSatisfy { !$0.isHidden })
        XCTAssertTrue(view.overflowButton.isHidden)
        var navigated: URL?
        view.onNavigate = { navigated = $0 }
        view.segmentButtons[1].performClick(nil)
        XCTAssertEqual(navigated?.path(percentEncoded: false), "/Volumes/Data/alpha/")
        XCTAssertEqual(view.chevronButtons.count, 4)
        XCTAssertTrue(view.chevronButtons.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty }, "icon-only controls have labels")
    }

    func testNarrowBarCollapsesLeadingSegmentsIntoOverflowMenu() throws {
        let view = makeView(width: 120)
        XCTAssertGreaterThan(view.collapsedCount, 0)
        XCTAssertFalse(view.overflowButton.isHidden)
        XCTAssertFalse(view.segmentButtons.last!.isHidden, "current folder stays visible")
        for i in 0..<view.collapsedCount { XCTAssertTrue(view.segmentButtons[i].isHidden) }
        let menu = view.overflowMenu()
        XCTAssertEqual(menu.items.map(\.title), Array(["Data", "alpha", "beta"].prefix(view.collapsedCount)))
        var navigated: URL?
        view.onNavigate = { navigated = $0 }
        let first = try XCTUnwrap(menu.items.first)
        _ = first.target?.perform(first.action, with: first)
        XCTAssertEqual(navigated?.path(percentEncoded: false), "/Volumes/Data/")
        XCTAssertFalse((view.overflowButton.accessibilityLabel() ?? "").isEmpty)
    }

    func testClickOnEmptySpaceRequestsEditMode() {
        let view = makeView(width: 2000)
        var asked = false
        view.onEmptySpaceClick = { asked = true }
        view.emptySpaceClicked()
        XCTAssertTrue(asked)
    }

    func testSubfolderMenuNavigates() {
        let view = makeView(width: 2000)
        var navigated: URL?
        view.onNavigate = { navigated = $0 }
        let parent = dir("/Volumes/Data/alpha")
        let menu = BreadcrumbView.subfolderMenu(names: ["one", "two"], in: parent, target: view)
        XCTAssertEqual(menu.items.map(\.title), ["one", "two"])
        let item = menu.items[1]
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(navigated?.path(percentEncoded: false), "/Volumes/Data/alpha/two/")
        let empty = BreadcrumbView.subfolderMenu(names: [], in: parent, target: view)
        XCTAssertEqual(empty.items.count, 1)
        XCTAssertFalse(empty.items[0].isEnabled, "a disabled 'No subfolders' item")
    }

    // MARK: subfolder listing (sandbox only)

    func testSubfolderListerListsFoldersOnlyAndHonoursShowHidden() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("p/Beta"); try h.dir("p/alpha"); try h.dir("p/.secret"); try h.file("p/file.txt")
        let readers = h.environment.readers
        let names = await SubfolderLister.list(h.url("p"), readers: readers, showHidden: false)
        XCTAssertEqual(names, ["alpha", "Beta"])
        let all = await SubfolderLister.list(h.url("p"), readers: readers, showHidden: true)
        XCTAssertEqual(Set(all), [".secret", "alpha", "Beta"])
        let missing = await SubfolderLister.list(h.url("nope"), readers: readers, showHidden: false)
        XCTAssertEqual(missing, [])
    }
}
