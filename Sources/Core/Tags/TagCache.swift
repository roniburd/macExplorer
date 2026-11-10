import Foundation
import MacxFS

/// Tags per item for menus and the tag editor (P4-05): menus never do file-system I/O while being built, so they
/// read this cache and prefetch what's missing. Keyed by standardized path, bounded (oldest insertion goes first).
/// Reads run on the item's volume read lane without materializing dataless files; a read error caches as `[]`.
@MainActor
public final class TagCache {
    /// Insertion-ordered bounded map (pure, so the bound is testable without 20,000 files).
    struct Storage {
        let capacity: Int
        private var values: [String: (tags: [FileTag], seq: Int)] = [:]
        private var order: [(key: String, seq: Int)] = []
        private var head = 0
        private var nextSeq = 0

        init(capacity: Int) { self.capacity = capacity }

        var count: Int { values.count }
        func value(_ key: String) -> [FileTag]? { values[key]?.tags }

        /// A new key goes last; an update keeps its place.
        mutating func store(_ key: String, _ tags: [FileTag]) {
            if let existing = values[key] {
                values[key] = (tags, existing.seq)
                return
            }
            nextSeq += 1
            values[key] = (tags, nextSeq)
            order.append((key, nextSeq))
            while values.count > capacity, head < order.count {
                let oldest = order[head]
                head += 1
                if values[oldest.key]?.seq == oldest.seq { values[oldest.key] = nil }   // else removed or re-stored
            }
            if head > 1024, head * 2 > order.count {      // drop the consumed prefix now and then
                order.removeFirst(head)
                head = 0
            }
            // Removed keys leave stale slots behind (and re-storing one adds a slot), so below capacity the list would
            // grow by one per invalidate-and-reread. Once stale slots outnumber live ones, keep only the live slots.
            if order.count - head > 2 * values.count + 64 {
                order = order[head...].filter { values[$0.key]?.seq == $0.seq }
                head = 0
            }
        }

        /// Its order slot goes stale and is skipped when reached (or dropped when `store` compacts).
        mutating func remove(_ key: String) { values[key] = nil }

        /// Order slots still held, live or stale (for the bound test).
        var orderSlots: Int { order.count - head }

        var keys: Dictionary<String, (tags: [FileTag], seq: Int)>.Keys { values.keys }
    }

    public static let capacity = 20_000
    /// Most URLs read per `prefetch` call (the visible rows or a selection).
    public static let batchLimit = 500

    private let lanes: LanePool
    private let volumeID: @MainActor (URL) -> VolumeID
    private var storage = Storage(capacity: TagCache.capacity)
    private var pending: Set<String> = []
    /// Invalidated while their read was in flight: that read may predate the change, so they are read again.
    private var rereads: Set<String> = []
    private let observers = Observers<[URL]>()

    public init(lanes: LanePool, volumeID: @escaping @MainActor (URL) -> VolumeID) {
        self.lanes = lanes
        self.volumeID = volumeID
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path(percentEncoded: false) }

    /// nil: not read yet (call `prefetch`).
    public func cachedTags(for url: URL) -> [FileTag]? { storage.value(Self.key(url)) }

    /// Called once per finished batch with the URLs whose tags were (re)read.
    public func observe(_ handler: @escaping @MainActor ([URL]) -> Void) -> ObserverToken { observers.add(handler) }

    /// Forgets `url`'s tags and reads them again; observers hear about the new value.
    public func invalidate(_ url: URL) { invalidate([url]) }

    /// `invalidate` for many URLs: one prefetch (so at most `batchLimit` are read again right away; the rest are
    /// read when next shown or asked for).
    public func invalidate(_ urls: [URL]) {
        invalidate(keys: urls.map(Self.key), onlyKnown: false)
    }

    /// Like `invalidate`, but only for URLs cached or being read: an uncached URL has nothing stale and is read when
    /// next shown or asked for (watcher events would otherwise read every changed item of a busy folder).
    public func invalidateCached(_ urls: [URL]) {
        invalidate(keys: urls.map(Self.key), onlyKnown: true)
    }

    /// The folder's watcher reported a change it can't pin to names (full rescan, F5, root changed): every cached
    /// direct child of `directory` is invalidated.
    public func invalidateChildren(of directory: URL) {
        let parent = Self.key(directory)
        invalidate(keys: knownKeys.filter { ($0 as NSString).deletingLastPathComponent == parent }, onlyKnown: true)
    }

    /// Items moved, renamed or trashed: each root and everything cached under it (cached or pending only) (paths reused later must not show
    /// the old item's tags).
    public func invalidateSubtrees(_ roots: [URL]) {
        guard !roots.isEmpty else { return }
        let rootKeys = Set(roots.map(Self.key))
        let prefixes = rootKeys.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        invalidate(keys: knownKeys.filter { key in rootKeys.contains(key) || prefixes.contains { key.hasPrefix($0) } },
                   onlyKnown: true)
    }

    /// Keys cached or being read.
    private var knownKeys: [String] { Array(storage.keys) + pending }

    private func invalidate(keys: [String], onlyKnown: Bool) {
        var again: [URL] = []
        for key in keys {
            if pending.contains(key) { rereads.insert(key); continue }
            if onlyKnown && storage.value(key) == nil { continue }
            storage.remove(key)
            again.append(URL(filePath: key))
        }
        prefetch(again)
    }

    /// Reads the tags of the URLs not cached or pending (at most `batchLimit`), one lane call per volume.
    public func prefetch(_ urls: [URL]) {
        var todo: [URL] = []
        for url in urls {
            guard todo.count < Self.batchLimit else { break }
            let key = Self.key(url)
            guard storage.value(key) == nil, pending.insert(key).inserted else { continue }
            todo.append(url)
        }
        guard !todo.isEmpty else { return }
        let groups = Dictionary(grouping: todo) { volumeID($0) }
        for (volume, group) in groups {
            Task { [weak self, lanes] in
                let results = (try? await lanes.perform(on: volume, .read) { _ in
                    withNoMaterialization { group.map { url in (url, (try? TagIO.read(url)) ?? []) } }
                }) ?? group.map { ($0, []) }
                self?.store(results)
            }
        }
    }

    private func store(_ results: [(URL, [FileTag])]) {
        var again: [URL] = []
        for (url, tags) in results {
            let key = Self.key(url)
            pending.remove(key)
            if rereads.remove(key) != nil { again.append(url) } else { storage.store(key, tags) }
        }
        let delivered = results.map(\.0).filter { cachedTags(for: $0) != nil }
        if !delivered.isEmpty { observers.send(delivered) }
        if !again.isEmpty { prefetch(again) }
    }
}
