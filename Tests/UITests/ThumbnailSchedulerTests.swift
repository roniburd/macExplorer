// Tests/UITests/ThumbnailSchedulerTests.swift
import XCTest
@testable import UI
@testable import Core
import MacxFS

@MainActor
final class FakeThumbnailGenerator: ThumbnailGenerating {
    var started: [URL] = []
    var cancelled: [URL] = []
    private var pending: [ThumbnailTicket: (URL, @MainActor (CGImage?) -> Void)] = [:]
    private var next: UInt64 = 0
    func generate(url: URL, pointSize: CGFloat, scale: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> ThumbnailTicket {
        next += 1; let t = ThumbnailTicket(raw: next); pending[t] = (url, completion); started.append(url); return t
    }
    func cancel(_ ticket: ThumbnailTicket) { if let (u, _) = pending.removeValue(forKey: ticket) { cancelled.append(u) } }
    func complete(_ url: URL, image: CGImage?) {
        guard let (t, (_, c)) = pending.first(where: { $0.value.0 == url }) else { return }
        pending[t] = nil; c(image)
    }
}

@MainActor
final class ThumbnailSchedulerTests: XCTestCase {
    let gen = FakeThumbnailGenerator()
    var cache = ThumbnailCache()
    lazy var scheduler = ThumbnailScheduler(generator: gen, cache: cache, maxInFlight: 8)
    func cand(_ i: Int, mtime: Int64 = 1) -> ThumbnailCandidate {
        ThumbnailCandidate(key: ThumbnailKey(volume: .unknown, id: .object(UInt64(i)), directory: "/d", mtime: mtime, size: 10, pixels: 128),
                           url: URL(filePath: "/d/\(i).png"))
    }
    func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testVisibleOnlyAndMaxInFlight() {
        scheduler.updateVisible((0..<20).map { cand($0) }, pointSize: 64, scale: 2)
        XCTAssertEqual(gen.started.count, 8)
        XCTAssertEqual(gen.started.map(\.lastPathComponent), (0..<8).map { "\($0).png" }, "in visible order")
    }

    func testScrollOffCancelsAndStartsNewlyVisible() {
        scheduler.updateVisible((0..<8).map { cand($0) }, pointSize: 64, scale: 2)
        scheduler.updateVisible((8..<16).map { cand($0) }, pointSize: 64, scale: 2)
        XCTAssertEqual(Set(gen.cancelled.map(\.lastPathComponent)), Set((0..<8).map { "\($0).png" }))
        XCTAssertEqual(gen.started.count, 16)
    }

    func testCompletionCachesNotifiesAndPumpsNext() {
        var notified: [ThumbnailKey] = []
        scheduler.onThumbnail = { notified.append($0) }
        scheduler.updateVisible((0..<9).map { cand($0) }, pointSize: 64, scale: 2)
        gen.complete(URL(filePath: "/d/0.png"), image: image())
        XCTAssertEqual(notified, [cand(0).key])
        XCTAssertNotNil(cache.image(cand(0).key))
        XCTAssertEqual(gen.started.count, 9, "slot freed → the 9th starts")
    }

    func testFailureIsNotRetriedAndCacheHitSkipsRequest() {
        scheduler.updateVisible([cand(0)], pointSize: 64, scale: 2)
        gen.complete(URL(filePath: "/d/0.png"), image: nil)
        scheduler.updateVisible([cand(0)], pointSize: 64, scale: 2)
        XCTAssertEqual(gen.started.count, 1)
        cache.store(image(), for: cand(1).key)
        scheduler.updateVisible([cand(1)], pointSize: 64, scale: 2)
        XCTAssertEqual(gen.started.count, 1)
        scheduler.updateVisible([cand(1, mtime: 2)], pointSize: 64, scale: 2)
        XCTAssertEqual(gen.started.count, 2, "a changed file is a new key")
    }

    func testCancelAllCancelsInFlightAndStopsRequests() {
        scheduler.updateVisible((0..<3).map { cand($0) }, pointSize: 64, scale: 2)
        scheduler.cancelAll()
        XCTAssertEqual(Set(gen.cancelled.map(\.lastPathComponent)), ["0.png", "1.png", "2.png"])
        XCTAssertTrue(scheduler.inFlight.isEmpty)
    }

    func testLateCompletionAfterCancelIsIgnored() {
        var notified: [ThumbnailKey] = []
        scheduler.onThumbnail = { notified.append($0) }
        var captured: (@MainActor (CGImage?) -> Void)?
        final class Capturing: ThumbnailGenerating {
            var completion: (@MainActor (CGImage?) -> Void)?
            func generate(url: URL, pointSize: CGFloat, scale: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> ThumbnailTicket {
                self.completion = completion; return ThumbnailTicket(raw: 1)
            }
            func cancel(_ ticket: ThumbnailTicket) {}
        }
        let capturing = Capturing()
        let s = ThumbnailScheduler(generator: capturing, cache: cache, maxInFlight: 8)
        s.onThumbnail = { notified.append($0) }
        s.updateVisible([cand(0)], pointSize: 64, scale: 2)
        captured = capturing.completion
        s.updateVisible([], pointSize: 64, scale: 2)
        captured?(image())
        XCTAssertTrue(notified.isEmpty)
        XCTAssertNil(cache.image(cand(0).key))
    }

    func testCacheCostLimitEvicts() {
        let small = ThumbnailCache(costLimit: 4 * 4 * 4)
        small.store(image(), for: cand(0).key)
        small.store(image(), for: cand(1).key)
        XCTAssertFalse(small.image(cand(0).key) != nil && small.image(cand(1).key) != nil, "cost limit holds one 4×4 image")
    }

    func testEligibility() {
        let types = TypeRegistry.shared
        func e(_ kind: Kind, _ flags: EntryFlags = [], size: Int64 = 10, ext: Substring = "png") -> Entry {
            Entry(rowID: 1, fileID: 1, size: size, allocSize: size, mtime: 0, ctime: 0, nameOffset: 0, nameLen: 0, kind: kind, flags: flags,
                  typeIndex: types.index(forExtension: ext, isDirectory: kind == .package || kind == .directory))
        }
        XCTAssertTrue(ThumbnailScheduler.isEligible(e(.file), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.file, [.dataless]), types: types), "never download iCloud content")
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.file, [.degraded]), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.file, size: 0), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.directory, ext: ""), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.package, ext: "app"), types: types))
        XCTAssertTrue(ThumbnailScheduler.isEligible(e(.package, ext: "pages"), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.symlink), types: types))
        XCTAssertFalse(ThumbnailScheduler.isEligible(e(.alias), types: types))
    }
}

/// IconsViewController wiring (P2-17): a fake generator, so nothing here calls Quick Look; every file is in the
/// harness sandbox.
@MainActor
final class IconsThumbnailTests: XCTestCase {
    private func makeIcons(_ h: ContentTestHarness, _ gen: FakeThumbnailGenerator) async throws -> (IconsViewController, FolderModel) {
        _ = try h.sandbox.writePNG("files/p1.png")
        try h.file("t.txt", bytes: 3)
        try h.file("empty.txt", bytes: 0)
        try h.dir("sub")
        h.context.makeThumbnailGenerator = { gen }
        let folder = try await h.openFolder()
        let icons = IconsViewController(context: h.context)
        try h.host(icons, size: NSSize(width: 620, height: 500))
        icons.bind(folder)
        return (icons, folder)
    }

    private func image(_ w: Int = 8, _ h: Int = 4) -> CGImage {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func item(_ icons: IconsViewController, _ folder: FolderModel, _ name: String) -> IconItem? {
        guard let row = (0..<folder.rowCount).first(where: { folder.name(atRow: $0) == name }) else { return nil }
        return icons.collectionView.item(at: IndexPath(item: row, section: 0)) as? IconItem
    }

    func testRequestsOnlyEligibleVisibleItemsAndShowsArrivingThumbnail() async throws {
        let h = try await ContentTestHarness.make(self)
        let gen = FakeThumbnailGenerator()
        let (icons, folder) = try await makeIcons(h, gen)
        try await h.waitUntil("requests") { gen.started.count == 2 }
        XCTAssertEqual(Set(gen.started.map(\.lastPathComponent)), ["p1.png", "t.txt"], "no folders, no empty files")
        XCTAssertEqual(icons.thumbnailNames(), [])
        XCTAssertNil(item(icons, folder, "p1.png")?.thumbnailKey, "the type icon shows first")
        gen.complete(try XCTUnwrap(gen.started.first { $0.lastPathComponent == "p1.png" }), image: image())
        XCTAssertEqual(icons.thumbnailNames(), ["p1.png"])
        let shown = try XCTUnwrap(item(icons, folder, "p1.png"))
        XCTAssertFalse(shown.thumbnailView.isHidden)
        XCTAssertTrue(shown.iconView.isHidden)
        XCTAssertEqual(shown.thumbnailView.layer?.borderWidth, 1)
        icons.collectionView.layoutSubtreeIfNeeded()
        XCTAssertEqual(shown.thumbnailView.frame.width, CGFloat(icons.layout.iconSize.points), accuracy: 0.5, "aspect fit: full width")
        XCTAssertEqual(shown.thumbnailView.frame.height, CGFloat(icons.layout.iconSize.points) / 2, accuracy: 0.5, "aspect fit: half height")
        icons.collectionView.reloadData()   // reconfigured cells take the cached thumbnail at once
        icons.collectionView.layoutSubtreeIfNeeded()
        XCTAssertEqual(icons.thumbnailNames(), ["p1.png"])
        XCTAssertEqual(gen.started.count, 2, "a cache hit never asks again")
    }

    func testTurningThumbnailsOffCancelsAndRestoresIcons() async throws {
        let h = try await ContentTestHarness.make(self)
        let gen = FakeThumbnailGenerator()
        let (icons, folder) = try await makeIcons(h, gen)
        try await h.waitUntil("requests") { gen.started.count == 2 }
        gen.complete(try XCTUnwrap(gen.started.first { $0.lastPathComponent == "p1.png" }), image: image())
        h.environment.settings.showThumbnails = false
        try await h.waitUntil("t.txt cancelled") { gen.cancelled.map(\.lastPathComponent) == ["t.txt"] }
        try await h.waitUntil("icons restored") { icons.thumbnailNames().isEmpty }
        XCTAssertNil(item(icons, folder, "p1.png")?.thumbnailKey)
        icons.refreshThumbnails()
        XCTAssertEqual(gen.started.count, 2, "no requests while off")
        h.environment.settings.showThumbnails = true
        try await h.waitUntil("cached thumbnail back") { icons.thumbnailNames() == ["p1.png"] }
        try await h.waitUntil("t.txt asked again") { gen.started.count == 3 }
    }

    /// QA round 1: Details scrolled past the grid's first screen, then ⌘2. The grid has no width when it is bound,
    /// so the scroll restore waits for its first layout; then the anchor's screen is shown and its thumbnails asked.
    func testSwitchingToIconsRestoresTheScrollAfterLayoutAndAsksForThoseThumbnails() async throws {
        let h = try await ContentTestHarness.make(self)
        for i in 0..<400 { try h.file(String(format: "p%03d.png", i), bytes: 10) }
        let gen = FakeThumbnailGenerator()
        h.context.makeThumbnailGenerator = { gen }
        let (content, session, _) = try await h.makeContent()
        session.folder.select(.set(IndexSet(integer: 300), cursor: 300))
        content.details.tableView.scrollRowToVisible(300)
        try await h.waitUntil("details anchor") { session.folder.scrollAnchor != nil }
        let anchor = try XCTUnwrap(session.folder.scrollAnchor)
        content.setViewMode(.icons)
        let icons = try XCTUnwrap(content.icons)
        try await h.waitUntil("the anchor's screen is shown and asked for") {
            icons.visibleRows().contains(300) && !gen.started.isEmpty
        }
        let visibleNames = Set(icons.visibleRows().map { String(format: "p%03d.png", $0) })
        XCTAssertTrue(gen.started.allSatisfy { visibleNames.contains($0.lastPathComponent) },
                      "only the shown screen is asked for: \(gen.started.map(\.lastPathComponent))")
        XCTAssertEqual(session.folder.scrollAnchor, anchor, "the clamp before the first layout never moves the anchor")
    }

    func testUnbindAndIconSizeChangeCancel() async throws {
        let h = try await ContentTestHarness.make(self)
        let gen = FakeThumbnailGenerator()
        let (icons, folder) = try await makeIcons(h, gen)
        try await h.waitUntil("requests") { gen.started.count == 2 }
        let small = try XCTUnwrap((0..<folder.rowCount).lazy.compactMap { icons.thumbnailKey(row: $0, scale: 2) }.first).pixels
        icons.setIconSize(icons.layout.iconSize == .large ? .small : .large)
        try await h.waitUntil("old size cancelled, new size asked") { gen.cancelled.count == 2 && gen.started.count == 4 }
        let rows = (0..<folder.rowCount).compactMap { icons.thumbnailKey(row: $0, scale: 2) }
        XCTAssertTrue(rows.allSatisfy { $0.pixels != small }, "icon size is part of the key")
        icons.bind(nil)
        XCTAssertEqual(gen.cancelled.count, 4)
        XCTAssertTrue(icons.thumbnails.inFlight.isEmpty)
    }
}
