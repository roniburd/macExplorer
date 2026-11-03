import AppKit
import Foundation
import MacxFS

/// `NSWorkspace.shared.notificationCenter` mount/unmount/rename notifications as `VolumeEvent`s (§4.2).
public struct WorkspaceVolumeEvents: VolumeEventSource {
    static let didMount = NSWorkspace.didMountNotification
    static let willUnmount = NSWorkspace.willUnmountNotification
    static let didUnmount = NSWorkspace.didUnmountNotification
    static let didRename = NSWorkspace.didRenameVolumeNotification
    static let volumeURLKey = NSWorkspace.volumeURLUserInfoKey

    public init() {}

    /// Subscribes for the app's lifetime (Volumes calls this once).
    @MainActor public func start(_ handler: @escaping @MainActor (VolumeEvent) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [Self.didMount, Self.willUnmount, Self.didUnmount, Self.didRename] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let event = Self.event(for: note.name, userInfo: note.userInfo) else { return }
                MainActor.assumeIsolated { handler(event) }
            }
        }
    }

    static func event(for name: Notification.Name, userInfo: [AnyHashable: Any]?) -> VolumeEvent? {
        guard let url = userInfo?[volumeURLKey] as? URL else { return nil }
        switch name {
        case didMount: return .didMount(url)
        case willUnmount: return .willUnmount(url)
        case didUnmount: return .didUnmount(url)
        case didRename: return .didRename(url)
        default: return nil
        }
    }
}
