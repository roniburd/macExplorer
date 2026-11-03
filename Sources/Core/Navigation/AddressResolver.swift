import Darwin
import Foundation
import MacxFS

public enum AddressResult: Sendable, Equatable {
    case folder(URL)
    case file(parent: URL, name: String)
    case notFound(String)       // the input text
    case noAccess(String)
}

/// Address-bar edit mode (§5.2): accepts /abs, ~, ~/rel, file:// URLs and paths relative to the current folder.
public enum AddressResolver {
    /// Pure: /abs, ~, ~/rel, file:// URLs, relative to `current`; standardizes "." and "..".
    /// Surrounding whitespace and one pair of matching quotes are stripped. "~name" is an ordinary relative name.
    /// Returns nil for empty input and for non-file or remote-host URLs. The result has no trailing slash. Paths are
    /// standardized lexically only (symlinks such as /private/var are kept as typed).
    public static func parse(_ input: String, current: URL, home: URL) -> URL? {
        guard let path = absolutePath(input, current: current, home: home) else { return nil }
        let normalized = normalize(path)
        return URL(filePath: normalized, directoryHint: normalized == "/" ? .isDirectory : .notDirectory)
    }

    /// parse + lstat/stat on a read lane of the volume containing the parsed path (longest mount-point match in
    /// `mounts`, `.unknown` when none). The address bar uses this: a typed path on a hung share then blocks only that
    /// share's lane, never the current folder's. A folder whose contents can't be listed (POSIX) is `.noAccess`; a
    /// package (e.g. an `.app`) is reported as a file so the caller selects it in its parent, as Finder's Go to
    /// Folder does. An unresponsive volume or failed lane reports `.noAccess`. Like FavoritesResolver, a call that
    /// stalls and then returns late resets that volume's poisoned count (`performRecovering`).
    public static func resolve(_ input: String, current: URL, home: URL, lanes: LanePool, mounts: MountTable) async -> AddressResult {
        guard let url = parse(input, current: current, home: home) else { return .notFound(input) }
        let path = url.path(percentEncoded: false)
        let volume = mounts.volume(containing: path)?.id ?? .unknown
        return await classifyOnLane(path, input: input) { work in try await lanes.performRecovering(on: volume, .read, work) }
    }

    /// As `resolve(_:current:home:lanes:mounts:)` on a lane of `volume`, which must be the volume of the parsed
    /// target (`parse` + `Volumes.volume(for:)`), not the current folder's: a target on another, hung volume would
    /// otherwise poison the current volume's lanes.
    public static func resolve(_ input: String, current: URL, home: URL, lanes: LanePool, volume: VolumeID) async -> AddressResult {
        guard let url = parse(input, current: current, home: home) else { return .notFound(input) }
        return await classifyOnLane(url.path(percentEncoded: false), input: input) { work in
            try await lanes.perform(on: volume, .read, work)
        }
    }

    // MARK: - Internals (shared with PathCompletion)

    static func absolutePath(_ input: String, current: URL, home: URL) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == "'" || first == "\"", text.last == first {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else { return nil }
        if let scheme = text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression),
           text[scheme].lowercased() != "file://" {
            return nil
        }
        if text.lowercased().hasPrefix("file:") {
            guard let url = URL(string: "file:" + text.dropFirst(5)), url.isFileURL else { return nil }
            if let host = url.host(percentEncoded: false), !host.isEmpty, host.lowercased() != "localhost" { return nil }
            let path = url.path(percentEncoded: false)
            return path.isEmpty ? "/" : path
        }
        if text == "~" { return plainPath(home) }
        if text.hasPrefix("~/") { return plainPath(home) + "/" + text.dropFirst(2) }
        if text.hasPrefix("/") { return text }
        return plainPath(current) + "/" + text
    }

    /// Lexical standardization: collapses "//", drops ".", applies ".." (never above "/"), no trailing slash.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// No `standardizedFileURL` here: it rewrites /private/var to /var, which would change the folder's identity.
    static func plainPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func classifyOnLane(
        _ path: String, input: String,
        _ run: (@escaping @Sendable (LaneContext) throws -> AddressResult) async throws -> AddressResult
    ) async -> AddressResult {
        do {
            return try await run { _ in
                assertOffMain()
                return withNoMaterialization { classify(path, input: input) }
            }
        } catch {
            return .noAccess(input)
        }
    }

    /// Runs on a lane thread.
    private static func classify(_ path: String, input: String) -> AddressResult {
        var st = stat()
        guard stat(path, &st) == 0 else {
            return errno == EACCES || errno == EPERM ? .noAccess(input) : .notFound(input)
        }
        let url = URL(filePath: path, directoryHint: .notDirectory)
        let parentPath = url.deletingLastPathComponent().path(percentEncoded: false)
        let parent = URL(filePath: parentPath, directoryHint: .isDirectory)
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            return .file(parent: parent, name: url.lastPathComponent)
        }
        if access(path, R_OK | X_OK) != 0, errno == EACCES { return .noAccess(input) }
        if path != "/", (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
            return .file(parent: parent, name: url.lastPathComponent)
        }
        return .folder(URL(filePath: path, directoryHint: .isDirectory))
    }
}
