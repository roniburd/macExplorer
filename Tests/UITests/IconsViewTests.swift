// Tests/UITests/IconsViewTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class IconsViewTests: XCTestCase {
    func testGridChangePolicy() {
        XCTAssertEqual(GridChangePolicy.plan(ChangeSet([])), .nothing)
        XCTAssertEqual(GridChangePolicy.plan(ChangeSet([.reload(IndexSet([1, 3]))])), .reloadItems(IndexSet([1, 3])))
        XCTAssertEqual(GridChangePolicy.plan(ChangeSet([.reload(IndexSet(integer: 1)), .insert(IndexSet(integer: 0))])), .reloadAll)
        XCTAssertEqual(GridChangePolicy.plan(.reset), .reloadAll)
    }

    func testRubberBandModes() {
        let grid = FileGridLayout()
        grid.itemCount = 10
        grid.fallbackWidth = 600
        let rect = RubberBand.rect(from: NSPoint(x: 260, y: 100), to: NSPoint(x: 20, y: 20))
        XCTAssertEqual(rect, NSRect(x: 20, y: 20, width: 240, height: 80))
        let hits = RubberBand.hits(in: rect, layout: grid)
        XCTAssertEqual(hits, IndexSet([0, 1, 2]))
        XCTAssertEqual(RubberBand.selection(base: IndexSet([2, 7]), hits: hits, mode: .replace), IndexSet([0, 1, 2]))
        XCTAssertEqual(RubberBand.selection(base: IndexSet([2, 7]), hits: hits, mode: .add), IndexSet([0, 1, 2, 7]))
        XCTAssertEqual(RubberBand.selection(base: IndexSet([2, 7]), hits: hits, mode: .toggle), IndexSet([0, 1, 7]))
    }

    func testTruncationLeavesShortNamesAlone() {
        XCTAssertEqual(LabelTruncation.twoLineMiddle("notes.txt", width: 100, font: CellStyle.smallFont), "notes.txt")
    }

    func testTruncationKeepsGraphemesAndExtension() {
        let font = CellStyle.smallFont
        let long = String(repeating: "verylongname_", count: 12) + "final.txt"
        let cut = LabelTruncation.twoLineMiddle(long, width: 72, font: font)
        XCTAssertTrue(cut.contains("…"))
        XCTAssertTrue(cut.hasSuffix(".txt"), cut)
        let twoLines = ("X\nX" as NSString).boundingRect(with: NSSize(width: 72, height: 1_000), options: [.usesLineFragmentOrigin],
                                                         attributes: [.font: font]).height
        let height = (cut as NSString).boundingRect(with: NSSize(width: 72, height: 1_000), options: [.usesLineFragmentOrigin],
                                                    attributes: [.font: font]).height
        XCTAssertLessThanOrEqual(height, twoLines + 0.5)
        let emoji = String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 30) + ".png"
        let cutEmoji = LabelTruncation.twoLineMiddle(emoji, width: 72, font: font)
        XCTAssertTrue(Set(cutEmoji).subtracting(Set(emoji)).subtracting(["…"]).isEmpty, "no split graphemes: \(cutEmoji)")
        XCTAssertTrue(cutEmoji.hasSuffix(".png"))
    }

    /// QA round 2: the label lays text out narrower than its frame (cell inset), so a candidate measured at the full
    /// width still overflowed and the cell added a second, tail ellipsis that hid the extension.
    func testIconLabelsShowOneMiddleEllipsisAndTheExtensionAtEverySize() throws {
        let name = "a very long file name that should wrap onto two lines and then ellipsize in the middle.txt"
        for size in IconSize.allCases {
            let metrics = GridMetrics.forIconSize(size)
            let item = IconItem()
            item.loadView()
            item.view.frame = NSRect(origin: .zero, size: metrics.itemSize)
            let icon = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
            let labelWidth = Double(metrics.itemSize.width - 8)
            item.configure(name: name, icon: icon, points: size.points, labelWidth: labelWidth, isCut: false,
                           isSelected: false, emphasized: false, isDataless: false, rowID: .object(1))
            item.view.layoutSubtreeIfNeeded()
            let shown = item.label.stringValue
            XCTAssertEqual(shown.filter { $0 == "…" }.count, 1, "\(size): \(shown)")
            XCTAssertTrue(shown.hasSuffix(".txt"), "\(size): \(shown)")
            XCTAssertEqual(item.label.alignmentRect(forFrame: item.label.frame).width, CGFloat(labelWidth), accuracy: 0.5)
            // Laid out by the label's own cell without a line limit, the text needs at most two lines: the cell
            // never has to truncate it again.
            let probe = NSTextField(wrappingLabelWithString: shown)
            probe.font = item.label.font
            probe.alignment = item.label.alignment
            let bounds = NSRect(x: 0, y: 0, width: item.label.frame.width, height: 1_000)
            let needed = try XCTUnwrap(probe.cell).cellSize(forBounds: bounds).height
            probe.stringValue = "X\nX"
            let twoLines = try XCTUnwrap(probe.cell).cellSize(forBounds: bounds).height
            XCTAssertLessThanOrEqual(needed, twoLines + 0.5, "\(size): '\(shown)' needs more than two lines")
        }
    }

    func testTruncationIsFast() {
        let names = (0..<200).map { "document-\($0)-" + String(repeating: "x", count: 120) + ".pdf" }
        // Best of 5 passes: the intrinsic cost, not scheduling noise when `swift test --parallel` loads every core.
        var best = Duration.seconds(60)
        for _ in 0..<5 {
            let start = ContinuousClock.now
            for name in names { _ = LabelTruncation.twoLineMiddle(name, width: 104, font: CellStyle.smallFont) }
            best = min(best, ContinuousClock.now - start)
        }
        XCTAssertLessThan(best / names.count, .milliseconds(2))
    }

    // MARK: AppKit (offscreen window)

    private func makeIcons(_ h: ContentTestHarness, files: Int) async throws -> (IconsViewController, FolderModel) {
        for i in 0..<files { try h.file(String(format: "i%02d.txt", i)) }
        let folder = try await h.openFolder()
        let icons = IconsViewController(context: h.context)
        try h.host(icons, size: NSSize(width: 620, height: 500))
        icons.bind(folder)
        return (icons, folder)
    }

    func testBindShowsItemsAndIconSizeFollowsSettings() async throws {
        let h = try await ContentTestHarness.make(self)
        h.environment.settings.iconSize = .medium
        let (icons, _) = try await makeIcons(h, files: 9)
        XCTAssertEqual(icons.collectionView.numberOfItems(inSection: 0), 9)
        XCTAssertEqual(icons.layout.itemCount, 9)
        XCTAssertEqual(icons.collectionView.accessibilityIdentifier(), AXID.iconsGrid)
        XCTAssertFalse(icons.collectionView.isSelectable, "selection is model-owned (§5.5)")
        h.environment.settings.iconSize = .large
        try await h.waitUntil("large icons") { icons.layout.iconSize == .large }
    }

    func testArrowKeysMoveSpatially() async throws {
        let h = try await ContentTestHarness.make(self)
        h.environment.settings.iconSize = .medium
        let (icons, folder) = try await makeIcons(h, files: 10)
        let columns = icons.layout.columns
        XCTAssertGreaterThan(columns, 1)
        folder.select(.set(IndexSet(integer: 0), cursor: 0))
        XCTAssertTrue(icons.handleKeyDown(try key(.downArrow, window: icons.view.window)))
        XCTAssertEqual(folder.selection.rows, IndexSet(integer: columns))
        XCTAssertTrue(icons.handleKeyDown(try key(.rightArrow, flags: .shift, window: icons.view.window)))
        XCTAssertEqual(folder.selection.rows, IndexSet([columns, columns + 1]))
        _ = icons.handleKeyDown(try key(.downArrow, flags: .command, window: icons.view.window))
        XCTAssertEqual(folder.selection.rows, IndexSet([columns, columns + 1]), "⌘-arrows never change the selection")
    }

    func testSwitchingViewModeKeepsSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["a.txt", "b.txt", "c.txt"] { try h.file(name) }
        let (content, session, _) = try await h.makeContent()
        session.folder.select(.set(IndexSet([0, 2]), cursor: 2))
        content.setViewMode(.icons)
        XCTAssertTrue(content.activeList === content.icons)
        XCTAssertEqual(content.icons?.collectionView.numberOfItems(inSection: 0), 3)
        XCTAssertEqual(session.folder.selection.rows, IndexSet([0, 2]))
        content.setViewMode(.details)
        XCTAssertTrue(content.activeList === content.details)
        XCTAssertEqual(content.details.tableView.selectedRowIndexes, IndexSet([0, 2]))
    }

    func testRubberBandSelectsIntoModel() async throws {
        let h = try await ContentTestHarness.make(self)
        h.environment.settings.iconSize = .medium
        let (icons, folder) = try await makeIcons(h, files: 8)
        icons.applyRubberBand(rect: NSRect(x: 0, y: 0, width: 600, height: 60), mode: .replace, base: [])
        XCTAssertEqual(folder.selection.rows, IndexSet(integersIn: 0..<icons.layout.columns))
        icons.applyRubberBand(rect: NSRect(x: 0, y: 0, width: 60, height: 60), mode: .toggle, base: folder.selection.rows)
        XCTAssertFalse(folder.selection.rows.contains(0))
    }

    private func key(_ special: NSEvent.SpecialKey, flags: NSEvent.ModifierFlags = [], window: NSWindow?) throws -> NSEvent {
        let characters = String(Character(UnicodeScalar(UInt16(special.rawValue))!))
        let codes: [NSEvent.SpecialKey: UInt16] = [.upArrow: 126, .downArrow: 125, .leftArrow: 123, .rightArrow: 124]
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                              windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                              charactersIgnoringModifiers: characters, isARepeat: false,
                                              keyCode: codes[special] ?? 0))
    }
}
