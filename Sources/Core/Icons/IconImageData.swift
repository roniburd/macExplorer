import Foundation
import CoreGraphics
import ImageIO

/// The bytes of an icon image (PNG, JPEG, ICNS, … anything ImageIO decodes). Kept in undo records only (in memory);
/// never written to the journal.
public struct IconImageData: Sendable, Codable, Equatable {
    public var bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
    public static let maxBytes = 10 * 1024 * 1024
    /// At most `maxBytes` and decodable by ImageIO (at least one image).
    public var isDecodableImage: Bool {
        guard !bytes.isEmpty, bytes.count <= Self.maxBytes,
              let src = CGImageSourceCreateWithData(bytes as CFData, nil) else { return false }
        return CGImageSourceGetCount(src) > 0 && CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
    }
}

/// Reads and writes an item's stored custom icon. Lane only: implementations do file-system I/O.
public protocol CustomIconWriting: Sendable {
    /// The stored custom icon, nil when the item has none or it can't be read (see `storedCustomIcon`).
    func currentCustomIcon(_ url: URL) throws -> IconImageData?
    /// Tells "no custom icon" apart from "marked as having one that can't be read". Default: from `currentCustomIcon`.
    func storedCustomIcon(_ url: URL) throws -> StoredCustomIcon
    /// nil removes the custom icon.
    func setIcon(_ data: IconImageData?, for url: URL) throws
}

/// What an item's custom icon is, as far as it can be read back.
public enum StoredCustomIcon: Sendable, Equatable {
    case none
    case image(IconImageData)
    /// The item is marked as having a custom icon (kHasCustomIcon), but no icon could be read: no `Icon\r`, no
    /// icns resource, or a malformed resource fork. Undo could never put it back.
    case unreadable

    public var image: IconImageData? { if case .image(let data) = self { data } else { nil } }
}

extension CustomIconWriting {
    public func storedCustomIcon(_ url: URL) throws -> StoredCustomIcon {
        try currentCustomIcon(url).map(StoredCustomIcon.image) ?? .none
    }
}

/// Undo uses this to tell whether an item still has the icon a job gave it: macOS re-encodes what it stores (a PNG
/// comes back as ICNS), so equal bytes are not required. Equal bytes → same; otherwise both are drawn into a 32×32
/// sRGB bitmap and compared with a small per-channel tolerance (re-encoding rounds colours).
enum IconCompare {
    static let side = 32
    static let tolerance = 6

    static func sameImage(_ a: IconImageData?, _ b: IconImageData?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (a?, b?):
            if a.bytes == b.bytes { return true }
            guard let pa = pixels(a), let pb = pixels(b) else { return false }
            return zip(pa, pb).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
        }
    }

    /// RGBA bytes of the largest image in `data`, drawn at 32×32.
    static func pixels(_ data: IconImageData) -> [UInt8]? {
        guard data.isDecodableImage, let src = CGImageSourceCreateWithData(data.bytes as CFData, nil) else { return nil }
        var best: CGImage?
        for i in 0..<CGImageSourceGetCount(src) {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            if best.map({ image.width > $0.width }) ?? true { best = image }
        }
        guard let image = best, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var out = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? out : nil
    }
}
