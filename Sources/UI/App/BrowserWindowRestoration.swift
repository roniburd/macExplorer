import AppKit

/// AppKit window restoration for browser windows (§5.1; off in sandbox mode, where windows are not restorable).
/// AppKit calls `restoreWindow` before `applicationDidFinishLaunching`, while Core is still starting, so requests are
/// queued here and `WindowManager.restoreOrOpenInitial()` opens them. Later requests open at once.
final class BrowserWindowRestoration: NSObject, NSWindowRestoration {
    static let identifier = NSUserInterfaceItemIdentifier("macx.browser")
    static let folderKey = "macx.folderPath"

    typealias Completion = (NSWindow?, (any Error)?) -> Void

    @MainActor static var pending: [(url: URL, completion: Completion)] = []
    /// Installed by the WindowManager once launch restoration is done.
    @MainActor static var consumer: ((URL, Completion) -> Void)?

    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping Completion) {
        MainActor.assumeIsolated {
            guard identifier == Self.identifier, let url = folderURL(from: state) else {
                completionHandler(nil, CocoaError(.featureUnsupported))
                return
            }
            if let consumer { consumer(url, completionHandler) } else { pending.append((url, completionHandler)) }
        }
    }

    static func encode(_ url: URL, into coder: NSCoder) {
        coder.encode(url.path(percentEncoded: false) as NSString, forKey: folderKey)
    }

    static func folderURL(from coder: NSCoder) -> URL? {
        guard let path = coder.decodeObject(of: NSString.self, forKey: folderKey) as String?, path.hasPrefix("/") else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Hands every queued request to `open` (nil refuses it) and routes later ones there too.
    @MainActor static func drain(_ open: @escaping (URL) -> NSWindow?) -> Int {
        let requests = pending
        pending = []
        consumer = { url, completion in
            let window = open(url)
            completion(window, window == nil ? CocoaError(.featureUnsupported) : nil)
        }
        var opened = 0
        for request in requests {
            let window = open(request.url)
            if window != nil { opened += 1 }
            request.completion(window, window == nil ? CocoaError(.featureUnsupported) : nil)
        }
        return opened
    }
}
