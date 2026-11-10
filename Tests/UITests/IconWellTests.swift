import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS

/// Collects values from escaping main-actor closures.
@MainActor
private final class Box<Value> {
    var values: [Value] = []
}

@MainActor
final class IconWellTests: XCTestCase {
    private func model(_ h: ContentTestHarness, _ relatives: [String]) -> PropertiesViewModel {
        PropertiesViewModel(subject: .items(relatives.map { h.url($0).standardizedFileURL }), environment: h.environment)
    }

    private func item(_ m: PropertiesViewModel) -> ItemProperties? {
        if case .item(let item) = m.content { item } else { nil }
    }

    private func multi(_ m: PropertiesViewModel) -> MultiProperties? {
        if case .items(let multi) = m.content { multi } else { nil }
    }

    private func privatePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("macx-tests-\(UUID().uuidString)"))
        addTeardownBlock { @MainActor in pb.releaseGlobally() }
        return pb
    }

    // MARK: the well and the Properties model

    func testDropImageFileRunsJobAndRemoveRestores() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt")
        let imageFile = try ui.file("icon.png", contents: TestImagesUI.png())
        let m = model(ui, ["a.txt"])
        await m.load()
        XCTAssertEqual(item(m)?.hasCustomIcon, false)
        XCTAssertFalse(m.hasCustomIcon)
        XCTAssertTrue(m.canEditIcon)
        let changed = Box<Void>()
        m.onIconChanged = { changed.values.append(()) }
        let well = IconWell(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        well.lanes = ui.environment.lanes
        well.onDropImage = { data in Task { await m.setCustomIcon(data) } }
        XCTAssertTrue(well.acceptFileURLs([imageFile]))
        try await ui.waitUntil("custom icon set") { self.item(m)?.hasCustomIcon == true }
        XCTAssertTrue(m.hasCustomIcon)
        XCTAssertFalse(changed.values.isEmpty, "the window refreshes its icon after the job")
        XCTAssertTrue(ui.environment.undo.canUndo)
        await m.setCustomIcon(nil)
        try await ui.waitUntil("custom icon removed") { self.item(m)?.hasCustomIcon == false }
        XCTAssertNil(m.inlineError)
        // Undo of the removal brings the icon back and the window follows (it reloads on finished jobs).
        ui.environment.undo.undoManager.undo()
        try await ui.waitUntil("undo restored the icon") { self.item(m)?.hasCustomIcon == true }
        m.close()
    }

    func testDropOnSeveralItemsIsOneJob() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt"); try ui.file("b.txt")
        let m = model(ui, ["a.txt", "b.txt"])
        await m.load()
        XCTAssertEqual(multi(m)?.customIcon, .off)
        let requests = Box<JobKind>()
        let operations = ui.environment.operations
        m.perform = { request in requests.values.append(request.kind); return await operations.perform(request) }
        await m.setCustomIcon(IconImageData(bytes: TestImagesUI.png()))
        XCTAssertEqual(requests.values.count, 1)
        XCTAssertEqual(multi(m)?.customIcon, .on)
        XCTAssertTrue(m.hasCustomIcon)
        m.close()
    }

    func testWellRefusesNonImagesAndHugeFiles() async throws {
        let ui = try await ContentTestHarness.make(self)
        let text = try ui.file("t.txt")
        let huge = try ui.file("huge.png", bytes: IconImageData.maxBytes + 1)
        let fake = try ui.file("fake.png", contents: Data("not an image".utf8))
        let well = IconWell(frame: .zero)
        well.lanes = ui.environment.lanes
        let dropped = Box<IconImageData>(), refused = Box<Void>()
        well.onDropImage = { dropped.values.append($0) }
        well.onRefused = { refused.values.append(()) }
        XCTAssertFalse(well.acceptFileURLs([text]))
        XCTAssertFalse(well.acceptFileURLs([]))
        XCTAssertTrue(well.acceptFileURLs([huge]), "the extension says image; the read decides")
        XCTAssertTrue(well.acceptFileURLs([fake]))
        try await ui.waitUntil("both refused") { refused.values.count == 2 }
        XCTAssertEqual(dropped.values.count, 0)
        well.isEnabled = false
        XCTAssertFalse(well.acceptFileURLs([try ui.file("ok.png", contents: TestImagesUI.png())]),
                       "a read-only item's well takes nothing")
    }

    func testDroppingAnAppOrFolderUsesItsIcon() async throws {
        let ui = try await ContentTestHarness.make(self)
        let app = try ui.dir("Some.app/Contents").deletingLastPathComponent()
        let well = IconWell(frame: .zero)
        well.lanes = ui.environment.lanes
        let dropped = Box<IconImageData>()
        well.onDropImage = { dropped.values.append($0) }
        XCTAssertTrue(well.acceptFileURLs([app]))
        try await ui.waitUntil("app icon taken") { !dropped.values.isEmpty }
        XCTAssertEqual(dropped.values.first?.isDecodableImage, true)
    }

    func testPasteFromPrivatePasteboard() async throws {
        _ = try await ContentTestHarness.make(self)
        let pb = privatePasteboard()
        pb.clearContents(); pb.setData(TestImagesUI.png(), forType: .png)
        let well = IconWell(frame: .zero)
        var got: IconImageData?
        well.onDropImage = { got = $0 }
        XCTAssertTrue(well.paste(from: pb))
        XCTAssertEqual(got?.isDecodableImage, true)
        pb.clearContents(); pb.setString("hello", forType: .string)
        got = nil
        XCTAssertFalse(well.paste(from: pb))
        XCTAssertNil(got)
    }

    func testCopyAndResponderPasteUseOnlyTheProvidedPasteboard() async throws {
        _ = try await ContentTestHarness.make(self)
        let well = IconWell(frame: .zero)
        let pb = privatePasteboard()
        XCTAssertFalse(well.validate(action: #selector(NSText.paste(_:))), "no pasteboard (sandbox default): no paste")
        well.pasteboardProvider = { pb }
        well.image = NSImage(data: TestImagesUI.png())
        well.copy(nil)
        XCTAssertNotNil(pb.data(forType: .tiff))
        var got: IconImageData?
        well.onDropImage = { got = $0 }
        XCTAssertTrue(well.validate(action: #selector(NSText.paste(_:))))
        well.paste(nil)
        XCTAssertEqual(got?.isDecodableImage, true)
        var removed = 0
        well.onRemove = { removed += 1 }
        well.showsRemove = false
        well.delete(nil)
        XCTAssertEqual(removed, 0)
        well.showsRemove = true
        well.delete(nil)
        XCTAssertEqual(removed, 1)
    }

    // MARK: icon packs

    func testIconPackOverridesTypeIconAfterLoad() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("pack/pdf.png", contents: TestImagesUI.png(red: 0))     // a distinctive colour
        try ui.file("pack/folder.png", contents: TestImagesUI.png(red: 0.5))
        let pack = try await IconPackLoader.load(ui.url("pack"), lanes: ui.environment.lanes)
        let types = ui.environment.types
        let pdf = types.index(forExtension: "pdf", isDirectory: false)
        let icons = ui.context.icons
        let before = icons.typeIcon(pdf, points: 32, scale: 2)
        let folderBefore = icons.typeIcon(TypeRegistry.folderIndex, points: 16, scale: 2)
        let posted = Box<Void>()
        let token = NotificationCenter.default.addObserver(forName: IconCache.iconPackChanged, object: icons, queue: nil) { _ in
            MainActor.assumeIsolated { posted.values.append(()) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await icons.setIconPack(pack)
        XCTAssertEqual(posted.values.count, 1)
        let after = icons.typeIcon(pdf, points: 32, scale: 2)
        XCTAssertFalse(before === after)
        XCTAssertEqual(after.width, 64)
        XCTAssertLessThan(TestImagesUI.centrePixel(after)[0], 40, "the pack's (red 0) image, not the system icon")
        XCTAssertTrue(after === icons.typeIcon(pdf, points: 32, scale: 2), "cached per pixel size")
        XCTAssertEqual(icons.typeIcon(pdf, points: 48, scale: 2).width, 96, "between rasterized sizes: scaled once")
        XCTAssertEqual(icons.typeIcon(pdf, points: 512, scale: 2).width, 1024)
        XCTAssertFalse(folderBefore === icons.typeIcon(TypeRegistry.folderIndex, points: 16, scale: 2))
        let txt = types.index(forExtension: "txt", isDirectory: false)
        XCTAssertGreaterThan(TestImagesUI.centrePixel(icons.typeIcon(txt, points: 32, scale: 2))[3], 0,
                             "types the pack doesn't cover keep the system icon")
        await icons.setIconPack(nil)
        XCTAssertEqual(posted.values.count, 2)
        XCTAssertFalse(icons.typeIcon(pdf, points: 32, scale: 2) === after)
        XCTAssertNil(icons.currentPack)
    }

    func testUndecodablePackImageFallsBackToTheSystemIcon() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("pack/pdf.png", contents: Data("not an image".utf8))
        try ui.file("pack/swift.png", contents: TestImagesUI.png(red: 0))
        let pack = try await IconPackLoader.load(ui.url("pack"), lanes: ui.environment.lanes)
        let icons = ui.context.icons
        await icons.setIconPack(pack)
        let pdf = ui.environment.types.index(forExtension: "pdf", isDirectory: false)
        XCTAssertGreaterThan(TestImagesUI.centrePixel(icons.typeIcon(pdf, points: 32, scale: 2))[3], 0)
        XCTAssertEqual(icons.currentPack, pack)
    }

    func testSettingsIconPackChooseClearAndRestore() async throws {
        let ui = try await ContentTestHarness.make(self)
        let settings = ui.environment.settings
        let iconPack = ui.context.iconPack
        let notPack = try ui.dir("notapack")
        try ui.file("notapack/readme.txt")
        let ok = await iconPack.choose(notPack)
        XCTAssertFalse(ok)
        XCTAssertEqual(iconPack.error, L10n.string("That folder isn't an icon pack."))
        XCTAssertNil(settings.iconPackBookmark)
        try ui.file("pack/pdf.png", contents: TestImagesUI.png(red: 0))
        let packURL = ui.url("pack")
        await iconPack.select(.choose) { packURL }
        XCTAssertNil(iconPack.error)
        XCTAssertEqual(iconPack.folderName, "pack")
        XCTAssertNotNil(settings.iconPackBookmark)
        XCTAssertNotNil(ui.context.icons.currentPack)
        // A launch resolves the stored bookmark.
        await ui.context.icons.setIconPack(nil)
        await ui.context.restoreIconPack()
        XCTAssertEqual(ui.context.icons.currentPack?.byExtension.keys.sorted(), ["pdf"])
        XCTAssertEqual(iconPack.selection, .current)
        await iconPack.select(.choose) { nil }                     // Choose Folder… cancelled: the pack stays
        XCTAssertEqual(iconPack.folderName, "pack")
        await iconPack.select(.none) { XCTFail("None asks for nothing"); return nil }
        XCTAssertEqual(iconPack.selection, .none)
        XCTAssertNil(settings.iconPackBookmark)
        XCTAssertNil(iconPack.folderName)
        XCTAssertNil(ui.context.icons.currentPack)
    }

    func testSandboxRunIgnoresAPackOutsideRoot() async throws {
        let ui = try await ContentTestHarness.make(self)
        let outside = try ui.sandbox.createFile("outside-pack/pdf.png", contents: TestImagesUI.png()).deletingLastPathComponent()
        ui.environment.settings.iconPackBookmark = try outside.bookmarkData(options: [])
        await ui.context.restoreIconPack()
        XCTAssertNil(ui.context.icons.currentPack, "--root sandbox runs only use packs inside the root")
        XCTAssertNil(ui.context.iconPack.folderName)
    }
}
