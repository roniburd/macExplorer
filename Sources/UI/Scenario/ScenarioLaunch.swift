import AppKit
import Core
import Foundation

public enum ScenarioLaunch {
    /// Call once the first browser window is open. A no-op unless --scenario was given; otherwise runs the
    /// driver, releases the private pasteboard, and exits 0 (passed) or 1 (failed). It skips
    /// applicationShouldTerminate: sandbox runs have nothing to save, and ui-scenarios.sh deletes the sandbox.
    @MainActor public static func runIfRequested(context: UIContext) {
        guard let file = context.options.scenario else { return }
        let stateDirectory = context.options.stateDirectory ?? FileManager.default.temporaryDirectory
        let output = context.options.scenarioOutput ?? stateDirectory.appending(path: "scenario-result.json")
        Task { @MainActor in
            let passed = await ScenarioDriver(context: context, file: file, output: output).run()
            if let name = context.options.pasteboardName { NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally() }
            exit(passed ? 0 : 1)
        }
    }
}
