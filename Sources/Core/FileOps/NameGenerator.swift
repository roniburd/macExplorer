import Foundation

/// On-disk names fixed by spec §6.3/§6.4 (Phase 1 ships English only; these are file names, not UI text).
enum NameGenerator {
    static func split(_ name: String, isDirectory: Bool) -> (base: String, ext: String) {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, !ext.contains(" ") else { return (name, "") }
        return (String(name[..<dot]), String(ext))
    }

    /// base + suffix (+ "." + ext), shortening base on a character boundary to stay ≤ 255 UTF-8 bytes.
    static func join(_ base: String, suffix: String, _ ext: String) -> String {
        var b = base
        func make() -> String { ext.isEmpty ? b + suffix : b + suffix + "." + ext }
        while make().utf8.count > 255, !b.isEmpty { b.removeLast() }
        return make()
    }

    /// Finder's rule: " 2" is appended ("IMG 0001.jpg" → "IMG 0001 2.jpg", "Report 2024.pdf" → "Report 2024 2.pdf").
    /// A trailing " N" is read as an earlier Keep Both counter (and bumped: "x 2.txt" → "x 3.txt") only when it
    /// plausibly is one: 2…99 with no leading zero AND the name without it ("x.txt") is taken too, i.e. there is
    /// evidence an earlier Keep Both made it. Anything else (a year, a camera's frame number, "Track 10" in an album
    /// folder) is part of the name.
    static func keepBoth(_ name: String, isDirectory: Bool, taken: (String) -> Bool) -> String {
        let (base, ext) = split(name, isDirectory: isDirectory)
        var stem = base
        var n = 2
        if let m = base.wholeMatch(of: /(.+) ([1-9]\d?)/), let k = Int(m.2), k >= 2,
           taken(join(String(m.1), suffix: "", ext)) {
            stem = String(m.1); n = k + 1
        }
        while true {
            let candidate = join(stem, suffix: " \(n)", ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    static func copyName(_ name: String, isDirectory: Bool, taken: (String) -> Bool) -> String {
        let (base, ext) = split(name, isDirectory: isDirectory)
        let first = join(base, suffix: " copy", ext)
        if !taken(first) { return first }
        var n = 2
        while true {
            let candidate = join(base, suffix: " copy \(n)", ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    static func newItemName(_ kind: NewItemKind, taken: (String) -> Bool) -> String {
        let (base, ext): (String, String) = switch kind {
        case .folder: ("New Folder", "")
        case .textFile: ("Untitled", "txt")
        case .emptyFile: ("Untitled", "")
        }
        let first = join(base, suffix: "", ext)
        if !taken(first) { return first }
        var n = 2
        while true {
            let candidate = join(base, suffix: " \(n)", ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}
