// Tests/UITests/ACLEditorTests.swift
import XCTest
import AppKit
import SwiftUI
@testable import UI
@testable import Core
import MacxFS

/// P4-18: the ACL editor in Properties › Permissions. Every file lives in the harness sandbox (HARD RULE).
@MainActor
final class ACLEditorTests: XCTestCase {
    private func read(_ u: URL, _ ui: ContentTestHarness) async throws -> [ACLEntry] {
        try await ui.environment.lanes.perform(on: .unknown) { _ in try ACLIO.read(u) }
    }

    private func editor(_ url: URL, _ ui: ContentTestHarness, isDirectory: Bool = false, isEditable: Bool = true) -> ACLEditorModel {
        let model = ACLEditorModel(url: url, isDirectory: isDirectory, isEditable: isEditable, environment: ui.environment)
        addTeardownBlock { @MainActor in model.close() }
        return model
    }

    func testSummaries() {
        XCTAssertEqual(ACLPermissionSummary.summary(.readOnlyPreset), .readOnly)
        XCTAssertEqual(ACLPermissionSummary.summary(.readWritePreset), .readWrite)
        XCTAssertEqual(ACLPermissionSummary.summary(.fullControlPreset), .fullControl)
        XCTAssertEqual(ACLPermissionSummary.summary([.readData, .delete]), .custom)
        XCTAssertEqual(ACLPermissionSummary.readOnly.title, "Read only")
        XCTAssertEqual(ACLPermissionSummary.readWrite.title, "Read & Write")
        XCTAssertEqual(ACLPermissionSummary.fullControl.title, "Full Control")
        XCTAssertEqual(ACLPermissionSummary.custom.title, "Custom")  // key "acl.access.custom"
        XCTAssertEqual(ACLPermissionSummary.readWrite.permissions, .readWritePreset)
        XCTAssertNil(ACLPermissionSummary.custom.permissions)
    }

    func testAppliesToDescribesInheritance() {
        XCTAssertEqual(ACLAppliesTo.text([]), "This folder only")
        XCTAssertEqual(ACLAppliesTo.text([.fileInherit, .directoryInherit]), "This folder, subfolders and files")
        XCTAssertEqual(ACLAppliesTo.text([.directoryInherit]), "This folder and subfolders")
        XCTAssertEqual(ACLAppliesTo.text([.fileInherit]), "This folder and files")
        XCTAssertEqual(ACLAppliesTo.text([.fileInherit, .directoryInherit, .onlyInherit]), "Subfolders and files only")
        XCTAssertEqual(ACLAppliesTo.text([.fileInherit, .onlyInherit]), "Files only")
        XCTAssertEqual(ACLAppliesTo.text([.directoryInherit, .limitInherit]), "This folder and subfolders (one level)")
    }

    func testDraftPresetsAndCustomPermissions() {
        var draft = ACLEntryDraft(ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset))
        XCTAssertEqual(draft.preset, .readOnly)
        draft.preset = .fullControl
        XCTAssertEqual(draft.entry.permissions, .fullControlPreset)
        draft.set(.changeOwner, false)
        XCTAssertEqual(draft.preset, .custom)
        XCTAssertFalse(draft.entry.permissions.contains(.changeOwner))
        draft.preset = .custom                                             // keeps the checkboxes as they are
        XCTAssertEqual(draft.entry.permissions, ACLPermissions.fullControlPreset.subtracting(.changeOwner))
        draft.set(.onlyInherit, true)
        XCTAssertEqual(draft.entry.inheritance, [.onlyInherit])
        XCTAssertEqual(ACLEntryDraft.permissionRows.count, 13, "the Custom… disclosure has one checkbox per permission")
        XCTAssertEqual(Set(ACLEntryDraft.permissionRows.map(\.permission)).count, 13)
    }

    func testAddReplaceRemoveRunUndoableJobs() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let model = editor(a, ui)
        await model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.entries, [])
        let everyoneRead = ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset)
        await model.add(everyoneRead)
        XCTAssertNil(model.error)
        let afterAdd = try await read(a, ui)
        XCTAssertEqual(afterAdd, [everyoneRead])
        XCTAssertTrue(ui.environment.undo.canUndo)
        let deny = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete])
        await model.add(deny)
        XCTAssertEqual(model.entries, [deny, everyoneRead], "canonical order after reload")
        await model.replace(at: 1, with: ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readWritePreset))
        let afterReplace = try await read(a, ui)
        XCTAssertEqual(afterReplace.last?.permissions, .readWritePreset)
        await model.remove(at: 0)
        let afterRemove = try await read(a, ui)
        XCTAssertEqual(afterRemove.count, 1)
        XCTAssertEqual(model.entries.count, 1)
        // Each edit is its own undo entry: undoing the removal brings the deny entry back, nothing else.
        ui.environment.undo.undoManager.undo()
        try await ui.waitUntil("undo registered its redo") { ui.environment.undo.canRedo }
        var afterUndo = try await read(a, ui)
        let deadline = ContinuousClock.now + .seconds(30)
        while afterUndo.count != 2, ContinuousClock.now < deadline {             // the undo job runs on the queue
            try await Task.sleep(for: .milliseconds(20))
            afterUndo = try await read(a, ui)
        }
        XCTAssertEqual(afterUndo.count, 2)
        XCTAssertEqual(afterUndo.first?.kind, .deny)
    }

    /// Review finding: "deny everyone Read only" denied the owner readsecurity, hid the ACL and broke undo.
    func testDenyThatWouldLockTheUserOutIsRefused() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let model = editor(a, ui)
        await model.load()
        let lockout = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset)
        let locksOut = await model.wouldLockOut(lockout)
        XCTAssertTrue(locksOut)
        let harmless = await model.wouldLockOut(ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete]))
        XCTAssertFalse(harmless)
        await model.add(lockout)
        XCTAssertNotNil(model.error, "explains why the entry wasn't added")
        let after = try await read(a, ui)
        XCTAssertEqual(after, [])
        XCTAssertFalse(ui.environment.undo.canUndo)
        // Replacing an existing entry with one that locks the user out is refused too.
        let deny = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete])
        await model.add(deny)
        XCTAssertNil(model.error)
        await model.replace(at: 0, with: ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete, .writeSecurity]))
        XCTAssertNotNil(model.error)
        let afterReplace = try await read(a, ui)
        XCTAssertEqual(afterReplace, [deny])
    }

    func testUnreadableACLShowsAnErrorNotAnEmptyTable() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let lock = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.readSecurity])
        try await ui.environment.lanes.perform(on: .unknown) { _ in try ACLIO.write(explicit: [lock], to: a) }
        let model = editor(a, ui)
        await model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(model.readError, "You can't read the access list of “a.txt”.")
        XCTAssertFalse(model.canAdd, "an unreadable list isn't shown as an empty, editable one")
    }

    func testInheritedRowsAreReadOnly() async throws {
        let ui = try await ContentTestHarness.make(self)
        let d = try ui.dir("d")
        try await ui.environment.lanes.perform(on: .unknown) { _ in
            try ACLIO.write(explicit: [ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset,
                                                inheritance: [.fileInherit])], to: d)
        }
        let child = try ui.file("d/c.txt")
        let model = editor(child, ui)
        await model.load()
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.isInherited, true)
        XCTAssertFalse(model.canEdit(row: 0))
        await model.remove(at: 0)                                         // ignored
        await model.replace(at: 0, with: ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.readData]))
        let after = try await read(child, ui)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.kind, .allow)
        // Adding an explicit entry keeps the inherited one after it.
        let deny = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete])
        await model.add(deny)
        XCTAssertEqual(model.entries.map(\.isInherited), [false, true])
        XCTAssertTrue(model.canEdit(row: 0))
    }

    /// No helper in Phase 4 (moved to Phase 6): an item the user can't change shows its ACL read-only.
    func testNotEditableShowsEntriesButIgnoresEdits() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let existing = ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset)
        try await ui.environment.lanes.perform(on: .unknown) { _ in try ACLIO.write(explicit: [existing], to: a) }
        let model = editor(a, ui, isEditable: false)
        await model.load()
        XCTAssertEqual(model.entries, [existing])
        XCTAssertFalse(model.canEdit(row: 0))
        XCTAssertFalse(model.canAdd)
        await model.add(ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete]))
        await model.remove(at: 0)
        let after = try await read(a, ui)
        XCTAssertEqual(after, [existing])
        XCTAssertFalse(ui.environment.undo.canUndo, "no job ran")
    }

    func testRequestCarriesExplicitEntriesAndOrigin() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let model = editor(a, ui)
        model.origin = { OriginID(raw: 42) }
        let list = [ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: [.readData])]
        let request = model.request(for: list)
        XCTAssertEqual(request.kind, .setAttributes([a], .acl(list)))
        XCTAssertEqual(request.origin, OriginID(raw: 42))
        XCTAssertEqual(UndoActionNames.name(for: request.kind.jobDescription), "Change Access")
        XCTAssertEqual(JobTitle.title(request.kind.jobDescription), "Changing access of 'a.txt'")
    }

    /// A failed edit shows the error inline and the table shows what is on disk.
    func testFailedEditShowsInlineErrorAndReloads() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let model = editor(a, ui)
        await model.load()
        let skipped = Box<JobRequest>()
        model.perform = { request in
            skipped.values.append(request)
            return JobOutcome(record: JobRecord(id: JobID(), verb: request.kind.verb, actions: []),
                              skipped: [SkippedItem(url: a, reason: .permissionDenied)], wasCancelled: false, created: [],
                              localChanges: [])
        }
        await model.add(ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: [.readData]))
        XCTAssertEqual(skipped.values.count, 1)
        XCTAssertEqual(model.error, "You don't have permission to change the access of 'a.txt'.")
        XCTAssertEqual(model.entries, [], "reloaded from disk")
    }

    func testPrincipalsLoadOnceAndFilter() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let model = editor(a, ui)
        await model.loadPrincipals()
        XCTAssertTrue(model.principals.contains(PrincipalDirectory.everyone))
        XCTAssertEqual(ACLEditorModel.filter(model.principals, "EVERY"), [PrincipalDirectory.everyone])
        XCTAssertEqual(ACLEditorModel.filter(model.principals, "").count, model.principals.count)
    }

    /// The table renders a folder's rows with the Applies To column; files get three columns.
    func testTableRendersRowsAndFolderOnlyColumn() async throws {
        try ContentTestHarness.requireWindowServer()
        let ui = try await ContentTestHarness.make(self)
        let parent = try ui.dir("p")
        try await ui.environment.lanes.perform(on: .unknown) { _ in
            try ACLIO.write(explicit: [ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset,
                                                inheritance: [.directoryInherit])], to: parent)
        }
        let child = try ui.dir("p/c")
        let model = editor(child, ui, isDirectory: true)
        await model.load()
        await model.add(ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete]))
        XCTAssertEqual(model.entries.map(\.isInherited), [false, true])
        let host = NSHostingView(rootView: ACLEditorView(model: model).frame(width: 420))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var table: NSTableView?
        try await ui.waitUntil("rows rendered") {
            host.layoutSubtreeIfNeeded()
            table = Self.tables(in: host).first
            return table?.numberOfRows == 2
        }
        let rendered = try XCTUnwrap(table)
        XCTAssertEqual(rendered.tableColumns.map(\.title), ["Name", "Type", "Access", "Applies To"])
        // A file has no Applies To column.
        let file = try ui.file("f.txt")
        let fileModel = editor(file, ui)
        await fileModel.load()
        let fileHost = NSHostingView(rootView: ACLEditorView(model: fileModel).frame(width: 420))
        fileHost.frame = host.frame
        window.contentView = fileHost
        var fileTable: NSTableView?
        try await ui.waitUntil("file table laid out") {
            fileHost.layoutSubtreeIfNeeded()
            fileTable = Self.tables(in: fileHost).first
            return fileTable != nil
        }
        XCTAssertEqual(fileTable?.tableColumns.map(\.title), ["Name", "Type", "Access"])
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    func testPropertiesModelBuildsTheEditorForOneItemOwnedByTheUser() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt"); try ui.file("b.txt")
        let one = PropertiesViewModel(subject: .items([ui.url("a.txt").standardizedFileURL]), environment: ui.environment)
        await one.load()
        let acl = try XCTUnwrap(one.acl)
        XCTAssertTrue(acl.isEditable, "the test user owns its sandbox files")
        XCTAssertTrue(acl.isLoaded)
        await acl.add(ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset))
        // Undo from elsewhere (Edit › Undo) reaches the table through the window's reload.
        ui.environment.undo.undoManager.undo()
        try await ui.waitUntil("table follows undo") { one.acl?.entries.isEmpty == true }
        one.close()
        let many = PropertiesViewModel(subject: .items(["a.txt", "b.txt"].map { ui.url($0).standardizedFileURL }),
                                       environment: ui.environment)
        await many.load()
        XCTAssertNil(many.acl, "access control is edited one item at a time")
        many.close()
    }
}

/// Collects values from escaping main-actor closures.
@MainActor
private final class Box<Value> {
    var values: [Value] = []
}
