import Core
import Darwin
import Foundation
import MacxFS

struct CrashHelperOptions: Equatable, Sendable {
    enum Mode: String, Sendable { case copy, replace, batchRename }
    var mode: Mode
    var source: URL
    var destination: URL
    var journal: URL
    var trash: URL
    var ready: URL
    /// batchRename: (old name, new name) inside `source`, from `--names` ("old/new" per line, plain names only).
    var renames: [(String, String)] = []
    var allPaths: [String] { [source, destination, journal, trash, ready].map(\.path) }

    static func parse(_ args: [String]) throws(ScenarioCLIError) -> CrashHelperOptions {
        var values: [String: String] = [:]
        var i = 0
        while i < args.count {
            let flag = args[i]
            guard ["--mode", "--source", "--destination", "--journal", "--trash", "--ready", "--names"].contains(flag) else { throw .unknownOption(flag) }
            guard i + 1 < args.count else { throw .missingValue(flag) }
            values[flag] = args[i + 1]
            i += 2
        }
        func need(_ flag: String) throws(ScenarioCLIError) -> String {
            guard let v = values[flag] else { throw .missingOption(flag) }
            return v
        }
        let modeText = try need("--mode")
        guard let mode = Mode(rawValue: modeText) else { throw .badValue("--mode", modeText) }
        var options = CrashHelperOptions(mode: mode, source: URL(filePath: try need("--source")),
                                         destination: URL(filePath: try need("--destination")),
                                         journal: URL(filePath: try need("--journal")), trash: URL(filePath: try need("--trash")),
                                         ready: URL(filePath: try need("--ready")))
        if mode == .batchRename {
            let text = try need("--names")
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw .badValue("--names", String(line)) }
                options.renames.append((parts[0], parts[1]))
            }
            guard !options.renames.isEmpty else { throw .badValue("--names", text) }
        }
        return options
    }

    static func == (a: Self, b: Self) -> Bool {
        a.mode == b.mode && a.allPaths == b.allPaths && a.renames.map(\.0) == b.renames.map(\.0) && a.renames.map(\.1) == b.renames.map(\.1)
    }
}

/// Child process for the crash scenarios: runs one cross-volume move (or a batch rename, P4-23) and blocks forever at
/// the fault point
/// (after writing the ready marker) so the parent can SIGKILL it mid-operation.
@MainActor
enum CrashHelper {
    /// True only for absolute paths that, after standardization, have a `macx-scenario-*` ancestor.
    nonisolated static func isInsideScenarioSandbox(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let standardized = URL(filePath: path).standardized.path
        return standardized.split(separator: "/").dropLast().contains { $0.hasPrefix("macx-scenario-") }
    }

    static func run(_ args: [String]) async -> Int32 {
        guard let o = try? CrashHelperOptions.parse(args), o.allPaths.allSatisfy(isInsideScenarioSandbox) else { return 64 }
        let point: FaultPoint = switch o.mode {
        case .copy: .afterPartialCopy
        case .replace: .afterTrashDestination
        case .batchRename: .batchRenameStaged     // every item at its temporary name
        }
        let readyPath = o.ready.path
        let tuning = FileOpTuning(faultHook: { reached, _ in
            guard reached == point else { return }
            FileManager.default.createFile(atPath: readyPath, contents: Data("ready".utf8))
            while true { sleep(60) }        // the parent sends SIGKILL
        })
        let interaction = ScriptedInteraction(conflicts: o.mode == .replace ? [.one(.replace)] : [])
        let queue = FileOpQueue(lanes: LanePool(config: .default), trash: SandboxTrash(directory: o.trash),
                                journal: Journal(fileURL: o.journal), interaction: interaction, tuning: tuning)
        let kind: JobKind = o.mode == .batchRename
            ? .batchRename(o.renames.map { BatchRenamePair(url: o.source.appending(path: $0.0), newName: $0.1) })
            : .move(sources: [o.source], destination: o.destination)
        let id = await queue.enqueue(JobRequest(kind, registersUndo: false))
        _ = await queue.outcome(of: id)
        return 3   // reaching this line means the fault point never fired
    }
}
