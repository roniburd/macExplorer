import Foundation

/// Batch-rename replacement templates (P4-11).
enum RegexTemplate {
    /// Expands `$0`–`$9` and `$$` against one match. Other characters are literal (no backslash escapes). A group that
    /// didn't participate expands to ""; `$n` for a group the pattern doesn't have, and a trailing lone `$`, stay literal.
    static func expand(_ template: String, match: NSTextCheckingResult, in source: NSString) -> String {
        var out = ""
        var it = template.makeIterator()
        while let c = it.next() {
            guard c == "$" else { out.append(c); continue }
            guard let n = it.next() else { out.append("$"); break }
            if n == "$" { out.append("$"); continue }
            guard n.isASCII, let d = n.wholeNumberValue, d < match.numberOfRanges else { out.append("$"); out.append(n); continue }
            let r = match.range(at: d)
            if r.location != NSNotFound { out += source.substring(with: r) }
        }
        return out
    }
}
