import Foundation
import Darwin
import MacxFS

public enum TextEncodingGuess: String, Sendable, Equatable { case utf8, utf16LE, utf16BE, windows1252, latin1 }
public struct TextPreview: Sendable, Equatable {
    public var text: String
    public var truncated: Bool
    public var encoding: TextEncodingGuess
    public init(text: String, truncated: Bool, encoding: TextEncodingGuess) { self.text = text; self.truncated = truncated; self.encoding = encoding }
}
public enum TextPreviewError: Error, Sendable, Equatable { case binary, posix(Int32) }

public enum TextPreviewLoader {
    public static let limit = 262_144

    public static func decode(_ bytes: [UInt8], truncated: Bool) -> TextPreview? {
        func preview(_ s: String, _ e: TextEncodingGuess) -> TextPreview { TextPreview(text: s, truncated: truncated, encoding: e) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return preview(String(decoding: trimPartialUTF8(bytes.dropFirst(3), truncated), as: UTF8.self), .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) { return preview(utf16(bytes.dropFirst(2), littleEndian: true), .utf16LE) }
        if bytes.starts(with: [0xFE, 0xFF]) { return preview(utf16(bytes.dropFirst(2), littleEndian: false), .utf16BE) }
        if bytes.contains(0) {
            guard let le = utf16Parity(bytes) else { return nil }
            return preview(utf16(bytes[...], littleEndian: le), le ? .utf16LE : .utf16BE)
        }
        let body = trimPartialUTF8(bytes[...], truncated)
        // Control bytes are checked before UTF-8 validation: a run of C0 controls is valid UTF-8 but is not text.
        let controls = body.reduce(0) { $1 < 0x20 && ![0x09, 0x0A, 0x0D, 0x0C, 0x1B].contains($1) ? $0 + 1 : $0 }
        if controls * 10 > max(body.count, 1) { return nil }
        if let s = String(validating: body, as: UTF8.self) { return preview(s, .utf8) }
        if let s = String(bytes: body, encoding: .windowsCP1252) { return preview(s, .windows1252) }
        return preview(String(bytes: body, encoding: .isoLatin1) ?? "", .latin1)
    }

    /// true = little endian, false = big endian, nil = not UTF-16.
    static func utf16Parity(_ bytes: [UInt8]) -> Bool? {
        let sample = bytes.prefix(4_096)
        let pairs = sample.count / 2
        guard pairs >= 2 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (i, b) in sample.enumerated() where b == 0 { if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 } }
        let even = Double(evenZeros) / Double(pairs), odd = Double(oddZeros) / Double(pairs)
        if odd > 0.4 && even < 0.05 { return true }
        if even > 0.4 && odd < 0.05 { return false }
        return nil
    }

    static func utf16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
            units.append(littleEndian ? a | b << 8 : a << 8 | b)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Drops a UTF-8 sequence cut off by the read limit (only when truncated).
    static func trimPartialUTF8(_ bytes: ArraySlice<UInt8>, _ truncated: Bool) -> ArraySlice<UInt8> {
        guard truncated, !bytes.isEmpty else { return bytes }
        var i = bytes.endIndex - 1
        var back = 0
        while i > bytes.startIndex && (bytes[i] & 0xC0) == 0x80 && back < 3 { i -= 1; back += 1 }
        let lead = bytes[i]
        let need = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return bytes.endIndex - i < need ? bytes[..<i] : bytes
    }

    public static func load(_ url: URL, lanes: LanePool, volume: VolumeID) async throws(TextPreviewError) -> TextPreview {
        let path = url.path(percentEncoded: false)
        let result: Result<[UInt8], ProbeError>
        do {
            result = try await lanes.perform(on: volume) { _ in withNoMaterialization { PreviewProbe.read(path, count: limit + 1) } }
        } catch {
            throw .posix(ETIMEDOUT)
        }
        switch result {
        case .failure(let e): throw .posix(e.code)
        case .success(let bytes):
            let truncated = bytes.count > limit
            guard let preview = decode(Array(bytes.prefix(limit)), truncated: truncated) else { throw .binary }
            return preview
        }
    }
}
