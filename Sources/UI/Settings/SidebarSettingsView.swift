import SwiftUI
import Core

/// §7 Sidebar: show or hide each default favorite (removing one from the sidebar hides it; this brings it back) and
/// the Locations items.
struct SidebarSettingsView: View {
    @Bindable var settings: Core.Settings

    var body: some View {
        Form {
            Section(L10n.string("Favorites")) {
                ForEach(DefaultFavorite.allCases, id: \.self) { favorite in
                    Toggle(SettingsChoices.title(for: favorite), isOn: SettingsChoices.visibilityBinding(favorite, in: settings))
                }
            }
            Section(L10n.string("Locations")) {
                Toggle(L10n.string("iCloud Drive"), isOn: $settings.showICloudInSidebar)
                Toggle(L10n.string("Cloud storage (OneDrive, Google Drive, Dropbox…)"), isOn: $settings.showCloudStorageInSidebar)
                Toggle(L10n.string("External disks"), isOn: $settings.showExternalVolumesInSidebar)
            }
        }
        .formStyle(.grouped)
    }
}
