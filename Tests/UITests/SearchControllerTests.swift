import XCTest
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class SearchControllerTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    var session: BrowserSession!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        try sandbox.createFile("work/tax.pdf")
        try sandbox.createFile("work/deep/tax-2.pdf")
        env = CoreEnvironment.sandboxed(root: sandbox.root)
        session = BrowserSession(environment: env, initialURL: sandbox.url("work"))
        let shown = session!
        addTeardownBlock { @MainActor in shown.close() }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if condition() { return }
        XCTFail("timed out: \(what)")
    }

    func testThisFolderNameIsInstant() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .seconds(10))
        c.scope = .thisFolder
        c.textDidChange("tax")
        await waitUntil("criteria applied") { session.folder.query.criteria != nil }
        XCTAssertNil(session.results)
    }

    func testSubfoldersDebouncesToOneSearch() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(80))
        c.scope = .subfolders
        var shown: [String] = []
        let token = session.observe { if case .resultsChanged(let m?) = $0 { shown.append(m.title) } }
        defer { token.cancel() }
        for prefix in ["t", "ta", "tax"] { c.textDidChange(prefix) }
        await waitUntil("one search") { !shown.isEmpty }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(shown, ["tax"])
        XCTAssertEqual(env.settings.searchScope, .subfolders)
    }

    func testReturnRunsImmediately() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .seconds(10))
        c.scope = .subfolders
        c.textDidChange("tax")
        c.commit()
        await waitUntil("results") { session.results != nil }
    }

    func testDiagnosticsAndClear() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(10))
        c.scope = .subfolders
        c.textDidChange("tax size:big")
        XCTAssertEqual(c.diagnostics, [SyntaxDiagnostic(token: "size:big", problem: .badSize)])
        c.commit()
        await waitUntil("results") { session.results != nil }
        c.clear()
        XCTAssertEqual(c.text, "")
        XCTAssertNil(session.results)
        XCTAssertTrue(c.diagnostics.isEmpty)
    }

    /// Review (P3-10): backspacing the text out keeps the filters, so a filters-only search survives editing the text.
    func testDeletingTheTextKeepsFiltersAndTheFiltersOnlySearch() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(10))
        let field = SearchFieldController(session: session, controller: c)
        c.scope = .subfolders
        c.filters = SearchFilters(extensions: ["pdf"])
        await waitUntil("filters-only results") { session.results != nil }
        field.field.stringValue = "tax"
        field.textDidChange()
        await waitUntil("text results") { session.results?.spec?.text == "tax" }
        field.field.stringValue = ""
        field.textDidChange()
        XCTAssertEqual(c.filters, SearchFilters(extensions: ["pdf"]), "typing never drops the filters")
        await waitUntil("filters-only search again") { session.results?.spec?.text == "" }
        XCTAssertEqual(session.results?.spec?.filters, SearchFilters(extensions: ["pdf"]))
    }

    /// The field's clear button still resets everything, filters included (like Esc).
    func testClearButtonResetsFilters() async throws {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(10))
        let field = SearchFieldController(session: session, controller: c)
        c.scope = .subfolders
        c.filters = SearchFilters(extensions: ["pdf"])
        field.field.stringValue = "tax"
        field.textDidChange()
        c.commit()
        await waitUntil("results") { session.results != nil }
        let cancel = try XCTUnwrap((field.field.cell as? NSSearchFieldCell)?.cancelButtonCell)
        NSApplication.shared.sendAction(try XCTUnwrap(cancel.action), to: cancel.target, from: cancel)
        XCTAssertEqual(field.field.stringValue, "")
        XCTAssertEqual(c.filters, SearchFilters())
        XCTAssertNil(session.results)
    }

    func testScopeChangeRerunsAndAdoptDoesNot() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(10))
        c.scope = .thisFolder
        c.textDidChange("tax")
        c.scope = .subfolders
        await waitUntil("results after scope change") { session.results != nil }
        let model = session.results
        c.adopt(SearchSpec(text: "other", scope: .thisMac, mode: .contents, root: sandbox.url("work")))
        XCTAssertEqual(c.text, "other")
        XCTAssertEqual(c.scope, .thisMac)
        XCTAssertEqual(c.mode, .contents)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(session.results === model, "adopt must not run a search")
    }

    func testRetypingInsideResultsKeepsTheRoot() async {
        let c = SearchController(session: session, settings: env.settings, debounce: .milliseconds(10))
        c.scope = .subfolders
        c.textDidChange("tax")
        c.commit()
        await waitUntil("results") { session.results != nil }
        c.textDidChange("tax-2")
        c.commit()
        await waitUntil("second") { session.results?.title == "tax-2" }
        XCTAssertEqual(session.results?.spec?.root.standardizedFileURL, sandbox.url("work").standardizedFileURL)
    }
}
