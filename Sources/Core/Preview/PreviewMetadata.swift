import Foundation
import Darwin
import CoreServices
import ImageIO
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers
import MacxFS

public struct PreviewDetails: Sendable, Equatable {
    public var size: Int64?
    public var created: Date?
    public var modified: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var pageCount: Int?
    public var kindDescription: String
    public init(size: Int64? = nil, created: Date? = nil, modified: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
                duration: Double? = nil, pageCount: Int? = nil, kindDescription: String) {
        self.size = size; self.created = created; self.modified = modified; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.duration = duration; self.pageCount = pageCount; self.kindDescription = kindDescription
    }
}

public enum PreviewMetadata {
    struct Gathered: Sendable { var details: PreviewDetails; var dataless: Bool; var isDirectory: Bool; var isRegular: Bool }

    public static func load(_ url: URL, typeIndex: UInt16, types: TypeRegistry, lanes: LanePool, volume: VolumeID) async -> PreviewDetails {
        let type = types.type(at: typeIndex)
        let kind = types.localizedDescription(typeIndex)
        let path = url.path(percentEncoded: false)
        let gathered: Gathered
        do {
            gathered = try await lanes.perform(on: volume) { _ in
                withNoMaterialization { gather(path, type: type, kindDescription: kind) }
            }
        } catch {
            return PreviewDetails(kindDescription: kind)
        }
        var details = gathered.details
        // AVFoundation runs outside the lane and outside withNoMaterialization, and follows links: re-check that the
        // target is still materialized right before it opens the file (it could have been evicted since `gather`).
        guard details.duration == nil, !gathered.dataless, gathered.isRegular, type.conforms(to: .audiovisualContent) else {
            return details
        }
        let materialized = (try? await lanes.perform(on: volume) { _ in withNoMaterialization { isMaterializedFile(path) } }) ?? false
        if materialized, let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric {
            details.duration = time.seconds
        }
        return details
    }

    /// The link target (or the file itself) exists, is a regular file (not a folder, FIFO or device) and is not
    /// dataless. Lane only.
    static func isMaterializedFile(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG && st.st_flags & UInt32(SF_DATALESS) == 0
    }

    static func gather(_ path: String, type: UTType, kindDescription: String) -> Gathered {
        var details = PreviewDetails(kindDescription: kindDescription)
        var st = stat()
        guard lstat(path, &st) == 0 else { return Gathered(details: details, dataless: false, isDirectory: false, isRegular: false) }
        // A symlink is described by its target, as PreviewPlanner classifies it (a broken link keeps its own stat).
        if (st.st_mode & S_IFMT) == S_IFLNK {
            var target = stat()
            if stat(path, &target) == 0 { st = target }
        }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let isRegular = (st.st_mode & S_IFMT) == S_IFREG     // FIFOs / devices: ImageIO, PDF and AVFoundation would block
        let dataless = st.st_flags & UInt32(SF_DATALESS) != 0
        func date(_ t: timespec) -> Date { Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9) }
        details.size = isDir ? nil : Int64(st.st_size)
        details.created = date(st.st_birthtimespec)
        details.modified = date(st.st_mtimespec)
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString) {
            func number(_ key: CFString) -> NSNumber? { MDItemCopyAttribute(item, key) as? NSNumber }
            details.pixelWidth = number(kMDItemPixelWidth)?.intValue
            details.pixelHeight = number(kMDItemPixelHeight)?.intValue
            details.duration = number(kMDItemDurationSeconds)?.doubleValue
            details.pageCount = number(kMDItemNumberOfPages)?.intValue
        }
        if !dataless && isRegular {
            let fileURL = URL(filePath: path) as CFURL
            if details.pixelWidth == nil, type.conforms(to: .image) {
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                if let source = CGImageSourceCreateWithURL(fileURL, options),
                   let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] {
                    details.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
                    details.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
                }
            }
            if details.pixelWidth == nil, type.conforms(to: .svg),
               case .success(let prefix) = PreviewProbe.read(path, count: 8_192), let size = svgSize(prefix) {
                details.pixelWidth = size.width
                details.pixelHeight = size.height
            }
            if details.pageCount == nil, type.conforms(to: .pdf), let doc = CGPDFDocument(fileURL) {
                details.pageCount = doc.numberOfPages
            }
        }
        return Gathered(details: details, dataless: dataless, isDirectory: isDir, isRegular: isRegular)
    }

    /// An SVG's intrinsic size from its root element: absolute `width` / `height` (unitless or px), else the
    /// `viewBox` size; nil when neither gives one (relative units like %, em). Rounded to whole pixels.
    static func svgSize(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let open = text.range(of: #"<svg[\s>]"#, options: .regularExpression),
              let close = text[open.lowerBound...].firstIndex(of: ">") else { return nil }
        let tag = text[open.lowerBound..<close]
        func attribute(_ name: String) -> String? {
            guard let r = tag.range(of: #"\s\#(name)\s*=\s*("[^"]*"|'[^']*')"#, options: .regularExpression) else { return nil }
            let value = tag[r].drop { $0 != "\"" && $0 != "'" }
            return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        func length(_ s: String?) -> Double? {
            guard var s else { return nil }
            if s.hasSuffix("px") { s.removeLast(2) }
            guard let v = Double(s.trimmingCharacters(in: .whitespaces)), v > 0, v.isFinite else { return nil }
            return v
        }
        if let w = length(attribute("width")), let h = length(attribute("height")) {
            return (Int(w.rounded()), Int(h.rounded()))
        }
        let box = attribute("viewBox")?.split { $0 == " " || $0 == "," }.compactMap { Double($0) } ?? []
        guard box.count == 4, box[2] > 0, box[3] > 0, box[2].isFinite, box[3].isFinite else { return nil }
        return (Int(box[2].rounded()), Int(box[3].rounded()))
    }
}
