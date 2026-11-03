import Foundation
import Darwin
import MacxFS

public protocol TrashService: Sendable {
    /// Synchronous; lane only. Returns the resulting URL. Throws FileOpError(.noTrash) where unsupported.
    func trash(_ url: URL) throws -> URL
}

public struct SystemTrash: TrashService {
    public init() {}
    public func trash(_ url: URL) throws -> URL {
        assertOffMain()
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        } catch {
            let locked = PosixFS.info(url.path)?.isLocked ?? false
            throw FileOpError(kind: FileOpErrorKind(error: error, isLockedItem: locked), url: url)
        }
        guard let result else { throw FileOpError(kind: .noTrash, url: url) }
        return result as URL
    }
}

/// Moves items into `directory/<UUID>/<name>`. For items on another volume (rename gives EXDEV) the bucket is
/// `<item's mount point>/.macx-sandbox-trash/<UUID>/<name>` (tests only use this on images they created).
/// Paths under `refusingPathsUnder` throw .noTrash (simulates volumes without a Trash).
public struct SandboxTrash: TrashService {
    public let directory: URL
    private let refusing: [String]
    public init(directory: URL) { self.init(directory: directory, refusingPathsUnder: []) }
    public init(directory: URL, refusingPathsUnder prefixes: [URL]) {
        self.directory = directory
        self.refusing = prefixes.map { $0.standardizedFileURL.path + "/" }
    }

    public func trash(_ url: URL) throws -> URL {
        assertOffMain()
        let path = url.standardizedFileURL.path
        if refusing.contains(where: { (path + "/").hasPrefix($0) && path + "/" != $0 }) {
            throw FileOpError(kind: .noTrash, url: url)
        }
        guard PosixFS.exists(path) else { throw FileOpError(kind: .sourceGone, url: url) }
        let locked = PosixFS.info(path)?.isLocked ?? false
        func attempt(into bucketRoot: URL) throws -> (URL, Int32) {
            let bucket = bucketRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
            let target = bucket.appending(path: url.lastPathComponent)
            return (target, PosixFS.rename(path, target.path))
        }
        var (target, code) = try attempt(into: directory)
        if code == EXDEV, let mount = PosixFS.mountPoint(of: path) {
            (target, code) = try attempt(into: URL(filePath: mount).appending(path: ".macx-sandbox-trash", directoryHint: .isDirectory))
        }
        guard code == 0 else { throw FileOpError(kind: FileOpErrorKind(errno: code, isLockedItem: locked), url: url) }
        return target
    }
}
