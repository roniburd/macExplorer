import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Guarded metadata writers (Phase 2 plan P2-03). Every path goes through `url(_:)`, which traps outside the
/// root after symlink and ".." resolution, so a fixture can only ever tag, date or write files it created.
/// Plain xattr and mode writes use the Phase 1 `setXattr(_:name:value:)` and `setMode(_:_:)`.
public extension Sandbox {
    static let finderTagsXattr = "com.apple.metadata:_kMDItemUserTags"
    static let finderCommentXattr = "com.apple.metadata:kMDItemFinderComment"
    static let lastUsedDateXattr = "com.apple.lastuseddate#PS"

    func setModificationDate(_ date: Date, on relativePath: String) throws {
        try setDates(relativePath, modified: date)
    }

    /// Finder stores tags as a binary plist array of "Name\n<colour index>"; colour 0 (none) is written as "Name".
    func setFinderTags(_ tags: [String], on relativePath: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        try setXattr(relativePath, name: Sandbox.finderTagsXattr, value: data)
    }

    /// Binary plist string, as Finder's Get Info writes it.
    func setFinderComment(_ comment: String, on relativePath: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: comment, format: .binary, options: 0)
        try setXattr(relativePath, name: Sandbox.finderCommentXattr, value: data)
    }

    /// 16 bytes: tv_sec (Int64, little endian), tv_nsec (Int64, little endian).
    func setLastUsedDate(_ date: Date, on relativePath: String) throws {
        try setXattr(relativePath, name: Sandbox.lastUsedDateXattr, value: Sandbox.lastUsedDateValue(date))
    }

    static func lastUsedDateValue(_ date: Date) -> Data {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let secs = Int64(seconds)
        let nsec = Int64(((date.timeIntervalSince1970 - seconds) * 1e9).rounded())
        var data = Data()
        withUnsafeBytes(of: secs.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: nsec.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Solid-colour PNG (fails if the file exists), so Quick Look and thumbnails have a real image.
    @discardableResult
    func writePNG(_ relativePath: String, pixels: Int = 64, red: CGFloat = 0.2, green: CGFloat = 0.5, blue: CGFloat = 0.9) throws -> URL {
        guard let data = Sandbox.pngData(pixels: pixels, red: red, green: green, blue: blue) else { throw POSIXError(.EIO) }
        return try createFile(relativePath, contents: data)
    }

    static func pngData(pixels: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let output = NSMutableData()
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }

    /// Noon local time, `days` from today (0 = today, -1 = yesterday).
    static func noon(daysFromToday days: Int, calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) -> Date {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: days, to: start)!
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
    }
}
