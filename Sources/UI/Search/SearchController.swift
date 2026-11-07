import Foundation
import Core
import MacxFS

/// Field text + scope + mode + filters → SearchSpec → BrowserSession.search (P3-10, spec §11). This folder by name
/// runs on every keystroke (the Phase 1 instant filter, now with criteria); every other combination is debounced;
/// Return runs at once; an empty query clears the search. Scope and mode persist in Settings and re-run at once.
@MainActor
final class SearchController {
    private unowned let session: BrowserSession
    private let settings: Settings
    private let debounce: Duration
    private var pending: Task<Void, Never>?
    private var adopting = false

    private(set) var text = ""
    /// What the parser did not understand in `text` ("size:big"); the scope bar shows it.
    private(set) var diagnostics: [SyntaxDiagnostic] = []
    var scope: SearchScope {
        didSet {
            guard !adopting, scope != oldValue else { return }
            settings.searchScope = scope
            onChange?()
            run(now: true)
        }
    }
    var mode: SearchMode {
        didSet {
            guard !adopting, mode != oldValue else { return }
            settings.searchMode = mode
            onChange?()
            run(now: true)
        }
    }
    var filters = SearchFilters() {
        didSet {
            guard !adopting, filters != oldValue else { return }
            onChange?()
            run(now: false)
        }
    }
    /// The field, scope bar and menus refresh from here.
    var onChange: (() -> Void)?

    init(session: BrowserSession, settings: Settings, debounce: Duration = .milliseconds(250)) {
        self.session = session
        self.settings = settings
        self.debounce = debounce
        scope = settings.searchScope
        mode = settings.searchMode
    }

    /// Retyping inside results keeps searching the same folder.
    var root: URL { session.results?.spec?.root ?? session.folder.directory }

    /// The spec the current text, scope, mode and filters describe; nil for an empty query.
    func spec() -> SearchSpec? {
        let s = SearchSpec(text: text, scope: scope, mode: mode, filters: filters, root: root)
        return s.isEmptyQuery ? nil : s
    }

    var hasQuery: Bool { spec() != nil }

    func textDidChange(_ newText: String) {
        guard newText != text else { return }
        text = newText
        diagnostics = QuerySyntax.parse(newText).diagnostics
        onChange?()
        run(now: scope == .thisFolder && mode == .name)
    }

    /// Return in the field.
    func commit() { run(now: true) }

    /// Esc in the field, the field's clear button: back to the folder.
    func clear() {
        pending?.cancel()
        pending = nil
        adopting = true
        text = ""
        diagnostics = []
        filters = SearchFilters()
        adopting = false
        session.clearSearch()
        onChange?()
    }

    /// Mirrors a spec the session shows (history, saved search) without running anything; nil empties the field.
    func adopt(_ spec: SearchSpec?) {
        pending?.cancel()
        pending = nil
        adopting = true
        defer { adopting = false; onChange?() }
        guard let spec else { text = ""; diagnostics = []; filters = SearchFilters(); return }
        text = spec.text
        diagnostics = QuerySyntax.parse(spec.text).diagnostics
        scope = spec.scope
        mode = spec.mode
        filters = spec.filters
    }

    /// Stops a debounced run that has not started (the window closed).
    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func run(now: Bool) {
        pending?.cancel()
        pending = nil
        guard let spec = spec() else { session.clearSearch(); return }
        let wait = now ? Duration.zero : debounce
        pending = Task { [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            await self.session.search(spec)
        }
    }
}
