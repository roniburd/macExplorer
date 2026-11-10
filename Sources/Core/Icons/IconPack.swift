import Darwin
import Foundation
import MacxFS

public enum IconPackError: Error, Sendable, Equatable { case notAFolder, unreadable(Int32) }

/// An icon pack (spec §11 Phase 4, "shown in the app only"): a folder of `<extension>.<fmt>` files, for example
/// `pdf.icns`, `swift.png`, `md.pdf`, plus optionally `folder.<fmt>` for plain folders.
/// - `<fmt>` is one of `formatPriority`; when several exist for one extension, the earliest in the list wins.
/// - Names are matched case-insensitively. Subfolders, symlinks, dotfiles, names with more than one dot and files
///   over 1 MiB are ignored; at most `maxEntries` extensions are loaded (in name order).
/// - A pack replaces Tier 0 type icons only. Tier 1 icons (apps, custom icons, volumes, `.icns` files) are unchanged.
public struct IconPack: Sendable, Equatable {
    public var folder: URL
    /// Lowercased extension → image file.
    public var byExtension: [String: URL]
    /// `folder.<fmt>`.
    public var folderIcon: URL?
    public static let formatPriority = ["icns", "png", "pdf", "tiff", "jpg"]
    static let maxFileBytes = 1 << 20
    public static let maxEntries = 2_000

    public init(folder: URL, byExtension: [String: URL], folderIcon: URL?) {
        self.folder = folder
        self.byExtension = byExtension
        self.folderIcon = folderIcon
    }

    /// No usable image at all: Settings says "That folder isn't an icon pack."
    public var isEmpty: Bool { byExtension.isEmpty && folderIcon == nil }
}

public enum IconPackLoader {
    /// Lists the pack folder on a read lane (no image is decoded here; `IconCache.setIconPack` rasterizes them).
    public static func load(_ folder: URL, lanes: LanePool) async throws -> IconPack {
        try await lanes.perform(on: .unknown, .read) { _ in try read(folder) }
    }

    static func read(_ folder: URL) throws -> IconPack {
        let path = folder.path(percentEncoded: false)
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw IconPackError.notAFolder }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: path) }
        catch { throw IconPackError.unreadable((error as NSError).code == NSFileReadNoPermissionError ? EACCES : EIO) }
        var best: [String: (rank: Int, url: URL)] = [:]
        var folderIcon: (rank: Int, url: URL)?
        for name in names.sorted() where !name.hasPrefix(".") {
            let fmt = (name as NSString).pathExtension.lowercased()
            guard let rank = IconPack.formatPriority.firstIndex(of: fmt) else { continue }
            let key = (name as NSString).deletingPathExtension.lowercased()
            guard !key.isEmpty, !key.contains(".") else { continue }
            let isFolderKey = key == "folder"
            if isFolderKey, let current = folderIcon, current.rank <= rank { continue }
            if !isFolderKey {
                if let current = best[key], current.rank <= rank { continue }
                if best[key] == nil, best.count >= IconPack.maxEntries { continue }
            }
            let url = folder.appending(path: name, directoryHint: .notDirectory)
            var item = stat()
            guard lstat(url.path(percentEncoded: false), &item) == 0, (item.st_mode & S_IFMT) == S_IFREG,
                  item.st_size <= IconPack.maxFileBytes else { continue }
            if isFolderKey { folderIcon = (rank, url) } else { best[key] = (rank, url) }
        }
        return IconPack(folder: folder, byExtension: best.mapValues(\.url), folderIcon: folderIcon?.url)
    }
}
