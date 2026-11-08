import Foundation
import Observation
import os
import Core

/// Removes its observer when released.
@MainActor public final class UpdateObservation {
    private let cancel: @MainActor () -> Void
    init(_ cancel: @escaping @MainActor () -> Void) { self.cancel = cancel }
    isolated deinit { cancel() }
}

/// The app-level Check for Updates… action (AppDelegate implements it: it opens a browser window when none is
/// open, so a badge is there to show the result). The menu item and Settings › Check Now both send it.
public enum UpdateCommands {
    public static let checkForUpdates = NSSelectorFromString("macx_checkForUpdates:")
    /// macExplorer › Install Previous Version… (AppDelegate; enabled when a live updater has a rollback service).
    public static let installPreviousVersion = NSSelectorFromString("macx_installPreviousVersion:")
}

/// What the toolbar badge, the menu and Settings read (spec §3). `UpdateController` installs the handlers; without
/// one (debug builds, sandbox runs, updates not configured) the model stays `.idle` and `isAvailable` is false.
@MainActor @Observable
public final class UpdateModel {
    private static let log = Logger(subsystem: "com.macexplorer.app", category: "updates")
    public private(set) var state: UpdateState = .idle
    public var installedVersion: String = ""
    /// Incremented by user-initiated checks: the key window's badge opens its popover.
    public private(set) var popoverRequest = 0

    @ObservationIgnored var checkHandler: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var restartHandler: (@MainActor () -> Void)?
    @ObservationIgnored var automaticChecksHandler: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var rollbackHandler: (@MainActor () -> RollbackService?)?
    @ObservationIgnored private var observers: [UUID: @MainActor (UpdateState) -> Void] = [:]

    public init() {}

    public var isAvailable: Bool { checkHandler != nil }
    /// Install Previous Version… can run (a live updater with a feed, a key and a replaceable app).
    public var canInstallPreviousVersion: Bool { isAvailable && rollbackService != nil }
    var rollbackService: RollbackService? { rollbackHandler?() }

    public func send(_ event: UpdateEvent) {
        // Spec §2.1: illegal transitions are ignored *and logged* (review of Task 1).
        guard let next = state.transition(event) else {
            Self.log.debug("ignored update event \(String(describing: event), privacy: .public) in state \(String(describing: self.state), privacy: .public)")
            return
        }
        guard next != state else { return }
        state = next
        for observer in observers.values { observer(next) }
    }

    public func checkNow(userInitiated: Bool = true) {
        guard let checkHandler else { return }
        if userInitiated { popoverRequest += 1 }
        send(.checkStarted(userInitiated: userInitiated))
        checkHandler(userInitiated)
    }

    public func restartNow() { restartHandler?() }
    public func acknowledge() { send(.acknowledged) }
    public func setAutomaticChecks(_ on: Bool) { automaticChecksHandler?(on) }

    public func addObserver(_ handler: @escaping @MainActor (UpdateState) -> Void) -> UpdateObservation {
        let id = UUID()
        observers[id] = handler
        return UpdateObservation { [weak self] in self?.observers[id] = nil }
    }
}
