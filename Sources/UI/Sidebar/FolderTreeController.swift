import Foundation
import Core
import MacxFS

/// One folder in the sidebar's Folders tree (§5.4). Roots are volumes; children load lazily, directories only.
@MainActor
final class FolderTreeNode {
    let url: URL
    let name: String
    let isHidden: Bool
    let volume: VolumeInfo
    /// A root that is a volume's mount point (false for the sandbox-mode root folder).
    let isVolume: Bool
    private(set) weak var parent: FolderTreeNode?
    /// nil until the first read finishes (unknown: the node shows a disclosure triangle).
    fileprivate(set) var allChildren: [FolderTreeNode]?
    fileprivate(set) var isExpanded = false
    fileprivate(set) var isWatched = false

    init(url: URL, name: String, isHidden: Bool, volume: VolumeInfo, isVolume: Bool = false, parent: FolderTreeNode?) {
        self.url = url
        self.name = name
        self.isHidden = isHidden
        self.volume = volume
        self.isVolume = isVolume && parent == nil
        self.parent = parent
    }

    /// Volume roots behave like Locations rows (§5.4).
    var isVolumeRoot: Bool { isVolume }
    var isRoot: Bool { parent == nil }
    var isLoaded: Bool { allChildren != nil }
    var key: String { ChangeBus.key(for: url) }

    /// Root first.
    var pathFromRoot: [FolderTreeNode] {
        var path: [FolderTreeNode] = [self]
        var next = parent
        while let node = next { path.insert(node, at: 0); next = node.parent }
        return path
    }
}

/// The Folders tree model (§4.3 Tree nodes, §5.4 FOLDERS): lazy dirs-only children through `DirectoryReader` (no
/// materialization), merges that keep existing nodes (and so their expansion), auto-reveal, and a `TreeWatcher`
/// source per expanded node. Nodes the watcher can't take (over the cap, non-local volumes) re-read on re-expand and
/// on `refreshUnwatched()` (window became key).
@MainActor
final class FolderTreeController {
    /// `nil` = the roots changed; otherwise the node whose children changed.
    var onChange: ((FolderTreeNode?) -> Void)?
    /// A node left the tree (the sidebar forgets its outline box).
    var onDrop: ((FolderTreeNode) -> Void)?

    var showHidden: Bool {
        didSet { if showHidden != oldValue { onChange?(nil) } }
    }

    private(set) var roots: [FolderTreeNode] = []
    private var watcher: TreeWatcher!
    private var watched: [String: FolderTreeNode] = [:]
    private var loads: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Nodes asked to load again while a read was running: one more read follows it (as FolderModel does).
    private var pendingLoads: Set<ObjectIdentifier> = []
    /// The revealed path's nodes stay visible even when hidden (e.g. /private on the way to a temp folder).
    private var pinned: [ObjectIdentifier: FolderTreeNode] = [:]

    typealias Listing = [(name: String, hidden: Bool)]
    /// Lists a folder's subfolders; nil when the read failed or stalled (tests replace it).
    var lister: @MainActor (URL) async -> Listing?

    init(readers: DirectoryReaders, showHidden: Bool) {
        self.showHidden = showHidden
        lister = { url in await FolderTreeController.listDirectories(url, readers: readers) }
        watcher = TreeWatcher { [weak self] url in self?.watchedDirectoryChanged(url) }
    }

    var watchedCount: Int { watcher.count }

    // MARK: structure

    struct Root: Equatable {
        var url: URL
        var name: String
        var volume: VolumeInfo
        var isVolume: Bool
    }

    /// The roots are the volumes (§5.4).
    func setVolumes(_ volumes: [VolumeInfo]) {
        setRoots(volumes.map { Root(url: $0.mountPoint, name: $0.name, volume: $0, isVolume: true) })
    }

    /// Keeps the root nodes still present (same URL, name and volume); drops (and unwatches) the others.
    func setRoots(_ specs: [Root]) {
        var next: [FolderTreeNode] = []
        for spec in specs {
            if let existing = roots.first(where: { $0.url == spec.url && $0.name == spec.name && $0.volume == spec.volume
                                                    && $0.isVolume == spec.isVolume }) {
                next.append(existing)
            } else {
                next.append(FolderTreeNode(url: spec.url, name: spec.name, isHidden: false, volume: spec.volume,
                                           isVolume: spec.isVolume, parent: nil))
            }
        }
        let kept = Set(next.map(ObjectIdentifier.init))
        for root in roots where !kept.contains(ObjectIdentifier(root)) { drop(root) }
        guard next.map(ObjectIdentifier.init) != roots.map(ObjectIdentifier.init) else { return }
        roots = next
        onChange?(nil)
    }

    /// The visible children (hidden folders only with `showHidden`, or when on the revealed path).
    func children(of node: FolderTreeNode) -> [FolderTreeNode] {
        guard let all = node.allChildren else { return [] }
        if showHidden { return all }
        return all.filter { !$0.isHidden || pinned[ObjectIdentifier($0)] != nil }
    }

    /// Unknown until read; afterwards only when it has visible children.
    func isExpandable(_ node: FolderTreeNode) -> Bool {
        node.isLoaded ? !children(of: node).isEmpty : true
    }

    /// The loaded node for `url`, if any.
    func node(for url: URL) -> FolderTreeNode? {
        let target = ChangeBus.key(for: url)
        func search(_ nodes: [FolderTreeNode]) -> FolderTreeNode? {
            for node in nodes {
                let key = node.key
                if key == target { return node }
                if Self.isSelfOrDescendant(target, of: key), let found = search(node.allChildren ?? []) { return found }
            }
            return nil
        }
        return search(roots)
    }

    // MARK: expansion

    /// The outline expanded `node`: read (or re-read) its children and watch it.
    func didExpand(_ node: FolderTreeNode) {
        node.isExpanded = true
        if !node.isWatched, watcher.watch(node.url, isLocalVolume: node.volume.isLocal) {
            node.isWatched = true
            watched[node.key] = node
        }
        Task { await self.load(node) }
    }

    /// Every vnode source closes (the window closed).
    func stopWatching() {
        func walk(_ nodes: [FolderTreeNode]) {
            for node in nodes { unwatch(node); node.isExpanded = false; walk(node.allChildren ?? []) }
        }
        walk(roots)
    }

    /// The outline collapsed `node`: its subtree collapses too and stops being watched.
    func didCollapse(_ node: FolderTreeNode) {
        func collapse(_ n: FolderTreeNode) {
            n.isExpanded = false
            unwatch(n)
            for child in n.allChildren ?? [] where child.isExpanded || child.isWatched { collapse(child) }
        }
        collapse(node)
    }

    /// Expanded nodes without a vnode source (over the cap, non-local volume) re-read (window became key).
    func refreshUnwatched() async {
        var stale: [FolderTreeNode] = []
        func walk(_ nodes: [FolderTreeNode]) {
            for node in nodes where node.isExpanded {
                if !node.isWatched { stale.append(node) }
                walk(node.allChildren ?? [])
            }
        }
        walk(roots)
        for node in stale { await load(node) }
    }

    /// Reads `node`'s children, one read at a time per node. A caller arriving mid-read (a watcher event, a
    /// re-expand) may have seen a change that read missed: it waits for the running read and one more read after it.
    func load(_ node: FolderTreeNode) async {
        let id = ObjectIdentifier(node)
        if let running = loads[id] {
            pendingLoads.insert(id)
            return await running.value
        }
        let task = Task { @MainActor in
            repeat {
                self.pendingLoads.remove(id)
                let listed = await self.lister(node.url)
                self.merge(listed, into: node)
            } while self.pendingLoads.contains(id)
            self.loads[id] = nil
        }
        loads[id] = task
        await task.value
    }

    /// Children of `node` loaded at least once (waits for a running read; reads only when not yet loaded).
    func ensureLoaded(_ node: FolderTreeNode) async {
        if let running = loads[ObjectIdentifier(node)] { await running.value }
        if !node.isLoaded { await load(node) }
    }

    // MARK: reveal

    /// Loads the ancestors of `url` from its volume root and returns the path (root first), or nil when a component
    /// isn't a listed folder (a package, a file, gone). Hidden components on the path are pinned visible.
    func reveal(_ url: URL) async -> [FolderTreeNode]? {
        let target = ChangeBus.key(for: url)
        guard let root = roots.filter({ Self.isSelfOrDescendant(target, of: $0.key) }).max(by: { $0.key.count < $1.key.count })
        else { return nil }
        let rootKey = root.key
        var components = (rootKey == "/" ? target : String(target.dropFirst(rootKey.count)))
            .split(separator: "/").map(String.init)
        // ChangeBus keys drop /private; the boot volume lists it ("var" itself is a symlink there).
        if rootKey == "/", let first = components.first, ["var", "tmp", "etc"].contains(first) {
            components.insert("private", at: 0)
        }
        var path = [root]
        var node = root
        for component in components {
            await ensureLoaded(node)
            guard let child = node.allChildren?.first(where: { Self.sameName($0.name, component) }) else { return nil }
            path.append(child)
            node = child
        }
        let newPinned = Dictionary(path.filter(\.isHidden).map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { a, _ in a })
        if Set(newPinned.keys) != Set(pinned.keys) {
            let flipped = Set(newPinned.keys).symmetricDifference(pinned.keys).compactMap { newPinned[$0] ?? pinned[$0] }
            pinned = newPinned
            if !showHidden {
                var parents: [ObjectIdentifier: FolderTreeNode] = [:]
                for node in flipped { if let parent = node.parent { parents[ObjectIdentifier(parent)] = parent } }
                // Outer parents first, so inner reloads see their rows.
                for parent in parents.values.sorted(by: { $0.pathFromRoot.count < $1.pathFromRoot.count }) { onChange?(parent) }
            }
        }
        return path
    }

    // MARK: private

    private func watchedDirectoryChanged(_ url: URL) {
        guard let node = watched[ChangeBus.key(for: url)] else { return }
        Task { await self.load(node) }
    }

    /// A failed or stalled read (nil) changes nothing: an unloaded node stays unknown and expandable, so re-expanding
    /// retries, and a loaded one keeps its children.
    private func merge(_ listed: Listing?, into node: FolderTreeNode) {
        guard let listed else { return }
        let existing = node.allChildren ?? []
        var byName: [String: FolderTreeNode] = [:]
        for child in existing { byName[child.name] = child }
        var next: [FolderTreeNode] = []
        for entry in listed {
            if let child = byName.removeValue(forKey: entry.name) {
                if child.isHidden == entry.hidden { next.append(child); continue }
                drop(child)
            }
            next.append(FolderTreeNode(url: node.url.appending(path: entry.name, directoryHint: .isDirectory),
                                       name: entry.name, isHidden: entry.hidden, volume: node.volume, parent: node))
        }
        for gone in byName.values { drop(gone) }
        let unchanged = node.allChildren.map { $0.map(ObjectIdentifier.init) == next.map(ObjectIdentifier.init) } ?? false
        node.allChildren = next
        if !unchanged { onChange?(node) }
    }

    /// A node leaving the tree: it and its subtree stop being watched.
    private func drop(_ node: FolderTreeNode) {
        node.isExpanded = false
        unwatch(node)
        for child in node.allChildren ?? [] { drop(child) }
        pinned[ObjectIdentifier(node)] = nil
        onDrop?(node)
    }

    private func unwatch(_ node: FolderTreeNode) {
        guard node.isWatched else { return }
        node.isWatched = false
        watcher.unwatch(node.url)
        if watched[node.key] === node { watched[node.key] = nil }
    }

    /// Folder names (not packages) with their hidden flag, sorted like Finder; nil when the folder can't be read.
    private static func listDirectories(_ directory: URL, readers: DirectoryReaders) async -> Listing? {
        var options = ReadOptions()
        options.directoriesOnly = true
        options.noMaterialization = true
        let stream = await readers.reader(for: directory).read(directory, generation: .initial, options: options)
        var listed: Listing = []
        loop: for await event in stream {
            switch event {
            case .batch(let batch):
                for index in 0..<batch.count where batch.entries[index].kind == .directory {
                    listed.append((batch.name(at: index), batch.entries[index].flags.isHidden))
                }
            case .completed:
                break loop
            case .failed, .stalled:
                return nil
            case .waitingForPermission, .resumed:
                continue
            }
        }
        listed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return listed
    }

    private static func sameName(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// Both are ChangeBus keys.
    static func isSelfOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        guard path.utf8.starts(with: ancestor.utf8) else { return false }
        let rest = path.utf8.dropFirst(ancestor.utf8.count)
        return rest.isEmpty || rest.first == UInt8(ascii: "/")
    }
}
