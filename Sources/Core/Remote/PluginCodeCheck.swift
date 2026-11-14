import Foundation
import Security

/// Whether a plugin bundle may be loaded into this process (spec §5.2).
public protocol PluginCodeCheck: Sendable {
    func signedLikeApp(_ bundle: URL) -> Bool
}

/// Production: the plugin's leaf signing certificate must equal the app's (same cert or refuse). An unsigned or
/// ad-hoc-signed bundle (no certificate chain) and an invalid signature are refused.
public struct SecCodePluginCheck: PluginCodeCheck {
    let appBundle: URL
    public init(appBundle: URL = Bundle.main.bundleURL) { self.appBundle = appBundle }

    public func signedLikeApp(_ bundle: URL) -> Bool {
        guard let plugin = Self.leafCertificate(of: bundle), let app = Self.leafCertificate(of: appBundle) else { return false }
        return plugin == app
    }

    static func leafCertificate(of url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let chain = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = chain.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}

/// Sandboxed runs with `--plugins-dir` (tests and scripts only): any signature. Never used for the real folder.
public struct AnySignatureCheck: PluginCodeCheck {
    public init() {}
    public func signedLikeApp(_ bundle: URL) -> Bool { true }
}
