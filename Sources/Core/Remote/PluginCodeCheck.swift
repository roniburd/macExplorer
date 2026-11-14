import Foundation
import Security

/// Whether a plugin bundle may be loaded into this process (spec §5.2).
public protocol PluginCodeCheck: Sendable {
    func signedLikeApp(_ bundle: URL) -> Bool
    /// The identity of the code that passed `signedLikeApp` (production: the executable's cdhash), or nil when the
    /// bundle fails the check. `PluginLoader` takes it right before loading and again right after, and refuses the
    /// plugin when the two differ, so a bundle swapped on disk between the check and the load is not used.
    func codeIdentity(_ bundle: URL) -> Data?
}

public extension PluginCodeCheck {
    /// Fakes that only answer yes/no: every passing bundle has the same (empty) identity.
    func codeIdentity(_ bundle: URL) -> Data? { signedLikeApp(bundle) ? Data() : nil }
}

/// Production: the plugin's leaf signing certificate must equal the app's (same cert or refuse). An unsigned or
/// ad-hoc-signed bundle (no certificate chain) and an invalid signature are refused.
public struct SecCodePluginCheck: PluginCodeCheck {
    let appBundle: URL
    public init(appBundle: URL = Bundle.main.bundleURL) { self.appBundle = appBundle }

    public func signedLikeApp(_ bundle: URL) -> Bool { codeIdentity(bundle) != nil }

    /// The plugin's cdhash, when its signature is valid and its leaf certificate equals the app's.
    public func codeIdentity(_ bundle: URL) -> Data? {
        guard let plugin = Self.signature(of: bundle), let app = Self.signature(of: appBundle), plugin.leaf == app.leaf
        else { return nil }
        return plugin.cdhash
    }

    /// The leaf certificate and cdhash of a statically valid signature, or nil.
    static func signature(of url: URL) -> (leaf: Data, cdhash: Data)? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let chain = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = chain.first,
              let cdhash = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return (SecCertificateCopyData(leaf) as Data, cdhash)
    }
}

/// Sandboxed runs with `--plugins-dir` (tests and scripts only): any signature. Never used for the real folder.
public struct AnySignatureCheck: PluginCodeCheck {
    public init() {}
    public func signedLikeApp(_ bundle: URL) -> Bool { true }
}
