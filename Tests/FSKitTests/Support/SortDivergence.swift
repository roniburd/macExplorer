import Foundation
import MacxFS

/// Classifies why our byte key orders `a` after `b` although localizedStandardCompare orders a < b.
/// Every category is a documented, accepted consequence of the §4.2 key layout.
enum DivergenceCategory: String, Codable, CaseIterable {
    case tieBreak = "tie-break"                       // folded keys equal: NFC-byte tie-break (A < a) vs ICU tertiary (a < A)
    case longDigitRun = "long-digit-run"              // a digit run > 18 digits: ICU stops comparing numerically
    case punctuation = "punctuation"                  // first difference involves a space/punctuation/symbol/digit-run byte
    case scriptOrder = "script-order"                 // first difference is between letters of different scripts
    case nonDecomposableLetter = "non-decomposable-letter"  // ø, ł, œ, æ, ß…: no diacritic decomposition to fold away
    case kanaVariant = "kana-variant"                 // hiragana vs katakana: ICU equal at primary strength, fold keeps them apart
    case compatibilityCharacter = "compatibility-character"  // ligatures like ﬁ: ICU expands them, the fold does not
    case other = "other"                              // unexplained: the test fails

    var reason: String {
        switch self {
        case .tieBreak: return "Folded keys are equal; the key tie-breaks on unfolded NFC bytes (uppercase before lowercase, more leading zeros first), ICU puts lowercase first."
        case .longDigitRun: return "localizedStandardCompare compares digit runs numerically only while they fit in 64 bits; the key compares runs of up to 255 digits numerically (§4.2 rule 2)."
        case .punctuation: return "ICU orders spaces < punctuation < symbols < digits by collation weight; the key uses folded UTF-8 code-unit order, and digit runs start with a length byte (0x01–0xFF)."
        case .scriptOrder: return "ICU root collation orders scripts (e.g. Hangul before Han); the key uses code-point order."
        case .nonDecomposableLetter: return "Letters such as ø, ł, œ, æ have no canonical decomposition, so CFStringFold keeps them; ICU sorts them next to their base letter."
        case .kanaVariant: return "ICU treats hiragana and katakana as equal at primary strength; CFStringFold has no kana-insensitive option, so the key orders them by code point."
        case .compatibilityCharacter: return "ICU expands compatibility characters (ligatures such as ﬁ) to their letters; CFStringFold with these options does not."
        case .other: return "Unexplained divergence: fix the key or add a category with a reason."
        }
    }

    static func classify(_ a: String, _ b: String) -> DivergenceCategory {
        let fa = SortKeys.nameKey(a, isFolder: false), fb = SortKeys.nameKey(b, isFolder: false)
        if fa.prefix(upTo: fa.firstIndex(of: 0)!) == fb.prefix(upTo: fb.firstIndex(of: 0)!) { return .tieBreak }
        if maxDigitRun(a) > 18 || maxDigitRun(b) > 18 { return .longDigitRun }
        let sa = Array(SortKeys.searchFold(a).unicodeScalarsFromUTF8), sb = Array(SortKeys.searchFold(b).unicodeScalarsFromUTF8)
        var i = 0
        while i < min(sa.count, sb.count) && sa[i] == sb[i] { i += 1 }
        guard i < sa.count && i < sb.count else { return .punctuation }   // one is a prefix: separator/extension decides
        let ca = sa[i], cb = sb[i]
        if String(ca).precomposedStringWithCompatibilityMapping != String(ca)
            || String(cb).precomposedStringWithCompatibilityMapping != String(cb) { return .compatibilityCharacter }
        if !isLetter(ca) || !isLetter(cb) { return .punctuation }
        if block(ca) == 3 && block(cb) == 3 { return .kanaVariant }
        if block(ca) != block(cb) { return .scriptOrder }
        if block(ca) == 0 && (!isASCIILetter(ca) || !isASCIILetter(cb)) { return .nonDecomposableLetter }
        if a.precomposedStringWithCompatibilityMapping != a || b.precomposedStringWithCompatibilityMapping != b {
            return .compatibilityCharacter
        }
        return .other
    }

    private static func maxDigitRun(_ s: String) -> Int {
        var best = 0, run = 0
        for u in s.utf8 { if u >= 48 && u <= 57 { run += 1; best = max(best, run) } else { run = 0 } }
        return best
    }
    private static func isLetter(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic }
    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool { (0x61...0x7A).contains(c.value) || (0x41...0x5A).contains(c.value) }
    /// Coarse script block: 0 Latin, 1 Greek, 2 Cyrillic, 3 kana, 4 Han, 5 Hangul, 6 other.
    private static func block(_ c: Unicode.Scalar) -> Int {
        switch c.value {
        case 0..<0x370: return 0
        case 0x370..<0x400: return 1
        case 0x400..<0x530: return 2
        case 0x3040..<0x3100: return 3
        case 0x4E00..<0xA000: return 4
        case 0xAC00..<0xD7B0: return 5
        default: return 6
        }
    }
}

extension Array where Element == UInt8 {
    var unicodeScalarsFromUTF8: String.UnicodeScalarView { String(decoding: self, as: UTF8.self).unicodeScalars }
}

struct Divergence: Codable, Equatable, Hashable {
    var a: String
    var b: String
    var category: String
}

struct DivergenceFile: Codable, Equatable {
    var comment: String
    var categories: [String: String]
    var divergences: [Divergence]
}

/// Adjacent pairs of the reference order that our keys invert.
func sortDivergences(_ names: [String]) -> [Divergence] {
    let locale = Locale(identifier: "en_US")
    let options: String.CompareOptions = [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering]
    let reference = names.sorted { $0.compare($1, options: options, range: nil, locale: locale) == .orderedAscending }
    let keys = Dictionary(uniqueKeysWithValues: names.map { ($0, SortKeys.nameKey($0, isFolder: false)) })
    var result: [Divergence] = []
    for i in 0..<(reference.count - 1) {
        let a = reference[i], b = reference[i + 1]
        guard a.compare(b, options: options, range: nil, locale: locale) == .orderedAscending else { continue }
        if !keys[a]!.lexicographicallyPrecedes(keys[b]!) {
            result.append(Divergence(a: a, b: b, category: DivergenceCategory.classify(a, b).rawValue))
        }
    }
    return result
}
