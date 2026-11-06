// Sources/UI/Icons/ThumbnailScheduler.swift
import AppKit
import Core
import MacxFS

/// Renders one thumbnail. `completion` runs on the main actor once, unless the ticket was cancelled first.
@MainActor protocol ThumbnailGenerating: AnyObject {
    func generate(url: URL, pointSize: CGFloat, scale: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> ThumbnailTicket
    func cancel(_ ticket: ThumbnailTicket)
}

/// Thumbnail requests for one grid (spec §11, §4.2 Tier 2): only the visible eligible items, at most `maxInFlight`
/// at a time in visible order; items that leave the visible set are cancelled; a failure is not retried for that
/// key while this scheduler lives.
@MainActor
final class ThumbnailScheduler {
    private let generator: any ThumbnailGenerating
    private let cache: ThumbnailCache
    private let maxInFlight: Int
    private(set) var inFlight: Set<ThumbnailKey> = []
    private var tickets: [ThumbnailKey: ThumbnailTicket] = [:]
    private var failed: Set<ThumbnailKey> = []
    private var wanted: [ThumbnailCandidate] = []
    private var pointSize: CGFloat = 64
    private var scale: CGFloat = 2
    /// A thumbnail for `key` is now in the cache.
    var onThumbnail: ((ThumbnailKey) -> Void)?

    init(generator: any ThumbnailGenerating, cache: ThumbnailCache, maxInFlight: Int = 8) {
        self.generator = generator
        self.cache = cache
        self.maxInFlight = maxInFlight
    }

    /// Regular non-empty files and document packages; never dataless (no iCloud downloads), degraded entries,
    /// folders, applications, symlinks or aliases.
    static func isEligible(_ e: Entry, types: TypeRegistry) -> Bool {
        guard !e.flags.contains(.dataless), !e.flags.contains(.degraded) else { return false }
        switch e.kind {
        case .file: return e.size > 0
        case .package: return !types.isApplication(e.typeIndex)
        case .directory, .symlink, .alias, .other: return false
        }
    }

    /// The visible candidates, in visible order. Cancels requests for keys no longer visible, then fills free slots.
    func updateVisible(_ candidates: [ThumbnailCandidate], pointSize: CGFloat, scale: CGFloat) {
        self.pointSize = pointSize
        self.scale = scale
        wanted = candidates
        let keep = Set(candidates.map(\.key))
        for key in inFlight where !keep.contains(key) {
            if let ticket = tickets.removeValue(forKey: key) { generator.cancel(ticket) }
            inFlight.remove(key)
        }
        pump()
    }

    /// Thumbnails off, or the grid unbound: cancel everything and request nothing until the next `updateVisible`.
    func cancelAll() {
        for ticket in tickets.values { generator.cancel(ticket) }
        tickets.removeAll()
        inFlight.removeAll()
        wanted.removeAll()
    }

    private func pump() {
        for candidate in wanted where inFlight.count < maxInFlight {
            let key = candidate.key
            guard !inFlight.contains(key), !failed.contains(key), cache.image(key) == nil else { continue }
            inFlight.insert(key)
            tickets[key] = generator.generate(url: candidate.url, pointSize: pointSize, scale: scale) { [weak self] image in
                self?.finish(key, image)
            }
        }
    }

    private func finish(_ key: ThumbnailKey, _ image: CGImage?) {
        guard inFlight.remove(key) != nil else { return }   // cancelled meanwhile
        tickets[key] = nil
        if let image {
            cache.store(image, for: key)
            onThumbnail?(key)
        } else {
            failed.insert(key)
        }
        pump()
    }
}
