import Foundation

/// Command-line options (overview §3.12). Sandbox mode (`--state-dir`) is how tests, scenarios and smoke runs keep
/// the app away from real user state: journal, settings and recents live in the state directory.
public struct LaunchOptions: Sendable, Equatable {
    public var root: URL?                  // --root <dir>: first window opens here; disables restoration
    public var stateDirectory: URL?        // --state-dir <dir>: journal + settings.json + recents; required with --root/--scenario
    public var sandboxTrash: URL?          // --sandbox-trash <dir>: SandboxTrash instead of SystemTrash
    public var pasteboardName: String?     // --pasteboard <name>: private NSPasteboard
    public var fakeLaunchServices: Bool    // --fake-launch-services
    public var skipOnboarding: Bool        // --skip-onboarding
    public var scenario: URL?              // --scenario <file.json>
    public var scenarioOutput: URL?        // --scenario-output <file.json>
    public var smokeExitAfter: Duration?   // --smoke-exit-after <seconds>: write <state-dir>/smoke.json then exit 0
    /// --index-status enabled|disabled|unknown (P3-13): what the fake index-status provider of a sandboxed run reports
    /// (nil = disabled). Sandboxed runs never ask the real Spotlight index.
    public var indexStatus: IndexingStatus? = nil

    public init() {
        fakeLaunchServices = false
        skipOnboarding = false
    }

    public var isSandboxed: Bool { stateDirectory != nil }

    /// Parses `CommandLine.arguments` (element 0 is the executable and is skipped).
    /// AppKit/Foundation argument-domain pairs (`-NS… value`, `-Apple… value`) and `-psn_…` are ignored.
    /// `--root`, `--scenario` and `--smoke-exit-after` require `--state-dir` (the app exits 64 otherwise).
    /// A directory option naming an existing non-directory fails with `notADirectory`; missing directories are allowed.
    public static func parse(_ arguments: [String]) throws(LaunchOptionsError) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        func value(for option: String) throws(LaunchOptionsError) -> String {
            let next = index + 1
            guard next < arguments.count, !arguments[next].isEmpty, !arguments[next].hasPrefix("--") else {
                throw .missingValue(option)
            }
            index = next
            return arguments[next]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--root": options.root = try directory(try value(for: argument))
            case "--state-dir": options.stateDirectory = try directory(try value(for: argument))
            case "--sandbox-trash": options.sandboxTrash = try directory(try value(for: argument))
            case "--pasteboard": options.pasteboardName = try value(for: argument)
            case "--fake-launch-services": options.fakeLaunchServices = true
            case "--skip-onboarding": options.skipOnboarding = true
            case "--scenario": options.scenario = file(try value(for: argument))
            case "--scenario-output": options.scenarioOutput = file(try value(for: argument))
            case "--smoke-exit-after":
                guard let seconds = Double(try value(for: argument)), seconds.isFinite, seconds >= 0 else {
                    throw .missingValue(argument)
                }
                options.smokeExitAfter = .milliseconds(Int64((seconds * 1000).rounded()))
            case "--index-status":
                let raw = try value(for: argument)
                guard let status = IndexingStatus(rawValue: raw) else { throw .invalidValue(option: argument, value: raw) }
                options.indexStatus = status
            default:
                if argument.hasPrefix("-psn_") { break }
                if isAppKitDefault(argument) {
                    index += 1   // skip the value (if any)
                    break
                }
                throw .unknownOption(argument)
            }
            index += 1
        }
        let needsState = options.root != nil || options.scenario != nil || options.smokeExitAfter != nil
        if needsState && options.stateDirectory == nil { throw .stateDirectoryRequired }
        return options
    }

    private static func isAppKitDefault(_ argument: String) -> Bool {
        !argument.hasPrefix("--") && (argument.hasPrefix("-NS") || argument.hasPrefix("-Apple"))
    }

    private static func absolute(_ path: String, hint: URL.DirectoryHint) -> URL {
        let url = URL(filePath: path, directoryHint: hint, relativeTo: nil)
        return URL(filePath: url.absoluteURL.standardizedFileURL.path(percentEncoded: false), directoryHint: hint)
    }

    private static func file(_ path: String) -> URL { absolute(path, hint: .notDirectory) }

    private static func directory(_ path: String) throws(LaunchOptionsError) -> URL {
        let url = absolute(path, hint: .isDirectory)
        // Check without the trailing slash: stat("file/") fails with ENOTDIR, which would hide a plain file.
        var checked = url.path(percentEncoded: false)
        while checked.count > 1, checked.hasSuffix("/") { checked.removeLast() }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: checked, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw .notADirectory(path)
        }
        return url
    }
}

public enum LaunchOptionsError: Error, Sendable, Equatable {
    case missingValue(String)
    case unknownOption(String)
    case stateDirectoryRequired            // --root or --scenario without --state-dir → exit 64
    case notADirectory(String)
    case invalidValue(option: String, value: String)   // e.g. --index-status maybe
}
