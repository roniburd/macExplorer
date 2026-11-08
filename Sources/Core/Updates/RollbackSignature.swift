import CryptoKit
import Foundation

/// Sparkle's EdDSA check for a downloaded archive: `sparkle:edSignature` is a base64 Ed25519 signature of the whole
/// file, `SUPublicEDKey` the base64 raw public key (checked against the real beta.13 zip, 2026-11-08).
public enum RollbackSignature {
    public static func isValid(data: Data, signature: String, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: signature) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    public static func isValid(file: URL, signature: String, publicKey: String) -> Bool {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        return isValid(data: data, signature: signature, publicKey: publicKey)
    }
}
