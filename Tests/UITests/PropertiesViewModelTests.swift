// Tests/UITests/PropertiesViewModelTests.swift
import XCTest
import AppKit
import Darwin
@testable import UI
import Core
import MacxFS

/// Collects values from escaping main-actor closures (a captured `var` can't be mutated from them).
@MainActor
private final class Recorder<Value> {
    var values: [Value] = []
}

@MainActor
final class PropertiesViewModelTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func model(_ h: ContentTestHarness, _ relatives: [String]) -> PropertiesViewModel {
        PropertiesViewModel(subject: .items(relatives.map { h.url($0).standardizedFileURL }), environment: h.environment)
    }

    private func item(_ m: PropertiesViewModel) -> ItemProperties? {
        if case .item(let item) = m.content { item } else { nil }
    }

    private func multi(_ m: PropertiesViewModel) -> MultiProperties? {
        if case .items(let multi) = m.content { multi } else { nil }
    }

    private func flags(_ h: ContentTestHarness, _ relative: String) -> UInt32? { h.lstatInfo(relative)?.st_flags }
    private func mode(_ h: ContentTestHarness, _ relative: String) -> UInt16? { h.lstatInfo(relative).map { UInt16($0.st_mode) & 0o777 } }

    func testSingleFileLoadsNameSizeAndTitle() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt", bytes: 1_234)
        let m = model(h, ["a.txt"])
        await m.load()
        let p = try XCTUnwrap(item(m))
        XCTAssertEqual(p.name, "a.txt")
        XCTAssertEqual(p.logicalSize, 1_234)
        XCTAssertEqual(m.nameDraft, "a.txt")
        XCTAssertEqual(m.title, "a.txt Properties")
        XCTAssertTrue(m.canEditPermissions, "the test user owns its sandbox files")
        XCTAssertTrue(m.showsOpensWith)
        XCTAssertNil(m.folderCount, "files are not counted")
    }

    func testFolderShowsLiveCountThatFinishes() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("F/a.txt", bytes: 10)
        try h.file("F/b.txt", bytes: 20)
        try h.file("F/sub/c.txt", bytes: 30)
        let m = model(h, ["F"])
        await m.load()
        XCTAssertFalse(m.showsOpensWith, "folders have no Opens with tab")
        try await h.waitUntil("count finished") { m.folderCount?.finished == true }
        // P1-16 counts the folder's contents, not the folder itself.
        XCTAssertEqual(m.folderCount?.files, 3)
        XCTAssertEqual(m.folderCount?.folders, 1)
        XCTAssertGreaterThanOrEqual(m.folderCount?.bytes ?? 0, 60, "logical or allocated bytes, at least the 60 written")
        m.close()
    }

    func testLockToggleRunsUndoableJobAndUndoRestores() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let path = h.url("a.txt").path
        addTeardownBlock { _ = chflags(path, 0) }   // never leave a locked file behind if an assertion fails
        let m = model(h, ["a.txt"])
        await m.load()
        await m.setLocked(true)
        XCTAssertNil(m.inlineError)
        XCTAssertEqual(flags(h, "a.txt").map { $0 & UInt32(UF_IMMUTABLE) != 0 }, true)
        XCTAssertEqual(item(m)?.isLocked, true)
        try await h.waitUntil("undo registered") { h.environment.undo.canUndo }
        h.environment.undo.undoManager.undo()
        try await h.waitUntil("unlocked on disk") { self.flags(h, "a.txt").map { $0 & UInt32(UF_IMMUTABLE) == 0 } == true }
        try await h.waitUntil("window follows the undo") { self.item(m)?.isLocked == false }
    }

    func testFailedEditShowsInlineErrorAndRevertsControl() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.setMode("a.txt", 0o644)
        try h.setFlags("a.txt", UF_IMMUTABLE)          // chmod on a locked file fails with EPERM
        let m = model(h, ["a.txt"])
        await m.load()
        await m.setAccess(.noAccess, for: .everyone)
        XCTAssertEqual(m.inlineError, "'a.txt' is locked.")
        XCTAssertEqual(item(m).map { $0.mode & 0o777 }, 0o644, "the popup reverts to the value on disk")
        XCTAssertEqual(mode(h, "a.txt"), 0o644)
        XCTAssertEqual(h.interaction.askedErrors().map(\.kind), [.locked])
        await m.setAccess(.readWrite, for: .owner)      // unchanged value: no job, error stays until the next edit
        XCTAssertEqual(h.interaction.askedErrors().count, 1)
    }

    func testRenameValidatesOnLaneIncludingHiddenNames() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.file("b.txt")
        try h.setFlags("b.txt", UF_HIDDEN)              // Review Focus 2: hidden names still count
        let m = model(h, ["a.txt"])
        await m.load()
        let renamed = Recorder<PropertiesSubject>()
        m.onSubjectChanged = { renamed.values.append($0) }
        m.nameDraft = "b.txt"
        let duplicate = await m.commitName()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(m.nameProblem, "The name 'b.txt' is already taken.")
        m.nameDraft = "a/b"
        let slash = await m.commitName()
        XCTAssertFalse(slash)
        XCTAssertEqual(m.nameProblem, "A name can't contain '/'.")
        XCTAssertTrue(h.exists("a.txt"))
        m.nameDraft = "c.txt"
        let ok = await m.commitName()
        XCTAssertTrue(ok)
        XCTAssertNil(m.nameProblem)
        XCTAssertTrue(h.exists("c.txt"))
        XCTAssertFalse(h.exists("a.txt"))
        let newURL = h.url("c.txt").standardizedFileURL
        try await h.waitUntil("subject follows the rename") { m.urls == [newURL] }
        XCTAssertEqual(renamed.values.last, .items([newURL]))
        XCTAssertEqual(m.title, "c.txt Properties")
        XCTAssertEqual(item(m)?.name, "c.txt")
    }

    func testExtensionChangeAsksBeforeRenaming() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let m = model(h, ["a.txt"])
        await m.load()
        let asked = Recorder<String>()
        m.confirm = { confirmation in
            if case .rename(.extensionChanged(let from, let to)) = confirmation { asked.values.append("\(from)>\(to)") }
            return false
        }
        m.nameDraft = "a.md"
        let ok = await m.commitName()
        XCTAssertFalse(ok)
        XCTAssertEqual(asked.values, ["txt>md"])
        XCTAssertEqual(m.nameDraft, "a.txt", "declining reverts the field")
        XCTAssertTrue(h.exists("a.txt"))
    }

    func testMultipleSelectionUsesTriStateAttributes() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt", bytes: 3)
        try h.file("b.txt", bytes: 4)
        try h.setFlags("b.txt", UF_HIDDEN)
        let m = model(h, ["a.txt", "b.txt"])
        await m.load()
        let before = try XCTUnwrap(multi(m))
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before.files, 2)
        XCTAssertEqual(before.folders, 0)
        XCTAssertEqual(before.hidden, .mixed)
        XCTAssertEqual(before.locked, .off)
        XCTAssertEqual(m.title, "2 Items Properties")
        XCTAssertFalse(m.showsOpensWith, "§5.8: no Opens with for a multiple selection")
        await m.setHidden(before.hidden.afterClick)
        XCTAssertEqual(flags(h, "a.txt").map { $0 & UInt32(UF_HIDDEN) != 0 }, true)
        XCTAssertEqual(flags(h, "b.txt").map { $0 & UInt32(UF_HIDDEN) != 0 }, true)
        XCTAssertEqual(multi(m)?.hidden, .on)
    }

    func testPermissionPopupsWriteModeBits() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.setMode("a.txt", 0o644)
        let m = model(h, ["a.txt"])
        await m.load()
        await m.setAccess(.noAccess, for: .everyone)
        XCTAssertEqual(mode(h, "a.txt"), 0o640)
        await m.setAccess(.readWrite, for: .group)
        XCTAssertEqual(mode(h, "a.txt"), 0o660)
        XCTAssertEqual(item(m).map { PermissionModel.access($0.mode, .group) }, .readWrite)
        XCTAssertNil(m.inlineError)
    }

    func testApplyToEnclosedConfirmsThenRunsChmodRecursive() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("F/sub")
        try h.setMode("F", 0o750)
        try h.setMode("F/sub", 0o755)
        let m = model(h, ["F"])
        await m.load()
        let asked = Recorder<String>()
        m.confirm = { confirmation in
            if case .applyToEnclosed(let name) = confirmation { asked.values.append(name) }
            return false
        }
        await m.applyPermissionsToEnclosed()
        XCTAssertEqual(asked.values, ["F"])
        XCTAssertEqual(mode(h, "F/sub"), 0o755, "declined: nothing changes")
        m.confirm = { _ in true }
        await m.applyPermissionsToEnclosed()
        XCTAssertEqual(mode(h, "F/sub"), 0o750)
        try await h.waitUntil("undoable") { h.environment.undo.canUndo }
        m.close()
    }

    func testRemoveQuarantineDeletesTheXattr() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("q.txt")
        try h.sandbox.setXattr("files/q.txt", name: "com.apple.quarantine", value: Data("0081;65f0c3a1;Safari;".utf8))
        let m = model(h, ["q.txt"])
        await m.load()
        XCTAssertNotNil(item(m)?.quarantine)
        await m.removeQuarantine()
        XCTAssertEqual(getxattr(h.url("q.txt").path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), -1)
        XCTAssertNil(item(m)?.quarantine)
        XCTAssertNil(m.inlineError)
    }

    func testVolumeSubjectShowsCapacityAndUsage() async throws {
        let h = try await ContentTestHarness.make(self)
        let volume = try XCTUnwrap(h.environment.volumes.volume(for: h.filesRoot))
        let m = PropertiesViewModel(subject: .volume(volume), environment: h.environment)
        await m.load()                                   // reads capacity only; S5-C8: nothing is ejected
        guard case .volume(let properties) = m.content else { return XCTFail("volume content expected") }
        XCTAssertEqual(properties.volume.id, volume.id)
        XCTAssertGreaterThan(properties.capacity ?? 0, 0)
        let usage = try XCTUnwrap(PropertiesFormat.usage(capacity: properties.capacity, available: properties.available))
        XCTAssertTrue((0...1).contains(usage))
        XCTAssertEqual(m.title, "\(volume.name) Properties")
        XCTAssertFalse(m.showsOpensWith)
    }

    func testChangeDefaultSetsDefaultsWithoutOpening() async throws {
        let h = try await ContentTestHarness.make(self)
        let fake = FakeLaunchServices()
        let app = h.url("Fake.app")                      // URLs only: the fake records, nothing is touched
        let file = h.url("x.txt")
        try await DefaultAppChoice.setDefault(app: app, file: file, allOfType: false, provider: fake)
        XCTAssertEqual(fake.defaultsSet().map(\.forType), [false], "Change…: this file only")
        try await DefaultAppChoice.setDefault(app: app, file: file, allOfType: true, provider: fake)
        XCTAssertEqual(fake.defaultsSet().map(\.forType), [false, true, false], "Change All…: type, then the per-file override")
        XCTAssertTrue(fake.opened().isEmpty, "Properties never opens the file")
    }

    func testPropertiesSubjectForEveryCommandTarget() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.file("b.txt")
        let folder = try await h.openFolder()
        let volume = try XCTUnwrap(h.environment.volumes.volume(for: h.filesRoot))
        let volumes = h.environment.volumes.list
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .contentSelection(folder), volumes: volumes),
                       .items([folder.directory]), "nothing selected: the current folder")
        folder.select(.names(["a.txt", "b.txt"]))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .contentSelection(folder), volumes: volumes),
                       .items(folder.selectedURLs))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .currentFolder(folder), volumes: volumes), .items([folder.directory]))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .folder(h.url("a.txt")), volumes: volumes), .items([h.url("a.txt")]))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .volume(volume), volumes: volumes), .volume(volume))
        XCTAssertEqual(FileCommandController.propertiesSubject(for: .folder(volume.mountPoint), volumes: volumes), .volume(volume),
                       "a volume root shows volume properties")
        XCTAssertFalse(FileCommandController.pendingCommands.contains(.properties))
    }

    func testJobErrorTextCoversTheErrorTable() {
        XCTAssertEqual(ErrorText.jobError(.permissionDenied, name: "a.txt", verb: .copying), "You don't have permission to copy 'a.txt'.")
        XCTAssertEqual(ErrorText.jobError(.permissionDenied, name: "a.txt"), "You don't have permission to change 'a.txt'.")
        XCTAssertEqual(ErrorText.jobError(.blockedByMacOS, name: "a.txt"), "macOS is blocking access to 'a.txt'.")
        XCTAssertEqual(ErrorText.jobError(.locked, name: "a.txt"), "'a.txt' is locked.")
        XCTAssertEqual(ErrorText.jobError(.readOnlyVolume, name: "a.txt"), "The destination is read-only.")
        XCTAssertEqual(ErrorText.jobError(.noSpace(needed: 2_000_000, available: 1_000_000), name: "a.txt"),
                       "Not enough space (needs 2 MB, 1 MB available).")
        XCTAssertEqual(ErrorText.jobError(.noSpace(needed: nil, available: nil), name: "a.txt"), "Not enough space on the destination.")
        XCTAssertEqual(ErrorText.jobError(.inUse, name: "a.txt"), "'a.txt' is in use by another app.")
        XCTAssertEqual(ErrorText.jobError(.nameTooLong, name: "a.txt"), "The name 'a.txt' is too long for the destination.")
        XCTAssertEqual(ErrorText.jobError(.sourceGone, name: "a.txt"), "'a.txt' no longer exists.")
        XCTAssertEqual(ErrorText.jobError(.intoItself, name: "A"), "'A' can't be moved or copied into itself.")
        XCTAssertEqual(ErrorText.jobError(.noTrash, name: "a.txt"), "'a.txt' can't be moved to the Trash.")
        XCTAssertEqual(ErrorText.jobError(.other(code: 5, message: "Input/output error"), name: "a.txt"),
                       "An error occurred with 'a.txt': Input/output error (error 5).")
    }

    func testFormattingAndTriStateClicks() {
        XCTAssertEqual(PropertiesFormat.size(1_234_567, locale: en), "1.2 MB (1,234,567 bytes)")
        XCTAssertEqual(PropertiesFormat.size(nil, locale: en), "--")
        XCTAssertEqual(PropertiesFormat.contains(files: 1_204, folders: 3, finished: false, locale: en), "Counting… 1,204 files, 3 folders")
        XCTAssertEqual(PropertiesFormat.contains(files: 1_204, folders: 3, finished: true, locale: en), "1,204 files, 3 folders")
        XCTAssertEqual(PropertiesFormat.items(count: 3, files: 2, folders: 1, locale: en), "3 items (2 files, 1 folders)")
        XCTAssertEqual(PropertiesFormat.access(.readWrite), "Read & Write")
        XCTAssertEqual(PropertiesFormat.who(.owner, owner: "me", group: "staff"), "Owner (me)")
        XCTAssertEqual(PropertiesFormat.usage(capacity: 100, available: 25), 0.75)
        XCTAssertNil(PropertiesFormat.usage(capacity: nil, available: 25))
        XCTAssertTrue(Tri.mixed.afterClick)
        XCTAssertTrue(Tri.off.afterClick)
        XCTAssertFalse(Tri.on.afterClick)
        XCTAssertEqual(Tri(true), .on)
        XCTAssertNil(PropertiesViewModel.permissionsNote(isOwner: true))
        XCTAssertEqual(PropertiesViewModel.permissionsNote(isOwner: false), "You can't change permissions because you aren't the owner.")
    }

    func testOneWindowPerSelectionSetAndUndoRouting() async throws {
        try ContentTestHarness.requireWindowServer()
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        try h.file("b.txt")
        let a = h.url("a.txt"), b = h.url("b.txt")
        let one = try XCTUnwrap(PropertiesWindowController.controller(for: .items([a]), context: h.context, activate: false))
        let again = PropertiesWindowController.controller(for: .items([a]), context: h.context, activate: false)
        XCTAssertTrue(one === again, "§5.8: a second invocation focuses the existing window")
        let pair = PropertiesWindowController.controller(for: .items([a, b]), context: h.context, activate: false)
        let pairReversed = PropertiesWindowController.controller(for: .items([b, a]), context: h.context, activate: false)
        XCTAssertTrue(pair === pairReversed, "the selection set, not its order, identifies the window")
        XCTAssertFalse(pair === one)
        XCTAssertEqual(PropertiesWindowController.openControllers(for: h.context).count, 2)
        let window = try XCTUnwrap(one.window)
        XCTAssertEqual(window.identifier?.rawValue, AXID.propertiesWindow)
        XCTAssertFalse(window.isVisible, "tests never order Properties windows front (S5-C7)")
        XCTAssertTrue(one.windowWillReturnUndoManager(window) === h.environment.undo.undoManager, "§6.6: one app-wide stack")
        XCTAssertTrue(PropertiesWindowController.answersErrorsInline(OriginID(raw: window.windowNumber)))
        try await h.waitUntil("loaded") { one.model.content != .loading }
        one.close()
        XCTAssertEqual(PropertiesWindowController.openControllers(for: h.context).count, 1)
        XCTAssertFalse(PropertiesWindowController.answersErrorsInline(OriginID(raw: window.windowNumber)))
    }
}
