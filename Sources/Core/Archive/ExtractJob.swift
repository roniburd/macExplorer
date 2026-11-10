import Foundation
import Darwin
import MacxFS

/// `.extract` jobs (P4-10): Extract Here for zip, the tar family, gzip and Apple Archive.
///
/// Before anything is written the archive is listed and every entry checked (`ArchiveSafety`); an unsafe or
/// unlistable archive is refused. The tool then extracts into a journaled partial folder next to the archive
/// (`PartialName`, so `LaunchRecovery` removes it after a crash), which is walked once more (nothing resolves outside
/// it, no link leaves it, no hard link reaches outside, setuid/setgid cleared) before it is placed: a single top-level
/// item lands as itself, several land in a folder named after the archive, each at the next free name. Records
/// `.created`, so Undo moves the result to the Trash. The archive itself is only read.
enum ExtractJob {
    private struct StepFailure: Error, Sendable { var code: Int32 }

    private enum Prepared: Sendable {
        case ready(ArchiveFormat, [ArchiveEntry], size: Int64)
        case unsupported
        case unsafe
        case failed(Int32)
    }

    private struct Attempt: Sendable { var result: ProcessResult; var safe: Bool }

    static func extract(_ ctx: JobContext, _ archive: URL) async {
        guard await ctx.checkpoint() else { return }
        // 1. Detect and list (lane); nothing has been written yet.
        var prepared: Prepared
        while true {
            prepared = (try? await ctx.onLane { lane in prepare(archive, lane) }) ?? .failed(EIO)
            if ctx.control.isCancelled { ctx.cancelJob(); return }
            guard case .failed(let code) = prepared else { break }
            switch await ctx.resolveFailure(code, url: archive) {
            case .retry: continue
            case .skipped, .cancelled: return
            }
        }
        let format: ArchiveFormat, entries: [ArchiveEntry], size: Int64
        switch prepared {
        case .ready(let f, let e, let s): (format, entries, size) = (f, e, s)
        case .unsupported: await refuse(ctx, archive, .unsupportedArchive); return
        case .unsafe: await refuse(ctx, archive, .unsafeArchive); return
        case .failed: return
        }

        // 2. Totals and the journaled partial folder.
        ctx.setTotals(items: entries.count, bytes: size)
        ctx.setState(.running)
        let parent = archive.deletingLastPathComponent()
        let baseName = folderName(for: archive.lastPathComponent)
        let partial = parent.appending(path: PartialName.make(for: baseName, job: ctx.id), directoryHint: .isDirectory)
        do { try await ctx.journalRecord(.partial(job: ctx.id, url: partial)) } catch {
            _ = await ctx.resolveFailure(EIO, url: archive)
            return
        }

        // 3. Run the tool, then post-check, retrying on request.
        let tool = { (path: String) in ctx.tuning.toolOverride?(path) ?? path }
        let (executable, arguments, output): (String, [String], ProcessOutput) = switch format {
        case .zip: (tool("/usr/bin/ditto"), ["-x", "-k", "--sequesterRsrc", "-V", archive.path, partial.path], .discard)
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            (tool("/usr/bin/tar"), ["-xvf", archive.path, "-C", partial.path, "--no-same-owner", "--no-same-permissions"], .discard)
        case .appleArchive: (tool("/usr/bin/aa"), ["extract", "-i", archive.path, "-d", partial.path], .discard)
        case .gzip: (tool("/usr/bin/gzip"), ["-dc", archive.path], .file(partial.appending(path: entries.first?.path ?? baseName)))
        }
        let control = ctx.control
        let perItem = entries.isEmpty ? 0 : size / Int64(entries.count)
        let start = ctx.progressMark()
        while true {
            ctx.restoreProgress(start)
            let attempt: Result<Attempt, any Error>
            do {
                attempt = .success(try await ctx.onLane { lane in
                    _ = PosixFS.removeTree(partial.path, unlock: true)        // a previous attempt's leftovers
                    guard mkdir(partial.path, 0o700) == 0 else { throw StepFailure(code: errno) }
                    let r = try ProcessRunner.run(executable, arguments, output: output, context: lane,
                                                  isPaused: { control.isPaused }, isCancelled: { control.isCancelled },
                                                  onStarted: { ctx.fault(.archiveToolStarted) },
                                                  onStderrLine: { line in progress(ctx, line, perItem: perItem) })
                    let safe = r.status == 0 ? postCheck(partial.path, lane: lane) : true
                    return Attempt(result: r, safe: safe)
                })
            } catch { attempt = .failure(error) }
            let succeeded = if case .success(let a) = attempt, a.result.status == 0, a.safe, !control.isCancelled { true } else { false }
            if !succeeded { _ = try? await ctx.onLane { _ in PosixFS.removeTree(partial.path, unlock: true) } }
            if control.isCancelled { ctx.cancelJob(); return }
            switch attempt {
            case .success(let a) where a.result.status == 0 && a.safe:
                ctx.restoreProgress((items: entries.count, bytes: size, cloned: start.cloned))
                await place(ctx, partial: partial, in: parent, folderName: baseName, archive: archive)
                return
            case .success(let a) where a.result.status == 0:
                await refuse(ctx, archive, .unsafeArchive)
                return
            case .success(let a):
                let kind = CompressJob.errorKind(stderrTail: a.result.stderrTail, status: a.result.status)
                switch await ctx.askError(FileOpError(kind: kind, url: archive)) {
                case .retry, .continueAnyway, .unlockAndContinue: continue
                case .cancel: ctx.cancelJob(); return
                case .skip, .skipAll: ctx.skip(archive, reason: kind); return
                }
            case .failure(let error):
                if (error as? LaneError) == .cancelled { ctx.cancelJob(); return }
                let code = (error as? StepFailure)?.code ?? (error as? any ErrnoCarrying)?.errnoCode ?? EIO
                switch await ctx.resolveFailure(code, url: archive) {
                case .retry: continue
                case .skipped, .cancelled: return
                }
            }
        }
    }

    /// "photos.tar.gz" → "photos"; an archive found by its bytes only ("photos.bin") → "photos".
    static func folderName(for archiveName: String) -> String {
        let stripped = ArchiveFormat.baseName(stripping: archiveName)
        if stripped != archiveName { return stripped }
        let noExt = (archiveName as NSString).deletingPathExtension
        return noExt.isEmpty ? archiveName : noExt
    }

    /// Skip/Cancel for an archive that is refused before (or after) extraction; nothing of it is left.
    private static func refuse(_ ctx: JobContext, _ archive: URL, _ kind: FileOpErrorKind) async {
        switch await ctx.askError(FileOpError(kind: kind, url: archive)) {
        case .cancel: ctx.cancelJob()
        case .skip, .skipAll, .retry, .continueAnyway, .unlockAndContinue: ctx.skip(archive, reason: kind)
        }
    }

    /// Lane: the format from the first 512 bytes, the listing and the safety rules.
    private static func prepare(_ archive: URL, _ lane: LaneContext) -> Prepared {
        let fd = open(archive.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .failed(errno) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { let e = errno; close(fd); return .failed(e) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return .unsupported }
        var head = [UInt8](repeating: 0, count: 512)
        let n = head.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        let readErrno = errno
        close(fd)
        guard n >= 0 else { return .failed(readErrno) }
        guard let format = ArchiveFormat.detect(magic: Data(head[0..<n]), name: archive.lastPathComponent) else { return .unsupported }
        let entries: [ArchiveEntry]
        do {
            entries = try ArchiveLister.entries(of: archive, format: format, context: lane)
        } catch let e as ProcessRunnerError {
            return .failed(e.code)
        } catch let e as LaneError {
            _ = e
            return .failed(ECANCELED)
        } catch {
            return .unsafe                                            // rule 4: a listing that failed
        }
        guard ArchiveSafety.problems(entries).isEmpty else { return .unsafe }
        return .ready(format, entries, size: Int64(st.st_size))
    }

    /// `tar -v` prints "x path" per entry; `ditto -V` "N bytes for path" per file. Each counts one item.
    private static func progress(_ ctx: JobContext, _ line: String, perItem: Int64) {
        if let m = line.wholeMatch(of: /x (.+?)\s*/) {
            ctx.addProgress(items: 1, bytes: perItem, current: (String(m.1) as NSString).lastPathComponent)
        } else if let m = line.wholeMatch(of: /\d+ bytes for (.+?)\s*/) {
            ctx.addProgress(items: 1, bytes: perItem, current: (String(m.1) as NSString).lastPathComponent)
        }
    }

    /// Lane: every extracted item resolves inside `root`, symlinks stay inside it (same lexical rule as
    /// `ArchiveSafety`), files with several hard links have all of them inside it, and setuid/setgid bits are cleared.
    static func postCheck(_ root: String, lane: LaneContext) -> Bool {
        assertOffMain()
        guard let realRoot = realpath(root, nil).map({ p -> String in defer { free(p) }; return String(cString: p) }) else { return false }
        let rootCopy = strdup(root)
        defer { free(rootCopy) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return false }
        defer { fts_close(fts) }
        var linkCounts: [UInt64: (seen: Int, total: Int)] = [:]
        var count = 0
        errno = 0
        while let ent = fts_read(fts) {
            count += 1
            if count & 255 == 0 { lane.heartbeat() }
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_DP { continue }
            if info == FTS_ERR || info == FTS_DNR || info == FTS_NS || info == FTS_NSOK { return false }
            let level = Int(ent.pointee.fts_level)
            guard level > 0 else { continue }
            let path = String(cString: ent.pointee.fts_path)
            let parentDir = (path as NSString).deletingLastPathComponent
            guard let realParent = realpath(parentDir, nil).map({ p -> String in defer { free(p) }; return String(cString: p) }),
                  realParent == realRoot || realParent.hasPrefix(realRoot + "/") else { return false }
            let st = ent.pointee.fts_statp.pointee
            if info == FTS_SL || info == FTS_SLNONE {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let len = readlink(path, &buffer, buffer.count - 1)
                guard len >= 0 else { return false }
                let target = String(decoding: buffer[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard linkStaysInside(target: target, from: realParent, realRoot: realRoot) else { return false }
                continue
            }
            if (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink > 1 {
                let previous = linkCounts[st.st_ino] ?? (0, Int(st.st_nlink))
                linkCounts[st.st_ino] = (previous.seen + 1, previous.total)
            }
            if st.st_mode & (S_ISUID | S_ISGID) != 0 {
                guard chmod(path, st.st_mode & 0o7777 & ~(S_ISUID | S_ISGID)) == 0 else { return false }
            }
        }
        if errno != 0 { return false }
        return linkCounts.values.allSatisfy { $0.seen == $0.total }
    }

    /// Whether a symlink in `folder` (a real path inside `realRoot`) with `target` resolves inside `realRoot`, following
    /// every link it passes through on disk (a lexical count would trust "d/l1/.." where d/l1 is itself a link to "..").
    /// Components that don't exist resolve lexically; an absolute target, a step outside the root or more than 32 links
    /// (a loop) fail it.
    static func linkStaysInside(target: String, from folder: String, realRoot: String) -> Bool {
        func inside(_ parts: [String]) -> Bool {
            let p = "/" + parts.joined(separator: "/")
            return p == realRoot || p.hasPrefix(realRoot + "/")
        }
        var at = folder.split(separator: "/").map(String.init)
        // On disk only "/" separates ("\\" is an ordinary character in a name here).
        func parts(_ t: String) -> [String] { t.split(separator: "/").map(String.init).filter { $0 != "." } }
        var pending = parts(target)
        if target.hasPrefix("/") { return false }
        var hops = 0
        while !pending.isEmpty {
            let c = pending.removeFirst()
            if c == ".." {
                guard !at.isEmpty else { return false }
                at.removeLast()
                guard inside(at) else { return false }
                continue
            }
            at.append(c)
            guard inside(at) else { return false }
            var st = stat()
            guard lstat("/" + at.joined(separator: "/"), &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { continue }
            hops += 1
            guard hops <= 32 else { return false }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let len = readlink("/" + at.joined(separator: "/"), &buffer, buffer.count - 1)
            guard len >= 0 else { return false }
            let next = String(decoding: buffer[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if next.hasPrefix("/") { return false }
            at.removeLast()
            pending = parts(next) + pending
        }
        return true
    }

    /// Moves the result out of the partial folder: its one top-level item (other than "__MACOSX") as itself, or the
    /// folder itself under the archive's name, each at the next free name (RENAME_EXCL).
    private static func place(_ ctx: JobContext, partial: URL, in parent: URL, folderName: String, archive: URL) async {
        enum Placed: Sendable { case placed(URL, FileIdentity?), failed(Int32) }
        while true {
            let r = (try? await ctx.onLane { _ -> Placed in
                let macosx = partial.appending(path: "__MACOSX").path
                if PosixFS.exists(macosx) { _ = PosixFS.removeTree(macosx, unlock: true) }
                guard case .success(let children) = PosixFS.childNames(partial.path) else { return .failed(EIO) }
                let source: String, name: String, isDirectory: Bool
                if children.count == 1, let only = children.first {
                    source = partial.appending(path: only).path
                    name = only
                    var st = stat()
                    isDirectory = lstat(source, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
                } else {
                    source = partial.path
                    name = folderName
                    isDirectory = true
                    guard chmod(source, 0o755) == 0 else { return .failed(errno) }
                }
                func taken(_ n: String) -> Bool { PosixFS.exists(parent.appending(path: n).path) }
                for _ in 0..<10_000 {
                    let candidate = taken(name) ? NameGenerator.keepBoth(name, isDirectory: isDirectory, taken: taken) : name
                    let final = parent.appending(path: candidate, directoryHint: isDirectory ? .isDirectory : .notDirectory)
                    switch RenamePrimitive.rename(source, final.path, renameExcl: true) {
                    case .renamed:
                        if source != partial.path { _ = PosixFS.removeTree(partial.path, unlock: true) }
                        return .placed(final, FileIdentity.of(path: final.path))
                    case .exists: continue
                    case .crossDevice: return .failed(EXDEV)
                    case .failed(let e): return .failed(e)
                    }
                }
                return .failed(EEXIST)
            }) ?? .failed(EIO)
            switch r {
            case .placed(let final, let identity):
                if let identity { ctx.record(.created(final, identity)) }
                ctx.landed(final)
                return
            case .failed(let code):
                switch await ctx.resolveFailure(code, url: archive) {
                case .retry: continue
                case .skipped, .cancelled:
                    _ = try? await ctx.onLane { _ in PosixFS.removeTree(partial.path, unlock: true) }
                    return
                }
            }
        }
    }
}
