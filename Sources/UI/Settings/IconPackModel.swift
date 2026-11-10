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
    /// Bumped by every choose / clear / restore: an older one still loading or rasterizing when a newer one starts
    /// neither stores its bookmark nor touches `folderName`, so the popup, the stored bookmark and the applied pack
    /// always agree (QA round 2).
    @ObservationIgnored private var generation = 0

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
        generation += 1
        let mine = generation
        let lanes = self.lanes
        let pack = try? await IconPackLoader.load(folder, lanes: lanes)
        let bookmark = pack.map { !$0.isEmpty } == true
            ? try? await lanes.perform(on: .unknown, .read, { _ in try folder.bookmarkData(options: []) }) : nil
        guard mine == generation else { return false }             // a newer choice (or None) replaced this one
        guard let pack, !pack.isEmpty, let bookmark else {
            error = L10n.string("That folder isn't an icon pack.")
            return false
        }
        settings.iconPackBookmark = bookmark
        return await apply(pack, generation: mine)
    }

    /// Back to the system icons.
    func clear() async {
        error = nil
        generation += 1
        settings.iconPackBookmark = nil
        await apply(nil, generation: generation)
    }

    /// At launch: resolves the stored bookmark and applies the pack. A pack that can't be found or read now is left
    /// stored (its volume may be back next time) and nothing is shown. Sandbox runs ignore packs outside `--root`.
    func restore() async {
        guard let bookmark = settings.iconPackBookmark else { return }
        generation += 1
        let mine = generation
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
              let pack = try? await IconPackLoader.load(folder, lanes: lanes), !pack.isEmpty,
              mine == generation else { return }
        await apply(pack, generation: mine)
    }

    /// Applies `pack` and shows it in the popup, unless a newer choice replaced it meanwhile (then that one shows).
    @discardableResult
    private func apply(_ pack: IconPack?, generation mine: Int) async -> Bool {
        guard await icons.setIconPack(pack), mine == generation else { return false }
        folderName = pack?.folder.lastPathComponent
        return true
    }
}
