import Darwin
import Foundation
import Synchronization

/// Experimental (Settings › Advanced): follow symlinks on SSH/FUSE mounts that store a path on the remote computer.
///
/// `ln -s /home/me/tools/x` made on the remote box stores `/home/me/tools/x`, which doesn't exist on this Mac, so the
/// link is broken here even though the target is inside the mount (`~/mnt/box/tools/x`). When the experiment is on and
/// such a link is broken locally, the remote prefix is swapped for the mount point. Nothing else changes: links that
/// resolve locally, relative links and links on ordinary volumes are never touched, and a target the mount doesn't
/// hold (another remote volume, e.g. `/workplace/me`) stays broken.
///
/// Prefixes come from the mount's remote root (`host:/local/home/me` from macFUSE's mount source or the `sshfs`
/// process running a fuse-t mount) and are learned from links: dropping leading components of a broken target until
/// the rest exists under the mount point. A learned prefix needs at least two components and, when the remote root is
/// known, the same last component (`/home/me` for `/local/home/me`), so `/usr/local/bin/x` never lands on `~/mnt/box/bin/x`.
public enum RemoteLinkRemap {
    private static let enabled = Atomic<Bool>(false)
    static let shared = Remapper(mountOf: RemoteMount.detect, exists: Remapper.lstatExists)

    public static var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    /// Settings mirrors `experimentalRemoteLinkRemap` here so lanes can read it without the main actor.
    public static func setEnabled(_ on: Bool) { enabled.store(on, ordering: .relaxed) }

    /// LinkResolver hook (lane only): the local path to use for `destination`, the absolute target stored in the
    /// symlink at `link`, or nil to keep `destination`.
    static func remap(link: String, destination: String) -> String? {
        guard isEnabled else { return nil }
        return shared.remap(link: link, destination: destination)
    }
}

/// A FUSE mount that may hold remote absolute paths. `remoteRoot` is the remote folder mounted at `mountPoint`, when known.
struct RemoteMount: Sendable, Equatable {
    var mountPoint: String
    var remoteRoot: String?

    private static let cache = Mutex<[String: RemoteMount?]>([:])

    /// The FUSE mount holding `directory` (statfs, which follows links, so pass the link's folder), or nil for any
    /// other volume. fuse-t mounts are NFS with an `fuse-t:` source; macFUSE ones have their own type.
    static func detect(directory: String) -> RemoteMount? {
        var sfs = statfs()
        guard statfs(directory, &sfs) == 0 else { return nil }
        let type = cString(&sfs.f_fstypename), from = cString(&sfs.f_mntfromname), on = cString(&sfs.f_mntonname)
        let isFuseT = from.hasPrefix("fuse-t:")
        guard isFuseT || ["macfuse", "osxfuse", "fusefs"].contains(type) else { return nil }
        let key = on + "\u{0}" + from
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let root = isFuseT ? SSHFSProcesses.remoteRoot(mountPoint: on) : remotePath(fromSource: from)
        let mount = RemoteMount(mountPoint: on, remoteRoot: root)
        cache.withLock { $0[key] = mount }
        return mount
    }

    /// `host:/abs/path` or `user@host:/abs/path` → `/abs/path`; anything else (a relative remote path, which is
    /// relative to the remote home we can't see) → nil.
    static func remotePath(fromSource source: String) -> String? {
        guard let colon = source.firstIndex(of: ":") else { return nil }
        let host = source[..<colon], path = source[source.index(after: colon)...]
        guard !host.isEmpty, !host.contains("/"), path.hasPrefix("/") else { return nil }
        return normalized(String(path))
    }

    static func normalized(_ path: String) -> String {
        let s = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        return s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private static func cString<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Finds the remote folder of a fuse-t `sshfs` mount from the process's arguments (`sshfs host:/path mountpoint …`),
/// since fuse-t's mount source (`fuse-t:/name`) doesn't record it. Only this user's processes are read.
enum SSHFSProcesses {
    static func remoteRoot(mountPoint: String) -> String? {
        for pid in userPIDs() {
            guard let args = arguments(of: pid), let exe = args.first,
                  (exe as NSString).lastPathComponent == "sshfs" else { continue }
            if let root = remoteRoot(arguments: args, mountPoint: mountPoint) { return root }
        }
        return nil
    }

    /// `args` includes argv[0]. The mount point must appear as an argument; the remote is the first `x:/…` argument.
    static func remoteRoot(arguments args: [String], mountPoint: String) -> String? {
        let mount = RemoteMount.normalized(mountPoint)
        let rest = args.dropFirst()
        guard rest.contains(where: { $0.hasPrefix("/") && RemoteMount.normalized($0) == mount }) else { return nil }
        for arg in rest where !arg.hasPrefix("-") {
            if let path = RemoteMount.remotePath(fromSource: arg) { return path }
        }
        return nil
    }

    private static func userPIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid).filter { $0 > 0 }
    }

    /// KERN_PROCARGS2: argc (Int32), the executable path, NUL padding, then argv.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }   // executable path
        while i < size, buffer[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

/// The remapping itself; `mountOf` and `exists` are injected so tests can use a plain folder as the "mount".
final class Remapper: Sendable {
    private let mountOf: @Sendable (String) -> RemoteMount?
    private let exists: @Sendable (String) -> Bool
    /// Learned prefixes per mount point, longest first.
    private let learned = Mutex<[String: [String]]>([:])
    static let minimumLearnedComponents = 2

    init(mountOf: @escaping @Sendable (String) -> RemoteMount?, exists: @escaping @Sendable (String) -> Bool) {
        self.mountOf = mountOf
        self.exists = exists
    }

    /// Something is at `path` (an unreadable item counts: it's there).
    static let lstatExists: @Sendable (String) -> Bool = { path in
        var st = stat()
        return lstat(path, &st) == 0 || LinkResolver.isPermission(errno)
    }

    func remap(link: String, destination: String) -> String? {
        guard destination.hasPrefix("/"), !exists(destination) else { return nil }
        guard let mount = mountOf((link as NSString).deletingLastPathComponent) else { return nil }
        let known = learned.withLock { $0[mount.mountPoint] ?? [] }
        guard let hit = Self.candidate(for: destination, mount: mount, learned: known, exists: exists) else { return nil }
        if let prefix = hit.learnedPrefix {
            learned.withLock { table in
                var list = table[mount.mountPoint] ?? []
                if !list.contains(prefix) { list.append(prefix); list.sort { $0.count > $1.count } }
                table[mount.mountPoint] = list
            }
        }
        return hit.path
    }

    /// The local path for `destination` on `mount`: known prefixes first (the remote root, then learned ones,
    /// longest first), then a new prefix learned from this link. `learnedPrefix` is set only for a new prefix.
    static func candidate(for destination: String, mount: RemoteMount, learned: [String],
                          exists: (String) -> Bool) -> (path: String, learnedPrefix: String?)? {
        let target = RemoteMount.normalized(destination)
        let mountPoint = RemoteMount.normalized(mount.mountPoint)
        // Already a path on this Mac's side of the mount: genuinely broken.
        guard target != mountPoint, !target.hasPrefix(mountPoint + "/") else { return nil }
        let parts = target.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }

        func local(_ rest: ArraySlice<String>) -> String { ([mountPoint] + rest).joined(separator: "/") }

        var known = learned
        if let root = mount.remoteRoot { known.insert(RemoteMount.normalized(root), at: 0) }
        for prefix in known {
            let prefixParts = prefix.split(separator: "/").map(String.init)
            guard parts.count > prefixParts.count, Array(parts.prefix(prefixParts.count)) == prefixParts else { continue }
            let path = local(parts.dropFirst(prefixParts.count))
            if exists(path) { return (path, nil) }
        }

        let root = mount.remoteRoot.map(RemoteMount.normalized)
        if root == "/" { return nil }   // the whole remote disk is mounted: the direct mapping above was the answer
        let rootLast = root.flatMap { $0.split(separator: "/").last.map(String.init) }
        guard parts.count > minimumLearnedComponents else { return nil }
        for k in minimumLearnedComponents..<parts.count {
            if let rootLast, parts[k - 1] != rootLast { continue }
            let path = local(parts.dropFirst(k))
            if exists(path) { return (path, "/" + parts.prefix(k).joined(separator: "/")) }
        }
        return nil
    }
}
