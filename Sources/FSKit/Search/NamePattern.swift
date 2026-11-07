import Darwin
import Foundation

/// A folded name term. Without `*`/`?` it is a substring test; with them it is an anchored whole-name glob
/// where `*` matches any run of bytes and `?` exactly one UTF-8 scalar (so "?" matches "日" or "😀"). Literal
/// pieces are folded with `SortKeys.searchFold`, the same case/diacritic/width fold the names are matched in.
public struct NamePattern: Sendable, Hashable {
    enum Token: Sendable, Hashable { case literal([UInt8]), star, one }
    let tokens: [Token]
    public let isGlob: Bool

    public init(_ term: String) {
        var tokens: [Token] = []
        var piece = ""
        var glob = false
        func flush() {
            if !piece.isEmpty { tokens.append(.literal(SortKeys.searchFold(piece))); piece = "" }
        }
        for ch in term {
            switch ch {
            case "*":
                flush(); glob = true
                if tokens.last != .star { tokens.append(.star) }
            case "?":
                flush(); glob = true
                tokens.append(.one)
            default:
                piece.append(ch)
            }
        }
        flush()
        self.tokens = tokens
        self.isGlob = glob
    }

    public func matches(_ foldedName: UnsafeRawBufferPointer) -> Bool {
        if !isGlob {
            guard case .literal(let needle)? = tokens.first else { return true }
            return Self.contains(foldedName, needle)
        }
        return Self.glob(tokens, foldedName)
    }

    static func contains(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        guard hay.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil }
    }

    static func hasPrefix(_ hay: UnsafeRawBufferPointer, at i: Int, _ lit: [UInt8]) -> Bool {
        if hay.count - i < lit.count { return false }
        for k in 0..<lit.count where hay[i + k] != lit[k] { return false }
        return true
    }

    /// Index of the scalar after the one starting at `i` (skips UTF-8 continuation bytes).
    static func nextScalar(_ s: UnsafeRawBufferPointer, _ i: Int) -> Int {
        var j = i + 1
        while j < s.count && (s[j] & 0xC0) == 0x80 { j += 1 }
        return j
    }

    /// Classic single-backtrack wildcard match over tokens (linear in practice, always terminates: each
    /// backtrack advances the star's start by one scalar).
    static func glob(_ tokens: [Token], _ s: UnsafeRawBufferPointer) -> Bool {
        var ti = 0, si = 0
        var starTi = -1, starSi = 0
        let n = s.count
        while true {
            if ti < tokens.count {
                switch tokens[ti] {
                case .star:
                    starTi = ti; starSi = si; ti += 1
                    continue
                case .one:
                    if si < n { si = nextScalar(s, si); ti += 1; continue }
                case .literal(let lit):
                    if hasPrefix(s, at: si, lit) { si += lit.count; ti += 1; continue }
                }
            } else if si == n {
                return true
            }
            if starTi < 0 || starSi >= n { return false }
            starSi = nextScalar(s, starSi)
            si = starSi
            ti = starTi + 1
        }
    }
}
