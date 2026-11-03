import AppKit
import UniformTypeIdentifiers
import os
import Core
import MacxFS

/// §4.4 icon tiers. Tier 0: one NSWorkspace type icon per (UTType, pixel size), rasterized once, available on the
/// first frame. Tier 1: per-file icons for apps, volumes, .icns files and custom-icon items, fetched for visible
/// rows only on a read lane under withNoMaterialization. Tier 2 (thumbnails) is Phase 2.
@MainActor
final class IconCache {
    private struct TypeKey: Hashable { let type: UInt16; let pixels: Int }
    private struct FileKey: Hashable { let id: RowID; let path: String; let pixels: Int }

    static let fileCacheLimit = 2_000
    private let lanes: LanePool
    private let types: TypeRegistry
    private var typeImages: [TypeKey: CGImage] = [:]
    private var fileImages: [FileKey: CGImage] = [:]
    private var fileOrder: [FileKey] = []
    private var pending: [FileKey: Task<Void, Never>] = [:]
    private var waiting: [FileKey: [@MainActor (CGImage) -> Void]] = [:]
    private var iconFill: OSSignpostIntervalState?
    /// Volume for a URL's lane (set by ContentViewController from Volumes); VolumeID.unknown when nil.
    var volumeLookup: (@MainActor (URL) -> VolumeID)?

    init(lanes: LanePool, types: TypeRegistry) {
        self.lanes = lanes
        self.types = types
    }

    func typeIcon(_ typeIndex: UInt16, points: Double, scale: Double) -> CGImage {
        let pixels = max(1, Int((points * scale).rounded()))
        let key = TypeKey(type: typeIndex, pixels: pixels)
        if let cached = typeImages[key] { return cached }
        let image = NSWorkspace.shared.icon(for: types.type(at: typeIndex))   // per type, not per path (§4.4 Tier 0)
        let raster = Self.rasterize(image, pixels: pixels) ?? Self.blank(pixels: pixels)
        typeImages[key] = raster
        return raster
    }

    /// Tier 1 eligibility (§4.4): apps, volume roots, .icns files and custom-icon items; never dataless items.
    func needsFileIcon(_ entry: Entry, name: String, isVolumeRoot: Bool) -> Bool {
        if entry.flags.contains(.dataless) { return false }
        if entry.flags.contains(.customIcon) || isVolumeRoot { return true }
        if entry.kind == .package && types.isApplication(entry.typeIndex) { return true }
        return entry.kind == .file && name.lowercased().hasSuffix(".icns")
    }

    func fileIcon(for url: URL, rowID: RowID, points: Double, scale: Double,
                  completion: @escaping @MainActor (CGImage) -> Void) {
        let pixels = max(1, Int((points * scale).rounded()))
        let key = FileKey(id: rowID, path: url.path, pixels: pixels)
        if let cached = fileImages[key] { completion(cached); return }
        if waiting[key] != nil { waiting[key]?.append(completion); return }
        waiting[key] = [completion]
        if pending.isEmpty { iconFill = PerfSignposts.signposter.beginInterval(PerfSignposts.iconFill) }
        let volume = volumeLookup?(url) ?? .unknown
        let lanes = self.lanes
        let path = url.path
        pending[key] = Task { [weak self] in
            let image: CGImage? = try? await lanes.perform(on: volume, .read) { _ in
                withNoMaterialization {
                    IconCache.rasterize(NSWorkspace.shared.icon(forFile: path), pixels: pixels)
                }
            }
            self?.landed(key, image: image)
        }
    }

    func cancelFileIcons(notIn visible: Set<RowID>) {
        for (key, task) in pending where !visible.contains(key.id) {
            task.cancel()
            pending[key] = nil
            waiting[key] = nil
        }
        endIconFillIfIdle()
    }

    private func landed(_ key: FileKey, image: CGImage?) {
        pending[key] = nil
        let callbacks = waiting.removeValue(forKey: key) ?? []
        if let image {
            if fileImages[key] == nil { fileOrder.append(key) }
            fileImages[key] = image
            if fileOrder.count > Self.fileCacheLimit { fileImages[fileOrder.removeFirst()] = nil }
            for callback in callbacks { callback(image) }
        }
        endIconFillIfIdle()
    }

    private func endIconFillIfIdle() {
        guard pending.isEmpty, let state = iconFill else { return }
        PerfSignposts.signposter.endInterval(PerfSignposts.iconFill, state)
        iconFill = nil
    }

    nonisolated static func rasterize(_ image: NSImage, pixels: Int) -> CGImage? {
        let side = max(pixels, 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func blank(pixels: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
