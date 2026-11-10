import AppKit
import SwiftUI
import Core

/// §7 General: startup folder (Home / last location / custom), open folders in, Return key, Terminal app; Updates
/// (channel, automatic checks, Check Now); Icon pack (P4-08).
struct GeneralSettingsView: View {
    @Bindable var settings: Core.Settings
    let panels: any SettingsPanels
    let updates: UpdateModel
    let iconPack: IconPackModel?

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
            if let iconPack {
                Picker(L10n.string("Icon pack:"), selection: Binding(
                    get: { iconPack.selection },
                    set: { choice in Task { await iconPack.select(choice) { [panels] in panels.chooseFolder() } } })) {
                    Text(L10n.string("None")).tag(IconPackChoice.none)
                    if let name = iconPack.folderName { Text(verbatim: name).tag(IconPackChoice.current) }
                    Divider()
                    Text(L10n.string("Choose Folder…")).tag(IconPackChoice.choose)
                }
                .accessibilityIdentifier(AXID.iconPackPicker)
                if let error = iconPack.error {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                }
            }
            Section(L10n.string("Updates")) {
                Picker(L10n.string("Channel:"), selection: Binding(
                    get: { settings.updateChannel },
                    set: { SettingsChoices.selectChannel($0, in: settings, updates: updates) })) {
                    ForEach(UpdateChannel.allCases, id: \.self) { Text(SettingsChoices.title(for: $0)).tag($0) }
                }
                .accessibilityIdentifier(AXID.updateChannel)
                if SettingsChoices.showsBetaToReleaseNote(settings: settings, installedVersion: updates.installedVersion) {
                    Text(L10n.string("You'll move to the next release that's newer than this beta."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L10n.string("Check for updates automatically"), isOn: Binding(
                    get: { settings.checkForUpdatesAutomatically },
                    set: { on in
                        if updates.isAvailable { updates.setAutomaticChecks(on) } else { settings.checkForUpdatesAutomatically = on }
                    }))
                .accessibilityIdentifier(AXID.automaticUpdateChecks)
                Button(L10n.string("Check Now")) {
                    SettingsChoices.checkNow(updates: updates) { NSApp.sendAction($0, to: nil, from: nil) }
                }
                .disabled(!updates.isAvailable)
                .accessibilityIdentifier(AXID.checkForUpdatesNow)
            }
        }
        .formStyle(.grouped)
    }
}
