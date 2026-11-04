import AppKit
import Core
import UI

let options: LaunchOptions
do {
    options = try LaunchOptions.parse(CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("macExplorer: \(LaunchErrorText.message(for: error))\n".utf8))
    exit(64)   // EX_USAGE
}

if let root = options.root {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
          isDirectory.boolValue else {
        FileHandle.standardError.write(Data("macExplorer: --root folder does not exist: \(root.path(percentEncoded: false))\n".utf8))
        exit(66)   // EX_NOINPUT
    }
}

if options.isSandboxed {
    // Volatile registration domain only (nothing is written): no saved window state in sandbox runs.
    UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
}

let app = MacxApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
