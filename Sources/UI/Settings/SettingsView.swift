import SwiftUI
import Core

/// §7 Settings (SwiftUI in an NSWindow, SettingsWindowController): General, View, Sidebar, Advanced tabs. Every control
/// writes straight to `Settings`, which persists the value and lets the open windows observe it.
struct SettingsView: View {
    let settings: Core.Settings
    let panels: any SettingsPanels
    @State private var section: SettingsSection

    init(settings: Core.Settings, panels: any SettingsPanels, initialSection: SettingsSection = .general) {
        self.settings = settings
        self.panels = panels
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        TabView(selection: $section) {
            ForEach(SettingsSection.allCases, id: \.self) { section in
                page(section)
                    .tabItem { Label(section.title, systemImage: section.symbolName) }
                    .tag(section)
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func page(_ section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralSettingsView(settings: settings, panels: panels)
        case .view: ViewSettingsView(settings: settings)
        case .sidebar: SidebarSettingsView(settings: settings)
        case .advanced: AdvancedSettingsView(settings: settings)
        }
    }
}
