/// Deterministic ~5k-name corpus for the §9 sort golden test (no file system involved).
public enum SortCorpus {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let latin = ["report", "Report", "résumé", "Resume", "café", "Cafe", "naïve", "Zoë", "Ångström", "über",
                        "Über", "straße", "Strasse", "façade", "élan", "Élan", "año", "Ano", "crème", "œuvre",
                        "ﬁle", "ｆｕｌｌ", "photo", "Photo", "notes", "zebra", "apple", "Apple", "Øresund", "łódź"]
    static let greek = ["αλφα", "Βήτα", "γάμμα", "Δέλτα", "έψιλον", "ζήτα", "ήτα", "Θήτα"]
    static let cyrillic = ["альфа", "Бета", "гамма", "Дельта", "ёлка", "Елка", "жук", "Яблоко"]
    static let cjk = ["文件", "资料", "写真", "ファイル", "ふぁいる", "자료", "한글", "日本"]
    static let separators = [" ", "-", "_", ".", " (", "~", ""]
    static let extensions = ["", ".txt", ".pdf", ".JPG", ".tar.gz", ".swift", ".md"]

    /// `count` distinct names; same seed → same list.
    public static func names(count: Int = 5_000, seed: UInt64 = 0x6D61_6378) -> [String] {
        var rng = SplitMix64(state: seed)
        var seen = Set<[UInt8]>()
        var result: [String] = []
        let words = latin + greek + cyrillic + cjk
        while result.count < count {
            var name = words.randomElement(using: &rng)!
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: name += separators.randomElement(using: &rng)! + String(Int.random(in: 0...120, using: &rng))
            case 1:                                                    // leading zeros
                let n = Int.random(in: 0...99, using: &rng)
                name += " " + String(repeating: "0", count: Int.random(in: 0...3, using: &rng)) + String(n)
            case 2:                                                    // long digit runs (up to 40 digits)
                let len = Int.random(in: 10...40, using: &rng)
                name += (0..<len).map { i in String(i == 0 ? Int.random(in: 1...9, using: &rng) : Int.random(in: 0...9, using: &rng)) }.joined()
            case 3: name = String(Int.random(in: 0...2_000, using: &rng)) + separators.randomElement(using: &rng)! + name
            case 4: name += separators.randomElement(using: &rng)! + words.randomElement(using: &rng)!
            default: break
            }
            name += extensions.randomElement(using: &rng)!
            if seen.insert(Array(name.utf8)).inserted { result.append(name) }
        }
        return result
    }
}
