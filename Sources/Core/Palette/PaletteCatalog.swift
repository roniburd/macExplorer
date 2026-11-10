import Foundation

/// What a palette row does: run a command through the target window's responder chain, or go to a folder.
/// Equal when their `encoded` forms are: a folder is the same row with or without a trailing slash.
public enum PaletteTarget: Sendable, Hashable {
    case command(Command)
    case location(URL)

    public static func == (a: PaletteTarget, b: PaletteTarget) -> Bool { a.encoded == b.encoded }
    public func hash(into hasher: inout Hasher) { hasher.combine(encoded) }

    /// The stored form in `Settings.paletteRecent`: "cmd:<raw>" or "loc:<path>".
    public var encoded: String {
        switch self {
        case .command(let command): "cmd:" + command.rawValue
        case .location(let url): "loc:" + Self.path(of: url)
        }
    }

    /// nil for an unknown command (a newer version's) or a malformed entry.
    public init?(encoded: String) {
        if encoded.hasPrefix("cmd:"), let command = Command(rawValue: String(encoded.dropFirst(4))) {
            self = .command(command)
        } else if encoded.hasPrefix("loc:"), encoded.count > 4 {
            self = .location(URL(filePath: String(encoded.dropFirst(4)), directoryHint: .isDirectory))
        } else {
            return nil
        }
    }

    /// The path without a trailing slash (a folder URL's path ends with one), so equal folders encode equally.
    static func path(of url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

public struct PaletteItem: Sendable, Hashable, Identifiable {
    public var id: PaletteTarget { target }
    public var target: PaletteTarget
    /// Localized by the UI before it hands the item in.
    public var title: String
    /// The path for locations, the key binding for commands.
    public var subtitle: String?
    public init(target: PaletteTarget, title: String, subtitle: String?) {
        self.target = target
        self.title = title
        self.subtitle = subtitle
    }
}

public struct RankedPaletteItem: Sendable, Equatable {
    public var item: PaletteItem
    public var match: FuzzyMatch
    public init(item: PaletteItem, match: FuzzyMatch) {
        self.item = item
        self.match = match
    }
}

public enum PaletteCatalog {
    /// How many of the most recent targets get a boost.
    public static let boostedRecents = 10

    /// Empty query: MRU first (most recent first), then alphabetical by title. Otherwise by score
    /// (+ MRU boost: 30 − 3 × rank for the 10 most recent), ties shorter title, then title. Pure and in memory.
    public static func rank(_ items: [PaletteItem], query: String, recent: [PaletteTarget]) -> [RankedPaletteItem] {
        var recentRank: [PaletteTarget: Int] = [:]
        for (index, target) in recent.enumerated() where recentRank[target] == nil { recentRank[target] = index }
        let q = FuzzyMatcher.fold(query).filter { !$0.isWhitespace }
        if q.isEmpty {
            let none = FuzzyMatch(score: 0, matchedIndices: [])
            let (used, rest) = (items.filter { recentRank[$0.target] != nil }, items.filter { recentRank[$0.target] == nil })
            let ordered = used.sorted { recentRank[$0.target]! < recentRank[$1.target]! }
                + rest.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return ordered.map { RankedPaletteItem(item: $0, match: none) }
        }
        var ranked: [RankedPaletteItem] = []
        ranked.reserveCapacity(items.count)
        for item in items {
            guard var match = FuzzyMatcher.match(folded: q, in: FuzzyMatcher.fold(item.title)) else { continue }
            if let r = recentRank[item.target], r < boostedRecents { match.score += 30 - 3 * r }
            ranked.append(RankedPaletteItem(item: item, match: match))
        }
        ranked.sort { a, b in
            if a.match.score != b.match.score { return a.match.score > b.match.score }
            if a.item.title.count != b.item.title.count { return a.item.title.count < b.item.title.count }
            return a.item.title.localizedStandardCompare(b.item.title) == .orderedAscending
        }
        return ranked
    }
}
