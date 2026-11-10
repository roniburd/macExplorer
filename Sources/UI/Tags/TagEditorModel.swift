import Foundation
import Core
import MacxFS

/// The tag editor's state (P4-05), shared by the Edit Tags… popover and the Properties "Tags" row.
/// Loads every item's tags with one lane call per volume. `tokens` is the union in first-seen order; `mixed` holds the names
/// only some items have. `commit()` turns the user's edits into undoable `setTags` jobs, one undo entry per edit,
/// and never rewrites tags it wasn't asked to change, so in a multi-selection every item keeps its other tags.
@MainActor @Observable
final class TagEditorModel {
    let urls: [URL]
    var tokens: [FileTag] = []
    private(set) var mixed: Set<String> = []
    private(set) var isLoaded = false
    /// Bumped on every load, so the token field replaces its contents only when the model reloaded.
    private(set) var revision = 0

    @ObservationIgnored let environment: CoreEnvironment
    /// Runs one job. Default: `OperationsCenter.perform` with no origin; the popover and Properties pass their own
    /// (window origin, inline errors).
    @ObservationIgnored var perform: @MainActor (JobKind) async -> JobOutcome
    /// A job skipped an item with a reason (locked, permission…).
    @ObservationIgnored var onSkipped: (@MainActor (SkippedItem, JobVerb) -> Void)?
    @ObservationIgnored private var loadedTokens: [FileTag] = []
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var committing = false
    @ObservationIgnored private var commitAgain = false

    init(urls: [URL], environment: CoreEnvironment) {
        self.urls = urls
        self.environment = environment
        let operations = environment.operations
        perform = { kind in await operations.perform(JobRequest(kind, origin: nil)) }
        Task { [weak self] in await self?.reload() }
    }

    convenience init(urls: [URL], context: UIContext) {
        self.init(urls: urls, environment: context.environment)
    }

    /// Reads every item's tags again (after a commit, or a tag job from elsewhere).
    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        // One lane call per volume (like TagCache.prefetch): an ejected or hung volume's reads stay on its own lane.
        let volumes = environment.volumes, lanes = environment.lanes
        let groups = Dictionary(grouping: urls.indices) { volumes.volume(for: urls[$0])?.id ?? .unknown }
        var perItem = urls.map { _ in [FileTag]() }
        await withTaskGroup(of: [(Int, [FileTag])].self) { group in
            for (volume, indices) in groups {
                let batch = indices.map { ($0, urls[$0]) }
                group.addTask {
                    (try? await lanes.perform(on: volume, .read) { _ in
                        withNoMaterialization { batch.map { ($0.0, (try? TagIO.read($0.1)) ?? []) } }
                    }) ?? []
                }
            }
            for await results in group { for (index, tags) in results { perItem[index] = tags } }
        }
        guard generation == loadGeneration else { return }
        apply(perItem)
    }

    private func apply(_ perItem: [[FileTag]]) {
        var union: [FileTag] = []
        var counts: [String: Int] = [:]
        for tags in perItem {
            var seenHere = Set<String>()
            for tag in tags {
                let key = Self.key(tag.name)
                guard seenHere.insert(key).inserted else { continue }
                if counts[key] == nil { union.append(tag) }
                counts[key, default: 0] += 1
            }
        }
        mixed = Set(union.filter { counts[Self.key($0.name)] != perItem.count }.map(\.name))
        defer { isLoaded = true }
        // Edits not committed yet (or queued behind a running commit) stay: `tokens` keeps them and `loadedTokens`
        // stays the base they were made from, so the next commit's diff is exactly the user's edit. The jobs apply it
        // per item on top of what is on disk, and the reload after that commit shows the result.
        guard Self.edits(from: TagIO.normalize(loadedTokens), to: TagIO.normalize(tokens)).isEmpty else { return }
        loadedTokens = union
        tokens = union
        revision += 1
    }

    /// The field ended editing: `edited` is what it shows, `shown` what it showed when editing started. The user's
    /// changes (shown → edited) are replayed onto `tokens`, so a reload that happened meanwhile (tags the field never
    /// displayed) is kept, not reverted. Call `commit()` next.
    func stage(edited: [FileTag], shown: [FileTag]) {
        var result = tokens
        for edit in Self.edits(from: TagIO.normalize(shown), to: TagIO.normalize(edited)) { result = edit.applied(to: result) }
        tokens = TagIO.normalize(result)
    }

    /// Colour changes first (`.recolor`, applied to each item's tags as the job reads them), then removals, then
    /// additions. Names compare trimmed and case-insensitively.
    static func edits(from base: [FileTag], to current: [FileTag]) -> [TagEdit] {
        let baseByKey = Dictionary(base.map { (key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let currentKeys = Set(current.map { key($0.name) })
        var edits: [TagEdit] = []
        for tag in current {
            guard let before = baseByKey[key(tag.name)], before.color != tag.color else { continue }
            edits.append(.recolor(tag))
        }
        for tag in base where !currentKeys.contains(key(tag.name)) { edits.append(.remove(tag.name)) }
        for tag in current where baseByKey[key(tag.name)] == nil { edits.append(.add(tag)) }
        return edits
    }

    static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    func isMixed(_ name: String) -> Bool { mixed.contains { Self.key($0) == Self.key(name) } }

    /// Known tag names starting with `prefix` (case-insensitive), most recently used first.
    func completions(for prefix: String) -> [String] {
        let key = Self.key(prefix)
        guard !key.isEmpty else { return [] }
        return environment.settings.knownTags.map(\.name).filter { $0.lowercased().hasPrefix(key) }
    }

    /// A typed name becomes a token with the known tag's colour, or no colour for a new name.
    func token(forTyped name: String) -> FileTag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let known = tokens.first(where: { Self.key($0.name) == Self.key(trimmed) })
            ?? environment.settings.knownTags.first(where: { Self.key($0.name) == Self.key(trimmed) }) {
            return FileTag(name: known.name, color: known.color)
        }
        return FileTag(name: trimmed)
    }

    func setColor(_ color: TagColor, forTokenNamed name: String) {
        guard let index = tokens.firstIndex(where: { Self.key($0.name) == Self.key(name) }) else { return }
        tokens[index].color = color
    }

    /// Diffs `tokens` against what was loaded: colour changes first (one `.recolor` job per recoloured tag over all
    /// items, applied to each item's tags as the job reads them), then one `.remove` job per deleted token and one
    /// `.add` job per new token over all items. Added tags go to the front of the known tags. Then reloads.
    func commit() async {
        if committing { commitAgain = true; return }
        committing = true
        defer { committing = false }
        var worked = false, lastWorked = false
        repeat {
            commitAgain = false
            lastWorked = await commitOnce()
            worked = worked || lastWorked
        } while commitAgain
        // A queued pass that found nothing to do: an earlier pass's reload may have kept tokens the user had since
        // put back; show what is on disk now.
        if worked && !lastWorked { await reload() }
    }

    /// Runs the jobs for the edits since `loadedTokens`; false when there were none.
    private func commitOnce() async -> Bool {
        guard isLoaded else { return false }
        let current = TagIO.normalize(tokens)
        let edits = Self.edits(from: TagIO.normalize(loadedTokens), to: current)
        guard !edits.isEmpty else { return false }
        for edit in edits {
            let outcome = await perform(.setTags(urls, edit))     // one job (one undo) per edit over all items
            if let skipped = outcome.skipped.first(where: { $0.reason != nil }) { onSkipped?(skipped, outcome.record.verb) }
        }
        for edit in edits {
            switch edit {
            case .add(let tag), .recolor(let tag): environment.settings.noteTagUsed(tag)
            case .remove, .set, .toggle: break
            }
        }
        // The base is now what was committed: an edit made while the jobs ran is whatever differs from it, so the
        // reload keeps it and the queued pass commits only that.
        loadedTokens = current
        await reload()
        return true
    }
}
