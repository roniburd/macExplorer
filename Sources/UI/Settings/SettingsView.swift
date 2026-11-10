import SwiftUI
import Core
import MacxFS

/// §7 Settings (SwiftUI in an NSWindow, SettingsWindowController): General, View, Sidebar, Shortcuts, Advanced tabs. Every control
/// writes straight to `Settings`, which persists the value and lets the open windows observe it.
struct SettingsView: View {
    let settings: Core.Settings
    let panels: any SettingsPanels
    let updates: UpdateModel
    let lanes: LanePool
    let iconPack: IconPackModel?
    @State private var section: SettingsSection

    init(settings: Core.Settings, panels: any SettingsPanels, updates: UpdateModel, lanes: LanePool,
         iconPack: IconPackModel? = nil, initialSection: SettingsSection = .general) {
        self.iconPack = iconPack
        self.settings = settings
        self.lanes = lanes
        self.panels = panels
        self.updates = updates
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
        case .general: GeneralSettingsView(settings: settings, panels: panels, updates: updates, iconPack: iconPack)
        case .view: ViewSettingsView(settings: settings)
        case .sidebar: SidebarSettingsView(settings: settings)
        case .shortcuts: ShortcutsSettingsView(settings: settings, panels: panels, lanes: lanes)
        case .advanced: AdvancedSettingsView(settings: settings)
        }
    }
}
