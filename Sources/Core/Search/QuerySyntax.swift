import Foundation
import MacxFS

public enum SizeWord: String, Sendable, CaseIterable {
    case empty, tiny, small, medium, large, huge, gigantic
    public var range: ByteRange {
        switch self {
        case .empty: return ByteRange(lower: 0, upper: 1)
        case .tiny: return ByteRange(lower: 1, upper: 16_000)
        case .small: return ByteRange(lower: 16_000, upper: 1_000_000)
        case .medium: return ByteRange(lower: 1_000_000, upper: 128_000_000)
        case .large: return ByteRange(lower: 128_000_000, upper: 1_000_000_000)
        case .huge: return ByteRange(lower: 1_000_000_000, upper: 4_000_000_000)
        case .gigantic: return ByteRange(lower: 4_000_000_000)
        }
    }
}

public struct SyntaxDiagnostic: Sendable, Codable, Equatable {
    public enum Problem: String, Sendable, Codable { case badSize, badDate, badKind, emptyValue }
    public var token: String
    public var problem: Problem
    public init(token: String, problem: Problem) { self.token = token; self.problem = problem }
}

public struct ParsedQuery: Sendable, Equatable {
    public var freeTerms: [String] = []
    public var nameTerms: [String] = []
    public var kinds: Set<KindFilter> = []
    public var extensions: Set<String> = []
    public var size: ByteRange? = nil
    public var modified: [DateToken] = []
    public var created: [DateToken] = []
    public var diagnostics: [SyntaxDiagnostic] = []
    public init() {}
}

public enum QuerySyntax {
    struct RawToken: Equatable { var text: String; var quoted: Bool }

    enum Key { case name, kind, ext, size, modified, created
        init?(_ raw: String) {
            switch raw.lowercased() {
            case "name": self = .name
            case "kind", "type": self = .kind
            case "ext", "extension": self = .ext
            case "size": self = .size
            case "modified", "datemodified", "date": self = .modified
            case "created", "datecreated": self = .created
            default: return nil
            }
        }
    }

    static let kindWords: [String: KindFilter] = [
        "folder": .folder, "folders": .folder, "directory": .folder,
        "document": .document, "documents": .document, "doc": .document, "docs": .document,
        "text": .text, "pdf": .pdf,
        "image": .image, "images": .image, "picture": .image, "pictures": .image, "photo": .image, "photos": .image,
        "movie": .movie, "movies": .movie, "video": .movie, "videos": .movie,
        "audio": .audio, "music": .audio, "sound": .audio,
        "archive": .archive, "archives": .archive, "zip": .archive,
        "app": .application, "apps": .application, "application": .application, "applications": .application,
        "program": .application, "programs": .application,
        "code": .code, "source": .code,
    ]

    static let relativeWords: [String: RelativeDay] = [
        "today": .today, "yesterday": .yesterday, "thisweek": .thisWeek, "lastweek": .lastWeek,
        "thismonth": .thisMonth, "lastmonth": .lastMonth, "thisyear": .thisYear, "lastyear": .lastYear,
        "last7days": .last7Days, "last30days": .last30Days,
    ]

    public static func parse(_ text: String) -> ParsedQuery {
        var q = ParsedQuery()
        for token in tokenize(text) where !token.text.isEmpty {
            guard !token.quoted, let colon = token.text.firstIndex(of: ":"), colon != token.text.startIndex,
                  let key = Key(String(token.text[..<colon])) else {
                q.freeTerms.append(token.text); continue
            }
            let value = String(token.text[token.text.index(after: colon)...])
            if value.isEmpty { q.diagnostics.append(.init(token: token.text, problem: .emptyValue)); continue }
            switch key {
            case .name:
                q.nameTerms.append(value)
            case .kind:
                var bad = false
                for word in value.lowercased().split(separator: ",") {
                    if let k = kindWords[String(word)] { q.kinds.insert(k) } else { bad = true }
                }
                if bad { q.diagnostics.append(.init(token: token.text, problem: .badKind)) }
            case .ext:
                for raw in value.lowercased().split(separator: ",") {
                    var e = Substring(raw)
                    if e.hasPrefix("*.") { e = e.dropFirst(2) } else if e.hasPrefix(".") { e = e.dropFirst() }
                    if !e.isEmpty { q.extensions.insert(String(e)) }
                }
            case .size:
                if let r = parseSize(value) { q.size = q.size.map { $0.intersection(r) } ?? r }
                else { q.diagnostics.append(.init(token: token.text, problem: .badSize)) }
            case .modified, .created:
                guard let d = parseDate(value) else { q.diagnostics.append(.init(token: token.text, problem: .badDate)); continue }
                if key == .modified { q.modified.append(d) } else { q.created.append(d) }
            }
        }
        return q
    }

    static func tokenize(_ s: String) -> [RawToken] {
        var out: [RawToken] = []
        var cur = "", inQuote = false, startedQuoted = false, hasContent = false
        for ch in s {
            if ch == "\"" {
                if !inQuote && !hasContent { startedQuoted = true }
                inQuote.toggle(); hasContent = true
                continue
            }
            if ch.isWhitespace && !inQuote {
                if hasContent { out.append(RawToken(text: cur, quoted: startedQuoted)) }
                cur = ""; hasContent = false; startedQuoted = false
                continue
            }
            cur.append(ch); hasContent = true
        }
        if hasContent { out.append(RawToken(text: cur, quoted: startedQuoted)) }
        return out
    }

    static func unit(_ suffix: String) -> Double? {
        switch suffix {
        case "", "b", "byte", "bytes": return 1
        case "k", "kb": return 1e3
        case "m", "mb": return 1e6
        case "g", "gb": return 1e9
        case "t", "tb": return 1e12
        case "kib": return 1024
        case "mib": return 1_048_576
        case "gib": return 1_073_741_824
        case "tib": return 1_099_511_627_776
        default: return nil
        }
    }

    /// Largest accepted byte count (2⁶², about 4.6 EB): far past any real file, and small enough that the
    /// `+ 1` / `± half unit` arithmetic below can never overflow `Int64` (which would trap).
    static let maxBytes: Double = 0x1p62

    /// Returns (bytes, unitSize) for "1.5MB", "100", "1KiB"; nil for malformed or absurdly large values.
    static func numberWithUnit(_ s: String) -> (bytes: Int64, unit: Double)? {
        let digits = s.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard !digits.isEmpty, let value = Double(digits), value >= 0,
              let u = unit(String(s.dropFirst(digits.count))) else { return nil }
        let bytes = (value * u).rounded()
        guard bytes.isFinite, bytes <= maxBytes else { return nil }
        return (Int64(bytes), u)
    }

    static func parseSize(_ raw: String) -> ByteRange? {
        let s = raw.lowercased()
        if let w = SizeWord(rawValue: s) { return w.range }
        if let dots = s.range(of: "..") {
            guard let a = numberWithUnit(String(s[..<dots.lowerBound])), let b = numberWithUnit(String(s[dots.upperBound...])),
                  a.bytes <= b.bytes else { return nil }
            return ByteRange(lower: a.bytes, upper: b.bytes + 1)
        }
        for op in [">=", "<=", ">", "<", "="] where s.hasPrefix(op) {
            guard let v = numberWithUnit(String(s.dropFirst(op.count)))?.bytes else { return nil }
            switch op {
            case ">=": return ByteRange(lower: v)
            case "<=": return ByteRange(upper: v + 1)
            case ">": return ByteRange(lower: v + 1)
            case "<": return ByteRange(upper: v)
            default: return ByteRange(lower: v, upper: v + 1)
            }
        }
        guard let (v, u) = numberWithUnit(s) else { return nil }
        if u == 1 { return ByteRange(lower: v, upper: v + 1) }
        let half = Int64((u / 2).rounded())
        return ByteRange(lower: max(0, v - half), upper: v + half)
    }

    static func parseDate(_ raw: String) -> DateToken? {
        let lowered = raw.lowercased()
        let word = lowered.filter { $0 != " " && $0 != "-" && $0 != "_" }
        if let r = relativeWords[word] { return .relative(r) }
        if let dots = lowered.range(of: "..") {
            guard let a = DayStamp(parsing: String(lowered[..<dots.lowerBound])),
                  let b = DayStamp(parsing: String(lowered[dots.upperBound...])) else { return nil }
            return .days(lower: DayBound(day: a, inclusive: true), upper: DayBound(day: b, inclusive: true))
        }
        for op in [">=", "<=", ">", "<"] where lowered.hasPrefix(op) {
            guard let d = DayStamp(parsing: String(lowered.dropFirst(op.count))) else { return nil }
            switch op {
            case ">=": return .days(lower: DayBound(day: d, inclusive: true), upper: nil)
            case ">": return .days(lower: DayBound(day: d, inclusive: false), upper: nil)
            case "<=": return .days(lower: nil, upper: DayBound(day: d, inclusive: true))
            default: return .days(lower: nil, upper: DayBound(day: d, inclusive: false))
            }
        }
        guard let d = DayStamp(parsing: lowered) else { return nil }
        return .days(lower: DayBound(day: d, inclusive: true), upper: DayBound(day: d, inclusive: true))
    }
}
