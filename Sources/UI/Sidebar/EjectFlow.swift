import AppKit
import Core
import MacxFS

enum RunningJobsChoice: Sendable, Equatable { case cancelJobs, wait, dontEject }

/// The questions and errors of an eject (§4.2, §5.9). Tests install a scripted one on `UIContext.ejectPrompts`.
@MainActor protocol EjectPrompting: AnyObject {
    /// Operations still running on the volume: cancel them, wait for them, or keep the volume.
    func runningJobs(volumeName: String, count: Int, window: NSWindow?) async -> RunningJobsChoice
    func ejectFailed(volumeName: String, error: EjectError, window: NSWindow?) async
}

/// Sidebar eject (⏏ button, ⌘E, menu): asks about running operations first (`CoreEnvironment.runningJobs(on:)`), then
/// `EjectCoordinator.eject` (release → unmount → busy diagnosis → one retry); failures name the blocking processes.
@MainActor
final class EjectFlow {
    private let environment: CoreEnvironment
    private let prompts: any EjectPrompting

    init(environment: CoreEnvironment, prompts: any EjectPrompting) {
        self.environment = environment
        self.prompts = prompts
    }

    /// true when the volume was ejected.
    @discardableResult
    func eject(_ volume: VolumeInfo, window: NSWindow?) async -> Bool {
        let running = await environment.runningJobs(on: volume.id)
        if !running.isEmpty {
            switch await prompts.runningJobs(volumeName: volume.name, count: running.count, window: window) {
            case .dontEject:
                return false
            case .cancelJobs:
                for id in running { await environment.fileOps.cancel(id) }
                for id in running { _ = await environment.fileOps.outcome(of: id) }
            case .wait:
                for id in running { _ = await environment.fileOps.outcome(of: id) }
            }
        }
        do {
            try await environment.ejectCoordinator.eject(volume)
            return true
        } catch {
            await prompts.ejectFailed(volumeName: volume.name, error: error, window: window)
            return false
        }
    }

    // MARK: text (pure)

    static func failureMessage(volumeName: String) -> String {
        String(format: L10n.string("“%@” couldn't be ejected."), volumeName)
    }

    static func failureDetail(_ error: EjectError) -> String {
        switch error {
        case .busy(let processes) where processes.isEmpty:
            L10n.string("It's in use by another app.")
        case .busy(let processes):
            String(format: L10n.string("It's in use by: %@."), processes.joined(separator: ", "))
        case .failed(_, let message):
            message
        }
    }
}

/// NSAlert sheets on the window (app-modal without one).
@MainActor
final class AlertEjectPrompts: EjectPrompting {
    func runningJobs(volumeName: String, count: Int, window: NSWindow?) async -> RunningJobsChoice {
        let alert = NSAlert()
        alert.messageText = String(format: L10n.string("%ld operations are still using “%@”."), count, volumeName)
        alert.informativeText = L10n.string("Cancel them and eject, or wait until they finish?")
        alert.addButton(withTitle: L10n.string("Wait"))
        alert.addButton(withTitle: L10n.string("Cancel Operations"))
        alert.addButton(withTitle: L10n.string("Don't Eject"))
        switch await Self.run(alert, window: window) {
        case .alertFirstButtonReturn: return .wait
        case .alertSecondButtonReturn: return .cancelJobs
        default: return .dontEject
        }
    }

    func ejectFailed(volumeName: String, error: EjectError, window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = EjectFlow.failureMessage(volumeName: volumeName)
        alert.informativeText = EjectFlow.failureDetail(error)
        alert.addButton(withTitle: L10n.string("OK"))
        _ = await Self.run(alert, window: window)
    }

    private static func run(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
    }
}
