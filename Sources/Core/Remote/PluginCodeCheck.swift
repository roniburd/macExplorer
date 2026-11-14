import Foundation
import Security
import Synchronization

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
/// ad-hoc-signed bundle (no certificate chain) and an invalid signature are refused. The app's own signature is
/// validated once (the first check), not per plugin; checks hash files, so `PluginLoader` runs them off the main actor.
public struct SecCodePluginCheck: PluginCodeCheck {
    let appBundle: URL
    private let appLeaf = AppLeaf()
    public init(appBundle: URL = Bundle.main.bundleURL) { self.appBundle = appBundle }

    public func signedLikeApp(_ bundle: URL) -> Bool { codeIdentity(bundle) != nil }

    /// The plugin's cdhash, when its signature is valid and its leaf certificate equals the app's.
    public func codeIdentity(_ bundle: URL) -> Data? {
        guard let app = appLeaf.value(appBundle), let plugin = Self.signature(of: bundle), plugin.leaf == app
        else { return nil }
        return plugin.cdhash
    }

    /// Whether `bundle` is signed with a certificate (not ad-hoc, not unsigned). Reads the signature only (no
    /// validation, no file hashing).
    public static func hasCertificate(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let chain = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return false }
        return !chain.isEmpty
    }

    /// The app's validated leaf certificate, computed on first use and kept (nil when the app fails validation).
    private final class AppLeaf: Sendable {
        private let state = Mutex<Data??>(nil)
        func value(_ appBundle: URL) -> Data? {
            state.withLock { cached in
                if let cached { return cached }
                let leaf = SecCodePluginCheck.signature(of: appBundle)?.leaf
                cached = .some(leaf)
                return leaf
            }
        }
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

/// `--plugins-dir` (tests and scripts only) in a debug build or an ad-hoc-signed app: any signature. Never used for
/// the real folder, and never in a certificate-signed release build (there `--plugins-dir` gets `SecCodePluginCheck`).
public struct AnySignatureCheck: PluginCodeCheck {
    public init() {}
    public func signedLikeApp(_ bundle: URL) -> Bool { true }
}
