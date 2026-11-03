import Foundation
import Darwin
import MacxFS

struct PlanEntry: Sendable, Equatable {
    enum EntryType: Sendable, Equatable { case file, directory, symlink, other }
    var relativePath: String          // "" = the top-level item itself
    var type: EntryType
    var size: Int64
    var allocSize: Int64
    var mode: UInt16
    var isLocked: Bool
    var errorCode: Int32              // fts_errno for unreadable entries, else 0
}

struct PlanItem: Sendable {
    var source: URL
    var info: PosixFS.Info
    var entries: [PlanEntry]          // pre-order; only the root entry when not enumerated
    var sameVolume: Bool
    var contentsUnknown: Bool         // dataless folder under no-materialization
    var itemCount: Int { entries.count }
    var byteCount: Int64 { entries.reduce(0) { $0 + ($1.type == .file ? $1.size : 0) } }
}

struct Refusal: Sendable, Equatable { var url: URL; var kind: FileOpErrorKind }

struct JobPlan: Sendable {
    var items: [PlanItem] = []
    var refused: [Refusal] = []
    var neededBytes: Int64 = 0
    var availableBytes: Int64? = nil
    var destinationVolumeName = ""
    var capabilities = VolumeIdentity.Capabilities(clone: false, renameExcl: false, caseSensitive: false)
    var topLevelConflicts: [URL] = []
    var totalItems: Int { items.reduce(0) { $0 + $1.itemCount } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
}

enum PlanMode: Sendable, Equatable { case copy, move, enumerate(noMaterialization: Bool), shallow }

enum Planner {
    static func plan(sources: [URL], destination: URL?, mode: PlanMode, forceCrossVolume: Bool, lane: LaneContext) -> JobPlan {
        assertOffMain()
        var plan = JobPlan()
        let destResolved = destination.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        let destDevice = destination.flatMap { VolumeIdentity.device(of: $0.path) }
        if let destination {
            plan.capabilities = VolumeIdentity.capabilities(of: destination)
            let cap = VolumeIdentity.availableCapacity(of: destination)
            plan.availableBytes = cap.available
            plan.destinationVolumeName = cap.volumeName
        }
        for src in sources {
            lane.heartbeat()
            guard let info = PosixFS.info(src.path) else {
                plan.refused.append(Refusal(url: src, kind: .sourceGone)); continue
            }
            if let destResolved, mode == .copy || mode == .move {
                // Resolve only the parent: a symlink source must not be replaced by its target.
                let s = src.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appending(path: src.lastPathComponent).standardizedFileURL.path
                if isSelfOrDescendant(source: s, destination: destResolved) {
                    plan.refused.append(Refusal(url: src, kind: .intoItself)); continue
                }
            }
            let sameVolume = !forceCrossVolume && (destDevice == nil || info.identity.device == destDevice)
            let deep: Bool
            var noMat = false
            switch mode {
            case .copy: deep = true
            case .move: deep = !sameVolume
            case .enumerate(let nm): deep = true; noMat = nm
            case .shallow: deep = false
            }
            let (entries, unknown) = deep ? enumerate(src, info: info, noMaterialization: noMat, lane: lane)
                                          : ([rootEntry(info)], false)
            plan.items.append(PlanItem(source: src, info: info, entries: entries, sameVolume: sameVolume, contentsUnknown: unknown))
            if let destination, src.deletingLastPathComponent().standardizedFileURL.path != destination.standardizedFileURL.path,
               PosixFS.exists(destination.appending(path: src.lastPathComponent).path) {
                plan.topLevelConflicts.append(src)
            }
        }
        plan.neededBytes = neededBytes(plan.items, mode: mode, destinationClones: plan.capabilities.clone)
        return plan
    }

    static func isSelfOrDescendant(source: String, destination: String) -> Bool {
        destination == source || destination.hasPrefix(source.hasSuffix("/") ? source : source + "/")
    }

    /// §6.5: sum of allocated sizes of files that won't clone; same-volume moves need 0.
    static func neededBytes(_ items: [PlanItem], mode: PlanMode, destinationClones: Bool) -> Int64 {
        var total: Int64 = 0
        for item in items {
            switch mode {
            case .move where item.sameVolume: continue
            case .copy where item.sameVolume && destinationClones: continue
            case .copy, .move: total += item.entries.reduce(0) { $0 + ($1.type == .file ? $1.allocSize : 0) }
            default: continue
            }
        }
        return total
    }

    static func rootEntry(_ info: PosixFS.Info) -> PlanEntry {
        PlanEntry(relativePath: "", type: info.isDirectory ? .directory : info.isSymlink ? .symlink : info.isRegular ? .file : .other,
                  size: info.size, allocSize: info.allocSize, mode: info.mode, isLocked: info.isLocked, errorCode: 0)
    }

    /// Pre-order fts (FTS_PHYSICAL): links are entries, never followed; loops cannot occur.
    static func enumerate(_ url: URL, info: PosixFS.Info, noMaterialization: Bool, lane: LaneContext) -> (entries: [PlanEntry], contentsUnknown: Bool) {
        guard info.isDirectory else { return ([rootEntry(info)], false) }
        if noMaterialization && info.isDataless { return ([rootEntry(info)], true) }
        func walk() -> ([PlanEntry], Bool) {
            var out: [PlanEntry] = []
            var unknown = false
            let rootBytes = url.path.utf8.count
            PosixFS.walk(url.path) { path, ent in
                if out.count % 256 == 0 { lane.heartbeat() }
                let rel = path.utf8.count <= rootBytes ? "" : String(decoding: path.utf8.dropFirst(rootBytes + 1), as: UTF8.self)
                let st = ent.pointee.fts_statp?.pointee
                let ftsInfo = Int32(ent.pointee.fts_info)
                let type: PlanEntry.EntryType = switch ftsInfo {
                case FTS_D, FTS_DNR, FTS_DC: .directory
                case FTS_F: .file
                case FTS_SL, FTS_SLNONE: .symlink
                default: .other
                }
                let flags = st?.st_flags ?? 0
                out.append(PlanEntry(relativePath: rel, type: type, size: Int64(st?.st_size ?? 0),
                                     allocSize: Int64(st?.st_blocks ?? 0) * 512, mode: UInt16((st?.st_mode ?? 0) & 0o7777),
                                     isLocked: flags & UInt32(UF_IMMUTABLE) != 0,
                                     errorCode: ftsInfo == FTS_DNR || ftsInfo == FTS_ERR || ftsInfo == FTS_NS ? ent.pointee.fts_errno : 0))
                if noMaterialization, type == .directory, flags & UInt32(SF_DATALESS) != 0 { unknown = true; return false }
                return true
            }
            return (out, unknown)
        }
        return noMaterialization ? withNoMaterialization(walk) : walk()
    }
}
