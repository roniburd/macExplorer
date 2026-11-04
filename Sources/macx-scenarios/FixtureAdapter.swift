import Darwin
import Foundation
import MacxFixtures

/// The ONLY file in macx-scenarios that names MacxFixtures (P1-02) types. If P1-02 shipped different
/// names, adapt this file only (Contract note C1).
enum ImageFormat: Sendable { case apfs, hfsPlus, exfat, msdos }

struct ImageHandle: Sendable {
    fileprivate let image: DiskImage
    var mountPoint: URL { image.mountPoint }
    func detach() throws { try image.detach() }
}

struct SandboxHandle: Sendable {
    fileprivate let sandbox: Sandbox
    var root: URL { sandbox.root }

    static func make(prefix: String) throws -> SandboxHandle { SandboxHandle(sandbox: try Sandbox(prefix: prefix)) }
    static var imagesAvailable: Bool { DiskImage.isAvailable }

    func url(_ relative: String) -> URL { sandbox.url(relative) }
    func contains(_ url: URL) -> Bool { sandbox.contains(url) }

    /// Path of `url` relative to `root`; traps outside the sandbox. Compares the raw paths first, then
    /// both with symlinks resolved (standardizing only one side drops `/private` and never matches).
    func relative(_ url: URL) -> String {
        let p = url.path(percentEncoded: false)
        precondition(sandbox.contains(url), "outside sandbox: \(p)")
        for (r, q) in [(root.path(percentEncoded: false), p),
                       (root.resolvingSymlinksInPath().path(percentEncoded: false), url.resolvingSymlinksInPath().path(percentEncoded: false))] {
            let base = r.hasSuffix("/") ? String(r.dropLast()) : r
            if q.hasPrefix(base + "/") { return String(q.dropFirst(base.count + 1)) }
        }
        preconditionFailure("cannot express \(p) relative to \(root.path(percentEncoded: false))")
    }

    @discardableResult func dir(_ relative: String) -> URL { fixtureWrite(relative) { try sandbox.createDirectory(relative) } }
    /// Creates the file, or replaces its contents if it already exists (Sandbox.createFile is O_EXCL;
    /// watcher scenarios rewrite files in place).
    @discardableResult func file(_ relative: String, _ contents: Data = Data("x".utf8)) -> URL {
        fixtureWrite(relative) {
            let url = sandbox.url(relative)
            var st = stat()
            if lstat(url.path(percentEncoded: false), &st) == 0 {
                try sandbox.overwrite(relative, contents: contents)
                return url
            }
            return try sandbox.createFile(relative, contents: contents)
        }
    }
    @discardableResult func flat(_ relative: String, count: Int) -> URL {
        fixtureWrite(relative) { try FixtureTree.flat(in: sandbox, at: relative, count: count) }
    }

    /// `name` labels the volume ("MACX" + up to 7 upper-case alphanumerics, valid for every format
    /// including MS-DOS); S1 picks the image file and mount point names itself (`img-<id>.dmg`, `mnt-<id>`).
    func image(_ name: String, _ format: ImageFormat, sizeMB: Int, readOnly: Bool) throws -> ImageHandle {
        let f: DiskImageFormat = switch format {
        case .apfs: .apfs
        case .hfsPlus: .hfsPlus
        case .exfat: .exfat
        case .msdos: .msdos
        }
        let label = "MACX" + String(name.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(7))
        return ImageHandle(image: try DiskImage.create(in: sandbox, format: f, sizeMB: sizeMB, volumeName: label, readOnly: readOnly))
    }

    /// Clears BSD flags and gives u+rwx to every directory under root (never follows symlinks), so a
    /// fixture with uchg files or mode-000 folders can always be removed.
    func makeWritable() {
        func visit(_ path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            _ = lchflags(path, 0)
            guard (st.st_mode & 0o170000) == 0o040000 else { return }
            _ = chmod(path, 0o755)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { visit(path + "/" + name) }
        }
        precondition(root.lastPathComponent.hasPrefix("macx-"), "refusing to touch \(root.path)")
        visit(root.path)
    }

    func destroy() { sandbox.destroy() }
}

/// A fixture write inside a fresh sandbox only fails when the environment is broken (disk full,
/// unwritable TMPDIR). The runner stops with the path and reason; run-scenarios.sh's EXIT trap
/// still detaches images and removes the run directory.
func fixtureWrite<T>(_ relative: String, _ body: () throws -> T) -> T {
    do { return try body() } catch { preconditionFailure("fixture write '\(relative)' failed: \(error)") }
}
