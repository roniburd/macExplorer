import Core
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScenarioFixtureError: Error, Equatable, CustomStringConvertible {
    case rootNotScenarioSandbox(String)
    case rootNotEmpty(String)
    case unsafePath(String)
    case io(String, Int32)
    case badMode(String)
    var description: String {
        switch self {
        case .rootNotScenarioSandbox(let p): "refusing: --root \(p) is not a macx-scenario-* directory"
        case .rootNotEmpty(let p): "refusing: --root \(p) is not empty"
        case .unsafePath(let p): "refusing unsafe fixture path '\(p)'"
        case .io(let p, let e): "fixture I/O failed for '\(p)' (errno \(e))"
        case .badMode(let p): "bad mode for '\(p)'"
        }
    }
}

enum ScenarioFixtures {
    static let rootPrefix = "macx-scenario-"

    /// Synchronous: call only inside lane work. `root` must already be symlink-resolved. Refuses unless root's
    /// last component starts with "macx-scenario-" and root is empty; every path must stay inside root.
    static func create(_ fixture: ScenarioFile.Fixture, in root: URL) throws(ScenarioFixtureError) {
        guard root.lastPathComponent.hasPrefix(rootPrefix) else { throw .rootNotScenarioSandbox(root.path) }
        let fm = FileManager.default
        let existing: [String]
        do { existing = try fm.contentsOfDirectory(atPath: root.path) } catch { throw .io(root.path, Int32((error as NSError).code)) }
        guard existing.isEmpty else { throw .rootNotEmpty(root.path) }
        let rootPath = root.standardizedFileURL.path

        func target(_ relative: String) throws(ScenarioFixtureError) -> URL {
            guard ScenarioPath.isSafeRelative(relative) else { throw .unsafePath(relative) }
            let url = root.appending(path: relative)
            guard url.standardizedFileURL.path.hasPrefix(rootPath + "/") else { throw .unsafePath(relative) }
            return url
        }

        for dir in fixture.dirs {
            let url = try target(dir)
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch { throw .io(dir, Int32((error as NSError).code)) }
        }
        // Every item the fixture creates, intermediate folders included (for the explicit 0644/0755 below).
        var created: [URL] = []
        func noteCreated(_ relative: String) {
            var parts = relative.split(separator: "/").map(String.init)
            while !parts.isEmpty {
                created.append(root.appending(path: parts.joined(separator: "/")))
                parts.removeLast()
            }
        }
        fixture.dirs.forEach(noteCreated)
        let hidden = fixture.hidden ?? []
        for path in fixture.files + hidden {
            let url = try target(path)
            do { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
                throw .io(path, Int32((error as NSError).code))
            }
            let data = fixture.sizes?[path].map { Data(repeating: 0x78, count: $0) } ?? Data("x".utf8)
            guard fm.createFile(atPath: url.path, contents: data) else { throw .io(path, errno) }
            if hidden.contains(path), chflags(url.path, UInt32(UF_HIDDEN)) != 0 { throw .io(path, errno) }
            noteCreated(path)
        }
        // Phase 3 (P3-13): text files, never-text binary files and bulk folders.
        func write(_ path: String, _ data: Data) throws(ScenarioFixtureError) {
            let url = try target(path)
            do { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
                throw .io(path, Int32((error as NSError).code))
            }
            guard fm.createFile(atPath: url.path, contents: data) else { throw .io(path, errno) }
            noteCreated(path)
        }
        for (path, text) in (fixture.contents ?? [:]).sorted(by: { $0.key < $1.key }) { try write(path, Data(text.utf8)) }
        for (path, count) in (fixture.binary ?? [:]).sorted(by: { $0.key < $1.key }) { try write(path, binaryData(count)) }
        for (dir, count) in (fixture.bulk ?? [:]).sorted(by: { $0.key < $1.key }) {
            let url = try target(dir)
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch { throw .io(dir, Int32((error as NSError).code)) }
            noteCreated(dir)
            let base = url.path
            for i in 1...max(1, count) {
                let fd = open(base + "/" + bulkName(i), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
                guard fd >= 0 else { throw .io(dir + "/" + bulkName(i), errno) }
                close(fd)
            }
        }
        for path in fixture.images ?? [] {
            let url = try target(path)
            do { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
                throw .io(path, Int32((error as NSError).code))
            }
            guard let png = pngData(pixels: 64), fm.createFile(atPath: url.path, contents: png) else { throw .io(path, errno) }
            noteCreated(path)
        }
        // §2.4: files 0644, folders 0755, independent of the umask (Permissions column scenarios rely on it).
        for url in Set(created) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { throw .io(url.path, errno) }
            let mode: mode_t = (st.st_mode & S_IFMT) == S_IFDIR ? 0o755 : 0o644
            if chmod(url.path, mode) != 0 { throw .io(url.path, errno) }
        }
        for (path, tags) in (fixture.tags ?? [:]).sorted(by: { $0.key < $1.key }) {
            try setFinderTags(tags, at: try target(path), relative: path)
        }
        for (path, comment) in (fixture.comments ?? [:]).sorted(by: { $0.key < $1.key }) {
            let data = try plist(comment, path)
            try setXattr(finderCommentXattr, data, at: try target(path), relative: path)
        }
        for (path, days) in (fixture.lastOpenedDays ?? [:]).sorted(by: { $0.key < $1.key }) {
            try setXattr(lastUsedDateXattr, lastUsedDateValue(noon(daysFromToday: days)), at: try target(path), relative: path)
        }
        // Modification dates last but one: creating children bumps a folder's mtime; xattrs and chmod don't.
        for (path, days) in (fixture.mtimeDays ?? [:]).sorted(by: { $0.key.count > $1.key.count }) {
            let url = try target(path)
            do { try fm.setAttributes([.modificationDate: noon(daysFromToday: days)], ofItemAtPath: url.path) } catch {
                throw .io(path, Int32((error as NSError).code))
            }
        }
        // Explicit modes last: a mode-000 folder would block every write above inside it (chmod keeps mtimes).
        for (path, mode) in (fixture.modes ?? [:]).sorted(by: { $0.key.count > $1.key.count }) {
            let url = try target(path)
            guard let bits = UInt16(mode, radix: 8) else { throw .badMode(path) }
            if chmod(url.path, mode_t(bits)) != 0 { throw .io(path, errno) }
        }
    }

    // MARK: Phase 3 fixtures (P3-13)

    /// FixtureTree.flat's names: "file-" + the 1-based index zero-padded to 6 digits + ".txt".
    static func bulkName(_ i: Int) -> String {
        let n = String(i)
        return "file-" + String(repeating: "0", count: max(0, 6 - n.count)) + n + ".txt"
    }

    /// `count` deterministic bytes (SplitMix64, seed 0x6D6163) with the high bit set and byte 0 = 0x00, so the
    /// data is never valid text (the text sniffer sees a NUL and invalid UTF-8).
    static func binaryData(_ count: Int) -> Data {
        var seed: UInt64 = 0x6D6163
        func next() -> UInt64 {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) | 0x80 }
        if !bytes.isEmpty { bytes[0] = 0 }
        return Data(bytes)
    }

    /// The fake Spotlight's items for `items` (paths under `root`, which the caller has resolved). Content type trees
    /// as Spotlight reports them: files `public.data` + the extension's type and its supertypes, folders
    /// `public.folder`, apps the application bundle tree.
    static func metadataItems(_ items: [ScenarioFile.SpotlightFixture], root: URL, now: Date = Date()) -> [MetadataItem] {
        var base = root.standardizedFileURL.path(percentEncoded: false)
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        return items.map { item in
            let name = String(item.path.split(separator: "/").last ?? Substring(item.path))
            let tree: [String]
            switch item.kind ?? "file" {
            case "folder": tree = ["public.folder", "public.directory", "public.item"]
            case "app": tree = ["com.apple.application-bundle", "com.apple.application", "com.apple.package", "public.directory", "public.item"]
            default:
                let ext = (name as NSString).pathExtension
                var types: [String] = []
                if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                    var queue = [type]
                    while let t = queue.first {
                        queue.removeFirst()
                        if types.contains(t.identifier) { continue }
                        types.append(t.identifier)
                        queue += t.supertypes.sorted { $0.identifier < $1.identifier }
                    }
                }
                tree = types.contains("public.data") ? types : types + ["public.data", "public.item"]
            }
            return MetadataItem(path: base + "/" + item.path, name: name, size: Int64(item.size ?? 1), modified: now, created: now,
                                contentTypeTree: tree, isInvisible: false)
        }
    }

    // MARK: Phase 2 metadata (same encodings as MacxFixtures.FixtureMetadata, which the app must not link)

    static let finderTagsXattr = "com.apple.metadata:_kMDItemUserTags"
    static let finderCommentXattr = "com.apple.metadata:kMDItemFinderComment"
    static let lastUsedDateXattr = "com.apple.lastuseddate#PS"

    /// The confined target of an fs step (fsWrite/fsTags). Synchronous: lane only. `root` must be symlink-resolved;
    /// `roots` are its spellings (ScenarioDriver.rootPrefixes). `relative` must pass ScenarioDriver.guardedURL; then
    /// the deepest *existing* ancestor of the parent is realpath'd and must sit inside `roots` (a link inside the root
    /// may point out, and resolvingSymlinksInPath leaves a path with missing components unresolved). Missing parent
    /// components are created one at a time with mkdirat + openat(O_NOFOLLOW | O_DIRECTORY) from that ancestor, so a
    /// symlink (dangling or not) is never followed. Returns <real parent>/<last component>; with `createParents` false
    /// a missing parent throws instead.
    static func confinedTarget(_ relative: String, root: URL, roots: [String],
                               createParents: Bool) throws(ScenarioFixtureError) -> URL {
        guard let lexical = ScenarioDriver.guardedURL(relative, root: root) else { throw .unsafePath(relative) }
        var rootPath = root.standardizedFileURL.path(percentEncoded: false)
        if rootPath.count > 1, rootPath.hasSuffix("/") { rootPath.removeLast() }
        let parentRelative = String(lexical.path(percentEncoded: false).dropFirst(rootPath.count))
            .split(separator: "/").map(String.init).dropLast()
        var missing: [String] = []
        var existing = Array(parentRelative)
        var real: String?
        while real == nil {
            let candidate = ([rootPath] + existing).joined(separator: "/")
            if let resolved = realpath(candidate, nil) {
                real = String(cString: resolved)
                free(resolved)
            } else if errno == ENOENT, let last = existing.popLast() {
                missing.insert(last, at: 0)
            } else {
                throw .io(candidate, errno)
            }
        }
        guard let ancestor = real, ScenarioDriver.relativePath(ancestor, roots: roots) != nil else {
            throw .unsafePath(relative)
        }
        if !missing.isEmpty, !createParents { throw .io(relative, ENOENT) }
        var fd = open(ancestor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .io(ancestor, errno) }
        defer { close(fd) }
        var path = ancestor
        for component in missing {
            if mkdirat(fd, component, 0o755) != 0, errno != EEXIST { throw .io(path + "/" + component, errno) }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw .unsafePath(relative) }  // ELOOP/ENOTDIR: a symlink or file is in the way
            close(fd)
            fd = next
            path += "/" + component
        }
        return URL(filePath: path, directoryHint: .isDirectory).appending(path: lexical.lastPathComponent)
    }

    /// Writes `count` zero bytes at `url` (creating or replacing it, never through a symlink), creating parents.
    /// Synchronous: lane only. The caller has confined `url` to the root (confinedTarget).
    static func writeZeros(_ count: Int, at url: URL) throws(ScenarioFixtureError) {
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
            throw .io(url.path, Int32((error as NSError).code))
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw .io(url.path, errno) }
        defer { close(fd) }
        let chunk = [UInt8](repeating: 0, count: min(count, 1 << 20))
        var left = count
        while left > 0 {
            let n = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, min(left, $0.count)) }
            guard n > 0 else { throw .io(url.path, errno) }
            left -= n
        }
    }

    static func setFinderTags(_ tags: [String], at url: URL, relative: String) throws(ScenarioFixtureError) {
        try setXattr(finderTagsXattr, try plist(tags, relative), at: url, relative: relative)
    }

    private static func plist(_ value: Any, _ relative: String) throws(ScenarioFixtureError) -> Data {
        do { return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) } catch {
            throw .io(relative, EINVAL)
        }
    }

    private static func setXattr(_ name: String, _ data: Data, at url: URL, relative: String) throws(ScenarioFixtureError) {
        let rc = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        if rc != 0 { throw .io(relative, errno) }
    }

    /// 16 bytes: tv_sec, tv_nsec (Int64, little endian).
    static func lastUsedDateValue(_ date: Date) -> Data {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        var data = Data()
        withUnsafeBytes(of: Int64(seconds).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64(((date.timeIntervalSince1970 - seconds) * 1e9).rounded()).littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Noon local time, `days` from today.
    static func noon(daysFromToday days: Int, calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    static func pngData(pixels: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let output = NSMutableData()
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? output as Data : nil
    }

    /// Names the browser should list in --root once the fixture exists (Show Hidden off).
    static func topLevelVisibleNames(_ fixture: ScenarioFile.Fixture) -> Set<String> {
        let hidden = Set(fixture.hidden ?? [])
        let phase3 = Array((fixture.contents ?? [:]).keys) + Array((fixture.binary ?? [:]).keys) + Array((fixture.bulk ?? [:]).keys)
        return Set((fixture.files + fixture.dirs + (fixture.images ?? []) + phase3).filter { !hidden.contains($0) }
            .compactMap { $0.split(separator: "/").first.map(String.init) }
            .filter { !$0.hasPrefix(".") })
    }
}
