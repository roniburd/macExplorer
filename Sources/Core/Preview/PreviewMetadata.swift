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
    struct Gathered: Sendable { var details: PreviewDetails; var dataless: Bool; var isDirectory: Bool }

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
        if details.duration == nil, !gathered.dataless, !gathered.isDirectory, type.conforms(to: .audiovisualContent),
           let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric {
            details.duration = time.seconds
        }
        return details
    }

    static func gather(_ path: String, type: UTType, kindDescription: String) -> Gathered {
        var details = PreviewDetails(kindDescription: kindDescription)
        var st = stat()
        guard lstat(path, &st) == 0 else { return Gathered(details: details, dataless: false, isDirectory: false) }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
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
        if !dataless && !isDir {
            let fileURL = URL(filePath: path) as CFURL
            if details.pixelWidth == nil, type.conforms(to: .image) {
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                if let source = CGImageSourceCreateWithURL(fileURL, options),
                   let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] {
                    details.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
                    details.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
                }
            }
            if details.pageCount == nil, type.conforms(to: .pdf), let doc = CGPDFDocument(fileURL) {
                details.pageCount = doc.numberOfPages
            }
        }
        return Gathered(details: details, dataless: dataless, isDirectory: isDir)
    }
}
