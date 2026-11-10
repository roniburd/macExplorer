import AppKit
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Core
import MacxFS

/// The 64 pt icon in Properties (P4-08, spec §11 "Custom icons"): drop an image file (or an app or folder, whose
/// icon is taken, like Finder's), or paste one, to set a custom icon; Delete or "Remove Custom Icon" clears it.
/// The view only produces `IconImageData`; the Properties model runs the undoable `setCustomIcon` job.
@MainActor
final class IconWell: NSView, NSUserInterfaceValidations {
    var onDropImage: @MainActor (IconImageData) -> Void = { _ in }
    var onRemove: @MainActor () -> Void = {}
    /// A dropped or pasted file turned out not to be a usable image (too big, not decodable, unreadable).
    var onRefused: @MainActor () -> Void = {}
    var image: NSImage? { didSet { needsDisplay = true } }
    /// Delete removes the custom icon (the item has one).
    var showsRemove = false
    /// False for items whose icon can't be changed (read-only volume): no drop, paste or delete.
    var isEnabled = true { didSet { needsDisplay = true } }
    /// Lane pool for reading dropped files; nil reads on a detached task (tests that build a bare well).
    var lanes: LanePool?
    /// Where Copy and Paste go: the app's pasteboard, or a private one in sandbox runs; nil = no clipboard at all.
    var pasteboardProvider: @MainActor () -> NSPasteboard? = { nil }
    private var isDropTarget = false { didSet { needsDisplay = true } }

    /// Side of the PNG made from another item's icon (an app or folder dropped onto the well).
    nonisolated static let itemIconPixels = 512

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.string("Icon"))
        setAccessibilityIdentifier(AXID.propertiesIconWell)
    }

    required init?(coder: NSCoder) { fatalError("IconWell is created in code") }

    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 64) }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .delete?, .deleteForward?: delete(nil)
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        guard let image, image.size.width > 0, image.size.height > 0 else {
            // No icon to show (several items): an empty well.
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            return
        }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.6)
    }

    // MARK: entry points (drag and paste call these)

    /// The first URL becomes the icon. The answer is synchronous (drag validation): true for an image file (by
    /// extension, `.icns` included) or an app or folder. The read on a lane then decides: `onDropImage` with the
    /// file's bytes (or the item's icon as PNG), or `onRefused` when it is over `IconImageData.maxBytes` or not an image.
    @discardableResult
    func acceptFileURLs(_ urls: [URL]) -> Bool {
        guard isEnabled, let url = urls.first, url.isFileURL, let source = Self.source(for: url) else { return false }
        let lanes = self.lanes
        Task { [weak self] in
            let data = await Self.read(url, source, lanes: lanes)
            guard let self else { return }
            if let data { self.onDropImage(data) } else { self.onRefused() }
        }
        return true
    }

    /// PNG, then TIFF, then a file URL from `pasteboard`. Image data is checked here (in memory) and handed on at once.
    @discardableResult
    func paste(from pasteboard: NSPasteboard) -> Bool {
        guard isEnabled else { return false }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let bytes = pasteboard.data(forType: type) else { continue }
            let data = IconImageData(bytes: bytes)
            guard data.isDecodableImage else { continue }
            onDropImage(data)
            return true
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return acceptFileURLs(urls)
    }

    // MARK: responder actions

    @objc func copy(_ sender: Any?) {
        guard let pasteboard = pasteboardProvider(), let tiff = image?.tiffRepresentation else { return }
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
    }

    @objc func paste(_ sender: Any?) {
        guard let pasteboard = pasteboardProvider() else { return }
        if !paste(from: pasteboard) { NSSound.beep() }
    }

    @objc func delete(_ sender: Any?) {
        guard isEnabled, showsRemove else { return }
        onRemove()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action.map(validate(action:)) ?? false
    }

    func validate(action: Selector) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return image != nil && pasteboardProvider() != nil
        case #selector(paste(_:)):
            guard isEnabled, let pasteboard = pasteboardProvider() else { return false }
            return pasteboard.availableType(from: [.png, .tiff, .fileURL]) != nil
        case #selector(delete(_:)):
            return isEnabled && showsRemove
        default:
            return false
        }
    }

    // MARK: dragging destination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = canAccept(sender.draggingPasteboard)
        isDropTarget = ok
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { isDropTarget = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        return paste(from: sender.draggingPasteboard)
    }

    private func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        guard isEnabled else { return false }
        if pasteboard.availableType(from: [.png, .tiff]) != nil { return true }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first.flatMap(Self.source(for:)) != nil
    }

    // MARK: reading (lane)

    nonisolated enum Source: Sendable { case imageFile, itemIcon }

    /// By name only (no file-system access on the main thread).
    static func source(for url: URL) -> Source? {
        let ext = url.pathExtension.lowercased()
        if ext == "icns" || (UTType(filenameExtension: ext)?.conforms(to: .image) ?? false) { return .imageFile }
        if ext == "app" || url.hasDirectoryPath { return .itemIcon }
        return nil
    }

    private static func read(_ url: URL, _ source: Source, lanes: LanePool?) async -> IconImageData? {
        let work: @Sendable () -> IconImageData? = { withNoMaterialization { readNow(url, source) } }
        if let lanes { return (try? await lanes.perform(on: .unknown, .read) { _ in work() }) ?? nil }
        return await Task.detached { work() }.value
    }

    nonisolated private static func readNow(_ url: URL, _ source: Source) -> IconImageData? {
        let path = url.path(percentEncoded: false)
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        switch source {
        case .imageFile:
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= IconImageData.maxBytes,
                  let bytes = try? Data(contentsOf: url) else { return nil }
            let data = IconImageData(bytes: bytes)
            return data.isDecodableImage ? data : nil
        case .itemIcon:
            guard (st.st_mode & S_IFMT) == S_IFDIR,
                  let raster = IconCache.rasterize(NSWorkspace.shared.icon(forFile: path), pixels: itemIconPixels),
                  let png = pngData(raster) else { return nil }
            let data = IconImageData(bytes: png)
            return data.isDecodableImage ? data : nil
        }
    }

    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// `IconWell` in the SwiftUI Properties form.
struct IconWellView: NSViewRepresentable {
    var image: CGImage?
    var isEnabled: Bool
    var showsRemove: Bool
    var lanes: LanePool
    var pasteboard: @MainActor () -> NSPasteboard?
    var onDropImage: @MainActor (IconImageData) -> Void
    var onRemove: @MainActor () -> Void

    func makeNSView(context: Context) -> IconWell {
        IconWell(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    }

    func updateNSView(_ well: IconWell, context: Context) {
        well.image = image.map { NSImage(cgImage: $0, size: NSSize(width: 64, height: 64)) }
        well.isEnabled = isEnabled
        well.showsRemove = showsRemove
        well.lanes = lanes
        well.pasteboardProvider = pasteboard
        well.onDropImage = onDropImage
        well.onRemove = onRemove
    }
}
