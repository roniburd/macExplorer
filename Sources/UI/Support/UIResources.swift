import Foundation

/// Locates the UI target's SwiftPM resource bundle (`macExplorer_UI.bundle`).
///
/// SwiftPM's generated `Bundle.module` looks in the `.app` root, which breaks code signing, so it is never used.
/// `scripts/bundle.sh` copies the bundle into `Contents/Resources`; unbundled runs (`swift run`, tests) find it next
/// to the executable or next to the test bundle in the build products directory.
public enum UIResources {
    public static let bundleName = "macExplorer_UI.bundle"

    /// The UI resource bundle, or `Bundle.main` if it cannot be found (strings then fall back to their keys).
    public static let bundle: Bundle = {
        let candidates = candidateDirectories(resourceURL: Bundle.main.resourceURL,
                                              executableURL: Bundle.main.executableURL,
                                              codeBundleURL: Bundle(for: BundleToken.self).bundleURL)
        return locate(in: candidates) ?? .main
    }()

    /// Search order: `Contents/Resources`, the executable's directory, the parent of the bundle containing this code.
    static func candidateDirectories(resourceURL: URL?, executableURL: URL?, codeBundleURL: URL?) -> [URL] {
        var result: [URL] = []
        func add(_ url: URL?) {
            guard let url else { return }
            let dir = URL(filePath: url.standardizedFileURL.path(percentEncoded: false), directoryHint: .isDirectory)
            if !result.contains(dir) { result.append(dir) }
        }
        add(resourceURL)
        add(executableURL?.deletingLastPathComponent())
        add(codeBundleURL?.deletingLastPathComponent())
        return result
    }

    /// The first `macExplorer_UI.bundle` found in `directories`.
    static func locate(in directories: [URL]) -> Bundle? {
        for dir in directories {
            let url = dir.appending(path: bundleName, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
               isDirectory.boolValue, let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }
}

private final class BundleToken {}
