import Foundation

/// Every user-visible string goes through here. Keys are the English text (String Catalog
/// `Sources/UI/Resources/Localizable.xcstrings`); a missing key returns the key itself.
public enum L10n {
    public static func string(_ key: String) -> String {
        UIResources.bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
