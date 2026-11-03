import MacxFS

public enum NameProblem: Sendable, Equatable { case empty, containsSlash, tooLong, duplicate }
public enum NameWarning: Sendable, Equatable { case extensionChanged(from: String, to: String), becomesHidden }
public enum NameValidation: Sendable, Equatable {
    case ok(warnings: [NameWarning])
    case invalid(NameProblem)
}

/// Rename and new-name rules (§5.6).
public enum NameRules {
    public static let maxNameBytes = 255

    /// `exists` is answered from the full EntryStore (hidden rows included), NameNormalizer.sameName semantics.
    /// `original` nil for new items. A case/normalization-only change of `original` is not a duplicate.
    /// Problems are checked in order empty, '/', length (UTF-8 bytes of the NFC form), duplicate; warnings follow.
    public static func validate(_ proposed: String, original: String?, caseSensitive: Bool,
                                exists: (String) -> Bool) -> NameValidation {
        if proposed.isEmpty { return .invalid(.empty) }
        if proposed.utf8.contains(UInt8(ascii: "/")) { return .invalid(.containsSlash) }
        if NameNormalizer.nfc(proposed).utf8.count > maxNameBytes { return .invalid(.tooLong) }
        let sameItem = original.map { NameNormalizer.sameName($0, proposed, caseSensitive: caseSensitive) } ?? false
        if !sameItem && exists(proposed) { return .invalid(.duplicate) }

        var warnings: [NameWarning] = []
        if let original {
            let from = fileExtension(original), to = fileExtension(proposed)
            if !NameNormalizer.sameName(from, to, caseSensitive: false) {
                warnings.append(.extensionChanged(from: from, to: to))
            }
        }
        if proposed.hasPrefix(".") && !(original?.hasPrefix(".") ?? false) { warnings.append(.becomesHidden) }
        return .ok(warnings: warnings)
    }

    /// Text after the last "." that is neither the first nor the last character ("" when there is none),
    /// the same rule as the type and extension-sort keys.
    static func fileExtension(_ name: String) -> String {
        let bytes = Array(name.utf8)
        guard bytes.count > 2, let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < bytes.count - 1 else { return "" }
        return String(decoding: bytes[(dot + 1)...], as: UTF8.self)
    }
}
