import Foundation
import Core
import MacxFS

/// The tag editor's state (P4-05), shared by the Edit Tags… popover and the Properties "Tags" row.
/// Loads every item's tags with one lane call. `tokens` is the union in first-seen order; `mixed` holds the names
/// only some items have. `commit()` turns the user's edits into undoable `setTags` jobs, each its own undo entry,
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
    @ObservationIgnored private var loadedPerItem: [[FileTag]] = []
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
        let urls = self.urls
        let volume = urls.first.flatMap { environment.volumes.volume(for: $0)?.id } ?? .unknown
        let perItem = (try? await environment.lanes.perform(on: volume, .read) { _ in
            withNoMaterialization { urls.map { (try? TagIO.read($0)) ?? [] } }
        }) ?? urls.map { _ in [] }
        guard generation == loadGeneration else { return }
        apply(perItem)
    }

    private func apply(_ perItem: [[FileTag]]) {
        loadedPerItem = perItem
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
        loadedTokens = union
        tokens = union
        mixed = Set(union.filter { counts[Self.key($0.name)] != perItem.count }.map(\.name))
        isLoaded = true
        revision += 1
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

    /// Diffs `tokens` against what was loaded: colour changes first (one `.set` job per item that has the tag,
    /// from that item's tags with the colour replaced), then one `.remove` job per deleted token and one `.add` job
    /// per new token over all items. Added tags go to the front of the known tags. Then reloads.
    func commit() async {
        if committing { commitAgain = true; return }
        committing = true
        defer { committing = false }
        repeat {
            commitAgain = false
            await commitOnce()
        } while commitAgain
    }

    private func commitOnce() async {
        guard isLoaded else { return }
        let current = TagIO.normalize(tokens)
        let loaded = loadedTokens
        let loadedByKey = Dictionary(loaded.map { (Self.key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let currentKeys = Set(current.map { Self.key($0.name) })
        var jobs: [JobKind] = []
        var recolored = loadedPerItem
        for tag in current {
            guard let before = loadedByKey[Self.key(tag.name)], before.color != tag.color else { continue }
            for (index, url) in urls.enumerated() {
                let tags = recolored[index]
                guard tags.contains(where: { Self.key($0.name) == Self.key(tag.name) }) else { continue }
                let updated = tags.map { Self.key($0.name) == Self.key(tag.name) ? FileTag(name: $0.name, color: tag.color) : $0 }
                recolored[index] = updated
                jobs.append(.setTags([url], .set(updated)))
            }
        }
        for tag in loaded where !currentKeys.contains(Self.key(tag.name)) {
            jobs.append(.setTags(urls, .remove(tag.name)))
        }
        let added = current.filter { loadedByKey[Self.key($0.name)] == nil }
        for tag in added { jobs.append(.setTags(urls, .add(tag))) }
        guard !jobs.isEmpty else { return }
        for kind in jobs {
            let outcome = await perform(kind)
            if let skipped = outcome.skipped.first(where: { $0.reason != nil }) { onSkipped?(skipped, outcome.record.verb) }
        }
        for tag in added { environment.settings.noteTagUsed(tag) }
        for tag in current where loadedByKey[Self.key(tag.name)].map({ $0.color != tag.color }) ?? false {
            environment.settings.noteTagUsed(tag)
        }
        await reload()
    }
}
