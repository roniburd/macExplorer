// Sources/UI/Properties/PropertiesTabs.swift
import SwiftUI
import Core
import MacxFS

/// The tabs of one item (§5.8).
enum PropertiesTab: Hashable, CaseIterable {
    case general, permissions, opensWith, details

    static func tabs(showsOpensWith: Bool) -> [PropertiesTab] {
        showsOpensWith ? allCases : allCases.filter { $0 != .opensWith }
    }

    /// ⌃Tab / ⌃⇧Tab: the next (previous) tab, wrapping around.
    static func next(after tab: PropertiesTab, in tabs: [PropertiesTab], forward: Bool = true) -> PropertiesTab {
        guard let index = tabs.firstIndex(of: tab), !tabs.isEmpty else { return tabs.first ?? .general }
        return tabs[(index + (forward ? 1 : tabs.count - 1)) % tabs.count]
    }

    @MainActor var title: String {
        switch self {
        case .general: L10n.string("General")
        case .permissions: L10n.string("Permissions")
        case .opensWith: L10n.string("Opens with")
        case .details: L10n.string("Details")
        }
    }
}

/// A segmented tab bar in the content area. A TabView moved its tabs into the window toolbar on macOS 26, where
/// four of them didn't fit the 440 pt window and collapsed into a lone overflow chevron (QA round 1).
struct ItemTabs: View {
    @Bindable var model: PropertiesViewModel
    let item: ItemProperties
    let actions: PropertiesActions
    @State private var selected: PropertiesTab = .general

    var body: some View {
        let tabs = PropertiesTab.tabs(showsOpensWith: model.showsOpensWith)
        let current = tabs.contains(selected) ? selected : .general
        VStack(alignment: .leading, spacing: 8) {
            Picker(selection: $selected) {
                ForEach(tabs, id: \.self) { tab in Text(verbatim: tab.title).tag(tab) }
            } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("macx.properties.tabs")
                .background {
                    // ⌃Tab / ⌃⇧Tab switch tabs, as in Explorer's Properties dialog.
                    Button("") { selected = PropertiesTab.next(after: current, in: tabs) }
                        .keyboardShortcut(.tab, modifiers: .control).hidden()
                    Button("") { selected = PropertiesTab.next(after: current, in: tabs, forward: false) }
                        .keyboardShortcut(.tab, modifiers: [.control, .shift]).hidden()
                }
            switch current {
            case .general: GeneralTab(model: model, item: item, actions: actions)
            case .permissions: PermissionsTab(model: model, item: item)
            case .opensWith: OpensWithTab(model: model, actions: actions)
            case .details: DetailsTab(model: model, item: item)
            }
        }
    }
}
