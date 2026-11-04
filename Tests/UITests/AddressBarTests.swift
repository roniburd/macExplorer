import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class AddressBarTests: XCTestCase {
    private func path(_ url: URL) -> String { BreadcrumbPath.posixPath(url) }

    private func editor(_ controller: BrowserWindowController) throws -> NSTextView {
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        return editor
    }

    // MARK: breadcrumb mode and hooks

    func testBreadcrumbModeIsTheDefaultAndHooksAreInstalled() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        XCTAssertEqual(bar.accessibilityIdentifier(), AXID.addressBar)
        XCTAssertEqual(bar.editField.accessibilityIdentifier(), AXID.addressField)
        XCTAssertFalse(bar.isEditing)
        XCTAssertTrue(bar.editField.isHidden)
        XCTAssertFalse(bar.breadcrumb.isHidden)
        XCTAssertEqual(bar.breadcrumb.segmentButtons.last?.title, "files")
        XCTAssertNotNil(controller.scenarioHooks.addressText)
        XCTAssertNotNil(controller.scenarioHooks.isEditingAddress)
        XCTAssertFalse(controller.probeIsEditingAddress)
        XCTAssertTrue(controller.probeAddressText.hasSuffix("› files"), controller.probeAddressText)
    }

    func testBreadcrumbFollowsNavigationAndSegmentClickNavigates() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("a/b")
        let controller = try await h.openWindow("a/b")
        let bar = controller.addressBar
        XCTAssertEqual(Array(bar.breadcrumb.segmentButtons.suffix(3).map(\.title)), ["files", "a", "b"])
        let index = bar.breadcrumb.segmentButtons.count - 2
        bar.breadcrumb.segmentButtons[index].performClick(nil)
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "a")
        XCTAssertEqual(bar.breadcrumb.segmentButtons.last?.title, "a")
        XCTAssertTrue(controller.session.history.canGoBack, "breadcrumb navigation is recorded in history")
    }

    // MARK: edit mode

    func testBeginEditingShowsThePosixPathAllSelected() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        controller.focus(.addressBar)                  // the ⌘L / ⌥D / F4 path
        XCTAssertTrue(bar.isEditing)
        XCTAssertTrue(controller.probeIsEditingAddress)
        XCTAssertFalse(bar.editField.isHidden)
        XCTAssertTrue(bar.breadcrumb.isHidden)
        let text = path(controller.session.folder.directory)
        XCTAssertEqual(bar.editField.stringValue, text)
        XCTAssertFalse(text.hasSuffix("/"))
        let editor = try editor(controller)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(controller.probeFocus, .addressBar)
        XCTAssertEqual(controller.probeAddressText, text)
    }

    func testEnterOnFolderNavigatesAndLeavesEditMode() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("a/b/deep.txt")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        bar.beginEditing()
        let editor = try editor(controller)
        editor.insertText("a/b", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertEqual(bar.editField.stringValue, "a/b")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await h.waitUntil("navigated to a/b") { controller.session.folder.directory.lastPathComponent == "b" }
        XCTAssertFalse(bar.isEditing)
        XCTAssertFalse(controller.probeIsEditingAddress)
        XCTAssertFalse(controller.probeFocus == .addressBar)
        XCTAssertEqual(h.environment.settings.recentLocations.first, path(h.url("a/b")))
    }

    func testEnterOnFileNavigatesToParentAndSelectsIt() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("top.txt"); try h.dir("a/b")
        let controller = try await h.openWindow("a/b")
        let bar = controller.addressBar
        bar.beginEditing()
        await bar.submit("../../top.txt")
        XCTAssertFalse(bar.isEditing)
        XCTAssertEqual(path(controller.session.folder.directory), path(h.url("")))
        try await h.waitUntil("top.txt selected") { controller.probeSelectedNames == ["top.txt"] }
    }

    func testAHiddenFileReportsInlineWhileHiddenItemsAreOff() async throws {
        let h = try await ShellHarness.make(self)
        try h.file("top.txt"); try h.file(".dot")
        h.environment.settings.showHidden = false
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        let before = controller.session.folder
        bar.beginEditing()
        await bar.submit(".dot")
        XCTAssertTrue(bar.isEditing, "nothing could be selected, so the bar says why")
        XCTAssertTrue(controller.session.folder === before)
        XCTAssertEqual(bar.errorText, "'.dot' is hidden (⇧⌘. shows hidden items)")
        h.environment.settings.showHidden = true
        try await h.waitUntil("hidden shown") { controller.session.folder.rowCount == 2 }
        await bar.submit(".dot")
        XCTAssertFalse(bar.isEditing)
        try await h.waitUntil(".dot selected") { controller.probeSelectedNames == [".dot"] }
    }

    func testAbsoluteTildeAndFileURLInput() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("x"); try h.dir("y")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        bar.beginEditing()
        await bar.submit(path(h.url("x")))
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "x")
        // Settings.home is the sandbox root in sandbox mode.
        bar.beginEditing()
        await bar.submit("~/files/y")
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "y")
        bar.beginEditing()
        await bar.submit(h.url("x").absoluteString)
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "x")
    }

    func testMissingPathShowsInlineErrorAndStaysInEditMode() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        let before = controller.session.folder
        bar.beginEditing()
        let editor = try editor(controller)
        editor.insertText("does-not-exist", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await h.waitUntil("inline error") { bar.errorText != nil }
        XCTAssertTrue(bar.isEditing)
        XCTAssertTrue(controller.session.folder === before)
        XCTAssertEqual(bar.errorText, "Can't find 'does-not-exist'")
        XCTAssertFalse(bar.errorLabel.isHidden)
        XCTAssertEqual(bar.editField.stringValue, "does-not-exist")
        XCTAssertEqual(controller.probeFocus, .addressBar, "the field keeps the keyboard")
        editor.insertText("x", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertNil(bar.errorText, "typing clears the error")
        XCTAssertTrue(bar.errorLabel.isHidden)
    }

    func testEscapeRevertsToTheBreadcrumb() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        let before = controller.session.folder
        bar.beginEditing()
        let editor = try editor(controller)
        editor.insertText("sub", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(bar.isEditing)
        XCTAssertTrue(bar.editField.isHidden)
        XCTAssertTrue(controller.session.folder === before, "Esc never navigates")
        XCTAssertNotEqual(controller.probeFocus, .addressBar)
        bar.beginEditing()
        XCTAssertEqual(bar.editField.stringValue, path(before.directory), "re-entering shows the current path again")
    }

    func testLosingFocusEndsEditMode() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        bar.beginEditing()
        controller.focus(.content)
        XCTAssertFalse(bar.isEditing)
    }

    func testResultArrivingAfterCancelIsIgnored() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        let before = controller.session.folder
        bar.beginEditing()
        let pending = Task { await bar.submit("sub") }
        bar.cancelEditing()
        await pending.value
        XCTAssertTrue(controller.session.folder === before, "a resolve that finishes after Esc does not navigate")
        XCTAssertFalse(bar.isEditing)
    }

    // MARK: autocomplete and recents

    func testSuggestionModelBuildsSubfolderCompletionsThenRecents() {
        let items = AddressSuggestions.make(for: "pro/al", subfolders: ["alpha", "alps"], recents: ["/r/alpha", "/r/zz"])
        XCTAssertEqual(items.map(\.title), ["alpha", "alps", "/r/alpha", "/r/zz"])
        XCTAssertEqual(items.map(\.text), ["pro/alpha/", "pro/alps/", "/r/alpha", "/r/zz"])
        XCTAssertEqual(items.map(\.kind), [.subfolder, .subfolder, .recent, .recent])
        let dedup = AddressSuggestions.make(for: "/r/al", subfolders: ["alpha"], recents: ["/r/alpha"])
        XCTAssertEqual(dedup.map(\.text), ["/r/alpha/"], "a recent equal to a completion is not listed twice")
    }

    func testTypingListsSubfoldersAndMatchingRecents() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("alpha"); try h.dir("alps"); try h.dir("beta"); try h.file("alpine.txt")
        h.environment.settings.recentLocations = ["/Library/alpenglow", "/Library/other"]
        let controller = try await h.openWindow()
        let field = controller.addressBar.editField
        controller.addressBar.beginEditing()
        await field.updateSuggestions(for: "al")
        XCTAssertEqual(field.suggestions.map(\.title), ["alpha", "alps", "/Library/alpenglow"])
        XCTAssertTrue(field.isShowingSuggestions)
        await field.updateSuggestions(for: "zzz")
        XCTAssertEqual(field.suggestions, [])
        XCTAssertFalse(field.isShowingSuggestions)
    }

    func testTypingSchedulesDebouncedCompletion() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("alpha")
        let controller = try await h.openWindow()
        let field = controller.addressBar.editField
        controller.addressBar.beginEditing()
        let editor = try editor(controller)
        editor.insertText("alp", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try await h.waitUntil("debounced suggestions") { field.suggestions.map(\.title) == ["alpha"] }
    }

    func testArrowKeysAndEnterAcceptASuggestion() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("alpha"); try h.dir("alps")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        let field = bar.editField
        bar.beginEditing()
        let editor = try editor(controller)
        editor.insertText("al", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        await field.updateSuggestions(for: "al")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(field.selectedSuggestion, 1)
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(field.selectedSuggestion, 0)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await h.waitUntil("navigated to alpha") { controller.session.folder.directory.lastPathComponent == "alpha" }
        XCTAssertFalse(bar.isEditing)
        XCTAssertFalse(field.isShowingSuggestions)
    }

    func testTabCompletesTheSelectedSuggestionAndEscapeClosesTheListFirst() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("alpha")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        let field = bar.editField
        bar.beginEditing()
        let editor = try editor(controller)
        editor.insertText("al", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        await field.updateSuggestions(for: "al")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(field.stringValue, "alpha/")
        XCTAssertTrue(bar.isEditing)
        await field.updateSuggestions(for: "al")
        XCTAssertTrue(field.isShowingSuggestions)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(field.isShowingSuggestions)
        XCTAssertTrue(bar.isEditing, "the first Esc only closes the list")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(bar.isEditing)
    }

    func testANewEditStartsWithoutStaleSuggestions() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("alpha")
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        let field = bar.editField
        bar.beginEditing()
        await field.updateSuggestions(for: "al")
        XCTAssertTrue(field.isShowingSuggestions)
        bar.cancelEditing()
        XCTAssertFalse(field.isShowingSuggestions)
        bar.beginEditing()
        let editor = try editor(controller)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertFalse(field.isShowingSuggestions)
        XCTAssertEqual(field.suggestions, [])
    }

    func testCollidingTextKeysStayInTheField() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let bar = controller.addressBar
        bar.beginEditing()
        let editor = try editor(controller)
        editor.insertText("abc", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.doCommand(by: #selector(NSResponder.moveToBeginningOfDocument(_:)))   // ⌘↑
        editor.insertText("x", replacementRange: editor.selectedRange())
        XCTAssertEqual(bar.editField.stringValue, "xabc")
        XCTAssertTrue(bar.isEditing)
    }

    func testSubmitForTestingMatchesSubmit() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("sub")
        let controller = try await h.openWindow()
        await controller.addressBar.submitForTesting("sub")
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "sub")
    }
}
