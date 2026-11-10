import AppKit
import Synchronization
import UniformTypeIdentifiers
import os
import Core
import MacxFS

/// §4.4 icon tiers. Tier 0: one NSWorkspace type icon per (UTType, pixel size), rasterized once, available on the
/// first frame. Tier 1: per-file icons for apps, volumes, .icns files and custom-icon items, fetched for visible
/// rows only on a read lane under withNoMaterialization. Tier 2 (thumbnails) is Phase 2.
/// An icon pack (P4-08) replaces Tier 0 type icons only: its images are rasterized on a lane when it is set, before
/// it takes effect, so the first frame afterwards has every image.
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
    /// The newest request per key: a result from an older (invalidated or superseded) request is dropped.
    private var requestTokens: [FileKey: Int] = [:]
    private var nextToken = 0
    private var waiting: [FileKey: [@MainActor (CGImage) -> Void]] = [:]
    private var iconFill: OSSignpostIntervalState?
    /// Volume for a URL's lane (set by ContentViewController from Volumes); VolumeID.unknown when nil.
    var volumeLookup: (@MainActor (URL) -> VolumeID)?

    /// Posted (object: the cache) after `setIconPack` switched packs; every visible list redraws its rows.
    static let iconPackChanged = Notification.Name("macx.iconPackChanged")
    /// Pixel sizes each pack image is rasterized at; other sizes are scaled from the nearest larger one once.
    nonisolated static let packPixelSizes = [16, 32, 64, 128, 256]
    /// `packImages` key of the pack's `folder.<fmt>` (no extension can contain a NUL).
    nonisolated static let packFolderKey = "\u{0}folder"
    private(set) var currentPack: IconPack?
    private var packImages: [String: [Int: CGImage]] = [:]
    private var packGeneration = 0

    init(lanes: LanePool, types: TypeRegistry) {
        self.lanes = lanes
        self.types = types
    }

    func typeIcon(_ typeIndex: UInt16, points: Double, scale: Double) -> CGImage {
        let pixels = max(1, Int((points * scale).rounded()))
        let key = TypeKey(type: typeIndex, pixels: pixels)
        if let cached = typeImages[key] { return cached }
        if currentPack != nil, let packed = packIcon(typeIndex, pixels: pixels) {
            typeImages[key] = packed
            return packed
        }
        let image = NSWorkspace.shared.icon(for: types.type(at: typeIndex))   // per type, not per path (§4.4 Tier 0)
        let raster = Self.rasterize(image, pixels: pixels) ?? Self.blank(pixels: pixels)
        typeImages[key] = raster
        return raster
    }

    /// Switches to `pack` (nil: back to the system icons). The pack's images are read and rasterized on a lane first;
    /// a later call wins over one still rasterizing. Images that can't be decoded are left out (system icon).
    func setIconPack(_ pack: IconPack?) async {
        packGeneration += 1
        let generation = packGeneration
        var images: [String: [Int: CGImage]] = [:]
        if let pack {
            images = (try? await lanes.perform(on: .unknown, .read) { context in
                try withNoMaterialization { try IconCache.rasterizePack(pack, context: context) }
            }) ?? [:]
            guard generation == packGeneration else { return }   // a newer pack (or none) was set meanwhile
        }
        currentPack = pack
        packImages = images
        typeImages = [:]
        NotificationCenter.default.post(name: Self.iconPackChanged, object: self)
    }

    /// The pack's image for a type at `pixels`: the folder icon for folders, else the first of the type's extensions
    /// the pack has. The nearest rasterized size ≥ `pixels` (else the largest), scaled once to `pixels`.
    private func packIcon(_ typeIndex: UInt16, pixels: Int) -> CGImage? {
        let keys = typeIndex == TypeRegistry.folderIndex ? [Self.packFolderKey] : types.extensionStrings(at: typeIndex)
        guard let sizes = keys.lazy.compactMap({ self.packImages[$0] }).first, !sizes.isEmpty else { return nil }
        let source = sizes.keys.filter { $0 >= pixels }.min().flatMap { sizes[$0] } ?? sizes[sizes.keys.max()!]!
        if source.width == pixels && source.height == pixels { return source }
        return Self.scale(source, to: pixels)
    }

    /// Lane work: each pack image decoded once and drawn (aspect fit) at every `packPixelSizes` size. Images are spread
    /// over every core (in batches, with a heartbeat and a cancellation check between them), so a 2,000-image pack is
    /// ready about as fast as a few hundred serially and the launch wait for it (`UIContext`) rarely times out.
    nonisolated static func rasterizePack(_ pack: IconPack, context: LaneContext) throws -> [String: [Int: CGImage]] {
        var files = pack.byExtension.map { ($0.key, $0.value) }
        if let folder = pack.folderIcon { files.append((packFolderKey, folder)) }
        let results = Mutex<[String: [Int: CGImage]]>([:])
        let batch = 64
        for start in stride(from: 0, to: files.count, by: batch) {
            if context.isCancelled { throw LaneError.cancelled }
            context.heartbeat()
            let slice = Array(files[start..<min(start + batch, files.count)])
            DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                let (key, url) = slice[i]
                // The no-materialization policy is per thread: each worker sets it for its own reads.
                guard let sizes = withNoMaterialization({ rasterizePackImage(url) }) else { return }
                results.withLock { $0[key] = sizes }
            }
        }
        return results.withLock { $0 }
    }

    /// One pack file at every `packPixelSizes` size; nil when it can't be read or decoded.
    nonisolated private static func rasterizePackImage(_ url: URL) -> [Int: CGImage]? {
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else { return nil }
        var sizes: [Int: CGImage] = [:]
        for pixels in packPixelSizes { sizes[pixels] = rasterizeFitting(image, pixels: pixels) }
        return sizes.isEmpty ? nil : sizes
    }

    /// Like `rasterize`, keeping the image's aspect ratio (centred in the square).
    nonisolated static func rasterizeFitting(_ image: NSImage, pixels: Int) -> CGImage? {
        let side = max(pixels, 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = image.size
        let fit = min(Double(side) / size.width, Double(side) / size.height)
        let rect = NSRect(x: (Double(side) - size.width * fit) / 2, y: (Double(side) - size.height * fit) / 2,
                          width: size.width * fit, height: size.height * fit)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func scale(_ image: CGImage, to pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage()
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
        nextToken += 1
        let token = nextToken
        requestTokens[key] = token
        pending[key] = Task { [weak self] in
            let image: CGImage? = try? await lanes.perform(on: volume, .read) { _ in
                withNoMaterialization {
                    IconCache.rasterize(NSWorkspace.shared.icon(forFile: path), pixels: pixels)
                }
            }
            self?.landed(key, token: token, image: image)
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

    /// Drops every cached Tier 1 image of `rowID` (all sizes) and cancels its pending requests (P4-07: the item's
    /// custom icon changed). The next `fileIcon` call fetches it again.
    func invalidate(rowID: RowID) {
        invalidateFileImages { $0.id == rowID }
    }

    /// Same, by file path: lists that key rows differently (Properties' `.name(path)`) see the change too.
    func invalidate(path: String) {
        invalidateFileImages { $0.path == path }
    }

    private func invalidateFileImages(where matches: (FileKey) -> Bool) {
        for key in fileImages.keys where matches(key) { fileImages[key] = nil }
        fileOrder.removeAll(where: matches)
        for key in requestTokens.keys where matches(key) { requestTokens[key] = nil }   // in-flight reads are stale
        for (key, task) in pending where matches(key) {
            task.cancel()
            pending[key] = nil
            waiting[key] = nil
        }
        endIconFillIfIdle()
    }

    /// Test hook: whether a Tier 1 image is cached for `rowID` (any size).
    func hasCachedFileIcon(rowID: RowID) -> Bool { fileImages.keys.contains { $0.id == rowID } }

    private func landed(_ key: FileKey, token: Int, image: CGImage?) {
        guard requestTokens[key] == token else { return }    // invalidated or superseded since it was asked for
        requestTokens[key] = nil
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
