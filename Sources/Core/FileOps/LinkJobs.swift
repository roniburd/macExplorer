import Foundation
import Darwin
import MacxFS

enum LinkJobs {
    private enum Made: Sendable { case ok(URL, FileIdentity), failed(FileOpErrorKind) }

    static func alias(_ ctx: JobContext, sources: [URL], destination: URL) async {
        await make(ctx, sources: sources, destination: destination) { src, dir in
            let name = freeName("\(src.lastPathComponent) alias", in: dir, isDirectory: false)
            let aliasURL = dir.appending(path: name)
            let data = try src.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: aliasURL)
            return aliasURL
        }
    }

    static func symlink(_ ctx: JobContext, sources: [URL], destination: URL) async {
        await make(ctx, sources: sources, destination: destination) { src, dir in
            let sameFolder = src.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path
            let name = freeName(sameFolder ? "\(src.lastPathComponent) symlink" : src.lastPathComponent, in: dir, isDirectory: false)
            let link = dir.appending(path: name)
            let target = VolumeIdentity.isSameVolume(src, destinationDirectory: dir) ? relativePath(from: dir, to: src) : src.path
            guard Darwin.symlink(target, link.path) == 0 else { throw FileOpError(kind: FileOpErrorKind(errno: errno, isLockedItem: false), url: link) }
            return link
        }
    }

    /// Lane only: `../src/a.txt`-style path from `directory` to `target` (symlinks in the parents resolved).
    static func relativePath(from directory: URL, to target: URL) -> String {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var i = 0
        while i < base.count, i < parent.count, base[i] == parent[i] { i += 1 }
        let ups = Array(repeating: "..", count: base.count - i)
        return (ups + Array(parent[i...]) + [target.lastPathComponent]).joined(separator: "/")
    }

    private static func freeName(_ name: String, in dir: URL, isDirectory: Bool) -> String {
        PosixFS.exists(dir.appending(path: name).path)
            ? NameGenerator.keepBoth(name, isDirectory: isDirectory) { PosixFS.exists(dir.appending(path: $0).path) }
            : name
    }

    private static func make(_ ctx: JobContext, sources: [URL], destination: URL,
                             _ body: @escaping @Sendable (URL, URL) throws -> URL) async {
        ctx.setTotals(items: sources.count, bytes: 0)
        ctx.setState(.running)
        items: for src in sources {
            guard await ctx.checkpoint() else { break }
            while true {
                let made = (try? await ctx.onLane { _ -> Made in
                    guard PosixFS.exists(src.path) else { return .failed(.sourceGone) }
                    do {
                        let u = try body(src, destination)
                        guard let id = FileIdentity.of(path: u.path) else { return .failed(.sourceGone) }
                        return .ok(u, id)
                    } catch { return .failed(FileOpErrorKind(error: error, isLockedItem: PosixFS.info(destination.path)?.isLocked ?? false)) }
                }) ?? .failed(.other(code: EIO, message: String(cString: strerror(EIO))))
                switch made {
                case .ok(let u, let id):
                    ctx.record(.created(u, id))
                    ctx.landed(u)
                    ctx.addProgress(items: 1, current: u.lastPathComponent)
                    continue items
                case .failed(let kind):
                    switch await ctx.askError(FileOpError(kind: kind, url: src, destination: destination)) {
                    case .retry, .continueAnyway, .unlockAndContinue: continue
                    case .skip, .skipAll: ctx.skip(src, reason: kind); continue items
                    case .cancel: ctx.cancelJob(); return
                    }
                }
            }
        }
    }
}
