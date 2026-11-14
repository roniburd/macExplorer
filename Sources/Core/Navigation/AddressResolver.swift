import Darwin
import Foundation
import MacxFS
import MacxPluginKit

public enum AddressResult: Sendable, Equatable {
    case folder(URL)
    case file(parent: URL, name: String)
    case notFound(String)       // the input text
    case noAccess(String)
    case remote(URL)            // a remote folder (ref resolved)
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
    public static func resolve(_ input: String, current: URL, home: URL, lanes: LanePool, mounts: MountTable,
                               remote: ProviderRegistry? = nil) async -> AddressResult {
        if let remote, let location = remoteTarget(input, current: current, registry: remote) {
            return await resolveRemote(location, input: input, registry: remote)
        }
        guard let url = parse(input, current: current, home: home) else { return .notFound(input) }
        let path = url.path(percentEncoded: false)
        let volume = mounts.volume(containing: path)?.id ?? .unknown
        return await classifyOnLane(path, input: input) { work in try await lanes.performRecovering(on: volume, .read, work) }
    }

    /// As `resolve(_:current:home:lanes:mounts:remote:)` on a lane of `volume`, which must be the volume of the parsed
    /// target (`parse` + `Volumes.volume(for:)`), not the current folder's: a target on another, hung volume would
    /// otherwise poison the current volume's lanes.
    public static func resolve(_ input: String, current: URL, home: URL, lanes: LanePool, volume: VolumeID,
                               remote: ProviderRegistry? = nil) async -> AddressResult {
        if let remote, let location = remoteTarget(input, current: current, registry: remote) {
            return await resolveRemote(location, input: input, registry: remote)
        }
        guard let url = parse(input, current: current, home: home) else { return .notFound(input) }
        return await classifyOnLane(url.path(percentEncoded: false), input: input) { work in
            try await lanes.perform(on: volume, .read, work)
        }
    }

    /// The remote location `input` names, before any network: a provider address (providers win over file paths,
    /// spec §2.4), an `x-macexplorer-remote:` URL of a registered provider, or, while `current` is remote, a relative
    /// path inside it ("lib", "../docs", "./a"). "/…", "~…" and other schemes stay file-system input (nil).
    public static func remoteTarget(_ input: String, current: URL, registry: ProviderRegistry) -> RemoteLocation? {
        let text = trimmedInput(input)
        guard !text.isEmpty else { return nil }
        if let location = registry.parse(address: text) { return location }
        if text.lowercased().hasPrefix(RemoteLocation.scheme + ":"), let url = URL(string: text),
           let location = RemoteLocation(url: url), registry.provider(id: location.provider) != nil {
            return location
        }
        guard let base = RemoteLocation(url: current), !text.hasPrefix("/"), !text.hasPrefix("~"),
              text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else { return nil }
        var location = base
        for component in text.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !location.path.isEmpty { location.path.removeLast() }
            default: location.path.append(String(component))
            }
        }
        return location
    }

    /// resolveRef, then what the location is: a folder → .remote; a file or link → its folder with it selected;
    /// a submodule (not browsable, spec §3) or any failure but "not found" → .noAccess.
    static func resolveRemote(_ location: RemoteLocation, input: String, registry: ProviderRegistry) async -> AddressResult {
        guard let provider = registry.provider(id: location.provider) else { return .notFound(input) }
        do {
            let resolved = try await provider.resolveRef(location)
            let item = try await registry.item(at: resolved)
            switch item.kind {
            case .directory:
                return .remote(resolved.url)
            case .file, .symlink:
                guard let parent = resolved.parent, let name = resolved.name else { return .notFound(input) }
                return .file(parent: parent.url, name: name)
            case .submodule:
                return .noAccess(input)
            @unknown default:
                return .noAccess(input)
            }
        } catch .notFound {
            return .notFound(input)
        } catch {
            return .noAccess(input)
        }
    }

    /// Surrounding whitespace and one pair of matching quotes removed (shared with absolutePath).
    static func trimmedInput(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == "'" || first == "\"", text.last == first {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    // MARK: - Internals (shared with PathCompletion)

    static func absolutePath(_ input: String, current: URL, home: URL) -> String? {
        let text = trimmedInput(input)
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
