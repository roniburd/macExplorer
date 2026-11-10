import AppKit
import SwiftUI
import Core
import MacxFS

/// The sidebar's TAGS section (P4-06), after LOCATIONS: `Settings.sidebarTags` in order, coloured from
/// `Settings.knownTags`. Clicking a row shows the items with that tag in the window's content area (Phase 3 results,
/// Details with a Path column); dropping files on a row adds the tag (one undoable `setTags` job, whatever the
/// modifiers). Sandboxed runs (`--state-dir`, `--root`) crawl the root instead of asking Spotlight.
@MainActor
final class SidebarTagsSection {
    typealias Row = SidebarTag

    private(set) var rows: [Row] = []
    private let context: UIContext
    private let session: BrowserSession
    /// Runs a tag edit (the window's FileCommandController in the app; set by the sidebar).
    var applyTagEdit: (TagEdit, [URL]) async -> Void
    /// The query and scope a click uses (tests may replace it).
    lazy var makeQuery: () -> (query: any TagQuerying, scope: TagScope, volume: VolumeID) = { [unowned self] in
        self.defaultQuery()
    }
    /// The results this section last showed, so a second click on the same row doesn't restart them.
    private var shown: (name: String, model: WeakModel)?

    private struct WeakModel { weak var model: SearchResultsModel? }

    var environment: CoreEnvironment { context.environment }
    var settings: Core.Settings { environment.settings }

    init(context: UIContext, session: BrowserSession) {
        self.context = context
        self.session = session
        let environment = context.environment
        applyTagEdit = { edit, urls in
            guard !urls.isEmpty else { return }
            _ = await environment.operations.perform(JobRequest(.setTags(urls, edit)))
            switch edit {
            case .add(let tag), .toggle(let tag): environment.settings.noteTagUsed(tag)
            case .remove, .set, .recolor: break
            }
        }
        rows = Self.rows(sidebarTags: settings.sidebarTags, knownTags: settings.knownTags)
    }

    /// Re-reads the rows from Settings; true when they changed.
    @discardableResult
    func rebuild() -> Bool {
        let now = Self.rows(sidebarTags: settings.sidebarTags, knownTags: settings.knownTags)
        guard now != rows else { return false }
        rows = now
        return true
    }

    /// Names in order (duplicates, case-insensitively, dropped), each with its known colour or none.
    static func rows(sidebarTags: [String], knownTags: [FileTag]) -> [Row] {
        var colors: [String: TagColor] = [:]
        for tag in knownTags where colors[tag.name.lowercased()] == nil { colors[tag.name.lowercased()] = tag.color }
        var seen = Set<String>()
        return sidebarTags.compactMap { name in
            let key = name.lowercased()
            guard !name.isEmpty, seen.insert(key).inserted else { return nil }
            return Row(name: name, color: colors[key] ?? .none)
        }
    }

    func row(named name: String) -> Row? { rows.first { $0.name.lowercased() == name.lowercased() } }

    // MARK: drops

    /// Files (from this app or another) are accepted with the copy cursor whatever the modifiers; anything else not.
    func validateDrop(fileURLs: [URL]) -> NSDragOperation { fileURLs.isEmpty ? [] : .copy }

    /// Adds the row's tag to every dropped file in one undoable job.
    func performDrop(_ urls: [URL], onto name: String) async {
        guard !urls.isEmpty, let row = row(named: name) else { return }
        await applyTagEdit(.add(row.tag), urls)
    }

    // MARK: results

    /// The items with the tag, in the window's content area (a Back-able history entry). Clicking the row whose
    /// results are already shown does nothing.
    func showResults(for name: String) {
        guard let row = row(named: name) else { return }
        if let shown, shown.name == row.name, let model = shown.model.model, session.results === model { return }
        let (query, scope, volume) = makeQuery()
        let model = SearchResultsModel(
            title: row.name,
            events: TagSearchEvents.events(query: query, tag: row.name, scope: scope, lanes: environment.lanes,
                                           types: environment.types, volume: volume),
            context: environment.searchContext())
        shown = (row.name, WeakModel(model: model))
        session.showResults(model, recordHistory: true)
    }

    /// Whether the window shows this row's results (the sidebar keeps the row selected meanwhile).
    func isShowingResults(of name: String) -> Bool {
        guard let shown, shown.name.lowercased() == name.lowercased(), let model = shown.model.model else { return false }
        return session.results === model
    }

    /// Spotlight over This Mac normally; in sandboxed runs a crawl of `--root` (nothing at all without a root), so
    /// tests and scenarios never query Spotlight.
    private func defaultQuery() -> (query: any TagQuerying, scope: TagScope, volume: VolumeID) {
        let options = context.options
        guard options.isSandboxed || options.root != nil else { return (SpotlightTagQuery(), .thisMac, .unknown) }
        let volume = options.root.flatMap { environment.volumes.volume(for: $0)?.id } ?? .unknown
        let crawl = CrawlTagQuery(lanes: environment.lanes, volume: volume, types: environment.types)
        return (crawl, options.root.map { .directory($0) } ?? .thisMac, volume)
    }
}

// MARK: Show All Tags…

/// The tags the Show All Tags… sheet and Settings › Sidebar list: every known tag, then sidebar names that aren't
/// known (case-insensitively), each with whether TAGS shows it.
enum SidebarTagChoices {
    @MainActor static func items(_ settings: Core.Settings) -> [(tag: FileTag, shown: Bool)] {
        let shown = Set(settings.sidebarTags.map { $0.lowercased() })
        var seen = Set<String>()
        var out: [(FileTag, Bool)] = []
        let unknown = settings.sidebarTags.map { FileTag(name: $0) }
        for tag in settings.knownTags + unknown where seen.insert(tag.name.lowercased()).inserted {
            out.append((tag, shown.contains(tag.name.lowercased())))
        }
        return out
    }
}

/// Checkboxes over `SidebarTagChoices.items` that edit `Settings.sidebarTags`.
struct SidebarTagChoicesList: View {
    @Bindable var settings: Core.Settings

    var body: some View {
        ForEach(SidebarTagChoices.items(settings), id: \.tag.name) { item in
            Toggle(isOn: Binding(get: { item.shown },
                                 set: { settings.setSidebarTag(item.tag.name, visible: $0) })) {
                HStack(spacing: 6) {
                    Image(nsImage: TagDotsView.menuImage(for: item.tag.color))
                    Text(item.tag.name)
                }
            }
        }
    }
}

/// The Show All Tags… sheet: the tag checkboxes and Done.
struct SidebarTagsSheet: View {
    @Bindable var settings: Core.Settings
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Tags shown in the sidebar")).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) { SidebarTagChoicesList(settings: settings) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 360)
            HStack {
                Spacer()
                Button(L10n.string("Done"), action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    /// Shows the sheet on `presenter`'s window; Done dismisses it.
    @MainActor static func present(from presenter: NSViewController, settings: Core.Settings) {
        let box = SheetBox()
        let sheet = NSHostingController(rootView: SidebarTagsSheet(settings: settings) { [weak presenter] in
            if let host = box.host { presenter?.dismiss(host) }
        })
        box.host = sheet
        presenter.presentAsSheet(sheet)
    }

    @MainActor private final class SheetBox { weak var host: NSViewController? }
}
