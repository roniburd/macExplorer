import AppKit
import Darwin
import Foundation

enum ScenarioCLIError: Error, Equatable, CustomStringConvertible {
    case missingValue(String), unknownOption(String), missingOption(String), badValue(String, String)
    var description: String {
        switch self {
        case .missingValue(let f): "missing value for \(f)"
        case .unknownOption(let f): "unknown option \(f)"
        case .missingOption(let f): "missing required option \(f)"
        case .badValue(let f, let v): "bad value '\(v)' for \(f)"
        }
    }
}

struct ScenarioCLIOptions: Equatable, Sendable {
    var list = false
    var filter: String? = nil
    var json: URL? = nil
    /// Each scenario sandbox root is appended here as soon as it exists, so run-scenarios.sh can detach
    /// and remove exactly those directories even if the CLI traps (FileManager.temporaryDirectory
    /// ignores TMPDIR, so sandboxes are siblings of the run directory, not children).
    var manifest: URL? = nil
    var keepSandbox = false
    var requireImages = false
    var printGeneralChangeCount = false

    static func parse(_ args: [String]) throws(ScenarioCLIError) -> ScenarioCLIOptions {
        var o = ScenarioCLIOptions()
        var i = 0
        func value(_ flag: String) throws(ScenarioCLIError) -> String {
            i += 1
            guard i < args.count else { throw .missingValue(flag) }
            return args[i]
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--list": o.list = true
            case "--filter": o.filter = try value(flag)
            case "--json": o.json = URL(filePath: try value(flag))
            case "--manifest": o.manifest = URL(filePath: try value(flag))
            case "--keep-sandbox": o.keepSandbox = true
            case "--require-images": o.requireImages = true
            case "--general-pasteboard-changecount": o.printGeneralChangeCount = true
            default: throw .unknownOption(flag)
            }
            i += 1
        }
        return o
    }
}

@MainActor
enum ScenarioCLI {
    static func main(_ args: [String]) async -> Int32 {
        if args.first == "crash-helper" { return await CrashHelper.run(Array(args.dropFirst())) }
        let options: ScenarioCLIOptions
        do { options = try ScenarioCLIOptions.parse(args) } catch {
            FileHandle.standardError.write(Data("macx-scenarios: \(error)\n".utf8))
            return 64
        }
        if options.printGeneralChangeCount {
            // Read-only: verify-phase1.sh compares this before/after a full run (nothing may write the general pasteboard).
            print(NSPasteboard.general.changeCount)
            return 0
        }
        let selected = Catalog.select(options.filter)
        if options.list {
            for s in selected { print(s.name) }
            return 0
        }
        guard !selected.isEmpty else {
            FileHandle.standardError.write(Data("macx-scenarios: no scenario matches '\(options.filter ?? "")'\n".utf8))
            return 64
        }
        if let manifest = options.manifest {
            let path = manifest.path(percentEncoded: false)
            ScenarioRunner.onSandboxCreated = { root in
                let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
                guard fd >= 0 else { return }
                let line = Array((root.path(percentEncoded: false) + "\n").utf8)
                _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                close(fd)
            }
        }
        let report = await ScenarioRunner.run(selected, helper: Bundle.main.executableURL, requireImages: options.requireImages,
                                              keepSandbox: options.keepSandbox) { print($0) }
        if let json = options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: json, options: .atomic)
        }
        print("macx-scenarios: \(report.passed) passed, \(report.failed) failed, \(report.skipped) skipped")
        return report.failed == 0 ? 0 : 1
    }
}
