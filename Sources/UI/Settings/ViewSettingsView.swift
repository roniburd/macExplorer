import SwiftUI
import Core

/// §7 View: density, show hidden, thumbnails (P2-17), command bar, auto-reveal in tree, date format.
struct ViewSettingsView: View {
    @Bindable var settings: Core.Settings

    var body: some View {
        Form {
            Picker(L10n.string("Row density:"), selection: $settings.density) {
                ForEach(Density.allCases, id: \.self) { Text(SettingsChoices.title(for: $0)).tag($0) }
            }
            Toggle(L10n.string("Show hidden files and folders"), isOn: $settings.showHidden)
            Toggle(L10n.string("Show thumbnails"), isOn: $settings.showThumbnails)
            Toggle(L10n.string("Show all filename extensions"), isOn: $settings.showAllExtensions)
            Toggle(L10n.string("Show the command bar"), isOn: $settings.commandBarVisible)
            Toggle(L10n.string("Reveal the current folder in the tree"), isOn: $settings.autoRevealInTree)
            Picker(L10n.string("Dates:"), selection: $settings.dateStyle) {
                ForEach([DateStyle.relative, .absolute], id: \.self) { Text(SettingsChoices.title(for: $0)).tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}
