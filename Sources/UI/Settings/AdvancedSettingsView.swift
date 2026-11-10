import SwiftUI
import Core

/// §7 Advanced: confirm before trash (off by default), confirm before delete (always on, shown locked), full path in
/// the window title, offer to report crashes on the next launch. Experimental: follow remote symlinks on SSH mounts.
struct AdvancedSettingsView: View {
    @Bindable var settings: Core.Settings

    var body: some View {
        Form {
            Toggle(L10n.string("Confirm before moving items to the Trash"), isOn: $settings.confirmBeforeTrash)
            Toggle(L10n.string("Confirm before deleting items permanently"), isOn: .constant(settings.confirmBeforeDelete))
                .disabled(true)
                .help(L10n.string("Permanent deletes can't be undone, so they always ask first."))
            Toggle(L10n.string("Show the full path in the window title"), isOn: $settings.showFullPathInTitle)
            Toggle(L10n.string("Offer to report crashes"), isOn: $settings.offerToReportCrashes)
                .accessibilityIdentifier(AXID.offerCrashReports)
            Section(L10n.string("Experimental")) {
                Toggle(L10n.string("Follow remote symlinks on SSH mounts"), isOn: $settings.experimentalRemoteLinkRemap)
                    .help(L10n.string("A symlink made on the remote computer stores a path like /home/you/file, which doesn't exist on this Mac. When such a link is broken here, macExplorer looks for the same path inside the mounted folder. Works with sshfs mounts (fuse-t and macFUSE)."))
            }
        }
        .formStyle(.grouped)
    }
}
