import SwiftUI
import Core

/// §7 General: startup folder (Home / last location / custom), open folders in, Return key, Terminal app.
struct GeneralSettingsView: View {
    @Bindable var settings: Core.Settings
    let panels: any SettingsPanels

    var body: some View {
        Form {
            Picker(L10n.string("Startup folder:"),
                   selection: SettingsChoices.startupBinding(in: settings) { [panels] in panels.chooseFolder() }) {
                ForEach(StartupFolderChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if let name = SettingsChoices.customFolderName(settings) {
                LabeledContent(L10n.string("Custom folder:")) {
                    HStack {
                        Text(name).lineLimit(1).truncationMode(.middle)
                        Button(L10n.string("Change…")) {
                            SettingsChoices.chooseCustomFolder(in: settings) { panels.chooseFolder() }
                        }
                    }
                }
            }
            Picker(L10n.string("Open folders in:"), selection: $settings.openFoldersIn) {
                ForEach([OpenFoldersIn.sameWindow, .newWindow], id: \.self) { Text(SettingsChoices.title(for: $0)).tag($0) }
            }
            Picker(L10n.string("Return key:"), selection: $settings.returnKey) {
                ForEach([ReturnKeyBehavior.open, .rename], id: \.self) { Text(SettingsChoices.title(for: $0)).tag($0) }
            }
            LabeledContent(L10n.string("Terminal app:")) {
                HStack {
                    Text(SettingsChoices.terminalAppName(settings)).lineLimit(1)
                    Button(L10n.string("Change…")) {
                        SettingsChoices.chooseTerminalApp(in: settings) { panels.chooseApplication() }
                    }
                    if settings.terminalApp != nil {
                        Button(L10n.string("Use Terminal")) { SettingsChoices.resetTerminalApp(in: settings) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
