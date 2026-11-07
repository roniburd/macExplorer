import Foundation
import MacxFS

public enum SearchScope: String, Sendable, Codable, CaseIterable { case thisFolder, subfolders, thisMac }
public enum SearchMode: String, Sendable, Codable, CaseIterable { case name, contents }

public struct SearchFilters: Sendable, Codable, Hashable {
    public var kinds: Set<KindFilter>
    public var extensions: Set<String>
    public var size: ByteRange?
    public var modified: DateToken?
    public var created: DateToken?
    public init(kinds: Set<KindFilter> = [], extensions: Set<String> = [], size: ByteRange? = nil,
                modified: DateToken? = nil, created: DateToken? = nil) {
        self.kinds = kinds; self.extensions = extensions; self.size = size; self.modified = modified; self.created = created
    }
    public var isEmpty: Bool { kinds.isEmpty && extensions.isEmpty && size == nil && modified == nil && created == nil }

    private enum CodingKeys: String, CodingKey { case kinds, extensions, size, modified, created }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kinds: try c.decodeIfPresent(Set<KindFilter>.self, forKey: .kinds) ?? [],
                  extensions: try c.decodeIfPresent(Set<String>.self, forKey: .extensions) ?? [],
                  size: try c.decodeIfPresent(ByteRange.self, forKey: .size),
                  modified: try c.decodeIfPresent(DateToken.self, forKey: .modified),
                  created: try c.decodeIfPresent(DateToken.self, forKey: .created))
    }

    /// Sets are written sorted: their iteration order is per-launch (seeded hashing), and the encoded form
    /// feeds `SearchSpec.url`, which must be the same string every time for history and saved searches.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kinds.map(\.rawValue).sorted(), forKey: .kinds)
        try c.encode(extensions.sorted(), forKey: .extensions)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(modified, forKey: .modified)
        try c.encodeIfPresent(created, forKey: .created)
    }
}

public struct SearchSpec: Sendable, Codable, Hashable {
    public var text: String
    public var scope: SearchScope
    public var mode: SearchMode
    public var filters: SearchFilters
    public var root: URL
    public init(text: String, scope: SearchScope, mode: SearchMode = .name, filters: SearchFilters = SearchFilters(), root: URL) {
        self.text = text; self.scope = scope; self.mode = mode; self.filters = filters; self.root = root
    }

    public static let urlScheme = "x-macexplorer-search"

    /// Internal history/saved-search URL; never handed to NSWorkspace. "x-macexplorer-search:?v=1&q=<base64url JSON>".
    public var url: URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(Self.urlScheme):?v=1&q=\(b64)")!
    }

    public init?(url: URL) {
        guard url.scheme == Self.urlScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "v" })?.value == "1",
              var b64 = items.first(where: { $0.name == "q" })?.value else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let spec = try? JSONDecoder().decode(SearchSpec.self, from: data) else { return nil }
        self = spec
    }

    public var isEmptyQuery: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filters.isEmpty }
}
