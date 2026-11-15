import XCTest
import Darwin
@testable import Core
import MacxFS
import MacxFixtures

/// Describes a job the child process runs until it SIGKILLs itself at `fault`.
struct CrashSpec: Codable {
    var mode: String                 // "move" | "copy" | "batchRename"
    var sources: [String]
    /// A folder path; for "batchRename" the new names (one per source, newline-separated, no "/").
    var destination: String
    var journal: String
    var trash: String
    var fault: String                // FaultPoint raw value
    var conflict: String?            // ConflictAction raw value answered for every conflict
    var forceCrossVolume: Bool
    var allowClone: Bool
}

extension CrashSpec {
    /// Paths the sandbox guard checks besides sources, journal and trash: the destination folder. A batch rename's
    /// destination holds plain names (checked separately), whose targets live next to the sources.
    var destinationPaths: [String] { mode == "batchRename" ? [] : [destination] }
    /// Every path the sandbox guards check.
    var guardedPaths: [String] { sources + destinationPaths + [journal, trash] }
}

/// Entry point executed only inside the child `xctest` process (skips everywhere else).
final class CrashHelperEntry: XCTestCase {
    func testRunCrashHelper() async throws {
        guard let raw = ProcessInfo.processInfo.environment["MACX_CRASH_SPEC"] else {
            throw XCTSkip("child-process entry point for crash tests")
        }
        let spec = try JSONDecoder().decode(CrashSpec.self, from: Data(raw.utf8))
        // Every path must resolve (symlinks, "..") strictly inside one and the same macx-tests sandbox in the temp dir.
        guard let sandboxRoot = Sandbox.commonRoot(of: spec.guardedPaths, prefixes: ["macx-tests"]) else {
            return XCTFail("crash helper refuses paths outside one test sandbox: \(spec.guardedPaths)")
        }
        let fault = try XCTUnwrap(FaultPoint(rawValue: spec.fault))
        var tuning = FileOpTuning(faultHook: { point, _ in if point == fault { kill(getpid(), SIGKILL) } })
        tuning.forceCrossVolume = spec.forceCrossVolume
        tuning.allowClone = spec.allowClone
        let interaction = ScriptedInteraction(conflicts: spec.conflict.flatMap(ConflictAction.init(rawValue:)).map { [.all($0)] } ?? [])
        let queue = FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: URL(filePath: spec.trash, directoryHint: .isDirectory)),
                                journal: Journal(fileURL: URL(filePath: spec.journal)), interaction: interaction, tuning: tuning)
        let sources = spec.sources.map { URL(filePath: $0) }
        let destination = URL(filePath: spec.destination, directoryHint: .isDirectory)
        let kind: JobKind = switch spec.mode {
        case "move": .move(sources: sources, destination: destination)
        case "batchRename":
            .batchRename(zip(sources, spec.destination.split(separator: "\n", omittingEmptySubsequences: false))
                .map { BatchRenamePair(url: $0, newName: String($1)) })
        default: .copy(sources: sources, destination: destination)
        }
        // Same guard on the request actually enqueued (the child has no FileOpsTestCase sandbox to delegate to).
        let jobPaths = kind.allURLs.map { $0.path(percentEncoded: false) }
        guard Sandbox.commonRoot(of: jobPaths, prefixes: ["macx-tests"]) == sandboxRoot else {
            return XCTFail("crash helper refuses job URLs outside the test sandbox: \(jobPaths)")
        }
        let id = await queue.enqueue(JobRequest(kind))
        _ = await queue.outcome(of: id)
        XCTFail("fault point \(spec.fault) was never reached")
    }
}

extension FileOpsTestCase {
    /// Runs `spec` in a child `xcrun xctest` process of this same test bundle. Returns true if the child was SIGKILLed.
    func runCrashingChild(_ spec: CrashSpec) async throws -> Bool {
        let sandboxRoot = Sandbox.enclosingRoot(of: sandbox.root.path(percentEncoded: false))
        guard sandboxRoot != nil, Sandbox.commonRoot(of: spec.guardedPaths, prefixes: ["macx-tests"]) == sandboxRoot else {
            XCTFail("outside this test's sandbox: \(spec.guardedPaths)"); return false
        }
        if spec.mode == "batchRename" {
            let names = spec.destination.split(separator: "\n", omittingEmptySubsequences: false)
            guard names.count == spec.sources.count, names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != ".." }) else {
                XCTFail("batchRename names must be plain names, one per source"); return false
            }
        }
        let bundle = Bundle(for: CrashHelperEntry.self).bundlePath
        guard bundle.hasSuffix(".xctest"), FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("xcrun xctest unavailable (bundle \(bundle))")
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "CoreTests.CrashHelperEntry/testRunCrashHelper", bundle]
        var env = ProcessInfo.processInfo.environment
        env["MACX_CRASH_SPEC"] = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, any Error>) in
            process.terminationHandler = { p in
                c.resume(returning: p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL)
            }
            do { try process.run() } catch { c.resume(throwing: error) }
        }
    }
}
