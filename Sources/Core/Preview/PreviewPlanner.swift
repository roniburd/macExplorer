import Foundation
import Darwin
import UniformTypeIdentifiers
import MacxFS

struct ProbeStat: Sendable, Equatable { var mode: mode_t; var flags: UInt32 }
struct ProbeError: Error, Sendable, Equatable { var code: Int32 }

/// `stat` (following links) or `lstat`. Lane only; callers wrap it in withNoMaterialization.
/// A free function because `PreviewProbe.stat` shadows Darwin's `stat` inside the struct.
private func systemStat(_ path: String, follow: Bool) -> Result<ProbeStat, ProbeError> {
    var st = stat()
    let rc = follow ? stat(path, &st) : lstat(path, &st)
    return rc == 0 ? .success(ProbeStat(mode: st.st_mode, flags: st.st_flags)) : .failure(ProbeError(code: errno))
}

/// File-system calls used by `PreviewPlanner.resolve`. Tests substitute `stat` to simulate dataless files.
struct PreviewProbe: Sendable {
    var stat: @Sendable (_ path: String, _ follow: Bool) -> Result<ProbeStat, ProbeError>
    var readPrefix: @Sendable (_ path: String, _ count: Int) -> Result<[UInt8], ProbeError>

    static let system = PreviewProbe(
        stat: { path, follow in systemStat(path, follow: follow) },
        readPrefix: { path, count in PreviewProbe.read(path, count: count) })

    /// Reads up to `count` bytes. Lane only; callers wrap it in withNoMaterialization.
    static func read(_ path: String, count: Int) -> Result<[UInt8], ProbeError> {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(ProbeError(code: errno)) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + filled, count - filled) }
            if n < 0 { if errno == EINTR { continue }; return .failure(ProbeError(code: errno)) }
            if n == 0 { break }
            filled += n
        }
        return .success(Array(buffer.prefix(filled)))
    }
}

public enum PreviewPlanner {
    static let sniffSize = 4_096

    public static func classify(_ type: UTType) -> PreviewClass {
        if [UTType.rtf, .rtfd, .flatRTFD, .pdf].contains(where: { type.conforms(to: $0) }) { return .quickLook }
        if type.conforms(to: .propertyList) { return .sniff }
        let textRoots: [UTType] = [.text, .sourceCode, .script, .json, .xml] + [UTType("public.yaml")].compactMap { $0 }
        if textRoots.contains(where: { type.conforms(to: $0) }) { return .text }
        if type == .data || type == .item || type.isDynamic || type.identifier.hasPrefix("dyn.") || type == .unixExecutable { return .sniff }
        return .quickLook
    }

    public static func resolve(_ subject: PreviewSubject, lanes: LanePool, volume: VolumeID, types: TypeRegistry) async -> PreviewContent {
        await resolve(subject, lanes: lanes, volume: volume, types: types, probe: .system)
    }

    static func resolve(_ subject: PreviewSubject, lanes: LanePool, volume: VolumeID, types: TypeRegistry,
                        probe: PreviewProbe) async -> PreviewContent {
        let url = subject.url
        do {
            return try await lanes.perform(on: volume) { _ in
                withNoMaterialization { decide(subject, types: types, probe: probe) }
            }
        } catch {
            return .unavailable(url, code: ETIMEDOUT)
        }
    }

    static func decide(_ subject: PreviewSubject, types: TypeRegistry, probe: PreviewProbe) -> PreviewContent {
        let url = subject.url
        let path = url.path(percentEncoded: false)
        var st: ProbeStat
        switch probe.stat(path, false) {
        case .failure(let e): return .unavailable(url, code: e.code)
        case .success(let s): st = s
        }
        var typeIndex = subject.typeIndex
        var readPath = path
        if (st.mode & S_IFMT) == S_IFLNK {
            guard case .success(let target) = probe.stat(path, true) else { return .brokenLink(url) }
            st = target
            let resolved = url.resolvingSymlinksInPath()
            readPath = resolved.path(percentEncoded: false)
            typeIndex = types.index(forExtension: Substring(resolved.pathExtension), isDirectory: (st.mode & S_IFMT) == S_IFDIR)
        } else if subject.kind == .alias {
            guard let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
                  case .success(let target) = probe.stat(resolved.path(percentEncoded: false), true) else { return .brokenLink(url) }
            st = target
            readPath = resolved.path(percentEncoded: false)
            typeIndex = types.index(forExtension: Substring(resolved.pathExtension), isDirectory: (st.mode & S_IFMT) == S_IFDIR)
        }
        let dataless = st.flags & UInt32(SF_DATALESS) != 0
        if (st.mode & S_IFMT) == S_IFDIR {
            guard subject.kind == .package || types.isPackage(typeIndex) else { return .folder(url) }
            // An evicted package (.pages, .rtfd, .app) would be materialized by QLPreviewView (spec §11).
            return dataless ? .cloudPlaceholder(url) : .quickLook(url)
        }
        if dataless { return .cloudPlaceholder(url) }
        switch classify(types.type(at: typeIndex)) {
        case .text: return .text(url)
        case .quickLook: return .quickLook(url)
        case .sniff:
            switch probe.readPrefix(readPath, sniffSize) {
            case .failure(let e): return .unavailable(url, code: e.code)
            case .success(let bytes):
                if bytes.isEmpty { return .text(url) }
                return TextPreviewLoader.decode(bytes, truncated: bytes.count == sniffSize) != nil ? .text(url) : .quickLook(url)
            }
        }
    }
}
