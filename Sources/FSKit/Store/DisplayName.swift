/// The name Finder shows for an item (design 2026-11-05 §1): the extension is hidden when Finder's per-file
/// "hide extension" flag is set or the item is an application bundle, unless `showAllExtensions`; a localized stem
/// (the name without its extension in the user's language) replaces the real stem. Pure, no I/O.
public enum DisplayName {
    public static func make(name: String, kind: Kind, flags: EntryFlags, localizedStem: String?, showAllExtensions: Bool) -> String {
        // Fast path (sort-key generation runs this for every row): nothing can change.
        if localizedStem == nil && (showAllExtensions || (kind != .package && !flags.contains(.extensionHidden))) { return name }
        var name = name
        let ext: Range<Int>? = name.withUTF8 { fileExtensionRange($0) }
        let stem: String
        if let localizedStem, !localizedStem.isEmpty {
            stem = localizedStem
        } else if let ext {
            stem = name.withUTF8 { String(decoding: UnsafeBufferPointer(rebasing: $0[..<(ext.lowerBound - 1)]), as: UTF8.self) }
        } else {
            return name
        }
        guard let ext else { return stem }
        let extText = name.withUTF8 { String(decoding: UnsafeBufferPointer(rebasing: $0[ext]), as: UTF8.self) }
        // Finder never shows the ".localized" suffix of a folder it has a localized name for.
        if localizedStem != nil, kind == .directory, extText == "localized" { return stem }
        let hide = !showAllExtensions
            && (flags.contains(.extensionHidden) || (kind == .package && extText.lowercased() == "app"))
        return hide ? stem : stem + "." + extText
    }

    /// Whether the extension would be hidden (no localized stem involved).
    public static func hidesExtension(name: String, kind: Kind, flags: EntryFlags, showAllExtensions: Bool) -> Bool {
        make(name: name, kind: kind, flags: flags, localizedStem: nil, showAllExtensions: showAllExtensions) != name
    }
}
