import Foundation

public enum UpdateError: Sendable, Equatable {
    case offline
    case network(String)
    case verificationFailed(version: String?)
    /// Running from a disk image or a translocated location: Sparkle can't replace the app.
    case notInApplications
    case other(String)
}

public enum UpdateEvent: Sendable, Equatable {
    case checkStarted(userInitiated: Bool)
    case noUpdateFound(currentVersion: String)
    case updateFound(version: String)
    case downloadProgress(Double?)
    case readyToInstall(version: String, notesURL: URL?)
    case failed(UpdateError)
    /// The user closed the popover on a transient result (up to date, failed).
    case acknowledged
}

/// Spec §3: background work is invisible until an update is ready; user-initiated checks show every step.
public enum UpdateState: Sendable, Equatable {
    case idle
    case checking(userInitiated: Bool)
    case upToDate(version: String)
    case downloading(version: String, fraction: Double?, userInitiated: Bool)
    case readyToRestart(version: String, notesURL: URL?)
    case failed(UpdateError, userInitiated: Bool)

    public var isBadgeVisible: Bool {
        switch self {
        case .idle: false
        case .checking(let user): user
        case .upToDate: true
        case .downloading(_, _, let user): user
        case .readyToRestart: true
        case .failed(let error, let user):
            if case .verificationFailed = error { true } else { user }
        }
    }

    /// Pure transition. Events that make no sense in the current state return `self`.
    public func reduce(_ event: UpdateEvent) -> UpdateState { transition(event) ?? self }

    /// Pure transition that distinguishes accepted from illegal events: `nil` means the event is
    /// illegal in this state and is ignored. Spec §2.1 wants those logged; Core has no logger, so the
    /// caller (UpdateModel) logs when this returns `nil`. A non-nil result may equal `self`
    /// (e.g. a duplicate progress tick) — that is accepted, not illegal.
    public func transition(_ event: UpdateEvent) -> UpdateState? {
        if case .readyToRestart = self {
            if case .readyToInstall(let version, let notes) = event { return .readyToRestart(version: version, notesURL: notes) }
            return nil
        }
        switch (self, event) {
        case (_, .readyToInstall(let version, let notes)):
            return .readyToRestart(version: version, notesURL: notes)

        case (.checking(let was), .checkStarted(let user)):
            return .checking(userInitiated: was || user)
        case (.downloading(let v, let f, let was), .checkStarted(let user)):
            return .downloading(version: v, fraction: f, userInitiated: was || user)
        case (_, .checkStarted(let user)):
            return .checking(userInitiated: user)

        case (.checking(let user), .noUpdateFound(let current)):
            return user ? .upToDate(version: current) : .idle

        case (.checking(let user), .updateFound(let version)):
            return .downloading(version: version, fraction: nil, userInitiated: user)
        case (.idle, .updateFound(let version)), (.upToDate, .updateFound(let version)), (.failed, .updateFound(let version)):
            return .downloading(version: version, fraction: nil, userInitiated: false)

        case (.downloading(let v, _, let user), .downloadProgress(let f)):
            return .downloading(version: v, fraction: f, userInitiated: user)

        case (.checking(let user), .failed(let error)), (.downloading(_, _, let user), .failed(let error)):
            if case .verificationFailed = error { return .failed(error, userInitiated: user) }
            return user ? .failed(error, userInitiated: true) : .idle

        case (.upToDate, .acknowledged), (.failed, .acknowledged):
            return .idle

        default:
            return nil
        }
    }
}
