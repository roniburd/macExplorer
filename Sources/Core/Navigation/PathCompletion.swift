import Darwin
import Foundation
import MacxFS

/// Address-bar autocomplete (§5.2): subfolders of the typed path's parent, read off main on a lane.
public enum PathCompletion {
    public static let limit = 50

    /// Subfolder names of the parent of `partial` starting with its last component (case-insensitive), ≤ 50.
    /// Directories and symlinks to directories only, sorted like Finder. Dot-folders appear only when the last
    /// component starts with ".". Empty input, "~" and unreadable parents give [].
    /// Runs on a read lane of the volume containing that parent (longest match in `mounts`, `.unknown` when none),
    /// so completing under a hung share never blocks the current folder's volume (`performRecovering`, as resolve).
    public static func complete(_ partial: String, current: URL, home: URL, lanes: LanePool, mounts: MountTable) async -> [String] {
        guard let (path, prefix) = target(partial, current: current, home: home) else { return [] }
        let volume = mounts.volume(containing: path)?.id ?? .unknown
        let names = try? await lanes.performRecovering(on: volume, .read) { context in
            assertOffMain()
            return withNoMaterialization { subfolders(of: path, prefix: prefix, context: context) }
        }
        return names ?? []
    }

    /// As `complete(_:current:home:lanes:mounts:)` on a lane of `volume`, which must be the volume of the typed
    /// path's parent, not the current folder's.
    public static func complete(_ partial: String, current: URL, home: URL, lanes: LanePool, volume: VolumeID) async -> [String] {
        guard let (path, prefix) = target(partial, current: current, home: home) else { return [] }
        let names = try? await lanes.perform(on: volume, .read) { context in
            assertOffMain()
            return withNoMaterialization { subfolders(of: path, prefix: prefix, context: context) }
        }
        return names ?? []
    }

    /// The parent folder to list (normalized absolute path) and the last-component prefix to match.
    private static func target(_ partial: String, current: URL, home: URL) -> (String, String)? {
        guard !partial.isEmpty, partial != "~" else { return nil }
        let head: String
        let prefix: String
        if let slash = partial.lastIndex(of: "/") {
            head = String(partial[...slash])
            prefix = String(partial[partial.index(after: slash)...])
        } else {
            head = "."
            prefix = partial
        }
        guard let parent = AddressResolver.absolutePath(head, current: current, home: home) else { return nil }
        return (AddressResolver.normalize(parent), prefix)
    }

    /// Runs on a lane thread.
    private static func subfolders(of path: String, prefix: String, context: LaneContext) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        let showHidden = prefix.hasPrefix(".")
        var names: [String] = []
        var seen = 0
        while let entry = readdir(dir) {
            seen += 1
            if seen % 1_024 == 0 {
                context.heartbeat()
                if context.isCancelled { return [] }
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || (!showHidden && name.hasPrefix(".")) { continue }
            guard matches(name, prefix: prefix) else { continue }
            var isDirectory = entry.pointee.d_type == DT_DIR
            if entry.pointee.d_type == DT_LNK || entry.pointee.d_type == DT_UNKNOWN {
                var st = stat()
                isDirectory = fstatat(fd, name, &st, 0) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            }
            if isDirectory { names.append(name) }
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return Array(names.prefix(limit))
    }

    static func matches(_ name: String, prefix: String) -> Bool {
        prefix.isEmpty || name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }
}

/// The recent-locations part of the address-bar dropdown (paths from `Settings.recentLocations`).
public enum RecentLocations {
    /// All recents for empty text; otherwise case-insensitive prefix matches first, then substring matches,
    /// each in recency order, at most `limit`.
    public static func matching(_ text: String, in recents: [String], limit: Int = 20) -> [String] {
        guard !text.isEmpty else { return Array(recents.prefix(limit)) }
        let prefixed = recents.filter { $0.range(of: text, options: [.caseInsensitive, .anchored]) != nil }
        let contained = recents.filter {
            !prefixed.contains($0) && $0.range(of: text, options: .caseInsensitive) != nil
        }
        return Array((prefixed + contained).prefix(limit))
    }
}
