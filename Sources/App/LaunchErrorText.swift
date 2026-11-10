import Core

/// Developer-facing (stderr) text for command-line errors; not localized.
enum LaunchErrorText {
    static func message(for error: LaunchOptionsError) -> String {
        switch error {
        case .missingValue(let option): "missing value for \(option)"
        case .unknownOption(let option): "unknown option \(option)"
        case .stateDirectoryRequired: "--root, --scenario, --smoke-exit-after and --keymap require --state-dir <dir>"
        case .notADirectory(let path): "not a directory: \(path)"
        case .invalidValue(let option, let value): "invalid value '\(value)' for \(option)"
        }
    }
}
