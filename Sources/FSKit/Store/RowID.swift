import Foundation

public enum IdentityMode: Sendable, Hashable {
    case objectID                         // idStable volume: identity = Entry.rowID
    case name(caseSensitive: Bool)        // other volumes: identity = normalized name
}

public enum RowID: Hashable, Sendable {
    case object(UInt64)
    case name(String)                     // NFC; lowercased (locale-independent) when the volume is case-insensitive
}

public enum NameNormalizer {
    public static func nfc(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }

    public static func identityName(_ name: String, caseSensitive: Bool) -> String {
        let n = nfc(name)
        return caseSensitive ? n : n.lowercased()
    }

    /// Same-name test used by rename duplicate checks: NFC always, case-insensitive when !caseSensitive.
    /// Compares unicode scalars (Swift's == is already canonical-equivalence based; scalars make it explicit).
    public static func sameName(_ a: String, _ b: String, caseSensitive: Bool) -> Bool {
        identityName(a, caseSensitive: caseSensitive).unicodeScalars
            .elementsEqual(identityName(b, caseSensitive: caseSensitive).unicodeScalars)
    }
}
