import SwiftUI
import Core

/// §7 Advanced: confirm before trash (off by default), confirm before delete (always on, shown locked), full path in
/// the window title, offer to report crashes on the next launch.
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
        }
        .formStyle(.grouped)
    }
}
