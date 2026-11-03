import Darwin
import Foundation
import Synchronization

/// A guarded temporary directory. Every fixture write made by tests, benchmarks and scenario runners
/// goes through a Sandbox (Global Constraints, Safety). Any path that resolves outside `root`
/// (after following symlinks of existing components, including "..") is a programming error and traps.
public final class Sandbox: Sendable {
    /// Directory-name prefixes a sandbox may use. Teardown refuses to delete anything else.
    public static let allowedPrefixes: [String] = ["macx-tests", "macx-bench", "macx-scenario", "macx-fixtures"]

    /// Fully resolved root, e.g. /private/var/folders/…/T/macx-tests-<UUID>.
    public let root: URL
    private let mounts = Mutex<[String]>([])

    /// Creates `<temporaryDirectory>/<prefix>-<UUID>`.
    public init(prefix: String = "macx-tests") throws {
        precondition(Sandbox.allowedPrefixes.contains(prefix), "Sandbox: unknown prefix \(prefix)")
        let temp = try Sandbox.resolvedTemporaryDirectory()
        let path = temp + "/" + prefix + "-" + UUID().uuidString
        guard mkdir(path, 0o700) == 0 else { throw Sandbox.posixError(errno, path) }
        root = URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Adopts an existing, empty directory created by a runner script (e.g. `--root` of a scenario run).
    /// Refuses (throws) unless it sits directly in the temporary directory and its name starts with an allowed prefix.
    public init(adopting directory: URL) throws {
        let temp = try Sandbox.resolvedTemporaryDirectory()
        guard let resolved = Sandbox.resolve(directory.path(percentEncoded: false)) else {
            throw Sandbox.posixError(ENOENT, directory.path(percentEncoded: false))
        }
        let name = (resolved as NSString).lastPathComponent
        let parent = (resolved as NSString).deletingLastPathComponent
        guard parent == temp, Sandbox.allowedPrefixes.contains(where: { name.hasPrefix($0 + "-") }) else {
            throw SandboxError.notASandboxDirectory(resolved)
        }
        root = URL(filePath: resolved, directoryHint: .isDirectory)
    }

    // MARK: Guard

    /// True when `url` resolves to `root` or something below it.
    public func contains(_ url: URL) -> Bool {
        guard let resolved = Sandbox.resolve(url.path(percentEncoded: false)) else { return false }
        let base = root.path(percentEncoded: false).trimmingSuffix("/")
        return resolved == base || resolved.hasPrefix(base + "/")
    }

    /// Returns `url` unchanged if it is inside the sandbox; traps otherwise.
    @discardableResult
    public func checked(_ url: URL, file: StaticString = #fileID, line: UInt = #line) -> URL {
        if !contains(url) {
            preconditionFailure("Sandbox violation: \(url.path(percentEncoded: false)) is outside \(root.path(percentEncoded: false))",
                                file: file, line: line)
        }
        return url
    }

    /// URL of `relative` (no leading "/") inside the sandbox; traps if it escapes.
    public func url(_ relative: String, file: StaticString = #fileID, line: UInt = #line) -> URL {
        precondition(!relative.hasPrefix("/"), "Sandbox.url expects a relative path, got \(relative)", file: file, line: line)
        let url = relative.isEmpty ? root : root.appending(path: relative)
        return checked(url, file: file, line: line)
    }

    // MARK: Writes (all guarded)

    @discardableResult
    public func createDirectory(_ relative: String) throws -> URL {
        let url = self.url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a new file (fails if it exists; never follows a symlink at the final component).
    @discardableResult
    public func createFile(_ relative: String, contents: Data = Data("x".utf8)) throws -> URL {
        let url = self.url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Sandbox.posixError(errno, path) }
        defer { close(fd) }
        try contents.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw Sandbox.posixError(errno, path) }
                offset += n
            }
        }
        return url
    }

    /// Replaces the contents of an existing regular file inside the sandbox.
    public func overwrite(_ relative: String, contents: Data) throws {
        let url = self.url(relative)
        try contents.write(to: url, options: [])
    }

    /// Appends bytes to an existing file (e.g. "source changes while being copied").
    public func append(_ relative: String, contents: Data) throws {
        let url = self.url(relative)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: contents)
    }

    /// Logical size `size`, one byte written at the end (a hole before it where the volume supports it).
    @discardableResult
    public func createSparseFile(_ relative: String, size: Int64) throws -> URL {
        precondition(size > 0)
        let url = try createFile(relative, contents: Data())
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Sandbox.posixError(errno, path) }
        defer { close(fd) }
        var byte: UInt8 = 0x78
        guard ftruncate(fd, off_t(size)) == 0, pwrite(fd, &byte, 1, off_t(size - 1)) == 1 else {
            throw Sandbox.posixError(errno, path)
        }
        return url
    }

    /// `relative` becomes a symlink whose link text is `target` (relative or absolute; never written through).
    @discardableResult
    public func createSymlink(_ relative: String, target: String) throws -> URL {
        let url = self.url(relative)
        guard symlink(target, url.path(percentEncoded: false)) == 0 else { throw Sandbox.posixError(errno, url.path(percentEncoded: false)) }
        return url
    }

    @discardableResult
    public func createHardLink(_ relative: String, to existing: String) throws -> URL {
        let url = self.url(relative)
        let source = self.url(existing)
        guard link(source.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 else {
            throw Sandbox.posixError(errno, url.path(percentEncoded: false))
        }
        return url
    }

    /// A Finder alias (bookmark file) at `relative` pointing to `target`.
    @discardableResult
    public func createAlias(_ relative: String, to target: String) throws -> URL {
        let url = self.url(relative)
        let data = try self.url(target).bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(data, to: url)
        return url
    }

    /// lchflags; e.g. UInt32(UF_HIDDEN), UInt32(UF_IMMUTABLE). Replaces all flags.
    public func setFlags(_ relative: String, _ flags: UInt32) throws {
        let path = url(relative).path(percentEncoded: false)
        guard lchflags(path, flags) == 0 else { throw Sandbox.posixError(errno, path) }
    }

    public func setMode(_ relative: String, _ mode: mode_t) throws {
        let path = url(relative).path(percentEncoded: false)
        guard chmod(path, mode) == 0 else { throw Sandbox.posixError(errno, path) }
    }

    public func setXattr(_ relative: String, name: String, value: Data) throws {
        let path = url(relative).path(percentEncoded: false)
        let rc = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard rc == 0 else { throw Sandbox.posixError(errno, path) }
    }

    public func setHiddenExtension(_ relative: String, _ hidden: Bool = true) throws {
        var url = self.url(relative)
        var values = URLResourceValues()
        values.hasHiddenExtension = hidden
        try url.setResourceValues(values)
    }

    public func setDates(_ relative: String, modified: Date? = nil, created: Date? = nil) throws {
        var url = self.url(relative)
        var values = URLResourceValues()
        if let modified { values.contentModificationDate = modified }
        if let created { values.creationDate = created }
        try url.setResourceValues(values)
    }

    public func rename(_ from: String, to: String) throws {
        let a = url(from).path(percentEncoded: false), b = url(to).path(percentEncoded: false)
        guard Darwin.rename(a, b) == 0 else { throw Sandbox.posixError(errno, a) }
    }

    /// Removes an item (clearing locks/permissions below it first).
    public func remove(_ relative: String) throws {
        let url = self.url(relative)
        precondition(url.path(percentEncoded: false) != root.path(percentEncoded: false), "use destroy() to remove the root")
        Sandbox.unlockTree(url.path(percentEncoded: false))
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Mounts (DiskImage registers here so destroy() can detach first)

    func registerMount(_ mountPoint: String) { mounts.withLock { $0.append(mountPoint) } }
    func unregisterMount(_ mountPoint: String) { mounts.withLock { $0.removeAll { $0 == mountPoint } } }

    /// Detaches every image mounted inside the root, clears locks and permissions, deletes the root.
    /// Idempotent. Refuses (traps) if `root` is not a sandbox directory in the temporary directory.
    public func destroy() {
        let base = root.path(percentEncoded: false).trimmingSuffix("/")
        let name = (base as NSString).lastPathComponent
        guard let temp = try? Sandbox.resolvedTemporaryDirectory(),
              (base as NSString).deletingLastPathComponent == temp,
              Sandbox.allowedPrefixes.contains(where: { name.hasPrefix($0 + "-") }) else {
            preconditionFailure("Sandbox.destroy refused for \(base)")
        }
        var points = Set(mounts.withLock { $0 })
        points.formUnion(Sandbox.mountPoints(under: base))
        for point in points.sorted(by: { $0.count > $1.count }) {
            DiskImage.forceDetach(mountPoint: point)
        }
        mounts.withLock { $0.removeAll() }
        guard access(base, F_OK) == 0 else { return }
        Sandbox.unlockTree(base)
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: Helpers

    public static func resolvedTemporaryDirectory() throws -> String {
        let raw = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        guard let resolved = resolve(raw) else { throw posixError(ENOENT, raw) }
        return resolved.trimmingSuffix("/")
    }

    /// Kernel-equivalent resolution: walks components from "/", following symlinks (also dangling ones,
    /// textually) and applying ".." to the resolved prefix. Components that don't exist are appended as-is.
    static func resolve(_ path: String, depth: Int = 0) -> String? {
        guard depth < 40, path.hasPrefix("/") else { return nil }
        var current = ""
        var rest = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        while !rest.isEmpty {
            let component = rest.removeFirst()
            if component == "." { continue }
            if component == ".." {
                current = (current as NSString).deletingLastPathComponent
                if current == "/" { current = "" }
                continue
            }
            let next = current + "/" + component
            var st = stat()
            guard lstat(next, &st) == 0 else {
                // Doesn't exist: the remainder is created fresh, nothing to follow.
                current = next
                continue
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(next, &buffer, Int(PATH_MAX))
                guard n >= 0 else { return nil }
                let target = String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let joined = (target.hasPrefix("/") ? target : (current.isEmpty ? "" : current) + "/" + target)
                    + (rest.isEmpty ? "" : "/" + rest.joined(separator: "/"))
                return resolve(joined, depth: depth + 1)
            }
            current = next
        }
        return current.isEmpty ? "/" : current
    }

    static func unlockTree(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 { _ = lchflags(path, 0) }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            _ = chmod(path, 0o700)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                unlockTree(path + "/" + name)
            }
        }
    }

    static func mountPoints(under base: String) -> [String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var result: [String] = []
        for i in 0..<Int(count) {
            var entry = buffer[i]
            let point = withUnsafeBytes(of: &entry.f_mntonname) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if point.hasPrefix(base + "/") { result.append(point) }
        }
        return result
    }

    static func posixError(_ code: Int32, _ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}

public enum SandboxError: Error, Equatable, Sendable {
    case notASandboxDirectory(String)
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        guard count > 1, hasSuffix(suffix) else { return self }
        return String(dropLast(suffix.count))
    }
}
