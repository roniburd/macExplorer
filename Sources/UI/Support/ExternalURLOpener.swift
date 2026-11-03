import AppKit
import Core

/// The one place S5 opens non-file URLs (System Settings deep links). Sandboxed runs record instead (S5-C2).
@MainActor protocol ExternalURLOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor final class WorkspaceURLOpener: ExternalURLOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

@MainActor final class RecordingURLOpener: ExternalURLOpening {
    static let shared = RecordingURLOpener()
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
    func reset() { opened = [] }
}

@MainActor enum ExternalOpeners {
    static func opener(for options: LaunchOptions) -> any ExternalURLOpening {
        options.isSandboxed || options.fakeLaunchServices ? RecordingURLOpener.shared : WorkspaceURLOpener()
    }
}

enum SystemSettingsLinks {
    static let privacyAllFiles = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
