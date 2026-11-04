import XCTest
import AppKit
import Darwin
@testable import UI
import Core
import MacxFS

@MainActor
final class InlineRenameTests: XCTestCase {
    // MARK: helpers

    private func controller(_ content: ContentViewController) throws -> InlineRenameController {
        try XCTUnwrap((content.activeList as? InlineRenameHost)?.renameController)
    }

    /// Non-recording lookup for polling (XCTUnwrap records a failure even under `try?`).
    private func current(_ content: ContentViewController) -> InlineRenameController? {
        (content.activeList as? InlineRenameHost)?.renameController
    }

    private func editor(_ controller: InlineRenameController) throws -> NSTextView {
        try XCTUnwrap(controller.field?.currentEditor() as? NSTextView)
    }

    private func type(_ text: String, _ controller: InlineRenameController) throws {
        let editor = try editor(controller)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func send(_ selector: Selector, _ controller: InlineRenameController) throws {
        let field = try XCTUnwrap(controller.field)
        _ = controller.control(field, textView: try editor(controller), doCommandBy: selector)
    }

    private func beginRename(_ content: ContentViewController, _ name: String) throws -> InlineRenameController {
        let row = try XCTUnwrap(content.session.folder.row(named: name))
        content.activeList.beginInlineRename(row: row)
        return try controller(content)
    }

    // MARK: pure

    func testRenameProblemTexts() {
        XCTAssertEqual(ErrorText.renameProblem(.empty, name: ""), "A name can't be empty.")
        XCTAssertEqual(ErrorText.renameProblem(.containsSlash, name: "a/b"), "A name can't contain '/'.")
        XCTAssertEqual(ErrorText.renameProblem(.tooLong, name: "x"), "The name is too long.")
        XCTAssertEqual(ErrorText.renameProblem(.duplicate, name: "b.txt"), "The name 'b.txt' is already taken.")
        XCTAssertEqual(ErrorText.renameProblem(.reserved, name: ".."), "'..' is not a valid name.")
    }

    // MARK: AppKit

    func testF2SelectsBaseNameAndCommitRenames() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let (content, session, _) = try await h.makeContent()
        let rename = try beginRename(content, "a.txt")
        XCTAssertTrue(rename.isEditing)
        XCTAssertEqual(rename.currentText, "a.txt")
        XCTAssertEqual(try editor(rename).selectedRange(), NSRange(location: 0, length: 1))
        XCTAssertEqual(rename.field?.accessibilityIdentifier(), AXID.renameField)
        try type("c.txt", rename)
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("renamed on disk") { h.exists("c.txt") && !h.exists("a.txt") }
        try await h.waitUntil("selection follows the rename") { session.folder.selectedURLs.map(\.lastPathComponent) == ["c.txt"] }
        XCTAssertFalse(rename.isEditing)
    }

    func testTabCommitsAndMovesToNext() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["a.txt", "b.txt", "c.txt"] { try h.file(name) }
        let (content, _, _) = try await h.makeContent()
        let first = try beginRename(content, "a.txt")
        try type("a1.txt", first)
        try send(#selector(NSResponder.insertTab(_:)), first)
        try await h.waitUntil("a renamed") { h.exists("a1.txt") }
        try await h.waitUntil("editing the next item") { self.current(content)?.currentText == "b.txt" }
        let second = try controller(content)
        try send(#selector(NSResponder.insertBacktab(_:)), second)
        try await h.waitUntil("back to the previous item") { self.current(content)?.currentText == "a1.txt" }
    }

    func testEscapeCancels() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, _, _) = try await h.makeContent()
        let rename = try beginRename(content, "a.txt")
        try type("zzz.txt", rename)
        try send(#selector(NSResponder.cancelOperation(_:)), rename)
        XCTAssertFalse(rename.isEditing)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(h.exists("a.txt"))
        XCTAssertFalse(h.exists("zzz.txt"))
    }

    func testInvalidNamesKeepEditing() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, _, _) = try await h.makeContent()
        let rename = try beginRename(content, "a.txt")
        for (text, message) in [("", "A name can't be empty."), ("x/y", "A name can't contain '/'."),
                                (String(repeating: "é", count: 128) + ".txt", "The name is too long.")] {
            try type(text, rename)
            try send(#selector(NSResponder.insertNewline(_:)), rename)
            XCTAssertTrue(rename.isEditing, text)
            XCTAssertEqual(rename.errorText, message)
        }
        XCTAssertTrue(h.exists("a.txt"))
    }

    /// Overview Review Focus 2: the duplicate check sees hidden entries even with Show Hidden off.
    func testInlineRenameRejectsNameOfHiddenItem() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("notes.txt"); try h.file(".env")
        try h.setFlags("notes.txt", UF_HIDDEN)
        h.environment.settings.showHidden = false
        let (content, session, _) = try await h.makeContent()
        XCTAssertNil(session.folder.row(named: "notes.txt"), "the hidden item is not displayed")
        let rename = try beginRename(content, "a.txt")
        for taken in ["notes.txt", ".env"] {
            try type(taken, rename)
            try send(#selector(NSResponder.insertNewline(_:)), rename)
            XCTAssertTrue(rename.isEditing)
            XCTAssertEqual(rename.errorText, "The name '\(taken)' is already taken.")
        }
        if !session.folder.caseSensitive {
            try type("NOTES.TXT", rename)
            try send(#selector(NSResponder.insertNewline(_:)), rename)
            XCTAssertEqual(rename.errorText, "The name 'NOTES.TXT' is already taken.")
        }
        XCTAssertTrue(h.exists("a.txt"))
        XCTAssertTrue(h.environment.operations.jobs.isEmpty, "no rename job was enqueued")
    }

    func testExtensionChangeAsksAndRespectsAnswer() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, _, _) = try await h.makeContent()
        let rename = try beginRename(content, "a.txt")
        var asked: [RenamePrompt] = []
        final class Answer { var value = false }
        let answer = Answer()
        rename.confirm = { prompt, _ in asked.append(prompt); return answer.value }
        try type("a.md", rename)
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("asked") { asked == [.extensionChanged(from: "txt", to: "md")] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(rename.isEditing, "declining keeps editing")
        XCTAssertTrue(h.exists("a.txt"))
        answer.value = true
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("renamed") { h.exists("a.md") }
    }

    func testLeadingDotWarnsHidden() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("b.txt")
        let (content, _, _) = try await h.makeContent()
        let rename = try beginRename(content, "b.txt")
        var asked: [RenamePrompt] = []
        rename.confirm = { prompt, _ in asked.append(prompt); return true }
        try type(".b.txt", rename)
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("renamed to a dot name") { h.exists(".b.txt") }
        XCTAssertEqual(asked, [.becomesHidden])
    }

    func testNewItemBeginsRenameWithWholeNameSelected() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, session, _) = try await h.makeContent()
        try h.dir("New Folder")
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), added: ["New Folder"], select: ["New Folder"],
                                                    beginRename: "New Folder"))
        try await h.waitUntil("rename began") { self.current(content)?.currentText == "New Folder" }
        XCTAssertEqual(try editor(try controller(content)).selectedRange(), NSRange(location: 0, length: 10))
    }

    /// Slice Review Focus 2: the field follows its item by identity.
    func testRenameFieldFollowsItemWhenRowsInsertedAbove() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("m.txt"); try h.file("x.txt")
        let (content, session, _) = try await h.makeContent()
        let rename = try beginRename(content, "m.txt")
        try type("mm.txt", rename)
        try h.file("a.txt")
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), added: ["a.txt"]))
        try await h.waitUntil("row inserted above") { session.folder.row(named: "m.txt") == 1 }
        let host = try XCTUnwrap(content.activeList as? InlineRenameHost)
        XCTAssertEqual(rename.field?.frame, host.renameFieldFrame(forRow: 1))
        XCTAssertTrue(rename.isEditing)
        XCTAssertEqual(rename.currentText, "mm.txt")
    }

    /// A rename of the editing item that lands after the field opened (the patch is async) refreshes an untouched
    /// field, so a commit never acts on a stale name.
    func testUntouchedFieldPicksUpLateRenameOfItsItem() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("m.txt"); try h.file("x.txt")
        let (content, session, _) = try await h.makeContent()
        let rename = try beginRename(content, "m.txt")
        try FileManager.default.moveItem(at: h.url("m.txt"), to: h.url("n.txt"))
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), renamed: [.init(from: "m.txt", to: "n.txt")]))
        try await h.waitUntil("field shows the new name or closed") { !rename.isEditing || rename.currentText == "n.txt" }
        XCTAssertTrue(rename.isEditing, "the item keeps its identity across the rename")
        XCTAssertEqual(rename.currentText, "n.txt")
        XCTAssertEqual(try editor(rename).selectedRange(), NSRange(location: 0, length: 1))
    }

    func testEditedFieldKeepsTextWhenItsItemIsRenamed() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("m.txt"); try h.file("x.txt")
        let (content, session, _) = try await h.makeContent()
        let rename = try beginRename(content, "m.txt")
        try type("typed.txt", rename)
        try FileManager.default.moveItem(at: h.url("m.txt"), to: h.url("n.txt"))
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), renamed: [.init(from: "m.txt", to: "n.txt")]))
        try await h.waitUntil("model shows the new name") { session.folder.row(named: "n.txt") != nil }
        XCTAssertEqual(rename.currentText, "typed.txt")
        try type("n.txt", rename)
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        XCTAssertFalse(rename.isEditing, "unchanged against the item's current name closes without a job")
        XCTAssertTrue(h.environment.operations.jobs.isEmpty)
    }

    func testRenameCancelsWhenItemDeletedExternally() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("m.txt"); try h.file("x.txt")
        let (content, session, _) = try await h.makeContent()
        let rename = try beginRename(content, "m.txt")
        try type("mm.txt", rename)
        try FileManager.default.removeItem(at: h.url("m.txt"))
        session.folder.applyLocalChange(LocalChange(directory: h.url(""), removed: ["m.txt"]))
        try await h.waitUntil("rename closed") { !rename.isEditing }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(h.exists("mm.txt"))
    }

    func testFieldEditorGetsPerEditUndoManager() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let browser = try await h.openBrowserWindow()
        let window = try XCTUnwrap(browser.window)
        let content = try h.content(of: browser)
        XCTAssertTrue(window.undoManager === h.environment.undo.undoManager)
        let rename = try beginRename(content, "a.txt")
        XCTAssertFalse(window.undoManager === h.environment.undo.undoManager,
                       "typing undo never mixes with file-operation undo (§6.6)")
        try send(#selector(NSResponder.cancelOperation(_:)), rename)
        XCTAssertTrue(window.undoManager === h.environment.undo.undoManager)
    }

    func testIconsViewRenamesToo() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let (content, _, _) = try await h.makeContent()
        content.setViewMode(.icons)
        let rename = try beginRename(content, "a.txt")
        XCTAssertTrue(rename.field?.superview === content.icons?.collectionView)
        try type("b.txt", rename)
        try send(#selector(NSResponder.insertNewline(_:)), rename)
        try await h.waitUntil("renamed from icons") { h.exists("b.txt") }
    }

    func testScenarioRenameTextHook() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let browser = try await h.openBrowserWindow()
        let rename = try beginRename(try h.content(of: browser), "a.txt")
        XCTAssertEqual(browser.probeRenameText, "a.txt")
        try send(#selector(NSResponder.cancelOperation(_:)), rename)
        XCTAssertNil(browser.probeRenameText)
    }

    // MARK: QA round 1: ⌘Z while renaming belongs to the field editor (§6.6)

    func testUndoWhileRenamingUndoesTheTypingNotTheLastFileOperation() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("b.txt")
        let controller = try await h.openBrowserWindow()
        let content = try h.content(of: controller)
        let folder = controller.session.folder
        let a = try XCTUnwrap(folder.row(named: "a.txt"))
        folder.select(.set(IndexSet(integer: a), cursor: a))
        content.handler?.perform(.moveToTrash, target: .contentSelection(folder), sender: nil)
        try await h.waitUntil("a.txt trashed") { !h.exists("a.txt") && h.environment.undo.canUndo }
        try await h.waitUntil("a.txt gone from the list") { folder.row(named: "a.txt") == nil }
        let rename = try beginRename(content, "b.txt")
        let editor = try editor(rename)
        XCTAssertTrue(controller.window?.firstResponder === editor)
        XCTAssertFalse(content.responds(to: NSSelectorFromString("undo:")), "the window's undo: (field editor manager) decides")
        XCTAssertFalse(content.responds(to: NSSelectorFromString("redo:")))
        XCTAssertTrue(editor.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(h.exists("a.txt"), "responder chain: the trash was not undone while typing")
        content.handler?.perform(.undo, target: .contentSelection(folder), sender: nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(h.exists("a.txt"), "command handler: the trash was not undone while typing")
        XCTAssertTrue(h.environment.undo.canUndo)
        try type("q.txt", rename)
        XCTAssertEqual(rename.currentText, "q.txt")
        XCTAssertTrue(editor.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        XCTAssertEqual(rename.currentText, "b.txt", "the typing is undone")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(h.exists("a.txt"))
        rename.cancel()
        XCTAssertTrue(content.responds(to: NSSelectorFromString("undo:")))
    }
}
