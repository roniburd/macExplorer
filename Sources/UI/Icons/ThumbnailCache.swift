// Sources/UI/Icons/ThumbnailCache.swift
import AppKit
import Core
import MacxFS

/// One thumbnail: the file's identity plus everything that changes its picture (§4.2 Tier 2). `.name` identities
/// are only unique within their directory, hence `directory`. `pixels` is the requested side in pixels, so a new
/// icon size (or backing scale) is a new key.
struct ThumbnailKey: Hashable, Sendable {
    var volume: VolumeID
    var id: RowID
    var directory: String
    var mtime: Int64
    var size: Int64
    var pixels: Int
}

/// A visible, eligible grid item: its key and the file to render.
struct ThumbnailCandidate {
    var key: ThumbnailKey
    var url: URL
}

/// Opaque handle for one generator request, used to cancel it.
struct ThumbnailTicket: Hashable { let raw: UInt64 }

/// Shared thumbnail images: an NSCache costed at width × height × 4 bytes, 64 MB by default.
@MainActor
final class ThumbnailCache {
    private final class KeyBox: NSObject {
        let key: ThumbnailKey
        init(_ key: ThumbnailKey) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
    }
    private final class ImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private let cache = NSCache<KeyBox, ImageBox>()

    init(costLimit: Int = 64 << 20) { cache.totalCostLimit = costLimit }

    func image(_ key: ThumbnailKey) -> CGImage? { cache.object(forKey: KeyBox(key))?.image }

    func store(_ image: CGImage, for key: ThumbnailKey) {
        cache.setObject(ImageBox(image), forKey: KeyBox(key), cost: image.width * image.height * 4)
    }
}
