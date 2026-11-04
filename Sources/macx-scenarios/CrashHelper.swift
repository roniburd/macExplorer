import Core
import Darwin
import Foundation
import MacxFS

struct CrashHelperOptions: Equatable, Sendable {
    enum Mode: String, Sendable { case copy, replace }
    var mode: Mode
    var source: URL
    var destination: URL
    var journal: URL
    var trash: URL
    var ready: URL
    var allPaths: [String] { [source, destination, journal, trash, ready].map(\.path) }

    static func parse(_ args: [String]) throws(ScenarioCLIError) -> CrashHelperOptions {
        var values: [String: String] = [:]
        var i = 0
        while i < args.count {
            let flag = args[i]
            guard ["--mode", "--source", "--destination", "--journal", "--trash", "--ready"].contains(flag) else { throw .unknownOption(flag) }
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
        return CrashHelperOptions(mode: mode, source: URL(filePath: try need("--source")),
                                  destination: URL(filePath: try need("--destination")),
                                  journal: URL(filePath: try need("--journal")), trash: URL(filePath: try need("--trash")),
                                  ready: URL(filePath: try need("--ready")))
    }
}

/// Child process for the crash scenarios: runs one cross-volume move and blocks forever at the fault point
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
        let point: FaultPoint = o.mode == .copy ? .afterPartialCopy : .afterTrashDestination
        let readyPath = o.ready.path
        let tuning = FileOpTuning(faultHook: { reached, _ in
            guard reached == point else { return }
            FileManager.default.createFile(atPath: readyPath, contents: Data("ready".utf8))
            while true { sleep(60) }        // the parent sends SIGKILL
        })
        let interaction = ScriptedInteraction(conflicts: o.mode == .replace ? [.one(.replace)] : [])
        let queue = FileOpQueue(lanes: LanePool(config: .default), trash: SandboxTrash(directory: o.trash),
                                journal: Journal(fileURL: o.journal), interaction: interaction, tuning: tuning)
        let id = await queue.enqueue(JobRequest(.move(sources: [o.source], destination: o.destination), registersUndo: false))
        _ = await queue.outcome(of: id)
        return 3   // reaching this line means the fault point never fired
    }
}
