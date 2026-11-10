import Foundation
import Observation
import Core
import MacxFS

/// The Icon pack popup's items.
enum IconPackChoice: Hashable { case none, current, choose }

/// Settings › General › Icon pack (P4-08): the chosen pack folder is kept as a bookmark in `Settings`, loaded with
/// `IconPackLoader` and handed to the shared `IconCache`. Every file-system step runs on a lane.
@MainActor @Observable
final class IconPackModel {
    /// The applied pack's folder name; nil when no pack is in use.
    private(set) var folderName: String?
    /// "That folder isn't an icon pack." after a failed choice.
    private(set) var error: String?

    @ObservationIgnored private let settings: Core.Settings
    @ObservationIgnored private let lanes: LanePool
    @ObservationIgnored private let icons: IconCache
    /// `--root` of a sandbox run: a stored pack is used only when it lies inside it. nil (and not sandboxed): any.
    @ObservationIgnored private let sandboxRoot: URL?
    @ObservationIgnored private let isSandboxed: Bool

    init(settings: Core.Settings, lanes: LanePool, icons: IconCache, options: LaunchOptions) {
        self.settings = settings
        self.lanes = lanes
        self.icons = icons
        sandboxRoot = options.root
        isSandboxed = options.isSandboxed
    }

    /// What the popup shows: the pack in use, or None.
    var selection: IconPackChoice { folderName == nil ? .none : .current }

    /// The popup: None clears the pack; Choose Folder… asks for a folder (cancel keeps the current pack).
    func select(_ choice: IconPackChoice, chooseFolder: () -> URL?) async {
        switch choice {
        case .none: await clear()
        case .current: break
        case .choose:
            guard let folder = chooseFolder() else { return }
            await choose(folder)
        }
    }

    /// Loads `folder` as the pack, stores its bookmark and applies it. false (with `error` set) when it isn't one.
    @discardableResult
    func choose(_ folder: URL) async -> Bool {
        error = nil
        let lanes = self.lanes
        guard let pack = try? await IconPackLoader.load(folder, lanes: lanes), !pack.isEmpty,
              let bookmark = try? await lanes.perform(on: .unknown, .read, { _ in try folder.bookmarkData(options: []) })
        else {
            error = L10n.string("That folder isn't an icon pack.")
            return false
        }
        settings.iconPackBookmark = bookmark
        await apply(pack)
        return true
    }

    /// Back to the system icons.
    func clear() async {
        error = nil
        settings.iconPackBookmark = nil
        await apply(nil)
    }

    /// At launch: resolves the stored bookmark and applies the pack. A pack that can't be found or read now is left
    /// stored (its volume may be back next time) and nothing is shown. Sandbox runs ignore packs outside `--root`.
    func restore() async {
        guard let bookmark = settings.iconPackBookmark else { return }
        let root = sandboxRoot, sandboxed = isSandboxed
        let folder = try? await lanes.perform(on: .unknown, .read) { _ -> URL? in
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard sandboxed else { return url }
            guard let root else { return nil }
            let base = root.resolvingSymlinksInPath().path(percentEncoded: false)
            let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
            let prefix = base.hasSuffix("/") ? base : base + "/"
            return path.hasPrefix(prefix) ? url : nil
        }
        guard let folder = folder ?? nil,
              let pack = try? await IconPackLoader.load(folder, lanes: lanes), !pack.isEmpty else { return }
        await apply(pack)
    }

    private func apply(_ pack: IconPack?) async {
        await icons.setIconPack(pack)
        folderName = pack?.folder.lastPathComponent
    }
}
