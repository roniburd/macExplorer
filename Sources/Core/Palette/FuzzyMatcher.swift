import Foundation

/// A query's match in one candidate: higher scores rank first. `matchedIndices` are Character offsets into the
/// folded candidate (the same as the original's when folding keeps its length).
public struct FuzzyMatch: Sendable, Equatable {
    public var score: Int
    public var matchedIndices: [Int]
    public init(score: Int, matchedIndices: [Int]) {
        self.score = score
        self.matchedIndices = matchedIndices
    }
}

/// The command palette's subsequence scorer (P4-03). Case-, diacritic- and width-insensitive; whitespace in the
/// query is ignored, so "new folder" and "nf" both match "New Folder".
public enum FuzzyMatcher {
    public static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")))
    }

    /// Scoring: +1 per matched char; +20 at index 0, +10 after a non-alphanumeric; +15 when consecutive;
    /// −1 per skipped char between matches; −min(firstIndex, 10) leading penalty. Best path by dynamic programming.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let q = fold(query).filter { !$0.isWhitespace }
        if q.isEmpty { return FuzzyMatch(score: 0, matchedIndices: []) }
        return match(folded: q, in: fold(candidate))
    }

    /// `match` with the query already folded and stripped of whitespace (PaletteCatalog folds it once per ranking).
    static func match(folded q: [Character], in c: [Character]) -> FuzzyMatch? {
        let n = q.count, m = c.count
        guard n > 0 else { return FuzzyMatch(score: 0, matchedIndices: []) }
        guard n <= m else { return nil }
        let neg = Int.min / 4
        func bonus(_ j: Int) -> Int { j == 0 ? 20 : ((c[j - 1].isLetter || c[j - 1].isNumber) ? 0 : 10) }
        // Row-major n × m tables (flat, so a match allocates two arrays, not 2n).
        var dp = [Int](repeating: neg, count: n * m)
        var from = [Int](repeating: -1, count: n * m)
        var any = false
        for j in 0..<m where c[j] == q[0] { dp[j] = 1 + bonus(j) - min(j, 10); any = true }
        guard any else { return nil }
        if n > 1 {
            for i in 1..<n {
                let prev = (i - 1) * m, row = i * m
                var best = neg, bestK = -1                     // max over k < j − 1 of dp[i−1][k] + k
                var rowAny = false
                for j in i..<m {
                    // Consecutive: from j − 1. Gap: from the best k < j − 1 (k = j − 1 is the consecutive case).
                    if j >= 2 {
                        let k = j - 2
                        if dp[prev + k] > neg, dp[prev + k] + k > best { best = dp[prev + k] + k; bestK = k }
                    }
                    guard c[j] == q[i] else { continue }
                    var s = neg, f = -1
                    if dp[prev + j - 1] > neg { s = dp[prev + j - 1] + 1 + 15 + bonus(j); f = j - 1 }
                    if bestK >= 0 {
                        let g = best - j + 1 + 1 + bonus(j)     // dp[k] − (j − k − 1) + 1 + bonus
                        if g > s { s = g; f = bestK }
                    }
                    if f >= 0 { dp[row + j] = s; from[row + j] = f; rowAny = true }
                }
                guard rowAny else { return nil }
            }
        }
        let last = (n - 1) * m
        var endJ = -1, endScore = neg
        for j in 0..<m where dp[last + j] > endScore { endScore = dp[last + j]; endJ = j }
        guard endJ >= 0 else { return nil }
        var indices = [Int](repeating: 0, count: n)
        var j = endJ
        for i in stride(from: n - 1, through: 0, by: -1) {
            indices[i] = j
            j = from[i * m + j]
        }
        return FuzzyMatch(score: endScore, matchedIndices: indices)
    }
}
